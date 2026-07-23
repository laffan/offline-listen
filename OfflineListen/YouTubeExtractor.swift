import Foundation
import AVFoundation

#if canImport(YoutubeDL)
import YoutubeDL
#endif

// PythonKit (a transitive dependency of YoutubeDL-iOS) lets us drive yt-dlp's
// Python `YoutubeDL` directly to pass options the structured `extractInfo` API
// can't — specifically a forced player client. Add it as an explicit package
// dependency on the app target to enable the H.264 recovery path below; without
// it, `canImport` is false and the recovery simply compiles out.
#if canImport(PythonKit)
import PythonKit
#endif

/// Result of extracting + downloading media for a URL.
struct ExtractedMedia {
    /// On-disk location of the downloaded file (`.m4a` for audio, `.mp4` for video).
    let fileURL: URL
    let title: String
    let duration: Double
    let isVideo: Bool
    /// Chapter markers exposed by the source, if any (empty otherwise).
    var chapters: [Chapter] = []
}

enum ExtractorError: LocalizedError {
    case packageUnavailable
    case invalidURL
    case noAudioFormat
    case noVideoFormat
    case unplayableVideoCodec(String)
    case hlsOnly
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .packageUnavailable:
            return "YoutubeDL-iOS is not linked. Add the Swift package in Xcode (see README)."
        case .invalidURL:
            return "That doesn't look like a valid URL."
        case .noAudioFormat:
            return "No downloadable audio track was found for this video."
        case .noVideoFormat:
            return "No downloadable video (with audio) was found for this video."
        case .unplayableVideoCodec(let codecs):
            return "The only video stream offered uses a codec this device can't play (\(codecs)). Try the download again — YouTube often serves an H.264 stream on a retry — or download it as Audio."
        case .hlsOnly:
            return "This link only offers HLS/streaming formats, which this app can't download yet (it fetches progressive files). Try a different quality, or a source that offers a direct file."
        case .downloadFailed(let message):
            return message
        }
    }
}

/// The single definition of "the user cancelled" for every retry/fallback
/// layer. Cancellation must never be retried, logged as a failure, or trigger
/// a fallback (CompositeExtractor's contract), so every catch site classifies
/// errors with this one predicate instead of hand-rolling its clauses.
func isCancellation(_ error: Error) -> Bool {
    error is CancellationError
        || (error as? URLError)?.code == .cancelled
        || Task.isCancelled
}

/// Decides whether AVFoundation can actually *decode* a video codec on this
/// device. YouTube increasingly serves video-only streams as AV1 (`av01`) or
/// VP9, which AVFoundation can't decode on the overwhelming majority of iPhones
/// — selecting one produces a file whose timeline scrubs but shows the
/// QuickTime placeholder instead of a picture (and whose audio won't play
/// either, because the undecodable video track poisons the whole item). We
/// keep this conservative: only H.264 (`avc1`/`avc3`) and HEVC (`hvc1`/`hev1`)
/// are treated as playable. Devices new enough to decode AV1 (A17 Pro / M3+)
/// are also offered H.264, so preferring it loses nothing in practice.
enum PlayableVideoCodec {
    /// `codec` is a codecs string such as "avc1.640028", "av01.0.08M.08",
    /// "vp09.00.10.08", "hev1.1.6.L93.B0".
    static func isPlayable(codec: String?) -> Bool {
        let c = (codec ?? "").lowercased()
        if c.isEmpty || c == "none" { return false }
        return c.hasPrefix("avc1") || c.hasPrefix("avc3") || c.hasPrefix("h264") || c.hasPrefix("mp4v")
            || c.hasPrefix("hvc1") || c.hasPrefix("hev1") || c.hasPrefix("h265")
    }

    /// Extracts the codecs value from a mimeType like
    /// `video/mp4; codecs="avc1.640028"` and tests it.
    static func isPlayable(mimeType: String?) -> Bool {
        guard let mt = mimeType, let range = mt.range(of: "codecs=") else { return false }
        let raw = mt[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        return isPlayable(codec: raw)
    }
}

/// Reads the duration of a local media file (audio or video).
func mediaDuration(of url: URL) async -> Double {
    guard let seconds = try? await AVURLAsset(url: url).load(.duration).seconds,
          seconds.isFinite else { return 0 }
    return seconds
}

/// Verifies a finished download is actually decodable before it's surfaced as a
/// success. A truncated or token-poisoned stream can produce a file that
/// *saves* fine but won't play; catching that here turns a silent dud in the
/// library into a retriable failure — the caller falls through to its next
/// player client or extractor instead of celebrating a broken file.
enum MediaVerifier {
    /// Returns the verified duration so callers don't re-open the asset just
    /// to read it again.
    @discardableResult
    static func verify(_ url: URL, isVideo: Bool, category: String) async throws -> Double {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? 0
        guard size > 0 else {
            throw ExtractorError.downloadFailed("The downloaded file is empty.")
        }
        let asset = AVURLAsset(url: url)
        let neededType: AVMediaType = isVideo ? .video : .audio
        let tracks = (try? await asset.loadTracks(withMediaType: neededType)) ?? []
        let duration = ((try? await asset.load(.duration))?.seconds) ?? 0
        guard !tracks.isEmpty, duration.isFinite, duration > 0 else {
            throw ExtractorError.downloadFailed(
                "The downloaded file isn't playable (no decodable \(isVideo ? "video" : "audio") track) — the stream was likely truncated or corrupted.")
        }
        appLog("Verified playable \(isVideo ? "video" : "audio") · \(Int(duration))s · \(size / 1024) KB",
               level: .debug, category: category)
        return duration
    }
}

/// Abstraction over the extraction step so the rest of the app is independent of
/// the concrete library and can be unit-tested with a mock.
protocol MediaExtractor {
    /// Downloads the best audio-only stream (`.audio`) or a muxed video+audio
    /// MP4 (`.video`) for `url`. `quality` steers which video rendition is
    /// picked (ignored for audio); it's always bounded by what the source
    /// offers in a device-playable codec.
    /// - Parameter onDownloadStart: invoked once the info has been resolved and
    ///   the actual download is about to begin.
    /// - Parameter onProgress: 0...1 download fraction (when the size is known).
    func extractMedia(from url: URL,
                      mode: DownloadMode,
                      quality: VideoQuality,
                      onDownloadStart: @escaping () -> Void,
                      onProgress: @escaping (Double) -> Void) async throws -> ExtractedMedia

    /// Whether this extractor can handle `url` at all. Lets a composite skip a
    /// primary that's URL-specific (e.g. the YouTube-only native extractor) for
    /// links it can't resolve, instead of failing through it. Defaults to true.
    func canHandle(_ url: URL) -> Bool
}

extension MediaExtractor {
    func canHandle(_ url: URL) -> Bool { true }

    /// Convenience without a quality preference — best available.
    func extractMedia(from url: URL,
                      mode: DownloadMode,
                      onDownloadStart: @escaping () -> Void,
                      onProgress: @escaping (Double) -> Void) async throws -> ExtractedMedia {
        try await extractMedia(from: url, mode: mode, quality: .best,
                               onDownloadStart: onDownloadStart, onProgress: onProgress)
    }
}

/// Production implementation backed by kewlbear/YoutubeDL-iOS (yt-dlp on device).
///
/// We use the library only to *resolve* the video (`extractInfo`), which runs
/// yt-dlp and returns ready-to-use direct stream URLs (the throttling parameter
/// is already decrypted). We then fetch the chosen audio stream ourselves with a
/// foreground `URLSession`.
///
/// Why not the library's own `download(...)`? It is hardwired to
/// `Downloader.shared`, which uses a *background* `URLSession`. Background
/// transfers don't complete reliably on the Simulator (and require app-delegate
/// event forwarding), so `download` hangs waiting on a completion that never
/// arrives. A plain foreground download behaves identically on Simulator and
/// device. (The `Downloader` initializer that would yield a foreground session
/// is `internal`, so it can't be substituted from here.)
final class YoutubeDLExtractor: MediaExtractor {
    /// Set after the one automatic engine refresh a session gets, so a stale-
    /// engine failure signature can't loop refresh → retry → refresh forever.
    private static var didAutoRefreshEngine = false

    /// Whether an error's text looks like the cached yt-dlp engine is stale
    /// relative to YouTube's player JS — the case `refreshEngine()` fixes.
    static func errorSuggestsStaleEngine(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("nsig") || t.contains("signature extraction failed")
            || (t.contains("unable to extract") && t.contains("player"))
    }

