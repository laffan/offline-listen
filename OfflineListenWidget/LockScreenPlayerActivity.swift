import ActivityKit
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

/// The **lock screen player**: the Player tab's controls as a Live Activity —
/// what's playing, a running progress bar, previous / back 15 / play-pause /
/// forward 30 / next, and the previous and next tracks named beneath, each
/// tappable, exactly as they sit under the Player's own transport.
///
/// Every button is an `AudioPlaybackIntent` (see `LockScreenPlayerShared.swift`)
/// that the system runs in the app, so a tap acts on whatever is making sound
/// — the library or a Browse preview — the same as the system's own controls.
/// A tap anywhere else opens the app on the Player tab.
///
/// The lock screen presentation is held under the 160 points ActivityKit
/// allows before it starts cutting things off: one row for the sleeve, the
/// names and the bar beside them, one for the transport, one for the
/// neighbours.
struct LockScreenPlayerActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LockScreenPlayerAttributes.self) { context in
            LockScreenPlayerView(state: context.state.presented(isStale: context.isStale))
                .widgetURL(WidgetDeepLink.player.url)
        } dynamicIsland: { context in
            let state = context.state.presented(isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PlayerSleeve(file: state.artworkFile, size: 44)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: state.isPlaying ? "waveform" : "pause.fill")
                        .font(.title3)
                        .foregroundStyle(PlayerPalette.accent)
                        .frame(width: 44, height: 44)
                        .accessibilityLabel(state.isPlaying ? "Playing" : "Paused")
                }
                DynamicIslandExpandedRegion(.center) {
                    PlayerNames(state: state, alignment: .center)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        PlayerProgressRow(state: state)
                        PlayerTransport(state: state)
                        PlayerNeighbours(previous: state.previous, next: state.next)
                    }
                }
            } compactLeading: {
                PlayerSleeve(file: state.artworkFile, size: 22)
            } compactTrailing: {
                PlayerProgressRing(state: state)
            } minimal: {
                PlayerProgressRing(state: state)
            }
            .widgetURL(WidgetDeepLink.player.url)
            .keylineTint(PlayerPalette.accent)
        }
    }
}

// MARK: - Lock screen

struct LockScreenPlayerView: View {
    let state: LockScreenPlayerAttributes.ContentState

    var body: some View {
        // Heights, roughly: 58 for the sleeve row, 32 for the transport, 30
        // for the neighbours, 12 between and 20 of padding — 152 of the 160.
        VStack(spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                PlayerSleeve(file: state.artworkFile, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    PlayerNames(state: state, alignment: .leading)
                    PlayerProgressRow(state: state)
                }
            }
            PlayerTransport(state: state)
            PlayerNeighbours(previous: state.previous, next: state.next)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Pieces

/// The app's accent. The extension has no asset catalog of its own, so the
/// colour is spelled out — the same sRGB value as `AccentColor` in the app's.
enum PlayerPalette {
    static let accent = Color(red: 0.890, green: 0.196, blue: 0.357)
}

/// Title over artist, as the Player sets them.
private struct PlayerNames: View {
    let state: LockScreenPlayerAttributes.ContentState
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(state.title)
                .font(.headline)
                .lineLimit(1)
            if state.hasArtist {
                Text(state.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
    }
}

/// The cover, or the Player's gradient stand-in when there isn't one.
private struct PlayerSleeve: View {
    let file: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let image = file.flatMap(Self.image(named:)) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(colors: [PlayerPalette.accent.opacity(0.65), PlayerPalette.accent.opacity(0.25)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.42))
                            .foregroundStyle(.white.opacity(0.9))
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
        .accessibilityHidden(true)
    }

    /// The app leaves these small (see `LockScreenArtwork`), so reading one
    /// per render is cheap.
    private static func image(named file: String) -> UIImage? {
        guard let url = LockScreenArtwork.url(for: file) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}

/// Elapsed time, the bar, and the track's length. While playing, the bar and
/// the elapsed time are timer views the system runs by itself — the app sends
/// nothing as they move — and while paused they're drawn still.
private struct PlayerProgressRow: View {
    let state: LockScreenPlayerAttributes.ContentState

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let range = state.playingRange {
                    Text(timerInterval: range, countsDown: false, showsHours: false)
                } else {
                    Text(Self.clock(state.elapsed))
                }
            }
            .frame(width: 40, alignment: .leading)

            Group {
                if let range = state.playingRange {
                    ProgressView(timerInterval: range, countsDown: false,
                                 label: { EmptyView() }, currentValueLabel: { EmptyView() })
                } else {
                    ProgressView(value: state.fraction)
                }
            }
            .progressViewStyle(.linear)
            .tint(PlayerPalette.accent)

            Text(state.duration > 0 ? Self.clock(state.duration) : "--:--")
                .frame(width: 40, alignment: .trailing)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    /// `m:ss`, or `h:mm:ss` past the hour — the Player's own format.
    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

/// The Dynamic Island's glance: how far through the track, as a ring.
private struct PlayerProgressRing: View {
    let state: LockScreenPlayerAttributes.ContentState

    var body: some View {
        Group {
            if let range = state.playingRange {
                ProgressView(timerInterval: range, countsDown: false,
                             label: { EmptyView() }, currentValueLabel: { EmptyView() })
            } else {
                ProgressView(value: state.fraction)
            }
        }
        .progressViewStyle(.circular)
        .tint(PlayerPalette.accent)
        .overlay {
            Image(systemName: state.isPlaying ? "music.note" : "pause.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(PlayerPalette.accent)
        }
        .frame(width: 22, height: 22)
        .accessibilityLabel(state.isPlaying ? "Playing \(state.title)" : "Paused")
    }
}

/// Previous, back 15, play/pause, forward 30, next — the Player's transport,
/// in the Player's order and with the Player's glyphs.
private struct PlayerTransport: View {
    let state: LockScreenPlayerAttributes.ContentState

    var body: some View {
        HStack(spacing: 0) {
            control(LockScreenPreviousIntent(), glyph: "backward.fill", size: 20,
                    label: "Previous")
            control(LockScreenSkipBackwardIntent(), glyph: "gobackward.15", size: 22,
                    label: "Back 15 seconds")
            control(LockScreenPlayPauseIntent(),
                    glyph: state.isPlaying ? "pause.circle.fill" : "play.circle.fill", size: 32,
                    label: state.isPlaying ? "Pause" : "Play")
            control(LockScreenSkipForwardIntent(), glyph: "goforward.30", size: 22,
                    label: "Forward 30 seconds")
            control(LockScreenNextIntent(), glyph: "forward.fill", size: 20,
                    label: "Next")
        }
        .foregroundStyle(PlayerPalette.accent)
    }

    private func control<Intent: AppIntent>(_ intent: Intent, glyph: String,
                                            size: CGFloat, label: String) -> some View {
        Button(intent: intent) {
            Image(systemName: glyph)
                .font(.system(size: size))
                .frame(maxWidth: .infinity, minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The tracks either side, named under the transport as the Player names them
/// — previous on the left, next on the right — and tappable the same way:
/// previous goes straight there, next is the next button by another name.
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

/// A small caption over the track — title, then artist, on one line to stay
/// inside the lock screen's height.
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
            line
                .font(.caption)
                .lineLimit(1)
        }
        .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var line: Text {
        let title: Text = Text(neighbour.title).foregroundStyle(.secondary)
        guard neighbour.hasArtist else { return title }
        return title + Text(" · \(neighbour.artist)").foregroundStyle(.tertiary)
    }
}
