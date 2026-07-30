import Foundation

/// Errors surfaced by the Spotify Web API client, phrased for the download
/// queue's failure row (which is where the user actually reads them).
enum SpotifyError: LocalizedError {
    case notConfigured
    case credentialsRejected
    /// A 404 from a metadata endpoint. Client Credentials can't see private
    /// playlists, so that's the likely cause and the message says so.
    case notFound(String)
    case http(Int, String)
    case malformedResponse
    case network(String)
    /// A Spotify reference of a type this app doesn't download.
    case unsupportedReference(String)
    /// A reference that parsed but couldn't be made sense of (a short link
    /// leading somewhere unexpected).
    case badReference(String)
    /// Metadata resolved, but nothing survived the YouTube matching.
    case noMatches(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Add Spotify credentials in Settings to download Spotify links."
        case .credentialsRejected:
            return "Spotify rejected the credentials. Check the client ID and secret in Settings."
        case .notFound(let what):
            return "Spotify has no \(what) at that link. If it's a private or collaborative playlist, it isn't readable — this app signs in as an app, not as you, so it can only read public items."
        case .http(let code, let message):
            return "Spotify API error (\(code)): \(message)"
        case .malformedResponse:
            return "Couldn't read Spotify's response."
        case .network(let message):
            return "Network error: \(message)"
        case .unsupportedReference(let type):
            return "Unsupported Spotify reference type: \(type). Tracks, albums, playlists and artists are supported."
        case .badReference(let message):
            return message
        case .noMatches(let name):
            return "No YouTube matches found for \"\(name)\"."
        }
    }
}

/// One Spotify track, reduced to the fields the YouTube match actually needs.
/// Deliberately not a model of Spotify's object graph — four endpoints feed
/// this one shape.
struct SpotifyTrack: Sendable, Equatable {
    let id: String
    let name: String
    let artists: [String]
    let albumName: String
    let durationMS: Int
    /// The recording's ISRC, when the endpoint exposed one. An ISRC identifies
    /// a specific *recording*, which is what makes it the better search key.
    let isrc: String?
    let trackNumber: Int?

    var primaryArtist: String { artists.first ?? "" }

    /// "Artist - Title" — the queue row's label and the YouTube fallback query.
    var displayTitle: String {
        primaryArtist.isEmpty ? name : "\(primaryArtist) - \(name)"
    }

    var duration: TimeInterval { Double(durationMS) / 1000 }
}

/// One release in an artist's catalogue, as `/artists/{id}/albums` lists it —
/// enough to browse a discography and hand an album to the download pipeline.
struct SpotifyAlbumSummary: Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    /// "1979", "1979-10" or "1979-10-12" — Spotify's precision varies.
    let releaseDate: String
    /// "album" | "single" | "compilation" — the group Spotify files it under.
    let group: String
    let totalTracks: Int

    var year: String { releaseDate.isEmpty ? "" : String(releaseDate.prefix(4)) }
    /// The open.spotify.com link — the same shape the paste path parses, so
    /// downloading an album from here rides the existing pipeline unchanged.
    var url: String { "https://open.spotify.com/album/\(id)" }
}

/// A Spotify album, playlist or artist reduced to a name (which becomes the
/// library folder's name) and its tracks in Spotify's own order.
struct SpotifyCollection: Sendable {
    let name: String
    let tracks: [SpotifyTrack]
}

/// Caches the Client Credentials bearer token across calls, keyed by client id
/// so re-entering credentials in Settings can't reuse the old app's token.
/// An actor because the resolver hits the API from several tasks at once.
actor SpotifyTokenCache {
    static let shared = SpotifyTokenCache()

    private var token: String?
    private var expiresAt: Date?
    private var owner: String?

    /// The live token for `clientID`, or nil when there isn't one (or it's
    /// within a minute of expiring — a token that dies mid-request costs a
    /// round trip to discover).
    func current(for clientID: String) -> String? {
        guard let token, let expiresAt, owner == clientID, expiresAt.timeIntervalSinceNow > 60 else {
            return nil
        }
        return token
    }

    func store(_ token: String, expiresIn: TimeInterval, for clientID: String) {
        self.token = token
        self.expiresAt = Date().addingTimeInterval(expiresIn)
        self.owner = clientID
    }

    func invalidate() {
        token = nil
        expiresAt = nil
        owner = nil
    }
}

