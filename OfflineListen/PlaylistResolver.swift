import Foundation

#if canImport(YoutubeDL)
import YoutubeDL
#endif

#if canImport(PythonKit)
import PythonKit
#endif

/// A playlist resolved into the individual entries we can download.
struct ResolvedPlaylist {
    /// The playlist's own title — used to name the folder its tracks land in.
    let title: String
    /// One downloadable URL per entry, in playlist order.
    let entryURLs: [String]
}

/// Decides whether a pasted link points at a playlist (so we should expand it
/// into a folder of downloads) rather than a single video.
///
/// Detection is deliberately URL-based and YouTube-scoped: it's cheap (no
/// network) and predictable. A real `list=` id triggers playlist mode for both
/// the dedicated `/playlist?list=…` page and a `watch?v=…&list=…` link opened
/// from within a playlist. Auto-generated **mixes/radios** (`RD…`) and the
/// auth-only **Watch Later** / **Liked** lists (`WL`/`LL`) are excluded — they
/// aren't fixed playlists worth foldering.
enum PlaylistURL {
    static func isYouTubeHost(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        return host == "youtu.be"
            || host.hasSuffix("youtube.com")
            || host.hasSuffix("youtube-nocookie.com")
    }

    /// The downloadable playlist id in `url`, or nil when there isn't one (or
    /// it's an auto-mix / auth-only list we don't expand).
    static func playlistID(in url: URL) -> String? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let list = comps.queryItems?.first(where: { $0.name == "list" })?.value,
              !list.isEmpty else { return nil }
        if list.hasPrefix("RD") || list == "WL" || list == "LL" { return nil }
        return list
    }

    static func isPlaylistURL(_ string: String) -> Bool {
        guard let url = URL(string: string) else { return false }
        return isYouTubeHost(url) && playlistID(in: url) != nil
    }
}

/// Resolves a playlist URL into its entries via the on-device yt-dlp (Python)
/// module, using a **flat** extraction (`extract_flat`) that lists the entries
/// without resolving each video's stream URLs — fast and metadata-only, the same
/// lightweight footing as `ChapterFetcher`.
///
/// Like `ChapterFetcher`, it only runs when the yt-dlp Python module is already
/// present (so it never triggers the tens-of-MB module download on its own) and
/// returns nil when PythonKit/YoutubeDL aren't linked. A nil result means "treat
/// the link as a single download" — the caller falls back gracefully.
enum PlaylistResolver {
    static func resolve(url: URL) async -> ResolvedPlaylist? {
        #if canImport(YoutubeDL) && canImport(PythonKit)
        let category = "Playlist"
        guard FileManager.default.fileExists(atPath: YoutubeDL.pythonModuleURL.path) else {
            appLog("yt-dlp module not present — can't resolve playlist.", level: .warning, category: category)
            return nil
        }
        do {
            // Instantiating YoutubeDL configures PythonKit's module search path so
            // `import yt_dlp` resolves (mirrors ChapterFetcher).
            _ = YoutubeDL()
            let ytdlpModule = Python.import("yt_dlp")
            let options: PythonObject = [
                "quiet": true,
                // List entries without resolving each video — fast, no nsig work.
                "extract_flat": "in_playlist",
                // Skip entries that error rather than aborting the whole playlist.
                "ignoreerrors": true,
                "nocheckcertificate": true,
            ]
            let ytdlp = ytdlpModule.YoutubeDL(options)
            let info = try ytdlp.extract_info.throwing.dynamicallyCall(withKeywordArguments: [
                "": url.absoluteString, "download": false, "process": false,
            ])
            let entriesObj = info.get("entries")
            if entriesObj == Python.None { return nil }

            let rawTitle = String(info.get("title")) ?? ""
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)

            var urls: [String] = []
            for entry in entriesObj {
                if entry == Python.None { continue }
                guard let entryURL = entryURL(from: entry) else { continue }
                urls.append(entryURL)
            }
            guard !urls.isEmpty else {
                appLog("Playlist resolved to no playable entries.", level: .warning, category: category)
                return nil
            }
            appLog("Resolved playlist \"\(title)\" → \(urls.count) entries.", level: .success, category: category)
            return ResolvedPlaylist(title: title.isEmpty ? "Playlist" : title, entryURLs: urls)
        } catch {
            appLog("Playlist resolution failed: \(error.localizedDescription)", level: .error, category: category)
            return nil
        }
        #else
        return nil
        #endif
    }

    #if canImport(PythonKit)
    /// Pulls a downloadable URL out of one flat playlist entry. Prefers a clean
    /// `watch?v=<id>` built from the id (so it carries no `list=` param and won't
    /// be re-detected as a playlist, and the native YouTubeKit path can take it),
    /// then `webpage_url`, then the entry's own `url`.
    private static func entryURL(from entry: PythonObject) -> String? {
        if let id = String(entry.get("id")), !id.isEmpty {
            let ie = (String(entry.get("ie_key")) ?? "").lowercased()
            // Flat YouTube entries carry only the bare 11-char id; build a watch URL.
            if ie.contains("youtube") || (id.count == 11 && entry.get("url") == Python.None) {
                return "https://www.youtube.com/watch?v=\(id)"
            }
        }
        if let webpage = String(entry.get("webpage_url")),
           webpage.lowercased().hasPrefix("http") {
            return webpage
        }
        if let raw = String(entry.get("url")), raw.lowercased().hasPrefix("http") {
            return raw
        }
        // Last resort: a bare id with no ie_key — assume YouTube.
        if let id = String(entry.get("id")), !id.isEmpty {
            return "https://www.youtube.com/watch?v=\(id)"
        }
        return nil
    }
    #endif
}
