import SwiftUI
import AVFoundation

// MARK: - Reading the waveform

/// A track's loudness over time, read once off its file: one peak per
/// `binDuration` seconds, normalized so the loudest is 1.
///
/// Read at a fine grain — fifty peaks a second — because the same reading
/// serves both views the editor draws: the whole track across the width of
/// the screen (a few hundred bars, pooled from these), and the magnified few
/// seconds around a handle being dragged, which needs the detail to place a
/// cut between two beats rather than somewhere near them.
struct Waveform {
    let peaks: [Float]
    let binDuration: Double
    /// The file's own length, which is what the cut is measured against.
    let duration: Double

    enum ReadError: LocalizedError {
        case noAudio
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .noAudio: return "This file has no audio track to draw."
            case .unreadable(let message): return message
            }
        }
    }

    /// Fifty a second, unless the track is so long that would be more than
    /// `maxBins` — a three-hour mix doesn't need its every 20 ms remembered.
    private static let finestBin = 0.02
    private static let maxBins = 200_000
    /// Decoded at a low rate and mono: a peak per 20 ms is all that's kept, and
    /// halving the samples halves the time it takes to get there.
    private static let sampleRate = 8_000.0

    static func read(from url: URL) async throws -> Waveform {
        try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            guard let audio = try await asset.loadTracks(withMediaType: .audio).first else {
                throw ReadError.noAudio
            }
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else {
                throw ReadError.unreadable("The file doesn't report a length.")
            }
            let binDuration = max(finestBin, duration / Double(maxBins))
            let samplesPerBin = max(1, Int(sampleRate * binDuration))

            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: audio, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: sampleRate,
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw ReadError.unreadable("The audio couldn't be decoded for drawing.")
            }
            reader.add(output)
            guard reader.startReading() else {
                throw ReadError.unreadable(reader.error?.localizedDescription ?? "The audio couldn't be read.")
            }

            var peaks: [Float] = []
            peaks.reserveCapacity(Int(duration / binDuration) + 1)
            var binPeak: Int16 = 0
            var inBin = 0
            while let buffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                // Copied out rather than read in place: a block buffer needn't
                // be contiguous, and a pointer into it covers only the first
                // run of bytes.
                let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Int16>.size
                guard count > 0 else { continue }
                var samples = [Int16](repeating: 0, count: count)
                let status = samples.withUnsafeMutableBytes { bytes in
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count,
                                               destination: bytes.baseAddress!)
                }
                guard status == kCMBlockBufferNoErr else { continue }
                for sample in samples {
                    // `magnitude` rather than `abs`: Int16.min has no positive
                    // counterpart.
                    let level = Int16(clamping: sample.magnitude)
                    if level > binPeak { binPeak = level }
                    inBin += 1
                    if inBin == samplesPerBin {
                        peaks.append(Float(binPeak))
                        binPeak = 0
                        inBin = 0
                    }
                }
            }
            if inBin > 0 { peaks.append(Float(binPeak)) }
            if reader.status == .failed {
                throw ReadError.unreadable(reader.error?.localizedDescription ?? "The audio couldn't be read.")
            }
            let loudest = peaks.max() ?? 0
            if loudest > 0 {
                for i in peaks.indices { peaks[i] /= loudest }
            }
            return Waveform(peaks: peaks, binDuration: binDuration, duration: duration)
        }.value
    }
}

/// Bars for a stretch of a waveform — `from`…`to` seconds — pooled to as many
/// as fit the width, mirrored about the middle.
private struct WaveformShape: Shape {
    let waveform: Waveform
    var from: Double
    var to: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let pitch: CGFloat = 3
        let barWidth: CGFloat = 2
        let bars = max(1, Int(rect.width / pitch))
        let span = max(to - from, waveform.binDuration)
        let peaks = waveform.peaks
        guard !peaks.isEmpty else { return path }
        for bar in 0..<bars {
            let t0 = from + span * Double(bar) / Double(bars)
            let t1 = from + span * Double(bar + 1) / Double(bars)
            let lo = max(0, Int(t0 / waveform.binDuration))
            let hi = min(peaks.count, max(lo + 1, Int((t1 / waveform.binDuration).rounded(.up))))
            guard lo < peaks.count, lo < hi else { continue }
            var level: Float = 0
            for i in lo..<hi where peaks[i] > level { level = peaks[i] }
            // A floor, so silence still reads as a line rather than a gap.
            let height = max(1.5, CGFloat(level) * rect.height)
            let x = rect.minX + CGFloat(bar) * pitch
            path.addRoundedRect(in: CGRect(x: x, y: rect.midY - height / 2, width: barWidth, height: height),
                                cornerSize: CGSize(width: 1, height: 1))
        }
        return path
    }
}

// MARK: - The editor

