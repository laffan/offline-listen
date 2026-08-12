import Foundation

/// One item in the download queue. An `ObservableObject` so each row updates
/// independently as its state/progress changes.
@MainActor
final class DownloadJob: ObservableObject, Identifiable {
    let id = UUID()
    let url: String
    let mode: DownloadMode
    /// When true this job doesn't download a file: it resolves a playlist URL
    /// (or a Spotify reference) into a folder and enqueues one child job per
    /// entry.
    let isPlaylist: Bool
    /// The Spotify reference this job resolves, when the queued token was a
    /// Spotify link or URI. Set on live jobs only — a restored history row
    /// re-parses its URL if it's restarted.
    let spotifyRef: SpotifyRef?
    /// The folder a finished track should be filed into, or nil for the main
    /// library list. Set on the child jobs a playlist expands into.
    let folderID: UUID?
    /// Album-art URL to fetch (best-effort) once the track lands — carried by
    /// Spotify-sourced enqueues, where the album cover is known up front.
    let artworkURL: String?
    /// The library track this download **replaces** once it lands — set by
    /// the Library's Convert to Video/Audio, which re-downloads a track's
    /// source in the other format. Replacement happens only on success, so a
    /// failed conversion never costs the original.
    let replacesTrackID: UUID?
    /// Track metadata already known when the job was queued. A discography
    /// download knows the release's real song title and artist from Spotify,
    /// so the finished track can read properly straight away instead of
    /// wearing a YouTube video title until the AI gets to it — or for good,
    /// when there's no Anthropic key to do the cleaning.
    let knownTitle: String?
    let knownArtist: String?

    @Published var title: String
    /// A live sub-status shown in place of the state label while a long
    /// resolution runs ("Resolving 42 of 137…"), so a big playlist doesn't
    /// look hung. Nil for every other job.
    @Published var progressNote: String?
    /// The artist, once known — snapshotted from the finished track so restored
    /// history still reads right if the track is later deleted. The live row
    /// prefers the library track's current artist while it exists.
    @Published var artist: String? = nil
    @Published var state: State
    @Published var progress: Double = 0
    /// The library track produced by this job, once finished (for tap-to-play).
    @Published var trackID: UUID?

    init(url: String, mode: DownloadMode, isPlaylist: Bool = false,
         spotifyRef: SpotifyRef? = nil, folderID: UUID? = nil,
         artworkURL: String? = nil, replacesTrackID: UUID? = nil,
         knownTitle: String? = nil, knownArtist: String? = nil) {
        self.url = url
        self.mode = mode
        self.isPlaylist = isPlaylist
        self.spotifyRef = spotifyRef
        self.folderID = folderID
        self.artworkURL = artworkURL
        self.replacesTrackID = replacesTrackID
        self.knownTitle = Self.cleaned(knownTitle)
        self.knownArtist = Self.cleaned(knownArtist)
        if let spotifyRef {
            self.title = DownloadJob.spotifyPlaceholder(for: spotifyRef)
        } else {
            self.title = isPlaylist ? "Playlist" : url
        }
        self.state = .queued
    }

