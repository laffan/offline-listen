import Foundation

/// What the model decided about a track.
struct AIOrganizationResult {
    /// Music vs. podcast classification.
    let kind: TrackKind
    /// Clean song title (music only); nil to leave the title unchanged.
    let cleanTitle: String?
    /// Performer/artist (music only); nil to leave the artist unchanged.
    let artist: String?
}

/// Orchestrates AI-assisted organization of tracks: builds the prompt, calls the
/// Anthropic API, and writes the result back to the library. Shared by the
/// download pipeline (automatic, when "AI assist" is on) and the library's
/// "AI Organize" long-press action (manual, on demand).
@MainActor
final class AIOrganizer: ObservableObject {
    private let library: LibraryStore
    private let settings: AISettingsStore

    /// Tracks currently being organized, so the UI can show progress and avoid
    /// kicking off a second pass on the same track.
    @Published private(set) var inFlight: Set<UUID> = []

    init(library: LibraryStore, settings: AISettingsStore) {
        self.library = library
        self.settings = settings
    }

    /// Whether AI organization is set up at all (a key is on file). Gates the
    /// "AI Organize" menu item.
    var isAvailable: Bool { settings.isAuthenticated }

    /// Runs organization only when the user has opted in via the assist toggle
    /// (and a key is configured). Used by the download pipeline.
    func organizeIfEnabled(_ trackID: UUID) async {
        guard settings.assistEnabled, settings.isAuthenticated else { return }
        await organize(trackID)
    }

    /// Organizes a single track: classify music/podcast and, for music, extract a
    /// clean title and artist. Best-effort — failures are logged, not surfaced.
    func organize(_ trackID: UUID) async {
        guard settings.isAuthenticated else { return }
        guard !inFlight.contains(trackID) else { return }
        guard let track = library.tracks.first(where: { $0.id == trackID }) else { return }
        // Video tracks aren't music/podcasts; leave them be.
        guard !track.isVideo else { return }

        inFlight.insert(trackID)
        defer { inFlight.remove(trackID) }

        let client = AnthropicClient(apiKey: settings.apiKey, model: settings.model)
        appLog("AI organizing \"\(track.title)\"…", category: "AI")
        do {
            let raw = try await client.complete(
                system: Self.systemPrompt,
                userText: Self.userPrompt(title: track.title, duration: track.duration),
                maxTokens: 256
            )
            guard let result = Self.parse(raw) else {
                appLog("AI returned an unparseable response for \"\(track.title)\".",
                       level: .warning, category: "AI")
                return
            }
            library.applyAIOrganization(to: trackID,
                                        kind: result.kind,
                                        cleanTitle: result.cleanTitle,
                                        artist: result.artist)
            switch result.kind {
            case .song:
                appLog("AI tagged \"\(result.cleanTitle ?? track.title)\" as music\(result.artist.map { " by \($0)" } ?? "").",
                       level: .success, category: "AI")
            case .podcast:
                appLog("AI classified \"\(track.title)\" as a podcast.",
                       level: .success, category: "AI")
            }
        } catch {
            appLog("AI organize failed: \(error.localizedDescription)", level: .error, category: "AI")
        }
    }

    // MARK: - Prompt + parsing

    private static let systemPrompt = """
    You organize a personal audio library. Given a downloaded track's title and \
    duration, decide whether it is a music track or a podcast/talk/spoken-word \
    episode, and for music extract the clean song title and the primary artist.

    Respond with ONLY a single JSON object and nothing else — no markdown, no \
    commentary. Shape:
    {"type": "music" | "podcast", "artist": string | null, "track": string | null}

    Rules:
    - For podcasts (interviews, talks, lectures, audiobooks, long spoken episodes), \
    set "artist" and "track" to null.
    - For music, "artist" is the performer and "track" is the song name with junk \
    removed: channel names, "Official Video", "(Lyrics)", "[HD]", remaster/year \
    tags, view counts, and emoji.
    - If genuinely unsure, lean on duration: songs are usually under ~10 minutes, \
    podcasts longer.
    """

    private static func userPrompt(title: String, duration: Double) -> String {
        let seconds = Int(duration.rounded())
        return "Title: \(title)\nDuration: \(seconds) seconds (\(duration.asPlaybackTime))"
    }

    /// Parses the model's JSON reply into a result. Tolerates surrounding text or
    /// markdown fences by extracting the outermost `{ … }` span.
    static func parse(_ raw: String) -> AIOrganizationResult? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"), start < end else { return nil }
        let jsonSlice = String(raw[start...end])
        guard let data = jsonSlice.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let typeString = (json["type"] as? String)?.lowercased() ?? ""
        let kind: TrackKind = typeString.contains("podcast") ? .podcast : .song

        func cleaned(_ key: String) -> String? {
            guard let value = json[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.lowercased() == "null" { return nil }
            return trimmed
        }

        if kind == .podcast {
            return AIOrganizationResult(kind: .podcast, cleanTitle: nil, artist: nil)
        }
        return AIOrganizationResult(kind: .song, cleanTitle: cleaned("track"), artist: cleaned("artist"))
    }
}
