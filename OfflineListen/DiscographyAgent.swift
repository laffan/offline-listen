import Foundation

/// The Browse tab's **Discography** source: an AI agent that, given an artist's
/// name, lays out the artist's discography as a nested list of albums — each
/// album a section of its tracks — with a **Highlights** list of the artist's
/// essential songs pinned on top.
///
/// Like `AIDiscovery` and the Blog Agent's mentioned-track fallback, the model
/// is asked only for real album and song *names* (with each album's year); it
/// is never trusted to produce YouTube links (it hallucinates video ids), so
/// every track is resolved to a real video by scraping the top result of a
/// YouTube search.
enum DiscographyAgent {
    /// The pinned first section's name — also the `groupKey`/`postTitle` its
    /// items carry, so the list can lift it above the albums.
    static let highlightsTitle = "Highlights"

    /// Caps that keep one refresh's YouTube-search fan-out bounded: a prolific
    /// artist's catalogue runs to hundreds of tracks and each track costs a
    /// search scrape. Anything past the ceiling is dropped and logged (never
    /// silently), matching the app's "no silent caps" rule.
    private static let maxHighlights = 12
    private static let maxAlbums = 20
    private static let maxTracksPerAlbum = 16
    /// Hard ceiling on how many track lookups one refresh performs.
    private static let maxTotalTracks = 120

    /// A far-future stamp shared by every Highlights track so they (a) sort as
    /// one block above the real, past-dated album tracks and (b) keep the
    /// model's best-first order under the list's stable date sort — a per-item
    /// `nil` date would fall back to each row's fetch time and reverse them.
    /// The list hides this stamp in the Highlights header.
    static let highlightsDate = DiscographyAgent.date(forYear: 9999)

    struct Result {
        var items: [FetchedBrowseItem]
    }

    static func fetch(source: BrowseSource, settings: AISettingsStore) async throws -> Result {
        guard await settings.isAuthenticated else { throw BrowseFetchError.aiNotConfigured }

        let artist = source.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty else { throw BrowseFetchError.badInput("Enter an artist's name.") }

        let client = await AnthropicClient(apiKey: settings.apiKey, model: settings.model)
        // Full exchange to the Log (debug level), so an incomplete catalogue
        // can be pinned on the model's answer vs. the caps/resolution below.
        appLog("AI prompt → Discography \"\(artist)\":\n--- system ---\n\(systemPrompt)\n--- user ---\nArtist: \(artist)",
               level: .debug, category: "Browse")
        // 8192, not 4096: a prolific artist's 20-album catalogue as JSON runs
        // past 4k output tokens, and a capped response truncates mid-array —
        // which used to read as an inexplicably short discography.
        let raw = try await client.complete(
            system: systemPrompt,
            userText: "Artist: \(artist)",
            maxTokens: 8192
        )
        appLog("Discography response for \"\(artist)\" (\(raw.count) chars):\n\(raw.prefix(1200))\(raw.count > 1200 ? "\n… [truncated in log]" : "")",
               level: .debug, category: "Browse")
        if !raw.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("}") {
            appLog("Discography response for \"\(artist)\" doesn't end in \"}\" — the model likely hit the token cap, so late albums are missing.",
                   level: .warning, category: "Browse")
        }

        let discography = parse(raw)
        let modelTracks = discography.albums.reduce(0) { $0 + $1.tracks.count }
        appLog("Discography for \"\(artist)\": model returned \(discography.highlights.count) highlight(s) and \(discography.albums.count) album(s) with \(modelTracks) track(s).",
               category: "Browse")
        logCapDrops(artist: artist, discography: discography)
        guard !discography.highlights.isEmpty || !discography.albums.isEmpty else {
            throw BrowseFetchError.badInput("The AI couldn't produce a discography for \"\(artist)\". Check the spelling and try again.")
        }

        var items: [FetchedBrowseItem] = []
        var attempts = 0
        var truncated = false

        // Highlights first — stamped with the shared far-future date so they
        // sort as a block at the very top, in the model's best-first order.
        for title in discography.highlights.prefix(maxHighlights) {
            if Task.isCancelled { break }
            guard attempts < maxTotalTracks else { truncated = true; break }
            attempts += 1
            if let item = await resolve(artist: artist, track: title, section: highlightsTitle, date: highlightsDate) {
                items.append(item)
            }
        }

        // Then each album's tracks, grouped under the album and dated by its
        // release year (albums thus land newest-first beneath Highlights).
        albums: for album in discography.albums.prefix(maxAlbums) {
            let albumDate = album.year.flatMap(Self.date(forYear:))
            for track in album.tracks.prefix(maxTracksPerAlbum) {
                if Task.isCancelled { break albums }
                guard attempts < maxTotalTracks else { truncated = true; break albums }
                attempts += 1
                if let item = await resolve(artist: artist, track: track, section: album.title, date: albumDate) {
                    items.append(item)
                }
            }
        }

        if truncated {
            appLog("Discography for \"\(artist)\" is large — capped at \(maxTotalTracks) track lookups this refresh.",
                   level: .warning, category: "Browse")
        }
        appLog("Discography: resolved \(items.count) track(s) for \"\(artist)\" across up to \(min(discography.albums.count, maxAlbums)) album(s).",
               category: "Browse")
        return Result(items: items)
    }