    /// Blank-or-whitespace metadata is the same as none — a caller that has
    /// only half a pair (the YouTube-ranked Top 10 carries song titles but no
    /// artist) shouldn't have empty strings written over the real thing.
    private static func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// What the queue row reads while a Spotify reference is being resolved —
    /// replaced by the track's or collection's real name as soon as the
    /// metadata lands.
    private static func spotifyPlaceholder(for ref: SpotifyRef) -> String {
        switch ref {
        case .direct(let kind, _): return "Spotify \(kind.rawValue)"
        case .shortLink: return "Spotify link"
        case .unsupported: return "Spotify link"
        }
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

/// A Browse preview waiting its turn in the pipeline: extract-only work whose
/// result goes back to the preview modal instead of the library.
private struct PreviewWork {
    let id: UUID
    let url: URL
    /// Audio (the default) or video — the Browse toggle / Download tab mode.
    let mode: DownloadMode
    /// Preferred video resolution (ignored for audio).
    let quality: VideoQuality
    /// Invoked when the pipeline actually picks the preview up (it may sit
    /// behind an in-flight download first).
    let onBegin: @MainActor () -> Void
    let onDownloadStart: @MainActor () -> Void
    let onProgress: @MainActor (Double) -> Void
    let continuation: CheckedContinuation<ExtractedMedia, Error>
}

/// A persisted snapshot of a completed (finished/failed/cancelled) download, so
/// the Download tab's history survives relaunches. In-flight jobs aren't saved
/// — they didn't finish — so a quit clears only the running queue, never the
/// record of what was downloaded.
private struct DownloadRecord: Codable {
    var url: String
    var modeRaw: String
    var isPlaylist: Bool
    var folderID: UUID?
    var artworkURL: String?
    var title: String
    var artist: String?
    var trackID: UUID?
    /// "finished" | "cancelled" | "failed".
    var stateRaw: String
    var failureMessage: String?
}

/// Owns the download queue and runs up to `maxConcurrent` jobs at once:
/// URL → extract (native / yt-dlp) → convert/save → add to library.
/// Anything that enters the embedded Python interpreter is serialized
/// app-wide through `PythonGate`; the parallelism overlaps the network
/// downloads, never the Python.
@MainActor
final class DownloadManager: ObservableObject {
    /// One track of a release, as `enqueueAlbum` takes them: in the tracklist's
    /// own order, carrying whatever the catalogue already knows about each.
    struct AlbumTrack {
        let url: String
        var title: String? = nil
        var artist: String? = nil
        var artworkURL: String? = nil
    }

    @Published private(set) var jobs: [DownloadJob] = []
    /// A resolved playlist waiting for the user to choose entries (drives the
    /// selection popup). Settable so the popup binding can clear it on dismiss.
    @Published var pendingPlaylist: PendingPlaylist?

    /// Album folder id → source URL → the track's place in the release. An
    /// album's downloads finish in whatever order the network serves them, so
    /// each one is slotted into the folder by this rather than by arrival.
    /// In-memory only, which matches the queue's own lifetime — in-flight jobs
    /// don't survive a quit either.
    private var albumOrders: [UUID: [String: Int]] = [:]

    private let library: LibraryStore
    private let extractor: MediaExtractor
    /// Optional AI organizer; when present and the user has opted in, finished
    /// downloads are classified/cleaned automatically.
    private let aiOrganizer: AIOrganizer?
    /// The Spotify credentials, when configured. Only the Spotify branch reads
    /// them; without it a pasted Spotify link fails pointing at Settings.
    private let spotifySettings: SpotifySettingsStore?

    /// How many downloads may run at once. Every phase that touches the
    /// embedded Python interpreter is serialized app-wide through
    /// `PythonGate`, so this parallelism overlaps the network downloads (and
    /// native YouTubeKit extractions) — concurrent Python never happens.
    static let maxConcurrent = 2

    /// Work currently holding a pipeline slot (jobs and previews alike),
    /// keyed by the job/preview id so a cancel can find its task.
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    /// Job ids among `activeTasks`, so the scheduler never picks a queued job
    /// twice (a job stays `.queued` until its slot's task actually starts).
    private var activeJobIDs: Set<UUID> = []
    /// Occupied slots, published so the preview modal's "waiting for the
    /// queue" state updates live.
    @Published private(set) var activeCount = 0

    /// True while at least one slot is working.
    var isProcessing: Bool { activeCount > 0 }

    /// Browse previews waiting for a pipeline slot. They jump ahead of queued
    /// jobs — a preview has the user actively waiting on it.
    private var previewQueue: [PreviewWork] = []

    /// True when every slot is taken — the preview modal shows a "waiting for
    /// the queue" state off this while its preview sits in line.
    var isPipelineBusy: Bool { activeCount >= Self.maxConcurrent }

    init(library: LibraryStore,
         aiOrganizer: AIOrganizer? = nil,
         spotifySettings: SpotifySettingsStore? = nil,
         // Native extractors first, each claiming only the site it knows
         // (`canHandle`), with yt-dlp behind them for everything else — and as
         // the fallback when a native attempt fails. Vimeo leads because its
         // player config is two plain requests, where the yt-dlp path for the
         // same link means minutes inside the embedded interpreter.
         extractor: MediaExtractor = CompositeExtractor(
            primary: VimeoExtractor(), named: "Vimeo",
            fallback: CompositeExtractor(
                primary: YouTubeKitExtractor(), named: "YouTubeKit",
                fallback: DefaultExtractors.ytDlp, named: "yt-dlp"),
            named: "YouTubeKit/yt-dlp")) {
        self.library = library
        self.aiOrganizer = aiOrganizer
        self.spotifySettings = spotifySettings
        self.extractor = extractor
        loadHistory()
    }

    // MARK: - History persistence

    /// The most recent completed downloads to keep on disk. Generous, but
    /// bounded so the file (and launch decode) can't grow without limit.
    private static let historyLimit = 500

    /// Rebuilds the finished/failed/cancelled jobs from `downloads.json` as
    /// display-only history rows (they're terminal, so `processNext` never
    /// touches them). In-flight jobs were never saved, so nothing resumes.
    private func loadHistory() {
        guard let data = try? Data(contentsOf: AppPaths.downloadsHistory),
              let records = try? JSONDecoder().decode([DownloadRecord].self, from: data) else { return }
        jobs = records.map { record in
            let job = DownloadJob(url: record.url,
                                  mode: DownloadMode(rawValue: record.modeRaw) ?? .audio,
                                  isPlaylist: record.isPlaylist,
                                  folderID: record.folderID,
                                  artworkURL: record.artworkURL)
            job.title = record.title
            job.artist = record.artist
            job.trackID = record.trackID
            switch record.stateRaw {
            case "failed": job.state = .failed(record.failureMessage ?? "Failed")
            case "cancelled": job.state = .cancelled
            default: job.state = .finished
            }
            return job
        }
    }

    /// Writes the finished/failed/cancelled jobs to disk (newest first, capped).
    /// Each record snapshots the live library track's current title/artist when
    /// it still exists (so post-AI metadata is captured), falling back to the
    /// job's own last-known values. Safe to call after any queue change.
    func persistHistory() {
        let records: [DownloadRecord] = jobs.compactMap { job in
            let stateRaw: String
            var failure: String? = nil
            switch job.state {
            case .finished: stateRaw = "finished"
            case .cancelled: stateRaw = "cancelled"
            case .failed(let message): stateRaw = "failed"; failure = message
            default: return nil   // in-flight — not persisted
            }
            let track = job.trackID.flatMap { id in library.tracks.first { $0.id == id } }
            let artist: String?
            if let live = track?.artist, !live.isEmpty, live.lowercased() != "unknown" {
                artist = live
            } else {
                artist = job.artist
            }
            return DownloadRecord(url: job.url,
                                  modeRaw: job.mode.rawValue,
                                  isPlaylist: job.isPlaylist,
                                  folderID: job.folderID,
                                  artworkURL: job.artworkURL,
                                  title: track?.title ?? job.title,
                                  artist: artist,
                                  trackID: job.trackID,
                                  stateRaw: stateRaw,
                                  failureMessage: failure)
        }
        let trimmed = Array(records.prefix(Self.historyLimit))
        do {
            let data = try JSONEncoder().encode(trimmed)
            try data.write(to: AppPaths.downloadsHistory, options: .atomic)
        } catch {
            appLog("Couldn't save download history: \(error.localizedDescription)",
                   level: .warning, category: "Queue")
        }
    }

    /// Enqueues every downloadable link found in `text`, treating whitespace/
    /// newlines as separators (URLs contain no spaces). Anything that isn't an
    /// http(s) URL or a Spotify reference is skipped, so pasting a blob of
    /// prose only queues the links. We accept *any* site (not just YouTube) and
    /// let yt-dlp decide — it supports Vimeo, SoundCloud and ~hundreds of
    /// others.
    func enqueueLinks(from text: String, mode: DownloadMode) {
        let tokens = text.split(whereSeparator: { $0.isWhitespace })
        var added = 0
        var skipped = 0
        for token in tokens {
            let link = String(token)
            // Spotify first: an open.spotify.com link is also a well-formed
            // http(s) URL, and yt-dlp can do nothing with one.
            if let ref = SpotifyRef.parse(link) {
                enqueueSpotify(ref: ref, urlString: link, mode: mode)
                added += 1
            } else if Self.isQueueableURL(link) {
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

    /// Everything the Download field should treat as a *link* rather than a
    /// search term: an http(s) URL, or a Spotify reference (`spotify:track:…`
    /// isn't a URL at all, and `open.spotify.com/…` needs the Spotify branch).
    ///
    /// Deliberately separate from `isQueueableURL`, which stays the narrow
    /// "real http(s) URL" test `enqueue` gates on — a `spotify:` URI reaching
    /// `enqueue` would be rejected as invalid.
    static func isDownloadableToken(_ string: String) -> Bool {
        isQueueableURL(string) || SpotifyRef.parse(string) != nil
    }

    static func isYouTubeURL(_ string: String) -> Bool {
        guard let url = URL(string: string), let host = url.host?.lowercased() else { return false }
        return host == "youtu.be"
            || host.hasSuffix("youtube.com")
            || host.hasSuffix("youtube-nocookie.com")
    }

    /// Adds a URL to the queue. Newest jobs show at the top; processing is FIFO.
    /// A `folderID` files the finished track into that folder (used for the child
    /// jobs a playlist expands into); `replacesTrackID` marks a format
    /// conversion — the named track leaves the library once this lands.
    func enqueue(urlString: String, mode: DownloadMode, folderID: UUID? = nil,
                 artworkURL: String? = nil, replacesTrackID: UUID? = nil,
                 knownTitle: String? = nil, knownArtist: String? = nil) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let job = DownloadJob(url: trimmed, mode: mode, folderID: folderID,
                              artworkURL: artworkURL, replacesTrackID: replacesTrackID,
                              knownTitle: knownTitle, knownArtist: knownArtist)
        if URL(string: trimmed) == nil || !trimmed.lowercased().hasPrefix("http") {
            job.state = .failed(ExtractorError.invalidURL.localizedDescription)
            jobs.insert(job, at: 0)
            appLog("Rejected invalid URL: \(trimmed)", level: .error, category: "Queue")
            return
        }
        jobs.insert(job, at: 0)
        appLog("Queued \(job.mode.displayName) download: \(trimmed)", category: "Queue")
        processNext()
    }

    /// Adds a playlist URL to the queue. The job's yt-dlp resolution is
    /// serialized through `PythonGate` (it never overlaps another extraction);
    /// it creates a folder named after the playlist and enqueues one download
    /// per entry.
    func enqueuePlaylist(urlString: String, mode: DownloadMode) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let job = DownloadJob(url: trimmed, mode: mode, isPlaylist: true)
        jobs.insert(job, at: 0)
        appLog("Queued playlist: \(trimmed)", category: "Queue")
        processNext()
    }

    /// Adds a Spotify reference to the queue. The job resolves Spotify metadata
    /// (plain HTTPS — never the Python gate) and matches each track to a
    /// YouTube video; a single track then enqueues one ordinary download, while
    /// an album/playlist/artist goes through the same selection popup and
    /// folder flow a YouTube playlist does.
    func enqueueSpotify(ref: SpotifyRef, urlString: String, mode: DownloadMode) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        // Collections get the playlist row treatment; a single track expands
        // into exactly one download but is still a resolver job, not a file.
        let job = DownloadJob(url: trimmed, mode: mode, isPlaylist: true, spotifyRef: ref)
        jobs.insert(job, at: 0)
        appLog("Queued Spotify reference: \(trimmed)", category: "Queue")
        processNext()
    }

    func clearFinished() {
        jobs.removeAll { $0.state.isFinishedOrStopped }
        persistHistory()
    }

    /// Stops a job. An active download is cancelled mid-flight; a queued job is
    /// marked cancelled so it's skipped.
    func cancel(_ job: DownloadJob) {
        if let task = activeTasks[job.id] {
            appLog("Cancelling: \(job.url)", level: .warning, category: "Queue")
            task.cancel()
        } else if job.state == .queued {
            job.state = .cancelled
            appLog("Cancelled queued: \(job.url)", level: .warning, category: "Queue")
            persistHistory()
        }
    }

    /// Removes a job from the queue list (cancelling it first if it's running).
    func remove(_ job: DownloadJob) {
        activeTasks[job.id]?.cancel()
        jobs.removeAll { $0.id == job.id }
        persistHistory()
    }

    /// Re-runs a job by removing it and enqueuing a fresh attempt for the same URL
    /// (keeping its folder, so a restarted Browse download refiles correctly).
    func restart(_ job: DownloadJob) {
        let url = job.url
        let mode = job.mode
        let wasPlaylist = job.isPlaylist
        let folderID = job.folderID
        let artworkURL = job.artworkURL
        // A live failed conversion keeps its replacement intent on retry.
        // (History rows restored from disk carry none — deliberately, so a
        // stale restart after a relaunch can never delete a track.)
        let replacesTrackID = job.replacesTrackID
        // The catalogue's title/artist survive a retry — they were never the
        // reason it failed, and losing them would leave one track of a
        // restarted album reading differently from the rest.
        let knownTitle = job.knownTitle
        let knownArtist = job.knownArtist
        remove(job)
        appLog("Restarting: \(url)", category: "Queue")
        // Re-read the reference from the URL rather than trusting the job's:
        // a row restored from history carries no live `spotifyRef`.
        if let ref = SpotifyRef.parse(url) {
            enqueueSpotify(ref: ref, urlString: url, mode: mode)
        } else if wasPlaylist {
            enqueuePlaylist(urlString: url, mode: mode)
        } else {
            enqueue(urlString: url, mode: mode, folderID: folderID, artworkURL: artworkURL,
                    replacesTrackID: replacesTrackID,
                    knownTitle: knownTitle, knownArtist: knownArtist)
        }
    }

    /// Fills free pipeline slots: previews first (the user is sitting in the
    /// modal waiting), then queued jobs oldest-first (jobs are inserted at the
    /// front for display). Up to `maxConcurrent` run at once; each completion
    /// frees its slot and refills.
    private func processNext() {
        while activeTasks.count < Self.maxConcurrent {
            if !previewQueue.isEmpty {
                let work = previewQueue.removeFirst()
                startSlot(id: work.id) { await self.runPreview(work) }
            } else if let job = jobs.last(where: { $0.state == .queued && !activeJobIDs.contains($0.id) }) {
                activeJobIDs.insert(job.id)
                startSlot(id: job.id) { await self.run(job) }
            } else {
                break
            }
        }
    }

    /// Spawns one slot's work; when it finishes, the slot frees and the queue
    /// refills. (The dictionary insert below runs before the task body can —
    /// both are on the main actor — so the scheduler never double-books.)
    private func startSlot(id: UUID, work: @escaping () async -> Void) {
        let task = Task {
            await work()
            self.activeTasks[id] = nil
            self.activeJobIDs.remove(id)
            self.activeCount = self.activeTasks.count
            self.processNext()
        }
        activeTasks[id] = task
        activeCount = activeTasks.count
    }

    // MARK: - Browse previews

    /// Downloads the media for `urlString` through the pipeline (taking the
    /// next free slot, ahead of queued jobs) and returns it *without* adding
    /// it to the library — the Browse preview modal plays it and then saves
    /// or discards it. `mode` picks audio or
    /// video, mirroring the download queue's own modes, and `quality` steers
    /// the video resolution (the preview modal's quality picker). The file
    /// lands in the previews scratch directory; the caller owns it from there.
    /// Honours task cancellation (dismissing the modal cancels the work).
    func downloadPreview(urlString: String,
                         mode: DownloadMode = .audio,
                         quality: VideoQuality = .best,
                         onBegin: @escaping @MainActor () -> Void = {},
                         onDownloadStart: @escaping @MainActor () -> Void = {},
                         onProgress: @escaping @MainActor (Double) -> Void = { _ in }) async throws -> ExtractedMedia {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ExtractorError.invalidURL
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                previewQueue.append(PreviewWork(id: id,
                                                url: url,
                                                mode: mode,
                                                quality: quality,
                                                onBegin: onBegin,
                                                onDownloadStart: onDownloadStart,
                                                onProgress: onProgress,
                                                continuation: continuation))
                appLog("Preview queued: \(url.absoluteString)", category: "Browse")
                self.processNext()
            }
        } onCancel: {
            Task { @MainActor in self.cancelPreview(id) }
        }
    }