/// Thin wrapper around the Spotify Web API's public metadata endpoints, spoken
/// directly over URLSession (there's no Swift SDK, and this needs four reads).
/// Authorization is the **Client Credentials** flow: the app's own id/secret
/// buy a bearer token that reads public metadata with no user login — and
/// therefore can't see saved songs or private playlists.
///
/// Mirrors `AnthropicClient`: a value type holding the credentials, a `verify()`
/// for Settings, and typed errors.
struct SpotifyClient {
    let clientID: String
    let clientSecret: String

    private static let tokenEndpoint = URL(string: "https://accounts.spotify.com/api/token")!
    private static let apiBase = "https://api.spotify.com/v1"
    private static let category = "Spotify"

    /// Playlist tracks page at 100 — Spotify's own maximum. (Album tracks page
    /// at 50 and arrive with the album object, so only `next` is followed.)
    private static let playlistPageSize = 100
    /// `/tracks?ids=` accepts up to 50 ids per call.
    private static let batchSize = 50
    /// Runaway guard for the artist-albums `next` walk (a karaoke-factory
    /// "artist" can list thousands of releases; at the default page size this
    /// still covers 1,000+).
    private static let maxAlbumPages = 50

    /// The market for `/artists/{id}/top-tracks`, where it's a required
    /// parameter: the device's region, falling back to US.
    static var market: String {
        let region = Locale.current.region?.identifier ?? ""
        return region.count == 2 ? region.uppercased() : "US"
    }

    // MARK: - Verification

    /// Checks the credentials by minting a token and making the cheapest
    /// metadata call there is. A rejected secret surfaces as
    /// `.credentialsRejected`, never as a generic network error.
    func verify() async throws {
        _ = try await token(forceRefresh: true)
        guard let url = URL(string: "\(Self.apiBase)/search?q=a&type=track&limit=1") else {
            throw SpotifyError.malformedResponse
        }
        _ = try await get(url, describing: "search")
    }

    // MARK: - Metadata reads

    func track(id: String) async throws -> SpotifyTrack {
        let data = try await get(path: "/tracks/\(id)", describing: "track")
        guard let api = try? JSONDecoder().decode(APITrack.self, from: data),
              let track = Self.normalize(api, albumFallback: nil) else {
            throw SpotifyError.malformedResponse
        }
        return track
    }

    /// The tracks of an album, in album order. `/albums/{id}/tracks` returns
    /// *simplified* track objects — no album name and, more importantly, no
    /// ISRC — so the ids are re-read in batches of 50 through `/tracks?ids=`
    /// to recover both. That's one extra request per 50 tracks, and the ISRC is
    /// what keeps the YouTube match on the right recording.
    func album(id: String) async throws -> SpotifyCollection {
        let data = try await get(path: "/albums/\(id)", describing: "album")
        guard let album = try? JSONDecoder().decode(APIAlbum.self, from: data) else {
            throw SpotifyError.malformedResponse
        }
        let name = album.name ?? "Album"

        var simplified = album.tracks?.items ?? []
        var next = album.tracks?.next
        // The album call carries the first page; follow `next` for the rest.
        while let link = next, let url = URL(string: link) {
            let pageData = try await get(url, describing: "album tracks")
            guard let page = try? JSONDecoder().decode(APIPage<APITrack>.self, from: pageData) else { break }
            simplified.append(contentsOf: page.items ?? [])
            next = page.next
        }

        let tracks = try await fullTracks(for: simplified, albumFallback: name)
        appLog("Spotify album \"\(name)\": \(tracks.count) track(s).", category: Self.category)
        return SpotifyCollection(name: name, tracks: tracks)
    }

