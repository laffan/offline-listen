import SwiftUI
import AVFoundation
import MediaPlayer
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

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
///
/// The queue itself lives on the **model**, not in this view's state. That
/// isn't tidiness: a queue that only advanced when SwiftUI re-rendered stopped
/// advancing the moment the phone was locked, because a backgrounded app draws
/// nothing. Everything the transport does — the buttons here, the lock screen's,
/// and the end-of-track hand-off — is a call into the model, which can move
/// with the screen off.
struct BrowsePreviewView: View {
    /// The list this preview walks: the caller's queue when it contains the
    /// tapped item, otherwise that item on its own. Resolved once, at init,
    /// so the starting index is right on the very first load.
    let items: [BrowseItem]
    /// Audio (the default) or video — the Browse toggle / Download tab mode.
    let mode: DownloadMode
    /// Where in `items` the tapped item sits.
    private let startIndex: Int

    init(item: BrowseItem, mode: DownloadMode = .audio, queue: [BrowseItem] = []) {
        // Membership by id *or* url: the discography browser mints its items on
        // the fly (a `BrowseItem` takes a fresh id each time it's built), so an
        // album's queue and the track tapped in it can be equal in every way
        // that matters and still not share an id — which used to drop the whole
        // record and leave the modal walking a queue of one.
        let walkable = queue.contains(where: { $0.id == item.id || $0.url == item.url })
            ? queue : [item]
        self.items = walkable
        self.mode = mode
        self.startIndex = walkable.firstIndex(where: { $0.id == item.id })
            ?? walkable.firstIndex(where: { $0.url == item.url })
            ?? 0
    }

    @EnvironmentObject private var browse: BrowseStore
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager
    @EnvironmentObject private var aiOrganizer: AIOrganizer
    @Environment(\.dismiss) private var dismiss

    @StateObject private var model = BrowsePreviewModel()
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

    /// What's loaded right now — the model's answer once it has been handed the
    /// queue, and the tapped item for the one render before that.
    private var current: BrowseItem {
        model.currentItem ?? items[min(startIndex, items.count - 1)]
    }

    /// Where in the queue the preview is. `items` is resolved at `init`, so
    /// this is right from the very first render — before the model has been
    /// handed anything — which is what lets the transport below be live from
    /// the moment the sheet opens rather than after the first `.task`.
    private var position: Int {
        model.isConfigured ? model.index : startIndex
    }

    private var canStepBack: Bool { items.indices.contains(position - 1) }
    private var canStepForward: Bool { items.indices.contains(position + 1) }

    /// Walks the queue. It configures first — idempotent, and the same call the
    /// `.task` makes — so a tap can never land on a model that hasn't been
    /// given the list it's meant to walk, whatever order SwiftUI ran things in.
    private func step(by delta: Int) {
        configureModel()
        model.go(to: position + delta)
    }

