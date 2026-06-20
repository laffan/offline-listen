import Foundation
import AVFoundation

/// Splits a single downloaded file into one file per chapter, using
/// AVFoundation's export session (audio → `.m4a`, video → passthrough `.mp4`) —
/// no FFmpeg. Each slice is written straight into Documents so it can become its
/// own library track. Used by "Break Chapters into Playlist".
enum ChapterSplitter {
    enum SplitError: LocalizedError {
        case noSession
        case exportFailed(String)
        case emptyOutput

        var errorDescription: String? {
            switch self {
            case .noSession: return "Could not create an export session for this file."
            case .exportFailed(let message): return message
            case .emptyOutput: return "A chapter export produced an empty file."
            }
        }
    }

    /// Exports the `[start, end)` range of `sourceURL` into a new Documents file
    /// named after `baseName`, returning the file name (relative to Documents).
    static func exportSlice(from sourceURL: URL,
                            start: Double,
                            end: Double,
                            isVideo: Bool,
                            baseName: String) async throws -> String {
        let asset = AVURLAsset(url: sourceURL)
        let preset = isVideo ? AVAssetExportPresetPassthrough : AVAssetExportPresetAppleM4A
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw SplitError.noSession
        }

        let ext = isVideo ? "mp4" : "m4a"
        let fileType: AVFileType = isVideo ? .mp4 : .m4a
        let name = AppPaths.uniqueDocumentName(base: baseName.sanitizedFileName(), ext: ext)
        let outURL = AppPaths.documents.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: outURL)

        session.outputURL = outURL
        session.outputFileType = fileType
        let startTime = CMTime(seconds: max(0, start), preferredTimescale: 600)
        let endTime = CMTime(seconds: max(start, end), preferredTimescale: 600)
        session.timeRange = CMTimeRange(start: startTime, end: endTime)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                switch session.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    let message = session.error?.localizedDescription ?? "Chapter export failed."
                    continuation.resume(throwing: SplitError.exportFailed(message))
                }
            }
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int).flatMap { $0 } ?? 0
        guard size > 0 else {
            try? FileManager.default.removeItem(at: outURL)
            throw SplitError.emptyOutput
        }
        return name
    }
}
