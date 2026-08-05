import Foundation
import AVFoundation

/// The Every Noise at Once dataset the app bundles (`EveryNoiseData/`, written
/// by `tools/everynoise/scrape.py`) and the stores that read it.
///
/// The dataset is big — 6,291 genres, ~630k artist rows — and the browser has
/// to stay smooth on modest hardware, so nothing is ever loaded wholesale:
/// the genre **index** (`genres.json`, ~1.4 MB) is read
/// once, off the main thread, the first time the browser opens; each genre's
/// **artist shard** (`genres/<key>.z`, raw DEFLATE) is inflated only when that
/// genre is opened, and a small LRU keeps recently opened genres warm so
/// backing out and tapping again costs nothing.

// MARK: - Models

/// One genre on the map: its position/color/size are the site's own layout
/// (nearby genres really do sound alike — that's the "rough relation" the map
/// preserves), `preview` is the 30-second example-track MP3 the site embeds.
struct ENGenre: Codable, Hashable, Identifiable {
    let name: String
    /// The site's page slug — the shard filename and the stable id.
    let key: String
    let x: Int
    let y: Int
    let color: String
    /// Font-size percent from the site (its popularity cue), 100 = normal.
    let size: Int
    let preview: String?
    /// The example track behind `preview`, e.g. `Artist "Song"`.
    let example: String?

    var id: String { key }

    /// Who the example track is by — everything ahead of the quoted song.
    /// A genre's preview is one artist's record, so this is the artist Scan is
    /// actually playing, and the one its "+" opens. Name only: the site never
    /// carried a Spotify id at this level, which is why resolving it takes a
    /// search.
    var exampleArtist: String? {
        guard let example, let quote = example.firstIndex(of: "\"") else { return nil }
        let name = example[..<quote].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}

/// One artist inside a genre, positioned on that genre's own map.
struct ENArtist: Codable, Hashable, Identifiable {
    let name: String
    let x: Int
    let y: Int
    let color: String
    let size: Int
    /// 30-second top-track preview MP3 (Spotify's CDN), straight from the
    /// scraped page — no API key involved.
    let preview: String?
    /// What the site calls the track behind `preview`: `Artist "Song"`, out of
    /// the row's `title` attribute — the same field a genre carries.
    ///
    /// Nil on rows from a scrape predating it being kept (the tool parsed it
    /// and dropped it on the way to the shard), and on **harvested** rows,
    /// which have no snippet to name: Spotify serves neither a preview URL nor
    /// its title to apps registered after November 2024, which is why the site
    /// is the only source for either.
    let example: String?
    /// Spotify artist id, when the page carried one.
    let spotify: String?
    /// True for a row the app **harvested** from Spotify rather than one the
    /// bundled scrape carried (see `ENUpdateStore`). No shard has this key, so
    /// everything from the dataset decodes `nil`. Two things follow from it,
    /// and they say the same thing — the map doesn't really know where this
    /// artist goes yet: the position is arbitrary (hashed into the genre's
    /// existing spread), and the popularity order puts them last.
    let harvested: Bool?

    var isHarvested: Bool { harvested == true }

    init(name: String, x: Int, y: Int, color: String, size: Int,
         preview: String? = nil, example: String? = nil,
         spotify: String? = nil, harvested: Bool? = nil) {
        self.name = name
        self.x = x
        self.y = y
        self.color = color
        self.size = size
        self.preview = preview
        self.example = example
        self.spotify = spotify
        self.harvested = harvested
    }

    /// Just the song out of `example`. The row it sits under already names the
    /// artist, so repeating that reads as noise — what's wanted is the title of
    /// the thing actually playing. (A *genre* shows the whole string, because
    /// there whose track it is is the interesting half.)
    var exampleTrack: String? {
        guard let example else { return nil }
        // The site writes `Artist "Song"`. Taking the outermost pair of quotes
        // rather than the first keeps a song with quotes of its own intact.
        if let open = example.firstIndex(of: "\""),
           let close = example.lastIndex(of: "\""), open < close {
            let song = example[example.index(after: open)..<close]
                .trimmingCharacters(in: .whitespaces)
            // A quoted row has said its piece either way — empty quotes mean
            // there is no title, not that the label should go up raw.
            return song.isEmpty ? nil : song
        }
        // Unquoted, so there's no song to separate out. Anything that isn't
        // just the artist's name over again is still worth showing.
        let whole = example.trimmingCharacters(in: .whitespaces)
        guard !whole.isEmpty, whole.caseInsensitiveCompare(name) != .orderedSame else { return nil }
        return whole
    }

