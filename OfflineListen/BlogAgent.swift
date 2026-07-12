import Foundation

/// The Browse tab's **Blog Agent**: RSS-reader behaviour for blogs that don't
/// publish a feed. The agent fetches the blog's homepage, asks the model which
/// of the page's links are recent articles (telling posts apart from nav/
/// category/about links is exactly the judgement call heuristics get wrong),
/// reads each article, and harvests the YouTube links inside — one Browse item
/// per video, titled after its article.
///
/// Sites behind bot protection (Cloudflare-style challenges, 403s for
/// non-browser clients) are detected and surfaced as the distinct
/// `agentBlocked` error rather than a generic failure or a silent empty
/// result.
enum BlogAgent {
    /// How many articles one refresh reads. Each costs a page fetch.
    private static let articleLimit = 8
    /// How many homepage links are offered to the model for triage.
    private static let anchorLimit = 150

    struct Result {
        /// The blog's own title (for auto-naming the source).
        var blogTitle: String
        var items: [FetchedBrowseItem]
    }

    static func fetch(source: BrowseSource, settings: AISettingsStore) async throws -> Result {
        guard await settings.isAuthenticated else { throw BrowseFetchError.aiNotConfigured }

        let trimmed = source.input.trimmingCharacters(in: .whitespacesAndNewlines)
        var normalized = trimmed
        if !normalized.lowercased().hasPrefix("http") {
            normalized = "https://\(normalized)"
        }
        guard let homeURL = URL(string: normalized), homeURL.host != nil else {
            throw BrowseFetchError.badInput("Enter the blog's URL (https://…).")
        }

        // 1. Fetch the homepage; a refusal here means the whole site is closed
        //    to the agent.
        let home = try await fetchPage(homeURL)
        let blogTitle = pageTitle(in: home.html) ?? ""

        // 2. Collect the page's links and let the model pick the articles.
        let anchors = collectAnchors(in: home.html, base: home.finalURL)
        guard !anchors.isEmpty else {
            throw BrowseFetchError.badInput("No links found on that page — is it really the blog's homepage?")
        }
        let articleURLs = try await selectArticleURLs(from: anchors, homeURL: home.finalURL, settings: settings)
        guard !articleURLs.isEmpty else {
            throw BrowseFetchError.badInput("The AI couldn't identify any article links on that page.")
        }

        // 3. Read each article and harvest its YouTube links. Serially — the
        //    agent is a polite guest. A single blocked/broken article is
        //    skipped; if *every* article refused the agent, say so.
        var items: [FetchedBrowseItem] = []
        var blockedCount = 0
        var fetchedCount = 0
        for articleURL in articleURLs.prefix(articleLimit) {
            if Task.isCancelled { break }
            let page: Page
            do {
                page = try await fetchPage(articleURL)
            } catch BrowseFetchError.agentBlocked {
                blockedCount += 1
                appLog("Blog agent blocked at \(articleURL.absoluteString) — skipping.",
                       level: .warning, category: "Browse")
                continue
            } catch {
                if isCancellation(error) { throw error }
                appLog("Blog agent couldn't read \(articleURL.absoluteString): \(error.localizedDescription)",
                       level: .warning, category: "Browse")
                continue
            }
            fetchedCount += 1

            let videoIDs = BrowseHTTP.youTubeVideoIDs(in: page.html)
            guard !videoIDs.isEmpty else { continue }

            let articleTitle = pageTitle(in: page.html) ?? articleURL.lastPathComponent
            let description = pageDescription(in: page.html) ?? ""
            let published = pagePublishedDate(in: page.html)
            for (index, videoID) in videoIDs.enumerated() {
                let title = videoIDs.count == 1
                    ? articleTitle
                    : "\(articleTitle) (\(index + 1) of \(videoIDs.count))"
                items.append(FetchedBrowseItem(
                    title: title,
                    detail: description,
                    url: BrowseHTTP.watchURL(forVideoID: videoID),
                    videoID: videoID,
                    datePublished: published
                ))
            }
        }

        if fetchedCount == 0 && blockedCount > 0 {
            throw BrowseFetchError.agentBlocked
        }
        appLog("Blog agent read \(fetchedCount) article(s), found \(items.count) YouTube link(s).",
               category: "Browse")
        return Result(blogTitle: blogTitle, items: items)
    }

    // MARK: - Fetching + block detection

    private struct Page {
        var html: String
        /// The URL after redirects — the base for resolving relative links.
        var finalURL: URL
    }

    private static func fetchPage(_ url: URL) async throws -> Page {
        let (data, status, finalURL) = try await BrowseHTTP.getRaw(url)
        let html = String(decoding: data, as: UTF8.self)
        if isBotBlock(status: status, html: html) {
            throw BrowseFetchError.agentBlocked
        }
        guard (200..<300).contains(status) else {
            throw BrowseFetchError.network("HTTP \(status) from \(url.host ?? "server")")
        }
        return Page(html: html, finalURL: finalURL)
    }

    /// Recognises a bot-protection refusal: the statuses challenge walls use,
    /// or a challenge/captcha interstitial served with a 200.
    static func isBotBlock(status: Int, html: String) -> Bool {
        if status == 403 || status == 429 { return true }
        // Challenge pages are small interstitials; a real article of this
        // shape is vanishingly rare, but keep the sniff to short bodies so a
        // post *about* Cloudflare doesn't false-positive.
        guard html.utf8.count < 60_000 else { return false }
        let t = html.lowercased()
        let signatures = [
            "just a moment...",
            "checking your browser",
            "verify you are human",
            "verifying you are human",
            "enable javascript and cookies to continue",
            "cf-challenge",
            "cf_chl_",
            "attention required! | cloudflare",
            "ddos protection by",
            "captcha-delivery.com",
            "px-captcha",
            "are you a robot",
        ]
        return signatures.contains { t.contains($0) }
    }

