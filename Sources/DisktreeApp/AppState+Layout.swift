// Layout and hit-testing: the tiles for the directory drawn, and everything
// one frame of the mosaic needs, resolved before painting.
//
// Layout runs in base-space points and is cached (Invariant 8); the view
// transform is applied while painting. Both `layout()` and `prepare()` run
// while the treemap draws, inside the observation tracking that schedules
// its next frame, so neither may change anything a view observes: the cache
// they fill is `@ObservationIgnored`, and every decision that changes state
// — a filter lapsing, a transition ending — is taken where the state
// changes, not here.

import DisktreeCore
import Foundation

extension AppState {
    /// How many labels one frame will shape.
    static let maxLabels = 150

    /// Height of a top-level directory's name band, in rem: 22 points at the
    /// default rem, scaled so zoom keeps the band's relationship to the
    /// label inside it.
    static let headerRems = 1.375

    /// Height of the slim label row a deeper open directory keeps, in rem:
    /// 18 points at the default rem. Room for a 12-point name's
    /// descenders: at one rem, the "g" of "arm64-apple-macosx" and the "y"
    /// of "Telemetry" were cut off at the band's bottom edge.
    static let headerInnerRems = 1.125

    /// Smallest tile, in rem, that gets a label: below this a name cannot
    /// be read.
    static let labelMinWidthRems = 3.375
    static let labelMinHeightRems = 0.9375

    /// `layoutOptions` with the header bands scaled by the current rem,
    /// which is what the layout actually runs with.
    public var effectiveLayoutOptions: LayoutOptions {
        var options = layoutOptions
        let rem = Double(self.rem)
        options.header = Self.headerRems * rem
        options.headerInner = Self.headerInnerRems * rem
        return options
    }

    /// Tiles for the current root and treemap size, computed once per
    /// change. Must not mutate observed state: it runs while drawing.
    public func layout() -> [Tile]? {
        // Every input is read before the cache is consulted, so a view that
        // draws inside observation tracking hears about a change to any of
        // them, and not only to those a cache miss happened to read.
        let tree = self.tree
        let filter = filterApplied ? matches : nil
        let metric = options.metric
        let area = treemapSize
        let key = LayoutKey(
            crumbs: crumbs,
            width: Double(area.width).rounded(),
            height: Double(area.height).rounded(),
            options: effectiveLayoutOptions,
            filter: filterEpoch
        )
        guard key.width >= 1, key.height >= 1 else {
            return nil
        }
        if let cache, cache.key == key {
            return cache.tiles
        }
        guard let node = tree?.resolve(key.crumbs) else {
            return nil
        }
        let tiles = DisktreeCore.layout(
            node,
            rootCrumbs: key.crumbs,
            area: Rect(x: 0, y: 0, w: key.width, h: key.height),
            metric: metric,
            options: key.options,
            filter: filter
        )
        cache = LayoutCache(key: key, tiles: tiles)
        return tiles
    }

    /// Base-space rect of the tile at `crumbs`, if it is currently drawn.
    public func tileRect(_ crumbs: [Int]) -> Rect? {
        drawnTile(crumbs)?.rect
    }

    /// The tile of the node at `crumbs`, if it is drawn. Never a merged
    /// tail: that carries its directory's crumbs, and for the directory
    /// drawn, whose own tile is the whole viewport and not in the layout,
    /// it would be the only tile that matched.
    func drawnTile(_ crumbs: [Int]) -> Tile? {
        layout()?.first { tile in
            if case .node(let own) = tile.kind { own == crumbs } else { false }
        }
    }

    /// Where a drawn directory's contents sit: its tile below the name band.
    /// This, not the whole tile, is the region its children occupy, so it is
    /// what a transition into or out of it has to map.
    public func tileBody(_ crumbs: [Int]) -> Rect? {
        guard let tile = drawnTile(crumbs) else {
            return nil
        }
        guard let header = tile.header else {
            return tile.rect
        }
        return Rect(
            x: tile.rect.x,
            y: header.bottom,
            w: tile.rect.w,
            h: tile.rect.bottom - header.bottom
        )
    }

