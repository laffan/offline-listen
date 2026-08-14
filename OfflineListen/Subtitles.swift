import Foundation
import SwiftUI

#if canImport(YoutubeDL)
import YoutubeDL
#endif

#if canImport(PythonKit)
import PythonKit
#endif

// MARK: - Model

/// One subtitle line: when it comes up, when it goes, and what it says.
/// `text` may hold more than one line (a two-line caption), already stripped of
/// the markup WebVTT allows.
struct SubtitleCue: Codable, Hashable {
    let start: Double
    let end: Double
    let text: String
}

extension Array where Element == SubtitleCue {
    /// The cue covering `time`, or nil in the gap between two of them. Cues are
    /// kept sorted by start, so this is a binary search — it runs several times
    /// a second while a video plays.
    ///
    /// The search finds the **last cue that has started**, then walks back over
    /// any that have already ended. The walk is what makes it right on a file
    /// whose cues *overlap* — a long line (a song lyric, a scene caption) with
    /// short ones inside it, which real subtitle files for films carry and
    /// which YouTube's rolling auto-captions produce by construction. Overlap
    /// means the cues aren't a clean partition of the timeline, and a plain
    /// "is the time inside this one?" search lands in a hole and answers
    /// nothing for stretches where a caption should be on screen. Bounded, so
    /// a gap between cues still costs a fixed handful of comparisons.
    func cue(at time: Double) -> SubtitleCue? {
        guard !isEmpty else { return nil }
        var low = 0
        var high = count - 1
        var started = -1
        while low <= high {
            let mid = (low + high) / 2
            if self[mid].start <= time {
                started = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard started >= 0 else { return nil }
        var index = started
        var steps = 0
        while index >= 0, steps < 16 {
            if time < self[index].end { return self[index] }
            index -= 1
            steps += 1
        }
        return nil
    }
}

// MARK: - Parsing

/// Reads the three caption formats the fetchers can come back with — **WebVTT**
/// and **SRT** (near-identical: SRT numbers its cues and writes its decimals
/// with a comma) and YouTube's own **timedtext XML** — into plain cues.
///
/// Auto-generated captions need the extra cleanup at the bottom: YouTube writes
/// them as *rolling* text, where each cue repeats the previous line and adds a
/// few words, with a hair-thin cue in between carrying the finished line. Left
/// alone that reads as every line being shown twice.
enum SubtitleParser {
    static func parse(_ raw: String) -> [SubtitleCue] {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var cues: [SubtitleCue] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            guard let arrow = line.range(of: "-->"),
                  let start = seconds(from: String(line[line.startIndex..<arrow.lowerBound])),
                  let end = seconds(from: String(line[arrow.upperBound...])) else { continue }

            var body: [String] = []
            while index < lines.count {
                let next = lines[index]
                if next.trimmingCharacters(in: .whitespaces).isEmpty || next.contains("-->") { break }
                body.append(clean(next))
                index += 1
            }
            append(&cues, start: start, end: end, lines: body)
        }
        return tidied(cues)
    }

    /// YouTube's `timedtext` XML (`<text start="1.2" dur="3.4">…`), which is
    /// what the caption endpoint serves when `fmt=vtt` isn't honoured.
    static func parseTimedText(_ data: Data) -> [SubtitleCue] {
        guard let xml = String(data: data, encoding: .utf8), xml.contains("<text") else { return [] }
        let pattern = #"<text start="([0-9.]+)"(?:\s+dur="([0-9.]+)")?[^>]*>([\s\S]*?)</text>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var cues: [SubtitleCue] = []
        let range = NSRange(xml.startIndex..., in: xml)
        regex.enumerateMatches(in: xml, range: range) { match, _, _ in
            guard let match,
                  let startRange = Range(match.range(at: 1), in: xml),
                  let bodyRange = Range(match.range(at: 3), in: xml),
                  let start = Double(xml[startRange]) else { return }
            let duration = Range(match.range(at: 2), in: xml).flatMap { Double(xml[$0]) } ?? 3
            let text = clean(String(xml[bodyRange]).replacingOccurrences(of: "\n", with: " "))
            append(&cues, start: start, end: start + duration, lines: [text])
        }
        return tidied(cues)
    }

    private static func append(_ cues: inout [SubtitleCue], start: Double, end: Double, lines: [String]) {
        // A line that was nothing but markup cleans down to nothing, and a
        // blank line inside a caption is just a gap in the plate.
        let text = lines.filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, end > start else { return }
        cues.append(SubtitleCue(start: start, end: end, text: text))
    }

    /// "01:02:03.456", "02:03.456" or the SRT comma form, in seconds.
    private static func seconds(from field: String) -> Double? {
        let trimmed = field.trimmingCharacters(in: .whitespaces)
            .split(separator: " ").first.map(String.init) ?? ""
        let stamp = trimmed.replacingOccurrences(of: ",", with: ".")
        let parts = stamp.split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count) else { return nil }
        var total: Double = 0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// Strips WebVTT's inline markup (`<c>`, `<00:00:01.000>`, `<v Name>`) and
    /// the handful of entities captions actually carry.
    private static func clean(_ line: String) -> String {
        var text = line.replacingOccurrences(of: "<[^>]*>", with: "",
                                             options: .regularExpression)
        for (entity, character) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                                    ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                                    ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Sorts, then unrolls YouTube's rolling auto-captions: the sliver cues
    /// (a hundredth of a second) go, a cue that opens with the line already on
    /// screen loses that line, and an exact repeat is dropped outright.
    private static func tidied(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        var result: [SubtitleCue] = []
        for cue in cues.sorted(by: { $0.start < $1.start }) {
            guard cue.end - cue.start >= 0.1 else { continue }
            var lines = cue.text.components(separatedBy: "\n")
            if let previous = result.last?.text.components(separatedBy: "\n").last {
                while let first = lines.first, first == previous, lines.count > 1 {
                    lines.removeFirst()
                }
            }
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text != result.last?.text else { continue }
            result.append(SubtitleCue(start: cue.start, end: cue.end, text: text))
        }
        return result
    }

    /// The cues as a WebVTT file — what actually goes on disk, so a captured
    /// track is a standard `.vtt` anything else can read.
    static func vtt(from cues: [SubtitleCue]) -> String {
        var out = "WEBVTT\n\n"
        for cue in cues {
            out += "\(stamp(cue.start)) --> \(stamp(cue.end))\n\(cue.text)\n\n"
        }
        return out
    }

    private static func stamp(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        let secs = Int(total) % 60
        let millis = Int((total - total.rounded(.down)) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, secs, millis)
    }
}

// MARK: - Loading

/// Reads a track's saved `.vtt` off disk, memoized by file name — the player
/// asks for the current cue several times a second, and a caption file is
/// parsed once per track rather than once per tick.
@MainActor
enum SubtitleStore {
    private static var cache: [String: [SubtitleCue]] = [:]
    private static let cacheLimit = 8

    static func cues(for track: Track) -> [SubtitleCue] {
        guard let name = track.subtitleFileName else { return [] }
        if let hit = cache[name] { return hit }
        guard let raw = try? String(contentsOf: AppPaths.subtitles.appendingPathComponent(name),
                                    encoding: .utf8) else {
            // The track points at a caption file that isn't there — worth
            // saying, since from the player it looks exactly like a video that
            // never had any.
            appLog("Subtitle file \(name) is recorded on \"\(track.title)\" but couldn't be read.",
                   level: .warning, category: SubtitleFetcher.category)
            cache[name] = []
            return []
        }
        let cues = SubtitleParser.parse(raw)
        if cues.isEmpty {
            appLog("Subtitle file \(name) parsed to no cues (\(raw.count) characters read).",
                   level: .warning, category: SubtitleFetcher.category)
        }
        if cache.count >= cacheLimit { cache.removeAll() }
        cache[name] = cues
        return cues
    }

    static func invalidate(fileName: String) {
        cache[fileName] = nil
    }
}

// MARK: - Appearance

/// How captions are drawn, and whether they're drawn at all. Plain
/// `UserDefaults` keys so Settings and the player can each read them with
/// `@AppStorage` and stay in step without a store of their own.
enum SubtitleSettings {
    static let enabledKey = "subtitlesEnabled"
    static let sizeKey = "subtitleTextSize"
    static let colorKey = "subtitleTextColorHex"
    static let backdropKey = "subtitleBackdrop"

    static let defaultColorHex = "#FFFFFF"

    /// The colour swatches the settings row offers — white, the classic
    /// broadcast yellow, and two that stay legible over a bright picture.
    static let swatches = ["#FFFFFF", "#FFE44D", "#7FE7FF", "#B7FF8A"]
}

/// Caption text size, as a multiplier on the base 18-point line.
enum SubtitleTextSize: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    /// Shifted up a rung after living with them on a phone: what read as
    /// Medium is the sensible floor, so it became Small, and Large is now
    /// genuinely large rather than merely bigger.
    var points: CGFloat {
        switch self {
        case .small: return 19
        case .medium: return 24
        case .large: return 31
        }
    }
}

/// What sits behind the text. Captions over a bright shot are unreadable
/// without something, and a solid plate over a dark one is heavier than it
/// needs to be — so the middle option (a shadowed, translucent plate) is the
/// default.
enum SubtitleBackdrop: String, CaseIterable, Identifiable {
    case none, dim, solid

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .none: return "None"
        case .dim: return "Dim"
        case .solid: return "Solid"
        }
    }

    var opacity: Double {
        switch self {
        case .none: return 0
        case .dim: return 0.55
        case .solid: return 0.85
        }
    }
}

