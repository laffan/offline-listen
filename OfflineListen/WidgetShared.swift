import Foundation

/// The wire format between the app and the home-screen widget, compiled into
/// **both** targets so encode and decode can't drift — the same trick
/// `WatchManifest.swift` uses for the watch and `SharedInbox.swift` for the
/// Share Extension.
///
/// A widget extension is its own process with its own container: it can't read
/// `Documents/`, so it can't open `everynoise-history.json` or `recents.json`
/// (nor should it — decoding a 200-entry log and a whole library to draw a
/// handful of rows is work a widget doesn't have the budget for). The app
/// instead leaves a tiny pre-resolved snapshot in the **App Group** container
/// whenever either log changes, and the widget only ever reads that.
///
/// Everything in here is `Codable` and free of app types on purpose: the widget
/// links none of the app's stores.

// MARK: - Rows

/// One entry from the Every Noise browser's visit log — a genre you opened, or
/// an artist you tapped. Both kinds live in the same type because the widget's
/// **Both** option interleaves them into one list.
struct WidgetBrowseEntry: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, Hashable {
        case genre
        case artist
    }

    let kind: Kind
    /// The genre's shard key — for an artist, the genre they were tapped in.
    /// Empty for an artist reached through the Find field's Spotify mode, who
    /// may have no place on the map at all.
    let genreKey: String
    /// The artist's id within that genre's shard, or their **Spotify** id when
    /// `isSpotifyArtist`. Nil for a genre.
    let artistID: String?
    /// True when `artistID` is a Spotify id: the row re-opens the live
    /// discography, since there's nowhere on the map to send it back to.
    let isSpotifyArtist: Bool
    let name: String
    /// The map colour, `#rrggbb`, so a row reads like the place it came from.
    /// Empty for a Spotify artist — off the map, so no colour.
    let colorHex: String
    /// An artist's home genre, drawn as the row's second line where there's
    /// room for one. Nil for a genre.
    let detail: String?
    /// When it was opened. Only ever used for **ordering**: the sizes that show
    /// a single item show the most recent across both lists, and the **Both**
    /// option interleaves genres with artists by recency.
    let date: Date

    var id: String { "\(kind.rawValue)|\(genreKey)|\(artistID ?? "")" }

    /// Where tapping this row goes. Kept here rather than in the widget so the
    /// mapping from "what kind of visit was this" to "what link re-opens it"
    /// exists once.
    var target: WidgetDeepLink.BrowseTarget {
        guard kind == .artist, let artistID else { return .genre(key: genreKey) }
        return isSpotifyArtist
            ? .spotifyArtist(id: artistID, name: name)
            : .artist(genreKey: genreKey, artistID: artistID)
    }
}

/// One song you played.
struct WidgetSongEntry: Codable, Hashable, Identifiable {
    let trackID: UUID
    let title: String
    /// Empty when the track has no artist (never AI-organized, no catalogue
    /// metadata) — the widget just drops the line.
    let artist: String
    /// When it was played, for the same ordering job the browse entries' date
    /// does.
    let date: Date

    var id: UUID { trackID }
}

// MARK: - Snapshot

/// What the widget draws: the genres and artists last opened in Browse, and the
/// songs last played, newest first within each list. The three lists are
/// written in two independent passes (they come from different stores), so the
/// snapshot is always read-modify-written rather than replaced wholesale.
struct WidgetSnapshot: Codable, Hashable {
    var genres: [WidgetBrowseEntry] = []
    var artists: [WidgetBrowseEntry] = []
    var songs: [WidgetSongEntry] = []

    static let empty = WidgetSnapshot()

    /// How many of each the app stores. The largest family shows four, and the
    /// **Both** option merges two four-deep lists down to four — so four of
    /// each is exactly enough for every size at every setting, and storing
    /// genres and artists *separately* is what keeps "show me artists" from
    /// coming up empty after a run of genre visits.
    static let storedRows = 4
}

// MARK: - Storage

