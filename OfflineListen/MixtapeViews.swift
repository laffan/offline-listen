import SwiftUI
import UIKit
import PhotosUI

// MARK: - Fonts

/// The curated title fonts the cover editor offers. All are iOS system-bundled
/// faces, so nothing needs embedding; `Font.custom` falls back to the system
/// font if a name ever goes missing.
struct MixtapeFontChoice: Identifiable, Hashable {
    let displayName: String
    /// PostScript name, nil for the system font.
    let fontName: String?

    var id: String { fontName ?? "system" }

    static let all: [MixtapeFontChoice] = [
        MixtapeFontChoice(displayName: "System", fontName: nil),
        MixtapeFontChoice(displayName: "Serif", fontName: "Georgia-Bold"),
        MixtapeFontChoice(displayName: "Typewriter", fontName: "AmericanTypewriter-Bold"),
        MixtapeFontChoice(displayName: "Marker", fontName: "MarkerFelt-Wide"),
        MixtapeFontChoice(displayName: "Futura", fontName: "Futura-Medium"),
        MixtapeFontChoice(displayName: "Script", fontName: "SnellRoundhand-Bold"),
        MixtapeFontChoice(displayName: "Chalk", fontName: "Chalkduster"),
        MixtapeFontChoice(displayName: "Mono", fontName: "Menlo-Bold"),
    ]
}

extension MixtapeStyle {
    /// The title font this style selects, at `size` points.
    func titleFont(size: CGFloat) -> Font {
        if let fontName {
            return .custom(fontName, size: size)
        }
        return .system(size: size, weight: .bold)
    }
}

// MARK: - Cover loading

