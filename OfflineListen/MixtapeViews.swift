import SwiftUI
import UIKit
import PhotosUI

// MARK: - Colors

extension Color {
    /// Parses "#RRGGBB" (leading # optional). Nil for anything else.
    init?(mixtapeHex hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return nil }
        self.init(red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }

    /// "#RRGGBB" for this color (alpha dropped), nil if it can't be resolved.
    var mixtapeHex: String? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        func byte(_ c: CGFloat) -> Int { Int((max(0, min(1, c)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}

extension MixtapeStyle {
    /// The title font this style selects, at `size` points.
    func titleFont(size: CGFloat) -> Font {
        if let fontName {
            return .custom(fontName, size: size)
        }
        return .system(size: size, weight: .bold)
    }

    /// The title colour: the user's pick, or white — except on a tape chip,
    /// where the unpicked default flips to black so it stays readable.
    var titleColor: Color {
        if let hex = textColorHex, let color = Color(mixtapeHex: hex) { return color }
        return tape ? .black : .white
    }

    var tapeColor: Color {
        Color(mixtapeHex: tapeColorHex ?? Self.defaultTapeHex) ?? .white
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

// MARK: - Banner building blocks

/// The cover image cropped non-destructively: it aspect-fills the frame, then
/// `zoom`/`offsetX`/`offsetY` (from one of the style's two crops) choose which
/// part shows. Without an image, a quiet gradient stands in.
struct MixtapeBackground: View {
    let image: UIImage?
    let zoom: Double
    let offsetX: Double
    let offsetY: Double

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(max(zoom, 1))
                        .offset(x: offsetX * geo.size.width,
                                y: offsetY * geo.size.height)
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

/// A mixtape title in its chosen font and colour, sitting on the tape chip
/// when the style asks for one.
struct MixtapeTitle: View {
    let text: String
    let style: MixtapeStyle
    let size: CGFloat
    var lineLimit: Int = 1

    var body: some View {
        Text(text)
            .font(style.titleFont(size: size))
            .foregroundStyle(style.titleColor)
            .lineLimit(lineLimit)
            .shadow(color: style.tape ? .clear : .black.opacity(0.5),
                    radius: size > 20 ? 3 : 2, y: 1)
            .padding(.horizontal, style.tape ? size * 0.4 : 0)
            .padding(.vertical, style.tape ? size * 0.14 : 0)
            .background {
                if style.tape {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(style.tapeColor.opacity(0.94))
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                }
            }
    }
}

/// The mixtape treatment for a folder-list row, at the row's own crop and
/// justification. Rendering is shared with the editor's list-row preview so
/// what you position there is exactly what the list shows.
struct MixtapeRowContent: View {
    let title: String
    let style: MixtapeStyle
    let image: UIImage?
    var count: Int?
    var showsSync: Bool = false
    var playingHere: Bool = false

    var body: some View {
        ZStack {
            MixtapeBackground(image: image, zoom: style.rowZoom,
                              offsetX: style.rowOffsetX, offsetY: style.rowOffsetY)
            if style.centered {
                MixtapeTitle(text: title, style: style, size: 17)
                    .padding(.horizontal, 34)
            }
            HStack(spacing: 8) {
                if showsSync {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                if playingHere {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                }
                if !style.centered {
                    MixtapeTitle(text: title, style: style, size: 17)
                }
                Spacer()
                if let count {
                    Text("\(count)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// The tall banner treatment for a mixtape's own screen, at the header crop.
struct MixtapeHeaderContent: View {
    let title: String
    let style: MixtapeStyle
    let image: UIImage?
    var height: CGFloat = 150

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            MixtapeBackground(image: image, zoom: style.zoom,
                              offsetX: style.offsetX, offsetY: style.offsetY)
            MixtapeTitle(text: title, style: style, size: 28, lineLimit: 2)
                .padding(14)
        }
        .frame(height: height)
        .clipped()
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
            MixtapeRowContent(title: folder.name,
                              style: folder.mixtape,
                              image: MixtapeCoverLoader.image(for: folder),
                              count: count,
                              showsSync: folder.isSynced,
                              playingHere: playingHere)
                .padding(.vertical, 4)
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
}

/// The banner at the top of a mixtape's own screen.
struct MixtapeHeaderBanner: View {
    @EnvironmentObject private var library: LibraryStore

    let folder: Folder

    var body: some View {
        MixtapeHeaderContent(title: folder.name,
                             style: folder.mixtape,
                             image: MixtapeCoverLoader.image(for: folder))
    }
}

// MARK: - Cover editor

/// The "Edit Cover" sheet: pick an image, frame it separately for the tall
/// header and the short list row (drag to pan; a zoom slider per preview —
/// pinch also works on the big one), lay a tape chip behind the title, and
/// pick the title's font, colour, and list-row justification. Nothing is
/// written until Save.
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
    @State private var showFontPicker = false

    // Gesture baselines so drag/pinch compose with the committed style.
    @State private var panBase: CGSize?
    @State private var zoomBase: Double?

    /// Preset tape colours; the colour well beside them takes anything else.
    private static let tapeSwatches: [String] = [
        MixtapeStyle.defaultTapeHex, // masking-tape white
        "#F7E08B", // yellow
        "#F2B8C6", // pink
        "#AFCBE8", // blue
        "#B8D8B0", // green
        "#C9A87C", // kraft
        "#3A3A3C", // black
    ]

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
                coverSection
                listRowSection
                tapeSection
                fontSection
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
            .sheet(isPresented: $showFontPicker) {
                MixtapeFontPicker(fontName: $style.fontName)
            }
        }
    }

    // MARK: Sections

    private var coverSection: some View {
        Section {
            headerPreview
                .listRowInsets(EdgeInsets())
            zoomSlider(value: $style.zoom)
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label(previewImage == nil ? "Choose Image" : "Choose Different Image",
                      systemImage: "photo")
            }
        } header: {
            Text("Cover")
        } footer: {
            Text(previewImage == nil
                 ? "Pick an image to show behind the mixtape's title."
                 : "Drag to position the image (pinch or slide to zoom). The original image is kept — the framing can be changed any time.")
        }
    }

    private var listRowSection: some View {
        Section {
            rowPreview
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowSeparator(.hidden)
            zoomSlider(value: rowZoomBinding)
            Picker("Title Alignment", selection: $style.centered) {
                Text("Left").tag(false)
                Text("Center").tag(true)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("List Row")
        } footer: {
            Text("The folder list shows a much shorter slice of the image, so it gets its own framing and title alignment.")
        }
    }

    private var tapeSection: some View {
        Section {
            Toggle("Add Tape", isOn: $style.tape)
            if style.tape {
                tapeColorRow
            }
        } header: {
            Text("Tape")
        } footer: {
            Text("Lays a tape-like chip behind the title.")
        }
    }

    private var fontSection: some View {
        Section("Title") {
            Button {
                showFontPicker = true
            } label: {
                HStack {
                    Text("Font")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(style.fontName ?? "System")
                        .font(style.titleFont(size: 17))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            ColorPicker("Text Color", selection: textColorBinding, supportsOpacity: false)
        }
    }

    // MARK: Previews

    private var headerPreview: some View {
        MixtapeHeaderContent(title: folder.name, style: style, image: previewImage, height: 170)
            .contentShape(Rectangle())
            .gesture(panGesture(offsetX: $style.offsetX, offsetY: $style.offsetY))
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

    private var rowPreview: some View {
        MixtapeRowContent(title: folder.name, style: style, image: previewImage,
                          count: library.tracks(in: folder.id).count,
                          showsSync: folder.isSynced)
            .contentShape(Rectangle())
            .gesture(panGesture(offsetX: rowOffsetXBinding, offsetY: rowOffsetYBinding))
    }

    /// Drag-to-pan over a preview: translation maps to the crop's normalized
    /// offsets against that preview's own size.
    private func panGesture(offsetX: Binding<Double>, offsetY: Binding<Double>) -> some Gesture {
        DragGesture(coordinateSpace: .local)
            .onChanged { value in
                let base = panBase ?? CGSize(width: offsetX.wrappedValue, height: offsetY.wrappedValue)
                panBase = base
                // Normalise against the gesture's own travel bounds; the row
                // is short, so vertical pans move it proportionally faster.
                offsetX.wrappedValue = clamp(base.width + value.translation.width / 320)
                offsetY.wrappedValue = clamp(base.height + value.translation.height / 120)
            }
            .onEnded { _ in panBase = nil }
    }

    private func zoomSlider(value: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "minus.magnifyingglass")
                .foregroundStyle(.secondary)
            Slider(value: value, in: 1...4)
            Image(systemName: "plus.magnifyingglass")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Tape colors

    private var tapeColorRow: some View {
        HStack(spacing: 10) {
            ForEach(Self.tapeSwatches, id: \.self) { hex in
                let selected = (style.tapeColorHex ?? MixtapeStyle.defaultTapeHex) == hex
                Button {
                    style.tapeColorHex = hex
                } label: {
                    Circle()
                        .fill(Color(mixtapeHex: hex) ?? .white)
                        .frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(
                            selected ? Color.accentColor : Color.secondary.opacity(0.3),
                            lineWidth: selected ? 2 : 1))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            ColorPicker("", selection: tapeColorBinding, supportsOpacity: false)
                .labelsHidden()
        }
    }

    // MARK: Bindings

    private var rowZoomBinding: Binding<Double> {
        Binding(get: { style.rowZoom }, set: { style.rowZoom = $0 })
    }

    private var rowOffsetXBinding: Binding<Double> {
        Binding(get: { style.rowOffsetX }, set: { style.rowOffsetX = $0 })
    }

    private var rowOffsetYBinding: Binding<Double> {
        Binding(get: { style.rowOffsetY }, set: { style.rowOffsetY = $0 })
    }

    private var textColorBinding: Binding<Color> {
        Binding(
            get: { style.titleColor },
            set: { style.textColorHex = $0.mixtapeHex }
        )
    }

    private var tapeColorBinding: Binding<Color> {
        Binding(
            get: { style.tapeColor },
            set: { style.tapeColorHex = $0.mixtapeHex }
        )
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
        // A fresh image starts from clean crops.
        style.zoom = 1
        style.offsetX = 0
        style.offsetY = 0
        style.rowZoom = 1
        style.rowOffsetX = 0
        style.rowOffsetY = 0
    }
}

// MARK: - Font picker

/// Every font family on the system (plus System itself), each row rendered in
/// the font it names, with the title colour picked separately in the editor.
struct MixtapeFontPicker: View {
    @Binding var fontName: String?
    @Environment(\.dismiss) private var dismiss

    private let families = UIFont.familyNames.sorted {
        $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }

    var body: some View {
        NavigationStack {
            List {
                fontRow(name: nil, displayName: "System")
                ForEach(families, id: \.self) { family in
                    fontRow(name: family, displayName: family)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Title Font")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func fontRow(name: String?, displayName: String) -> some View {
        Button {
            fontName = name
            dismiss()
        } label: {
            HStack {
                Text(displayName)
                    .font(name.map { Font.custom($0, size: 19) } ?? Font.system(size: 19, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                if fontName == name {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }
}
