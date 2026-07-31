import Foundation

/// Owns the Browse tab's state: the configured sources, the items discovered
/// for each, and refresh orchestration. Persists everything to
/// `Documents/browse.json` so curation (saved/discarded decisions) survives
/// relaunches and refreshes.
@MainActor
final class BrowseStore: ObservableObject {
    @Published private(set) var sources: [BrowseSource] = []
    @Published private(set) var items: [BrowseItem] = []
    /// Blog Agent articles (summary + mentioned artists), keyed to their source.
    /// Separate from `items` because a post can carry a summary/artist list with
    /// no playable tracks at all.
    @Published private(set) var posts: [BrowsePost] = []
    /// Sources with a refresh in flight (spinners in the UI).
    @Published private(set) var refreshing: Set<UUID> = []
    /// Sources with a "More" page in flight (the button shows a spinner).
    @Published private(set) var loadingMore: Set<UUID> = []
    /// Most recent refresh error per source, cleared on the next success.
    @Published private(set) var lastError: [UUID: String] = [:]

    /// The mode Browse's Download/Preview buttons act in — the Audio/Video
    /// toggle beside the Browse title. Persisted so the choice sticks.
    @Published var downloadMode: DownloadMode {
        didSet { UserDefaults.standard.set(downloadMode.rawValue, forKey: Self.downloadModeKey) }
    }
    private static let downloadModeKey = "browseDownloadMode"

    /// Needed by the AI kinds (artist/genre/country) at refresh time.
    private let aiSettings: AISettingsStore

    init(aiSettings: AISettingsStore) {
        self.aiSettings = aiSettings
        let storedMode = UserDefaults.standard.string(forKey: Self.downloadModeKey) ?? ""
        downloadMode = DownloadMode(rawValue: storedMode) ?? .audio
        load()
    }

    // MARK: - Queries

    func sources(of kind: BrowseSourceKind) -> [BrowseSource] {
        sources.filter { $0.kind == kind }
    }

    /// A source's items, discarded ones excluded. Most kinds read newest
    /// first (feed publish date when known, fetch date otherwise) — but a
    /// **YouTube Playlist** is a curated order, not a feed of dated uploads,
    /// so its items keep the position the playlist's page gives them
    /// (`feedPosition`; items from before that field existed sort last, in
    /// the order they were first seen, until the next refresh stamps them).
    func visibleItems(for sourceID: UUID) -> [BrowseItem] {
        let shown = items.filter { $0.sourceID == sourceID && $0.status != .discarded }
        if sources.first(where: { $0.id == sourceID })?.kind == .youtubePlaylist {
            return shown.sorted {
                ($0.feedPosition ?? Int.max, $0.dateFetched) < ($1.feedPosition ?? Int.max, $1.dateFetched)
            }
        }
        return shown.sorted { ($0.datePublished ?? $0.dateFetched) > ($1.datePublished ?? $1.dateFetched) }
    }

    /// How many not-yet-acted-on items a source has (the badge in the list).
    func newCount(for sourceID: UUID) -> Int {
        items.filter { $0.sourceID == sourceID && $0.status == .new }.count
    }

    /// A Blog Agent source's articles, newest first.
    func posts(for sourceID: UUID) -> [BrowsePost] {
        posts
            .filter { $0.sourceID == sourceID }
            .sorted { ($0.datePublished ?? $0.dateFetched) > ($1.datePublished ?? $1.dateFetched) }
    }

    // MARK: - Source management

    @discardableResult
    func addSource(kind: BrowseSourceKind,
                   name: String,
                   input: String,
                   era: String? = nil,
                   artistMode: ArtistSourceMode? = nil) -> BrowseSource {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Feed sources may leave the name blank — it's filled from the feed's
        // own title on first refresh. AI sources read naturally as their input
        // (with the era folded in for an era-scoped Country source).
        var fallbackName = trimmedInput.isEmpty ? kind.displayName : trimmedInput
        if let era { fallbackName += " (\(era))" }
        // Several Artist sources for the same artist — a Top 10 and either
        // discography — would otherwise be identically-named rows.
        if kind == .artist, trimmedName.isEmpty {
            switch artistMode {
            case .discography: fallbackName += " (Discography)"
            case .spotifyDiscography: fallbackName += " (Spotify)"
            default: break
            }
        }
        let source = BrowseSource(kind: kind,
                                  name: trimmedName.isEmpty ? fallbackName : trimmedName,
                                  input: trimmedInput,
                                  era: era,
                                  artistMode: artistMode?.rawValue)
        sources.append(source)
        save()
        appLog("Browse: added \(kind.displayName) source \"\(source.name)\"", category: "Browse")
        return source
    }