/// **Trim**, from the Player's sleeve: the track's progress bar and transport
/// give way to its waveform, with a handle at either end to drag inwards.
/// While a handle is held, a **magnified** stretch of the waveform around it
/// floats above it — the overview squeezes a whole song into the width of the
/// phone, which is fine for finding the end of a long fade and no good at all
/// for placing the cut on the beat.
///
/// Letting go of a handle plays from it (the out-point from a few seconds
/// before), so where a cut falls is heard rather than guessed. **Save**
/// rewrites the file to the kept stretch — it's a cut, not a bookmark, so the
/// watch, the widget and a local sync all get the shorter track — and the
/// track keeps its place in the library and goes on playing where it was.
struct TrimEditorView: View {
    let track: Track
    let onClose: () -> Void

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager

    @State private var waveform: Waveform?
    @State private var loadError: String?
    @State private var start: Double = 0
    @State private var end: Double = 0
    @State private var dragging: Handle?
    @State private var confirming = false
    @State private var saving = false
    @State private var saveError: String?

    private enum Handle {
        case start, end
    }

    /// The shortest stretch worth keeping, so the handles can't cross.
    private let minimumLength = 1.0
    /// How much of the track the magnifier shows, centred on the handle.
    private let loupeSpan = 6.0
    private let waveHeight: CGFloat = 72
    private let handleWidth: CGFloat = 14

    private var duration: Double { waveform?.duration ?? max(playback.duration, track.duration) }

    private var isUntouched: Bool {
        start < 0.05 && end > duration - 0.05
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Label("Trim", systemImage: "scissors")
                    .font(.headline)
                Spacer()
                Text("Keeping \((end - start).asPlaybackTime) of \(duration.asPlaybackTime)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            editorArea
                .frame(height: waveHeight)
                // The magnifier rides above the waveform, over the title.
                .zIndex(1)

            HStack {
                Text(start.asPlaybackTime)
                Spacer()
                Text(end.asPlaybackTime)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()

            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Button("Cancel", action: onClose)
                    .buttonStyle(.bordered)
                Button {
                    playback.seek(to: start)
                    if !playback.isPlaying { playback.togglePlayPause() }
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
                .disabled(waveform == nil)
                Spacer()
                Button {
                    confirming = true
                } label: {
                    if saving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save").fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(waveform == nil || isUntouched || saving)
            }
        }
        .padding(.horizontal)
        .task(id: track.id) { await load() }
        .confirmationDialog("Trim to \((end - start).asPlaybackTime)?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("Trim Track", role: .destructive) { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The audio outside the handles is cut from the file for good.")
        }
    }

    @ViewBuilder
    private var editorArea: some View {
        if let waveform {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .topLeading) {
                    // The whole track, dim; the kept stretch over it in the
                    // accent colour, masked to the handles.
                    WaveformShape(waveform: waveform, from: 0, to: waveform.duration)
                        .fill(Color.secondary.opacity(0.35))
                    WaveformShape(waveform: waveform, from: 0, to: waveform.duration)
                        .fill(Color.accentColor)
                        .mask(alignment: .topLeading) {
                            Rectangle()
                                .frame(width: max(0, x(end, width) - x(start, width)))
                                .offset(x: x(start, width))
                        }

                    TrimPlayhead(progress: playback.progress, duration: waveform.duration, width: width)

                    handle(.start, width: width)
                    handle(.end, width: width)
                }
                // What the handles' drags are measured in — their own frames
                // move with them, so a local reading would chase itself.
                .coordinateSpace(name: Self.space)
                .contentShape(Rectangle())
                // A tap on the waveform moves the playhead there.
                .onTapGesture(coordinateSpace: .local) { point in
                    playback.seek(to: time(atX: point.x, width: width))
                }
                .overlay(alignment: .topLeading) {
                    if let dragging {
                        loupe(for: dragging, waveform: waveform, width: width)
                    }
                }
            }
        } else if let loadError {
            Text(loadError)
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading the waveform…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A handle: a bar at the cut with a grip, wide enough for a thumb to find
    /// without having to land on a two-point line.
    private func handle(_ which: Handle, width: CGFloat) -> some View {
        let at = x(which == .start ? start : end, width)
        let active = dragging == which
        return RoundedRectangle(cornerRadius: 3)
            .fill(Color.accentColor)
            .frame(width: 4, height: waveHeight + 12)
            .overlay {
                Capsule()
                    .fill(Color.white)
                    .frame(width: 2, height: 16)
            }
            .scaleEffect(active ? 1.15 : 1)
            .frame(width: 44, height: waveHeight + 12)
            .contentShape(Rectangle())
            .offset(x: at - 22, y: -6)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(TrimEditorView.space))
                    .onChanged { value in
                        dragging = which
                        let t = time(atX: value.location.x, width: width)
                        switch which {
                        case .start: start = min(max(0, t), end - minimumLength)
                        case .end: end = max(min(duration, t), start + minimumLength)
                        }
                    }
                    .onEnded { _ in
                        dragging = nil
                        // Hear where it falls: from the in-point, or into the
                        // out-point from a few seconds before it.
                        playback.seek(to: which == .start ? start : max(start, end - 3))
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(which == .start ? "Trim start" : "Trim end")
            .accessibilityValue((which == .start ? start : end).asPlaybackTime)
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 0.5 : -0.5
                switch which {
                case .start: start = min(max(0, start + step), end - minimumLength)
                case .end: end = max(min(duration, end + step), start + minimumLength)
                }
            }
    }

