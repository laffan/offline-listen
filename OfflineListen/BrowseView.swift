import SwiftUI

/// The Search tab's sections, in the order their buttons sit across its top.
enum SearchSection: String, CaseIterable, Identifiable {
    /// The Every Noise genre map.
    case browse
    /// The link field and the download queue.
    case download
    /// The channels, feeds and AI lists you keep tabs on.
    case sources
    /// Saved for Later.
    case bookmarks

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .browse: return "Browse"
        case .download: return "Download"
        case .sources: return "Sources"
        case .bookmarks: return "Bookmarks"
        }
    }

    var systemImage: String {
        switch self {
        case .browse: return "safari"
        case .download: return "arrow.down.circle"
        case .sources: return "rectangle.stack"
        case .bookmarks: return "bookmark"
        }
    }
}

/// The Search tab: everything for finding something to listen to, behind four
/// buttons across the top — **Browse** (the Every Noise map), **Download**
/// (paste a link or search YouTube, and the queue), **Sources** and
/// **Bookmarks**. It used to be two tabs, Browse and Download, with the sources
/// and the bookmarks behind buttons in Browse's corner; the buttons that were
/// a level down are the tab's own organization now.
///
/// The sections are **kept alive** behind the one showing rather than built
/// anew on each switch: the map takes a moment to read off disk and remembers
/// where you were on it, the Download field may be holding a half-pasted link,
/// and a source list keeps its scroll. Only the showing one takes touches or
/// reaches VoiceOver.
struct SearchView: View {
    @EnvironmentObject private var router: AppRouter

    /// Switches to the player tab after a finished download is tapped.
    let onPlay: () -> Void

    @State private var section: SearchSection = .browse

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SearchSectionBar(selection: $section)
                ZStack {
                    ForEach(SearchSection.allCases) { candidate in
                        let showing = candidate == section
                        page(candidate)
                            .opacity(showing ? 1 : 0)
                            .allowsHitTesting(showing)
                            .accessibilityHidden(!showing)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // Never shown — the section buttons stand where the bar would —
            // but it's what a pushed screen's back button reads.
            .navigationTitle(section.displayName)
            .navigationBarTitleDisplayMode(.inline)
            #if !os(macOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
        .onAppear { openPending() }
        .onChange(of: section) { router.searchSection = $0 }
        .onChange(of: router.pendingSearchSection) { _ in openPending() }
        .onChange(of: router.pendingBrowse) { _ in openPending() }
    }

    @ViewBuilder
    private func page(_ candidate: SearchSection) -> some View {
        switch candidate {
        case .browse:
            EveryNoiseView(isActive: section == .browse)
        case .download:
            DownloadView(onPlay: onPlay, isActive: section == .download)
        case .sources:
            BrowseSourcesView()
        case .bookmarks:
            SavedForLaterView(onOpen: { open($0) })
        }
    }

    /// Goes where the router asks: back to the section a playing track was
    /// started in (the Player's swipe-down), or to Browse for a widget row or
    /// a bookmark, which the map then opens itself.
    private func openPending() {
        if router.pendingBrowse != nil {
            section = .browse
        }
        if let pending = router.pendingSearchSection {
            router.pendingSearchSection = nil
            section = pending
        }
    }

    /// A bookmark opens in Browse, the way a widget row does — the same three
    /// destinations, and the same wait for the genre index if the map hasn't
    /// been read off disk yet.
    private func open(_ item: SavedForLaterItem) {
        let target: WidgetDeepLink.BrowseTarget
        switch item.kind {
        case .genre:
            target = .genre(key: item.genreKey)
        case .artist:
            guard let id = item.artistID else { return }
            target = .artist(genreKey: item.genreKey, artistID: id)
        case .spotify:
            guard let id = item.artistID else { return }
            target = .spotifyArtist(id: id, name: item.name)
        }
        section = .browse
        router.pendingBrowse = target
    }
}

/// The Search tab's four buttons, where a navigation bar would be: glyph over
/// name, the one showing in the accent colour. Two of them carry news from the
/// section behind them — **Download** the number of downloads still working or
/// waiting (the tab's own badge says the same from elsewhere in the app), and
/// **Sources** a dot when a refresh has turned up items nobody has acted on.
///
/// It observes the queue and the sources on its own so that a refresh or a
/// download starting redraws *this* and not the genre map behind it.
private struct SearchSectionBar: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var browse: BrowseStore
    @Binding var selection: SearchSection

