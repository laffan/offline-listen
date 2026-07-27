import Foundation

/// AI-driven song discovery for the Browse tab's Artist / Genre / Country
/// sources: the model suggests popular songs (title + artist), and each
/// suggestion is resolved to a real YouTube link via the search scraper —
/// the model is never trusted to produce video ids or URLs, which it happily
/// hallucinates.
enum AIDiscovery {
    /// How many songs to ask for per refresh. Each one costs a YouTube search
    /// request, so this stays modest.
    private static let batchSize = 10

    static func fetch(source: BrowseSource,
                      settings: AISettingsStore,
                      excludingTitles: [String]) async throws -> [FetchedBrowseItem] {
        guard await settings.isAuthenticated else { throw BrowseFetchError.aiNotConfigured }
        let client = await AnthropicClient(apiKey: settings.apiKey, model: settings.model)

        let raw = try await client.complete(
            system: systemPrompt,
            userText: userPrompt(source: source, excludingTitles: excludingTitles),
            maxTokens: 1500
        )
        let suggestions = parse(raw)
        guard !suggestions.isEmpty else {
            throw BrowseFetchError.badInput("The AI returned no usable song suggestions.")
        }

        // Resolve each suggestion to a real video, serially — these are cheap
        // page fetches, and hammering YouTube in parallel invites rate limits.
        var items: [FetchedBrowseItem] = []
        for suggestion in suggestions {
            if Task.isCancelled { break }
            let query = "\(suggestion.artist) \(suggestion.title)"
            guard let videoID = await YouTubeSearchResolver.firstVideoID(matching: query) else {
                appLog("No YouTube result for \"\(query)\" — skipping.", level: .warning, category: "Browse")
                continue
            }
            items.append(FetchedBrowseItem(
                title: "\(suggestion.artist) — \(suggestion.title)",
                detail: "",
                url: BrowseHTTP.watchURL(forVideoID: videoID),
                videoID: videoID,
                datePublished: nil
            ))
        }
        return items
    }

    // MARK: - Prompt + parsing

    struct Suggestion {
        var artist: String
        var title: String
    }

    private static let systemPrompt = """
    You are a knowledgeable music curator helping build a personal listening \
    list. Suggest real, well-known songs only — never invent titles or artists.

    Respond with ONLY a JSON array and nothing else — no markdown, no \
    commentary. Each element:
    {"artist": string, "title": string}

    Do not include YouTube links or video ids — they will be looked up \
    separately.
    """

    private static func userPrompt(source: BrowseSource, excludingTitles: [String]) -> String {
        let subject: String
        switch source.kind {
        case .artist:
            if let era = source.era {
                subject = "List the \(batchSize) most popular, best-known tracks by the artist \"\(source.input)\" released in the \(era), ranked from most to least popular."
            } else {
                subject = "List the \(batchSize) most popular, best-known tracks by the artist \"\(source.input)\", ranked from most to least popular."
            }
        case .genre:
            if let era = source.era {
                subject = "List \(batchSize) popular, essential songs in the genre \"\(source.input)\" released in the \(era), spanning different artists of that decade."
            } else {
                subject = "List \(batchSize) popular, essential songs in the genre \"\(source.input)\", spanning different artists."
            }
        case .country:
            if let era = source.era {
                subject = "List \(batchSize) popular, beloved songs from \(source.input) released in the \(era) (by artists from that country), spanning artists and styles of that decade."
            } else {
                subject = "List \(batchSize) popular, beloved songs from \(source.input) (by artists from that country), spanning eras and artists."
            }
        default:
            subject = "List \(batchSize) popular songs related to \"\(source.input)\"."
        }
        guard !excludingTitles.isEmpty else { return subject }
        let exclusions = excludingTitles.suffix(60).joined(separator: "; ")
        return subject + "\n\nAlready listed — do NOT repeat any of these:\n" + exclusions
    }

    /// Parses the model's JSON array, tolerating surrounding text/fences by
    /// extracting the outermost `[ … ]` span (same trick as `AIOrganizer`).
    static func parse(_ raw: String) -> [Suggestion] {
        guard let start = raw.firstIndex(of: "["),
              let end = raw.lastIndex(of: "]"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { entry in
            guard let artist = (entry["artist"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let title = (entry["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !artist.isEmpty, !title.isEmpty else { return nil }
            return Suggestion(artist: artist, title: title)
        }
    }
}
