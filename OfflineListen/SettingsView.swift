import SwiftUI
import UniformTypeIdentifiers

/// The Settings tab. Top section configures AI-assisted organization (model +
/// API key + the assist opt-in); Local Sync and the Blog Agent's limits sit
/// below it, and the Log is a section beneath them, opened in a pushed screen.
struct SettingsView: View {
    @EnvironmentObject private var ai: AISettingsStore
    @EnvironmentObject private var localSync: LocalSyncStore
    @EnvironmentObject private var log: LogStore

    @State private var keyInput = ""
    @State private var verifyState: VerifyState = .idle
    @State private var showFolderPicker = false

    // The Blog Agent's limits — same keys `BlogAgentSettings` reads at
    // refresh time, so a change here applies to the next refresh.
    @AppStorage(BlogAgentSettings.maxPostsKey)
    private var blogAgentMaxPosts = BlogAgentSettings.defaultMaxPosts
    @AppStorage(BlogAgentSettings.maxSongsPerPostKey)
    private var blogAgentMaxSongs = BlogAgentSettings.defaultMaxSongsPerPost

    private enum VerifyState: Equatable {
        case idle
        case verifying
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                aiSection
                localSyncSection
                blogAgentSection
                logSection
            }
            .navigationTitle("Settings")
            .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    localSync.setRoot(url)
                }
            }
        }
    }

    // MARK: - Local Sync

    private var localSyncSection: some View {
        Section {
            if let root = localSync.rootURL {
                HStack {
                    Label(root.lastPathComponent, systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    Button("Remove", role: .destructive) {
                        localSync.clearRoot()
                    }
                    .font(.callout)
                }
                Button("Change Folder…") {
                    showFolderPicker = true
                }
            } else {
                Button {
                    showFolderPicker = true
                } label: {
                    Label("Choose Sync Folder…", systemImage: "arrow.triangle.2.circlepath")
                }
            }
        } header: {
            Text("Local Sync")
        } footer: {
            Text("Pick a folder (in Files, iCloud Drive, …) to sync with. \"Sync to Local\" moves a track or folder there, playable files already in it appear in your library with the sync icon, and changes made to the folder from outside the app show up immediately. Removing the sync folder keeps its files — they just leave the library.")
        }
    }

    // MARK: - Blog Agent

    private var blogAgentSection: some View {
        Section {
            Stepper(value: $blogAgentMaxPosts, in: BlogAgentSettings.postsRange) {
                HStack {
                    Text("Posts per refresh")
                    Spacer()
                    Text("\(blogAgentMaxPosts)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Stepper(value: $blogAgentMaxSongs, in: BlogAgentSettings.songsRange) {
                HStack {
                    Text("Songs per post")
                    Spacer()
                    Text("\(blogAgentMaxSongs)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } header: {
            Text("Blog Agent")
        } footer: {
            Text("How many recent posts a Blog Agent source reads on each refresh, and how many tracks it may take from a single post (found links and mentioned tracks alike).")
        }
    }

    // MARK: - AI

    private var aiSection: some View {
        Section {
            Picker("Model", selection: $ai.model) {
                ForEach(AIModel.allCases) { model in
                    Text(model.displayName).tag(model)
                }
            }

            if ai.isAuthenticated {
                authenticatedControls
            } else {
                apiKeyEntry
            }
        } header: {
            Text("AI Model & API Key")
        } footer: {
            if ai.isAuthenticated {
                Text("AI assist uses available metadata to label new downloads as music or podcasts and to clean up music titles and artists.")
            } else {
                Text("Add an Anthropic API key to enable AI-assisted organization. The key is stored securely in the device Keychain.")
            }
        }
    }

    @ViewBuilder
    private var authenticatedControls: some View {
        HStack {
            Label("API key saved", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
            Spacer()
            Button("Remove", role: .destructive) {
                ai.clearAPIKey()
                keyInput = ""
                verifyState = .idle
            }
            .font(.callout)
        }

        Toggle("AI assist with organization", isOn: $ai.assistEnabled)
    }

    @ViewBuilder
    private var apiKeyEntry: some View {
        SecureField("Anthropic API key (sk-ant-…)", text: $keyInput)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .disabled(verifyState == .verifying)

        Button {
            verifyAndSave()
        } label: {
            HStack {
                if verifyState == .verifying {
                    ProgressView()
                    Text("Verifying…")
                } else {
                    Text("Verify & Save")
                }
            }
        }
        .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || verifyState == .verifying)

        if case .failed(let message) = verifyState {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func verifyAndSave() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        verifyState = .verifying
        Task {
            let client = AnthropicClient(apiKey: key, model: ai.model)
            do {
                try await client.verify()
                ai.saveAPIKey(key)
                keyInput = ""
                verifyState = .idle
                appLog("AI API key verified and saved.", level: .success, category: "AI")
            } catch {
                verifyState = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Log

    private var logSection: some View {
        Section {
            NavigationLink {
                LogView()
            } label: {
                HStack {
                    Label("Log", systemImage: "doc.plaintext")
                    Spacer()
                    Text("\(log.entries.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("A timestamped, copyable stream of every pipeline step (queue, yt-dlp, conversion, AI) for diagnosing downloads.")
        }
    }
}
