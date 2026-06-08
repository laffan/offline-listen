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
            data: [.videoId: videoID],
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
        guard let chosen = pool.max(by: { ($0.averageBitrate ?? 0) < ($1.averageBitrate ?? 0) }),
              let mediaURL = chosen.url else {
            throw ExtractorError.noAudioFormat
        }
        let ext = (chosen.mimeType ?? "").contains("webm") ? "webm" : "m4a"
        appLog("Selected audio · \(ext) · \(Int(chosen.averageBitrate ?? 0) / 1000) kbps", category: category)

        var request = URLRequest(url: mediaURL)
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let dest = AppPaths.work.appendingPathComponent("\(UUID().uuidString).\(ext)")
        appLog("Downloading audio stream in chunks…", category: category)
        onDownloadStart()

        try await AudioStreamDownloader.download(
            baseRequest: request,
            expectedSize: chosen.contentLength,
            to: dest,
            category: category,
            onProgress: onProgress
        )

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