    func removeSource(_ source: BrowseSource) {
        sources.removeAll { $0.id == source.id }
        items.removeAll { $0.sourceID == source.id }
        posts.removeAll { $0.sourceID == source.id }
        lastError[source.id] = nil
        // A discography-mode source's cached first pass goes with it.
        try? FileManager.default.removeItem(at: AppPaths.discographyCatalogue(for: source.id))
        save()
        appLog("Browse: removed source \"\(source.name)\"", category: "Browse")
    }

    func renameSource(_ source: BrowseSource, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = sources.firstIndex(where: { $0.id == source.id }) else { return }
        sources[index].name = trimmed
        save()
    }

    // MARK: - Item status

    func markDownloaded(_ item: BrowseItem) {
        setStatus(.downloaded, for: item.id)
    }

    /// Marks several items downloaded in one shot — a single rewrite of the
    /// array (one published change) and a single disk save. The per-item
    /// `setStatus` would fire a full `browse.json` write per call, so a bulk
    /// "Download selected" over a big list (a whole discography) would stall
    /// the main thread on dozens of synchronous writes.
    func markDownloaded(_ picks: [BrowseItem]) {
        let ids = Set(picks.map(\.id))
        guard !ids.isEmpty else { return }
        var updated = items
        var changed = false
        for index in updated.indices where ids.contains(updated[index].id) && updated[index].status != .downloaded {
            updated[index].status = .downloaded
            changed = true
        }
        guard changed else { return }
        items = updated
        save()
    }

    func markSaved(_ item: BrowseItem) {
        setStatus(.saved, for: item.id)
    }

    func markDiscarded(_ item: BrowseItem) {
        setStatus(.discarded, for: item.id)
    }

    /// Records that an item has been auditioned in the preview modal, so its
    /// row can show a filled play icon. Deliberately *not* a status change —
    /// previewing is browsing, not a decision, and the item stays actionable.
    /// A no-op for the transient items the Download tab's search builds.
    func markPreviewed(_ item: BrowseItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              items[index].previewed != true else { return }
        items[index].previewed = true
        save()
    }

    private func setStatus(_ status: BrowseItemStatus, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = status
        save()
    }

    // MARK: - Refresh

    func refreshAll() async {
        // Serially — the fetchers are polite, and the AI kinds each cost an
        // API call plus a page scrape per song.
        for source in sources {
            await refresh(source)
        }
    }

    func refresh(_ source: BrowseSource) async {
        // Discography-mode sources have no item feed to refresh: their
        // album-first catalogue is fetched (and re-fetched) from inside their
        // own screen, which stamps `lastRefreshed` via
        // `saveDiscographyCatalogue`. Refresh-all just passes them by.
        guard !source.usesDiscographyBrowser else { return }
        guard !refreshing.contains(source.id) else { return }
        refreshing.insert(source.id)
        defer { refreshing.remove(source.id) }

        appLog("Browse: refreshing \"\(source.name)\"…", category: "Browse")
        do {
            let fetched: [FetchedBrowseItem]
            var feedTitle: String? = nil
            switch source.kind {
            case .youtubeChannel, .youtubePlaylist:
                let result = try await YouTubeBrowseFeed.fetch(source: source)
                fetched = result.items
                feedTitle = result.feedTitle
                if let resolved = result.resolvedChannelID,
                   let index = sources.firstIndex(where: { $0.id == source.id }) {
                    sources[index].resolvedChannelID = resolved
                }
            case .rssFeed:
                let result = try await RSSBrowseFeed.fetch(source: source)
                fetched = result.items
                feedTitle = result.feedTitle
            case .blogAgent:
                let result = try await BlogAgent.fetch(source: source, settings: aiSettings)
                fetched = result.items
                feedTitle = result.blogTitle
                mergePosts(result.posts, into: source.id)
            case .discography:
                // Unreachable — the guard above returns for every
                // discography-mode source (this legacy kind included).
                return
            case .artist, .genre, .country:
                // Tell the model what it already suggested so refreshes dig
                // deeper instead of repeating (discards included, on purpose).
                let existingTitles = items.filter { $0.sourceID == source.id }.map(\.title)
                fetched = try await AIDiscovery.fetch(source: source,
                                                      settings: aiSettings,
                                                      excludingTitles: existingTitles)
            }

            let added = merge(fetched, into: source.id)

            if let index = sources.firstIndex(where: { $0.id == source.id }) {
                sources[index].lastRefreshed = Date()
                // Adopt the feed's own title when the user left the name as
                // the raw input (URL/handle).
                if let feedTitle, !feedTitle.isEmpty,
                   sources[index].name == sources[index].input || sources[index].name.isEmpty {
                    sources[index].name = feedTitle
                }
            }
            lastError[source.id] = nil
            save()
            appLog("Browse: \"\(source.name)\" refreshed — \(added) new item(s).",
                   level: .success, category: "Browse")
        } catch {
            if isCancellation(error) { return }
            lastError[source.id] = error.localizedDescription
            appLog("Browse: refresh of \"\(source.name)\" failed: \(error.localizedDescription)",
                   level: .error, category: "Browse")
        }
    }

