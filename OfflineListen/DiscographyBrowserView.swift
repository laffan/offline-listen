import SwiftUI

// MARK: - Catalogue model
//
// The album-first "first pass": release and song *names* only, no YouTube
// work. Matching tracks to actual videos happens per release, on demand, when
// the user searches that release — which is what keeps opening a big catalogue
// instant instead of costing a search scrape per track up front. The same
// shapes serve both providers (Spotify's live catalogue and the AI layout),
// and they're Codable so a Browse source can persist its first pass.

struct DiscographyTrackInfo: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var artist: String
    var albumName: String
    /// Spotify's figures, when the provider has them — they gate the YouTube
    /// match on the right recording. The AI layout carries neither.
    var durationMS: Int?
    var isrc: String?
    /// The track's album-cover URL, when known — handed to the download so
    /// the finished track wears its art.
    var artworkURL: String? = nil
    /// A pre-matched watch URL, for tracks that *came from* YouTube (the
    /// search-ranked Top 10 backup) — the provider returns it directly
    /// instead of running a search that would only rediscover it.
    var youTubeURL: String? = nil
}

/// What a release row is, beyond an ordinary album: the pinned **Top 10**
/// (Spotify's most-played, "Search Top 10" button) or the AI layout's
/// **Highlights** list. Both sit above the albums and behave like a release.
enum DiscographyReleaseKind: String, Codable {
    case release
    case topTen
    case highlights
}

struct DiscographyRelease: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var year: String
    var totalTracks: Int
    var kind: DiscographyReleaseKind
    /// The release's cover-art URL (Spotify catalogues carry one; the AI
    /// layout has none). A thumbnail beside the row; full-size when expanded.
    var imageURL: String? = nil
    /// Inline tracklist (the AI layout carries its names up front); nil means
    /// the provider loads it on demand (a Spotify album's tracks).
    var tracks: [DiscographyTrackInfo]?
}

struct DiscographySection: Identifiable, Codable, Hashable {
    var title: String
    var releases: [DiscographyRelease]
    var id: String { title }
}

struct DiscographyCatalogue: Codable {
    var artistName: String
    var spotifyArtistID: String?
    /// The artist's portrait URL (Spotify), for the header. Nil for the AI
    /// catalogue, whose header is name-only.
    var artistImageURL: String? = nil
    var sections: [DiscographySection]
    var fetched: Date
}

// MARK: - Providers

/// Where a discography browser gets its data: the catalogue layout, each
/// release's tracks, and the on-demand YouTube match for one track.
protocol DiscographyProviding {
    /// The full first pass — names only, no YouTube work.
    func loadCatalogue() async throws -> DiscographyCatalogue
    /// A release's tracks (still names only), fetched if the layout carries none.
    func tracks(for release: DiscographyRelease) async throws -> [DiscographyTrackInfo]
    /// The YouTube video for one track, or nil when nothing usable matches.
    func youTubeURL(for track: DiscographyTrackInfo) async -> String?
}

/// The artist's *real* catalogue, live from Spotify: releases grouped
/// Albums / Singles & EPs / Compilations with a pinned **Top 10** on top.
/// Matching is ISRC-first with a duration gate (`SpotifyResolver`), so a hit
/// is almost always the right recording.
struct SpotifyDiscographyProvider: DiscographyProviding {
    let client: SpotifyClient
    let artistName: String
    /// Known Spotify artist id (the Every Noise data carries one per artist);
    /// nil makes `loadCatalogue` resolve the typed name via Spotify's search.
    var artistID: String? = nil
    /// When set (and a key is verified), the pinned Top 10's tracklist comes
    /// from the model (`DiscographyAgent.topTracks`) instead of Spotify's
    /// `/top-tracks` endpoint — which answers 403 (Forbidden) under newer
    /// client-credentials apps, and isn't needed just to *name* the songs.
    /// Spotify remains the fallback when no AI key is configured.
    var aiSettings: AISettingsStore? = nil

    func loadCatalogue() async throws -> DiscographyCatalogue {
        let resolvedID: String
        var resolvedName = artistName
        if let artistID {
            resolvedID = artistID
        } else {
            let hit = try await client.searchArtist(named: artistName)
            resolvedID = hit.id
            resolvedName = hit.name
        }
        // The portrait for the header; non-fatal if it doesn't come.
        let portrait = try? await client.artist(id: resolvedID)
        let albums = try await client.artistAlbums(id: resolvedID)

        // Top 10 pinned first — its tracks (and their YouTube matches) load on
        // demand, exactly like an album's. The release id doubles as the
        // artist id, which is what the top-tracks endpoint needs.
        var sections: [DiscographySection] = [
            DiscographySection(title: "", releases: [
                DiscographyRelease(id: resolvedID, name: "Top 10", year: "",
                                   totalTracks: 0, kind: .topTen, tracks: nil)
            ])
        ]
        func add(_ title: String, _ group: String) {
            let matches = albums.filter { $0.group == group }
                .sorted { $0.releaseDate > $1.releaseDate }
            guard !matches.isEmpty else { return }
            sections.append(DiscographySection(title: title, releases: matches.map {
                DiscographyRelease(id: $0.id, name: $0.name, year: $0.year,
                                   totalTracks: $0.totalTracks, kind: .release,
                                   imageURL: $0.imageURL, tracks: nil)
            }))
        }
        add("Albums", "album")
        add("Singles & EPs", "single")
        add("Compilations", "compilation")

        return DiscographyCatalogue(artistName: portrait?.name ?? resolvedName,
                                    spotifyArtistID: resolvedID,
                                    artistImageURL: portrait?.imageURL,
                                    sections: sections,
                                    fetched: Date())
    }

