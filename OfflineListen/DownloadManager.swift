import Foundation

/// One item in the download queue. An `ObservableObject` so each row updates
/// independently as its state/progress changes.
@MainActor
final class DownloadJob: ObservableObject, Identifiable {
    let id = UUID()
    let url: String
    let mode: DownloadMode

    @Published var title: String
    @Published var state: State
    @Published var progress: Double = 0
    /// The library track produced by this job, once finished (for tap-to-play).
    @Published var trackID: UUID?

    init(url: String, mode: DownloadMode) {
        self.url = url
        self.mode = mode
        self.title = url
        self.state = .queued
    }

    enum State: Equatable {
        case queued
        case extracting
        case downloading
        case converting
        case finished
        case cancelled
        case failed(String)

        var label: String {
            switch self {
            case .queued: return "Queued"
            case .extracting: return "Preparing…"
            case .downloading: return "Downloading"
            case .converting: return "Saving"
            case .finished: return "Done"
            case .cancelled: return "Cancelled"
            case .failed(let message): return "Failed: \(message)"
            }
        }

        var isActive: Bool {
            switch self {
            case .extracting, .downloading, .converting: return true
            default: return false
            }
        }

        /// True once the job has stopped for any reason (won't run again on its own).
        var isFinishedOrStopped: Bool {
            switch self {
            case .finished, .cancelled, .failed: return true
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
    private let extractor: MediaExtractor
    private var isProcessing = false

    /// The job currently being processed and the task running it, so an active
    /// download can be cancelled.
    private var activeJob: DownloadJob?
    private var activeTask: Task<Void, Never>?

    init(library: LibraryStore,
         extractor: MediaExtractor = CompositeExtractor(
            primary: YouTubeKitExtractor(), named: "YouTubeKit",
            fallback: YoutubeDLExtractor(), named: "yt-dlp")) {
        self.library = library
        self.extractor = extractor
    }

    /// Enqueues every YouTube link found in `text`, treating whitespace/newlines
    /// as separators (URLs contain no spaces). Non-YouTube links are skipped.
    func enqueueLinks(from text: String, mode: DownloadMode) {
        let tokens = text.split(whereSeparator: { $0.isWhitespace })
        var added = 0
        var skipped = 0
        for token in tokens {
            let link = String(token)
            if Self.isYouTubeURL(link) {
                enqueue(urlString: link, mode: mode)
                added += 1
            } else {
                skipped += 1
            }
        }
        if skipped > 0 {
            appLog("Skipped \(skipped) non-YouTube link(s).", level: .warning, category: "Queue")
        }
        if added == 0 {
            appLog("No YouTube links found in input.", level: .warning, category: "Queue")
        }
    }

    static func isYouTubeURL(_ string: String) -> Bool {
        guard let url = URL(string: string), let host = url.host?.lowercased() else { return false }
        return host == "youtu.be"
            || host.hasSuffix("youtube.com")
            || host.hasSuffix("youtube-nocookie.com")
    }

    /// Adds a URL to the queue. Newest jobs show at the top; processing is FIFO.
    func enqueue(urlString: String, mode: DownloadMode) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let job = DownloadJob(url: trimmed, mode: mode)
        if URL(string: trimmed) == nil || !trimmed.lowercased().hasPrefix("http") {
            job.state = .failed(ExtractorError.invalidURL.localizedDescription)
            jobs.insert(job, at: 0)
            appLog("Rejected invalid URL: \(trimmed)", level: .error, category: "Queue")
            return
        }
        jobs.insert(job, at: 0)
        appLog("Queued \(job.mode.displayName) download: \(trimmed)", category: "Queue")
        Task { await processNext() }
    }

    func clearFinished() {
        jobs.removeAll { $0.state.isFinishedOrStopped }
    }

    /// Stops a job. An active download is cancelled mid-flight; a queued job is
    /// marked cancelled so it's skipped.
    func cancel(_ job: DownloadJob) {
        if job.id == activeJob?.id {
            appLog("Cancelling: \(job.url)", level: .warning, category: "Queue")
            activeTask?.cancel()
        } else if job.state == .queued {
            job.state = .cancelled
            appLog("Cancelled queued: \(job.url)", level: .warning, category: "Queue")
        }
    }

    /// Removes a job from the queue list (cancelling it first if it's running).
    func remove(_ job: DownloadJob) {
        if job.id == activeJob?.id {
            activeTask?.cancel()
        }
        jobs.removeAll { $0.id == job.id }
    }

    /// Re-runs a job by removing it and enqueuing a fresh attempt for the same URL.
    func restart(_ job: DownloadJob) {
        let url = job.url
        let mode = job.mode
        remove(job)
        appLog("Restarting: \(url)", category: "Queue")
        enqueue(urlString: url, mode: mode)
    }

    private func processNext() async {
        guard !isProcessing else { return }
        // Oldest queued job first (jobs are inserted at the front for display).
        guard let job = jobs.last(where: { $0.state == .queued }) else { return }

        isProcessing = true
        activeJob = job
        let task = Task { await run(job) }
        activeTask = task
        await task.value
        activeTask = nil
        activeJob = nil
        isProcessing = false

        await processNext()
    }

    private func run(_ job: DownloadJob) async {
        guard let url = URL(string: job.url) else {
            job.state = .failed(ExtractorError.invalidURL.localizedDescription)
            return
        }

        do {
            appLog("Processing: \(job.url)", category: "Queue")
            job.state = .extracting
            let extracted = try await extractor.extractMedia(
                from: url,
                mode: job.mode,
                onDownloadStart: {
                    Task { @MainActor in job.state = .downloading }
                },
                onProgress: { fraction in
                    Task { @MainActor in job.progress = fraction }
                }
            )

            job.state = .converting
            job.title = extracted.title

            // Move the downloaded file into the library under a title-based name,
            // keeping its real extension (m4a for audio, mp4 for video).
            let ext = extracted.fileURL.pathExtension.isEmpty ? (extracted.isVideo ? "mp4" : "m4a") : extracted.fileURL.pathExtension
            let destinationName = AppPaths.uniqueDocumentName(
                base: extracted.title.sanitizedFileName(),
                ext: ext
            )
            let finalURL = AppPaths.documents.appendingPathComponent(destinationName)
            try? FileManager.default.removeItem(at: finalURL)
            try FileManager.default.moveItem(at: extracted.fileURL, to: finalURL)
            appLog("Saved \(finalURL.lastPathComponent)", level: .success, category: "Queue")

            let track = Track(
                title: extracted.title,
                fileName: finalURL.lastPathComponent,
                sourceURL: job.url,
                duration: extracted.duration,
                isVideo: extracted.isVideo
            )
            library.add(track)
            job.trackID = track.id
            job.state = .finished
            appLog("Added to library: \"\(track.title)\" (\(track.duration.asPlaybackTime))",
                   level: .success, category: "Queue")
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                job.state = .cancelled
                appLog("Cancelled: \(job.url)", level: .warning, category: "Queue")
            } else {
                job.state = .failed(error.localizedDescription)
                appLog("Job failed: \(error.localizedDescription)", level: .error, category: "Queue")
            }
        }
    }
}
