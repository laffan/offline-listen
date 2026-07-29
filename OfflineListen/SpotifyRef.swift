import Foundation

/// A pasted reference to something on Spotify, parsed out of a `spotify:` URI or
/// an `open.spotify.com` link.
///
/// Parsing is deliberately synchronous and network-free (the Download tab's
/// input field asks "is this a link?" on every keystroke), with one exception
/// that *can't* be answered offline: a `spotify.link` short link only reveals
/// what it points at by following its redirect. Those parse as `.shortLink` and
/// are resolved later, on the download job's async path.
enum SpotifyRef: Equatable, Sendable {
    /// A reference we can read straight away.
    case direct(kind: Kind, id: String)
    /// A `spotify.link` short link — the real reference is behind a redirect.
    case shortLink(URL)
    /// Recognisably Spotify, but a type this app doesn't download (a podcast
    /// show or episode, an audiobook, a user profile). Kept as a parse *result*
    /// rather than a nil so the paste reads as a link and fails with a clear
    /// message, instead of silently turning into a YouTube search.
    case unsupported(type: String)

    /// The four kinds of Spotify object that resolve to downloadable tracks.
    /// Everything but `.track` expands into many tracks, and those go through
    /// the selection popup and land in a folder, like a YouTube playlist.
    enum Kind: String, Equatable, Sendable {
        case track, album, playlist, artist
    }

    /// Types Spotify serves that this app deliberately doesn't handle. Listed
    /// explicitly so an unrecognised path shape stays a `nil` (and falls
    /// through to the ordinary http download path) rather than being claimed.
    private static let unsupportedTypes: Set<String> = [
        "show", "episode", "audiobook", "chapter", "user", "collection", "concert",
    ]

    /// Hosts whose links are Spotify short links: the whole reference is behind
    /// a redirect, so the type and id can't be read from the URL itself.
    private static let shortLinkHosts: Set<String> = ["spotify.link", "spotify.app.link"]

    private static let webHosts: Set<String> = ["open.spotify.com", "play.spotify.com"]

    /// Parses a single pasted token. Returns nil when it isn't a Spotify
    /// reference at all — the caller then treats it as it always has (an
    /// ordinary link, or a search term).
    static func parse(_ string: String) -> SpotifyRef? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // `spotify:track:…` (and the legacy `spotify:user:x:playlist:…`).
        if trimmed.lowercased().hasPrefix("spotify:") {
            let parts = trimmed.dropFirst("spotify:".count).split(separator: ":").map(String.init)
            return reference(inComponents: parts, claimUnknown: true)
        }

        guard let url = URL(string: trimmed), let host = url.host?.lowercased() else { return nil }
        let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host

        if shortLinkHosts.contains(bareHost) { return .shortLink(url) }
        guard webHosts.contains(bareHost) else { return nil }

        // Localized share links carry an `/intl-xx/` segment before the type
        // (`open.spotify.com/intl-de/track/…`); drop it. The query is ignored
        // entirely by construction — `si` is a share token, not part of the
        // reference.
        let components = url.pathComponents.filter {
            $0 != "/" && !$0.lowercased().hasPrefix("intl-")
        }
        return reference(inComponents: components, claimUnknown: false)
    }

    /// Finds the reference in a list of `:`- or `/`-separated components. A
    /// supported type wins wherever it sits (so the legacy
    /// `user:<name>:playlist:<id>` form resolves to the playlist, not the
    /// user), and an unsupported type is only reported when no supported one
    /// was found.
    ///
    /// `claimUnknown` is true for the `spotify:` scheme, where an unfamiliar
    /// type word is still unmistakably a Spotify reference; for web URLs an
    /// unfamiliar path shape returns nil so the link keeps its ordinary
    /// http(s) handling.
    private static func reference(inComponents parts: [String], claimUnknown: Bool) -> SpotifyRef? {
        for (index, part) in parts.enumerated() {
            guard let kind = Kind(rawValue: part.lowercased()) else { continue }
            guard index + 1 < parts.count, isValidID(parts[index + 1]) else { continue }
            return .direct(kind: kind, id: parts[index + 1])
        }
        for part in parts {
            let type = part.lowercased()
            if unsupportedTypes.contains(type) { return .unsupported(type: type) }
        }
        // A `spotify:` URI we couldn't read is still a Spotify reference — say
        // so rather than letting it fall through to a YouTube search.
        if claimUnknown, let first = parts.first, !first.isEmpty {
            return .unsupported(type: first.lowercased())
        }
        return nil
    }

    /// Spotify ids are base62 and, in practice, always 22 characters. Validated
    /// loosely — alphanumeric, roughly the right length — so a future change of
    /// length doesn't break parsing, while obvious non-ids ("playlists",
    /// "search") are still rejected.
    static func isValidID(_ candidate: String) -> Bool {
        guard (20...24).contains(candidate.count) else { return false }
        return candidate.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// Resolves this reference to a concrete `(kind, id)` pair, following a
    /// short link's redirect if that's what it is. The only networking in this
    /// file, and the reason resolution lives on the job's async path.
    func resolved() async throws -> (kind: Kind, id: String) {
        switch self {
        case .direct(let kind, let id):
            return (kind, id)
        case .unsupported(let type):
            throw SpotifyError.unsupportedReference(type)
        case .shortLink(let url):
            let destination: URL
            do {
                destination = try await BrowseHTTP.getRaw(url).finalURL
            } catch {
                if isCancellation(error) { throw error }
                throw SpotifyError.network(error.localizedDescription)
            }
            appLog("Spotify short link \(url.absoluteString) → \(destination.absoluteString)",
                   level: .debug, category: "Spotify")
            guard let parsed = SpotifyRef.parse(destination.absoluteString) else {
                throw SpotifyError.badReference("That short link didn't lead to a Spotify track, album, playlist or artist.")
            }
            // One hop only — a redirect chain that lands on another short link
            // would otherwise recurse.
            if case .shortLink = parsed {
                throw SpotifyError.badReference("That short link didn't resolve to a Spotify reference.")
            }
            return try await parsed.resolved()
        }
    }
}
