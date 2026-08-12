import SwiftUI

/// The in-app Every Noise at Once browser — the Browse tab's own screen: the
/// site's genre map, faithfully — **Map**, **List** and **Scan** modes plus a
/// **Find** field, at both levels. Tapping a genre reveals its constituent
/// artists positioned in rough relation to one another; tapping an artist
/// plays their 30-second top-track preview and offers a **+** that opens
/// their live Spotify discography — or, when Spotify isn't configured, files
/// them into Browse as a regular Artist source (Top 10 or Search Discography).
struct EveryNoiseView: View {
    @EnvironmentObject private var playback: PlaybackManager
    /// Gates the Find field's Spotify target and the scan's "+", both of which
    /// need the live catalogue to say anything.
    @EnvironmentObject private var spotifySettings: SpotifySettingsStore
    /// Carries a row tapped in the home-screen widget, parked until the index
    /// below has loaded and can resolve it.
    @EnvironmentObject private var router: AppRouter
    /// What History (and an artist's page) has put aside — shown by the
    /// bookmark button beside the sources one.
    @EnvironmentObject private var savedForLater: SavedForLaterStore
    /// The maps ignore the bottom safe area, so the mini player's height is
    /// handed to them as extra content inset (UIKit can't see the SwiftUI bar).
    @Environment(\.miniPlayerHeight) private var miniPlayerHeight

    @StateObject private var store = EveryNoiseStore()
    @StateObject private var player = ENPreviewPlayer()

    @State private var mode: ENBrowseMode = .map
    @State private var query = ""
    /// What the root Find field searches: the genre index, or **every artist
    /// in the dataset** via the flat global index (`ENArtistIndex`).
    @State private var findMode: ENFindMode = .genre
    /// Global artist search results, and whether a scan is still in flight.
    @State private var artistHits: [ENArtistHit] = []
    @State private var artistSearching = false
    /// Live Spotify search results (Find ▸ Spotify), and its own in-flight flag.
    @State private var spotifyHits: [SpotifyArtistHit] = []
    @State private var spotifySearching = false
    /// An artist being opened straight into their Spotify discography — a
    /// Spotify search hit, a History row from one, or the artist behind a
    /// genre's example track. Not on the map, so it can't go through
    /// `pushedGenre`.
    @State private var liveArtist: ENLiveArtist?
    /// Set while a genre scan's "+" is resolving its example artist's name
    /// into the id a discography needs.
    @State private var resolvingScanArtist = false
    /// The measured height of whatever bottom bar is up, so the map insets by
    /// it and the Find dropdown stops above it.
    @State private var bottomBarHeight: CGFloat = 0
    /// List mode's order, and the genre a similarity sort is anchored on.
    @State private var listSort: ENListSort = .alphabetical
    @State private var listAnchor: String?
    /// The genre being opened (map taps, list rows) — pushed onto Browse's
    /// own navigation stack, so the tab bar stays put throughout.
    @State private var pushedGenre: ENGenre?
    /// Set alongside `pushedGenre` when a History artist row is opened: the
    /// genre view selects (and centers on) this artist once its shard loads.
    @State private var pushedArtistID: String?
    /// Where scan left off, so reopening resumes mid-map.
    @AppStorage("everyNoiseScanIndex") private var scanIndex = 0
    @State private var centerRequest: NoiseMapCenter?
    /// Briefly highlights a genre jumped to via Find.
    @State private var flashID: String?
    /// Whether the Saved for Later list is up.
    @State private var showingSaved = false