    /// The magnified stretch around the handle being dragged, floating above
    /// it: `loupeSpan` seconds, the cut marked down the middle, the side being
    /// cut away dimmed.
    private func loupe(for which: Handle, waveform: Waveform, width: CGFloat) -> some View {
        let at = which == .start ? start : end
        let from = at - loupeSpan / 2
        let to = at + loupeSpan / 2
        let loupeWidth = min(220, width * 0.7)
        let loupeHeight: CGFloat = 64
        // Kept on screen at the ends, so it may sit off-centre from the handle.
        let centre = min(max(x(at, width), loupeWidth / 2), width - loupeWidth / 2)
        return ZStack {
            WaveformShape(waveform: waveform, from: from, to: to)
                .fill(Color.accentColor)
            // The side being cut away.
            Rectangle()
                .fill(Color.appBackground.opacity(0.6))
                .frame(width: loupeWidth / 2)
                .frame(maxWidth: .infinity, alignment: which == .start ? .leading : .trailing)
            Rectangle()
                .fill(Color.primary)
                .frame(width: 1.5)
        }
        .padding(.vertical, 6)
        .frame(width: loupeWidth, height: loupeHeight)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.appSeparator, lineWidth: 1))
        .overlay(alignment: .bottom) {
            Text(at.asPlaybackTime)
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .padding(.horizontal, 5)
                .background(.regularMaterial, in: Capsule())
                .offset(y: 8)
        }
        .shadow(radius: 6, y: 2)
        .offset(x: centre - loupeWidth / 2, y: -loupeHeight - 22)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private static let space = "TrimEditor"

    private func x(_ time: Double, _ width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(time / duration, 0), 1)) * width
    }

    private func time(atX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(x / width, 0), 1)) * duration
    }

    @MainActor
    private func load() async {
        do {
            let read = try await Waveform.read(from: track.fileURL)
            waveform = read
            start = 0
            end = read.duration
        } catch {
            if isCancellation(error) { return }
            loadError = error.localizedDescription
            appLog("Couldn't read \"\(track.title)\"'s waveform: \(error.localizedDescription)",
                   level: .error, category: "Library")
        }
    }

    /// Writes the kept stretch to a new file, hands it to the track, and only
    /// then lets the old file go — the player is still reading it until the
    /// swap. A failed export changes nothing.
    private func save() {
        let (from, to) = (start, end)
        let resumeAt = max(0, playback.currentTime - from)
        saving = true
        saveError = nil
        Task { @MainActor in
            defer { saving = false }
            do {
                let name = try await ChapterSplitter.exportSlice(from: track.fileURL,
                                                                 start: from, end: to,
                                                                 isVideo: false,
                                                                 baseName: UUID().uuidString)
                let newURL = AppPaths.documents.appendingPathComponent(name)
                let length = (try? await AVURLAsset(url: newURL).load(.duration).seconds)
                    .flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? (to - from)
                guard let oldURL = library.applyTrim(to: track.id, fileName: name,
                                                     duration: length, removedFromStart: from),
                      let updated = library.track(withID: track.id) else {
                    try? FileManager.default.removeItem(at: newURL)
                    saveError = "The track couldn't be updated."
                    return
                }
                playback.reloadCurrent(with: updated, at: min(resumeAt, length))
                if oldURL != newURL { try? FileManager.default.removeItem(at: oldURL) }
                appLog("Trimmed \"\(track.title)\" to \(from.asPlaybackTime)–\(to.asPlaybackTime) (\(length.asPlaybackTime)).",
                       level: .success, category: "Library")
                onClose()
            } catch {
                if isCancellation(error) { return }
                saveError = error.localizedDescription
                appLog("Trim of \"\(track.title)\" failed: \(error.localizedDescription)",
                       level: .error, category: "Library")
            }
        }
    }
}

/// The playhead across the waveform. Its own view on the 2 Hz progress ticker,
/// so the waveform under it isn't redrawn twice a second.
private struct TrimPlayhead: View {
    @ObservedObject var progress: PlaybackProgress
    let duration: Double
    let width: CGFloat

    var body: some View {
        let fraction = duration > 0 ? min(max(progress.currentTime / duration, 0), 1) : 0
        Rectangle()
            .fill(Color.primary.opacity(0.8))
            .frame(width: 1.5)
            .offset(x: CGFloat(fraction) * width)
            .allowsHitTesting(false)
    }
}