    /// The deepest tile under a treemap-local point: what hovering reports
    /// and a click, a mark or the context menu act on.
    ///
    /// A merged "+N more" tail is nothing to act on. Its crumbs are its
    /// directory's, so answering with them would mark, open or hand over
    /// that whole directory — the large entries beside the tail included —
    /// from a tile that stands only for the small ones.
    public func tile(atX x: Double, y: Double) -> [Int]? {
        guard let tile = hitTile(x: x, y: y), case .node(let crumbs) = tile.kind
        else {
            return nil
        }
        return crumbs
    }

    /// The deepest tile under a treemap-local point, a merged tail included.
    func hitTile(x: Double, y: Double) -> Tile? {
        let base = view.unproject(x: x, y: y)
        guard let tiles = layout() else {
            return nil
        }
        return hit(tiles, x: base.x, y: base.y)
    }

    /// What the merged tail of the directory at `crumbs` stands for: the
    /// `count` entries the layout left out of its own tiles, and what they
    /// weigh together.
    ///
    /// The layout keeps the largest children, by the metric or by what the
    /// applied filter keeps of them, and merges the rest, so the tail is
    /// the smallest `count` of the same values.
    func mergedTail(of crumbs: [Int], count: Int) -> HoveredTail? {
        guard count > 0, let node = node(at: crumbs) else {
            return nil
        }
        let metric = options.metric
        let filter = filterApplied ? matches : nil
        var values: [UInt64] = []
        values.reserveCapacity(node.children.count)
        for (index, child) in node.children.enumerated() {
            let value: UInt64
            if let filter {
                guard let keep = filter.keep(crumbs + [index]) else {
                    continue
                }
                value = Matches.value(keep, node: child, metric: metric)
            } else {
                value = child.value(metric)
            }
            // A layout draws nothing that weighs nothing, merged or not.
            if value > 0 {
                values.append(value)
            }
        }
        values.sort()
        // A part of the directory's own total, so it fits wherever that did.
        let total = values.prefix(count).reduce(0, +)
        return HoveredTail(crumbs: crumbs, count: count, value: total)
    }

    /// The deepest drawn directory under a viewport point that has contents
    /// to show: what zooming at that point is zooming into. Over a merged
    /// tail, that is the directory holding it: zooming there is looking
    /// closer at its small entries.
    func zoomTarget(x: Double, y: Double) -> [Int]? {
        guard let hovered = hitTile(x: x, y: y)?.crumbs else {
            return nil
        }
        let root = crumbs.count
        guard hovered.count > root else {
            return nil
        }
        for length in stride(from: hovered.count, through: root + 1, by: -1) {
            let candidate = Array(hovered.prefix(length))
            if let node = node(at: candidate), node.isDir,
                !node.children.isEmpty, tileBody(candidate) != nil
            {
                return candidate
            }
        }
        return nil
    }

