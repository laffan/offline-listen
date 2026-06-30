import SwiftUI

/// The Settings pane: audio output preference and a destructive "Clear all
/// Tracks" (with a confirmation step) that empties the watch and tells the phone
/// to clear its Watch folder to match.
struct WatchSettingsView: View {
    @EnvironmentObject private var playback: WatchPlaybackManager
    @EnvironmentObject private var connectivity: WatchConnectivityManager
    @EnvironmentObject private var library: WatchLibraryStore

    @State private var confirmingClear = false

    private var outputBinding: Binding<WatchAudioOutput> {
        Binding(get: { playback.preferredOutput }, set: { playback.preferredOutput = $0 })
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Output", selection: outputBinding) {
                        ForEach(WatchAudioOutput.allCases) { output in
                            Label(output.displayName, systemImage: output.systemImage)
                                .tag(output)
                        }
                    }
                    .pickerStyle(.navigationLink)
                } header: {
                    Text("Output")
                } footer: {
                    Text("Apple Watch routes audio to Bluetooth headphones when connected, otherwise the built-in speaker.")
                }

                Section {
                    Button(role: .destructive) {
                        confirmingClear = true
                    } label: {
                        Label("Clear all Tracks", systemImage: "trash")
                    }
                    .disabled(library.tracks.isEmpty)
                } footer: {
                    Text("Deletes all tracks saved on this watch.")
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                "Clear all Tracks?",
                isPresented: $confirmingClear,
                titleVisibility: .visible
            ) {
                Button("Clear All", role: .destructive) {
                    connectivity.clearAll()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes every track saved on your watch. They stay in your iPhone library.")
            }
        }
    }
}