    private func configureModel() {
        model.configure(items: items, startAt: startIndex, mode: mode,
                        quality: quality, downloads: downloads,
                        playback: playback, browse: browse)
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
                        model.setQuality(quality)
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
        // Hands the model the queue and the stores it drives, then lets go:
        // from here on the loading, the advancing and the lock screen are all
        // the model's, so none of it depends on this view being on screen.
        .task {
            configureModel()
            model.begin()
        }
        // The list can grow under an open preview — a release is matched
        // against YouTube a track at a time, and the modal is opened on the
        // first hit. The transport above already reads `items`, so it lights up
        // on its own; this is what gets the longer queue to the model, which is
        // what the end-of-track advance walks.
        .onChange(of: items.count) { _ in
            configureModel()
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
                           style: .headline,
                           maxLines: 2,
                           onBrowseArtist: browseArtist)
            if !current.detail.isEmpty {
                SelectableText(text: current.detail,
                               style: .caption,
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
                    step(by: -1)
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.title2)
                }
                .disabled(!canStepBack)
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
                    step(by: 1)
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.title2)
                }
                .disabled(!canStepForward)
                .accessibilityLabel("Next track")
            }
            // Borderless so the three buttons stay independently tappable and
            // dim themselves at the ends of the queue.
            .buttonStyle(.borderless)

            if items.count > 1 {
                Text("\(position + 1) of \(items.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
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
                    model.retry()
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
                    .frame(height: PlatformScreen.width * 9 / 16)
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

/// The two text roles the preview modal draws with, named here rather than
/// passed as a platform font/colour pair so the call sites don't have to know
/// whether they're talking to UIKit or AppKit.
enum SelectableTextStyle {
    case headline, caption

    #if canImport(UIKit)
    var font: UIFont {
        UIFont.preferredFont(forTextStyle: self == .headline ? .headline : .caption1)
    }
    var color: UIColor { self == .headline ? .label : .secondaryLabel }
    #else
    var font: NSFont {
        NSFont.preferredFont(forTextStyle: self == .headline ? .headline : .caption1)
    }
    var color: NSColor { self == .headline ? .labelColor : .secondaryLabelColor }
    #endif
}

#if canImport(UIKit)

/// Selectable text for the preview modal, backed by a non-editable
/// `UITextView` because SwiftUI's `Text` offers no way to extend its selection
/// menu. Selecting text adds a **Browse Artist** action alongside the system
/// ones — handing the selection (an artist name in a title like
/// "Ali Farka Touré — Savane") to `onBrowseArtist`.
struct SelectableText: UIViewRepresentable {
    let text: String
    let style: SelectableTextStyle
    let maxLines: Int
    let onBrowseArtist: @MainActor (String) -> Void

    private var font: UIFont { style.font }
    private var color: UIColor { style.color }

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

#else

/// The AppKit twin: a non-editable `NSTextView` whose right-click menu grows a
/// **Browse Artist** item whenever there's a selection.
struct SelectableText: NSViewRepresentable {
    let text: String
    let style: SelectableTextStyle
    let maxLines: Int
    let onBrowseArtist: @MainActor (String) -> Void

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.maximumNumberOfLines = maxLines
        view.textContainer?.lineBreakMode = .byTruncatingTail
        view.alignment = .center
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        view.string = text
        view.font = style.font
        view.textColor = style.color
        // Re-assert alignment: setting `string` resets the typing attributes,
        // so without this the second render draws left-aligned.
        view.alignment = .center
        context.coordinator.onBrowseArtist = onBrowseArtist
    }

    /// Same story as UIKit's: a non-scrolling text view won't self-size inside
    /// SwiftUI, so answer the proposal with the wrapped height.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0,
              let container = nsView.textContainer,
              let layoutManager = nsView.layoutManager else { return nil }
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let height = layoutManager.usedRect(for: container).height
        return CGSize(width: width, height: height)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onBrowseArtist: onBrowseArtist)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onBrowseArtist: @MainActor (String) -> Void
        private var selected = ""

        init(onBrowseArtist: @escaping @MainActor (String) -> Void) {
            self.onBrowseArtist = onBrowseArtist
        }

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            let range = view.selectedRange()
            guard range.length > 0,
                  let text = view.string as NSString?,
                  range.location + range.length <= text.length else { return menu }
            selected = text.substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !selected.isEmpty else { return menu }

            menu.addItem(.separator())
            let item = NSMenuItem(title: "Browse Artist",
                                  action: #selector(browseSelection), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            return menu
        }

        @objc private func browseSelection() {
            let selection = selected
            Task { @MainActor [weak self] in
                self?.onBrowseArtist(selection)
            }
        }
    }
}

#endif