    /// Resolve everything the mosaic needs for this frame. Must not mutate
    /// observed state: it runs while drawing.
    ///
    /// Painting then only has to draw: the marked, covered, filtered and
    /// selected state of every tile is decided here, where the tree and the
    /// marks are both at hand. `now` is the instant the frame shows, so a
    /// transition is sampled once for all of it.
    public func prepare(now: ContinuousClock.Instant = .now) -> Mosaic {
        let view = self.view
        guard let tiles = layout(), let tree else {
            return Mosaic(view: view)
        }
        let metric = options.metric
        let hovered = self.hovered
        let selected = self.selected
        let matches = self.matches
        let focus = self.legendFocus
        let rem = Double(self.rem)
        let ageNow: Int64? = colorMode == .age ? scannedAt : nil
        let motion = transition.flatMap { $0.motion(at: now) }
        func animated(_ rect: Rect) -> Rect {
            motion?.apply(rect) ?? rect
        }

        // Marks are paths; the mosaic thinks in crumbs. Resolve once per
        // frame rather than building a path for every tile. Slices, so a
        // tile's ancestors can be looked up without copying its crumbs.
        var marked = Set<ArraySlice<Int>>()
        for item in marks.items {
            if let crumbs = Self.crumbs(
                for: item.path,
                rootPath: rootPath,
                in: tree
            ) {
                marked.insert(crumbs[...])
            }
        }

        // The directory drawn goes with a mark: said once, by the legend,
        // and every tile keeps its kind, tinted (`Mosaic.insideMark`).
        let insideMark =
            !marked.isEmpty
            && (0...crumbs.count).contains { marked.contains(crumbs[..<$0]) }

        // Hue comes from the node's kind; lightness from its depth in this
        // view, so the first level always reads as the first level.
        var walker = NodeWalker(root: tree)
        var decorations: [TileDeco] = []
        decorations.reserveCapacity(tiles.count)
        var candidates: [LabelCandidate] = []
        for (index, tile) in tiles.enumerated() {
            let crumbs = tile.crumbs
            let node: Node? =
                switch tile.kind {
                case .node: walker.node(at: crumbs)
                case .others: nil
                }
            let bucket: Int? =
                if let ageNow, let node, node.modified > 0 {
                    ageBucket(days: (ageNow - node.modified) / 86_400)
                } else {
                    nil
                }
            let filtered: Filtered =
                if let matches {
                    switch matches.keep(crumbs) {
                    case .some(.whole): .shown
                    case .some(.partial): .holds
                    case nil: .out
                    }
                } else if let focus {
                    // The legend's key under the pointer: its kind stays,
                    // the rest steps back as a find's misses do.
                    Self.stands(node, bucket: bucket, for: focus)
                        ? .shown : .out
                } else {
                    .shown
                }
            // A merged tail carries its directory's crumbs but is not that
            // directory: it is never the one marked, hovered or selected,
            // and it sits inside the directory its crumbs name.
            let isTail: Bool =
                switch tile.kind {
                case .node: false
                case .others: true
                }
            let isMarked = !isTail && marked.contains(crumbs[...])
            // Everything inside a marked directory goes with it, so it is
            // drawn marked too.
            let ancestors = isTail ? crumbs.count + 1 : crumbs.count
            let isCovered =
                !marked.isEmpty && ancestors > 1
                && (1..<ancestors).contains {
                    marked.contains(crumbs[..<$0])
                }
            let drawn = animated(tile.rect)
            decorations.append(
                TileDeco(
                    rect: drawn,
                    depth: tile.depth,
                    category: node?.category ?? .other,
                    ageBucket: bucket,
                    reclaimable: node?.reclaim != nil,
                    filtered: filtered,
                    unreadable: node?.readError ?? false,
                    marked: isMarked,
                    covered: isCovered,
                    hovered: !isTail && hovered == crumbs,
                    selected: !isTail && selected == crumbs
                )
            )

            // Labels are chosen in screen space: zooming in makes room for
            // more of them, which is the point of zooming in.
            let screen = view.project(tile.header.map(animated) ?? drawn)
            guard screen.w >= Self.labelMinWidthRems * rem,
                screen.h >= Self.labelMinHeightRems * rem
            else {
                continue
            }
            if case .node = tile.kind, node == nil {
                continue
            }
            candidates.append(
                LabelCandidate(
                    tile: index,
                    rect: drawn,
                    node: node,
                    filtered: filtered,
                    // Inside a mark, a name inside it is set as any other:
                    // the whole screen goes with the mark, and the legend
                    // says so.
                    marked: isMarked || (isCovered && !insideMark)
                )
            )
        }

        // The largest first, and ties in layout order, so the same frame
        // always shapes the same labels. Only the ones kept are spelled out:
        // a size is a formatted string, and most candidates never show.
        candidates.sort { left, right in
            let (lhs, rhs) = (
                left.rect.w * left.rect.h, right.rect.w * right.rect.h
            )
            return lhs != rhs ? lhs > rhs : left.tile < right.tile
        }
        let labels = candidates.prefix(Self.maxLabels).map { candidate in
            let tile = tiles[candidate.tile]
            switch tile.kind {
            case .node:
                let node = candidate.node
                return TileLabel(
                    text: node?.name ?? "",
                    rect: candidate.rect,
                    header: tile.header.map(animated),
                    depth: tile.depth,
                    dim: candidate.filtered == .out,
                    marked: candidate.marked,
                    sizeText: node.map { shortValue($0, metric: metric) }
                        ?? "",
                    isFile: node.map { !$0.isDir } ?? false
                )
            case .others(_, let count):
                return TileLabel(
                    text: "+\(count) more",
                    rect: candidate.rect,
                    header: nil,
                    depth: tile.depth,
                    dim: matches != nil,
                    marked: candidate.marked,
                    sizeText: ""
                )
            }
        }

        return Mosaic(
            tiles: decorations,
            labels: labels,
            view: view,
            insideMark: insideMark
        )
    }

