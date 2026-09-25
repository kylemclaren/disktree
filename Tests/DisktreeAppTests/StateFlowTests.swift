// End-to-end flows through the state, ported from the Rust window-harness
// tests (tests.rs).
//
// These drive the application the way a person does — press keys, type,
// point and click — over a real scan of a real tree on disk, so they catch
// what a unit test of one method cannot: a binding that never fires, a
// search whose answer is lost, a hand-over that copies a command which
// removes the wrong thing. What the Rust tests checked of the window itself
// (that a frame draws) belongs to the screens' own tests; the removal they
// ran is now a command the user runs, so these run it as the user would.

import CoreGraphics
import DisktreeCore
import Foundation
import System
import Testing

@testable import DisktreeApp

@MainActor
@Test func theWindowHasATreemapWithTiles() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    #expect(state.treemapSize.width > 0 && state.treemapSize.height > 0)
    let tiles = state.layout()?.count ?? 0
    #expect(tiles >= 3, "tiles laid out: \(tiles)")
    #expect(state.prepare().tiles.count == tiles)
}

@MainActor
@Test func theFirstScanShowsWhatItIsDoingThenTheTreemap() async throws {
    let tree = try fixture()
    let hooks = Hooks()
    // Through the real constructor, so this is the path every first run
    // takes.
    let state = AppState(root: tree.root, options: fixtureOptions, depth: 3)
    hooks.capture(state)
    state.treemapSize = treemapArea

    // Nothing is known yet, so the viewport counts the walk instead of
    // showing an empty mosaic.
    #expect(state.tree == nil)
    #expect(state.layout() == nil)
    #expect(state.prepare().tiles.isEmpty)
    #expect(state.scanRoot == tree.root)

    try await finishScan(state)
    let tiles = state.layout()?.count ?? 0
    #expect(tiles >= 3, "tiles after the scan: \(tiles)")
    #expect(
        state.selected != nil,
        "the largest entry is selected for the selection line"
    )
    #expect(
        state.tree?.children.contains { $0.name.hasPrefix(".") } == true,
        "hidden directories are part of the tree"
    )
    #expect(state.progress.finished)
    #expect(state.scanElapsed != nil)
    #expect(state.scanError == nil)
}

@MainActor
@Test func keysWalkTheTreeAndMarkWhatIsSelected() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())

    // Largest first: .cache holds the biggest file.
    #expect(state.selected == [0])
    #expect(state.node(at: [0])?.name == ".cache")

    try press(state, "space")
    #expect(state.marks.count == 1)
    #expect(state.plan().bytes == 300_000, "the whole hidden directory")

    // Enter descends, Escape comes back out.
    try press(state, "enter")
    #expect(!state.crumbs.isEmpty)
    try press(state, "escape escape")
    #expect(state.crumbs.isEmpty)

    // Space twice more leaves the mark as it was.
    try press(state, "space space")
    #expect(state.marks.count == 1)
    #expect(state.marks.items.first?.bytes == 300_000)
}

/// A subdivided directory keeps a band at the top for its own name, and its
/// children start below it. That is what makes the inner tiles selectable:
/// the parent's name never covers them.
@MainActor
@Test func aParentsNameGetsItsOwnBandAboveItsChildren() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let junk = try childCrumbs(state, [], "junk")
    let tiles = try #require(state.layout())
    let parent = try #require(tiles.first { $0.crumbs == junk })
    let band = try #require(
        parent.header,
        "junk is subdivided, so it keeps a band"
    )
    let childrenTop =
        tiles
        .filter { $0.crumbs.starts(with: junk) && $0.crumbs.count > 1 }
        .map(\.rect.y)
        .min() ?? .infinity
    #expect(
        childrenTop >= band.bottom - .ulpOfOne,
        "children start at \(childrenTop) but the band ends at \(band.bottom)"
    )
    #expect(band.h >= 8, "a band has to be tall enough to read: \(band.h)")
    let bands = state.prepare().labels.filter { $0.header != nil }.count
    #expect(bands >= 1, "the parent's own label is placed in a band")
}

