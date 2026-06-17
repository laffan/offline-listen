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
}

enum ExtractorError: LocalizedError {
    case packageUnavailable
    case invalidURL
    case noAudioFormat
    case noVideoFormat
    case unplayableVideoCodec(String)
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
        case .downloadFailed(let message):
            return message
        }
    }
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

#if canImport(YoutubeDL) && canImport(PythonKit)
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
    private func extractViaForcedClients(url: URL,
                                         mode: DownloadMode,
                                         category: String,
                                         onDownloadStart: @escaping () -> Void,
                                         onProgress: @escaping (Double) -> Void) async throws -> ExtractedMedia? {
        // Try clients one at a time with fallback: an unsupported client name
        // (older on-device yt-dlp) or a PO-token-gated client fails only its own
        // attempt instead of the whole recovery. Ordered by how reliably each
        // returns URLs that need no nsig descrambling.
        let clientSets: [[String]] = [["ios"], ["web_safari"], ["android"], ["tv"], ["mweb"], ["web"]]

        for clients in clientSets {
            let label = clients.joined(separator: ",")
            appLog("Forced-client extract: re-resolving with player client \(label)…",
                   level: .warning, category: category)

            let info: PythonObject
            do {
                info = try await withHeartbeat("Still re-resolving (\(label))", category: category) {
                    let ytdlpModule = Python.import("yt_dlp")
                    let options: PythonObject = [
                        "quiet": true,
                        "noplaylist": true,
                        "nocheckcertificate": true,
                        "extractor_args": ["youtube": ["player_client": PythonObject(clients)]],
                    ]
                    let ytdlp = ytdlpModule.YoutubeDL(options)
                    return try ytdlp.extract_info.throwing.dynamicallyCall(withKeywordArguments: [
                        "": url.absoluteString, "download": false, "process": true,
                    ])
                }
            } catch {
                appLog("Forced-client extract: client \(label) failed: \(error.localizedDescription)",
                       level: .warning, category: category)
                // localizedDescription is the opaque "PythonError error 0"; the
                // full value carries the real Python exception text.
                appLog("Forced-client detail (\(label)): \(String(describing: error))",
                       level: .debug, category: category)
                continue
            }

            let media = mode == .video
                ? try await downloadPlayable(from: info, client: label, url: url,
                                             category: category,
                                             onDownloadStart: onDownloadStart, onProgress: onProgress)
                : try await downloadBestAudio(from: info, client: label, url: url,
                                              category: category,
                                              onDownloadStart: onDownloadStart, onProgress: onProgress)
            if let media { return media }
            appLog("Forced-client extract: client \(label) returned no usable \(mode == .video ? "H.264/HEVC video" : "audio") — trying next.",
                   category: category)
        }

        appLog("Forced-client extract: no player client produced a usable \(mode == .video ? "video" : "audio") stream.",
               level: .error, category: category)
        return nil
    }

    /// Picks the tallest H.264/HEVC video (+ best m4a audio) from a resolved
    /// yt-dlp info dict and downloads + merges it. Returns nil if the dict has no
    /// decodable video. Every dict read uses `.get(...)` so a missing key yields
    /// Python `None` rather than trapping.
    private func downloadPlayable(from info: PythonObject,
                                  client: String,
                                  url: URL,
                                  category: String,
                                  onDownloadStart: @escaping () -> Void,
                                  onProgress: @escaping (Double) -> Void) async throws -> ExtractedMedia? {
        let formatsObj = info.get("formats")
        if formatsObj == Python.None { return nil }

        func headers(_ format: PythonObject) -> [String: String] {
            var result: [String: String] = [:]
            let h = format.get("http_headers")
            if h == Python.None { return result }
            for key in h.keys() {
                if let k = String(key), let v = String(h[key]) { result[k] = v }
            }
            return result
        }

        struct VideoCand { let url: String; let height: Int; let vcodec: String; let headers: [String: String] }
        struct AudioCand { let url: String; let abr: Double; let headers: [String: String] }
        var videos: [VideoCand] = []
        var audios: [AudioCand] = []

        for format in formatsObj {
            guard let furl = String(format.get("url")) else { continue }
            let vcodec = String(format.get("vcodec")) ?? "none"
            let acodec = String(format.get("acodec")) ?? "none"
            let ext = String(format.get("ext")) ?? ""
            let hasVideo = vcodec != "none" && !vcodec.isEmpty
            let hasAudio = acodec != "none" && !acodec.isEmpty

            if hasVideo, ext == "mp4", PlayableVideoCodec.isPlayable(codec: vcodec) {
                videos.append(VideoCand(url: furl, height: Int(format.get("height")) ?? 0,
                                        vcodec: vcodec, headers: headers(format)))
            } else if hasAudio, !hasVideo, ext == "m4a" {
                let abr = Double(format.get("abr")) ?? Double(Int(format.get("tbr")) ?? 0)
                audios.append(AudioCand(url: furl, abr: abr, headers: headers(format)))
            }
        }

        guard let video = videos.max(by: { $0.height < $1.height }) else { return nil }
        let audio = audios.max(by: { $0.abr < $1.abr })
        appLog("Recovery (\(client)) selected H.264 video \(video.height)p (\(video.vcodec))\(audio == nil ? " · no separate audio" : " + m4a audio")",
               level: .success, category: category)

        func request(_ urlString: String, _ headerFields: [String: String]) -> URLRequest? {
            guard let u = URL(string: urlString) else { return nil }
            var r = URLRequest(url: u)
            for (key, value) in headerFields { r.setValue(value, forHTTPHeaderField: key) }
            return r
        }
        guard let videoRequest = request(video.url, video.headers) else { return nil }
        let audioRequest = audio.flatMap { request($0.url, $0.headers) }

        let title = String(info.get("title")) ?? url.absoluteString
        let reportedDuration = Double(info.get("duration")) ?? 0

        var dest = AppPaths.work.appendingPathComponent("\(UUID().uuidString).mp4")
        appLog("Downloading recovered video stream in chunks…", category: category)
        onDownloadStart()
        try await AudioStreamDownloader.download(baseRequest: videoRequest, expectedSize: nil,
                                                 to: dest, category: category, onProgress: onProgress)
        dest = try await VideoMerger.ensureAudio(videoFile: dest, audioRequest: audioRequest, category: category)

        let duration = reportedDuration > 0 ? reportedDuration : await mediaDuration(of: dest)
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? nil
        appLog("Recovery download finished: \(dest.lastPathComponent)\(size.map { " (\($0 / 1024) KB)" } ?? "")",
               level: .success, category: category)
        return ExtractedMedia(fileURL: dest, title: title, duration: duration, isVideo: true)
    }

    /// Audio counterpart to `downloadPlayable`: picks the best audio from a
    /// forced-client info dict — a dedicated audio-only m4a if present (no
    /// transcoding), otherwise the smallest muxed mp4 with its audio extracted to
    /// m4a. Mirrors the default path's audio selection. Returns nil if the dict
    /// offers no usable audio. Every dict read uses `.get(...)` so a missing key
    /// yields Python `None` rather than trapping.
    private func downloadBestAudio(from info: PythonObject,
                                   client: String,
                                   url: URL,
                                   category: String,
                                   onDownloadStart: @escaping () -> Void,
                                   onProgress: @escaping (Double) -> Void) async throws -> ExtractedMedia? {
        let formatsObj = info.get("formats")
        if formatsObj == Python.None { return nil }

        func headers(_ format: PythonObject) -> [String: String] {
            var result: [String: String] = [:]
            let h = format.get("http_headers")
            if h == Python.None { return result }
            for key in h.keys() {
                if let k = String(key), let v = String(h[key]) { result[k] = v }
            }
            return result
        }

        struct AudioCand { let url: String; let abr: Double; let headers: [String: String] }
        struct MuxedCand { let url: String; let height: Int; let headers: [String: String] }
        var audios: [AudioCand] = []
        var muxed: [MuxedCand] = []

        for format in formatsObj {
            guard let furl = String(format.get("url")) else { continue }
            let vcodec = String(format.get("vcodec")) ?? "none"
            let acodec = String(format.get("acodec")) ?? "none"
            let ext = String(format.get("ext")) ?? ""
            let hasVideo = vcodec != "none" && !vcodec.isEmpty
            let hasAudio = acodec != "none" && !acodec.isEmpty

            if hasAudio, !hasVideo, ext == "m4a" {
                let abr = Double(format.get("abr")) ?? Double(Int(format.get("tbr")) ?? 0)
                audios.append(AudioCand(url: furl, abr: abr, headers: headers(format)))
            } else if hasAudio, hasVideo, ext == "mp4" {
                muxed.append(MuxedCand(url: furl, height: Int(format.get("height")) ?? Int.max,
                                       headers: headers(format)))
            }
        }

        func request(_ urlString: String, _ headerFields: [String: String]) -> URLRequest? {
            guard let u = URL(string: urlString) else { return nil }
            var r = URLRequest(url: u)
            for (key, value) in headerFields { r.setValue(value, forHTTPHeaderField: key) }
            return r
        }

        let title = String(info.get("title")) ?? url.absoluteString
        let reportedDuration = Double(info.get("duration")) ?? 0

        // Prefer a dedicated audio-only m4a — no transcoding, no extraction step.
        if let audio = audios.max(by: { $0.abr < $1.abr }),
           let audioRequest = request(audio.url, audio.headers) {
            appLog("Forced-client (\(client)) selected audio-only m4a \(Int(audio.abr)) kbps",
                   level: .success, category: category)
            let dest = AppPaths.work.appendingPathComponent("\(UUID().uuidString).m4a")
            onDownloadStart()
            try await AudioStreamDownloader.download(baseRequest: audioRequest, expectedSize: nil,
                                                     to: dest, category: category, onProgress: onProgress)
            let duration = reportedDuration > 0 ? reportedDuration : await mediaDuration(of: dest)
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? nil
            appLog("Forced-client audio download finished: \(dest.lastPathComponent)\(size.map { " (\($0 / 1024) KB)" } ?? "")",
                   level: .success, category: category)
            return ExtractedMedia(fileURL: dest, title: title, duration: duration, isVideo: false)
        }

        // No audio-only stream: take the smallest muxed mp4 and extract its audio.
        guard let video = muxed.min(by: { $0.height < $1.height }),
              let videoRequest = request(video.url, video.headers) else {
            return nil
        }
        appLog("Forced-client (\(client)) no audio-only stream — using muxed mp4 \(video.height)p + audio extraction",
               level: .warning, category: category)
        var dest = AppPaths.work.appendingPathComponent("\(UUID().uuidString).mp4")
        onDownloadStart()
        try await AudioStreamDownloader.download(baseRequest: videoRequest, expectedSize: nil,
                                                 to: dest, category: category, onProgress: onProgress)
        dest = try await VideoAudioExtractor.extractAudio(fromVideo: dest, category: category)

        let duration = reportedDuration > 0 ? reportedDuration : await mediaDuration(of: dest)
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? nil
        appLog("Forced-client audio extraction finished: \(dest.lastPathComponent)\(size.map { " (\($0 / 1024) KB)" } ?? "")",
               level: .success, category: category)
        return ExtractedMedia(fileURL: dest, title: title, duration: duration, isVideo: false)
    }
