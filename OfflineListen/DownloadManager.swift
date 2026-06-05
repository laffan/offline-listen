import Foundation

/// One item in the download queue. An `ObservableObject` so each row updates
/// independently as its state/progress changes.
@MainActor
final class DownloadJob: ObservableObject, Identifiable {
    let id = UUID()
    let url: String
    let format: AudioFormat

    @Published var title: String
    @Published var state: State
    @Published var progress: Double = 0

    init(url: String, format: AudioFormat) {
        self.url = url
        self.format = format
        self.title = url
        self.state = .queued
    }

    enum State: Equatable {
        case queued
        case extracting
        case downloading
        case converting
        case finished
        case failed(String)

        var label: String {
            switch self {
            case .queued: return "Queued"
            case .extracting: return "Preparing…"
            case .downloading: return "Downloading"
            case .converting: return "Saving"
            case .finished: return "Done"
            case .failed(let message): return "Failed: \(message)"
            }
        }

        var isActive: Bool {
            switch self {
            case .extracting, .downloading, .converting: return true
            default: return false
            }
        }
    }
}

/// Owns the download queue and runs jobs one at a time:
/// URL → extract audio (yt-dlp) → convert/save → add to library.
@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var jobs: [DownloadJob] = []

    private let library: LibraryStore
    private let extractor: YouTubeAudioExtractor
    private var isProcessing = false

    init(library: LibraryStore, extractor: YouTubeAudioExtractor = YoutubeDLExtractor()) {
        self.library = library
        self.extractor = extractor
    }

    /// Adds a URL to the queue. Newest jobs show at the top; processing is FIFO.
    func enqueue(urlString: String, format: AudioFormat) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let job = DownloadJob(url: trimmed, format: format)
        if URL(string: trimmed) == nil || !trimmed.lowercased().hasPrefix("http") {
            job.state = .failed(ExtractorError.invalidURL.localizedDescription)
            jobs.insert(job, at: 0)
            return
        }
        jobs.insert(job, at: 0)
        Task { await processNext() }
    }

    func clearFinished() {
        jobs.removeAll { job in
            if case .finished = job.state { return true }
            if case .failed = job.state { return true }
            return false
        }
    }

    private func processNext() async {
        guard !isProcessing else { return }
        // Oldest queued job first (jobs are inserted at the front for display).
        guard let job = jobs.last(where: { $0.state == .queued }) else { return }

        isProcessing = true
        await run(job)
        isProcessing = false

        await processNext()
    }

    private func run(_ job: DownloadJob) async {
        guard let url = URL(string: job.url) else {
            job.state = .failed(ExtractorError.invalidURL.localizedDescription)
            return
        }

        do {
            job.state = .extracting
            let extracted = try await extractor.extractAudio(from: url) { fraction in
                Task { @MainActor in
                    if job.state == .extracting || job.state == .downloading {
                        job.state = .downloading
                        job.progress = fraction
                    }
                }
            }

            job.state = .converting
            job.title = extracted.title

            let destinationName = "\(UUID().uuidString).\(job.format.fileExtension)"
            let finalURL = try AudioConverter.process(
                input: extracted.fileURL,
                to: job.format,
                destinationName: destinationName
            )

            let track = Track(
                title: extracted.title,
                fileName: finalURL.lastPathComponent,
                sourceURL: job.url,
                duration: extracted.duration
            )
            library.add(track)
            job.state = .finished
        } catch {
            job.state = .failed(error.localizedDescription)
        }
    }
}
