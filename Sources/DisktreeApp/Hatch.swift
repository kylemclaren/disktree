// The diagonal hatch over reclaimable space.
//
// On Linux this was GPUI's `pattern_slash`, a shader fill. Here it is plain
// geometry: each stripe is a band between two diagonals, clipped to the
// rectangle as a polygon, for a legend swatch or a meter slice in SwiftUI.
// The mosaic rasterises the same geometry itself (`MosaicRaster`): the same
// diagonals, width and period in device pixels, phase anchored at each
// tile's top-left corner, so the hatch in the legend is the hatch on the
// tiles.
//
// `pattern_slash` ran per fragment over device pixels, so its width and
// interval are pixels, not points: on a Retina display a tile's stripe is one
// pixel in seven, and the legend's one in four (the screenshot, a 2x capture,
// shows exactly that). A hatch here keeps those pixel numbers, and the caller
// says how many pixels there are to the point: the view's backing scale, or
// SwiftUI's `displayScale`. A shape is never shown a context to ask, and a
// view knows its window's scale for certain. The hatch does not follow the
// interface zoom or the mosaic's zoom either, as it did not in GPUI: it is a
// texture, not a size.
//
// The stripes lean like a slash on screen whichever way the drawing space
// runs, because "/" is what the legend promises. The caller says which way
// that is: a context cannot be asked. AppKit hands a flipped, layer-backed
// view the same identity transform as an unflipped one and flips the layer
// instead, so the transform only tells the truth off screen.

import CoreGraphics
import SwiftUI

/// Slash stripes: `width` wide with `interval` between them, both measured
/// along a row in device pixels, as `pattern_slash` measured them.
public struct Hatch: Sendable, Hashable {
    /// A stripe's width along a row, in device pixels.
    public var width: CGFloat
    /// The gap between two stripes along a row, in device pixels.
    public var interval: CGFloat

    public init(width: CGFloat, interval: CGFloat) {
        self.width = width
        self.interval = interval
    }

    /// Over a tile: one pixel in seven, sparse, so the hue beneath still
    /// reads.
    public static let tile = Hatch(width: 1, interval: 6)

    /// In a legend swatch or a meter slice: one pixel in four, so a swatch
    /// ten points square still holds five stripes on a Retina display.
    public static let dense = Hatch(width: 1, interval: 3)

    /// From one stripe to the next along a row, in device pixels.
    public var period: CGFloat { width + interval }

    /// The most stripes one call draws: a 5K display's diagonal at the
    /// densest hatch is under three thousand.
    static let maxStripes: CGFloat = 100_000

    /// The stripes crossing `rect`, each clipped to it as a convex polygon.
    ///
    /// `rect` and `anchor` are in points; `scale` is the drawing's device
    /// pixels per point, which turns the hatch's pixels into points. A
    /// stripe is centred on every diagonal through `anchor` (the rect's
    /// origin unless given) plus a whole number of periods, so a hatch
    /// starts in the same phase on every tile, as a pattern anchored to its
    /// quad did. `yDown` says which way the space runs: SwiftUI and a
    /// flipped view grow downward, a bare CoreGraphics context upward.
    public func stripes(
        in rect: CGRect,
        anchor: CGPoint? = nil,
        yDown: Bool = true,
        scale: CGFloat
    ) -> [[CGPoint]] {
        let rect = rect.standardized
        guard width > 0, interval >= 0, scale > 0, scale.isFinite,
            !rect.isEmpty, !rect.isInfinite,
            rect.width.isFinite, rect.height.isFinite
        else { return [] }
        let anchor = anchor ?? rect.origin
        // The hatch in points, at this many pixels to the point.
        let stripe = width / scale
        let step = period / scale
        // Position across the stripes, in row units. On screen a slash
        // rises to the right: with y down that is `x + y` constant, with y
        // up `x - y`.
        let lean: CGFloat = yDown ? 1 : -1
        let across = { (point: CGPoint) in
            (point.x - anchor.x) + lean * (point.y - anchor.y)
        }
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
        ]
        let span = corners.map(across)
        guard let low = span.min(), let high = span.max() else { return [] }
        let half = stripe / 2
        // A rect this wide is never on screen whole: `fill` strips it to the
        // visible part first. Refusing it keeps a runaway size from turning
        // into millions of stripes, or an index past `Int`.
        guard (high - low + stripe) / step < Hatch.maxStripes else {
            return []
        }
        let first = Int(((low - half) / step).rounded(.up))
        let last = Int(((high + half) / step).rounded(.down))
        guard first <= last else { return [] }

