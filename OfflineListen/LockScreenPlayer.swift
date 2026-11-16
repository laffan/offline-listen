import Foundation
#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import MediaPlayer
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
/// get (`onLockScreenChange`, at the ticker's 2 Hz), and most of those change
/// nothing it shows: the playhead moving is drawn by the activity's own timer
/// views. So an update goes out only when something visible changes — the
/// track, play/pause, the neighbours, the cover, the length — or when the
/// playhead jumps (a seek, a skip) rather than moves.
///
/// **What iOS lets it do, and when.** A Live Activity can only be *started*
/// with the app in the foreground, so it starts when playback starts in the
/// app, or the next time the app is opened. Updating one from the background is
/// documented as allowed, but developers report that iOS drops updates from a
/// process that is only playing background audio — exactly this app with the
/// phone locked. The state is built to survive that: the bar runs off its own
/// clock, the next track is carried ahead of time and rolls in when the
/// current one is due to end (`ContentState.presented(isStale:)`), every
/// update a tap causes is sent while the tap's intent is still running, and
/// the whole thing is brought up to date whenever the app comes forward.
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
    /// What the activity was last given, and the parts of the snapshot it was
    /// built from, for telling a real change from the ticker repeating itself.
    private var sent: State?
    private var sentSignature: Signature?
    /// The snapshot a start was last tried for and refused (Live Activities
    /// switched off for the app in iOS Settings, say), so the ticker doesn't
    /// ask again twice a second. Cleared by anything that forces a refresh.
    private var refusedStart: Signature?
    /// True once the person has swiped the activity away. It isn't put back
    /// until a track is started from the app: removing it is an answer.
    private var dismissedByPerson = false

    /// The cover thumbnail made for a borrower's artwork, which has no file to
    /// key it by — kept so a seek doesn't re-encode it.
    private var borrowedArtwork: (id: UUID, object: ObjectIdentifier, file: String)?

    private init() {}

    /// Wires the player up. Called once, from the app's entry point.
    func install(on playback: PlaybackManager) {
        self.playback = playback
        playback.onLockScreenChange = { [weak self] info in self?.receive(info) }
        playback.onLockScreenStart = { [weak self] in self?.playbackStarted() }
        LockScreenTransport.handler = { [weak self] command in await self?.perform(command) }
        adoptRunningActivity()
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

        let jumped = sent.map { abs(Self.expectedElapsed(of: $0) - info.elapsed) > 2 } ?? true
        guard force || jumped || signature != sentSignature else { return }
        let state = makeState(from: info)
        sent = state
        sentSignature = signature
        send(state, to: activity)
    }

    /// Where `state`'s playhead has got to by now, by its own clock.
    private static func expectedElapsed(of state: State) -> Double {
        state.isPlaying ? state.elapsed + Date().timeIntervalSince(state.anchor) : state.elapsed
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
            sent = state
            sentSignature = signature
            adopt(activity)
            appLog("Lock screen player up for \"\(state.title)\".", level: .debug, category: "Player")
        } catch {
            refusedStart = signature
            appLog("Couldn't put the lock screen player up: \(error.localizedDescription)",
                   level: .warning, category: "Player")
        }
    }

    /// Takes over an activity left running by the last launch — the app may
    /// have been killed with it up, or woken by one of its buttons — so there
    /// is never more than one. It's brought up to date by the first snapshot.
    private func adoptRunningActivity() {
        let running = Activity<LockScreenPlayerAttributes>.activities
        var kept = false
        for activity in running {
            if !kept, Self.isLive(activity) {
                adopt(activity)
                kept = true
            } else {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
            }
        }
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
        sent = nil
        sentSignature = nil
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
        // Woken from cold by a button on an activity left up by the last run:
        // nothing is loaded yet, so load what was, and act on that.
        if !playback.hasSomethingToPlay {
            playback.restoreLastSession()
        }
        switch command {
        case .previous:
            playback.remotePrevious()
        case .previousTrack:
            playback.remotePlayPreviousTrack()
        case .skipBackward:
            playback.remoteSkipBackward()
        case .togglePlayPause:
            playback.remoteTogglePlayPause()
        case .skipForward:
            playback.remoteSkipForward()
        case .next:
            playback.remoteNext()
        }
        await updateChain?.value
    }

    // MARK: - State

    private func makeState(from info: RemoteAudioInfo) -> State {
        let now = Date()
        let next = info.next.map { neighbour($0) }
        let remaining = info.duration - info.elapsed
        // Only a track that is playing, with something after it and a known
        // end, can roll over on its own.
        let rollOverAt: Date? = info.isPlaying && next != nil && info.duration > 0 && remaining > 0
            ? now.addingTimeInterval(remaining)
            : nil
        return State(trackID: info.id,
                     title: Self.clip(info.title),
                     artist: Self.clip(info.artist),
                     artworkFile: artworkFile(for: info),
                     isPlaying: info.isPlaying,
                     duration: max(0, info.duration),
                     elapsed: max(0, info.elapsed),
                     anchor: now,
                     previous: info.previous.map { neighbour($0) },
                     next: next,
                     afterNext: info.afterNext.map { neighbour($0) },
                     rollOverAt: rollOverAt)
    }

    private func neighbour(_ entry: QueueNeighbour) -> LockScreenNeighbour {
        LockScreenNeighbour(title: Self.clip(entry.title),
                            artist: Self.clip(entry.artist),
                            duration: max(0, entry.duration),
                            artworkFile: entry.artworkFileName.flatMap { thumbnail(forLibraryArtwork: $0) })
    }

    /// ActivityKit caps a payload at 4 KB, and four tracks' names go in each.
    /// No real title comes near this; it's here so a pathological one can't
    /// take the whole update down with it.
    private static func clip(_ text: String) -> String {
        text.count > 120 ? String(text.prefix(119)) + "…" : text
    }

    // MARK: - Artwork

    private func artworkFile(for info: RemoteAudioInfo) -> String? {
        if let name = info.artworkFileName {
            return thumbnail(forLibraryArtwork: name)
        }
        if let artwork = info.artwork {
            return thumbnail(forBorrowed: artwork, id: info.id)
        }
        return nil
    }

    /// A library cover, shrunk into the App Group. Named after the cover file
    /// and remade only when the cover is newer than the copy — Get Album Art
    /// rewrites a cover under the same name.
    private func thumbnail(forLibraryArtwork name: String) -> String? {
        let source = AppPaths.artwork.appendingPathComponent(name)
        let file = "track-" + (name as NSString).deletingPathExtension + ".jpg"
        guard let destination = LockScreenArtwork.url(for: file) else { return nil }
        if let made = Self.modificationDate(of: destination),
           let cover = Self.modificationDate(of: source), made >= cover {
            return file
        }
        guard let image = ImageDecoding.thumbnail(at: source, maxPixel: LockScreenArtwork.maxPixel) else {
            return nil
        }
        return write(image, as: file)
    }

    /// A borrower's cover (a Browse preview's, fetched from the web), which
    /// arrives as an `MPMediaItemArtwork` with no file behind it.
    private func thumbnail(forBorrowed artwork: MPMediaItemArtwork, id: UUID) -> String? {
        let object = ObjectIdentifier(artwork)
        if let borrowedArtwork, borrowedArtwork.id == id, borrowedArtwork.object == object {
            return borrowedArtwork.file
        }
        let side = CGFloat(LockScreenArtwork.maxPixel)
        guard let source = artwork.image(at: CGSize(width: side, height: side)) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let aspect = source.size.width / max(source.size.height, 1)
        let size = aspect >= 1
            ? CGSize(width: side, height: (side / aspect).rounded())
            : CGSize(width: (side * aspect).rounded(), height: side)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: size))
        }
        let file = "preview-\(id.uuidString).jpg"
        guard let written = write(image, as: file) else { return nil }
        borrowedArtwork = (id, object, written)
        return written
    }

    private func write(_ image: UIImage, as file: String) -> String? {
        guard let directory = LockScreenArtwork.directory,
              let data = image.jpegData(compressionQuality: 0.85) else { return nil }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(file), options: .atomic)
        } catch {
            appLog("Couldn't write a lock screen cover: \(error.localizedDescription)",
                   level: .warning, category: "Player")
            return nil
        }
        prune(directory)
        return file
    }

    /// Keeps the folder to the newest few — enough for every track the
    /// activity names at once, with room for a queue's worth beside them.
    private func prune(_ directory: URL) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > LockScreenArtwork.keep else { return }
        let oldestFirst = files.sorted {
            (Self.modificationDate(of: $0) ?? .distantPast) < (Self.modificationDate(of: $1) ?? .distantPast)
        }
        for file in oldestFirst.prefix(files.count - LockScreenArtwork.keep) {
            try? fileManager.removeItem(at: file)
        }
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: - What counts as a change

    /// The parts of a snapshot the activity shows, other than the moving
    /// playhead. Two snapshots with the same signature draw the same thing.
    private struct Signature: Equatable {
        var id: UUID
        var title: String
        var artist: String
        var isPlaying: Bool
        /// Whole seconds: the ticker refines a length by fractions as the item
        /// loads, and nobody can see that.
        var duration: Int
        var artworkFileName: String?
        var artwork: ObjectIdentifier?
        var previous: QueueNeighbour?
        var next: QueueNeighbour?
        var afterNext: QueueNeighbour?

        init(_ info: RemoteAudioInfo) {
            id = info.id
            title = info.title
            artist = info.artist
            isPlaying = info.isPlaying
            duration = info.duration.isFinite ? Int(info.duration) : 0
            artworkFileName = info.artworkFileName
            artwork = info.artwork.map { ObjectIdentifier($0) }
            previous = info.previous
            next = info.next
            afterNext = info.afterNext
        }
    }
}

#endif
