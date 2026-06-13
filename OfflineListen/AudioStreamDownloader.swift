import Foundation

/// Downloads an audio stream in sequential HTTP byte-range chunks, appending to
/// `destination`. YouTube drops/throttles single large connections, so — like
/// yt-dlp — we issue moderate ranged requests, each retried on transient network
/// errors. Cancellation-aware between chunks. Shared by all extractors.
enum AudioStreamDownloader {
    static func download(baseRequest: URLRequest,
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
        var chunkIndex = 0
        var warnedNoTotal = false

        appLog("Chunked download → \(destination.lastPathComponent) · expected \(total > 0 ? byteSize(total) : "size unknown until first response")",
               level: .debug, category: category)

        while total == 0 || offset < total {
            try Task.checkCancellation()
            chunkIndex += 1

            let upper = total > 0 ? min(offset + chunkSize, total) - 1 : offset + chunkSize - 1
            let requested = upper - offset + 1

            var req = baseRequest
            req.timeoutInterval = 120
            req.setValue("bytes=\(offset)-\(upper)", forHTTPHeaderField: "Range")

            let chunkStarted = Date()
            let (data, response) = try await fetchChunk(req, attempts: 4, category: category,
                                                        label: "Chunk \(chunkIndex) (at \(byteSize(offset)))")
            guard let http = response as? HTTPURLResponse else {
                throw ExtractorError.downloadFailed("No HTTP response from stream host")
            }
            guard http.statusCode == 200 || http.statusCode == 206 else {
                throw ExtractorError.downloadFailed("Stream host returned HTTP \(http.statusCode)")
            }

            // Learn the total size from the first ranged response if we didn't
            // already have it from the format metadata.
            if total == 0 {
                if let range = http.value(forHTTPHeaderField: "Content-Range"),
                   let totalPart = range.split(separator: "/").last,
                   let parsed = Int(totalPart) {
                    total = parsed
                    appLog("Stream size from Content-Range: \(byteSize(total))", level: .debug, category: category)
                } else if let length = http.value(forHTTPHeaderField: "Content-Length"),
                          let parsed = Int(length) {
                    total = parsed
                    appLog("Stream size from Content-Length: \(byteSize(total))", level: .debug, category: category)
                } else if !warnedNoTotal {
                    warnedNoTotal = true
                    appLog("Server reported no total size (no Content-Range/Content-Length) — progress is unknown; downloading until the stream ends",
                           level: .warning, category: category)
                }
            }

            if data.isEmpty {
                appLog("Server returned an empty body at \(byteSize(offset)) (HTTP \(http.statusCode)) — stopping",
                       level: .warning, category: category)
                break
            }
            try handle.write(contentsOf: data)
            offset += data.count

            let chunkElapsed = Date().timeIntervalSince(chunkStarted)
            let speed = chunkElapsed > 0 ? Int(Double(data.count) / chunkElapsed / 1024) : 0
            let percent = total > 0 ? " · \(Int(min(Double(offset) / Double(total), 1.0) * 100))%" : ""
            appLog("Chunk \(chunkIndex): HTTP \(http.statusCode) · \(byteSize(data.count)) in \(String(format: "%.1f", chunkElapsed))s (\(speed) KB/s) · \(byteSize(offset)) so far\(percent)",
                   level: .debug, category: category)

            if total > 0 {
                onProgress(min(Double(offset) / Double(total), 1.0))
            }

            // Server ignored the range and returned the whole file, or we've hit EOF.
            if http.statusCode == 200 {
                appLog("Server ignored the Range header (HTTP 200) — treating the response as the whole file",
                       level: .debug, category: category)
                break
            }
            if data.count < requested {
                appLog("Short chunk (\(byteSize(data.count)) of \(byteSize(requested)) requested) — end of stream",
                       level: .debug, category: category)
                break
            }
        }

        let elapsed = Int(Date().timeIntervalSince(started))
        appLog("Chunked download done: \(byteSize(offset)) in \(elapsed)s", level: .debug, category: category)
        if total > 0 && offset < total {
            appLog("Downloaded \(byteSize(offset)) but the stream advertised \(byteSize(total)) — file may be truncated",
                   level: .warning, category: category)
        }

        onProgress(1.0)
    }

    private static func fetchChunk(_ request: URLRequest,
                                   attempts: Int,
                                   category: String,
                                   label: String) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                // The 120s timeoutInterval only fires when the connection goes
                // fully idle — a server trickling bytes never trips it. The
                // heartbeat makes such a stalled-but-alive chunk visible.
                return try await withHeartbeat("\(label) still in flight, attempt \(attempt)",
                                               category: category, interval: 15, level: .warning) {
                    try await URLSession.shared.data(for: request)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if (error as? URLError)?.code == .cancelled { throw error }
                lastError = error
                appLog("\(label) attempt \(attempt)/\(attempts) failed: \(error.localizedDescription) — retrying",
                       level: .warning, category: category)
                try await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000)
            }
        }
        throw lastError ?? ExtractorError.downloadFailed("Chunk download failed")
    }

    private static func byteSize(_ bytes: Int) -> String {
        bytes >= 1024 * 1024
            ? String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
            : "\(bytes / 1024) KB"
    }
}
