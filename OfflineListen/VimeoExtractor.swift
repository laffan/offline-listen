import Foundation

/// Native-Swift extractor for **Vimeo** — the same role `YouTubeKitExtractor`
/// plays for YouTube, and for the same reason: driving the embedded Python
/// yt-dlp for a site this simple is slow, opaque, and (on device) the step that
/// actually fails.
///
/// Vimeo's web player runs off a JSON **player config** carrying everything we
/// need: the title, the duration, any **progressive** MP4s, and the **HLS**
/// master playlist. Plain HTTPS and `Codable` — no interpreter, no Python gate,
/// and no 90-second timeout to sit through. (It's what yt-dlp's own Vimeo
/// extractor reads, minus the dozen fallback paths for embeds, albums and
/// Vimeo Pro review links, which still go to yt-dlp.)
///
/// This is deliberately best-effort: any failure throws, and
/// `CompositeExtractor` falls straight through to yt-dlp, so the worst case is
/// today's behaviour plus one fast request.
final class VimeoExtractor: MediaExtractor {
    private static let category = "Vimeo"

    /// Vimeo's player refuses config requests it can't attribute to a page, so
    /// every request carries a browser UA and a vimeo.com referer.
    private static let userAgent = BrowseHTTP.userAgent

    func canHandle(_ url: URL) -> Bool {
        Self.reference(from: url) != nil
    }

    // MARK: - Reference parsing

    /// A Vimeo video: its numeric id, plus the **unlisted hash** when the link
    /// carries one (`vimeo.com/{id}/{hash}` — the private-link form, which the
    /// config endpoint needs as `?h=`).
    struct Reference: Equatable {
        let id: String
        let hash: String?
    }

    /// Reads the video reference out of any of Vimeo's URL shapes —
    /// `vimeo.com/953003096`, `vimeo.com/953003096/a1b2c3d4e5`,
    /// `player.vimeo.com/video/953003096`,
    /// `vimeo.com/channels/staffpicks/953003096`,
    /// `vimeo.com/groups/name/videos/953003096` — and nil for anything else
    /// (an album, a user page, a non-Vimeo host), which sends the link to
    /// yt-dlp instead.
    ///
    /// Query parameters are ignored entirely: the share links Vimeo hands out
    /// carry tracking junk (`?fl=pl&fe=sh`) that names nothing.
    static func reference(from url: URL) -> Reference? {
        let host = (url.host ?? "").lowercased()
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        guard bare == "vimeo.com" || bare == "player.vimeo.com" else { return nil }

        let parts = url.pathComponents.filter { $0 != "/" }
        // The id is the last purely-numeric component; anything after it is the
        // unlisted hash.
        guard let index = parts.lastIndex(where: { $0.allSatisfy(\.isNumber) && !$0.isEmpty }) else {
            return nil
        }
        let id = parts[index]
        // Vimeo ids are 6+ digits; a stray "1" from some other path shape isn't one.
        guard id.count >= 6 else { return nil }
        let hash = parts.indices.contains(index + 1) ? parts[index + 1] : nil
        // `/video/{id}/config` and friends aren't hashes.
        let reserved: Set<String> = ["config", "settings", "embed", "likes", "collections"]
        return Reference(id: id, hash: hash.flatMap { reserved.contains($0.lowercased()) ? nil : $0 })
    }

    // MARK: - Extraction

