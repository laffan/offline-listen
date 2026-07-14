import SwiftUI
import UIKit

struct DownloadView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager

    /// Switches to the player tab after starting playback.
    let onPlay: () -> Void

    @State private var urlText = ""
    @State private var mode: DownloadMode = .audio
    @FocusState private var urlFieldFocused: Bool

    /// True while a YouTube search is in flight (spinner on the button).
    @State private var searching = false
    /// The finished search awaiting a pick (drives the results modal).
    @State private var searchResults: DownloadSearchResults?
    /// A query that came back empty (drives the failure alert).
    @State private var failedQuery: String?

    /// The input reads as a search term when it's non-empty and contains no
    /// downloadable link — then the button flips from Download to Search.
    private var isSearch: Bool {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !trimmed.split(whereSeparator: { $0.isWhitespace })
            .contains { DownloadManager.isQueueableURL(String($0)) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                inputCard

                if downloads.jobs.isEmpty {
                    ContentUnavailableViewCompat(
                        title: "No downloads yet",
                        systemImage: "arrow.down.circle",
                        description: "Paste a video or playlist URL above to start downloading, or type anything else to search YouTube. A playlist downloads into its own folder."
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    List {
                        ForEach(downloads.jobs) { job in
                            DownloadJobRow(job: job)
                                .contentShape(Rectangle())
                                .onTapGesture { playFinished(job) }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .padding(.top)
            .navigationTitle("Download")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button {
                            Task { await YoutubeDLExtractor.refreshEngine() }
                        } label: {
                            Label("Refresh yt-dlp engine", systemImage: "arrow.triangle.2.circlepath")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Clear") { downloads.clearFinished() }
                        .disabled(downloads.jobs.isEmpty)
                }
            }
            .sheet(item: $downloads.pendingPlaylist) { pending in
                PlaylistPickerView(pending: pending)
            }
            .sheet(item: $searchResults) { search in
                SearchResultsView(search: search, mode: mode)
            }
            .alert("No results",
                   isPresented: Binding(get: { failedQuery != nil },
                                        set: { if !$0 { failedQuery = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Nothing came back for “\(failedQuery ?? "")”. Check the connection or try different words.")
            }
        }
    }

    private var inputCard: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("Paste a URL or search YouTube", text: $urlText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.webSearch)
                    .focused($urlFieldFocused)
                    .submitLabel(isSearch ? .search : .go)
                    .onSubmit(submit)

                if urlText.isEmpty {
                    Button {
                        if let pasted = UIPasteboard.general.string {
                            urlText = pasted
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Paste")
                } else {
                    Button {
                        urlText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Clear")
                }
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))

            HStack {
                Picker("Mode", selection: $mode) {
                    ForEach(DownloadMode.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 160)

                Spacer()

                Button(action: submit) {
                    if searching {
                        ProgressView()
                            .controlSize(.small)
                            .frame(minWidth: 90)
                    } else {
                        Label(isSearch ? "Search" : "Download",
                              systemImage: isSearch ? "magnifyingglass" : "arrow.down")
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty || searching)
            }
        }
        .padding(.horizontal)
    }

    /// URLs download; anything else searches YouTube.
    private func submit() {
        let text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if isSearch {
            search(for: text)
        } else {
            downloads.enqueueLinks(from: urlText, mode: mode)
            urlText = ""
            urlFieldFocused = false
        }
    }

    /// Fetches the top YouTube results for the term and presents them in the
    /// pick-a-result modal. The query stays in the field so a miss is easy to
    /// refine.
    private func search(for query: String) {
        guard !searching else { return }
        searching = true
        urlFieldFocused = false
        appLog("Searching YouTube for \"\(query)\"…", category: "Queue")
        Task { @MainActor in
            let results = await YouTubeSearchResolver.topVideos(matching: query, limit: 5)
            searching = false
            if results.isEmpty {
                failedQuery = query
                appLog("Search returned no results for \"\(query)\".", level: .warning, category: "Queue")
            } else {
                searchResults = DownloadSearchResults(query: query, results: results)
                appLog("Search found \(results.count) result(s) for \"\(query)\".",
                       level: .success, category: "Queue")
            }
        }
    }

    /// Tapping a finished download plays it and switches to the player.
    private func playFinished(_ job: DownloadJob) {
        guard job.state == .finished,
              let id = job.trackID,
              let track = library.tracks.first(where: { $0.id == id }) else { return }
        playback.play(track, in: library.activeTracks)
        onPlay()
    }
}

private struct DownloadJobRow: View {
    @EnvironmentObject private var downloads: DownloadManager
    @ObservedObject var job: DownloadJob

    private var isActiveOrQueued: Bool {
        job.state.isActive || job.state == .queued
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.title)
                .font(.subheadline)
                .lineLimit(1)

            HStack(spacing: 8) {
                statusIcon
                Text(job.state.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if job.state == .downloading, job.progress > 0 {
                    Spacer()
                    Text("\(Int(job.progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if job.state == .downloading, job.progress > 0 {
                ProgressView(value: job.progress)
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if isActiveOrQueued {
                Button(role: .destructive) {
                    downloads.cancel(job)
                } label: {
                    Label("Cancel", systemImage: "stop.circle")
                }
            } else {
                Button(role: .destructive) {
                    downloads.remove(job)
                } label: {
                    Label("Clear", systemImage: "trash")
                }
            }

            Button {
                downloads.restart(job)
            } label: {
                Label("Restart", systemImage: "arrow.clockwise")
            }
            .tint(.blue)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.state {
        case .finished:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled:
            Image(systemName: "stop.circle").foregroundStyle(.secondary)
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary)
        default:
            ProgressView().controlSize(.mini)
        }
    }
}

/// The popup shown after a playlist link resolves: lists its entries with
/// checkmarks (all selected by default), a Select-All toggle, and a Download
/// button that queues the chosen entries into a folder. Cancelling — or
/// dismissing the sheet — downloads nothing. The decision is delivered back to
/// the waiting download job via `pending.decide`.
struct PlaylistPickerView: View {
    let pending: PendingPlaylist

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<PlaylistEntry.ID>
    /// Guards against `decide` being called twice (e.g. a button tap followed by
    /// the sheet's `onDisappear`); the download side is idempotent too.
    @State private var decided = false

    init(pending: PendingPlaylist) {
        self.pending = pending
        // Everything selected by default — "grab the whole list" is one tap.
        _selected = State(initialValue: Set(pending.entries.map(\.id)))
    }

    private var allSelected: Bool { selected.count == pending.entries.count }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(pending.entries) { entry in
                        Button {
                            toggle(entry.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selected.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(entry.id) ? Color.accentColor : .secondary)
                                Text(entry.title)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        Text("\(pending.entries.count) items · \(pending.mode.displayName)")
                        Spacer()
                        Button(allSelected ? "Deselect All" : "Select All") {
                            selected = allSelected ? [] : Set(pending.entries.map(\.id))
                        }
                        .font(.caption.weight(.semibold))
                        .textCase(nil)
                    }
                }
            }
            .navigationTitle(pending.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { finish(nil) }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Download (\(selected.count))") {
                        let chosen = pending.entries.filter { selected.contains($0.id) }
                        finish(chosen)
                    }
                    .fontWeight(.semibold)
                    .disabled(selected.isEmpty)
                }
            }
            .onDisappear { finish(nil) }
        }
    }

    private func toggle(_ id: PlaylistEntry.ID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func finish(_ entries: [PlaylistEntry]?) {
        guard !decided else { return }
        decided = true
        pending.decide(entries)
        dismiss()
    }
}

/// A finished Download-tab search: the query plus its top YouTube results,
/// presented as a pick-a-result modal via `.sheet(item:)`.
struct DownloadSearchResults: Identifiable {
    let id = UUID()
    let query: String
    let results: [YouTubeSearchResult]
}

/// The search-results modal: the top YouTube hits for the typed term, each row
/// styled like a Browse item — title, channel, and **Download** / **Preview**.
/// Download queues the video in the tab's current mode; Preview opens the same
/// listen-first modal Browse uses (Save files it into the library).
private struct SearchResultsView: View {
    let search: DownloadSearchResults
    let mode: DownloadMode

    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss

    /// The result being previewed (drives the nested preview modal).
    @State private var previewItem: BrowseItem?
    /// Results already sent to the queue (their row shows a status instead).
    @State private var sent: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(search.results) { result in
                        SearchResultRow(result: result,
                                        sent: sent.contains(result.videoID),
                                        onDownload: { download(result) },
                                        onPreview: { previewItem = browseItem(for: result) })
                    }
                } header: {
                    Text("Top \(search.results.count) result(s) · \(mode.displayName)")
                }
            }
            .listStyle(.plain)
            .navigationTitle("“\(search.query)”")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(item: $previewItem) { item in
            BrowsePreviewView(item: item)
        }
    }

    private func download(_ result: YouTubeSearchResult) {
        downloads.enqueue(urlString: result.url, mode: mode)
        sent.insert(result.videoID)
    }

    /// Wraps a search result as a transient `BrowseItem` so the shared preview
    /// modal can play it. The item lives nowhere in the Browse store — its
    /// save/discard bookkeeping there is a harmless no-op.
    private func browseItem(for result: YouTubeSearchResult) -> BrowseItem {
        BrowseItem(sourceID: UUID(),
                   title: result.title,
                   detail: result.channel,
                   url: result.url,
                   videoID: result.videoID)
    }
}

/// One search hit: title, channel, and the same Download/Preview button pair
/// a Browse row carries.
private struct SearchResultRow: View {
    let result: YouTubeSearchResult
    let sent: Bool
    let onDownload: () -> Void
    let onPreview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(result.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)

            if !result.channel.isEmpty {
                Text(result.channel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if sent {
                Label("Sent to Downloads", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
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
        .padding(.vertical, 4)
    }
}

/// Lightweight stand-in for `ContentUnavailableView` to keep the iOS 16 floor.
struct ContentUnavailableViewCompat: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}
