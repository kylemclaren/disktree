// Where the treemap is: the tree and the directory drawn, the trail and its
// sibling menus, and every move from one directory or tile to another.
//
// Crumbs are absolute: child indices from the scanned root, whatever
// directory is drawn (Invariant 7). Anything that turns a path into crumbs
// walks from the scanned root too.

import DisktreeCore
import System

extension AppState {
    // MARK: The tree

    /// The node the treemap is currently rooted at.
    public var current: Node? {
        tree?.resolve(crumbs)
    }

    public func node(at crumbs: [Int]) -> Node? {
        tree?.resolve(crumbs)
    }

    public func path(at crumbs: [Int]) -> FilePath? {
        guard let tree else {
            return nil
        }
        return pathOf(rootPath: rootPath, root: tree, crumbs: crumbs)
    }

    /// Path of the directory currently drawn.
    public var currentPath: FilePath {
        path(at: crumbs) ?? rootPath
    }

    /// `disktree · ~/path`: the window title, in step with the directory on
    /// screen.
    public var windowTitle: String {
        "disktree · " + displayPath(currentPath, home: home)
    }

    /// The trail, from `/`: the directories above the scanned root, which
    /// widen the scan, then the root and the path into the tree.
    public func breadcrumbs() -> [TrailStep] {
        var above: [FilePath] = []
        var path = rootPath
        while !path.isEmpty {
            let parent = path.removingLastComponent()
            // `/` is its own parent.
            if parent == path {
                break
            }
            above.append(parent)
            path = parent
        }
        var trail = above.reversed().map {
            TrailStep(label: crumbLabel($0), crumb: .above($0))
        }
        trail.append(TrailStep(label: crumbLabel(rootPath), crumb: .tree([])))
        guard var node = tree else {
            return trail
        }
        var walked: [Int] = []
        for index in crumbs {
            guard let child = node.child(at: index) else {
                break
            }
            walked.append(index)
            trail.append(TrailStep(label: child.name, crumb: .tree(walked)))
            node = child
        }
        return trail
    }

    /// The children of `parent`, largest first, for a sibling menu, and how
    /// many more there are beyond `siblingRows`.
    public func siblings(_ parent: [Int]) -> (rows: [Sibling], more: Int) {
        let metric = options.metric
        guard let node = node(at: parent) else {
            return ([], 0)
        }
        var rows = node.children.enumerated().map { index, child in
            Sibling(
                index: index,
                name: child.name,
                value: child.value(metric),
                category: child.category,
                isDir: child.isDir
            )
        }
        // Equal ones keep the tree's order, as the stable sort they were
        // ranked with in Rust did.
        rows.sort { left, right in
            left.value != right.value
                ? left.value > right.value : left.index < right.index
        }
        let more = max(rows.count - siblingRows, 0)
        return (Array(rows.prefix(siblingRows)), more)
    }

    /// Crumbs for an absolute path, if the tree still contains it. Walks
    /// from the scanned root (Invariant 7).
    public func crumbs(for path: FilePath) -> [Int]? {
        guard let tree else {
            return nil
        }
        return Self.crumbs(for: path, rootPath: rootPath, in: tree)
    }

    /// `crumbs(for:)` against a tree in hand, so a frame that resolves every
    /// mark reads the observed tree once.
    nonisolated static func crumbs(
        for path: FilePath,
        rootPath: FilePath,
        in tree: Node
    ) -> [Int]? {
        // The path is relative to the scanned root, so the walk starts
        // there, not at the directory currently drawn.
        var relative = path
        guard relative.removePrefix(rootPath) else {
            return nil
        }
        var node = tree
        var crumbs: [Int] = []
        for component in relative.components {
            // Byte for byte, as the filesystem stores names; the length
            // first, which turns most of a long listing away for free.
            let name = component.string.utf8
            guard
                let index = node.children.firstIndex(where: {
                    $0.name.utf8.count == name.count
                        && $0.name.utf8.elementsEqual(name)
                })
            else {
                return nil
            }
            crumbs.append(index)
            node = node.children[index]
        }
        return crumbs
    }

    // MARK: The trail's menus

