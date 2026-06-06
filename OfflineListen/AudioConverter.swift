import Foundation

enum AudioConverterError: LocalizedError {
    case mp3EncoderUnavailable
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .mp3EncoderUnavailable:
            return "MP3 encoding isn't available in this build. Use M4A, or see the README to enable an MP3-capable FFmpeg."
        case .conversionFailed(let message):
            return message
        }
    }
}

/// Moves/transcodes a freshly downloaded audio file into the library in the
/// requested container.
///
/// DESIGN
/// ------
/// * **M4A (default):** yt-dlp already returns an AAC `.m4a` stream, so we simply
///   move it into Documents. No transcode, no dependency on FFmpeg encoders —
///   this is the reliable path that satisfies "download + play offline".
/// * **MP3:** real re-encoding, which needs an FFmpeg with an MP3 encoder
///   (libmp3lame / libshine). No FFmpeg is bundled, so this path is gated behind
///   the `USE_FFMPEG_MP3` compilation condition and off by default. See the
///   README for how to add an MP3-capable FFmpeg if you want MP3 output.
enum AudioConverter {
    static func process(input: URL,
                        to format: AudioFormat,
                        destinationName: String) throws -> URL {
        let destination = AppPaths.documents.appendingPathComponent(destinationName)
        try? FileManager.default.removeItem(at: destination)

        switch format {
        case .m4a:
            // Passthrough: the downloaded stream is already a playable m4a.
            appLog("Saving audio (m4a passthrough) → \(destinationName)", category: "Convert")
            try FileManager.default.moveItem(at: input, to: destination)
            appLog("Saved \(destination.lastPathComponent)", level: .success, category: "Convert")
            return destination

        case .mp3:
            appLog("Transcoding to MP3 → \(destinationName)", category: "Convert")
            let result = try transcodeToMP3(input: input, destination: destination)
            try? FileManager.default.removeItem(at: input)
            return result
        }
    }

    private static func transcodeToMP3(input: URL, destination: URL) throws -> URL {
        #if USE_FFMPEG_MP3
        // Expected to use a command-style FFmpeg wrapper, e.g.:
        //
        //   let session = FFmpegKit.execute("-y -i \"\(input.path)\" -vn -c:a libmp3lame -q:a 2 \"\(destination.path)\"")
        //   guard ReturnCode.isSuccess(session.getReturnCode()) else {
        //       throw AudioConverterError.conversionFailed(session.getOutput() ?? "ffmpeg failed")
        //   }
        //   return destination
        //
        // Fill this in once you've added an MP3-capable FFmpeg (see README) and
        // defined USE_FFMPEG_MP3 in the target's build settings.
        throw AudioConverterError.conversionFailed("USE_FFMPEG_MP3 is set but the transcode call is not implemented yet.")
        #else
        throw AudioConverterError.mp3EncoderUnavailable
        #endif
    }
}
