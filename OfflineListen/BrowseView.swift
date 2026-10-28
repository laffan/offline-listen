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
                // Room under the tab's line before a section starts — the same
                // as the sections leave at their sides, so the content sits in
                // the outline rather than butting up against its top.
                .padding(.top, SearchTabMetrics.contentInset)
                // Clear of the screen's edges, so the outline the tab opens
                // into has sides to draw.
                .padding(.horizontal, SearchTabMetrics.gutter)
            }
            .overlayPreferenceValue(SelectedSearchTabKey.self) { anchor in
                GeometryReader { proxy in
                    if let anchor {
                        SearchTabOutline(tab: proxy[anchor],
                                         panelMinX: SearchTabMetrics.gutter,
                                         panelMaxX: proxy.size.width - SearchTabMetrics.gutter)
                            .stroke(Color.appSeparator, lineWidth: 1)
                            .animation(.easeInOut(duration: 0.2), value: section)
                    }
                }
                // Open at the foot: the sides run on under the mini player and
                // the tab bar rather than stopping short of them.
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
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

/// Shared by the tab strip and the panel beneath it, so the first tab's left
/// edge and the panel's left edge are one line.
private enum SearchTabMetrics {
    /// How far the strip and the panel sit in from the screen's sides.
    static let gutter: CGFloat = 6
    /// The rounding on the tab's top corners and the panel's.
    static let cornerRadius: CGFloat = 10
    /// The gap between the panel's top edge and the section inside it —
    /// matched to the standard 16-point side padding the sections use, so
    /// the content is framed evenly.
    static let contentInset: CGFloat = 16
}

/// Where the selected tab is, for the outline that joins it to its panel.
private struct SelectedSearchTabKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// The Search tab's four sections, as **tabs**: a glyph over its name, where a
/// navigation bar would be. The names went for a while — four familiar icons
/// read at a glance — and came back, because four icons are a puzzle the
/// first few times and a name costs one caption line.
///
/// The selected tab is drawn the way a tab is: one hairline runs up its sides
/// and over its top and carries on around the section's content, open where
/// the two meet (`SearchTabOutline`). Which section you are in is then a shape
/// rather than only a colour. Two of the tabs carry news from the section
/// behind them — **Download** the number of downloads still working or waiting
/// (the tab's own badge says the same from elsewhere in the app), and
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
        HStack(spacing: 2) {
            ForEach(SearchSection.allCases) { candidate in
                button(candidate)
            }
        }
        .padding(.horizontal, SearchTabMetrics.gutter)
        .padding(.top, 4)
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
                    .font(.caption.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .anchorPreference(key: SelectedSearchTabKey.self, value: .bounds) { selected ? $0 : nil }
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

/// The outline of the selected tab and the panel it opens onto, as one line:
/// up the panel's left side, around the tab, and down the panel's right side,
/// left open along the stretch where the tab meets the panel and at the foot
/// (which runs on under the bars). Where the tab sits flush with a side of the
/// panel, its side *is* the panel's side and the line goes straight up.
private struct SearchTabOutline: Shape {
    /// The selected tab's frame, in the shape's own coordinates.
    var tab: CGRect
    /// The panel's left and right edges.
    var panelMinX: CGFloat
    var panelMaxX: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(tab.minX, tab.width) }
        set {
            tab.origin.x = newValue.first
            tab.size.width = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let r = SearchTabMetrics.cornerRadius
        // The concave turn from the panel's top into a tab's side is gentler
        // than the corners, so a narrow gap still reads as a curve.
        let inner: CGFloat = 6
        let left = panelMinX, right = panelMaxX, bottom = rect.maxY
        let panelTop = tab.maxY
        let tabTop = tab.minY
        let tabLeft = max(tab.minX, left), tabRight = min(tab.maxX, right)

        var path = Path()
        path.move(to: CGPoint(x: left, y: bottom))
        if tabLeft - left < 1 {
            path.addArc(tangent1End: CGPoint(x: left, y: tabTop),
                        tangent2End: CGPoint(x: tabRight, y: tabTop), radius: r)
        } else {
            path.addArc(tangent1End: CGPoint(x: left, y: panelTop),
                        tangent2End: CGPoint(x: tabLeft, y: panelTop), radius: r)
            path.addArc(tangent1End: CGPoint(x: tabLeft, y: panelTop),
                        tangent2End: CGPoint(x: tabLeft, y: tabTop), radius: inner)
            path.addArc(tangent1End: CGPoint(x: tabLeft, y: tabTop),
                        tangent2End: CGPoint(x: tabRight, y: tabTop), radius: r)
        }
        if right - tabRight < 1 {
            path.addArc(tangent1End: CGPoint(x: right, y: tabTop),
                        tangent2End: CGPoint(x: right, y: bottom), radius: r)
        } else {
            path.addArc(tangent1End: CGPoint(x: tabRight, y: tabTop),
                        tangent2End: CGPoint(x: tabRight, y: panelTop), radius: r)
            path.addArc(tangent1End: CGPoint(x: tabRight, y: panelTop),
                        tangent2End: CGPoint(x: right, y: panelTop), radius: inner)
            path.addArc(tangent1End: CGPoint(x: right, y: panelTop),
                        tangent2End: CGPoint(x: right, y: bottom), radius: r)
        }
        path.addLine(to: CGPoint(x: right, y: bottom))
        return path
    }
}

/// The sources screen — the Search tab's **Sources** section. Every source is
/// a **section of its own**: its name and state as the header, and beneath it
/// the tracks it has turned up, each with the Artist page's controls —
/// download it, preview it, or (once it's in the library) play it — and a
/// **Download All** above them that takes the whole list the way a record is
/// taken, as one album folder in tracklist order.
///
/// It used to be a list of source *names*, each a screen to push into before
/// anything it had found could be seen. The list a source makes is the point
/// of having it, so that's what the screen shows; the source's own screen is
/// still a tap away, for the full list, multi-select, **More**, and a Blog
/// Agent's posts.
struct BrowseSourcesView: View {
    @EnvironmentObject private var browse: BrowseStore
    @EnvironmentObject private var router: AppRouter

    /// The kind picked from the "+" menu, driving the add sheet.
    @State private var addingKind: BrowseSourceKind?
    /// The item being previewed (drives the modal), and the source list it was
    /// tapped in — the modal's next/previous walk that list.
    @State private var previewItem: BrowseItem?
    @State private var previewQueue: [BrowseItem] = []
    /// Sections folded shut by their header's chevron.
    @State private var collapsed: Set<UUID> = []

    /// Every source, in the order the "+" menu lists their kinds (stations
    /// first), and in the order they were added within a kind.
    private var orderedSources: [BrowseSource] {
        BrowseSourceKind.addable.flatMap { browse.sources(of: $0) }
    }

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
        .sheet(item: $previewItem) { item in
            BrowsePreviewView(item: item, mode: browse.downloadMode, queue: previewQueue)
        }
    }

    private var addMenu: some View {
        Menu {
            addButtons
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
        }
        .accessibilityLabel("Add source")
    }

    @ViewBuilder
    private var addButtons: some View {
        ForEach(BrowseSourceKind.addable) { kind in
            Button {
                addingKind = kind
            } label: {
                Label(kind.displayName, systemImage: kind.systemImage)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ContentUnavailableViewCompat(
                title: "No sources yet",
                systemImage: "sparkles.rectangle.stack",
                description: "Start a radio station from an artist or a song, follow a YouTube channel or playlist or an RSS feed, or let AI dig up popular songs by artist, genre or country."
            )
            Menu {
                addButtons
            } label: {
                Label("Add a Source", systemImage: "plus")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxHeight: .infinity)
    }

    private var sourceList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(orderedSources) { source in
                    BrowseSourceSection(
                        source: source,
                        isCollapsed: collapsed.contains(source.id),
                        onToggle: { toggle(source.id) },
                        onPreview: { item, queue in
                            browse.markPreviewed(item)
                            previewQueue = queue
                            previewItem = item
                        }
                    )
                }
            }
            .listStyle(.plain)
            .miniPlayerClearance()
            .refreshable { await browse.refreshAll() }
            .onAppear { showPendingSource(with: proxy) }
            .onChange(of: router.pendingSource) { _ in showPendingSource(with: proxy) }
        }
    }

    private func toggle(_ id: UUID) {
        withAnimation {
            if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        }
    }

    /// Find Similar's station, scrolled to and opened. Each section's first
    /// row carries the source's id, which is what `scrollTo` finds — so the
    /// section is opened first, and the scroll waits a turn for it to draw.
    private func showPendingSource(with proxy: ScrollViewProxy) {
        guard let id = router.pendingSource,
              browse.sources.contains(where: { $0.id == id }) else { return }
        router.pendingSource = nil
        collapsed.remove(id)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            withAnimation { proxy.scrollTo(id, anchor: .top) }
        }
    }
}

