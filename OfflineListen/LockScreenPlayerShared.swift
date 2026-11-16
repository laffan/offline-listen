import Foundation
#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import AppIntents
#endif

/// The wire format of the **lock screen player** — the Live Activity that puts
/// the Player tab's controls on the lock screen — compiled into both the app
/// and the widget extension, the same way `WidgetShared.swift` is, so the
/// state the app writes and the views that draw it can't drift.
///
/// Why a Live Activity at all: the system's own Now Playing controls take
/// metadata and commands, not a layout. They show three buttons, and the side
/// pair is *either* next/previous *or* the skip intervals, never both (see
/// `PlaybackManager.updateTransportButtons`); there is nowhere to put the
/// names of the tracks either side. A Live Activity is the only surface on the
/// lock screen an app gets to draw for itself.
///
/// The app half lives in `LockScreenPlayer.swift`; the views in the widget
/// extension's `LockScreenPlayerActivity.swift`.

// MARK: - Neighbours

/// A track either side of the one playing, as the lock screen names it.
struct LockScreenNeighbour: Codable, Hashable {
    var title: String
    /// Empty when there's no artist to show.
    var artist: String
    /// Seconds, 0 when unknown. Only the *next* track's is ever read — it's
    /// what the roll-over (see `ContentState.presented(isStale:)`) runs its
    /// progress bar off.
    var duration: Double
    /// The thumbnail in `LockScreenArtwork.directory`, when there is one.
    var artworkFile: String?

    var hasArtist: Bool {
        !artist.isEmpty && artist.lowercased() != "unknown"
    }
}

// MARK: - Commands

/// What a tap on the lock screen player asks for. Each maps onto the
/// `remote…` transport `PlaybackManager` gives every control outside the
/// Player screen, so a tap here drives whatever is actually making sound —
/// a Browse preview included — exactly as the system's own buttons do.
enum LockScreenCommand: String, Codable {
    /// The ⏮ button: back to the start of the track more than three seconds
    /// in, the previous track otherwise — `previous()`'s rule.
    case previous
    /// The **Previous Track** name: straight to it, whatever the playhead —
    /// the in-app label's `playPreviousTrack()`.
    case previousTrack
    case skipBackward
    case togglePlayPause
    case skipForward
    /// The ⏭ button and the **Next Track** name alike.
    case next
}

/// Where a lock-screen tap lands in the app. The intents below are compiled
/// into the widget extension too (a `Button(intent:)` has to be able to name
/// them), but the system runs an `AudioPlaybackIntent` in the **app's**
/// process — so the extension's copy never performs anything, and this
/// handler, which only the app installs, is nil there.
@MainActor
enum LockScreenTransport {
    static var handler: ((LockScreenCommand) async -> Void)?

    static func run(_ command: LockScreenCommand) async {
        await handler?(command)
    }
}

// MARK: - Artwork

/// The cover thumbnails the lock screen player draws. A Live Activity runs in
/// its own sandbox and can't reach `Documents/`, so the app leaves a small copy
/// of each cover in the **App Group** container and names it in the state.
///
/// Small on purpose: ActivityKit refuses to start a Live Activity whose images
/// are larger than the presentation they're drawn in, and the biggest slot
/// here is a 56-point sleeve.
enum LockScreenArtwork {
    /// Longest side, in pixels.
    static let maxPixel = 150
    /// How many thumbnails are kept before the oldest go.
    static let keep = 32

    static var directory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SharedInbox.appGroup)?
            .appendingPathComponent("LockScreenArtwork", isDirectory: true)
    }

    static func url(for file: String) -> URL? {
        directory?.appendingPathComponent(file)
    }
}

#if os(iOS) && canImport(ActivityKit)

// MARK: - Activity

/// The lock screen player's Live Activity. Nothing about it is fixed for its
/// lifetime — it follows whatever plays — so the attributes are empty and
/// everything is in the content state.
@available(iOS 16.1, *)
struct LockScreenPlayerAttributes: ActivityAttributes {
    /// One update's worth. Strings are clipped by the app before they get
    /// here: ActivityKit caps the whole payload at 4 KB.
    struct ContentState: Codable, Hashable {
        var trackID: UUID
        var title: String
        /// Empty when there's no artist to show.
        var artist: String
        var artworkFile: String?
        var isPlaying: Bool
        /// Seconds; 0 when unknown.
        var duration: Double
        /// The playhead as of `anchor`. While playing, the views run their
        /// own clocks from these two — a Live Activity draws timers itself, so
        /// the bar moves without the app sending anything.
        var elapsed: Double
        var anchor: Date
        var previous: LockScreenNeighbour?
        var next: LockScreenNeighbour?
        /// The track after `next` — what becomes "next" after a roll-over.
        var afterNext: LockScreenNeighbour?
        /// When the playing track is due to end and `next` to start — also the
        /// activity's stale date. Nil while paused, or with nothing after this.
        var rollOverAt: Date?

