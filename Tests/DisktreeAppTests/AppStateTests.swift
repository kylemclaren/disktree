// The state's own promises, one at a time: the trail, marks and what they
// cover, the hand-over's bookkeeping, find, the pointer, and the frame the
// mosaic is drawn from — which must never change what it reads.
//
// Real trees on disk where the answer depends on the disk; trees built in
// memory where the answer is about layout and drawing, which a synthetic
// tree pins more exactly.

import CoreGraphics
import DisktreeCore
import Foundation
import Observation
import Synchronization
import System
import Testing

@testable import DisktreeApp

// MARK: - Synthetic trees

private func file(
    _ name: String,
    _ bytes: UInt64,
    modified: Int64 = 0
) -> Node {
    var node = Node.entry(name, kind: .file, bytes: bytes)
    node.modified = modified
    return node
}

private func directory(_ name: String, _ children: [Node]) -> Node {
    Node.directory(name, children: children)
}

/// A state over a tree built in memory, at a root that is not on disk.
@MainActor
private func syntheticState(
    _ children: [Node],
    area: CGSize = treemapArea,
    depth: Int = 3
) -> AppState {
    var root = directory("synthetic", children)
    aggregate(&root, metric: .bytes)
    let state = AppState(
        root: "/nonexistent/disktree-synthetic",
        tree: root,
        options: ScanOptions(),
        depth: depth
    )
    Hooks().capture(state)
    state.treemapSize = area
    return state
}

/// Set from the `@Sendable` change handler, read by the test.
private final class Fired: Sendable {
    let flag = Atomic<Bool>(false)
    var value: Bool { flag.load(ordering: .relaxed) }
}

// MARK: - The tree and the trail

@MainActor
@Test func theTrailRunsFromTheTopToTheDirectoryDrawn() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let junk = try childCrumbs(state, [], "junk")
    let deeper = try childCrumbs(state, junk, "deeper")
    state.goTo(deeper)

    let trail = state.breadcrumbs()
    let above = tree.root.components.count
    #expect(trail.count == above + 1 + 2)
    #expect(trail.first == TrailStep(label: "/", crumb: .above("/")))
    #expect(
        trail[above]
            == TrailStep(
                label: tree.root.lastComponent?.string ?? "",
                crumb: .tree([])
            )
    )
    #expect(trail[above + 1] == TrailStep(label: "junk", crumb: .tree(junk)))
    #expect(trail.last == TrailStep(label: "deeper", crumb: .tree(deeper)))
    // Every step above the root is an ancestor, in order.
    for (index, step) in trail.prefix(above).enumerated() {
        guard case .above(let path) = step.crumb else {
            Issue.record("\(step) is above the root")
            continue
        }
        #expect(path.components.count == index)
        #expect(tree.root.starts(with: path))
    }

    #expect(state.currentPath == tree.path("junk/deeper"))
    #expect(
        state.windowTitle
            == "disktree · " + displayPath(state.currentPath, home: state.home)
    )
}

@MainActor
@Test func siblingsAreRankedAndCappedWithTheRestCounted() throws {
    let tree = try TempTree(
        (0..<30).map { (path: "many/f\($0).bin", count: 1_000 + $0) }
    )
    let state = try stateOver(tree.root, hooks: Hooks())
    let (rows, more) = state.siblings([0])
    #expect(rows.count == siblingRows)
    #expect(more == 30 - siblingRows)
    #expect(rows.first?.name == "f29.bin")
    #expect(zip(rows, rows.dropFirst()).allSatisfy { $0.value >= $1.value })
    #expect(rows.allSatisfy { !$0.isDir })
    let none = state.siblings([7, 7])
    #expect(none.rows.isEmpty && none.more == 0)
}

@MainActor
@Test func crumbsForAPathWalkFromTheScannedRoot() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let junk = try childCrumbs(state, [], "junk")
    let deeper = try childCrumbs(state, junk, "deeper")
    #expect(state.crumbs(for: tree.root) == [])
    #expect(state.crumbs(for: tree.path("junk/deeper")) == deeper)
    // Wherever the view is.
    state.goTo(deeper)
    #expect(state.crumbs(for: tree.path("junk")) == junk)
    #expect(state.crumbs(for: tree.path("junk/nothing")) == nil)
    #expect(state.crumbs(for: "/elsewhere") == nil)
    // Component-wise: a sibling whose name starts like the root is outside.
    #expect(state.crumbs(for: FilePath(tree.root.string + "-real")) == nil)
}

// MARK: - Moving about

@MainActor
@Test func descendingWithNothingSelectedEntersTheLargest() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    state.select(nil)
    state.descend()
    #expect(state.crumbs == [0], ".cache, the largest")
    #expect(state.selected == [0])
    #expect(state.transition != nil)
    // A file cannot be entered.
    state.goTo([])
    let keep = try childCrumbs(state, [], "keep")
    let notes = try childCrumbs(state, keep, "notes.txt")
    state.goTo(keep)
    state.enter(notes, from: nil)
    #expect(state.crumbs == keep)
}

@MainActor
@Test func ascendingSelectsTheParentAndMovesTheRegionBack() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let junk = try childCrumbs(state, [], "junk")
    state.goTo(junk)
    state.ascend()
    #expect(state.crumbs == [])
    #expect(state.selected == [])
    #expect(state.view == .identity)
    #expect(state.transition != nil, "junk shrinks back into its tile")
    state.ascend()
    #expect(state.crumbs == [], "the root has no parent in the tree")
    #expect(state.parentCrumbs == nil)
}

@MainActor
@Test func revealShowsAPathInItsDirectorySelected() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let junk = try childCrumbs(state, [], "junk")
    let more = try childCrumbs(
        state, try childCrumbs(state, junk, "deeper"), "more.bin")
    state.pointerMoved(to: CGPoint(x: 10, y: 10))
    state.reveal(more)
    #expect(state.crumbs == Array(more.dropLast()))
    #expect(state.selected == more)
    #expect(!state.pointerActive)
    #expect(state.transition == nil, "a jump lands at once")
}

