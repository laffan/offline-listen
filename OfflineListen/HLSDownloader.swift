import Foundation
import AVFoundation

/// Saves an **HLS** (`.m3u8`) stream to an ordinary local file by fetching its
/// segments and joining them — no FFmpeg, and no AVFoundation export.
///
/// `AudioStreamDownloader` fetches a single file over byte ranges, so it can't
/// touch a playlist of segments. That's fine for YouTube, whose DASH renditions
/// are direct URLs, but it's the whole story on **Vimeo**: since Vimeo retired
/// progressive files, an ordinary Vimeo link offers HLS and nothing else.
///
/// The first attempt at this handed the playlist to `AVAssetExportSession`,
/// which was wrong twice over. A remote HLS `AVURLAsset` exposes **no
/// `AVAssetTrack`s at all** (track info only materializes through an
/// `AVPlayerItem`), so the "does this carry video?" precheck rejected every
/// stream it was given; and an HLS asset reports itself as non-exportable
/// anyway, so the export behind it would very likely have failed too. Apple's
/// supported route for offline HLS — `AVAssetDownloadTask` — produces a
/// `.movpkg` bundle, which is not a file this app can move into the library,
/// play by path, share, or send to the watch.
///
/// So this reads the playlist itself. Modern HLS (Vimeo included) is **fMP4**:
/// an `EXT-X-MAP` initialization segment followed by `.m4s` media segments, and
/// those concatenated *are* a valid fragmented MP4 that AVFoundation reads
/// natively. Audio-only renditions come out as a small audio file — a real win
/// over downloading a whole video to extract from — and a video variant with a
/// separate audio group is muxed back together by `VideoMerger`, the same way
/// the YouTube DASH path already works.
enum HLSDownloader {
    /// Segments fetched at once. Each is its own request, so serial is slow on
    /// a long video; a small window keeps ordering trivial without hammering
    /// the CDN.
    private static let windowSize = 4
    /// Attempts per segment before the download gives up.
    private static let segmentAttempts = 3

    /// Downloads `playlist` to `destination`. Returns the file it wrote (which
    /// may differ from `destination` when a merge or an audio extraction
    /// produced a new one). Honours task cancellation between segments.
    static func download(playlist: URL,
                         headers: [String: String],
                         mode: DownloadMode,
                         quality: VideoQuality,
                         to destination: URL,
                         category: String,
                         onProgress: @escaping (Double) -> Void) async throws -> URL {
        let manifest = try await text(at: playlist, headers: headers, category: category)

        // A media playlist can be handed to us directly (some CDNs' `avc_url`
        // points at one); otherwise pick a variant out of the master.
        guard manifest.contains("#EXT-X-STREAM-INF") else {
            appLog("HLS: playlist is a single rendition — downloading it directly.",
                   level: .debug, category: category)
            try await fetchStream(playlist: playlist, manifest: manifest, headers: headers,
                                  to: destination, category: category, onProgress: onProgress)
            return try await finish(destination, mode: mode, mergedWith: nil, category: category)
        }

        let master = parseMaster(manifest, base: playlist)
        guard !master.variants.isEmpty else {
            throw ExtractorError.downloadFailed("The HLS master playlist listed no streams.")
        }
        appLog("HLS: \(master.variants.count) variant(s), \(master.audio.count) audio rendition(s).",
               level: .debug, category: category)

        // Audio mode takes the audio rendition on its own when there is one —
        // a fraction of the bytes, and no extraction step afterwards.
        if mode == .audio, let audio = master.audio.first {
            appLog("HLS: downloading the audio rendition\(audio.name.isEmpty ? "" : " (\(audio.name))") only.",
                   category: category)
            try await fetchStream(playlist: audio.url, manifest: nil, headers: headers,
                                  to: destination, category: category, onProgress: onProgress)
            return try await finish(destination, mode: .audio, mergedWith: nil, category: category)
        }

        // Otherwise pick a variant: for video the tallest within the quality
        // cap, restricted to codecs the device can decode; for audio the
        // smallest, since we only want the sound out of it.
        let playable = master.variants.filter { $0.isDeviceDecodable }
        let candidates = playable.isEmpty ? master.variants : playable
        let variant: Variant?
        if mode == .video {
            variant = quality.pick(from: candidates, height: { $0.height })
        } else {
            variant = candidates.min(by: { $0.bandwidth < $1.bandwidth })
        }
        guard let variant else { throw ExtractorError.downloadFailed("No usable HLS variant was offered.") }
        appLog("HLS: selected \(variant.height > 0 ? "\(variant.height)p" : "variant") · \(variant.bandwidth / 1000) kbps\(variant.codecs.isEmpty ? "" : " · \(variant.codecs)")",
               category: category)

        // A variant that names an audio group carries no sound of its own.
        let separateAudio = variant.audioGroup.flatMap { group in
            master.audio.first { $0.groupID == group }
        }
        // Leave room at the top of the bar for the audio stream and the mux.
        let videoShare = separateAudio == nil ? 1.0 : 0.85
        try await fetchStream(playlist: variant.url, manifest: nil, headers: headers,
                              to: destination, category: category,
                              onProgress: { onProgress($0 * videoShare) })

        guard let separateAudio else {
            return try await finish(destination, mode: mode, mergedWith: nil, category: category)
        }
        appLog("HLS: variant carries no audio — fetching its audio rendition to merge.",
               level: .debug, category: category)
        let audioFile = AppPaths.work.appendingPathComponent("\(UUID().uuidString).m4a")
        try await fetchStream(playlist: separateAudio.url, manifest: nil, headers: headers,
                              to: audioFile, category: category,
                              onProgress: { onProgress(videoShare + $0 * (1 - videoShare)) })
        return try await finish(destination, mode: mode, mergedWith: audioFile, category: category)
    }

