// Squarified treemap layout.
//
// Bruls, Huizing and van Wijk's squarified algorithm: grow a row of tiles
// while the worst aspect ratio inside it keeps improving, then start a new row
// in the remaining space. That is what produces the legible mosaic of
// KDirStat-style explorers instead of the slivers a naive slice-and-dice
// gives.
//
// Layout runs in points, in the coordinate space of an unzoomed viewport. The
// view applies its own pan and zoom when painting, so re-layout is only needed
// when the tree, the viewport size, or the requested depth changes. Geometry
// is `Double`, so the view hands it to Core Graphics as it is.

/// An axis-aligned rectangle in viewport points: base space, before the
/// view's pan and zoom. `y` grows downwards: a directory's header band sits
/// at its `y`, above its children, so the view that paints it is flipped.
public struct Rect: Sendable, Hashable {
    /// Left edge.
    public var x: Double
    /// Top edge.
    public var y: Double
    /// Width; a layout never makes it negative.
    public var w: Double
    /// Height; a layout never makes it negative.
    public var h: Double

    /// A rectangle from its top-left corner and its size.
    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    /// Empty, at the origin: the place of a value `squarify` gave no room.
    public static let zero = Rect(x: 0, y: 0, w: 0, h: 0)

    /// Right edge, just outside the rectangle.
    public var right: Double { x + w }

    /// Bottom edge, just outside the rectangle.
    public var bottom: Double { y + h }

    /// Area in square points; a negative side counts as nothing.
    public var area: Double { max(w, 0) * max(h, 0) }

    /// Half-open, so a point on a shared edge belongs to exactly one of two
    /// neighbours.
    public func contains(x: Double, y: Double) -> Bool {
        x >= self.x && x < right && y >= self.y && y < bottom
    }

    /// Shrink on every side, never past empty.
    public func inset(_ padding: Double) -> Rect {
        Rect(
            x: x + padding,
            y: y + padding,
            w: max(w - padding * 2, 0),
            h: max(h - padding * 2, 0)
        )
    }

    /// Every coordinate multiplied by `scale`: the zoom half of the view
    /// transform, `screen = (base - origin) * scale`.
    public func scaled(_ scale: Double) -> Rect {
        Rect(x: x * scale, y: y * scale, w: w * scale, h: h * scale)
    }

    /// Moved by `dx`, `dy`, the same size: the pan half of the view
    /// transform.
    public func translated(dx: Double, dy: Double) -> Rect {
        Rect(x: x + dx, y: y + dy, w: w, h: h)
    }
}

/// What a tile stands for.
public enum TileKind: Sendable, Hashable {
    /// A real node at `crumbs`, which are child indices from the scanned root.
    case node(crumbs: [Int])
    /// The tail of a long child list, merged so its area is still accounted
    /// for instead of silently dropped. `crumbs` are the directory's whose
    /// tail it is.
    case others(crumbs: [Int], count: Int)
}

/// One rectangle of the mosaic.
public struct Tile: Sendable, Hashable {
    /// What it stands for: a node, or a directory's merged tail.
    public var kind: TileKind
    /// Where it is, in base-space points, already inset by its padding.
    public var rect: Rect
    /// Nesting level: 0 tiles are children of the current root.
    public var depth: Int
    /// The band this directory reserved for its own name, when it is
    /// subdivided. Its children are laid out below it, so a parent's name
    /// never sits on top of a child — and the band is part of the parent for
    /// hit-testing, which makes a parent reachable without aiming at its
    /// border.
    public var header: Rect?

    /// A tile as `layout` places it; `header` only for a subdivided
    /// directory.
    public init(kind: TileKind, rect: Rect, depth: Int, header: Rect? = nil) {
        self.kind = kind
        self.rect = rect
        self.depth = depth
        self.header = header
    }

    /// Absolute crumbs from the scanned root: the node itself, or, for an
    /// `others` tile, the directory whose tail it stands for.
    public var crumbs: [Int] {
        switch kind {
        case .node(let crumbs): crumbs
        case .others(let crumbs, _): crumbs
        }
    }
}

/// How much of the tree to draw, and how finely.
public struct LayoutOptions: Sendable, Hashable {
    /// Nesting levels drawn at once; 1 draws only the root's children.
    public var maxDepth: Int
    /// Gap between siblings inside a directory, and inset into it.
    public var padding: Double
    /// Gap between the top-level directories: wider than `padding`, so the
    /// first level of structure reads before the detail inside it.
    public var paddingOuter: Double
    /// Tiles below this many points are dropped; they cannot be read or hit.
    public var minTile: Double
    /// Children kept per directory. The tail merges into one `others` tile.
    public var maxChildren: Int
    /// Height of the band a top-level directory keeps for its name.
    public var header: Double
    /// Height of the slimmer band a deeper directory keeps when it is drawn
    /// open. A directory drawn closed has no band: its label sits in its
    /// corner, over nothing but its own fill.
    public var headerInner: Double

