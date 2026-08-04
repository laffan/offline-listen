import Foundation
import CryptoKit

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
        everyNoiseUpdates.appendingPathComponent(everyNoiseUpdatesFileName)
    }

    /// Harvest bookkeeping (which genres, how many requests today).
    static var everyNoiseUpdatesState: URL {
        everyNoiseUpdates.appendingPathComponent("state.json")
    }

    /// The record file's name, reused for the copy kept in the sync folder.
    static let everyNoiseUpdatesFileName = "everynoise-updates.jsonl"
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
    /// Bumped whenever the harvest records something new. A genre on screen
    /// reads it through `merged(_:genre:)`, which is what puts freshly found
    /// artists on the map **as they arrive** rather than at the next rebuild
    /// of the bundled dataset.
    @Published private(set) var harvestVersion = 0

    var hasRecords: Bool { recordCount > 0 }

    /// Hands the accumulated record file to whoever mirrors app data into the
    /// sync folder — wired to `LocalSyncStore` in the app entry, and left nil
    /// on a build (or a device) with no sync configured.
    var syncMirror: ((Data) -> Void)?

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
    /// The same records grouped by the genre they were found under — what
    /// `merged(_:genre:)` draws from.
    private var byGenre: [String: [ENUpdateRecord]] = [:]
    /// Memoized `ENArtist` renderings per genre, tagged with the harvest
    /// version they were built at. `merged` is called from a view body, and
    /// finding a genre's spread means walking a shard that can hold thousands
    /// of artists — not something to redo on every redraw.
    private var renderCache: [String: (version: Int, artists: [ENArtist])] = [:]
    /// The bundled genre index, folded — memoized on first harvest.
    private var knownGenres: Set<String> = []

    // MARK: Lifecycle

    /// Reads the bookkeeping (and the records themselves) once, lazily — the
    /// feature costs nothing at all until it's used. Deliberately publishes
    /// nothing: `merged(_:genre:)` calls this from a view body, where changing
    /// an `@Published` mid-update is exactly the thing SwiftUI complains
    /// about. Callers that want the Settings counts refreshed say so.
    private func loadIfNeeded() {
        guard !stateLoaded else { return }
        stateLoaded = true
        if let data = try? Data(contentsOf: AppPaths.everyNoiseUpdatesState),
           let decoded = try? JSONDecoder().decode(HarvestState.self, from: data) {
            state = decoded
        }
        for record in Self.loadRecords(in: AppPaths.everyNoiseUpdatesFile) {
            recorded.insert("\(record.genreKey)|\(Self.fold(record.artist))")
            byGenre[record.genreKey, default: []].append(record)
        }
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
        publishCounts()
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
        var seenThisPass: Set<String> = []
        for hit in hits {
            let folded = Self.fold(hit.name)
            let key = "\(genre.key)|\(folded)"
            guard !knownArtists.contains(folded), !recorded.contains(key),
                  seenThisPass.insert(folded).inserted else { continue }
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
            byGenre[genre.key, default: []].append(contentsOf: fresh)
            // The genre whose map is very likely still on screen: bumping the
            // version is what makes these artists appear on it now.
            harvestVersion += 1
            mirrorToSyncFolder()
        }
        saveState()
        publishCounts()
        appLog("Every Noise update: \"\(genre.name)\" — \(hits.count) artist(s) live, \(fresh.count) new to the map.",
               level: fresh.isEmpty ? .debug : .info, category: "Browse")
    }

    // MARK: Showing them straight away

    /// A genre's artists as the browser should draw them: the bundled shard,
    /// plus everything the harvest has since found under that label.
    ///
    /// The bundled dataset is only rebuilt when someone runs
    /// `merge_updates.py` against an export, which could be months after the
    /// app noticed an artist. Until then the finding sat in a file nobody
    /// could see. These rows are shown as what they are:
    ///
    /// - **Positioned at random.** The site's layout came from Spotify's
    ///   audio-feature API, withdrawn with everything else, so there is no
    ///   honest place to put a new artist. They're hashed deterministically
    ///   into the spread their genre's own artists occupy — among the right
    ///   company, not at a meaningful point within it — which is exactly what
    ///   the merge tool does, off the same seed, so an artist doesn't jump
    ///   when the dataset is eventually rebuilt.
    /// - **Assumed unpopular.** Nothing about a live catalogue hit says how
    ///   the frozen page would have sized it, so they're drawn at the small
    ///   end of the sizes the genre already uses and sorted last by
    ///   popularity, ordered among themselves by Spotify's own score.
    func merged(_ shardArtists: [ENArtist], genre: ENGenre) -> [ENArtist] {
        loadIfNeeded()
        guard let records = byGenre[genre.key], !records.isEmpty else { return shardArtists }
        if let cached = renderCache[genre.key], cached.version == harvestVersion {
            return cached.artists
        }
        let merged = shardArtists + Self.render(records, into: shardArtists, genre: genre)
        // A merged list is a whole shard's worth of artists; a handful of them
        // is plenty for backing out and tapping again, and the shard cache
        // behind it is bounded the same way.
        if renderCache.count >= 12 { renderCache.removeAll() }
        renderCache[genre.key] = (harvestVersion, merged)
        return merged
    }

    /// Builds the `ENArtist` rows for one genre's harvested records.
    private static func render(_ records: [ENUpdateRecord],
                               into shardArtists: [ENArtist],
                               genre: ENGenre) -> [ENArtist] {
        var present = Set(shardArtists.map { fold($0.name) })
        let box = spread(of: shardArtists)
        let sizes = sizeBand(of: shardArtists)
        var fresh: [ENArtist] = []
        for record in records {
            let name = record.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, present.insert(fold(name)).inserted else { continue }
            let seed = "\(genre.key)|\(name)"
            fresh.append(ENArtist(
                name: name,
                x: max(0, box.centerX - box.width / 2 + jitter(seed + "|x", span: box.width)),
                y: max(0, box.centerY - box.height / 2 + jitter(seed + "|y", span: box.height)),
                // Artists on a genre page share the genre's hue on the site;
                // a harvested row has no colour of its own to copy.
                color: genre.color,
                size: sizes.low + Int((Double(sizes.high - sizes.low)
                                       * Double(max(0, min(100, record.popularity))) / 100).rounded()),
                // Spotify serves no `preview_url` to apps created after
                // November 2024, so there is genuinely no snippet to play.
                preview: nil,
                spotify: record.spotifyID,
                harvested: true))
        }
        return fresh
    }

    /// The box a genre's existing artists occupy, with a floor under it: a
    /// genre holding one artist has *no* spread, and without the floor every
    /// addition would land on that one point in a stack of labels.
    private static func spread(of artists: [ENArtist]) -> (centerX: Int, centerY: Int, width: Int, height: Int) {
        let xs = artists.map(\.x)
        let ys = artists.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else {
            // An empty shard: the canvas a brand-new genre's map would use.
            return (1000, 700, 2000, 1400)
        }
        return ((minX + maxX) / 2, (minY + maxY) / 2,
                max(maxX - minX, minSpread), max(maxY - minY, minSpread))
    }

    /// The narrow band at the **bottom** of a genre's own sizes that harvested
    /// artists are drawn in — small enough to read as "we don't know", big
    /// enough to still be legible, because it's a size the genre already uses.
    private static func sizeBand(of artists: [ENArtist]) -> (low: Int, high: Int) {
        let sizes = artists.map(\.size)
        guard let low = sizes.min(), let high = sizes.max(), high > low else {
            return defaultSizeBand
        }
        return (low, low + max(1, (high - low) / 8))
    }

    /// A stable pseudo-random offset in `0..<span`, keyed on a name.
    ///
    /// SHA-1 over the seed's first four bytes, big-endian — the same thing
    /// `merge_updates.py`'s `jitter()` computes, so an artist the app placed
    /// lands in the same spot once the export is merged into the dataset.
    private static func jitter(_ seed: String, span: Int) -> Int {
        guard span > 0 else { return 0 }
        let digest = Insecure.SHA1.hash(data: Data(seed.utf8))
        let word = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return Int(word % UInt32(span))
    }

    /// The size range a shard falls back to when it has too few artists to
    /// imply one — the merge tool's `DEFAULT_SIZE_RANGE`, bottom band only.
    private static let defaultSizeBand = (low: 60, high: 72)
    /// The merge tool's `MIN_SPREAD`.
    private static let minSpread = 400

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

    // MARK: The copy in the sync folder

    /// Writes the record file into `OfflineListenData/` in the **first** sync
    /// folder, whenever it changes.
    ///
    /// The records are only useful off the device — `merge_updates.py` eats
    /// them — and until now the only way out was Settings ▸ Download New Data
    /// and a share sheet. A configured sync folder is already a two-way door
    /// to a computer, so the file simply lives there too, kept current. It's a
    /// copy, not a move: `Documents/` stays the original, and a sync folder
    /// that's unreachable (provider offline) just means the copy is stale
    /// until the next harvest.
    func mirrorToSyncFolder() {
        guard let syncMirror else { return }
        syncMirror((try? Data(contentsOf: AppPaths.everyNoiseUpdatesFile)) ?? Data())
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
        byGenre = [:]
        renderCache = [:]
        harvestVersion += 1
        stateLoaded = true
        lastError = nil
        publishCounts()
        // The sync folder's copy goes with it — leaving it there would offer
        // a merge of records the app no longer believes in.
        mirrorToSyncFolder()
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

    /// Reads the whole record file back — one pass, in the order written, so
    /// the dedup keys and the per-genre grouping both come out of it.
    private static func loadRecords(in url: URL) -> [ENUpdateRecord] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var records: [ENUpdateRecord] = []
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let record = try? decoder.decode(ENUpdateRecord.self, from: lineData) else { continue }
            records.append(record)
        }
        return records
    }
}
