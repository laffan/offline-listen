import Foundation

/// The kinds of audio source the Browse tab can keep tabs on. Three are
/// feed-driven (scrape/RSS) and three are AI-driven (the model suggests popular
/// songs, which are then resolved to real YouTube links via a search scrape).
enum BrowseSourceKind: String, Codable, CaseIterable, Identifiable {
    case youtubeChannel
    case youtubePlaylist
    case rssFeed
    case blogAgent
    case artist
    case genre
    case country

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .youtubeChannel: return "YouTube Channel"
        case .youtubePlaylist: return "YouTube Playlist"
        case .rssFeed: return "RSS Feed"
        case .blogAgent: return "Blog Agent"
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
        case .artist: return "Artists"
        case .genre: return "Genres"
        case .country: return "Countries"
        }
    }

    var systemImage: String {
        switch self {
        case .youtubeChannel: return "person.crop.rectangle"
        case .youtubePlaylist: return "list.and.film"
        case .rssFeed: return "dot.radiowaves.up.forward"
        case .blogAgent: return "doc.text.magnifyingglass"
        case .artist: return "music.mic"
        case .genre: return "guitars"
        case .country: return "globe"
        }
    }

    /// AI-driven kinds need an Anthropic key (Settings) to refresh. The Blog
    /// Agent counts: it uses the model to tell article links apart from the
    /// rest of a homepage.
    var usesAI: Bool {
        switch self {
        case .blogAgent, .artist, .genre, .country: return true
        case .youtubeChannel, .youtubePlaylist, .rssFeed: return false
        }
    }

    /// Whether the input field takes a URL/handle (URL keyboard, no
    /// autocapitalization) rather than free text like an artist name.
    var inputIsURL: Bool {
        switch self {
        case .youtubeChannel, .youtubePlaylist, .rssFeed, .blogAgent: return true
        case .artist, .genre, .country: return false
        }
    }

    /// Placeholder for the add-source input field.
    var inputPlaceholder: String {
        switch self {
        case .youtubeChannel: return "Channel URL or @handle"
        case .youtubePlaylist: return "Playlist URL or ID"
        case .rssFeed: return "Feed URL"
        case .blogAgent: return "Blog URL"
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
            return "For blogs without a feed: an AI agent visits the site, reads recent articles, and pulls out the YouTube links inside them."
        case .artist:
            return "AI suggests the artist's popular songs and finds them on YouTube."
        case .genre:
            return "AI suggests popular songs in the genre and finds them on YouTube."
        case .country:
            return "AI suggests popular songs from the country and finds them on YouTube."
        }
    }
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

    init(id: UUID = UUID(),
         kind: BrowseSourceKind,
         name: String,
         input: String,
         dateAdded: Date = Date(),
         lastRefreshed: Date? = nil,
         resolvedChannelID: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.input = input
        self.dateAdded = dateAdded
        self.lastRefreshed = lastRefreshed
        self.resolvedChannelID = resolvedChannelID
    }
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

    init(id: UUID = UUID(),
         sourceID: UUID,
         title: String,
         detail: String = "",
         url: String,
         videoID: String? = nil,
         datePublished: Date? = nil,
         dateFetched: Date = Date(),
         status: BrowseItemStatus = .new) {
        self.id = id
        self.sourceID = sourceID
        self.title = title
        self.detail = detail
        self.url = url
        self.videoID = videoID
        self.datePublished = datePublished
        self.dateFetched = dateFetched
        self.status = status
    }

    /// Identity across refreshes: the video id when known, else the URL.
    var dedupKey: String { videoID ?? url }
}

/// What a fetcher hands back for one discovered link, before the store merges
/// it with what it already knows (existing items keep their id and status).
struct FetchedBrowseItem {
    var title: String
    var detail: String
    var url: String
    var videoID: String?
    var datePublished: Date?
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
