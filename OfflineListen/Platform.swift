import SwiftUI
import AVFoundation

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// The handful of platform types and affordances the app reaches for that UIKit
/// and AppKit spell differently.
///
/// The app was written for iPhone, so nearly all of it is plain SwiftUI and
/// crosses to the Mac untouched. What doesn't cross falls into two piles, and
/// this file exists so neither one has to litter the call sites:
///
///  1. **Types with the same shape under different names** — `UIImage`/`NSImage`,
///     `UIColor`/`NSColor`, the pasteboard. These get a `Platform…` alias plus
///     whatever small extension makes the AppKit side answer the same calls the
///     UIKit side already does (`jpegData(compressionQuality:)` is the notable
///     one — `NSImage` has no such method).
///  2. **SwiftUI modifiers iOS declares and macOS doesn't** — the navigation-bar
///     family, `keyboardType`, autocapitalization. Rather than wrap two dozen
///     call sites in `#if os(iOS)`, macOS gets a no-op shim with a matching
///     signature, so the shared views read exactly as they did before and the
///     modifier simply does nothing where the concept doesn't exist.
///
/// Anything genuinely *different* on the Mac — the share sheet, the video
/// surface, the noise map's scroll machinery — is not shimmed here; those have
/// real per-platform implementations next to their iOS counterparts.

// MARK: - Types

#if canImport(UIKit)
typealias PlatformImage = UIImage
typealias PlatformColor = UIColor
#else
typealias PlatformImage = NSImage
typealias PlatformColor = NSColor
#endif

extension Image {
    /// `Image(uiImage:)` / `Image(nsImage:)` under one name.
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

// MARK: - Images

#if canImport(AppKit) && !canImport(UIKit)
extension NSImage {
    /// `UIImage`'s JPEG encoder, which `NSImage` lacks. Goes through a bitmap
    /// rep because that's the only thing on the AppKit side that can encode.
    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg,
                                     properties: [.compressionFactor: compressionQuality])
    }
}
#endif

extension PlatformImage {
    /// A copy drawn down to `size`, or the original when it already fits.
    /// Stands in for `UIGraphicsImageRenderer`, which has no AppKit twin.
    func downscaled(toLongestSide longest: CGFloat) -> PlatformImage {
        let largest = max(size.width, size.height)
        guard largest > longest, largest > 0 else { return self }
        let scale = longest / largest
        let target = CGSize(width: (size.width * scale).rounded(),
                            height: (size.height * scale).rounded())
        #if canImport(UIKit)
        return UIGraphicsImageRenderer(size: target).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
        #else
        let output = NSImage(size: target)
        output.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: CGRect(origin: .zero, size: target))
        output.unlockFocus()
        return output
        #endif
    }
}

// MARK: - Colors

extension Color {
    /// The sRGB components behind this color, or nil when it can't be resolved
    /// (a catalog color with no concrete value, say). AppKit needs the explicit
    /// conversion to sRGB first — `getRed` raises on a color in any other space,
    /// where UIKit quietly converts.
    var rgbaComponents: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if canImport(UIKit)
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        #else
        guard let resolved = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        return (r, g, b, a)
    }
}

extension Color {
    /// The window/page background. UIKit names it `systemBackground`; AppKit
    /// calls the same thing `windowBackgroundColor`.
    static var appBackground: Color {
        #if canImport(UIKit)
        return Color(UIColor.systemBackground)
        #else
        return Color(NSColor.windowBackgroundColor)
        #endif
    }

    /// The background for content sitting *on* `appBackground` — cards, grouped
    /// rows, the layer the map's legend floats in.
    static var appSecondaryBackground: Color {
        #if canImport(UIKit)
        return Color(UIColor.secondarySystemBackground)
        #else
        return Color(NSColor.underPageBackgroundColor)
        #endif
    }

    /// The hairline between stacked bars and content.
    static var appSeparator: Color {
        #if canImport(UIKit)
        return Color(UIColor.separator)
        #else
        return Color(NSColor.separatorColor)
        #endif
    }

    /// A noise-map `#rrggbb`, as a SwiftUI color. The platform-color parse it
    /// defers to lives beside each platform's map engine.
    init(noiseHex hex: String) {
        self.init(PlatformColor(noiseHex: hex))
    }
}

// MARK: - Fonts

enum PlatformFonts {
    /// Every font family installed on the system, sorted for display.
    static var familyNames: [String] {
        #if canImport(UIKit)
        let names = UIFont.familyNames
        #else
        let names = NSFontManager.shared.availableFontFamilies
        #endif
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

// MARK: - Pasteboard

enum Pasteboard {
    static var string: String? {
        #if canImport(UIKit)
        return UIPasteboard.general.string
        #else
        return NSPasteboard.general.string(forType: .string)
        #endif
    }

    static func copy(_ value: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = value
        #else
        // AppKit pasteboards are append-only within a "declaration", so a write
        // has to clear the old contents first or it reads back stale.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #endif
    }
}

// MARK: - Audio session

/// `AVAudioSession` is an iOS concept — the Mac has no session to claim, arbitrate
/// or be interrupted on, and `AVPlayer` there just plays. These two calls are the
/// only places the shared playback code touches it, so they become no-ops rather
/// than `#if`s at the call sites.
enum AudioSession {
    static func configureForPlayback() {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        } catch {
            appLog("Audio session error: \(error.localizedDescription)",
                   level: .warning, category: "Player")
        }
        #endif
    }

    static func activate() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }
}

