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

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                inputCard

                if downloads.jobs.isEmpty {
                    ContentUnavailableViewCompat(
                        title: "No downloads yet",
                        systemImage: "arrow.down.circle",
                        description: "Paste a video or playlist URL above to start downloading. A playlist downloads into its own folder."
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
        }
    }

    private var inputCard: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("Paste video URL", text: $urlText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .focused($urlFieldFocused)
                    .submitLabel(.go)
                    .onSubmit(startDownload)

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

                Button(action: startDownload) {
                    Label("Download", systemImage: "arrow.down")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal)
    }

    private func startDownload() {
        let text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        downloads.enqueueLinks(from: urlText, mode: mode)
        urlText = ""
        urlFieldFocused = false
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