    /// The options the explorer draws with, unless told otherwise.
    public init(
        maxDepth: Int = 3,
        padding: Double = 1,
        paddingOuter: Double = 3,
        minTile: Double = 5,
        maxChildren: Int = 96,
        header: Double = 20,
        headerInner: Double = 15
    ) {
        self.maxDepth = maxDepth
        self.padding = padding
        self.paddingOuter = paddingOuter
        self.minTile = minTile
        self.maxChildren = maxChildren
        self.header = header
        self.headerInner = headerInner
    }
}

/// Lay out everything beneath `root` inside `area`, showing only what
/// `filter` keeps when there is one: its matches, at the size of what
/// matched, inside ancestors sized the same way.
///
/// `rootCrumbs` is where `root` sits in the scanned tree. Every tile's crumbs
/// extend it, so they always address the scanned tree, never the node being
/// drawn: a caller that resolves a tile from the scanned root gets that tile,
/// at any depth.
public func layout(
    _ root: Node,
    rootCrumbs: [Int],
    area: Rect,
    metric: Metric,
    options: LayoutOptions,
    filter: Matches? = nil
) -> [Tile] {
    var tiles: [Tile] = []
    var crumbs = rootCrumbs
    let place = Placement(metric: metric, options: options, filter: filter)
    placeChildren(
        root,
        area: area,
        place: place,
        depth: 0,
        crumbs: &crumbs,
        out: &tiles
    )
    return tiles
}

/// What stays the same for every level of one layout.
private struct Placement {
    var metric: Metric
    var options: LayoutOptions
    /// Set while the level being placed is inside a filtered region; a
    /// match clears it for everything beneath.
    var filter: Matches?
}

private func placeChildren(
    _ node: Node,
    area: Rect,
    place: Placement,
    depth: Int,
    crumbs: inout [Int],
    out: inout [Tile]
) {
    let (metric, options) = (place.metric, place.options)
    if node.children.isEmpty || area.w <= 0 || area.h <= 0 {
        return
    }

    // Rank by importance ourselves: the tree is already sorted, but a metric
    // switch or a hand-built tree must not produce a bad layout.
    var ranked: [(index: Int, value: Double)] = []
    for (index, child) in node.children.enumerated() {
        let value: UInt64
        if let filter = place.filter {
            crumbs.append(index)
            let keep = filter.keep(crumbs)
            crumbs.removeLast()
            guard let keep else {
                continue
            }
            value = Matches.value(keep, node: child, metric: metric)
        } else {
            value = child.value(metric)
        }
        if value > 0 {
            ranked.append((index, Double(value)))
        }
    }
    if ranked.isEmpty {
        return
    }
    // Ties keep the tree's order, so equal siblings never trade places
    // between two frames; `sort` does not promise that on its own.
    ranked.sort { left, right in
        left.value != right.value
            ? left.value > right.value : left.index < right.index
    }

    let kept = min(ranked.count, max(options.maxChildren, 0))
    var values = ranked[..<kept].map(\.value)
    var sources: [Int?] = ranked[..<kept].map(\.index)
    let tailCount = ranked.count - kept
    if tailCount > 0 {
        values.append(ranked[kept...].reduce(0) { $0 + $1.value })
        sources.append(nil)
    }

    for (slot, raw) in squarify(values, in: area).enumerated() {
        let rect = raw.inset(
            depth == 0 ? options.paddingOuter : options.padding
        )
        if rect.w < options.minTile || rect.h < options.minTile {
            continue
        }
        guard let index = sources[slot] else {
            out.append(
                Tile(
                    kind: .others(crumbs: crumbs, count: tailCount),
                    rect: rect,
                    depth: depth
                )
            )
            continue
        }

        let child = node.children[index]
        // A directory that only holds matches is opened past the depth
        // drawn: an applied filter shows the matches, and one deeper than
        // the depth would otherwise have no tile of its own to show.
        crumbs.append(index)
        let holdsMatches: Bool =
            if case .partial = place.filter?.keep(crumbs) {
                true
            } else {
                false
            }
        crumbs.removeLast()
        let subdividable =
            child.isDir && (depth + 1 < options.maxDepth || holdsMatches)
        // A directory that is about to be subdivided claims a header band for
        // its own name. When there is no room for one it stays whole: a name
        // drawn over its own children is worse than one level less of detail,
        // and zooming in gives it the room back.
        let header =
            subdividable
            ? headerBand(rect, options: options, depth: depth) : nil
        crumbs.append(index)
        out.append(
            Tile(
                kind: .node(crumbs: crumbs),
                rect: rect,
                depth: depth,
                header: header
            )
        )
        if let header {
            let body = Rect(
                x: rect.x,
                y: header.bottom,
                w: rect.w,
                h: rect.bottom - header.bottom
            )
            // Beneath a match everything is shown; above one, only matches.
            var inner = place
            if place.filter?.keep(crumbs) == .whole {
                inner.filter = nil
            }
            placeChildren(
                child,
                area: body,
                place: inner,
                depth: depth + 1,
                crumbs: &crumbs,
                out: &out
            )
        }
        crumbs.removeLast()
    }
}

