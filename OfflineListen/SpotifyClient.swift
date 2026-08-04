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
    /// The album cover's largest image URL, when the endpoint served one —
    /// what a download fetched from this track wears as its artwork.
    let albumImageURL: String?
    /// Spotify's 0–100 per-track popularity score, carried by *full* track
    /// objects (`/tracks?ids=` re-reads); nil on simplified ones. What the
    /// catalogue-derived Top 10 ranks by.
    var popularity: Int? = nil

    var primaryArtist: String { artists.first ?? "" }

    /// "Artist - Title" — the queue row's label and the YouTube fallback query.
    var displayTitle: String {
        primaryArtist.isEmpty ? name : "\(primaryArtist) - \(name)"
    }

    var duration: TimeInterval { Double(durationMS) / 1000 }
}

/// One release in an artist's catalogue, as `/artists/{id}/albums` lists it —
/// enough to browse a discography and hand an album to the download pipeline.
/// One artist as the live catalogue describes them — what an artist search
/// hit carries beyond a name. The Every Noise harvest records these for names
/// the bundled (frozen) scrape doesn't have under a genre.
///
/// There is no preview URL here on purpose: artist objects never carried one,
/// and Spotify stopped serving `preview_url` on *tracks* to newly created apps
/// in November 2024 — so a harvested artist arrives without a snippet, and the
/// merge tool records that rather than inventing one.
struct SpotifyArtistHit: Sendable, Hashable {
    let id: String
    let name: String
    /// Spotify's own 0–100 score — the stand-in for the site's font-size cue.
    let popularity: Int
    /// Every genre label Spotify files this artist under.
    let genres: [String]
    let imageURL: String?
}

struct SpotifyAlbumSummary: Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    /// "1979", "1979-10" or "1979-10-12" — Spotify's precision varies.
    let releaseDate: String
    /// "album" | "single" | "compilation" — the group Spotify files it under.
    let group: String
    let totalTracks: Int
    /// The cover's largest image URL (Spotify orders images largest first).
    let imageURL: String?

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

/// Tracks Spotify's rate-limit state **app-wide**. A 429 arrives with a
/// `Retry-After`, and honoring it globally is what matters: Spotify keeps
/// extending the penalty window while requests keep landing, so a client
/// that fires the next call immediately turns a few seconds of limit into
/// minutes of 429s — including on screens that only cost two requests.
/// Every request first waits out (or fails fast against) the recorded
/// cooldown. An actor because requests run from several tasks at once.
///
/// Two properties matter for the *long* penalties Spotify escalates to
/// (an hour is real): the window **persists across relaunches** — a fresh
/// launch that forgot it would re-trip the 429 and extend it — and it is
/// **keyed by client id**, because the penalty belongs to the Spotify app
/// that earned it: freshly minted credentials start with a clean quota and
/// must not inherit the old app's timeout.
actor SpotifyRateLimiter {
    static let shared = SpotifyRateLimiter()

    private static let untilKey = "spotifyRateLimitUntil"
    private static let ownerKey = "spotifyRateLimitOwner"

    /// The end of the current penalty window, and the client id it belongs to.
    private var retryAt: Date?
    private var owner: String?

    init() {
        let stored = UserDefaults.standard.double(forKey: Self.untilKey)
        if stored > Date().timeIntervalSince1970 {
            retryAt = Date(timeIntervalSince1970: stored)
            owner = UserDefaults.standard.string(forKey: Self.ownerKey)
        }
    }

    /// Seconds left of the recorded window **for these credentials**
    /// (0 = clear to send — including under a different client id).
    func remainingCooldown(for clientID: String) -> TimeInterval {
        guard let retryAt, owner == clientID else { return 0 }
        let remaining = retryAt.timeIntervalSinceNow
        if remaining <= 0 {
            clear()
            return 0
        }
        return remaining
    }

    /// Records a 429's Retry-After — never shortening a window already known
    /// for the same client id.
    func noteRateLimited(for seconds: TimeInterval, clientID: String) {
        let until = Date().addingTimeInterval(max(1, seconds))
        if owner == clientID, let retryAt, retryAt >= until { return }
        retryAt = until
        owner = clientID
        UserDefaults.standard.set(until.timeIntervalSince1970, forKey: Self.untilKey)
        UserDefaults.standard.set(clientID, forKey: Self.ownerKey)
    }

    /// Drops the recorded window without waiting it out — Settings' escape
    /// hatch. The next request then tests reality: it either succeeds (the
    /// recorded window was stale or wrong) or comes straight back with a
    /// fresh 429 that re-records it. Harmless either way, since one request
    /// is also all a wrongly-forgotten window costs.
    func reset() {
        clear()
        appLog("Spotify: recorded rate-limit window cleared by the user.",
               category: "Spotify")
    }

    private func clear() {
        retryAt = nil
        owner = nil
        UserDefaults.standard.removeObject(forKey: Self.untilKey)
        UserDefaults.standard.removeObject(forKey: Self.ownerKey)
    }
}