/// The preview's player: the queue it's walking, the pipeline download behind
/// each entry, the AVPlayer that plays it, and the lock screen it borrows while
/// it does. Owns the temp file too — it's deleted on teardown unless
/// `saveToLibrary` moved it first.
///
/// Three things live here that used to live in the view, and all three for the
/// same reason: **a locked phone draws nothing**. The queue and the position in
/// it, the decision to load the next track, and the now-playing metadata are
/// all state a backgrounded app still has to be able to change. Driven from
/// `@State` and a `.task(id:)`, none of them moved once the screen went off —
/// the audio finished and the modal simply sat there.
@MainActor
final class BrowsePreviewModel: ObservableObject, RemoteAudioSource {
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
    /// The list being auditioned, and where in it the preview is. The modal
    /// hands these over once and then only reads them: every move through the
    /// queue — its own buttons, the lock screen's, the end-of-track advance —
    /// is a call into this object.
    @Published private(set) var items: [BrowseItem] = []
    @Published private(set) var index = 0
    /// Whether the queue and the stores have been handed over yet. Published
    /// because the transport's own enabled state depends on it: until this is
    /// true there is nothing here to walk, and a button that looks live but
    /// calls into an unconfigured model is a tap that does nothing.
    @Published private(set) var isConfigured = false
    /// Set by the slider while dragging so observer ticks don't fight the thumb.
    var isScrubbing = false

    /// What's loaded (or loading) right now.
    var currentItem: BrowseItem? {
        items.indices.contains(index) ? items[index] : items.first
    }

    var canGoNext: Bool { items.indices.contains(index + 1) }
    var canGoPrevious: Bool { items.indices.contains(index - 1) }

    private var mode: DownloadMode = .audio
    private var quality: VideoQuality = .best
    // Held strongly: these are the app's own long-lived stores, and none of
    // them holds this model back (`PlaybackManager` keeps its borrower weak).
    private var downloads: DownloadManager?
    private var playback: PlaybackManager?
    private var browse: BrowseStore?
    private var started = false

    private var media: ExtractedMedia?
    /// Exposed (read-only) so the modal's video surface can render it.
    private(set) var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    /// The preview's end-of-track watchdog, and the reason a hands-off audition
    /// gets through a record. `AVPlayerItemDidPlayToEndTime` was the only thing
    /// watching for the end here, and it is the same not-always-delivered
    /// signal the library player long ago stopped trusting on its own: a file
    /// whose container over-reports its length runs out of samples at a
    /// timestamp AVFoundation doesn't consider the end, so the notification
    /// never comes and the queue stops between two tracks.
    ///
    /// It has to be a wall-clock timer rather than the periodic time observer
    /// above, because that observer is driven by the item's *own* timeline — it
    /// stops firing the instant the playhead does, which is exactly the moment
    /// something needs to notice.
    private var watchdog: Timer?
    private var lastWatchdogPosition: Double = -1
    private var stalledTicks = 0
    private var playheadHasMoved = false
    /// True once the loaded track's end has been acted on, so the two routes to
    /// it can't both advance the queue.
    private var didFinishCurrent = false
    private var downloadTask: Task<Void, Never>?
    /// The item's cover, fetched for the lock screen (best-effort — a miss just
    /// leaves the artwork blank, as it does everywhere else in the app).
    private var artworkTask: Task<Void, Never>?
    private var artwork: MPMediaItemArtwork?
    /// Bumped on every start/teardown so a stale task can't clear a newer
    /// task's handle when a cancel and a retry overlap.
    private var generation = 0
    /// True once the file has been moved into the library — teardown must not
    /// delete it then.
    private var savedToLibrary = false

    // MARK: - Setup

    /// Hands over the queue and the stores. Idempotent: the modal calls it from
    /// its `.task` and again before every transport move, so a tap can never
    /// land on a model that hasn't been given the list it is supposed to walk.
    /// Re-running it beyond the first time is a no-op — it must not restart a
    /// preview that's already going.
    func configure(items: [BrowseItem], startAt: Int, mode: DownloadMode,
                   quality: VideoQuality, downloads: DownloadManager,
                   playback: PlaybackManager, browse: BrowseStore) {
        guard !isConfigured else {
            adopt(items: items, startAt: startAt)
            return
        }
        isConfigured = true
        self.items = items
        self.index = items.indices.contains(startAt) ? startAt : 0
        self.mode = mode
        self.quality = quality
        self.downloads = downloads
        self.playback = playback
        self.browse = browse
        appLog("Preview queue: \(items.count) track(s), starting at \(self.index + 1).",
               level: .debug, category: "Browse")
    }

