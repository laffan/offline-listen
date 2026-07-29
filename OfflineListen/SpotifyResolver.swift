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
        return PlaylistEntry(title: track.displayTitle, url: url)
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
