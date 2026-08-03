#if canImport(AppKit) && !canImport(UIKit)

import SwiftUI
import AppKit

/// The Mac's noise map — the AppKit twin of the `UIScrollView` engine in
/// `NoiseMapView.swift`, and identical in design: a spatial grid buckets the
/// items, and only labels intersecting the visible rect (plus a margin) exist as
/// views, recycled from a pool as the map pans. A few hundred live labels at
/// most, whatever the dataset size.
///
/// Two things differ from iOS, both because the Mac is not a phone:
///
///  * **No scroll pill.** iOS grew one because the system scroll indicator
///    can't be grabbed with a finger, and the genre map is ~15 screens tall. A
///    Mac scroller is a real, draggable control, so the map just uses it.
///  * **A flipped document view.** The frame math puts the origin top-left
///    (it's the site's own layout coordinate space); AppKit's default is
///    bottom-left, so the canvas declares `isFlipped` and everything downstream
///    — the grid, taps, centering — reads exactly as it does on iOS.
struct NoiseMapView: NSViewRepresentable {
    /// Identity of the dataset — rebuild only when this changes, never on
    /// ordinary SwiftUI re-renders.
    let mapID: String
    let items: [NoiseMapItem]
    /// The item drawn inverted (its color as background), e.g. what's playing.
    var highlightedID: String?
    var centerRequest: NoiseMapCenter?
    /// Extra bottom clearance for the SwiftUI mini player, which floats over
    /// the map rather than participating in its layout.
    var bottomInset: CGFloat = 0
    var onTap: (String) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = false
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        let content = FlippedView()
        scroll.documentView = content

        let coordinator = context.coordinator
        coordinator.scrollView = scroll
        coordinator.contentView = content

        // AppKit reports scrolling as a bounds change on the clip view, and
        // only when asked to.
        scroll.contentView.postsBoundsChangedNotifications = true
        coordinator.observeScrolling()