    /// Takes on a queue the modal has been handed after it was already
    /// configured — which is the ordinary case, not an exotic one.
    ///
    /// A release is matched against YouTube a track at a time, and each one
    /// offers Preview the moment *it* lands, so a preview opened on the first
    /// hit was handed the only entry that existed yet and then kept it: a
    /// record of one, its next/previous dimmed for good, while the other twelve
    /// tracks lit up behind it. The list is now re-handed as it grows, and the
    /// same applies to a sheet re-presented on a track from a different list
    /// while it's still up (SwiftUI updates a sheet in place rather than
    /// rebuilding it).
    ///
    /// The entry already loaded keeps playing and keeps its place, wherever it
    /// has moved to in the longer list — growing the queue is not a reason to
    /// restart the audition. Only a list the current entry has left entirely
    /// counts as a different record.
    private func adopt(items newItems: [BrowseItem], startAt: Int) {
        // Compared by url, not id: the discography browser mints its items on
        // the fly, so the same record re-offered is a set of fresh ids for
        // tracks that haven't changed at all.
        guard newItems.map(\.url) != items.map(\.url) else { return }
        let loaded = currentItem
        items = newItems
        if let loaded,
           let moved = newItems.firstIndex(where: { $0.id == loaded.id || $0.url == loaded.url }) {
            index = moved
            appLog("Preview queue grew to \(newItems.count) track(s); still on \(moved + 1).",
                   level: .debug, category: "Browse")
        } else {
            index = newItems.indices.contains(startAt) ? startAt : 0
            appLog("Preview handed a new queue: \(newItems.count) track(s), starting at \(index + 1).",
                   level: .debug, category: "Browse")
            startCurrent()
        }
    }

    /// Starts the first track. Idempotent, so a view that appears twice doesn't
    /// restart the download.
    func begin() {
        guard isConfigured, !started else { return }
        started = true
        startCurrent()
    }

    // MARK: - Walking the queue

    /// Moves to a position and loads it. The transport's buttons, the lock
    /// screen's, and the end-of-track advance all come through here.
    func go(to position: Int) {
        guard items.indices.contains(position) else {
            appLog("Preview: nothing at position \(position + 1) of \(items.count) — staying put.",
                   level: .debug, category: "Browse")
            return
        }
        index = position
        // A move *is* a start, so a `begin()` arriving afterwards mustn't drag
        // the preview back to where the modal opened.
        started = true
        appLog("Preview → \(position + 1) of \(items.count): \"\(currentItem?.title ?? "")\"",
               level: .debug, category: "Browse")
        startCurrent()
    }

    func next() { go(to: index + 1) }
    func previous() { go(to: index - 1) }

    /// Re-runs the current entry — the failure view's Try Again.
    func retry() { startCurrent() }

    /// Re-runs it at a different resolution. Noted in the Log because nothing
    /// on screen says why the download restarted.
    func setQuality(_ newQuality: VideoQuality) {
        guard newQuality != quality else { return }
        quality = newQuality
        appLog("Preview restarting at \(newQuality.displayName) quality…", category: "Browse")
        startCurrent()
    }

