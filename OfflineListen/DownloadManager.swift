import Foundation

/// One item in the download queue. An `ObservableObject` so each row updates
/// independently as its state/progress changes.
@MainActor
final class DownloadJob: ObservableObject, Identifiable {
    let id = UUID()
    let url: String
    let mode: DownloadMode
    /// When true this job doesn't download a file: it resolves a playlist URL
    /// into a folder and enqueues one child job per entry.
    let isPlaylist: Bool
    /// The folder a finished track should be filed into, or nil for the main
    /// library list. Set on the child jobs a playlist expands into.
    let folderID: UUID?

    @Published var title: String
    @Published var state: State
    @Published var progress: Double = 0
    /// The library track produced by this job, once finished (for tap-to-play).
    @Published var trackID: UUID?

    init(url: String, mode: DownloadMode, isPlaylist: Bool = false, folderID: UUID? = nil) {
        self.url = url
        self.mode = mode
        self.isPlaylist = isPlaylist
        self.folderID = folderID
        self.title = isPlaylist ? "Playlist" : url
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

/// A resolved playlist awaiting the user's pick of which entries to download.
/// Presented as a popup via `.sheet(item:)`; `decide` delivers the chosen
/// entries back to the waiting download job (nil/empty means cancel).
struct PendingPlaylist: Identifiable {
    let id = UUID()
    /// The playlist job this selection belongs to (so a cancel can match it up).
    let jobID: UUID
    let title: String
    let entries: [PlaylistEntry]
    let mode: DownloadMode
    let decide: ([PlaylistEntry]?) -> Void
}

/// Thread-safe one-shot bridge between the playlist popup and the suspended
/// download job: whichever of the popup's answer or the job's cancellation
/// arrives first resumes the continuation; later calls are ignored.
final class PlaylistDecisionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[PlaylistEntry]?, Never>?
    private var resumed = false
    private var pending: [PlaylistEntry]??

    func attach(_ continuation: CheckedContinuation<[PlaylistEntry]?, Never>) {
        lock.lock(); defer { lock.unlock() }
        if resumed { return }
        if let pending {
            resumed = true
            continuation.resume(returning: pending)
        } else {
            self.continuation = continuation
        }
    }

    func resume(_ value: [PlaylistEntry]?) {
        lock.lock(); defer { lock.unlock() }
        guard !resumed else { return }
        if let continuation {
            resumed = true
            continuation.resume(returning: value)
            self.continuation = nil
        } else {
            // Answer arrived before `attach`; hand it over when attach runs.
            pending = .some(value)
        }
    }
}

/// Owns the download queue and runs jobs one at a time:
/// URL → extract audio (yt-dlp) → convert/save → add to library.
@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var jobs: [DownloadJob] = []
    /// A resolved playlist waiting for the user to choose entries (drives the
    /// selection popup). Settable so the popup binding can clear it on dismiss.
    @Published var pendingPlaylist: PendingPlaylist?

    private let library: LibraryStore
    private let extractor: MediaExtractor
    /// Optional AI organizer; when present and the user has opted in, finished
    /// downloads are classified/cleaned automatically.
    private let aiOrganizer: AIOrganizer?
    private var isProcessing = false

    /// The job currently being processed and the task running it, so an active
    /// download can be cancelled.
    private var activeJob: DownloadJob?
    private var activeTask: Task<Void, Never>?

    init(library: LibraryStore,
         aiOrganizer: AIOrganizer? = nil,
         extractor: MediaExtractor = CompositeExtractor(
            primary: YouTubeKitExtractor(), named: "YouTubeKit",
            fallback: YoutubeDLExtractor(), named: "yt-dlp")) {
        self.library = library
        self.aiOrganizer = aiOrganizer
        self.extractor = extractor
    }

    /// Enqueues every downloadable link found in `text`, treating whitespace/
    /// newlines as separators (URLs contain no spaces). Anything that isn't an
    /// http(s) URL is skipped, so pasting a blob of prose only queues the links.
    /// We accept *any* site (not just YouTube) and let yt-dlp decide — it
    /// supports Vimeo, SoundCloud and ~hundreds of others.
    func enqueueLinks(from text: String, mode: DownloadMode) {
        let tokens = text.split(whereSeparator: { $0.isWhitespace })
        var added = 0
        var skipped = 0
        for token in tokens {
            let link = String(token)
            if Self.isQueueableURL(link) {
                if PlaylistURL.isPlaylistURL(link) {
                    enqueuePlaylist(urlString: link, mode: mode)
                } else {
                    enqueue(urlString: link, mode: mode)
                }
                added += 1
            } else {
                skipped += 1
            }
        }
        if skipped > 0 {
            appLog("Skipped \(skipped) non-URL token(s).", level: .warning, category: "Queue")
        }
        if added == 0 {
            appLog("No links found in input.", level: .warning, category: "Queue")
        }
    }

    /// Any well-formed http(s) URL with a host is queueable; yt-dlp handles the
    /// site detection. (We don't gate on a host allowlist — yt-dlp's reach is
    /// far wider than anything we'd hard-code.)
    static func isQueueableURL(_ string: String) -> Bool {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && (url.host?.isEmpty == false)
    }

    static func isYouTubeURL(_ string: String) -> Bool {
        guard let url = URL(string: string), let host = url.host?.lowercased() else { return false }
        return host == "youtu.be"
            || host.hasSuffix("youtube.com")
            || host.hasSuffix("youtube-nocookie.com")
    }

