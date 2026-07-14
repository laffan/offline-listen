import Foundation
import AVFoundation

#if canImport(YouTubeKit)
import YouTubeKit
#endif

/// Native-Swift extractor backed by b5i/YouTubeKit (no Python, no on-device
/// engine download). Resolves the audio-only stream URL via YouTube's internal
/// API and downloads it with the shared chunked downloader.
final class YouTubeKitExtractor: MediaExtractor {
    /// YouTubeKit only speaks to YouTube, so it can handle a URL exactly when we
    /// can pull a video id out of it. Non-YouTube links (Vimeo, SoundCloud, …)
    /// return false so the composite goes straight to the yt-dlp fallback.
    func canHandle(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        let isYouTubeHost = host == "youtu.be"
            || host.hasSuffix("youtube.com")
            || host.hasSuffix("youtube-nocookie.com")
        return isYouTubeHost && Self.videoID(from: url) != nil
    }

    /// Which stream a (re-)resolution should pick — mirrors the three selection
    /// rules in `extractMedia` so a mid-download refresh re-picks consistently.
    private enum StreamKind {
        case video          // tallest device-playable H.264/HEVC mp4
        case audioOnly      // best audio-only (m4a preferred)
        case muxedSmallest  // smallest muxed mp4 (audio-extraction fallback)
    }

    private static func userAgentRequest(_ u: URL) -> URLRequest {
        var r = URLRequest(url: u)
        r.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        return r
    }

    #if canImport(YouTubeKit)
    /// The three stream-selection rules, defined once and used by both the
    /// initial pick in `extractMedia` and the mid-download refresher, so the
    /// two can't drift apart. Audio is restricted to mp4/m4a — AVFoundation
    /// can't decode the webm/opus streams YouTube also offers, so a webm pick
    /// would download completely and then fail verification; videos with no
    /// m4a audio route to the muxed-mp4 + extraction fallback instead.
    private static func pickBestVideo(_ videoFormats: [VideoDownloadFormat],
                                      quality: VideoQuality) -> VideoDownloadFormat? {
        let playable = videoFormats.filter {
            $0.url != nil && ($0.mimeType ?? "").contains("mp4") && PlayableVideoCodec.isPlayable(mimeType: $0.mimeType)
        }
        return quality.pick(from: playable, height: { $0.height ?? 0 })
    }

    private static func pickBestAudio(_ audioFormats: [AudioOnlyFormat]) -> AudioOnlyFormat? {
        audioFormats
            .filter { $0.url != nil && ($0.mimeType ?? "").contains("mp4") }
            .max(by: { ($0.averageBitrate ?? 0) < ($1.averageBitrate ?? 0) })
    }

    private static func pickSmallestMuxed(_ videoFormats: [VideoDownloadFormat]) -> VideoDownloadFormat? {
        videoFormats
            .filter { $0.url != nil && ($0.mimeType ?? "").contains("mp4") }
            .min(by: { ($0.height ?? .max) < ($1.height ?? .max) })
    }

    /// Re-resolves the video and returns a fresh request for the same stream.
    /// Handed to `AudioStreamDownloader` as its refresher, so a stream URL that
    /// expires or gets rejected (403) mid-download is replaced and the download
    /// resumes from its current offset instead of failing.
    ///
    /// Resuming mid-file requires the *same rendition*, not just the same
    /// selection rule — appending bytes from a different-quality stream would
    /// corrupt the file. So when `matchingLength` (the original format's
    /// contentLength) is known, only an exact byte-size match qualifies and a
    /// miss returns nil (a clean "couldn't re-resolve" failure); the selection
    /// rule is used only when the original size was never known, and the
    /// downloader's Content-Range consistency check backstops that case.
    private func freshMediaRequest(videoID: String,
                                   kind: StreamKind,
                                   quality: VideoQuality,
                                   matchingLength: Int?,
                                   category: String) async throws -> URLRequest? {
        appLog("Re-resolving \(videoID) via YouTubeKit for a fresh stream URL…", category: category)
        let response = try await VideoInfosWithDownloadFormatsResponse.sendThrowingRequest(
            youtubeModel: YouTubeModel(),
            data: [.query: videoID],
            useCookies: nil
        )
        let videoFormats = (response.downloadFormats + response.defaultFormats)
            .compactMap { $0 as? VideoDownloadFormat }
        let audioFormats = response.downloadFormats.compactMap { $0 as? AudioOnlyFormat }

        if let matchingLength {
            let exact: URL?
            switch kind {
            case .video, .muxedSmallest:
                exact = videoFormats.first { $0.url != nil && $0.contentLength == matchingLength }?.url
            case .audioOnly:
                exact = audioFormats.first { $0.url != nil && $0.contentLength == matchingLength }?.url
            }
            guard let exact else {
                appLog("Fresh resolve no longer offers the original rendition (\(matchingLength) bytes) — not resuming into a different one.",
                       level: .warning, category: category)
                return nil
            }
            return Self.userAgentRequest(exact)
        }

        let streamURL: URL?
        switch kind {
        case .video: streamURL = Self.pickBestVideo(videoFormats, quality: quality)?.url
        case .muxedSmallest: streamURL = Self.pickSmallestMuxed(videoFormats)?.url
        case .audioOnly: streamURL = Self.pickBestAudio(audioFormats)?.url
        }
        return streamURL.map(Self.userAgentRequest)
    }
    #endif