    func extractMedia(from url: URL,
                      mode: DownloadMode,
                      quality: VideoQuality,
                      onDownloadStart: @escaping () -> Void,
                      onProgress: @escaping (Double) -> Void) async throws -> ExtractedMedia {
        guard let reference = Self.reference(from: url) else { throw ExtractorError.invalidURL }
        let category = Self.category

        let config = try await Self.fetchConfig(reference, category: category)
        let title = config.video?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reportedDuration = config.video?.duration ?? 0
        let name = (title?.isEmpty ?? true) ? "Vimeo \(reference.id)" : title!

        let files = config.request?.files
        let progressive = (files?.progressive ?? []).filter { $0.url?.isEmpty == false }
        appLog("Vimeo \(reference.id): \"\(name)\" · \(progressive.count) progressive file(s)\(files?.hls == nil ? "" : " + HLS")",
               level: .success, category: category)
        for file in progressive.prefix(10) {
            appLog("· \(file.quality ?? "?") \(file.height.map { "\($0)p" } ?? "") \(file.mime ?? "")",
                   level: .debug, category: category)
        }

        // Progressive first when Vimeo still offers it — a direct MP4 is a
        // plain ranged download, and (for audio) a small one to extract from.
        if !progressive.isEmpty {
            return try await downloadProgressive(progressive, name: name, duration: reportedDuration,
                                                 mode: mode, quality: quality, category: category,
                                                 onDownloadStart: onDownloadStart, onProgress: onProgress)
        }

        // Vimeo retired progressive files for most accounts, so this is the
        // usual path now: the HLS master, fetched segment by segment.
        guard let playlist = Self.hlsURL(from: files?.hls, mode: mode) else {
            throw ExtractorError.downloadFailed(
                "Vimeo returned no downloadable files for this video — it may be a live stream, or restricted to particular sites.")
        }
        appLog("Vimeo \(reference.id): no progressive files — using the HLS playlist.",
               level: .warning, category: category)

        let ext = mode == .video ? "mp4" : "m4a"
        let scratch = AppPaths.work.appendingPathComponent("\(UUID().uuidString).\(ext)")
        onDownloadStart()
        // The returned file isn't always the one handed in — a muxed or
        // audio-extracted result is a new file.
        let dest = try await HLSDownloader.download(playlist: playlist,
                                                    headers: Self.streamHeaders,
                                                    mode: mode,
                                                    quality: quality,
                                                    to: scratch,
                                                    category: category,
                                                    onProgress: onProgress)
        let verified = try await MediaVerifier.verify(dest, isVideo: mode == .video, category: category)
        appLog("Vimeo download finished: \(dest.lastPathComponent)", level: .success, category: category)
        return ExtractedMedia(fileURL: dest,
                              title: name,
                              duration: reportedDuration > 0 ? reportedDuration : verified,
                              isVideo: mode == .video)
    }

    /// Downloads one of Vimeo's progressive MP4s. Video takes the tallest
    /// rendition within the quality cap; audio takes the **smallest** file and
    /// extracts its audio track (Vimeo publishes no audio-only progressive
    /// stream, so this is the same muxed-then-extract route the yt-dlp path
    /// uses when a site has no audio-only format).
    private func downloadProgressive(_ files: [VimeoConfig.ProgressiveFile],
                                     name: String,
                                     duration: Double,
                                     mode: DownloadMode,
                                     quality: VideoQuality,
                                     category: String,
                                     onDownloadStart: @escaping () -> Void,
                                     onProgress: @escaping (Double) -> Void) async throws -> ExtractedMedia {
        let chosen: VimeoConfig.ProgressiveFile?
        if mode == .video {
            chosen = quality.pick(from: files, height: { $0.height ?? 0 })
        } else {
            chosen = files.min(by: { ($0.height ?? .max) < ($1.height ?? .max) })
        }
        guard let file = chosen, let link = file.url, let streamURL = URL(string: link) else {
            throw mode == .video ? ExtractorError.noVideoFormat : ExtractorError.noAudioFormat
        }
        appLog("Vimeo: selected progressive \(file.quality ?? "?") (\(file.height.map { "\($0)p" } ?? "?"))\(mode == .audio ? " — audio will be extracted from it" : "")",
               category: category)

        var request = URLRequest(url: streamURL)
        for (key, value) in Self.streamHeaders { request.setValue(value, forHTTPHeaderField: key) }

        var dest = AppPaths.work.appendingPathComponent("\(UUID().uuidString).mp4")
        onDownloadStart()
        try await AudioStreamDownloader.download(baseRequest: request,
                                                 expectedSize: file.size,
                                                 to: dest,
                                                 category: category,
                                                 onProgress: onProgress)
        if mode == .audio {
            dest = try await VideoAudioExtractor.extractAudio(fromVideo: dest, category: category)
        }
        let verified = try await MediaVerifier.verify(dest, isVideo: mode == .video, category: category)
        appLog("Vimeo download finished: \(dest.lastPathComponent)", level: .success, category: category)
        return ExtractedMedia(fileURL: dest,
                              title: name,
                              duration: duration > 0 ? duration : verified,
                              isVideo: mode == .video)
    }

    /// The playlist to hand AVFoundation. For **video** the CDN's `avc_url` is
    /// preferred where present: it's the H.264-only variant list, and H.264 is
    /// what the device can actually decode (the plain `url` may advertise
    /// renditions in codecs AVFoundation won't touch). Audio doesn't care.
    private static func hlsURL(from hls: VimeoConfig.HLS?, mode: DownloadMode) -> URL? {
        guard let hls else { return nil }
        let cdns = hls.cdns ?? [:]
        // The CDN Vimeo itself would use, then any other it lists.
        let ordered = [hls.defaultCDN].compactMap { $0 }.compactMap { cdns[$0] } + cdns.values
        for cdn in ordered {
            let preferred = mode == .video ? (cdn.avcURL ?? cdn.url) : (cdn.url ?? cdn.avcURL)
            if let link = preferred, let url = URL(string: link) { return url }
        }
        return nil
    }

    // MARK: - Config fetch