/// The narrowest band worth reserving: about the narrowest the view writes a
/// name in at the default interface size (3.3 times its 12 point label type,
/// plus the label's padding). A thinner band would take the children's room
/// for a name that is never drawn.
private let minHeaderWidth = 44.0

/// The band a directory keeps for its name, or `nil` when the tile is too
/// small to leave its children a usable area below it.
///
/// The top level gets the full header; deeper directories a slimmer band.
private func headerBand(
    _ rect: Rect,
    options: LayoutOptions,
    depth: Int
) -> Rect? {
    let height = depth == 0 ? options.header : options.headerInner
    let body = rect.h - height
    // Less than three minimum tiles of body leaves the children a strip too
    // thin to read or hit; the tile says more drawn whole.
    if rect.w < minHeaderWidth || body < options.minTile * 3 {
        return nil
    }
    return Rect(x: rect.x, y: rect.y, w: rect.w, h: height)
}

/// Split `area` into one rectangle per value, proportional to it.
///
/// Returned in the order of `values`, not in layout order.
public func squarify(_ values: [Double], in area: Rect) -> [Rect] {
    var rects = Array(repeating: Rect.zero, count: values.count)
    let total = values.filter { $0 > 0 }.reduce(0, +)
    if total <= 0 || area.w <= 0 || area.h <= 0 {
        return rects
    }

    // Largest first, ties in the order given, so the same values always
    // produce the same mosaic.
    let order = values.indices.filter { values[$0] > 0 }
        .sorted { left, right in
            values[left] != values[right]
                ? values[left] > values[right] : left < right
        }

    let scale = area.w * area.h / total
    let areas = order.map { values[$0] * scale }

    var free = area
    var start = 0
    while start < areas.count {
        let side = min(free.w, free.h)
        var end = start + 1
        var rowSum = areas[start]
        var rowWorst = worstRatio(
            areas[start..<end],
            rowSum: rowSum,
            side: side
        )

        while end < areas.count {
            let candidateSum = rowSum + areas[end]
            let candidateWorst = worstRatio(
                areas[start...end],
                rowSum: candidateSum,
                side: side
            )
            if candidateWorst > rowWorst {
                break
            }
            rowSum = candidateSum
            rowWorst = candidateWorst
            end += 1
        }

        if free.w >= free.h {
            // A vertical strip on the left; tiles stack top to bottom.
            let stripW = min(rowSum / free.h, free.w)
            var y = free.y
            for index in start..<end {
                let height = stripW > 0 ? areas[index] / stripW : 0
                let clamped = max(min(height, free.bottom - y), 0)
                rects[order[index]] = Rect(
                    x: free.x, y: y, w: stripW, h: clamped)
                y += clamped
            }
            free.x += stripW
            free.w -= stripW
        } else {
            // A horizontal strip along the top; tiles run left to right.
            let stripH = min(rowSum / free.w, free.h)
            var x = free.x
            for index in start..<end {
                let width = stripH > 0 ? areas[index] / stripH : 0
                let clamped = max(min(width, free.right - x), 0)
                rects[order[index]] = Rect(
                    x: x, y: free.y, w: clamped, h: stripH)
                x += clamped
            }
            free.y += stripH
            free.h -= stripH
        }
        start = end
    }
    return rects
}

/// Worst (largest) aspect ratio in a row of `areas` laid along `side`.
private func worstRatio(
    _ areas: ArraySlice<Double>,
    rowSum: Double,
    side: Double
) -> Double {
    if rowSum <= 0 || side <= 0 {
        return .infinity
    }
    let thickness = rowSum / side
    return areas.reduce(0) { worst, area in
        if area <= 0 || thickness <= 0 {
            return worst
        }
        let other = area / thickness
        return max(worst, thickness / other, other / thickness)
    }
}

/// The deepest tile containing a point.
///
/// Children are emitted after their parent and are inset inside it, so the
/// last match — the first in reverse order — is the most specific one.
public func hit(_ tiles: [Tile], x: Double, y: Double) -> Tile? {
    tiles.last { $0.rect.contains(x: x, y: y) }
}
