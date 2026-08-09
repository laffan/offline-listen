import AppIntents
import WidgetKit

/// What the widget's **Browse** section lists — the one thing the options pane
/// (touch and hold the widget → *Edit Widget*) offers.
///
/// The browser logs two kinds of visit and they answer different questions:
/// *where was I in the map* and *who was I listening to*. Which of those is
/// worth a home-screen row is a matter of how you use the app, so it's a
/// setting rather than a guess.
enum BrowseWidgetContent: String, AppEnum {
    /// Genres you opened.
    case genres
    /// Artists you tapped — on the map, or through the Find field's Spotify
    /// search.
    case artists
    /// Both, interleaved by recency: the browse history as it happened.
    case both

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Browse Shows"

    static var caseDisplayRepresentations: [BrowseWidgetContent: DisplayRepresentation] = [
        .genres: DisplayRepresentation(title: "Genres",
                                       subtitle: "The genres you last opened"),
        .artists: DisplayRepresentation(title: "Artists",
                                        subtitle: "The artists you last tapped"),
        .both: DisplayRepresentation(title: "Genres & Artists",
                                     subtitle: "Both, most recent first"),
    ]
}

/// The widget's configuration. One parameter today; it exists as an intent so
/// there's an options pane at all.
struct RecentsConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Recent"
    static var description = IntentDescription(
        "Choose whether the Browse side lists genres, artists, or both."
    )

    @Parameter(title: "Browse", default: .genres)
    var browseContent: BrowseWidgetContent
}
