import SwiftUI

/// The Browse tab. The **Every Noise at Once** browser *is* the tab — the whole
/// genre map, open the moment you get here — and the sources you keep tabs on
/// (YouTube channels/playlists, RSS feeds, AI-curated artist/genre/country
/// lists) sit one tap away behind the button in the top-right corner. That's
/// the reverse of how it started: the map used to be the thing behind a button.
struct BrowseView: View {
    var body: some View {
        NavigationStack {
            // The two corner buttons — Saved for Later and Sources — are
            // declared by the browser itself, so they sit in one group in a
            // known order rather than in two toolbars that merge however
            // SwiftUI feels like.
            EveryNoiseView()
        }
    }
}

/// The sources button, wearing a dot when the sources have turned up items
/// nobody has acted on yet. With the map as the tab, this is the only thing
/// left that says a refresh found something — the per-source counts are a
/// screen away now.
///
/// It observes the store on its own so that a refresh redraws *this* and not
/// the genre map behind it.
struct SourcesButtonLabel: View {
    @EnvironmentObject private var browse: BrowseStore

    var body: some View {
        let new = browse.totalNewCount
        return Image(systemName: "rectangle.stack")
            .overlay(alignment: .topTrailing) {
                if new > 0 {
                    // The same tint the per-source count badges wear.
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 8, height: 8)
                        .offset(x: 5, y: -3)
                }
            }
            .accessibilityLabel(new > 0 ? "Your sources — \(new) new" : "Your sources")
    }
}

/// The sources screen: what each source has surfaced, ready to curate —
/// download, preview, save or discard. Reached from the button in the Browse
/// tab's top-right corner.
struct BrowseSourcesView: View {
    @EnvironmentObject private var browse: BrowseStore

    /// The kind picked from the "+" menu, driving the add sheet.
    @State private var addingKind: BrowseSourceKind?

    var body: some View {
        VStack(spacing: 0) {
            // The Audio/Video toggle beneath the title (kept out of the
            // toolbar so it doesn't crowd the add button): every item's
            // Download and Preview act in this mode, mirroring the
            // Download tab's own toggle.
            HStack {
                Picker("Mode", selection: $browse.downloadMode) {
                    ForEach(DownloadMode.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)

                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 4)

            if browse.sources.isEmpty {
                emptyState
            } else {
                sourceList
            }
        }
        .navigationTitle("Sources")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Both on the trailing edge: the leading one belongs to the back
            // button now that this is a screen you arrive at rather than land on.
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    Task { await browse.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(browse.sources.isEmpty || !browse.refreshing.isEmpty)
                .accessibilityLabel("Refresh all sources")
                addMenu
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