        var hasArtist: Bool {
            !artist.isEmpty && artist.lowercased() != "unknown"
        }

        /// The span the track plays over, for the self-running timer views.
        /// Nil while paused or when the length is unknown — those draw a still
        /// bar from `elapsed` instead.
        var playingRange: ClosedRange<Date>? {
            guard isPlaying, duration > 0 else { return nil }
            let start = anchor.addingTimeInterval(-max(0, elapsed))
            let end = start.addingTimeInterval(duration)
            guard end > start else { return nil }
            return start...end
        }

        /// How far through the track the still bar is.
        var fraction: Double {
            guard duration > 0 else { return 0 }
            return min(1, max(0, elapsed / duration))
        }

        /// What to draw, given whether the system has marked the activity
        /// stale.
        ///
        /// iOS doesn't reliably let an app that is *only playing audio in the
        /// background* update its Live Activity — the update is dropped
        /// without an error ("Process is only playing background media so is
        /// forbidden to update activity" in the device log). So a track
        /// changing on a locked phone may never reach the lock screen. The
        /// state therefore carries the next track ahead of time, with
        /// `rollOverAt` as the stale date: when the playing track is due to
        /// end, the system redraws the activity as stale whether or not the
        /// app's update got through, and this turns the next track into the
        /// one playing. One roll-over's worth — there's only one stale
        /// transition — but that covers the commonest case, a phone locked
        /// partway through a track. When the update *does* get through it
        /// carries the same thing, so the two never disagree.
        func presented(isStale: Bool) -> ContentState {
            guard isStale, isPlaying, let next, let rollOverAt else { return self }
            var rolled = self
            rolled.title = next.title
            rolled.artist = next.artist
            rolled.artworkFile = next.artworkFile
            rolled.duration = next.duration
            rolled.elapsed = 0
            rolled.anchor = rollOverAt
            rolled.previous = LockScreenNeighbour(title: title, artist: artist,
                                                  duration: duration, artworkFile: artworkFile)
            rolled.next = afterNext
            rolled.afterNext = nil
            rolled.rollOverAt = nil
            return rolled
        }
    }
}

// MARK: - Intents

// One intent per control rather than one with a parameter: a button's intent
// is archived with the view, and a parameterless type has nothing to resolve
// or get wrong. `AudioPlaybackIntent` because every one of these changes what
// is playing — it's the conformance that has the system run the intent in the
// app's process, and start audio from there if the app was suspended. None of
// them is offered to Shortcuts: they're the lock screen's buttons, not actions
// of their own.

@available(iOS 17.0, *)
struct LockScreenPreviousIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Previous"
    static var description = IntentDescription("Restarts the track, or goes back to the previous one near its start.")
    static var isDiscoverable: Bool { false }

    init() {}

    func perform() async throws -> some IntentResult {
        await LockScreenTransport.run(.previous)
        return .result()
    }
}

@available(iOS 17.0, *)
struct LockScreenPreviousTrackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Previous Track"
    static var description = IntentDescription("Plays the previous track in the queue.")
    static var isDiscoverable: Bool { false }

    init() {}

    func perform() async throws -> some IntentResult {
        await LockScreenTransport.run(.previousTrack)
        return .result()
    }
}

@available(iOS 17.0, *)
struct LockScreenSkipBackwardIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Back 15 Seconds"
    static var description = IntentDescription("Jumps back 15 seconds.")
    static var isDiscoverable: Bool { false }

    init() {}

    func perform() async throws -> some IntentResult {
        await LockScreenTransport.run(.skipBackward)
        return .result()
    }
}

@available(iOS 17.0, *)
struct LockScreenPlayPauseIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play or Pause"
    static var description = IntentDescription("Plays or pauses the current track.")
    static var isDiscoverable: Bool { false }

    init() {}

    func perform() async throws -> some IntentResult {
        await LockScreenTransport.run(.togglePlayPause)
        return .result()
    }
}

@available(iOS 17.0, *)
struct LockScreenSkipForwardIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Forward 30 Seconds"
    static var description = IntentDescription("Jumps ahead 30 seconds.")
    static var isDiscoverable: Bool { false }

    init() {}

    func perform() async throws -> some IntentResult {
        await LockScreenTransport.run(.skipForward)
        return .result()
    }
}

@available(iOS 17.0, *)
struct LockScreenNextIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Next Track"
    static var description = IntentDescription("Plays the next track in the queue.")
    static var isDiscoverable: Bool { false }

    init() {}

    func perform() async throws -> some IntentResult {
        await LockScreenTransport.run(.next)
        return .result()
    }
}

#endif
