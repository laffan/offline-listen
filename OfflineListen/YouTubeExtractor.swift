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
    /// - Parameter progress: 0...1 download fraction. YoutubeDL-iOS does not
    ///   surface a progress callback here, so the production implementation only
    ///   reports 0 at the start; the UI shows an indeterminate spinner.
    func extractAudio(from url: URL,
                      progress: @escaping (Double) -> Void) async throws -> ExtractedAudio
}

/// Production implementation backed by kewlbear/YoutubeDL-iOS (yt-dlp on device).
///
/// First launch downloads the yt-dlp Python module (tens of MB) and therefore
/// requires a network connection. Subsequent extractions reuse the cached module.
/// The library remuxes the selected audio-only stream into a playable container
/// (an `.m4a`) and returns the final file URL.
final class YoutubeDLExtractor: YouTubeAudioExtractor {
    /// Reference box so the (escaping) format-selector closure can hand metadata
    /// back out of the single extraction the download performs.
    private final class Metadata {
        var title = ""
        var duration: Double = 0
    }

    func extractAudio(from url: URL,
                      progress: @escaping (Double) -> Void) async throws -> ExtractedAudio {
        #if canImport(YoutubeDL)
        progress(0)
        do {
            // First run: fetch the on-device yt-dlp Python module if missing.
            if !FileManager.default.fileExists(atPath: YoutubeDL.pythonModuleURL.path) {
                try await YoutubeDL.downloadPythonModule()
            }

            let youtubeDL = YoutubeDL()
            let metadata = Metadata()

            // The format selector receives the extracted `Info`; we capture the
            // title/duration there and choose the best audio-only stream,
            // preferring an m4a so remuxing stays container-only (no transcode).
            let fileURL = try await youtubeDL.download(url: url) { info in
                metadata.title = info.title
                metadata.duration = info.duration ?? 0

                let audioOnly = info.formats.filter { $0.isAudioOnly }
                let m4a = audioOnly.filter { $0.ext == "m4a" }
                let pool = m4a.isEmpty ? audioOnly : m4a
                let chosen = pool.max(by: { ($0.abr ?? $0.tbr ?? 0) < ($1.abr ?? $1.tbr ?? 0) })
                    ?? info.formats.max(by: { ($0.tbr ?? 0) < ($1.tbr ?? 0) })
                    ?? info.formats[0]

                // Tuple: (formats, outputURL?, timeRange?, bitRate?, title).
                return ([chosen], nil, nil, chosen.abr ?? chosen.tbr, info.safeTitle)
            }

            return ExtractedAudio(
                fileURL: fileURL,
                title: metadata.title.isEmpty ? url.absoluteString : metadata.title,
                duration: metadata.duration
            )
        } catch {
            throw ExtractorError.downloadFailed(error.localizedDescription)
        }
        #else
        throw ExtractorError.packageUnavailable
        #endif
    }
}

/// Lets you exercise the queue/library/player UI without the native package by
/// generating a placeholder entry. Swap `DownloadManager`'s default extractor to
/// this in previews or simulator smoke tests.
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