// MARK: - Background execution

/// An assertion that keeps the app running through a **silent gap**.
///
/// An app with the `audio` background mode stays alive *because* it is playing
/// audio; the instant the sound stops, iOS is entitled to suspend it — and a
/// suspended app never gets to start the next track. Every gap the app opens on
/// purpose is therefore wrapped in one of these: swapping the player's item at
/// the end of a track, and (much longer) resolving and downloading the next
/// preview in the Browse modal, which is seconds of silence rather than
/// milliseconds. The system grants roughly half a minute, which is what makes
/// hands-off auditioning survive a locked phone.
///
/// macOS has no such notion — a backgrounded Mac app just keeps running — so
/// the whole thing compiles down to nothing there.
@MainActor
final class BackgroundActivity {
    #if os(iOS)
    private var id: UIBackgroundTaskIdentifier = .invalid
    #endif

    init(_ name: String) {
        #if os(iOS)
        take(name)
        #endif
    }

    #if os(iOS)
    private func take(_ name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in self?.end() }
        }
    }
    #endif

    /// Hands the assertion back. Idempotent — iOS kills an app that lets one
    /// run to its deadline, so every path out of the gap calls this.
    func end() {
        #if os(iOS)
        guard id != .invalid else { return }
        let handle = id
        id = .invalid
        UIApplication.shared.endBackgroundTask(handle)
        #endif
    }

    /// Holds one across an async span — the shape most callers want.
    static func spanning<T>(_ name: String, _ work: () async throws -> T) async rethrows -> T {
        let activity = BackgroundActivity(name)
        defer { activity.end() }
        return try await work()
    }

    /// Holds one for a few seconds past a synchronous hand-off. `AVPlayer.play()`
    /// returns long before the audio is actually running, so letting go the
    /// moment the call returns gives the app back to the scheduler mid-gap.
    static func bridging(_ name: String, seconds: Double = 5, _ work: () -> Void) {
        let activity = BackgroundActivity(name)
        work()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            activity.end()
        }
    }
}

// MARK: - Screen

enum PlatformScreen {
    /// Width of the screen the app is on, for the one place that sizes a video
    /// box off it before layout can measure anything.
    static var width: CGFloat {
        #if canImport(UIKit)
        return UIScreen.main.bounds.width
        #else
        return NSScreen.main?.frame.width ?? 1440
        #endif
    }
}

// MARK: - SwiftUI modifiers macOS doesn't declare

#if os(macOS)

/// Stand-in for `NavigationBarItem.TitleDisplayMode`, which is iOS-only. Exists
/// purely so `.navigationBarTitleDisplayMode(.inline)` still type-checks in the
/// shared views; the Mac has no navigation bar to size.
enum PlatformTitleDisplayMode {
    case automatic, inline, large
}

/// Stand-in for `UIKeyboardType` — nothing on the Mac has a software keyboard
/// to specialize.
enum PlatformKeyboardType {
    case `default`, URL, webSearch, emailAddress, numberPad, decimalPad
}

/// Stand-in for `TextInputAutocapitalization`.
enum PlatformTextInputAutocapitalization {
    case never, words, sentences, characters
}

extension View {
    func navigationBarTitleDisplayMode(_ mode: PlatformTitleDisplayMode) -> some View { self }
    func keyboardType(_ type: PlatformKeyboardType) -> some View { self }
    func textInputAutocapitalization(_ style: PlatformTextInputAutocapitalization?) -> some View { self }
    func statusBarHidden(_ hidden: Bool = true) -> some View { self }
}

/// Stand-in for SwiftUI's `EditMode`, which macOS doesn't have.
///
/// The screens that use it drive their *own* selection chrome from
/// `isEditing` — the checkboxes, the Select/Done button, whether a row taps
/// through to playback — so on the Mac that all keeps working off this flag.
/// What's lost is only the system-drawn edit affordance, and `.onMove` reorders
/// by drag on macOS without one.
enum EditMode {
    case inactive, active, transient

    var isEditing: Bool { self != .inactive }
}

#endif

extension View {
    /// iOS's grouped-inset list; the Mac's nearest equivalent is a plain inset
    /// list, since it has no grouped style.
    func insetGroupedListStyle() -> some View {
        #if os(macOS)
        return listStyle(.inset)
        #else
        return listStyle(.insetGrouped)
        #endif
    }

    /// Publishes the screen's edit state to the `List` beneath it — which is an
    /// iOS-only conversation, so on the Mac this is a no-op and the screen's own
    /// selection chrome is the whole story.
    func editModeEnvironment(_ mode: Binding<EditMode>) -> some View {
        #if os(macOS)
        return self
        #else
        return environment(\.editMode, mode)
        #endif
    }
}

#if os(macOS)

extension ToolbarItemPlacement {
    /// The Mac's nearest equivalents, so shared toolbars keep one spelling.
    /// `.primaryAction` lands at the trailing edge of the window toolbar and
    /// `.navigation` at the leading edge — the same reading order the iOS bar
    /// gives these two.
    static var navigationBarTrailing: ToolbarItemPlacement { .primaryAction }
    static var navigationBarLeading: ToolbarItemPlacement { .navigation }
}

#endif
