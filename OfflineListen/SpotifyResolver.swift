import Foundation

/// Turns Spotify metadata into something the existing download pipeline can
/// swallow: each Spotify track is matched to a real YouTube video, and a
/// collection becomes a `ResolvedPlaylist` — the same shape a YouTube playlist
/// resolves to, so the selection popup, the folder creation and the queue need
/// no changes at all.
///
/// The matching mirrors spotdl's strategy without any of its machinery: ISRC
/// first (an ISRC names a specific *recording*, so a hit is the right master
/// rather than a live take or a lyric-video re-upload), then
/// `"{artist} - {title}"`, gated on duration. No FFmpeg, no conversion, no
/// Python — the result is an ordinary YouTube watch URL that inherits
/// everything the app already does with one.
enum SpotifyResolver {
    private static let category = "Spotify"

    /// Every track costs at least one YouTube search, so one paste is bounded
    /// the way a Discography refresh is. Anything past the ceiling is dropped
    /// and logged — never silently truncated.
    static let maxTracks = 200

    /// How many searches run at once. Serial is far too slow for a 200-track
    /// playlist; all-at-once gets throttled by YouTube.
    static let concurrency = 5

    /// A candidate whose length differs from Spotify's by more than this is a
    /// different recording (an extended mix, a live version, a full-album
    /// upload) — take the next result instead.
    static let durationTolerance: TimeInterval = 15

    /// Matches every track in `collection` to a YouTube video and packages the
    /// hits as a `ResolvedPlaylist` titled after the collection (which becomes
    /// the library folder's name). Best-effort by nature: a track with no
    /// usable match drops out with a warning and the rest still come through.
    /// `onProgress` reports `(resolved, total)` as each search settles, so a
    /// long playlist doesn't look hung.
    static func resolve(_ collection: SpotifyCollection,
                        onProgress: @escaping @MainActor @Sendable (Int, Int) -> Void) async -> ResolvedPlaylist {
        var tracks = collection.tracks
        if tracks.count > maxTracks {
            appLog("\"\(collection.name)\" has \(tracks.count) tracks — resolving the first \(maxTracks) and dropping \(tracks.count - maxTracks).",
                   level: .warning, category: category)
            tracks = Array(tracks.prefix(maxTracks))
        }
        let bounded = tracks
        let total = bounded.count
        guard total > 0 else { return ResolvedPlaylist(title: collection.name, entries: []) }

        var matched: [Int: PlaylistEntry] = [:]
        var completed = 0

        await withTaskGroup(of: IndexedEntry.self) { group in
            // Keep `concurrency` searches in flight: seed that many, then start
            // one more each time a result lands.
            var scheduled = 0
            while scheduled < min(concurrency, total) {
                let index = scheduled
                group.addTask { IndexedEntry(index: index, entry: await Self.entry(for: bounded[index])) }
                scheduled += 1
            }

            while let result = await group.next() {
                completed += 1
                if let entry = result.entry { matched[result.index] = entry }
                await onProgress(completed, total)
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                if scheduled < total {
                    let index = scheduled
                    group.addTask { IndexedEntry(index: index, entry: await Self.entry(for: bounded[index])) }
                    scheduled += 1
                }
            }
        }

        let entries = matched.keys.sorted().compactMap { matched[$0] }
        // On cancellation the shortfall is the cancel, not a matching failure —
        // the caller marks the job cancelled and nothing is queued.
        if entries.count < total, !Task.isCancelled {
            appLog("\"\(collection.name)\": \(total - entries.count) of \(total) track(s) had no usable YouTube match and were skipped.",
                   level: .warning, category: category)
        }
        return ResolvedPlaylist(title: collection.name, entries: entries)
    }

    /// One track as a playlist entry, or nil when nothing matched.
    private static func entry(for track: SpotifyTrack) async -> PlaylistEntry? {
        guard let url = await youTubeURL(for: track) else { return nil }
        return PlaylistEntry(title: track.displayTitle, url: url,
                             artworkURL: track.albumImageURL)
    }