    /// Headers the media requests carry. Vimeo's CDNs check the referer on
    /// segment and file requests as well as on the config call.
    private static var streamHeaders: [String: String] {
        ["User-Agent": userAgent, "Referer": "https://vimeo.com/"]
    }

    /// Gets the player config, the JSON the web player runs on.
    ///
    /// Asking `player.vimeo.com/video/{id}/config` **directly** is the obvious
    /// route and it mostly doesn't work any more: Vimeo now signs that URL, so
    /// an unsigned request comes back **403 even for a perfectly public
    /// video**. The signature (`s=` + `t=`, or an `h=` hash) lives on the
    /// `config_url` printed into the player's own page — which is why the
    /// player page comes first here, exactly as yt-dlp's Vimeo extractor does
    /// it. Three attempts, cheapest first:
    ///
    /// 1. The **player page** (`player.vimeo.com/video/{id}`) — usually carries
    ///    the whole config inline as `window.playerConfig = {…}`, so one
    ///    request is the whole job.
    /// 2. The **watch page** (`vimeo.com/{id}`) — same inline config for some
    ///    videos; otherwise it prints a signed `config_url` to fetch.
    /// 3. The **unsigned config endpoint**, which still works for videos whose
    ///    owner allows unrestricted embedding — and whose 403, having got this
    ///    far, is a real refusal worth reporting.
    private static func fetchConfig(_ reference: Reference, category: String) async throws -> VimeoConfig {
        var playerComponents = URLComponents(string: "https://player.vimeo.com/video/\(reference.id)")
        var watchComponents = URLComponents(string: "https://vimeo.com/\(reference.id)")
        if let hash = reference.hash {
            playerComponents?.queryItems = [URLQueryItem(name: "h", value: hash)]
            watchComponents = URLComponents(string: "https://vimeo.com/\(reference.id)/\(hash)")
        }
        let pageURLs = [playerComponents?.url, watchComponents?.url].compactMap { $0 }

        for pageURL in pageURLs {
            if let config = try await config(fromPage: pageURL, category: category) {
                return config
            }
        }
        return try await fetchConfigDirect(reference, category: category)
    }

    /// Reads a player/watch page and returns the config it carries — inline
    /// when the page has it, otherwise by following the **signed** `config_url`
    /// it advertises. Returns nil (rather than throwing) whenever this page
    /// simply isn't the one that has it, so the caller moves on to the next.
    private static func config(fromPage pageURL: URL, category: String) async throws -> VimeoConfig? {
        guard let (data, status) = try await get(pageURL, accept: "text/html", category: category) else {
            return nil
        }
        guard (200..<300).contains(status) else {
            appLog("Vimeo: \(pageURL.absoluteString) returned HTTP \(status).", level: .debug, category: category)
            return nil
        }
        let html = String(decoding: data, as: UTF8.self)

        // The page usually inlines the entire config — no second request.
        if let inline = jsonObject(afterMarker: "playerConfig", in: html),
           let config = try? JSONDecoder().decode(VimeoConfig.self, from: inline),
           config.request?.files != nil {
            appLog("Vimeo: read the player config inline from \(pageURL.host ?? "the page").",
                   level: .debug, category: category)
            return config
        }

        // Otherwise it prints where the (signed) config lives.
        guard let link = configURL(in: html), let url = URL(string: link) else { return nil }
        appLog("Vimeo: following the page's signed config URL…", level: .debug, category: category)
        guard let (configData, configStatus) = try await get(url, accept: "application/json", category: category),
              (200..<300).contains(configStatus) else { return nil }
        return try? JSONDecoder().decode(VimeoConfig.self, from: configData)
    }

    /// The last-resort unsigned config request. Still serves videos whose owner
    /// allows embedding anywhere; a 403 here, after the pages above have been
    /// tried, is a genuine refusal.
    private static func fetchConfigDirect(_ reference: Reference, category: String) async throws -> VimeoConfig {
        var components = URLComponents(string: "https://player.vimeo.com/video/\(reference.id)/config")
        if let hash = reference.hash {
            components?.queryItems = [URLQueryItem(name: "h", value: hash)]
        }
        guard let url = components?.url else { throw ExtractorError.invalidURL }

        appLog("Fetching Vimeo's unsigned player config for \(reference.id)…", level: .debug, category: category)
        guard let (data, status) = try await get(url, accept: "application/json", category: category) else {
            throw ExtractorError.downloadFailed("Couldn't reach Vimeo.")
        }
        guard (200..<300).contains(status) else {
            // Vimeo explains itself in the body when it has something to say.
            let message = (try? JSONDecoder().decode(VimeoError.self, from: data))?.message
            appLog("Vimeo config returned HTTP \(status)\(message.map { ": \($0)" } ?? "").",
                   level: .error, category: category)
            switch status {
            case 403:
                throw ExtractorError.downloadFailed(
                    "Vimeo refused to describe this video\(message.map { " — \($0)" } ?? "") — its player page carried no usable config either. Password-protected videos, and videos restricted to embedding on particular sites, aren't downloadable.")
            case 404:
                throw ExtractorError.downloadFailed("Vimeo has no video at that link (it may have been removed).")
            default:
                throw ExtractorError.downloadFailed("Vimeo returned HTTP \(status)\(message.map { ": \($0)" } ?? "").")
            }
        }

        do {
            return try JSONDecoder().decode(VimeoConfig.self, from: data)
        } catch {
            appLog("Vimeo config didn't decode (\(error.localizedDescription)) — falling back to yt-dlp.",
                   level: .warning, category: category)
            throw ExtractorError.downloadFailed("Vimeo's player config wasn't in the expected shape.")
        }
    }