@MainActor
@Test func arrowsMoveTheSelectionToANeighbour() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let tiles = try #require(state.layout())
    state.select(nil)
    try press(state, "right")
    #expect(state.selected == tiles.first?.crumbs, "nothing selected: first")

    // From each top-level tile, a move lands on another top-level tile or
    // stays: never a child.
    for direction in [Direction.right, .left, .up, .down] {
        state.select([0])
        state.moveSelection(direction)
        let moved = try #require(state.selected)
        #expect(moved.count == 1, "\(direction) went to \(moved)")
    }
    // Some direction from .cache reaches junk, its neighbour.
    let junk = try childCrumbs(state, [], "junk")
    let reached = [Direction.right, .left, .up, .down].contains {
        state.select([0])
        state.moveSelection($0)
        return state.selected == junk
    }
    #expect(reached)
}

@MainActor
@Test func tabCyclesSiblingsByRankAndWraps() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    state.select([0])
    try press(state, "tab")
    #expect(state.selected == [1])
    try press(state, "tab tab")
    #expect(state.selected == [0], "it wraps")
    try press(state, "shift-tab")
    #expect(state.selected == [2])
    state.select(nil)
    state.cycleSibling(-1)
    #expect(state.selected == [2], "backwards from nothing: the last")
}

@MainActor
@Test func escapeTakesTheFilterThenTheSelectionThenTheLevel() async throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let junk = try childCrumbs(state, [], "junk")
    state.goTo(junk)
    try press(state, "/")
    typeText(state, "blob")
    try await awaitSearch(state)
    try press(state, "enter")
    #expect(state.filterApplied)
    try press(state, "escape")
    #expect(state.matches == nil)
    #expect(state.selected != nil)
    try press(state, "escape")
    #expect(state.selected == nil)
    #expect(state.crumbs == junk)
    try press(state, "escape")
    #expect(state.crumbs == [])
}

@MainActor
@Test func goingToTheWholeDiskFromItsTopGoesToTheTop() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    state.diskRoot = tree.root
    let junk = try childCrumbs(state, [], "junk")
    state.goTo(junk)
    let epoch = state.scanEpoch
    try press(state, "g")
    #expect(state.crumbs == [])
    #expect(state.scanEpoch == epoch, "already the root: no walk")
    state.diskRoot = nil
    try press(state, "g")
    #expect(state.scanEpoch == epoch)
}

@MainActor
@Test func settingARootScansItAndKeepsTheMarks() async throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    state.toggleMark(try childCrumbs(state, [], "keep"))
    state.screen = .review
    state.setRoot(tree.path("junk"))
    #expect(state.screen == .explore)
    #expect(state.rootPath == tree.path("junk"))
    #expect(state.tree == nil)
    try await finishScan(state)
    #expect(state.tree?.childNamed("deeper") != nil)
    #expect(state.marks.items.map(\.path) == [tree.path("keep")])
    // Outside the new root, it is kept back rather than acted on.
    #expect(state.plan().targets.isEmpty)
    #expect(state.plan().blocked.map(\.path) == [tree.path("keep")])
}

// MARK: - Marks

@MainActor
@Test func theScannedRootCannotBeMarked() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    state.select([])
    try press(state, "space")
    #expect(state.marks.isEmpty)
    #expect(
        state.notice
            == Notice(
                "the scanned root cannot be removed; open a directory first",
                status: .warning
            )
    )
}

/// By any route, not only the key: a ⌘-click or the context menu reaches
/// `toggleMark` too. A mark on the root would absorb every other mark, and
/// the plan keeps the root back, so the whole list would be lost to it.
@MainActor
@Test func theScannedRootCannotBeMarkedFromAnywhere() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    state.toggleMark(try childCrumbs(state, [], "junk"))
    state.toggleMark([])
    #expect(state.marks.items.map(\.path) == [tree.path("junk")])
    #expect(
        state.notice?.text
            == "the scanned root cannot be removed; open a directory first"
    )
}

@MainActor
@Test func theReviewNeedsSomethingMarked() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    try press(state, "c")
    #expect(state.screen == .explore)
    #expect(
        state.notice?.text
            == "mark something first: space marks the selected tile"
    )
}

@MainActor
@Test func theBaselineIsTakenAtTheFirstMarkAndClearedWithTheMarks() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let before = SpaceInfo(total: 1_000, free: 500, available: 400)
    state.space = before
    state.toggleMark(try childCrumbs(state, [], "junk"))
    #expect(state.spaceBaseline == before)
    state.space = SpaceInfo(total: 1_000, free: 700, available: 600)
    state.toggleMark(try childCrumbs(state, [], "keep"))
    #expect(state.spaceBaseline == before, "the first mark's, not the last")
    #expect(state.measuredGain == 200)
    state.clearMarks()
    #expect(state.spaceBaseline == nil)
    #expect(state.measuredGain == nil)

    // Unmarking the last one clears it too, so the next first mark measures
    // from the disk as it is then.
    let junk = try childCrumbs(state, [], "junk")
    state.toggleMark(junk)
    #expect(state.spaceBaseline == state.space)
    state.unmark(tree.path("junk"))
    #expect(state.spaceBaseline == nil)
}

@MainActor
@Test func theMeasuredGainIsOnlyWhatTheDiskGained() {
    let state = syntheticState([file("a", 10)])
    state.space = SpaceInfo(total: 1_000, free: 500, available: 450)
    #expect(state.measuredGain == nil, "no baseline, no claim")
    state.spaceBaseline = SpaceInfo(total: 1_000, free: 400, available: 350)
    #expect(state.measuredGain == 100, "available space, as df shows it")
    state.spaceBaseline = state.space
    #expect(state.measuredGain == nil, "nothing gained")
    state.spaceBaseline = SpaceInfo(total: 1_000, free: 900, available: 800)
    #expect(state.measuredGain == nil, "the disk filled: no gain")
    state.space = nil
    #expect(state.measuredGain == nil)
}