    /// Whether a failure happened at the download stage (stream URL rejected
    /// even after refreshes, truncation, an unplayable/failed merge) — worth
    /// retrying via other player clients, which resolve *different* URLs.
    /// Deliberately a positive list: format-shape verdicts (HLS-only, no audio
    /// offered, undecodable codec) can't be changed by another client, and
    /// *local* failures — a full disk throwing from `FileHandle.write`, a
    /// permissions error — would fail identically on every client, so unknown
    /// error types default to **false** rather than launching a multi-client
    /// sweep that re-downloads hundreds of MB against the same wall.
    private static func isDownloadStageError(_ error: Error) -> Bool {
        if error is OperationTimeout { return true }
        if error is URLError { return true }
        if let extractorError = error as? ExtractorError {
            if case .downloadFailed = extractorError { return true }
        }
        return false
    }

    /// Tracks the orphaned default extraction after a timeout so the
    /// forced-client recovery can wait for it to settle before starting new
    /// Python work — running two concurrent yt-dlp `extract_info` calls
    /// through the embedded interpreter risks a crash (memory pressure or
    /// PythonKit threading fault).
    private var orphanedDefaultExtraction: Task<Void, Never>?

    /// Waits up to `cap` seconds for the orphaned default extraction to finish
    /// before starting forced-client recovery. Uses a GCD timer (not
    /// Task.sleep / withTaskGroup) because the orphaned Python call can starve
    /// the cooperative pool, and because withTaskGroup waits for *all* children
    /// before returning — a non-throwing `await orphan.value` child would block
    /// the group even after cancellation.
    /// Returns whether the interpreter is now idle: `true` if there was no
    /// orphan, or it finished within `cap`; `false` if it's still running. The
    /// handle is cleared **only** when the orphan actually settles, so a `false`
    /// return leaves it tracked — that's the reliable "Python is busy" signal the
    /// safe JS-runtime wiring depends on (an unconditionally-cleared handle would
    /// falsely read as idle while a zombie extraction still holds the GIL).
    @discardableResult
    private func waitForOrphanedExtraction(category: String, cap: TimeInterval = 5) async -> Bool {
        guard let orphan = orphanedDefaultExtraction else { return true }
        appLog("Waiting for orphaned default extraction to settle (up to \(Int(cap))s)…",
               level: .debug, category: category)
        let settled: Bool = await withCheckedContinuation { continuation in
            let lock = NSLock()
            var done = false
            func settle(_ value: Bool) {
                lock.lock(); defer { lock.unlock() }
                guard !done else { return }
                done = true
                continuation.resume(returning: value)
            }

            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            timer.schedule(deadline: .now() + cap)
            timer.setEventHandler { settle(false); timer.cancel() }
            timer.resume()

            Task { await orphan.value; settle(true); timer.cancel() }
        }
        if settled {
            orphanedDefaultExtraction = nil
            appLog("Orphaned extraction settled — proceeding with recovery.",
                   level: .debug, category: category)
        } else {
            appLog("Orphaned extraction still running after \(Int(cap))s — proceeding anyway (memory pressure risk).",
                   level: .warning, category: category)
        }
        return settled
    }

    /// One-shot signal that a prior `extractInfo` has booted the embedded Python
    /// runtime this session, so direct PythonKit calls (and the plugin import) are
    /// safe. Set after the first resolve attempt of the session, success or
    /// timeout — either way `extract_info` ran and Python came up.
    private static var pythonBootstrapped = false

    /// Registers the on-device JS-runtime providers at a point where it can't
    /// crash: only once Python is bootstrapped **and** no extraction is running
    /// in the interpreter. `load_all_plugins()` (the plugin import work) must
    /// never run concurrently with another `extract_info` — that re-entrancy is
    /// what crashed a mid-recovery attempt. Doing it at the very start of a job
    /// (serial queue) after confirming the interpreter is idle lets the default
    /// web extraction that follows solve nsig on device (so it resolves instead
    /// of hanging) and mint a PO token.
    private func wireJSRuntimeIfSafe(category: String) async {
        #if canImport(PythonKit)
        guard Self.pythonBootstrapped, !PythonBridge.isConfigured else { return }
        guard await waitForOrphanedExtraction(category: category) else {
            appLog("Deferring on-device JS-runtime wiring — a prior extraction is still running in the interpreter.",
                   level: .debug, category: category)
            return
        }
        // Under the app-wide Python gate: with two pipeline slots, "the
        // orphan settled" no longer implies the interpreter is idle — the
        // other slot may be mid-extraction — and the plugin import must never
        // overlap one.
        try? await PythonGate.shared.run { PythonBridge.configureIfNeeded() }
        #endif
    }

    /// Deletes the cached yt-dlp Python module and re-downloads it. Useful when
    /// extraction starts failing because the engine is stale relative to
    /// YouTube's frequent changes.
    /// Canonicalises a YouTube watch URL to `https://www.youtube.com/watch?v=ID`,
    /// dropping the mobile host (`m.youtube.com`) and tracking/autoplay query
    /// params (`pp`, `ra`, …). A mobile or heavily-parameterised URL can push
    /// yt-dlp's on-device extraction down a slower/different code path; the bare
    /// desktop watch form is what the extractor handles most reliably. Falls back
    /// to the original URL when no video id can be parsed (non-watch URLs are left
    /// untouched).
    static func canonicalURL(_ url: URL) -> URL {
        guard let id = YouTubeKitExtractor.videoID(from: url),
              let canonical = URL(string: "https://www.youtube.com/watch?v=\(id)") else {
            return url
        }
        return canonical
    }

    /// Whether `url` is a YouTube link the forced player-client path applies to.
    /// yt-dlp's `extractor_args: youtube → player_client` only affect YouTube, so
    /// for any other site (Vimeo, SoundCloud, …) the default extraction is the
    /// only path. We use this to skip the slow on-device web-client nsig
    /// descrambling for YouTube and go straight to the fast clients, which need no
    /// descrambling — the web path then becomes a last-resort fallback.
    static func isYouTubeURL(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        let isYouTubeHost = host == "youtu.be"
            || host.hasSuffix("youtube.com")
            || host.hasSuffix("youtube-nocookie.com")
        return isYouTubeHost && YouTubeKitExtractor.videoID(from: url) != nil
    }

    /// Container/codecs AVFoundation can decode for a *direct audio save* (no
    /// extraction step). Anything outside this — opus, webm, ogg, flac — routes
    /// to the muxed-video + audio-extraction fallback instead of being saved raw.
    static let playableAudioExts: Set<String> = ["m4a", "mp3", "aac", "wav", "aiff", "m4b"]

    /// Whether a yt-dlp format is a single, range-fetchable file (what
    /// `AudioStreamDownloader` needs) rather than an HLS playlist or segmented
    /// DASH stream we can't assemble. Detected from the bits every extractor
    /// exposes (id/ext/url), deliberately *not* from "dash" alone: YouTube's
    /// DASH renditions use numeric ids and direct googlevideo URLs and download
    /// fine — only the segmented `http_dash_segments` marker is excluded.
    static func isProgressiveDownloadable(formatID: String, ext: String, url: String) -> Bool {
        let id = formatID.lowercased()
        let lowerURL = url.lowercased()
        if ext.lowercased() == "m3u8" || ext.lowercased() == "mpd" { return false }
        if lowerURL.contains(".m3u8") || lowerURL.contains(".mpd") { return false }
        if id.contains("hls") { return false }
        if id.contains("dash_segments") || id.contains("http_dash") { return false }
        return true
    }

