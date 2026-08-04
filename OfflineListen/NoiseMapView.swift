import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One dot of text on a noise map — a genre on the master map, or an artist
/// on a genre's map. Coordinates are the site's own layout pixels (top-left
/// origin); the renderer flips the vertical axis, so an item with the
/// smallest `y` draws at the *bottom* of the canvas.
struct NoiseMapItem {
    let id: String
    let label: String
    let x: CGFloat
    let y: CGFloat
    let colorHex: String
    /// Font-size percent (the site's popularity cue), 100 = normal.
    let size: Int
    /// Drawn underlined. The one thing on these maps that isn't from the
    /// scrape: an artist the app harvested from Spotify, whose position is
    /// arbitrary and whose size is a guess (see `ENUpdateStore`). Worth
    /// marking, since everything around it means something.
    var underlined: Bool = false
}

/// A programmatic "scroll the map here" request. A fresh token re-triggers
/// centering even on the same id (find → find the same genre again).
struct NoiseMapCenter: Equatable {
    let id: String
    let token: UUID
}

/// The scatter map, faithful to the site: thousands of absolutely-positioned
/// colored labels on a big scrollable canvas. SwiftUI can't keep that smooth
/// on an iPad — a ZStack would materialize every label — so this is a
/// `UIScrollView` that **virtualizes**: a spatial grid buckets the items, and
/// only labels intersecting the visible rect (plus a margin) exist as views,
/// recycled from a pool as the map pans. A few hundred live labels at most,
/// whatever the dataset size.
///
/// Two navigation aids ride on top: the map **opens centered** on its canvas
/// (not the top-left corner), and a **scroll pill** hugs the right edge — a
/// draggable dot mapped onto the full vertical scroll, since the genre map is
/// ~15 screens tall and the system indicator can't be grabbed.
#if canImport(UIKit)

struct NoiseMapView: UIViewRepresentable {
    /// Identity of the dataset — rebuild only when this changes, never on
    /// ordinary SwiftUI re-renders.
    let mapID: String
    let items: [NoiseMapItem]
    /// Bumped by the caller when `items` changes for the **same** map — the
    /// Every Noise harvest adding artists to a genre already on screen. Kept
    /// apart from `mapID` because a rebuild re-centers the canvas, and having
    /// the map jump back to the middle under you is not what "a new artist
    /// turned up" should feel like.
    var itemsVersion: Int = 0
    /// The item drawn inverted (its color as background), e.g. what's playing.
    var highlightedID: String?
    var centerRequest: NoiseMapCenter?
    /// Extra bottom content inset. The map ignores the bottom safe area (it
    /// runs edge to edge under the tab bar), so UIKit's inset adjustment never
    /// learns about the SwiftUI mini player — the caller passes its measured
    /// height here so the lowest rows can still scroll clear of it.
    var bottomInset: CGFloat = 0
    var onTap: (String) -> Void

    func makeUIView(context: Context) -> UIView {
        let container = UIView()

        let scroll = NoiseScrollView()
        scroll.backgroundColor = .systemBackground
        scroll.delegate = context.coordinator
        scroll.showsVerticalScrollIndicator = true
        scroll.showsHorizontalScrollIndicator = true
        scroll.contentInsetAdjustmentBehavior = .always
        scroll.frame = container.bounds
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(scroll)

        let content = UIView()
        scroll.addSubview(content)
        context.coordinator.scrollView = scroll
        context.coordinator.contentView = content
        // Scrolling reports through the delegate, but the *initial* layout
        // (and rotations) only pass through layoutSubviews — without this
        // hook the map would stay blank until the first pan.
        scroll.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.viewportChanged()
        }

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        content.addGestureRecognizer(tap)

