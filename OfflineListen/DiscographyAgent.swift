import Foundation

/// The AI half of the Artist source's **Search Discography** mode: given an
/// artist's name, the model lays out the discography as albums with real song
/// *names* (plus a **Highlights** list of essentials pinned on top). That
/// layout is all this agent produces now — it never resolves YouTube links.
/// The discography browser (`DiscographyBrowserView`) shows the album and song
/// names as a first pass, and each album's tracks are matched against YouTube
/// only when the user searches that album, so one refresh no longer costs a
/// search scrape per track across the whole catalogue.
///
/// (The model is never trusted to produce YouTube links — it hallucinates
/// video ids — which is why matching is a separate, on-demand search step.)
enum DiscographyAgent {
    /// The pinned first section's name.
    static let highlightsTitle = "Highlights"

    /// Asks the model for the artist's catalogue layout: album titles, years
    /// and track names, plus the Highlights list. No YouTube work happens here.
    static func layout(artist rawArtist: String, settings: AISettingsStore) async throws -> Discography {
        guard await settings.isAuthenticated else { throw BrowseFetchError.aiNotConfigured }

        let artist = rawArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty else { throw BrowseFetchError.badInput("Enter an artist's name.") }

        let client = await AnthropicClient(apiKey: settings.apiKey, model: settings.model)
        // Full exchange to the Log (debug level), so an incomplete catalogue
        // can be pinned on the model's answer.
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
        guard !discography.highlights.isEmpty || !discography.albums.isEmpty else {
            throw BrowseFetchError.badInput("The AI couldn't produce a discography for \"\(artist)\". Check the spelling and try again.")
        }
        return discography
    }

    /// The pinned **Top 10** as an agent call: the model lists the artist's
    /// ten most popular tracks, names only — YouTube matching stays the
    /// browser's on-demand search step, exactly like an album's tracks.
    ///
    /// An **empty answer is a legitimate one**, not an error: the prompt
    /// forbids inventing tracks, so the model answers `[]` for any artist it
    /// doesn't know — which is most of the Every Noise map's long tail. The
    /// caller (`SpotifyDiscographyProvider`) treats empty as "ask the
    /// catalogue instead", never as something to show the user.
    static func topTracks(artist rawArtist: String, settings: AISettingsStore) async throws -> [String] {
        guard await settings.isAuthenticated else { throw BrowseFetchError.aiNotConfigured }

        let artist = rawArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty else { throw BrowseFetchError.badInput("Enter an artist's name.") }

        let client = await AnthropicClient(apiKey: settings.apiKey, model: settings.model)
        appLog("AI prompt → Top 10 \"\(artist)\":\n--- system ---\n\(topTracksSystemPrompt)\n--- user ---\nArtist: \(artist)",
               level: .debug, category: "Browse")
        let raw = try await client.complete(
            system: topTracksSystemPrompt,
            userText: "Artist: \(artist)",
            maxTokens: 1000
        )
        appLog("Top 10 response for \"\(artist)\":\n\(raw.prefix(600))",
               level: .debug, category: "Browse")

        let titles = parseTitles(raw)
        appLog("Top 10 for \"\(artist)\": model returned \(titles.count) track(s).",
               level: titles.isEmpty ? .warning : .info, category: "Browse")
        return Array(titles.prefix(10))
    }

    // MARK: - Prompt

    private static let topTracksSystemPrompt = """
    You are a music encyclopedia. Given an artist, list that artist's 10 most \
    popular, best-known songs, ranked from most to least popular.

    Respond with ONLY a JSON array of song-title strings and nothing else — \
    no markdown, no commentary:
    ["Song", ...]

    Rules:
    - Real song titles only — never invent tracks.
    - Song titles only — no "Artist -" prefix and no "(feat. ...)" credits.
    - If you don't recognize the artist, return [].
    """

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

    /// Parses a bare array of song titles (the Top 10 answer). The straight
    /// path is the requested JSON array (tolerating surrounding text by
    /// extracting the outermost `[ … ]` span); an answer that sampled as
    /// prose instead — a numbered list, quoted titles in running text, or a
    /// token-capped array missing its `]` — is **salvaged** rather than
    /// failed, because "couldn't parse the shape" must never read as
    /// "doesn't know the artist".
    static func parseTitles(_ raw: String) -> [String] {
        if let start = raw.firstIndex(of: "["),
           let end = raw.lastIndex(of: "]"), start < end,
           let data = String(raw[start...end]).data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) {
            let titles = stringList(array)
            if !titles.isEmpty { return titles }
        }

        // Salvage 1: numbered-list lines — `1. Song` / `2) "Song"`.
        let numbered = raw.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let match = trimmed.range(of: #"^\d{1,2}[.)]\s+"#, options: .regularExpression) else {
                return nil
            }
            let title = trimmed[match.upperBound...]
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'").union(.whitespaces))
            return title.isEmpty ? nil : title
        }
        if !numbered.isEmpty { return numbered }

        // Salvage 2: double-quoted titles anywhere — running prose, or a
        // truncated JSON array whose closing bracket the token cap ate.
        guard let quoteFinder = try? NSRegularExpression(pattern: "\"([^\"\\n]{1,80})\"") else {
            return []
        }
        let range = NSRange(raw.startIndex..., in: raw)
        return quoteFinder.matches(in: raw, range: range).compactMap { match in
            guard let titleRange = Range(match.range(at: 1), in: raw) else { return nil }
            let title = raw[titleRange].trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : title
        }
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
