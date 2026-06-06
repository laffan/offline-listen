import SwiftUI

@main
struct OfflineListenApp: App {
    @StateObject private var library: LibraryStore
    @StateObject private var downloads: DownloadManager
    @StateObject private var playback: PlaybackManager

    init() {
        let library = LibraryStore()
        _library = StateObject(wrappedValue: library)
        _downloads = StateObject(wrappedValue: DownloadManager(library: library))
        _playback = StateObject(wrappedValue: PlaybackManager())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(downloads)
                .environmentObject(playback)
                .environmentObject(LogStore.shared)
        }
    }
}
