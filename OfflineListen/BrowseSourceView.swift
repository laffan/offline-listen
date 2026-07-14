import SwiftUI

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

    private var source: BrowseSource? {
        browse.sources.first(where: { $0.id == sourceID })
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
                List {
                    if source?.kind == .blogAgent {
                        // Blog Agent lists group tracks under the post they
                        // were found in, newest post first.
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
                .refreshable { await refreshAsync() }
            }
        }
        .navigationTitle(source?.name ?? "Source")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
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
            if let date = group.date {
                Text(date.formatted(date: .abbreviated, time: .omitted))
                    .foregroundStyle(.secondary)
            }
        }
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
        downloads.enqueue(urlString: item.url, mode: browse.downloadMode)
        browse.markDownloaded(item)
    }
}

/// One discovered item: artist/song title, publish date, and the Download /
/// Preview buttons (replaced by a status line once acted on). Descriptions
/// deliberately don't show here — the row stays a compact artist + title line
/// (the preview modal still surfaces the detail when one exists).
private struct BrowseItemRow: View {
    let item: BrowseItem
    let onDownload: () -> Void
    let onPreview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)

            HStack(spacing: 12) {
                statusOrActions
                Spacer()
                if let published = item.datePublished {
                    Text(published.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
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
