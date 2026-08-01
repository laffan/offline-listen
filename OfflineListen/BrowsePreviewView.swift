import SwiftUI
import AVFoundation
import UIKit

/// The Browse preview modal: downloads the item's media (through the same
/// serial pipeline as the download queue — audio or video per `mode`), plays
/// it in its own mini player (with a picture for video), and offers **Save**
/// (file it into the library — mid-play, playback hands off to the main
/// player at the same position and keeps going) or **Discard** (delete it and
/// hide the item). Dismissing without deciding deletes the temp file and
/// leaves the item untouched.
///
/// It previews a **queue**, not a single track: the list the tapped item came
/// from is handed over with it, so the transport's previous/next buttons walk
/// that list and a track that plays to its end rolls straight into the next
/// one. A caller with nothing to walk (a one-off search result) passes no
/// queue and the side buttons are simply disabled.
struct BrowsePreviewView: View {
    /// The list this preview walks: the caller's queue when it contains the
    /// tapped item, otherwise that item on its own. Resolved once, at init,
    /// so the starting index is right on the very first load.
    let items: [BrowseItem]
    /// Audio (the default) or video — the Browse toggle / Download tab mode.
    let mode: DownloadMode

    init(item: BrowseItem, mode: DownloadMode = .audio, queue: [BrowseItem] = []) {
        let walkable = queue.contains(where: { $0.id == item.id }) ? queue : [item]
        self.items = walkable
        self.mode = mode
        _index = State(initialValue: walkable.firstIndex(where: { $0.id == item.id }) ?? 0)
    }

    @EnvironmentObject private var browse: BrowseStore
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager
    @EnvironmentObject private var aiOrganizer: AIOrganizer
    @Environment(\.dismiss) private var dismiss

    @StateObject private var model = BrowsePreviewModel()
    /// Where in `items` the preview currently is. Changing it *is* the
    /// "load the next track" action — the `.task(id:)` below follows it.
    @State private var index: Int
    /// The artist just added via the selection menu's "Browse Artist" (drives
    /// the confirmation alert).
    @State private var addedArtist: String?
    /// The video-quality preference, remembered across previews. Changing it
    /// mid-preview restarts the download at the new quality.
    @AppStorage("previewVideoQuality") private var qualityRaw: String = VideoQuality.best.rawValue

    private var quality: VideoQuality {
        VideoQuality(rawValue: qualityRaw) ?? .best
    }

    private var qualityBinding: Binding<VideoQuality> {
        Binding(get: { VideoQuality(rawValue: qualityRaw) ?? .best },
                set: { qualityRaw = $0.rawValue })
    }

    /// What's loaded right now. `items` is never empty, so this always resolves.
    private var current: BrowseItem {
        items.indices.contains(index) ? items[index] : items[0]
    }

