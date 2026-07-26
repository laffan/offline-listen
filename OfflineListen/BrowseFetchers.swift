import Foundation

/// Errors surfaced by the Browse fetchers, phrased for the source list UI.
enum BrowseFetchError: LocalizedError {
    case badInput(String)
    case network(String)
    case notAFeed
    case channelNotFound
    case aiNotConfigured
    /// The site refused the agent (bot protection / anti-scraping challenge).
    case agentBlocked

    var errorDescription: String? {
        switch self {
        case .badInput(let message):
            return message
        case .network(let message):
            return "Network error: \(message)"
        case .notAFeed:
            return "That URL didn't return a readable RSS/Atom feed."
        case .channelNotFound:
            return "Couldn't find that channel. Open it in a browser and paste the address from the URL bar (either the /channel/UC… or the @handle form)."
        case .aiNotConfigured:
            return "This source type needs an Anthropic API key — add one in Settings."
        case .agentBlocked:
            return "Agent blocked: the site's bot protection is refusing automated readers."
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

    /// Like `get`, but hands back non-2xx responses instead of throwing, so
    /// the Blog Agent can tell a bot-protection refusal (403/429 + challenge
    /// page) from an ordinary failure. Also reports the post-redirect URL
    /// (the base for resolving a page's relative links). Network-level errors
    /// still throw.
    static func getRaw(_ url: URL) async throws -> (data: Data, status: Int, finalURL: URL) {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = 30
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            return (data, status, response.url ?? url)
        } catch {
            if isCancellation(error) { throw error }
            throw BrowseFetchError.network(error.localizedDescription)
        }
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

    /// First match's capture group 1, or nil. (Stops at the first hit, which
    /// matters on the megabyte-scale pages the scrapers read.)
    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }

    /// Every match's capture group 1, in order of appearance, deduplicated.
    static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        var results: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        where match.numberOfRanges > 1 {
            let value = ns.substring(with: match.range(at: 1))
            if seen.insert(value).inserted { results.append(value) }
        }
        return results
    }

    /// True when a fetched page is a bot-protection / consent interstitial
    /// rather than the content that was asked for — YouTube serves these to
    /// unrecognised clients, and they carry no channel id to scrape.
    static func looksLikeChallenge(_ html: String) -> Bool {
        let markers = ["consent.youtube.com", "Before you continue to YouTube",
                       "Verify you are human", "Just a moment…", "Just a moment...",
                       "confirm you’re not a bot", "confirm you're not a bot"]
        let head = String(html.prefix(200_000))
        return markers.contains { head.localizedCaseInsensitiveContains($0) }
    }
}

/// Fetches a YouTube channel's or playlist's entries via YouTube's public
/// RSS/Atom feeds (`/feeds/videos.xml`) — no API key, no quota. A channel given
/// as a handle, a vanity URL or a plain name is resolved to its `UC…` id —
/// page scrape first, channel search as a backstop — and every candidate id is
/// verified against the feed endpoint before it's cached on the source.
enum YouTubeBrowseFeed {
    /// Result of a feed fetch: the feed's own title (for auto-naming the
    /// source) plus the items, and the resolved channel id worth caching.
    struct Result {
        var feedTitle: String
        var items: [FetchedBrowseItem]
        var resolvedChannelID: String?
    }

    /// A channel id as YouTube writes it: `UC` + 22 id characters.
    private static let idPattern = "UC[0-9A-Za-z_-]{22}"

    static func fetch(source: BrowseSource) async throws -> Result {
        switch source.kind {
        case .youtubeChannel:
            return try await fetchChannel(source: source)
        case .youtubePlaylist:
            let playlistID = try Self.playlistID(from: source.input)
            guard let url = URL(string: "https://www.youtube.com/feeds/videos.xml?playlist_id=\(playlistID)") else {
                throw BrowseFetchError.badInput("That doesn't look like a playlist link or id.")
            }
            guard let feed = try await parsedFeed(at: url) else {
                throw BrowseFetchError.badInput("YouTube has no feed for that playlist — private and unlisted playlists aren't readable, and auto-generated mixes (RD…) have no feed.")
            }
            return Result(feedTitle: feed.title, items: items(in: feed), resolvedChannelID: nil)
        default:
            throw BrowseFetchError.badInput("Not a YouTube feed source.")
        }
    }