    /// Cancels a preview: still-queued work is resumed as cancelled right away;
    /// an active one has its slot's task cancelled (the extractor throws, and
    /// `runPreview` resumes the continuation with that error).
    private func cancelPreview(_ id: UUID) {
        if let index = previewQueue.firstIndex(where: { $0.id == id }) {
            let work = previewQueue.remove(at: index)
            work.continuation.resume(throwing: CancellationError())
        } else {
            activeTasks[id]?.cancel()
        }
    }

    private func runPreview(_ work: PreviewWork) async {
        work.onBegin()
        appLog("Preview extracting (\(work.mode.displayName)): \(work.url.absoluteString)", category: "Browse")
        do {
            let extracted = try await extractor.extractMedia(
                from: work.url,
                mode: work.mode,
                quality: work.quality,
                onDownloadStart: {
                    Task { @MainActor in work.onDownloadStart() }
                },
                onProgress: { fraction in
                    Task { @MainActor in work.onProgress(fraction) }
                }
            )
            // Move the file out of the shared work dir so the next job can't
            // touch it while the preview is playing.
            let ext = extracted.fileURL.pathExtension.isEmpty
                ? (extracted.isVideo ? "mp4" : "m4a")
                : extracted.fileURL.pathExtension
            let safeURL = AppPaths.previews.appendingPathComponent("\(work.id.uuidString).\(ext)")
            try? FileManager.default.removeItem(at: safeURL)
            try FileManager.default.moveItem(at: extracted.fileURL, to: safeURL)
            let media = ExtractedMedia(fileURL: safeURL,
                                       title: extracted.title,
                                       duration: extracted.duration,
                                       isVideo: extracted.isVideo,
                                       chapters: extracted.chapters)
            appLog("Preview ready: \"\(media.title)\"", level: .success, category: "Browse")
            work.continuation.resume(returning: media)
        } catch {
            if isCancellation(error) {
                appLog("Preview cancelled.", level: .warning, category: "Browse")
            } else {
                appLog("Preview failed: \(error.localizedDescription)", level: .error, category: "Browse")
            }
            work.continuation.resume(throwing: error)
        }
    }