@MainActor
@Test func hoveringReportsTheTileUnderThePointer() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    // A leaf tile, so "the deepest tile under the pointer" is unambiguous.
    let tiles = try #require(state.layout())
    let leaves = tiles.filter { tile in
        !tiles.contains {
            $0.crumbs.count > tile.crumbs.count
                && $0.crumbs.starts(with: tile.crumbs)
        }
    }
    let biggest = try #require(leaves.max { $0.rect.area < $1.rect.area })
    let rect = try #require(state.tileRect(biggest.crumbs))

    state.pointerMoved(to: centre(state, of: rect))
    #expect(state.hovered == biggest.crumbs)
    #expect(state.pointerActive)
    #expect(state.pointer != nil)
    #expect(state.actionTarget == biggest.crumbs)
}

@MainActor
@Test func typingFiltersLiveAndEnterShowsOnlyTheMatches() async throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())

    try press(state, "/")
    typeText(state, "BLOB")
    // The search runs off the main actor; let it land.
    try await awaitSearch(state)
    // Live: two matches, nothing hidden yet, the rest only dimmed.
    let matches = try #require(state.matches, "matching as it is typed")
    let keep = try childCrumbs(state, [], "keep")
    #expect(matches.count == 2, "junk/blob.bin and .cache/blob.bin")
    #expect(!state.filterApplied)
    #expect(matches.keep(keep) == nil, "keep holds no blob")
    // Dimmed, not hidden: a non-match is still drawn while typing.
    #expect(namesDrawn(state).contains("deeper"))
    // junk/deeper holds no blob either, and is large enough to be drawn.
    let deeper = try #require(state.crumbs(for: tree.path("junk/deeper")))
    let deeperTile = zip(state.layout() ?? [], state.prepare().tiles).first {
        $0.0.crumbs == deeper
    }
    #expect(deeperTile?.1.filtered == .out)

    // Enter: only the matches, and the largest selected for marking.
    try press(state, "enter")
    let drawn = namesDrawn(state)
    #expect(state.filterApplied)
    #expect(!drawn.contains { $0 == "keep" || $0 == "deeper" }, "\(drawn)")
    #expect(drawn.filter { $0 == "blob.bin" }.count == 2, "\(drawn)")
    #expect(
        state.selected.flatMap { state.path(at: $0) }
            == tree.path(".cache/blob.bin")
    )

    // Escape gives everything back.
    try press(state, "escape")
    #expect(state.matches == nil && !state.filterApplied)
    #expect(namesDrawn(state).contains("deeper"))
}

@MainActor
@Test func theHelpOverlayOpensAndCloses() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    try press(state, "?")
    #expect(state.showHelp)
    // While it is open it owns the keyboard.
    let selected = state.selected
    #expect(try press(state, "right"))
    #expect(state.selected == selected)
    try press(state, "escape")
    #expect(!state.showHelp)
}

@MainActor
@Test func theTreemapZoomsAndResets() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let middle = (
        x: Double(state.treemapSize.width) / 2,
        y: Double(state.treemapSize.height) / 2
    )
    state.zoom(atX: middle.x, y: middle.y, factor: 1.5, descend: false)
    #expect(state.view.scale > 1, "scale after zooming: \(state.view.scale)")
    try press(state, "0")
    #expect(state.view.scale == 1)

    // The keys zoom about the middle, never below the whole view.
    try press(state, "= =")
    #expect(abs(state.view.scale - 1.25 * 1.25) < 1e-9)
    try press(state, "- - - -")
    #expect(state.view.scale == ViewTransform.minScale)
}

