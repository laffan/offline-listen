import Foundation
#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import UIKit
#endif

/// The **Lock Screen Player** switch in Settings. On by default; turning it
/// off takes the Live Activity down at once and stops it coming back.
enum LockScreenPlayerSettings {
    static let enabledKey = "lockScreenPlayerEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }
}

#if os(iOS) && canImport(ActivityKit)

/// The app's half of the lock screen player: keeps one Live Activity in step
/// with whatever `PlaybackManager` is publishing, and runs the taps made on it.
///
/// It's fed the same snapshot the system's Now Playing controls and the watch
/// get (`onLockScreenChange`, at the ticker's 2 Hz), and almost none of those
/// change anything it shows. What it shows is the tracks either side, so an
/// update goes out when the track, the neighbours or play/pause change — and
/// also when the playhead *jumps* (a seek, a skip) or the length is corrected,
/// since either moves the moment the next track is due, which the activity
/// keeps as its stale date (see below).
///
/// **What iOS lets it do, and when.** A Live Activity can only be *started*
/// with the app in the foreground, so it starts when playback starts in the
/// app, or the next time the app is opened. Updating one from the background is
/// documented as allowed, but developers report that iOS drops updates from a
/// process that is only playing background audio — exactly this app with the
/// phone locked. The state is built to survive that: the next track's
/// neighbours are carried ahead of time and shift in when the current track is
/// due to end (`ContentState.presented(isStale:)`), every update a tap causes
/// is sent while the tap's intent is still running, and the whole thing is
/// brought up to date whenever the app comes forward.
///
/// **It belongs to a running app.** iOS doesn't end a Live Activity when its
/// app goes, so this does: when the app is told it's terminating, and — for
/// the times it isn't told — at the next launch, before anything else.
@available(iOS 17.0, *)
@MainActor
final class LockScreenPlayer {
    static let shared = LockScreenPlayer()

    typealias State = LockScreenPlayerAttributes.ContentState

    private weak var playback: PlaybackManager?
    private var activity: Activity<LockScreenPlayerAttributes>?
    private var stateObserver: Task<Void, Never>?
    /// Updates are chained so they reach ActivityKit in the order they were
    /// made — and so a tap's intent can wait for its own to be handed over.
    private var updateChain: Task<Void, Never>?

    /// The latest snapshot, whether or not it was worth an update.
    private var latest: RemoteAudioInfo?
    /// The parts of the snapshot the last update was built from, for telling
    /// a real change from the ticker repeating itself.
    private var sentSignature: Signature?
    /// Where the playhead was when the last update was built, and when — the
    /// clock the stale date was set by. A playhead that has wandered off it
    /// has jumped, and the stale date with it.
    private var sentClock: (elapsed: Double, at: Date, isPlaying: Bool)?
    /// The snapshot a start was last tried for and refused (Live Activities
    /// switched off for the app in iOS Settings, say), so the ticker doesn't
    /// ask again twice a second. Cleared by anything that forces a refresh.
    private var refusedStart: Signature?
    /// True once the person has swiped the activity away. It isn't put back
    /// until a track is started from the app: removing it is an answer.
    private var dismissedByPerson = false
    private var terminationObserver: NSObjectProtocol?

    private init() {}

