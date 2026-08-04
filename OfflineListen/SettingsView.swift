import SwiftUI
import UniformTypeIdentifiers

private extension View {
    /// Settings' `Form`, dressed for the platform it's on.
    ///
    /// iOS needs nothing: a `Form` in a `NavigationStack` is already the
    /// grouped, inset, section-spaced thing the rest of the app looks like.
    ///
    /// The Mac defaults to the **columns** style instead — labels right-aligned
    /// in a narrow gutter, rows stretched the full width of the window, headers
    /// butted straight up against the previous section's footer. That's the
    /// right shape for a compact preferences pane and quite wrong for a full
    /// window, where it reads as unstyled text. Two changes fix it:
    ///
    ///  - **`.grouped`** puts each section in its own rounded box, with the
    ///    header above it and the footer beneath in secondary type — the same
    ///    reading order iOS gives, and real space between sections.
    ///  - **A capped, centred width.** Grouped rows fill whatever they're
    ///    given, so in a 1180-point window a toggle's label and its switch end
    ///    up a hand's width apart and the footer paragraphs run to unreadable
    ///    measure. `SettingsMetrics.maxContentWidth` holds them to roughly the
    ///    column System Settings uses. It doubles as a structural guard: with
    ///    the content's width bounded, no row inside can drive the window's
    ///    size (see `stepperRow` for what that costs when it can).
    @ViewBuilder
    func settingsFormChrome() -> some View {
        #if os(macOS)
        self
            .formStyle(.grouped)
            // The grouped style paints its own panel behind the scroll view.
            // Capping the width would leave that panel as a lit rectangle with
            // hard vertical edges down the middle of a dark window, so it goes
            // and the section boxes float on the window's own background.
            .scrollContentBackground(.hidden)
            .frame(maxWidth: SettingsMetrics.maxContentWidth)
            .frame(maxWidth: .infinity)
        #else
        self
        #endif
    }
}

#if os(macOS)
private enum SettingsMetrics {
    /// Wide enough for the longest footer paragraph to break naturally, narrow
    /// enough that a row's label and its control stay visually paired.
    static let maxContentWidth: CGFloat = 720
}
#endif

/// The Settings tab. Top section configures AI-assisted organization (model +
/// API key + the assist opt-in), then the Spotify credentials; Local Sync and
/// the Blog Agent's limits sit below them, and the Log is a section beneath
/// those, opened in a pushed screen.
struct SettingsView: View {
    @EnvironmentObject private var ai: AISettingsStore
    @EnvironmentObject private var spotify: SpotifySettingsStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var localSync: LocalSyncStore
    @EnvironmentObject private var everyNoiseUpdates: ENUpdateStore
    @EnvironmentObject private var log: LogStore

    @State private var keyInput = ""
    @State private var verifyState: VerifyState = .idle
    @State private var showFolderPicker = false
    /// Drives the share sheet that hands the collected dataset updates off
    /// the device, and the confirmation before throwing them away.
    @State private var exportingUpdates = false
    @State private var confirmingUpdateClear = false

    /// The Every Noise harvest's opt-in. Read straight from `UserDefaults` by
    /// `ENUpdateStore` too, so flipping it here takes effect on the next genre
    /// you open.
    @AppStorage(ENUpdateSettings.enabledKey) private var everyNoiseUpdatesEnabled = false

    #if os(macOS)
    /// The resolved yt-dlp's version. Outer nil = still asking; inner nil = it
    /// couldn't be run.
    @State private var ytDlpVersion: String??
    /// Which of the three copies is in use, phrased for the row.
    @State private var ytDlpSource: String?
    @State private var updatingYtDlp = false
    @State private var ytDlpError: String?
    /// Bumped after an update so the version and source are re-read.
    @State private var ytDlpRevision = 0
    #endif