/// `⌘=` / `⌘-` / `⌘0` (and ctrl) change the rem, which every size in the
/// app is expressed in, and the mosaic's header band follows it.
@MainActor
@Test func interfaceZoomScalesTheRemAndTheHeaderBand() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let junk = try childCrumbs(state, [], "junk")
    let base = state.rem
    let band = { () -> (option: Double, drawn: Double?) in
        (
            state.effectiveLayoutOptions.header,
            state.layout()?.first { $0.crumbs == junk }?.header?.h
        )
    }
    let baseBand = band()
    #expect(baseBand.drawn == baseBand.option, "the layout runs with it")

    try press(state, "ctrl-=")
    let zoomed = state.rem
    #expect(zoomed > base, "\(zoomed) after zooming in from \(base)")
    let zoomedBand = band()
    #expect(
        abs(zoomedBand.option / baseBand.option - zoomed / base) < 0.01,
        "the band scales with the rem: \(baseBand) -> \(zoomedBand)"
    )
    #expect(zoomedBand.drawn == zoomedBand.option)
    // The stored options are the user's: only the effective ones scale.
    #expect(state.layoutOptions.header == LayoutOptions().header)

    try press(state, "ctrl-- ctrl--")
    #expect(state.rem < base, "zooming out goes below the default")
    try press(state, "ctrl-0")
    #expect(abs(state.rem - base) < 0.01, "ctrl 0 resets")
}

/// Regression: the wheel magnified toward the deepest directory under the
/// pointer, then went into the *top-level* one containing it, so the screen
/// after the descent was never the area that was zoomed into.
@MainActor
@Test func theWheelGoesIntoTheDirectoryItZoomedInto() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    // Point at the middle of junk/deeper's contents: a directory one level
    // below a top-level one.
    let junk = try childCrumbs(state, [], "junk")
    let deeper = try childCrumbs(state, junk, "deeper")
    let body = try #require(state.tileBody(deeper), "deeper is drawn")
    let point = CGPoint(x: body.x + body.w / 2, y: body.y + body.h / 2)

    var entered: [Int]?
    for _ in 0..<40 {
        // One notch at a time, as a wheel sends them.
        if state.scroll(at: point, lines: 1, shift: false) == .changedLevel {
            entered = state.crumbs
            break
        }
        #expect(state.crumbs.isEmpty)
    }
    #expect(
        entered == deeper,
        "descended into the pointed-at directory, not its top-level ancestor"
    )
    #expect(state.transition != nil, "and the tiles grow into place")
}

/// Regression, keyboard side: Enter on a deep selection enters that
/// directory, and on a file enters the directory holding it.
@MainActor
@Test func enterOpensTheSelectedDirectoryAtAnyDepth() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let junk = try childCrumbs(state, [], "junk")
    let deeper = try childCrumbs(state, junk, "deeper")
    state.select(deeper)
    state.descend()
    #expect(state.crumbs == deeper)

    try press(state, "escape escape escape")
    state.goTo([])
    let blob = try childCrumbs(state, junk, "blob.bin")
    state.select(blob)
    state.descend()
    #expect(state.crumbs == junk, "a file opens its directory")
}

/// The mark key acts on what the pointer is over when the pointer moved
/// last, and on the keyboard selection after an arrow.
@MainActor
@Test func theMarkKeyFollowsThePointerUntilTheKeyboardMoves() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    // Point at junk's name band, which belongs to junk itself (its body
    // belongs to its children). junk is not the default selection, .cache
    // is.
    let junk = try childCrumbs(state, [], "junk")
    let band = try #require(
        state.layout()?.first { $0.crumbs == junk }?.header,
        "junk is drawn with a band"
    )
    #expect(state.selected != junk)
    state.pointerMoved(to: centre(state, of: band))

    try press(state, "space")
    #expect(state.marks.items.map(\.path) == [tree.path("junk")])
    #expect(state.selected == junk)

    // An arrow hands control back to the keyboard selection.
    try press(state, "right")
    #expect(!state.pointerActive)
}

