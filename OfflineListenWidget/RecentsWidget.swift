import AppIntents
import Foundation
import SwiftUI
import WidgetKit

/// "Pick up where you left off": what you last opened in the Every Noise
/// browser beside what you last played, each row a link straight to the thing
/// itself rather than to the app's front door.
///
/// It runs at every home-screen size plus the lock screen's rectangular slot.
/// Every size shows **both** lists; what changes is how deep they go and how
/// many tap targets WidgetKit will give them:
///
/// | Family | Layout | Taps |
/// |---|---|---|
/// | `systemSmall` | stacked, one row each | one |
/// | `systemMedium` | two columns, two rows each | per row |
/// | `systemLarge` | two stacked sections, three rows each | per row |
/// | `systemExtraLarge` | two columns, four rows each | per row |
/// | `accessoryRectangular` | stacked, one row each | one |
///
/// A `systemSmall` widget — and any accessory one — has exactly **one** tap
/// target: `Link` views inside it are ignored, and only `widgetURL` is read.
/// So those sizes still draw both rows (seeing what you were doing is most of
/// the point) and send the tap to the song, marking that row with a play glyph
/// so which one is live is visible rather than guessed at.
struct RecentsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetSnapshotStore.kind,
                               intent: RecentsConfigurationIntent.self,
                               provider: RecentsProvider()) { entry in
            RecentsWidgetView(entry: entry)
        }
        .configurationDisplayName("Recent")
        .description("The genres and artists you last browsed, and the songs you last played — one tap each.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .systemExtraLarge, .accessoryRectangular])
    }
}

// MARK: - Timeline

struct RecentsEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let browseContent: BrowseWidgetContent
}

/// There is nothing to schedule: the lists change when the app records a visit
/// or a play, and the app reloads this widget's timeline at that moment. So
/// every timeline is one entry with a `.never` policy — no wake-ups spent
/// re-reading a file that can't have changed on its own.
struct RecentsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> RecentsEntry {
        RecentsEntry(date: Date(), snapshot: .placeholder, browseContent: .genres)
    }

    func snapshot(for configuration: RecentsConfigurationIntent,
                  in context: Context) async -> RecentsEntry {
        // The widget gallery previews it before it has ever run for real, and
        // an empty box there says nothing about what it does.
        let snapshot: WidgetSnapshot = context.isPreview ? .placeholder : WidgetSnapshotStore.read()
        return RecentsEntry(date: Date(), snapshot: snapshot,
                            browseContent: configuration.browseContent)
    }

    func timeline(for configuration: RecentsConfigurationIntent,
                  in context: Context) async -> Timeline<RecentsEntry> {
        let entry = RecentsEntry(date: Date(), snapshot: WidgetSnapshotStore.read(),
                                 browseContent: configuration.browseContent)
        return Timeline(entries: [entry], policy: .never)
    }
}

// MARK: - One drawable row

/// A row the widget can draw and link to, whichever list it came from. Both
/// halves collapse to this so the single-item sizes can pick "the most recent
/// thing" across the two without caring which one it is.
private struct WidgetRow: Identifiable {
    let id: String
    /// "Genre" / "Artist" / "Played" — what this row *is*, which only the
    /// single-item sizes have room to say.
    let caption: String
    let title: String
    let subtitle: String?
    let systemImage: String
    /// The map colour to tint the glyph with. Nil where there isn't one (a
    /// song; an artist reached through Spotify, who has no place on the map).
    let tint: Color?
    let url: URL
    let date: Date
}

private extension WidgetBrowseEntry {
    var row: WidgetRow {
        WidgetRow(id: "browse-\(id)",
                  caption: kind == .genre ? "Genre" : "Artist",
                  title: name,
                  subtitle: detail,
                  // The same glyphs the browser's own History rows use.
                  systemImage: isSpotifyArtist ? "antenna.radiowaves.left.and.right"
                      : (kind == .genre ? "guitars" : "music.mic"),
                  tint: colorHex.isEmpty ? nil : Color(noiseHex: colorHex),
                  url: WidgetDeepLink.browse(target).url,
                  date: date)
    }
}

private extension WidgetSongEntry {
    var row: WidgetRow {
        WidgetRow(id: "song-\(trackID.uuidString)",
                  caption: "Played",
                  title: title,
                  subtitle: artist.isEmpty ? nil : artist,
                  systemImage: "music.note",
                  tint: nil,
                  url: WidgetDeepLink.track(id: trackID).url,
                  date: date)
    }
}

// MARK: - View

