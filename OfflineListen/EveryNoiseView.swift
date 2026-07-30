import SwiftUI

/// The in-app Every Noise at Once browser (the globe button in Browse): the
/// site's genre map, faithfully — **Map**, **List** and **Scan** modes plus a
/// **Find** field, at both levels. Tapping a genre reveals its constituent
/// artists positioned in rough relation to one another; tapping an artist
/// plays their 30-second top-track preview and offers a **+** that creates a
/// regular Artist source (Top 10 or Discography) back in Browse.
struct EveryNoiseView: View {
    @EnvironmentObject private var playback: PlaybackManager

    @StateObject private var store = EveryNoiseStore()
    @StateObject private var player = ENPreviewPlayer()

    @State private var mode: ENBrowseMode = .map
    @State private var query = ""
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
        .navigationTitle("Every Noise")
        .navigationBarTitleDisplayMode(.inline)
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
        .environmentObject(store)
        .environmentObject(player)
        .onAppear { store.loadIfNeeded() }
        .onDisappear { player.stop() }
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
    /// genre with that artist selected (their own tap re-logs the visit).
    private func open(_ entry: ENHistoryEntry) {
        guard let genre = store.genres.first(where: { $0.key == entry.genreKey }) else { return }
        if entry.kind == .genre {
            push(genre)
        } else {
            pushedArtistID = entry.artistID
            pushedGenre = genre
        }
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
            ENModeBar(mode: $mode, query: $query, sort: $listSort)
            ZStack(alignment: .top) {
                switch mode {
                case .map, .scan:
                    genreMap
                case .list:
                    ENGenreListView(genres: store.genres, query: query,
                                    sort: listSort, anchorKey: $listAnchor) { genre in
                        push(genre)
                    }
                case .history:
                    ENHistoryView(query: query) { entry in
                        open(entry)
                    }
                }
                if mode == .map || mode == .scan, !query.isEmpty {
                    ENFindResults(entries: matches) { entry in
                        jump(to: entry)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if mode == .scan {
                ENScanBar(entries: scanEntries,
                          index: $scanIndex,
                          player: player,
                          unit: "genres") { entry in
                    centerRequest = NoiseMapCenter(id: entry.id, token: UUID())
                }
            }
        }
        .onChange(of: mode) { newMode in
            if newMode != .scan { player.stop() }
        }
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
                     centerRequest: centerRequest) { key in
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
/// the order on itself.
enum ENListSort: String, CaseIterable, Identifiable {
    case alphabetical, similarity
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .alphabetical: return "Alphabetical"
        case .similarity: return "Similarity"
        }
    }
}

/// The mode picker and Find field — the site's header controls. List mode
/// adds the sort menu beside Find.
struct ENModeBar: View {
    @Binding var mode: ENBrowseMode
    @Binding var query: String
    /// The list sort, shown only in list mode (map/scan don't sort).
    var sort: Binding<ENListSort>? = nil
    /// Which modes this level offers (History exists at the root only).
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
                    TextField("Find", text: $query)
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
                }
                .padding(8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))

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
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .accessibilityLabel("Sort order")
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

/// Squared map distance — the similarity metric (closer on the map = more
/// alike). Squared is fine for ordering and avoids the sqrt.
func enDistanceSquared(_ ax: Int, _ ay: Int, _ bx: Int, _ by: Int) -> Int {
    let dx = ax - bx
    let dy = ay - by
    return dx * dx + dy * dy
}

struct ENFindEntry: Identifiable {
    let id: String
    let label: String
    let colorHex: String
}

/// The Find dropdown over the map: tap a match to fly there.
struct ENFindResults: View {
    let entries: [ENFindEntry]
    let onPick: (ENFindEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if entries.isEmpty {
                Text("No matches")
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            Button {
                                onPick(entry)
                            } label: {
                                HStack {
                                    Text(entry.label)
                                        .foregroundStyle(Color(UIColor(noiseHex: entry.colorHex)))
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
                .frame(maxHeight: 320)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 8, y: 4)
        .padding(.horizontal)
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
                                .foregroundStyle(Color(UIColor(noiseHex: genre.color)))
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
            }
            .listStyle(.plain)
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
    let onOpen: (ENHistoryEntry) -> Void

    private var shown: [ENHistoryEntry] {
        query.isEmpty
            ? store.history
            : store.history.filter { $0.name.localizedStandardContains(query) }
    }

    var body: some View {
        if store.history.isEmpty {
            ContentUnavailableViewCompat(
                title: "No history yet",
                systemImage: "clock",
                description: "Genres and artists you open land here."
            )
            .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(shown) { entry in
                    Button {
                        onOpen(entry)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: entry.kind == .genre ? "guitars" : "music.mic")
                                .foregroundStyle(.secondary)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                    .foregroundStyle(Color(UIColor(noiseHex: entry.color)))
                                    .lineLimit(1)
                                if let detail = entry.detail {
                                    Text("in \(detail)")
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
                }

                Section {
                    Button(role: .destructive) {
                        store.clearHistory()
                    } label: {
                        Text("Clear History")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .listStyle(.plain)
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

    let entries: [ENScanEntry]
    @Binding var index: Int
    @ObservedObject var player: ENPreviewPlayer
    /// "genres" / "artists" — the count caption.
    let unit: String
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
            HStack(spacing: 40) {
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
                        ProgressView()
                    } else {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 40))
                    }
                }
                Button { move(1) } label: {
                    Image(systemName: "forward.fill")
                }
            }
            Text("\(min(index + 1, entries.count)) of \(entries.count) \(unit)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
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

    @State private var artists: [ENArtist]?
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
                ENDiscographyView(artistName: discographyArtist.name, spotifyID: spotifyID)
            }
        }
        .task(id: genre.key) {
            let loaded = await store.artists(for: genre)
            artists = loaded
            if let initialArtistID,
               let target = loaded.first(where: { $0.id == initialArtistID }) {
                select(target)
                centerRequest = NoiseMapCenter(id: target.id, token: UUID())
            }
        }
        .onDisappear {
            // Covered or popped, this genre's previews stop (the discography
            // and the genre map both talk over them otherwise).
            player.stop()
        }
    }

    private func content(_ artists: [ENArtist]) -> some View {
        VStack(spacing: 0) {
            ENModeBar(mode: $mode, query: $query, sort: $listSort,
                      modes: [.map, .list, .scan])
            ZStack(alignment: .top) {
                switch mode {
                case .map, .scan, .history:
                    artistMap(artists)
                case .list:
                    artistList(artists)
                }
                if mode != .list, !query.isEmpty {
                    ENFindResults(entries: matches(artists)) { entry in
                        jump(to: entry, in: artists)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomBar(artists)
        }
        .onChange(of: mode) { newMode in
            if newMode != .scan { player.stop() }
            selected = nil
        }
    }

    @ViewBuilder
    private func bottomBar(_ artists: [ENArtist]) -> some View {
        if mode == .scan {
            ENScanBar(entries: artists.map {
                ENScanEntry(id: $0.id, label: $0.name, detail: nil, preview: $0.preview)
            }, index: $scanIndex, player: player, unit: "artists") { entry in
                centerRequest = NoiseMapCenter(id: entry.id, token: UUID())
            }
        } else if let selected {
            ENArtistBar(artist: selected, player: player,
                        onBrowseDiscography: {
                            discographyArtist = selected
                        },
                        onClose: {
                            self.selected = nil
                            player.stop()
                        })
        }
    }

    private func artistMap(_ artists: [ENArtist]) -> some View {
        NoiseMapView(mapID: "genre-\(genre.key)",
                     items: artists.map {
                         NoiseMapItem(id: $0.id, label: $0.name,
                                      x: CGFloat($0.x), y: CGFloat($0.y),
                                      colorHex: $0.color, size: $0.size)
                     },
                     highlightedID: player.currentID ?? flashID,
                     centerRequest: centerRequest) { id in
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
        }
        return ScrollViewReader { proxy in
            List(shown) { artist in
                HStack(spacing: 12) {
                    Button {
                        select(artist)
                    } label: {
                        HStack {
                            Text(artist.name)
                                .foregroundStyle(Color(UIColor(noiseHex: artist.color)))
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
            }
            .listStyle(.plain)
            .onChange(of: listAnchor) { key in
                guard listSort == .similarity, let key else { return }
                withAnimation { proxy.scrollTo(key, anchor: .top) }
            }
        }
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
/// snippet, and the **+** that files them into Browse as an Artist source —
/// Top 10 or Discography, the same two depths the rest of the app offers.
struct ENArtistBar: View {
    let artist: ENArtist
    @ObservedObject var player: ENPreviewPlayer
    /// Pushes the live-from-Spotify discography (offered when credentials are
    /// saved — the scraped dataset itself carries no discographies).
    var onBrowseDiscography: (() -> Void)? = nil
    let onClose: () -> Void

    @EnvironmentObject private var playback: PlaybackManager
    @EnvironmentObject private var browse: BrowseStore
    @EnvironmentObject private var spotifySettings: SpotifySettingsStore

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
                    choosingMode = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 30))
                }
                .accessibilityLabel("Follow \(artist.name) in Browse")
            }

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .confirmationDialog("", isPresented: $choosingMode) {
            Button("Top 10") { add(.topTracks) }
            Button("Discography") { add(.discography) }
            if offersLiveDiscography, let onBrowseDiscography {
                Button("Browse Discography") { onBrowseDiscography() }
            }
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

/// The tapped artist's *real* discography, read live from Spotify — the
/// scraped dataset carries each artist's Spotify id but no catalogue, so this
/// needs the Settings ▸ Spotify credentials. Pushed inside the main nav like
/// everything else. Releases group into Albums / Singles & EPs / Compilations,
/// newest first; expanding one lists its tracks, and each release's **search**
/// button matches its tracks against YouTube in place — matched tracks light
/// up with Download/Preview beside them, no picker popup. Downloads are
/// single-track picks, so they file **unfiled** (visible in the Library's
/// Tracks list and the Inbox both), not into an album folder.
struct ENDiscographyView: View {
    let artistName: String
    let spotifyID: String

    @EnvironmentObject private var spotifySettings: SpotifySettingsStore
    @EnvironmentObject private var browse: BrowseStore

    @State private var albums: [SpotifyAlbumSummary]?
    @State private var loadError: String?
    /// The track being auditioned — the same preview modal Browse rows use.
    @State private var previewItem: BrowseItem?

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableViewCompat(
                    title: "Couldn't load the discography",
                    systemImage: "exclamationmark.triangle",
                    description: loadError
                )
            } else if let albums {
                if albums.isEmpty {
                    ContentUnavailableViewCompat(
                        title: "Nothing listed",
                        systemImage: "opticaldisc",
                        description: "Spotify lists no releases for this artist."
                    )
                } else {
                    releaseList(albums)
                }
            } else {
                ProgressView("Reading the catalogue…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(artistName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $previewItem) { item in
            BrowsePreviewView(item: item, mode: browse.downloadMode)
        }
        .task {
            guard let client = spotifySettings.client else {
                loadError = "Add Spotify credentials in Settings ▸ Spotify first."
                return
            }
            do {
                albums = try await client.artistAlbums(id: spotifyID)
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private func releaseList(_ albums: [SpotifyAlbumSummary]) -> some View {
        List {
            releaseSection("Albums", albums.filter { $0.group == "album" })
            releaseSection("Singles & EPs", albums.filter { $0.group == "single" })
            releaseSection("Compilations", albums.filter { $0.group == "compilation" })
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func releaseSection(_ title: String, _ items: [SpotifyAlbumSummary]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items.sorted { $0.releaseDate > $1.releaseDate }) { album in
                    ENAlbumRow(album: album) { item in
                        previewItem = item
                    }
                }
            }
        }
    }
}

/// One release row: name, year and track count, plus a **search** button that
/// matches the tracklist against YouTube. Expanding shows the tracks; after a
/// search, matched tracks are highlighted with Download/Preview beside them
/// and misses are dimmed. Searching shows live progress in the row.
private struct ENAlbumRow: View {
    let album: SpotifyAlbumSummary
    let onPreview: (BrowseItem) -> Void

    @EnvironmentObject private var spotifySettings: SpotifySettingsStore
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var browse: BrowseStore

    @State private var expanded = false
    @State private var tracks: [SpotifyTrack]?
    @State private var trackError: String?
    @State private var searching = false
    @State private var searched = false
    @State private var progress = (done: 0, total: 0)
    /// track id → matched YouTube watch URL (absent = no match once searched).
    @State private var matches: [String: String] = [:]
    /// Tracks already sent to the download queue from this row.
    @State private var sent: Set<String> = []

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            trackRows
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.name)
                        .lineLimit(2)
                    Text(detailLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if searching {
                    ProgressView()
                } else if searched {
                    Image(systemName: "magnifyingglass.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                } else {
                    Button {
                        search()
                    } label: {
                        Image(systemName: "magnifyingglass.circle")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Find \(album.name)'s tracks on YouTube")
                }
            }
        }
        .onChange(of: expanded) { open in
            guard open, tracks == nil, trackError == nil else { return }
            Task { await loadTracks() }
        }
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

    private func trackRow(number: Int, track: SpotifyTrack) -> some View {
        HStack(spacing: 10) {
            Text("\(number).  \(track.name)")
                .font(.callout)
                .fontWeight(matches[track.id] != nil ? .medium : .regular)
                .foregroundStyle(trackStyle(track))
                .lineLimit(2)
            Spacer(minLength: 8)
            if let url = matches[track.id] {
                if sent.contains(track.id) {
                    // Becomes a green play button the moment the download lands
                    // in the library — plays in the background, list intact.
                    BrowseTrackStatusButton(sourceURL: url,
                                            pendingIcon: "checkmark.circle.fill",
                                            pendingLabel: "Sent to Downloads")
                } else {
                    Button {
                        // A single-track pick, so no album folder: it lands in
                        // the Library's root Tracks list (and the Inbox).
                        downloads.enqueue(urlString: url, mode: browse.downloadMode)
                        sent.insert(track.id)
                    } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Download \(track.name)")
                }
                Button {
                    onPreview(browseItem(for: track, url: url))
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

    private func trackStyle(_ track: SpotifyTrack) -> HierarchicalShapeStyle {
        if matches[track.id] != nil { return .primary }
        return searched ? .tertiary : .secondary
    }

    /// Fetches the tracklist (also triggered by plain expansion, so the
    /// search never runs against a missing list). Main-actor: these methods
    /// write `@State`, and a Task spawned in a nonisolated context wouldn't
    /// come back to the main thread on its own.
    @MainActor
    private func loadTracks() async {
        guard let client = spotifySettings.client else {
            trackError = "Add Spotify credentials in Settings ▸ Spotify first."
            return
        }
        do {
            tracks = try await client.album(id: album.id).tracks
        } catch {
            trackError = error.localizedDescription
        }
    }

    /// The search: resolve each track to a YouTube video (ISRC first, then
    /// title, duration-gated — `SpotifyResolver`, same as a pasted album),
    /// updating the rows as each match lands.
    @MainActor
    private func search() {
        expanded = true
        searching = true
        Task {
            if tracks == nil { await loadTracks() }
            guard let tracks, !tracks.isEmpty else {
                searching = false
                searched = tracks != nil
                return
            }
            progress = (0, tracks.count)
            for (index, track) in tracks.enumerated() {
                if let url = await SpotifyResolver.youTubeURL(for: track) {
                    matches[track.id] = url
                }
                progress = (index + 1, tracks.count)
            }
            searching = false
            searched = true
        }
    }

    /// Wraps a matched track as a Browse item so the standard preview modal
    /// can audition it. The item is ephemeral (its id lives in no store), and
    /// every store call the modal makes is an id lookup, so nothing sticks.
    private func browseItem(for track: SpotifyTrack, url: String) -> BrowseItem {
        BrowseItem(sourceID: UUID(),
                   title: track.primaryArtist.isEmpty ? track.name : "\(track.primaryArtist) — \(track.name)",
                   detail: album.name,
                   url: url,
                   videoID: URLComponents(string: url)?.queryItems?.first(where: { $0.name == "v" })?.value)
    }

    private var detailLine: String {
        var parts: [String] = []
        if !album.year.isEmpty { parts.append(album.year) }
        if album.totalTracks > 0 { parts.append("\(album.totalTracks) track\(album.totalTracks == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}
