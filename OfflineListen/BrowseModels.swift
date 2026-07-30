import Foundation

/// The kinds of audio source the Browse tab can keep tabs on. Three are
/// feed-driven (scrape/RSS) and three are AI-driven (the model suggests popular
/// songs, which are then resolved to real YouTube links via a search scrape).
enum BrowseSourceKind: String, Codable, CaseIterable, Identifiable {
    case youtubeChannel
    case youtubePlaylist
    case rssFeed
    case blogAgent
    /// **Legacy.** Artist Discography used to be its own kind; it's now the
    /// `.discography` *mode* of an `.artist` source. The case survives only so
    /// a `browse.json` written before the merge still decodes — `BrowseStore`
    /// migrates any such source to `.artist` on load, and `addable` keeps it
    /// out of the UI, so nothing creates one any more.
    case discography
    case artist
    case genre
    case country

    var id: String { rawValue }

    /// The kinds offered in the "+" menu and used to section the source list —
    /// every case except the legacy `.discography` shim.
    static var addable: [BrowseSourceKind] { allCases.filter { $0 != .discography } }

    var displayName: String {
        switch self {
        case .youtubeChannel: return "YouTube Channel"
        case .youtubePlaylist: return "YouTube Playlist"
        case .rssFeed: return "RSS Feed"
        case .blogAgent: return "Blog Agent"
        case .discography: return "Artist Discography"
        case .artist: return "Artist"
        case .genre: return "Genre"
        case .country: return "Country"
        }
    }

    /// Section header in the Browse tab.
    var pluralName: String {
        switch self {
        case .youtubeChannel: return "YouTube Channels"
        case .youtubePlaylist: return "YouTube Playlists"
        case .rssFeed: return "RSS Feeds"
        case .blogAgent: return "Blog Agents"
        case .discography: return "Artist Discographies"
        case .artist: return "Artists"
        case .genre: return "Genres"
        case .country: return "Countries"
        }
    }

    /// Whether the source can be asked for **more** — an older page of what it
    /// lists. The feed kinds cap out at what one page carries (a YouTube feed
    /// at 15 entries, an RSS feed at its window, the Blog Agent at its
    /// per-refresh article limit), so a "More" button pulls the next page.
    /// The AI kinds already dig deeper on every refresh, so they don't need one.
    var supportsMore: Bool {
        switch self {
        case .youtubeChannel, .rssFeed, .blogAgent: return true
        case .youtubePlaylist, .discography, .artist, .genre, .country: return false
        }
    }

    var systemImage: String {
        switch self {
        case .youtubeChannel: return "person.crop.rectangle"
        case .youtubePlaylist: return "list.and.film"
        case .rssFeed: return "dot.radiowaves.up.forward"
        case .blogAgent: return "doc.text.magnifyingglass"
        case .discography: return "square.stack"
        case .artist: return "music.mic"
        case .genre: return "guitars"
        case .country: return "globe"
        }
    }

    /// AI-driven kinds need an Anthropic key (Settings) to refresh. The Blog
    /// Agent counts: it uses the model to tell article links apart from the
    /// rest of a homepage; the Discography agent uses it to lay out an artist's
    /// catalogue.
    var usesAI: Bool {
        switch self {
        case .blogAgent, .discography, .artist, .genre, .country: return true
        case .youtubeChannel, .youtubePlaylist, .rssFeed: return false
        }
    }

    /// Whether the input field takes a URL/handle (URL keyboard, no
    /// autocapitalization) rather than free text like an artist name.
    var inputIsURL: Bool {
        switch self {
        case .youtubeChannel, .youtubePlaylist, .rssFeed, .blogAgent: return true
        case .discography, .artist, .genre, .country: return false
        }
    }

    /// Whether the source can be scoped to a decade (the AI music kinds:
    /// early Dylan, 1980s synth-pop, 1970s Mali). An Artist source only offers
    /// it in Top 10 mode — a Discography spans the artist's whole catalogue —
    /// which is why the add sheet consults `ArtistSourceMode.supportsEra` too.
    var supportsEra: Bool {
        switch self {
        case .artist, .genre, .country: return true
        case .youtubeChannel, .youtubePlaylist, .rssFeed, .blogAgent, .discography: return false
        }
    }