    var body: some View {
        Group {
            switch store.state {
            case .idle, .loading:
                ProgressView("Loading the genre map…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .missing:
                missingData
            case .ready:
                browser
            }
        }
        // No title: this is the Browse tab's own screen, and the map wants every
        // point of height it can get. The mode bar underneath says where you are.
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    showingSaved = true
                } label: {
                    Image(systemName: savedForLater.items.isEmpty ? "bookmark" : "bookmark.fill")
                }
                .accessibilityLabel("Saved for later")

                // A push, not a cover: the sources list lives inside the main
                // nav — tab bar in place — like every other Browse screen. A
                // link rather than a presented destination, since the map
                // already carries two of those for genres and artists.
                NavigationLink {
                    BrowseSourcesView()
                } label: {
                    SourcesButtonLabel()
                }
            }
        }
        .sheet(isPresented: $showingSaved) {
            SavedForLaterView { item in
                // The sheet is on its way out; the push it asked for has to
                // wait for the next runloop turn or it lands under it.
                DispatchQueue.main.async { open(saved: item) }
            }
        }
        .navigationDestination(isPresented: genreIsPushed) {
            if let pushedGenre {
                // Pushed destinations are hosted by Browse's NavigationStack,
                // which sits *outside* this view — so they inherit the app's
                // environment but not objects injected here. Hand the local
                // ones over explicitly or the genre view dies looking for
                // its ENPreviewPlayer.
                ENGenreView(genre: pushedGenre, initialArtistID: pushedArtistID)
                    .environmentObject(store)
                    .environmentObject(player)
            }
        }
        // A second destination for artists that have no place on the map:
        // Spotify search hits, and whoever a genre's example track is by.
        .navigationDestination(isPresented: liveArtistIsPushed) {
            if let liveArtist {
                ENDiscographyView(artistName: liveArtist.name, spotifyID: liveArtist.spotifyID,
                                  exampleTrack: liveArtist.exampleTrack)
            }
        }
        .environmentObject(store)
        .environmentObject(player)
        .onAppear {
            store.loadIfNeeded()
            openPendingBrowse()
        }
        // Three ways a widget's row can arrive: the tab was already up (the
        // target changes), the tab was just switched to (appear), or the tap
        // cold-launched the app and the index is still being read off disk
        // (the genres land).
        .onChange(of: router.pendingBrowse) { _ in openPendingBrowse() }
        .onChange(of: store.genres.count) { _ in openPendingBrowse() }
        .onDisappear { player.stop() }
    }

    /// Opens whatever a widget row asked for — the same three destinations a
    /// History row leads to. Nothing is cleared until it resolves, so a tap
    /// that lands mid-load isn't dropped; an unresolvable one (a dataset
    /// rebuilt without that genre) is, rather than being retried forever.
    private func openPendingBrowse() {
        guard let target = router.pendingBrowse else { return }
        switch target {
        case .spotifyArtist(let id, let name):
            // No place on the map, so nothing to wait for the index over.
            router.pendingBrowse = nil
            present { self.liveArtist = ENLiveArtist(name: name, spotifyID: id) }
        case .genre(let key):
            openMapped(genreKey: key, artistID: nil)
        case .artist(let genreKey, let artistID):
            openMapped(genreKey: genreKey, artistID: artistID)
        }
    }

    /// A genre, or an artist selected on their genre's map. Returns without
    /// consuming the link while the index is still loading.
    private func openMapped(genreKey: String, artistID: String?) {
        switch store.state {
        case .idle, .loading: return  // the index is still being read; try again when it lands
        case .ready, .missing: break
        }
        router.pendingBrowse = nil
        guard let genre = store.genres.first(where: { $0.key == genreKey }) else {
            appLog("Widget asked for genre '\(genreKey)', which isn't in the map.",
                   level: .warning, category: "Widget")
            return
        }
        present {
            if let artistID {
                // Selecting an artist doesn't re-log the visit — their own tap
                // inside the genre does, exactly as a History row behaves.
                self.pushedArtistID = artistID
                self.pushedGenre = genre
            } else {
                self.push(genre)
            }
        }
    }

    /// Runs a push, first clearing any destination already showing.
    /// `navigationDestination(isPresented:)` updates a presented screen in
    /// place rather than rebuilding it, so swapping the value underneath one
    /// leaves the old screen up — tapping a second widget row while the first
    /// one's screen is open would go nowhere.
    private func present(_ open: @escaping () -> Void) {
        guard pushedGenre != nil || liveArtist != nil else { return open() }
        pushedGenre = nil
        pushedArtistID = nil
        liveArtist = nil
        DispatchQueue.main.async(execute: open)
    }

    /// The Find targets this level can actually answer. Spotify's needs
    /// credentials, so without them it isn't offered — and a mode left
    /// selected when they're removed falls back to the genre index.
    private var findModes: [ENFindMode] {
        spotifySettings.isConfigured ? ENFindMode.allCases : [.genre, .artist]
    }

    private var liveArtistIsPushed: Binding<Bool> {
        Binding(get: { liveArtist != nil }, set: { if !$0 { liveArtist = nil } })
    }

    private var genreIsPushed: Binding<Bool> {
        Binding(get: { pushedGenre != nil },
                set: { if !$0 {
                    pushedGenre = nil
                    pushedArtistID = nil
                } })
    }

    /// Opens a genre's artists, logging the visit in History.
    private func push(_ genre: ENGenre) {
        pushedArtistID = nil
        pushedGenre = genre
        store.recordVisit(genre: genre)
    }

    /// A History row: a genre re-opens directly; an artist re-opens their
    /// genre with that artist selected (their own tap re-logs the visit); a
    /// Spotify hit goes back to the discography it came from, since it has no
    /// place on the map to return to.
    private func open(_ entry: ENHistoryEntry) {
        if entry.kind == .spotify {
            if let id = entry.artistID {
                liveArtist = ENLiveArtist(name: entry.name, spotifyID: id)
            }
            return
        }
        guard let genre = store.genres.first(where: { $0.key == entry.genreKey }) else { return }
        if entry.kind == .genre {
            push(genre)
        } else {
            pushedArtistID = entry.artistID
            pushedGenre = genre
        }
    }

    /// A Saved for Later row leads exactly where the History row it was saved
    /// from does — the three destinations differ only in how they're reached.
    private func open(saved item: SavedForLaterItem) {
        present {
            if item.kind == .spotify {
                guard let id = item.artistID else { return }
                self.liveArtist = ENLiveArtist(name: item.name, spotifyID: id)
                return
            }
            guard let genre = self.store.genres.first(where: { $0.key == item.genreKey }) else {
                appLog("Saved genre '\(item.genreKey)' isn't in the map any more.",
                       level: .warning, category: "Browse")
                return
            }
            if item.kind == .genre {
                self.push(genre)
            } else {
                self.pushedArtistID = item.artistID
                self.pushedGenre = genre
            }
        }
    }

    /// Opens a live-catalogue artist and logs the visit, so a Spotify search
    /// leaves the same breadcrumb a map tap does.
    private func openLive(name: String, spotifyID: String, detail: String?,
                          exampleTrack: String? = nil) {
        store.recordVisit(spotifyArtist: name, id: spotifyID, detail: detail)
        liveArtist = ENLiveArtist(name: name, spotifyID: spotifyID, exampleTrack: exampleTrack)
    }

    private var missingData: some View {
        ContentUnavailableViewCompat(
            title: "No Every Noise data",
            systemImage: "globe",
            description: "Run tools/everynoise/scrape.py and rebuild to bundle the genre map."
        )
    }

    private var browser: some View {
        VStack(spacing: 0) {
            ENModeBar(mode: $mode, query: $query, sort: $listSort,
                      findMode: $findMode, findModes: findModes)
            ZStack(alignment: .top) {
                switch mode {
                case .map, .scan:
                    genreMap
                case .list:
                    // Artist and Spotify find work as a dropdown over any mode,
                    // so the genre-scoped list/history filters step aside.
                    ENGenreListView(genres: store.genres, query: findMode == .genre ? query : "",
                                    sort: listSort, anchorKey: $listAnchor) { genre in
                        push(genre)
                    }
                case .history:
                    ENHistoryView(query: findMode == .genre ? query : "") { entry in
                        open(entry)
                    }
                }
                findOverlay
            }
        }
        .everyNoiseBottomBar(height: $bottomBarHeight) {
            if mode == .scan {
                ENScanBar(entries: scanEntries,
                          index: $scanIndex,
                          player: player,
                          unit: "genres",
                          onOpenCurrent: scanOpenAction,
                          isOpening: resolvingScanArtist) { entry in
                    centerRequest = NoiseMapCenter(id: entry.id, token: UUID())
                }
            }
        }
        .onChange(of: mode) { newMode in
            if newMode != .scan { player.stop() }
        }
        // Credentials withdrawn while the Spotify target was selected: fall
        // back rather than leaving a field that can only fail.
        .onChange(of: spotifySettings.isConfigured) { configured in
            if !configured, findMode == .spotify { findMode = .genre }
        }
        // The global artist search: debounced (the scan reads ~470k names),
        // re-run when the query or the Find target changes.
        .task(id: "\(findMode.rawValue)|\(query)") {
            guard findMode == .artist, artistQuery.count >= 2 else {
                artistHits = []
                artistSearching = false
                return
            }
            artistSearching = true
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let hits = await ENArtistIndex.shared.search(artistQuery)
            guard !Task.isCancelled else { return }
            artistHits = hits
            artistSearching = false
        }
        // The live one, debounced harder: every keystroke past the delay is a
        // request against Spotify's search endpoint, where the artist index is
        // a local byte scan.
        .task(id: "spotify|\(findMode.rawValue)|\(query)") {
            guard findMode == .spotify, artistQuery.count >= 2,
                  let client = spotifySettings.client else {
                spotifyHits = []
                spotifySearching = false
                return
            }
            spotifySearching = true
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            let hits = (try? await client.searchArtists(named: artistQuery)) ?? []
            guard !Task.isCancelled else { return }
            spotifyHits = hits
            spotifySearching = false
        }
    }

    private var artistQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The Find dropdown, whichever target is selected.
    ///
    /// It hangs from the top of the map and is capped at whatever room is
    /// left above the bottom bar — a long result set used to run straight
    /// under the scan transport and the mini player, hiding its last rows with
    /// no way to scroll to them.
    @ViewBuilder
    private var findOverlay: some View {
        GeometryReader { geo in
            let room = max(140, geo.size.height - max(miniPlayerHeight, bottomBarHeight) - 24)
            // The reader is here only to measure; handing its width straight
            // back keeps the dropdown laid out exactly as the ZStack had it.
            Group {
                switch findMode {
                case .artist where artistQuery.count >= 2:
                    ENFindResults(entries: artistMatches, searching: artistSearching,
                                  maxHeight: room) { entry in
                        jumpToArtist(entry.id)
                    }
                case .spotify where artistQuery.count >= 2:
                    ENFindResults(entries: spotifyMatches, searching: spotifySearching,
                                  maxHeight: room) { entry in
                        openSpotifyHit(entry.id)
                    }
                case .genre where !query.isEmpty && (mode == .map || mode == .scan):
                    ENFindResults(entries: matches, maxHeight: room) { entry in
                        jump(to: entry)
                    }
                default:
                    EmptyView()
                }
            }
            .frame(width: geo.size.width)
        }
    }

    /// Live Spotify hits as find rows, most popular first, captioned with the
    /// artist's own labels — the nearest thing to the map position they don't
    /// have.
    private var spotifyMatches: [ENFindEntry] {
        spotifyHits
            .sorted { $0.popularity > $1.popularity }
            .map { hit in
                let labels = hit.genres.prefix(3).joined(separator: " · ")
                return ENFindEntry(id: hit.id, label: hit.name,
                                   detail: labels.isEmpty ? nil : labels,
                                   icon: ENFindMode.spotify.icon)
            }
    }

    private func openSpotifyHit(_ id: String) {
        guard let hit = spotifyHits.first(where: { $0.id == id }) else { return }
        query = ""
        spotifyHits = []
        openLive(name: hit.name, spotifyID: hit.id, detail: hit.genres.first)
    }

    /// A genre's preview is one artist's record, and the site names them — so
    /// the scan's "+" at this level opens *that* artist. It needs Spotify to
    /// turn the name into an id, so without credentials there's no button
    /// rather than one that can only fail.
    private var scanOpenAction: ((ENScanEntry) -> Void)? {
        spotifySettings.isConfigured ? openScannedGenre : nil
    }

    /// The scan's "+" at the genre level: the example track's artist, resolved
    /// through Spotify's catalogue because the site only ever named them.
    private func openScannedGenre(_ entry: ENScanEntry) {
        guard !resolvingScanArtist,
              let genre = store.genres.first(where: { $0.key == entry.id }),
              let name = genre.exampleArtist,
              let client = spotifySettings.client else { return }
        resolvingScanArtist = true
        Task {
            defer { resolvingScanArtist = false }
            guard let hit = try? await client.searchArtists(named: name).first else {
                appLog("Couldn't find \"\(name)\" on Spotify — no discography to open.",
                       level: .warning, category: "Browse")
                return
            }
            // The snippet that was playing when the "+" was pressed is the one
            // song we know they liked, so it travels with them.
            openLive(name: hit.name, spotifyID: hit.id, detail: hit.genres.first,
                     exampleTrack: genre.exampleTrack)
        }
    }

    /// Artist hits as find rows, each carrying its home genre as the detail
    /// line (the genre a tap opens, with the artist selected there).
    private var artistMatches: [ENFindEntry] {
        artistHits.map { hit in
            ENFindEntry(id: hit.id, label: hit.name, colorHex: hit.color,
                        detail: store.genres.first(where: { $0.key == hit.genreKey })?.name
                            ?? hit.genreKey)
        }
    }

    /// Opens the hit's home genre with the artist selected, centered and
    /// previewing — the same route a History artist row takes.
    private func jumpToArtist(_ hitID: String) {
        guard let hit = artistHits.first(where: { $0.id == hitID }),
              let genre = store.genres.first(where: { $0.key == hit.genreKey }) else { return }
        query = ""
        artistHits = []
        pushedArtistID = hit.artistID
        pushedGenre = genre
    }

    // MARK: Genre map

    private var genreMap: some View {
        NoiseMapView(mapID: "genres-\(store.genres.count)",
                     items: store.genres.map {
                         NoiseMapItem(id: $0.key, label: $0.name,
                                      x: CGFloat($0.x), y: CGFloat($0.y),
                                      colorHex: $0.color, size: $0.size)
                     },
                     highlightedID: player.currentID ?? flashID,
                     centerRequest: centerRequest,
                     // The scan bar clears the mini player itself, so its
                     // measured height already covers both — hence the larger
                     // of the two rather than their sum.
                     bottomInset: max(miniPlayerHeight, bottomBarHeight)) { key in
            guard let genre = store.genres.first(where: { $0.key == key }) else { return }
            if mode == .scan {
                // Scanning: a tap retunes the scan there instead of leaving.
                if let i = store.genres.firstIndex(of: genre) { scanIndex = i }
            } else {
                push(genre)
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private var matches: [ENFindEntry] {
        let hits = store.genres.filter { $0.name.localizedStandardContains(query) }
        return hits.prefix(25).map { ENFindEntry(id: $0.key, label: $0.name, colorHex: $0.color) }
    }

    private func jump(to entry: ENFindEntry) {
        query = ""
        if mode == .scan, let i = store.genres.firstIndex(where: { $0.key == entry.id }) {
            scanIndex = i
            return
        }
        centerRequest = NoiseMapCenter(id: entry.id, token: UUID())
        flashID = entry.id
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if flashID == entry.id { flashID = nil }
        }
    }

    private var scanEntries: [ENScanEntry] {
        store.genres.map { ENScanEntry(id: $0.key, label: $0.name,
                                       detail: $0.example, preview: $0.preview) }
    }
}

// MARK: - Modes, find bar, list

enum ENBrowseMode: String, CaseIterable, Identifiable {
    case map, list, scan, history
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .map: return "Map"
        case .list: return "List"
        case .scan: return "Scan"
        case .history: return "History"
        }
    }
}

