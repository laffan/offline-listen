import CarPlay
import Combine

/// Builds and maintains the CarPlay template interface, driving playback through
/// the shared `PlaybackManager` (the same engine the phone UI uses, via
/// `AppServices`). Lives for the duration of a CarPlay connection; created and
/// torn down by `CarPlaySceneDelegate`.
///
/// The hierarchy is deliberately shallow — safe to operate while driving:
///   • Root: a list with an "Inbox" / folder browse section and a flat
///     "Tracks" section of unfiled tracks that play on tap.
///   • Tapping a folder/Inbox row pushes a list of its tracks.
///   • Tapping a track starts it and surfaces the system Now Playing screen.
///
/// The Now Playing screen, its transport buttons, and the lock-screen-style
/// metadata are all served by the `MPNowPlayingInfoCenter` /
/// `MPRemoteCommandCenter` wiring `PlaybackManager` already maintains, so there
/// is nothing CarPlay-specific to build there.
@MainActor
final class CarPlayController {
    private weak var interfaceController: CPInterfaceController?
    private var rootTemplate: CPListTemplate?
    private let services = AppServices.shared
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Lifecycle

    func connect(_ interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        let root = CPListTemplate(title: "Offline Listen", sections: rootSections())
        root.emptyViewTitleVariants = ["No downloads yet"]
        root.emptyViewSubtitleVariants = ["Download tracks on your phone to play them here."]
        rootTemplate = root
        interfaceController.setRootTemplate(root, animated: false, completion: nil)
        observeChanges()
    }

    func disconnect() {
        cancellables.removeAll()
        rootTemplate = nil
        interfaceController = nil
    }

    // MARK: - Observation

    private func observeChanges() {
        // The library changing (a download finishing, a track moved or deleted)
        // rebuilds the root list. Receiving on the main run loop coalesces the
        // burst of edits a single operation can emit.
        services.library.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshRoot() }
            .store(in: &cancellables)

        // The current track changing just updates the "now playing" indicator on
        // the rows already on screen — no need to rebuild templates.
        services.playback.$currentTrack
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshPlayingIndicators() }
            .store(in: &cancellables)
    }

    private func refreshRoot() {
        rootTemplate?.updateSections(rootSections())
    }

    /// Re-flags `isPlaying` on every visible list row across the whole template
    /// stack, matching the row's track id (stashed in `userInfo`) against the
    /// current track.
    private func refreshPlayingIndicators() {
        let currentID = services.playback.currentTrack?.id
        for template in interfaceController?.templates ?? [] {
            guard let list = template as? CPListTemplate else { continue }
            for section in list.sections {
                for case let item as CPListItem in section.items {
                    item.isPlaying = (item.userInfo as? UUID) == currentID
                }
            }
        }
    }

    // MARK: - Template building

    private func rootSections() -> [CPListSection] {
        var sections: [CPListSection] = []
        let library = services.library

        // Browse rows: the Inbox, then each user folder, each drilling into its
        // own track list.
        var browseItems: [CPListItem] = []
        let inbox = library.inboxTracks
        if !inbox.isEmpty {
            browseItems.append(browseItem(title: "Inbox",
                                          detail: countLabel(inbox.count, "unplayed"),
                                          tracks: inbox))
        }
        for folder in library.folders {
            let tracks = library.tracks(in: folder.id)
            browseItems.append(browseItem(title: folder.name,
                                          detail: countLabel(tracks.count, "track"),
                                          tracks: tracks))
        }
        if !browseItems.isEmpty {
            sections.append(CPListSection(items: browseItems, header: "Library", sectionIndexTitle: nil))
        }

        // Unfiled tracks play directly from the root.
        let unfiled = library.unfiledActiveTracks
        if !unfiled.isEmpty {
            let items = unfiled.map { trackItem($0, in: unfiled) }
            sections.append(CPListSection(items: items, header: "Tracks", sectionIndexTitle: nil))
        }
        return sections
    }

    /// A disclosure row that pushes a list of `tracks` when tapped.
    private func browseItem(title: String, detail: String, tracks: [Track]) -> CPListItem {
        let item = CPListItem(text: title, detailText: detail)
        item.accessoryType = .disclosureIndicator
        item.handler = { [weak self] _, completion in
            self?.pushTrackList(title: title, tracks: tracks)
            completion()
        }
        return item
    }

    /// A playable row. `pool` is the list it belongs to, handed to
    /// `PlaybackManager` so autoplay advances through the same set (filtered to
    /// the track's media category, as on the phone).
    private func trackItem(_ track: Track, in pool: [Track]) -> CPListItem {
        let item = CPListItem(text: track.title,
                              detailText: subtitle(for: track),
                              image: TrackArtwork.listImage(for: track))
        item.userInfo = track.id
        item.isPlaying = services.playback.currentTrack?.id == track.id
        item.playingIndicatorLocation = .trailing
        item.handler = { [weak self] _, completion in
            self?.play(track, in: pool)
            completion()
        }
        return item
    }

    private func pushTrackList(title: String, tracks: [Track]) {
        let items = tracks.map { trackItem($0, in: tracks) }
        let template = CPListTemplate(title: title, sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func play(_ track: Track, in pool: [Track]) {
        services.playback.play(track, in: pool)
        guard let interfaceController else { return }
        // Surface the system Now Playing screen, but don't stack a second copy if
        // it's already on top.
        if interfaceController.topTemplate !== CPNowPlayingTemplate.shared {
            interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
        }
    }

    // MARK: - Helpers

    private func subtitle(for track: Track) -> String {
        let artist = track.artist
        let hasArtist = !artist.isEmpty && artist.lowercased() != "unknown"
        let duration = track.duration > 0 ? track.duration.asPlaybackTime : nil
        return [hasArtist ? artist : nil, duration]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func countLabel(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}