    /// A playlist's tracks, in playlist order. Items are wrapped and can be
    /// null (a removed track), a podcast episode, or a local file with no
    /// usable id — all three are skipped and counted.
    func playlist(id: String) async throws -> SpotifyCollection {
        let data = try await get(path: "/playlists/\(id)", describing: "playlist")
        guard let playlist = try? JSONDecoder().decode(APIPlaylist.self, from: data) else {
            throw SpotifyError.malformedResponse
        }
        let name = playlist.name ?? "Playlist"

        var items = playlist.tracks?.items ?? []
        var next = playlist.tracks?.next
        if items.isEmpty && next == nil {
            // Some responses carry only the tracks *href*; page it explicitly.
            next = "\(Self.apiBase)/playlists/\(id)/tracks?limit=\(Self.playlistPageSize)"
        }
        while let link = next, let url = URL(string: link) {
            let pageData = try await get(url, describing: "playlist tracks")
            guard let page = try? JSONDecoder().decode(APIPage<APIPlaylistItem>.self, from: pageData) else { break }
            items.append(contentsOf: page.items ?? [])
            next = page.next
        }

        var tracks: [SpotifyTrack] = []
        var locals = 0
        var nonTracks = 0
        for item in items {
            guard let api = item.track else { nonTracks += 1; continue }
            if item.isLocal == true || api.isLocal == true { locals += 1; continue }
            if let type = api.type, type != "track" { nonTracks += 1; continue }
            guard let track = Self.normalize(api, albumFallback: nil) else { nonTracks += 1; continue }
            tracks.append(track)
        }
        if locals > 0 {
            appLog("Spotify playlist \"\(name)\": skipped \(locals) local file(s) — they have no Spotify id to match on.",
                   level: .warning, category: Self.category)
        }
        if nonTracks > 0 {
            appLog("Spotify playlist \"\(name)\": skipped \(nonTracks) non-track item(s) (podcast episodes or removed tracks).",
                   level: .warning, category: Self.category)
        }
        appLog("Spotify playlist \"\(name)\": \(tracks.count) track(s).", category: Self.category)
        return SpotifyCollection(name: name, tracks: tracks)
    }

    /// An artist's top tracks in the device's market. `market` is required by
    /// this endpoint — omitting it is a 400, not a default.
    func artistTopTracks(id: String) async throws -> SpotifyCollection {
        let artistData = try await get(path: "/artists/\(id)", describing: "artist")
        let name = (try? JSONDecoder().decode(APIArtist.self, from: artistData))?.name ?? "Artist"

        let market = Self.market
        let data = try await get(path: "/artists/\(id)/top-tracks?market=\(market)",
                                 describing: "artist's top tracks")
        guard let response = try? JSONDecoder().decode(APITrackList.self, from: data) else {
            throw SpotifyError.malformedResponse
        }
        let tracks = (response.tracks ?? []).compactMap { Self.normalize($0, albumFallback: nil) }
        appLog("Spotify artist \"\(name)\": \(tracks.count) top track(s) in market \(market).",
               category: Self.category)
        return SpotifyCollection(name: name, tracks: tracks)
    }

    /// An artist's releases — albums, singles/EPs and compilations, without
    /// the "appears on" clutter — paginated to completion. This backs the
    /// Every Noise browser's discography view; each row's `url` re-enters the
    /// ordinary paste pipeline when the user downloads an album.
    func artistAlbums(id: String) async throws -> [SpotifyAlbumSummary] {
        var albums: [SpotifyAlbumSummary] = []
        // No explicit `limit`: this endpoint rejects values the docs say are
        // fine ("Invalid limit" on limit=50 under a client-credentials app),
        // so take the server's default page size and follow the `next` links
        // it mints itself — those are valid by construction. A few more
        // round-trips for a big catalogue, never a 400.
        var next: String? = "\(Self.apiBase)/artists/\(id)/albums?include_groups=album,single,compilation"
        var pages = 0
        while let link = next, let url = URL(string: link) {
            pages += 1
            if pages > Self.maxAlbumPages {
                appLog("Spotify artist \(id): catalogue runs past \(Self.maxAlbumPages) pages — stopping there.",
                       level: .warning, category: Self.category)
                break
            }
            let data = try await get(url, describing: "artist's albums")
            guard let page = try? JSONDecoder().decode(APIPage<APIAlbumSummary>.self, from: data) else {
                throw SpotifyError.malformedResponse
            }
            for item in page.items ?? [] {
                guard let itemID = item.id, let name = item.name, !name.isEmpty else { continue }
                albums.append(SpotifyAlbumSummary(
                    id: itemID,
                    name: name,
                    releaseDate: item.releaseDate ?? "",
                    group: item.albumGroup ?? item.albumType ?? "album",
                    totalTracks: item.totalTracks ?? 0))
            }
            next = page.next
        }
        // The same release can be listed once per market variant under a
        // different id; a name+year collapse keeps the list readable.
        var seen = Set<String>()
        let unique = albums.filter {
            seen.insert("\($0.name.lowercased())|\($0.year)|\($0.group)").inserted
        }
        appLog("Spotify artist \(id): \(unique.count) release(s) in the catalogue.", category: Self.category)
        return unique
    }