/// How list mode orders its rows. Similarity is the site's own list behavior:
/// map distance *is* the similarity measure, so "sort from here" surfaces an
/// item's sonic neighbors — each row grows a resort button that re-anchors
/// the order on itself. Popularity reads the scraped font-size percent — the
/// site's popularity cue — biggest names first.
enum ENListSort: String, CaseIterable, Identifiable {
    case alphabetical, similarity, popularity
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .alphabetical: return "Alphabetical"
        case .similarity: return "Similarity"
        case .popularity: return "Popularity"
        }
    }
}

/// What the root-level Find field searches: the genre index, or every artist
/// in the dataset (the global index — see `ENArtistIndex`). Toggled by the
/// icons inside the field's trailing edge.
enum ENFindMode: String, CaseIterable, Identifiable {
    case genre, artist
    /// Straight to Spotify's own catalogue, past the frozen dataset entirely.
    /// Offered only with credentials saved, since it's the one Find target
    /// that leaves the device.
    case spotify
    var id: String { rawValue }
    /// The same glyphs the rest of the app uses for the two kinds — and, for
    /// the live search, an over-the-air one: this is the only target that
    /// isn't answered from the bundled data.
    var icon: String {
        switch self {
        case .genre: return "guitars"
        case .artist: return "music.mic"
        case .spotify: return "antenna.radiowaves.left.and.right"
        }
    }
    var placeholder: String {
        switch self {
        case .genre: return "Find Genre"
        case .artist: return "Find Artist"
        case .spotify: return "Search Spotify"
        }
    }
}

/// The mode picker and Find field — the site's header controls. List mode
/// adds the sort menu beside Find; the root level adds the genre/artist
/// toggle inside the field.
struct ENModeBar: View {
    @Binding var mode: ENBrowseMode
    @Binding var query: String
    /// The list sort, shown only in list mode (map/scan don't sort).
    var sort: Binding<ENListSort>? = nil
    /// The root level's genre/artist Find target. Nil (a genre's own page)
    /// keeps the plain genre-scoped field with no toggle.
    var findMode: Binding<ENFindMode>? = nil
    /// Which Find targets the toggle offers. Spotify's is dropped without
    /// credentials — a target that can only fail isn't worth a button.
    var findModes: [ENFindMode] = ENFindMode.allCases
    /// Which modes this level offers.
    var modes: [ENBrowseMode] = ENBrowseMode.allCases