/// One source in the Sources list: a header naming it — with its state, its
/// new-item count and a menu for the rest — over the tracks it has found.
///
/// How many tracks show is capped (`shownLimit`): a channel can list hundreds,
/// and one source shouldn't push every other one off the bottom of the screen.
/// The rest are behind **Show all**, the source's own screen. A discography-
/// mode Artist source isn't a list of tracks at all but a catalogue, so its
/// section is the way into the catalogue browser instead.
private struct BrowseSourceSection: View {
    let source: BrowseSource
    let isCollapsed: Bool
    let onToggle: () -> Void
    /// The tapped item and the source's whole visible list — the queue the
    /// preview modal walks.
    let onPreview: (BrowseItem, [BrowseItem]) -> Void

    @EnvironmentObject private var browse: BrowseStore
    @EnvironmentObject private var downloads: DownloadManager

    /// A station's first set is twenty songs and reads as one; the other kinds
    /// show the newest ten.
    private var shownLimit: Int { source.kind == .radio ? 20 : 10 }

    var body: some View {
        let items = browse.visibleItems(for: source.id)
        Section {
            if !isCollapsed {
                content(items: items)
            }
        } header: {
            header
        }
    }

    @ViewBuilder
    private func content(items: [BrowseItem]) -> some View {
        if source.usesDiscographyBrowser {
            NavigationLink {
                ArtistDiscographySourceView(sourceID: source.id)
            } label: {
                Label("Open Discography", systemImage: "square.stack")
            }
            .id(source.id)
        } else if items.isEmpty {
            statusRow
                .id(source.id)
        } else {
            SourceDownloadAllButton(source: source, items: items)
                .id(source.id)
            let shown = Array(items.prefix(shownLimit))
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                trackRow(number: index + 1, item: item, queue: items)
            }
            NavigationLink {
                BrowseSourceView(sourceID: source.id)
            } label: {
                Text(items.count > shown.count
                     ? "Show all \(items.count)"
                     : (source.kind == .blogAgent ? "Posts & artists" : "Open \(source.kind.displayName)"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    /// What a source with no tracks yet has to say: it's being fetched (a
    /// station being put together, mostly — the add sheet closes at once and
    /// the model does its work here), it failed, or it hasn't been asked.
    @ViewBuilder
    private var statusRow: some View {
        if browse.refreshing.contains(source.id) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(source.kind == .radio ? "Tuning in — finding music like \(source.input)…" : "Refreshing…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        } else {
            HStack(spacing: 10) {
                if let error = browse.lastError[source.id] {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                } else {
                    Text("Nothing here yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Refresh") {
                    Task { await browse.refresh(source) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.vertical, 4)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    Image(systemName: source.kind.systemImage)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(source.name)
                            .lineLimit(1)
                        subtitle
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(source.name), \(source.kind.displayName)")
            .accessibilityHint(isCollapsed ? "Shows its tracks" : "Hides its tracks")

            if browse.refreshing.contains(source.id) {
                ProgressView().controlSize(.small)
            } else {
                let count = browse.newCount(for: source.id)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                        .accessibilityLabel("\(count) new")
                }
            }
            menu
        }
        .browseSectionHeaderStyle()
    }

    @ViewBuilder
    private var subtitle: some View {
        if let error = browse.lastError[source.id] {
            Text(error)
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(1)
        } else if let refreshed = source.lastRefreshed {
            Text("\(source.kind.displayName) · Updated \(refreshed.formatted(.relative(presentation: .named)))")
                .font(.caption.weight(.regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text(source.kind.displayName)
                .font(.caption.weight(.regular))
                .foregroundStyle(.secondary)
        }
    }

    private var menu: some View {
        Menu {
            // Catalogue sources refresh from their own screen's toolbar.
            if !source.usesDiscographyBrowser {
                Button {
                    Task { await browse.refresh(source) }
                } label: {
                    Label(source.kind == .radio ? "More Like This" : "Refresh",
                          systemImage: "arrow.clockwise")
                }
                .disabled(browse.refreshing.contains(source.id))
            }
            Button(role: .destructive) {
                browse.removeSource(source)
            } label: {
                Label("Delete Source", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
                .foregroundStyle(Color.accentColor)
                .padding(.leading, 4)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("\(source.name) options")
    }

    private func trackRow(number: Int, item: BrowseItem, queue: [BrowseItem]) -> some View {
        SourceTrackRow(number: number, item: item,
                       onDownload: { download(item) },
                       onPreview: { onPreview(item, queue) })
            // Touch and hold to (re-)download in the current Audio/Video mode
            // — the way back for an item grabbed in the wrong format.
            .contextMenu {
                Button {
                    download(item)
                } label: {
                    Label(item.status == .new
                            ? "Download (\(browse.downloadMode.displayName))"
                            : "Download Again (\(browse.downloadMode.displayName))",
                          systemImage: "arrow.down.circle")
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    browse.markDiscarded(item)
                } label: {
                    Label("Discard", systemImage: "xmark.bin")
                }
            }
    }

    /// One track to the queue, filed into the folder named after the source —
    /// with the row's own name and artist riding along for the queue to show
    /// (see `BrowseSourceView.enqueue`).
    private func download(_ item: BrowseItem) {
        let name = source.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let named = item.naming
        if name.isEmpty {
            downloads.enqueue(urlString: item.url, mode: browse.downloadMode,
                              queuedTitle: named.title, queuedArtist: named.artist)
        } else {
            downloads.enqueue(urlString: item.url, mode: browse.downloadMode,
                              browseFolderNamed: name,
                              queuedTitle: named.title, queuedArtist: named.artist)
        }
        browse.markDownloaded(item)
    }
}

/// A track under its source's header, laid out as the Artist page lays out a
/// release's tracks: its number, the song (artist beneath), then **Download**
/// — or, once it's in the library, the green play button — and **Preview**,
/// whose icon fills in once it's been auditioned.
struct SourceTrackRow: View {
    let number: Int
    let item: BrowseItem
    let onDownload: () -> Void
    let onPreview: () -> Void

    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        let named = item.naming
        HStack(spacing: 10) {
            Text("\(number).")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 22, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(named.title)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(2)
                if let artist = named.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if item.status == .downloaded || item.status == .saved
                || library.track(forSourceURL: item.url) != nil {
                BrowseTrackStatusButton(sourceURL: item.url,
                                        pendingIcon: item.status == .saved
                                            ? "checkmark.circle.fill" : "arrow.down.circle.fill",
                                        pendingLabel: item.status == .saved
                                            ? "Saved to Library" : "Sent to Downloads")
            } else {
                Button(action: onDownload) {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Download \(named.title)")
            }
            Button(action: onPreview) {
                Image(systemName: item.wasPreviewed ? "play.circle.fill" : "play.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(item.wasPreviewed ? "Preview \(named.title) again" : "Preview \(named.title)")
        }
        .font(.title3)
        .padding(.vertical, 3)
    }
}

/// **Download All** for a source: every track it lists, queued the way the
/// Artist page's **Download Album** queues a record — one album folder named
/// after the source, in the list's own order, grouped as one row in the
/// Download section. It counts the tracks in as they land and becomes **Play
/// All** once the whole list is in one folder. Like that button, the state is
/// read off the **library** past the moment of queueing, so it stays true
/// across a redraw and still offers to play a list taken on an earlier visit.
private struct SourceDownloadAllButton: View {
    let source: BrowseSource
    let items: [BrowseItem]

    @EnvironmentObject private var browse: BrowseStore
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager

    /// The links this button sent to the queue, which is what tells
    /// "downloading" apart from "some of these happen to be in the library".
    @State private var queuedURLs: Set<String> = []

    private enum BulkState {
        case idle(Int)
        case downloading(landed: Int, total: Int)
        case ready(UUID)
    }

    private var state: BulkState {
        let landed = items.compactMap { library.track(forSourceURL: $0.url) }
        let folders = Set(landed.compactMap(\.folderID))
        if !items.isEmpty, landed.count == items.count, folders.count == 1, let folder = folders.first {
            return .ready(folder)
        }
        if !queuedURLs.isEmpty {
            let arrived = queuedURLs.filter { library.track(forSourceURL: $0) != nil }.count
            return .downloading(landed: arrived, total: queuedURLs.count)
        }
        return .idle(items.count)
    }

    var body: some View {
        let state = self.state
        VStack(spacing: 6) {
            Button {
                if case .ready(let folderID) = state {
                    playAll(in: folderID)
                } else {
                    downloadAll()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon(for: state))
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
            .disabled(isDownloading(state))

            if case .downloading(let landed, let total) = state, total > 0 {
                ProgressView(value: Double(landed), total: Double(total))
                    .progressViewStyle(.linear)
            }
        }
        .padding(.vertical, 4)
        // The capsule is a control, not a row to select.
        .listRowSeparator(.hidden)
    }

    private func label(for state: BulkState) -> String {
        switch state {
        case .idle(let count): return "Download All (\(count))"
        case .downloading(let landed, let total):
            return landed >= total ? "Filing…" : "Downloading \(landed) of \(total)…"
        case .ready: return "Play All"
        }
    }

    private func icon(for state: BulkState) -> String {
        switch state {
        case .idle: return "arrow.down.circle.fill"
        case .downloading: return "arrow.down.circle"
        case .ready: return "play.circle.fill"
        }
    }

    private func isReady(_ state: BulkState) -> Bool {
        if case .ready = state { return true }
        return false
    }

    private func isDownloading(_ state: BulkState) -> Bool {
        if case .downloading(let landed, let total) = state { return landed < total }
        return false
    }

    /// The whole list as one record. An AI list's rows are "Artist — Song"
    /// pairs the model named, so those ride along as the track's metadata (and
    /// spare it the organizer); a feed's rows are video titles, which the
    /// download names better itself.
    private func downloadAll() {
        let tracks = items.map { item -> DownloadManager.AlbumTrack in
            let named = item.naming
            let knowsArtist = item.title.contains(" — ") && named.artist != nil
            return DownloadManager.AlbumTrack(url: item.url,
                                              title: knowsArtist ? named.title : nil,
                                              artist: knowsArtist ? named.artist : nil,
                                              artworkURL: item.artworkURL)
        }
        guard !tracks.isEmpty else { return }
        _ = downloads.enqueueAlbum(named: source.name, tracks: tracks, mode: browse.downloadMode)
        queuedURLs = Set(tracks.map(\.url))
        browse.markDownloaded(items)
    }

    private func playAll(in folderID: UUID) {
        let folderTracks = library.tracks(in: folderID)
        guard let first = folderTracks.first else { return }
        playback.play(first, in: folderTracks, restrictToCategory: false)
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
            .navigationTitle(kind == .radio ? "New Radio Station" : "Add \(kind.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    // A station is made rather than added: the model builds it
                    // in the background once the sheet closes.
                    Button(kind == .radio ? "Create" : "Add") { add() }
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
