import Foundation
#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import AppIntents
#endif

/// The wire format of the **lock screen player** — a Live Activity that sits
/// beneath iOS's own Now Playing controls and adds what those can't show —
/// compiled into both the app and the widget extension, the same way
/// `WidgetShared.swift` is, so the state the app writes and the views that
/// draw it can't drift.
///
/// The two are meant to be read together. iOS's controls already carry the
/// cover, the title, the progress bar, play/pause and next/previous; they take
/// metadata and commands, not a layout, and their side buttons are *either* the
/// track buttons *or* the skip intervals, never both (see
/// `PlaybackManager.updateTransportButtons`). So the activity carries only the
/// rest of the Player's transport: **back 15** and **forward 30**, the names
/// of the **previous and next tracks**, and a way into the **Recent** tab —
/// plus, while playback is paused, a **Close** button that takes the panel
/// down (see `ContentState.showsClose`).
///
/// The app half lives in `LockScreenPlayer.swift`; the views in the widget
/// extension's `LockScreenPlayerActivity.swift`.

// MARK: - Neighbours

/// A track either side of the one playing, as the lock screen names it.
struct LockScreenNeighbour: Codable, Hashable {
    var title: String
    /// Empty when there's no artist to show.
    var artist: String

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
    /// The **Previous Track** name: straight to it, whatever the playhead —
    /// the in-app label's `playPreviousTrack()`.
    case previousTrack
    case skipBackward
    case skipForward
    /// The **Next Track** name.
    case next
    /// The **Close** button: take the lock screen player down. Not a
    /// transport command — nothing about playback changes.
    case close
}

/// Where a lock-screen tap lands in the app. The intents below are compiled
/// into the widget extension too (a `Button(intent:)` has to be able to name
/// them), but the system runs an `AudioPlaybackIntent` or a
/// `LiveActivityIntent` in the **app's** process — so the extension's copy
/// never performs anything, and this handler, which only the app installs, is
/// nil there.
@MainActor
enum LockScreenTransport {
    static var handler: ((LockScreenCommand) async -> Void)?

    static func run(_ command: LockScreenCommand) async {
        await handler?(command)
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
        /// The playing track. Not drawn — iOS's controls above already show
        /// it — but it's what becomes **Previous Track** when the next one
        /// rolls in on its own.
        var title: String
        var artist: String
        var isPlaying: Bool
        var previous: LockScreenNeighbour?
        var next: LockScreenNeighbour?
        /// The track after `next` — what becomes **Next Track** after a
        /// roll-over.
        var afterNext: LockScreenNeighbour?
        /// When the playing track is due to end and `next` to start — also the
        /// activity's stale date. Nil while paused, or with nothing after this.
        var rollOverAt: Date?

        /// Whether the panel offers **Close**.
        ///
        /// What it would like to know is whether the app is still running,
        /// and it can't: a Live Activity is drawn by the system from the last
        /// state the app sent, with no way to ask after the app itself. But
        /// the case that leaves it behind is narrow. An app that is playing is
        /// awake, is told when it's being closed, and takes the panel down on
        /// its way out. One that is paused is suspended by iOS within seconds,
        /// and a suspended app is killed — swiped away, or reclaimed for
        /// memory — without being told anything. So "paused" is exactly when
        /// the app may have gone without a word, and that's when Close shows.
        var showsClose: Bool { !isPlaying }

        /// What to draw, given whether the system has marked the activity
        /// stale.
        ///
        /// iOS doesn't reliably let an app that is *only playing audio in the
        /// background* update its Live Activity — the update is dropped
        /// without an error ("Process is only playing background media so is
        /// forbidden to update activity" in the device log). So a track
        /// changing on a locked phone may never reach the lock screen, and the
        /// names here would be one track behind. The state therefore carries
        /// the next track's neighbours ahead of time, with `rollOverAt` as the
        /// stale date: when the playing track is due to end, the system
        /// redraws the activity as stale whether or not the app's update got
        /// through, and this shifts the names along by one. One roll-over's
        /// worth — there's only one stale transition — but that covers the
        /// commonest case, a phone locked partway through a track. When the
        /// update *does* get through it says the same thing, so the two never
        /// disagree.
        func presented(isStale: Bool) -> ContentState {
            guard isStale, isPlaying, let next, rollOverAt != nil else { return self }
            var rolled = self
            rolled.title = next.title
            rolled.artist = next.artist
            rolled.previous = LockScreenNeighbour(title: title, artist: artist)
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

/// **Close.** A `LiveActivityIntent` rather than an audio one: it changes the
/// panel, not the playback. The system runs it in the app's process,
/// launching the app in the background if it had been killed — which is the
/// case Close exists for, and which works either way: the app hears it and
/// notes that the panel was closed on purpose, and the activities are ended
/// here as well, so an app that came up without its handler (or found nothing
/// of its own to end) still leaves nothing behind.
@available(iOS 17.0, *)
struct LockScreenCloseIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Close Lock Screen Player"
    static var description = IntentDescription("Takes the lock screen player down.")
    static var isDiscoverable: Bool { false }

    init() {}

    func perform() async throws -> some IntentResult {
        await LockScreenTransport.run(.close)
        for activity in Activity<LockScreenPlayerAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        return .result()
    }
}

#endif