    /// A channel's uploads. The cached id is tried first but never trusted
    /// forever: when its feed has gone (the channel was deleted, or an earlier
    /// scrape latched onto an id that was never the channel's) the input is
    /// re-resolved from scratch instead of every refresh failing identically.
    private static func fetchChannel(source: BrowseSource) async throws -> Result {
        if let cached = source.resolvedChannelID,
           let url = feedURL(forChannelID: cached),
           let feed = try await parsedFeed(at: url) {
            return Result(feedTitle: feed.title, items: items(in: feed), resolvedChannelID: nil)
        }
        if let cached = source.resolvedChannelID {
            appLog("Browse: the stored channel id \(cached) no longer has a feed — re-resolving \"\(source.input)\".",
                   level: .warning, category: "Browse")
        }
        let resolved = try await resolveChannelFeed(from: source.input)
        return Result(feedTitle: resolved.feed.title,
                      items: items(in: resolved.feed),
                      resolvedChannelID: resolved.id)
    }

    /// The feed entries as browse items. YouTube feed entries always carry
    /// `yt:videoId`; the link scan is a belt-and-braces fallback.
    private static func items(in feed: ParsedFeed) -> [FetchedBrowseItem] {
        feed.entries.compactMap { entry in
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
    }

    private static func feedURL(forChannelID id: String) -> URL? {
        URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(id)")
    }

    /// Fetches a YouTube feed, returning nil when the server says there isn't
    /// one there (a 404 for an id that names no channel/playlist) or the body
    /// isn't a feed. Genuine network failures — and a server-side 5xx — still
    /// throw: "we're offline" or "YouTube is having a moment" must not be
    /// mistaken for "that id is wrong".
    private static func parsedFeed(at url: URL) async throws -> ParsedFeed? {
        let (data, status, _) = try await BrowseHTTP.getRaw(url)
        if (500..<600).contains(status) {
            throw BrowseFetchError.network("HTTP \(status) from \(url.host ?? "server")")
        }
        guard (200..<300).contains(status) else { return nil }
        return FeedParser.parse(data)
    }

    /// Turns whatever the user typed into a channel id *whose feed actually
    /// loads*, and hands back that first feed so the caller doesn't fetch it
    /// twice.
    ///
    /// Candidate ids come from three places, tried in order: the input itself
    /// (`/channel/UC…` or a bare id), the channel page the input points at
    /// (several URL shapes, several markers per page — the page's markup moves
    /// around, and the first `UC…`-looking token in it isn't reliably the
    /// channel), and finally a YouTube channel search, which is what rescues a
    /// plain typed name like "NPR Music". Each candidate is verified against
    /// the feed endpoint before it's accepted, so a wrong guess moves on to
    /// the next instead of being cached and failing forever.
    static func resolveChannelFeed(from input: String) async throws -> (id: String, feed: ParsedFeed) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BrowseFetchError.badInput("Enter a channel link or handle.") }

        var tried = Set<String>()
        var sawChallenge = false

        /// Verifies a candidate id, returning its feed when it's real.
        func check(_ candidates: [String]) async throws -> (id: String, feed: ParsedFeed)? {
            for id in candidates where tried.insert(id).inserted {
                guard let url = feedURL(forChannelID: id) else { continue }
                if let feed = try await parsedFeed(at: url) { return (id, feed) }
                appLog("Browse: \(id) isn't a channel with a feed — trying the next candidate.",
                       level: .debug, category: "Browse")
            }
            return nil
        }

        // 1. The input already names the channel.
        if let hit = try await check(BrowseHTTP.allMatches("(\(idPattern))", in: trimmed)) {
            return hit
        }