    /// Whether a tile for `node`, of age `bucket`, is what the legend key
    /// `focus` stands for. A merged tail stands for nothing.
    nonisolated static func stands(
        _ node: Node?,
        bucket: Int?,
        for focus: LegendFocus
    ) -> Bool {
        guard let node else { return false }
        return switch focus {
        case .reclaimable: node.reclaim != nil
        case .kind(let category): node.category == category
        case .age(let age): bucket == age
        }
    }

    /// Advance the layout transition. Returns whether another frame is
    /// needed; clears the transition once it has landed.
    @discardableResult
    public func tickTransition(now: ContinuousClock.Instant = .now) -> Bool {
        guard let transition else {
            return false
        }
        if transition.sample(.zero, at: now).running {
            return true
        }
        self.transition = nil
        return false
    }
}

/// A tile that is large enough on screen for its name, waiting to be ranked.
private struct LabelCandidate {
    /// Its index in the layout, the tie-break.
    var tile: Int
    /// Where it is drawn this frame.
    var rect: Rect
    var node: Node?
    var filtered: Filtered
    var marked: Bool
}

/// Resolves tile after tile from the one before. The layout emits a
/// directory right before what is inside it, so consecutive tiles share
/// most of their crumbs, and only what differs is walked: resolving each
/// from the scanned root would copy every node on the way, per tile, per
/// frame of a transition.
struct NodeWalker {
    /// `chain[k]` is the node at the first `k` of `crumbs`: one more than
    /// there are crumbs, the root first.
    private var chain: [Node]
    private var crumbs: [Int] = []

    init(root: Node) {
        chain = [root]
    }

    mutating func node(at target: [Int]) -> Node? {
        var shared = 0
        let limit = min(crumbs.count, target.count)
        while shared < limit, crumbs[shared] == target[shared] {
            shared += 1
        }
        crumbs.removeSubrange(shared...)
        chain.removeSubrange((shared + 1)...)
        for index in target[shared...] {
            guard let child = chain[chain.count - 1].child(at: index) else {
                return nil
            }
            chain.append(child)
            crumbs.append(index)
        }
        return chain[chain.count - 1]
    }
}

/// A transition as one frame sees it: `LayoutTransition.sample` with the
/// easing worked out once, since every tile and label of a frame is drawn
/// at the same instant.
struct Motion {
    var transition: LayoutTransition
    var eased: Double

    func apply(_ rect: Rect) -> Rect {
        let from = transition.origin(of: rect)
        func lerp(_ a: Double, _ b: Double) -> Double { (b - a) * eased + a }
        return Rect(
            x: lerp(from.x, rect.x),
            y: lerp(from.y, rect.y),
            w: lerp(from.w, rect.w),
            h: lerp(from.h, rect.h)
        )
    }
}

extension LayoutTransition {
    /// The frame at `now`, or `nil` once the transition has landed and
    /// tiles are drawn where they are. The same easing as `sample`.
    func motion(at now: ContinuousClock.Instant) -> Motion? {
        let elapsed = (now - started) / duration
        if elapsed >= 1 {
            return nil
        }
        // Ease out: fast at first, settling into place.
        return Motion(transition: self, eased: 1 - pow(1 - max(elapsed, 0), 3))
    }
}