    var body: some View {
        VStack(spacing: 8) {
            Picker("Mode", selection: $mode) {
                ForEach(modes) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(findMode?.wrappedValue.placeholder ?? "Find", text: $query)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let findMode {
                        findModeToggle(findMode)
                    }
                }
                .padding(8)
                .background(Color.appSecondaryBackground, in: RoundedRectangle(cornerRadius: 10))

                if mode == .list, let sort {
                    Menu {
                        Picker("Sort", selection: sort) {
                            ForEach(ENListSort.allCases) { s in
                                Text(s.displayName).tag(s)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .padding(9)
                            .background(Color.appSecondaryBackground, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .accessibilityLabel("Sort order")
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    /// The genre/artist toggle riding inside the field's trailing edge: two
    /// small icons, the active one filled with the accent color.
    private func findModeToggle(_ binding: Binding<ENFindMode>) -> some View {
        HStack(spacing: 4) {
            ForEach(findModes) { target in
                Button {
                    binding.wrappedValue = target
                } label: {
                    Image(systemName: target.icon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(binding.wrappedValue == target ? Color.white : Color.secondary)
                        .frame(width: 28, height: 22)
                        .background(
                            binding.wrappedValue == target ? Color.accentColor : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(target.placeholder)
            }
        }
    }
}

/// Squared map distance — the similarity metric (closer on the map = more
/// alike). Squared is fine for ordering and avoids the sqrt.
func enDistanceSquared(_ ax: Int, _ ay: Int, _ bx: Int, _ by: Int) -> Int {
    let dx = ax - bx
    let dy = ay - by
    return dx * dx + dy * dy
}

/// An artist reached without going through the map — a Spotify search hit, or
/// whoever a genre's example track is by, once their name has been resolved to
/// an id. All a discography needs.
struct ENLiveArtist: Identifiable, Hashable {
    var id: String { spotifyID }
    let name: String
    let spotifyID: String
    /// The song whose snippet was playing when this was opened — a genre
    /// scan's example track. A Spotify search hit has none: nothing played.
    var exampleTrack: String? = nil
}

struct ENFindEntry: Identifiable {
    let id: String
    let label: String
    /// The item's map color. Nil for a hit that has no place on the map — a
    /// Spotify search result — which reads in the ordinary text color instead.
    var colorHex: String? = nil
    /// A caption beneath the label — an artist hit's home genre, or a Spotify
    /// hit's own labels.
    var detail: String? = nil
    /// Leading glyph, for a row whose kind isn't obvious from the map color.
    var icon: String? = nil
}

/// The Find dropdown over the map: tap a match to fly there.
struct ENFindResults: View {
    let entries: [ENFindEntry]
    /// True while a (global artist or Spotify) search is still running, so an
    /// empty list reads as a spinner instead of a premature "No matches".
    var searching: Bool = false
    /// How tall the list may get. The caller works this out from the space it
    /// actually has: the dropdown hangs from the top of the map, and a long
    /// result set used to run straight under the scan bar and the mini player,
    /// hiding its last rows with no way to reach them.
    var maxHeight: CGFloat = 320
    let onPick: (ENFindEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if entries.isEmpty {
                if searching {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(12)
                } else {
                    Text("No matches")
                        .foregroundStyle(.secondary)
                        .padding(12)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            Button {
                                onPick(entry)
                            } label: {
                                HStack {
                                    if let icon = entry.icon {
                                        Image(systemName: icon)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 20)
                                    }
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(entry.label)
                                            .foregroundStyle(entry.colorHex.map { Color(noiseHex: $0) }
                                                             ?? Color.primary)
                                        if let detail = entry.detail {
                                            Text(detail)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.right.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                            }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: maxHeight)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 8, y: 4)
        .padding(.horizontal)
    }
}

// MARK: - Clearing the browser's own bottom bar

/// How tall the Every Noise browser's bottom bar is right now — the scan
/// transport or the artist action bar — measured, published, and read by
/// everything that has to stay clear of it.
///
/// The mini player already does this (`\.miniPlayerHeight`), and for the same
/// reason: the maps ignore the bottom safe area outright, and a `List` inside a
/// `NavigationStack` never picks up a safe-area inset applied outside the
/// stack. Both need the number as an explicit content inset instead. These
/// bars sit *above* the mini player and clear it themselves, so the published
/// height already covers both — which is why the clearance below takes the
/// larger of the two rather than the sum.
private struct ENBottomBarHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var enBottomBarHeight: CGFloat {
        get { self[ENBottomBarHeightKey.self] }
        set { self[ENBottomBarHeightKey.self] = newValue }
    }
}

private struct ENBottomBarHeightPreference: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ENBottomBarModifier<Bar: View>: ViewModifier {
    /// Reported back to the owner as well as published downwards: the map's
    /// inset and the Find dropdown's cap are both built in the *same* view
    /// that attaches the bar, which is above the point the environment value
    /// takes effect and so can't read it.
    @Binding var height: CGFloat
    /// Built by the caller's `@ViewBuilder`; plain here, so forwarding it is a
    /// value pass rather than a second builder transform.
    let bar: () -> Bar

    func body(content: Content) -> some View {
        content
            .environment(\.enBottomBarHeight, height)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bar()
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: ENBottomBarHeightPreference.self,
                                                   value: geo.size.height)
                        }
                    )
            }
            .onPreferenceChange(ENBottomBarHeightPreference.self) { height = $0 }
    }
}

private struct ENBottomClearanceModifier: ViewModifier {
    @Environment(\.miniPlayerHeight) private var miniPlayerHeight
    @Environment(\.enBottomBarHeight) private var barHeight

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: max(miniPlayerHeight, barHeight))
        }
    }
}

extension View {
    /// Attaches the browser's bottom bar and publishes its measured height, so
    /// the map underneath and any list beside it can inset by exactly as much
    /// as it takes up. An absent bar measures 0 and this is a plain no-op.
    func everyNoiseBottomBar<Bar: View>(height: Binding<CGFloat>,
                                        @ViewBuilder _ bar: @escaping () -> Bar) -> some View {
        modifier(ENBottomBarModifier(height: height, bar: bar))
    }

    /// Bottom clearance for a scrollable container inside the browser: the
    /// bottom bar's height, or the mini player's when there's no bar.
    func everyNoiseBottomClearance() -> some View {
        modifier(ENBottomClearanceModifier())
    }
}

/// List mode: every genre in its map color, with a preview play button per
/// row; tapping the row opens its artists. Sorted alphabetically, or — the
/// site's own list behavior — by **similarity**: each row's resort button
/// re-orders the whole list around that genre (it lands on top, its sonic
/// neighbors follow). With no anchor picked yet, similarity shows the map's
/// own top-to-bottom order, which is already a similarity walk.
struct ENGenreListView: View {
    @EnvironmentObject private var playback: PlaybackManager
    @EnvironmentObject private var player: ENPreviewPlayer

    let genres: [ENGenre]
    let query: String
    var sort: ENListSort = .alphabetical
    /// The genre the similarity order is anchored on (its `key`).
    @Binding var anchorKey: String?
    let onOpen: (ENGenre) -> Void

    private var shown: [ENGenre] {
        let base = query.isEmpty
            ? genres
            : genres.filter { $0.name.localizedStandardContains(query) }
        switch sort {
        case .alphabetical:
            return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .similarity:
            guard let anchor = genres.first(where: { $0.key == anchorKey }) else { return base }
            return base.sorted {
                enDistanceSquared($0.x, $0.y, anchor.x, anchor.y)
                    < enDistanceSquared($1.x, $1.y, anchor.x, anchor.y)
            }
        case .popularity:
            return base.sorted {
                $0.size != $1.size
                    ? $0.size > $1.size
                    : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List(shown) { genre in
                HStack(spacing: 12) {
                    Button {
                        if player.currentID == genre.key {
                            player.togglePlayPause()
                        } else if let preview = genre.preview {
                            player.play(preview, id: genre.key, mainPlayback: playback)
                        }
                    } label: {
                        Image(systemName: player.currentID == genre.key && player.isPlaying
                              ? "pause.circle.fill" : "play.circle")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .disabled(genre.preview == nil)
                    .opacity(genre.preview == nil ? 0.3 : 1)

                    Button {
                        onOpen(genre)
                    } label: {
                        HStack {
                            Text(genre.name)
                                .foregroundStyle(Color(noiseHex: genre.color))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if sort == .similarity {
                        Button {
                            anchorKey = genre.key
                        } label: {
                            Image(systemName: genre.key == anchorKey
                                  ? "arrow.up.to.line.circle.fill" : "arrow.up.to.line.circle")
                                .font(.title3)
                                .foregroundStyle(genre.key == anchorKey ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Sort by similarity to \(genre.name)")
                    }
                }
                // The same swipe History has: keep this one to come back to.
                .saveForLaterSwipe(SavedForLaterItem(kind: .genre, genreKey: genre.key,
                                                     name: genre.name, color: genre.color))
            }
            .listStyle(.plain)
            .everyNoiseBottomClearance()
            .onChange(of: anchorKey) { key in
                guard sort == .similarity, let key else { return }
                withAnimation { proxy.scrollTo(key, anchor: .top) }
            }
        }
    }
}

/// History mode: the visit log, newest first — every genre you've opened and
/// every artist you've tapped, distinguished by icon (guitars vs. mic, the
/// same glyphs the Browse source kinds use). Tapping a genre re-opens its
/// artists; tapping an artist re-opens their genre with the artist selected
/// and centered. The Find field filters it; rows swipe to delete.
struct ENHistoryView: View {
    @EnvironmentObject private var store: EveryNoiseStore

    let query: String
    /// Set on a genre's own page: only the artists tapped *in this genre*,
    /// which is the useful question there ("who have I already heard here?").
    /// Nil at the root, where the whole log is the point.
    var genreKey: String? = nil
    let onOpen: (ENHistoryEntry) -> Void

    /// Everything this level's History covers, before the Find filter.
    private var scoped: [ENHistoryEntry] {
        guard let genreKey else { return store.history }
        return store.history.filter { $0.kind == .artist && $0.genreKey == genreKey }
    }

    private var shown: [ENHistoryEntry] {
        query.isEmpty
            ? scoped
            : scoped.filter { $0.name.localizedStandardContains(query) }
    }

    var body: some View {
        if scoped.isEmpty {
            ContentUnavailableViewCompat(
                title: "No history yet",
                systemImage: "clock",
                description: genreKey == nil
                    ? "Genres and artists you open land here."
                    : "Artists you play from this genre land here."
            )
            .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(shown) { entry in
                    Button {
                        onOpen(entry)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: icon(for: entry.kind))
                                .foregroundStyle(.secondary)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                // A Spotify hit has no place on the map and so
                                // no map color to wear.
                                Text(entry.name)
                                    .foregroundStyle(entry.color.isEmpty
                                                     ? Color.primary : Color(noiseHex: entry.color))
                                    .lineLimit(1)
                                if let detail = entry.detail {
                                    // "in <genre>" reads wrong for a Spotify
                                    // hit — its caption is the artist's own
                                    // labels, not somewhere they were found.
                                    Text(entry.kind == .spotify ? detail : "in \(detail)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            Text(entry.date.formatted(.relative(presentation: .named)))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            store.removeHistory(entry)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                    // Swiping the other way keeps it instead of forgetting it:
                    // the row goes to the bookmark button's list, and stays in
                    // History as the log entry it is.
                    .saveForLaterSwipe(entry.savedForLater)
                }

                // Clearing is a whole-log action, so it belongs where the whole
                // log is shown — a genre's page only ever sees its own slice.
                if genreKey == nil {
                    Section {
                        Button(role: .destructive) {
                            store.clearHistory()
                        } label: {
                            Text("Clear History")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .everyNoiseBottomClearance()
        }
    }

    private func icon(for kind: ENVisitKind) -> String {
        switch kind {
        case .genre: return "guitars"
        case .artist: return "music.mic"
        case .spotify: return ENFindMode.spotify.icon
        }
    }
}

// MARK: - Scan

struct ENScanEntry {
    let id: String
    let label: String
    let detail: String?
    let preview: String?
}

/// The scan transport: auto-plays each entry's preview in map order,
/// advancing when one ends (entries with no preview are skipped). The site's
/// "scan" mode, as a bottom bar.
struct ENScanBar: View {
    @EnvironmentObject private var playback: PlaybackManager
    /// The maps this bar sits over ignore the bottom safe area, so the mini
    /// player doesn't push the bar up on its own — it clears it by hand.
    @Environment(\.miniPlayerHeight) private var miniPlayerHeight

    let entries: [ENScanEntry]
    @Binding var index: Int
    @ObservedObject var player: ENPreviewPlayer
    /// "genres" / "artists" — the count caption.
    let unit: String
    /// Given, the bar grows a "+" that leaves the scan for whatever's playing
    /// — the current artist's discography. Nil where there's nothing to open
    /// (a genre scan with no Spotify credentials to resolve its example
    /// artist), so the button is absent rather than dead.
    var onOpenCurrent: ((ENScanEntry) -> Void)? = nil
    /// True while that "+" is still working — a genre's example artist has to
    /// be looked up by name before there's a discography to go to.
    var isOpening: Bool = false
    /// Called on every move so the map can follow the scan.
    let onMove: (ENScanEntry) -> Void

    private var current: ENScanEntry? {
        entries.indices.contains(index) ? entries[index] : nil
    }

    var body: some View {
        VStack(spacing: 6) {
            if let current {
                VStack(spacing: 2) {
                    Text(current.label)
                        .font(.headline)
                        .lineLimit(1)
                    if let detail = current.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            // Small, large, large, small: the "+" sits next to the play/pause
            // and matches its size, so the row stays symmetrical instead of
            // hanging a fourth control off one end.
            HStack(spacing: 28) {
                Button { move(-1) } label: {
                    Image(systemName: "backward.fill")
                }
                Button {
                    if player.currentID == current?.id {
                        player.togglePlayPause()
                    } else {
                        playCurrent()
                    }
                } label: {
                    if player.isLoading {
                        ProgressView().frame(width: 40, height: 40)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 40))
                    }
                }
                // The same "+" a tapped artist gets, so hearing something on
                // the scan and wanting the rest of it doesn't mean stopping,
                // leaving scan mode, and finding them again by hand. It stops
                // the scan on the way out — the discography has its own audio.
                if let onOpenCurrent {
                    Button {
                        guard let current else { return }
                        player.stop()
                        onOpenCurrent(current)
                    } label: {
                        if isOpening {
                            ProgressView().frame(width: 40, height: 40)
                        } else {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 40))
                        }
                    }
                    .disabled(current == nil || isOpening)
                    .accessibilityLabel(current.map { "Open \($0.label)" } ?? "Open this entry")
                }
                Button { move(1) } label: {
                    Image(systemName: "forward.fill")
                }
            }
            // Borderless so the buttons stay independently tappable rather
            // than the row acting as one target.
            .buttonStyle(.borderless)
            Text("\(min(index + 1, entries.count)) of \(entries.count) \(unit)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .padding(.bottom, miniPlayerHeight)
        .onAppear {
            player.onFinished = { move(1) }
            if !entries.indices.contains(index) { index = 0 }
            playCurrent()
        }
        .onDisappear {
            player.onFinished = nil
        }
        .onChange(of: index) { _ in
            playCurrent()
        }
    }

    /// Steps to the nearest entry with a preview in `direction`. Running off
    /// the far end stops the scan; off the near end is a no-op.
    private func move(_ direction: Int) {
        guard !entries.isEmpty else { return }
        var i = index
        while true {
            i += direction
            guard entries.indices.contains(i) else { break }
            if entries[i].preview != nil {
                index = i
                return
            }
        }
        if direction > 0 { player.stop() }
    }

    private func playCurrent() {
        guard let current else { return }
        onMove(current)
        if let preview = current.preview {
            player.play(preview, id: current.id, mainPlayback: playback)
        } else {
            move(1)
        }
    }
}

// MARK: - One genre: its artists, positioned

/// A genre's own page: the constituent artists in rough relation to one
/// another, with the same Map/List/Scan + Find controls. Tapping an artist
/// plays their top-track preview and opens the action bar with the **+**
/// that creates an Artist source in Browse.
struct ENGenreView: View {
    let genre: ENGenre
    /// When set (a History artist row), this artist is selected — action bar,
    /// preview, map centering — as soon as the shard loads.
    var initialArtistID: String? = nil

    @EnvironmentObject private var store: EveryNoiseStore
    @EnvironmentObject private var player: ENPreviewPlayer
    @EnvironmentObject private var playback: PlaybackManager
    /// Opening a genre is what feeds the dataset harvest (opt-in, one request,
    /// heavily throttled — see `ENUpdateStore`). Both of these are app-level
    /// environment objects, so the push inherits them.
    @EnvironmentObject private var updates: ENUpdateStore
    @EnvironmentObject private var spotifySettings: SpotifySettingsStore
    /// The artist map ignores the bottom safe area — the mini player's height
    /// rides in as extra content inset, same as the genre map.
    @Environment(\.miniPlayerHeight) private var miniPlayerHeight

    /// The bundled shard, as unpacked. Nil while it's loading.
    @State private var shardArtists: [ENArtist]?
    @State private var mode: ENBrowseMode = .map
    @State private var query = ""
    /// List mode's order, and the artist a similarity sort is anchored on.
    @State private var listSort: ENListSort = .alphabetical
    @State private var listAnchor: String?
    @State private var scanIndex = 0
    @State private var centerRequest: NoiseMapCenter?
    @State private var flashID: String?
    /// The artist the action bar is showing (tapped on map or list).
    @State private var selected: ENArtist?
    /// The artist whose live Spotify discography is being pushed.
    @State private var discographyArtist: ENArtist?
    /// An artist History (or the scan's "+") asked to land on, applied once
    /// the map is showing — switching modes clears the selection, so the
    /// request has to outlive the switch.
    @State private var pendingSelectID: String?
    /// The measured height of whatever bottom bar is up, so the map insets by
    /// it and the Find dropdown stops above it.
    @State private var bottomBarHeight: CGFloat = 0

    /// What the screen actually draws: the shard plus everything the harvest
    /// has found under this label since the scrape froze. Computed rather than
    /// stored so a harvest that lands while you're looking at the map shows up
    /// on it — `harvestVersion` changes, this view is observing `updates`, and
    /// the merge (memoized in the store) runs again. The alternative was
    /// waiting for someone to rebuild the bundled dataset.
    private var artists: [ENArtist]? {
        shardArtists.map { updates.merged($0, genre: genre) }
    }

    var body: some View {
        Group {
            if let artists {
                if artists.isEmpty {
                    ContentUnavailableViewCompat(
                        title: "No artists in the data",
                        systemImage: "person.3",
                        description: "This genre's page wasn't captured in the bundled scrape."
                    )
                } else {
                    content(artists)
                }
            } else {
                ProgressView("Unpacking \(genre.name)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(genre.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The genre's own example preview, up beside its name.
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    if player.currentID == genre.key {
                        player.togglePlayPause()
                    } else if let preview = genre.preview {
                        player.play(preview, id: genre.key, mainPlayback: playback)
                    }
                } label: {
                    Image(systemName: player.currentID == genre.key && player.isPlaying
                          ? "speaker.wave.2.fill" : "speaker.wave.2")
                }
                .disabled(genre.preview == nil)
                .accessibilityLabel("Play a \(genre.name) example")
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { discographyArtist != nil },
            set: { if !$0 { discographyArtist = nil } }
        )) {
            if let discographyArtist, let spotifyID = discographyArtist.spotify {
                ENDiscographyView(artistName: discographyArtist.name, spotifyID: spotifyID,
                                  exampleTrack: discographyArtist.exampleTrack)
            }
        }
        .task(id: genre.key) {
            let loaded = await store.artists(for: genre)
            shardArtists = loaded
            // Off the view-update path, where publishing the harvest's counts
            // would be a state change mid-render.
            updates.refreshCounts()
            if let initialArtistID,
               let target = (artists ?? loaded).first(where: { $0.id == initialArtistID }) {
                select(target)
                centerRequest = NoiseMapCenter(id: target.id, token: UUID())
            }
            // Ask the live catalogue who it files under this label now, and
            // record whoever the frozen shard is missing. Declines itself
            // when the feature is off, when this genre was harvested
            // recently, or when Spotify is anywhere near a rate limit. It's
            // handed the *merged* list, so artists an earlier harvest already
            // found count as known rather than as fresh discoveries.
            updates.genreOpened(genre, localArtists: artists ?? loaded,
                                genreIndex: store.genres,
                                client: spotifySettings.client)
        }
        .onDisappear {
            // Covered or popped, this genre's previews stop (the discography
            // and the genre map both talk over them otherwise).
            player.stop()
        }
    }

    private func content(_ artists: [ENArtist]) -> some View {
        VStack(spacing: 0) {
            // History belongs at this level too, scoped to the genre: the
            // useful question inside a genre is which of *its* artists you've
            // already heard, and the answer was only ever reachable from the
            // root, mixed in with every other genre you'd opened.
            ENModeBar(mode: $mode, query: $query, sort: $listSort,
                      modes: [.map, .list, .scan, .history])
            ZStack(alignment: .top) {
                switch mode {
                case .map, .scan:
                    artistMap(artists)
                case .list:
                    artistList(artists)
                case .history:
                    ENHistoryView(query: query, genreKey: genre.key) { entry in
                        reopen(entry, in: artists)
                    }
                }
                if mode == .map || mode == .scan, !query.isEmpty {
                    GeometryReader { geo in
                        ENFindResults(entries: matches(artists),
                                      maxHeight: max(140, geo.size.height
                                                     - max(miniPlayerHeight, bottomBarHeight) - 24)) { entry in
                            jump(to: entry, in: artists)
                        }
                        .frame(width: geo.size.width)
                    }
                }
            }
        }
        .everyNoiseBottomBar(height: $bottomBarHeight) {
            bottomBar(artists)
        }
        .onChange(of: mode) { newMode in
            if newMode != .scan { player.stop() }
            // A History row asked for this artist on the map; leaving the
            // selection alone is the whole point of the trip.
            if let pendingSelectID, newMode == .map,
               let artist = artists.first(where: { $0.id == pendingSelectID }) {
                self.pendingSelectID = nil
                select(artist)
                centerRequest = NoiseMapCenter(id: artist.id, token: UUID())
            } else {
                selected = nil
            }
        }
    }

    /// A History row on a genre's own page: go to that artist on the map,
    /// selected and playing, rather than pushing anything.
    private func reopen(_ entry: ENHistoryEntry, in artists: [ENArtist]) {
        guard let id = entry.artistID, artists.contains(where: { $0.id == id }) else { return }
        pendingSelectID = id
        mode = .map
    }

    @ViewBuilder
    private func bottomBar(_ artists: [ENArtist]) -> some View {
        if mode == .scan {
            ENScanBar(entries: artists.map {
                ENScanEntry(id: $0.id, label: $0.name, detail: $0.exampleTrack,
                            preview: $0.preview)
            }, index: $scanIndex, player: player, unit: "artists",
               // Stops the scan on whoever is playing and opens them — their
               // discography with Spotify configured, otherwise the map with
               // their action bar up, which offers the same "+" choices.
               onOpenCurrent: { entry in openScanned(entry, in: artists) }) { entry in
                centerRequest = NoiseMapCenter(id: entry.id, token: UUID())
            }
        } else if let selected {
            ENArtistBar(artist: selected, player: player,
                        bookmark: bookmark(for: selected),
                        onBrowseDiscography: {
                            discographyArtist = selected
                        })
        }
    }

    private func artistMap(_ artists: [ENArtist]) -> some View {
        NoiseMapView(mapID: "genre-\(genre.key)",
                     items: artists.map {
                         NoiseMapItem(id: $0.id, label: $0.name,
                                      x: CGFloat($0.x), y: CGFloat($0.y),
                                      colorHex: $0.color, size: $0.size,
                                      // Harvested rather than scraped: the one
                                      // thing on this map whose position is
                                      // arbitrary, so it's marked as such.
                                      underlined: $0.isHarvested)
                     },
                     // A harvest landing while this genre is open adds rows to
                     // the map it's already drawing; this is what makes them
                     // appear, without throwing away the scroll position.
                     itemsVersion: updates.harvestVersion,
                     highlightedID: player.currentID ?? flashID,
                     centerRequest: centerRequest,
                     // The bars clear the mini player themselves, so the larger
                     // of the two is the whole inset, not their sum.
                     bottomInset: max(miniPlayerHeight, bottomBarHeight)) { id in
            guard let artist = artists.first(where: { $0.id == id }) else { return }
            if mode == .scan {
                if let i = artists.firstIndex(of: artist) { scanIndex = i }
            } else {
                select(artist)
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    /// The artist rows, ordered like the genre list: alphabetical, or by
    /// similarity around the anchored artist (the per-row resort button).
    private func artistList(_ artists: [ENArtist]) -> some View {
        let base = query.isEmpty ? artists : artists.filter { $0.name.localizedStandardContains(query) }
        let shown: [ENArtist]
        switch listSort {
        case .alphabetical:
            shown = base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .similarity:
            if let anchor = artists.first(where: { $0.id == listAnchor }) {
                shown = base.sorted {
                    enDistanceSquared($0.x, $0.y, anchor.x, anchor.y)
                        < enDistanceSquared($1.x, $1.y, anchor.x, anchor.y)
                }
            } else {
                shown = base
            }
        case .popularity:
            shown = base.sorted { a, b in
                // Harvested artists sort last, whatever their size. The frozen
                // page never rated them, so the app is assuming — and the
                // honest assumption for someone the scrape didn't have is
                // "less popular than everyone it did". Among themselves they
                // order by size, which carries Spotify's own score.
                if a.isHarvested != b.isHarvested { return b.isHarvested }
                if a.size != b.size { return a.size > b.size }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
        return ScrollViewReader { proxy in
            List(shown) { artist in
                HStack(spacing: 12) {
                    Button {
                        select(artist)
                    } label: {
                        HStack {
                            // Underlined for a harvested artist, matching the
                            // map — the app found this one, the scrape didn't.
                            Text(artist.name)
                                .underline(artist.isHarvested)
                                .foregroundStyle(Color(noiseHex: artist.color))
                            Spacer()
                            if player.currentID == artist.id && player.isPlaying {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if listSort == .similarity {
                        Button {
                            listAnchor = artist.id
                        } label: {
                            Image(systemName: artist.id == listAnchor
                                  ? "arrow.up.to.line.circle.fill" : "arrow.up.to.line.circle")
                                .font(.title3)
                                .foregroundStyle(artist.id == listAnchor ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Sort by similarity to \(artist.name)")
                    }
                }
                .saveForLaterSwipe(bookmark(for: artist))
            }
            .listStyle(.plain)
            .everyNoiseBottomClearance()
            .onChange(of: listAnchor) { key in
                guard listSort == .similarity, let key else { return }
                withAnimation { proxy.scrollTo(key, anchor: .top) }
            }
        }
    }

    /// The scan's "+": stop on this artist and go where their action bar's own
    /// "+" would go. With Spotify configured that's their discography, in one
    /// step; without it there's no live catalogue to open, so the next best
    /// thing is to put them on the map with the bar up, whose "+" then offers
    /// the Browse-source route instead.
    private func openScanned(_ entry: ENScanEntry, in artists: [ENArtist]) {
        guard let artist = artists.first(where: { $0.id == entry.id }) else { return }
        if artist.spotify != nil, spotifySettings.isConfigured {
            discographyArtist = artist
        } else {
            pendingSelectID = artist.id
            mode = .map
        }
    }

    /// An artist of this genre as something to save — the same row History
    /// would file, so a saved artist re-opens here with them selected.
    private func bookmark(for artist: ENArtist) -> SavedForLaterItem {
        SavedForLaterItem(kind: .artist, genreKey: genre.key, artistID: artist.id,
                          name: artist.name, color: artist.color, detail: genre.name)
    }

    /// Tap an artist: the preview starts right away, the action bar (with
    /// the **+**) appears, and the visit lands in History.
    private func select(_ artist: ENArtist) {
        selected = artist
        store.recordVisit(artist: artist, in: genre)
        if let preview = artist.preview {
            player.play(preview, id: artist.id, mainPlayback: playback)
        } else {
            player.stop()
        }
    }

    private func matches(_ artists: [ENArtist]) -> [ENFindEntry] {
        let hits = artists.filter { $0.name.localizedStandardContains(query) }
        return hits.prefix(25).map { ENFindEntry(id: $0.id, label: $0.name, colorHex: $0.color) }
    }

    private func jump(to entry: ENFindEntry, in artists: [ENArtist]) {
        query = ""
        if mode == .scan, let i = artists.firstIndex(where: { $0.id == entry.id }) {
            scanIndex = i
            return
        }
        centerRequest = NoiseMapCenter(id: entry.id, token: UUID())
        flashID = entry.id
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if flashID == entry.id { flashID = nil }
        }
    }
}

/// The tapped artist's bar: name + example track, play/pause for the preview
/// snippet, a **bookmark** that keeps them for later, and the **+** that files
/// them into Browse as an Artist source — Top 10 or Discography, the same two
/// depths the rest of the app offers.
struct ENArtistBar: View {
    let artist: ENArtist
    @ObservedObject var player: ENPreviewPlayer
    /// This artist as a saved row, built by the genre view (which knows the
    /// genre they belong to).
    let bookmark: SavedForLaterItem
    /// Pushes the live-from-Spotify discography (offered when credentials are
    /// saved — the scraped dataset itself carries no discographies).
    var onBrowseDiscography: (() -> Void)? = nil

    @EnvironmentObject private var playback: PlaybackManager
    @EnvironmentObject private var browse: BrowseStore
    @EnvironmentObject private var spotifySettings: SpotifySettingsStore
    @EnvironmentObject private var savedForLater: SavedForLaterStore
    /// The artist map underneath ignores the bottom safe area, so the mini
    /// player doesn't push this bar up on its own — it clears it by hand.
    @Environment(\.miniPlayerHeight) private var miniPlayerHeight

    @State private var choosingMode = false
    @State private var added: ArtistSourceMode?

    var body: some View {
        HStack(spacing: 14) {
            Button {
                if player.currentID == artist.id {
                    player.togglePlayPause()
                } else if let preview = artist.preview {
                    player.play(preview, id: artist.id, mainPlayback: playback)
                }
            } label: {
                if player.isLoading && player.currentID == artist.id {
                    ProgressView()
                        .frame(width: 36, height: 36)
                } else {
                    Image(systemName: player.currentID == artist.id && player.isPlaying
                          ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 36))
                }
            }
            .disabled(artist.preview == nil)
            .opacity(artist.preview == nil ? 0.3 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(artist.name)
                    .font(.headline)
                    .lineLimit(1)
                if artist.preview == nil {
                    Text("No preview available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let track = artist.exampleTrack {
                    // What the snippet actually is, the way Scan names it.
                    // Blank on a dataset scraped before the field was kept.
                    Text(track)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let added {
                Label(added == .topTracks ? "Top 10 added" : "Discography added",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                Button {
                    // With Spotify configured, skip the popup entirely: the
                    // "+" goes straight to the artist's real discography (its
                    // pinned "Search Top 10" row covers the popup's Top 10).
                    // The Top 10 / Search Discography chooser remains the
                    // fallback when the live catalogue isn't reachable.
                    if offersLiveDiscography, let onBrowseDiscography {
                        onBrowseDiscography()
                    } else {
                        choosingMode = true
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 30))
                }
                .accessibilityLabel(offersLiveDiscography
                                    ? "Browse \(artist.name)'s discography"
                                    : "Follow \(artist.name) in Browse")
            }

            // Where the bar's close button used to be. Dismissing it was the
            // least useful thing you could do to an artist you'd just tapped —
            // another tap on the map replaces the selection anyway, and
            // leaving the mode clears it — so the slot goes to the one action
            // that keeps them: onto the Saved for Later list, without leaving
            // the map or interrupting the snippet.
            //
            // A switch, not a one-way door: it fills in when they're on the
            // list and empties when tapped again. The bare bookmark shape (no
            // circle around it) at a size that balances the "+" beside it, in
            // the same accent, since the two are the same kind of thing.
            let saved = savedForLater.contains(bookmark)
            Button {
                savedForLater.toggle(bookmark)
            } label: {
                Image(systemName: saved ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 26))
            }
            .accessibilityLabel(saved ? "Remove \(artist.name) from Saved for Later"
                                      : "Save \(artist.name) for later")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .padding(.bottom, miniPlayerHeight)
        .confirmationDialog("", isPresented: $choosingMode) {
            Button(ArtistSourceMode.topTracks.displayName) { add(.topTracks) }
            Button(ArtistSourceMode.discography.displayName) { add(.discography) }
        }
        .onChange(of: artist.id) { _ in added = nil }
    }

    private var offersLiveDiscography: Bool {
        spotifySettings.isConfigured && artist.spotify != nil && onBrowseDiscography != nil
    }

    /// Mirrors the Blog Agent's tap-an-artist flow: create the source and
    /// kick off its first refresh so it lands populated. The confirmation
    /// badge steps aside after a beat so the *other* depth stays addable.
    private func add(_ mode: ArtistSourceMode) {
        let source = browse.addSource(kind: .artist, name: artist.name,
                                      input: artist.name, artistMode: mode)
        Task { await browse.refresh(source) }
        added = mode
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if added == mode { added = nil }
        }
    }
}

// MARK: - Live discography (Spotify)

/// The tapped artist's *real* discography — the shared `DiscographyBrowserView`
/// with a Spotify provider (the scraped dataset carries each artist's Spotify
/// id but no catalogue, so this needs the Settings ▸ Spotify credentials).
/// Pushed inside the main nav like everything else. Releases group into a
/// pinned **Top 10** (with its "Search Top 10" button), then Albums /
/// Singles & EPs / Compilations; expanding a release lists its track names and
/// its **search** button matches them against YouTube in place. Downloads are
/// single-track picks, so they file **unfiled** (visible in the Library's
/// Tracks list and the Inbox both), not into an album folder.
struct ENDiscographyView: View {
    let artistName: String
    let spotifyID: String
    /// The song the 30-second preview played, when we came from a row that
    /// named one — it gets its own line above the catalogue.
    var exampleTrack: String? = nil

    @EnvironmentObject private var spotifySettings: SpotifySettingsStore
    @EnvironmentObject private var aiSettings: AISettingsStore
    @EnvironmentObject private var browse: BrowseStore
    @EnvironmentObject private var savedForLater: SavedForLaterStore

    /// This artist as a bookmark: a Spotify-kind row, exactly like one saved
    /// from a Find ▸ Spotify visit, so it re-opens this same page.
    private var bookmark: SavedForLaterItem {
        SavedForLaterItem(kind: .spotify, genreKey: "", artistID: spotifyID, name: artistName)
    }

    var body: some View {
        if let client = spotifySettings.client {
            DiscographyBrowserView(
                title: artistName,
                provider: SpotifyDiscographyProvider(client: client,
                                                     artistName: artistName,
                                                     artistID: spotifyID,
                                                     aiSettings: aiSettings),
                // "Add as Source" files this artist into Browse as a
                // discography-mode Artist source (the same catalogue,
                // persistently followed from the Browse tab).
                addSource: DiscographyAddSource(
                    isAdded: {
                        browse.sources.contains {
                            $0.kind == .artist
                                && $0.artistSourceMode == .spotifyDiscography
                                && $0.input.caseInsensitiveCompare(artistName) == .orderedSame
                        }
                    },
                    add: {
                        browse.addSource(kind: .artist, name: artistName,
                                         input: artistName,
                                         artistMode: .spotifyDiscography)
                    }),
                saveForLater: DiscographySaveForLater(
                    isSaved: { savedForLater.contains(bookmark) },
                    toggle: { savedForLater.toggle(bookmark) }),
                exampleTrack: exampleTrack)
        } else {
            ContentUnavailableViewCompat(
                title: "Couldn't load the discography",
                systemImage: "exclamationmark.triangle",
                description: "Add Spotify credentials in Settings ▸ Spotify first."
            )
            .navigationTitle(artistName)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