    /// Dispatches a collection reference to the right endpoint.
    func collection(kind: SpotifyRef.Kind, id: String) async throws -> SpotifyCollection {
        switch kind {
        case .album: return try await album(id: id)
        case .playlist: return try await playlist(id: id)
        case .artist: return try await artistTopTracks(id: id)
        case .track:
            let single = try await track(id: id)
            return SpotifyCollection(name: single.displayTitle, tracks: [single])
        }
    }

    /// Re-reads simplified album tracks as full track objects (in batches of
    /// 50) so they carry an ISRC. Best-effort: if the batch call fails, the
    /// simplified objects are used as-is with the album's name carried down.
    private func fullTracks(for simplified: [APITrack], albumFallback: String) async throws -> [SpotifyTrack] {
        let ids = simplified.compactMap { $0.id }
        guard !ids.isEmpty else {
            return simplified.compactMap { Self.normalize($0, albumFallback: albumFallback) }
        }

        var full: [String: SpotifyTrack] = [:]
        for chunk in stride(from: 0, to: ids.count, by: Self.batchSize).map({ Array(ids[$0..<min($0 + Self.batchSize, ids.count)]) }) {
            let joined = chunk.joined(separator: ",")
            do {
                let data = try await get(path: "/tracks?ids=\(joined)", describing: "tracks")
                guard let response = try? JSONDecoder().decode(APITrackList.self, from: data) else { continue }
                for api in response.tracks ?? [] {
                    guard let track = Self.normalize(api, albumFallback: albumFallback) else { continue }
                    full[track.id] = track
                }
            } catch {
                if isCancellation(error) { throw error }
                appLog("Couldn't re-read \(chunk.count) album track(s) for their ISRCs: \(error.localizedDescription) — matching on title instead.",
                       level: .warning, category: Self.category)
            }
        }

        // Keep the album's own order; fall back to the simplified object for
        // anything the batch didn't return.
        return simplified.compactMap { api in
            if let id = api.id, let track = full[id] { return track }
            return Self.normalize(api, albumFallback: albumFallback)
        }
    }

    // MARK: - Normalization