    /// Says up front — precisely — how much of the model's catalogue the caps
    /// will drop, so "the discography is incomplete" is a diagnosis you can
    /// read off the Log instead of a mystery: N albums past the album cap,
    /// M tracks past the per-album cap, K past the total-lookup ceiling.
    private static func logCapDrops(artist: String, discography: Discography) {
        let extraAlbums = max(0, discography.albums.count - maxAlbums)
        let keptAlbums = discography.albums.prefix(maxAlbums)
        let overlongTracks = keptAlbums.reduce(0) { $0 + max(0, $1.tracks.count - maxTracksPerAlbum) }
        let planned = min(discography.highlights.count, maxHighlights)
            + keptAlbums.reduce(0) { $0 + min($1.tracks.count, maxTracksPerAlbum) }
        let overTotal = max(0, planned - maxTotalTracks)
        guard extraAlbums > 0 || overlongTracks > 0 || overTotal > 0 else { return }
        var parts: [String] = []
        if extraAlbums > 0 { parts.append("\(extraAlbums) album(s) past the \(maxAlbums)-album cap") }
        if overlongTracks > 0 { parts.append("\(overlongTracks) track(s) past the \(maxTracksPerAlbum)-per-album cap") }
        if overTotal > 0 { parts.append("\(overTotal) track(s) past the \(maxTotalTracks)-lookup ceiling") }
        appLog("Discography for \"\(artist)\": the refresh caps will drop \(parts.joined(separator: ", ")).",
               level: .warning, category: "Browse")
    }

    /// Resolves one `"artist track"` query to a real YouTube video and wraps it
    /// as an item grouped under `section` (an album title, or "Highlights"),
    /// dated by `date` (the album's release year, or the Highlights stamp).
    /// Returns nil when the search finds nothing — logged and skipped, exactly
    /// like `AIDiscovery`.
    private static func resolve(artist: String, track: String, section: String, date: Date?) async -> FetchedBrowseItem? {
        let query = "\(artist) \(track)"
        guard let videoID = await YouTubeSearchResolver.firstVideoID(matching: query) else {
            appLog("No YouTube result for \"\(query)\" — skipping.", level: .warning, category: "Browse")
            return nil
        }
        return FetchedBrowseItem(
            title: "\(artist) — \(track)",
            detail: "",
            url: BrowseHTTP.watchURL(forVideoID: videoID),
            videoID: videoID,
            datePublished: date,
            postTitle: section,
            postURL: nil,
            // Fold the section into the dedup identity so a Highlights track
            // that is *also* an album track stays a separate row in each.
            groupKey: section
        )
    }

    // MARK: - Prompt

    private static let systemPrompt = """
    You are a music encyclopedia. Given an artist, lay out that artist's \
    discography.

    Respond with ONLY a JSON object and nothing else — no markdown, no \
    commentary:
    {
      "highlights": [string, ...],
      "albums": [
        {"title": string, "year": number, "tracks": [string, ...]},
        ...
      ]
    }

    Rules:
    - "highlights" is a short list (about 10, at most 12) of the artist's \
    signature/most essential songs, best first. These titles may also appear \
    inside the albums below — that's expected.
    - "albums" lists the artist's studio albums in chronological order (oldest \
    first), at most 20 (the most significant if there are more), each with its \
    release year and its real track titles.
    - Use real album and song titles only. Never invent releases or tracks, and \
    never pad a tracklist.
    - Song titles only — no "Artist -" prefix and no "(feat. ...)" credits.
    - If you don't recognize the artist, return {"highlights": [], "albums": []}.
    """

    // MARK: - Parsing

    struct Album {
        var title: String
        var year: Int?
        var tracks: [String]
    }

    struct Discography {
        var highlights: [String]
        var albums: [Album]
    }

    /// Parses the model's JSON object, tolerating surrounding text/fences by
    /// extracting the outermost `{ ... }` span (the same salvage trick the
    /// other AI parsers use), and accepting song entries as either bare strings
    /// or `{"title": ...}` objects.
    static func parse(_ raw: String) -> Discography {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Discography(highlights: [], albums: [])
        }
        let highlights = stringList(object["highlights"])
        let albums = (object["albums"] as? [Any])?
            .compactMap { ($0 as? [String: Any]).flatMap(Self.parseAlbum) } ?? []
        return Discography(highlights: highlights, albums: albums)
    }

    /// Reads a list of song titles, accepting `"Song"` or `{"title": "Song"}`
    /// (some models wrap them), trimmed and empties dropped.
    private static func stringList(_ value: Any?) -> [String] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { element -> String? in
            let raw: String?
            if let string = element as? String {
                raw = string
            } else if let dict = element as? [String: Any] {
                raw = (dict["title"] as? String) ?? (dict["name"] as? String) ?? (dict["song"] as? String)
            } else {
                raw = nil
            }
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty ?? true) ? nil : trimmed
        }
    }

    private static func parseAlbum(_ dict: [String: Any]) -> Album? {
        let rawTitle = (dict["title"] as? String) ?? (dict["album"] as? String) ?? (dict["name"] as? String)
        guard let title = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }
        let year: Int?
        if let value = dict["year"] as? Int {
            year = value
        } else if let value = dict["year"] as? String, let parsed = Int(value.prefix(4)) {
            year = parsed
        } else {
            year = nil
        }
        let tracks = stringList(dict["tracks"] ?? dict["songs"])
        guard !tracks.isEmpty else { return nil }
        return Album(title: title, year: year, tracks: tracks)
    }

    /// January 1st of `year`, used both to order albums newest-first and to
    /// label each album section with its year.
    static func date(forYear year: Int) -> Date? {
        var components = DateComponents()
        components.year = year
        components.month = 1
        components.day = 1
        return Calendar(identifier: .gregorian).date(from: components)
    }
}
