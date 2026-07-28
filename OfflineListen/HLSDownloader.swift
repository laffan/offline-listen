import Foundation
import AVFoundation

/// Saves an **HLS** (`.m3u8`) stream to an ordinary local file using
/// AVFoundation alone — no FFmpeg, no segment stitching of our own.
///
/// `AudioStreamDownloader` fetches a single file over byte ranges, so it can't
/// touch a playlist of segments. That's fine for YouTube, whose DASH renditions
/// are direct URLs, but it's the whole story on **Vimeo**: since Vimeo retired
/// progressive files for most accounts, an ordinary Vimeo link offers HLS and
/// nothing else, and the download failed with `hlsOnly` before it ever started.
///
/// `AVAssetExportSession` reads a remote HLS asset natively (it's the same
/// machinery `AVPlayer` streams with) and writes a finished m4a/mp4. Audio uses
/// the `AppleM4A` preset — which keeps only the audio track, so a video-carrying
/// variant still yields a clean audio file — and video uses the tallest
/// size-capped preset the asset supports.
///
/// Two limits are inherent and deliberately not worked around: a **live**
/// stream has no end, so it would export forever (VOD only), and video export
/// re-encodes rather than copying, so it's slower than a progressive download of
/// the same video. Both are the price of not shipping FFmpeg.
enum HLSDownloader {
    /// Downloads `playlist` to `destination`. Returns the file it actually
    /// wrote (same as `destination`). Honours task cancellation by cancelling
    /// the export.
    static func download(playlist: URL,
                         headers: [String: String],
                         mode: DownloadMode,
                         quality: VideoQuality,
                         to destination: URL,
                         category: String,
                         onProgress: @escaping (Double) -> Void) async throws -> URL {
        var options: [String: Any] = [:]
        if !headers.isEmpty {
            // Undocumented but long-standing: without it a site that checks
            // Referer (Vimeo's player URLs do) refuses the segment requests
            // even though the playlist itself loaded.
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }
        let asset = AVURLAsset(url: playlist, options: options)

        // Confirm the stream actually carries what we're asking for before
        // spending an export on it.
        let neededType: AVMediaType = mode == .video ? .video : .audio
        let tracks = (try? await asset.loadTracks(withMediaType: neededType)) ?? []
        guard !tracks.isEmpty else {
            throw ExtractorError.downloadFailed(
                "The HLS stream carries no \(mode == .video ? "video" : "audio") track (or it couldn't be read).")
        }

        let presetName = try await preset(for: asset, mode: mode, quality: quality, category: category)
        guard let session = AVAssetExportSession(asset: asset, presetName: presetName) else {
            throw ExtractorError.downloadFailed("Could not create an export session for the HLS stream.")
        }
        try? FileManager.default.removeItem(at: destination)
        session.outputURL = destination
        session.outputFileType = mode == .video ? .mp4 : .m4a
        session.shouldOptimizeForNetworkUse = true

        appLog("HLS stream — exporting with AVFoundation (\(presetName))…", category: category)

        // The export reports its own 0…1 progress; sample it so the queue row
        // moves instead of sitting at 0% for the length of the video. A GCD
        // timer rather than a polling Task, mirroring `withTimeout` — the
        // export blocks nothing here, but the timer needs no task of its own.
        let poll = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        poll.schedule(deadline: .now() + 0.5, repeating: 0.5)
        poll.setEventHandler { onProgress(Double(session.progress)) }
        poll.resume()
        defer { poll.cancel() }

        try await withTaskCancellationHandler {
            try await withHeartbeat("Still converting the HLS stream", category: category,
                                    progress: { Double(session.progress) }) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    session.exportAsynchronously {
                        switch session.status {
                        case .completed:
                            continuation.resume()
                        case .cancelled:
                            continuation.resume(throwing: CancellationError())
                        default:
                            let message = session.error?.localizedDescription
                                ?? "The HLS export failed for an unknown reason."
                            continuation.resume(throwing: ExtractorError.downloadFailed(
                                "Couldn't convert the HLS stream: \(message)"))
                        }
                    }
                }
            }
        } onCancel: {
            session.cancelExport()
        }

        onProgress(1)
        return destination
    }

    /// The export preset to use: audio always takes `AppleM4A` (audio-only
    /// output, whatever the source carried); video takes the tallest preset the
    /// asset supports at or below the quality cap, so the picker still means
    /// something on an HLS source.
    ///
    /// Presets are checked against the asset rather than assumed — a stream
    /// AVFoundation won't export at 1080p still exports at 720p, and finding
    /// that out here beats a failed export.
    private static func preset(for asset: AVURLAsset,
                               mode: DownloadMode,
                               quality: VideoQuality,
                               category: String) async throws -> String {
        guard mode == .video else { return AVAssetExportPresetAppleM4A }

        let compatible = Set(AVAssetExportSession.exportPresets(compatibleWith: asset))
        // Tallest first; each entry is (height, preset name).
        let ladder: [(Int, String)] = [
            (2160, AVAssetExportPreset3840x2160),
            (1080, AVAssetExportPreset1920x1080),
            (720, AVAssetExportPreset1280x720),
            (480, AVAssetExportPreset960x540),
            (360, AVAssetExportPreset640x480),
        ]
        let cap = quality.maxHeight ?? Int.max
        if let pick = ladder.first(where: { $0.0 <= cap && compatible.contains($0.1) }) {
            return pick.1
        }
        // Everything on offer is above the cap — take the smallest, mirroring
        // `VideoQuality.pick`'s degrade-don't-fail rule.
        if let smallest = ladder.last(where: { compatible.contains($0.1) }) {
            appLog("No HLS export preset at or below \(cap)p — using \(smallest.1).",
                   level: .warning, category: category)
            return smallest.1
        }
        guard compatible.contains(AVAssetExportPresetHighestQuality) else {
            throw ExtractorError.downloadFailed("AVFoundation can't export this HLS stream as video.")
        }
        return AVAssetExportPresetHighestQuality
    }
}