    /// Turns one API track object into our own shape, rejecting anything that
    /// isn't a usable track (a null entry, an episode, a local file).
    private static func normalize(_ api: APITrack, albumFallback: String?) -> SpotifyTrack? {
        guard let id = api.id, !id.isEmpty, api.isLocal != true else { return nil }
        if let type = api.type, type != "track" { return nil }
        let name = (api.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let artists = (api.artists ?? []).compactMap { artist -> String? in
            let trimmed = (artist.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let isrc = api.externalIDs?.isrc?.trimmingCharacters(in: .whitespacesAndNewlines)
        return SpotifyTrack(id: id,
                            name: name,
                            artists: artists,
                            albumName: api.album?.name ?? albumFallback ?? "",
                            durationMS: api.durationMS ?? 0,
                            isrc: (isrc?.isEmpty ?? true) ? nil : isrc,
                            trackNumber: api.trackNumber)
    }

    // MARK: - Transport

    /// A GET against an API path (`"/tracks/…"`), joined to the API base.
    private func get(path: String, describing what: String) async throws -> Data {
        guard let url = URL(string: Self.apiBase + path) else { throw SpotifyError.malformedResponse }
        return try await get(url, describing: what)
    }

    /// A token for these credentials — cached until it expires. `forceRefresh`
    /// mints a fresh one (used by `verify` and by the one 401 retry).
    private func token(forceRefresh: Bool = false) async throws -> String {
        guard !clientID.isEmpty, !clientSecret.isEmpty else { throw SpotifyError.notConfigured }
        if !forceRefresh, let cached = await SpotifyTokenCache.shared.current(for: clientID) {
            return cached
        }

        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let credentials = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("grant_type=client_credentials".utf8)
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            if isCancellation(error) { throw error }
            throw SpotifyError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw SpotifyError.malformedResponse }
        // Spotify answers a bad id/secret with 400 `invalid_client` or a 401 —
        // both mean "these credentials are wrong", which is worth saying plainly.
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 400 || http.statusCode == 401 {
                throw SpotifyError.credentialsRejected
            }
            throw SpotifyError.http(http.statusCode, Self.errorMessage(from: data))
        }
        guard let minted = try? JSONDecoder().decode(APIToken.self, from: data), !minted.accessToken.isEmpty else {
            throw SpotifyError.malformedResponse
        }
        let lifetime = minted.expiresIn ?? 3600
        await SpotifyTokenCache.shared.store(minted.accessToken, expiresIn: lifetime, for: clientID)
        appLog("Spotify access token minted (valid \(Int(lifetime))s).",
               level: .debug, category: Self.category)
        return minted.accessToken
    }

    /// A bearer GET. Refreshes the token and retries **once** on a 401 (the
    /// cached token can expire between the check and the call), then maps the
    /// status onto a typed error.
    private func get(_ url: URL, describing what: String) async throws -> Data {
        var bearer = try await token()
        var (data, status) = try await send(url, bearer: bearer)
        if status == 401 {
            await SpotifyTokenCache.shared.invalidate()
            bearer = try await token(forceRefresh: true)
            (data, status) = try await send(url, bearer: bearer)
        }
        guard (200..<300).contains(status) else {
            switch status {
            case 401: throw SpotifyError.credentialsRejected
            case 404: throw SpotifyError.notFound(what)
            case 429: throw SpotifyError.http(429, "rate limited by Spotify — wait a moment and try again")
            default: throw SpotifyError.http(status, Self.errorMessage(from: data))
            }
        }
        return data
    }

    private func send(_ url: URL, bearer: String) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 200)
        } catch {
            if isCancellation(error) { throw error }
            throw SpotifyError.network(error.localizedDescription)
        }
    }

    /// Pulls the human-readable message out of an error body, falling back to
    /// the raw bytes.
    private static func errorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            // The token endpoint uses OAuth's flat shape instead.
            if let description = json["error_description"] as? String { return description }
            if let error = json["error"] as? String { return error }
        }
        return String(data: data, encoding: .utf8) ?? "unknown error"
    }
}

// MARK: - Wire types

/// Only the fields we actually read are modelled, and every one of them is
/// optional: `/playlists/{id}/tracks` mixes full tracks, podcast episodes and
/// nulls into one array, and a single strict field would fail the whole page's
/// decode rather than one item's.
private struct APITrack: Decodable {
    let id: String?
    let name: String?
    let type: String?
    let artists: [APIArtist]?
    let album: APIAlbum?
    let durationMS: Int?
    let externalIDs: APIExternalIDs?
    let trackNumber: Int?
    let isLocal: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, type, artists, album
        case durationMS = "duration_ms"
        case externalIDs = "external_ids"
        case trackNumber = "track_number"
        case isLocal = "is_local"
    }
}

private struct APIArtist: Decodable {
    let name: String?
}

private struct APIAlbum: Decodable {
    let name: String?
    let tracks: APIPage<APITrack>?
}

/// A row of `/artists/{id}/albums` — the summary form, no tracklist.
private struct APIAlbumSummary: Decodable {
    let id: String?
    let name: String?
    let releaseDate: String?
    let albumGroup: String?
    let albumType: String?
    let totalTracks: Int?

    enum CodingKeys: String, CodingKey {
        case id, name
        case releaseDate = "release_date"
        case albumGroup = "album_group"
        case albumType = "album_type"
        case totalTracks = "total_tracks"
    }
}

private struct APIPlaylist: Decodable {
    let name: String?
    let tracks: APIPage<APIPlaylistItem>?
}

private struct APIPlaylistItem: Decodable {
    let track: APITrack?
    let isLocal: Bool?

    enum CodingKeys: String, CodingKey {
        case track
        case isLocal = "is_local"
    }
}

private struct APIExternalIDs: Decodable {
    let isrc: String?
}

/// Spotify's paging object. `next` is a full URL (or null on the last page) —
/// following it to nil is what keeps a 200-track playlist from truncating at
/// its first page.
private struct APIPage<Item: Decodable>: Decodable {
    let items: [Item]?
    let next: String?
}

private struct APITrackList: Decodable {
    let tracks: [APITrack]?
}

private struct APIToken: Decodable {
    let accessToken: String
    let expiresIn: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
    }
}