    /// Go to a sibling, from a step's menu of the folders beside it: into
    /// it when it is a directory, beside it (selected) when it is a file.
    /// The menu is the system's, built from the tree each time it opens,
    /// so it never lists what a new tree has renumbered.
    public func chooseSibling(parent: [Int], index: Int) {
        let crumbs = parent + [index]
        if node(at: crumbs)?.isDir == true {
            goTo(crumbs)
        } else {
            reveal(crumbs)
        }
    }

    // MARK: Moving between directories

    /// Descend into the selected tile, or into the largest child of the
    /// current root when nothing is selected.
    public func descend() {
        let target: [Int]
        if let selected, selected.count > crumbs.count {
            // Enter what is selected, however deep: a directory opens
            // itself, a file opens the directory holding it.
            target =
                node(at: selected)?.isDir == true
                ? selected : Array(selected.dropLast())
        } else if let index = current?.largestChild {
            // Nothing below the root is selected: the largest entry.
            target = crumbs + [index]
        } else {
            return
        }
        let from = tileBody(target).map { view.project($0) }
        enter(target, from: from)
    }

    /// Make `target` — any directory below the current root — the root.
    ///
    /// `from` is where that directory's contents were on screen, so the
    /// transition grows them from exactly there into the full viewport.
    func enter(_ target: [Int], from: Rect?) {
        guard target.count > crumbs.count, target.starts(with: crumbs),
            let node = node(at: target), node.isDir, !node.children.isEmpty
        else {
            return
        }
        selected = target
        crumbs = target
        forgetHover()
        cache = nil
        let area = treemapSize
        let src = from ?? view.visibleBase(area)
        view = .identity
        let dst = Rect(
            x: 0,
            y: 0,
            w: max(Double(area.width), 1),
            h: max(Double(area.height), 1)
        )
        transition = LayoutTransition(src: src, dst: dst)
        lapseFilter()
    }

    /// Ascend to the parent directory, keeping the directory we came from in
    /// view so the motion reads as zooming out.
    public func ascend() {
        guard let parent = parentCrumbs else {
            return
        }
        leave(to: parent)
    }

    /// Go up to `ancestor`, any directory above the current root, keeping
    /// the directory we came from in view: `ascend` one level, or a smart
    /// zoom's way back over several.
    func leave(to ancestor: [Int]) {
        guard ancestor.count < crumbs.count, crumbs.starts(with: ancestor)
        else {
            return
        }
        // The region we are looking at now, and where it sits in the layout
        // we are going back to.
        let area = treemapSize
        let child = crumbs
        let src = view.visibleBase(area)
        crumbs = ancestor
        forgetHover()
        cache = nil
        selected = ancestor
        view = .identity
        // Several levels up, the directory we left may be drawn too deep to
        // have a tile; then the motion shrinks into the deepest one of its
        // ancestors that is drawn.
        let landing = stride(
            from: child.count,
            through: ancestor.count + 1,
            by: -1
        )
        .lazy
        .compactMap { self.tileBody(Array(child.prefix($0))) }
        .first
        transition =
            landing
            .flatMap { $0.w > 1 && $0.h > 1 ? $0 : nil }
            .map { LayoutTransition(src: src, dst: $0) }
        lapseFilter()
    }

    /// The crumbs of the parent of the current root, if any.
    public var parentCrumbs: [Int]? {
        crumbs.isEmpty ? nil : Array(crumbs.dropLast())
    }

    /// Jump straight to a crumb from the trail.
    ///
    /// A jump can skip several levels, so there is no single region to
    /// move: it lands immediately, the way selecting a folder does.
    public func goTo(_ crumbs: [Int]) {
        self.crumbs = crumbs
        selected = crumbs
        forgetHover()
        view = .identity
        transition = nil
        cache = nil
        lapseFilter()
    }

    /// Show `crumbs` in its directory, selected: what a "worth a look" row
    /// or a found name does.
    public func reveal(_ crumbs: [Int]) {
        goTo(Array(crumbs.dropLast()))
        selected = crumbs
        pointerActive = false
    }

