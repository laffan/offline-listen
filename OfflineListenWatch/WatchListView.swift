import SwiftUI

/// The List pane: playlists (folders) the phone sent, then loose tracks. Tapping
/// a track starts it and jumps to the Listen pane.
struct WatchListView: View {
    @EnvironmentObject private var library: WatchLibraryStore
    @EnvironmentObject private var playback: WatchPlaybackManager

    let onPlay: () -> Void

    var body: some View {
        NavigationStack {
            // Always a List (with the title attached to it), rather than swapping
            // a List in/out of a Group — that swap left the first row tucked under
            // the title until the pane was re-laid-out. The empty state is an
            // overlay so the List still owns the scroll/title layout.
            List {
                if !library.folders.isEmpty {
                    Section("Playlists") {
                        ForEach(library.folders) { folder in
                            NavigationLink {
                                WatchPlaylistView(folderName: folder.name, onPlay: onPlay)
                            } label: {
                                HStack {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(.secondary)
                                    Text(folder.name).lineLimit(1)
                                    Spacer()
                                    Text("\(folder.tracks.count)")
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                }
                if !library.looseTracks.isEmpty {
                    Section("Tracks") {
                        ForEach(library.looseTracks) { track in
                            WatchTrackRow(track: track,
                                          isCurrent: playback.currentTrack?.id == track.id) {
                                playback.play(track, in: library.looseTracks)
                                onPlay()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .overlay {
                if library.tracks.isEmpty {
                    ContentUnavailableCompat(
                        title: "Nothing here yet",
                        systemImage: "applewatch",
                        description: "Send tracks from Offline Listen on your iPhone to listen offline."
                    )
                }
            }
        }
    }
}

/// A playlist's tracks on the watch. Reads from the store by folder name (rather
/// than a captured snapshot) so it refreshes live as files arrive or the phone
/// removes tracks. Plays straight through in order.
struct WatchPlaylistView: View {
    @EnvironmentObject private var library: WatchLibraryStore
    @EnvironmentObject private var playback: WatchPlaybackManager
    let folderName: String
    let onPlay: () -> Void

    private var tracks: [WatchTrack] {
        library.folders.first { $0.name == folderName }?.tracks ?? []
    }

    var body: some View {
        List {
            ForEach(tracks) { track in
                WatchTrackRow(track: track,
                              isCurrent: playback.currentTrack?.id == track.id) {
                    playback.play(track, in: tracks)
                    onPlay()
                }
            }
        }
        .navigationTitle(folderName)
    }
}

/// A tappable track row. While the audio file is still transferring it shows a
/// "Syncing…" state and isn't playable yet.
struct WatchTrackRow: View {
    let track: WatchTrack
    let isCurrent: Bool
    let onTap: () -> Void

    private var iconName: String {
        track.isPodcast ? "mic.fill" : "music.note"
    }

    private var hasArtist: Bool {
        !track.artist.isEmpty && track.artist.lowercased() != "unknown"
    }

    private var syncPercent: Int { Int((track.syncProgress * 100).rounded()) }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.body)
                        .lineLimit(2)
                    if !track.isAvailable {
                        Text("Syncing… \(syncPercent)%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else if hasArtist {
                        Text(track.artist)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if !track.isAvailable {
                    Text("\(syncPercent)%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .disabled(!track.isAvailable)
    }
}

/// A small stand-in for `ContentUnavailableView` (watchOS 10 compatible).
struct ContentUnavailableCompat: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(description)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
