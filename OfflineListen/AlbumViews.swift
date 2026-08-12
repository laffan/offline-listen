import SwiftUI
import PhotosUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// MARK: - Colours

/// The stand-in cover for an album with no art: one flat colour, kept on the
/// folder (`albumColorHex`) so it doesn't change from one redraw to the next.
/// A folder the user turns into an album gets one straight away — an album has
/// to look like something in the folder grid before any image is picked — and
/// **Reset Album Art** rolls a fresh one when there's no downloaded cover to
/// go back to.
enum AlbumColor {
    /// Muted enough to sit under white text, distinct enough to tell two
    /// albums apart at thumbnail size.
    static let palette: [String] = [
        "#B5533F", // clay
        "#C8813A", // amber
        "#8C9A44", // olive
        "#4F8A6B", // jade
        "#3F7C93", // teal
        "#4B5FA6", // indigo
        "#7A5AA6", // violet
        "#A8497A", // magenta
        "#8C6244", // umber
        "#5B6470", // slate
    ]

    /// A colour from the palette, never the one already in use — a reset that
    /// hands back the same colour looks like a reset that did nothing.
    static func randomHex(excluding current: String?) -> String {
        let choices = palette.filter { $0 != current }
        return choices.randomElement() ?? palette[0]
    }

    /// The folder's colour: the one it recorded, or — for an album that
    /// somehow has none — one derived from its id, so it's at least stable.
    static func color(for folder: Folder) -> Color {
        if let hex = folder.albumColorHex, let color = Color(mixtapeHex: hex) { return color }
        return Color(mixtapeHex: palette[Int(folder.id.uuid.0) % palette.count]) ?? .gray
    }
}

// MARK: - Cover rendering

/// An album's square sleeve: its cover if it has one, otherwise its colour.
/// `image` is resolved by the caller (`FolderCover.image(for:tracks:)`), since
/// only the caller knows the folder's tracks — the shared-artwork fallback a
/// hand-assembled album earns its sleeve through.
struct AlbumCoverArt: View {
    let folder: Folder
    var image: PlatformImage?
    var cornerRadius: CGFloat = 8

    var body: some View {
        // The square comes from the (flexible, so unopinionated) backing
        // colour; the cover rides in an overlay, where a `scaledToFill` image
        // spilling past the edges is clipped rather than stretching the cell.
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    AlbumColor.color(for: folder)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// One album in the Folders tab's cover view: the sleeve, the album's name,
/// and the artist beneath it — the same title-over-artist shape the list row
/// prints, which is what makes a grid of covers readable at all.
struct AlbumCoverCell: View {
    @EnvironmentObject private var library: LibraryStore

    let folder: Folder
    var playingHere: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            AlbumCoverArt(folder: folder,
                          image: FolderCover.image(for: folder, tracks: library.tracks(in: folder.id)))
                .overlay(alignment: .topTrailing) { badges }
                .shadow(radius: 3, y: 2)

            Text(folder.name)
                .font(.caption)
                .foregroundStyle(playingHere ? Color.accentColor : .primary)
                .lineLimit(1)
            if let artist = library.folderArtist(of: folder.id) {
                Text(artist)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }

    /// What the list row says in words, at the size a cover leaves for it: the
    /// sync mark, and the speaker for the album currently playing.
    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 3) {
            if folder.isSynced {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            if playingHere {
                Image(systemName: "speaker.wave.2.fill")
            }
        }
        .font(.system(size: 10, weight: .bold))
        .padding(4)
        .background(.regularMaterial, in: Capsule())
        .padding(4)
        .opacity(folder.isSynced || playingHere ? 1 : 0)
    }
}

// MARK: - Cropping

/// Turns a picked photo into an album cover: the square the user framed,
/// re-encoded as a JPEG.
///
/// The framing is stored the way the mixtape editor stores its crops — a zoom
/// on top of aspect-fill, plus a pan as a fraction of the frame — so the crop
/// can be worked back out from those alone. The preview's own size cancels
/// out: an aspect-filled square shows `min(width, height)` of the image, and
/// the zoom divides it, so the visible window is `min(w, h) / zoom` image
/// points wide however large the preview was drawn.
enum AlbumCoverCrop {
    /// Big enough for the Player's artwork on any phone, small enough that a
    /// cover copied onto a dozen tracks costs little.
    static let outputSide: CGFloat = 1000

    static func squareJPEG(from image: PlatformImage, zoom: Double,
                           offsetX: Double, offsetY: Double,
                           quality: CGFloat = 0.85) -> Data? {
        square(from: image, zoom: zoom, offsetX: offsetX, offsetY: offsetY)?
            .jpegData(compressionQuality: quality)
    }

    static func square(from image: PlatformImage, zoom: Double,
                       offsetX: Double, offsetY: Double) -> PlatformImage? {
        let width = image.size.width
        let height = image.size.height
        guard width > 0, height > 0 else { return nil }

        let side = min(width, height) / max(zoom, 1)
        // Panning the image right moves the visible window left, hence the
        // subtraction; the clamp keeps the window inside the image even if a
        // stored offset ever outran its limits.
        let originX = min(max(width / 2 - offsetX * side - side / 2, 0), max(0, width - side))
        let originY = min(max(height / 2 - offsetY * side - side / 2, 0), max(0, height - side))
        let scale = outputSide / side
        let target = CGSize(width: outputSide, height: outputSide)
        let drawn = CGSize(width: width * scale, height: height * scale)

        #if canImport(UIKit)
        // At the device's scale a 1000-point square would come out 3000 pixels
        // wide — a couple of megabytes, copied onto every song in the folder.
        // The cover is measured in pixels, so render it one for one.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: CGPoint(x: -originX * scale, y: -originY * scale),
                                  size: drawn))
        }
        #else
        // AppKit draws from the bottom-left corner, so the crop's y flips.
        let flippedY = height - originY - side
        let output = NSImage(size: target)
        output.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: CGRect(origin: CGPoint(x: -originX * scale, y: -flippedY * scale),
                              size: drawn))
        output.unlockFocus()
        return output
        #endif
    }
}

