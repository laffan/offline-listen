import Foundation
import SwiftUI
import WidgetKit

/// "Pick up where you left off": the last two genres opened in the Every Noise
/// browser beside the last two songs played, each row a link straight to the
/// thing itself rather than to the app's front door.
///
/// **Medium only, deliberately.** WidgetKit gives a `systemSmall` widget a
/// single tap target and ignores `Link` inside it, so a small version could
/// only ever open the app — which is the one thing this widget exists not to
/// do. Medium is also the size the content fits: two short lists side by side.
struct RecentsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshotStore.kind, provider: RecentsProvider()) { entry in
            RecentsWidgetView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Recent")
        .description("The genres you last browsed and the songs you last played — one tap each.")
        .supportedFamilies([.systemMedium])
    }
}

// MARK: - Timeline

struct RecentsEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

/// There is nothing to schedule: the two lists change when the app records a
/// visit or a play, and the app reloads this widget's timeline at that moment.
/// So every timeline is one entry with a `.never` policy — no wake-ups spent
/// re-reading a file that can't have changed on its own.
struct RecentsProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecentsEntry {
        RecentsEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (RecentsEntry) -> Void) {
        // The widget gallery previews it before it has ever run for real, and
        // an empty box there says nothing about what it does.
        let snapshot: WidgetSnapshot = context.isPreview ? .placeholder : WidgetSnapshotStore.read()
        completion(RecentsEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentsEntry>) -> Void) {
        let entry = RecentsEntry(date: Date(), snapshot: WidgetSnapshotStore.read())
        completion(Timeline(entries: [entry], policy: .never))
    }
}

// MARK: - View

struct RecentsWidgetView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            column(title: "Browse", systemImage: "guitars") {
                if snapshot.genres.isEmpty {
                    EmptyRow(text: "No genres yet")
                } else {
                    ForEach(snapshot.genres) { GenreRow(genre: $0) }
                }
            }

            Divider()

            column(title: "Played", systemImage: "music.note") {
                if snapshot.songs.isEmpty {
                    EmptyRow(text: "Nothing played yet")
                } else {
                    ForEach(snapshot.songs) { SongRow(song: $0) }
                }
            }
        }
        .padding(.vertical, 2)
        .widgetContainerBackground()
    }

    /// One side: a small header, then its rows pinned to the top with the slack
    /// underneath, so a section with one row lines up with a section that has
    /// two.
    private func column<Content: View>(title: String, systemImage: String,
                                       @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A genre, wearing its own colour from the map.
private struct GenreRow: View {
    let genre: WidgetGenreEntry

    var body: some View {
        Link(destination: WidgetDeepLink.genre(key: genre.key).url) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(noiseHex: genre.colorHex))
                    .frame(width: 8, height: 8)
                Text(genre.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .widgetRow()
        }
    }
}

/// A song: title over artist, the same shape a Library row has.
private struct SongRow: View {
    let song: WidgetSongEntry

    var body: some View {
        Link(destination: WidgetDeepLink.track(id: song.trackID).url) {
            VStack(alignment: .leading, spacing: 0) {
                Text(song.title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if !song.artist.isEmpty {
                    Text(song.artist)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .widgetRow()
        }
    }
}

private struct EmptyRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
    }
}

// MARK: - Helpers

private extension View {
    /// Makes a `Link`'s label read and behave like a row: the whole column
    /// width is the tap target rather than just the glyphs, and the text keeps
    /// its own colour instead of being tinted the way a link's label otherwise
    /// is (a row that says what you last played is content, not a link you're
    /// being invited to notice). Styles set closer to a leaf still win, so the
    /// artist line stays secondary.
    func widgetRow() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .foregroundStyle(.primary)
    }

    /// iOS 17 took the widget's background off the view and gave it to the
    /// system; a widget that still paints its own is letterboxed in the gallery
    /// and in StandBy. Earlier releases want the padding drawn here.
    @ViewBuilder
    func widgetContainerBackground() -> some View {
        if #available(iOS 17.0, *) {
            containerBackground(.fill.tertiary, for: .widget)
        } else {
            padding()
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
            WidgetGenreEntry(key: "shoegaze", name: "shoegaze", colorHex: "#8fbc8f"),
            WidgetGenreEntry(key: "ethiojazz", name: "ethio-jazz", colorHex: "#dda0dd"),
        ],
        songs: [
            WidgetSongEntry(trackID: UUID(), title: "Tezeta", artist: "Mulatu Astatke"),
            WidgetSongEntry(trackID: UUID(), title: "Sometimes", artist: "My Bloody Valentine"),
        ]
    )
}
