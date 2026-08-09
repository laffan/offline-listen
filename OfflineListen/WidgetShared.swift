import Foundation

/// The wire format between the app and the home-screen widget, compiled into
/// **both** targets so encode and decode can't drift — the same trick
/// `WatchManifest.swift` uses for the watch and `SharedInbox.swift` for the
/// Share Extension.
///
/// A widget extension is its own process with its own container: it can't read
/// `Documents/`, so it can't open `everynoise-history.json` or `recents.json`
/// (nor should it — decoding a 200-entry log and a whole library to draw four
/// rows is work a widget doesn't have the budget for). The app instead leaves a
/// tiny pre-resolved snapshot in the **App Group** container whenever either
/// log changes, and the widget only ever reads that.
///
/// Everything in here is `Codable` and free of app types on purpose: the widget
/// links none of the app's stores.

// MARK: - Rows

/// One genre the user opened in Browse.
struct WidgetGenreEntry: Codable, Hashable, Identifiable {
    /// The genre's shard key — what the deep link carries back so the browser
    /// can find it in the index without a name match.
    let key: String
    let name: String
    /// The genre's own map colour, `#rrggbb`, so a widget row reads like the
    /// place it came from rather than like plain text.
    let colorHex: String

    var id: String { key }
}

/// One song the user played.
struct WidgetSongEntry: Codable, Hashable, Identifiable {
    let trackID: UUID
    let title: String
    /// Empty when the track has no artist (never AI-organized, no catalogue
    /// metadata) — the widget just drops the line.
    let artist: String

    var id: UUID { trackID }
}

// MARK: - Snapshot

/// What the widget draws: the last couple of genres opened in Browse and the
/// last couple of songs played, newest first. Both halves are written
/// independently (they come from different stores), so the snapshot is always
/// read-modify-written rather than replaced wholesale.
struct WidgetSnapshot: Codable, Hashable {
    var genres: [WidgetGenreEntry] = []
    var songs: [WidgetSongEntry] = []

    static let empty = WidgetSnapshot()

    /// How many of each the widget shows — and how many the app bothers to
    /// write. Two of each is the whole design: enough to be a shortcut, few
    /// enough to stay legible at the small size.
    static let rowLimit = 2
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
    /// Open the Every Noise browser on this genre.
    case genre(key: String)
    /// Start playing this track.
    case track(id: UUID)

    /// Matches `CFBundleURLSchemes` in the app's Info.plist.
    static let scheme = "offlinelisten"

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .genre(let key):
            components.host = "genre"
            components.queryItems = [URLQueryItem(name: "key", value: key)]
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
        let value = { (name: String) in
            components.queryItems?.first(where: { $0.name == name })?.value
        }
        switch components.host {
        case "genre":
            guard let key = value("key"), !key.isEmpty else { return nil }
            self = .genre(key: key)
        case "track":
            guard let raw = value("id"), let id = UUID(uuidString: raw) else { return nil }
            self = .track(id: id)
        default:
            return nil
        }
    }
}