    /// Wires the player up. Called once, from the app's entry point.
    func install(on playback: PlaybackManager) {
        self.playback = playback
        playback.onLockScreenChange = { [weak self] info in self?.receive(info) }
        playback.onLockScreenStart = { [weak self] in self?.playbackStarted() }
        LockScreenTransport.handler = { [weak self] command in await self?.perform(command) }
        endLeftovers()
        // `queue: nil` runs the block on the posting thread, synchronously —
        // the main thread, inside `applicationWillTerminate`. A block queued
        // for later would never run: the process is gone once that returns.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            Self.endAllBeforeExit()
        }
    }

    // MARK: - Feed

    private func receive(_ info: RemoteAudioInfo?) {
        latest = info
        guard info != nil, LockScreenPlayerSettings.isEnabled else {
            end(reason: info == nil ? "nothing is loaded" : nil)
            return
        }
        refresh(force: false)
    }

    /// A track started from the app. Lifts a swipe-away, since starting
    /// something is as clear a "show me the player" as there is.
    private func playbackStarted() {
        dismissedByPerson = false
    }

    /// The app came to the foreground: the one moment a Live Activity can be
    /// started, and the moment to repair anything the background didn't let
    /// through.
    func sceneDidBecomeActive() {
        guard LockScreenPlayerSettings.isEnabled else { return }
        refresh(force: true)
    }

    /// The Settings switch moved.
    func settingChanged() {
        if LockScreenPlayerSettings.isEnabled {
            dismissedByPerson = false
            refresh(force: true)
        } else {
            end(reason: "switched off in Settings")
        }
    }

    private func refresh(force: Bool) {
        guard let info = latest else { return }
        let signature = Signature(info)
        if force { refusedStart = nil }
        if let activity, !Self.isLive(activity) { self.activity = nil }

        guard let activity else {
            // Nothing up. One goes up for a track that's playing — not for one
            // that's paused, and not after a swipe-away — and only with the app
            // in front: ActivityKit refuses a start from anywhere else (a
            // `visibility` error), so a background start waits for the app to
            // be opened, which forces a refresh.
            guard info.isPlaying, !dismissedByPerson, refusedStart != signature,
                  UIApplication.shared.applicationState == .active else { return }
            start(with: info, signature: signature)
            return
        }

        guard force || signature != sentSignature || playheadJumped(info) else { return }
        let state = makeState(from: info)
        note(info, signature: signature)
        send(state, to: activity)
    }

    /// Whether the playhead is somewhere other than where the last update's
    /// clock says it should be by now.
    private func playheadJumped(_ info: RemoteAudioInfo) -> Bool {
        guard let sentClock else { return true }
        let expected = sentClock.isPlaying
            ? sentClock.elapsed + Date().timeIntervalSince(sentClock.at)
            : sentClock.elapsed
        return abs(expected - info.elapsed) > 2
    }

    private func note(_ info: RemoteAudioInfo, signature: Signature) {
        sentSignature = signature
        sentClock = (info.elapsed, Date(), info.isPlaying)
    }

    private static func isLive(_ activity: Activity<LockScreenPlayerAttributes>) -> Bool {
        switch activity.activityState {
        case .active, .stale: return true
        default: return false
        }
    }

    // MARK: - Lifecycle

    private func start(with info: RemoteAudioInfo, signature: Signature) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            refusedStart = signature
            return
        }
        let state = makeState(from: info)
        do {
            let activity = try Activity.request(
                attributes: LockScreenPlayerAttributes(),
                content: ActivityContent(state: state, staleDate: state.rollOverAt),
                pushType: nil)
            note(info, signature: signature)
            adopt(activity)
            appLog("Lock screen player up beside \"\(state.title)\".", level: .debug, category: "Player")
        } catch {
            refusedStart = signature
            appLog("Couldn't put the lock screen player up: \(error.localizedDescription)",
                   level: .warning, category: "Player")
        }
    }

    /// Takes down whatever an earlier run left up. At launch, any activity
    /// there is belongs to a process that has gone — one iOS suspended while
    /// paused and then killed (swiped away from the app switcher, or reclaimed
    /// for memory), which is never told it's ending and so never took its
    /// activity with it. The lock screen player is part of a running app, so
    /// it goes; a new one goes up when something plays with the app open.
    private func endLeftovers() {
        for activity in Activity<LockScreenPlayerAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// The app is being closed while awake — swiped away from the app switcher
    /// while playing, or while still in front — and is told so. The activity
    /// goes with it, as iOS's own Now Playing controls do.
    ///
    /// Blocks the main thread until ActivityKit has it, for two seconds at
    /// most: `applicationWillTerminate` is the last code the app runs, and an
    /// `end` left to finish afterwards never would. The work runs detached so
    /// it doesn't need the main thread it's holding.
    nonisolated private static func endAllBeforeExit() {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for activity in Activity<LockScreenPlayerAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }

    private func adopt(_ activity: Activity<LockScreenPlayerAttributes>) {
        self.activity = activity
        stateObserver?.cancel()
        stateObserver = Task { [weak self] in
            var last = activity.activityState
            for await state in activity.activityStateUpdates {
                self?.activityStateChanged(activity, from: last, to: state)
                last = state
            }
        }
    }

    private func activityStateChanged(_ activity: Activity<LockScreenPlayerAttributes>,
                                      from old: ActivityState, to new: ActivityState) {
        guard activity.id == self.activity?.id else { return }
        switch new {
        case .dismissed:
            // Straight from live to gone is a person swiping it away; after
            // `.ended` it's only the system clearing what it had already ended.
            if old == .active || old == .stale {
                dismissedByPerson = true
                appLog("Lock screen player swiped away — it stays down until a track is started.",
                       level: .debug, category: "Player")
            }
            self.activity = nil
        case .ended:
            // The system's eight-hour limit, most likely. A new one goes up the
            // next time the app is opened with something playing.
            self.activity = nil
        default:
            break
        }
    }

    private func end(reason: String?) {
        sentSignature = nil
        sentClock = nil
        guard let activity else { return }
        self.activity = nil
        stateObserver?.cancel()
        stateObserver = nil
        if let reason {
            appLog("Lock screen player taken down — \(reason).", level: .debug, category: "Player")
        }
        let previous = updateChain
        updateChain = Task {
            await previous?.value
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func send(_ state: State, to activity: Activity<LockScreenPlayerAttributes>) {
        let previous = updateChain
        updateChain = Task {
            await previous?.value
            await activity.update(ActivityContent(state: state, staleDate: state.rollOverAt))
        }
    }

    // MARK: - Taps

    /// Runs a tap made on the lock screen player. Called from the tapped
    /// button's intent, which the system runs in this process — waking the app
    /// first if it had been suspended or killed — and the intent is kept
    /// waiting until the update the tap caused has been handed to ActivityKit:
    /// an update made while an intent is running is the one the background
    /// rules are likeliest to let through.
    private func perform(_ command: LockScreenCommand) async {
        guard let playback else { return }
        appLog("Lock screen player: \(command.rawValue).", level: .debug, category: "Player")
        // Woken from cold by a button on an activity an earlier run left up
        // (this launch is taking it down): nothing is loaded yet, so load
        // what was, and act on that.
        if !playback.hasSomethingToPlay {
            playback.restoreLastSession()
        }
        switch command {
        case .previousTrack:
            playback.remotePlayPreviousTrack()
        case .skipBackward:
            playback.remoteSkipBackward()
        case .skipForward:
            playback.remoteSkipForward()
        case .next:
            playback.remoteNext()
        }
        await updateChain?.value
    }

    // MARK: - State

    private func makeState(from info: RemoteAudioInfo) -> State {
        let remaining = info.duration - info.elapsed
        // Only a track that is playing, with something after it and a known
        // end, can roll over on its own.
        let rollOverAt: Date? = info.isPlaying && info.next != nil && info.duration > 0 && remaining > 0
            ? Date().addingTimeInterval(remaining)
            : nil
        return State(trackID: info.id,
                     title: Self.clip(info.title),
                     artist: Self.clip(info.artist),
                     isPlaying: info.isPlaying,
                     previous: info.previous.map { Self.neighbour($0) },
                     next: info.next.map { Self.neighbour($0) },
                     afterNext: info.afterNext.map { Self.neighbour($0) },
                     rollOverAt: rollOverAt)
    }

    private static func neighbour(_ entry: QueueNeighbour) -> LockScreenNeighbour {
        LockScreenNeighbour(title: clip(entry.title), artist: clip(entry.artist))
    }

    /// ActivityKit caps a payload at 4 KB, and four tracks' names go in each.
    /// No real title comes near this; it's here so a pathological one can't
    /// take the whole update down with it.
    private static func clip(_ text: String) -> String {
        text.count > 120 ? String(text.prefix(119)) + "…" : text
    }

    // MARK: - What counts as a change

    /// The parts of a snapshot that decide what the activity shows or when it
    /// rolls over, other than the moving playhead.
    private struct Signature: Equatable {
        var id: UUID
        var title: String
        var artist: String
        var isPlaying: Bool
        /// Whole seconds: the ticker refines a length by fractions as the item
        /// loads, and that moves the roll-over by nothing worth an update.
        var duration: Int
        var previous: QueueNeighbour?
        var next: QueueNeighbour?
        var afterNext: QueueNeighbour?

        init(_ info: RemoteAudioInfo) {
            id = info.id
            title = info.title
            artist = info.artist
            isPlaying = info.isPlaying
            duration = info.duration.isFinite ? Int(info.duration) : 0
            previous = info.previous
            next = info.next
            afterNext = info.afterNext
        }
    }
}

#endif