    private func run(_ job: DownloadJob) async {
        // A Spotify job's URL may be a `spotify:` URI, which isn't a URL we can
        // hand to anything else — resolve it before the URL check below.
        if let ref = job.spotifyRef {
            await runSpotify(job, ref: ref)
            return
        }

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

            // A job that already knows what it downloaded (a discography pick,
            // whose title and artist come from Spotify) wears that instead of
            // the YouTube video title, and keeps the download title as the
            // "original" so Edit Metadata ▸ Reset still works.
            let track = Track(
                title: job.knownTitle ?? extracted.title,
                artist: job.knownArtist ?? "Unknown",
                fileName: finalURL.lastPathComponent,
                sourceURL: job.url,
                duration: extracted.duration,
                isVideo: extracted.isVideo,
                folderID: job.folderID,
                originalTitle: job.knownTitle == nil ? nil : extracted.title,
                chapters: chapters
            )
            // An album download files its tracks in the release's own order,
            // however the queue happened to finish them.
            if let folderID = job.folderID, let order = albumOrders[folderID] {
                library.add(track, orderedWithin: folderID, by: order)
            } else {
                library.add(track)
            }
            // Album art (best-effort): a Spotify-sourced enqueue carried the
            // cover URL — fetch it and hang it on the track. Never blocks the
            // queue, never fatal.
            ArtworkFetcher.attach(job.artworkURL, to: track.id, library: library)
            // English subtitles (best-effort, video only): captured off the
            // source the same way, after the file has landed, so a caption
            // track that isn't there costs the download nothing.
            SubtitleFetcher.attach(from: url, to: track.id,
                                   isVideo: track.isVideo, library: library)
            // A format conversion (Library ▸ Convert to Video/Audio): only
            // now that the replacement has fully landed does the original —
            // file and all — leave the library.
            if let replacedID = job.replacesTrackID {
                library.replaceAfterConversion(originalID: replacedID, with: track.id)
            }
            job.trackID = track.id
            job.title = track.title
            job.artist = track.artist.lowercased() == "unknown" ? nil : track.artist
            job.state = .finished
            appLog("Added to library: \"\(track.title)\" (\(track.duration.asPlaybackTime))",
                   level: .success, category: "Queue")
            persistHistory()

            // Best-effort AI organization (music/podcast + clean metadata), only
            // when the user has set up and opted into AI assist. Runs detached so
            // it never holds up the queue; re-snapshots the history once done so
            // the saved row carries the AI's clean title/artist too.
            //
            // Skipped when the job already carried both: guessing a title and
            // artist out of a YouTube video name can only do worse than the
            // catalogue's own, and a track from a discography is music by
            // construction, so there's no classification left to make either.
            let metadataKnown = job.knownTitle != nil && job.knownArtist != nil
            if let aiOrganizer, !metadataKnown {
                let id = track.id
                Task {
                    await aiOrganizer.organizeIfEnabled(id)
                    persistHistory()
                }
            }
        } catch {
            if isCancellation(error) {
                job.state = .cancelled
                appLog("Cancelled: \(job.url)", level: .warning, category: "Queue")
            } else {
                job.state = .failed(error.localizedDescription)
                appLog("Job failed: \(error.localizedDescription)", level: .error, category: "Queue")
                // A single, greppable classification line per failed job, so a
                // week of diagnostics logs can be tallied by failure mode
                // (JS-RUNTIME-PLAN "Testing & metrics").
                appLog("Failure class: \(Self.failureClass(for: error))", level: .warning, category: "Queue")
            }
            persistHistory()
        }
    }

    /// Buckets a job failure into one coarse class for the diagnostics tally.
    /// Pure string matching over the error text (the same signatures
    /// `diagnosticHint` recognises), most-specific first. `other` when nothing
    /// matches — it never guesses.
    static func failureClass(for error: Error) -> String {
        if error is OperationTimeout { return "timeout" }
        if let extractorError = error as? ExtractorError {
            switch extractorError {
            case .hlsOnly: return "hls-only"
            case .unplayableVideoCodec: return "unplayable-codec"
            case .noAudioFormat, .noVideoFormat: return "no-format"
            default: break
            }
        }
        let t = "\(error.localizedDescription) \(String(describing: error))".lowercased()
        func has(_ s: String) -> Bool { t.contains(s) }
        if has("sign in to confirm") || has("not a bot") || has("confirm you’re not a bot") { return "bot-check" }
        if has("po token") || has("po_token") || has("missing a po") { return "po-token" }
        if has("nsig") || has("signature extraction failed") || (has("unable to extract") && has("player")) { return "nsig" }
        if has("http 403") || has("403") || has("410") { return "http-403" }
        if has("timed out") || has("timeout") { return "timeout" }
        if has("members-only") || has("private video") || has("age") || has("unavailable") { return "unavailable" }
        if has("network") || has("connection") || has("offline") { return "network" }
        if has("truncat") || has("not playable") || has("corrupt") { return "truncated" }
        return "other"
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
            persistHistory()
            enqueue(urlString: job.url, mode: job.mode)
            return
        }

        if Task.isCancelled {
            job.state = .cancelled
            persistHistory()
            return
        }

        job.title = playlist.title

        // Ask the user which entries to grab. Holds this job's pipeline slot
        // while the popup is open (the other slot keeps working) — the user is
        // right there having just pasted the link.
        let chosen = await requestPlaylistSelection(playlist, mode: job.mode, jobID: job.id)
        if pendingPlaylist?.jobID == job.id { pendingPlaylist = nil }

        guard let chosen, !chosen.isEmpty else {
            job.state = .cancelled
            appLog("Playlist selection cancelled — nothing downloaded.", level: .warning, category: "Queue")
            persistHistory()
            return
        }

        let folder = folder(named: playlist.title, fallback: "Playlist")
        for entry in chosen {
            enqueue(urlString: entry.url, mode: job.mode, folderID: folder.id,
                    artworkURL: entry.artworkURL)
        }
        job.state = .finished
        appLog("Playlist \"\(playlist.title)\" → queued \(chosen.count) of \(playlist.entries.count) download(s) into a folder.",
               level: .success, category: "Queue")
        persistHistory()
    }

    /// Expands a Spotify reference: metadata → a YouTube match per track → the
    /// ordinary download path.
    ///
    /// Everything here is plain HTTPS. The Spotify path deliberately never
    /// touches the embedded Python interpreter (no `PythonGate`, no yt-dlp, no
    /// `PlaylistResolver`), so a pasted Spotify link works on a fresh install —
    /// before the yt-dlp module has ever been fetched. Only the per-track
    /// *downloads* it spawns go through the normal extractor.
    ///
    /// A single track enqueues one ordinary download and shows no popup; an
    /// album, playlist or artist reuses the playlist machinery wholesale —
    /// selection popup, `folder(named:fallback:)`, one child job per pick.
    private func runSpotify(_ job: DownloadJob, ref: SpotifyRef) async {
        job.state = .extracting
        defer { job.progressNote = nil }

        guard let client = spotifySettings?.client else {
            job.state = .failed(SpotifyError.notConfigured.localizedDescription)
            appLog("A Spotify link was pasted but no credentials are saved — add them in Settings ▸ Spotify.",
                   level: .error, category: "Queue")
            persistHistory()
            return
        }

        do {
            let (kind, id) = try await ref.resolved()
            appLog("Resolving Spotify \(kind.rawValue) \(id)…", category: "Queue")

            if kind == .track {
                let track = try await client.track(id: id)
                job.title = track.displayTitle
                job.artist = track.primaryArtist.isEmpty ? nil : track.primaryArtist
                try Task.checkCancellation()
                guard let url = await SpotifyResolver.youTubeURL(for: track) else {
                    throw SpotifyError.noMatches(track.displayTitle)
                }
                try Task.checkCancellation()
                job.state = .finished
                appLog("Spotify track \"\(track.displayTitle)\" → \(url)", level: .success, category: "Queue")
                persistHistory()
                enqueue(urlString: url, mode: job.mode, artworkURL: track.albumImageURL)
                return
            }

            let collection = try await client.collection(kind: kind, id: id)
            job.title = collection.name
            guard !collection.tracks.isEmpty else { throw SpotifyError.noMatches(collection.name) }
            try Task.checkCancellation()

            // Each track costs a YouTube search, so this is the slow part —
            // the row counts them off rather than sitting on "Preparing…".
            let playlist = await SpotifyResolver.resolve(collection) { done, total in
                job.progressNote = "Resolving \(done) of \(total)…"
            }
            job.progressNote = nil
            try Task.checkCancellation()
            guard !playlist.entries.isEmpty else { throw SpotifyError.noMatches(collection.name) }

            // From here it's the YouTube playlist flow, unchanged.
            let chosen = await requestPlaylistSelection(playlist, mode: job.mode, jobID: job.id)
            if pendingPlaylist?.jobID == job.id { pendingPlaylist = nil }

            guard let chosen, !chosen.isEmpty else {
                job.state = .cancelled
                appLog("Spotify selection cancelled — nothing downloaded.", level: .warning, category: "Queue")
                persistHistory()
                return
            }

            let folder = folder(named: playlist.title, fallback: kind.rawValue.capitalized)
            for entry in chosen {
                enqueue(urlString: entry.url, mode: job.mode, folderID: folder.id,
                        artworkURL: entry.artworkURL)
            }
            job.state = .finished
            appLog("Spotify \(kind.rawValue) \"\(playlist.title)\" → queued \(chosen.count) of \(playlist.entries.count) download(s) into a folder.",
                   level: .success, category: "Queue")
            persistHistory()
        } catch {
            if isCancellation(error) {
                job.state = .cancelled
                appLog("Cancelled Spotify resolution: \(job.url)", level: .warning, category: "Queue")
            } else {
                job.state = .failed(error.localizedDescription)
                appLog("Spotify job failed: \(error.localizedDescription)", level: .error, category: "Queue")
            }
            persistHistory()
        }
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
    /// playlist — or refreshing a Browse source — doesn't spawn duplicates),
    /// creating one if none matches. `fallback` names the folder when the name
    /// is blank.
    private func folder(named name: String, fallback: String) -> Folder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = trimmed.isEmpty ? fallback : trimmed
        if let existing = library.folders.first(where: {
            !$0.isArchived && $0.name.localizedCaseInsensitiveCompare(wanted) == .orderedSame
        }) {
            return existing
        }
        return library.createFolder(named: wanted) ?? Folder(name: wanted)
    }

    /// The album equivalent, matched on **name *and* parent**: two artists can
    /// both have a "Greatest Hits", and each belongs under its own artist
    /// folder — the plain name lookup above would hand the second one the
    /// first one's folder.
    private func albumFolder(named name: String, fallback: String, parent parentID: UUID?) -> Folder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = trimmed.isEmpty ? fallback : trimmed
        if let existing = library.folders.first(where: {
            !$0.isArchived && $0.parentID == parentID
                && $0.name.localizedCaseInsensitiveCompare(wanted) == .orderedSame
        }) {
            return existing
        }
        return library.createFolder(named: wanted, parent: parentID)
            ?? Folder(name: wanted, parentID: parentID)
    }

    /// Queues a whole release: one ordinary download per matched track, all
    /// filed into a folder named after the album, with the release's cover
    /// attached to that folder so it shows as a thumbnail in the Library's
    /// folder list. A Browse source nests the album inside its own source
    /// folder (everything from one source still stays together); the Every
    /// Noise browser, which files single picks unfiled, gets a top-level album
    /// folder. Re-downloading the same album reuses its folder rather than
    /// spawning a second one.
    @discardableResult
    func enqueueAlbum(named albumName: String,
                      tracks: [AlbumTrack],
                      mode: DownloadMode,
                      insideFolderNamed parentName: String? = nil,
                      artworkURL: String? = nil) -> Folder? {
        guard !tracks.isEmpty else { return nil }
        let parentTrimmed = (parentName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = parentTrimmed.isEmpty ? nil : folder(named: parentTrimmed, fallback: "Browse")
        let album = albumFolder(named: albumName, fallback: "Album", parent: parent?.id)
        ArtworkFetcher.attach(artworkURL, toFolder: album.id, library: library)
        // Recorded before anything is queued, so the first track to land
        // already has somewhere to be. Merged into any order already there,
        // never replacing it: filling in a couple of tracks that failed the
        // first time must not move the ones that landed.
        var order = albumOrders[album.id] ?? [:]
        for (position, track) in tracks.enumerated() {
            order[track.url] = position
        }
        albumOrders[album.id] = order
        for track in tracks {
            enqueue(urlString: track.url, mode: mode, folderID: album.id,
                    artworkURL: track.artworkURL ?? artworkURL,
                    knownTitle: track.title, knownArtist: track.artist)
        }
        appLog("Queued \(tracks.count) track(s) from \"\(album.name)\" into a library folder.",
               category: "Queue")
        return album
    }

    /// Enqueues a Browse download filed into a folder named after its source, so
    /// everything pulled from one Browse source lands together (e.g. a
    /// "Brian Eno" folder for a Discography source). Blank names fall back to a
    /// generic "Browse" folder.
    func enqueue(urlString: String, mode: DownloadMode, browseFolderNamed folderName: String,
                 artworkURL: String? = nil,
                 knownTitle: String? = nil, knownArtist: String? = nil) {
        let folder = folder(named: folderName, fallback: "Browse")
        enqueue(urlString: urlString, mode: mode, folderID: folder.id, artworkURL: artworkURL,
                knownTitle: knownTitle, knownArtist: knownArtist)
    }
}