    /// Shard rows have no ids of their own; position disambiguates the rare
    /// same-name collision within one genre.
    var id: String { "\(name)|\(x)|\(y)" }
}

/// A genre shard: the decoded `genres/<key>.z`.
private struct ENShard: Codable {
    let name: String
    let artists: [ENArtist]
}

/// What a history row points back to.
enum ENVisitKind: String, Codable {
    case genre
    case artist
    /// An artist reached through the Find field's **Spotify** mode rather than
    /// through the map — they may not be on it at all. Their row carries a
    /// Spotify id where a mapped artist carries a shard id, and no genre to
    /// lead back to, so it re-opens straight into the discography.
    case spotify
}

/// One "you opened this" record — a tapped genre, or a tapped artist (kept
/// with the genre it was tapped in, so the row can lead back there). Like the
/// Library's Recent, history is a **log, not a set**: revisits re-append,
/// with only consecutive repeats collapsed.
struct ENHistoryEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let kind: ENVisitKind
    /// The genre's key — for an artist, the genre they were tapped inside.
    let genreKey: String
    /// The artist's id within that genre's shard; nil for a genre visit.
    let artistID: String?
    let name: String
    let color: String
    /// For an artist row: the containing genre's display name.
    let detail: String?
    var date: Date

    init(kind: ENVisitKind, genreKey: String, artistID: String? = nil,
         name: String, color: String, detail: String? = nil, date: Date = Date()) {
        self.id = UUID()
        self.kind = kind
        self.genreKey = genreKey
        self.artistID = artistID
        self.name = name
        self.color = color
        self.detail = detail
        self.date = date
    }
}

extension AppPaths {
    static var everyNoiseHistory: URL {
        documents.appendingPathComponent("everynoise-history.json")
    }
}

// MARK: - Store

/// Loads the bundled dataset lazily and caches decoded shards (LRU).
@MainActor
final class EveryNoiseStore: ObservableObject {
    enum State {
        case idle
        case loading
        /// Loaded and non-empty.
        case ready
        /// The bundle carries no dataset (placeholder before the one-time
        /// scrape has been run and committed).
        case missing
    }

    @Published private(set) var state: State = .idle
    /// The full genre index in the site's map order — also the scan order.
    @Published private(set) var genres: [ENGenre] = []
    /// The visit log behind the History mode, newest first. Persisted to
    /// `Documents/everynoise-history.json`, capped like the Library's Recent.
    @Published private(set) var history: [ENHistoryEntry] = []

    private var historyLoaded = false
    private static let maxHistory = 200

    /// Decoded shards, newest-used last (a tiny LRU: each shard is a few
    /// hundred KB decoded, and a dozen covers any realistic backtracking).
    private var shardCache: [(key: String, artists: [ENArtist])] = []
    private let shardCacheLimit = 12

    static let subdirectory = "EveryNoiseData"

    /// Reads the genre index once, off the main thread.
    func loadIfNeeded() {
        guard state == .idle else { return }
        state = .loading
        loadHistoryIfNeeded()
        Task.detached(priority: .userInitiated) {
            let loaded: [ENGenre]
            if let url = Bundle.main.url(forResource: "genres", withExtension: "json",
                                         subdirectory: Self.subdirectory),
               let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode([ENGenre].self, from: data) {
                loaded = decoded
            } else {
                loaded = []
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.genres = loaded
                self.state = loaded.isEmpty ? .missing : .ready
                if !loaded.isEmpty {
                    appLog("Every Noise: loaded \(loaded.count) genres", category: "Browse")
                }
            }
        }
    }

    /// The artists of one genre — from the LRU when warm, otherwise inflated
    /// off the main thread. Returns an empty list when the shard is absent
    /// (a partial scrape); the genre view says so rather than erroring.
    func artists(for genre: ENGenre) async -> [ENArtist] {
        if let index = shardCache.firstIndex(where: { $0.key == genre.key }) {
            let entry = shardCache.remove(at: index)
            shardCache.append(entry)
            return entry.artists
        }
        let key = genre.key
        let artists: [ENArtist] = await Task.detached(priority: .userInitiated) {
            guard let url = Bundle.main.url(forResource: key, withExtension: "z",
                                            subdirectory: "\(Self.subdirectory)/genres"),
                  let packed = try? Data(contentsOf: url),
                  let raw = try? (packed as NSData).decompressed(using: .zlib) as Data,
                  let shard = try? JSONDecoder().decode(ENShard.self, from: raw) else {
                return []
            }
            return shard.artists
        }.value
        shardCache.append((key, artists))
        if shardCache.count > shardCacheLimit {
            shardCache.removeFirst(shardCache.count - shardCacheLimit)
        }
        return artists
    }