/// The gain is measured on one volume. When the root moves to another —
/// Open Folder…, a folder dropped on the Dock, `g` from a disk under
/// `/Volumes` — what was gained so far is carried over and the rest is
/// measured there: never one disk's free space against another's, which
/// would report the gap between them as a saving (Invariant 9).
@MainActor
@Test func theBaselineFollowsTheRootToAnotherVolume() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    state.toggleMark(try childCrumbs(state, [], "keep"))
    // As if the root so far were on another disk, where 100 bytes were
    // freed since the first mark.
    state.device = "/dev/elsewhere"
    state.space = SpaceInfo(total: 1_000, free: 500, available: 400)
    state.spaceBaseline = SpaceInfo(total: 1_000, free: 400, available: 300)
    #expect(state.measuredGain == 100)

    state.setRoot(tree.path("junk"))
    let space = try #require(state.space, "the fixture's volume")
    #expect(state.device != "/dev/elsewhere")
    #expect(
        state.measuredGain == 100,
        "what was gained there, not the gap between two disks"
    )
    #expect(state.spaceBaseline?.available == space.available - 100)
    #expect(state.marks.count == 1, "the marks are kept")

    // Another root on the same volume leaves the baseline as it is.
    let baseline = state.spaceBaseline
    state.setRoot(tree.root)
    #expect(state.spaceBaseline == baseline)
}

@Test func aCarriedBaselineNeverMakesUpAGain() {
    let baseline = SpaceInfo(total: 1_000, free: 400, available: 300)
    let was = SpaceInfo(total: 1_000, free: 500, available: 400)
    // One APFS container: the same free space either side, so the same
    // baseline.
    #expect(AppState.rebased(baseline, from: was, to: was) == baseline)
    // More gained than the new volume can show: under-reported, from zero.
    let small = SpaceInfo(total: 100, free: 60, available: 50)
    let fromZero = AppState.rebased(baseline, from: was, to: small)
    #expect(fromZero?.available == 0 && fromZero?.free == 0)
    // The disk filled since the first mark: the loss is carried too.
    let fuller = SpaceInfo(total: 1_000, free: 300, available: 200)
    #expect(AppState.rebased(baseline, from: fuller, to: was)?.available == 500)
    let full = SpaceInfo(total: .max, free: .max, available: .max)
    #expect(
        AppState.rebased(baseline, from: fuller, to: full)?.available == .max
    )
    // Either side unreadable: nothing to measure from.
    #expect(AppState.rebased(baseline, from: nil, to: was) == nil)
    #expect(AppState.rebased(baseline, from: was, to: nil) == nil)
}

@MainActor
@Test func aPlanWithEveryMarkKeptBackHasNothingToHandOver() throws {
    let tree = try fixture()
    let elsewhere = try TempTree([("x.bin", 10)])
    let hooks = Hooks()
    let state = try stateOver(tree.root, hooks: hooks)
    state.marks.toggle(
        Target(path: elsewhere.root, bytes: 10, isDir: true, hidden: false)
    )
    #expect(state.cleanupCommand() == nil)
    state.copyCommand()
    state.revealMarkedInFinder()
    #expect(hooks.copied.isEmpty && hooks.revealed.isEmpty)
    #expect(
        state.notice?.text == "nothing to hand over: every mark is kept back"
    )
}

// MARK: - Watching the marks go

@MainActor
@Test func checkingMarksNamesWhatIsGoneAndWaitsForTheRest() async throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    await state.checkDisk()
    #expect(state.gone.isEmpty, "nothing marked, nothing to look for")

    state.toggleMark(try childCrumbs(state, [], "junk"))
    state.toggleMark(try childCrumbs(state, [], "keep"))
    let epoch = state.scanEpoch
    await state.checkDisk()
    #expect(state.gone.isEmpty)

    // Removed in Finder, say: one of the two.
    try FileManager.default.removeItem(atPath: tree.path("keep").string)
    await state.checkDisk()
    #expect(state.gone == [tree.path("keep")])
    #expect(state.scanEpoch == epoch, "one is left: no rescan yet")
    #expect(state.tree != nil)
    #expect(state.marks.count == 2, "a gone mark stays listed, struck")

    // Unmarking a gone path forgets that it went.
    state.unmark(tree.path("keep"))
    #expect(state.gone.isEmpty)
}

/// A rescan drops the marks whose paths are gone from disk and keeps the
/// rest, re-measured (Invariant 5).
@MainActor
@Test func aRescanDropsVanishedMarksAndKeepsTheRest() async throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let junk = try childCrumbs(state, [], "junk")
    state.toggleMark(try childCrumbs(state, junk, "blob.bin"))
    state.toggleMark(try childCrumbs(state, [], "keep"))
    try FileManager.default.removeItem(atPath: tree.path("keep").string)
    try tree.write("junk/blob.bin", count: 5_000)

    try press(state, "r")
    try await finishScan(state)
    #expect(state.marks.items.map(\.path) == [tree.path("junk/blob.bin")])
    #expect(state.marks.items.first?.bytes == 5_000, "re-measured")
    #expect(state.gone.isEmpty)
    #expect(state.spaceBaseline != nil || state.space == nil)
}

/// Marks the guards keep back are never in the command; once everything
/// else is gone the hand-over is done, and they stay.
@MainActor
@Test func marksKeptBackDoNotHoldUpTheRescan() async throws {
    let tree = try fixture()
    let elsewhere = try TempTree([("x.bin", 10)])
    let state = try stateOver(tree.root, hooks: Hooks())
    state.toggleMark(try childCrumbs(state, [], "keep"))
    state.marks.toggle(
        Target(path: elsewhere.root, bytes: 10, isDir: true, hidden: false)
    )
    try FileManager.default.removeItem(atPath: tree.path("keep").string)
    let epoch = state.scanEpoch
    await state.checkDisk()
    #expect(state.scanEpoch == epoch + 1)
    try await finishScan(state)
    #expect(state.marks.items.map(\.path) == [elsewhere.root])
}