/// Regression: after descending, tiles resolved against the scanned root
/// instead of the directory drawn, so labels, hover and marks named
/// strangers.
@MainActor
@Test func afterDescendingEveryTileIsInsideTheDirectoryDrawn() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let junk = try childCrumbs(state, [], "junk")
    state.select(junk)
    state.descend()
    #expect(state.crumbs == junk)

    let tiles = try #require(state.layout())
    let paths = tiles.compactMap { state.path(at: $0.crumbs) }
    #expect(!paths.isEmpty)
    for path in paths {
        #expect(path.starts(with: tree.path("junk")), "\(path) is outside")
    }
    for label in state.prepare().labels.map(\.text) {
        #expect(
            ["blob.bin", "deeper", "more.bin"].contains(label)
                || label.hasPrefix("+"),
            "label \(label) does not belong to junk"
        )
    }

    // Space on the selection marks something inside junk, never elsewhere.
    state.select(try childCrumbs(state, junk, "blob.bin"))
    try press(state, "space")
    #expect(state.marks.items.map(\.path) == [tree.path("junk/blob.bin")])
    #expect(state.marks.items.first?.bytes == 200_000)

    // And the mark is drawn on the right tile: its crumbs resolve here.
    let hatched = state.prepare().tiles.filter(\.marked).count
    #expect(hatched == 1, "exactly the marked tile is hatched")
}

@MainActor
@Test func wideningReusesTheTreeItHasAndReadsOnlyTheRest() async throws {
    let tree = try fixture()
    let inner = tree.path("junk")
    let state = try stateOver(inner, hooks: Hooks())
    state.diskRoot = tree.root
    let before = state.tree?.files

    // The trail runs from "/", and the scanned root sits under its parents.
    let trail = state.breadcrumbs()
    #expect(trail.first?.label == "/")
    #expect(trail.first?.crumb == .above("/"))
    #expect(
        trail.contains(
            TrailStep(
                label: tree.root.lastComponent?.string ?? "",
                crumb: .above(tree.root)
            )
        )
    )
    #expect(trail.last == TrailStep(label: "junk", crumb: .tree([])))

    // Written after the first scan: a memoized subtree cannot see it.
    try tree.write("junk/late.bin", count: 4_096)

    try press(state, "g")
    // The old tree stays on screen while the wider one is read.
    #expect(state.tree != nil)
    #expect(state.scanRoot == tree.root)
    #expect(state.rootPath == inner)
    try await finishScan(state)
    #expect(state.rootPath == tree.root)
    let wider = try #require(state.tree, "the wider tree")
    #expect(
        wider.childNamed("junk")?.files == before,
        "junk was reused, not walked again"
    )
    #expect(wider.childNamed("keep") != nil, "what is outside it was walked")
    #expect(
        state.selected.flatMap { state.node(at: $0) }?.name == "junk",
        "where you came from"
    )
    #expect(state.crumbs.isEmpty)
    #expect(state.windowTitle.hasSuffix(tree.root.lastComponent?.string ?? ""))
}

@MainActor
@Test func enterBeforeTheSearchLandsAppliesItWhenItDoes() async throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    try press(state, "/")
    typeText(state, "blob")
    // Nothing can land between these: the search answers on the main
    // actor, which this test holds until it waits.
    #expect(state.finding)
    try press(state, "enter")
    try await awaitSearch(state)
    #expect(state.filterApplied, "Enter was not lost to a search in flight")
    #expect(state.matches?.count == 2)
    #expect(!state.findOpen)
}

@MainActor
@Test func aCrumbListsItsSiblingsAndJumpsSideways() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    // Into junk, so the trail ends in a crumb that has siblings.
    let junk = try childCrumbs(state, [], "junk")
    state.goTo(junk)

    guard case .tree(let last) = state.breadcrumbs().last?.crumb else {
        Issue.record("the trail ends in the tree")
        return
    }
    // The step's menu lists the folders beside it, from the tree, as the
    // system's menu shows them when it opens.
    let parent = Array(last.dropLast())
    let rows = state.siblings(parent).rows
    let names = rows.map(\.name)
    #expect(names.contains(".cache") && names.contains("keep"))
    #expect(names.contains("junk"), "where you are is among them")

    // Choosing one goes sideways, straight into it.
    let cache = try #require(rows.first { $0.name == ".cache" })
    state.chooseSibling(parent: parent, index: cache.index)
    #expect(state.crumbs == (try childCrumbs(state, [], ".cache")))
}

