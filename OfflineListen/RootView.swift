import SwiftUI

enum Tab: Hashable {
    case download
    case library
    case player
    case settings
}

struct RootView: View {
    @State private var selection: Tab = .library

    var body: some View {
        TabView(selection: $selection) {
            DownloadView(onPlay: { selection = .player })
                .tabItem { Label("Download", systemImage: "arrow.down.circle") }
                .tag(Tab.download)

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
