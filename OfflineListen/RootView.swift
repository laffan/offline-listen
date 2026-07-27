import SwiftUI

enum Tab: Hashable {
    case download
    case browse
    case library
    case player
    case settings
}

struct RootView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @State private var selection: Tab = .library

    /// Downloads still working or waiting — the number shown on the Download
    /// tab's badge (finished/failed/cancelled history doesn't count).
    private var pendingDownloads: Int {
        downloads.jobs.filter { $0.state.isActive || $0.state == .queued }.count
    }

    var body: some View {
        TabView(selection: $selection) {
            DownloadView(onPlay: { selection = .player })
                .tabItem { Label("Download", systemImage: "arrow.down.circle") }
                .badge(pendingDownloads == 0 ? nil : Text("\(pendingDownloads)"))
                .tag(Tab.download)

            BrowseView()
                .tabItem { Label("Browse", systemImage: "safari") }
                .tag(Tab.browse)

            LibraryView(onPlay: { selection = .player })
                .tabItem { Label("Library", systemImage: "music.note.list") }
                .tag(Tab.library)

            PlayerView()
                .tabItem { Label("Player", systemImage: "play.circle") }
                .tag(Tab.player)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
    }
}