    /// Placeholder for the add-source input field.
    var inputPlaceholder: String {
        switch self {
        case .youtubeChannel: return "Channel URL or @handle"
        case .youtubePlaylist: return "Playlist URL or ID"
        case .rssFeed: return "Feed URL"
        case .blogAgent: return "Blog URL"
        case .discography: return "Artist name"
        case .artist: return "Artist name"
        case .genre: return "Genre (e.g. Bossa Nova)"
        case .country: return "Country (e.g. Mali)"
        }
    }

    /// One-line explanation shown in the add-source sheet.
    var help: String {
        switch self {
        case .youtubeChannel:
            return "Watches the channel's upload feed for new videos."
        case .youtubePlaylist:
            return "Watches the playlist's feed for entries."
        case .rssFeed:
            return "Reads the feed and keeps only posts that contain YouTube links."
        case .blogAgent:
            return "For blogs without a feed: an AI agent reads recent articles and shows each as a summary, its YouTube links, and the artists it mentions (tap one to follow that artist)."
        case .discography, .artist:
            return "Follow one artist: an AI Top 10, an AI-laid-out discography, or their real discography from Spotify."
        case .genre:
            return "AI suggests popular songs in the genre and finds them on YouTube."
        case .country:
            return "AI suggests popular songs from the country and finds them on YouTube."
        }
    }
}

/// The decades an AI music source (Artist/Genre/Country) can be scoped to.
enum BrowseEra {
    static let decades = ["1950s", "1960s", "1970s", "1980s", "1990s", "2000s", "2010s", "2020s"]
}

/// What an **Artist** source follows. Picked in the add sheet — the modes used
/// to be separate source kinds, which made the "+" menu read as unrelated
/// things rather than one artist with several depths. The two discography
/// modes share the album-first browser (`DiscographyBrowserView`): the first
/// pass shows just albums and song names, and each album's tracks are matched
/// against YouTube when you search it. They differ only in where the
/// catalogue comes from — the AI's layout, or Spotify's real one.
enum ArtistSourceMode: String, Codable, CaseIterable, Identifiable {
    case topTracks
    case discography
    case spotifyDiscography

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .topTracks: return "Top 10"
        case .discography: return "Search Discography"
        case .spotifyDiscography: return "Spotify Discography"
        }
    }

    var help: String {
        switch self {
        case .topTracks:
            return "AI finds the artist's 10 most popular tracks on YouTube, digging deeper on each refresh."
        case .discography:
            return "An AI agent lays out the artist's albums and song names, with a Highlights list on top. Search an album to match its tracks against YouTube."
        case .spotifyDiscography:
            return "Reads the artist's real discography live from Spotify — a pinned Top 10, then every release. Search a release to match its tracks against YouTube. Needs the Settings ▸ Spotify credentials."
        }
    }

    /// Only Top 10 can be scoped to a decade — a discography spans the
    /// artist's whole catalogue by definition.
    var supportsEra: Bool { self == .topTracks }

    /// Whether refreshing this mode calls the Anthropic API. The Spotify
    /// discography needs no AI key — only the Spotify credentials.
    var usesAI: Bool { self != .spotifyDiscography }
}

/// One configured source inside the Browse tab (a channel, a feed, an artist…).
struct BrowseSource: Identifiable, Codable, Hashable {
    let id: UUID
    var kind: BrowseSourceKind
    /// Display name. For feed kinds this is filled from the feed's own title on
    /// first refresh when the user left it blank.
    var name: String
    /// What the user typed: a URL/handle/id for the feed kinds, or the artist/
    /// genre/country for the AI kinds.
    var input: String
    var dateAdded: Date
    var lastRefreshed: Date?
    /// Cached YouTube channel id (`UC…`) once resolved from a handle/vanity URL,
    /// so later refreshes skip the page scrape.
    var resolvedChannelID: String?
    /// The decade an AI music source (Artist/Genre/Country) is scoped to
    /// (one of `BrowseEra.decades`). Nil means any era — and nil for every
    /// kind that doesn't support one.
    var era: String?
    /// What an `.artist` source follows (`ArtistSourceMode`). Nil — including
    /// on every source written before the modes merged — reads as Top 10.
    var artistMode: String?
    /// Opaque per-kind cursor for the **More** button: a YouTube continuation
    /// token, the next feed page's URL, or how many articles the Blog Agent has
    /// already read. Nil before the first "More".
    var moreCursor: String?
    /// Set once a "More" pull came back with nothing further — the button then
    /// reads "No more items" instead of pretending there's another page.
    var moreExhausted: Bool?