/// The scanned root itself went, marks and all: the rescan fails, and
/// still drops what is gone, so the hand-over does not try again forever.
@MainActor
@Test func aRescanThatFailsStillDropsWhatWent() async throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    state.toggleMark(try childCrumbs(state, [], "junk"))
    try FileManager.default.removeItem(atPath: tree.root.string)
    await state.checkDisk()
    try await finishScan(state)
    #expect(state.scanError != nil)
    #expect(state.marks.isEmpty)
    let epoch = state.scanEpoch
    await state.checkDisk()
    #expect(state.scanEpoch == epoch)
}

/// The look at the disk is taken off the main actor — `statfs` and `lstat`
/// on a network share that stopped answering would freeze the window —
/// and what it finds lands back here.
@MainActor
@Test func checkingMarksLooksOffTheMainActorAndLandsHere() async throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    state.toggleMark(try childCrumbs(state, [], "junk"))
    state.toggleMark(try childCrumbs(state, [], "keep"))
    try FileManager.default.removeItem(atPath: tree.path("keep").string)
    state.checkMarks()
    #expect(state.gone.isEmpty, "not looked at here")
    for _ in 0..<2_000 where state.gone.isEmpty {
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(state.gone == [tree.path("keep")])
}

/// `t` while a walk is out: the tree it brings is ranked by the metric it
/// started with, and has to be ranked by the one on screen, or "the
/// largest" — the first selection, Enter, Tab — means the other one.
@MainActor
@Test func aMetricSwitchedDuringAWalkRanksTheTreeThatLands() async throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    state.startScan()
    try press(state, "t")
    #expect(state.options.metric == .files)
    try await finishScan(state)
    #expect(
        state.tree?.children.first?.name == "junk",
        "two files: the most by count"
    )
    #expect(state.selected.flatMap { state.node(at: $0) }?.name == "junk")
}

// MARK: - Find

@MainActor
@Test func onlyTheNewestSearchIsKept() async throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    state.find = "notes"
    state.refreshMatches()
    state.find = "blob"
    state.refreshMatches()
    try await awaitSearch(state)
    // Give a superseded answer every chance to land after the newest one.
    try await Task.sleep(for: .milliseconds(50))
    #expect(state.matches?.needle == "blob")
    #expect(state.matches?.count == 2)
}

@MainActor
@Test func blankFindTextFindsNothing() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    state.find = "   "
    state.refreshMatches()
    #expect(!state.finding)
    #expect(state.matches == nil)
}

@MainActor
@Test func enterWithNoMatchSaysSo() async throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    try press(state, "/")
    typeText(state, "zzz")
    try await awaitSearch(state)
    try press(state, "enter")
    #expect(!state.filterApplied)
    #expect(state.notice?.text == "nothing here matches zzz")
    #expect(!state.findOpen)
}

/// An Enter still waiting on its search is superseded by going back to
/// typing: only an Enter after the last edit applies what that edit finds,
/// so the field does not shut on someone still typing in it.
@MainActor
@Test func anEnterLeftBehindByTypingAppliesNothingLater() async throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    try press(state, "/")
    typeText(state, "b")
    #expect(state.finding)
    try press(state, "enter / backspace")
    typeText(state, "m")
    try await awaitSearch(state)
    #expect(state.findOpen, "still typing")
    #expect(!state.filterApplied)
    #expect(state.matches?.count == 1, "more.bin")

    // An Enter after the last edit still waits for it.
    try press(state, "enter")
    try await awaitSearch(state)
    #expect(state.filterApplied && !state.findOpen)
}

/// A filter is about the directory it was typed in: going above it lets it
/// lapse, where the directory changes — never while drawing.
@MainActor
@Test func aFilterLapsesAboveWhereItWasTyped() async throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let junk = try childCrumbs(state, [], "junk")
    state.goTo(junk)
    try press(state, "/")
    typeText(state, "blob")
    try await awaitSearch(state)
    try press(state, "enter")
    #expect(state.matches?.base == junk)
    #expect(state.filterApplied)

    // Deeper is still within it.
    let deeper = try childCrumbs(state, junk, "deeper")
    state.goTo(deeper)
    #expect(state.matches != nil)

    // Above it, it goes.
    state.goTo([])
    #expect(state.matches == nil)
    #expect(!state.filterApplied)
    #expect(state.find.isEmpty)
}

@MainActor
@Test func aSearchThatLandsAboveTheViewLapsesOnArrival() async throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let junk = try childCrumbs(state, [], "junk")
    state.goTo(junk)
    try press(state, "/")
    typeText(state, "blob")
    try press(state, "enter")
    state.goTo([])
    try await awaitSearch(state)
    #expect(state.matches == nil)
    #expect(!state.filterApplied)
}

// MARK: - Drawing