/// Session-lived cache for the catalogue reads the discography browser
/// repeats: the same artist's portrait and album list (opening their page,
/// then Search Top 10), the same album's tracklist (a Top 10 derivation,
/// then expanding that album). It's public, effectively-static metadata, so
/// a short TTL costs nothing in freshness — the point is that browsing the
/// same artist twice must not bill the API twice. An actor: reads come from
/// several concurrent tasks.
actor SpotifyMetadataCache {
    static let shared = SpotifyMetadataCache()

    private let ttl: TimeInterval = 10 * 60
    private let maxArtists = 30
    private let maxCollections = 100

    private var artistsByID: [String: (value: (name: String, imageURL: String?), at: Date)] = [:]
    private var albumsByArtist: [String: (value: [SpotifyAlbumSummary], at: Date)] = [:]
    private var collectionsByAlbum: [String: (value: SpotifyCollection, at: Date)] = [:]

    func artist(forID id: String) -> (name: String, imageURL: String?)? {
        fresh(artistsByID[id])
    }

    func storeArtist(_ value: (name: String, imageURL: String?), forID id: String) {
        artistsByID[id] = (value, Date())
        trim(&artistsByID, to: maxArtists)
    }

    func albums(forArtist id: String) -> [SpotifyAlbumSummary]? {
        fresh(albumsByArtist[id])
    }

    func storeAlbums(_ value: [SpotifyAlbumSummary], forArtist id: String) {
        albumsByArtist[id] = (value, Date())
        trim(&albumsByArtist, to: maxArtists)
    }

    func collection(forAlbum id: String) -> SpotifyCollection? {
        fresh(collectionsByAlbum[id])
    }

    func storeCollection(_ value: SpotifyCollection, forAlbum id: String) {
        collectionsByAlbum[id] = (value, Date())
        trim(&collectionsByAlbum, to: maxCollections)
    }

    private func fresh<T>(_ entry: (value: T, at: Date)?) -> T? {
        guard let entry, Date().timeIntervalSince(entry.at) < ttl else { return nil }
        return entry.value
    }

    private func trim<T>(_ table: inout [String: (value: T, at: Date)], to cap: Int) {
        while table.count > cap,
              let oldest = table.min(by: { $0.value.at < $1.value.at }) {
            table.removeValue(forKey: oldest.key)
        }
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
    /// `/albums?ids=` accepts up to 20 ids per call.
    private static let albumBatchSize = 20
    /// Runaway guard for the artist-albums `next` walk (a karaoke-factory
    /// "artist" can list thousands of releases; at the default page size this
    /// still covers 1,000+).
    private static let maxAlbumPages = 50
    /// How many releases the catalogue-derived Top 10 reads tracklists for —
    /// one full `/albums?ids=` batch. A huge catalogue is still sampled
    /// rather than swept, but the sample is close to free: the batch read
    /// plus its cross-album `/tracks?ids=` sweep is ~5 requests total.
    private static let maxDerivedTopReleases = 20

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
        if let cached = await SpotifyMetadataCache.shared.collection(forAlbum: id) {
            return cached
        }
        let data = try await get(path: "/albums/\(id)", describing: "album")
        guard let album = try? JSONDecoder().decode(APIAlbum.self, from: data) else {
            throw SpotifyError.malformedResponse
        }
        let name = album.name ?? "Album"
        let cover = album.images?.first?.url

        var simplified = album.tracks?.items ?? []
        var next = album.tracks?.next
        // The album call carries the first page; follow `next` for the rest.
        while let link = next, let url = URL(string: link) {
            let pageData = try await get(url, describing: "album tracks")
            guard let page = try? JSONDecoder().decode(APIPage<APITrack>.self, from: pageData) else { break }
            simplified.append(contentsOf: page.items ?? [])
            next = page.next
        }

        let tracks = try await fullTracks(for: simplified, albumFallback: name, imageFallback: cover)
        appLog("Spotify album \"\(name)\": \(tracks.count) track(s).", category: Self.category)
        let collection = SpotifyCollection(name: name, tracks: tracks)
        await SpotifyMetadataCache.shared.storeCollection(collection, forAlbum: id)
        return collection
    }

    /// Several albums as collections keyed by id, using the **batch** albums
    /// endpoint — `/albums?ids=` returns up to 20 full albums (first tracks
    /// page inline) in ONE request, exactly the "reduce your API requests by
    /// calling the batch APIs" the docs advise. The ISRC/popularity re-read
    /// then sweeps every album's tracks together through `/tracks?ids=`
    /// (batches of 50), so a 12-release Top 10 derivation costs ~4 requests
    /// where the one-album-at-a-time path cost ~24. Cache-aware on both
    /// ends: already-cached albums aren't refetched, and everything fetched
    /// is stored — expanding any of these releases afterwards costs nothing.
    func albums(ids: [String]) async throws -> [String: SpotifyCollection] {
        var result: [String: SpotifyCollection] = [:]
        var missing: [String] = []
        for id in ids where result[id] == nil {
            if let cached = await SpotifyMetadataCache.shared.collection(forAlbum: id) {
                result[id] = cached
            } else {
                missing.append(id)
            }
        }
        guard !missing.isEmpty else { return result }

        var pending: [(id: String, name: String, cover: String?, simplified: [APITrack])] = []
        for chunk in stride(from: 0, to: missing.count, by: Self.albumBatchSize)
            .map({ Array(missing[$0..<min($0 + Self.albumBatchSize, missing.count)]) }) {
            let data = try await get(path: "/albums?ids=\(chunk.joined(separator: ","))",
                                     describing: "albums")
            guard let batch = try? JSONDecoder().decode(APIAlbumBatch.self, from: data) else {
                throw SpotifyError.malformedResponse
            }
            for album in (batch.albums ?? []).compactMap({ $0 }) {
                guard let id = album.id, !id.isEmpty else { continue }
                var simplified = album.tracks?.items ?? []
                // The inline page carries 50 tracks; follow `next` for the
                // rare release that runs past it.
                var next = album.tracks?.next
                while let link = next, let url = URL(string: link) {
                    let pageData = try await get(url, describing: "album tracks")
                    guard let page = try? JSONDecoder().decode(APIPage<APITrack>.self, from: pageData) else { break }
                    simplified.append(contentsOf: page.items ?? [])
                    next = page.next
                }
                pending.append((id, album.name ?? "Album", album.images?.first?.url, simplified))
            }
        }

        // One cross-album sweep recovers ISRC/popularity/art for everything.
        let full = try await fullTrackTable(for: pending.flatMap { $0.simplified.compactMap(\.id) })
        for entry in pending {
            let tracks = entry.simplified.compactMap { api -> SpotifyTrack? in
                if let id = api.id, let track = full[id] { return track }
                return Self.normalize(api, albumFallback: entry.name, imageFallback: entry.cover)
            }
            let collection = SpotifyCollection(name: entry.name, tracks: tracks)
            await SpotifyMetadataCache.shared.storeCollection(collection, forAlbum: entry.id)
            result[entry.id] = collection
        }
        appLog("Spotify: \(pending.count) album(s) read in \((missing.count + Self.albumBatchSize - 1) / Self.albumBatchSize) batch request(s).",
               category: Self.category)
        return result
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

    /// Rebuilds an artist's Top 10 from the catalogue when the dedicated
    /// endpoint can't serve it (`/top-tracks` answers 403 under newer
    /// client-credentials apps, and the AI agent only knows well-known
    /// names): reads the tracklists of up to `maxDerivedTopReleases`
    /// non-compilation releases — through the **batch** albums endpoint, so
    /// the whole derivation costs a handful of requests — and ranks every
    /// track by Spotify's own per-track **popularity** score, which the full
    /// track objects carry and the top-tracks endpoint is essentially a view
    /// over. Same-named recordings (an album track re-issued as a single)
    /// collapse to their most popular copy.
    func derivedTopTracks(artistID: String, limit: Int = 10) async throws -> [SpotifyTrack] {
        let releases = try await artistAlbums(id: artistID)
        var considered = releases.filter { $0.group != "compilation" }
        if considered.isEmpty { considered = releases }
        if considered.count > Self.maxDerivedTopReleases {
            considered = Array(considered.prefix(Self.maxDerivedTopReleases))
        }

        let collections = try await albums(ids: considered.map(\.id))

        var best: [String: SpotifyTrack] = [:]
        var order: [String] = []
        for release in considered {
            guard let collection = collections[release.id] else { continue }
            for track in collection.tracks {
                let key = track.name.lowercased()
                if let existing = best[key] {
                    if (track.popularity ?? 0) > (existing.popularity ?? 0) {
                        best[key] = track
                    }
                } else {
                    best[key] = track
                    order.append(key)
                }
            }
        }
        let ranked = order.compactMap { best[$0] }
            .sorted { ($0.popularity ?? 0) > ($1.popularity ?? 0) }
        let top = Array(ranked.prefix(limit))
        appLog("Spotify artist \(artistID): derived a top \(top.count) from \(considered.count) release(s) (\(ranked.count) tracks ranked by popularity).",
               category: Self.category)
        return top
    }

    /// An artist's display metadata — name and portrait — from `/artists/{id}`.
    /// Backs the discography browser's header.
    func artist(id: String) async throws -> (name: String, imageURL: String?) {
        if let cached = await SpotifyMetadataCache.shared.artist(forID: id) {
            return cached
        }
        let data = try await get(path: "/artists/\(id)", describing: "artist")
        guard let artist = try? JSONDecoder().decode(APIArtist.self, from: data) else {
            throw SpotifyError.malformedResponse
        }
        let value: (name: String, imageURL: String?) = (artist.name ?? "Artist",
                                                        artist.images?.first?.url)
        await SpotifyMetadataCache.shared.storeArtist(value, forID: id)
        return value
    }

    /// Resolves an artist's name to their Spotify id — what makes a typed-in
    /// "Spotify Discography" Browse source work without an Every Noise tap
    /// (which carries the id in the scraped data). Takes Spotify's top search
    /// hit, which is overwhelmingly the artist meant; a misfire is visible
    /// immediately (the wrong catalogue) and fixable by retyping the name.
    func searchArtist(named name: String) async throws -> (id: String, name: String) {
        let query = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        let data = try await get(path: "/search?q=\(query)&type=artist&limit=1",
                                 describing: "artist search")
        guard let response = try? JSONDecoder().decode(APIArtistSearch.self, from: data) else {
            throw SpotifyError.malformedResponse
        }
        guard let hit = response.artists?.items?.first, let id = hit.id, !id.isEmpty else {
            throw SpotifyError.notFound("artist named \"\(name)\"")
        }
        let resolved = hit.name ?? name
        appLog("Spotify artist search \"\(name)\" → \(resolved) (\(id)).", category: Self.category)
        return (id, resolved)
    }

    /// The artists Spotify currently files under a genre label — one page of
    /// `/search?q=genre:"…"&type=artist`, which is *the* request the Every
    /// Noise dataset harvest makes (one per genre you open, and never more
    /// than that — see `ENUpdateStore`). Search hits are full artist objects,
    /// so each carries its popularity, its own genre labels and a portrait.
    ///
    /// It is not a catalogue read and deliberately isn't cached: the whole
    /// point is to see what the live catalogue says *now* versus what the
    /// 2024-frozen scrape recorded.
    func searchArtists(genre: String) async throws -> [SpotifyArtistHit] {
        // The quotes matter: `genre:deep house` filters on "deep" and searches
        // for "house", `genre:"deep house"` filters on the whole label.
        let raw = "genre:\"\(genre)\""
        let encoded = raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? raw
        // No explicit `limit` or `offset`, for the same reason `artistAlbums`
        // sends none: under a client-credentials app Spotify answers
        // *"Invalid limit"* (400) to values its own docs call valid — this
        // asked for the documented maximum of 50 and got nothing back at all.
        // The server's default page is whatever it is happy to serve, which is
        // the only size guaranteed not to 400. Fewer artists per genre than
        // the ask, and far more than the zero a rejected request returns.
        let data = try await get(path: "/search?q=\(encoded)&type=artist",
                                 describing: "artists in \"\(genre)\"")
        guard let response = try? JSONDecoder().decode(APIArtistSearch.self, from: data) else {
            throw SpotifyError.malformedResponse
        }
        return (response.artists?.items ?? []).compactMap { api in
            guard let id = api.id, !id.isEmpty, let name = api.name, !name.isEmpty else { return nil }
            return SpotifyArtistHit(id: id, name: name,
                                    popularity: api.popularity ?? 0,
                                    genres: api.genres ?? [],
                                    imageURL: api.images?.first?.url)
        }
    }

    /// The top track-search hits for a free-text query. Backs the Library's
    /// **Get Album Art**: a downloaded track's artist + title comes in, the
    /// best hit's album cover goes out.
    func searchTracks(query: String, limit: Int = 5) async throws -> [SpotifyTrack] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let data = try await get(path: "/search?q=\(encoded)&type=track&limit=\(limit)",
                                 describing: "track search")
        guard let response = try? JSONDecoder().decode(APITrackSearch.self, from: data) else {
            throw SpotifyError.malformedResponse
        }
        return (response.tracks?.items ?? []).compactMap { Self.normalize($0, albumFallback: nil) }
    }

    /// An artist's releases — albums, singles/EPs and compilations, without
    /// the "appears on" clutter — paginated to completion. This backs the
    /// Every Noise browser's discography view; each row's `url` re-enters the
    /// ordinary paste pipeline when the user downloads an album.
    func artistAlbums(id: String) async throws -> [SpotifyAlbumSummary] {
        if let cached = await SpotifyMetadataCache.shared.albums(forArtist: id) {
            return cached
        }
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
                    totalTracks: item.totalTracks ?? 0,
                    imageURL: item.images?.first?.url))
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
        await SpotifyMetadataCache.shared.storeAlbums(unique, forArtist: id)
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

    /// Full track objects for arbitrary ids, keyed by id — `/tracks?ids=` in
    /// batches of 50. This is the sweep that recovers what simplified album
    /// tracks don't carry (ISRC, popularity, album art), and because the ids
    /// can span **albums**, one sweep serves a whole Top 10 derivation
    /// instead of one re-read per release. Best-effort per batch: a failed
    /// chunk logs and drops out, and the caller falls back to its simplified
    /// objects for anything missing.
    private func fullTrackTable(for ids: [String]) async throws -> [String: SpotifyTrack] {
        var full: [String: SpotifyTrack] = [:]
        for chunk in stride(from: 0, to: ids.count, by: Self.batchSize).map({ Array(ids[$0..<min($0 + Self.batchSize, ids.count)]) }) {
            let joined = chunk.joined(separator: ",")
            do {
                let data = try await get(path: "/tracks?ids=\(joined)", describing: "tracks")
                guard let response = try? JSONDecoder().decode(APITrackList.self, from: data) else { continue }
                for api in response.tracks ?? [] {
                    guard let track = Self.normalize(api, albumFallback: nil) else { continue }
                    full[track.id] = track
                }
            } catch {
                if isCancellation(error) { throw error }
                appLog("Couldn't re-read \(chunk.count) album track(s) for their ISRCs: \(error.localizedDescription) — matching on title instead.",
                       level: .warning, category: Self.category)
            }
        }
        return full
    }

    /// Re-reads simplified album tracks as full track objects so they carry
    /// an ISRC (and popularity). Best-effort: anything the batch didn't
    /// return keeps its simplified object with the album's name carried down.
    private func fullTracks(for simplified: [APITrack], albumFallback: String,
                            imageFallback: String? = nil) async throws -> [SpotifyTrack] {
        let full = try await fullTrackTable(for: simplified.compactMap { $0.id })
        return simplified.compactMap { api in
            if let id = api.id, let track = full[id] { return track }
            return Self.normalize(api, albumFallback: albumFallback, imageFallback: imageFallback)
        }
    }

    // MARK: - Normalization

    /// Turns one API track object into our own shape, rejecting anything that
    /// isn't a usable track (a null entry, an episode, a local file).
    private static func normalize(_ api: APITrack, albumFallback: String?,
                                  imageFallback: String? = nil) -> SpotifyTrack? {
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
                            trackNumber: api.trackNumber,
                            albumImageURL: api.album?.images?.first?.url ?? imageFallback,
                            popularity: api.popularity)
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

    /// How long a request will *wait out* a rate-limit window (sleep, then
    /// proceed) before giving up and surfacing the 429 instead.
    private static let maxRateLimitWait: TimeInterval = 30

    /// A bearer GET. Refreshes the token and retries **once** on a 401 (the
    /// cached token can expire between the check and the call); waits out —
    /// or fails fast against — any rate-limit window `SpotifyRateLimiter`
    /// knows about, records the `Retry-After` of any 429 it meets (and
    /// retries once when it's short); then maps the status onto a typed error.
    private func get(_ url: URL, describing what: String) async throws -> Data {
        // Sending during a known window is what makes Spotify extend it —
        // hold here instead, however unrelated this particular read is.
        let cooldown = await SpotifyRateLimiter.shared.remainingCooldown(for: clientID)
        if cooldown > 0 {
            guard cooldown <= Self.maxRateLimitWait else {
                // Logged distinctly from a server 429, so "the app is
                // waiting out a recorded window" and "Spotify answered 429
                // again" can't be confused in the Log.
                appLog("Spotify: \(Int(max(1, (cooldown / 60).rounded()))) min left of the recorded rate-limit window — the \(what) request was not sent.",
                       level: .warning, category: Self.category)
                throw SpotifyError.http(429, Self.rateLimitMessage(wait: cooldown))
            }
            appLog("Spotify: holding \(Int(cooldown.rounded()))s for the rate limit before reading the \(what).",
                   level: .debug, category: Self.category)
            try await Task.sleep(nanoseconds: UInt64(cooldown * 1_000_000_000))
        }

        var bearer = try await token()
        var (data, status, response) = try await send(url, bearer: bearer)
        if status == 401 {
            await SpotifyTokenCache.shared.invalidate()
            bearer = try await token(forceRefresh: true)
            (data, status, response) = try await send(url, bearer: bearer)
        }
        if status == 429 {
            let retryAfter = Self.retryAfterSeconds(from: response) ?? 5
            await SpotifyRateLimiter.shared.noteRateLimited(for: retryAfter, clientID: clientID)
            appLog("Spotify rate limited reading the \(what) — Retry-After \(Int(retryAfter))s.",
                   level: .warning, category: Self.category)
            if retryAfter <= Self.maxRateLimitWait {
                try await Task.sleep(nanoseconds: UInt64((retryAfter + 1) * 1_000_000_000))
                (data, status, response) = try await send(url, bearer: bearer)
                if status == 429 {
                    let again = Self.retryAfterSeconds(from: response) ?? retryAfter
                    await SpotifyRateLimiter.shared.noteRateLimited(for: again, clientID: clientID)
                }
            }
        }
        guard (200..<300).contains(status) else {
            switch status {
            case 401: throw SpotifyError.credentialsRejected
            case 404: throw SpotifyError.notFound(what)
            case 429:
                let wait = await SpotifyRateLimiter.shared.remainingCooldown(for: clientID)
                throw SpotifyError.http(429, Self.rateLimitMessage(wait: wait))
            default: throw SpotifyError.http(status, Self.errorMessage(from: data))
            }
        }
        return data
    }

    private func send(_ url: URL, bearer: String) async throws -> (Data, Int, HTTPURLResponse?) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            return (data, http?.statusCode ?? 200, http)
        } catch {
            if isCancellation(error) { throw error }
            throw SpotifyError.network(error.localizedDescription)
        }
    }

    /// The `Retry-After` header of a 429, in seconds, when Spotify sent one.
    private static func retryAfterSeconds(from response: HTTPURLResponse?) -> TimeInterval? {
        guard let raw = response?.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw), seconds > 0 else { return nil }
        return seconds
    }

    /// The user-facing 429 line, with the actual wait when it's known.
    private static func rateLimitMessage(wait: TimeInterval) -> String {
        if wait <= 1 { return "rate limited by Spotify — wait a moment and try again" }
        if wait < 90 { return "rate limited by Spotify — try again in about \(Int(wait.rounded())) seconds" }
        return "rate limited by Spotify — try again in about \(Int((wait / 60).rounded())) minutes"
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
    let popularity: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, type, artists, album, popularity
        case durationMS = "duration_ms"
        case externalIDs = "external_ids"
        case trackNumber = "track_number"
        case isLocal = "is_local"
    }
}