    init(id: UUID = UUID(),
         kind: BrowseSourceKind,
         name: String,
         input: String,
         dateAdded: Date = Date(),
         lastRefreshed: Date? = nil,
         resolvedChannelID: String? = nil,
         era: String? = nil,
         artistMode: String? = nil,
         moreCursor: String? = nil,
         moreExhausted: Bool? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.input = input
        self.dateAdded = dateAdded
        self.lastRefreshed = lastRefreshed
        self.resolvedChannelID = resolvedChannelID
        self.era = era
        self.artistMode = artistMode
        self.moreCursor = moreCursor
        self.moreExhausted = moreExhausted
    }

    /// What this source follows when it's an Artist source. Anything else
    /// reads as Top 10 and never consults it.
    var artistSourceMode: ArtistSourceMode {
        artistMode.flatMap(ArtistSourceMode.init(rawValue:)) ?? .topTracks
    }

    /// True when the source lays out a whole discography — either an Artist
    /// source in Discography mode or a legacy `.discography` source that
    /// hasn't been migrated yet. Drives the album-grouped list layout.
    var isDiscography: Bool {
        kind == .discography || (kind == .artist && artistSourceMode == .discography)
    }

    /// True when opening the source shows the album-first discography browser
    /// (`ArtistDiscographySourceView`) instead of the item list — both
    /// discography modes, from either catalogue. These sources carry no
    /// Browse items and don't take part in the item-refresh pipeline; their
    /// first pass is fetched (and cached) by the browser itself.
    var usesDiscographyBrowser: Bool {
        kind == .discography || (kind == .artist && artistSourceMode != .topTracks)
    }

    /// Whether the "More" button should be offered: the kind pages at all, and
    /// a previous pull hasn't reported the end.
    var canLoadMore: Bool { kind.supportsMore && moreExhausted != true }
}

/// What the user has done with a browse item. `discarded` items stay in the
/// store (hidden from the list) so a refresh doesn't resurrect them.
enum BrowseItemStatus: String, Codable {
    case new
    case downloaded
    case saved
    case discarded
}

/// One discovered song/video inside a source: a YouTube link plus metadata.
struct BrowseItem: Identifiable, Codable, Hashable {
    let id: UUID
    var sourceID: UUID
    var title: String
    /// Description when the source provides one (feed description, AI note).
    /// Empty when there isn't any.
    var detail: String
    /// The YouTube watch link the Download/Preview actions act on.
    var url: String
    /// The 11-character YouTube video id when known — the dedup key across
    /// refreshes (falls back to `url`).
    var videoID: String?
    var datePublished: Date?
    var dateFetched: Date
    var status: BrowseItemStatus
    /// The post/article (Blog Agent) or album (Discography) the item came from,
    /// so the list can group tracks under their section. Nil for sources
    /// without that structure — and for items saved before these fields existed.
    var postTitle: String?
    var postURL: String?
    /// Set once the user has opened this item in the preview modal, so the row
    /// can show a filled play icon — the same "you've already been here" cue
    /// the Download action gets, without changing the item's status (previewing
    /// is browsing, not a decision).
    var previewed: Bool?
    /// A dedup discriminator for grouped sources where the *same* video may
    /// legitimately appear in more than one section — notably a Discography's
    /// Highlights track that is also a track on one of its albums. When set it
    /// is folded into `dedupKey` so those stay separate items. Nil elsewhere
    /// (Blog Agent keeps collapsing a video shared across posts to one item).
    var groupKey: String?

