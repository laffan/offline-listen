import SwiftUI

/// The Settings tab. Top section configures AI-assisted organization (model +
/// API key + the assist opt-in); the Log lives below it as its own section,
/// opened in a pushed screen.
struct SettingsView: View {
    @EnvironmentObject private var ai: AISettingsStore
    @EnvironmentObject private var log: LogStore

    @State private var keyInput = ""
    @State private var verifyState: VerifyState = .idle

    private enum VerifyState: Equatable {
        case idle
        case verifying
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                aiSection
                logSection
            }
            .navigationTitle("Settings")
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