    /// Drops whatever is in flight and starts the entry at `index`: mark it
    /// previewed (so a list walked hands-off still fills in its breadcrumbs),
    /// fetch its cover for the lock screen, then run it through the pipeline.
    private func startCurrent() {
        // Both of these are "can't happen" — the modal configures before it
        // ever calls in, and the queue is never empty — but a silent return
        // here reads from the outside exactly like a dead button, so say so.
        guard let downloads else {
            appLog("Preview can't start: the modal hasn't handed over the download pipeline.",
                   level: .warning, category: "Browse")
            return
        }
        guard let item = currentItem else {
            appLog("Preview can't start: the queue is empty.", level: .warning, category: "Browse")
            return
        }
        reset()
        browse?.markPreviewed(item)
        loadArtwork(for: item)
        playback?.remoteAudioDidChange(self)

        let gen = generation
        let mode = self.mode
        let quality = self.quality
        downloadTask = Task { [weak self] in
            // Resolving and downloading the next track is *seconds* of silence,
            // not the milliseconds a library track's item swap costs. An app
            // with the audio background mode is alive because it is playing, so
            // that gap is exactly where a locked phone had the app suspended and
            // the audition simply ended.
            await BackgroundActivity.spanning("Preview download") {
                guard let self else { return }
                await self.runDownload(item: item, mode: mode, quality: quality,
                                       downloads: downloads, generation: gen)
            }
        }
    }

    private func runDownload(item: BrowseItem, mode: DownloadMode, quality: VideoQuality,
                             downloads: DownloadManager, generation gen: Int) async {
        phase = .waiting
        do {
            let media = try await downloads.downloadPreview(
                urlString: item.url,
                mode: mode,
                quality: quality,
                onBegin: { [weak self] in self?.setPhase(.preparing, generation: gen) },
                onDownloadStart: { [weak self] in self?.setPhase(.downloading(0), generation: gen) },
                onProgress: { [weak self] fraction in
                    self?.setPhase(.downloading(fraction), generation: gen)
                }
            )
            if Task.isCancelled || generation != gen {
                // The modal moved on (or went away) while the extraction was
                // finishing — nobody will play or save this file.
                try? FileManager.default.removeItem(at: media.fileURL)
            } else {
                attachPlayer(to: media)
            }
        } catch {
            // A bumped generation is the *only* thing that supersedes a
            // preview, and it's bumped before anything that would cancel one.
            // So still being on the same generation means nobody moved on, and
            // whatever went wrong has to be shown — including a cancellation.
            // Swallowing those left the modal on a spinner that nothing would
            // ever replace, which from the outside is a next button that did
            // nothing at all.
            if generation == gen {
                appLog("Preview failed: \(error.localizedDescription)",
                       level: .error, category: "Browse")
                phase = .failed(isCancellation(error)
                                ? "The download was cancelled before it finished."
                                : error.localizedDescription)
                playback?.remoteAudioDidChange(self)
            }
        }
        if generation == gen {
            downloadTask = nil
        }
    }

    private func setPhase(_ newPhase: Phase, generation gen: Int) {
        guard generation == gen else { return }
        phase = newPhase
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
        didFinishCurrent = false
        phase = .waiting
    }

