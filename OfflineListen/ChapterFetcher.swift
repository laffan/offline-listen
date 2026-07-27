import Foundation

#if canImport(YoutubeDL)
import YoutubeDL
#endif

#if canImport(PythonKit)
import PythonKit
#endif

/// Best-effort capture of a video's chapter markers via the on-device yt-dlp
/// (Python) module. Chapters aren't part of the stream URLs the extractors
/// resolve, so we read them from yt-dlp's metadata with a fast, metadata-only
/// `extract_info(download: false, process: false)` — no format processing, no
/// nsig descrambling.
///
/// Deliberately conservative: it only runs when the yt-dlp Python module is
/// **already present** (a previous yt-dlp download fetched it), so capturing
/// chapters never triggers the tens-of-MB module download on its own. When the
/// module isn't there — or PythonKit/YoutubeDL aren't linked — it simply returns
/// no chapters and the rest of the app behaves exactly as before.
enum ChapterFetcher {
    static func fetch(url: URL) async -> [Chapter] {
        #if canImport(YoutubeDL) && canImport(PythonKit)
        let category = "Chapters"
        guard FileManager.default.fileExists(atPath: YoutubeDL.pythonModuleURL.path) else {
            appLog("yt-dlp module not present — skipping chapter lookup.", level: .debug, category: category)
            return []
        }
        do {
            // The whole Python section — instantiation, extract_info, and the
            // chapters parse — runs under the app-wide gate so it can't overlap
            // another pipeline slot's interpreter work.
            let chapters = try await PythonGate.shared.run { () throws -> [Chapter] in
                // Instantiating YoutubeDL configures PythonKit's module search path so
                // `import yt_dlp` resolves even when this download went through the
                // native extractor.
                _ = YoutubeDL()
                let ytdlpModule = Python.import("yt_dlp")
                let options: PythonObject = [
                    "quiet": true,
                    "noplaylist": true,
                    "skip_download": true,
                    "nocheckcertificate": true,
                ]
                let ytdlp = ytdlpModule.YoutubeDL(options)
                let info = try ytdlp.extract_info.throwing.dynamicallyCall(withKeywordArguments: [
                    "": url.absoluteString, "download": false, "process": false,
                ])
                return parseChapters(from: info)
            }
            if !chapters.isEmpty {
                appLog("Captured \(chapters.count) chapter marker(s).", level: .success, category: category)
            }
            return chapters
        } catch {
            appLog("Chapter lookup failed (non-fatal): \(error.localizedDescription)",
                   level: .debug, category: category)
            return []
        }
        #else
        return []
        #endif
    }

    #if canImport(PythonKit)
    /// Parses yt-dlp's `chapters` list (`[{title, start_time, end_time}]`) into
    /// our model. Every read uses `.get(...)` so a missing key yields Python
    /// `None` rather than trapping. Drops entries without a usable start time.
    static func parseChapters(from info: PythonObject) -> [Chapter] {
        let chaptersObj = info.get("chapters")
        if chaptersObj == Python.None { return [] }
        var result: [Chapter] = []
        for (offset, item) in chaptersObj.enumerated() {
            guard let start = Double(item.get("start_time")) else { continue }
            let end = Double(item.get("end_time")) ?? 0
            let rawTitle = String(item.get("title")) ?? ""
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(Chapter(title: title.isEmpty ? "Chapter \(offset + 1)" : title,
                                  start: start, end: end))
        }
        return result.sorted { $0.start < $1.start }
    }
    #endif
}