        // The scroll pill: a generous grab area with the visible dot centered
        // in it, overlaid on the container (not the scroll view) so it never
        // scrolls with the canvas.
        let pill = UIView(frame: CGRect(x: 0, y: 0,
                                        width: Coordinator.pillHitSize,
                                        height: Coordinator.pillHitSize))
        let dot = UIView(frame: CGRect(
            x: (Coordinator.pillHitSize - Coordinator.pillSize) / 2,
            y: (Coordinator.pillHitSize - Coordinator.pillSize) / 2,
            width: Coordinator.pillSize, height: Coordinator.pillSize))
        // An open ring, not a filled dot: clear center, white 3pt outline.
        // No shadowPath — CoreAnimation derives the shadow from the layer's
        // alpha, so it hugs the ring (a path would shade the open center too)
        // and keeps the white outline legible over a white map.
        dot.backgroundColor = .clear
        dot.layer.cornerRadius = Coordinator.pillSize / 2
        dot.layer.borderWidth = 3
        dot.layer.borderColor = UIColor.white.cgColor
        dot.layer.shadowColor = UIColor.black.cgColor
        dot.layer.shadowOpacity = 0.35
        dot.layer.shadowRadius = 2
        dot.layer.shadowOffset = CGSize(width: 0, height: 1)
        dot.isUserInteractionEnabled = false
        pill.addSubview(dot)
        pill.isHidden = true
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePillPan(_:)))
        pill.addGestureRecognizer(pan)
        container.addSubview(pill)
        context.coordinator.pillView = pill

        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        let c = context.coordinator
        c.onTap = onTap
        c.setBottomInset(bottomInset)
        if c.mapID != mapID {
            c.rebuild(mapID: mapID, items: items, version: itemsVersion)
        } else if c.itemsVersion != itemsVersion {
            c.refresh(items: items, version: itemsVersion)
        }
        c.setHighlight(highlightedID)
        if let request = centerRequest, request.token != c.lastCenterToken {
            c.lastCenterToken = request.token
            c.center(on: request.id, animated: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Coordinator: the actual virtualizing engine

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: UIScrollView?
        weak var contentView: UIView?
        weak var pillView: UIView?
        var onTap: (String) -> Void = { _ in }
        var lastCenterToken: UUID?

        private(set) var mapID = ""
        private(set) var itemsVersion = 0
        private var items: [NoiseMapItem] = []
        /// Precomputed label frames in content coordinates, parallel to `items`.
        private var frames: [CGRect] = []
        private var colors: [UIColor] = []
        private var fonts: [UIFont] = []
        private var indexByID: [String: Int] = [:]
        /// Spatial grid: cell key → item indices, for O(visible) lookups.
        private var grid: [Int: [Int]] = [:]
        private var highlightedID: String?
        /// Set by `rebuild`, honored on the first layout pass with real
        /// bounds: the map opens centered on its canvas, not the top-left.
        private var pendingInitialCenter = false
        /// A `center(on:)` that arrived before the first layout (a History
        /// artist re-open) — applied once bounds exist, instead of being
        /// computed against a zero-sized viewport.
        private var pendingCenterID: String?

        /// Live labels keyed by item index, plus the recycle pool.
        private var visible: [Int: UILabel] = [:]
        private var pool: [UILabel] = []

        private static let cell: CGFloat = 256
        private static let margin: CGFloat = 300
        private static let padding: CGFloat = 40

        /// The visible scroll-pill ring, and the (larger) draggable area it
        /// sits in — the ring alone is a fiddly drag target.
        static let pillSize: CGFloat = 30
        static let pillHitSize: CGFloat = 44
        private static let pillMargin: CGFloat = 6

        /// A different dataset: lay it out and open centered on the canvas.
        func rebuild(mapID: String, items: [NoiseMapItem], version: Int) {
            self.mapID = mapID
            self.itemsVersion = version
            highlightedID = nil
            layout(items)
            if let scroll = scrollView {
                // Land in the middle of the canvas, not the top-left corner.
                // Bounds may still be zero here (first update runs before
                // layout), in which case the first real layout pass applies it.
                pendingCenterID = nil
                pendingInitialCenter = true
                applyInitialCenterIfReady(scroll)
            }
            updateVisible()
        }

        /// The same dataset with rows added — relaid out where the reader left
        /// it, no re-centering and no loss of the highlight.
        func refresh(items: [NoiseMapItem], version: Int) {
            itemsVersion = version
            layout(items)
            updateVisible()
        }

        private func layout(_ items: [NoiseMapItem]) {
            self.items = items

            for label in visible.values { label.removeFromSuperview() }
            visible.removeAll()

            frames.removeAll(keepingCapacity: true)
            colors.removeAll(keepingCapacity: true)
            fonts.removeAll(keepingCapacity: true)
            indexByID.removeAll(keepingCapacity: true)
            grid.removeAll(keepingCapacity: true)

            // The vertical axis renders *reversed* relative to the scraped
            // page coordinates: the site's y grows downward (CSS), and flipping
            // it here turns the map the way round the user reads it. Only the
            // anchor positions flip — everything downstream (the grid, taps,
            // centering) works off the flipped `frames`, so nothing else cares.
            let maxRawY = items.map(\.y).max() ?? 0

            var maxX: CGFloat = 0
            var maxY: CGFloat = 0
            for (i, item) in items.enumerated() {
                let font = UIFont.systemFont(ofSize: 12 * CGFloat(item.size) / 100,
                                             weight: item.size >= 130 ? .semibold : .regular)
                let text = item.label as NSString
                let size = text.size(withAttributes: [.font: font])
                let frame = CGRect(x: Self.padding + item.x,
                                   y: Self.padding + (maxRawY - item.y),
                                   width: ceil(size.width) + 10,
                                   height: ceil(size.height) + 4)
                frames.append(frame)
                fonts.append(font)
                colors.append(UIColor(noiseHex: item.colorHex))
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
            scrollView?.contentSize = contentSize
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            updateVisible()
        }

        /// Layout hook: re-evaluate only when the viewport actually moved or
        /// resized (layoutSubviews also fires on every scroll tick).
        func viewportChanged() {
            guard let scroll = scrollView else { return }
            applyInitialCenterIfReady(scroll)
            let rect = CGRect(origin: scroll.contentOffset, size: scroll.bounds.size)
            if rect != lastViewport {
                updateVisible()
            }
        }

        private var lastViewport = CGRect.null

        private func applyInitialCenterIfReady(_ scroll: UIScrollView) {
            guard scroll.bounds.width > 0 else { return }
            if let id = pendingCenterID {
                pendingCenterID = nil
                pendingInitialCenter = false
                center(on: id, animated: false)
                return
            }
            guard pendingInitialCenter else { return }
            pendingInitialCenter = false
            let target = CGPoint(x: scroll.contentSize.width / 2,
                                 y: scroll.contentSize.height / 2)
            scroll.setContentOffset(clampedOffset(centering: target, in: scroll),
                                    animated: false)
        }

        /// Materializes labels intersecting the viewport (+margin), retires
        /// the rest into the pool.
        private func updateVisible() {
            guard let scroll = scrollView, let content = contentView,
                  !items.isEmpty, scroll.bounds.width > 0 else { return }
            lastViewport = CGRect(origin: scroll.contentOffset, size: scroll.bounds.size)
            updatePill()
            let view = lastViewport
                .insetBy(dx: -Self.margin, dy: -Self.margin)

            var wanted = Set<Int>()
            let x0 = max(0, Int(view.minX / Self.cell)), x1 = max(0, Int(view.maxX / Self.cell))
            let y0 = max(0, Int(view.minY / Self.cell)), y1 = max(0, Int(view.maxY / Self.cell))
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

        private func dequeue(in content: UIView) -> UILabel {
            if let label = pool.popLast() {
                label.isHidden = false
                return label
            }
            let label = UILabel()
            label.textAlignment = .center
            label.layer.cornerRadius = 4
            label.layer.masksToBounds = true
            content.addSubview(label)
            return label
        }

        private func configure(_ label: UILabel, for i: Int) {
            label.frame = frames[i]
            style(label, index: i)
        }

        /// Normal: colored text, clear background. Highlighted: inverted, the
        /// site's own "now playing" cue. An underlined item needs attributed
        /// text (a `UILabel` has no underline of its own), so the text goes on
        /// here rather than in `configure` — otherwise a recycled label could
        /// keep the last occupant's underline, or lose its own to a highlight.
        private func style(_ label: UILabel, index: Int) {
            let highlighted = items[index].id == highlightedID
            let color = highlighted ? UIColor.systemBackground : colors[index]
            label.layer.backgroundColor = highlighted
                ? colors[index].cgColor
                : UIColor.clear.cgColor
            if items[index].underlined {
                label.attributedText = NSAttributedString(
                    string: items[index].label,
                    attributes: [.font: fonts[index],
                                 .foregroundColor: color,
                                 .underlineStyle: NSUnderlineStyle.single.rawValue,
                                 .underlineColor: color,
                                 // Carried in the attributes rather than left
                                 // to the label's own `textAlignment`, which
                                 // attributed text doesn't reliably inherit.
                                 .paragraphStyle: Self.centered])
            } else {
                label.attributedText = nil
                label.text = items[index].label
                label.font = fonts[index]
                label.textColor = color
            }
        }

        private static let centered: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            return style
        }()

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

        /// Applies the caller's extra bottom inset (the mini player's height —
        /// see `NoiseMapView.bottomInset`) on top of UIKit's own adjustment.
        func setBottomInset(_ inset: CGFloat) {
            guard let scroll = scrollView, scroll.contentInset.bottom != inset else { return }
            scroll.contentInset.bottom = inset
            scroll.verticalScrollIndicatorInsets.bottom = inset
            // The pill's track just changed length — resettle it now rather
            // than on the next scroll tick.
            updatePill()
        }

        func center(on id: String, animated: Bool) {
            guard let scroll = scrollView, let i = indexByID[id] else { return }
            // An explicit target supersedes the open-centered default; before
            // the first layout it can only be deferred, not computed.
            pendingInitialCenter = false
            guard scroll.bounds.width > 0 else {
                pendingCenterID = id
                return
            }
            let frame = frames[i]
            scroll.setContentOffset(
                clampedOffset(centering: CGPoint(x: frame.midX, y: frame.midY), in: scroll),
                animated: animated)
        }

        /// The content offset that puts `point` (content coordinates) in the
        /// middle of the visible area, clamped to the scrollable range.
        private func clampedOffset(centering point: CGPoint, in scroll: UIScrollView) -> CGPoint {
            let inset = scroll.adjustedContentInset
            let viewW = scroll.bounds.width - inset.left - inset.right
            let viewH = scroll.bounds.height - inset.top - inset.bottom
            var offset = CGPoint(x: point.x - viewW / 2 - inset.left,
                                 y: point.y - viewH / 2 - inset.top)
            offset.x = max(-inset.left, min(offset.x, scroll.contentSize.width - viewW - inset.left))
            offset.y = max(-inset.top, min(offset.y, scroll.contentSize.height - viewH - inset.top))
            return offset
        }

        // MARK: Scroll pill

        /// The pill's vertical travel within the container: clear of the bars
        /// the safe area describes, with a small margin.
        private func pillTrack(_ scroll: UIScrollView) -> (top: CGFloat, height: CGFloat) {
            let inset = scroll.adjustedContentInset
            let top = inset.top + Self.pillMargin
            let bottom = scroll.bounds.height - inset.bottom - Self.pillMargin
            return (top, max(0, bottom - top - Self.pillHitSize))
        }

        /// How far down the scrollable range the viewport currently sits, 0–1.
        private func scrollFraction(_ scroll: UIScrollView) -> CGFloat? {
            let inset = scroll.adjustedContentInset
            let range = scroll.contentSize.height + inset.top + inset.bottom - scroll.bounds.height
            guard range > 1 else { return nil }
            return max(0, min(1, (scroll.contentOffset.y + inset.top) / range))
        }

        /// Keeps the pill mirroring the scroll position (and hides it when the
        /// whole canvas fits the viewport).
        private func updatePill() {
            guard let scroll = scrollView, let pill = pillView else { return }
            guard let fraction = scrollFraction(scroll) else {
                pill.isHidden = true
                return
            }
            pill.isHidden = false
            let track = pillTrack(scroll)
            pill.frame.origin = CGPoint(
                x: scroll.bounds.width - Self.pillHitSize - Self.pillMargin,
                y: track.top + track.height * fraction)
        }

        /// Dragging the pill scrolls the map: the finger's position on the
        /// track maps straight onto the scrollable range, like a scrollbar.
        @objc func handlePillPan(_ gesture: UIPanGestureRecognizer) {
            guard let scroll = scrollView, let container = pillView?.superview else { return }
            let track = pillTrack(scroll)
            guard track.height > 0 else { return }
            let y = gesture.location(in: container).y - track.top - Self.pillHitSize / 2
            let fraction = max(0, min(1, y / track.height))
            let inset = scroll.adjustedContentInset
            let range = scroll.contentSize.height + inset.top + inset.bottom - scroll.bounds.height
            guard range > 0 else { return }
            scroll.setContentOffset(
                CGPoint(x: scroll.contentOffset.x, y: fraction * range - inset.top),
                animated: false)
        }

        /// Tap: the label under the finger — nearest center among generous
        /// hit rects, since map text is small.
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            let point = gesture.location(in: contentView)
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

/// A `UIScrollView` that reports layout passes — the initial one especially —
/// so the virtualizer can populate before any scrolling happens.
final class NoiseScrollView: UIScrollView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

extension UIColor {
    /// `#rrggbb` (the site's colors). Anything unparseable renders as label
    /// gray rather than invisibly.
    convenience init(noiseHex hex: String) {
        var value: UInt64 = 0
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&value) else {
            self.init(white: 0.5, alpha: 1)
            return
        }
        self.init(red: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: 1)
    }
}

#endif