    // MARK: - More

    /// Pulls the **next page** of a source's listing — older uploads from a
    /// channel, the next page of a feed, the next batch of a blog's articles —
    /// and merges it in like a refresh. A refresh always re-reads the *newest*
    /// page, so without this the older half of a source is unreachable.
    ///
    /// The cursor each fetcher hands back is stored on the source, so the next
    /// "More" resumes where this one stopped; a page that returns no cursor (or
    /// nothing new) marks the source exhausted and retires the button.
    func loadMore(_ source: BrowseSource) async {
        guard !loadingMore.contains(source.id), !refreshing.contains(source.id) else { return }
        loadingMore.insert(source.id)
        defer { loadingMore.remove(source.id) }

        appLog("Browse: loading more from \"\(source.name)\"…", category: "Browse")
        do {
            let page: BrowseMorePage
            switch source.kind {
            case .youtubeChannel:
                page = try await YouTubeBrowseFeed.fetchMore(source: source, cursor: source.moreCursor)
            case .rssFeed:
                page = try await RSSBrowseFeed.fetchMore(source: source, cursor: source.moreCursor)
            case .blogAgent:
                let known = Set(posts.filter { $0.sourceID == source.id }.compactMap(\.url))
                page = try await BlogAgent.fetchMore(source: source,
                                                     settings: aiSettings,
                                                     cursor: source.moreCursor,
                                                     knownArticleURLs: known)
            default:
                return
            }

            if !page.posts.isEmpty { mergePosts(page.posts, into: source.id) }
            let added = merge(page.items, into: source.id)

            if let index = sources.firstIndex(where: { $0.id == source.id }) {
                sources[index].moreCursor = page.cursor
                // The cursor alone decides: a page of items we already knew
                // still has a page after it (the first page of a channel's
                // videos overlaps its feed by design), so only running out of
                // cursor means there's no further back to go.
                sources[index].moreExhausted = page.cursor == nil
            }
            lastError[source.id] = nil
            save()
            if added == 0 && page.posts.isEmpty {
                appLog("Browse: \"\(source.name)\" has nothing older to show.",
                       level: .warning, category: "Browse")
            } else {
                appLog("Browse: \"\(source.name)\" — \(added) older item(s) added.",
                       level: .success, category: "Browse")
            }
        } catch {
            if isCancellation(error) { return }
            lastError[source.id] = error.localizedDescription
            appLog("Browse: loading more from \"\(source.name)\" failed: \(error.localizedDescription)",
                   level: .error, category: "Browse")
        }
    }

    /// Merges fetched items into the store: an item already known (same video)
    /// keeps its id and status but picks up fresher metadata; genuinely new
    /// ones are inserted as `.new`. Items that vanished from the feed are kept
    /// — Browse is a running log to curate, not a mirror of the feed's window.
    /// Returns how many were new.
    private func merge(_ fetched: [FetchedBrowseItem], into sourceID: UUID) -> Int {
        var known: [String: Int] = [:]
        for (index, item) in items.enumerated() where item.sourceID == sourceID {
            known[item.dedupKey] = index
        }

        var added = 0
        for (position, candidate) in fetched.enumerated() {
            let key = candidate.dedupKey
            if let index = known[key] {
                items[index].title = candidate.title
                if !candidate.detail.isEmpty { items[index].detail = candidate.detail }
                if let published = candidate.datePublished { items[index].datePublished = published }
                if let postTitle = candidate.postTitle { items[index].postTitle = postTitle }
                if let postURL = candidate.postURL { items[index].postURL = postURL }
                items[index].feedPosition = position
            } else {
                let item = BrowseItem(sourceID: sourceID,
                                      title: candidate.title,
                                      detail: candidate.detail,
                                      url: candidate.url,
                                      videoID: candidate.videoID,
                                      datePublished: candidate.datePublished,
                                      postTitle: candidate.postTitle,
                                      postURL: candidate.postURL,
                                      groupKey: candidate.groupKey,
                                      feedPosition: position)
                items.append(item)
                known[key] = items.count - 1
                added += 1
            }
        }
        return added
    }

