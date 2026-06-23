import Foundation

/// Process-wide owner of the shared stores.
///
/// The app runs **two** scene types in one process: the SwiftUI phone UI
/// (`UIWindowScene`) and the CarPlay template UI (`CPTemplateApplicationScene`).
/// Both must drive the *same* library and playback engine — a track started in
/// the car has to show up in the phone's Now Playing, and a download finished on
/// the phone has to appear in the car's list. SwiftUI's `App` builds its
/// `StateObject`s from these instances, and `CarPlaySceneDelegate` reads the same
/// ones here, so there is a single source of truth behind both scenes.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let library: LibraryStore
    let downloads: DownloadManager
    let playback: PlaybackManager

    private init() {
        let library = LibraryStore()
        self.library = library
        self.downloads = DownloadManager(library: library)
        self.playback = PlaybackManager(library: library)
    }
}