/// `layout()` and `prepare()` run while the treemap draws, inside the
/// observation tracking that schedules its next frame: changing anything a
/// view reads there would schedule frames forever.
@MainActor
@Test func drawingChangesNothingAViewObserves() async throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let junk = try childCrumbs(state, [], "junk")
    state.goTo(junk)
    try press(state, "/")
    typeText(state, "blob")
    try await awaitSearch(state)
    try press(state, "enter")
    // Every trap a drawing pass could fall into at once: a stale cache, a
    // filter above the view (bypassing where it would lapse), a transition
    // in flight, the marks to resolve and a zoomed interface.
    state.toggleMark(try childCrumbs(state, junk, "deeper"))
    state.crumbs = []
    state.transition = LayoutTransition(
        src: Rect(x: 0, y: 0, w: 10, h: 10),
        dst: Rect(x: 0, y: 0, w: 1_100, h: 800)
    )
    state.zoomInterface(KeyStroke("=", command: true))
    state.cache = nil
    state.colorMode = .age

    let fired = Fired()
    withObservationTracking {
        _ = (state.tree, state.crumbs, state.selected, state.hovered)
        _ = (state.pointerActive, state.view, state.transition)
        _ = (state.layoutOptions, state.pointer, state.treemapSize)
        _ = (state.zoomStep, state.matches, state.filterApplied, state.find)
        _ = (state.findOpen, state.finding, state.notice, state.marks.count)
        _ = (state.gone, state.space, state.spaceBaseline, state.screen)
        _ = (state.insights, state.git, state.progress, state.scanError)
        _ = (state.scannedAt, state.options, state.colorMode, state.rootPath)
        _ = (state.showHelp, state.legendFocus, state.commandStyle)
        _ = (state.toast, state.toastSerial, state.quickLookTarget)
        _ = (state.hoveredTail, state.preferences, state.panelRems)
    } onChange: {
        fired.flag.store(true, ordering: .relaxed)
    }
    _ = state.layout()
    _ = state.prepare()
    _ = state.prepare(now: .now + .seconds(1))
    _ = state.tile(atX: 100, y: 100)
    _ = state.tileBody(junk)
    _ = state.tileRect(junk)
    _ = state.effectiveLayoutOptions
    // The review asks for these from `body`: their memo is not observed.
    _ = (state.plan(), state.handOverPlan(), state.cleanupCommand())
    _ = (state.plan(), state.cleanupCommand())
    #expect(!fired.value)
    #expect(state.matches != nil, "the filter lapses where crumbs change")
    #expect(state.transition != nil, "the ticker clears it, not a frame")
}

@MainActor
@Test func aFinishedTransitionIsClearedByTheTicker() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    state.descend()
    let transition = try #require(state.transition)
    #expect(state.tickTransition(now: transition.started))
    #expect(state.transition != nil)
    // Mid-flight, tiles are on their way; at the end, where they are.
    let middle = transition.started + transition.duration / 2
    let tiles = try #require(state.layout())
    let moving = state.prepare(now: middle).tiles
    #expect(zip(tiles, moving).contains { $0.rect != $1.rect })
    let landed = state.prepare(now: transition.started + .seconds(1)).tiles
    #expect(zip(tiles, landed).allSatisfy { $0.rect == $1.rect })

    #expect(!state.tickTransition(now: transition.started + .seconds(1)))
    #expect(state.transition == nil)
    #expect(!state.tickTransition())
}

@MainActor
@Test func aFrameShapesAtMostItsLabelLimitLargestFirst() {
    // Twenty directories of twenty files, on a large treemap: every tile is
    // big enough for its name, many more than one frame will shape.
    let children = (0..<20).map { dir in
        directory(
            "dir\(dir)",
            (0..<20).map { file("file\($0)", 1_000) }
        )
    }
    let state = syntheticState(
        children,
        area: CGSize(width: 4_000, height: 3_000)
    )
    let mosaic = state.prepare()
    #expect(mosaic.tiles.count == 420)
    #expect(mosaic.labels.count == AppState.maxLabels)
    let areas = mosaic.labels.map { $0.rect.w * $0.rect.h }
    #expect(zip(areas, areas.dropFirst()).allSatisfy { $0 >= $1 })
    // The same frame always shapes the same labels.
    #expect(state.prepare().labels == mosaic.labels)
}

@MainActor
@Test func equalLabelsKeepLayoutOrder() {
    let state = syntheticState(
        (0..<4).map { file("f\($0)", 1_000) },
        area: CGSize(width: 800, height: 800)
    )
    let tiles = state.layout() ?? []
    let mosaic = state.prepare()
    let areas = Set(mosaic.labels.map { $0.rect.w * $0.rect.h })
    #expect(areas.count == 1, "four equal tiles: \(areas)")
    #expect(
        mosaic.labels.map(\.text)
            == tiles.compactMap { state.node(at: $0.crumbs)?.name }
    )
}

@MainActor
@Test func theMergedTailIsLabelledWithItsCount() {
    let state = syntheticState((0..<200).map { file("f\($0)", 1_000) })
    let mosaic = state.prepare()
    let more = mosaic.labels.first { $0.text.hasPrefix("+") }
    #expect(more?.text == "+104 more")
    #expect(more?.sizeText == "")
    #expect(more?.header == nil)
    #expect(more?.dim == false)
}

@MainActor
@Test func smallTilesGoUnlabelledUntilZoomMakesRoom() {
    // One large file and one whose tile is too narrow for a name.
    let state = syntheticState(
        // 34 points wide once padded: drawn, but narrower than a name.
        [file("big", 1_000_000), file("small", 41_667)],
        area: CGSize(width: 1_000, height: 400)
    )
    #expect(state.prepare().labels.map(\.text) == ["big"])
    let small = state.layout()?.last?.rect ?? .zero
    state.zoom(
        atX: small.x + small.w / 2,
        y: small.y + small.h / 2,
        factor: 5,
        descend: false
    )
    #expect(state.prepare().labels.map(\.text).contains("small"))
}

@MainActor
@Test func aTileSaysItsAgeKindAndState() {
    let now = nowSeconds()
    var cache = directory(
        "cache",
        [file("old.bin", 5_000, modified: now - 10 * 86_400)]
    )
    cache.category = .cache
    cache.reclaim = .regenerable
    var locked = directory("locked", [file("readable.bin", 4_000)])
    locked.readError = true
    let state = syntheticState([
        cache, locked, file("undated.bin", 3_000),
    ])
    let tiles = state.layout() ?? []
    func deco(_ name: String) -> TileDeco? {
        let mosaic = state.prepare()
        return zip(tiles, mosaic.tiles).first {
            state.node(at: $0.0.crumbs)?.name == name
        }?.1
    }
    #expect(deco("cache")?.category == .cache)
    #expect(deco("cache")?.reclaimable == true)
    #expect(deco("old.bin")?.reclaimable == false, "not classified here")
    #expect(deco("cache")?.ageBucket == nil, "kind mode: no age")
    #expect(deco("locked")?.unreadable == true)
    #expect(deco("readable.bin")?.unreadable == false)

    state.setMode(2)
    #expect(state.modeIndex == 2)
    #expect(deco("old.bin")?.ageBucket == 1, "ten days: this month")
    #expect(deco("undated.bin")?.ageBucket == nil, "never written: unknown")

    let cacheCrumbs = state.crumbs(for: "/nonexistent/disktree-synthetic/cache")
    state.select(cacheCrumbs)
    state.hovered = cacheCrumbs
    #expect(deco("cache")?.selected == true)
    #expect(deco("cache")?.hovered == true)
    #expect(deco("undated.bin")?.selected == false)
}

