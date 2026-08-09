import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// The app's half of the widget contract: keeps the App Group snapshot in step
/// with the two logs the widget draws from, and nudges WidgetKit when it
/// changes.
///
/// The two halves are published separately because they come from separate
/// stores — songs from `LibraryStore`'s listening log, genres from
/// `EveryNoiseStore`'s visit log, which isn't even loaded until the browser is
/// opened. Each writer reads the current snapshot, replaces its own half and
/// writes it back, so neither can clobber the other's rows.
@MainActor
enum WidgetBridge {
    /// The last couple of *distinct* songs played. Repeats are collapsed the
    /// way `recentTracks` collapses them: the Recent log is a log, so a track
    /// you keep coming back to appears in it repeatedly, and two widget rows
    /// naming the same song would be a wasted row.
    static func publishSongs(from library: LibraryStore) {
        let songs = library.recentTracks.prefix(WidgetSnapshot.rowLimit).map {
            WidgetSongEntry(trackID: $0.id, title: $0.title, artist: $0.artist)
        }
        var snapshot = WidgetSnapshotStore.read()
        snapshot.songs = songs
        reloadIfChanged(snapshot)
    }

    /// The last couple of *distinct* genres opened. History collapses only
    /// consecutive repeats, so hopping between two genres would otherwise fill
    /// both rows with the same one.
    static func publishGenres(from history: [ENHistoryEntry]) {
        var seen = Set<String>()
        var genres: [WidgetGenreEntry] = []
        for entry in history where entry.kind == .genre {
            guard seen.insert(entry.genreKey).inserted else { continue }
            genres.append(WidgetGenreEntry(key: entry.genreKey,
                                           name: entry.name,
                                           colorHex: entry.color))
            if genres.count == WidgetSnapshot.rowLimit { break }
        }
        var snapshot = WidgetSnapshotStore.read()
        snapshot.genres = genres
        reloadIfChanged(snapshot)
    }

    /// Reads the visit log straight off disk. The browser's store loads it
    /// lazily — nothing touches `everynoise-history.json` until the Browse tab
    /// is opened — so without this a launch that never got there would leave
    /// the widget's genre rows on whatever the last session wrote, forever.
    static func publishGenresFromHistory() {
        guard let data = try? Data(contentsOf: AppPaths.everyNoiseHistory),
              let history = try? JSONDecoder().decode([ENHistoryEntry].self, from: data) else {
            return
        }
        publishGenres(from: history)
    }

    /// Writes, and reloads the widget only when the file actually changed —
    /// the publishers are called from save paths that fire far more often than
    /// the top two rows change, and WidgetKit meters reloads.
    private static func reloadIfChanged(_ snapshot: WidgetSnapshot) {
        guard WidgetSnapshotStore.write(snapshot) else { return }
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotStore.kind)
        #endif
    }
}

/// Where a tapped widget row wants the app to go. The link is parsed here and
/// parked; `RootView` picks the tab and starts the track, and the Every Noise
/// browser picks up the genre once its index is loaded.
///
/// It's a two-step because neither destination is reachable synchronously from
/// `onOpenURL`: a cold launch hasn't selected the Browse tab yet, and the genre
/// index is read off the main thread after the browser appears.
@MainActor
final class AppRouter: ObservableObject {
    /// A genre the browser should open, cleared by it once pushed.
    @Published var pendingGenreKey: String?
    /// A track to start playing, cleared by `RootView` once it has.
    @Published var pendingTrackID: UUID?

    /// Returns false for a URL that isn't a widget link, so the caller can fall
    /// through to its usual handling (the Share Extension's
    /// `offlinelisten://import`).
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard let link = WidgetDeepLink(url: url) else { return false }
        switch link {
        case .genre(let key):
            pendingGenreKey = key
            appLog("Widget opened genre \(key)", category: "Widget")
        case .track(let id):
            pendingTrackID = id
            appLog("Widget opened track \(id)", category: "Widget")
        }
        return true
    }
}