    var body: some View {
        NavigationStack {
            // Audio previews are deliberately tighter than video ones: with no
            // picture to make room for, the spacing that framed a 16:9 pane
            // just pushed the transport down the sheet.
            VStack(spacing: mode == .video ? 18 : 12) {
                titleBlock

                // Video previews get a quality picker; changing it restarts
                // the download at the chosen resolution (bounded by what the
                // source actually offers in a playable codec).
                if mode == .video {
                    Picker("Quality", selection: qualityBinding) {
                        ForEach(VideoQuality.allCases) { q in
                            Text(q.displayName).tag(q)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .onChange(of: qualityRaw) { _ in
                        Task {
                            await model.restart(item: current, mode: mode, quality: quality,
                                                downloads: downloads, mainPlayback: playback)
                        }
                    }
                }

                phaseContent
                    .frame(maxHeight: .infinity)

                // Outside `phaseContent` on purpose: the transport stays put
                // while the next track resolves, so skipping past a slow one
                // doesn't mean waiting for it to arrive first.
                transport

                decisionButtons
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
            .padding(.top, mode == .video ? 18 : 10)
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
        // A video preview needs the room for its picture; audio keeps the
        // half-height option.
        .presentationDetents(mode == .video ? [.large] : [.medium, .large])
        .onAppear {
            model.onFinished = { autoAdvance() }
        }
        // Keyed on the position, so moving through the queue *is* the load:
        // the previous track's task is cancelled and the new one starts,
        // structurally, the same way the first one did. Marking previewed
        // here covers the auto-advance too, so a list walked hands-off ends
        // up with its "you've heard this one" breadcrumbs filled in.
        .task(id: index) {
            browse.markPreviewed(current)
            await model.load(item: current, mode: mode, quality: quality,
                             downloads: downloads, mainPlayback: playback)
        }
        .onDisappear {
            model.teardown()
        }
        .alert("Added to Browse",
               isPresented: Binding(get: { addedArtist != nil },
                                    set: { if !$0 { addedArtist = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Artist source \"\(addedArtist ?? "")\" was added and is refreshing in the background.")
        }
    }

    private var titleBlock: some View {
        VStack(spacing: 4) {
            SelectableText(text: current.title,
                           font: .preferredFont(forTextStyle: .headline),
                           color: .label,
                           maxLines: 2,
                           onBrowseArtist: browseArtist)
            if !current.detail.isEmpty {
                SelectableText(text: current.detail,
                               font: .preferredFont(forTextStyle: .caption1),
                               color: .secondaryLabel,
                               maxLines: 2,
                               onBrowseArtist: browseArtist)
            }
        }
        .padding(.horizontal)
    }

    /// Previous / play-pause / next, with the queue position beneath. The side
    /// buttons step through the list the item was tapped in; a single-item
    /// preview simply has them disabled.
    private var transport: some View {
        VStack(spacing: 4) {
            HStack(spacing: 30) {
                Button {
                    go(to: index - 1)
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.title2)
                }
                .disabled(!items.indices.contains(index - 1))
                .accessibilityLabel("Previous track")

                Button {
                    model.togglePlayPause()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 52))
                }
                .disabled(!model.phase.isReady)
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")

                Button {
                    go(to: index + 1)
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.title2)
                }
                .disabled(!items.indices.contains(index + 1))
                .accessibilityLabel("Next track")
            }
            // Borderless so the three buttons stay independently tappable and
            // dim themselves at the ends of the queue.
            .buttonStyle(.borderless)

            if items.count > 1 {
                Text("\(index + 1) of \(items.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }

    /// Moves to a position in the queue — the transport's own buttons and the
    /// auto-advance both come through here. Setting `index` is all it takes;
    /// the `.task(id:)` above does the loading.
    private func go(to newIndex: Int) {
        guard items.indices.contains(newIndex) else { return }
        index = newIndex
    }

    /// A track played through to its end: roll into the next one, so a list
    /// can be auditioned without touching the phone. At the end of the queue
    /// there's nothing to advance to and the player just rewinds, as before.
    private func autoAdvance() {
        guard items.indices.contains(index + 1) else { return }
        go(to: index + 1)
    }

    /// The selection menu's "Browse Artist": adds an Artist source for the
    /// selected text and kicks off its first refresh, exactly like typing it
    /// into the add-source sheet.
    private func browseArtist(_ text: String) {
        let source = browse.addSource(kind: .artist, name: "", input: text)
        Task { await browse.refresh(source) }
        addedArtist = text
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch model.phase {
        case .waiting:
            VStack(spacing: 10) {
                ProgressView()
                Text(downloads.isPipelineBusy
                     ? "Waiting for the download queue to free up…"
                     : "Starting…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .preparing:
            VStack(spacing: 10) {
                ProgressView()
                Text(mode == .video ? "Resolving video…" : "Resolving audio…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .downloading(let fraction):
            VStack(spacing: 10) {
                if fraction > 0 {
                    ProgressView(value: fraction)
                        .padding(.horizontal, 40)
                    Text("Downloading… \(Int(fraction * 100))%")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                    Text("Downloading…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        case .ready:
            miniPlayer
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("Try Again") {
                    Task {
                        await model.load(item: current, mode: mode, quality: quality,
                                         downloads: downloads, mainPlayback: playback)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// The picture (video only) and the scrubber. The play/pause and the
    /// queue's next/previous live in `transport`, below and outside the phase
    /// switch, so they don't come and go as tracks load.
    private var miniPlayer: some View {
        VStack(spacing: model.isVideo ? 14 : 8) {
            // Video previews get a picture above the controls; the same
            // AVPlayer drives both, so scrub/play-pause stay in sync. The
            // height is fixed to a 16:9 slice of the pane's full width — a
            // flexible aspect-ratio frame would let the surrounding VStack
            // squeeze the picture down to a sliver when vertical space is
            // tight (the "minuscule rectangle" bug).
            if model.isVideo, let player = model.player {
                NativeVideoPlayer(player: player, allowsPiP: false)
                    .frame(maxWidth: .infinity)
                    .frame(height: UIScreen.main.bounds.width * 9 / 16)
            }

            VStack(spacing: 0) {
                Slider(
                    value: Binding(
                        get: { model.currentTime },
                        set: { model.scrub(to: $0) }
                    ),
                    in: 0...max(model.duration, 1),
                    onEditingChanged: { editing in model.isScrubbing = editing }
                )

                HStack {
                    Text(model.currentTime.asPlaybackTime)
                    Spacer()
                    Text(model.duration.asPlaybackTime)
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
        }
    }

    private var decisionButtons: some View {
        HStack(spacing: 12) {
            Button(role: .destructive) {
                model.markDiscardedAndCleanUp()
                browse.markDiscarded(current)
                dismiss()
            } label: {
                Label("Discard", systemImage: "xmark")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                save()
            } label: {
                Label("Save", systemImage: "checkmark")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.phase.isReady)
        }
    }

    /// Files the previewed audio into the library as a normal track (it lands
    /// in the Inbox like any fresh download) and lets the AI organizer at it.
    /// Saving mid-listen doesn't cut the song off: playback hands off to the
    /// main player at the same position (now in the background, like any
    /// library track), so browsing continues with the music still going.
    private func save() {
        let saved = current
        let handoffTime = model.currentTime
        let wasPlaying = model.isPlaying
        guard let track = model.saveToLibrary(as: saved, library: library) else { return }
        browse.markSaved(saved)
        if wasPlaying {
            // The handoff doesn't count as listening — the saved track still
            // lands in the Inbox like any fresh download.
            playback.play(track, in: library.activeTracks, startAt: handoffTime,
                          countsAsListened: false)
        }
        Task { await aiOrganizer.organizeIfEnabled(track.id) }
        dismiss()
    }
}

/// Selectable text for the preview modal, backed by a non-editable
/// `UITextView` because SwiftUI's `Text` offers no way to extend its selection
/// menu. Selecting text adds a **Browse Artist** action alongside the system
/// ones — handing the selection (an artist name in a title like
/// "Ali Farka Touré — Savane") to `onBrowseArtist`.
struct SelectableText: UIViewRepresentable {
    let text: String
    let font: UIFont
    let color: UIColor
    let maxLines: Int
    let onBrowseArtist: @MainActor (String) -> Void

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.maximumNumberOfLines = maxLines
        view.textContainer.lineBreakMode = .byTruncatingTail
        view.textAlignment = .center
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        view.text = text
        view.font = font
        view.textColor = color
        context.coordinator.onBrowseArtist = onBrowseArtist
    }

    /// Non-scrolling UITextViews don't self-size cleanly inside SwiftUI;
    /// answer the proposal explicitly with the wrapped text height.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onBrowseArtist: onBrowseArtist)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onBrowseArtist: @MainActor (String) -> Void

        init(onBrowseArtist: @escaping @MainActor (String) -> Void) {
            self.onBrowseArtist = onBrowseArtist
        }

        func textView(_ textView: UITextView,
                      editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0,
                  let text = textView.text,
                  let selectedRange = Range(range, in: text) else { return nil }
            let selected = String(text[selectedRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !selected.isEmpty else { return nil }

            let browseArtist = UIAction(title: "Browse Artist",
                                        image: UIImage(systemName: "music.mic")) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.onBrowseArtist(selected)
                }
            }
            return UIMenu(children: suggestedActions + [browseArtist])
        }
    }
}

/// State machine + mini audio player behind the preview modal. Owns the temp
/// file: it's deleted on teardown unless `saveToLibrary` moved it first.
@MainActor
final class BrowsePreviewModel: ObservableObject {
    enum Phase {
        case waiting
        case preparing
        case downloading(Double)
        case ready
        case failed(String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    @Published private(set) var phase: Phase = .waiting
    @Published private(set) var isPlaying = false
    @Published var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    /// True when the previewed media is a video (the modal shows a picture).
    @Published private(set) var isVideo = false
    /// Set by the slider while dragging so observer ticks don't fight the thumb.
    var isScrubbing = false
    /// Called when the track plays through to its end — the modal's cue to
    /// advance to the next item in the queue it was opened with.
    var onFinished: (() -> Void)?

    private var media: ExtractedMedia?
    /// Exposed (read-only) so the modal's video surface can render it.
    private(set) var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var downloadTask: Task<Void, Never>?
    /// Bumped on every start/teardown so a stale task can't clear a newer
    /// task's handle when a cancel and a retry overlap.
    private var generation = 0
    /// True once the file has been moved into the library — teardown must not
    /// delete it then.
    private var savedToLibrary = false

    /// Kicks off (or retries) the preview download and, on success, starts the
    /// mini player — pausing the app's main playback so they don't talk over
    /// each other.
    func start(item: BrowseItem, mode: DownloadMode, quality: VideoQuality = .best,
               downloads: DownloadManager, mainPlayback: PlaybackManager) async {
        guard downloadTask == nil, media == nil else { return }
        phase = .waiting
        generation += 1
        let gen = generation
        let task = Task { [weak self] in
            do {
                let media = try await downloads.downloadPreview(
                    urlString: item.url,
                    mode: mode,
                    quality: quality,
                    onBegin: { [weak self] in self?.phase = .preparing },
                    onDownloadStart: { [weak self] in self?.phase = .downloading(0) },
                    onProgress: { [weak self] fraction in self?.phase = .downloading(fraction) }
                )
                if Task.isCancelled || self == nil || self?.generation != gen {
                    // The modal went away while the extraction was finishing —
                    // nobody will play or save this file.
                    try? FileManager.default.removeItem(at: media.fileURL)
                } else {
                    self?.attachPlayer(to: media, mainPlayback: mainPlayback)
                }
            } catch {
                if !isCancellation(error) {
                    self?.phase = .failed(error.localizedDescription)
                }
            }
            if self?.generation == gen {
                self?.downloadTask = nil
            }
        }
        downloadTask = task
        await task.value
    }

    /// Switches the mini player to a different item — the queue's next/previous
    /// and the end-of-track auto-advance both land here. Whatever is in flight
    /// is cancelled and its file dropped before the new preview starts.
    func load(item: BrowseItem, mode: DownloadMode, quality: VideoQuality,
              downloads: DownloadManager, mainPlayback: PlaybackManager) async {
        reset()
        await start(item: item, mode: mode, quality: quality,
                    downloads: downloads, mainPlayback: mainPlayback)
    }

    /// Re-runs the preview at a different quality: the same reset-and-start,
    /// noted in the Log because nothing on screen says why it restarted.
    func restart(item: BrowseItem, mode: DownloadMode, quality: VideoQuality,
                 downloads: DownloadManager, mainPlayback: PlaybackManager) async {
        appLog("Preview restarting at \(quality.displayName) quality…", category: "Browse")
        await load(item: item, mode: mode, quality: quality,
                   downloads: downloads, mainPlayback: mainPlayback)
    }

    /// Back to square one for a fresh item. Bumping the generation first means
    /// the cancelled task can't clear the new task's handle or resurrect its
    /// file. A file already moved into the library is *released*, never
    /// deleted — it stopped being the preview's to clean up the moment it was
    /// saved.
    private func reset() {
        generation += 1
        downloadTask?.cancel()
        downloadTask = nil
        stopPlayer()
        if savedToLibrary {
            media = nil
            savedToLibrary = false
        } else {
            deleteTempFile()
        }
        isVideo = false
        currentTime = 0
        duration = 0
        phase = .waiting
    }

    private func attachPlayer(to media: ExtractedMedia, mainPlayback: PlaybackManager) {
        self.media = media
        isVideo = media.isVideo
        duration = media.duration
        if duration <= 0 {
            // Extractor metadata can lack a duration; read it off the file.
            Task { [weak self] in
                let real = await mediaDuration(of: media.fileURL)
                self?.duration = real
            }
        }

        let player = AVPlayer(url: media.fileURL)
        self.player = player

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, !self.isScrubbing else { return }
                self.currentTime = time.seconds
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = false
                // Rewind first, then tell the modal: at the end of a queue
                // (or with no queue at all) nothing advances and this is the
                // whole behaviour, exactly as it was before.
                self.currentTime = 0
                self.player?.seek(to: .zero)
                self.onFinished?()
            }
        }

        // Don't talk over the main player.
        if mainPlayback.isPlaying {
            mainPlayback.togglePlayPause()
        }

        phase = .ready
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        isPlaying = true
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
        }
        isPlaying.toggle()
    }

    func scrub(to time: Double) {
        currentTime = time
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Moves the previewed file into Documents and adds a library track for
    /// it. Returns the new track, or nil when there's nothing ready to save.
    func saveToLibrary(as item: BrowseItem, library: LibraryStore) -> Track? {
        guard let media else { return nil }
        stopPlayer()

        let title = item.title.isEmpty ? media.title : item.title
        let ext = media.fileURL.pathExtension.isEmpty
            ? (media.isVideo ? "mp4" : "m4a")
            : media.fileURL.pathExtension
        let fileName = AppPaths.uniqueDocumentName(base: title.sanitizedFileName(), ext: ext)
        let destination = AppPaths.documents.appendingPathComponent(fileName)
        do {
            try FileManager.default.moveItem(at: media.fileURL, to: destination)
        } catch {
            phase = .failed("Couldn't save the file: \(error.localizedDescription)")
            return nil
        }
        savedToLibrary = true

        let track = Track(
            title: title,
            fileName: fileName,
            sourceURL: item.url,
            duration: media.duration,
            isVideo: media.isVideo,
            chapters: media.chapters
        )
        library.add(track)
        // Album art (best-effort) when the item carried a cover URL — the
        // discography browser's matched tracks do.
        ArtworkFetcher.attach(item.artworkURL, to: track.id, library: library)
        appLog("Preview saved to library: \"\(title)\"", level: .success, category: "Browse")
        return track
    }

    /// Discard tapped: stop playback and delete the file right away (teardown
    /// would too, but the intent is explicit here).
    func markDiscardedAndCleanUp() {
        downloadTask?.cancel()
        stopPlayer()
        deleteTempFile()
    }

    /// Called when the modal goes away for any reason: cancel an in-flight
    /// download, stop the player, and delete the temp file unless it was saved.
    func teardown() {
        generation += 1
        downloadTask?.cancel()
        downloadTask = nil
        // The callback holds the (dismissed) modal; dropping it here keeps a
        // finished track from advancing a queue nobody is watching.
        onFinished = nil
        stopPlayer()
        if !savedToLibrary {
            deleteTempFile()
        }
    }

    private func stopPlayer() {
        player?.pause()
        isPlaying = false
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    private func deleteTempFile() {
        guard let media else { return }
        try? FileManager.default.removeItem(at: media.fileURL)
        self.media = nil
    }
}
