import Foundation
import AVFoundation

/// Combines a video stream with an audio stream into a single playable MP4 using
/// AVFoundation (no FFmpeg). YouTube increasingly serves video-only and
/// audio-only DASH streams separately, so for video downloads we fetch the best
/// of each and mux them here.
enum VideoMerger {
    /// Ensures `videoFile` has an audio track. If it already does (a progressive
    /// muxed download), it's returned unchanged. Otherwise the audio described by
    /// `audioRequest` is downloaded and muxed in. `audioRefresh`, when provided,
    /// lets the chunked download replace an expired/rejected audio URL and
    /// resume, the same way the main stream download does.
    static func ensureAudio(videoFile: URL,
                            audioRequest: URLRequest?,
                            audioRefresh: AudioStreamDownloader.RequestRefresher? = nil,
                            category: String) async throws -> URL {
        appLog("Checking downloaded video for an embedded audio track…", level: .debug, category: category)
        let videoAsset = AVURLAsset(url: videoFile)
        let existingAudio = (try? await withHeartbeat("Still inspecting video tracks", category: category) {
            try await videoAsset.loadTracks(withMediaType: .audio)
        }) ?? []
        if !existingAudio.isEmpty {
            appLog("Video already contains audio — no merge needed.", level: .debug, category: category)
            return videoFile
        }

        guard let audioRequest else {
            throw ExtractorError.downloadFailed("Video stream has no audio and no separate audio stream was found to merge.")
        }

        appLog("Video stream is video-only — downloading audio to merge…", category: category)
        let audioDest = AppPaths.work.appendingPathComponent("\(UUID().uuidString).m4a")
        try await AudioStreamDownloader.download(
            baseRequest: audioRequest,
            expectedSize: nil,
            to: audioDest,
            category: category,
            refresh: audioRefresh,
            onProgress: { _ in }
        )

        return try await merge(video: videoFile, audio: audioDest, category: category)
    }

    private static func merge(video: URL, audio: URL, category: String) async throws -> URL {
        appLog("Building merge composition…", level: .debug, category: category)
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)

        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw ExtractorError.downloadFailed("No video track found to merge.")
        }
        let videoDuration = try await videoAsset.load(.duration)

        if let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try compVideo.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: videoTrack, at: .zero)
        }

        if let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let audioDuration = try await audioAsset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: min(videoDuration, audioDuration))
            try compAudio.insertTimeRange(range, of: audioTrack, at: .zero)
        }

        let dest = AppPaths.work.appendingPathComponent("\(UUID().uuidString).mp4")
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ExtractorError.downloadFailed("Could not create the video merge session.")
        }
        export.outputURL = dest
        export.outputFileType = .mp4

        appLog("Muxing video + audio (passthrough export)…", category: category)
        try await withHeartbeat("Still muxing video + audio", category: category,
                                progress: { Double(export.progress) }) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                export.exportAsynchronously {
                    switch export.status {
                    case .completed:
                        continuation.resume()
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    default:
                        continuation.resume(throwing: ExtractorError.downloadFailed(export.error?.localizedDescription ?? "Video merge failed."))
                    }
                }
            }
        }

        try? FileManager.default.removeItem(at: video)
        try? FileManager.default.removeItem(at: audio)
        appLog("Merged video + audio → \(dest.lastPathComponent)", level: .success, category: category)
        return dest
    }
}