@MainActor
@Test func markingADirectoryMarksEverythingInsideIt() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let junk = try #require(state.crumbs(for: tree.path("junk")))
    let deeper = try #require(state.crumbs(for: tree.path("junk/deeper")))

    // Marked inside first, then the directory around it: one mark remains,
    // and it covers the inner one.
    state.toggleMark(deeper)
    state.toggleMark(junk)
    #expect(
        state.marks.items.map(\.path) == [tree.path("junk")],
        "the inner mark is absorbed"
    )
    #expect(state.notice?.text.contains("now covers 1 mark inside it") == true)

    // Every tile inside it is drawn marked: the ones below the mark are
    // "covered", which paints the same fill and label.
    let tiles = try #require(state.layout())
    let mosaic = state.prepare()
    let inside = zip(tiles, mosaic.tiles).filter { tile, _ in
        tile.crumbs.starts(with: junk) && tile.crumbs != junk
    }
    #expect(inside.count >= 2, "blob.bin and deeper are drawn inside junk")
    #expect(inside.allSatisfy { $0.1.covered }, "all of it goes with junk")
    #expect(
        zip(tiles, mosaic.tiles).first { $0.0.crumbs == junk }?.1.marked == true
    )

    // Marking something inside it is refused, and says why.
    state.toggleMark(deeper)
    #expect(state.marks.count == 1)
    #expect(state.notice?.text.contains("goes with the marked") == true)
    #expect(state.notice?.status == .warning)

    // Unmarking the directory unmarks everything.
    state.toggleMark(junk)
    #expect(state.marks.isEmpty)
}

// MARK: - Handing the marks over

/// The Rust test removed `junk` in the app; disktree removes nothing itself
/// now. The review copies a command instead, the user runs it, and the
/// state sees the marked path go, measures, and scans again.
@MainActor
@Test func theReviewCopiesACommandThatRemovesOnlyWhatIsMarked() async throws {
    let tree = try fixture()
    let hooks = Hooks()
    let state = try stateOver(tree.root, hooks: hooks)

    // Mark "junk" directly, which is what clicking its tile would do.
    let junk = try childCrumbs(state, [], "junk")
    state.select(junk)
    state.toggleMark(junk)
    #expect(state.plan().bytes == 300_000)

    try press(state, "c")
    #expect(state.screen == .review)

    // `rm`, so the test never reaches the real Trash.
    try press(state, "p")
    try press(state, "enter")
    let command = try #require(hooks.copied.last, "Enter copies")
    #expect(command.hasPrefix("/bin/rm -rfx -- \\\n"))
    #expect(command.contains(shellQuoted(tree.path("junk"))))
    #expect(command == state.cleanupCommand())
    #expect(
        state.toast?.text
            == "Copied: rm for 1 item, 293 KiB — paste it into Terminal"
    )
    #expect(tree.exists("junk"), "copying removes nothing")

    // The user pastes it into a terminal.
    #expect(try await runInShell(command) == 0)
    #expect(!tree.exists("junk"), "junk is gone")
    #expect(tree.exists("keep/notes.txt"), "an unmarked directory is kept")
    #expect(tree.exists(".cache/blob.bin"), "an unmarked hidden one too")

    // The ticker, or the app coming back to the front, looks again.
    let epoch = state.scanEpoch
    await state.checkDisk()
    #expect(state.gone == [tree.path("junk")])
    #expect(state.scanEpoch == epoch + 1, "a rescan started")
    #expect(state.tree == nil)
    #expect(state.screen == .explore)
    let notice = try #require(state.notice)
    #expect(notice.text.hasPrefix("1 marked item gone"))

    // Another look while the walk is in flight starts nothing new, and
    // says nothing new.
    state.notice = nil
    await state.checkDisk()
    #expect(state.scanEpoch == epoch + 1)
    #expect(state.notice == nil)
    state.notice = notice

    try await finishScan(state)
    #expect(state.marks.isEmpty, "a mark whose path is gone is dropped")
    #expect(state.gone.isEmpty)
    #expect(state.spaceBaseline == nil)
    #expect(state.tree?.childNamed("junk") == nil)
    #expect(state.tree?.childNamed("keep") != nil)
    #expect(state.tree?.childNamed(".cache") != nil)
    #expect(state.notice == notice, "the report stays up")
}