        var stripes: [[CGPoint]] = []
        stripes.reserveCapacity(last - first + 1)
        for index in first...last {
            let centre = CGFloat(index) * step
            // The rect, cut to one side of the stripe, then the other.
            let behind = clip(corners) { across($0) - (centre - half) }
            let polygon = clip(behind) { (centre + half) - across($0) }
            if polygon.count >= 3 {
                stripes.append(polygon)
            }
        }
        return stripes
    }

    /// The stripes crossing `rect` as one path, for filling.
    public func path(
        in rect: CGRect,
        anchor: CGPoint? = nil,
        yDown: Bool = true,
        scale: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()
        let stripes = stripes(
            in: rect,
            anchor: anchor,
            yDown: yDown,
            scale: scale
        )
        for polygon in stripes {
            path.addLines(between: polygon)
            path.closeSubpath()
        }
        return path
    }

    /// Hatch `rect` in `color` on `context`: the mosaic's paint pass.
    ///
    /// Only the part of `rect` inside the context's clip is striped, so a
    /// tile zoomed far past the viewport costs what its visible part costs;
    /// the phase is still taken from the whole rect. `yDown` is the drawing
    /// view's `isFlipped`, and `scale` its window's `backingScaleFactor`.
    public func fill(
        _ rect: CGRect,
        color: CGColor,
        in context: CGContext,
        yDown: Bool,
        scale: CGFloat,
        anchor: CGPoint? = nil
    ) {
        let visible = rect.standardized.intersection(
            context.boundingBoxOfClipPath
        )
        guard !visible.isNull, !visible.isEmpty else { return }
        context.saveGState()
        context.addPath(
            path(
                in: visible,
                anchor: anchor ?? rect.standardized.origin,
                yDown: yDown,
                scale: scale
            )
        )
        context.setFillColor(color)
        context.fillPath()
        context.restoreGState()
    }
}

/// The part of a convex polygon where `keeping` is not negative
/// (Sutherland–Hodgman against one half-plane). `keeping` must be linear, so
/// an edge crossing the boundary is cut where it reaches zero.
private func clip(
    _ polygon: [CGPoint],
    keeping: (CGPoint) -> CGFloat
) -> [CGPoint] {
    var kept: [CGPoint] = []
    for (index, current) in polygon.enumerated() {
        let next = polygon[(index + 1) % polygon.count]
        let (here, there) = (keeping(current), keeping(next))
        if here >= 0 {
            kept.append(current)
        }
        if (here >= 0) != (there >= 0) {
            let t = here / (here - there)
            kept.append(
                CGPoint(
                    x: current.x + (next.x - current.x) * t,
                    y: current.y + (next.y - current.y) * t
                )
            )
        }
    }
    return kept
}

/// The hatch as a SwiftUI shape: fill it in the hatch colour over a ground.
/// `scale` is the view's `displayScale`; `HatchFill` reads it for you.
public struct HatchShape: Shape {
    public var hatch: Hatch
    /// Device pixels per point.
    public var scale: CGFloat

    public init(_ hatch: Hatch = .dense, scale: CGFloat) {
        self.hatch = hatch
        self.scale = scale
    }

    public func path(in rect: CGRect) -> Path {
        // SwiftUI's space grows downward.
        Path(hatch.path(in: rect, yDown: true, scale: scale))
    }
}

/// Its frame hatched in `color`, at the display's own pixel scale: what
/// `.bg(pattern_slash(color, …))` was on a div.
public struct HatchFill: View {
    let hatch: Hatch
    let color: HSLA
    @Environment(\.displayScale) private var scale

    public init(_ hatch: Hatch = .dense, color: HSLA) {
        self.hatch = hatch
        self.color = color
    }

    public var body: some View {
        HatchShape(hatch, scale: scale).fill(color.color)
    }
}