    func tracks(for release: DiscographyRelease) async throws -> [DiscographyTrackInfo] {
        let collection: SpotifyCollection
        switch release.kind {
        case .topTen:
            // Four sources, in order of preference. The **agent** knows the
            // popular canon and costs one call — but it answers [] for
            // artists it doesn't know, which is most of the Every Noise
            // map's long tail, so an empty answer isn't a failure: the
            // **catalogue itself** is read next, ranked by Spotify's
            // per-track popularity score (endpoints that still work). When
            // Spotify has nothing to rank either, **YouTube's own search
            // ranking** stands in — the long tail very often lives there —
            // and the dedicated **top-tracks endpoint** stays as the final
            // resort (it answers 403 under newer client-credentials apps,
            // but remains correct where it works).
            if let aiSettings, await aiSettings.isAuthenticated {
                let titles = (try? await DiscographyAgent.topTracks(artist: artistName,
                                                                    settings: aiSettings)) ?? []
                if !titles.isEmpty {
                    // Agent tracks carry no ISRC or duration, so their
                    // YouTube match falls to the plain title search — the
                    // same rule the AI layout lives by.
                    return titles.enumerated().map { index, title in
                        DiscographyTrackInfo(id: "top-\(index)", name: title, artist: artistName,
                                             albumName: "", durationMS: nil, isrc: nil)
                    }
                }
                appLog("Top 10: the model doesn't know \"\(artistName)\" — ranking the catalogue by popularity instead.",
                       category: "Browse")
            }
            if let derived = try? await client.derivedTopTracks(artistID: release.id),
               !derived.isEmpty {
                collection = SpotifyCollection(name: "Top 10", tracks: derived)
            } else {
                let fromYouTube = await YouTubeTopTracks.fetch(artist: artistName)
                if !fromYouTube.isEmpty { return fromYouTube }
                collection = try await client.artistTopTracks(id: release.id)
            }
        case .release, .highlights:
            collection = try await client.album(id: release.id)
        }
        let tracks = release.kind == .topTen
            ? Array(collection.tracks.prefix(10))
            : collection.tracks
        return tracks.map {
            DiscographyTrackInfo(id: $0.id, name: $0.name, artist: $0.primaryArtist,
                                 albumName: $0.albumName, durationMS: $0.durationMS,
                                 isrc: $0.isrc,
                                 artworkURL: $0.albumImageURL ?? release.imageURL)
        }
    }

    func youTubeURL(for track: DiscographyTrackInfo) async -> String? {
        if let direct = track.youTubeURL { return direct }
        return await SpotifyResolver.youTubeURL(for: SpotifyTrack(
            id: track.id,
            name: track.name,
            artists: track.artist.isEmpty ? [] : [track.artist],
            albumName: track.albumName,
            durationMS: track.durationMS ?? 0,
            isrc: track.isrc,
            trackNumber: nil,
            albumImageURL: track.artworkURL))
    }
}

/// The straight-from-YouTube Top 10: the artist's top organic search results,
/// taken as the tracklist directly. This is what serves the Every Noise
/// long tail — an artist too obscure for the model *and* too unstreamed for
/// a usable Spotify catalogue very often still has a healthy YouTube
/// presence, and the search page's own ranking is a popularity signal. Each
/// row arrives pre-matched (it *is* a video), so the Search step resolves
/// instantly.
enum YouTubeTopTracks {
    /// Song-length gate: an artist query's results include full-album uploads
    /// and hour-long compilations, which a "top tracks" list shouldn't be.
    private static let maxDuration: TimeInterval = 12 * 60

    static func fetch(artist: String, limit: Int = 10) async -> [DiscographyTrackInfo] {
        // Over-fetch so the length gate doesn't leave the list short.
        let results = await YouTubeSearchResolver.topVideos(matching: artist, limit: limit + 8)
        var tracks: [DiscographyTrackInfo] = []
        for result in results {
            if let length = result.durationSeconds, length > maxDuration { continue }
            // Artist deliberately empty: video titles almost always carry the
            // artist's name already, so prefixing it again would double up.
            tracks.append(DiscographyTrackInfo(
                id: "yt-\(result.videoID)",
                name: result.title,
                artist: "",
                albumName: "",
                durationMS: result.durationSeconds.map { Int($0 * 1000) },
                isrc: nil,
                youTubeURL: result.url))
            if tracks.count == limit { break }
        }
        appLog("Top 10 via YouTube search for \"\(artist)\": \(tracks.count) of \(results.count) result(s) kept.",
               level: tracks.isEmpty ? .warning : .info, category: "Browse")
        return tracks
    }
}

/// The AI-laid-out catalogue (`DiscographyAgent`): albums with song names and
/// a **Highlights** list on top, from one model call. With no ISRC or duration
/// to gate on, a track resolves to the top result of a YouTube search — the
/// same rule the old eager pipeline used, now paid per album on demand.
struct AIDiscographyProvider: DiscographyProviding {
    let artistName: String
    let settings: AISettingsStore

