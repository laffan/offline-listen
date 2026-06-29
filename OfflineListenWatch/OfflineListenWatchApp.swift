import SwiftUI

@main
struct OfflineListenWatchApp: App {
    @StateObject private var library: WatchLibraryStore
    @StateObject private var connectivity: WatchConnectivityManager
    @StateObject private var playback: WatchPlaybackManager

    init() {
        let library = WatchLibraryStore()
        _library = StateObject(wrappedValue: library)
        _connectivity = StateObject(wrappedValue: WatchConnectivityManager(store: library))
        _playback = StateObject(wrappedValue: WatchPlaybackManager(store: library))
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