/// Reads and writes the snapshot in the App Group container. Both sides go
/// through here; the widget only ever calls `read()`.
enum WidgetSnapshotStore {
    /// The widget's kind identifier, shared so the app can reload exactly this
    /// widget's timelines rather than everything.
    static let kind = "OfflineListenRecents"

    private static let fileName = "widget-snapshot.json"

    /// Nil when the App Group isn't provisioned (it has to be enabled on every
    /// target in Xcode — see the README). Everything here then no-ops, so a
    /// misconfigured group costs an empty widget rather than a crash.
    static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SharedInbox.appGroup)?
            .appendingPathComponent(fileName)
    }

    /// A snapshot written by an older build decodes to `.empty` rather than
    /// throwing its way out — and the app republishes both halves at launch, so
    /// a format change costs one cold start, not a stuck widget.
    static func read() -> WidgetSnapshot {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else {
            return .empty
        }
        return snapshot
    }

    /// Writes the snapshot, returning whether anything actually changed — the
    /// app uses that to skip a pointless widget reload.
    @discardableResult
    static func write(_ snapshot: WidgetSnapshot) -> Bool {
        guard let fileURL, read() != snapshot else { return false }
        guard let data = try? JSONEncoder().encode(snapshot) else { return false }
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Deep links

/// The `offlinelisten://` links a widget row opens the app with. Built by the
/// widget and parsed by the app, so both sides are defined here together.
enum WidgetDeepLink: Hashable {
    /// Somewhere in the Every Noise browser.
    case browse(BrowseTarget)
    /// Start playing this track.
    case track(id: UUID)

    /// The three shapes a browse row can re-open, mirroring what the browser's
    /// own History rows do: a genre's artist map, an artist selected on that
    /// map, or — for one reached through Spotify, with no place on the map —
    /// their live discography.
    enum BrowseTarget: Hashable {
        case genre(key: String)
        case artist(genreKey: String, artistID: String)
        case spotifyArtist(id: String, name: String)
    }

    /// Matches `CFBundleURLSchemes` in the app's Info.plist.
    static let scheme = "offlinelisten"

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .browse(.genre(let key)):
            components.host = "genre"
            components.queryItems = [URLQueryItem(name: "key", value: key)]
        case .browse(.artist(let genreKey, let artistID)):
            components.host = "artist"
            components.queryItems = [URLQueryItem(name: "genre", value: genreKey),
                                     URLQueryItem(name: "id", value: artistID)]
        case .browse(.spotifyArtist(let id, let name)):
            components.host = "artist"
            components.queryItems = [URLQueryItem(name: "spotify", value: id),
                                     URLQueryItem(name: "name", value: name)]
        case .track(let id):
            components.host = "track"
            components.queryItems = [URLQueryItem(name: "id", value: id.uuidString)]
        }
        // The components are ours and always well-formed; the fallback keeps
        // the widget's `Link` non-optional rather than adding a branch to
        // every row.
        return components.url ?? URL(string: "\(Self.scheme)://")!
    }

    /// Nil for anything that isn't one of ours — notably `offlinelisten://import`,
    /// which is the Share Extension bringing the app forward and must keep
    /// falling through to the shared-inbox drain.
    init?(url: URL) {
        guard url.scheme == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        func value(_ name: String) -> String? {
            let found = components.queryItems?.first(where: { $0.name == name })?.value
            return (found?.isEmpty ?? true) ? nil : found
        }
        switch components.host {
        case "genre":
            guard let key = value("key") else { return nil }
            self = .browse(.genre(key: key))
        case "artist":
            if let spotifyID = value("spotify") {
                self = .browse(.spotifyArtist(id: spotifyID, name: value("name") ?? ""))
            } else if let genreKey = value("genre"), let artistID = value("id") {
                self = .browse(.artist(genreKey: genreKey, artistID: artistID))
            } else {
                return nil
            }
        case "track":
            guard let raw = value("id"), let id = UUID(uuidString: raw) else { return nil }
            self = .track(id: id)
        default:
            return nil
        }
    }
}