    /// Turns the downloaded stream(s) into the file the caller wants: muxed
    /// when video and audio arrived separately, audio-extracted when a video
    /// variant was the only way to get sound.
    private static func finish(_ file: URL,
                               mode: DownloadMode,
                               mergedWith audioFile: URL?,
                               category: String) async throws -> URL {
        if let audioFile {
            return try await VideoMerger.merge(video: file, audio: audioFile, category: category)
        }
        if mode == .audio {
            // We had to take a video variant; keep only its audio track.
            let asset = AVURLAsset(url: file)
            let hasVideo = !((try? await asset.loadTracks(withMediaType: .video)) ?? []).isEmpty
            if hasVideo {
                return try await VideoAudioExtractor.extractAudio(fromVideo: file, category: category)
            }
        }
        return file
    }

    // MARK: - Fetching a single rendition

    /// Downloads one media playlist's segments, appended in order into `file`.
    /// `manifest` may be supplied when the caller already fetched it.
    private static func fetchStream(playlist: URL,
                                    manifest: String?,
                                    headers: [String: String],
                                    to file: URL,
                                    category: String,
                                    onProgress: @escaping (Double) -> Void) async throws {
        let manifestText: String
        if let manifest {
            manifestText = manifest
        } else {
            manifestText = try await text(at: playlist, headers: headers, category: category)
        }
        let media = try parseMedia(manifestText, base: playlist)
        guard !media.segments.isEmpty else {
            throw ExtractorError.downloadFailed("The HLS playlist listed no segments to download.")
        }
        if media.isEncrypted {
            throw ExtractorError.downloadFailed(
                "This HLS stream is encrypted (DRM or an AES key), which this app can't decrypt.")
        }
        if media.initSegment == nil && media.looksLikeTransportStream {
            // Concatenated MPEG-TS isn't a container AVFoundation reads. Say so
            // now rather than saving a file that won't play.
            throw ExtractorError.downloadFailed(
                "This HLS stream uses MPEG-TS segments, which this app can't join into a playable file (it handles the fMP4 kind).")
        }

        try? FileManager.default.removeItem(at: file)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: file) else {
            throw ExtractorError.downloadFailed("Couldn't open the destination file for writing.")
        }
        defer { try? handle.close() }

        // The init segment carries the moov box — without it the media
        // segments are unreadable.
        if let initSegment = media.initSegment {
            let data = try await fetchSegment(initSegment, headers: headers, category: category)
            try handle.write(contentsOf: data)
        }

