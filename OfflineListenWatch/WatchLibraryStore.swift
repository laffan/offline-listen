import Foundation
import Combine

/// Owns the watch's offline library: the index of tracks the phone has pushed
/// and the audio files on disk. The phone is the source of truth, so this
/// reconciles to whatever manifest arrives — adding new tracks, preserving
/// podcast playheads, and pruning files that are no longer wanted.
@MainActor
final class WatchLibraryStore: ObservableObject {
    @Published private(set) var tracks: [WatchTrack] = []

    init() {
        load()
    }

    // MARK: - Grouping for the List pane

    /// A playlist on the watch: tracks that were sent as part of the same folder.
    struct WatchFolder: Identifiable {
        var id: String { name }
        let name: String
        let tracks: [WatchTrack]
    }

    /// Tracks sent as part of a playlist, grouped by folder name in send order.
    var folders: [WatchFolder] {
        var order: [String] = []
        var grouped: [String: [WatchTrack]] = [:]
        for track in tracks {
            guard let name = track.folderName else { continue }
            if grouped[name] == nil { order.append(name) }
            grouped[name, default: []].append(track)
        }
        return order.map { WatchFolder(name: $0, tracks: grouped[$0] ?? []) }
    }

    /// Tracks sent on their own (not part of any playlist).
    var looseTracks: [WatchTrack] {
        tracks.filter { $0.folderName == nil }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: WatchPaths.index),
              let decoded = try? JSONDecoder().decode([WatchTrack].self, from: data) else {
            tracks = []
            return
        }
        tracks = decoded.sorted { $0.order < $1.order }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(tracks) {
            try? data.write(to: WatchPaths.index, options: .atomic)
        }
    }

    // MARK: - Sync

    /// Reconciles the library to a manifest from the phone. New tracks are added,
    /// existing ones keep their saved playhead, and any local file no longer in
    /// the manifest is deleted.
    func apply(_ manifest: WatchManifest) {
        let existing = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        let wantedFileNames = Set(manifest.tracks.map { $0.fileName })

        // Delete files for tracks that fell out of the manifest.
        for track in tracks where !wantedFileNames.contains(track.fileName) {
            try? FileManager.default.removeItem(at: track.fileURL)
        }

        tracks = manifest.tracks
            .sorted { $0.order < $1.order }
            .map { m in
                // Keep a position we already have (live updates own it); adopt the
                // manifest's position only for a track new to the watch.
                WatchTrack(manifest: m, lastPosition: existing[m.id]?.lastPosition ?? m.lastPosition)
            }
        save()
    }

    /// Empties the watch: deletes every audio file and clears the index.
    func clearAll() {
        for track in tracks {
            try? FileManager.default.removeItem(at: track.fileURL)
        }
        tracks = []
        save()
    }

    /// Called with a podcast playhead change so it can be forwarded to the phone.
    var onPositionChanged: ((UUID, Double) -> Void)?

    /// Records a podcast's playhead so it resumes next time, and forwards it to
    /// the phone to keep both in sync.
    func updatePosition(for id: UUID, to position: Double) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        guard abs(tracks[index].lastPosition - position) >= 1 else { return }
        tracks[index].lastPosition = position
        save()
        onPositionChanged?(id, position)
    }

    /// Applies a playhead update received *from* the phone (no echo back).
    func applyRemotePosition(_ id: UUID, _ position: Double) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        guard abs(tracks[index].lastPosition - position) >= 1 else { return }
        tracks[index].lastPosition = position
        save()
    }
}