    /// Returns whether the fresh module actually landed, so the automatic
    /// retry path only re-runs extraction (and only spends its once-per-session
    /// budget) when the refresh succeeded.
    @discardableResult
    static func refreshEngine() async -> Bool {
        let category = "yt-dlp"
        #if canImport(YoutubeDL)
        appLog("Refreshing yt-dlp engine…", level: .warning, category: category)
        try? FileManager.default.removeItem(at: YoutubeDL.pythonModuleURL)
        do {
            try await YoutubeDL.downloadPythonModule()
            appLog("yt-dlp engine refreshed.", level: .success, category: category)
            return true
        } catch {
            appLog("Engine refresh failed: \(error.localizedDescription)", level: .error, category: category)
            return false
        }
        #else
        appLog("YoutubeDL is not linked.", level: .error, category: category)
        return false
        #endif
    }

#if canImport(YoutubeDL)
    /// Runs yt-dlp's (opaque) info extraction with a heartbeat log every 10s and
    /// an overall timeout, so a stall becomes visible and recoverable instead of
    /// an indefinite hang.
    ///
    /// The timeout fires from a **GCD timer**, not a Swift-concurrency task: the
    /// underlying yt-dlp call blocks its thread synchronously and can starve the
    /// cooperative pool, which would prevent a `Task.sleep`-based timeout from
    /// ever running. On timeout we stop *waiting* and let the queue move on, but
    /// we deliberately keep observing the orphaned extraction: when it eventually
    /// returns or throws, we log that real outcome — it's the only place yt-dlp's
    /// own error (bot check, unavailable video, signature failure) surfaces,
    /// since our own timeout message would otherwise bury it.
    private func resolveInfo(_ youtubeDL: YoutubeDL,
                             url: URL,
                             category: String,
                             timeout: TimeInterval = 90) async throws -> ([Format], Info) {
        // Serialize entry into the embedded interpreter. Waiting here — before
        // the timeout clock starts — means queueing behind another job's
        // Python never eats into this extraction's own window. The extraction
        // task below owns the release, so a timed-out (abandoned) call keeps
        // the gate until it actually settles and new Python work waits for it
        // instead of crashing into it.
        try await PythonGate.shared.acquire()

        let started = Date()
        let heartbeat = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { return }
                appLog("Still extracting… \(Int(Date().timeIntervalSince(started)))s elapsed",
                       category: category)
            }
        }
        defer { heartbeat.cancel() }

