import SwiftUI
import UIKit

/// One source's discovered items: artist/song title with per-row **Download**
/// (sends to the download queue) and **Preview** (opens the listen-first
/// modal) actions, both in the mode set by the Browse tab's Audio/Video
/// toggle. Swipe an item left to discard it without previewing.
struct BrowseSourceView: View {
    let sourceID: UUID

    @EnvironmentObject private var browse: BrowseStore
    @EnvironmentObject private var downloads: DownloadManager

    /// The item being previewed (drives the modal).
    @State private var previewItem: BrowseItem?
    /// Drives multi-select mode (the "Select" button); `selection` holds the
    /// checked items so they can be downloaded in one tap.
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<BrowseItem.ID>()
    /// The artist tapped in a Blog Agent post's list, driving the "create a
    /// source for this artist" popup.
    @State private var artistForSource: String?

    private var source: BrowseSource? {
        browse.sources.first(where: { $0.id == sourceID })
    }

    /// Blog Agent lists group by article (summary + tracks + artists); an
    /// Artist source in Discography mode groups by album (with a Highlights
    /// section on top); the rest are a single flat list.
    private var isBlogAgent: Bool { source?.kind == .blogAgent }
    private var isDiscography: Bool { source?.isDiscography == true }

    /// The AI music sources title their items "Artist — Song", so the row can
    /// lift the artist onto its own line (Library-style). Feed titles (video/
    /// post names) aren't a reliable artist/song pair, so they're left whole.
    private var parsesArtist: Bool {
        switch source?.kind {
        case .artist, .genre, .country, .discography: return true
        default: return false
        }
    }