// MARK: - Capture

/// Best-effort capture of a video's **English** subtitles, saved beside the
/// track as WebVTT.
///
/// Two routes, in order. YouTube publishes its caption tracks in the watch
/// page's player response, which is a plain HTTPS read and needs nothing
/// installed — that's the fast path and covers the overwhelming majority of
/// downloads. Anything else (and a YouTube page that won't give them up) falls
/// to **yt-dlp's** metadata, exactly as `ChapterFetcher` does: only when the
/// Python module is already present, so capturing subtitles never triggers the
/// tens-of-MB module download on its own.
///
/// Failure is never fatal and never logged as an error — a video with no
/// captions is the ordinary case, and the track simply plays without them.
enum SubtitleFetcher {
    static let category = "Subtitles"

    /// Captures subtitles for a finished **video** download and records the
    /// file on the track. Audio downloads skip it — there's nothing to draw
    /// captions over.
    /// `requested` marks the on-demand path (the library's **Get Subtitles**),
    /// where a miss is news — the automatic one keeps quiet about a video that
    /// simply has no captions, which is most of them.
    static func attach(from url: URL, to trackID: UUID, isVideo: Bool,
                       library: LibraryStore, requested: Bool = false) {
        guard isVideo else { return }
        Task {
            guard let cues = await fetch(url: url), !cues.isEmpty else {
                appLog("No English captions on offer for \(url.absoluteString).",
                       level: requested ? .warning : .debug, category: category)
                return
            }
            let fileName = "\(trackID.uuidString).vtt"
            let destination = AppPaths.subtitles.appendingPathComponent(fileName)
            do {
                try SubtitleParser.vtt(from: cues).write(to: destination, atomically: true, encoding: .utf8)
            } catch {
                appLog("Couldn't save the subtitles: \(error.localizedDescription)",
                       level: .warning, category: category)
                return
            }
            await MainActor.run {
                SubtitleStore.invalidate(fileName: fileName)
                library.setSubtitles(for: trackID, fileName: fileName)
            }
            appLog("Captured \(cues.count) English subtitle cue(s).", level: .success, category: category)
        }
    }

