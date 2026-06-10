import Foundation
import AVFoundation

#if canImport(YouTubeKit)
import YouTubeKit
#endif

/// Native-Swift extractor backed by b5i/YouTubeKit (no Python, no on-device
/// engine download). Resolves the audio-only stream URL via YouTube's internal
/// API and downloads it with the shared chunked downloader.
final class YouTubeKitExtractor: YouTubeAudioExtractor {
    func extractAudio(from url: URL,
                      onDownloadStart: @escaping () -> Void,
                      onProgress: @escaping (Double) -> Void) async throws -> ExtractedAudio {
        let category = "YouTubeKit"
        #if canImport(YouTubeKit)
        guard let videoID = Self.videoID(from: url) else {
            throw ExtractorError.invalidURL
        }
        appLog("Resolving \(videoID) via YouTubeKit…", category: category)

        let model = YouTubeModel()
        let response = try await VideoInfosWithDownloadFormatsResponse.sendThrowingRequest(
            youtubeModel: model,
            data: [.query: videoID],
            useCookies: nil
        )

        let title = response.videoInfos.title ?? url.absoluteString
        let audioFormats = response.downloadFormats.compactMap { $0 as? AudioOnlyFormat }
        appLog("Info: \"\(title)\" · \(audioFormats.count) audio formats", level: .success, category: category)

        // Prefer m4a/AAC (audio/mp4) so the file plays with no transcode; among
        // those pick the highest bitrate with a usable URL.
        let usable = audioFormats.filter { $0.url != nil }
        let mp4 = usable.filter { ($0.mimeType ?? "").contains("mp4") }
        let pool = mp4.isEmpty ? usable : mp4

        let mediaURL: URL
        let ext: String
        let expectedSize: Int?
        var extractAfterDownload = false

        if let chosen = pool.max(by: { ($0.averageBitrate ?? 0) < ($1.averageBitrate ?? 0) }),
           let chosenURL = chosen.url {
            mediaURL = chosenURL
            ext = (chosen.mimeType ?? "").contains("webm") ? "webm" : "m4a"
            expectedSize = chosen.contentLength
            appLog("Selected audio · \(ext) · \(Int(chosen.averageBitrate ?? 0) / 1000) kbps", category: category)
        } else {
            // Fallback: no dedicated audio stream. Download a muxed (video+audio)
            // MP4 and extract its audio track afterwards. AVFoundation can't read
            // WebM, so only MP4 candidates qualify. Lowest resolution wins — we
            // only want the audio.
            let muxed = (response.downloadFormats + response.defaultFormats)
                .compactMap { $0 as? VideoDownloadFormat }
                .filter { $0.url != nil && ($0.mimeType ?? "").contains("mp4") }
            guard let video = muxed.min(by: { ($0.height ?? .max) < ($1.height ?? .max) }),
                  let videoURL = video.url else {
                throw ExtractorError.noAudioFormat
            }
            mediaURL = videoURL
            ext = "mp4"
            expectedSize = video.contentLength
            extractAfterDownload = true
            appLog("No audio-only stream — falling back to muxed video (\(video.quality ?? "?")) + audio extraction",
                   level: .warning, category: category)
        }

        var request = URLRequest(url: mediaURL)
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        var dest = AppPaths.work.appendingPathComponent("\(UUID().uuidString).\(ext)")
        appLog("Downloading \(extractAfterDownload ? "video" : "audio") stream in chunks…", category: category)
        onDownloadStart()

        try await AudioStreamDownloader.download(
            baseRequest: request,
            expectedSize: expectedSize,
            to: dest,
            category: category,
            onProgress: onProgress
        )

        if extractAfterDownload {
            dest = try await VideoAudioExtractor.extractAudio(fromVideo: dest, category: category)
        }

        // YouTubeKit's response carries no duration; read it from the file.
        let duration = (try? AVAudioPlayer(contentsOf: dest))?.duration ?? 0
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? nil
        appLog("Download finished: \(dest.lastPathComponent)\(size.map { " (\($0 / 1024) KB)" } ?? "")",
               level: .success, category: category)

        return ExtractedAudio(fileURL: dest, title: title, duration: duration)
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