/// Loads mixtape cover images from disk with a small cache. The cache key
/// includes the file's modification date, so a replaced cover is picked up on
/// the next render without manual invalidation.
enum MixtapeCoverLoader {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(for folder: Folder) -> UIImage? {
        guard let url = folder.coverURL else { return nil }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        let key = "\(url.path)#\(modified?.timeIntervalSince1970 ?? 0)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

// MARK: - Banner background

/// The cover image cropped per the mixtape's style — non-destructively: the
/// image aspect-fills the banner, then the style's zoom and pan choose which
/// part shows. Without an image, a quiet gradient stands in.
struct MixtapeBackground: View {
    let image: UIImage?
    let style: MixtapeStyle

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(max(style.zoom, 1))
                        .offset(x: style.offsetX * geo.size.width,
                                y: style.offsetY * geo.size.height)
                } else {
                    LinearGradient(colors: [Color.accentColor.opacity(0.55), Color.indigo.opacity(0.7)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                // A scrim so the title stays legible on any image.
                LinearGradient(colors: [.black.opacity(0.45), .black.opacity(0.15)],
                               startPoint: .bottom, endPoint: .top)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }
}

// MARK: - Folder rows

/// The label for a folder row in any list: the plain icon/name/count row for a
/// normal folder, or the cover-banner treatment for a mixtape. Synced folders
/// wear the sync icon.
struct FolderRowLabel: View {
    @EnvironmentObject private var library: LibraryStore

    let folder: Folder
    let count: Int
    var playingHere: Bool = false

    var body: some View {
        if folder.isMixtape {
            mixtapeRow
        } else {
            plainRow
        }
    }

    private var plainRow: some View {
        HStack(spacing: 12) {
            Image(systemName: folder.isSynced ? "arrow.triangle.2.circlepath" : "folder.fill")
                .foregroundStyle(playingHere ? Color.accentColor : .secondary)
                .frame(width: 24)
            Text(folder.name)
                .font(.body)
                .lineLimit(1)
            Spacer()
            Text("\(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
    }

    private var mixtapeRow: some View {
        ZStack {
            MixtapeBackground(image: MixtapeCoverLoader.image(for: folder), style: folder.mixtape)
            HStack(spacing: 8) {
                if folder.isSynced {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                if playingHere {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                }
                Text(folder.name)
                    .font(folder.mixtape.titleFont(size: 17))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                Spacer()
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.vertical, 4)
    }
}

/// The tall banner at the top of a mixtape's own screen: the cover crop with
/// the title in the chosen font.
struct MixtapeHeaderBanner: View {
    @EnvironmentObject private var library: LibraryStore

    let folder: Folder

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            MixtapeBackground(image: MixtapeCoverLoader.image(for: folder), style: folder.mixtape)
            Text(folder.name)
                .font(folder.mixtape.titleFont(size: 28))
                .foregroundStyle(.white)
                .lineLimit(2)
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                .padding(14)
        }
        .frame(height: 150)
        .clipped()
    }
}

// MARK: - Cover editor

/// The "Edit Cover" sheet: pick an image, drag/pinch the banner preview to
/// choose (non-destructively) what shows behind the title, and pick the title
/// font. Nothing is written until Save.
struct MixtapeCoverEditor: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    let folder: Folder

    @State private var style: MixtapeStyle
    /// A newly picked image (preview + the JPEG that will be saved); nil while
    /// the existing cover (if any) is kept.
    @State private var pickedImage: UIImage?
    @State private var pickedImageData: Data?
    @State private var pickerItem: PhotosPickerItem?

    // Gesture baselines so drag/pinch compose with the committed style.
    @State private var panBase: CGSize?
    @State private var zoomBase: Double?

    init(folder: Folder) {
        self.folder = folder
        _style = State(initialValue: folder.mixtape)
    }

    private var previewImage: UIImage? {
        pickedImage ?? MixtapeCoverLoader.image(for: folder)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    preview
                        .listRowInsets(EdgeInsets())
                } header: {
                    Text("Cover")
                } footer: {
                    Text(previewImage == nil
                         ? "Pick an image to show behind the mixtape's title."
                         : "Drag to position the image; pinch to zoom. The original image is kept — the crop can be changed any time.")
                }

                Section {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label(previewImage == nil ? "Choose Image" : "Choose Different Image",
                              systemImage: "photo")
                    }
                    if previewImage != nil {
                        Button("Reset Crop") {
                            style.zoom = 1
                            style.offsetX = 0
                            style.offsetY = 0
                        }
                        .disabled(style.zoom == 1 && style.offsetX == 0 && style.offsetY == 0)
                    }
                }

                Section("Title Font") {
                    fontPicker
                }
            }
            .navigationTitle("Edit Cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        library.setMixtapeStyle(folder, style, coverImageData: pickedImageData)
                        dismiss()
                    }
                }
            }
            .onChange(of: pickerItem) { item in
                guard let item else { return }
                Task { await loadPicked(item) }
            }
        }
    }

    /// The live banner preview, driven by the same rendering the rows use, so
    /// what you position here is exactly what shows.
    private var preview: some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { geo in
                MixtapeBackground(image: previewImage, style: style)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let base = panBase ?? CGSize(width: style.offsetX, height: style.offsetY)
                                panBase = base
                                style.offsetX = clamp(base.width + value.translation.width / geo.size.width)
                                style.offsetY = clamp(base.height + value.translation.height / geo.size.height)
                            }
                            .onEnded { _ in panBase = nil }
                    )
                    .simultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                let base = zoomBase ?? style.zoom
                                zoomBase = base
                                style.zoom = min(max(base * value, 1), 4)
                            }
                            .onEnded { _ in zoomBase = nil }
                    )
            }
            Text(folder.name)
                .font(style.titleFont(size: 28))
                .foregroundStyle(.white)
                .lineLimit(2)
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                .padding(14)
                .allowsHitTesting(false)
        }
        .frame(height: 170)
        .clipped()
    }

    private var fontPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(MixtapeFontChoice.all) { choice in
                    let selected = choice.fontName == style.fontName
                    Button {
                        style.fontName = choice.fontName
                    } label: {
                        VStack(spacing: 4) {
                            Text("Abc")
                                .font(MixtapeStyle(fontName: choice.fontName).titleFont(size: 22))
                            Text(choice.displayName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(minWidth: 64)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, -1), 1)
    }

    /// Loads the picked photo, downscales it to a sane size, and re-encodes it
    /// as the JPEG that will be written on Save.
    private func loadPicked(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              var image = UIImage(data: data) else { return }
        let maxDimension: CGFloat = 1600
        let largest = max(image.size.width, image.size.height)
        if largest > maxDimension {
            let scale = maxDimension / largest
            let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image = UIGraphicsImageRenderer(size: newSize).image { _ in
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }
        }
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else { return }
        pickedImage = image
        pickedImageData = jpeg
        // A fresh image starts from a clean crop.
        style.zoom = 1
        style.offsetX = 0
        style.offsetY = 0
    }
}
