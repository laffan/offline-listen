import Foundation

/// Keeping the bundled Every Noise dataset from ageing, one browsed genre at
/// a time.
///
/// The map the app ships is a one-time scrape of a site that **froze in late
/// 2024**, when Spotify revoked its API access. The genre space itself is
/// still moving, though: artists debut, and Spotify files them under labels
/// the frozen page never listed. This closes that gap opportunistically —
/// when you open a genre, and only then, the live catalogue is asked *once*
/// who it currently files under that label, and every name the bundled shard
/// doesn't have is written to an update file you can export and fold back
/// into the dataset at build time (`tools/everynoise/merge_updates.py`).
///
/// **Why it can't trip Spotify's rate limits.** The whole feature is one
/// request per genre *visit*, behind four independent brakes:
///
/// - **Opt-in.** Off until Settings ▸ Every Noise Data turns it on.
/// - **One at a time, slowly.** A single harvest runs at once, no two
///   requests are closer than `minRequestInterval`, and each is delayed a
///   few seconds behind the tap so it never races the screen the user is
///   actually waiting on.
/// - **Capped.** `dailyRequestCap` requests a day, and a genre already
///   harvested isn't asked again for `revisitInterval` — so re-opening the
///   genres you like costs nothing at all.
/// - **It yields to the limiter.** `SpotifyRateLimiter` already records
///   429 windows globally and persistently; a harvest with any window in
///   force is *skipped outright* rather than queued, because sending during
///   a window is precisely what makes Spotify extend it.
///
/// The budget is deliberately far below what Spotify meters: at one request
/// per 20 seconds it is ~3/minute against a client that gets its own quota,
/// and a genuinely heavy browsing session tops out at 150 requests for the
/// day — about what opening twenty artists in the discography browser costs.

// MARK: - The update record

/// One artist the live catalogue files under a genre that the bundled scrape
/// doesn't list there. Written one JSON object per line (JSONL, so appending
/// never rewrites the file) to `Documents/EveryNoiseUpdates/`.
struct ENUpdateRecord: Codable, Hashable {
    /// The `genres.json` key of the genre that was open when this turned up.
    let genreKey: String
    let genreName: String
    let artist: String
    let spotifyID: String
    /// Spotify's 0–100 popularity — what the merge tool sizes the new label
    /// from, standing in for the site's own font-size cue.
    let popularity: Int
    let imageURL: String?
    /// Every genre Spotify files this artist under. **New genres fall out of
    /// this**: a label here that `genres.json` has no row for is one the map
    /// is missing, and the known labels beside it say where to put it.
    let genres: [String]
    let seen: Date
}

/// The harvest's one user-tunable thing, persisted in UserDefaults and edited
/// from Settings ▸ Every Noise Data (via `@AppStorage` on the same key) — the
/// shape `BlogAgentSettings` uses, so the store reads it directly rather than
/// having it handed over.
enum ENUpdateSettings {
    static let enabledKey = "everyNoiseUpdatesEnabled"

    /// Off until turned on: this spends someone's Spotify quota, so it is
    /// never something the app starts doing on its own.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }
}

