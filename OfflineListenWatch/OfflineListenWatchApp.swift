import SwiftUI

@main
struct OfflineListenWatchApp: App {
    @StateObject private var library: WatchLibraryStore
    @StateObject private var connectivity: WatchConnectivityManager
    @StateObject private var playback: WatchPlaybackManager

    init() {
        let library = WatchLibraryStore()
        let connectivity = WatchConnectivityManager(store: library)
        _library = StateObject(wrappedValue: library)
        _connectivity = StateObject(wrappedValue: connectivity)
        _playback = StateObject(wrappedValue: WatchPlaybackManager(store: library))
        // Forward podcast playhead changes on the watch to the phone.
        library.onPositionChanged = { [weak connectivity] id, pos in
            connectivity?.sendPosition(id: id, position: pos)
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
