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

    private var source: BrowseSource? {
        browse.sources.first(where: { $0.id == sourceID })
    }

    /// Blog Agent and Discography lists are grouped into sections (by post and
    /// by album, respectively); the rest are a single flat list.
    private var grouped: Bool { source?.kind.groupsItems ?? false }
    private var isDiscography: Bool { source?.kind == .discography }

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
        Group {
            if items.isEmpty {
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
                    if grouped {
                        // Blog Agent groups tracks under the post they were
                        // found in (newest post first); Discography groups them
                        // by album with a Highlights section pinned on top.
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
                }
                .listStyle(.plain)
                .environment(\.editMode, $editMode)
                .refreshable { await refreshAsync() }
            }
        }
        .navigationTitle(source?.name ?? "Source")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
        .sheet(item: $previewItem) { item in
            BrowsePreviewView(item: item, mode: browse.downloadMode)
        }
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
            onPreview: { previewItem = item }
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                browse.markDiscarded(item)
            } label: {
                Label("Discard", systemImage: "xmark.bin")
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
    private func header(count: Int) -> some View {
        HStack {
            Text("\(count) item(s)")
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

    /// Queues every selected item that hasn't been dealt with yet (still-new
    /// rows — the ones that would show a Download button), then leaves select
    /// mode. Already-downloaded/saved picks are skipped, mirroring the per-row
    /// behaviour where their button is gone.
    ///
    /// The status change is applied in one batch (`markDownloaded(_:)`) — a
    /// single save and a single published mutation — before select mode is torn
    /// down, mirroring the Library's bulk-action order. The per-item mark would
    /// otherwise rewrite `browse.json` once per pick, stalling the main thread
    /// on a big selection (a whole discography), which is what crashed the app.
    private func downloadSelected() {
        let picks = browse.visibleItems(for: sourceID)
            .filter { selection.contains($0.id) && $0.status == .new }
        guard !picks.isEmpty else {
            selection.removeAll()
            withAnimation { editMode = .inactive }
            return
        }
        for item in picks {
            enqueue(item)
        }
        browse.markDownloaded(picks)
        selection.removeAll()
        withAnimation { editMode = .inactive }
    }
}

/// One discovered item: artist/song title, publish date, and the Download /
/// Preview buttons (replaced by a status line once acted on). Descriptions
/// deliberately don't show here — the row stays a compact artist + title line
/// (the preview modal still surfaces the detail when one exists).
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
        VStack(alignment: .leading, spacing: 6) {
            // Library-style: name on one line, artist beneath, date/metadata on
            // the right.
            HStack(alignment: .firstTextBaseline, spacing: 12) {
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
            }

            statusOrActions
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusOrActions: some View {
        switch item.status {
        case .downloaded:
            Label("Sent to Downloads", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .saved:
            Label("Saved to Library", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .new, .discarded:
            if !selecting {
                HStack(spacing: 10) {
                    Button(action: onDownload) {
                        Label("Download", systemImage: "arrow.down")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(action: onPreview) {
                        Label("Preview", systemImage: "play.circle")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
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