    // MARK: - Homepage link triage

    private struct Anchor {
        var url: URL
        var text: String
    }

    /// Pulls the homepage's links: same-site, http(s), non-asset, deduplicated,
    /// capped at `anchorLimit` (page order — blogs list recent posts first).
    private static func collectAnchors(in html: String, base: URL) -> [Anchor] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<a\s[^>]*?href\s*=\s*["']([^"'#]+)["'][^>]*>(.*?)</a>"#,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else { return [] }

        let assetExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "svg", "pdf", "zip", "mp3", "mp4", "css", "js", "xml", "ico"]
        let baseHost = (base.host ?? "").replacingOccurrences(of: "www.", with: "")

        var seen = Set<String>()
        var anchors: [Anchor] = []
        let range = NSRange(html.startIndex..., in: html)
        regex.enumerateMatches(in: html, range: range) { match, _, stop in
            guard let match,
                  let hrefRange = Range(match.range(at: 1), in: html),
                  let textRange = Range(match.range(at: 2), in: html) else { return }
            let href = String(html[hrefRange]).decodedHTMLEntities
            guard !href.hasPrefix("mailto:"), !href.hasPrefix("tel:"), !href.hasPrefix("javascript:"),
                  let url = URL(string: href, relativeTo: base)?.absoluteURL,
                  url.scheme == "http" || url.scheme == "https" else { return }

            // Same site only (www. differences tolerated) — the articles we
            // want live on the blog itself.
            let host = (url.host ?? "").replacingOccurrences(of: "www.", with: "")
            guard host == baseHost else { return }
            guard !assetExtensions.contains(url.pathExtension.lowercased()) else { return }
            // Skip the homepage itself.
            guard url.path != base.path || url.query != base.query else { return }
            guard seen.insert(url.absoluteString).inserted else { return }

            let text = String(html[textRange]).strippedHTML
                .replacingOccurrences(of: "\n", with: " ")
            anchors.append(Anchor(url: url, text: String(text.prefix(80))))
            if anchors.count >= anchorLimit { stop.pointee = true }
        }
        return anchors
    }

    /// Asks the model which of the homepage's links are individual recent
    /// articles. Returns them newest-first as judged by the model, capped at
    /// `articleLimit`.
    private static func selectArticleURLs(from anchors: [Anchor],
                                          homeURL: URL,
                                          settings: AISettingsStore) async throws -> [URL] {
        let client = await AnthropicClient(apiKey: settings.apiKey, model: settings.model)

        let listing = anchors
            .map { "\($0.url.absoluteString) — \($0.text.isEmpty ? "(no text)" : $0.text)" }
            .joined(separator: "\n")
        let raw = try await client.complete(
            system: """
            You triage links scraped from a blog's homepage. Identify the links \
            that point to individual articles/posts on that blog — not \
            navigation, category/tag/archive pages, author pages, about/contact, \
            login/subscribe, or pagination.

            Respond with ONLY a JSON array of URL strings and nothing else — no \
            markdown, no commentary. List the most recent-looking articles \
            first, at most \(articleLimit). Use the URLs exactly as given. If \
            nothing looks like an article, return [].
            """,
            userText: "Blog homepage: \(homeURL.absoluteString)\n\nLinks (URL — link text):\n\(listing)",
            maxTokens: 1000
        )

        guard let start = raw.firstIndex(of: "["),
              let end = raw.lastIndex(of: "]"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return []
        }
        // Only accept URLs that were actually on the page — the model must
        // pick, not invent.
        let offered = Set(anchors.map { $0.url.absoluteString })
        return array
            .compactMap { $0 as? String }
            .filter { offered.contains($0) }
            .compactMap { URL(string: $0) }
    }

    // MARK: - Article metadata scraping

    /// og:title, falling back to `<title>`.
    static func pageTitle(in html: String) -> String? {
        let title = metaContent(property: "og:title", in: html)
            ?? BrowseHTTP.firstMatch(#"<title[^>]*>([\s\S]*?)</title>"#, in: html)
        let cleaned = title?.decodedHTMLEntities.trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned?.isEmpty ?? true) ? nil : cleaned
    }

    /// og:description, falling back to the description meta tag.
    static func pageDescription(in html: String) -> String? {
        let description = metaContent(property: "og:description", in: html)
            ?? metaContent(name: "description", in: html)
        let cleaned = description?.decodedHTMLEntities.trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned?.isEmpty ?? true) ? nil : cleaned
    }

    /// article:published_time (ISO 8601), when the page carries one.
    static func pagePublishedDate(in html: String) -> Date? {
        guard let stamp = metaContent(property: "article:published_time", in: html) else { return nil }
        return FeedParser.parseDate(stamp)
    }

    /// Reads `<meta property="…" content="…">`, tolerating either attribute
    /// order.
    private static func metaContent(property: String, in html: String) -> String? {
        metaContent(attribute: "property", value: property, in: html)
            ?? metaContent(attribute: "name", value: property, in: html)
    }

    private static func metaContent(name: String, in html: String) -> String? {
        metaContent(attribute: "name", value: name, in: html)
    }

    private static func metaContent(attribute: String, value: String, in html: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: value)
        return BrowseHTTP.firstMatch(
            #"<meta[^>]*\#(attribute)\s*=\s*["']\#(escaped)["'][^>]*content\s*=\s*["']([^"']*)["']"#,
            in: html
        ) ?? BrowseHTTP.firstMatch(
            #"<meta[^>]*content\s*=\s*["']([^"']*)["'][^>]*\#(attribute)\s*=\s*["']\#(escaped)["']"#,
            in: html
        )
    }
}
