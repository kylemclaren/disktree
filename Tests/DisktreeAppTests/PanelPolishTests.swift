import AppKit
import DisktreeCore
import Foundation
import SwiftUI
import System
import Testing

@testable import DisktreeApp

// The side panel's feel: marked rows that are clicked or dragged out as
// files but never both, what a drag offers to the Trash, Finder and
// Terminal, the tooltips' keys, a row going from disk that stays the row it
// was, the native controls it is built from, and Reduce Motion, which
// changes how the panel moves and never what it shows.
//
// No test here starts a drag session or touches the pasteboard for real:
// the views' hooks are listened to instead.

@MainActor
@Suite struct PanelPolishTests {
    // MARK: Marked rows as files

    /// A drag area on its own in a window, listened to.
    @MainActor
    private final class Area {
        let view = PanelDragView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 20)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 20),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        var clicks = 0
        var drags = 0

        init(url: URL?) {
            _ = NSApplication.shared
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(view)
            view.url = url
            view.onClick = { [unowned self] in clicks += 1 }
            view.startDrag = { [unowned self] _ in drags += 1 }
        }

        func event(
            _ type: NSEvent.EventType,
            x: CGFloat
        ) throws -> NSEvent {
            try PanelHarness.mouse(
                type,
                at: NSPoint(x: x, y: 10),
                in: window
            )
        }

        /// Press at 20, move by each of `moves`, and let go.
        func press(moving moves: [CGFloat] = []) throws {
            view.mouseDown(with: try event(.leftMouseDown, x: 20))
            for move in moves {
                view.mouseDragged(
                    with: try event(.leftMouseDragged, x: 20 + move)
                )
            }
            view.mouseUp(
                with: try event(.leftMouseUp, x: 20 + (moves.last ?? 0))
            )
        }
    }

    @Test func aMarkedRowIsClickedOrDraggedNeverBoth() throws {
        let area = Area(url: URL(filePath: "/tmp/disktree-mark"))
        defer { closeWindow(area.window) }

        try area.press()
        #expect(area.clicks == 1 && area.drags == 0)

        // A finger wobbles as it clicks: short of the threshold it is
        // still a click.
        try area.press(moving: [1, PanelDragView.threshold - 1])
        #expect(area.clicks == 2 && area.drags == 0)

        // Past it, a drag, started once however far it goes, and never a
        // click as well.
        try area.press(moving: [2, PanelDragView.threshold, 30, 60])
        #expect(area.clicks == 2 && area.drags == 1)
    }

    @Test func aGoneMarkIsNeitherClickedNorDragged() throws {
        let area = Area(url: nil)
        defer { closeWindow(area.window) }
        try area.press()
        try area.press(moving: [10, 40])
        #expect(area.clicks == 0 && area.drags == 0)
        #expect(!area.view.isAccessibilityElement())
    }

    @Test func aMarkIsOfferedOutsideAsFinderOffersAFile() {
        let outside = PanelDragView.operations(.outsideApplication)
        // The Dock's Trash takes a delete; Finder a move, or a copy across
        // volumes; Terminal anything that carries the path.
        for operation: NSDragOperation in [
            .delete, .move, .copy, .generic, .link,
        ] {
            #expect(outside.contains(operation), "\(operation)")
        }
        // Inside the app nothing takes it: the window would scan it.
        #expect(PanelDragView.operations(.withinApplication).isEmpty)
    }

    @Test func aDraggedMarkCarriesItsFileURL() throws {
        let fixture = try PanelHarness.fixture()
        defer { fixture.remove() }
        // A name with a space, as a path is spelled on disk, not as a URL
        // escapes it.
        let path = fixture.path("with space")
        try FileManager.default.createDirectory(
            atPath: path.string,
            withIntermediateDirectories: true
        )
        let url = URL(filePath: path.string)
        let item = PanelDragView.item(url, at: NSPoint(x: 100, y: 50))
        let carried = try #require(item.item as? NSURL)
        #expect(carried.isFileURL)
        #expect(carried.path == path.string)
        // Its icon under the pointer, centred on it.
        #expect(item.draggingFrame.midX == 100)
        #expect(item.draggingFrame.midY == 50)
        #expect(item.draggingFrame.width == 32)
    }

    @Test func thePanelsMarkedRowsShowTheirTilesAndGoneOnesDoNot() throws {
        let fixture = try PanelHarness.fixture()
        defer { fixture.remove() }
        let state = try PanelHarness.state(fixture)
        try PanelScene.goneWithGain.apply(to: state, fixture: fixture)
        let tree = try #require(state.tree)
        let (window, host) = PanelHarness.window(state)
        defer { closeWindow(window) }

        let areas = PanelHarness.views(PanelDragView.self, in: host)
            .filter { $0.window != nil }
        // One per listed mark; the two gone from disk offer nothing.
        let offered = areas.compactMap(\.url).map(\.path)
        #expect(offered == [fixture.path(".cache").string])
        #expect(areas.count(where: { $0.url == nil }) == 2)
        #expect(
            areas.allSatisfy {
                $0.toolTip?.contains(fixture.root.lastComponent?.string ?? "")
                    == true
            }
        )

        // A click on the one still there shows it, selected, in its
        // directory: the scanned root, for a mark at its top.
        let live = try #require(areas.first { $0.url != nil })
        state.goTo(try #require(PanelHarness.crumbs("junk", in: tree)))
        let centre = live.convert(
            NSPoint(x: live.bounds.midX, y: live.bounds.midY),
            to: nil
        )
        live.mouseDown(
            with: try PanelHarness.mouse(.leftMouseDown, at: centre, in: window)
        )
        live.mouseUp(
            with: try PanelHarness.mouse(.leftMouseUp, at: centre, in: window)
        )
        #expect(state.crumbs == [])
        #expect(state.selected == PanelHarness.crumbs(".cache", in: tree))
    }

    // MARK: Words

    @Test func theKeysTheTooltipsNameDoWhatTheButtonsDo() throws {
        // Each control's tooltip ends with the key that does the same from
        // anywhere in the window: pressed, it acts on what the button acts
        // on, the selection.
        #expect(PanelHelp.open.hasSuffix("· Enter"))
        #expect(PanelHelp.reveal.hasSuffix("· f"))
        #expect(PanelHelp.mark.hasSuffix("· Space"))
        #expect(PanelHelp.unmark.hasSuffix("· Space"))
        #expect(PanelHelp.review.hasSuffix("· c"))

        let fixture = try PanelHarness.fixture()
        defer { fixture.remove() }
        let state = try PanelHarness.state(fixture)
        let tree = try #require(state.tree)
        let junk = try #require(PanelHarness.crumbs("junk", in: tree))
        var shown: [FilePath] = []
        state.showInFinder = { shown += $0 }
        state.selected = junk

        // Reveal in Finder: `revealInFinder(target)`.
        #expect(state.handleKey(KeyStroke("f")))
        #expect(shown == [fixture.path("junk")])
        // Mark for removal, then Unmark: `toggleMark(target)`.
        #expect(state.handleKey(KeyStroke("space")))
        #expect(state.marks.contains(fixture.path("junk")))
        #expect(state.handleKey(KeyStroke("space")))
        #expect(!state.marks.contains(fixture.path("junk")))
        // Review: the review screen, once something is marked.
        state.toggleMark(junk)
        #expect(state.handleKey(KeyStroke("c")))
        #expect(state.screen == .review)
        state.screen = .explore
        // Open: `goTo(target)`.
        state.selected = junk
        #expect(state.handleKey(KeyStroke("enter")))
        #expect(state.crumbs == junk)
    }

    @Test func aMarkedRowsTooltipSaysWhatAClickAndADragDo() {
        let help = PanelHelp.marked("~/Library/Caches/thing")
        #expect(help.hasPrefix("~/Library/Caches/thing\n"))
        #expect(help.contains("Trash"))
        #expect(help.contains("Terminal"))
        #expect(PanelHelp.finding("~/app/node_modules").hasPrefix("~/app/"))
    }

    // MARK: Native controls

    @Test(arguments: PanelHarness.Look.allCases)
    func theMainActionWearsTheHighlight(look: PanelHarness.Look) throws {
        // Marking is what the panel is for: its button is the one filled
        // with the highlight. Once the selection is marked the same button
        // takes the accent, and the highlight leaves it, so the state is
        // seen where the pointer is.
        let theme = look == .dark ? Theme.dark : Theme.light
        let fixture = try PanelHarness.fixture()
        defer { fixture.remove() }
        let selection = 0.0...420.0
        let unmarked = try PanelHarness.state(fixture)
        try PanelScene.directory.apply(to: unmarked, fixture: fixture)
        let marking = try PanelHarness.render(
            unmarked,
            look: look,
            preset: true
        )
        let marked = try PanelHarness.state(fixture)
        try PanelScene.marked.apply(to: marked, fixture: fixture)
        let unmarking = try PanelHarness.render(
            marked,
            look: look,
            preset: true
        )
        let lit = try marking.pixels(near: theme.highlight, rows: selection)
        #expect(lit > 1_500, "the mark button is filled: \(lit)")
        let left = try unmarking.pixels(
            near: theme.highlight,
            rows: selection
        )
        #expect(left * 4 < lit, "\(left) of \(lit) still lit")
        #expect(
            try unmarking.pixels(near: theme.inspectorAccent, rows: selection)
                > 1_500
        )
    }

    @Test(arguments: PanelHarness.Look.allCases)
    func theReviewIsProminentOnlyWithSomethingToReview(
        look: PanelHarness.Look
    ) throws {
        // The accent fills the way to the review once something is marked;
        // with nothing marked the button is there, quiet, and unfilled.
        let theme = look == .dark ? Theme.dark : Theme.light
        let fixture = try PanelHarness.fixture()
        defer { fixture.remove() }
        let bottom = 800.0...900.0
        let idle = try PanelHarness.state(fixture)
        let quiet = try PanelHarness.render(idle, look: look, preset: true)
        let busy = try PanelHarness.state(fixture)
        try PanelScene.marked.apply(to: busy, fixture: fixture)
        let prominent = try PanelHarness.render(busy, look: look, preset: true)
        #expect(
            try quiet.pixels(near: theme.inspectorAccent, rows: bottom) < 50
        )
        #expect(
            try prominent.pixels(near: theme.inspectorAccent, rows: bottom)
                > 2_000
        )
    }

    // MARK: Reduce Motion

    /// The scenes where something moves: numbers, rows, the strike, the
    /// mark's symbol, the notice.
    nonisolated static let moving: [PanelScene] = [
        .marked, .covered, .manyMarks, .goneWithGain, .goneNothingMeasured,
        .projection, .notice, .scanError, .filesMetric,
    ]

    @Test(arguments: moving, PanelHarness.Look.allCases)
    func reduceMotionChangesHowThePanelMovesNeverWhatItShows(
        scene: PanelScene,
        look: PanelHarness.Look
    ) throws {
        let fixture = try PanelHarness.fixture()
        defer { fixture.remove() }
        let state = try PanelHarness.state(fixture)
        try scene.apply(to: state, fixture: fixture)
        let moving = try PanelHarness.render(state, look: look)
        let still = try PanelHarness.render(
            state,
            look: look,
            reduceMotion: true,
            name: "\(scene.rawValue)-reduced"
        )
        // At rest the two are the same drawing, pixel row for pixel row:
        // a struck-through row is struck all the way, a figure shows its
        // whole number, a symbol its final state.
        let all = 0.0...900.0
        #expect(still.profile(rows: all) == moving.profile(rows: all))
        #expect(still.drawn() > 1_500)
    }

    // MARK: Motion

    @Test func aRowGoingFromDiskKeepsItsViewsSoItsLineCanBeDrawn() throws {
        // The line through a gone row grows from its start only if the
        // row that was there is the row that is struck: rebuilt, it would
        // arrive struck already, and its drag area would be swapped under
        // the pointer. The drag area stands for the row's views.
        let fixture = try PanelHarness.fixture()
        defer { fixture.remove() }
        let state = try PanelHarness.state(fixture)
        let tree = try #require(state.tree)
        let junk = fixture.path("junk")
        state.marks.toggle(
            try #require(PanelHarness.target("junk", in: fixture, tree: tree))
        )
        let (window, host) = PanelHarness.window(state)
        defer { closeWindow(window) }
        let areas = {
            PanelHarness.views(PanelDragView.self, in: host)
                .filter { $0.window != nil }
        }
        let area = try #require(areas().first)
        #expect(area.url?.path == junk.string)

        state.gone = [junk]
        host.layoutSubtreeIfNeeded()
        // The same one, and only it: no second copy of the row coming in
        // while the first goes out.
        #expect(areas().count == 1)
        #expect(areas().first === area)
        #expect(area.url == nil)
    }

    @Test func withReduceMotionANoticeTakesItsRoomAtOnce() throws {
        // Closing up is movement: under Reduce Motion the column gives the
        // notice, pinned over the disk, its room in the same frame it
        // arrives in, and only the notice itself fades.
        let fixture = try PanelHarness.fixture()
        defer { fixture.remove() }
        let state = try PanelHarness.state(fixture)
        try PanelScene.manyMarks.apply(to: state, fixture: fixture)
        let (window, host) = PanelHarness.window(state, reduceMotion: true)
        defer { closeWindow(window) }
        let before = try listsHeight(in: host)

        state.notice = Notice("Revealed 3 items in Finder", status: .success)
        host.layoutSubtreeIfNeeded()
        let now = try listsHeight(in: host)

        // Where the lists come to rest: a panel drawn with the notice from
        // the start.
        let (rested, restedHost) = PanelHarness.window(
            state,
            reduceMotion: true
        )
        defer { closeWindow(rested) }
        #expect(now < before)
        #expect(now == (try listsHeight(in: restedHost)))
    }

    /// The room the scrolling column has above the disk pinned under it:
    /// the scroll view's height, less what the pinned part covers, which
    /// it is told as its bottom inset.
    private func listsHeight(in host: NSView) throws -> CGFloat {
        let lists = PanelHarness.views(NSScrollView.self, in: host)
            .filter { $0.window != nil }
        #expect(lists.count == 1)
        let column = try #require(lists.first)
        return column.frame.height - column.contentInsets.bottom
    }

    @Test func aGoneRowIsStruckThroughAndALiveOneIsNot() throws {
        // The same marks, one of them gone: only the rows band differs,
        // by the lines through the gone one.
        let fixture = try PanelHarness.fixture()
        defer { fixture.remove() }
        let state = try PanelHarness.state(fixture)
        try PanelScene.goneWithGain.apply(to: state, fixture: fixture)
        let gone = state.gone
        let struck = try PanelHarness.render(state, look: .dark)
        state.gone = []
        state.spaceBaseline = nil
        let whole = try PanelHarness.render(state, look: .dark)
        #expect(struck.drawn() != whole.drawn())
        #expect(!gone.isEmpty)
        // The selection above them is untouched.
        #expect(
            struck.profile(rows: 0...300) == whole.profile(rows: 0...300)
        )
    }
}