@MainActor
@Test func whileTypingATileSaysHowItStandsAgainstTheFindText() async throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    try press(state, "/")
    typeText(state, "blob")
    try await awaitSearch(state)
    let tiles = try #require(state.layout())
    let mosaic = state.prepare()
    func filtered(_ path: String) -> Filtered? {
        let crumbs = state.crumbs(for: tree.path(path))
        return zip(tiles, mosaic.tiles).first { $0.0.crumbs == crumbs }?.1
            .filtered
    }
    #expect(filtered("junk") == .holds)
    #expect(filtered("junk/blob.bin") == .shown)
    #expect(filtered("junk/deeper") == .out)
    #expect(filtered("junk/deeper/more.bin") == .out)
    #expect(mosaic.labels.first { $0.text == "deeper" }?.dim == true)
    #expect(mosaic.labels.first { $0.text == "junk" }?.dim == false)
}

// MARK: - The pointer

@MainActor
@Test func thePointerOutsideTheMosaicHoversNothing() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    state.pointerMoved(to: CGPoint(x: 20, y: 40))
    #expect(state.hovered != nil)
    #expect(state.pointerActive)
    // Moves outside are ignored, and a stale hover goes.
    state.pointerMoved(to: CGPoint(x: -1, y: 40))
    #expect(state.hovered == nil && state.pointer == nil)
    #expect(!state.pointerActive)
    state.pointerMoved(to: CGPoint(x: 20, y: treemapArea.height))
    #expect(state.pointer == nil)
    state.pointerMoved(to: CGPoint(x: 20, y: 40))
    state.pointerExited()
    #expect(state.hovered == nil && state.pointer == nil)
    #expect(!state.pointerActive)
}

@MainActor
@Test func clicksSelectOpenAndMark() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let junk = try childCrumbs(state, [], "junk")
    let keep = try childCrumbs(state, [], "keep")
    let band = try #require(state.layout()?.first { $0.crumbs == junk }?.header)
    let onJunk = centre(state, of: band)
    let plain = PointerModifiers()

    // A click selects; a second click on a selected directory opens it.
    state.mouseDown(at: onJunk, button: .left, clickCount: 1, modifiers: plain)
    #expect(state.selected == junk)
    #expect(state.crumbs == [])
    state.mouseDown(at: onJunk, button: .left, clickCount: 1, modifiers: plain)
    #expect(state.crumbs == junk)

    // A double click opens what it lands on.
    state.goTo([])
    state.select(keep)
    state.mouseDown(at: onJunk, button: .left, clickCount: 2, modifiers: plain)
    #expect(state.crumbs == junk)

    // ⌘-click and ctrl-click mark; so does the middle button.
    state.goTo([])
    state.mouseDown(
        at: onJunk,
        button: .left,
        clickCount: 1,
        modifiers: PointerModifiers(command: true)
    )
    #expect(state.marks.items.map(\.path) == [tree.path("junk")])
    state.mouseDown(
        at: onJunk,
        button: .left,
        clickCount: 1,
        modifiers: PointerModifiers(control: true)
    )
    #expect(state.marks.isEmpty)
    state.mouseDown(
        at: onJunk, button: .middle, clickCount: 1, modifiers: plain)
    #expect(state.marks.count == 1)
    #expect(state.crumbs == [], "marking opens nothing")

    // The right button is the view's context menu: nothing happens here.
    state.select(keep)
    state.mouseDown(at: onJunk, button: .right, clickCount: 1, modifiers: plain)
    #expect(state.selected == keep)
    #expect(state.marks.count == 1)

    // A click on nothing, the gap at the edge, clears the selection.
    #expect(state.tile(atX: 1, y: 1) == nil)
    state.mouseDown(
        at: CGPoint(x: 1, y: 1),
        button: .left,
        clickCount: 1,
        modifiers: plain
    )
    #expect(state.selected == nil)
}

/// A double click arrives as a click, which opens a directory that is
/// already selected, then a second click: that one must not go on into
/// whatever now lies under the pointer. One gesture, one level.
@MainActor
@Test func aDoubleClickOnTheSelectedDirectoryOpensItOnce() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let junk = try childCrumbs(state, [], "junk")
    let band = try #require(state.layout()?.first { $0.crumbs == junk }?.header)
    let onJunk = centre(state, of: band)
    let plain = PointerModifiers()
    state.select(junk)
    state.mouseDown(at: onJunk, button: .left, clickCount: 1, modifiers: plain)
    #expect(state.crumbs == junk)
    state.mouseDown(at: onJunk, button: .left, clickCount: 2, modifiers: plain)
    #expect(state.crumbs == junk, "the second click opens nothing more")
    state.mouseDown(at: onJunk, button: .left, clickCount: 3, modifiers: plain)
    #expect(state.crumbs == junk)

    // The next double click is a gesture of its own.
    let deeper = try childCrumbs(state, junk, "deeper")
    let onDeeper = centre(state, of: try #require(state.tileRect(deeper)))
    state.mouseDown(
        at: onDeeper, button: .left, clickCount: 1, modifiers: plain)
    state.mouseDown(
        at: onDeeper, button: .left, clickCount: 2, modifiers: plain)
    #expect(state.crumbs == deeper)
}

