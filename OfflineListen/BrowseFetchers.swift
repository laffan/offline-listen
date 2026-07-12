import Foundation

/// Errors surfaced by the Browse fetchers, phrased for the source list UI.
enum BrowseFetchError: LocalizedError {
    case badInput(String)
    case network(String)
    case notAFeed
    case channelNotFound
    case aiNotConfigured

    var errorDescription: String? {
        switch self {
        case .badInput(let message):
            return message
        case .network(let message):
            return "Network error: \(message)"
        case .notAFeed:
            return "That URL didn't return a readable RSS/Atom feed."
        case .channelNotFound:
            return "Couldn't find a channel id for that link. Try the channel's /channel/UC… URL."
        case .aiNotConfigured:
            return "This source type needs an Anthropic API key — add one in Settings."
        }
    }
}

/// Shared plumbing for the Browse fetchers: a plain GET with a desktop browser
/// user agent (YouTube serves scrapers the same pages it serves Safari) and the
/// YouTube-link patterns both the RSS filter and the search resolver use.
enum BrowseHTTP {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    static func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = 30
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            if isCancellation(error) { throw error }
            throw BrowseFetchError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BrowseFetchError.network("HTTP \(http.statusCode) from \(url.host ?? "server")")
        }
        return data
    }

    /// Every YouTube video id found in `text` (watch/short/embed/youtu.be
    /// links), in order of appearance, deduplicated.
    static func youTubeVideoIDs(in text: String) -> [String] {
        let pattern = #"(?:youtube(?:-nocookie)?\.com/(?:watch\?[^"'\s<>]*?v=|shorts/|embed/|live/)|youtu\.be/)([0-9A-Za-z_-]{11})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        var ids: [String] = []
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, match.numberOfRanges > 1,
                  let idRange = Range(match.range(at: 1), in: text) else { return }
            let id = String(text[idRange])
            if seen.insert(id).inserted { ids.append(id) }
        }
        return ids
    }

    static func watchURL(forVideoID id: String) -> String {
        "https://www.youtube.com/watch?v=\(id)"
    }

    /// First match's capture group 1, or nil.
    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }
}

/// Fetches a YouTube channel's or playlist's entries via YouTube's public
/// RSS/Atom feeds (`/feeds/videos.xml`) — no API key, no quota. A channel given
/// as a handle or vanity URL is resolved to its `UC…` id by scraping the
/// channel page once (cached on the source afterwards).
enum YouTubeBrowseFeed {
    /// Result of a feed fetch: the feed's own title (for auto-naming the
    /// source) plus the items, and the resolved channel id worth caching.
    struct Result {
        var feedTitle: String
        var items: [FetchedBrowseItem]
        var resolvedChannelID: String?
    }

    static func fetch(source: BrowseSource) async throws -> Result {
        var resolvedID: String? = nil
        let feedURL: URL
        switch source.kind {
        case .youtubeChannel:
            let channelID: String
            if let cached = source.resolvedChannelID {
                channelID = cached
            } else {
                channelID = try await resolveChannelID(from: source.input)
                resolvedID = channelID
            }
            feedURL = URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelID)")!
        case .youtubePlaylist:
            let playlistID = try Self.playlistID(from: source.input)
            guard let url = URL(string: "https://www.youtube.com/feeds/videos.xml?playlist_id=\(playlistID)") else {
                throw BrowseFetchError.badInput("That doesn't look like a playlist link or id.")
            }
            feedURL = url
        default:
            throw BrowseFetchError.badInput("Not a YouTube feed source.")
        }

        let data = try await BrowseHTTP.get(feedURL)
        guard let feed = FeedParser.parse(data) else { throw BrowseFetchError.notAFeed }

