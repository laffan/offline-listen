import SwiftUI

/// The "Watch" virtual folder: every track that's been pushed to the Apple
/// Watch, regardless of where it otherwise lives in the library. Sending a track
/// here never moves it elsewhere — this is purely for managing what's on the
/// watch (the reverse is also true: the watch's "Clear all Tracks" empties this).
///
/// Tracks sent as part of a playlist are grouped under that folder's name; tracks
/// sent on their own sit in a plain list. A sync-progress banner sits at the top.
/// Per the spec it's deliberately spare: tap to play, and a single swipe-left
/// action — **Remove from Watch**. No swipe-right (Song/Podcast) actions.
struct WatchFolderView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager
    @ObservedObject private var sync = WatchSync.shared

    let onPlay: () -> Void

    private var tracks: [Track] {
        library.watchTracks
    }

    /// Watch tracks grouped by the folder (playlist) they were sent as part of,
    /// in the library's folder order.
    private var folderedTracks: [(folder: Folder, tracks: [Track])] {
        let grouped = Dictionary(grouping: tracks) { $0.folderID }
        return library.folders.compactMap { folder in
            guard let ts = grouped[folder.id], !ts.isEmpty else { return nil }
            return (folder, ts)
        }
    }

    /// Watch tracks sent on their own (or whose folder no longer exists).
    private var looseTracks: [Track] {
        let known = Set(library.folders.map { $0.id })
        return tracks.filter { $0.folderID == nil || !known.contains($0.folderID!) }
    }

    private var syncedCount: Int {
        tracks.filter { sync.deliveredFileNames.contains($0.fileName) }.count
    }

    /// Overall sync fraction: delivered files plus the in-flight transfers'
    /// real byte progress, over the total.
    private var syncFraction: Double {
        guard !tracks.isEmpty else { return 1 }
        let inFlight = tracks.reduce(0.0) { $0 + (sync.activeTransfers[$1.fileName] ?? 0) }
        return (Double(syncedCount) + inFlight) / Double(tracks.count)
    }

    /// The track currently transferring (the undelivered one with the most
    /// progress), with its percent — for the banner subtitle.
    private var syncingTrack: (title: String, percent: Int)? {
        let pending = tracks.filter { !sync.deliveredFileNames.contains($0.fileName) }
        let best = pending
            .map { ($0.title, sync.activeTransfers[$0.fileName] ?? 0) }
            .max { $0.1 < $1.1 }
        guard let best else { return nil }
        return (best.0, Int((best.1 * 100).rounded()))
    }

    var body: some View {
        Group {
            if tracks.isEmpty {
                ContentUnavailableViewCompat(
                    title: "Nothing on your Watch",
                    systemImage: "applewatch",
                    description: "Touch and hold a track or playlist and choose Send to Watch to listen offline on your Apple Watch."
                )
            } else {
                List {
                    syncStatusSection
                    ForEach(folderedTracks, id: \.folder.id) { entry in
                        Section(entry.folder.name) {
                            ForEach(entry.tracks) { track in
                                row(for: track, queue: entry.tracks)
                            }
                        }
                    }
                    if !looseTracks.isEmpty {
                        Section(folderedTracks.isEmpty ? "" : "Tracks") {
                            ForEach(looseTracks) { track in
                                row(for: track, queue: looseTracks)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Watch")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var syncStatusSection: some View {
        let total = tracks.count
        let synced = syncedCount
        Section {
            if synced < total {
                HStack(spacing: 10) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Syncing \(synced) of \(total) to Watch…")
                            .font(.callout)
                        ProgressView(value: syncFraction)
                            .tint(.accentColor)
                        if let syncing = syncingTrack {
                            Text("\(syncing.title) — \(syncing.percent)%")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .monospacedDigit()
                        }
                    }
                }
                .padding(.vertical, 2)
            } else {
                Label("All \(total) track\(total == 1 ? "" : "s") synced to Watch", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(for track: Track, queue: [Track]) -> some View {
        TrackRow(
            track: track,
            isCurrent: playback.currentTrack?.id == track.id
        )
        .contentShape(Rectangle())
        .onTapGesture {
            playback.play(track, in: queue)
            onPlay()
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                library.removeFromWatch(track)
            } label: {
                Label("Remove from Watch", systemImage: "applewatch.slash")
            }
            .tint(.indigo)
        }
    }
}
