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
    /// Spotify artist id, when the page carried one.
    let spotify: String?

    /// Shard rows have no ids of their own; position disambiguates the rare
    /// same-name collision within one genre.
    var id: String { "\(name)|\(x)|\(y)" }
}

/// A genre shard: the decoded `genres/<key>.z`.
private struct ENShard: Codable {
    let name: String
    let artists: [ENArtist]
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

    /// Decoded shards, newest-used last (a tiny LRU: each shard is a few
    /// hundred KB decoded, and a dozen covers any realistic backtracking).
    private var shardCache: [(key: String, artists: [ENArtist])] = []
    private let shardCacheLimit = 12

    static let subdirectory = "EveryNoiseData"

    /// Reads the genre index once, off the main thread.
    func loadIfNeeded() {
        guard state == .idle else { return }
        state = .loading
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

        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
    }

    /// Play/pause for the currently loaded preview.
    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            try? AVAudioSession.sharedInstance().setActive(true)
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