    // MARK: History

    func recordVisit(genre: ENGenre) {
        record(ENHistoryEntry(kind: .genre, genreKey: genre.key,
                              name: genre.name, color: genre.color))
    }

    func recordVisit(artist: ENArtist, in genre: ENGenre) {
        record(ENHistoryEntry(kind: .artist, genreKey: genre.key, artistID: artist.id,
                              name: artist.name, color: artist.color, detail: genre.name))
    }

    /// A hit from the Find field's Spotify mode. `artistID` is a **Spotify**
    /// id here, and there's no genre behind it — the row re-opens the
    /// discography directly rather than a place on the map.
    func recordVisit(spotifyArtist name: String, id: String, detail: String?) {
        record(ENHistoryEntry(kind: .spotify, genreKey: "", artistID: id,
                              name: name, color: "", detail: detail))
    }

    func removeHistory(_ entry: ENHistoryEntry) {
        history.removeAll { $0.id == entry.id }
        saveHistory()
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    /// Appends a visit, collapsing a consecutive repeat (re-tapping what's
    /// already on top updates its time instead of stuttering the log).
    private func record(_ entry: ENHistoryEntry) {
        loadHistoryIfNeeded()
        if let top = history.first, top.kind == entry.kind,
           top.genreKey == entry.genreKey, top.artistID == entry.artistID {
            history[0].date = entry.date
        } else {
            history.insert(entry, at: 0)
            if history.count > Self.maxHistory {
                history.removeLast(history.count - Self.maxHistory)
            }
        }
        saveHistory()
    }

    private func loadHistoryIfNeeded() {
        guard !historyLoaded else { return }
        historyLoaded = true
        guard let data = try? Data(contentsOf: AppPaths.everyNoiseHistory),
              let decoded = try? JSONDecoder().decode([ENHistoryEntry].self, from: data) else { return }
        history = decoded
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: AppPaths.everyNoiseHistory, options: .atomic)
    }
}

// MARK: - Global artist search

/// One hit from the global artist search: enough to open the artist's home
/// genre with them selected there (`ENGenreView.initialArtistID` matches the
/// shard row's `name|x|y` id).
struct ENArtistHit: Identifiable, Hashable {
    let name: String
    let genreKey: String
    let x: Int
    let y: Int
    let color: String

    /// The artist's id within their genre's shard.
    var artistID: String { "\(name)|\(x)|\(y)" }
    var id: String { "\(genreKey)|\(name)|\(x)|\(y)" }
}

