import Foundation
import AVFoundation

#if canImport(YoutubeDL)
import YoutubeDL
#endif

/// Result of extracting + downloading media for a URL.
struct ExtractedMedia {
    /// On-disk location of the downloaded file (`.m4a` for audio, `.mp4` for video).
    let fileURL: URL
    let title: String
    let duration: Double
    let isVideo: Bool
}

enum ExtractorError: LocalizedError {
    case packageUnavailable
    case invalidURL
    case noAudioFormat
    case noVideoFormat
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
        case .downloadFailed(let message):
            return message
        }
    }
}

/// Reads the duration of a local media file (audio or video).
func mediaDuration(of url: URL) async -> Double {
    guard let seconds = try? await AVURLAsset(url: url).load(.duration).seconds,
          seconds.isFinite else { return 0 }
    return seconds
}

/// Abstraction over the extraction step so the rest of the app is independent of
/// the concrete library and can be unit-tested with a mock.
protocol MediaExtractor {
    /// Downloads the best audio-only stream (`.audio`) or the best muxed
    /// video+audio MP4 (`.video`) for `url`.
    /// - Parameter onDownloadStart: invoked once the info has been resolved and
    ///   the actual download is about to begin.
    /// - Parameter onProgress: 0...1 download fraction (when the size is known).
    func extractMedia(from url: URL,
                      mode: DownloadMode,
                      onDownloadStart: @escaping () -> Void,
                      onProgress: @escaping (Double) -> Void) async throws -> ExtractedMedia
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
    /// Deletes the cached yt-dlp Python module and re-downloads it. Useful when
    /// extraction starts failing because the engine is stale relative to
    /// YouTube's frequent changes.
    static func refreshEngine() async {
        let category = "yt-dlp"
        #if canImport(YoutubeDL)
        appLog("Refreshing yt-dlp engine…", level: .warning, category: category)
        try? FileManager.default.removeItem(at: YoutubeDL.pythonModuleURL)
        do {
            try await YoutubeDL.downloadPythonModule()
            appLog("yt-dlp engine refreshed.", level: .success, category: category)
        } catch {
            appLog("Engine refresh failed: \(error.localizedDescription)", level: .error, category: category)
        }
        #else
        appLog("YoutubeDL is not linked.", level: .error, category: category)
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
    /// ever running. If it times out we abandon the extraction (the orphaned
    /// Python work keeps running until it returns, but the queue moves on).
    private func resolveInfo(_ youtubeDL: YoutubeDL,
                             url: URL,
                             category: String,
                             timeout: TimeInterval = 90) async throws -> ([Format], Info) {
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

        let extraction = Task { try await youtubeDL.extractInfo(url: url) }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<([Format], Info), Error>) in
            let lock = NSLock()
            var finished = false
            func finish(_ work: () -> Void) {
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                work()
            }

            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                finish {
                    extraction.cancel()
                    continuation.resume(throwing: ExtractorError.downloadFailed(
                        "Timed out after \(Int(timeout))s extracting info. YouTube may have changed — try the ⋯ menu → Refresh yt-dlp engine, or a different video."))
                }
                timer.cancel()
            }
            timer.resume()

            Task {
                do {
                    let value = try await extraction.value
                    finish { timer.cancel(); continuation.resume(returning: value) }
                } catch {
                    finish { timer.cancel(); continuation.resume(throwing: error) }
                }
            }
        }
    }
#endif

    func extractMedia(from url: URL,
                      mode: DownloadMode,
                      onDownloadStart: @escaping () -> Void,
                      onProgress: @escaping (Double) -> Void) async throws -> ExtractedMedia {
        let category = "yt-dlp"
        #if canImport(YoutubeDL)
        do {
            appLog("Resolving \(url.absoluteString)", category: category)

            // First run: fetch the on-device yt-dlp Python module if missing.
            let modulePath = YoutubeDL.pythonModuleURL.path
            if FileManager.default.fileExists(atPath: modulePath) {
                appLog("yt-dlp Python module present.", level: .debug, category: category)
            } else {
                appLog("yt-dlp Python module not found — downloading (first run, can take a while)…",
                       level: .warning, category: category)
                try await YoutubeDL.downloadPythonModule()
                appLog("yt-dlp Python module downloaded.", level: .success, category: category)
            }

            appLog("Initializing yt-dlp…", level: .debug, category: category)
            let youtubeDL = YoutubeDL()

            appLog("Extracting video info (running yt-dlp)…", category: category)
            let (formats, info) = try await resolveInfo(youtubeDL, url: url, category: category)
            appLog("Info: \"\(info.title)\" · \(formats.count) formats · \(Int(info.duration ?? 0))s",
                   level: .success, category: category)

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

            // Best audio-only (m4a preferred) — used directly for audio mode and
            // as the track to merge for video-only video downloads.
            let audioOnly = formats.filter { $0.isAudioOnly }
            let m4aAudio = audioOnly.filter { $0.ext == "m4a" }
            let bestAudio = (m4aAudio.isEmpty ? audioOnly : m4aAudio)
                .max(by: { ($0.abr ?? $0.tbr ?? 0) < ($1.abr ?? $1.tbr ?? 0) })

            let chosen: Format
            var mergeAudioRequest: URLRequest?
            var extractAudioAfterDownload = false

            if mode == .video {
                // Best MP4 carrying video (muxed or video-only); AVFoundation needs
                // MP4/avc1. If it's video-only we merge the best audio afterwards.
                let videoMP4 = formats.filter { !$0.isAudioOnly && $0.ext == "mp4" }
                guard let video = videoMP4.max(by: { ($0.height ?? 0) < ($1.height ?? 0) }) else {
                    throw ExtractorError.noVideoFormat
                }
                chosen = video
                mergeAudioRequest = bestAudio.flatMap(makeRequest)
                appLog("Selected video \(chosen.format_id) (\(chosen.height.map { "\($0)p" } ?? "?")) \(chosen.isVideoOnly ? "video-only — will merge audio" : "muxed")",
                       category: category)
            } else if let audio = bestAudio {
                chosen = audio
                appLog("Selected format \(chosen.format_id) · \(chosen.ext) · \(Int(chosen.abr ?? chosen.tbr ?? 0)) kbps",
                       category: category)
            } else {
                // No audio-only stream: take the smallest muxed MP4 and extract its audio.
                let muxedMP4 = formats.filter { !$0.isAudioOnly && !$0.isVideoOnly && $0.ext == "mp4" }
                guard let video = muxedMP4.min(by: { ($0.height ?? .max) < ($1.height ?? .max) }) else {
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
                onProgress: onProgress
            )

            if mode == .video {
                dest = try await VideoMerger.ensureAudio(videoFile: dest, audioRequest: mergeAudioRequest, category: category)
            } else if extractAudioAfterDownload {
                dest = try await VideoAudioExtractor.extractAudio(fromVideo: dest, category: category)
            }

            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? nil
            let sizeText = size.map { " (\($0 / 1024) KB)" } ?? ""
            appLog("Download finished: \(dest.lastPathComponent)\(sizeText)", level: .success, category: category)

            return ExtractedMedia(
                fileURL: dest,
                title: info.title.isEmpty ? url.absoluteString : info.title,
                duration: info.duration ?? 0,
                isVideo: mode == .video
            )
        } catch {
            appLog("yt-dlp failed: \(error.localizedDescription)", level: .error, category: category)
            // The localized description hides yt-dlp/Python exception text; the
            // full value usually contains the real reason (e.g. "Sign in to
            // confirm you're not a bot", "Video unavailable").
            appLog("Detail: \(String(describing: error))", level: .debug, category: category)
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
