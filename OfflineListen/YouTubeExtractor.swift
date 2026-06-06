import Foundation

#if canImport(YoutubeDL)
import YoutubeDL
#endif

/// Result of extracting + downloading the audio stream for a URL.
struct ExtractedAudio {
    /// On-disk location of the downloaded audio (typically `.m4a`).
    let fileURL: URL
    let title: String
    let duration: Double
}

enum ExtractorError: LocalizedError {
    case packageUnavailable
    case invalidURL
    case noAudioFormat
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .packageUnavailable:
            return "YoutubeDL-iOS is not linked. Add the Swift package in Xcode (see README)."
        case .invalidURL:
            return "That doesn't look like a valid URL."
        case .noAudioFormat:
            return "No downloadable audio track was found for this video."
        case .downloadFailed(let message):
            return message
        }
    }
}

/// Abstraction over the YouTube audio extraction step so the rest of the app is
/// independent of the concrete library and can be unit-tested with a mock.
protocol YouTubeAudioExtractor {
    /// Downloads the best audio-only stream for `url`.
    /// - Parameter onDownloadStart: invoked once the video info has been
    ///   extracted and the actual stream download is about to begin.
    /// - Parameter onProgress: 0...1 download fraction (when the size is known).
    func extractAudio(from url: URL,
                      onDownloadStart: @escaping () -> Void,
                      onProgress: @escaping (Double) -> Void) async throws -> ExtractedAudio
}

/// Reports download progress for an async `URLSession.download(for:delegate:)`.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    // Required by the protocol; the async download(for:delegate:) handles the file.
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
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
final class YoutubeDLExtractor: YouTubeAudioExtractor {
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

    func extractAudio(from url: URL,
                      onDownloadStart: @escaping () -> Void,
                      onProgress: @escaping (Double) -> Void) async throws -> ExtractedAudio {
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
            let (formats, info) = try await youtubeDL.extractInfo(url: url)
            appLog("Info: \"\(info.title)\" · \(formats.count) formats · \(Int(info.duration ?? 0))s",
                   level: .success, category: category)

            // Pick the best audio-only stream, preferring m4a (AAC) so the file
            // is directly playable by AVFoundation with no transcode.
            let audioOnly = formats.filter { $0.isAudioOnly }
            let m4a = audioOnly.filter { $0.ext == "m4a" }
            let pool = m4a.isEmpty ? audioOnly : m4a
            guard let chosen = pool.max(by: { ($0.abr ?? $0.tbr ?? 0) < ($1.abr ?? $1.tbr ?? 0) })
                ?? formats.max(by: { ($0.tbr ?? 0) < ($1.tbr ?? 0) }) else {
                throw ExtractorError.noAudioFormat
            }
            appLog("Selected format \(chosen.format_id) · \(chosen.ext) · \(Int(chosen.abr ?? chosen.tbr ?? 0)) kbps",
                   category: category)

            guard let mediaURL = URL(string: chosen.url) else {
                throw ExtractorError.noAudioFormat
            }

            // Carry over yt-dlp's request headers (User-Agent, etc.) so the CDN
            // doesn't reject the request. A generous idle timeout tolerates the
            // throttled, bursty delivery YouTube applies to single connections.
            var request = URLRequest(url: mediaURL)
            for (key, value) in chosen.http_headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            request.timeoutInterval = 300

            appLog("Downloading audio stream (foreground)…", category: category)
            onDownloadStart()

            let started = Date()
            var loggedBucket = 0
            let delegate = DownloadProgressDelegate { fraction in
                onProgress(fraction)
                let bucket = Int(fraction * 5) // log every ~20%
                if bucket > loggedBucket {
                    loggedBucket = bucket
                    let elapsed = Int(Date().timeIntervalSince(started))
                    appLog("Download \(Int(fraction * 100))% · \(elapsed)s elapsed", level: .debug, category: category)
                }
            }

            let (tempURL, response) = try await URLSession.shared.download(for: request, delegate: delegate)
            if let http = response as? HTTPURLResponse {
                let level: LogLevel = (200..<300).contains(http.statusCode) ? .debug : .warning
                appLog("HTTP \(http.statusCode) from stream host", level: level, category: category)
                guard (200..<300).contains(http.statusCode) else {
                    throw ExtractorError.downloadFailed("Stream host returned HTTP \(http.statusCode)")
                }
            }

            let ext = chosen.ext.isEmpty ? "m4a" : chosen.ext
            let dest = AppPaths.work.appendingPathComponent("\(UUID().uuidString).\(ext)")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tempURL, to: dest)

            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? nil
            let sizeText = size.map { " (\($0 / 1024) KB)" } ?? ""
            appLog("Download finished: \(dest.lastPathComponent)\(sizeText)", level: .success, category: category)

            return ExtractedAudio(
                fileURL: dest,
                title: info.title.isEmpty ? url.absoluteString : info.title,
                duration: info.duration ?? 0
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
final class MockExtractor: YouTubeAudioExtractor {
    func extractAudio(from url: URL,
                      onDownloadStart: @escaping () -> Void,
                      onProgress: @escaping (Double) -> Void) async throws -> ExtractedAudio {
        appLog("Mock: extracting info…", category: "yt-dlp")
        try await Task.sleep(nanoseconds: 400_000_000)
        onDownloadStart()
        appLog("Mock: downloading…", category: "yt-dlp")
        for step in 1...5 {
            try await Task.sleep(nanoseconds: 160_000_000)
            onProgress(Double(step) / 5)
        }
        let dest = AppPaths.work.appendingPathComponent("\(UUID().uuidString).m4a")
        // A real file isn't produced here; the mock is only for UI flow testing.
        FileManager.default.createFile(atPath: dest.path, contents: Data())
        return ExtractedAudio(fileURL: dest, title: "Mock Track \(Int.random(in: 1...999))", duration: 180)
    }
}