    /// Finds the YouTube video for one Spotify track.
    ///
    /// 1. **ISRC.** Searched bare. A hit is almost always the right recording,
    ///    so it's preferred outright — but it's still duration-checked when the
    ///    results page exposes a length, because a YouTube search *always*
    ///    returns something, and an ISRC nothing has tagged would otherwise
    ///    hand back an unrelated video with full confidence.
    /// 2. **`"{artist} - {title}"`**, through the same search resolver the AI
    ///    Discovery and Discography sources use, taking the first result whose
    ///    length is within `durationTolerance` of Spotify's.
    static func youTubeURL(for track: SpotifyTrack) async -> String? {
        if let isrc = track.isrc {
            let results = await YouTubeSearchResolver.topVideos(matching: isrc, limit: 3)
            if let hit = results.first(where: { fits(track: track, result: $0) }) {
                appLog("\"\(track.displayTitle)\" → ISRC \(isrc) matched \"\(hit.title)\".",
                       level: .debug, category: category)
                return BrowseHTTP.watchURL(forVideoID: hit.videoID)
            }
            if !results.isEmpty {
                appLog("\"\(track.displayTitle)\": ISRC \(isrc) returned nothing of the right length — falling back to a title search.",
                       level: .debug, category: category)
            }
        }

        let query = track.displayTitle
        let results = await YouTubeSearchResolver.topVideos(matching: query, limit: 5)
        guard !results.isEmpty else {
            appLog("No YouTube result for \"\(query)\" — skipping.", level: .warning, category: category)
            return nil
        }
        for result in results {
            guard fits(track: track, result: result) else {
                appLog("\"\(query)\": rejected \"\(result.title)\" (\(lengthDescription(result)) vs \(track.duration.asPlaybackTime)) — trying the next result.",
                       level: .debug, category: category)
                continue
            }
            appLog("\"\(query)\" → title search matched \"\(result.title)\".",
                   level: .debug, category: category)
            return BrowseHTTP.watchURL(forVideoID: result.videoID)
        }
        appLog("No YouTube result within \(Int(durationTolerance))s of \(track.duration.asPlaybackTime) for \"\(query)\" — skipping.",
               level: .warning, category: category)
        return nil
    }

    /// The duration gate. A result whose length the search page didn't expose
    /// passes (we don't reject on missing information), as does any track
    /// Spotify reported no duration for.
    private static func fits(track: SpotifyTrack, result: YouTubeSearchResult) -> Bool {
        guard track.durationMS > 0, let length = result.durationSeconds else { return true }
        return abs(length - track.duration) <= durationTolerance
    }

    private static func lengthDescription(_ result: YouTubeSearchResult) -> String {
        guard let length = result.durationSeconds else { return "unknown length" }
        return length.asPlaybackTime
    }
}

/// A task group result tagged with its position, so bounded-concurrency
/// matching still yields entries in Spotify's own order.
private struct IndexedEntry: Sendable {
    let index: Int
    let entry: PlaylistEntry?
}

// MARK: - Turning a folder of files into a record

/// What the catalogue can tell us about a folder that looks like an album.
///
/// A synced folder arrives as a directory of files: no order beyond the
/// alphabet, no artist, no sleeve. But a folder named after a record whose
/// files are named "Artist - Title" is carrying almost enough to identify
/// itself, and Spotify supplies the rest — the real tracklist order and the
/// cover — for **one or two requests**, which is the whole budget this is
/// allowed. The album search hit already carries the sleeve, so art alone is
/// a single request; the tracklist is the second, and it is cached for good
/// afterwards.
enum AlbumIdentifier {
    /// What a matched release says about itself.
    struct Match {
        let name: String
        let artist: String?
        let coverURL: String?
        /// Song titles in album order — empty when only the sleeve was asked
        /// for, or when the tracklist read failed (the cover is still worth
        /// having on its own).
        let titles: [String]
    }