    private var pendingDownloads: Int {
        downloads.jobs.filter { $0.state.isActive || $0.state == .queued }.count
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SearchSection.allCases) { candidate in
                button(candidate)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    private func button(_ candidate: SearchSection) -> some View {
        let selected = candidate == selection
        return Button {
            selection = candidate
        } label: {
            VStack(spacing: 3) {
                Image(systemName: candidate.systemImage)
                    .font(.body.weight(.semibold))
                    .overlay(alignment: .topTrailing) { marker(for: candidate) }
                Text(candidate.displayName)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: candidate))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func marker(for candidate: SearchSection) -> some View {
        switch candidate {
        case .download where pendingDownloads > 0:
            Text("\(pendingDownloads)")
                .font(.system(size: 10, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(minWidth: 15, minHeight: 15)
                .background(Color.red, in: Capsule())
                .offset(x: 10, y: -6)
        case .sources where browse.totalNewCount > 0:
            // The same tint the per-source count badges wear.
            Circle()
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)
                .offset(x: 5, y: -3)
        default:
            EmptyView()
        }
    }

    private func accessibilityLabel(for candidate: SearchSection) -> String {
        switch candidate {
        case .download where pendingDownloads > 0:
            return "Download — \(pendingDownloads) in progress"
        case .sources where browse.totalNewCount > 0:
            return "Sources — \(browse.totalNewCount) new"
        default:
            return candidate.displayName
        }
    }
}

/// The sources screen: what each source has surfaced, ready to curate —
/// download, preview, save or discard. The Search tab's **Sources** section.
struct BrowseSourcesView: View {
    @EnvironmentObject private var browse: BrowseStore

    /// The kind picked from the "+" menu, driving the add sheet.
    @State private var addingKind: BrowseSourceKind?

    var body: some View {
        VStack(spacing: 0) {
            // The Audio/Video toggle, with Refresh All and Add on the same
            // row — there's no navigation bar to carry them at the top of the
            // Search tab. Every item's Download and Preview act in this mode,
            // mirroring the Download section's own toggle.
            HStack(spacing: 16) {
                Picker("Mode", selection: $browse.downloadMode) {
                    ForEach(DownloadMode.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)

                Spacer()

                Button {
                    Task { await browse.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(browse.sources.isEmpty || !browse.refreshing.isEmpty)
                .accessibilityLabel("Refresh all sources")
                addMenu
            }
            .padding(.horizontal)
            .padding(.bottom, 4)

            if browse.sources.isEmpty {
                emptyState
            } else {
                sourceList
            }
        }
        .sheet(item: $addingKind) { kind in
            AddBrowseSourceView(kind: kind)
        }
    }

    private var addMenu: some View {
        Menu {
            ForEach(BrowseSourceKind.addable) { kind in
                Button {
                    addingKind = kind
                } label: {
                    Label(kind.displayName, systemImage: kind.systemImage)
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
        }
        .accessibilityLabel("Add source")
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ContentUnavailableViewCompat(
                title: "No sources yet",
                systemImage: "sparkles.rectangle.stack",
                description: "Add a YouTube channel or playlist, an RSS feed, or let AI dig up popular songs by artist, genre or country."
            )
            Menu {
                ForEach(BrowseSourceKind.addable) { kind in
                    Button {
                        addingKind = kind
                    } label: {
                        Label(kind.displayName, systemImage: kind.systemImage)
                    }
                }
            } label: {
                Label("Add a Source", systemImage: "plus")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxHeight: .infinity)
    }

    private var sourceList: some View {
        List {
            ForEach(BrowseSourceKind.addable) { kind in
                let ofKind = browse.sources(of: kind)
                if !ofKind.isEmpty {
                    Section(kind.pluralName) {
                        ForEach(ofKind) { source in
                            NavigationLink {
                                // Discography-mode Artist sources open the
                                // album-first browser; everything else keeps
                                // the item list.
                                if source.usesDiscographyBrowser {
                                    ArtistDiscographySourceView(sourceID: source.id)
                                } else {
                                    BrowseSourceView(sourceID: source.id)
                                }
                            } label: {
                                BrowseSourceRow(source: source)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    browse.removeSource(source)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                // Catalogue sources refresh from their own
                                // screen's toolbar; the swipe would no-op.
                                if !source.usesDiscographyBrowser {
                                    Button {
                                        Task { await browse.refresh(source) }
                                    } label: {
                                        Label("Refresh", systemImage: "arrow.clockwise")
                                    }
                                    .tint(.blue)
                                }
                            }
                        }
                    }
                }
            }
        }
        .insetGroupedListStyle()
        .miniPlayerClearance()
        .refreshable { await browse.refreshAll() }
    }
}

/// One source row: icon, name, and either a spinner (refreshing), the last
/// error, or the new-item count.
private struct BrowseSourceRow: View {
    @EnvironmentObject private var browse: BrowseStore
    let source: BrowseSource

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: source.kind.systemImage)
                .foregroundStyle(Color.accentColor)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .lineLimit(1)
                if let error = browse.lastError[source.id] {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                } else if let refreshed = source.lastRefreshed {
                    Text("Updated \(refreshed.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Never refreshed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if browse.refreshing.contains(source.id) {
                ProgressView().controlSize(.small)
            } else {
                let count = browse.newCount(for: source.id)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor, in: Capsule())
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// The add-source sheet for one kind: a name (optional for feeds), the
/// kind-specific input, and an Add button that kicks off the first refresh.
struct AddBrowseSourceView: View {
    let kind: BrowseSourceKind

    @EnvironmentObject private var browse: BrowseStore
    @EnvironmentObject private var aiSettings: AISettingsStore
    @EnvironmentObject private var spotifySettings: SpotifySettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var input = ""
    /// Decade scope for an AI music source; empty means any era.
    @State private var era = ""
    /// What an Artist source follows — the choice that used to be two separate
    /// source kinds in the "+" menu.
    @State private var artistMode: ArtistSourceMode = .topTracks
    /// Presents the all-countries picker (Country kind only).
    @State private var showingCountryList = false

    private var isArtist: Bool { kind == .artist }

    /// Whether the configured source would call the Anthropic API — every AI
    /// kind except an Artist source in Spotify Discography mode, which reads
    /// Spotify instead.
    private var aiBlocked: Bool {
        guard kind.usesAI else { return false }
        if isArtist && !artistMode.usesAI { return false }
        return !aiSettings.isAuthenticated
    }

    /// The Spotify Discography mode is the one source that needs the
    /// Settings ▸ Spotify credentials rather than an AI key.
    private var spotifyBlocked: Bool {
        isArtist && artistMode == .spotifyDiscography && !spotifySettings.isConfigured
    }

    /// The era picker applies to the AI music kinds — but not to an Artist
    /// source in Discography mode, which spans the whole catalogue.
    private var showsEra: Bool {
        kind.supportsEra && (!isArtist || artistMode.supportsEra)
    }

    private var footerText: String {
        if isArtist { return artistMode.help }
        return showsEra ? "\(kind.help) Pick a decade to focus the suggestions on that era." : kind.help
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField(kind.inputPlaceholder, text: $input)
                            .textInputAutocapitalization(kind.inputIsURL ? .never : .words)
                            .autocorrectionDisabled(kind.inputIsURL)
                            .keyboardType(kind.inputIsURL ? .URL : .default)
                        if kind == .country {
                            Button {
                                showingCountryList = true
                            } label: {
                                Image(systemName: "globe")
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.borderless)
                            .contentShape(Rectangle())
                            .accessibilityLabel("Choose from a list of countries")
                        }
                    }
                    if isArtist {
                        // A menu, not segments: three modes with real names
                        // ("Spotify Discography") don't fit a segmented bar.
                        Picker("Follow", selection: $artistMode) {
                            ForEach(ArtistSourceMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    if showsEra {
                        Picker("Era", selection: $era) {
                            Text("Any era").tag("")
                            ForEach(BrowseEra.decades, id: \.self) { decade in
                                Text(decade).tag(decade)
                            }
                        }
                    }
                    TextField(kind.inputIsURL ? "Name (optional — uses the site's title)" : "Name (optional)",
                              text: $name)
                } footer: {
                    Text(footerText)
                }

                if aiBlocked {
                    Section {
                        Label("This source type uses AI. Add an Anthropic API key in Settings first.",
                              systemImage: "key")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }

                if spotifyBlocked {
                    Section {
                        Label("This mode reads the discography from Spotify. Add Spotify credentials in Settings first.",
                              systemImage: "key")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Add \(kind.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add") { add() }
                        .fontWeight(.semibold)
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty
                                  || aiBlocked || spotifyBlocked)
                }
            }
            .sheet(isPresented: $showingCountryList) {
                CountryListView { country in
                    input = country
                }
            }
        }
    }

    private func add() {
        let source = browse.addSource(kind: kind,
                                      name: name,
                                      input: input,
                                      era: (showsEra && !era.isEmpty) ? era : nil,
                                      artistMode: isArtist ? artistMode : nil)
        // First refresh happens right away so the source lands populated.
        Task { await browse.refresh(source) }
        dismiss()
    }
}

/// A searchable list of every country, for the Country source's input field —
/// handy when the spelling the model expects isn't obvious. Built from the
/// system's ISO region list (localized names), so nothing is hard-coded.
struct CountryListView: View {
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    /// Localized names for the two-letter ISO regions (skipping the "unknown
    /// region" placeholder), sorted for scanning.
    private static let countries: [String] = {
        let codes = Locale.Region.isoRegions
            .map(\.identifier)
            .filter { $0.count == 2 && $0.allSatisfy(\.isLetter) && $0 != "ZZ" }
        let names = codes.compactMap { Locale.current.localizedString(forRegionCode: $0) }
        return Set(names).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }()

    private var filtered: [String] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return Self.countries }
        return Self.countries.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(filtered, id: \.self) { country in
                Button {
                    onSelect(country)
                    dismiss()
                } label: {
                    Text(country)
                        .foregroundStyle(.primary)
                }
            }
            #if os(macOS)
            .searchable(text: $search)
            #else
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
            #endif
            .navigationTitle("Choose a Country")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
