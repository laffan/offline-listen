import Foundation

/// Tries a primary extractor and, if it fails, falls back to a secondary one.
/// Cancellation is never treated as a failure — it propagates immediately so the
/// Cancel button doesn't accidentally trigger the fallback.
final class CompositeExtractor: YouTubeAudioExtractor {
    private let primary: YouTubeAudioExtractor
    private let primaryName: String
    private let fallback: YouTubeAudioExtractor
    private let fallbackName: String

    init(primary: YouTubeAudioExtractor, named primaryName: String,
         fallback: YouTubeAudioExtractor, named fallbackName: String) {
        self.primary = primary
        self.primaryName = primaryName
        self.fallback = fallback
        self.fallbackName = fallbackName
    }

    func extractAudio(from url: URL,
                      onDownloadStart: @escaping () -> Void,
                      onProgress: @escaping (Double) -> Void) async throws -> ExtractedAudio {
        do {
            appLog("Trying \(primaryName)…", category: "Extract")
            return try await primary.extractAudio(from: url,
                                                  onDownloadStart: onDownloadStart,
                                                  onProgress: onProgress)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                throw error
            }
            appLog("\(primaryName) failed: \(error.localizedDescription) — falling back to \(fallbackName)",
                   level: .warning, category: "Extract")
            return try await fallback.extractAudio(from: url,
                                                   onDownloadStart: onDownloadStart,
                                                   onProgress: onProgress)
        }
    }
}