    var body: some View {
        let items = browse.visibleItems(for: sourceID)
        // A Blog Agent source can have posts (summary + artists) with no tracks,
        // so it isn't "empty" just because there are no items.
        let posts = isBlogAgent ? browse.posts(for: sourceID) : []
        VStack(spacing: 0) {
            // The same Audio/Video toggle the Browse tab's own screen carries:
            // this list's Download and Preview act in this mode too, and having
            // to go back a screen to change it was the wrong shape.
            modeBar
            content(items: items, posts: posts)
        }
        .navigationTitle(source?.name ?? "Source")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent(items: items) }
        .sheet(item: $previewItem) { item in
            BrowsePreviewView(item: item, mode: browse.downloadMode)
        }
        .confirmationDialog(
            "Follow this artist",
            isPresented: presentingArtist,
            titleVisibility: .visible,
            presenting: artistForSource
        ) { artist in
            Button(ArtistSourceMode.topTracks.displayName) { addArtistSource(.topTracks, name: artist) }
            Button(ArtistSourceMode.discography.displayName) { addArtistSource(.discography, name: artist) }
            Button("Cancel", role: .cancel) {}
        } message: { artist in
            Text("Add “\(artist)” as a new Artist source.")
        }
    }

    private var modeBar: some View {
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
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func content(items: [BrowseItem], posts: [BrowsePost]) -> some View {
        Group {
            if items.isEmpty && posts.isEmpty {
                VStack(spacing: 16) {
                    if browse.refreshing.contains(sourceID) {
                        ProgressView("Refreshing…")
                    } else {
                        ContentUnavailableViewCompat(
                            title: "Nothing here yet",
                            systemImage: source?.kind.systemImage ?? "sparkles",
                            description: emptyDescription
                        )
                        Button {
                            refresh()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    if isBlogAgent {
                        blogAgentSections(posts: posts, items: items)
                    } else if isDiscography {
                        // Grouped by album, Highlights section pinned on top.
                        Section {
                        } header: {
                            header(count: items.count)
                        }
                        ForEach(postGroups(of: items)) { group in
                            Section {
                                ForEach(group.items) { itemRow($0) }
                            } header: {
                                postHeader(group)
                            }
                        }
                    } else {
                        Section {
                            ForEach(items) { itemRow($0) }
                        } header: {
                            header(count: items.count)
                        }
                    }
                    // Foot of every layout — a Blog Agent's article sections
                    // page just as a flat feed list does.
                    moreSection
                }
                .listStyle(.plain)
                .miniPlayerClearance()
                .environment(\.editMode, $editMode)
                .refreshable { await refreshAsync() }
            }
        }
    }

    /// The **More** row at the foot of the list: pulls the next page of the
    /// source's listing (older uploads, the feed's next page, the blog's next
    /// batch of articles). A refresh only ever re-reads the newest page, so
    /// this is the only way further back. Hidden in select mode, and it retires
    /// itself once the source reports there's nothing older.
    @ViewBuilder
    private var moreSection: some View {
        if let source, source.kind.supportsMore, !editMode.isEditing {
            Section {
                if browse.loadingMore.contains(sourceID) {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Loading older items…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
                } else if source.canLoadMore {
                    Button {
                        Task { await browse.loadMore(source) }
                    } label: {
                        Label("More", systemImage: "arrow.down.circle")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                } else {
                    Text("Nothing older to load")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 6)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbarContent(items: [BrowseItem]) -> some ToolbarContent {
        if editMode.isEditing {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    downloadSelected()
                } label: {
                    Label(selection.isEmpty ? "Download" : "Download (\(selection.count))",
                          systemImage: "arrow.down.circle")
                }
                .disabled(selection.isEmpty)
            }
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if !editMode.isEditing {
                if browse.refreshing.contains(sourceID) {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh")
                }
            }
            Button(editMode.isEditing ? "Done" : "Select") {
                withAnimation {
                    if editMode.isEditing {
                        editMode = .inactive
                        selection.removeAll()
                    } else {
                        editMode = .active
                    }
                }
            }
            .disabled(items.isEmpty && !editMode.isEditing)
        }
    }

    private var presentingArtist: Binding<Bool> {
        Binding(get: { artistForSource != nil },
                set: { if !$0 { artistForSource = nil } })
    }

    /// Adds an Artist source for `name` — following either its top tracks or
    /// its whole discography — and kicks off its first refresh.
    private func addArtistSource(_ mode: ArtistSourceMode, name: String) {
        let source = browse.addSource(kind: .artist, name: name, input: name, artistMode: mode)
        Task { await browse.refresh(source) }
    }

    /// One item row with its discard swipe — shared by the flat and the
    /// grouped-by-post layouts.
    @ViewBuilder
    private func itemRow(_ item: BrowseItem) -> some View {
        BrowseItemRow(
            item: item,
            // While selecting, hide the per-row buttons so a tap toggles the
            // selection instead of firing Download/Preview.
            selecting: editMode.isEditing,
            // Discography rows already carry their year in the album header, so
            // the redundant per-row date is dropped.
            showsDate: !isDiscography,
            parsesArtist: parsesArtist,
            onDownload: { download(item) },
            // Marked as soon as it's opened: the row's filled play icon is a
            // "you've heard this one" breadcrumb, not a record of a decision,
            // so dismissing the modal doesn't take it back.
            onPreview: {
                browse.markPreviewed(item)
                previewItem = item
            }
        )
        // Touch and hold to (re-)download in the current Audio/Video mode —
        // the way back for an item grabbed in the wrong format, whose row
        // button has already given way to the dealt-with marker.
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

    // MARK: - Blog Agent layout

    /// Blog Agent layout: one section per article — a **summary**, then the
    /// YouTube **tracks** found in it, then the **artists** it names (each
    /// tappable to spin up a new Artist source, Top 10 or Discography). Posts
    /// newest-first; any legacy tracks whose article wasn't summarized gather
    /// in a trailing "Other finds" section.
    @ViewBuilder
    private func blogAgentSections(posts: [BrowsePost], items: [BrowseItem]) -> some View {
        Section {
        } header: {
            header(count: posts.count, noun: "post")
        }
        ForEach(posts) { post in
            Section {
                if !post.summary.isEmpty {
                    Text(post.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                }
                ForEach(tracks(in: post, from: items)) { itemRow($0) }
                // The artist list is for browsing, not selecting — hide it in
                // select mode so only tracks are pickable.
                if !editMode.isEditing {
                    artistList(post.artists)
                }
            } header: {
                blogPostHeader(post)
            }
        }
        let orphans = orphanTracks(items, posts: posts)
        if !orphans.isEmpty {
            Section {
                ForEach(orphans) { itemRow($0) }
            } header: {
                Text("Other finds").browseSectionHeaderStyle()
            }
        }
    }

    /// The tracks belonging to one article (matched by its URL/title).
    private func tracks(in post: BrowsePost, from items: [BrowseItem]) -> [BrowseItem] {
        items.filter { ($0.postURL ?? $0.postTitle ?? "") == post.dedupKey }
    }

    /// Tracks left over from before articles were summarized (or whose article
    /// dropped out), so nothing a refresh already surfaced silently disappears.
    private func orphanTracks(_ items: [BrowseItem], posts: [BrowsePost]) -> [BrowseItem] {
        let known = Set(posts.map(\.dedupKey))
        return items.filter { !known.contains($0.postURL ?? $0.postTitle ?? "") }
    }

    @ViewBuilder
    private func blogPostHeader(_ post: BrowsePost) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(post.title)
                .lineLimit(2)
            Spacer()
            if let date = post.datePublished {
                Text(date.formatted(date: .abbreviated, time: .omitted))
                    .foregroundStyle(.secondary)
            }
        }
        .browseSectionHeaderStyle()
    }

    /// A labeled list of the artists an article names; tapping one opens the
    /// popup to create an Artist source — Top 10 or Discography — for it.
    @ViewBuilder
    private func artistList(_ artists: [String]) -> some View {
        if !artists.isEmpty {
            Text("Artists mentioned")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(artists, id: \.self) { artist in
                Button {
                    artistForSource = artist
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "music.mic")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        Text(artist)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "plus.circle")
                            .foregroundStyle(Color.accentColor)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Tracks bucketed under the post they were found in, preserving the
    /// items' newest-first order (so the freshest post's group comes first).
    private struct PostGroup: Identifiable {
        let id: String
        let title: String
        let date: Date?
        var items: [BrowseItem]
    }

    private func postGroups(of items: [BrowseItem]) -> [PostGroup] {
        var order: [String] = []
        var groups: [String: PostGroup] = [:]
        for item in items {
            // Items saved before post tracking existed have neither field;
            // they gather under one catch-all group at their sort position.
            let key = item.postURL ?? item.postTitle ?? ""
            if groups[key] == nil {
                groups[key] = PostGroup(id: key,
                                        title: item.postTitle ?? "Other finds",
                                        date: item.datePublished,
                                        items: [])
                order.append(key)
            }
            groups[key]?.items.append(item)
        }
        return order.compactMap { groups[$0] }
    }

    @ViewBuilder
    private func postHeader(_ group: PostGroup) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(group.title)
                .lineLimit(2)
            Spacer()
            if let trailing = sectionDateText(group) {
                Text(trailing)
                    .foregroundStyle(.secondary)
            }
        }
        .browseSectionHeaderStyle()
    }

    /// The right-aligned label for a section header: a Discography album shows
    /// just its release year; a Blog Agent post shows its full date. The
    /// Discography **Highlights** section isn't an album, so it shows nothing
    /// (its date is only an internal sort stamp).
    private func sectionDateText(_ group: PostGroup) -> String? {
        guard let date = group.date else { return nil }
        guard isDiscography else {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        if group.title == DiscographyAgent.highlightsTitle { return nil }
        return String(Calendar(identifier: .gregorian).component(.year, from: date))
    }

    private var emptyDescription: String {
        if let error = browse.lastError[sourceID] {
            return error
        }
        return "Refresh to fetch this source's items."
    }

    @ViewBuilder
    private func header(count: Int, noun: String = "item") -> some View {
        HStack {
            Text("\(count) \(noun)(s)")
            Spacer()
            if let error = browse.lastError[sourceID] {
                Text(error)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else if let refreshed = source?.lastRefreshed {
                Text("Updated \(refreshed.formatted(.relative(presentation: .named)))")
            }
        }
        .browseSectionHeaderStyle()
    }

    private func refresh() {
        guard let source else { return }
        Task { await browse.refresh(source) }
    }

    private func refreshAsync() async {
        guard let source else { return }
        await browse.refresh(source)
    }

    /// Sends the item to the download queue (in the Browse toggle's
    /// Audio/Video mode) and marks it so the row shows where it went.
    private func download(_ item: BrowseItem) {
        enqueue(item)
        browse.markDownloaded(item)
    }

    /// Queues one item, filed into a library folder named after this source so
    /// everything from a Browse source (e.g. a "Brian Eno" Discography) lands
    /// together — that folder's unlistened tracks still surface in the Inbox.
    private func enqueue(_ item: BrowseItem) {
        let name = source?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty {
            downloads.enqueue(urlString: item.url, mode: browse.downloadMode)
        } else {
            downloads.enqueue(urlString: item.url, mode: browse.downloadMode, browseFolderNamed: name)
        }
    }

    /// Queues every selected item — **including** already-downloaded or saved
    /// rows, which is how a batch mistakenly grabbed as audio gets re-pulled
    /// as video: flip the toggle, tick them again, Download. The selection is
    /// explicit, so what's ticked is what's queued.
    ///
    /// The status change is applied in one batch (`markDownloaded(_:)`) — a
    /// single save and a single published mutation. Select mode is torn down
    /// *first*, in its own transaction, and the data work lands on the next
    /// main-actor turn: ending the animated edit transition in the same
    /// update as dozens of row-status mutations is what crashed the List
    /// (the UIKit diff underneath doesn't survive the combination).
    private func downloadSelected() {
        let picks = browse.visibleItems(for: sourceID)
            .filter { selection.contains($0.id) }
        selection.removeAll()
        withAnimation { editMode = .inactive }
        guard !picks.isEmpty else { return }
        Task { @MainActor in
            for item in picks {
                enqueue(item)
            }
            browse.markDownloaded(picks)
        }
    }
}

/// The marker a browse row shows once its track has been dealt with — shared by
/// every list that offers a download (a source's items, the Every Noise
/// discography, the Download tab's search results).
///
/// Once the download has actually landed in the library the marker becomes a
/// green **play** button: tapping it starts that track in the background and
/// leaves you exactly where you are, so a list can be worked through and
/// listened to at the same time. It falls back to `pendingIcon` while the
/// library has nothing matching yet — a queued download has nothing to play.
struct BrowseTrackStatusButton: View {
    /// The link the row acts on, and how its library track is found.
    let sourceURL: String
    /// Shown while no library track matches: what the row's state means on its
    /// own (sent to the queue, saved).
    let pendingIcon: String
    let pendingLabel: String
    /// In a list's select mode the row belongs to the selection, so the button
    /// steps back to being a plain marker.
    var selecting: Bool = false
    /// Set on roomier, non-icon-only rows (the Download tab's search results)
    /// to spell out what the marker means beside it.
    var showsCaption: Bool = false

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager

    private var track: Track? { library.track(forSourceURL: sourceURL) }

    var body: some View {
        if let track = track, !selecting {
            Button {
                play(track)
            } label: {
                marker(icon: iconName(for: track),
                       caption: isCurrent(track) && playback.isPlaying
                           ? "Playing — tap to pause" : "Play from Library")
            }
            .buttonStyle(.borderless)
            // Green is the "already dealt with" colour these rows use; the
            // borderless style would otherwise tint the label with the accent.
            .tint(.green)
            .accessibilityLabel(isCurrent(track) && playback.isPlaying
                                ? "Pause \(track.title)" : "Play \(track.title)")
        } else {
            marker(icon: pendingIcon, caption: pendingLabel)
                .accessibilityLabel(pendingLabel)
        }
    }

    private func marker(icon: String, caption: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            if showsCaption {
                Text(caption).font(.caption)
            }
        }
        .foregroundStyle(.green)
    }

    private func isCurrent(_ track: Track) -> Bool {
        playback.currentTrack?.id == track.id
    }

    private func iconName(for track: Track) -> String {
        isCurrent(track) && playback.isPlaying ? "pause.circle.fill" : "play.circle.fill"
    }

    /// Starts the track without leaving the list. A filed track plays on
    /// through its folder (a folder is a curated playlist); an unfiled one
    /// plays alone, since the browse list it came from isn't a library queue.
    private func play(_ track: Track) {
        if isCurrent(track) {
            playback.togglePlayPause()
            return
        }
        if let folderID = track.folderID {
            let siblings = library.tracks(in: folderID)
            playback.play(track,
                          in: siblings.isEmpty ? [track] : siblings,
                          restrictToCategory: false)
        } else {
            playback.play(track, in: [track])
        }
    }
}

/// One discovered item, laid out like a Library row: track name on one line,
/// artist beneath, and — on the trailing edge, in line with the title —
/// icon-only Download/Preview buttons (or a green status icon once acted on).
/// Descriptions deliberately don't show here (the preview modal still surfaces
/// the detail when one exists).
private struct BrowseItemRow: View {
    let item: BrowseItem
    /// In select mode the row hides its action buttons so a tap toggles the
    /// list selection rather than firing Download/Preview.
    var selecting: Bool = false
    /// Whether to show the item's publish date on the right (suppressed for
    /// Discography, whose album header already carries the year).
    var showsDate: Bool = true
    /// Whether the title is an "Artist — Song" pair to split onto two lines
    /// (name over artist, Library-style). Off for feed titles.
    var parsesArtist: Bool = false
    let onDownload: () -> Void
    let onPreview: () -> Void

    /// The track name — the song half of "Artist — Song" when applicable,
    /// otherwise the whole title.
    private var name: String {
        if parsesArtist, let range = item.title.range(of: " — ") {
            return String(item.title[range.upperBound...])
        }
        return item.title
    }

    /// The artist — the first half of "Artist — Song", when applicable.
    private var artist: String? {
        guard parsesArtist, let range = item.title.range(of: " — ") else { return nil }
        let value = String(item.title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    var body: some View {
        // Library-style: name on one line, artist beneath, and the controls
        // (icon-only Download/Preview, or the acted-on status) on the trailing
        // edge, in line with the title.
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.body)
                    .lineLimit(1)
                if let artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if showsDate, let published = item.datePublished {
                Text(published.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            trailingControls
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var trailingControls: some View {
        switch item.status {
        case .downloaded:
            BrowseTrackStatusButton(sourceURL: item.url,
                                    pendingIcon: "arrow.down.circle.fill",
                                    pendingLabel: "Sent to Downloads",
                                    selecting: selecting)
                .font(.title2)
        case .saved:
            BrowseTrackStatusButton(sourceURL: item.url,
                                    pendingIcon: "checkmark.circle.fill",
                                    pendingLabel: "Saved to Library",
                                    selecting: selecting)
                .font(.title2)
        case .new, .discarded:
            // Hidden while selecting so a row tap toggles the selection.
            if !selecting {
                HStack(spacing: 16) {
                    Button(action: onDownload) {
                        Image(systemName: "arrow.down.circle")
                    }
                    .accessibilityLabel("Download")

                    // Filled once it's been auditioned — the same
                    // already-dealt-with cue the Download action gets, while
                    // the button itself keeps working.
                    Button(action: onPreview) {
                        Image(systemName: item.wasPreviewed ? "play.circle.fill" : "play.circle")
                    }
                    .accessibilityLabel(item.wasPreviewed ? "Preview again" : "Preview")
                }
                .font(.title2)
                .buttonStyle(.borderless)
            }
        }
    }
}

private extension View {
    /// Browse list section headers: primary-coloured and non-uppercased, set
    /// off with a thin underline so they read as clear dividers instead of the
    /// default faint grey. Carries an opaque background (the main list colour)
    /// spanning edge-to-edge, so a header pinned while scrolling doesn't let
    /// the rows show through it.
    func browseSectionHeaderStyle() -> some View {
        self
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .textCase(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .background(Color(.systemBackground))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.primary)
                    .frame(height: 1)
            }
            .listRowInsets(EdgeInsets())
    }
}