    /// A GET carrying the browser headers Vimeo expects. Returns nil only for a
    /// network-level failure the caller should treat as "this route didn't
    /// work" (cancellation still propagates).
    private static func get(_ url: URL, accept: String, category: String) async throws -> (Data, Int)? {
        var request = URLRequest(url: url)
        for (key, value) in streamHeaders { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 200)
        } catch {
            if isCancellation(error) { throw error }
            appLog("Vimeo: \(url.absoluteString) failed: \(error.localizedDescription)",
                   level: .warning, category: category)
            return nil
        }
    }

    /// The `config_url` a Vimeo page advertises — the **signed** config
    /// endpoint. Written into the page either as JSON (`"config_url":"https:\/\/…"`)
    /// or as an HTML attribute (`data-config-url="…&amp;s=…"`), so both forms
    /// are read and un-escaped with the matching decoder.
    private static func configURL(in html: String) -> String? {
        if let raw = BrowseHTTP.firstMatch(#""config_url":"([^"]+)""#, in: html) {
            // Decode it as the JSON string literal it is: that handles the
            // escaped slashes and any & in the query.
            if let decoded = try? JSONDecoder().decode(String.self, from: Data("\"\(raw)\"".utf8)) {
                return decoded
            }
            return raw.replacingOccurrences(of: "\\/", with: "/")
        }
        if let raw = BrowseHTTP.firstMatch(#"data-config-url="([^"]+)""#, in: html) {
            return raw.decodedHTMLEntities
        }
        return nil
    }

    /// The JSON object assigned after `marker` in a page's script — e.g. the
    /// `{…}` of `window.playerConfig = {…};`. Brace-matched rather than
    /// regexed, skipping string literals so a `}` inside a title can't end it
    /// early; nil when the marker isn't there or the object never closes.
    private static func jsonObject(afterMarker marker: String, in html: String) -> Data? {
        guard let markerRange = html.range(of: marker),
              let start = html[markerRange.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < html.endIndex {
            let character = html[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(html[start...index]).data(using: .utf8)
                }
            }
            index = html.index(after: index)
        }
        return nil
    }
}

/// The slice of Vimeo's player config we read. Every field is optional: the
/// config carries a great deal we don't care about and its shape shifts, and a
/// strict field would turn a cosmetic change into a failed download. When it
/// doesn't decode we simply fall through to yt-dlp.
struct VimeoConfig: Decodable {
    var video: Video?
    var request: Request?

    struct Video: Decodable {
        var title: String?
        var duration: Double?
    }

    struct Request: Decodable {
        var files: Files?
    }

    struct Files: Decodable {
        /// Direct MP4s. Absent for most accounts since Vimeo retired them,
        /// which is why the HLS path below is the usual one.
        var progressive: [ProgressiveFile]?
        var hls: HLS?
    }

    struct ProgressiveFile: Decodable {
        var url: String?
        /// Vimeo's own label ("540p", "1080p").
        var quality: String?
        var width: Int?
        var height: Int?
        var fps: Double?
        var mime: String?
        /// Byte size when advertised — passed to the chunked downloader so its
        /// progress and truncation checks have a target.
        var size: Int?
    }

    struct HLS: Decodable {
        var defaultCDN: String?
        var cdns: [String: CDN]?

        enum CodingKeys: String, CodingKey {
            case defaultCDN = "default_cdn"
            case cdns
        }
    }

    struct CDN: Decodable {
        var url: String?
        /// The H.264-only variant playlist — what the device can decode.
        var avcURL: String?

        enum CodingKeys: String, CodingKey {
            case url
            case avcURL = "avc_url"
        }
    }
}

/// Vimeo's error body (`{"message": "...", "error_code": 4101}`).
private struct VimeoError: Decodable {
    var message: String?
}
