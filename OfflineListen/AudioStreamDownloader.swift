import Foundation

/// Downloads a media stream in sequential HTTP byte-range chunks, appending to
/// `destination`. YouTube drops/throttles single large connections, so — like
/// yt-dlp — we issue moderate ranged requests, each retried on transient network
/// errors. Cancellation-aware between chunks. Shared by all extractors.
///
/// Reliability behaviours (what lets a long download survive a hostile CDN):
///
/// - **Re-resolve + resume.** googlevideo URLs expire (~6h), are IP-bound, and
///   get rejected outright (HTTP 403/410) when YouTube's token checks shift
///   mid-download. When that happens the downloader asks the caller-supplied
///   `refresh` closure for a *fresh* URL to the same stream and resumes from
///   the current byte offset instead of failing the whole job.
/// - **No silent truncation.** An empty or short response before the advertised
///   size is a stall to retry (and re-resolve), *not* an end-of-stream; if the
///   remaining bytes still can't be fetched the download **fails** — a
///   truncated file is never reported as a success.
/// - **The server's size wins.** The first response's Content-Range total
///   overrides the extractor's metadata size (which can be approximate); a
///   *change* in the server-confirmed total afterwards means a different
///   rendition was served and aborts the download rather than corrupting it.
/// - **Patient retries.** Transient transport errors back off exponentially
///   (2s → 8s) instead of giving up within a second on flaky cellular.
enum AudioStreamDownloader {
    /// Produces a fresh `URLRequest` for the *same rendition* of the stream
    /// when the current URL stops working (expired / token-rejected). Return
    /// nil when a replacement for that exact rendition can't be produced — the
    /// download then fails with a clear error instead of resuming into a
    /// different file's bytes.
    typealias RequestRefresher = () async throws -> URLRequest?

