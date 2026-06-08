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
            // already have it from the format metadata.
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
}