/// Escape leaves the review: the list is kept, and nothing on disk has
/// changed. (The Rust review's delete dialog cancelled the same way.)
@MainActor
@Test func escapeLeavesTheReviewWithTheListKept() throws {
    let tree = try fixture()
    let hooks = Hooks()
    let state = try stateOver(tree.root, hooks: hooks)
    state.toggleMark(try childCrumbs(state, [], "junk"))
    try press(state, "c")
    #expect(state.screen == .review)
    try press(state, "escape")
    #expect(state.screen == .explore)
    #expect(state.marks.count == 1, "the list is kept")
    #expect(tree.exists("junk"))
    #expect(hooks.copied.isEmpty && hooks.revealed.isEmpty)
}

/// The command style is a choice the key makes, and the copied command
/// follows it.
@MainActor
@Test func theReviewSwitchesTheCommandStyle() throws {
    let tree = try fixture()
    let hooks = Hooks()
    let state = try stateOver(tree.root, hooks: hooks)
    state.toggleMark(try childCrumbs(state, [], "junk"))
    try press(state, "c")

    try press(state, "m enter")
    #expect(state.commandStyle == .trash)
    #expect(hooks.copied.last?.hasPrefix("/usr/bin/trash \\\n") == true)
    #expect(state.toast?.text.hasPrefix("Copied: trash for 1 item") == true)
    #expect(state.toast?.status == .success)
    #expect(state.notice == nil, "a passing confirmation, not a notice")
    try press(state, "p enter")
    #expect(state.commandStyle == .remove)
    #expect(hooks.copied.last?.hasPrefix("/bin/rm -rfx -- \\\n") == true)
    #expect(hooks.copied.count == 2)
    try press(state, "!")
    #expect(state.marks.isEmpty)
    #expect(state.spaceBaseline == nil)
    #expect(state.cleanupCommand() == nil)
    try press(state, "enter")
    #expect(hooks.copied.count == 2, "nothing to copy")
    #expect(state.notice?.text == "nothing is marked")
    #expect(state.screen == .review)
}

/// Reversible is the default: the trash, which Put Back and the Trash
/// window both undo.
@MainActor
@Test func theTrashIsTheDefault() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    #expect(state.commandStyle == .trash)
}

@MainActor
@Test func revealInFinderShowsTheTargets() throws {
    let tree = try fixture()
    let hooks = Hooks()
    let state = try stateOver(tree.root, hooks: hooks)
    let junk = try childCrumbs(state, [], "junk")
    let deeper = try childCrumbs(state, junk, "deeper")
    let keep = try childCrumbs(state, [], "keep")
    state.toggleMark(deeper)
    state.toggleMark(keep)
    try press(state, "c f")
    #expect(hooks.revealed == [[tree.path("junk/deeper"), tree.path("keep")]])
    #expect(state.toast?.text.hasPrefix("Revealed 2 items in Finder") == true)
    #expect(state.toast?.text.contains("Put Back") == true)
    #expect(state.notice == nil)

    // In the treemap, `f` shows the tile a key acts on. (The first Escape
    // takes the toast down.)
    try press(state, "escape escape")
    #expect(state.screen == .explore)
    state.select(junk)
    try press(state, "f")
    #expect(hooks.revealed.last == [tree.path("junk")])
    #expect(state.selected == junk)
}