    init(id: UUID = UUID(),
         sourceID: UUID,
         title: String,
         detail: String = "",
         url: String,
         videoID: String? = nil,
         datePublished: Date? = nil,
         dateFetched: Date = Date(),
         status: BrowseItemStatus = .new,
         postTitle: String? = nil,
         postURL: String? = nil,
         previewed: Bool? = nil,
         groupKey: String? = nil) {
        self.id = id
        self.sourceID = sourceID
        self.title = title
        self.detail = detail
        self.url = url
        self.videoID = videoID
        self.datePublished = datePublished
        self.dateFetched = dateFetched
        self.status = status
        self.postTitle = postTitle
        self.postURL = postURL
        self.previewed = previewed
        self.groupKey = groupKey
    }

    /// Whether this item has been auditioned in the preview modal.
    var wasPreviewed: Bool { previewed == true }

    /// Identity across refreshes: the video id when known, else the URL —
    /// prefixed by `groupKey` when the source keeps per-section copies of a
    /// video (Discography).
    var dedupKey: String { Self.dedupKey(videoID: videoID, url: url, groupKey: groupKey) }

    /// Shared so `FetchedBrowseItem` computes the exact same key the merge
    /// looks up by.
    static func dedupKey(videoID: String?, url: String, groupKey: String?) -> String {
        let base = videoID ?? url
        guard let groupKey else { return base }
        return "\(groupKey)\u{1}\(base)"
    }
}

/// What a fetcher hands back for one discovered link, before the store merges
/// it with what it already knows (existing items keep their id and status).
struct FetchedBrowseItem {
    var title: String
    var detail: String
    var url: String
    var videoID: String?
    var datePublished: Date?
    /// The post (Blog Agent) or album (Discography) the item was found in, for
    /// grouping.
    var postTitle: String? = nil
    var postURL: String? = nil
    /// Per-section dedup discriminator (see `BrowseItem.groupKey`).
    var groupKey: String? = nil

    /// The identity the store merges by — matches `BrowseItem.dedupKey`.
    var dedupKey: String { BrowseItem.dedupKey(videoID: videoID, url: url, groupKey: groupKey) }
}

/// One page of *older* items from a source, fetched by the "More" button.
/// `cursor` is what the next "More" should pass back (nil when the source has
/// nothing further to give — the button then retires).
struct BrowseMorePage {
    var items: [FetchedBrowseItem] = []
    /// Blog Agent articles, when the source has them.
    var posts: [FetchedBrowsePost] = []
    var cursor: String? = nil
}

/// A Blog Agent article: a short summary and the artists it names, shown around
/// the YouTube tracks found in the same article (summary above, artists below).
/// A post can exist with **no** tracks — a text-only write-up — which is why
/// it's its own record rather than metadata hung off a track. Its tracks tie
/// back by `url` matching a `BrowseItem`'s `postURL`.
struct BrowsePost: Identifiable, Codable, Hashable {
    let id: UUID
    var sourceID: UUID
    var title: String
    /// The article URL, when known — the grouping/dedup key for its tracks.
    var url: String?
    /// A one-or-two-sentence plain-language summary of the article.
    var summary: String
    /// The artists the article names, most prominent first, for the tappable
    /// "create a source for this artist" list.
    var artists: [String]
    var datePublished: Date?
    var dateFetched: Date

    init(id: UUID = UUID(),
         sourceID: UUID,
         title: String,
         url: String? = nil,
         summary: String = "",
         artists: [String] = [],
         datePublished: Date? = nil,
         dateFetched: Date = Date()) {
        self.id = id
        self.sourceID = sourceID
        self.title = title
        self.url = url
        self.summary = summary
        self.artists = artists
        self.datePublished = datePublished
        self.dateFetched = dateFetched
    }

    /// Identity across refreshes: the article URL when known, else the title.
    var dedupKey: String { url ?? title }
}

/// What the Blog Agent hands back for one article before the store merges it.
struct FetchedBrowsePost {
    var title: String
    var url: String?
    var summary: String
    var artists: [String]
    var datePublished: Date?

    var dedupKey: String { url ?? title }
}

extension AppPaths {
    static var browseIndex: URL {
        documents.appendingPathComponent("browse.json")
    }

    /// Scratch directory for preview downloads (separate from the download
    /// queue's work dir so an in-flight job can't clobber a playing preview).
    static var previews: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
