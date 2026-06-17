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
        DownloadManager.isYouTubeURL(url.absoluteString) && Self.videoID(from: url) != nil
    }

    func extractMedia(from url: URL,
                      mode: DownloadMode,
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

        func userAgentRequest(_ u: URL) -> URLRequest {
            var r = URLRequest(url: u)
            r.setValue(
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                forHTTPHeaderField: "User-Agent"
            )
            return r
        }

        // Best audio-only (m4a preferred) — used for audio mode and as the merge
        // track when a video stream turns out to be video-only.
        let usableAudio = audioFormats.filter { $0.url != nil }
        let m4aAudio = usableAudio.filter { ($0.mimeType ?? "").contains("mp4") }
        let bestAudio = (m4aAudio.isEmpty ? usableAudio : m4aAudio)
            .max(by: { ($0.averageBitrate ?? 0) < ($1.averageBitrate ?? 0) })

        let mediaURL: URL
        let ext: String
        let expectedSize: Int?
        var mergeAudioRequest: URLRequest?
        var extractAudioAfterDownload = false

        if mode == .video {
            // Best MP4 with video AVFoundation can decode. AV1/VP9 streams (which
            // YouTube often offers) play as a blank QuickTime placeholder on iOS,
            // so restrict to H.264/HEVC. If video-only, VideoMerger adds audio.
            let mp4Video = videoFormats.filter { $0.url != nil && ($0.mimeType ?? "").contains("mp4") }
            let playable = mp4Video.filter { PlayableVideoCodec.isPlayable(mimeType: $0.mimeType) }
            if playable.isEmpty {
                let offered = Set(mp4Video.compactMap { $0.mimeType }).sorted().joined(separator: " | ")
                appLog("No device-playable video stream (need H.264/HEVC) — offered: \(offered.isEmpty ? "none" : offered)",
                       level: .error, category: category)
                throw ExtractorError.unplayableVideoCodec(offered.isEmpty ? "none" : offered)
            }
            guard let video = playable.max(by: { ($0.height ?? 0) < ($1.height ?? 0) }), let videoURL = video.url else {
                throw ExtractorError.noVideoFormat
            }
            mediaURL = videoURL
            ext = "mp4"
            expectedSize = video.contentLength
            mergeAudioRequest = bestAudio?.url.map(userAgentRequest)
            let sizeHint = video.contentLength.map { " · ~\($0 / 1024 / 1024) MB" } ?? " · size unknown"
            appLog("Selected video (\(video.quality ?? "?")) \(video.mimeType ?? "?")\(sizeHint)\(bestAudio == nil ? " · no audio-only stream found to merge" : "")", category: category)
        } else if let chosen = bestAudio, let chosenURL = chosen.url {
            mediaURL = chosenURL
            ext = (chosen.mimeType ?? "").contains("webm") ? "webm" : "m4a"
            expectedSize = chosen.contentLength
            let sizeHint = chosen.contentLength.map { " · ~\($0 / 1024 / 1024) MB" } ?? " · size unknown"
            appLog("Selected audio · \(ext) · \(Int(chosen.averageBitrate ?? 0) / 1000) kbps\(sizeHint)", category: category)
        } else {
            // No dedicated audio stream: grab the smallest muxed MP4 and extract audio.
            let mp4Video = videoFormats.filter { $0.url != nil && ($0.mimeType ?? "").contains("mp4") }
            guard let video = mp4Video.min(by: { ($0.height ?? .max) < ($1.height ?? .max) }), let videoURL = video.url else {
                throw ExtractorError.noAudioFormat
            }
            mediaURL = videoURL
            ext = "mp4"
            expectedSize = video.contentLength
            extractAudioAfterDownload = true
            appLog("No audio-only stream — falling back to muxed video (\(video.quality ?? "?")) + audio extraction",
                   level: .warning, category: category)
        }

        let request = userAgentRequest(mediaURL)

        var dest = AppPaths.work.appendingPathComponent("\(UUID().uuidString).\(ext)")
        appLog("Downloading \(mode == .video ? "video" : (extractAudioAfterDownload ? "video" : "audio")) stream in chunks…", category: category)
        onDownloadStart()

        try await AudioStreamDownloader.download(
            baseRequest: request,
            expectedSize: expectedSize,
            to: dest,
            category: category,
            onProgress: onProgress
        )

        if mode == .video {
            dest = try await VideoMerger.ensureAudio(videoFile: dest, audioRequest: mergeAudioRequest, category: category)
        } else if extractAudioAfterDownload {
            dest = try await VideoAudioExtractor.extractAudio(fromVideo: dest, category: category)
        }

        let duration = await mediaDuration(of: dest)
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