    func loadCatalogue() async throws -> DiscographyCatalogue {
        let discography = try await DiscographyAgent.layout(artist: artistName, settings: settings)

        var sections: [DiscographySection] = []
        if !discography.highlights.isEmpty {
            sections.append(DiscographySection(title: "", releases: [
                DiscographyRelease(id: "highlights",
                                   name: DiscographyAgent.highlightsTitle,
                                   year: "",
                                   totalTracks: discography.highlights.count,
                                   kind: .highlights,
                                   tracks: trackInfos(discography.highlights,
                                                      album: DiscographyAgent.highlightsTitle,
                                                      idPrefix: "hl"))
            ]))
        }
        // The model answers oldest-first; newest-first is how the Spotify
        // catalogue reads, so match it (ties keep the model's order).
        let ordered = discography.albums.enumerated().sorted { a, b in
            let ya = a.element.year ?? Int.min
            let yb = b.element.year ?? Int.min
            return ya != yb ? ya > yb : a.offset < b.offset
        }.map(\.element)
        if !ordered.isEmpty {
            sections.append(DiscographySection(title: "Albums", releases: ordered.enumerated().map { index, album in
                DiscographyRelease(id: "album-\(index)-\(album.title)",
                                   name: album.title,
                                   year: album.year.map(String.init) ?? "",
                                   totalTracks: album.tracks.count,
                                   kind: .release,
                                   tracks: trackInfos(album.tracks, album: album.title,
                                                      idPrefix: "a\(index)"))
            }))
        }

        return DiscographyCatalogue(artistName: artistName,
                                    spotifyArtistID: nil,
                                    sections: sections,
                                    fetched: Date())
    }

    private func trackInfos(_ names: [String], album: String, idPrefix: String) -> [DiscographyTrackInfo] {
        names.enumerated().map { index, name in
            DiscographyTrackInfo(id: "\(idPrefix)-\(index)", name: name, artist: artistName,
                                 albumName: album, durationMS: nil, isrc: nil)
        }
    }

    func tracks(for release: DiscographyRelease) async throws -> [DiscographyTrackInfo] {
        release.tracks ?? []
    }

    func youTubeURL(for track: DiscographyTrackInfo) async -> String? {
        if let direct = track.youTubeURL { return direct }
        let query = "\(track.artist) \(track.name)"
        guard let videoID = await YouTubeSearchResolver.firstVideoID(matching: query) else {
            appLog("No YouTube result for \"\(query)\" — skipping.",
                   level: .warning, category: "Browse")
            return nil
        }
        return BrowseHTTP.watchURL(forVideoID: videoID)
    }
}

// MARK: - The browser

/// Wiring for the browser header's **Add as Source** button: how to file the
/// browsed artist into Browse, and whether an equivalent source is already
/// there (the button then reads as a checkmark instead of adding a copy).
/// Passed by the Every Noise push only — a Browse source's own screen *is*
/// a source, so it passes nothing and shows no button.
struct DiscographyAddSource {
    var isAdded: () -> Bool
    var add: () -> Void
}

/// The shared album-first discography screen: sections of release rows, each
/// expandable to its track names, each searchable to match those tracks
/// against YouTube in place — matched tracks light up with Download/Preview
/// beside them, misses are dimmed. Serves both the Every Noise browser's
/// "Browse Discography" push and the Browse tab's discography-mode Artist
/// sources; only the provider (and whether the first pass is cached) differs.
struct DiscographyBrowserView: View {
    let title: String
    let provider: any DiscographyProviding
    /// Library folder new downloads file into — Browse sources pass their name
    /// so everything from one source stays together. Nil leaves picks unfiled
    /// (the Every Noise browser's single-track behaviour).
    var downloadFolderName: String? = nil
    /// Where a cached first pass comes from / goes to. Browse sources persist
    /// theirs so re-opening doesn't re-run the fetch; Every Noise passes
    /// neither and loads live, as it always has.
    var loadCached: (() -> DiscographyCatalogue?)? = nil
    var onFetched: ((DiscographyCatalogue) -> Void)? = nil
    /// The header's Add as Source button (nil hides it — see the type).
    var addSource: DiscographyAddSource? = nil

    @EnvironmentObject private var browse: BrowseStore

    @State private var catalogue: DiscographyCatalogue?
    @State private var loadError: String?
    @State private var loading = false
    /// The track being auditioned — the same preview modal Browse rows use —
    /// and the release's other matched tracks, so the modal's next/previous
    /// buttons walk the record rather than dead-ending on one song.
    @State private var previewItem: BrowseItem?
    @State private var previewQueue: [BrowseItem] = []
    /// The header's Learn More sheet, and its once-per-visit cached result.
    @State private var showingBio = false
    @State private var bio: ArtistBio?