        let click = NSClickGestureRecognizer(target: coordinator,
                                             action: #selector(Coordinator.handleClick(_:)))
        content.addGestureRecognizer(click)

        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.onTap = onTap
        c.setBottomInset(bottomInset)
        if c.mapID != mapID {
            c.rebuild(mapID: mapID, items: items)
        }
        c.setHighlight(highlightedID)
        if let request = centerRequest, request.token != c.lastCenterToken {
            c.lastCenterToken = request.token
            c.center(on: request.id)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// The canvas. Flipped so y grows downward, matching the frames the
    /// virtualizer computes (and the site's own coordinate space).
    final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    // MARK: - Coordinator: the virtualizing engine

    final class Coordinator: NSObject {
        weak var scrollView: NSScrollView?
        weak var contentView: NSView?
        var onTap: (String) -> Void = { _ in }
        var lastCenterToken: UUID?

        private(set) var mapID = ""
        private var items: [NoiseMapItem] = []
        /// Precomputed label frames in content coordinates, parallel to `items`.
        private var frames: [CGRect] = []
        private var colors: [NSColor] = []
        private var fonts: [NSFont] = []
        private var indexByID: [String: Int] = [:]
        /// Spatial grid: cell key → item indices, for O(visible) lookups.
        private var grid: [Int: [Int]] = [:]
        private var highlightedID: String?
        /// Set by `rebuild`, honored on the first pass with real bounds: the
        /// map opens centered on its canvas, not the top-left corner.
        private var pendingInitialCenter = false
        /// A `center(on:)` that arrived before the view had bounds — applied
        /// once they exist, instead of against a zero-sized viewport.
        private var pendingCenterID: String?
        private var lastViewport = CGRect.null
        private var observer: NSObjectProtocol?

        /// Live labels keyed by item index, plus the recycle pool.
        private var visible: [Int: NSTextField] = [:]
        private var pool: [NSTextField] = []

        private static let cell: CGFloat = 256
        private static let margin: CGFloat = 300
        private static let padding: CGFloat = 40

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func observeScrolling() {
            guard let clip = scrollView?.contentView else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.viewportChanged() }
            }
        }

        func rebuild(mapID: String, items: [NoiseMapItem]) {
            self.mapID = mapID
            self.items = items
            highlightedID = nil

            for label in visible.values { label.removeFromSuperview() }
            visible.removeAll()

            frames.removeAll(keepingCapacity: true)
            colors.removeAll(keepingCapacity: true)
            fonts.removeAll(keepingCapacity: true)
            indexByID.removeAll(keepingCapacity: true)
            grid.removeAll(keepingCapacity: true)

            // The vertical axis renders *reversed* relative to the scraped page
            // coordinates: the site's y grows downward (CSS), and flipping it
            // here turns the map the way round the user reads it.
            let maxRawY = items.map(\.y).max() ?? 0

            var maxX: CGFloat = 0
            var maxY: CGFloat = 0
            for (i, item) in items.enumerated() {
                let font = NSFont.systemFont(ofSize: 12 * CGFloat(item.size) / 100,
                                             weight: item.size >= 130 ? .semibold : .regular)
                let text = item.label as NSString
                let size = text.size(withAttributes: [.font: font])
                let frame = CGRect(x: Self.padding + item.x,
                                   y: Self.padding + (maxRawY - item.y),
                                   width: ceil(size.width) + 10,
                                   height: ceil(size.height) + 4)
                frames.append(frame)
                fonts.append(font)
                colors.append(NSColor(noiseHex: item.colorHex))
                indexByID[item.id] = i
                maxX = max(maxX, frame.maxX)
                maxY = max(maxY, frame.maxY)

                let x0 = Int(frame.minX / Self.cell), x1 = Int(frame.maxX / Self.cell)
                let y0 = Int(frame.minY / Self.cell), y1 = Int(frame.maxY / Self.cell)
                for cy in y0...y1 {
                    for cx in x0...x1 {
                        grid[cy << 16 | cx, default: []].append(i)
                    }
                }
            }

            let contentSize = CGSize(width: maxX + Self.padding, height: maxY + Self.padding)
            contentView?.frame = CGRect(origin: .zero, size: contentSize)
            pendingCenterID = nil
            pendingInitialCenter = true
            applyInitialCenterIfReady()
            updateVisible()
        }

        /// Scroll and resize both land here; re-evaluate only when the viewport
        /// actually moved.
        func viewportChanged() {
            applyInitialCenterIfReady()
            guard let scroll = scrollView else { return }
            if scroll.documentVisibleRect != lastViewport {
                updateVisible()
            }
        }

        private func applyInitialCenterIfReady() {
            guard let scroll = scrollView, scroll.contentView.bounds.width > 0 else { return }
            if let id = pendingCenterID {
                pendingCenterID = nil
                pendingInitialCenter = false
                center(on: id)
                return
            }
            guard pendingInitialCenter else { return }
            pendingInitialCenter = false
            let size = contentView?.frame.size ?? .zero
            scrollTo(clampedOrigin(centering: CGPoint(x: size.width / 2, y: size.height / 2)))
        }

        /// Materializes labels intersecting the viewport (+margin), retires the
        /// rest into the pool.
        private func updateVisible() {
            guard let scroll = scrollView, let content = contentView,
                  !items.isEmpty, scroll.contentView.bounds.width > 0 else { return }
            lastViewport = scroll.documentVisibleRect
            let view = lastViewport.insetBy(dx: -Self.margin, dy: -Self.margin)

            var wanted = Set<Int>()
            let x0 = max(0, Int(view.minX / Self.cell)), x1 = max(0, Int(view.maxX / Self.cell))
            let y0 = max(0, Int(view.minY / Self.cell)), y1 = max(0, Int(view.maxY / Self.cell))
            guard x0 <= x1, y0 <= y1 else { return }
            for cy in y0...y1 {
                for cx in x0...x1 {
                    guard let bucket = grid[cy << 16 | cx] else { continue }
                    for i in bucket where frames[i].intersects(view) {
                        wanted.insert(i)
                    }
                }
            }

            for (i, label) in visible where !wanted.contains(i) {
                label.isHidden = true
                pool.append(label)
                visible.removeValue(forKey: i)
            }
            for i in wanted where visible[i] == nil {
                let label = dequeue(in: content)
                configure(label, for: i)
                visible[i] = label
            }
        }

        private func dequeue(in content: NSView) -> NSTextField {
            if let label = pool.popLast() {
                label.isHidden = false
                return label
            }
            let label = NSTextField(labelWithString: "")
            label.alignment = .center
            label.isBezeled = false
            label.isEditable = false
            label.drawsBackground = false
            label.wantsLayer = true
            label.layer?.cornerRadius = 4
            label.layer?.masksToBounds = true
            content.addSubview(label)
            return label
        }

        private func configure(_ label: NSTextField, for i: Int) {
            label.stringValue = items[i].label
            label.font = fonts[i]
            label.frame = frames[i]
            style(label, index: i)
        }

        /// Normal: colored text, clear background. Highlighted: inverted, the
        /// site's own "now playing" cue.
        private func style(_ label: NSTextField, index: Int) {
            if items[index].id == highlightedID {
                label.textColor = .textBackgroundColor
                label.layer?.backgroundColor = colors[index].cgColor
            } else {
                label.textColor = colors[index]
                label.layer?.backgroundColor = NSColor.clear.cgColor
            }
        }

        func setHighlight(_ id: String?) {
            guard id != highlightedID else { return }
            let previous = highlightedID
            highlightedID = id
            for changed in [previous, id] {
                if let changed, let i = indexByID[changed], let label = visible[i] {
                    style(label, index: i)
                }
            }
        }

        /// The mini player floats over the map, so the lowest rows need room to
        /// scroll clear of it.
        func setBottomInset(_ inset: CGFloat) {
            guard let scroll = scrollView, scroll.contentInsets.bottom != inset else { return }
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: inset, right: 0)
        }

