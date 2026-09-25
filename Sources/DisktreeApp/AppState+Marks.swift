// Marking: what a mark covers, what it refuses, and the plan the review
// screen shows.
//
// Marking is never destructive. A mark is a path (Invariant 5) and a
// promise to show it in the review; nothing on disk changes until the user
// takes the list to Finder or to a terminal.

import DisktreeCore
import System

extension AppState {
    /// Mark or unmark the current selection.
    public func toggleMarkSelected() {
        guard let crumbs = selected else {
            return
        }
        toggleMark(crumbs)
    }

    /// Space and X: mark or unmark the selected tile. The directory drawn,
    /// which Enter, Backspace and the trail leave selected, is not one: it
    /// is marked from its parent's view, where it is a tile, as the panel
    /// says. Marking it from inside would take everything on screen, and
    /// refuse every mark in it after.
    func markSelectedTile() {
        guard let selected else {
            return
        }
        if selected == crumbs, !crumbs.isEmpty {
            notice = Notice(
                "\(displayPath(currentPath, home: home)) is the directory on "
                    + "screen: mark it from its parent, or pick a tile in it",
                status: .warning
            )
            return
        }
        toggleMark(selected)
    }

    /// Mark or unmark the node at `crumbs`. Returns whether a mark went on
    /// or came off, so a pointer that asked can be answered with a feel; a
    /// refusal changes nothing and says why in the notice.
    ///
    /// A mark covers everything beneath it, since removing a directory takes
    /// its contents with it: marking a directory absorbs the marks already
    /// inside it, and a path inside a marked directory cannot be marked or
    /// kept on its own — it says which mark it goes with instead.
    ///
    /// The scanned root is refused here, whatever asked: a mark on it would
    /// absorb every other mark, and the plan keeps the root back, so the
    /// whole list would be lost to a mark that can never be handed over.
    @discardableResult
    public func toggleMark(_ crumbs: [Int]) -> Bool {
        if crumbs.isEmpty {
            notice = Notice(
                "the scanned root cannot be removed; open a directory first",
                status: .warning
            )
            return false
        }
        guard let target = target(at: crumbs) else {
            return false
        }
        // A mark is a path (Invariant 5), and this one names another entry,
        // or none: it could only ever be kept back, and would read as gone.
        if isLossy(target.path), !marks.contains(target.path) {
            notice = Notice(
                "\(displayPath(target.path, home: home)): its name is not "
                    + "UTF-8, so disktree cannot name it: remove it in Finder",
                status: .warning
            )
            return false
        }
        notice = nil
        if !marks.contains(target.path),
            let ancestor = markedAncestor(of: target.path)
        {
            notice = Notice(
                "\(displayPath(target.path, home: home)) goes with the marked "
                    + "\(displayPath(ancestor, home: home)); "
                    + "unmark that to keep it",
                status: .warning
            )
            return false
        }
        let path = target.path
        guard marks.toggle(target) else {
            marksChanged()
            return true
        }
        // What "freed so far" is measured from: the disk as it was when the
        // first mark went on, not the marked sum (Invariant 9).
        if spaceBaseline == nil {
            spaceBaseline = space
        }
        let inside = marks.items.map(\.path).filter {
            $0 != path && $0.starts(with: path)
        }
        for inner in inside {
            marks.remove(inner)
        }
        if !inside.isEmpty {
            notice = Notice(
                "\(displayPath(path, home: home)) now covers \(inside.count) "
                    + "mark\(inside.count == 1 ? "" : "s") inside it",
                status: .neutral
            )
            marksChanged()
        }
        return true
    }

    /// The marked directory `path` is inside, if any; never `path` itself.
    public func markedAncestor(of path: FilePath) -> FilePath? {
        marks.items
            .map(\.path)
            .filter { $0 != path && path.starts(with: $0) }
            // The outermost: that is the mark it goes with.
            .min { $0.components.count < $1.components.count }
    }

    /// The mark the node at `crumbs` would be: its bytes, whatever the
    /// mosaic is ranked by, since that is what the projection sums
    /// (Invariant 9).
    public func target(at crumbs: [Int]) -> Target? {
        guard let node = node(at: crumbs), let path = path(at: crumbs) else {
            return nil
        }
        return Target(
            path: path,
            bytes: node.bytes,
            isDir: node.isDir,
            hidden: isHidden(path)
        )
    }

    public func unmark(_ path: FilePath) {
        marks.remove(path)
        marksChanged()
    }

    public func clearMarks() {
        marks.clear()
        notice = nil
        marksChanged()
    }

    /// The plan the review screen shows: every mark, with the guards'
    /// verdicts. Kept until the marks, the root or what is gone changes
    /// (`handOver()`).
    public func plan() -> Plan {
        handOver().plan
    }

    /// What the copied command and Finder are given: `plan()` less the
    /// targets already gone from disk, which there is nothing left to do
    /// with.
    public func handOverPlan() -> Plan {
        handOver().live
    }

    /// The plan, worked out once for the marks, the root and what is gone
    /// as they are now. Views ask for it from `body`, over and over, and a
    /// fresh plan `lstat`s and `statfs`es every mark on the main actor.
    ///
    /// Reads each of them first, so a view that asks is redrawn when one of
    /// them changes; the memo itself is not observed.
    func handOver() -> HandOverMemo {
        let marked = marks.items
        let root = rootPath
        let gone = self.gone
        if let memo = handOverMemo, memo.marks == marked, memo.root == root,
            memo.gone == gone
        {
            return memo
        }
        let plan = DisktreeCore.plan(marked, root: root, home: home)
        // The plan's paths are normalised; so are these, to compare.
        let vanished = Set(gone.map(normalize))
        var live = plan
        live.targets.removeAll { vanished.contains(normalize($0.path)) }
        let memo = HandOverMemo(
            marks: marked,
            root: root,
            gone: gone,
            plan: plan,
            live: live
        )
        handOverMemo = memo
        return memo
    }

    /// Keep what hangs off the marks in step with them: `gone` only ever
    /// names marked paths, and with no marks left there is no gain to
    /// measure, so the next first mark takes a fresh baseline.
    func marksChanged() {
        assign(\.gone, gone.filter { marks.contains($0) })
        if marks.isEmpty {
            assign(\.spaceBaseline, nil)
        }
    }
}

/// A plan, and the command made from it, for one set of marks, root and
/// paths gone.
struct HandOverMemo {
    var marks: [Target]
    var root: FilePath
    var gone: Set<FilePath>
    var plan: Plan
    /// The plan less the targets already gone.
    var live: Plan
    /// The command for `live`, in the style it was last asked for.
    var command: (style: CommandStyle, text: String?)?
}
