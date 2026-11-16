import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The **lock screen player**: a Live Activity that sits beneath iOS's own Now
/// Playing controls and carries the part of the Player those can't. The two
/// are read together — iOS's controls have the cover, the title, the progress
/// bar, play/pause and next/previous, so none of that is repeated here. What
/// is here:
///
/// ```
///  ↺15            [ ⟲ Recent ]            30↻
///                    ✕ Close          (while paused)
///  PREVIOUS TRACK                  NEXT TRACK
///  Title                                Title
///  Artist                              Artist
/// ```
///
/// The skip buttons sit at the edges, over the side of the queue they lean
/// toward; **Recent** opens the app on the Recent tab's Recent list; and the
/// track names are tappable as they are under the Player's transport —
/// previous goes straight there, next is the next track. While playback is
/// paused — when the app may have been closed without a chance to take the
/// panel down — **Close** sits under Recent (see `ContentState.showsClose`). A
/// tap anywhere else opens the Player.
///
/// Every button is an `AudioPlaybackIntent` (see `LockScreenPlayerShared.swift`)
/// that the system runs in the app, so a tap acts on whatever is making sound
/// — the library or a Browse preview — the same as the system's own controls.
struct LockScreenPlayerActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LockScreenPlayerAttributes.self) { context in
            LockScreenCompanionView(state: context.state.presented(isStale: context.isStale))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .widgetURL(WidgetDeepLink.player.url)
        } dynamicIsland: { context in
            let state = context.state.presented(isStale: context.isStale)
            // iOS's own Now Playing already takes the Dynamic Island while
            // audio plays, with the cover and a waveform. This one stays out of
            // its way: a glyph when compact (the empty trailing side is hidden
            // by the system), and the same controls when expanded.
            return DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    LockScreenCompanionView(state: state)
                }
            } compactLeading: {
                CompanionGlyph()
            } compactTrailing: {
                EmptyView()
            } minimal: {
                CompanionGlyph()
            }
            .widgetURL(WidgetDeepLink.player.url)
            .keylineTint(PlayerPalette.accent)
        }
    }
}

// MARK: - Layout

struct LockScreenCompanionView: View {
    let state: LockScreenPlayerAttributes.ContentState

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 0) {
                SkipButton(intent: LockScreenSkipBackwardIntent(),
                           glyph: "gobackward.15", label: "Back 15 seconds")
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 6) {
                    RecentButton()
                    if state.showsClose {
                        CloseButton()
                    }
                }
                SkipButton(intent: LockScreenSkipForwardIntent(),
                           glyph: "goforward.30", label: "Forward 30 seconds")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            PlayerNeighbours(previous: state.previous, next: state.next)
        }
    }
}

// MARK: - Pieces

/// The app's accent. The extension has no asset catalog of its own, so the
/// colour is spelled out — the same sRGB value as `AccentColor` in the app's.
enum PlayerPalette {
    static let accent = Color(red: 0.890, green: 0.196, blue: 0.357)
}

/// What the Dynamic Island shows when it isn't expanded.
private struct CompanionGlyph: View {
    var body: some View {
        Image(systemName: "music.note.list")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(PlayerPalette.accent)
            .accessibilityLabel("Offline Listen")
    }
}

/// Back 15 or forward 30, with the Player's glyphs.
private struct SkipButton<Intent: AppIntent>: View {
    let intent: Intent
    let glyph: String
    let label: String

    var body: some View {
        Button(intent: intent) {
            Image(systemName: glyph)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(PlayerPalette.accent)
                .frame(width: 48, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Opens the app on the Recent tab's **Recent** list. A link rather than an
/// intent: it goes somewhere instead of doing something, and only the app can
/// show the place it goes.
private struct RecentButton: View {
    var body: some View {
        Link(destination: WidgetDeepLink.recent.url) {
            Label("Recent", systemImage: "clock.arrow.circlepath")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PlayerPalette.accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(PlayerPalette.accent.opacity(0.18), in: Capsule())
        }
        .accessibilityHint("Opens the Recent tab")
    }
}

/// Takes the panel down. Quieter than Recent — it's a way out, not a place to
/// go — and only there while paused.
private struct CloseButton: View {
    var body: some View {
        Button(intent: LockScreenCloseIntent()) {
            Label("Close", systemImage: "xmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .overlay { Capsule().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1) }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close the lock screen player")
    }
}

/// The tracks either side, named as the Player names them under its
/// transport — previous on the left, next on the right — and tappable the
/// same way: previous goes straight there, next is the next track.
private struct PlayerNeighbours: View {
    let previous: LockScreenNeighbour?
    let next: LockScreenNeighbour?

    var body: some View {
        if previous != nil || next != nil {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if let previous {
                        Button(intent: LockScreenPreviousTrackIntent()) {
                            NeighbourLabel(caption: "Previous Track", neighbour: previous, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear.frame(height: 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Group {
                    if let next {
                        Button(intent: LockScreenNextIntent()) {
                            NeighbourLabel(caption: "Next Track", neighbour: next, alignment: .trailing)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear.frame(height: 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

/// A small caption over the track's title and artist — the Player's
/// neighbour label, a size up for reading at arm's length.
private struct NeighbourLabel: View {
    let caption: String
    let neighbour: LockScreenNeighbour
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(caption)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
            Text(neighbour.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            if neighbour.hasArtist {
                Text(neighbour.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