        let items: [FetchedBrowseItem] = feed.entries.compactMap { entry in
            // YouTube feed entries always carry yt:videoId; fall back to
            // scanning the link just in case.
            guard let videoID = entry.videoID ?? BrowseHTTP.youTubeVideoIDs(in: entry.link).first else {
                return nil
            }
            return FetchedBrowseItem(
                title: entry.title.isEmpty ? "Untitled video" : entry.title,
                detail: entry.summary,
                url: BrowseHTTP.watchURL(forVideoID: videoID),
                videoID: videoID,
                datePublished: entry.published
            )
        }
        return Result(feedTitle: feed.title, items: items, resolvedChannelID: resolvedID)
    }

    /// Accepts a `/channel/UC…` URL, a bare `UC…` id, an `@handle`, a vanity
    /// `/c/…`/`/user/…` URL, or a plain channel name — scraping the channel page
    /// for its id when the input doesn't carry one.
    static func resolveChannelID(from input: String) async throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BrowseFetchError.badInput("Enter a channel link or handle.") }

        // Already an id, or a URL that contains one.
        if let id = BrowseHTTP.firstMatch(#"(UC[0-9A-Za-z_-]{22})"#, in: trimmed) {
            return id
        }

        // Build the channel page URL to scrape.
        let pageURL: URL?
        if trimmed.lowercased().hasPrefix("http") {
            pageURL = URL(string: trimmed)
        } else if trimmed.hasPrefix("@") {
            pageURL = URL(string: "https://www.youtube.com/\(trimmed)")
        } else {
            // A bare handle/name — try it as a handle.
            let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
            pageURL = URL(string: "https://www.youtube.com/@\(encoded)")
        }
        guard let pageURL else { throw BrowseFetchError.badInput("That doesn't look like a channel link or handle.") }

        let data = try await BrowseHTTP.get(pageURL)
        let html = String(decoding: data, as: UTF8.self)
        if let id = BrowseHTTP.firstMatch(#""channelId":"(UC[0-9A-Za-z_-]{22})""#, in: html)
            ?? BrowseHTTP.firstMatch(#"channel_id=(UC[0-9A-Za-z_-]{22})"#, in: html)
            ?? BrowseHTTP.firstMatch(#"(UC[0-9A-Za-z_-]{22})"#, in: html) {
            return id
        }
        throw BrowseFetchError.channelNotFound
    }

    /// Pulls a playlist id out of a URL's `list=` param, or accepts a bare id.
    static func playlistID(from input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = BrowseHTTP.firstMatch(#"[?&]list=([0-9A-Za-z_-]+)"#, in: trimmed) {
            return id
        }
        // A bare playlist id (PL/UU/OL/FL…) — anything URL-ish is rejected.
        if !trimmed.contains("/"), !trimmed.contains(" "), trimmed.count >= 13 {
            return trimmed
        }
        throw BrowseFetchError.badInput("That doesn't look like a playlist link or id.")
    }
}

/// Reads any RSS/Atom feed and keeps only the posts that contain YouTube links
/// (a blog's music roundups, a newsletter's song-of-the-day, …). One item per
/// YouTube video found; a post with several links yields several items.
enum RSSBrowseFeed {
    struct Result {
        var feedTitle: String
        var items: [FetchedBrowseItem]
    }

    static func fetch(source: BrowseSource) async throws -> Result {
        let trimmed = source.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else {
            throw BrowseFetchError.badInput("Enter the feed's URL (https://…).")
        }
        let data = try await BrowseHTTP.get(url)
        guard let feed = FeedParser.parse(data) else { throw BrowseFetchError.notAFeed }

        var items: [FetchedBrowseItem] = []
        for entry in feed.entries {
            // Scan the entry's link and every raw body for YouTube links.
            let haystack = ([entry.link] + entry.rawBodies).joined(separator: "\n")
            let ids = BrowseHTTP.youTubeVideoIDs(in: haystack)
            for (index, videoID) in ids.enumerated() {
                let title = ids.count == 1
                    ? entry.title
                    : "\(entry.title) (\(index + 1) of \(ids.count))"
                items.append(FetchedBrowseItem(
                    title: title.isEmpty ? "Untitled post" : title,
                    detail: entry.summary,
                    url: BrowseHTTP.watchURL(forVideoID: videoID),
                    videoID: videoID,
                    datePublished: entry.published
                ))
            }
        }
        return Result(feedTitle: feed.title, items: items)
    }
}

/// Resolves a free-text query ("Ali Farka Touré Savane") to the first YouTube
/// search result by scraping the results page's initial data blob. Best-effort:
/// returns nil rather than throwing when the page shape changes.
enum YouTubeSearchResolver {
    static func firstVideoID(matching query: String) async -> String? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://www.youtube.com/results?search_query=\(encoded)") else { return nil }
        do {
            let data = try await BrowseHTTP.get(url)
            let html = String(decoding: data, as: UTF8.self)
            // The first videoRenderer in ytInitialData is the top organic result.
            if let id = BrowseHTTP.firstMatch(#""videoRenderer":\{"videoId":"([0-9A-Za-z_-]{11})""#, in: html) {
                return id
            }
            // Page shape fallback: any watch link in the markup.
            return BrowseHTTP.youTubeVideoIDs(in: html).first
        } catch {
            appLog("YouTube search failed for \"\(query)\": \(error.localizedDescription)",
                   level: .warning, category: "Browse")
            return nil
        }
    }
}
