import SwiftUI
import AVFoundation
import UIKit

/// The Browse preview modal: downloads the item's audio (through the same
/// serial pipeline as the download queue), plays it in its own mini player,
/// and offers **Save** (file it into the library — mid-play, the song hands
/// off to the main player at the same position and keeps going) or
/// **Discard** (delete it and hide the item). Dismissing without deciding
/// deletes the temp file and leaves the item untouched.
struct BrowsePreviewView: View {
    let item: BrowseItem

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

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(spacing: 6) {
                    SelectableText(text: item.title,
                                   font: .preferredFont(forTextStyle: .headline),
                                   color: .label,
                                   maxLines: 3,
                                   onBrowseArtist: browseArtist)
                    if !item.detail.isEmpty {
                        SelectableText(text: item.detail,
                                       font: .preferredFont(forTextStyle: .caption1),
                                       color: .secondaryLabel,
                                       maxLines: 3,
                                       onBrowseArtist: browseArtist)
                    }
                }
                .padding(.horizontal)

                phaseContent
                    .frame(maxHeight: .infinity)

                decisionButtons
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
            .padding(.top, 24)
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            await model.start(item: item, downloads: downloads, mainPlayback: playback)
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
                Text("Resolving audio…")
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
                    Task { await model.start(item: item, downloads: downloads, mainPlayback: playback) }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var miniPlayer: some View {
        VStack(spacing: 16) {
            Slider(
                value: Binding(
                    get: { model.currentTime },
                    set: { model.scrub(to: $0) }
                ),
                in: 0...max(model.duration, 1),
                onEditingChanged: { editing in model.isScrubbing = editing }
            )
            .padding(.horizontal, 32)

            HStack {
                Text(model.currentTime.asPlaybackTime)
                Spacer()
                Text(model.duration.asPlaybackTime)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 32)

            Button {
                model.togglePlayPause()
            } label: {
                Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
            }
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
        }
    }

    private var decisionButtons: some View {
        HStack(spacing: 12) {
            Button(role: .destructive) {
                model.markDiscardedAndCleanUp()
                browse.markDiscarded(item)
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
        let handoffTime = model.currentTime
        let wasPlaying = model.isPlaying
        guard let track = model.saveToLibrary(as: item, library: library) else { return }
        browse.markSaved(item)
        if wasPlaying {
            playback.play(track, in: library.activeTracks, startAt: handoffTime)
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
    /// Set by the slider while dragging so observer ticks don't fight the thumb.
    var isScrubbing = false

    private var media: ExtractedMedia?
    private var player: AVPlayer?
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
    func start(item: BrowseItem, downloads: DownloadManager, mainPlayback: PlaybackManager) async {
        guard downloadTask == nil, media == nil else { return }
        phase = .waiting
        generation += 1
        let gen = generation
        let task = Task { [weak self] in
            do {
                let media = try await downloads.downloadPreview(
                    urlString: item.url,
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

    private func attachPlayer(to media: ExtractedMedia, mainPlayback: PlaybackManager) {
        self.media = media
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
                self.currentTime = 0
                self.player?.seek(to: .zero)
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
        let ext = media.fileURL.pathExtension.isEmpty ? "m4a" : media.fileURL.pathExtension
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
            isVideo: false,
            chapters: media.chapters
        )
        library.add(track)
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