extension AppPaths {
    /// Where harvested updates accumulate. A plain directory rather than a
    /// single file so the export can hand over one tidy artefact.
    static var everyNoiseUpdates: URL {
        let url = documents.appendingPathComponent("EveryNoiseUpdates", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The append-only record file — the thing Settings exports.
    static var everyNoiseUpdatesFile: URL {
        everyNoiseUpdates.appendingPathComponent("everynoise-updates.jsonl")
    }

    /// Harvest bookkeeping (which genres, how many requests today).
    static var everyNoiseUpdatesState: URL {
        everyNoiseUpdates.appendingPathComponent("state.json")
    }
}

// MARK: - The store

@MainActor
final class ENUpdateStore: ObservableObject {
    /// Never two requests closer than this.
    private static let minRequestInterval: TimeInterval = 20
    /// A hard ceiling on a day's harvesting, however much browsing happens.
    private static let dailyRequestCap = 150
    /// How long a harvested genre is left alone before it's worth asking again.
    private static let revisitInterval: TimeInterval = 30 * 24 * 60 * 60
    /// The pause between opening a genre and asking about it — long enough
    /// that the request never competes with the shard load and the map's
    /// first layout, and short enough to still happen on a real visit.
    private static let settleDelay: TimeInterval = 4
    /// One page of the artist search: Spotify's own maximum.
    private static let pageSize = 50

    /// New artists recorded so far, and how many genres have been harvested.
    @Published private(set) var recordCount = 0
    @Published private(set) var harvestedGenreCount = 0
    /// Genre labels seen on harvested artists that `genres.json` has no row
    /// for — genres the map is missing outright.
    @Published private(set) var newGenreCount = 0
    /// True while a harvest is in flight (Settings shows it, quietly).
    @Published private(set) var isHarvesting = false
    /// The last thing that went wrong, for the Settings row. Cleared by a
    /// harvest that succeeds.
    @Published private(set) var lastError: String?

    var hasRecords: Bool { recordCount > 0 }

    /// The file Settings exports, when there's anything in it.
    var exportURL: URL? {
        let url = AppPaths.everyNoiseUpdatesFile
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private struct HarvestState: Codable {
        /// genre key → when it was last harvested.
        var harvested: [String: Date] = [:]
        var records: Int = 0
        /// Genre labels with no row in `genres.json`, deduped.
        var newGenres: Set<String> = []
        /// Requests made on `day` (an ISO yyyy-MM-dd string), for the cap.
        var day: String = ""
        var requestsToday: Int = 0
    }

    private var state = HarvestState()
    private var stateLoaded = false
    /// The single in-flight harvest — one at a time, always.
    private var harvestTask: Task<Void, Never>?
    private var lastRequest: Date?
    /// `genreKey|folded artist name` for everything already recorded, so a
    /// re-harvest months later doesn't write the same rows twice. Rebuilt
    /// from the file on first use.
    private var recorded: Set<String> = []
    /// The bundled genre index, folded — memoized on first harvest.
    private var knownGenres: Set<String> = []

    // MARK: Lifecycle

    /// Reads the bookkeeping (and the record file's keys) once, lazily — the
    /// feature costs nothing at all until it's used.
    private func loadIfNeeded() {
        guard !stateLoaded else { return }
        stateLoaded = true
        if let data = try? Data(contentsOf: AppPaths.everyNoiseUpdatesState),
           let decoded = try? JSONDecoder().decode(HarvestState.self, from: data) {
            state = decoded
        }
        recorded = Self.recordedKeys(in: AppPaths.everyNoiseUpdatesFile)
        publishCounts()
    }

    private func publishCounts() {
        recordCount = state.records
        harvestedGenreCount = state.harvested.count
        newGenreCount = state.newGenres.count
    }

    private func saveState() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: AppPaths.everyNoiseUpdatesState, options: .atomic)
    }

    // MARK: The harvest

    /// Called when a genre's artist map opens. Decides — cheaply, on the main
    /// actor — whether this visit is worth a request, and schedules it behind
    /// the settle delay if so. Every reason not to is silent: this is a
    /// background nicety, never something that interrupts browsing.
    func genreOpened(_ genre: ENGenre,
                     localArtists: [ENArtist],
                     genreIndex: [ENGenre],
                     client: SpotifyClient?) {
        guard ENUpdateSettings.isEnabled, let client else { return }
        loadIfNeeded()
        guard harvestTask == nil else { return }
        if let last = state.harvested[genre.key],
           Date().timeIntervalSince(last) < Self.revisitInterval { return }
        guard requestsRemainingToday > 0 else { return }

        if knownGenres.isEmpty {
            knownGenres = Set(genreIndex.map { Self.fold($0.name) })
        }
        let known = Set(localArtists.map { Self.fold($0.name) })
        harvestTask = Task { [weak self] in
            await self?.harvest(genre: genre, knownArtists: known, client: client)
            self?.harvestTask = nil
        }
    }

    private var requestsRemainingToday: Int {
        state.day == Self.today ? max(0, Self.dailyRequestCap - state.requestsToday) : Self.dailyRequestCap
    }

    private func harvest(genre: ENGenre, knownArtists: Set<String>, client: SpotifyClient) async {
        // Let the screen settle, and keep a floor under the request spacing.
        var wait = Self.settleDelay
        if let lastRequest {
            wait = max(wait, Self.minRequestInterval - Date().timeIntervalSince(lastRequest))
        }
        try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
        guard !Task.isCancelled, ENUpdateSettings.isEnabled else { return }

        // Sending into a recorded rate-limit window is what makes Spotify
        // *extend* it, and this request is the least urgent one the app ever
        // makes — so it is dropped, not queued.
        let cooldown = await SpotifyRateLimiter.shared.remainingCooldown(for: client.clientID)
        guard cooldown <= 0 else {
            appLog("Every Noise update: skipped \"\(genre.name)\" — \(Int(cooldown.rounded()))s left of the Spotify rate-limit window.",
                   level: .debug, category: "Browse")
            return
        }

        isHarvesting = true
        defer { isHarvesting = false }
        noteRequest()

        let hits: [SpotifyArtistHit]
        do {
            hits = try await client.searchArtists(genre: genre.name, limit: Self.pageSize)
            lastError = nil
        } catch {
            if isCancellation(error) { return }
            lastError = error.localizedDescription
            appLog("Every Noise update: \"\(genre.name)\" failed — \(error.localizedDescription)",
                   level: .warning, category: "Browse")
            return
        }

        // Mark the genre done whatever came back: an empty answer is an
        // answer, and re-asking it every visit would be the one way this
        // could turn into a request loop.
        state.harvested[genre.key] = Date()

        var fresh: [ENUpdateRecord] = []
        for hit in hits {
            let folded = Self.fold(hit.name)
            let key = "\(genre.key)|\(folded)"
            guard !knownArtists.contains(folded), !recorded.contains(key) else { continue }
            recorded.insert(key)
            fresh.append(ENUpdateRecord(genreKey: genre.key,
                                        genreName: genre.name,
                                        artist: hit.name,
                                        spotifyID: hit.id,
                                        popularity: hit.popularity,
                                        imageURL: hit.imageURL,
                                        genres: hit.genres,
                                        seen: Date()))
            for label in hit.genres where !knownGenres.contains(Self.fold(label)) {
                state.newGenres.insert(label)
            }
        }

        if !fresh.isEmpty {
            append(fresh)
            state.records += fresh.count
        }
        saveState()
        publishCounts()
        appLog("Every Noise update: \"\(genre.name)\" — \(hits.count) artist(s) live, \(fresh.count) new to the map.",
               level: fresh.isEmpty ? .debug : .info, category: "Browse")
    }

    private func noteRequest() {
        if state.day != Self.today {
            state.day = Self.today
            state.requestsToday = 0
        }
        state.requestsToday += 1
        lastRequest = Date()
    }

    /// Appends records as JSONL. Append-only by design: the file is written a
    /// handful of lines at a time across weeks of browsing, and rewriting it
    /// wholesale each visit would be both slower and less crash-safe.
    private func append(_ records: [ENUpdateRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var blob = Data()
        for record in records {
            guard let line = try? encoder.encode(record) else { continue }
            blob.append(line)
            blob.append(0x0A)
        }
        guard !blob.isEmpty else { return }
        let url = AppPaths.everyNoiseUpdatesFile
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: blob)
        } else {
            try? blob.write(to: url, options: .atomic)
        }
    }

    /// Throws away everything collected — after an export has been merged
    /// into the dataset, the records are just history.
    func clear() {
        harvestTask?.cancel()
        harvestTask = nil
        try? FileManager.default.removeItem(at: AppPaths.everyNoiseUpdatesFile)
        try? FileManager.default.removeItem(at: AppPaths.everyNoiseUpdatesState)
        state = HarvestState()
        recorded = []
        stateLoaded = true
        lastError = nil
        publishCounts()
        appLog("Every Noise updates cleared.", category: "Browse")
    }

    /// Loads the counts for the Settings screen without waiting for a harvest.
    func refreshCounts() {
        loadIfNeeded()
        publishCounts()
    }

    // MARK: Helpers

    /// The same folding the artist index uses, so "Beyoncé" and "beyonce" are
    /// one artist when comparing the live catalogue against a shard.
    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var today: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    /// Rebuilds the "already recorded" set from the file — one pass, only
    /// decoding the two fields the key needs.
    private static func recordedKeys(in url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var keys: Set<String> = []
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let record = try? decoder.decode(ENUpdateRecord.self, from: lineData) else { continue }
            keys.insert("\(record.genreKey)|\(fold(record.artist))")
        }
        return keys
    }
}
