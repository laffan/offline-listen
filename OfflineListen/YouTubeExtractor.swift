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

    /// Downloads a file in sequential HTTP byte-range chunks, appending to
    /// `destination`. YouTube drops/throttles single large connections, so this
    /// mirrors what yt-dlp does: moderate ranged requests, each retried on
    /// transient network errors. Cancellation-aware between chunks.
    private static func downloadInChunks(baseRequest: URLRequest,
                                         expectedSize: Int?,
                                         to destination: URL,
                                         category: String,
                                         onProgress: @escaping (Double) -> Void) async throws {
        let chunkSize = 5 * 1024 * 1024 // 5 MB

        try? FileManager.default.removeItem(at: destination)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var offset = 0
        var total = expectedSize ?? 0
        let started = Date()
        var loggedBucket = 0

        while total == 0 || offset < total {
            try Task.checkCancellation()

            let upper = total > 0 ? min(offset + chunkSize, total) - 1 : offset + chunkSize - 1
            let requested = upper - offset + 1

            var req = baseRequest
            req.timeoutInterval = 120
            req.setValue("bytes=\(offset)-\(upper)", forHTTPHeaderField: "Range")

            let (data, response) = try await fetchChunk(req, attempts: 4, category: category)
            guard let http = response as? HTTPURLResponse else {
                throw ExtractorError.downloadFailed("No HTTP response from stream host")
            }
            guard http.statusCode == 200 || http.statusCode == 206 else {
                throw ExtractorError.downloadFailed("Stream host returned HTTP \(http.statusCode)")
            }

            // Learn the total size from the first ranged response if we didn't
            // already have it from yt-dlp's metadata.
            if total == 0 {
                if let range = http.value(forHTTPHeaderField: "Content-Range"),
                   let totalPart = range.split(separator: "/").last,
                   let parsed = Int(totalPart) {
                    total = parsed
                } else if let length = http.value(forHTTPHeaderField: "Content-Length"),
                          let parsed = Int(length) {
                    total = parsed
                }
            }

            if data.isEmpty { break }
            try handle.write(contentsOf: data)
            offset += data.count

            if total > 0 {
                let fraction = min(Double(offset) / Double(total), 1.0)
                onProgress(fraction)
                let bucket = Int(fraction * 5) // log every ~20%
                if bucket > loggedBucket {
                    loggedBucket = bucket
                    let elapsed = Int(Date().timeIntervalSince(started))
                    appLog("Download \(Int(fraction * 100))% · \(elapsed)s", level: .debug, category: category)
                }
            }

            // Server ignored the range and returned the whole file, or we've hit EOF.
            if http.statusCode == 200 { break }
            if data.count < requested { break }
        }

        onProgress(1.0)
    }

    private static func fetchChunk(_ request: URLRequest,
                                   attempts: Int,
                                   category: String) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                return try await URLSession.shared.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if (error as? URLError)?.code == .cancelled { throw error }
                lastError = error
                appLog("Chunk attempt \(attempt)/\(attempts) failed: \(error.localizedDescription) — retrying",
                       level: .warning, category: category)
                try await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000)
            }
        }
        throw lastError ?? ExtractorError.downloadFailed("Chunk download failed")
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
            // doesn't reject the request.
            var request = URLRequest(url: mediaURL)
            for (key, value) in chosen.http_headers {
                request.setValue(value, forHTTPHeaderField: key)
            }

            let ext = chosen.ext.isEmpty ? "m4a" : chosen.ext
            let dest = AppPaths.work.appendingPathComponent("\(UUID().uuidString).\(ext)")

            let expected = chosen.filesize
            let sizeHint = expected.map { " (~\($0 / 1024 / 1024) MB)" } ?? ""
            appLog("Downloading audio stream in chunks\(sizeHint)…", category: category)
            onDownloadStart()

            try await Self.downloadInChunks(
                baseRequest: request,
                expectedSize: expected,
                to: dest,
                category: category,
                onProgress: onProgress
            )

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
