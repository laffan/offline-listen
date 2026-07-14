import Foundation

/// Tries a primary extractor and, if it fails, falls back to a secondary one.
/// Cancellation is never treated as a failure — it propagates immediately so the
/// Cancel button doesn't accidentally trigger the fallback.
final class CompositeExtractor: MediaExtractor {
    private let primary: MediaExtractor
    private let primaryName: String
    private let fallback: MediaExtractor
    private let fallbackName: String

    init(primary: MediaExtractor, named primaryName: String,
         fallback: MediaExtractor, named fallbackName: String) {
        self.primary = primary
        self.primaryName = primaryName
        self.fallback = fallback
        self.fallbackName = fallbackName
    }

    func extractMedia(from url: URL,
                      mode: DownloadMode,
                      quality: VideoQuality,
                      onDownloadStart: @escaping () -> Void,
                      onProgress: @escaping (Double) -> Void) async throws -> ExtractedMedia {
        // Skip the primary entirely for URLs it can't handle (e.g. the native
        // YouTube extractor on a Vimeo/SoundCloud link) — going straight to the
        // fallback avoids a noisy, guaranteed failure in the log.
        guard primary.canHandle(url) else {
            appLog("\(primaryName) doesn't handle this URL — using \(fallbackName).", category: "Extract")
            return try await fallback.extractMedia(from: url, mode: mode, quality: quality,
                                                   onDownloadStart: onDownloadStart,
                                                   onProgress: onProgress)
        }
        do {
            appLog("Trying \(primaryName)…", category: "Extract")
            return try await primary.extractMedia(from: url, mode: mode, quality: quality,
                                                  onDownloadStart: onDownloadStart,
                                                  onProgress: onProgress)
        } catch {
            if isCancellation(error) { throw error }
            appLog("\(primaryName) failed: \(error.localizedDescription) — falling back to \(fallbackName)",
                   level: .warning, category: "Extract")
            // localizedDescription is generic (e.g. YouTubeKit's "ResponseError
            // error 1"); the full value usually names the real reason a video is
            // rejected — age-gate, region/members-only, sign-in required, or a
            // player change — which is what distinguishes a video that works
            // from one that doesn't.
            appLog("\(primaryName) error detail: \(String(describing: error))", level: .debug, category: "Extract")
            return try await fallback.extractMedia(from: url, mode: mode, quality: quality,
                                                   onDownloadStart: onDownloadStart,
                                                   onProgress: onProgress)
        }
    }
}