/// The merged "+N more" tail carries the crumbs of the directory it sits
/// in, and stands only for that directory's smallest entries: acting on
/// it as that directory would mark, open or hand over the large entries
/// beside it too.
@MainActor
@Test func theMergedTailIsNothingToActOn() throws {
    let tree = try TempTree(
        [("dir/big.bin", 500_000), ("other.bin", 1_000)]
            + (0..<120).map { (path: "dir/small-\($0).bin", count: 100) }
    )
    let state = try stateOver(tree.root, hooks: Hooks())
    let dir = try childCrumbs(state, [], "dir")
    let tiles = try #require(state.layout())
    let index = try #require(
        tiles.firstIndex {
            if case .others = $0.kind { true } else { false }
        },
        "the small entries merge"
    )
    #expect(tiles[index].crumbs == dir)
    let onTail = centre(state, of: tiles[index].rect)

    state.pointerMoved(to: onTail)
    #expect(state.hovered == nil, "nothing to report under the pointer")
    let plain = PointerModifiers()
    state.mouseDown(
        at: onTail,
        button: .left,
        clickCount: 1,
        modifiers: PointerModifiers(command: true)
    )
    state.mouseDown(
        at: onTail, button: .middle, clickCount: 1, modifiers: plain)
    #expect(state.marks.isEmpty, "not the directory the tail sits in")

    // Drawn: never the selected or hovered tile, even when its directory
    // is, and inside the directory when that is marked.
    let band = try #require(tiles.first { $0.crumbs == dir }?.header)
    state.pointerMoved(to: centre(state, of: band))
    state.select(dir)
    state.toggleMark(dir)
    let mosaic = state.prepare()
    #expect(mosaic.tiles.filter(\.hovered).count == 1)
    #expect(mosaic.tiles.filter(\.selected).count == 1)
    #expect(mosaic.tiles.filter(\.marked).count == 1)
    let tail = mosaic.tiles[index]
    #expect(tail.covered && !tail.marked && !tail.hovered && !tail.selected)

    // The wheel over it still zooms into the directory holding it.
    state.clearMarks()
    state.pointerMoved(to: onTail)
    var entered = false
    for _ in 0..<40 where !entered {
        entered =
            state.scroll(at: onTail, lines: 1, shift: false) == .changedLevel
    }
    #expect(state.crumbs == dir)

    // At the top of the tree the tail's crumbs are the scanned root's.
    let flat = try TempTree(
        [("big.bin", 500_000)]
            + (0..<120).map { (path: "small-\($0).bin", count: 100) }
    )
    let top = try stateOver(flat.root, hooks: Hooks())
    let rootTail = try #require(
        top.layout()?.first {
            if case .others = $0.kind { true } else { false }
        }
    )
    top.toggleMark(try childCrumbs(top, [], "big.bin"))
    top.mouseDown(
        at: centre(top, of: rootTail.rect),
        button: .left,
        clickCount: 1,
        modifiers: PointerModifiers(command: true)
    )
    #expect(top.marks.items.map(\.path) == [flat.path("big.bin")])
}

@MainActor
@Test func shiftScrollPansAndAPlainScrollZooms() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let middle = CGPoint(x: 550, y: 400)
    #expect(state.scroll(at: middle, lines: 0, shift: false) == .none)
    #expect(state.view == .identity, "nothing to scroll")

    state.zoom(atX: 550, y: 400, factor: 2, descend: false)
    let origin = state.view.originY
    #expect(state.scroll(at: middle, lines: 1, shift: true) == .zoomed)
    #expect(state.view.originY == max(origin - 40 / 2, 0))
    #expect(state.view.scale == 2, "panning does not zoom")
    state.scroll(at: middle, lines: 1_000, shift: true)
    #expect(state.view.originY == 0, "never above the top")
    state.scroll(at: middle, lines: -1_000, shift: true)
    #expect(
        state.view.originY == Double(treemapArea.height) / 2,
        "nor past the bottom: no empty band opens up"
    )
    state.resetView()
    #expect(state.scroll(at: middle, lines: -5, shift: true) == .none)
    #expect(state.view == .identity, "the whole view has nowhere to pan")

    // A fraction of a notch zooms by a fraction of a step. Over files
    // alone, where no directory sets a ceiling below the view's own.
    let files = syntheticState([file("a", 3_000), file("b", 1_000)])
    #expect(files.scroll(at: middle, lines: 0.5, shift: false) == .zoomed)
    #expect(abs(files.view.scale - pow(1.15, 0.5)) < 1e-9)
    #expect(files.scroll(at: middle, lines: 1, shift: false) == .zoomed)
    #expect(abs(files.view.scale - pow(1.15, 1.5)) < 1e-9)

    // At the bottom, scrolling out goes up a level, and says so.
    let junk = try childCrumbs(state, [], "junk")
    state.goTo(junk)
    #expect(state.scroll(at: middle, lines: -1, shift: false) == .changedLevel)
    #expect(state.crumbs == [])
}

@MainActor
@Test func aPinchZoomsAndGoesThroughLevelsLikeTheWheel() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let middle = CGPoint(x: 550, y: 400)
    #expect(state.magnify(at: middle, factor: 1) == .none)
    #expect(state.magnify(at: middle, factor: 0) == .none)
    #expect(state.magnify(at: middle, factor: .nan) == .none)
    #expect(state.view == .identity)
    let files = syntheticState([file("a", 3_000), file("b", 1_000)])
    #expect(files.magnify(at: middle, factor: 1.1) == .zoomed)
    #expect(abs(files.view.scale - 1.1) < 1e-9)

    // Pinching in on junk's contents ends up inside it.
    let junk = try childCrumbs(state, [], "junk")
    let body = try #require(state.tileBody(junk))
    state.resetView()
    let point = centre(state, of: body)
    var entered = false
    for _ in 0..<60 where !entered {
        entered = state.magnify(at: point, factor: 1.2) == .changedLevel
    }
    #expect(entered)
    #expect(state.crumbs.starts(with: junk) && !state.crumbs.isEmpty)

    // And out again, with a pinch of its own: at the whole view, the
    // floor is felt first, then a squeeze goes through it.
    state.endMagnify()
    state.resetView()
    #expect(state.magnify(at: middle, factor: 0.8) == .reachedEdge)
    #expect(state.magnify(at: middle, factor: 0.8) == .changedLevel)
}

