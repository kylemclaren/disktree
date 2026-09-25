// The view: how many levels the mosaic draws, what its areas measure and its
// colours say, and the size of the whole interface. Zooming by hand, and the
// stops it meets, are `AppState+Zoom.swift`.
//
// The view transform is the only thing zoom changes (Invariant 8); depth,
// metric and interface zoom change the layout itself.

import DisktreeCore
import Foundation
import System

extension AppState {
    /// The tolerance a scale is compared with: what the Rust port's `f32`
    /// allowed, so a scale clamped to its ceiling counts as at it.
    static let scaleEpsilon = Double(Float.ulpOfOne)

    public func resetView() {
        view = .identity
        rehover()
    }

    /// Draw fewer or more levels at once (1 to 6): the other meaning of zoom
    /// in a treemap, seeing further in without changing what is on screen.
    public func adjustDepth(_ step: Int) {
        layoutOptions.maxDepth = min(max(layoutOptions.maxDepth + step, 1), 6)
        cache = nil
        rehover()
    }

    /// Weigh tiles by the other metric: bytes or files.
    ///
    /// Children are ordered by the metric, so every crumb moves. The
    /// directory on screen and the selection are found again by path, so
    /// the view stays where it was instead of landing on whatever now has
    /// the old index.
    ///
    /// A large tree is re-ranked off the main actor (`rankInPlaceLimit`):
    /// the window keeps the old order, whole and consistent, until the new
    /// one lands, and only the mode picker shows the switch meanwhile.
    public func toggleMetric() {
        let next = (pendingMetric ?? options.metric).toggled
        rankEpoch &+= 1
        clearFilter()
        // Switched back before the re-ranking landed: the tree on screen is
        // ranked so already.
        guard next != options.metric else {
            pendingMetric = nil
            return
        }
        guard let tree, tree.files &+ tree.dirs > rankInPlaceLimit else {
            pendingMetric = nil
            rankInPlace(by: next)
            return
        }
        pendingMetric = next
        let epoch = rankEpoch
        let generation = treeGeneration
        let limit = Self.insightLimit
        Task { @MainActor [weak self] in
            let ranked = await Task.detached(priority: .userInitiated) {
                var ranked = tree
                aggregate(&ranked, metric: next)
                let now = nowSeconds()
                let insights = worthALook(ranked, now: now, limit: limit)
                return Ranked(tree: ranked, insights: insights, at: now)
            }.value
            // A newer switch, or another tree on screen: this order is
            // nobody's. A tree that landed meanwhile is ranked again there.
            guard let self, epoch == self.rankEpoch,
                generation == self.treeGeneration
            else {
                return
            }
            self.pendingMetric = nil
            self.adoptRanking(ranked, metric: next)
        }
    }

    /// Re-rank the tree on the main actor: small enough not to be felt.
    private func rankInPlace(by metric: Metric) {
        let before = (currentPath, selected.flatMap { path(at: $0) })
        guard var tree else {
            options.metric = metric
            refreshInsights()
            cache = nil
            return
        }
        // Let the copy be the only owner, so the re-sort happens in place
        // instead of duplicating the whole tree first.
        self.tree = nil
        aggregate(&tree, metric: metric)
        let now = nowSeconds()
        adoptRanking(
            Ranked(
                tree: tree,
                insights: worthALook(tree, now: now, limit: Self.insightLimit),
                at: now
            ),
            metric: metric,
            before: before
        )
    }

    /// Put a re-ranked tree on screen, with the directory drawn and the
    /// selection found again by path. `before` is where they were, when the
    /// tree they were in is no longer on screen to ask.
    private func adoptRanking(
        _ ranked: Ranked,
        metric: Metric,
        before: (here: FilePath, chosen: FilePath?)? = nil
    ) {
        let here = before?.here ?? currentPath
        let chosen = before.map(\.chosen) ?? selected.flatMap { path(at: $0) }
        options.metric = metric
        replaceTree(with: ranked.tree)
        crumbs = crumbs(for: here) ?? []
        selected = chosen.flatMap { crumbs(for: $0) }
        forgetHover()
        scannedAt = ranked.at
        insights = ranked.insights
        // Matches name the old order's crumbs.
        clearFilter()
        cache = nil
    }

    /// The Size | Files | Age choice: what areas measure, and what colour
    /// says. Age keeps areas by size, since age has no area of its own.
    public func setMode(_ index: Int) {
        let (metric, color): (Metric, ColorMode) =
            switch index {
            case 1: (.files, .kind)
            case 2: (.bytes, .age)
            default: (.bytes, .kind)
            }
        colorMode = color
        if (pendingMetric ?? options.metric) != metric {
            toggleMetric()
        }
    }

    /// The Size | Files | Age choice currently on: 0, 1 or 2. A switch
    /// still being ranked shows as made.
    public var modeIndex: Int {
        switch (colorMode, pendingMetric ?? options.metric) {
        case (.age, _): 2
        case (.kind, .files): 1
        case (.kind, .bytes): 0
        }
    }

    /// `⌘=`/`⌘-`/`⌘0` (and ctrl, as on Linux): interface zoom. Changes the
    /// rem, which every size in this app is expressed in, so hierarchy and
    /// spacing keep their proportions at every step. Returns whether the
    /// key was one of them.
    @discardableResult
    public func zoomInterface(_ key: KeyStroke) -> Bool {
        guard key.control || key.command else {
            return false
        }
        let next: Int
        switch key.key {
        case "=", "+": next = min(zoomStep + 1, zoomSteps.count - 1)
        case "-": next = max(zoomStep - 1, 0)
        case "0": next = defaultZoomStep
        default: return false
        }
        assign(\.zoomStep, next)
        // The header band is in rem, so the layout follows; the key would
        // change on its own, and this says so where it happens.
        cache = nil
        return true
    }
}

/// A tree re-ranked by another metric, and what "worth a look" found in it,
/// whose crumbs are that order's.
struct Ranked: Sendable {
    var tree: Node
    var insights: [Candidate]
    /// When the findings were made: the "now" ages are measured from.
    var at: Int64
}