    var body: some View {
        Group {
            if let catalogue {
                if catalogue.sections.isEmpty {
                    ContentUnavailableViewCompat(
                        title: "Nothing listed",
                        systemImage: "opticaldisc",
                        description: "No releases came back for this artist."
                    )
                } else {
                    releaseList(catalogue)
                }
            } else if let loadError {
                VStack(spacing: 16) {
                    ContentUnavailableViewCompat(
                        title: "Couldn't load the discography",
                        systemImage: "exclamationmark.triangle",
                        description: loadError
                    )
                    Button {
                        Task { await fetch() }
                    } label: {
                        Label("Try Again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                ProgressView("Reading the catalogue…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if loading && catalogue != nil {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await fetch() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(loading)
                    .accessibilityLabel("Refresh the catalogue")
                }
            }
        }
        .sheet(item: $previewItem) { item in
            BrowsePreviewView(item: item, mode: browse.downloadMode, queue: previewQueue)
        }
        .sheet(isPresented: $showingBio) {
            ArtistBioSheet(artistName: catalogue?.artistName ?? title, bio: $bio)
        }
        // A refresh that fails with a catalogue already showing keeps the old
        // one — this surfaces why nothing changed.
        .alert("Couldn't refresh", isPresented: refreshErrorPresented) {
            Button("OK") {}
        } message: {
            Text(loadError ?? "")
        }
        .task {
            guard catalogue == nil else { return }
            if let cached = loadCached?() {
                catalogue = cached
                return
            }
            await fetch()
        }
    }

    private var refreshErrorPresented: Binding<Bool> {
        Binding(
            get: { loadError != nil && catalogue != nil },
            set: { if !$0 { loadError = nil } }
        )
    }

    private func releaseList(_ catalogue: DiscographyCatalogue) -> some View {
        List {
            Section {
                artistHeader(catalogue)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(catalogue.sections) { section in
                Section(section.title) {
                    ForEach(section.releases) { release in
                        DiscographyReleaseRow(release: release,
                                              provider: provider,
                                              artistName: catalogue.artistName,
                                              downloadFolderName: downloadFolderName) { item, queue in
                            previewQueue = queue
                            previewItem = item
                        }
                    }
                }
            }
        }
        .insetGroupedListStyle()
        .miniPlayerClearance()
    }

    /// The page's masthead: the artist's portrait (when the catalogue carries
    /// one — Spotify does, the AI layout doesn't), their name in large type,
    /// and the **Learn More** button that opens the AI bio sheet.
    private func artistHeader(_ catalogue: DiscographyCatalogue) -> some View {
        VStack(spacing: 12) {
            if let urlString = catalogue.artistImageURL, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        ZStack {
                            Color.secondary.opacity(0.12)
                            Image(systemName: "music.mic")
                                .font(.system(size: 44))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 180, height: 180)
                .clipShape(Circle())
                .shadow(radius: 8, y: 4)
            }
            Text(catalogue.artistName)
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button {
                    showingBio = true
                } label: {
                    Label("Learn More", systemImage: "text.book.closed")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)

                // Files the artist into Browse as a discography-mode Artist
                // source. `isAdded` reads the live source list, so the label
                // flips to a checkmark the moment the source exists (and
                // shows as one from the start if it already did).
                if let addSource {
                    let added = addSource.isAdded()
                    Button {
                        addSource.add()
                    } label: {
                        Label(added ? "In Browse" : "Add as Source",
                              systemImage: added ? "checkmark.circle.fill" : "plus.circle")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .disabled(added)
                    .foregroundStyle(added ? Color.green : Color.accentColor)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    @MainActor
    private func fetch() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let fresh = try await provider.loadCatalogue()
            catalogue = fresh
            loadError = nil
            onFetched?(fresh)
        } catch {
            if isCancellation(error) { return }
            loadError = error.localizedDescription
        }
    }
}

/// One release row: name, year and track count, plus a **search** button that
/// matches the tracklist against YouTube (labelled **Search Top 10** on the
/// pinned Top 10 row). Expanding shows the cover full-size, a **Download
/// Album** button beneath it, and then the track names; after a search,
/// matched tracks carry Download/Preview and misses are dimmed. The Download
/// button becomes the shared green play button once its track lands in the
/// library.
private struct DiscographyReleaseRow: View {
    let release: DiscographyRelease
    let provider: any DiscographyProviding
    /// The catalogue's artist, for naming the folder a Top 10 / Highlights
    /// bulk download files into (a release names its own).
    let artistName: String
    let downloadFolderName: String?
    /// The tapped track and the release's other matched tracks — the queue the
    /// preview modal walks with next/previous.
    let onPreview: (BrowseItem, [BrowseItem]) -> Void

    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var browse: BrowseStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager

    @State private var expanded = false
    @State private var tracks: [DiscographyTrackInfo]?
    @State private var trackError: String?
    @State private var searching = false
    @State private var searched = false
    @State private var progress = (done: 0, total: 0)
    /// track id → matched YouTube watch URL (absent = no match once searched).
    @State private var matches: [String: String] = [:]
    /// Tracks already sent to the download queue from this row.
    @State private var sent: Set<String> = []
    /// The tracklist fetch in flight, if any — see `loadTracks`.
    @State private var loadTask: Task<Void, Never>?
    /// The YouTube match pass in flight, if any — see `runSearch`. Single-flight
    /// for the same reason `loadTask` is: **Download Album** needs the search's
    /// results, and pressing it mid-search must join that pass rather than
    /// start a second one (or read a half-filled `matches`).
    @State private var searchTask: Task<Void, Never>?
    /// True while **Download Album** is matching and queueing. Once the jobs
    /// are in the queue the button reads the *library* instead, so it keeps
    /// telling the truth across a redraw — and still offers to play a record
    /// downloaded on an earlier visit.
    @State private var queueing = false
    /// The URLs this row sent to the queue, which is what tells "downloading"
    /// apart from "some of these happen to be in the library already".
    @State private var queuedURLs: Set<String> = []

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            expandedCover
            downloadAllButton
            trackRows
        } label: {
            HStack(spacing: 12) {
                if let thumb = release.imageURL.flatMap(URL.init(string:)) {
                    AsyncImage(url: thumb) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Color.secondary.opacity(0.12)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(release.name)
                        .fontWeight(release.kind == .release ? .regular : .medium)
                        .lineLimit(2)
                    if !detailLine.isEmpty {
                        Text(detailLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                searchControl
            }
        }
        .onChange(of: expanded) { open in
            // `!searching` matters: the Search button expands the row itself
            // and runs its own load — reacting here too double-fetched.
            guard open, tracks == nil, trackError == nil, !searching else { return }
            Task { await loadTracks() }
        }
    }

    @ViewBuilder
    private var searchControl: some View {
        if searching {
            ProgressView()
        } else if searched {
            Image(systemName: "magnifyingglass.circle.fill")
                .font(.title3)
                .foregroundStyle(.tertiary)
        } else if release.kind == .topTen {
            // The one labelled search button — the pinned row's whole point.
            Button {
                search()
            } label: {
                Label("Search Top 10", systemImage: "magnifyingglass")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderless)
        } else {
            Button {
                search()
            } label: {
                Image(systemName: "magnifyingglass.circle")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Find \(release.name)'s tracks on YouTube")
        }
    }

    /// The full-size cover, first thing under the twirled-open row. The same
    /// URL the thumbnail used, so it's usually already in the URL cache.
    @ViewBuilder
    private var expandedCover: some View {
        if let url = release.imageURL.flatMap(URL.init(string:)) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.secondary.opacity(0.12))
                        .aspectRatio(1, contentMode: .fit)
                }
            }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.vertical, 4)
        }
    }

    /// What the whole-release button is offering right now. Everything past
    /// the queueing moment is derived from the **library**, not from what this
    /// row remembers doing: that's what keeps the count honest as downloads
    /// land one by one, and what lets the button offer to play a record that
    /// was pulled down on an earlier visit.
    private enum BulkState {
        /// Matching the tracklist against YouTube, or queueing the results.
        case working
        /// Ready to download; the count is how many tracks matched (0 before
        /// a search has run, or when nothing matched at all).
        case idle(Int)
        /// Queued and arriving: how many of them are in the library so far.
        case downloading(landed: Int, total: Int)
        /// All of them are in the library, in one folder — play it.
        case ready(UUID)
    }

    private var bulkState: BulkState {
        if queueing { return .working }
        let urls = matchedURLs
        guard !urls.isEmpty else { return .idle(0) }
        let landed = urls.compactMap { library.track(forSourceURL: $0) }
        let folders = Set(landed.compactMap(\.folderID))
        if landed.count == urls.count, folders.count == 1, let folder = folders.first {
            return .ready(folder)
        }
        if !queuedURLs.isEmpty { return .downloading(landed: landed.count, total: urls.count) }
        return .idle(urls.count)
    }

    /// Every track of this release that matched a video, in tracklist order.
    private var matchedURLs: [String] {
        (tracks ?? []).compactMap { matches[$0.id] }
    }

    /// **Download Album** — one tap for the whole record: it runs the YouTube
    /// match first when the release hasn't been searched yet, then queues every
    /// track that matched into a library folder named after the release (with
    /// the cover attached to it). It counts the downloads in as they land and
    /// turns into **Play Album** once the record is complete. Sits directly
    /// under the cover and above the tracklist, which is where an action on the
    /// *whole* release belongs — the per-track buttons stay where they were.
    @ViewBuilder
    private var downloadAllButton: some View {
        let state = bulkState
        VStack(spacing: 6) {
            Button {
                if case .ready(let folderID) = state {
                    playAlbum(in: folderID)
                } else {
                    downloadAll()
                }
            } label: {
                HStack(spacing: 8) {
                    if case .working = state {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: icon(for: state))
                    }
                    Text(label(for: state))
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(isReady(state) ? Color.green : Color.accentColor)
            .disabled(isBusy(state) || (searched && matches.isEmpty))

            // A real bar for the real thing: "3 of 12" alone reads as a label,
            // and a whole album takes long enough to want a shape for it.
            if case .downloading(let landed, let total) = state, total > 0 {
                ProgressView(value: Double(landed), total: Double(total))
                    .progressViewStyle(.linear)
            }
        }
        .padding(.vertical, 4)
    }

    private func label(for state: BulkState) -> String {
        switch state {
        case .working:
            return progress.total > 0 && progress.done < progress.total
                ? "Matching \(progress.done) of \(progress.total)…"
                : "Queueing…"
        case .downloading(let landed, let total):
            return "Downloading \(landed) of \(total)…"
        case .ready:
            return "Play \(bulkNoun)"
        case .idle(let matched):
            if searched {
                return matched == 0
                    ? "Nothing matched on YouTube"
                    : "Download \(bulkNoun) (\(matched))"
            }
            return "Download \(bulkNoun)"
        }
    }

    private func icon(for state: BulkState) -> String {
        switch state {
        case .ready: return "play.circle.fill"
        case .downloading: return "arrow.down.circle"
        default: return "arrow.down.circle.fill"
        }
    }

    private func isReady(_ state: BulkState) -> Bool {
        if case .ready = state { return true }
        return false
    }

    private func isBusy(_ state: BulkState) -> Bool {
        switch state {
        case .working, .downloading: return true
        case .idle, .ready: return false
        }
    }

    /// What the bulk button calls this release: a real album is an "Album",
    /// while the pinned Top 10 / Highlights rows are lists, not records.
    private var bulkNoun: String {
        release.kind == .release ? "Album" : "All"
    }

    /// The library folder a bulk download files into. A release names its own;
    /// Top 10 / Highlights are qualified by the artist, since "Top 10" alone
    /// would collide across every artist you ever browse.
    private var bulkFolderName: String {
        guard release.kind != .release else { return release.name }
        let artist = artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        return artist.isEmpty ? release.name : "\(artist) — \(release.name)"
    }

    @ViewBuilder
    private var trackRows: some View {
        if let trackError {
            Text(trackError)
                .font(.caption)
                .foregroundStyle(.orange)
        } else if let tracks {
            if searching {
                Text("Matching \(progress.done) of \(progress.total)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                trackRow(number: index + 1, track: track)
            }
        } else {
            ProgressView()
        }
    }

    private func trackRow(number: Int, track: DiscographyTrackInfo) -> some View {
        HStack(spacing: 10) {
            Text("\(number).  \(track.name)")
                .font(.callout)
                .fontWeight(matches[track.id] != nil ? .medium : .regular)
                .foregroundStyle(trackStyle(track))
                .lineLimit(2)
            Spacer(minLength: 8)
            if let url = matches[track.id] {
                if sent.contains(track.id) || library.track(forSourceURL: url) != nil {
                    // Becomes the shared green play button the moment the
                    // track is in the library — a download sent from here,
                    // *or* a preview auditioned and saved (which never
                    // touches `sent`, so the library is checked directly).
                    BrowseTrackStatusButton(sourceURL: url,
                                            pendingIcon: "checkmark.circle.fill",
                                            pendingLabel: "Sent to Downloads")
                } else {
                    Button {
                        enqueue(track, url: url)
                        sent.insert(track.id)
                    } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Download \(track.name)")
                }
                Button {
                    // Hand over the whole release, not just this song: the
                    // modal's next/previous walk it, and it auto-advances at
                    // the end of each track.
                    let queue = previewQueue
                    onPreview(queue.first(where: { $0.url == url }) ?? browseItem(for: track, url: url),
                              queue)
                } label: {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Preview \(track.name)")
            } else if searched {
                Text("no match")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func trackStyle(_ track: DiscographyTrackInfo) -> HierarchicalShapeStyle {
        if matches[track.id] != nil { return .primary }
        return searched ? .tertiary : .secondary
    }

    /// Queues one matched track — with its album art *and the catalogue's own
    /// title and artist* riding along, so the finished download wears both
    /// rather than a YouTube video title. A Browse source files it into the
    /// folder named after the source; the Every Noise browser's picks stay
    /// unfiled.
    private func enqueue(_ track: DiscographyTrackInfo, url: String) {
        let known = knownMetadata(for: track)
        let artworkURL = track.artworkURL ?? release.imageURL
        if let folder = downloadFolderName, !folder.isEmpty {
            downloads.enqueue(urlString: url, mode: browse.downloadMode,
                              browseFolderNamed: folder, artworkURL: artworkURL,
                              knownTitle: known.title, knownArtist: known.artist)
        } else {
            downloads.enqueue(urlString: url, mode: browse.downloadMode,
                              artworkURL: artworkURL,
                              knownTitle: known.title, knownArtist: known.artist)
        }
    }

    /// What the catalogue knows about a track, when it's worth carrying into
    /// the download. The **YouTube-ranked Top 10** backup is the exception:
    /// its "tracks" are video titles with no artist at all, which is exactly
    /// what the download would have arrived with anyway — so it passes
    /// nothing and the AI organizer gets its usual go at them.
    private func knownMetadata(for track: DiscographyTrackInfo) -> (title: String?, artist: String?) {
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = track.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty, !name.isEmpty else { return (nil, nil) }
        return (name, artist)
    }

    /// Plays the downloaded album from its first track. A folder is a curated
    /// playlist, so it runs straight through in list order — which, thanks to
    /// the ordered insert the album download uses, is the release's own order.
    private func playAlbum(in folderID: UUID) {
        let albumTracks = library.tracks(in: folderID)
        guard let first = albumTracks.first else { return }
        playback.play(first, in: albumTracks, restrictToCategory: false)
    }

    /// Fetches the tracklist (also triggered by plain expansion, so the
    /// search never runs against a missing list). **Single-flight**: Search
    /// and the expansion it triggers used to fetch concurrently — two
    /// identical model calls for the Top 10 row, and whichever finished last
    /// was free to overwrite the list, or worse, *error over* one the first
    /// had already delivered. A second caller now awaits the fetch already
    /// in flight instead of starting its own. A failure also never clobbers
    /// a loaded list, and a success clears any earlier error. Main-actor:
    /// these methods write `@State`, and a Task spawned in a nonisolated
    /// context wouldn't come back to the main thread on its own.
    @MainActor
    private func loadTracks() async {
        if let inFlight = loadTask {
            await inFlight.value
            return
        }
        let task = Task { @MainActor in
            do {
                tracks = try await provider.tracks(for: release)
                trackError = nil
            } catch {
                if isCancellation(error) { return }
                if tracks == nil { trackError = error.localizedDescription }
            }
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    /// The search button's action — fire and forget; `runSearch` owns the work.
    @MainActor
    private func search() {
        Task { await runSearch() }
    }

    /// The search: resolve each track to a YouTube video via the provider
    /// (ISRC-first for Spotify, top search hit for the AI layout), updating
    /// the rows as each match lands. **Single-flight**, like `loadTracks`: a
    /// second caller (the Search button and Download Album can both want it)
    /// awaits the pass already running instead of starting a rival one.
    @MainActor
    private func runSearch() async {
        if let inFlight = searchTask {
            await inFlight.value
            return
        }
        let task = Task { @MainActor in await performSearch() }
        searchTask = task
        await task.value
        searchTask = nil
    }

    @MainActor
    private func performSearch() async {
        expanded = true
        searching = true
        if tracks == nil { await loadTracks() }
        guard let tracks, !tracks.isEmpty else {
            searching = false
            searched = self.tracks != nil
            return
        }
        progress = (0, tracks.count)
        for (index, track) in tracks.enumerated() {
            if let url = await provider.youTubeURL(for: track) {
                matches[track.id] = url
            }
            progress = (index + 1, tracks.count)
        }
        searching = false
        searched = true
    }

    /// **Download Album**: match the release against YouTube if that hasn't
    /// happened yet, then queue every track that matched into one folder. The
    /// misses are simply left out — "all available tracks" is what matched, and
    /// the tracklist below shows which those were.
    @MainActor
    private func downloadAll() {
        guard !queueing else { return }
        expanded = true
        queueing = true
        Task {
            if !searched { await runSearch() }
            if let tracks {
                // Tracklist order is the order these go in, and the queue
                // preserves it however fast each one downloads.
                let picks: [DownloadManager.AlbumTrack] = tracks.compactMap { track in
                    guard let url = matches[track.id] else { return nil }
                    let known = knownMetadata(for: track)
                    return DownloadManager.AlbumTrack(url: url,
                                                      title: known.title,
                                                      artist: known.artist,
                                                      artworkURL: track.artworkURL ?? release.imageURL)
                }
                if !picks.isEmpty {
                    downloads.enqueueAlbum(named: bulkFolderName,
                                           tracks: picks,
                                           mode: browse.downloadMode,
                                           insideFolderNamed: downloadFolderName,
                                           artworkURL: release.imageURL)
                    // The per-track buttons follow suit, so a row doesn't offer
                    // to download something already on its way.
                    sent.formUnion(tracks.filter { matches[$0.id] != nil }.map(\.id))
                    queuedURLs = Set(picks.map(\.url))
                }
            }
            queueing = false
        }
    }

    /// This release's matched tracks as preview items, in tracklist order —
    /// the queue the modal's next/previous buttons step through. Built fresh
    /// per tap (a `BrowseItem` mints a new id each time), so the tapped item
    /// is taken *out of* this list rather than made separately.
    private var previewQueue: [BrowseItem] {
        (tracks ?? []).compactMap { track in
            matches[track.id].map { browseItem(for: track, url: $0) }
        }
    }

    /// Wraps a matched track as a Browse item so the standard preview modal
    /// can audition it. The item is ephemeral (its id lives in no store), and
    /// every store call the modal makes is an id lookup, so nothing sticks.
    private func browseItem(for track: DiscographyTrackInfo, url: String) -> BrowseItem {
        BrowseItem(sourceID: UUID(),
                   title: track.artist.isEmpty ? track.name : "\(track.artist) — \(track.name)",
                   detail: release.name,
                   url: url,
                   videoID: URLComponents(string: url)?.queryItems?.first(where: { $0.name == "v" })?.value,
                   artworkURL: track.artworkURL)
    }

    private var detailLine: String {
        switch release.kind {
        case .topTen:
            return "Their most played, matched against YouTube"
        case .highlights:
            return "Essential songs"
        case .release:
            var parts: [String] = []
            if !release.year.isEmpty { parts.append(release.year) }
            if release.totalTracks > 0 {
                parts.append("\(release.totalTracks) track\(release.totalTracks == 1 ? "" : "s")")
            }
            return parts.joined(separator: " · ")
        }
    }
}

// MARK: - The Browse source wrapper

/// A discography-mode Artist source's screen: the shared browser wired to the
/// right provider (live Spotify catalogue or the AI layout), with the first
/// pass persisted per source so re-opening doesn't re-run the fetch — the
/// toolbar's refresh re-reads it. Downloads file into a folder named after
/// the source, like every other Browse download.
struct ArtistDiscographySourceView: View {
    let sourceID: UUID

    @EnvironmentObject private var browse: BrowseStore
    @EnvironmentObject private var aiSettings: AISettingsStore
    @EnvironmentObject private var spotifySettings: SpotifySettingsStore

    private var source: BrowseSource? {
        browse.sources.first { $0.id == sourceID }
    }

    var body: some View {
        if let source {
            switch source.artistSourceMode {
            case .spotifyDiscography:
                if let client = spotifySettings.client {
                    browser(for: source,
                            provider: SpotifyDiscographyProvider(client: client,
                                                                 artistName: source.input,
                                                                 aiSettings: aiSettings))
                } else {
                    ContentUnavailableViewCompat(
                        title: "Spotify isn't set up",
                        systemImage: "key",
                        description: "This source reads the discography live from Spotify. Add credentials in Settings ▸ Spotify first."
                    )
                    .navigationTitle(source.name)
                    .navigationBarTitleDisplayMode(.inline)
                }
            default:
                browser(for: source,
                        provider: AIDiscographyProvider(artistName: source.input,
                                                        settings: aiSettings))
            }
        }
    }

    private func browser(for source: BrowseSource, provider: any DiscographyProviding) -> some View {
        DiscographyBrowserView(
            title: source.name,
            provider: provider,
            downloadFolderName: source.name,
            loadCached: { browse.loadDiscographyCatalogue(for: source.id) },
            onFetched: { browse.saveDiscographyCatalogue($0, for: source.id) })
    }
}

extension AppPaths {
    /// One saved first pass per discography-mode Artist source.
    static var discographies: URL {
        let url = documents.appendingPathComponent("Discographies", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func discographyCatalogue(for sourceID: UUID) -> URL {
        discographies.appendingPathComponent("\(sourceID.uuidString).json")
    }
}

// MARK: - Learn More (artist bio)

/// What the Learn More sheet shows: the bio prose plus a Wikipedia link when
/// the lookup found a real page. Cached in the browser's state so reopening
/// the sheet doesn't re-run the model.
struct ArtistBio: Equatable {
    var text: String
    var wikipediaTitle: String?
    var wikipediaURL: String?
}

/// The header's **Learn More** sheet: a brief AI-written artist bio with a
/// link to the Wikipedia entry when one exists.
///
/// Two sources, deliberately split: the *link* comes from Wikipedia's own
/// search API — a page that actually exists, never a model-suggested URL (it
/// hallucinates those) — and the *prose* comes from the Anthropic model,
/// grounded on the page's summary when one was found. Without an AI key the
/// Wikipedia summary itself stands in as the bio, so the button still works.
struct ArtistBioSheet: View {
    let artistName: String
    @Binding var bio: ArtistBio?

    @EnvironmentObject private var aiSettings: AISettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let bio {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(bio.text)
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let urlString = bio.wikipediaURL, let url = URL(string: urlString) {
                                Link(destination: url) {
                                    Label("Read more on Wikipedia", systemImage: "book")
                                        .font(.subheadline.weight(.semibold))
                                }
                            }
                        }
                        .padding()
                    }
                } else if let loadError {
                    ContentUnavailableViewCompat(
                        title: "No bio available",
                        systemImage: "text.book.closed",
                        description: loadError
                    )
                } else {
                    ProgressView("Reading up on \(artistName)…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(artistName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    @MainActor
    private func load() async {
        guard bio == nil else { return }
        let wiki = await WikipediaLookup.find(artistName)

        if aiSettings.isAuthenticated {
            do {
                let client = AnthropicClient(apiKey: aiSettings.apiKey, model: aiSettings.model)
                var userText = "Artist: \(artistName)"
                if let wiki, !wiki.extract.isEmpty {
                    userText += "\n\nWikipedia's summary, for grounding:\n\(wiki.extract)"
                }
                let text = try await client.complete(
                    system: Self.systemPrompt,
                    userText: userText,
                    maxTokens: 1024
                )
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { throw BrowseFetchError.badInput("Empty response.") }
                bio = ArtistBio(text: trimmed,
                                wikipediaTitle: wiki?.title,
                                wikipediaURL: wiki?.url)
                return
            } catch {
                if isCancellation(error) { return }
                appLog("Artist bio failed for \"\(artistName)\": \(error.localizedDescription)",
                       level: .warning, category: "Browse")
                // Fall through to the Wikipedia summary, if there is one.
            }
        }

        if let wiki, !wiki.extract.isEmpty {
            bio = ArtistBio(text: wiki.extract,
                            wikipediaTitle: wiki.title,
                            wikipediaURL: wiki.url)
        } else if aiSettings.isAuthenticated {
            loadError = "Couldn't put together a bio for \(artistName). Try again in a moment."
        } else {
            loadError = "No Wikipedia entry was found, and AI bios need an Anthropic API key (Settings ▸ AI)."
        }
    }

    private static let systemPrompt = """
    You are a music writer. Write a brief biography of the musician or band \
    the user names: who they are, where and when they emerged, what they \
    sound like, and why they matter. About 120 words, at most two short \
    paragraphs, plain prose — no headings, lists or markdown. If a Wikipedia \
    summary is provided, treat it as ground truth. If you don't recognize \
    the artist and no summary is provided, say so in one sentence instead \
    of guessing.
    """
}

/// Finds an artist's Wikipedia page — search first (so the page provably
/// exists), then the summary endpoint for its extract and canonical URL.
/// Best-effort: any failure is just "no page".
enum WikipediaLookup {
    struct Page {
        let title: String
        let url: String
        let extract: String
    }

    static func find(_ query: String) async -> Page? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://en.wikipedia.org/w/rest.php/v1/search/page?q=\(encoded)&limit=1") else {
            return nil
        }
        do {
            var request = URLRequest(url: searchURL)
            request.timeoutInterval = 15
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let search = try? JSONDecoder().decode(SearchResponse.self, from: data),
                  let hit = search.pages?.first, let key = hit.key, !key.isEmpty,
                  let summaryURL = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(key)") else {
                return nil
            }
            let (summaryData, _) = try await URLSession.shared.data(from: summaryURL)
            guard let summary = try? JSONDecoder().decode(Summary.self, from: summaryData) else {
                return nil
            }
            let pageURL = summary.contentURLs?.desktop?.page ?? "https://en.wikipedia.org/wiki/\(key)"
            return Page(title: summary.title ?? hit.title ?? query,
                        url: pageURL,
                        extract: summary.extract ?? "")
        } catch {
            return nil
        }
    }

    private struct SearchResponse: Decodable {
        let pages: [Hit]?
        struct Hit: Decodable {
            let key: String?
            let title: String?
        }
    }

    private struct Summary: Decodable {
        let title: String?
        let extract: String?
        let contentURLs: ContentURLs?

        enum CodingKeys: String, CodingKey {
            case title, extract
            case contentURLs = "content_urls"
        }

        struct ContentURLs: Decodable {
            let desktop: Desktop?
            struct Desktop: Decodable {
                let page: String?
            }
        }
    }
}
