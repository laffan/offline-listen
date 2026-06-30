import SwiftUI

@main
struct OfflineListenWatchApp: App {
    @StateObject private var library: WatchLibraryStore
    @StateObject private var connectivity: WatchConnectivityManager
    @StateObject private var playback: WatchPlaybackManager

    init() {
        let library = WatchLibraryStore()
        let connectivity = WatchConnectivityManager(store: library)
        let playback = WatchPlaybackManager(store: library)
        _library = StateObject(wrappedValue: library)
        _connectivity = StateObject(wrappedValue: connectivity)
        _playback = StateObject(wrappedValue: playback)
        // Forward podcast playhead changes on the watch to the phone.
        library.onPositionChanged = { [weak connectivity] id, pos in
            connectivity?.sendPosition(id: id, position: pos)
        }
        // Remote control: feed the phone's now-playing into the player, and let
        // the player's transport buttons drive the phone.
        connectivity.onRemoteState = { [weak playback] state in playback?.applyRemote(state) }
        playback.sendRemoteCommand = { [weak connectivity] command in
            connectivity?.sendRemoteCommand(command)
        }
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(library)
                .environmentObject(connectivity)
                .environmentObject(playback)
        }
    }
}
