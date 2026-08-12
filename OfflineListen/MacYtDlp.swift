#if os(macOS)

import Foundation

/// yt-dlp on the Mac, as a subprocess.
///
/// iOS can't spawn processes, so the app embeds a Python interpreter and drives
/// yt-dlp as a module (`PythonBridge`, `YoutubeDLExtractor`). That whole stack is
/// unavailable here — the `Python-iOS` and `FFmpeg-iOS-Lame` xcframeworks ship no
/// macOS slice, so the package isn't linked into this build at all and every
/// `canImport(YoutubeDL)` branch compiles out.
///
/// The Mac doesn't need any of it: it can just run the real `yt-dlp`. That's
/// simpler *and* better — a standalone binary is self-contained, updates
/// independently of the app, and does its own signature and PO-token work
/// without the JavaScriptCore/WKWebView bridge iOS needs.
///
/// **Where the binary comes from.** Three places, newest-wins in spirit:
///
///  1. **An updated copy** in Application Support, fetched by `update()` — the
///     "Refresh yt-dlp engine" action, and the same thing the iOS build does
///     when it re-downloads its Python module.
///  2. **Homebrew or a system install** (`/opt/homebrew/bin`, `/usr/local/bin`,
///     `/usr/bin`), so a machine that already maintains a yt-dlp uses that one.
///  3. **The copy bundled in the app** at `Contents/Helpers/yt-dlp`, put there by
///     the `Embed yt-dlp (macOS)` build phase (`tools/embed-ytdlp.sh`). This is
///     the floor: a fresh install can download from every site yt-dlp supports
///     without anyone setting anything up.
///
/// The order matters because yt-dlp chases a moving target — YouTube changes its
/// player and yesterday's build stops resolving — and the bundled copy only
/// moves when the app is rebuilt. 1 and 2 are both routes to something newer.
///
/// This target is **not sandboxed**, which is what makes 1 and 2 possible at all:
/// App Sandbox refuses to execute a binary its signature doesn't cover, so under
/// it a downloaded or Homebrew yt-dlp reads back `exists=true, executable=false`,
/// and even the bundled one dies on startup (the single-file build opens a POSIX
/// named semaphore, which the sandbox only allows under an app-group prefix).
///
/// Everything here is best-effort: if nothing is found or it won't run,
/// `isAvailable` is false, the extractor throws `.packageUnavailable`, and
/// downloads fall back to the native Swift extractors exactly as they do when
/// yt-dlp is missing on iOS.
@MainActor
enum MacYtDlp {
    static let category = "yt-dlp"

    /// The copy `update()` maintains, and the first place `resolve()` looks.
    static var updatedURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base
            .appendingPathComponent("OfflineListen", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("yt-dlp")
    }