        // 2. Scrape the channel page(s) the input points at.
        for pageURL in channelPageURLs(for: trimmed) {
            let (data, status, _) = try await BrowseHTTP.getRaw(pageURL)
            guard (200..<300).contains(status) else {
                appLog("Browse: \(pageURL.absoluteString) returned HTTP \(status).",
                       level: .debug, category: "Browse")
                continue
            }
            let html = String(decoding: data, as: UTF8.self)
            if BrowseHTTP.looksLikeChallenge(html) {
                sawChallenge = true
                continue
            }
            if let hit = try await check(channelIDs(inPage: html)) { return hit }
        }

        // 3. Last resort: ask YouTube's channel search. Handles a plain name
        //    ("NPR Music") and a handle YouTube has since renamed.
        if let hit = try await check(searchChannelIDs(for: searchTerm(from: trimmed))) {
            return hit
        }

        if sawChallenge { throw BrowseFetchError.agentBlocked }
        throw BrowseFetchError.channelNotFound
    }

    /// The channel pages worth scraping for the input, most likely first: what
    /// was pasted, then the same URL trimmed back to the channel's own page
    /// (a pasted `/@handle/videos` or `/channel/UC…?si=…` link), then the
    /// handle/vanity/legacy-user forms of a bare name.
    private static func channelPageURLs(for input: String) -> [URL] {
        var candidates: [String] = []
        if input.lowercased().hasPrefix("http") {
            candidates.append(input)
            if let components = URLComponents(string: input),
               let host = components.host, host.localizedCaseInsensitiveContains("youtube."),
               let first = components.path.split(separator: "/").first {
                let second = components.path.split(separator: "/").dropFirst().first
                // /channel/UC…, /c/name and /user/name need their second
                // component; /@handle is one component on its own.
                if ["channel", "c", "user"].contains(String(first)), let second {
                    candidates.append("https://www.youtube.com/\(first)/\(second)")
                } else {
                    candidates.append("https://www.youtube.com/\(first)")
                }
            }
        } else {
            let handle = input.hasPrefix("@") ? String(input.dropFirst()) : input
            let slug = handle.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }.joined()
            for path in ["@\(handle)", "@\(slug)", "c/\(slug)", "user/\(slug)"] {
                let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
                candidates.append("https://www.youtube.com/\(encoded)")
            }
        }
        var seen = Set<String>()
        return candidates.compactMap { seen.insert($0).inserted ? URL(string: $0) : nil }
    }

    /// Channel ids scraped from a channel page, most trustworthy marker first.
    /// The bare-token sweep is last and deliberately kept — it's the only thing
    /// that still works when YouTube reshuffles its markup — but because every
    /// candidate is verified against the feed, a wrong guess costs one request
    /// rather than a broken source.
    private static func channelIDs(inPage html: String) -> [String] {
        let patterns = [
            #"<link rel="canonical" href="https://www\.youtube\.com/channel/(\#(idPattern))""#,
            #""externalId":"(\#(idPattern))""#,
            #""channelId":"(\#(idPattern))""#,
            #"channel_id=(\#(idPattern))"#,
            #"/channel/(\#(idPattern))"#,
            "(\(idPattern))",
        ]
        var seen = Set<String>()
        var ids: [String] = []
        for pattern in patterns {
            for id in BrowseHTTP.allMatches(pattern, in: html) where seen.insert(id).inserted {
                ids.append(id)
                // A page mentions plenty of other channels (related, comments);
                // a handful of verification requests is the sane ceiling.
                if ids.count >= 4 { return ids }
            }
        }
        return ids
    }

    /// The channel ids YouTube's channel-filtered search returns for a term.
    private static func searchChannelIDs(for term: String) async -> [String] {
        let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term
        // sp=EgIQAg%3D%3D is the results page's "Channels" filter.
        guard !term.isEmpty,
              let url = URL(string: "https://www.youtube.com/results?search_query=\(encoded)&sp=EgIQAg%3D%3D"),
              let data = try? await BrowseHTTP.get(url) else { return [] }
        let html = String(decoding: data, as: UTF8.self)
        let ids = BrowseHTTP.allMatches(#""channelRenderer":\{"channelId":"(\#(idPattern))""#, in: html)
        return Array(ids.prefix(3))
    }

    /// What to search for when the input didn't resolve directly: the handle
    /// or the last path component of a URL, read as a name.
    private static func searchTerm(from input: String) -> String {
        guard input.lowercased().hasPrefix("http") else {
            return input.hasPrefix("@") ? String(input.dropFirst()) : input
        }
        guard let components = URLComponents(string: input) else { return "" }
        let parts = components.path.split(separator: "/").map(String.init)
        guard let name = parts.last(where: { !["videos", "streams", "shorts", "featured",
                                               "playlists", "about", "community"].contains($0) })
        else { return "" }
        return name.hasPrefix("@") ? String(name.dropFirst()) : name
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

/// One organic result scraped off a YouTube search page: enough to show a
/// pickable row (title + channel) and to build the watch URL.
struct YouTubeSearchResult: Identifiable, Hashable {
    let videoID: String
    let title: String
    /// The uploading channel's name — usually the artist for music results.
    let channel: String

    var id: String { videoID }
    var url: String { BrowseHTTP.watchURL(forVideoID: videoID) }
}

/// Resolves a free-text query ("Ali Farka Touré Savane") to YouTube search
/// results by scraping the results page's initial data blob. Best-effort:
/// returns nil/empty rather than throwing when the page shape changes.
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

    /// The top organic video results for a query, with titles — what the
    /// Download tab's search shows for picking. Empty on failure.
    static func topVideos(matching query: String, limit: Int = 5) async -> [YouTubeSearchResult] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://www.youtube.com/results?search_query=\(encoded)") else { return [] }
        do {
            let data = try await BrowseHTTP.get(url)
            let html = String(decoding: data, as: UTF8.self)
            return parseResults(in: html, limit: limit)
        } catch {
            appLog("YouTube search failed for \"\(query)\": \(error.localizedDescription)",
                   level: .warning, category: "Browse")
            return []
        }
    }

    /// Walks each `"videoRenderer":{"videoId":"…"` occurrence in the page's
    /// ytInitialData and reads the title/channel out of the JSON that follows
    /// it (the renderer's own fields sit within a few KB of its opening).
    static func parseResults(in html: String, limit: Int) -> [YouTubeSearchResult] {
        guard limit > 0,
              let regex = try? NSRegularExpression(pattern: #""videoRenderer":\{"videoId":"([0-9A-Za-z_-]{11})""#) else {
            return []
        }
        let ns = html as NSString
        var seen = Set<String>()
        var results: [YouTubeSearchResult] = []
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard results.count < limit else { break }
            guard match.numberOfRanges > 1 else { continue }
            let videoID = ns.substring(with: match.range(at: 1))
            guard seen.insert(videoID).inserted else { continue }

            let start = match.range.location
            let window = ns.substring(with: NSRange(location: start, length: min(8000, ns.length - start)))
            let stringBody = #"((?:[^"\\]|\\.)*)"#
            guard let rawTitle = BrowseHTTP.firstMatch(#""title":\{"runs":\[\{"text":""# + stringBody + #"""#, in: window) else {
                continue
            }
            let rawChannel = BrowseHTTP.firstMatch(#""ownerText":\{"runs":\[\{"text":""# + stringBody + #"""#, in: window)
                ?? BrowseHTTP.firstMatch(#""longBylineText":\{"runs":\[\{"text":""# + stringBody + #"""#, in: window)
            let title = decodeJSONStringBody(rawTitle)
            guard !title.isEmpty else { continue }
            results.append(YouTubeSearchResult(videoID: videoID,
                                               title: title,
                                               channel: decodeJSONStringBody(rawChannel ?? "")))
        }
        return results
    }

    /// Un-escapes the body of a JSON string literal ("Beyoncé & JAY-Z").
    private static func decodeJSONStringBody(_ raw: String) -> String {
        guard raw.contains("\\") else { return raw }
        let data = Data("\"\(raw)\"".utf8)
        return (try? JSONDecoder().decode(String.self, from: data)) ?? raw
    }
}
