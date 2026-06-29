import SwiftUI

/// The "Watch" virtual folder: every track that's been pushed to the Apple
/// Watch, regardless of where it otherwise lives in the library. Sending a track
/// here never moves it elsewhere — this is purely for managing what's on the
/// watch (the reverse is also true: the watch's "Clear all Tracks" empties this).
///
/// Per the spec it's deliberately spare: tap to play, and a single swipe-left
/// action — **Remove from Watch**. No swipe-right (Song/Podcast) actions.
struct WatchFolderView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager

    let onPlay: () -> Void

    private var tracks: [Track] {
        library.watchTracks
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
                    ForEach(tracks) { track in
                        TrackRow(
                            track: track,
                            isCurrent: playback.currentTrack?.id == track.id
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            playback.play(track, in: tracks)
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
                .listStyle(.plain)
            }
        }
        .navigationTitle("Watch")
        .navigationBarTitleDisplayMode(.inline)
    }
}