// MARK: - Cover editor

/// The album art sheet: pick an image and frame the square it's cropped to
/// (drag to pan, pinch or slide to zoom). Saving writes the cover on the
/// folder **and on every song in it**, which is what makes the record wear it
/// in the Player, on the lock screen and in the mini player.
///
/// Unlike a mixtape's banner this crop *is* destructive — a square JPEG is
/// what gets copied onto the tracks — so the framing can't be revisited later;
/// picking the image again is how it's changed.
struct AlbumCoverEditor: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    let folder: Folder

    @State private var pickerItem: PhotosPickerItem?
    @State private var picked: PlatformImage?
    @State private var zoom: Double = 1
    @State private var offsetX: Double = 0
    @State private var offsetY: Double = 0

    // Gesture baselines, so a drag/pinch composes with what's already set.
    @State private var panBase: CGSize?
    @State private var zoomBase: Double?

    /// The cover as it stands, for the "before" the sheet opens on.
    private var currentImage: PlatformImage? {
        FolderCover.image(for: folder, tracks: library.tracks(in: folder.id))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    preview
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)
                    if picked != nil {
                        zoomSlider
                    }
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label(picked == nil ? "Choose Image" : "Choose Different Image",
                              systemImage: "photo")
                    }
                } header: {
                    Text("Album Art")
                } footer: {
                    Text(picked == nil
                         ? "Pick an image for this album. It's cropped to a square and applied to every song in the folder."
                         : "Drag to position the image (pinch or slide to zoom). The square you frame here is the cover — it goes on the folder and on every song in it.")
                }
            }
            .navigationTitle("Album Art")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(picked == nil)
                }
            }
            .onChange(of: pickerItem) { item in
                guard let item else { return }
                Task { await loadPicked(item) }
            }
        }
    }

    // MARK: Preview

    private var preview: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let frame = CGSize(width: side, height: side)
            HStack {
                Spacer(minLength: 0)
                square(side: side)
                    .contentShape(Rectangle())
                    .gesture(panGesture(frame: frame))
                    .simultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                guard picked != nil else { return }
                                let base = zoomBase ?? zoom
                                zoomBase = base
                                zoom = min(max(base * value, 1), 4)
                            }
                            .onEnded { _ in zoomBase = nil }
                    )
                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: 260)
    }

    /// The framed square itself: the picked image under the crop being set,
    /// or — before anything is picked — the cover the album already wears.
    @ViewBuilder
    private func square(side: CGFloat) -> some View {
        let frame = CGSize(width: side, height: side)
        ZStack {
            if let picked {
                let limits = MixtapeBackground.offsetLimits(image: picked, zoom: zoom, frame: frame)
                Image(platformImage: picked)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .scaleEffect(max(zoom, 1))
                    .offset(x: min(max(offsetX, -limits.width), limits.width) * side,
                            y: min(max(offsetY, -limits.height), limits.height) * side)
            } else if let currentImage {
                Image(platformImage: currentImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
            } else {
                AlbumColor.color(for: folder)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(radius: 5, y: 3)
    }

    private var zoomSlider: some View {
        HStack(spacing: 10) {
            Image(systemName: "minus.magnifyingglass")
                .foregroundStyle(.secondary)
            Slider(value: $zoom, in: 1...4)
            Image(systemName: "plus.magnifyingglass")
                .foregroundStyle(.secondary)
        }
    }

    /// Drag-to-pan, clamped to the image's actual overflow in the square, so a
    /// pan can reach the image's edges but never past them.
    private func panGesture(frame: CGSize) -> some Gesture {
        DragGesture(coordinateSpace: .local)
            .onChanged { value in
                guard let picked else { return }
                let base = panBase ?? CGSize(width: offsetX, height: offsetY)
                panBase = base
                let limits = MixtapeBackground.offsetLimits(image: picked, zoom: zoom, frame: frame)
                offsetX = clamp(base.width + value.translation.width / max(frame.width, 1),
                                to: limits.width)
                offsetY = clamp(base.height + value.translation.height / max(frame.height, 1),
                                to: limits.height)
            }
            .onEnded { _ in panBase = nil }
    }

    private func clamp(_ value: Double, to limit: Double) -> Double {
        min(max(value, -limit), limit)
    }

    // MARK: Loading & saving

    private func loadPicked(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = PlatformImage(data: data) else { return }
        picked = image.downscaled(toLongestSide: 1600)
        // A fresh image starts from a clean crop.
        zoom = 1
        offsetX = 0
        offsetY = 0
    }

    private func save() {
        guard let picked,
              let data = AlbumCoverCrop.squareJPEG(from: picked, zoom: zoom,
                                                   offsetX: offsetX, offsetY: offsetY) else {
            appLog("Couldn't crop the album cover.", level: .error, category: "Library")
            dismiss()
            return
        }
        library.setAlbumArtwork(folder, imageData: data)
        dismiss()
    }
}