    /// Splits "Artist - Title" — the naming scheme a folder of files most
    /// often arrives in — into its halves.
    ///
    /// The **first** separator wins, because a title may well contain another
    /// ("Marvin Gaye - Ain't No Mountain High Enough - Single Version") while
    /// an artist rarely does. A leading track number is stripped first: "03
    /// Artist - Title" and "03. Artist - Title" and "1-03 Artist - Title" are
    /// all the same thing wearing a different prefix. Anything without a
    /// separator returns nil rather than a guess — a file called "Track 04"
    /// is not telling us the artist is "Track 04".
    static func split(fileName: String) -> (artist: String, title: String)? {
        var text = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        text = strippingTrackNumber(from: text)
        for separator in [" - ", " – ", " — "] {
            guard let range = text.range(of: separator) else { continue }
            let artist = String(text[text.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = String(text[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !artist.isEmpty, !title.isEmpty else { return nil }
            return (artist, title)
        }
        return nil
    }

    /// Drops a leading "03", "03.", "03 -", "1-03" and the space after it.
    private static func strippingTrackNumber(from text: String) -> String {
        let pattern = "^\\s*\\d{1,2}([-.]\\d{1,2})?\\s*[.)-]?\\s+"
        guard let range = text.range(of: pattern, options: .regularExpression) else { return text }
        let rest = String(text[range.upperBound...])
        // Only when something recognisable is left: a track *named* "03" keeps
        // its name.
        return rest.isEmpty ? text : rest
    }

    /// Finds the release, and reads its tracklist when the order is wanted.
    /// Nil when nothing credible came back — a miss leaves the folder exactly
    /// as it was, which is the right outcome for a folder that only looked
    /// like an album.
    static func find(album: String, artist: String?, client: SpotifyClient,
                     wantsTracklist: Bool) async -> Match? {
        let hits: [SpotifyAlbumSummary]
        do {
            hits = try await client.searchAlbums(named: album, artist: artist)
        } catch {
            if isCancellation(error) { return nil }
            appLog("Album lookup for \"\(album)\" failed: \(error.localizedDescription)",
                   level: .warning, category: "Spotify")
            return nil
        }
        // The name has to actually match. Spotify answers *something* for
        // nearly any query, and a record silently retitled after somebody
        // else's album is worse than one left alone.
        guard let hit = hits.first(where: { discographyNamesMatch($0.name, album) }) else {
            appLog("No album on Spotify matches \"\(album)\" — leaving it as it is.",
                   level: .warning, category: "Spotify")
            return nil
        }

        var titles: [String] = []
        if wantsTracklist {
            // Titles only: the ISRC re-read this skips is for matching a
            // recording on YouTube, and nothing here is being matched to a
            // video. One request, cached for good.
            let read = try? await client.albums(ids: [hit.id], namesOnly: true)
            if let collection = read?[hit.id] {
                titles = collection.tracks.map(\.name)
            }
        }
        let credited = hit.artistName ?? "unnamed artist"
        let tracklist = titles.isEmpty ? "" : " (\(titles.count) track(s))"
        appLog("\"\(album)\" identified as \(hit.name) by \(credited)\(tracklist).",
               level: .success, category: "Spotify")
        return Match(name: hit.name, artist: hit.artistName,
                     coverURL: hit.imageURL, titles: titles)
    }
}

/// The **Convert to Album** and **Retrieve Album Art** actions, in one place
/// because they are the same errand at two depths.
@MainActor
enum AlbumConversion {
    /// Makes a folder an album: it becomes one immediately (the UI should not
    /// wait on a network round trip to redraw), its files' names are read for
    /// the artist and title they carry, and then — if Spotify is configured —
    /// the catalogue supplies the running order and the sleeve.
    ///
    /// Every step past the first is best-effort. A folder whose files aren't
    /// named "Artist - Title", or whose name isn't a record Spotify knows, is
    /// still an album; it just doesn't gain anything else.
    static func convert(_ folder: Folder, library: LibraryStore, client: SpotifyClient?) async {
        library.convertToAlbum(folder)
        let artist = library.applyFileNameMetadata(in: folder.id)
        guard let client else { return }
        guard let match = await AlbumIdentifier.find(album: folder.name, artist: artist,
                                                     client: client, wantsTracklist: true) else { return }
        library.orderTracks(in: folder.id, byTitles: match.titles)
        ArtworkFetcher.attach(match.coverURL, toFolder: folder.id, library: library)
    }

    /// The sleeve alone, for a record that already is one — one request, since
    /// the search hit carries the cover URL.
    static func retrieveArt(for folder: Folder, library: LibraryStore, client: SpotifyClient) async {
        let artist = library.folderArtist(of: folder.id)
        guard let match = await AlbumIdentifier.find(album: folder.name, artist: artist,
                                                     client: client, wantsTracklist: false),
              let cover = match.coverURL else { return }
        ArtworkFetcher.attach(cover, toFolder: folder.id, library: library)
    }
}