    static func download(baseRequest: URLRequest,
                         expectedSize: Int?,
                         to destination: URL,
                         category: String,
                         refresh: RequestRefresher? = nil,
                         onProgress: @escaping (Double) -> Void) async throws {
        let chunkSize = 5 * 1024 * 1024 // 5 MB
        let maxRefreshes = 3
        /// Consecutive failures tolerated at one offset before a refresh (and,
        /// with refreshes exhausted, before giving up).
        let maxStalledAttempts = 3

        try? FileManager.default.removeItem(at: destination)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var request = baseRequest
        var offset = 0
        var total = expectedSize ?? 0
        /// Whether `total` has been confirmed by a server Content-Range (as
        /// opposed to seeded from extractor metadata, which can be inaccurate).
        var serverConfirmedTotal = false
        /// Offset at which a 416-on-unknown-size was already probed with a
        /// fresh URL, so the probe runs once per position.
        var eofProbeOffset = -1
        let started = Date()
        var chunkIndex = 0
        var warnedNoTotal = false
        var refreshesUsed = 0
        var stalledAttempts = 0

        appLog("Chunked download → \(destination.lastPathComponent) · expected \(total > 0 ? byteSize(total) : "size unknown until first response")",
               level: .debug, category: category)

        /// Swaps in a re-resolved URL for the same stream so the loop can
        /// resume from `offset`. Returns false when refreshing isn't possible
        /// (no closure, budget exhausted, or re-resolution came up empty).
        func tryRefresh(reason: String) async -> Bool {
            guard let refresh, refreshesUsed < maxRefreshes else { return false }
            refreshesUsed += 1
            appLog("\(reason) — re-resolving the stream URL (\(refreshesUsed)/\(maxRefreshes)) to resume from \(byteSize(offset))…",
                   level: .warning, category: category)
            do {
                guard let fresh = try await refresh() else {
                    appLog("Re-resolution returned no replacement stream URL.", level: .warning, category: category)
                    return false
                }
                request = fresh
                return true
            } catch {
                appLog("Re-resolution failed: \(error.localizedDescription)", level: .warning, category: category)
                return false
            }
        }

        /// One failure at the current offset: retry in place with backoff a
        /// couple of times, then try a URL refresh, then give up with `error`.
        func handleStall(_ description: String, error: @autoclosure () -> Error) async throws {
            stalledAttempts += 1
            if stalledAttempts < maxStalledAttempts {
                let delay = min(8, 1 << stalledAttempts)
                appLog("\(description) — retrying in \(delay)s (attempt \(stalledAttempts)/\(maxStalledAttempts))…",
                       level: .warning, category: category)
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                return
            }
            stalledAttempts = 0
            if await tryRefresh(reason: description) { return }
            throw error()
        }

        while total == 0 || offset < total {
            try Task.checkCancellation()
            chunkIndex += 1

            let upper = total > 0 ? min(offset + chunkSize, total) - 1 : offset + chunkSize - 1
            let requested = upper - offset + 1

            var req = request
            req.timeoutInterval = 120
            req.setValue("bytes=\(offset)-\(upper)", forHTTPHeaderField: "Range")

            let chunkStarted = Date()
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await fetchChunk(req, attempts: 3, category: category,
                                                        label: "Chunk \(chunkIndex) (at \(byteSize(offset)))")
            } catch {
                if isCancellation(error) { throw error }
                try await handleStall("Chunk \(chunkIndex) failed after transport retries (\(error.localizedDescription))",
                                      error: error)
                continue
            }
            guard let http = response as? HTTPURLResponse else {
                try await handleStall("No HTTP response from stream host",
                                      error: ExtractorError.downloadFailed("No HTTP response from stream host"))
                continue
            }

            // A 416 on a stream whose size the server never reported is
            // ambiguous: the range may start exactly at EOF (the only
            // completion signal an unknown-size stream gives on a chunk
            // boundary) — or the URL may have gone stale. Probe once with a
            // fresh URL: an expired URL's replacement serves the bytes and the
            // download resumes; a genuine EOF 416s again and we finish.
            if http.statusCode == 416, total == 0, offset > 0 {
                if eofProbeOffset != offset,
                   await tryRefresh(reason: "Range beyond reported stream (HTTP 416) at \(byteSize(offset)) with unknown total — probing with a fresh URL") {
                    eofProbeOffset = offset
                    continue
                }
                appLog("Range beyond end of stream (HTTP 416) at \(byteSize(offset)) — end of stream",
                       level: .debug, category: category)
                break
            }

            // 403/410/416 mean the URL itself has gone bad — expired, IP/token
            // rejected, or out of sync with the file. Retrying the same URL is
            // pointless, so go straight to a refresh.
            if http.statusCode == 403 || http.statusCode == 410 || http.statusCode == 416 {
                stalledAttempts = 0
                if await tryRefresh(reason: "Stream host rejected the URL (HTTP \(http.statusCode))") { continue }
                throw ExtractorError.downloadFailed(
                    "Stream host rejected the URL (HTTP \(http.statusCode)) and it couldn't be re-resolved — the link is likely expired or token-gated. Restart the download to fetch a fresh URL.")
            }
            guard http.statusCode == 200 || http.statusCode == 206 else {
                try await handleStall("Stream host returned HTTP \(http.statusCode)",
                                      error: ExtractorError.downloadFailed("Stream host returned HTTP \(http.statusCode)"))
                continue
            }

            // Reconcile our size with the server's. The first Content-Range
            // total is authoritative — extractor metadata can be off, and a
            // hard mismatch there would strand a perfectly downloadable file.
            // A change in the *server-confirmed* total afterwards (possible
            // after a URL refresh) means a different rendition was served —
            // appending its bytes would corrupt the file.
            if let serverTotal = contentRangeTotal(http) {
                if !serverConfirmedTotal {
                    if total > 0 && serverTotal != total {
                        appLog("Server reports \(byteSize(serverTotal)) but metadata said \(byteSize(total)) — trusting the server",
                               level: .debug, category: category)
                    } else if total == 0 {
                        appLog("Stream size from Content-Range: \(byteSize(serverTotal))", level: .debug, category: category)
                    }
                    total = serverTotal
                    serverConfirmedTotal = true
                } else if serverTotal != total {
                    throw ExtractorError.downloadFailed(
                        "The stream changed size mid-download (\(byteSize(serverTotal)) vs \(byteSize(total)) expected) — a different rendition was served; restart the download.")
                }
            } else if total == 0 {
                // Without a Content-Range, Content-Length only names the whole
                // file on a 200 (on a 206 it's just this chunk's length).
                if http.statusCode == 200,
                   let length = http.value(forHTTPHeaderField: "Content-Length"),
                   let parsed = Int(length) {
                    total = parsed
                    appLog("Stream size from Content-Length: \(byteSize(total))", level: .debug, category: category)
                } else if !warnedNoTotal {
                    warnedNoTotal = true
                    appLog("Server reported no total size (no Content-Range/Content-Length) — progress is unknown; downloading until the stream ends",
                           level: .warning, category: category)
                }
            }

            // Empty bodies are handled BEFORE any rewind: with a known size an
            // empty 2xx is never a valid end of stream — googlevideo serves
            // these when a URL goes stale — so retry/refresh and resume from
            // the current offset. With an unknown size, an empty body after
            // real bytes is the only end-of-stream signal we get.
            if data.isEmpty {
                if total == 0 && offset > 0 { break }
                try await handleStall(
                    "Server returned an empty body at \(byteSize(offset)) (HTTP \(http.statusCode))",
                    error: ExtractorError.downloadFailed(
                        "The stream ended prematurely (empty response at \(byteSize(offset))\(total > 0 ? " of \(byteSize(total))" : ""))."))
                continue
            }

            // A non-empty HTTP 200 means the server ignored the Range header
            // and restarted the body from byte 0. Mid-file, appending it would
            // silently corrupt everything already written — rewind and
            // overwrite from the start instead.
            if http.statusCode == 200, offset > 0 {
                appLog("Server ignored the Range header mid-download (HTTP 200 at \(byteSize(offset))) — rewriting the file from this whole-file response",
                       level: .warning, category: category)
                try handle.truncate(atOffset: 0)
                offset = 0
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

            if http.statusCode == 200 {
                // Whole-file response. Done if it covered everything (or the
                // size is unknown); a short one is itself a stall — and the
                // stall counter deliberately does NOT reset on this path, so a
                // server that keeps sending short 200s fails after the budget
                // instead of looping forever.
                if total == 0 || offset >= total { break }
                try await handleStall(
                    "Whole-file response stopped at \(byteSize(offset)) of \(byteSize(total))",
                    error: ExtractorError.downloadFailed(
                        "The stream ended prematurely (\(byteSize(offset)) of \(byteSize(total)))."))
                continue
            }

            // A real ranged chunk landed — this is forward progress, so the
            // stall counter resets here (and only here).
            stalledAttempts = 0

            // A short ranged chunk with a known total is *not* an end-of-stream
            // signal — the loop simply continues from the new offset (this is
            // the resume behaviour). Only with an unknown total is it EOF.
            if total == 0 && data.count < requested {
                appLog("Short chunk with unknown total size (\(byteSize(data.count)) of \(byteSize(requested)) requested) — treating as end of stream",
                       level: .debug, category: category)
                break
            }
        }

        guard offset > 0 else {
            throw ExtractorError.downloadFailed("The download produced no data.")
        }
        if total > 0 && offset < total {
            // Unreachable by construction today (every exit path requires
            // total == 0 or offset >= total) — kept as the invariant's
            // backstop: a truncated file must never be reported as a success.
            throw ExtractorError.downloadFailed(
                "Download stopped at \(byteSize(offset)) of \(byteSize(total)) and couldn't be completed — not saving a truncated file.")
        }

        let elapsed = Int(Date().timeIntervalSince(started))
        appLog("Chunked download done: \(byteSize(offset)) in \(elapsed)s", level: .debug, category: category)
        onProgress(1.0)
    }

    /// Parses the total-size field of a Content-Range header ("bytes 0-99/1234"
    /// → 1234). Returns nil for a missing header or an unknown total ("/*").
    private static func contentRangeTotal(_ http: HTTPURLResponse) -> Int? {
        guard let range = http.value(forHTTPHeaderField: "Content-Range"),
              let totalPart = range.split(separator: "/").last,
              let parsed = Int(totalPart) else { return nil }
        return parsed
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
            } catch {
                if isCancellation(error) { throw error }
                lastError = error
                guard attempt < attempts else { break }
                // Exponential backoff (2s, 4s) — flaky cellular needs more
                // patience than a sub-second retry loop gives it.
                let delay = min(8, 1 << attempt)
                appLog("\(label) attempt \(attempt)/\(attempts) failed: \(error.localizedDescription) — retrying in \(delay)s",
                       level: .warning, category: category)
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
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