    private func attachPlayer(to media: ExtractedMedia) {
        self.media = media
        isVideo = media.isVideo
        duration = media.duration
        if duration <= 0 {
            // Extractor metadata can lack a duration; read it off the file.
            Task { [weak self] in
                let real = await mediaDuration(of: media.fileURL)
                guard let self else { return }
                self.duration = real
                self.playback?.remoteAudioDidChange(self)
            }
        }

        let player = AVPlayer(url: media.fileURL)
        // A preview is as much a background listen as a library track is —
        // without this a video preview goes silent the moment the phone locks.
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
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
                self?.finishTrack(reason: "played to the end")
            }
        }

        // Don't talk over the main player.
        if let playback {
            if playback.isPlaying { playback.togglePlayPause() }
            // Now that there's sound to attach it to, take the lock screen:
            // from here the preview is what Control Center, the headphones and
            // the watch are talking to, and its title/artist/cover are what
            // shows. Handed back in `teardown`.
            playback.beginRemoteAudio(self)
        }

        phase = .ready
        AudioSession.activate()
        player.play()
        isPlaying = true
        startWatchdog()
        playback?.remoteAudioDidChange(self)
    }

    /// A track played through to its end: roll into the next one, so a list can
    /// be auditioned without touching the phone. At the end of the queue there's
    /// nothing to advance to and the player just rewinds, as before.
    private func advanceAtEnd() {
        if canGoNext {
            next()
        } else {
            currentTime = 0
            player?.seek(to: .zero)
            playback?.remoteAudioDidChange(self)
        }
    }

    // MARK: - Noticing the end without being told

    /// Ticks (at 2 Hz) a frozen playhead is given before the track is called
    /// over wherever it sits, and the shorter count that applies once the item
    /// has drained its buffer with nothing left to fill it. Both mirror the
    /// library player's.
    private static let stalledTickLimit = 12
    private static let drainedTickLimit = 6

    private func startWatchdog() {
        watchdog?.invalidate()
        lastWatchdogPosition = -1
        stalledTicks = 0
        playheadHasMoved = false
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForSilentEnd() }
        }
        // `.common`, so scrolling the list behind the sheet can't stop the
        // clock the auto-advance depends on.
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    /// A playhead that has stopped while the preview still believes it's
    /// playing means the track is over, whatever the player reports: an item
    /// that runs out of samples short of its stated duration doesn't pause, it
    /// sits in `.waitingToPlayAtSpecifiedRate` for good.
    private func checkForSilentEnd() {
        guard isPlaying, let player, let item = player.currentItem,
              item.status == .readyToPlay else {
            stalledTicks = 0
            lastWatchdogPosition = -1
            return
        }
        let position = player.currentTime().seconds
        let advanced = position.isFinite && lastWatchdogPosition >= 0
            && abs(position - lastWatchdogPosition) > 0.05
        let moved = advanced || !position.isFinite || lastWatchdogPosition < 0
        lastWatchdogPosition = position.isFinite ? position : -1
        if advanced { playheadHasMoved = true }
        guard !moved else {
            stalledTicks = 0
            return
        }
        stalledTicks += 1

        let atEnd = position.isFinite && position > 0
            && duration > 0 && position >= duration - 1.5
        // A track that hasn't started yet hasn't run out of anything, so the
        // drained-buffer reading only counts once the playhead has moved.
        let ranOut = playheadHasMoved
            && item.isPlaybackBufferEmpty && !item.isPlaybackLikelyToKeepUp

        if atEnd, stalledTicks >= 2 {
            finishTrack(reason: "the playhead stopped at the end")
        } else if ranOut, stalledTicks >= Self.drainedTickLimit {
            finishTrack(reason: "the file ran out of audio before its stated end")
        } else if stalledTicks >= Self.stalledTickLimit {
            finishTrack(reason: "playback stalled with nothing more to play")
        }
    }

    /// One claim per track. The notification and the watchdog are two views of
    /// the same event and can arrive together; acting on the second would skip
    /// the track the first just started. Cleared by `reset()`.
    private func finishTrack(reason: String) {
        guard !didFinishCurrent else { return }
        didFinishCurrent = true
        stalledTicks = 0
        watchdog?.invalidate()
        watchdog = nil
        isPlaying = false
        appLog("Preview: track over — \(reason).", level: .debug, category: "Browse")
        advanceAtEnd()
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            AudioSession.activate()
            player.play()
        }
        isPlaying.toggle()
        if isPlaying {
            // Also covers replaying the last track of a queue, which was left
            // rewound with its watchdog retired and its end already claimed.
            didFinishCurrent = false
            startWatchdog()
        } else {
            // The last reading is from before the pause, so comparing against
            // it would read as a frozen playhead.
            lastWatchdogPosition = -1
            stalledTicks = 0
        }
        playback?.remoteAudioDidChange(self)
    }

    func scrub(to time: Double) {
        currentTime = time
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
        // Moving the playhead puts the track back in play, whatever the
        // watchdog thought of it a moment ago — otherwise a track rewound at
        // its end could never report finishing again.
        didFinishCurrent = false
        lastWatchdogPosition = -1
        stalledTicks = 0
        playback?.remoteAudioDidChange(self)
    }

    // MARK: - The lock screen

    /// What the lock screen, Control Center and the watch show while this modal
    /// owns them. Deliberately answered even mid-download, so the *next* track's
    /// name is up before its audio is — the alternative is the library player's
    /// paused metadata flickering back in between every pair of previews.
    var remoteAudioInfo: RemoteAudioInfo? {
        guard let item = currentItem else { return nil }
        let named = splitTitle(of: item)
        return RemoteAudioInfo(id: item.id,
                               title: named.title,
                               artist: named.artist,
                               duration: duration,
                               elapsed: currentTime,
                               isPlaying: isPlaying,
                               artwork: artwork)
    }

    func remotePlay() { if !isPlaying { togglePlayPause() } }

    func remotePause() { if isPlaying { togglePlayPause() } }

    func remoteTogglePlayPause() { togglePlayPause() }

    func remoteNext() { next() }

    /// Mirrors the library player: more than three seconds in — or with nothing
    /// behind it — "previous" means "start this one again".
    func remotePrevious() {
        if currentTime > 3 || !canGoPrevious {
            scrub(to: 0)
        } else {
            previous()
        }
    }

    func remoteSeek(to time: Double) {
        scrub(to: max(0, min(time, duration > 0 ? duration : time)))
    }

    /// Song and artist out of a Browse item's single title string.
    ///
    /// The lists that *know* the artist spell it "Artist — Song" — the
    /// discography browser's matched tracks, the AI song lists — which is the
    /// same split the Browse rows draw name-over-artist from. Anything else is a
    /// video title and goes up whole, with the item's own detail line (a channel
    /// name, the release it came from) standing in for the artist when it's
    /// short enough to read as one; a feed's paragraph of description isn't.
    private func splitTitle(of item: BrowseItem) -> (title: String, artist: String) {
        if let range = item.title.range(of: " — ") {
            let artist = item.title[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let song = item.title[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !artist.isEmpty, !song.isEmpty { return (song, artist) }
        }
        let detail = item.detail
            .split(separator: "\n").first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return (item.title, detail.count <= 60 ? detail : "")
    }

    private func loadArtwork(for item: BrowseItem) {
        artworkTask?.cancel()
        artworkTask = nil
        artwork = nil
        guard let urlString = item.artworkURL, let url = URL(string: urlString) else { return }
        artworkTask = Task { [weak self] in
            guard let fetched = try? await URLSession.shared.data(from: url),
                  let image = PlatformImage(data: fetched.0),
                  !Task.isCancelled, let self else { return }
            self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.playback?.remoteAudioDidChange(self)
        }
    }

    // MARK: - Saving and tearing down

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
        // …and its English subtitles, when it's a video the source captions.
        if let sourceURL = URL(string: item.url) {
            SubtitleFetcher.attach(from: sourceURL, to: track.id,
                                   isVideo: track.isVideo, library: library)
        }
        appLog("Preview saved to library: \"\(title)\"", level: .success, category: "Browse")
        return track
    }

    /// Discard tapped: stop playback and delete the file right away (teardown
    /// would too, but the intent is explicit here).
    func markDiscardedAndCleanUp() {
        generation += 1
        downloadTask?.cancel()
        downloadTask = nil
        playback?.endRemoteAudio(self)
        stopPlayer()
        deleteTempFile()
    }

    /// Called when the modal goes away for any reason: cancel an in-flight
    /// download, hand the lock screen back, stop the player, and delete the temp
    /// file unless it was saved.
    func teardown() {
        generation += 1
        downloadTask?.cancel()
        downloadTask = nil
        artworkTask?.cancel()
        artworkTask = nil
        artwork = nil
        // Before `stopPlayer`, so the library player's own metadata is what
        // goes back up rather than a preview frozen at whatever it was showing.
        playback?.endRemoteAudio(self)
        stopPlayer()
        if !savedToLibrary {
            deleteTempFile()
        }
    }

    private func stopPlayer() {
        player?.pause()
        isPlaying = false
        watchdog?.invalidate()
        watchdog = nil
        stalledTicks = 0
        lastWatchdogPosition = -1
        playheadHasMoved = false
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        // Removed here, which is also what keeps a dismissed modal from
        // advancing a queue nobody is listening to.
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
