import SwiftUI
import UIKit

/// One dot of text on a noise map — a genre on the master map, or an artist
/// on a genre's map. Coordinates are the site's own layout pixels.
struct NoiseMapItem {
    let id: String
    let label: String
    let x: CGFloat
    let y: CGFloat
    let colorHex: String
    /// Font-size percent (the site's popularity cue), 100 = normal.
    let size: Int
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
struct NoiseMapView: UIViewRepresentable {
    /// Identity of the dataset — rebuild only when this changes, never on
    /// ordinary SwiftUI re-renders.
    let mapID: String
    let items: [NoiseMapItem]
    /// The item drawn inverted (its color as background), e.g. what's playing.
    var highlightedID: String?
    var centerRequest: NoiseMapCenter?
    var onTap: (String) -> Void

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = NoiseScrollView()
        scroll.backgroundColor = .systemBackground
        scroll.delegate = context.coordinator
        scroll.showsVerticalScrollIndicator = true
        scroll.showsHorizontalScrollIndicator = true
        scroll.contentInsetAdjustmentBehavior = .always

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
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        let c = context.coordinator
        c.onTap = onTap
        if c.mapID != mapID {
            c.rebuild(mapID: mapID, items: items)
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
        var onTap: (String) -> Void = { _ in }
        var lastCenterToken: UUID?

        private(set) var mapID = ""
        private var items: [NoiseMapItem] = []
        /// Precomputed label frames in content coordinates, parallel to `items`.
        private var frames: [CGRect] = []
        private var colors: [UIColor] = []
        private var fonts: [UIFont] = []
        private var indexByID: [String: Int] = [:]
        /// Spatial grid: cell key → item indices, for O(visible) lookups.
        private var grid: [Int: [Int]] = [:]
        private var highlightedID: String?

        /// Live labels keyed by item index, plus the recycle pool.
        private var visible: [Int: UILabel] = [:]
        private var pool: [UILabel] = []

        private static let cell: CGFloat = 256
        private static let margin: CGFloat = 300
        private static let padding: CGFloat = 40

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

            var maxX: CGFloat = 0
            var maxY: CGFloat = 0
            for (i, item) in items.enumerated() {
                let font = UIFont.systemFont(ofSize: 12 * CGFloat(item.size) / 100,
                                             weight: item.size >= 130 ? .semibold : .regular)
                let text = item.label as NSString
                let size = text.size(withAttributes: [.font: font])
                let frame = CGRect(x: Self.padding + item.x,
                                   y: Self.padding + item.y,
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
            if let scroll = scrollView {
                scroll.contentSize = contentSize
                let inset = scroll.adjustedContentInset
                scroll.setContentOffset(CGPoint(x: -inset.left, y: -inset.top), animated: false)
            }
            updateVisible()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            updateVisible()
        }

        /// Layout hook: re-evaluate only when the viewport actually moved or
        /// resized (layoutSubviews also fires on every scroll tick).
        func viewportChanged() {
            guard let scroll = scrollView else { return }
            let rect = CGRect(origin: scroll.contentOffset, size: scroll.bounds.size)
            if rect != lastViewport {
                updateVisible()
            }
        }

        private var lastViewport = CGRect.null

        /// Materializes labels intersecting the viewport (+margin), retires
        /// the rest into the pool.
        private func updateVisible() {
            guard let scroll = scrollView, let content = contentView,
                  !items.isEmpty, scroll.bounds.width > 0 else { return }
            lastViewport = CGRect(origin: scroll.contentOffset, size: scroll.bounds.size)
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
            label.text = items[i].label
            label.font = fonts[i]
            label.frame = frames[i]
            style(label, index: i)
        }

        /// Normal: colored text, clear background. Highlighted: inverted, the
        /// site's own "now playing" cue.
        private func style(_ label: UILabel, index: Int) {
            if items[index].id == highlightedID {
                label.textColor = .systemBackground
                label.layer.backgroundColor = colors[index].cgColor
            } else {
                label.textColor = colors[index]
                label.layer.backgroundColor = UIColor.clear.cgColor
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

        func center(on id: String, animated: Bool) {
            guard let scroll = scrollView, let i = indexByID[id] else { return }
            let frame = frames[i]
            let inset = scroll.adjustedContentInset
            let viewW = scroll.bounds.width - inset.left - inset.right
            let viewH = scroll.bounds.height - inset.top - inset.bottom
            var offset = CGPoint(x: frame.midX - viewW / 2 - inset.left,
                                 y: frame.midY - viewH / 2 - inset.top)
            offset.x = max(-inset.left, min(offset.x, scroll.contentSize.width - viewW - inset.left))
            offset.y = max(-inset.top, min(offset.y, scroll.contentSize.height - viewH - inset.top))
            scroll.setContentOffset(offset, animated: animated)
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
