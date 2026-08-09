import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// The app's half of the widget contract: keeps the App Group snapshot in step
/// with the two logs the widget draws from, and nudges WidgetKit when it
/// changes.
///
/// The browse and song halves are written separately because they come from
/// separate stores — songs from `LibraryStore`'s listening log, genres and
/// artists from `EveryNoiseStore`'s visit log, which isn't even loaded until
/// the browser is opened. Each writer reads the current snapshot, replaces its
/// own half and writes it back, so neither can clobber the other's rows.
@MainActor
enum WidgetBridge {
    /// The last few *distinct* songs played. Repeats are collapsed the way
    /// `recentTracks` collapses them: the Recent log is a log, so a track you
    /// keep coming back to appears in it repeatedly, and two widget rows naming
    /// the same song would be a wasted row.
    static func publishSongs(from library: LibraryStore) {
        var seen = Set<UUID>()
        var songs: [WidgetSongEntry] = []
        for row in library.recentListenEntries {
            guard seen.insert(row.track.id).inserted else { continue }
            songs.append(WidgetSongEntry(trackID: row.track.id,
                                         title: row.track.title,
                                         artist: row.track.artist,
                                         date: row.entry.date))
            if songs.count == WidgetSnapshot.storedRows { break }
        }
        var snapshot = WidgetSnapshotStore.read()
        snapshot.songs = songs
        reloadIfChanged(snapshot)
    }

    /// The last few *distinct* genres and artists opened, kept as two lists.
    /// Splitting them here rather than filtering one merged list in the widget
    /// is what makes the **Artists** option work after a run of genre visits:
    /// a single top-four list would be all genres and the artist rows would
    /// come up empty even though you'd visited plenty.
    ///
    /// History collapses only *consecutive* repeats, so hopping between two
    /// genres would otherwise fill every row with the same one — hence the
    /// dedupe.
    static func publishBrowse(from history: [ENHistoryEntry]) {
        var snapshot = WidgetSnapshotStore.read()
        snapshot.genres = topEntries(in: history) { $0.kind == .genre }
        // A Spotify search hit is an artist you visited like any other; it just
        // re-opens through the live catalogue instead of the map.
        snapshot.artists = topEntries(in: history) { $0.kind == .artist || $0.kind == .spotify }
        reloadIfChanged(snapshot)
    }

    /// Reads the visit log straight off disk. The browser's store loads it
    /// lazily — nothing touches `everynoise-history.json` until the Browse tab
    /// is opened — so without this a launch that never got there would leave
    /// the widget's browse rows on whatever the last session wrote, forever.
    static func publishBrowseFromHistory() {
        guard let data = try? Data(contentsOf: AppPaths.everyNoiseHistory),
              let history = try? JSONDecoder().decode([ENHistoryEntry].self, from: data) else {
            return
        }
        publishBrowse(from: history)
    }

    private static func topEntries(in history: [ENHistoryEntry],
                                   matching: (ENHistoryEntry) -> Bool) -> [WidgetBrowseEntry] {
        var seen = Set<String>()
        var rows: [WidgetBrowseEntry] = []
        for entry in history where matching(entry) {
            let row = WidgetBrowseEntry(entry)
            guard seen.insert(row.id).inserted else { continue }
            rows.append(row)
            if rows.count == WidgetSnapshot.storedRows { break }
        }
        return rows
    }

    /// Writes, and reloads the widget only when the file actually changed —
    /// the publishers are called from save paths that fire far more often than
    /// the top rows change, and WidgetKit meters reloads.
    private static func reloadIfChanged(_ snapshot: WidgetSnapshot) {
        guard WidgetSnapshotStore.write(snapshot) else { return }
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotStore.kind)
        #endif
    }
}

private extension WidgetBrowseEntry {
    /// The visit log's own row, stripped to what a widget row needs.
    init(_ entry: ENHistoryEntry) {
        self.init(kind: entry.kind == .genre ? .genre : .artist,
                  genreKey: entry.genreKey,
                  artistID: entry.artistID,
                  isSpotifyArtist: entry.kind == .spotify,
                  name: entry.name,
                  colorHex: entry.color,
                  detail: entry.detail,
                  date: entry.date)
    }
}

/// Where a tapped widget row wants the app to go. The link is parsed here and
/// parked; `RootView` picks the tab and starts the track, and the Every Noise
/// browser picks up the browse target once its index has loaded and can resolve
/// it.
///
/// It's a two-step because neither destination is reachable synchronously from
/// `onOpenURL`: a cold launch hasn't selected the Browse tab yet, and the genre
/// index is read off the main thread after the browser appears.
@MainActor
final class AppRouter: ObservableObject {
    /// Somewhere in the Every Noise browser, cleared by it once opened.
    @Published var pendingBrowse: WidgetDeepLink.BrowseTarget?
    /// A track to start playing, cleared by `RootView` once it has.
    @Published var pendingTrackID: UUID?

    /// Returns false for a URL that isn't a widget link, so the caller can fall
    /// through to its usual handling (the Share Extension's
    /// `offlinelisten://import`).
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard let link = WidgetDeepLink(url: url) else { return false }
        switch link {
        case .browse(let target):
            pendingBrowse = target
        case .track(let id):
            pendingTrackID = id
        }
        appLog("Widget opened \(url.absoluteString)", category: "Widget")
        return true
    }
}
