import SwiftUI

/// The Browse tab: keeps tabs on audio sources (YouTube channels/playlists,
/// RSS feeds, and AI-curated artist/genre/country lists) and presents what
/// they surface for curation — download, preview, save or discard.
struct BrowseView: View {
    @EnvironmentObject private var browse: BrowseStore

    /// The kind picked from the "+" menu, driving the add sheet.
    @State private var addingKind: BrowseSourceKind?

    var body: some View {
        NavigationStack {
            Group {
                if browse.sources.isEmpty {
                    emptyState
                } else {
                    sourceList
                }
            }
            .navigationTitle("Browse")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        Task { await browse.refreshAll() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(browse.sources.isEmpty || !browse.refreshing.isEmpty)
                    .accessibilityLabel("Refresh all sources")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    addMenu
                }
            }
            .sheet(item: $addingKind) { kind in
                AddBrowseSourceView(kind: kind)
            }
        }
    }

    private var addMenu: some View {
        Menu {
            ForEach(BrowseSourceKind.allCases) { kind in
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
                ForEach(BrowseSourceKind.allCases) { kind in
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
            ForEach(BrowseSourceKind.allCases) { kind in
                let ofKind = browse.sources(of: kind)
                if !ofKind.isEmpty {
                    Section(kind.pluralName) {
                        ForEach(ofKind) { source in
                            NavigationLink {
                                BrowseSourceView(sourceID: source.id)
                            } label: {
                                BrowseSourceRow(source: source)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    browse.removeSource(source)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
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
        .listStyle(.insetGrouped)
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
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var input = ""
    /// Decade scope for an AI music source; empty means any era.
    @State private var era = ""
    /// Presents the all-countries picker (Country kind only).
    @State private var showingCountryList = false

    private var aiBlocked: Bool { kind.usesAI && !aiSettings.isAuthenticated }

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
                                Image(systemName: "list.bullet.circle")
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Choose from a list of countries")
                        }
                    }
                    if kind.supportsEra {
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
                    Text(kind.supportsEra
                         ? "\(kind.help) Pick a decade to focus the suggestions on that era."
                         : kind.help)
                }

                if aiBlocked {
                    Section {
                        Label("This source type uses AI. Add an Anthropic API key in Settings first.",
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
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || aiBlocked)
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
                                      era: era.isEmpty ? nil : era)
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
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
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