    func extractMedia(from url: URL,
                      mode: DownloadMode,
                      quality: VideoQuality,
                      onDownloadStart: @escaping () -> Void,
                      onProgress: @escaping (Double) -> Void) async throws -> ExtractedMedia {
        let category = "YouTubeKit"
        #if canImport(YouTubeKit)
        guard let videoID = Self.videoID(from: url) else {
            throw ExtractorError.invalidURL
        }
        appLog("Resolving \(videoID) via YouTubeKit…", category: category)

        // The resolve call is opaque (network + on-device player-JS decoding);
        // a heartbeat keeps a stall visible in the log instead of silent.
        let model = YouTubeModel()
        let response = try await withHeartbeat("Still resolving \(videoID) via YouTubeKit",
                                               category: category) {
            try await VideoInfosWithDownloadFormatsResponse.sendThrowingRequest(
                youtubeModel: model,
                data: [.query: videoID],
                useCookies: nil
            )
        }

        let title = response.videoInfos.title ?? url.absoluteString

        let videoFormats = (response.downloadFormats + response.defaultFormats)
            .compactMap { $0 as? VideoDownloadFormat }
        let audioFormats = response.downloadFormats.compactMap { $0 as? AudioOnlyFormat }

        // Log every discovered format so we can see what's available.
        appLog("Info: \"\(title)\" · \(videoFormats.count) video, \(audioFormats.count) audio", level: .success, category: category)
        for v in videoFormats.prefix(20) {
            appLog("· video \(v.quality ?? "?") \(v.mimeType ?? "?") len=\(v.contentLength.map(String.init) ?? "?") url=\(v.url != nil)", level: .debug, category: category)
        }
        for a in audioFormats.prefix(20) {
            appLog("· audio \(a.mimeType ?? "?") \(Int(a.averageBitrate ?? 0) / 1000)kbps len=\(a.contentLength.map(String.init) ?? "?") url=\(a.url != nil)", level: .debug, category: category)
        }

        // Best decodable audio-only stream (mp4/m4a only — a webm/opus pick
        // would download fully and then fail verification) — used for audio
        // mode and as the merge track when a video stream is video-only.
        let bestAudio = Self.pickBestAudio(audioFormats)

        let mediaURL: URL
        let ext: String
        let expectedSize: Int?
        let chosenKind: StreamKind
        var mergeAudioRequest: URLRequest?
        var extractAudioAfterDownload = false

        if mode == .video {
            // Best MP4 with video AVFoundation can decode, honouring the
            // quality preference. AV1/VP9 streams (which YouTube often offers)
            // play as a blank QuickTime placeholder on iOS, so restrict to
            // H.264/HEVC. If video-only, VideoMerger adds audio.
            guard let video = Self.pickBestVideo(videoFormats, quality: quality), let videoURL = video.url else {
                let mp4Video = videoFormats.filter { $0.url != nil && ($0.mimeType ?? "").contains("mp4") }
                let offered = Set(mp4Video.compactMap { $0.mimeType }).sorted().joined(separator: " | ")
                appLog("No device-playable video stream (need H.264/HEVC) — offered: \(offered.isEmpty ? "none" : offered)",
                       level: .error, category: category)
                throw ExtractorError.unplayableVideoCodec(offered.isEmpty ? "none" : offered)
            }
            mediaURL = videoURL
            ext = "mp4"
            expectedSize = video.contentLength
            chosenKind = .video
            mergeAudioRequest = bestAudio?.url.map(Self.userAgentRequest)
            let sizeHint = video.contentLength.map { " · ~\($0 / 1024 / 1024) MB" } ?? " · size unknown"
            appLog("Selected video (\(video.quality ?? "?")) \(video.mimeType ?? "?")\(sizeHint)\(bestAudio == nil ? " · no audio-only stream found to merge" : "")", category: category)
        } else if let chosen = bestAudio, let chosenURL = chosen.url {
            mediaURL = chosenURL
            ext = "m4a"
            expectedSize = chosen.contentLength
            chosenKind = .audioOnly
            let sizeHint = chosen.contentLength.map { " · ~\($0 / 1024 / 1024) MB" } ?? " · size unknown"
            appLog("Selected audio · \(ext) · \(Int(chosen.averageBitrate ?? 0) / 1000) kbps\(sizeHint)", category: category)
        } else {
            // No decodable dedicated audio stream (none at all, or webm/opus
            // only): grab the smallest muxed MP4 and extract its audio.
            guard let video = Self.pickSmallestMuxed(videoFormats), let videoURL = video.url else {
                throw ExtractorError.noAudioFormat
            }
            mediaURL = videoURL
            ext = "mp4"
            expectedSize = video.contentLength
            chosenKind = .muxedSmallest
            extractAudioAfterDownload = true
            appLog("No audio-only stream — falling back to muxed video (\(video.quality ?? "?")) + audio extraction",
                   level: .warning, category: category)
        }

        let request = Self.userAgentRequest(mediaURL)

        var dest = AppPaths.work.appendingPathComponent("\(UUID().uuidString).\(ext)")
        appLog("Downloading \(mode == .video ? "video" : (extractAudioAfterDownload ? "video" : "audio")) stream in chunks…", category: category)
        onDownloadStart()

        try await AudioStreamDownloader.download(
            baseRequest: request,
            expectedSize: expectedSize,
            to: dest,
            category: category,
            refresh: { [self] in
                try await freshMediaRequest(videoID: videoID, kind: chosenKind, quality: quality,
                                            matchingLength: expectedSize, category: category)
            },
            onProgress: onProgress
        )

        if mode == .video {
            let mergeAudioLength = bestAudio?.contentLength
            dest = try await VideoMerger.ensureAudio(
                videoFile: dest, audioRequest: mergeAudioRequest,
                audioRefresh: { [self] in
                    try await freshMediaRequest(videoID: videoID, kind: .audioOnly, quality: quality,
                                                matchingLength: mergeAudioLength, category: category)
                },
                category: category)
        } else if extractAudioAfterDownload {
            dest = try await VideoAudioExtractor.extractAudio(fromVideo: dest, category: category)
        }

        // A file that saved but can't be decoded (truncated or token-poisoned
        // stream) must fail here, so the composite falls back to yt-dlp instead
        // of a broken track landing in the library.
        let duration = try await MediaVerifier.verify(dest, isVideo: mode == .video, category: category)
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? nil
        appLog("Download finished: \(dest.lastPathComponent)\(size.map { " (\($0 / 1024) KB)" } ?? "")",
               level: .success, category: category)

        return ExtractedMedia(fileURL: dest, title: title, duration: duration, isVideo: mode == .video)
        #else
        throw ExtractorError.packageUnavailable
        #endif
    }

    /// Extracts the 11-character video id from common YouTube URL shapes.
    static func videoID(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let host = (components.host ?? "").lowercased()

        if host.contains("youtu.be") {
            return components.path.split(separator: "/").first.map(String.init)
        }
        if let v = components.queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty {
            return v
        }
        // /shorts/<id>, /embed/<id>, /live/<id>
        let parts = components.path.split(separator: "/").map(String.init)
        if let idx = parts.firstIndex(where: { ["shorts", "embed", "live", "v"].contains($0) }),
           idx + 1 < parts.count {
            return parts[idx + 1]
        }
        return nil
    }
}