    /// The copy that ships inside the app. `Contents/Helpers` rather than
    /// `Contents/MacOS` so it's unmistakably an auxiliary executable.
    static var bundledURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent("yt-dlp")
    }

    private static let systemPaths = [
        "/opt/homebrew/bin/yt-dlp",
        "/usr/local/bin/yt-dlp",
        "/usr/bin/yt-dlp",
    ]

    /// Memoized result of `resolve()`.
    private static var cached: URL??

    // MARK: - Locating

    /// The executable to run, or nil when there isn't one.
    static func resolve() -> URL? {
        if let cached { return cached }
        let found = locate()
        cached = .some(found)
        return found
    }

    /// Forgets the memoized location — after `update()` puts a new copy down.
    static func refresh() {
        cached = nil
        _ = resolve()
    }

    static var isAvailable: Bool { resolve() != nil }

    /// Which of the three sources the resolved binary came from, for the log and
    /// the Settings row.
    static func sourceDescription(of url: URL) -> String {
        if url == updatedURL { return "updated copy" }
        if url == bundledURL { return "bundled with the app" }
        return "installed at \(url.path)"
    }

    private static func locate() -> URL? {
        if isExecutable(updatedURL) { return updatedURL }
        for path in systemPaths {
            let url = URL(fileURLWithPath: path)
            if isExecutable(url) { return url }
        }
        if isExecutable(bundledURL) { return bundledURL }
        appLog("No yt-dlp anywhere — not in Application Support, not on the system, and none bundled at \(bundledURL.path).",
               level: .warning, category: category)
        return nil
    }

    private static func isExecutable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }

    // MARK: - Updating

    /// The official standalone build — one self-contained executable, so the
    /// machine needs no Python of its own.
    private static let releaseURL = URL(string:
        "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!

    /// Downloads the current yt-dlp release into Application Support, where it
    /// takes precedence over both the system and bundled copies. This is the Mac
    /// half of "Refresh yt-dlp engine" — the thing to reach for when YouTube
    /// changes its player and downloads start failing.
    static func update() async throws {
        appLog("Downloading the latest yt-dlp…", category: category)
        let (temp, response) = try await URLSession.shared.download(from: releaseURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MacYtDlpError.updateFailed("The download server answered HTTP \(http.statusCode).")
        }

        let fileManager = FileManager.default
        let destination = updatedURL
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temp, to: destination)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)

        refresh()
        guard let version = await version() else {
            throw MacYtDlpError.updateFailed("The file downloaded but wouldn't run.")
        }
        appLog("yt-dlp updated to \(version).", level: .success, category: category)
    }

    /// Records at launch whether there's a yt-dlp to fall back to. "Downloads
    /// from this site don't work" is otherwise a puzzle whose answer lives in a
    /// Settings section the user hasn't visited.
    ///
    /// It asks the binary for its version rather than just noting that a file is
    /// there, because those are different questions — a yt-dlp can be perfectly
    /// present and still refuse to run. A version in the log means it really
    /// executed.
    static func logStartupState() async {
        guard let url = resolve() else {
            appLog("No yt-dlp found — only the built-in extractors are available.",
                   level: .warning, category: category)
            return
        }
        let ffmpegNote = hasFFmpeg ? "with ffmpeg"
            : "no ffmpeg — video is limited to already-muxed streams"
        do {
            let output = try await run(arguments: ["--version"])
            let version = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard output.status == 0, !version.isEmpty else {
                appLog("yt-dlp at \(url.path) wouldn't run (status \(output.status)). stdout: \(version.isEmpty ? "<empty>" : version) · stderr: \(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))",
                       level: .warning, category: category)
                return
            }
            appLog("yt-dlp \(version) ready — \(sourceDescription(of: url)), \(ffmpegNote).",
                   level: .success, category: category)
        } catch {
            appLog("yt-dlp at \(url.path) wouldn't run: \(error.localizedDescription)",
                   level: .warning, category: category)
        }
    }

    /// The bundled helper's version, for the Settings row. Nil while it's still
    /// being asked, or when there's nothing to ask.
    static func version() async -> String? {
        guard isAvailable else { return nil }
        guard let output = try? await run(arguments: ["--version"]), output.status == 0 else {
            return nil
        }
        let version = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }

    // MARK: - ffmpeg

    /// Whether an `ffmpeg` is reachable. yt-dlp needs one to join a separate
    /// video and audio stream; without it the video path is restricted to
    /// already-muxed (progressive) formats, which caps resolution but always
    /// produces a playable file.
    ///
    /// Nothing bundles one, so this is whatever the machine has — `brew install
    /// ffmpeg` is the fix when the note about muxed-only video shows up.
    static var hasFFmpeg: Bool { ffmpegURL() != nil }

    static func ffmpegURL() -> URL? {
        let bundled = bundledURL.deletingLastPathComponent().appendingPathComponent("ffmpeg")
        if isExecutable(bundled) { return bundled }
        for path in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"] {
            let url = URL(fileURLWithPath: path)
            if isExecutable(url) { return url }
        }
        return nil
    }

    // MARK: - Running

    struct Output: Sendable {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    /// Runs yt-dlp to completion and collects its output.
    ///
    /// `onLine` sees each line of stdout as it arrives, which is what drives
    /// download progress. Reading both pipes concurrently is not optional: a
    /// child that fills the 64 KB pipe buffer while the parent waits on exit
    /// deadlocks, and yt-dlp is chatty enough to do exactly that.
    @discardableResult
    static func run(arguments: [String],
                    onLine: (@Sendable (String) -> Void)? = nil) async throws -> Output {
        guard let executable = resolve() else { throw MacYtDlpError.notInstalled }
        return try await Self.execute(executable, arguments: arguments, onLine: onLine)
    }

    /// Off the main actor: `Process` blocks, and the pipe pumps have to run
    /// while it does.
    private nonisolated static func execute(_ executable: URL,
                                            arguments: [String],
                                            onLine: (@Sendable (String) -> Void)?) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let collected = Collected()
                    let group = DispatchGroup()

                    for (pipe, isStdout) in [(outPipe, true), (errPipe, false)] {
                        group.enter()
                        DispatchQueue.global(qos: .userInitiated).async {
                            defer { group.leave() }
                            var pending = ""
                            while true {
                                let chunk = pipe.fileHandleForReading.availableData
                                if chunk.isEmpty { break }
                                let text = String(decoding: chunk, as: UTF8.self)
                                guard isStdout else {
                                    collected.appendErr(text)
                                    continue
                                }
                                collected.appendOut(text)
                                guard let onLine else { continue }
                                // yt-dlp redraws progress with \r; treat it as a
                                // line break so every update is seen.
                                pending += text
                                let parts = pending.split(omittingEmptySubsequences: false,
                                                          whereSeparator: { $0 == "\n" || $0 == "\r" })
                                pending = String(parts.last ?? "")
                                for line in parts.dropLast() where !line.isEmpty {
                                    onLine(String(line))
                                }
                            }
                        }
                    }

                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    process.waitUntilExit()
                    group.wait()
                    continuation.resume(returning: Output(stdout: collected.out,
                                                          stderr: collected.err,
                                                          status: process.terminationStatus))
                }
            }
        } onCancel: {
            process.terminate()
        }
    }

    /// Somewhere for the two reader queues to accumulate into.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var outBuffer = "", errBuffer = ""

        func appendOut(_ text: String) { lock.lock(); outBuffer += text; lock.unlock() }
        func appendErr(_ text: String) { lock.lock(); errBuffer += text; lock.unlock() }
        var out: String { lock.lock(); defer { lock.unlock() }; return outBuffer }
        var err: String { lock.lock(); defer { lock.unlock() }; return errBuffer }
    }

    /// The arguments every invocation carries. `--no-config` matters: the user's
    /// own `~/.config/yt-dlp` could otherwise set an output template or format
    /// that breaks the app's assumptions about where the file lands.
    static var baseArguments: [String] {
        var arguments = ["--no-config", "--no-playlist", "--no-warnings", "--no-colors"]
        if let ffmpeg = ffmpegURL() {
            arguments += ["--ffmpeg-location", ffmpeg.deletingLastPathComponent().path]
        }
        return arguments
    }
}