    /// The cues for a URL, or nil when nothing English is on offer. Which of
    /// the two routes answered is logged: they fail for quite different
    /// reasons, and "no captions" from one is not the same news as from both.
    static func fetch(url: URL) async -> [SubtitleCue]? {
        if let cues = await fromYouTubePage(url), !cues.isEmpty {
            appLog("Captions read from the watch page: \(cues.count) cue(s).",
                   level: .debug, category: category)
            return cues
        }
        guard let link = await ytDlpSubtitleURL(for: url) else { return nil }
        let cues = await download(link)
        appLog("Captions via yt-dlp's caption list: \(cues?.count ?? 0) cue(s).",
               level: .debug, category: category)
        return cues
    }

    // MARK: The YouTube page

    /// Reads `captionTracks` out of the watch page's player response and takes
    /// the best English track: a human-written one where there is one, the
    /// auto-generated one otherwise.
    private static func fromYouTubePage(_ url: URL) async -> [SubtitleCue]? {
        guard let videoID = YouTubeKitExtractor.videoID(from: url),
              let page = URL(string: BrowseHTTP.watchURL(forVideoID: videoID)) else { return nil }
        guard let data = try? await BrowseHTTP.get(page),
              let html = String(data: data, encoding: .utf8),
              let tracks = captionTracks(in: html),
              let chosen = pickEnglish(tracks),
              let base = chosen["baseUrl"] as? String else { return nil }
        // The endpoint speaks WebVTT when asked; without the parameter it
        // answers its own XML, which the parser also reads.
        let link = base.contains("fmt=") ? base : base + "&fmt=vtt"
        return await download(link)
    }