/// Searches every artist in the dataset by name — the Find field's artist
/// mode. ~470k unique names is far too many to decode into Swift values per
/// keystroke, so the search never parses the index at all: the bundled
/// `artists.idx.z` (derived from the shards by
/// `tools/everynoise/build_artist_index.py`) inflates once into a cache file
/// that is **memory-mapped** and scanned as raw bytes. Each record line leads
/// with a pre-folded copy of the name; the query is folded the same way
/// (case/diacritic/width), so matching is a plain byte search across the blob
/// — no per-row allocation, and only the pages a scan touches ever become
/// resident. Lines are ordered by the site's popularity cue, so the first N
/// matches are automatically the most popular artists matching.
actor ENArtistIndex {
    static let shared = ENArtistIndex()

    private var blob: Data?
    private var unavailable = false

    /// The most popular `limit` artists whose folded name contains `query`.
    func search(_ query: String, limit: Int = 25) -> [ENArtistHit] {
        guard let blob = loadIfNeeded() else { return [] }
        let folded = query.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                   locale: nil)
        guard let needle = folded.data(using: .utf8), !needle.isEmpty else { return [] }

        let newline = UInt8(ascii: "\n")
        var hits: [ENArtistHit] = []
        var cursor = blob.startIndex
        while hits.count < limit, cursor < blob.endIndex,
              let match = blob.range(of: needle, in: cursor..<blob.endIndex) {
            // Expand the raw hit to its record line.
            var lineStart = match.lowerBound
            while lineStart > blob.startIndex, blob[lineStart - 1] != newline {
                lineStart -= 1
            }
            var lineEnd = match.upperBound
            while lineEnd < blob.endIndex, blob[lineEnd] != newline {
                lineEnd += 1
            }
            cursor = min(blob.endIndex, lineEnd + 1)

            guard let line = String(data: blob.subdata(in: lineStart..<lineEnd), encoding: .utf8) else {
                continue
            }
            let fields = line.components(separatedBy: "\u{1f}")
            // fields: folded, display, genreKey, x, y, color. Only a hit
            // inside the *folded-name* field (the first) counts — the needle
            // can also occur in the display name or the genre key.
            guard fields.count == 6,
                  match.upperBound - lineStart <= fields[0].utf8.count,
                  let x = Int(fields[3]), let y = Int(fields[4]) else { continue }
            hits.append(ENArtistHit(name: fields[1], genreKey: fields[2],
                                    x: x, y: y, color: fields[5]))
        }
        return hits
    }

    /// The inflated index, memory-mapped. First use inflates the bundled
    /// `.z` into Caches (keyed by the packed size, so a rebuilt dataset can't
    /// serve a stale cache); every use after that maps the cache file.
    private func loadIfNeeded() -> Data? {
        if let blob { return blob }
        if unavailable { return nil }
        guard let packedURL = Bundle.main.url(forResource: "artists.idx", withExtension: "z",
                                              subdirectory: EveryNoiseStore.subdirectory) else {
            unavailable = true
            appLog("Every Noise: no artist index in the bundle — run tools/everynoise/build_artist_index.py and rebuild.",
                   level: .warning, category: "Browse")
            return nil
        }
        do {
            let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
            let packedSize = (try packedURL.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            let cacheURL = caches.appendingPathComponent("everynoise-artists-\(packedSize).idx")
            if !FileManager.default.fileExists(atPath: cacheURL.path) {
                let packed = try Data(contentsOf: packedURL)
                let raw = try (packed as NSData).decompressed(using: .zlib) as Data
                try raw.write(to: cacheURL, options: .atomic)
                appLog("Every Noise: artist index inflated (\(raw.count / 1_000_000) MB).",
                       level: .debug, category: "Browse")
            }
            let mapped = try Data(contentsOf: cacheURL, options: .mappedIfSafe)
            blob = mapped
            return mapped
        } catch {
            unavailable = true
            appLog("Every Noise: couldn't load the artist index (\(error.localizedDescription)).",
                   level: .warning, category: "Browse")
            return nil
        }
    }
}

// MARK: - Preview player

/// Plays the 30-second preview snippets (genre examples, artist top tracks).
/// Deliberately tiny — an `AVPlayer` straight onto the CDN URL — and separate
/// from the app's `PlaybackManager`, which it pauses so they don't talk over
/// each other (the same courtesy the Browse preview modal extends).
@MainActor
final class ENPreviewPlayer: ObservableObject {
    /// The id of the item whose preview is loaded (a genre key or artist id) —
    /// what the UI highlights.
    @Published private(set) var currentID: String?
    @Published private(set) var isPlaying = false
    /// Flipped while the stream is still buffering, so a tapped row can show
    /// a spinner rather than nothing.
    @Published private(set) var isLoading = false

    /// Called when a preview plays to its end — scan mode's advance signal.
    var onFinished: (() -> Void)?

    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?

    /// Starts `urlString` for item `id`, replacing whatever was playing.
    func play(_ urlString: String, id: String, mainPlayback: PlaybackManager) {
        guard let url = URL(string: urlString) else { return }
        stop()

        // Don't talk over the main player.
        if mainPlayback.isPlaying {
            mainPlayback.togglePlayPause()
        }

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        currentID = id
        isLoading = true
        isPlaying = true

        statusObservation = item.observe(\.status) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.player?.currentItem === item else { return }
                switch item.status {
                case .readyToPlay:
                    self.isLoading = false
                case .failed:
                    appLog("Every Noise: preview failed (\(item.error?.localizedDescription ?? "unknown"))",
                           level: .warning, category: "Browse")
                    self.isLoading = false
                    self.isPlaying = false
                    // A dead URL shouldn't stall a scan — treat it as finished.
                    self.onFinished?()
                default:
                    break
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = false
                self.onFinished?()
            }
        }

        AudioSession.activate()
        player.play()
    }

    /// Play/pause for the currently loaded preview.
    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            AudioSession.activate()
            player.play()
        }
        isPlaying.toggle()
    }

    func stop() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        player?.pause()
        player = nil
        currentID = nil
        isPlaying = false
        isLoading = false
    }
}
