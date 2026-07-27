import Foundation

/// Persists the Spotify Web API credentials — a client id and secret from a free
/// Spotify developer app — in the device Keychain, mirroring `AISettingsStore`.
///
/// Credentials are only ever saved after a successful verification call (see
/// `SettingsView`), so `isConfigured` means "a working pair, the last time it
/// was checked". They authorize the **Client Credentials** flow, which reads
/// public metadata only: no liked songs, no private playlists, no user library.
@MainActor
final class SpotifySettingsStore: ObservableObject {
    /// The saved credentials (empty when none). Read-only to callers; mutate
    /// via `saveCredentials`/`clearCredentials` so the Keychain stays in sync.
    @Published private(set) var clientID: String
    @Published private(set) var clientSecret: String

    private static let idAccount = "spotify-client-id"
    private static let secretAccount = "spotify-client-secret"

    init() {
        clientID = Keychain.read(account: Self.idAccount) ?? ""
        clientSecret = Keychain.read(account: Self.secretAccount) ?? ""
    }

    /// True once a verified pair is on file — the gate every Spotify paste
    /// checks before it does any work.
    var isConfigured: Bool { !clientID.isEmpty && !clientSecret.isEmpty }

    /// A client built from the saved credentials, or nil when none are saved.
    var client: SpotifyClient? {
        guard isConfigured else { return nil }
        return SpotifyClient(clientID: clientID, clientSecret: clientSecret)
    }

    /// Persists a verified pair to the Keychain.
    func saveCredentials(id: String, secret: String) {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.save(account: Self.idAccount, value: trimmedID)
        Keychain.save(account: Self.secretAccount, value: trimmedSecret)
        clientID = trimmedID
        clientSecret = trimmedSecret
    }

    /// Forgets the credentials (and the bearer token they minted).
    func clearCredentials() {
        Keychain.delete(account: Self.idAccount)
        Keychain.delete(account: Self.secretAccount)
        clientID = ""
        clientSecret = ""
        Task { await SpotifyTokenCache.shared.invalidate() }
    }
}