    /// A filter is about the directory it was typed in: above it, it would
    /// hide everything beside that directory, so it lapses. Checked wherever
    /// the directory on screen changes, never while drawing.
    func lapseFilter() {
        if let matches, !crumbs.starts(with: matches.base) {
            clearFilter()
        }
    }

    // MARK: The selection

    /// Select the tile at `crumbs` without changing the root.
    public func select(_ crumbs: [Int]?) {
        selected = crumbs
    }

    /// The tile a key acts on: under the pointer if the pointer moved last,
    /// otherwise the keyboard selection.
    public var actionTarget: [Int]? {
        pointerActive ? hovered ?? selected : selected
    }

    /// Make the pointed-at tile the selection before a key acts, so marking,
    /// opening and arrow movement all start from what the user is looking
    /// at.
    func adoptPointerTarget() {
        // Hit again where the pointer rests: whatever changed the layout
        // since it last moved, the key acts on what is under it now.
        rehover()
        if pointerActive, let hovered {
            selected = hovered
        }
    }

    /// After the layout changes under a still pointer, its hover is stale
    /// until the pointer moves again.
    func forgetHover() {
        assign(\.hovered, nil)
        assign(\.hoveredTail, nil)
        assign(\.pointerActive, false)
    }

    /// Move the selection geometrically, falling back to the parent at an
    /// edge.
    public func moveSelection(_ direction: Direction) {
        assign(\.pointerActive, false)
        // Merged tails carry their directory's crumbs: stepping onto one
        // would select that directory from somewhere it is not.
        guard
            let tiles = layout()?.filter({
                if case .node = $0.kind { true } else { false }
            })
        else {
            return
        }
        // Nothing selected, or no tile for what is — the directory drawn,
        // which Enter, Backspace and the trail leave selected, or a level
        // too deep to be drawn: an arrow starts at this level's first tile.
        guard let current = selected,
            let from = tiles.first(where: { $0.crumbs == current })
        else {
            let level = crumbs.count + 1
            if let first = tiles.first(where: { $0.crumbs.count == level }) {
                select(first.crumbs)
            }
            return
        }
        let view = self.view
        let origin = view.project(from.rect)

        // Same-depth neighbours only: stepping into a child by arrow key
        // would make the depth of the selection impossible to predict.
        let depth = current.count
        var best: (score: Double, crumbs: [Int])?
        for tile in tiles {
            let crumbs = tile.crumbs
            if crumbs.count != depth || crumbs == current {
                continue
            }
            let rect = view.project(tile.rect)
            guard let gap = direction.gap(from: origin, to: rect) else {
                continue
            }
            // Off-axis distance weighs more than distance along the axis:
            // the tile straight ahead beats a nearer one off to the side.
            let score = direction.offset(from: origin, to: rect) * 2.5 + gap
            // Strictly better only, so of two equal candidates the first in
            // layout order wins, every time.
            if best.map({ score < $0.score }) ?? true {
                best = (score, crumbs)
            }
        }

        if let best {
            select(best.crumbs)
        } else if direction.isBackwards, let parent = parentCrumbs {
            select(parent)
        }
    }

    /// Select the next sibling by rank, which is next-largest by the active
    /// metric. Scanning a directory for space is exactly this walk.
    public func cycleSibling(_ step: Int) {
        assign(\.pointerActive, false)
        let siblings = rankedSiblings()
        guard !siblings.isEmpty else {
            return
        }
        let position = selected.flatMap { siblings.firstIndex(of: $0) }
        let next: Int
        if let position {
            let count = siblings.count
            next = ((position + step) % count + count) % count
        } else {
            next = step >= 0 ? 0 : siblings.count - 1
        }
        select(siblings[next])
    }

    /// The selection's siblings, in the tree's order: largest first.
    private func rankedSiblings() -> [[Int]] {
        let parent: [Int] =
            if let selected, selected.count > crumbs.count {
                Array(selected.dropLast())
            } else {
                crumbs
            }
        guard let node = node(at: parent) else {
            return []
        }
        return node.children.indices.map { parent + [$0] }
    }
}

/// A trail step's label: the directory's own name, or `/` for the root.
private func crumbLabel(_ path: FilePath) -> String {
    path.lastComponent?.string ?? path.string
}