struct RecentsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RecentsEntry

    var body: some View {
        layout.widgetContainerBackground(family)
    }

    @ViewBuilder
    private var layout: some View {
        switch family {
        case .systemSmall:
            compactPair
        case .accessoryRectangular:
            accessoryPair
        case .systemLarge:
            stackedSections
        default:
            // Medium and extra-large: the two lists side by side.
            sideBySideSections
        }
    }

    // MARK: Rows to draw

    /// How many rows a section gets. Stacked sections share the height, so
    /// large takes fewer than the (taller, side-by-side) extra-large; the
    /// single-tap sizes show one of each.
    private var rowsPerSection: Int {
        switch family {
        case .systemLarge: return 3
        case .systemExtraLarge: return 4
        case .systemSmall, .accessoryRectangular: return 1
        default: return 2
        }
    }

    /// The browse list the options pane asked for. **Both** interleaves by
    /// recency rather than showing genres then artists — it's the browse
    /// history as it happened, which is what makes it worth its own setting.
    private var browseEntries: [WidgetBrowseEntry] {
        switch entry.browseContent {
        case .genres: return entry.snapshot.genres
        case .artists: return entry.snapshot.artists
        case .both: return (entry.snapshot.genres + entry.snapshot.artists)
            .sorted { $0.date > $1.date }
        }
    }

    private var browseRows: [WidgetRow] {
        browseEntries.prefix(rowsPerSection).map(\.row)
    }

    private var songRows: [WidgetRow] {
        entry.snapshot.songs.prefix(rowsPerSection).map(\.row)
    }

    /// Where the whole widget goes at the sizes that get one tap target.
    ///
    /// The **song**, when there is one. Both rows are drawn either way, but only
    /// one of them can be the destination, and picking by recency would mean a
    /// tap doing different things on different days — the last thing a
    /// home-screen button should do. Playing is also the action this app is
    /// for; the browse row is there to be *read*. Which one is live is said out
    /// loud rather than left to be discovered: the destination row wears a play
    /// glyph. With nothing played yet, the browse row takes the tap.
    private var singleTapTarget: URL? {
        songRows.first?.url ?? browseRows.first?.url
    }

    private var browseTitle: String {
        switch entry.browseContent {
        case .genres: return "Genres"
        case .artists: return "Artists"
        case .both: return "Browse"
        }
    }

    private var browseSymbol: String {
        switch entry.browseContent {
        case .genres: return "guitars"
        case .artists: return "music.mic"
        case .both: return "safari"
        }
    }

    private var browseEmptyText: String {
        switch entry.browseContent {
        case .genres: return "No genres yet"
        case .artists: return "No artists yet"
        case .both: return "Nothing browsed yet"
        }
    }

    // MARK: Layouts

    private var sideBySideSections: some View {
        HStack(alignment: .top, spacing: 12) {
            browseSection
            Divider()
            songSection
        }
        .padding(.vertical, 2)
    }

    private var stackedSections: some View {
        VStack(alignment: .leading, spacing: 10) {
            browseSection
            Divider()
            songSection
        }
    }

    private var browseSection: some View {
        section(title: browseTitle, systemImage: browseSymbol,
                rows: browseRows, emptyText: browseEmptyText)
    }

    private var songSection: some View {
        section(title: "Played", systemImage: "music.note.list",
                rows: songRows, emptyText: "Nothing played yet")
    }

    /// One side (or half): a small header, then its rows pinned to the top with
    /// the slack underneath, so a section with one row lines up with a section
    /// that has three.
    private func section(title: String, systemImage: String,
                         rows: [WidgetRow], emptyText: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            if rows.isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(rows) { RowLabel(row: $0) }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Small: one browse row over one song row — the same two sections the
    /// bigger sizes show, one deep. Only the tap target is different, because
    /// a `systemSmall` widget has exactly one.
    @ViewBuilder
    private var compactPair: some View {
        if browseRows.isEmpty && songRows.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 7) {
                compactEntry(caption: browseRows.first?.caption ?? browseTitle,
                             row: browseRows.first,
                             emptyText: browseEmptyText)
                Divider()
                compactEntry(caption: "Played",
                             row: songRows.first,
                             emptyText: "Nothing played yet",
                             // Marked only when it really is where the tap
                             // goes — with no song, the browse row is.
                             isTapTarget: songRows.first != nil)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .widgetURL(singleTapTarget)
        }
    }

    /// One labelled line of the small layout.
    private func compactEntry(caption: String, row: WidgetRow?,
                              emptyText: String, isTapTarget: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(caption)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            if let row {
                HStack(spacing: 5) {
                    Image(systemName: row.systemImage)
                        .font(.caption)
                        .foregroundStyle(row.tint ?? Color.secondary)
                    Text(row.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if isTapTarget {
                        Spacer(minLength: 2)
                        Image(systemName: "play.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        // Full width, so the play glyph sits at the widget's trailing edge
        // rather than hard against the title it follows.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The lock screen's rectangular slot: the same pair, three lines deep and
    /// without colour — the system flattens it there anyway.
    @ViewBuilder
    private var accessoryPair: some View {
        if browseRows.isEmpty && songRows.isEmpty {
            Text("Nothing yet").font(.caption)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                if let row = browseRows.first {
                    Label(row.title, systemImage: row.systemImage)
                        .font(.caption)
                        .lineLimit(1)
                        .widgetAccentable()
                }
                if let row = songRows.first {
                    Text(row.title)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let subtitle = row.subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(singleTapTarget)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 2) {
            Image(systemName: "music.note.list")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text("Nothing yet")
                .font(.headline)
            Text("Open a genre or play a song.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// A row in the multi-row sizes: glyph, title, and whatever second line the row
/// carries — the genre an artist was tapped in, or a song's artist.
private struct RowLabel: View {
    let row: WidgetRow

    var body: some View {
        Link(destination: row.url) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: row.systemImage)
                    .font(.caption)
                    .foregroundStyle(row.tint ?? Color.secondary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.title)
                        .font(.subheadline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let subtitle = row.subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .widgetRow()
        }
    }
}

// MARK: - Helpers

private extension View {
    /// Makes a `Link`'s label read and behave like a row: the whole column
    /// width is the tap target rather than just the glyphs, and the text keeps
    /// its own colour instead of being tinted the way a link's label otherwise
    /// is (a row that says what you last played is content, not a link you're
    /// being invited to notice). Styles set closer to a leaf still win, so the
    /// second line stays secondary.
    func widgetRow() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .foregroundStyle(.primary)
    }

    /// The widget's background belongs to the system, not to the view — one
    /// that paints its own is letterboxed in the gallery and in StandBy. On the
    /// lock screen there shouldn't be one at all.
    @ViewBuilder
    func widgetContainerBackground(_ family: WidgetFamily) -> some View {
        if family == .accessoryRectangular {
            containerBackground(Color.clear, for: .widget)
        } else {
            containerBackground(.fill.tertiary, for: .widget)
        }
    }
}

private extension Color {
    /// An Every Noise `#rrggbb`. The app parses these through its platform
    /// colour helpers, which live beside the map engine the widget doesn't
    /// link — so it does the six-digit read itself, falling back to a neutral
    /// grey exactly as the map does on a malformed value.
    init(noiseHex hex: String) {
        var value: UInt64 = 0
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&value) else {
            self = Color(white: 0.5)
            return
        }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

private extension WidgetSnapshot {
    /// What the widget gallery shows before the app has written anything.
    static let placeholder = WidgetSnapshot(
        genres: [
            WidgetBrowseEntry(kind: .genre, genreKey: "shoegaze", artistID: nil,
                              isSpotifyArtist: false, name: "shoegaze",
                              colorHex: "#8fbc8f", detail: nil,
                              date: Date(timeIntervalSinceNow: -300)),
            WidgetBrowseEntry(kind: .genre, genreKey: "ethiojazz", artistID: nil,
                              isSpotifyArtist: false, name: "ethio-jazz",
                              colorHex: "#dda0dd", detail: nil,
                              date: Date(timeIntervalSinceNow: -3600)),
        ],
        artists: [
            WidgetBrowseEntry(kind: .artist, genreKey: "ethiojazz", artistID: "Mulatu Astatke|10|20",
                              isSpotifyArtist: false, name: "Mulatu Astatke",
                              colorHex: "#dda0dd", detail: "ethio-jazz",
                              date: Date(timeIntervalSinceNow: -900)),
            WidgetBrowseEntry(kind: .artist, genreKey: "shoegaze", artistID: "Slowdive|30|40",
                              isSpotifyArtist: false, name: "Slowdive",
                              colorHex: "#8fbc8f", detail: "shoegaze",
                              date: Date(timeIntervalSinceNow: -5400)),
        ],
        songs: [
            WidgetSongEntry(trackID: UUID(), title: "Tezeta", artist: "Mulatu Astatke",
                            date: Date(timeIntervalSinceNow: -120)),
            WidgetSongEntry(trackID: UUID(), title: "Sometimes", artist: "My Bloody Valentine",
                            date: Date(timeIntervalSinceNow: -2400)),
        ]
    )
}