        appLog("HLS: fetching \(media.segments.count) segment(s)…", category: category)
        var written = 0
        var index = 0
        while index < media.segments.count {
            try Task.checkCancellation()
            let upper = min(index + windowSize, media.segments.count)
            let window = Array(media.segments[index..<upper])
            // Fetch the window concurrently, then write it in playlist order —
            // segments must be appended in sequence to stay playable.
            let fetched = try await withThrowingTaskGroup(of: (Int, Data).self) { group -> [Int: Data] in
                for (offset, segment) in window.enumerated() {
                    group.addTask {
                        (offset, try await fetchSegment(segment, headers: headers, category: category))
                    }
                }
                var results: [Int: Data] = [:]
                for try await (offset, data) in group { results[offset] = data }
                return results
            }
            for offset in 0..<window.count {
                guard let data = fetched[offset] else { continue }
                try handle.write(contentsOf: data)
                written += data.count
            }
            index = upper
            onProgress(Double(index) / Double(media.segments.count))
        }

        appLog("HLS: wrote \(written / 1024) KB from \(media.segments.count) segment(s).",
               level: .debug, category: category)
    }

    /// One segment, retried a few times — a CDN dropping a single segment
    /// shouldn't sink a download that's most of the way through.
    private static func fetchSegment(_ segment: Segment,
                                     headers: [String: String],
                                     category: String) async throws -> Data {
        var lastError: Error?
        for attempt in 1...segmentAttempts {
            do {
                var request = URLRequest(url: segment.url)
                for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
                if let range = segment.byteRange {
                    request.setValue("bytes=\(range.offset)-\(range.offset + range.length - 1)",
                                     forHTTPHeaderField: "Range")
                }
                request.timeoutInterval = 30
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                guard (200..<300).contains(status) else {
                    throw ExtractorError.downloadFailed("Segment request returned HTTP \(status).")
                }
                guard !data.isEmpty else {
                    throw ExtractorError.downloadFailed("Segment came back empty.")
                }
                return data
            } catch {
                if isCancellation(error) { throw error }
                lastError = error
                if attempt < segmentAttempts {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
                }
            }
        }
        appLog("HLS: a segment failed after \(segmentAttempts) attempts: \(lastError?.localizedDescription ?? "unknown")",
               level: .error, category: category)
        throw lastError ?? ExtractorError.downloadFailed("An HLS segment couldn't be downloaded.")
    }

    private static func text(at url: URL, headers: [String: String], category: String) async throws -> String {
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.timeoutInterval = 30
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            if isCancellation(error) { throw error }
            throw ExtractorError.downloadFailed("Couldn't fetch the HLS playlist: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            throw ExtractorError.downloadFailed("The HLS playlist returned HTTP \(status).")
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Playlist parsing

    struct Variant {
        let url: URL
        let bandwidth: Int
        let height: Int
        let codecs: String
        /// The `AUDIO` group this variant takes its sound from, when its own
        /// segments carry none.
        let audioGroup: String?

        /// Only H.264/HEVC decode on the overwhelming majority of iPhones —
        /// the same rule the yt-dlp path applies to DASH renditions. A variant
        /// lists every codec it carries in one `CODECS` attribute, in no
        /// guaranteed order, so each entry is tested and the audio ones
        /// ignored; a variant that lists none is given the benefit of the doubt.
        var isDeviceDecodable: Bool {
            let entries = codecs.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }
            let audioPrefixes = ["mp4a", "opus", "ac-3", "ec-3", "alac", "flac"]
            let videoEntries = entries.filter { entry in
                !audioPrefixes.contains { entry.hasPrefix($0) }
            }
            guard !videoEntries.isEmpty else { return true }
            return videoEntries.contains { PlayableVideoCodec.isPlayable(codec: $0) }
        }
    }

    struct Rendition {
        let url: URL
        let groupID: String
        let name: String
    }

    struct Segment {
        let url: URL
        /// `#EXT-X-BYTERANGE` when the playlist packs several segments into one
        /// file; nil for the usual one-file-per-segment layout.
        var byteRange: (length: Int, offset: Int)?
    }

    static func parseMaster(_ manifest: String, base: URL) -> (variants: [Variant], audio: [Rendition]) {
        var variants: [Variant] = []
        var audio: [Rendition] = []
        let lines = manifest.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }

        for (index, line) in lines.enumerated() {
            if line.hasPrefix("#EXT-X-MEDIA:"), attribute("TYPE", in: line) == "AUDIO" {
                guard let uri = attribute("URI", in: line),
                      let url = URL(string: uri, relativeTo: base)?.absoluteURL else { continue }
                audio.append(Rendition(url: url,
                                       groupID: attribute("GROUP-ID", in: line) ?? "",
                                       name: attribute("NAME", in: line) ?? ""))
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                // The variant's URI is the next non-comment line.
                guard let uriLine = lines[(index + 1)...].first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
                      let url = URL(string: uriLine, relativeTo: base)?.absoluteURL else { continue }
                let resolution = attribute("RESOLUTION", in: line) ?? ""
                let height = Int(resolution.split(separator: "x").last.map(String.init) ?? "") ?? 0
                variants.append(Variant(url: url,
                                        bandwidth: Int(attribute("BANDWIDTH", in: line) ?? "") ?? 0,
                                        height: height,
                                        codecs: attribute("CODECS", in: line) ?? "",
                                        audioGroup: attribute("AUDIO", in: line)))
            }
        }
        return (variants, audio)
    }

    struct MediaPlaylist {
        var initSegment: Segment?
        var segments: [Segment] = []
        var isEncrypted = false
        var looksLikeTransportStream = false
    }

    static func parseMedia(_ manifest: String, base: URL) throws -> MediaPlaylist {
        var playlist = MediaPlaylist()
        var pendingRange: (length: Int, offset: Int)?
        /// Where the next `@`-less byte range continues from, per RFC 8216.
        var rangeCursor = 0

        for raw in manifest.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-KEY:") {
                // METHOD=NONE is the "no longer encrypted" marker, not a key.
                if (attribute("METHOD", in: line) ?? "NONE") != "NONE" { playlist.isEncrypted = true }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                if let uri = attribute("URI", in: line),
                   let url = URL(string: uri, relativeTo: base)?.absoluteURL {
                    playlist.initSegment = Segment(url: url, byteRange: byteRange(in: line, cursor: &rangeCursor))
                }
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                let value = String(line.dropFirst("#EXT-X-BYTERANGE:".count))
                pendingRange = parseByteRange(value, cursor: &rangeCursor)
            } else if !line.hasPrefix("#") {
                guard let url = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
                playlist.segments.append(Segment(url: url, byteRange: pendingRange))
                pendingRange = nil
                if url.pathExtension.lowercased() == "ts" { playlist.looksLikeTransportStream = true }
            }
        }
        return playlist
    }

    /// `#EXT-X-MAP:...,BYTERANGE="1234@0"`.
    private static func byteRange(in line: String, cursor: inout Int) -> (length: Int, offset: Int)? {
        guard let value = attribute("BYTERANGE", in: line) else { return nil }
        return parseByteRange(value, cursor: &cursor)
    }

    /// `<length>[@<offset>]` — an absent offset continues from the end of the
    /// previous range.
    private static func parseByteRange(_ value: String, cursor: inout Int) -> (length: Int, offset: Int)? {
        let parts = value.split(separator: "@").map(String.init)
        guard let length = Int(parts.first ?? "") else { return nil }
        let offset = parts.count > 1 ? (Int(parts[1]) ?? cursor) : cursor
        cursor = offset + length
        return (length, offset)
    }

    /// Reads `KEY=VALUE` / `KEY="VALUE"` out of an `#EXT-X-…` attribute list.
    /// Quoted values may contain commas (a CODECS list always does), so this
    /// can't just split on `,`.
    static func attribute(_ name: String, in line: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        if let quoted = BrowseHTTP.firstMatch(#"[,:]\#(escaped)="([^"]*)""#, in: line) {
            return quoted
        }
        return BrowseHTTP.firstMatch(#"[,:]\#(escaped)=([^,"]+)"#, in: line)
    }
}
