import Foundation
import AVFoundation

/// Extracts the audio track from a downloaded video file into a standalone
/// `.m4a`, using AVFoundation's export session — no FFmpeg required. Used as a
/// last-resort fallback when a video has no dedicated audio-only stream.
///
/// Note: AVFoundation reads MP4/MOV but not WebM, so callers must only feed this
/// MP4 downloads.
enum VideoAudioExtractor {
    static func extractAudio(fromVideo videoURL: URL, category: String) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)

        // Verify there is actually audio inside before exporting.
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw ExtractorError.downloadFailed("The downloaded video contains no audio track.")
        }
        appLog("Video has \(audioTracks.count) audio track(s) — extracting to m4a…", category: category)

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ExtractorError.downloadFailed("Could not create an audio extraction session.")
        }
        let dest = AppPaths.work.appendingPathComponent("\(UUID().uuidString).m4a")
        try? FileManager.default.removeItem(at: dest)
        session.outputURL = dest
        session.outputFileType = .m4a

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                switch session.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    let message = session.error?.localizedDescription ?? "Audio extraction failed."
                    continuation.resume(throwing: ExtractorError.downloadFailed(message))
                }
            }
        }

        // Final sanity check: the exported file must exist and contain audio.
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int).flatMap { $0 } ?? 0
        guard size > 0 else {
            throw ExtractorError.downloadFailed("Audio extraction produced an empty file.")
        }
        let exported = AVURLAsset(url: dest)
        let exportedAudio = try await exported.loadTracks(withMediaType: .audio)
        guard !exportedAudio.isEmpty else {
            try? FileManager.default.removeItem(at: dest)
            throw ExtractorError.downloadFailed("Extracted file has no audible track.")
        }

        try? FileManager.default.removeItem(at: videoURL)
        appLog("Audio extracted: \(dest.lastPathComponent) (\(size / 1024) KB)", level: .success, category: category)
        return dest
    }
}