        let extraction = Task { () async throws -> ([Format], Info) in
            defer { PythonGate.shared.release() }
            return try await youtubeDL.extractInfo(url: url)
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<([Format], Info), Error>) in
            let lock = NSLock()
            var finished = false
            func finish(_ work: () -> Void) -> Bool {
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return false }
                finished = true
                work()
                return true
            }

            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { [weak self] in
                _ = finish {
                    extraction.cancel()
                    continuation.resume(throwing: ExtractorError.downloadFailed(
                        "Timed out after \(Int(timeout))s extracting info. YouTube may have changed — try the ⋯ menu → Refresh yt-dlp engine, or a different video."))
                }
                timer.cancel()

                // Track the orphaned extraction so the forced-client path can
                // wait for it to settle before starting new Python work.
                let orphan = Task {
                    _ = try? await extraction.value
                }
                self?.orphanedDefaultExtraction = orphan
            }
            timer.resume()

            Task {
                do {
                    let value = try await extraction.value
                    let settled = finish { timer.cancel(); continuation.resume(returning: value) }
                    if !settled {
                        appLog("Note: the extraction that timed out actually succeeded after \(Int(Date().timeIntervalSince(started)))s (\(value.0.count) formats). The video isn't broken — extraction was just slow this time.",
                               level: .warning, category: category)
                    }
                } catch {
                    let settled = finish { timer.cancel(); continuation.resume(throwing: error) }
                    if !settled {
                        if !(error is CancellationError) {
                            appLog("yt-dlp's own error (arrived \(Int(Date().timeIntervalSince(started)))s in, after the timeout): \(error.localizedDescription)",
                                   level: .error, category: category)
                            appLog("Detail: \(String(describing: error))", level: .debug, category: category)
                            if let hint = Self.diagnosticHint(for: "\(error.localizedDescription) \(String(describing: error))") {
                                appLog("Hint: \(hint)", level: .warning, category: category)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Maps common yt-dlp / YouTube failure signatures to a plain-language hint so
    /// an otherwise opaque error in the log comes with a likely cause and next
    /// step. Returns nil when nothing recognisable matches (so we never invent a
    /// diagnosis). Pure string matching — safe to call from any path.
    static func diagnosticHint(for text: String) -> String? {
        let t = text.lowercased()
        func has(_ s: String) -> Bool { t.contains(s) }

        if has("sign in to confirm") || has("not a bot") || has("confirm you’re not a bot") {
            return "YouTube is applying a bot check to this request (it wants a signed-in / PO-token-backed client). It commonly hits one video while others pass. Retrying later, switching network, or the forced ios/tv clients often clears it."
        }
        if has("po token") || has("po_token") || has("missing a po") {
            return "This video wants a PO token. The forced ios/tv player clients sidestep it; if they also fail, YouTube is gating this particular video harder than usual."
        }
        if has("nsig") || has("signature extraction failed") || (has("unable to extract") && has("player")) {
            return "yt-dlp couldn't run YouTube's signature/nsig descrambling — usually the player JS changed and the cached engine is stale. Try ⋯ → Refresh yt-dlp engine, then retry."
        }
        if has("private video") { return "The video is private — not downloadable." }
        if has("members-only") || has("join this channel") { return "Members-only video — needs the channel membership; not downloadable here." }
        if has("age") && (has("confirm your age") || has("age-restricted") || has("inappropriate") || has("sign in")) {
            return "Age-restricted video — yt-dlp has no signed-in session to confirm age."
        }
        if has("video unavailable") || has("this video is not available") || has("removed by the uploader") {
            return "YouTube reports the video as unavailable — region block, takedown, or a stale/changed id."
        }
        if has("requested format is not available") {
            return "yt-dlp resolved the video but none of the requested formats matched — the codec/format filter may be too strict for what this video offers."
        }
        if has("unable to download webpage") || has("failed to resolve") || has("connection") || has("network is") {
            return "A network error reaching YouTube — check connectivity and retry."
        }
        return nil
    }

    /// The default-extraction download path: selects from the already-resolved
    /// `formats`, downloads, merges/extracts as needed, verifies the result is
    /// actually playable, and returns the media. Mid-download URL refreshes
    /// re-run the same default extraction and re-pick the same `format_id`, so
    /// a stream URL that expires or gets rejected (403) partway through resumes
    /// from its current offset instead of failing the job.
    private func downloadUsingDefaultInfo(formats: [Format],
                                          info: Info,
                                          youtubeDL: YoutubeDL,
                                          url: URL,
                                          mode: DownloadMode,
                                          quality: VideoQuality,
                                          category: String,
                                          onDownloadStart: @escaping () -> Void,
                                          onProgress: @escaping (Double) -> Void) async throws -> ExtractedMedia {
        // Log every discovered format so we can see exactly what's available.
        appLog("\(formats.count) formats discovered:", level: .debug, category: category)
        for f in formats.prefix(30) {
            let type = f.isAudioOnly ? "audio-only" : (f.isVideoOnly ? "video-only" : "muxed")
            appLog("· \(f.format_id) \(f.ext) \(f.height.map { "\($0)p" } ?? "—") [\(type)] v=\(f.vcodec ?? "?") a=\(f.acodec ?? "?")",
                   level: .debug, category: category)
        }

        func makeRequest(for format: Format) -> URLRequest? {
            guard let u = URL(string: format.url) else { return nil }
            var r = URLRequest(url: u)
            for (key, value) in format.http_headers { r.setValue(value, forHTTPHeaderField: key) }
            return r
        }

        // Builds the refresher a download hands to `AudioStreamDownloader`:
        // re-runs the default extraction and returns a request for the same
        // `format_id`, or nil when the fresh resolve no longer offers it.
        func refresher(formatID: String) -> AudioStreamDownloader.RequestRefresher {
            { [weak self] in
                guard let self else { return nil }
                // A previous refresh attempt may have timed out and orphaned
                // its Python extract_info — let it settle first (two
                // concurrent yt-dlp calls risk crashing the interpreter).
                await self.waitForOrphanedExtraction(category: category)
                appLog("Re-resolving via yt-dlp for a fresh stream URL (format \(formatID))…", category: category)
                let (freshFormats, _) = try await self.resolveInfo(youtubeDL, url: url, category: category, timeout: 45)
                guard let fresh = freshFormats.first(where: { $0.format_id == formatID }) else {
                    appLog("Fresh extraction no longer offers format \(formatID).", level: .warning, category: category)
                    return nil
                }
                return makeRequest(for: fresh)
            }
        }

        // Only progressive (single-URL) formats are fetchable by the chunked
        // downloader; HLS/segmented-DASH are filtered out here so non-YouTube
        // sites (Vimeo, SoundCloud) that mix both don't yield an unusable
        // playlist URL.
        func progressive(_ f: Format) -> Bool {
            Self.isProgressiveDownloadable(formatID: f.format_id, ext: f.ext, url: f.url)
        }

        // Best audio-only (m4a preferred), restricted to containers
        // AVFoundation can play directly — so an opus/webm-only stream isn't
        // saved raw but routes to the muxed + extraction fallback below. Used
        // for audio mode and as the merge track for video-only downloads.
        let audioOnly = formats.filter {
            $0.isAudioOnly && progressive($0) && Self.playableAudioExts.contains($0.ext.lowercased())
        }
        let m4aAudio = audioOnly.filter { $0.ext == "m4a" }
        let bestAudio = (m4aAudio.isEmpty ? audioOnly : m4aAudio)
            .max(by: { ($0.abr ?? $0.tbr ?? 0) < ($1.abr ?? $1.tbr ?? 0) })

        let chosen: Format
        var mergeAudioRequest: URLRequest?
        var mergeAudioRefresh: AudioStreamDownloader.RequestRefresher?
        var extractAudioAfterDownload = false

        if mode == .video {
            // Pick the best video AVFoundation can actually decode. YouTube
            // often offers AV1/VP9 video-only streams that iOS can't play —
            // selecting one yields a file that scrubs but shows no picture
            // (and no audio). Restrict to H.264/HEVC progressive, tallest.
            let videoMP4 = formats.filter { !$0.isAudioOnly && $0.ext == "mp4" && progressive($0) }
            let playable = videoMP4.filter { PlayableVideoCodec.isPlayable(codec: $0.vcodec) }
            if playable.isEmpty {
                // Distinguish "all the video was HLS/streaming" (a non-YouTube
                // case) from "only undecodable codecs were offered" (the
                // AV1/VP9 case, which the recovery below can still rescue). It's
                // HLS-only when video exists but *none of it* is progressive.
                let hadAnyVideo = formats.contains { !$0.isAudioOnly && ($0.vcodec ?? "none") != "none" }
                let hadProgressiveVideo = formats.contains { !$0.isAudioOnly && progressive($0) }
                if hadAnyVideo && !hadProgressiveVideo {
                    appLog("Only HLS/streaming video formats offered — none progressively downloadable.",
                           level: .error, category: category)
                    throw ExtractorError.hlsOnly
                }
                let offered = videoMP4.compactMap { $0.vcodec }.filter { $0 != "none" }
                let list = offered.isEmpty ? "none" : Set(offered).sorted().joined(separator: ", ")
                // Tallest resolution offered in *any* codec — passed to the
                // recovery so it can explain a large quality drop (e.g. a 2160p
                // AV1-only source recovered as 360p H.264).
                let offeredHeight = formats.filter { !$0.isAudioOnly }.compactMap { $0.height }.max()
                appLog("Default extraction offered no device-playable video (need H.264/HEVC) — offered: \(list)\(offeredHeight.map { " up to \($0)p" } ?? "")",
                       level: .warning, category: category)
                // Recovery: re-resolve forcing a player client that returns
                // H.264. Bypasses the rest of this method on success.
                #if canImport(PythonKit)
                if let recovered = try await extractViaForcedClients(
                    url: url, mode: .video, quality: quality, category: category,
                    offeredVideoHeight: offeredHeight,
                    onDownloadStart: onDownloadStart, onProgress: onProgress) {
                    return recovered
                }
                #endif
                appLog("No device-playable video stream (need H.264/HEVC) — offered: \(list)",
                       level: .error, category: category)
                throw ExtractorError.unplayableVideoCodec(list)
            }
            guard let video = quality.pick(from: playable, height: { $0.height ?? 0 }) else {
                throw ExtractorError.noVideoFormat
            }
            chosen = video
            mergeAudioRequest = bestAudio.flatMap(makeRequest)
            mergeAudioRefresh = bestAudio.map { refresher(formatID: $0.format_id) }
            appLog("Selected video \(chosen.format_id) (\(chosen.height.map { "\($0)p" } ?? "?")\(quality.maxHeight.map { " · preference ≤\($0)p" } ?? "")) \(chosen.vcodec ?? "?") \(chosen.isVideoOnly ? "video-only — will merge audio" : "muxed")",
                   category: category)
        } else if let audio = bestAudio {
            chosen = audio
            appLog("Selected format \(chosen.format_id) · \(chosen.ext) · \(Int(chosen.abr ?? chosen.tbr ?? 0)) kbps",
                   category: category)
        } else {
            // No directly-playable audio-only stream: take the smallest
            // progressive muxed MP4 and extract its audio.
            let muxedMP4 = formats.filter { !$0.isAudioOnly && !$0.isVideoOnly && $0.ext == "mp4" && progressive($0) }
            guard let video = muxedMP4.min(by: { ($0.height ?? .max) < ($1.height ?? .max) }) else {
                // If the site offered formats but none were progressive, the
                // blocker is HLS, not a missing audio track — say which.
                let hadProgressive = formats.contains { progressive($0) }
                if !formats.isEmpty && !hadProgressive {
                    appLog("Only HLS/streaming formats offered — none progressively downloadable.",
                           level: .error, category: category)
                    throw ExtractorError.hlsOnly
                }
                throw ExtractorError.noAudioFormat
            }
            chosen = video
            extractAudioAfterDownload = true
            appLog("No audio-only stream — falling back to muxed video \(chosen.format_id) + audio extraction",
                   level: .warning, category: category)
        }

        guard let request = makeRequest(for: chosen) else {
            throw mode == .video ? ExtractorError.noVideoFormat : ExtractorError.noAudioFormat
        }

        let ext = chosen.ext.isEmpty ? "m4a" : chosen.ext
        var dest = AppPaths.work.appendingPathComponent("\(UUID().uuidString).\(ext)")

        let expected = chosen.filesize
        let sizeHint = expected.map { " (~\($0 / 1024 / 1024) MB)" } ?? ""
        appLog("Downloading \(mode == .video ? "video" : (extractAudioAfterDownload ? "video" : "audio")) stream in chunks\(sizeHint)…", category: category)
        onDownloadStart()

        try await AudioStreamDownloader.download(
            baseRequest: request,
            expectedSize: expected,
            to: dest,
            category: category,
            refresh: refresher(formatID: chosen.format_id),
            onProgress: onProgress
        )

        if mode == .video {
            dest = try await VideoMerger.ensureAudio(videoFile: dest, audioRequest: mergeAudioRequest,
                                                     audioRefresh: mergeAudioRefresh, category: category)
        } else if extractAudioAfterDownload {
            dest = try await VideoAudioExtractor.extractAudio(fromVideo: dest, category: category)
        }

        let verifiedDuration = try await MediaVerifier.verify(dest, isVideo: mode == .video, category: category)
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? nil
        let sizeText = size.map { " (\($0 / 1024) KB)" } ?? ""
        appLog("Download finished: \(dest.lastPathComponent)\(sizeText)", level: .success, category: category)

        return ExtractedMedia(
            fileURL: dest,
            title: info.title.isEmpty ? url.absoluteString : info.title,
            duration: info.duration ?? verifiedDuration,
            isVideo: mode == .video
        )
    }
#endif

#if canImport(YoutubeDL) && canImport(PythonKit)
    /// Builds a Python object that yt-dlp will treat as its `logger`, collecting
    /// every debug/info/warning/error message into a list we can drain into the
    /// app log afterwards. This is how yt-dlp's *own* diagnostics — "Sign in to
    /// confirm you're not a bot", "missing a PO token", "Some formats may be
    /// missing", signature/nsig failures — become visible, instead of being
    /// swallowed silently. Returns nil (capture simply disabled) if the tiny
    /// Python class can't be defined, so it never blocks an extraction.
    private func makeCaptureLogger() -> PythonObject? {
        let code = "class _OLLogger:\n"
            + "    def __init__(self):\n"
            + "        self.lines = []\n"
            + "    def debug(self, m):\n"
            + "        self.lines.append(('debug', str(m)))\n"
            + "    def info(self, m):\n"
            + "        self.lines.append(('info', str(m)))\n"
            + "    def warning(self, m):\n"
            + "        self.lines.append(('warning', str(m)))\n"
            + "    def error(self, m):\n"
            + "        self.lines.append(('error', str(m)))\n"
        do {
            let builtins = Python.import("builtins")
            let namespace = builtins.dict()
            _ = try builtins.exec.throwing.dynamicallyCall(withArguments: [code.pythonObject, namespace])
            return namespace["_OLLogger"]()
        } catch {
            appLog("yt-dlp log capture unavailable: \(error.localizedDescription)", level: .debug, category: "yt-dlp")
            return nil
        }
    }

    /// Forwards everything a capture logger collected into the app log, tagged
    /// with the client so it's clear which attempt produced it. yt-dlp's warning
    /// and error lines are the diagnostic gold; debug lines are kept but at
    /// `.debug` level. Capped to the most recent lines so a chatty extraction
    /// can't flood the log.
    private func drainCaptureLogger(_ logger: PythonObject, client: String, category: String) {
        let lines = logger.lines
        let count = Int(Python.len(lines)) ?? 0
        guard count > 0 else { return }
        let start = max(0, count - 50)
        for i in start..<count {
            let entry = lines[i]
            let kind = String(entry[0]) ?? "info"
            let message = (String(entry[1]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty { continue }
            let level: LogLevel = kind == "error" ? .error : (kind == "warning" ? .warning : .debug)
            appLog("yt-dlp(\(client)): \(message)", level: level, category: category)
        }
    }

    /// Re-resolves a URL forcing yt-dlp's `ios`/`web_safari`/… player clients,
    /// whose stream URLs need **no nsig descrambling** — the same renditions
    /// Safari plays. Used in two situations:
    ///
    /// - **Codec recovery** (`mode == .video`): the default extraction exposed
    ///   only video codecs AVFoundation can't decode (e.g. AV1-only, which
    ///   happens when the on-device player JS can't be resolved and every H.264
    ///   URL — needing descrambling — is dropped). These clients return decodable
    ///   H.264 (avc1).
    /// - **Timeout/failure recovery** (either mode): the default `extractInfo`
    ///   stalled or threw. On device, the default web client needs nsig
    ///   descrambling run through the slow pure-Python JS interpreter, which can
    ///   hang past the timeout; these clients skip that step entirely, so they're
    ///   fast and succeed for videos that play in the browser.
    ///
    /// Drives Python directly (mirroring YoutubeDL-iOS's own internal calls)
    /// because the structured `extractInfo` API can't pass `extractor_args`.
    /// `.throwing` converts Python exceptions to Swift errors, and every dict
    /// access uses `.get(...)` so a missing key yields Python `None` rather than
    /// trapping. Returns nil if no client yields a usable stream (caller then
    /// surfaces a clear error).
    /// - Parameter offeredVideoHeight: the tallest video resolution the *default*
    ///   extraction exposed (in any codec, including the undecodable AV1/VP9 we're
    ///   recovering from). Used only to explain in the log when the recovered
    ///   H.264 stream is much lower — so a 360p save from a 2160p video reads as a
    ///   codec limitation, not a silent quality bug.
    private func extractViaForcedClients(url: URL,
                                         mode: DownloadMode,
                                         quality: VideoQuality = .best,
                                         category: String,
                                         offeredVideoHeight: Int? = nil,
                                         onDownloadStart: @escaping () -> Void,
                                         onProgress: @escaping (Double) -> Void) async throws -> ExtractedMedia? {
        // Try clients one at a time with fallback: an unsupported client name
        // (older on-device yt-dlp) or a PO-token-gated client fails only its own
        // attempt instead of the whole recovery. The order is **mode-aware**,
        // because the right trade-off differs:
        //
        // - **Audio**: stream resolution is irrelevant, so we lead with the
        //   pre-signed clients (`ios`, `android`) whose format URLs need no nsig
        //   descrambling *and* aren't subject to YouTube's `tv`-client DRM
        //   experiment (yt-dlp #12563, which wraps all `tv` formats in DRM for
        //   some sessions and is undownloadable). `tv` follows only as a backup.
        //   This avoids wasting a client attempt on a DRM/EJS-gated `tv` resolve.
        // - **Video**: quality matters, so `tv` leads — it serves the highest-
        //   resolution H.264 (up to 1080p) with no nsig — and when its DRM
        //   experiment is active for the session it fails fast, falling to `ios`.
        //
        // `android`'s renditions are often capped low (360p) when SABR strips its
        // formats — fine for audio, which is why it sits behind `ios` there. The
        // web-family clients (`web_safari`/`mweb`/`web`) come last in both: on
        // device they almost always fail the n-challenge (no JS runtime), so
        // they're a last resort. We accept the first client that yields a usable
        // stream, so this order is what decides quality and which client wins.
        // Wire the on-device JS runtime for the forced clients below, under
        // the app-wide Python gate: `load_all_plugins()` (the plugin import)
        // must never overlap another `extract_info`, and with two pipeline
        // slots the gate — not the old idle-interpreter heuristic — is what
        // guarantees that. Python is fully bootstrapped by the default
        // `extractInfo` that preceded us. With the runtime live, the
        // web-family clients below resolve their n-challenge in JavaScriptCore
        // and get a minted PO token, instead of failing.
        try? await PythonGate.shared.run { PythonBridge.configureIfNeeded() }

        // The client order still leads with the pre-signed no-token clients
        // (`tv` for video quality, `ios` for audio); the web-family clients —
        // now resolvable thanks to on-device nsig solving + PO tokens — are the
        // fallback tier.
        let clientSets: [[String]] = mode == .video
            ? [["tv"], ["ios"], ["android"], ["web_safari"], ["mweb"], ["web"]]
            : [["ios"], ["android"], ["tv"], ["web_safari"], ["mweb"], ["web"]]

        for clients in clientSets {
            let label = clients.joined(separator: ",")
            appLog("Forced-client extract: re-resolving with player client \(label)…",
                   level: .warning, category: category)

            let info: ForcedInfo
            do {
                // The dict → Swift snapshot happens inside the gated section;
                // from here on this attempt holds no Python objects at all.
                info = try await forcedClientResolve(url: url, clients: clients, label: label, category: category) { [self] raw in
                    snapshotInfo(raw)
                }
            } catch {
                appLog("Forced-client extract: client \(label) failed: \(error.localizedDescription)",
                       level: .warning, category: category)
                // localizedDescription is the opaque "PythonError error 0"; the
                // full value carries the real Python exception text.
                let detail = String(describing: error)
                appLog("Forced-client detail (\(label)): \(detail)", level: .debug, category: category)
                if let hint = Self.diagnosticHint(for: "\(error.localizedDescription) \(detail)") {
                    appLog("Hint (\(label)): \(hint)", level: .warning, category: category)
                }
                continue
            }

            // A download-stage failure (stream URL rejected even after refreshes,
            // or a truncated/unplayable result) shouldn't sink the whole
            // recovery — the next client resolves *different* URLs that often
            // work. Only cancellation stops the loop.
            do {
                let media = mode == .video
                    ? try await downloadPlayable(from: info, client: label, url: url,
                                                 quality: quality,
                                                 category: category, offeredVideoHeight: offeredVideoHeight,
                                                 onDownloadStart: onDownloadStart, onProgress: onProgress)
                    : try await downloadBestAudio(from: info, client: label, url: url,
                                                  category: category,
                                                  onDownloadStart: onDownloadStart, onProgress: onProgress)
                if let media { return media }
                appLog("Forced-client extract: client \(label) returned no usable \(mode == .video ? "H.264/HEVC video" : "audio") — trying next.",
                       category: category)
            } catch {
                if isCancellation(error) { throw error }
                // Local failures (full disk, permissions) would fail
                // identically on every client — surface them instead of
                // re-downloading the stream several more times.
                guard Self.isDownloadStageError(error) else { throw error }
                appLog("Forced-client extract: client \(label) download failed (\(error.localizedDescription)) — trying next client.",
                       level: .warning, category: category)
            }
        }

        appLog("Forced-client extract: no player client produced a usable \(mode == .video ? "video" : "audio") stream.",
               level: .error, category: category)
        return nil
    }

    /// Runs one forced-client `extract_info` and returns the resolved info
    /// dict. Shared by the client loop above and by the mid-download URL
    /// refreshers. Hard per-client cap (the heartbeat alone never bounded this,
    /// so a client that hung inside Python stalled the whole download with no
    /// further log output). Breadcrumbs around each Python call are written to
    /// the durable on-disk log *before* the call runs, so if the interpreter
    /// faults the process the last persisted line names exactly which step died.
    /// `transform` runs **inside the gated Python section**, right after
    /// `extract_info` returns, and must reduce the info dict to plain Swift
    /// values — nothing downstream may keep a `PythonObject`, because once the
    /// gate is released another slot's Python call may be executing, and even
    /// a dict traversal would then be a concurrent interpreter access.
    private func forcedClientResolve<T>(url: URL,
                                        clients: [String],
                                        label: String,
                                        category: String,
                                        transform: @escaping (PythonObject) throws -> T) async throws -> T {
        try await withTimeout("Forced-client (\(label)) re-resolve", category: category, seconds: 60) {
            try await withHeartbeat("Still re-resolving (\(label))", category: category) {
                // Everything that touches the interpreter — the capture-logger
                // object included — runs under the app-wide Python gate, in a
                // detached task that keeps the gate if this attempt is
                // abandoned by the timeout above.
                try await PythonGate.shared.run { [self] in
                    let logger = makeCaptureLogger()
                    do {
                        appLog("Importing yt_dlp module (client \(label))…", level: .debug, category: category)
                        let ytdlpModule = Python.import("yt_dlp")
                        // A `None` logger is what yt-dlp falls back to anyway, so this
                        // is a no-op when capture couldn't be installed.
                        let options: PythonObject = [
                            "quiet": true,
                            "noplaylist": true,
                            "nocheckcertificate": true,
                            "extractor_args": ["youtube": ["player_client": PythonObject(clients)]],
                            "logger": logger ?? Python.None,
                        ]
                        let ytdlp = ytdlpModule.YoutubeDL(options)
                        appLog("Running extract_info (client \(label))…", level: .debug, category: category)
                        let result = try ytdlp.extract_info.throwing.dynamicallyCall(withKeywordArguments: [
                            "": url.absoluteString, "download": false, "process": true,
                        ])
                        appLog("extract_info returned (client \(label)).", level: .debug, category: category)
                        // Surface any warnings yt-dlp emitted even on a success
                        // (skipped formats, PO-token notices) — they explain odd
                        // selections later.
                        if let logger { drainCaptureLogger(logger, client: label, category: category) }
                        return try transform(result)
                    } catch {
                        // Drain first: yt-dlp's logger usually holds the *real*
                        // reason (bot check, unavailable, signature failure) the
                        // bare exception text only hints at.
                        if let logger { drainCaptureLogger(logger, client: label, category: category) }
                        throw error
                    }
                }
            }
        }
    }

    /// Builds the refresher a forced-client download hands to
    /// `AudioStreamDownloader`: re-runs the same client's extraction and
    /// returns a request for the same `format_id`, so a stream URL that goes
    /// stale mid-download (403) gets replaced and the download resumes from its
    /// current offset instead of failing.
    /// Builds a `URLRequest` for a resolved Python format dict, carrying its
    /// `http_headers` — the one definition shared by the candidate builders
    /// and the refreshers, so headers can't drift between the original request
    /// and its mid-download replacement.
    private static func requestForPythonFormat(_ format: PythonObject) -> URLRequest? {
        guard let urlString = String(format.get("url")), let u = URL(string: urlString) else { return nil }
        var r = URLRequest(url: u)
        let h = format.get("http_headers")
        if h != Python.None {
            for key in h.keys() {
                if let k = String(key), let v = String(h[key]) { r.setValue(v, forHTTPHeaderField: k) }
            }
        }
        return r
    }

    private func forcedClientRefresher(url: URL,
                                       label: String,
                                       formatID: String,
                                       category: String) -> AudioStreamDownloader.RequestRefresher {
        let clients = label.split(separator: ",").map(String.init)
        return { [weak self] in
            guard let self, !formatID.isEmpty else { return nil }
            // The format lookup runs inside the gated Python section, so the
            // dict traversal can't overlap another slot's interpreter work.
            let request: URLRequest? = try await self.forcedClientResolve(
                url: url, clients: clients, label: label, category: category
            ) { info in
                let formatsObj = info.get("formats")
                if formatsObj == Python.None { return nil }
                for format in formatsObj where (String(format.get("format_id")) ?? "") == formatID {
                    if let request = Self.requestForPythonFormat(format) { return request }
                }
                return nil
            }
            if request == nil {
                appLog("Fresh (\(label)) extraction no longer offers format \(formatID).",
                       level: .warning, category: category)
            }
            return request
        }
    }

    /// Whether a format dict is a single, range-fetchable file. Uses yt-dlp's
    /// `protocol` field when present (the authoritative signal — rejects
    /// `m3u8*`, `http_dash_segments`, `ism`, `rtmp`, `mhtml`) and falls back to
    /// the id/ext/url heuristic otherwise.
    private func isProgressivePython(_ format: PythonObject) -> Bool {
        let proto = (String(format.get("protocol")) ?? "").lowercased()
        if proto.contains("m3u8") || proto.contains("dash_segments")
            || proto == "mhtml" || proto == "ism" || proto == "rtmp" {
            return false
        }
        return Self.isProgressiveDownloadable(
            formatID: String(format.get("format_id")) ?? "",
            ext: String(format.get("ext")) ?? "",
            url: String(format.get("url")) ?? "")
    }

    /// A plain-Swift snapshot of one format from a forced-client resolve,
    /// captured under the Python gate so nothing downstream touches the
    /// interpreter.
    private struct ForcedFormat {
        let url: String
        let formatID: String
        let ext: String
        let vcodec: String
        let acodec: String
        /// Nil when the dict carries no height (audio-only formats).
        let height: Int?
        let abr: Double
        let progressive: Bool
        let headers: [String: String]

        var hasVideo: Bool { vcodec != "none" && !vcodec.isEmpty }
        var hasAudio: Bool { acodec != "none" && !acodec.isEmpty }
    }

    /// The forced-client info dict reduced to the Swift values the download
    /// stage needs.
    private struct ForcedInfo {
        let title: String?
        let duration: Double
        let formats: [ForcedFormat]
    }

    /// Reduces a resolved info dict to `ForcedInfo`. Must be called **inside**
    /// the gated Python section (it traverses `PythonObject`s). Every dict
    /// read uses `.get(...)` so a missing key yields Python `None` rather than
    /// trapping.
    private func snapshotInfo(_ info: PythonObject) -> ForcedInfo {
        var formats: [ForcedFormat] = []
        let formatsObj = info.get("formats")
        if formatsObj != Python.None {
            for format in formatsObj {
                guard let furl = String(format.get("url")) else { continue }
                var headers: [String: String] = [:]
                let h = format.get("http_headers")
                if h != Python.None {
                    for key in h.keys() {
                        if let k = String(key), let v = String(h[key]) { headers[k] = v }
                    }
                }
                formats.append(ForcedFormat(
                    url: furl,
                    formatID: String(format.get("format_id")) ?? "",
                    ext: (String(format.get("ext")) ?? "").lowercased(),
                    vcodec: String(format.get("vcodec")) ?? "none",
                    acodec: String(format.get("acodec")) ?? "none",
                    height: Int(format.get("height")),
                    abr: Double(format.get("abr")) ?? Double(Int(format.get("tbr")) ?? 0),
                    progressive: isProgressivePython(format),
                    headers: headers))
            }
        }
        return ForcedInfo(title: String(info.get("title")),
                          duration: Double(info.get("duration")) ?? 0,
                          formats: formats)
    }

    /// Builds a `URLRequest` for a snapshotted format, carrying its headers —
    /// shared by both download stages so headers can't drift.
    private static func request(for format: ForcedFormat) -> URLRequest? {
        guard let u = URL(string: format.url) else { return nil }
        var r = URLRequest(url: u)
        for (key, value) in format.headers { r.setValue(value, forHTTPHeaderField: key) }
        return r
    }

    /// Picks the tallest H.264/HEVC video (+ best m4a audio) from a resolved
    /// forced-client snapshot and downloads + merges it. Returns nil if it has
    /// no decodable, progressively-downloadable video.
    private func downloadPlayable(from info: ForcedInfo,
                                  client: String,
                                  url: URL,
                                  quality: VideoQuality = .best,
                                  category: String,
                                  offeredVideoHeight: Int? = nil,
                                  onDownloadStart: @escaping () -> Void,
                                  onProgress: @escaping (Double) -> Void) async throws -> ExtractedMedia? {
        let candidates = info.formats.filter { $0.progressive }
        let videos = candidates.filter {
            $0.hasVideo && $0.ext == "mp4" && PlayableVideoCodec.isPlayable(codec: $0.vcodec)
        }
        let audios = candidates.filter { $0.hasAudio && !$0.hasVideo && $0.ext == "m4a" }

        guard let video = quality.pick(from: videos, height: { $0.height ?? 0 }) else { return nil }
        let videoHeight = video.height ?? 0
        let audio = audios.max(by: { $0.abr < $1.abr })
        appLog("Recovery (\(client)) selected H.264 video \(videoHeight)p\(quality.maxHeight.map { " (preference ≤\($0)p)" } ?? "") (\(video.vcodec))\(audio == nil ? " · no separate audio" : " + m4a audio")",
               level: .success, category: category)
        // If YouTube offered the video at a notably higher resolution but only in
        // a codec this device can't decode (AV1/VP9), say so — otherwise a 360p
        // save from a 2160p source looks like a bug rather than a codec ceiling.
        if let offered = offeredVideoHeight, offered >= videoHeight + 240 {
            appLog("Note: the highest resolution offered was \(offered)p, but only as AV1/VP9, which this device can't decode — \(videoHeight)p is the best H.264 (device-playable) rendition available.",
                   level: .warning, category: category)
        }

        guard let videoRequest = Self.request(for: video) else { return nil }
        let audioRequest = audio.flatMap { Self.request(for: $0) }

        let title = info.title ?? url.absoluteString
        let reportedDuration = info.duration

        var dest = AppPaths.work.appendingPathComponent("\(UUID().uuidString).mp4")
        appLog("Downloading recovered video stream in chunks…", category: category)
        onDownloadStart()
        try await AudioStreamDownloader.download(
            baseRequest: videoRequest, expectedSize: nil, to: dest, category: category,
            refresh: forcedClientRefresher(url: url, label: client, formatID: video.formatID, category: category),
            onProgress: onProgress)
        dest = try await VideoMerger.ensureAudio(
            videoFile: dest, audioRequest: audioRequest,
            audioRefresh: audio.map { forcedClientRefresher(url: url, label: client, formatID: $0.formatID, category: category) },
            category: category)

        let verifiedDuration = try await MediaVerifier.verify(dest, isVideo: true, category: category)
        let duration = reportedDuration > 0 ? reportedDuration : verifiedDuration
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? nil
        appLog("Recovery download finished: \(dest.lastPathComponent)\(size.map { " (\($0 / 1024) KB)" } ?? "")",
               level: .success, category: category)
        return ExtractedMedia(fileURL: dest, title: title, duration: duration, isVideo: true)
    }

    /// Audio counterpart to `downloadPlayable`: picks the best audio from a
    /// forced-client snapshot — a dedicated audio-only m4a if present (no
    /// transcoding), otherwise the smallest muxed mp4 with its audio extracted to
    /// m4a. Mirrors the default path's audio selection. Returns nil if the
    /// snapshot offers no usable audio.
    private func downloadBestAudio(from info: ForcedInfo,
                                   client: String,
                                   url: URL,
                                   category: String,
                                   onDownloadStart: @escaping () -> Void,
                                   onProgress: @escaping (Double) -> Void) async throws -> ExtractedMedia? {
        let candidates = info.formats.filter { $0.progressive }
        // Accept any audio-only container AVFoundation can play directly
        // (m4a/mp3/aac/…) — covers SoundCloud's progressive mp3, not just
        // YouTube's m4a. Unplayable (opus/webm) audio is ignored here and
        // handled by the muxed-extraction fallback.
        let audios = candidates.filter {
            $0.hasAudio && !$0.hasVideo && Self.playableAudioExts.contains($0.ext)
        }
        let muxed = candidates.filter { $0.hasAudio && $0.hasVideo && $0.ext == "mp4" }

        let title = info.title ?? url.absoluteString
        let reportedDuration = info.duration

        // Prefer a dedicated audio-only stream — no transcoding, no extraction
        // step. Keep its real container extension (m4a, mp3, …).
        if let audio = audios.max(by: { $0.abr < $1.abr }),
           let audioRequest = Self.request(for: audio) {
            appLog("Forced-client (\(client)) selected audio-only \(audio.ext) \(Int(audio.abr)) kbps",
                   level: .success, category: category)
            let dest = AppPaths.work.appendingPathComponent("\(UUID().uuidString).\(audio.ext.isEmpty ? "m4a" : audio.ext)")
            onDownloadStart()
            try await AudioStreamDownloader.download(
                baseRequest: audioRequest, expectedSize: nil, to: dest, category: category,
                refresh: forcedClientRefresher(url: url, label: client, formatID: audio.formatID, category: category),
                onProgress: onProgress)
            let verifiedDuration = try await MediaVerifier.verify(dest, isVideo: false, category: category)
            let duration = reportedDuration > 0 ? reportedDuration : verifiedDuration
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? nil
            appLog("Forced-client audio download finished: \(dest.lastPathComponent)\(size.map { " (\($0 / 1024) KB)" } ?? "")",
                   level: .success, category: category)
            return ExtractedMedia(fileURL: dest, title: title, duration: duration, isVideo: false)
        }

        // No audio-only stream: take the smallest muxed mp4 and extract its audio.
        guard let video = muxed.min(by: { ($0.height ?? Int.max) < ($1.height ?? Int.max) }),
              let videoRequest = Self.request(for: video) else {
            return nil
        }
        appLog("Forced-client (\(client)) no audio-only stream — using muxed mp4 \(video.height.map { "\($0)p" } ?? "?p") + audio extraction",
               level: .warning, category: category)
        var dest = AppPaths.work.appendingPathComponent("\(UUID().uuidString).mp4")
        onDownloadStart()
        try await AudioStreamDownloader.download(
            baseRequest: videoRequest, expectedSize: nil, to: dest, category: category,
            refresh: forcedClientRefresher(url: url, label: client, formatID: video.formatID, category: category),
            onProgress: onProgress)
        dest = try await VideoAudioExtractor.extractAudio(fromVideo: dest, category: category)

        let verifiedDuration = try await MediaVerifier.verify(dest, isVideo: false, category: category)
        let duration = reportedDuration > 0 ? reportedDuration : verifiedDuration
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? nil
        appLog("Forced-client audio extraction finished: \(dest.lastPathComponent)\(size.map { " (\($0 / 1024) KB)" } ?? "")",
               level: .success, category: category)
        return ExtractedMedia(fileURL: dest, title: title, duration: duration, isVideo: false)
    }
#endif

    func extractMedia(from url: URL,
                      mode: DownloadMode,
                      quality: VideoQuality,
                      onDownloadStart: @escaping () -> Void,
                      onProgress: @escaping (Double) -> Void) async throws -> ExtractedMedia {
        let category = "yt-dlp"
        #if canImport(YoutubeDL)
        // Canonicalise away the mobile host / tracking params before handing the
        // URL to yt-dlp (they can trigger a slower extraction path on device).
        let originalURL = url
        let url = Self.canonicalURL(url)
        do {
            if url != originalURL {
                appLog("Normalized URL \(originalURL.absoluteString) → \(url.absoluteString)",
                       level: .debug, category: category)
            }
            appLog("Resolving \(url.absoluteString)", category: category)

            // First run: fetch the on-device yt-dlp Python module if missing.
            // Under the Python gate so two first-run slots can't race the
            // module download/unpack (the second waits, then finds it present).
            let modulePath = YoutubeDL.pythonModuleURL.path
            if FileManager.default.fileExists(atPath: modulePath) {
                appLog("yt-dlp Python module present.", level: .debug, category: category)
            } else {
                appLog("yt-dlp Python module not found — downloading (first run, can take a while)…",
                       level: .warning, category: category)
                try await PythonGate.shared.acquire()
                do {
                    if !FileManager.default.fileExists(atPath: modulePath) {
                        try await YoutubeDL.downloadPythonModule()
                        appLog("yt-dlp Python module downloaded.", level: .success, category: category)
                    }
                    PythonGate.shared.release()
                } catch {
                    PythonGate.shared.release()
                    throw error
                }
            }

            appLog("Initializing yt-dlp…", level: .debug, category: category)
            // Instance creation configures library-side state (PYTHONHOME,
            // module search path) — gated so it can't overlap the other slot's
            // interpreter work.
            let youtubeDL = try await PythonGate.shared.run { YoutubeDL() }

            // Register the on-device JS runtime *before* this job's default
            // extraction, so the extraction solves nsig in JavaScriptCore instead
            // of grinding it in pure Python — which runs the full timeout and
            // leaves an uncancellable orphan holding the interpreter, the reason
            // hard videos never recover even on retry. For YouTube we start Python
            // ourselves (the wrapper's exact init sequence) and wire the providers
            // up front, on the very first download. Runs under the Python gate so
            // the plugin import never races a running extraction — including the
            // other pipeline slot's.
            //
            // This early bootstrap faulted once before (it skipped the fake-Popen
            // shim); it now mirrors the wrapper step-for-step with breadcrumbs, and
            // falls through to the lazy path if it can't bootstrap.
            #if canImport(PythonKit)
            if Self.isYouTubeURL(url), orphanedDefaultExtraction == nil {
                try? await PythonGate.shared.run {
                    PythonBridge.bootstrapAndConfigure(pythonAlreadyInitialized: Self.pythonBootstrapped)
                }
            }
            #endif
            await wireJSRuntimeIfSafe(category: category)

            // The default web-client extraction (`extractInfo`) must run first: it
            // is the call that bootstraps the embedded Python runtime (PYTHONHOME,
            // the unpacked stdlib, PythonKit's module search path). The forced-
            // client recovery below drives Python directly, so running it before
            // any `extractInfo` crashes with "No module named 'encodings'".
            //
            // The timeout used to be a *short* 15s for YouTube, on the theory
            // that the default web client would grind nsig through the slow
            // pure-Python JS interpreter and stall. But modern yt-dlp
            // (2026.x) with no JS runtime no longer defaults to the web client —
            // it uses the JS-less `android_vr` client, which needs no nsig and
            // just makes a network call. The 15s grace was cutting that
            // legitimate (occasionally slow) resolve off mid-flight, which is
            // what produced the "timed out → orphan → crash" chain on videos that
            // are otherwise perfectly downloadable. A network call can't hang the
            // interpreter the way pure-Python nsig could, so YouTube now gets a
            // generous window too. (Once the on-device JS runtime is wired, the
            // web client's nsig is solved in JavaScriptCore in a couple of
            // seconds, so this never reintroduces the old stall.)
            let infoTimeout: TimeInterval = Self.isYouTubeURL(url) ? 60 : 90

            appLog("Extracting video info (running yt-dlp)…", category: category)
            let formats: [Format]
            let info: Info
            do {
                (formats, info) = try await resolveInfo(youtubeDL, url: url, category: category, timeout: infoTimeout)
                // extract_info ran, so Python is bootstrapped for the session.
                Self.pythonBootstrapped = true
            } catch {
                // The default extraction stalled (the on-device web client needs
                // nsig descrambling via the slow pure-Python JS interpreter, which
                // can hang past the timeout) or failed outright. Retry forcing the
                // tv/ios/… player clients, whose URLs need no descrambling — fast,
                // and the same renditions Safari plays, so they succeed for videos
                // that work in the browser. Python is already initialized by the
                // extractInfo attempt above, so the direct PythonKit calls are
                // safe here. Cancellation is never retried.
                // extract_info ran (even though it threw/timed out), so Python is
                // bootstrapped — a later job can safely wire the JS runtime.
                Self.pythonBootstrapped = true
                if isCancellation(error) { throw error }
                #if canImport(PythonKit)
                appLog("Default extraction failed (\(error.localizedDescription)) — retrying with forced fast player clients…",
                       level: .warning, category: category)
                // The forced clients drive Python directly. Running a second
                // `extract_info` while the timed-out one is still executing in the
                // interpreter is the concurrent-Python fault that crashes the app,
                // so only proceed once the orphan has genuinely settled (waiting a
                // generous window for a slow-but-finishing nsig). If it won't
                // settle, fail cleanly rather than risk the crash.
                if await waitForOrphanedExtraction(category: category, cap: 30) {
                    if let media = try await extractViaForcedClients(
                        url: url, mode: mode, quality: quality, category: category,
                        onDownloadStart: onDownloadStart, onProgress: onProgress) {
                        return media
                    }
                } else {
                    appLog("Skipping forced-client recovery — the timed-out extraction is still running in the interpreter; a second concurrent one risks a crash.",
                           level: .error, category: category)
                }
                #endif
                throw error
            }
            appLog("Info: \"\(info.title)\" · \(formats.count) formats · \(Int(info.duration ?? 0))s",
                   level: .success, category: category)

            // The default extractInfo just *succeeded*, so nothing is orphaned in
            // the interpreter — register the JS-runtime providers for the rest of
            // the session (doesn't affect this already-resolved job, but every
            // later default-web resolve gets on-device nsig solving and, with
            // `botguard.js`, PO-token minting). Idempotent and orphan-guarded.
            await wireJSRuntimeIfSafe(category: category)

            do {
                return try await downloadUsingDefaultInfo(
                    formats: formats, info: info, youtubeDL: youtubeDL,
                    url: url, mode: mode, quality: quality, category: category,
                    onDownloadStart: onDownloadStart, onProgress: onProgress)
            } catch {
                if isCancellation(error) { throw error }
                // A failure *after* a successful extraction — the stream URL
                // rejected even across refreshes, a truncated or unplayable
                // result, a failed merge — is usually specific to the URLs this
                // client handed out; a different player client resolves
                // different URLs that often work. Format-shape verdicts and
                // local (disk/permission) errors are excluded, and so are
                // non-YouTube sites: `player_client` only changes anything for
                // YouTube, so the sweep would just repeat the same extraction.
                guard Self.isDownloadStageError(error), Self.isYouTubeURL(url) else { throw error }
                #if canImport(PythonKit)
                appLog("Download failed after a successful extraction (\(error.localizedDescription)) — retrying with forced player clients…",
                       level: .warning, category: category)
                // A timed-out mid-download refresh may have orphaned a Python
                // extract_info; only start new Python work once it has settled, so
                // two extractions never run concurrently in the interpreter.
                if await waitForOrphanedExtraction(category: category, cap: 30) {
                    if let media = try await extractViaForcedClients(
                        url: url, mode: mode, quality: quality, category: category,
                        onDownloadStart: onDownloadStart, onProgress: onProgress) {
                        return media
                    }
                } else {
                    appLog("Skipping forced-client recovery — a prior extraction is still running in the interpreter; a second concurrent one risks a crash.",
                           level: .error, category: category)
                }
                #endif
                throw error
            }
        } catch {
            appLog("yt-dlp failed: \(error.localizedDescription)", level: .error, category: category)
            // The localized description hides yt-dlp/Python exception text; the
            // full value usually contains the real reason (e.g. "Sign in to
            // confirm you're not a bot", "Video unavailable").
            let detail = String(describing: error)
            appLog("Detail: \(detail)", level: .debug, category: category)
            if let hint = Self.diagnosticHint(for: "\(error.localizedDescription) \(detail)") {
                appLog("Hint: \(hint)", level: .warning, category: category)
            }
            // A signature/nsig failure usually means the cached yt-dlp module is
            // stale relative to YouTube's player JS. Refresh it once per session
            // automatically — instead of waiting for the user to discover
            // ⋯ → Refresh yt-dlp engine — and retry this URL from scratch. A
            // *failed* refresh (offline, CDN hiccup) doesn't spend the budget:
            // retrying with the same stale module is pointless now, but a later
            // download should still get its shot once connectivity is back.
            if !isCancellation(error), !Self.didAutoRefreshEngine,
               Self.errorSuggestsStaleEngine("\(error.localizedDescription) \(detail)") {
                appLog("The failure signature points at a stale yt-dlp engine — refreshing it and retrying once…",
                       level: .warning, category: category)
                if await Self.refreshEngine() {
                    Self.didAutoRefreshEngine = true
                    return try await extractMedia(from: originalURL, mode: mode, quality: quality,
                                                  onDownloadStart: onDownloadStart, onProgress: onProgress)
                }
            }
            throw (error as? ExtractorError) ?? ExtractorError.downloadFailed(error.localizedDescription)
        }
        #else
        throw ExtractorError.packageUnavailable
        #endif
    }
}

/// Lets you exercise the queue/library/player UI without the native package by
/// generating a placeholder entry. Swap `DownloadManager`'s default extractor to
/// this in previews or simulator smoke tests.
final class MockExtractor: MediaExtractor {
    func extractMedia(from url: URL,
                      mode: DownloadMode,
                      quality: VideoQuality,
                      onDownloadStart: @escaping () -> Void,
                      onProgress: @escaping (Double) -> Void) async throws -> ExtractedMedia {
        appLog("Mock: extracting info…", category: "yt-dlp")
        try await Task.sleep(nanoseconds: 400_000_000)
        onDownloadStart()
        appLog("Mock: downloading…", category: "yt-dlp")
        for step in 1...5 {
            try await Task.sleep(nanoseconds: 160_000_000)
            onProgress(Double(step) / 5)
        }
        let ext = mode == .video ? "mp4" : "m4a"
        let dest = AppPaths.work.appendingPathComponent("\(UUID().uuidString).\(ext)")
        // A real file isn't produced here; the mock is only for UI flow testing.
        FileManager.default.createFile(atPath: dest.path, contents: Data())
        return ExtractedMedia(fileURL: dest, title: "Mock Track \(Int.random(in: 1...999))", duration: 180, isVideo: mode == .video)
    }
}