/// Fetches a track's album art (best-effort, off the queue) and records it on
/// the track. The image lands in `AppPaths.artwork` as `<track-id>.jpg`; a
/// failed fetch just leaves the placeholder — never an error the user sees.
enum ArtworkFetcher {
    static func attach(_ urlString: String?, to trackID: UUID, library: LibraryStore) {
        fetch(urlString, named: "\(trackID.uuidString).jpg", into: AppPaths.artwork) { fileName in
            // Re-fetches overwrite the same file name; drop the decoded copy
            // so the new cover shows instead of the memoized old one — and the
            // folder-cover verdict with it, since that compares these files.
            TrackArtwork.invalidate(fileName: fileName)
            await MainActor.run {
                FolderCover.invalidate()
                library.setArtwork(for: trackID, fileName: fileName)
            }
        }
    }

    /// The same best-effort fetch for a **folder's** cover — an album
    /// downloaded whole from a discography wears its release art on its
    /// Library row. Kept separate from the track path only by where the file
    /// lands and which store field it records.
    static func attach(_ urlString: String?, toFolder folderID: UUID, library: LibraryStore) {
        fetch(urlString, named: "\(folderID.uuidString).jpg", into: AppPaths.folderArtwork) { fileName in
            FolderArtwork.invalidate(fileName: fileName)
            await MainActor.run { library.setFolderArtwork(for: folderID, fileName: fileName) }
        }
    }

    private static func fetch(_ urlString: String?, named fileName: String, into directory: URL,
                              record: @escaping (String) async -> Void) {
        guard let urlString, let url = URL(string: urlString) else { return }
        Task {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 30
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    throw SpotifyError.http(http.statusCode, "artwork fetch")
                }
                guard !data.isEmpty else { return }
                try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
                await record(fileName)
                appLog("Album art saved (\(data.count / 1024) KB).", level: .debug, category: "Queue")
            } catch {
                if isCancellation(error) { return }
                appLog("Album art fetch failed (kept the placeholder): \(error.localizedDescription)",
                       level: .warning, category: "Queue")
            }
        }
    }
}