// MARK: - The view

@MainActor
@Test func depthStaysBetweenOneAndSix() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    try press(state, "[ [ [ [")
    #expect(state.layoutOptions.maxDepth == 1)
    #expect(state.layout()?.allSatisfy { $0.depth == 0 } == true)
    try press(state, "] ] ] ] ] ] ] ]")
    #expect(state.layoutOptions.maxDepth == 6)
}

/// Children are ordered by the metric, so switching it moves every crumb:
/// the directory on screen and the selection are found again by path.
@MainActor
@Test func switchingTheMetricKeepsTheDirectoryOnScreen() throws {
    let tree = try TempTree([
        ("big/one.bin", 900_000),
        ("many/a.bin", 10), ("many/b.bin", 10), ("many/c.bin", 10),
    ])
    let state = try stateOver(tree.root, hooks: Hooks())
    let big = try childCrumbs(state, [], "big")
    state.goTo(big)
    state.select(try childCrumbs(state, big, "one.bin"))
    #expect(state.modeIndex == 0)

    try press(state, "t")
    #expect(state.modeIndex == 1)
    #expect(state.options.metric == .files)
    #expect(state.node(at: [0])?.name == "many", "re-ranked by files")
    #expect(state.currentPath == tree.path("big"))
    #expect(
        state.selected.flatMap { state.path(at: $0) }
            == tree.path("big/one.bin"))

    try press(state, "t")
    #expect(state.modeIndex == 2)
    #expect(state.colorMode == .age)
    #expect(state.options.metric == .bytes, "age keeps areas by size")
    #expect(state.currentPath == tree.path("big"))
    try press(state, "t")
    #expect(state.modeIndex == 0)
}

@MainActor
@Test func theSettingsKeysScanAgainWithTheNewOptions() async throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    try press(state, "p")
    #expect(!state.showSelection)
    try press(state, "i")
    #expect(!state.options.includeHidden)
    try await finishScan(state)
    #expect(state.tree?.childNamed(".cache") == nil, "hidden left out")
    try press(state, "d")
    #expect(!state.options.apparentSize)
    try await finishScan(state)
    #expect(state.tree != nil)
}

@MainActor
@Test func gitIsAskedOnceOffTheMainActor() async throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    state.ensureGit(tree.root)
    state.ensureGit(tree.root)
    #expect(state.gitPending == [tree.root])
    for _ in 0..<2_000 where state.git.index(forKey: tree.root) == nil {
        try await Task.sleep(for: .milliseconds(1))
    }
    // Asked, and found not to be a checkout: recorded, not left unasked.
    #expect(state.git.index(forKey: tree.root) != nil)
    #expect(state.git[tree.root] == .some(nil))
    #expect(state.gitPending.isEmpty)
}

// MARK: - Performance

/// `prepare()` runs every frame of a transition. Over real, large trees it
/// has to stay well under a 60 Hz frame. Walks real directories, so it runs
/// only when asked, and in release, as the app ships:
/// `DISKTREE_BENCH=1 swift test -c release -Xswiftc -enable-testing
/// --filter prepareStays`.
@MainActor
@Test(
    .enabled(if: ProcessInfo.processInfo.environment["DISKTREE_BENCH"] != nil)
)
func prepareStaysWellUnderAFrame() throws {
    let clock = ContinuousClock()
    let frames = 60
    /// Every frame of `transition`, prepared with it running: the median,
    /// the mean and the worst.
    func animate(
        _ state: AppState,
        _ transition: LayoutTransition
    ) -> (tiles: Int, median: Duration, mean: Duration, worst: Duration) {
        state.transition = transition
        _ = state.prepare(now: transition.started)
        var times: [Duration] = []
        for frame in 0..<frames {
            let now =
                transition.started + transition.duration
                * (Double(frame) / Double(frames))
            times.append(clock.measure { _ = state.prepare(now: now) })
        }
        times.sort()
        let total = times.reduce(Duration.zero, +)
        return (
            state.layout()?.count ?? 0, times[frames / 2], total / frames,
            times[frames - 1]
        )
    }
    for root in ["/Users/kyle/Dev/disktree", "/Applications", "/usr"] {
        let options = ScanOptions()
        var scanned: Node?
        let scanTime = try clock.measure {
            scanned = try scan(FilePath(root), options: options)
        }
        let tree = try #require(scanned)
        for depth in [3, 6] {
            let state = AppState(
                root: FilePath(root),
                tree: tree,
                options: options,
                depth: depth
            )
            Hooks().capture(state)
            state.treemapSize = CGSize(width: 1_100, height: 820)
            // Marks to resolve every frame, as a real session has.
            for index in 0..<min(tree.children.count, 5) {
                state.toggleMark([index])
            }
            let layoutTime = clock.measure { _ = state.layout() }
            // The top of the tree, as ascending back to it animates it.
            let top = animate(
                state,
                LayoutTransition(
                    src: Rect(x: 0, y: 0, w: 1_100, h: 820),
                    dst: Rect(x: 200, y: 200, w: 300, h: 200)
                )
            )
            state.descend()
            let entered = animate(state, try #require(state.transition))
            print(
                "prepare \(root) depth \(depth): scan \(scanTime), "
                    + "layout \(layoutTime); top \(top.tiles) tiles, "
                    + "median \(top.median), mean \(top.mean), worst "
                    + "\(top.worst); entered \(entered.tiles) tiles, median "
                    + "\(entered.median), mean \(entered.mean), worst "
                    + "\(entered.worst)"
            )
            // A 60 Hz frame is 16.7 ms, and painting needs most of it. The
            // median, not the worst: one frame the scheduler took away from
            // a busy machine says nothing about what `prepare` costs.
            #expect(top.median < .milliseconds(8), "\(root) depth \(depth)")
            #expect(entered.median < .milliseconds(8), "\(root) \(depth)")
        }
    }
}