enum MacYtDlpError: LocalizedError {
    case notInstalled
    case updateFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "No yt-dlp is available, so only the built-in extractors can be used."
        case .updateFailed(let reason):
            return "Couldn't update yt-dlp. \(reason)"
        }
    }
}

// MARK: - The extractor

/// `MediaExtractor` on top of the yt-dlp subprocess — the Mac's stand-in for
/// `YoutubeDLExtractor`, sitting last behind the native Swift extractors in
/// exactly the same way.
final class MacYtDlpExtractor: MediaExtractor {
    func extractMedia(from url: URL,
                      mode: DownloadMode,
                      quality: VideoQuality,
                      onDownloadStart: @escaping () -> Void,
                      onProgress: @escaping (Double) -> Void) async throws -> ExtractedMedia {
        guard await MacYtDlp.isAvailable else { throw ExtractorError.packageUnavailable }
        let category = MacYtDlp.category

        appLog("Resolving \(url.absoluteString)", category: category)
        let info = try await Self.info(for: url)
        appLog("Info: \"\(info.title)\" · \(Int(info.duration))s", level: .success, category: category)

        // Downloads land in a fresh directory so the finished file can be found
        // by looking rather than by predicting what yt-dlp will name it — the
        // extension depends on which format won, which isn't known up front.
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        let isVideo = mode == .video
        var arguments = await MacYtDlp.baseArguments
        arguments += ["--newline", "--progress"]
        arguments += ["-f", await Self.formatSelector(mode: mode, quality: quality)]
        arguments += ["-o", workingDirectory.appendingPathComponent("media.%(ext)s").path]
        arguments.append(url.absoluteString)

        onDownloadStart()
        appLog("Downloading \(isVideo ? "video" : "audio")…", category: category)

        let output = try await MacYtDlp.run(arguments: arguments) { line in
            guard let fraction = Self.progressFraction(in: line) else { return }
            onProgress(fraction)
        }

        guard output.status == 0 else {
            try? FileManager.default.removeItem(at: workingDirectory)
            throw ExtractorError.downloadFailed(Self.message(from: output))
        }

        let produced = (try? FileManager.default.contentsOfDirectory(
            at: workingDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        // yt-dlp leaves `.part` files behind on an aborted fetch; whatever's
        // left that isn't one is the download.
        guard let file = produced.first(where: { $0.pathExtension != "part" }) else {
            try? FileManager.default.removeItem(at: workingDirectory)
            throw ExtractorError.downloadFailed(Self.message(from: output))
        }

        let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        appLog("Download finished: \(file.lastPathComponent) (\(bytes / 1024) KB)",
               level: .success, category: category)

        return ExtractedMedia(fileURL: file,
                              title: info.title,
                              duration: info.duration,
                              isVideo: isVideo,
                              chapters: info.chapters)
    }

    /// The format to ask for.
    ///
    /// Audio prefers m4a because AVFoundation plays it and Opus-in-WebM — which
    /// is what "best audio" means on YouTube — it does not. Video prefers H.264
    /// in MP4 for the same reason, and only asks yt-dlp to *join* separate video
    /// and audio streams when there's an ffmpeg to do the joining; without one it
    /// takes an already-muxed stream, which caps resolution but always plays.
    static func formatSelector(mode: DownloadMode, quality: VideoQuality) async -> String {
        guard mode == .video else {
            return "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]/best[ext=mp4]/best"
        }
        let cap = quality.maxHeight.map { "[height<=\($0)]" } ?? ""
        let progressive = "best[ext=mp4][vcodec^=avc1]\(cap)/best[ext=mp4]\(cap)/best\(cap)"
        guard await MacYtDlp.hasFFmpeg else { return progressive }
        return "bestvideo[ext=mp4][vcodec^=avc1]\(cap)+bestaudio[ext=m4a]/\(progressive)"
    }

    /// `[download]  34.5% of ...` → 0.345.
    static func progressFraction(in line: String) -> Double? {
        guard line.hasPrefix("[download]"), let percent = line.firstIndex(of: "%") else { return nil }
        let head = line[line.startIndex..<percent]
        guard let lastSpace = head.lastIndex(of: " ") else { return nil }
        guard let value = Double(head[head.index(after: lastSpace)...]) else { return nil }
        return min(1, max(0, value / 100))
    }

    /// The most useful line of a failure. yt-dlp puts the real reason on an
    /// `ERROR:` line in stderr; everything else is noise.
    static func message(from output: MacYtDlp.Output) -> String {
        if let errorLine = output.stderr.split(separator: "\n").first(where: { $0.hasPrefix("ERROR:") }) {
            return String(errorLine.dropFirst("ERROR:".count)).trimmingCharacters(in: .whitespaces)
        }
        if let last = output.stderr.split(separator: "\n").last {
            return String(last)
        }
        return "yt-dlp exited with status \(output.status)."
    }

    // MARK: Metadata

    struct Info {
        let title: String
        let duration: Double
        let chapters: [Chapter]
    }

    /// One metadata-only pass (`-J`): no download, just the JSON.
    static func info(for url: URL) async throws -> Info {
        var arguments = await MacYtDlp.baseArguments
        arguments += ["-J", url.absoluteString]
        let output = try await MacYtDlp.run(arguments: arguments)
        guard output.status == 0, let data = output.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExtractorError.downloadFailed(message(from: output))
        }
        return Info(title: json["title"] as? String ?? url.lastPathComponent,
                    duration: json["duration"] as? Double ?? 0,
                    chapters: chapters(from: json))
    }

    static func chapters(from json: [String: Any]) -> [Chapter] {
        guard let raw = json["chapters"] as? [[String: Any]] else { return [] }
        return raw.compactMap { entry in
            guard let start = entry["start_time"] as? Double,
                  let end = entry["end_time"] as? Double else { return nil }
            return Chapter(title: entry["title"] as? String ?? "Chapter", start: start, end: end)
        }
    }
}

// MARK: - Chapters and playlists

extension MacYtDlp {
    /// Chapter markers for a URL, best-effort — the Mac's answer to
    /// `ChapterFetcher`, which needs the embedded interpreter this build hasn't
    /// got.
    static func chapters(for url: URL) async -> [Chapter] {
        guard isAvailable else { return [] }
        do {
            return try await MacYtDlpExtractor.info(for: url).chapters
        } catch {
            appLog("Couldn't read chapters: \(error.localizedDescription)",
                   level: .debug, category: category)
            return []
        }
    }