    @State private var spotifyIDInput = ""
    @State private var spotifySecretInput = ""
    @State private var spotifyVerifyState: VerifyState = .idle
    /// Seconds left of Spotify's rate-limit window for the saved credentials
    /// (0 = none) — drives the section's "rate limited" row, so "is it me or
    /// Spotify" is answerable at a glance.
    @State private var spotifyCooldown: TimeInterval = 0

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
                #if os(macOS)
                ytDlpSection
                #endif
                aiSection
                spotifySection
                everyNoiseDataSection
                localSyncSection
                blogAgentSection
                logSection
            }
            .settingsFormChrome()
            .miniPlayerClearance()
            .navigationTitle("Settings")
            .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    localSync.addRoot(url)
                }
            }
            .sheet(isPresented: $exportingUpdates) {
                if let url = everyNoiseUpdates.exportURL {
                    ActivityView(items: [url])
                }
            }
            .confirmationDialog("Discard the collected updates?",
                                isPresented: $confirmingUpdateClear,
                                titleVisibility: .visible) {
                Button("Discard", role: .destructive) { everyNoiseUpdates.clear() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Everything found so far is thrown away, and the genres already harvested become eligible again. Export first if you haven't merged it into the dataset yet.")
            }
            .task(id: spotify.clientID) { await refreshSpotifyCooldown() }
            .onAppear {
                Task { await refreshSpotifyCooldown() }
                everyNoiseUpdates.refreshCounts()
            }
        }
    }

    // MARK: - Every Noise data

    /// The dataset-freshness section: the opt-in, what browsing has turned up
    /// so far, and the export that carries it off the device for
    /// `tools/everynoise/merge_updates.py` to fold into the bundled map.
    #if os(macOS)
    /// Mac-only. iOS carries yt-dlp as an embedded Python module it fetches on
    /// first use; the Mac runs the real binary — a copy ships with the app, and
    /// **Update** fetches a newer one into Application Support that outranks it
    /// (see `MacYtDlp`). Updating matters more than it sounds: yt-dlp tracks a
    /// moving target, and a stale one shows up as downloads that used to work
    /// and suddenly don't.
    private var ytDlpSection: some View {
        Section {
            LabeledContent("Version") {
                switch ytDlpVersion {
                case .some(.some(let version)):
                    Text(version).foregroundStyle(.primary)
                case .some(.none):
                    Text("Not available").foregroundStyle(.secondary)
                case .none:
                    ProgressView().controlSize(.small)
                }
            }

            if let source = ytDlpSource {
                LabeledContent("Source") {
                    Text(source)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Button {
                updateYtDlp()
            } label: {
                HStack {
                    Text("Update yt-dlp")
                    if updatingYtDlp {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(updatingYtDlp)

            if let ytDlpError {
                Text(ytDlpError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if !MacYtDlp.hasFFmpeg {
                Text("No ffmpeg found. Downloads work, but video is limited to streams that already carry their audio, which caps the resolution some sites offer. `brew install ffmpeg` lifts it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("yt-dlp")
        } footer: {
            Text("Downloads try the built-in extractors first and fall back to yt-dlp, which covers the hundreds of other sites. A copy ships with the app; Update fetches a newer one, and a Homebrew install is used ahead of the bundled copy.")
        }
        .task(id: ytDlpRevision) { await readYtDlpState() }
    }

    private func readYtDlpState() async {
        ytDlpSource = MacYtDlp.resolve().map(MacYtDlp.sourceDescription(of:))
        // Double optional: nil while the binary is still being asked,
        // .some(nil) once it has answered that it can't run.
        ytDlpVersion = .some(await MacYtDlp.version())
    }

    private func updateYtDlp() {
        updatingYtDlp = true
        ytDlpError = nil
        ytDlpVersion = nil
        Task {
            do {
                try await MacYtDlp.update()
            } catch {
                ytDlpError = error.localizedDescription
            }
            updatingYtDlp = false
            ytDlpRevision += 1
        }
    }
    #endif

    private var everyNoiseDataSection: some View {
        Section {
            Toggle("Collect updates as I browse", isOn: $everyNoiseUpdatesEnabled)
                .disabled(!spotify.isConfigured)

            if everyNoiseUpdates.hasRecords || everyNoiseUpdates.harvestedGenreCount > 0 {
                HStack(spacing: 8) {
                    if everyNoiseUpdates.isHarvesting {
                        ProgressView()
                    } else {
                        Image(systemName: "chart.bar.doc.horizontal")
                            .foregroundStyle(.secondary)
                    }
                    Text(collectedSummary)
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }

            if let error = everyNoiseUpdates.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            // With a sync folder configured the export is already happening on
            // its own; say so, so nobody hunts for a share sheet they don't
            // need. Named so it can be found in Files.
            if let syncRoot = localSync.roots.first {
                Label("Also kept in \(syncRoot.name)/\(AppPaths.syncAppDataDirName)",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button {
                exportingUpdates = true
            } label: {
                Label("Download New Data", systemImage: "square.and.arrow.down")
            }
            .disabled(everyNoiseUpdates.exportURL == nil)

            if everyNoiseUpdates.hasRecords {
                Button(role: .destructive) {
                    confirmingUpdateClear = true
                } label: {
                    Label("Discard Collected Updates", systemImage: "trash")
                }
            }
        } header: {
            Text("Every Noise Data")
        } footer: {
            Text(spotify.isConfigured
                 ? "The bundled genre map is a one-time scrape of a site that froze in late 2024. With this on, opening a genre in the Every Noise browser also asks Spotify — once per genre, at most a few times a minute, never while Spotify is rate limiting — which artists it files under that label now, and records the ones the map is missing. Nothing changes in the app; the findings collect in a file you export here and merge into the dataset with tools/everynoise/merge_updates.py before a rebuild."
                 : "Needs Spotify credentials (above). With them saved, browsing the Every Noise map can also collect the artists and genres Spotify has added since the map was scraped, for merging into the dataset at build time.")
        }
    }

    /// "412 new artists across 37 genres · 8 genres missing from the map".
    private var collectedSummary: String {
        let artists = everyNoiseUpdates.recordCount
        let genres = everyNoiseUpdates.harvestedGenreCount
        var line = "\(artists) new artist\(artists == 1 ? "" : "s") across \(genres) genre\(genres == 1 ? "" : "s")"
        let missing = everyNoiseUpdates.newGenreCount
        if missing > 0 {
            line += " · \(missing) genre\(missing == 1 ? "" : "s") missing from the map"
        }
        return line
    }

    /// Re-reads the limiter on appearance (and when credentials change), so
    /// the Spotify section's countdown reflects the live window.
    @MainActor
    private func refreshSpotifyCooldown() async {
        spotifyCooldown = await SpotifyRateLimiter.shared.remainingCooldown(for: spotify.clientID)
    }

    // MARK: - Local Sync

    private var localSyncSection: some View {
        Section {
            ForEach(localSync.roots) { root in
                HStack {
                    Label(root.name, systemImage: root.url != nil
                          ? "arrow.triangle.2.circlepath"
                          : "exclamationmark.triangle")
                        .foregroundStyle(root.url != nil ? Color.primary : Color.orange)
                    Spacer()
                    Button("Remove", role: .destructive) {
                        localSync.removeRoot(root.id)
                    }
                    .font(.callout)
                    .buttonStyle(.borderless)
                }
            }
            if !localSync.roots.isEmpty {
                syncStatusRow
            }
            Button {
                showFolderPicker = true
            } label: {
                Label(localSync.roots.isEmpty ? "Choose Sync Folder…" : "Add Sync Folder…",
                      systemImage: localSync.roots.isEmpty ? "arrow.triangle.2.circlepath" : "plus")
            }
            if !localSync.roots.isEmpty {
                Toggle("Group under a \"Synced\" folder", isOn: $library.groupSyncedFolders)
            }
        } header: {
            Text("Local Sync")
        } footer: {
            Text("Pick folders (in Files, iCloud Drive, Dropbox, …) to mirror with. \"Sync to Local\" copies a track or folder into one of them, and playable files in a sync folder are copied into the app — so everything keeps playing offline — appearing with the sync icon and disappearing when removed from the folder. Removing a sync folder removes its synced items from your library; the folder's own files are untouched.\n\nGrouping is a display choice only: it collects the synced folders behind a single \"Synced\" row in the Library instead of listing them among your own folders. Nothing moves, and switching it back puts them where they were.")
        }
    }

    /// A quiet one-line status for the mirror: syncing (with the track count
    /// once the pass knows how much there is to copy), waiting to copy out
    /// changes (folder unreachable), or up to date.
    private var syncStatusRow: some View {
        HStack(spacing: 8) {
            if localSync.isSyncing {
                ProgressView()
                Text(syncingLabel)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if localSync.pendingOpCount > 0 {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.orange)
                Text("\(localSync.pendingOpCount) change\(localSync.pendingOpCount == 1 ? "" : "s") waiting to copy")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
                Text("Up to date")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    /// "Syncing 12 of 133 tracks" once the pass has counted its work; a plain
    /// "Syncing…" while it's still scanning (a cloud folder listing can take a
    /// while before the first file count is known).
    private var syncingLabel: String {
        let total = localSync.syncFileTotal
        guard total > 0 else { return "Syncing…" }
        let done = min(localSync.syncedFileCount, total)
        return "Syncing \(done) of \(total) track\(total == 1 ? "" : "s")"
    }

    // MARK: - Blog Agent

    private var blogAgentSection: some View {
        Section {
            stepperRow("Posts per refresh",
                       value: $blogAgentMaxPosts,
                       in: BlogAgentSettings.postsRange)
            stepperRow("Songs per post",
                       value: $blogAgentMaxSongs,
                       in: BlogAgentSettings.songsRange)
        } header: {
            Text("Blog Agent")
        } footer: {
            Text("How many recent posts a Blog Agent source reads on each refresh, and how many tracks it may take from a single post (found links and mentioned tracks alike).")
        }
    }

    /// A stepper naming its setting and showing the current value.
    ///
    /// The two platforms build this differently, and the difference is not
    /// cosmetic. iOS pushes the number to the trailing edge of the `Stepper`'s
    /// own label with a `Spacer`, which is greedy — it takes whatever width it
    /// is offered. On the Mac that is fatal: SwiftUI sizes the window to the
    /// `Form`'s content, so a row that grows to fill the window makes the
    /// window wider, which offers the row more width, which widens the window
    /// again. AppKit runs the loop until it exceeds one constraints pass per
    /// view and throws `NSGenericException` mid-layout — the window is a few
    /// hundred thousand points wide by then — which took the whole Settings tab
    /// down with it.
    ///
    /// So the Mac splits the row with `LabeledContent` instead, which divides
    /// leading label from trailing content itself rather than being handed a
    /// greedy spacer, and keeps the value beside the stepper it belongs to.
    @ViewBuilder
    private func stepperRow(_ title: String,
                            value: Binding<Int>,
                            in range: ClosedRange<Int>) -> some View {
        #if os(macOS)
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text("\(value.wrappedValue)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Stepper(title, value: value, in: range)
                    .labelsHidden()
            }
        }
        #else
        Stepper(value: value, in: range) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        #endif
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

    // MARK: - Spotify

    private var spotifySection: some View {
        Section {
            if spotify.isConfigured {
                HStack {
                    Label("Credentials saved", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Remove", role: .destructive) {
                        spotify.clearCredentials()
                        spotifyIDInput = ""
                        spotifySecretInput = ""
                        spotifyVerifyState = .idle
                    }
                    .font(.callout)
                }
                if spotifyCooldown > 1 {
                    Label("Rate limited by Spotify — clears in about \(spotifyCooldownText). Credentials from a newly created Spotify app start with a fresh quota.",
                          systemImage: "hourglass")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    // The escape hatch: drops only the app's *memory* of the
                    // window. The next Spotify tap then either works (the
                    // record was stale) or re-records a fresh 429.
                    Button {
                        Task {
                            await SpotifyRateLimiter.shared.reset()
                            await refreshSpotifyCooldown()
                        }
                    } label: {
                        Label("Forget the wait and retry", systemImage: "arrow.clockwise")
                            .font(.footnote)
                    }
                }
            } else {
                spotifyCredentialEntry
            }
        } header: {
            Text("Spotify")
        } footer: {
            if spotify.isConfigured {
                Text("Paste a Spotify track, album, playlist or artist link into the Download tab and its tracks are matched to YouTube videos and downloaded. Signing in as an app rather than as you, it reads public metadata only — your saved songs and private playlists aren't visible to it.")
            } else {
                Text("Create a free app at developer.spotify.com to get a client ID and secret, then paste them here to download Spotify links. They're stored securely in the device Keychain.")
            }
        }
    }

    @ViewBuilder
    private var spotifyCredentialEntry: some View {
        TextField("Client ID", text: $spotifyIDInput)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .disabled(spotifyVerifyState == .verifying)

        SecureField("Client secret", text: $spotifySecretInput)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .disabled(spotifyVerifyState == .verifying)

        Button {
            verifyAndSaveSpotify()
        } label: {
            HStack {
                if spotifyVerifyState == .verifying {
                    ProgressView()
                    Text("Verifying…")
                } else {
                    Text("Verify & Save")
                }
            }
        }
        .disabled(spotifyCredentialsIncomplete || spotifyVerifyState == .verifying)

        if case .failed(let message) = spotifyVerifyState {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var spotifyCredentialsIncomplete: Bool {
        spotifyIDInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || spotifySecretInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var spotifyCooldownText: String {
        spotifyCooldown < 90
            ? "\(Int(spotifyCooldown.rounded())) seconds"
            : "\(Int((spotifyCooldown / 60).rounded())) minutes"
    }

    private func verifyAndSaveSpotify() {
        let id = spotifyIDInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = spotifySecretInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !secret.isEmpty else { return }
        spotifyVerifyState = .verifying
        Task {
            do {
                try await SpotifyClient(clientID: id, clientSecret: secret).verify()
                spotify.saveCredentials(id: id, secret: secret)
                spotifyIDInput = ""
                spotifySecretInput = ""
                spotifyVerifyState = .idle
                appLog("Spotify credentials verified and saved.", level: .success, category: "Spotify")
            } catch {
                spotifyVerifyState = .failed(error.localizedDescription)
                appLog("Spotify verification failed: \(error.localizedDescription)",
                       level: .error, category: "Spotify")
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
