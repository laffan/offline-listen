import Foundation

/// A parsed RSS/Atom feed reduced to what Browse needs.
struct ParsedFeed {
    var title: String
    var entries: [ParsedFeedEntry]
}

struct ParsedFeedEntry {
    var title: String = ""
    var link: String = ""
    /// Item description/summary, HTML tags stripped.
    var summary: String = ""
    /// Raw HTML bodies (description/content:encoded/media:description) kept
    /// unstripped so link extraction can find YouTube URLs inside markup.
    var rawBodies: [String] = []
    var published: Date?
    /// `<yt:videoId>` from YouTube's own feeds, when present.
    var videoID: String?
}

/// Minimal event-driven parser covering the two feed dialects Browse meets:
/// RSS 2.0 (`<rss><channel><item>`) and Atom (`<feed><entry>`) — the latter is
/// what YouTube's channel/playlist feeds speak. Namespaced elements arrive with
/// their prefixes (`yt:videoId`, `media:description`) since namespace
/// processing is off.
final class FeedParser: NSObject, XMLParserDelegate {
    static func parse(_ data: Data) -> ParsedFeed? {
        let delegate = FeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        // A malformed byte mid-feed shouldn't throw away the entries already
        // parsed, so a failed `parse()` still returns what was collected.
        parser.parse()
        guard delegate.sawFeedRoot else { return nil }
        return ParsedFeed(title: delegate.feedTitle, entries: delegate.entries)
    }

    private var sawFeedRoot = false
    private var feedTitle = ""
    private var entries: [ParsedFeedEntry] = []

    private var inEntry = false
    private var current = ParsedFeedEntry()
    private var text = ""
    /// Nesting guard so `<title>` inside `<media:group>` etc. doesn't clobber
    /// the entry title.
    private var elementStack: [String] = []

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        elementStack.append(elementName)
        if elementStack.count == 1, ["rss", "feed", "rdf:RDF"].contains(elementName) {
            sawFeedRoot = true
        }

        switch elementName {
        case "item", "entry":
            inEntry = true
            current = ParsedFeedEntry()
        case "link" where inEntry:
            // Atom links live in the href attribute; prefer the alternate rel
            // (YouTube's entry link) but take any href if none is marked.
            if let href = attributeDict["href"], !href.isEmpty {
                let rel = attributeDict["rel"] ?? "alternate"
                if current.link.isEmpty || rel == "alternate" {
                    current.link = href
                }
            }
        default:
            break
        }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(data: CDATABlock, encoding: .utf8) ?? ""
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        defer { if !elementStack.isEmpty { elementStack.removeLast() } }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard inEntry else {
            // Feed-level title: only the one directly under channel/feed.
            if elementName == "title", elementStack.count <= 3, feedTitle.isEmpty {
                feedTitle = value
            }
            return
        }

        switch elementName {
        case "item", "entry":
            inEntry = false
            entries.append(current)
        case "title":
            // Direct child of item/entry only (not media:group's title).
            if current.title.isEmpty, elementStack.suffix(2).first.map({ $0 == "item" || $0 == "entry" }) == true {
                current.title = value.decodedHTMLEntities
            }
        case "link":
            // RSS 2.0 puts the URL in the element text.
            if current.link.isEmpty, !value.isEmpty {
                current.link = value
            }
        case "description", "summary", "content", "content:encoded", "media:description":
            if !value.isEmpty {
                current.rawBodies.append(value)
                if current.summary.isEmpty {
                    current.summary = value.strippedHTML
                }
            }
        case "pubDate", "published", "dc:date", "updated":
            if current.published == nil {
                current.published = Self.parseDate(value)
            }
        case "yt:videoId":
            if !value.isEmpty { current.videoID = value }
        default:
            break
        }
        text = ""
    }

    // MARK: Dates

    /// RSS uses RFC 822; Atom uses ISO 8601 (with or without fractional seconds).
    static func parseDate(_ string: String) -> Date? {
        if let date = iso8601Fractional.date(from: string) ?? iso8601.date(from: string) {
            return date
        }
        return rfc822.date(from: string)
    }

    private static let iso8601: ISO8601DateFormatter = ISO8601DateFormatter()
    private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let rfc822: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()
}

extension String {
    /// Removes HTML tags and decodes common entities — enough to turn a feed's
    /// description markup into readable plain text (no full HTML parse).
    var strippedHTML: String {
        var result = replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        result = result.decodedHTMLEntities
        // Collapse runs of blank lines/spaces left behind by the tags.
        let lines = result
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    /// Decodes the handful of named entities feeds actually use, plus numeric
    /// character references.
    var decodedHTMLEntities: String {
        guard contains("&") else { return self }
        var result = self
        let named: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&apos;": "'", "&#39;": "'", "&nbsp;": " ",
        ]
        for (entity, character) in named {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        // Numeric references: &#233; and &#xE9;
        while let range = result.range(of: "&#x?[0-9a-fA-F]+;", options: .regularExpression) {
            let token = String(result[range])
            let digits = token.dropFirst(2).dropLast()
            let scalar: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                scalar = UInt32(digits.dropFirst(), radix: 16)
            } else {
                scalar = UInt32(digits)
            }
            let replacement = scalar.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
            result = result.replacingCharacters(in: range, with: replacement)
        }
        return result
    }
}
