import Foundation

#if canImport(YoutubeDL)
import YoutubeDL
#endif

/// Result of extracting + downloading the audio stream for a URL.
struct ExtractedAudio {
    /// On-disk location of the downloaded audio (typically `.m4a`).
    let fileURL: URL
    let title: String
    let duration: Double
}

enum ExtractorError: LocalizedError {
    case packageUnavailable
    case invalidURL
    case noAudioFormat
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .packageUnavailable:
            return "YoutubeDL-iOS is not linked. Add the Swift package in Xcode (see README)."
        case .invalidURL:
            return "That doesn't look like a valid URL."
        case .noAudioFormat:
            return "No downloadable audio track was found for this video."
        case .downloadFailed(let message):
            return message
        }
    }
}

/// Abstraction over the YouTube audio extraction step so the rest of the app is
/// independent of the concrete library and can be unit-tested with a mock.
protocol YouTubeAudioExtractor {
    /// Downloads the best audio-only stream for `url`.
    /// - Parameter progress: 0...1 download fraction, may be called off the main thread.
    func extractAudio(from url: URL,
                      progress: @escaping (Double) -> Void) async throws -> ExtractedAudio
}

/// Production implementation backed by kewlbear/YoutubeDL-iOS (yt-dlp on device).
///
/// NOTE ON INTEGRATION
/// -------------------
/// YoutubeDL-iOS bridges to the Python `yt_dlp` module, whose Swift surface has
/// shifted across releases. The call below reflects the common shape of the API
/// (init → optional one-time Python module download → `download(url:)`). When you
/// resolve the package in Xcode, confirm the method names against the installed
/// version's headers and adjust this single method if needed — nothing else in
/// the app depends on these specifics.
///
/// First launch downloads the yt-dlp Python files (~tens of MB) and therefore
/// requires a network connection. Subsequent extractions reuse the cached module.
final class YoutubeDLExtractor: YouTubeAudioExtractor {
    func extractAudio(from url: URL,
                      progress: @escaping (Double) -> Void) async throws -> ExtractedAudio {
        #if canImport(YoutubeDL)
        do {
            // Ensure the on-device yt-dlp Python module is present (first run only).
            if YoutubeDL.shouldDownloadPythonModule {
                try await YoutubeDL.downloadPythonModule()
            }

            let youtubeDL = try YoutubeDL()

            // Request best audio-only stream, preferring an m4a container so the
            // result is immediately playable with no transcode.
            let (fileURLs, info) = try await youtubeDL.download(
                url: url,
                options: "bestaudio[ext=m4a]/bestaudio/best"
            ) { fraction in
                progress(fraction)
            }

            guard let audioURL = fileURLs.first else {
                throw ExtractorError.noAudioFormat
            }

            return ExtractedAudio(
                fileURL: audioURL,
                title: info.title ?? url.lastPathComponent,
                duration: info.duration ?? 0
            )
        } catch let error as ExtractorError {
            throw error
        } catch {
            throw ExtractorError.downloadFailed(error.localizedDescription)
        }
        #else
        throw ExtractorError.packageUnavailable
        #endif
    }
}

/// Lets you exercise the queue/library/player UI without the heavy native
/// packages by generating a short silent tone. Swap `DownloadManager`'s default
/// extractor to this in previews or simulator smoke tests.
final class MockExtractor: YouTubeAudioExtractor {
    func extractAudio(from url: URL,
                      progress: @escaping (Double) -> Void) async throws -> ExtractedAudio {
        for step in 1...10 {
            try await Task.sleep(nanoseconds: 120_000_000)
            progress(Double(step) / 10)
        }
        let dest = AppPaths.work.appendingPathComponent("\(UUID().uuidString).m4a")
        // A real file isn't produced here; the mock is only for UI flow testing.
        FileManager.default.createFile(atPath: dest.path, contents: Data())
        return ExtractedAudio(fileURL: dest, title: "Mock Track \(Int.random(in: 1...999))", duration: 180)
    }
}
