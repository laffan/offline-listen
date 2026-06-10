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
                        description: "Paste a video URL above to start downloading audio."
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
