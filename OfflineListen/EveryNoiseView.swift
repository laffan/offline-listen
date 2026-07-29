import SwiftUI

/// The in-app Every Noise at Once browser (the globe button in Browse): the
/// site's genre map, faithfully — **Map**, **List** and **Scan** modes plus a
/// **Find** field, at both levels. Tapping a genre reveals its constituent
/// artists positioned in rough relation to one another; tapping an artist
/// plays their 30-second top-track preview and offers a **+** that creates a
/// regular Artist source (Top 10 or Discography) back in Browse.
struct EveryNoiseView: View {
    @EnvironmentObject private var playback: PlaybackManager
    @Environment(\.dismiss) private var dismiss

    @StateObject private var store = EveryNoiseStore()
    @StateObject private var player = ENPreviewPlayer()

    @State private var mode: ENBrowseMode = .map
    @State private var query = ""
    /// Programmatic pushes (map taps, find results) drive the stack directly.
    @State private var path: [ENGenre] = []
    /// Where scan left off, so reopening resumes mid-map.
    @AppStorage("everyNoiseScanIndex") private var scanIndex = 0
    @State private var centerRequest: NoiseMapCenter?
    /// Briefly highlights a genre jumped to via Find.
    @State private var flashID: String?

    var body: some View {
        NavigationStack(path: $path) {
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
            .navigationDestination(for: ENGenre.self) { genre in
                ENGenreView(genre: genre)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .environmentObject(store)
        .environmentObject(player)
        .onAppear { store.loadIfNeeded() }
        .onDisappear { player.stop() }
    }

    private var missingData: some View {
        ContentUnavailableViewCompat(
            title: "No Every Noise data",
            systemImage: "globe",
            description: "This build doesn't bundle the Every Noise dataset. Run tools/everynoise/scrape.py once (see its README) and rebuild — the map, every genre's artists and their preview snippets are baked in from then on."
        )
    }

    private var browser: some View {
        VStack(spacing: 0) {
            ENModeBar(mode: $mode, query: $query)
            ZStack(alignment: .top) {
                switch mode {
                case .map, .scan:
                    genreMap
                case .list:
                    ENGenreListView(genres: store.genres, query: query) { genre in
                        path.append(genre)
                    }
                }
                if mode != .list, !query.isEmpty {
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
                path.append(genre)
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
    case map, list, scan
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .map: return "Map"
        case .list: return "List"
        case .scan: return "Scan"
        }
    }
}

/// The mode picker and Find field — the site's header controls.
struct ENModeBar: View {
    @Binding var mode: ENBrowseMode
    @Binding var query: String

    var body: some View {
        VStack(spacing: 8) {
            Picker("Mode", selection: $mode) {
                ForEach(ENBrowseMode.allCases) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .pickerStyle(.segmented)

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
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
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

/// List mode: every genre alphabetically in its map color, with a preview
/// play button per row; tapping the row opens its artists.
struct ENGenreListView: View {
    @EnvironmentObject private var playback: PlaybackManager
    @EnvironmentObject private var player: ENPreviewPlayer

    let genres: [ENGenre]
    let query: String
    let onOpen: (ENGenre) -> Void

    private var shown: [ENGenre] {
        let base = query.isEmpty
            ? genres
            : genres.filter { $0.name.localizedStandardContains(query) }
        return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
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
            }
        }
        .listStyle(.plain)
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

    @EnvironmentObject private var store: EveryNoiseStore
    @EnvironmentObject private var player: ENPreviewPlayer
    @EnvironmentObject private var playback: PlaybackManager

    @State private var artists: [ENArtist]?
    @State private var mode: ENBrowseMode = .map
    @State private var query = ""
    @State private var scanIndex = 0
    @State private var centerRequest: NoiseMapCenter?
    @State private var flashID: String?
    /// The artist the action bar is showing (tapped on map or list).
    @State private var selected: ENArtist?

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
        .task(id: genre.key) {
            artists = await store.artists(for: genre)
        }
        .onDisappear {
            // Popping back to the genre map stops this genre's previews.
            player.stop()
        }
    }

    private func content(_ artists: [ENArtist]) -> some View {
        VStack(spacing: 0) {
            ENModeBar(mode: $mode, query: $query)
            ZStack(alignment: .top) {
                switch mode {
                case .map, .scan:
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
            ENArtistBar(artist: selected, player: player) {
                self.selected = nil
                player.stop()
            }
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

    private func artistList(_ artists: [ENArtist]) -> some View {
        let shown = (query.isEmpty ? artists : artists.filter { $0.name.localizedStandardContains(query) })
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return List(shown) { artist in
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
        }
        .listStyle(.plain)
    }

    /// Tap an artist: the preview starts right away and the action bar (with
    /// the **+**) appears.
    private func select(_ artist: ENArtist) {
        selected = artist
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
    let onClose: () -> Void

    @EnvironmentObject private var playback: PlaybackManager
    @EnvironmentObject private var browse: BrowseStore

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
                Text(artist.preview == nil ? "No preview in the data" : "Top-song preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .confirmationDialog("Follow this artist", isPresented: $choosingMode, titleVisibility: .visible) {
            Button("Top 10") { add(.topTracks) }
            Button("Discography") { add(.discography) }
        } message: {
            Text("Add “\(artist.name)” as a new Artist source in Browse.")
        }
        .onChange(of: artist.id) { _ in added = nil }
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