#endif

    func extractMedia(from url: URL,
                      mode: DownloadMode,
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
            let formats: [Format]
            let info: Info
            do {
                (formats, info) = try await resolveInfo(youtubeDL, url: url, category: category)
            } catch {
                // The default extraction stalled (the on-device web client needs
                // nsig descrambling via the slow pure-Python JS interpreter, which
                // can hang past the timeout) or failed outright. Retry forcing the
                // ios/web_safari/… player clients, whose URLs need no descrambling
                // — fast, and the same renditions Safari plays, so they succeed for
                // videos that work in the browser. Cancellation is never retried.
                if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                    throw error
                }
                #if canImport(PythonKit)
                appLog("Default extraction failed (\(error.localizedDescription)) — retrying with forced fast player clients…",
                       level: .warning, category: category)
                if let media = try await extractViaForcedClients(
                    url: url, mode: mode, category: category,
                    onDownloadStart: onDownloadStart, onProgress: onProgress) {
                    return media
                }
                #endif
                throw error
            }
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
                // Pick the best video AVFoundation can actually decode. YouTube
                // often offers AV1/VP9 video-only streams that iOS can't play —
                // selecting one yields a file that scrubs but shows no picture
                // (and no audio). Restrict to H.264/HEVC, then take the tallest.
                let videoMP4 = formats.filter { !$0.isAudioOnly && $0.ext == "mp4" }
                let playable = videoMP4.filter { PlayableVideoCodec.isPlayable(codec: $0.vcodec) }
                if playable.isEmpty {
                    let offered = videoMP4.compactMap { $0.vcodec }.filter { $0 != "none" }
                    let list = offered.isEmpty ? "none" : Set(offered).sorted().joined(separator: ", ")
                    appLog("Default extraction offered no device-playable video (need H.264/HEVC) — offered: \(list)",
                           level: .warning, category: category)
                    // Recovery: re-resolve forcing a player client that returns
                    // H.264. Bypasses the rest of this method on success.
                    #if canImport(PythonKit)
                    if let recovered = try await extractViaForcedClients(
                        url: url, mode: .video, category: category,
                        onDownloadStart: onDownloadStart, onProgress: onProgress) {
                        return recovered
                    }
                    #endif
                    appLog("No device-playable video stream (need H.264/HEVC) — offered: \(list)",
                           level: .error, category: category)
                    throw ExtractorError.unplayableVideoCodec(list)
                }
                guard let video = playable.max(by: { ($0.height ?? 0) < ($1.height ?? 0) }) else {
                    throw ExtractorError.noVideoFormat
                }
                chosen = video
                mergeAudioRequest = bestAudio.flatMap(makeRequest)
                appLog("Selected video \(chosen.format_id) (\(chosen.height.map { "\($0)p" } ?? "?")) \(chosen.vcodec ?? "?") \(chosen.isVideoOnly ? "video-only — will merge audio" : "muxed")",
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
