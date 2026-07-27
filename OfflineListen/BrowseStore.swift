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

    /// A source's items, newest first (feed publish date when known, fetch
    /// date otherwise), discarded ones excluded.
    func visibleItems(for sourceID: UUID) -> [BrowseItem] {
        items
            .filter { $0.sourceID == sourceID && $0.status != .discarded }
            .sorted { ($0.datePublished ?? $0.dateFetched) > ($1.datePublished ?? $1.dateFetched) }
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
    func addSource(kind: BrowseSourceKind, name: String, input: String, era: String? = nil) -> BrowseSource {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Feed sources may leave the name blank — it's filled from the feed's
        // own title on first refresh. AI sources read naturally as their input
        // (with the era folded in for an era-scoped Country source).
        var fallbackName = trimmedInput.isEmpty ? kind.displayName : trimmedInput
        if let era { fallbackName += " (\(era))" }
        let source = BrowseSource(kind: kind,
                                  name: trimmedName.isEmpty ? fallbackName : trimmedName,
                                  input: trimmedInput,
                                  era: era)
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
                fetched = try await DiscographyAgent.fetch(source: source, settings: aiSettings).items
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
        for candidate in fetched {
            let key = candidate.dedupKey
            if let index = known[key] {
                items[index].title = candidate.title
                if !candidate.detail.isEmpty { items[index].detail = candidate.detail }
                if let published = candidate.datePublished { items[index].datePublished = published }
                if let postTitle = candidate.postTitle { items[index].postTitle = postTitle }
                if let postURL = candidate.postURL { items[index].postURL = postURL }
            } else {
                let item = BrowseItem(sourceID: sourceID,
                                      title: candidate.title,
                                      detail: candidate.detail,
                                      url: candidate.url,
                                      videoID: candidate.videoID,
                                      datePublished: candidate.datePublished,
                                      postTitle: candidate.postTitle,
                                      postURL: candidate.postURL,
                                      groupKey: candidate.groupKey)
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
        } catch {
            print("[BrowseStore] failed to decode index: \(error)")
        }
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