    /// Merges fetched Blog Agent posts into the store — an article already known
    /// (same URL) refreshes its summary/artists/date; new ones are appended.
    /// Like items, posts that fall out of the feed are kept.
    private func mergePosts(_ fetched: [FetchedBrowsePost], into sourceID: UUID) {
        var known: [String: Int] = [:]
        for (index, post) in posts.enumerated() where post.sourceID == sourceID {
            known[post.dedupKey] = index
        }
        for candidate in fetched {
            if let index = known[candidate.dedupKey] {
                posts[index].title = candidate.title
                if !candidate.summary.isEmpty { posts[index].summary = candidate.summary }
                if !candidate.artists.isEmpty { posts[index].artists = candidate.artists }
                if let published = candidate.datePublished { posts[index].datePublished = published }
            } else {
                posts.append(BrowsePost(sourceID: sourceID,
                                        title: candidate.title,
                                        url: candidate.url,
                                        summary: candidate.summary,
                                        artists: candidate.artists,
                                        datePublished: candidate.datePublished))
                known[candidate.dedupKey] = posts.count - 1
            }
        }
    }

    // MARK: - Discography catalogues

    /// The saved first pass of a discography-mode Artist source — one JSON
    /// file per source under `Documents/Discographies/`, so re-opening the
    /// source shows the catalogue instantly instead of re-running the fetch
    /// (an AI layout costs a model call; Spotify costs a page walk).
    func loadDiscographyCatalogue(for sourceID: UUID) -> DiscographyCatalogue? {
        guard let data = try? Data(contentsOf: AppPaths.discographyCatalogue(for: sourceID)) else {
            return nil
        }
        return try? JSONDecoder().decode(DiscographyCatalogue.self, from: data)
    }

    /// Persists a freshly fetched first pass and stamps the source's
    /// `lastRefreshed` — the browser's fetch is these sources' refresh.
    func saveDiscographyCatalogue(_ catalogue: DiscographyCatalogue, for sourceID: UUID) {
        do {
            let data = try JSONEncoder().encode(catalogue)
            try data.write(to: AppPaths.discographyCatalogue(for: sourceID), options: .atomic)
        } catch {
            appLog("Couldn't save the discography catalogue: \(error.localizedDescription)",
                   level: .error, category: "Browse")
        }
        if let index = sources.firstIndex(where: { $0.id == sourceID }) {
            sources[index].lastRefreshed = Date()
            lastError[sourceID] = nil
            save()
        }
    }

    // MARK: - Persistence

    private struct BrowseIndex: Codable {
        var sources: [BrowseSource]
        var items: [BrowseItem]
        /// Optional so a `browse.json` written before posts existed still decodes.
        var posts: [BrowsePost]?
    }

    private func load() {
        guard let data = try? Data(contentsOf: AppPaths.browseIndex) else { return }
        do {
            let index = try JSONDecoder().decode(BrowseIndex.self, from: data)
            sources = index.sources
            items = index.items
            posts = index.posts ?? []
            migrateDiscographySources()
        } catch {
            print("[BrowseStore] failed to decode index: \(error)")
        }
    }

    /// Folds the retired `.discography` kind into `.artist` + the Discography
    /// mode. Artist Top 10 and Artist Discography are one source type with two
    /// depths now; this keeps sources created before that merge working (and
    /// listed under "Artists") without touching their items or curation state.
    private func migrateDiscographySources() {
        var migrated = 0
        for index in sources.indices where sources[index].kind == .discography {
            sources[index].kind = .artist
            sources[index].artistMode = ArtistSourceMode.discography.rawValue
            migrated += 1
        }
        guard migrated > 0 else { return }
        save()
        appLog("Browse: migrated \(migrated) Artist Discography source(s) to the merged Artist type.",
               category: "Browse")
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(BrowseIndex(sources: sources, items: items, posts: posts))
            try data.write(to: AppPaths.browseIndex, options: .atomic)
        } catch {
            print("[BrowseStore] failed to save index: \(error)")
        }
    }
}