        func center(on id: String) {
            guard let scroll = scrollView, let i = indexByID[id] else { return }
            // An explicit target supersedes the open-centered default; before
            // there are bounds it can only be deferred, not computed.
            pendingInitialCenter = false
            guard scroll.contentView.bounds.width > 0 else {
                pendingCenterID = id
                return
            }
            let frame = frames[i]
            scrollTo(clampedOrigin(centering: CGPoint(x: frame.midX, y: frame.midY)))
        }

        /// The document origin that puts `point` (content coordinates) in the
        /// middle of the visible area, clamped to the scrollable range.
        private func clampedOrigin(centering point: CGPoint) -> CGPoint {
            guard let scroll = scrollView else { return .zero }
            let viewport = scroll.contentView.bounds.size
            let content = contentView?.frame.size ?? .zero
            var origin = CGPoint(x: point.x - viewport.width / 2,
                                 y: point.y - viewport.height / 2)
            origin.x = max(0, min(origin.x, max(0, content.width - viewport.width)))
            origin.y = max(0, min(origin.y, max(0, content.height - viewport.height)))
            return origin
        }

        private func scrollTo(_ origin: CGPoint) {
            guard let scroll = scrollView else { return }
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
            updateVisible()
        }

        /// Click: the label under the pointer — nearest center among generous
        /// hit rects, since map text is small.
        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let content = contentView else { return }
            let point = gesture.location(in: content)
            var best: (index: Int, distance: CGFloat)?
            for (i, _) in visible {
                let hit = frames[i].insetBy(dx: -12, dy: -8)
                guard hit.contains(point) else { continue }
                let d = hypot(frames[i].midX - point.x, frames[i].midY - point.y)
                if best == nil || d < best!.distance {
                    best = (i, d)
                }
            }
            if let best {
                onTap(items[best.index].id)
            }
        }
    }
}

extension NSColor {
    /// `#rrggbb` (the site's colors). Anything unparseable renders as label
    /// gray rather than invisibly.
    convenience init(noiseHex hex: String) {
        var value: UInt64 = 0
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&value) else {
            self.init(white: 0.5, alpha: 1)
            return
        }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: 1)
    }
}

#endif