    /// The `"captionTracks":[ … ]` array, sliced out of the page by bracket
    /// matching and decoded as ordinary JSON (it is — it's embedded in a script
    /// tag, not escaped into a string).
    private static func captionTracks(in html: String) -> [[String: Any]]? {
        guard let marker = html.range(of: "\"captionTracks\":") else { return nil }
        guard let open = html[marker.upperBound...].firstIndex(of: "[") else { return nil }
        var depth = 0
        var end: String.Index?
        var index = open
        while index < html.endIndex {
            let character = html[index]
            if character == "[" { depth += 1 }
            if character == "]" {
                depth -= 1
                if depth == 0 { end = html.index(after: index); break }
            }
            index = html.index(after: index)
        }
        guard let end,
              let data = String(html[open..<end]).data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return array
    }

    private static func pickEnglish(_ tracks: [[String: Any]]) -> [String: Any]? {
        let english = tracks.filter { isEnglish(($0["languageCode"] as? String) ?? "") }
        // `kind == "asr"` marks the machine transcript; a real caption track
        // beats it every time.
        return english.first { ($0["kind"] as? String) != "asr" } ?? english.first
    }

    static func isEnglish(_ code: String) -> Bool {
        let lower = code.lowercased()
        return lower == "en" || lower.hasPrefix("en-") || lower.hasPrefix("en_")
    }

    private static func download(_ link: String) async -> [SubtitleCue]? {
        guard let url = URL(string: link), let data = try? await BrowseHTTP.get(url) else { return nil }
        if let text = String(data: data, encoding: .utf8),
           text.contains("-->") {
            let cues = SubtitleParser.parse(text)
            if !cues.isEmpty { return cues }
        }
        let cues = SubtitleParser.parseTimedText(data)
        return cues.isEmpty ? nil : cues
    }

    // MARK: yt-dlp's metadata

    /// The English caption URL yt-dlp lists for the video (manual subtitles
    /// first, automatic captions second), or nil when it can't be asked.
    private static func ytDlpSubtitleURL(for url: URL) async -> String? {
        #if os(macOS)
        return await MacYtDlp.englishSubtitleURL(for: url)
        #elseif canImport(YoutubeDL) && canImport(PythonKit)
        guard FileManager.default.fileExists(atPath: YoutubeDL.pythonModuleURL.path) else {
            appLog("yt-dlp module not present — skipping the subtitle lookup.",
                   level: .debug, category: category)
            return nil
        }
        do {
            // Same shape as `ChapterFetcher`: everything touching the
            // interpreter runs under the app-wide gate, and Python is started
            // first if a native extraction meant nothing has yet.
            return try await PythonGate.shared.run { () throws -> String? in
                guard PythonBridge.ensurePythonRunning() else { return nil }
                _ = YoutubeDL()
                let module = Python.import("yt_dlp")
                let options: PythonObject = [
                    "quiet": true,
                    "noplaylist": true,
                    "skip_download": true,
                    "nocheckcertificate": true,
                ]
                let ytdlp = module.YoutubeDL(options)
                let info = try ytdlp.extract_info.throwing.dynamicallyCall(withKeywordArguments: [
                    "": url.absoluteString, "download": false, "process": false,
                ])
                for key in ["subtitles", "automatic_captions"] {
                    let table = info.get(key)
                    if table == Python.None { continue }
                    if let link = englishLink(in: table) { return link }
                }
                return nil
            }
        } catch {
            appLog("Subtitle lookup failed (non-fatal): \(error.localizedDescription)",
                   level: .debug, category: category)
            return nil
        }
        #else
        return nil
        #endif
    }

    #if canImport(PythonKit)
    /// Picks an English entry out of yt-dlp's `{language: [{ext, url}, …]}`
    /// table, preferring a format the parser reads.
    private static func englishLink(in table: PythonObject) -> String? {
        var formats: [PythonObject] = []
        for key in table {
            guard let code = String(key), isEnglish(code) else { continue }
            let entries = table[key]
            if entries == Python.None { continue }
            for entry in entries { formats.append(entry) }
        }
        for wanted in ["vtt", "srt"] {
            for entry in formats where String(entry.get("ext")) == wanted {
                if let link = String(entry.get("url")) { return link }
            }
        }
        // Anything else is worth a try: the download path sniffs the payload
        // and falls back to the timedtext parser.
        for entry in formats {
            if let link = String(entry.get("url")) { return link }
        }
        return nil
    }
    #endif
}
