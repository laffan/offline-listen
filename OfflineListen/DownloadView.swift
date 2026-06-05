import SwiftUI

struct DownloadView: View {
    @EnvironmentObject private var downloads: DownloadManager

    @State private var urlText = ""
    @State private var format: AudioFormat = .m4a
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
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .padding(.top)
            .navigationTitle("Download")
            .toolbar {
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

                if !urlText.isEmpty {
                    Button {
                        urlText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))

            HStack {
                Picker("Format", selection: $format) {
                    ForEach(AudioFormat.allCases) { fmt in
                        Text(fmt.displayName).tag(fmt)
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
        downloads.enqueue(urlString: text, format: format)
        urlText = ""
        urlFieldFocused = false
    }
}

private struct DownloadJobRow: View {
    @ObservedObject var job: DownloadJob

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
            }

            if job.state == .downloading {
                ProgressView(value: job.progress)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.state {
        case .finished:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
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