    /// Adds a URL to the queue. Newest jobs show at the top; processing is FIFO.
    /// A `folderID` files the finished track into that folder (used for the child
    /// jobs a playlist expands into).
    func enqueue(urlString: String, mode: DownloadMode, folderID: UUID? = nil) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let job = DownloadJob(url: trimmed, mode: mode, folderID: folderID)
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

    /// Adds a playlist URL to the queue. The job runs in the serial queue (so its
    /// yt-dlp resolution never overlaps another download's extraction), creates a
    /// folder named after the playlist, and enqueues one download per entry.
    func enqueuePlaylist(urlString: String, mode: DownloadMode) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let job = DownloadJob(url: trimmed, mode: mode, isPlaylist: true)
        jobs.insert(job, at: 0)
        appLog("Queued playlist: \(trimmed)", category: "Queue")
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
        let wasPlaylist = job.isPlaylist
        remove(job)
        appLog("Restarting: \(url)", category: "Queue")
        if wasPlaylist {
            enqueuePlaylist(urlString: url, mode: mode)
        } else {
            enqueue(urlString: url, mode: mode)
        }
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

        if job.isPlaylist {
            await runPlaylist(job, url: url)
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

            // Capture chapter markers (best-effort) — from the extractor if it
            // provided them, otherwise via a metadata-only yt-dlp lookup.
            var chapters = extracted.chapters
            if chapters.isEmpty {
                chapters = await ChapterFetcher.fetch(url: url)
            }

            let track = Track(
                title: extracted.title,
                fileName: finalURL.lastPathComponent,
                sourceURL: job.url,
                duration: extracted.duration,
                isVideo: extracted.isVideo,
                folderID: job.folderID,
                chapters: chapters
            )
            library.add(track)
            job.trackID = track.id
            job.state = .finished
            appLog("Added to library: \"\(track.title)\" (\(track.duration.asPlaybackTime))",
                   level: .success, category: "Queue")

            // Best-effort AI organization (music/podcast + clean metadata), only
            // when the user has set up and opted into AI assist. Runs detached so
            // it never holds up the queue.
            if let aiOrganizer {
                let id = track.id
                Task { await aiOrganizer.organizeIfEnabled(id) }
            }
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

    /// Expands a playlist job: resolves the entries (running serially in the
    /// queue so its yt-dlp call never overlaps another extraction), asks the user
    /// which entries to download via a selection popup, then creates or reuses a
    /// folder named after the playlist and enqueues one download per chosen entry
    /// filed into that folder. If resolution yields nothing usable, the link
    /// falls back to a single ordinary download.
    private func runPlaylist(_ job: DownloadJob, url: URL) async {
        appLog("Resolving playlist: \(job.url)", category: "Queue")
        job.state = .extracting

        guard let playlist = await PlaylistResolver.resolve(url: url) else {
            // Couldn't resolve as a playlist — treat the link as a single video.
            appLog("Couldn't resolve as a playlist — downloading as a single item.",
                   level: .warning, category: "Queue")
            job.state = .finished
            enqueue(urlString: job.url, mode: job.mode)
            return
        }

        if Task.isCancelled {
            job.state = .cancelled
            return
        }

        job.title = playlist.title

        // Ask the user which entries to grab. Blocks the queue while the popup is
        // open — intentional, since concurrent yt-dlp work risks a crash and the
        // user is right there having just pasted the link.
        let chosen = await requestPlaylistSelection(playlist, mode: job.mode, jobID: job.id)
        if pendingPlaylist?.jobID == job.id { pendingPlaylist = nil }

        guard let chosen, !chosen.isEmpty else {
            job.state = .cancelled
            appLog("Playlist selection cancelled — nothing downloaded.", level: .warning, category: "Queue")
            return
        }

        let folder = folderForPlaylist(named: playlist.title)
        for entry in chosen {
            enqueue(urlString: entry.url, mode: job.mode, folderID: folder.id)
        }
        job.state = .finished
        appLog("Playlist \"\(playlist.title)\" → queued \(chosen.count) of \(playlist.entries.count) download(s) into a folder.",
               level: .success, category: "Queue")
    }

    /// Publishes the resolved playlist for the UI to present as a selection popup
    /// and suspends until the user decides. Returns the chosen entries, or nil
    /// when cancelled (popup dismissed, or the job itself cancelled). The
    /// continuation is resumed exactly once via `PlaylistDecisionBox`, whether the
    /// answer arrives from the popup or from task cancellation.
    private func requestPlaylistSelection(_ playlist: ResolvedPlaylist,
                                          mode: DownloadMode,
                                          jobID: UUID) async -> [PlaylistEntry]? {
        let box = PlaylistDecisionBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<[PlaylistEntry]?, Never>) in
                box.attach(cont)
                pendingPlaylist = PendingPlaylist(
                    jobID: jobID,
                    title: playlist.title,
                    entries: playlist.entries,
                    mode: mode
                ) { decision in box.resume(decision) }
                if Task.isCancelled { box.resume(nil) }
            }
        } onCancel: {
            box.resume(nil)
        }
    }

    /// Returns an existing active folder with this name (so re-downloading a
    /// playlist doesn't spawn duplicates), creating one if none matches.
    private func folderForPlaylist(named name: String) -> Folder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = trimmed.isEmpty ? "Playlist" : trimmed
        if let existing = library.folders.first(where: {
            !$0.isArchived && $0.name.localizedCaseInsensitiveCompare(wanted) == .orderedSame
        }) {
            return existing
        }
        return library.createFolder(named: wanted) ?? Folder(name: wanted)
    }
}