/// Finder opens a window per folder of a selection; past twelve, the
/// command is the better tool, and the notice says so.
@MainActor
@Test func revealInFinderStopsAtTwelveFolders() throws {
    let tree = try TempTree(
        (0..<13).map { (path: "d\($0)/file.bin", count: 100 + $0) }
    )
    let hooks = Hooks()
    let state = try stateOver(tree.root, hooks: hooks)
    for index in 0..<13 {
        let folder = try childCrumbs(state, [], "d\(index)")
        state.toggleMark(try childCrumbs(state, folder, "file.bin"))
    }
    #expect(state.plan().targets.count == 13)
    state.revealMarkedInFinder()
    #expect(hooks.revealed.isEmpty)
    #expect(state.notice?.text.contains("13 folders") == true)
    #expect(state.notice?.status == .warning)

    state.unmark(tree.path("d0/file.bin"))
    state.revealMarkedInFinder()
    #expect(hooks.revealed.count == 1)
    #expect(hooks.revealed.first?.count == 12)
}

/// A hand-over while a walk is out. `g` widens to the whole disk, a long
/// walk, and the old tree and the review stay usable meanwhile, so the
/// command can run before it lands — and the walk reuses the subtree
/// measured before, marked path and all. The hand-over is still said once,
/// and the tree that ends up on screen was read after the removal.
@MainActor
@Test func aHandOverDuringAWalkIsSaidOnceAndReadAgain() async throws {
    let tree = try fixture()
    let hooks = Hooks()
    let state = try stateOver(tree.path("junk"), hooks: hooks)
    state.diskRoot = tree.root
    state.toggleMark(try childCrumbs(state, [], "deeper"))
    try press(state, "g")
    let epoch = state.scanEpoch
    #expect(state.scanRoot == tree.root && state.tree != nil)
    try press(state, "c p enter")
    let command = try #require(hooks.copied.last)
    #expect(try await runInShell(command) == 0)
    #expect(!tree.exists("junk/deeper"))

    // The ticker's look; the walk may have landed while the command ran,
    // which ends the hand-over the same way.
    await state.checkDisk()
    let notice = try #require(state.notice, "the hand-over is said")
    #expect(notice.text.hasPrefix("1 marked item gone"))
    #expect(state.screen == .explore)

    try await settleScans(state)
    #expect(state.scanEpoch == epoch + 1, "read again, once")
    #expect(state.rootPath == tree.root, "the widening asked for is kept")
    #expect(state.marks.isEmpty)
    let junk = try #require(state.tree?.childNamed("junk"))
    #expect(junk.childNamed("deeper") == nil, "read after the removal")
    #expect(junk.childNamed("blob.bin") != nil)
    #expect(state.notice == notice, "and said once")
}

/// The walk lands before any look at the disk has seen the marks go: the
/// landing ends the hand-over — says what it was worth before the marks
/// and their baseline are dropped — and reads again, since the tree it
/// brought still holds what went.
@MainActor
@Test func aWalkThatLandsAfterAHandOverSaysSoAndReadsAgain() async throws {
    let tree = try fixture()
    let hooks = Hooks()
    let state = try stateOver(tree.path("junk"), hooks: hooks)
    state.diskRoot = tree.root
    state.toggleMark(try childCrumbs(state, [], "deeper"))
    try press(state, "g")
    let epoch = state.scanEpoch
    try press(state, "c p enter")
    let command = try #require(hooks.copied.last)
    #expect(try await runInShell(command) == 0)

    try await finishScan(state)
    let notice = try #require(state.notice, "not dropped without a word")
    #expect(notice.text.hasPrefix("1 marked item gone"))
    #expect(state.screen == .explore)
    try await settleScans(state)
    #expect(state.scanEpoch == epoch + 1, "the stale tree is read again")
    #expect(state.tree?.childNamed("junk")?.childNamed("deeper") == nil)
    #expect(state.marks.isEmpty && state.spaceBaseline == nil)
    #expect(state.notice == notice)
}