private struct APIArtist: Decodable {
    let id: String?
    let name: String?
    /// Present on full artist objects (`/artists/{id}`, search hits), largest
    /// first; absent on the slim artist stubs inside track objects.
    let images: [APIImage]?
    /// Full artist objects only: Spotify's own 0–100 popularity score and the
    /// genre labels it files the artist under. Both feed the Every Noise
    /// dataset harvest; nil everywhere the object is a stub.
    let popularity: Int?
    let genres: [String]?
}

/// One entry of Spotify's `images` arrays (albums, artists, playlists).
private struct APIImage: Decodable {
    let url: String?
    let width: Int?
    let height: Int?
}

/// The `/search?type=artist` envelope: a paging object under an "artists" key.
private struct APIArtistSearch: Decodable {
    let artists: APIPage<APIArtist>?
}

/// The `/search?type=track` envelope: a paging object under a "tracks" key.
private struct APITrackSearch: Decodable {
    let tracks: APIPage<APITrack>?
}

private struct APIAlbum: Decodable {
    /// Present on batch (`/albums?ids=`) entries, where it keys the result;
    /// unused on the single-album read.
    let id: String?
    let name: String?
    let images: [APIImage]?
    let tracks: APIPage<APITrack>?
}

/// The `/albums?ids=` envelope. Entries are positional and can be null (an
/// unknown id), so the array is of optionals.
private struct APIAlbumBatch: Decodable {
    let albums: [APIAlbum?]?
}

/// A row of `/artists/{id}/albums` — the summary form, no tracklist.
private struct APIAlbumSummary: Decodable {
    let id: String?
    let name: String?
    let releaseDate: String?
    let albumGroup: String?
    let albumType: String?
    let totalTracks: Int?
    let images: [APIImage]?

    enum CodingKeys: String, CodingKey {
        case id, name, images
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