    /// The English caption URL for a video, best-effort — the Mac's answer to
    /// the embedded-Python half of `SubtitleFetcher`. Manual subtitles are
    /// preferred over the automatic transcript, and a format the parser reads
    /// over one it has to sniff.
    static func englishSubtitleURL(for url: URL) async -> String? {
        guard isAvailable else { return nil }
        do {
            var arguments = baseArguments
            arguments += ["-J", url.absoluteString]
            let output = try await run(arguments: arguments)
            guard output.status == 0, let data = output.stdout.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            for key in ["subtitles", "automatic_captions"] {
                guard let table = json[key] as? [String: Any] else { continue }
                var formats: [[String: Any]] = []
                for (code, value) in table where SubtitleFetcher.isEnglish(code) {
                    if let list = value as? [[String: Any]] { formats += list }
                }
                for wanted in ["vtt", "srt"] {
                    if let hit = formats.first(where: { ($0["ext"] as? String) == wanted }),
                       let link = hit["url"] as? String {
                        return link
                    }
                }
                if let link = formats.first?["url"] as? String { return link }
            }
            return nil
        } catch {
            appLog("Couldn't read subtitles: \(error.localizedDescription)",
                   level: .debug, category: SubtitleFetcher.category)
            return nil
        }
    }

    /// A playlist's entries via a flat extraction — the entries listed without
    /// resolving each video's streams, matching what `PlaylistResolver` does
    /// with the Python module on iOS. Nil means "treat the link as a single
    /// download", which is what every caller falls back to.
    static func playlist(for url: URL) async -> ResolvedPlaylist? {
        guard isAvailable else { return nil }
        // `--no-playlist` lives in the base arguments and would defeat the whole
        // point here, so this call builds its own.
        let arguments = ["--no-config", "--no-warnings", "--no-colors",
                         "--flat-playlist", "--yes-playlist", "-J",
                         url.absoluteString]
        do {
            let output = try await run(arguments: arguments)
            guard output.status == 0, let data = output.stdout.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawEntries = json["entries"] as? [[String: Any]] else {
                appLog("Couldn't resolve the playlist: \(MacYtDlpExtractor.message(from: output))",
                       level: .warning, category: "Playlist")
                return nil
            }
            let entries: [PlaylistEntry] = rawEntries.enumerated().compactMap { index, entry in
                guard let link = (entry["url"] as? String) ?? (entry["webpage_url"] as? String) else {
                    return nil
                }
                return PlaylistEntry(title: entry["title"] as? String ?? "Track \(index + 1)", url: link)
            }
            guard !entries.isEmpty else { return nil }
            let title = json["title"] as? String ?? "Playlist"
            appLog("Playlist \"\(title)\" resolved: \(entries.count) entries.",
                   level: .success, category: "Playlist")
            return ResolvedPlaylist(title: title, entries: entries)
        } catch {
            appLog("Couldn't resolve the playlist: \(error.localizedDescription)",
                   level: .warning, category: "Playlist")
            return nil
        }
    }
}

#endif
