// What the polish asks of the state: a pinch that meets stops it has to be
// pushed through, the smart-zoom tap, the outcomes the view turns into a
// feel under the fingers, the toast and the Quick Look target the keys can
// take away, the preferences a launch starts from, and the loose ends —
// a plan kept while nothing it is made of changes, a command that leaves
// out what is gone, a merged tail with a hover of its own, room for a
// name's descenders.
//
// Driven the way a person does, as the other state tests are: gestures and
// keys in, what changed read back. Nothing here touches the pasteboard,
// Finder, Quick Look's panel or the person's own defaults.

import AppKit
import CoreGraphics
import DisktreeCore
import Foundation
import System
import Testing

@testable import DisktreeApp

// MARK: - Helpers

private func file(_ name: String, _ bytes: UInt64) -> Node {
    Node.entry(name, kind: .file, bytes: bytes)
}

/// A state over a tree built in memory, at a root that is not on disk.
@MainActor
private func synthetic(_ children: [Node]) -> AppState {
    var root = Node.directory("synthetic", children: children)
    aggregate(&root, metric: .bytes)
    let state = AppState(
        root: "/nonexistent/disktree-polish",
        tree: root,
        options: ScanOptions(),
        depth: 3
    )
    Hooks().capture(state)
    state.treemapSize = treemapArea
    return state
}

/// Pinch by `factor` at `point` until the zoom stops moving; the outcomes
/// on the way.
@MainActor
private func pinchToStop(
    _ state: AppState,
    at point: CGPoint,
    factor: Double
) -> [ZoomOutcome] {
    var outcomes: [ZoomOutcome] = []
    for _ in 0..<200 {
        let outcome = state.magnify(at: point, factor: factor)
        outcomes.append(outcome)
        if outcome != .zoomed {
            break
        }
    }
    return outcomes
}

/// The middle of junk/deeper's contents in the fixture, where a pinch goes
/// into `deeper`.
@MainActor
private func deeperPoint(_ state: AppState) throws -> (CGPoint, [Int]) {
    let junk = try childCrumbs(state, [], "junk")
    let deeper = try childCrumbs(state, junk, "deeper")
    let body = try #require(state.tileBody(deeper), "deeper is drawn")
    let point = centre(state, of: body)
    #expect(state.zoomTarget(x: point.x, y: point.y) == deeper)
    return (point, deeper)
}

/// A key going down, as AppKit delivers one.
private func keyDown(
    _ keyCode: UInt16,
    _ characters: String,
    _ flags: NSEvent.ModifierFlags = []
) throws -> NSEvent {
    try #require(
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    )
}

// MARK: - Pinch detents

/// The user's ask: pinch zoom on the cells that feels like a physical
/// control. The zoom stops where the directory under the fingers fills the
/// view, says so once, and a squeeze of 12% more goes inside it.
@MainActor
@Test func aPinchStopsWhereTheDirectoryFillsTheViewAndASqueezeGoesIn() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let (point, deeper) = try deeperPoint(state)

    let way = pinchToStop(state, at: point, factor: 1.05)
    #expect(way.last == .reachedEdge, "\(way)")
    #expect(way.dropLast().allSatisfy { $0 == .zoomed }, "\(way)")
    #expect(state.crumbs.isEmpty, "stopped, not through")
    let rest = state.view
    let body = try #require(state.tileBody(deeper))
    let fit = min(
        ViewTransform.fitScale(body, area: treemapArea),
        ViewTransform.maxScale
    )
    #expect(
        abs(rest.scale - fit) < 1e-9,
        "at the stop, deeper's contents fill the view"
    )

    // 1.03 three times is 9% past the stop; the fourth is 12.6%.
    for _ in 0..<3 {
        #expect(state.magnify(at: point, factor: 1.03) == .none)
        #expect(state.view == rest, "the view holds still against it")
    }
    #expect(state.magnify(at: point, factor: 1.03) == .changedLevel)
    #expect(state.crumbs == deeper)
    #expect(state.transition != nil, "the tiles grow into place")
}

/// A wheel notch is a deliberate step: felt as it arrives at the stop, and
/// the next notch goes straight through, as it always did.
@MainActor
@Test func aWheelNotchGoesStraightThroughTheStop() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let (point, deeper) = try deeperPoint(state)
    var outcomes: [ZoomOutcome] = []
    for _ in 0..<60 {
        let outcome = state.scroll(at: point, lines: 1, shift: false)
        outcomes.append(outcome)
        if outcome == .changedLevel {
            break
        }
    }
    #expect(Array(outcomes.suffix(2)) == [.reachedEdge, .changedLevel])
    #expect(outcomes.filter { $0 == .reachedEdge }.count == 1)
    #expect(state.crumbs == deeper)

    // And out: felt at the whole view, through on the next notch.
    let middle = CGPoint(x: 550, y: 400)
    #expect(state.scroll(at: middle, lines: 1, shift: false) == .zoomed)
    #expect(state.scroll(at: middle, lines: -1, shift: false) == .reachedEdge)
    #expect(state.scroll(at: middle, lines: -1, shift: false) == .changedLevel)
    #expect(state.crumbs.count == deeper.count - 1)
}

/// Pinching out at the whole view needs the same squeeze before it goes
/// up; at the scanned root there is nowhere to go, and it stays a stop.
@MainActor
@Test func pinchingOutAtTheWholeViewNeedsTheSameSqueeze() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let junk = try childCrumbs(state, [], "junk")
    state.goTo(junk)
    let middle = CGPoint(x: 550, y: 400)
    #expect(state.magnify(at: middle, factor: 0.97) == .reachedEdge)
    // 0.97⁴ is past 1/1.12; three are not.
    for _ in 0..<3 {
        #expect(state.magnify(at: middle, factor: 0.97) == .none)
        #expect(state.crumbs == junk)
    }
    #expect(state.magnify(at: middle, factor: 0.97) == .changedLevel)
    #expect(state.crumbs.isEmpty)

    state.endMagnify()
    #expect(state.magnify(at: middle, factor: 0.9) == .reachedEdge)
    for _ in 0..<20 {
        #expect(state.magnify(at: middle, factor: 0.9) == .none)
    }
    #expect(state.crumbs.isEmpty && state.view == .identity)
}

/// After a pinch changes level it keeps magnifying the new one, but it
/// cannot change level again until the fingers lift: no tunnelling through
/// several levels in one motion.
@MainActor
@Test func onePinchChangesLevelOnce() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let (point, deeper) = try deeperPoint(state)
    _ = pinchToStop(state, at: point, factor: 1.05)
    var outcome = ZoomOutcome.none
    for _ in 0..<10 where outcome != .changedLevel {
        outcome = state.magnify(at: point, factor: 1.05)
    }
    #expect(outcome == .changedLevel && state.crumbs == deeper)

    // Not dead: the same pinch magnifies the level it went into.
    let middle = CGPoint(x: 550, y: 400)
    #expect(state.magnify(at: middle, factor: 1.2) == .zoomed)
    #expect(state.view.scale > 1)

    // Back out to the whole view and on: the floor is felt, but it holds.
    let back = pinchToStop(state, at: middle, factor: 0.9)
    #expect(back.last == .reachedEdge, "\(back)")
    for _ in 0..<10 {
        #expect(state.magnify(at: middle, factor: 0.9) == .none)
    }
    #expect(state.crumbs == deeper)

    // The fingers lift; the next pinch squeezes through, felt stop and all.
    state.endMagnify()
    outcome = .none
    var squeezes = 0
    while outcome != .changedLevel, squeezes < 10 {
        outcome = state.magnify(at: middle, factor: 0.95)
        squeezes += 1
    }
    #expect(outcome == .changedLevel)
    #expect(squeezes == 3, "0.95³ is past the push; the stop was felt")
    #expect(state.crumbs == Array(deeper.dropLast()))
}

/// The squeeze starts over when the pinch ends, and when the fingers move
/// over another directory.
@MainActor
@Test func theSqueezeStartsOverWithANewPinchOrDirectory() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let (point, deeper) = try deeperPoint(state)
    _ = pinchToStop(state, at: point, factor: 1.05)
    // 1.05² is short of 1.12, 1.05³ past it.
    #expect(state.magnify(at: point, factor: 1.05) == .none)
    #expect(state.magnify(at: point, factor: 1.05) == .none)
    state.endMagnify()
    #expect(state.magnify(at: point, factor: 1.05) == .none, "from nothing")
    #expect(state.magnify(at: point, factor: 1.05) == .none)
    #expect(state.magnify(at: point, factor: 1.05) == .changedLevel)
    #expect(state.crumbs == deeper)

    // Two directories the same size side by side: the same stop, but
    // another directory, so another squeeze.
    let two = synthetic([
        .directory("a", children: [file("x", 1_000), file("y", 1_000)]),
        .directory("b", children: [file("x", 1_000), file("y", 1_000)]),
    ])
    let bodyA = try #require(two.tileBody([0]))
    let bodyB = try #require(two.tileBody([1]))
    let onA = centre(two, of: bodyA)
    #expect(pinchToStop(two, at: onA, factor: 1.01).last == .reachedEdge)
    #expect(two.magnify(at: onA, factor: 1.05) == .none)
    #expect(two.magnify(at: onA, factor: 1.05) == .none)
    let onB = centre(two, of: bodyB)
    #expect(two.zoomTarget(x: onB.x, y: onB.y) == [1])
    #expect(two.magnify(at: onB, factor: 1.05) == .reachedEdge)
    #expect(two.magnify(at: onB, factor: 1.05) == .none)
    #expect(two.magnify(at: onB, factor: 1.05) == .none)
    #expect(two.magnify(at: onB, factor: 1.05) == .changedLevel)
    #expect(two.crumbs == [1])
}

/// Pinching back off a stop relaxes the squeeze before the view moves, and
/// moving off lets go of it. Fingers trembling at the edge are felt once;
/// coming back from well away is a new arrival.
@MainActor
@Test func movingOffTheStopLetsGoAndTremblingIsFeltOnce() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let (point, _) = try deeperPoint(state)
    #expect(pinchToStop(state, at: point, factor: 1.05).last == .reachedEdge)
    let rest = state.view
    #expect(state.magnify(at: point, factor: 1.05) == .none)
    #expect(state.magnify(at: point, factor: 0.99) == .none, "relaxes first")
    #expect(state.view == rest)
    #expect(state.magnify(at: point, factor: 0.95) == .zoomed)
    #expect(state.view.scale < rest.scale, "then moves off")
    #expect(
        state.magnify(at: point, factor: 1.05) == .zoomed,
        "back at the same stop, a moment later: not a second click"
    )
    #expect(abs(state.view.scale - rest.scale) < 1e-9)
    // The squeeze let go when the view moved: three to go through again.
    #expect(state.magnify(at: point, factor: 1.05) == .none)
    #expect(state.magnify(at: point, factor: 1.05) == .none)
    #expect(state.crumbs.isEmpty)

    // Well away, and back: a new arrival.
    state.endMagnify()
    #expect(state.magnify(at: point, factor: 0.9) == .zoomed)
    #expect(pinchToStop(state, at: point, factor: 1.05).last == .reachedEdge)
    #expect(state.crumbs.isEmpty)
}

/// The keys magnify, and only magnify: they never go through a level, and
/// a key has no finger on the pad to feel a stop.
@MainActor
@Test func theKeysOnlyMagnify() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    for _ in 0..<20 {
        try press(state, "=")
    }
    #expect(state.view.scale == ViewTransform.maxScale)
    #expect(state.crumbs.isEmpty)
    #expect(state.zoom(atX: 550, y: 400, factor: 2, descend: false) == .none)
    try press(state, "0")
    #expect(state.zoom(atX: 550, y: 400, factor: 0.5, descend: false) == .none)
    #expect(state.crumbs.isEmpty)
}

// MARK: - Smart zoom

/// A two-finger double tap goes into what a pinch there would go into, and
/// the same tap again comes back.
@MainActor
@Test func smartZoomGoesInAndTheSameTapComesBack() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let (point, deeper) = try deeperPoint(state)
    #expect(state.smartZoom(at: point) == .changedLevel)
    #expect(state.crumbs == deeper)
    #expect(state.transition != nil, "growing, as a pinch's would")

    let middle = CGPoint(x: 550, y: 400)
    state.transition = nil
    #expect(state.smartZoom(at: middle) == .changedLevel)
    #expect(state.crumbs.isEmpty, "back where it came from")
    #expect(state.transition != nil, "shrinking back into its tile")

    // And in again: the way back is used up, not a loop.
    #expect(state.smartZoom(at: point) == .changedLevel)
    #expect(state.crumbs == deeper)

    // Somewhere else by other means, the tap is a tap again.
    try press(state, "backspace")
    let junk = Array(deeper.dropLast())
    #expect(state.crumbs == junk)
    let blob = try childCrumbs(state, junk, "blob.bin")
    let onBlob = centre(state, of: try #require(state.tileRect(blob)))
    #expect(state.zoomTarget(x: onBlob.x, y: onBlob.y) == nil)
    #expect(
        state.smartZoom(at: onBlob) == .changedLevel,
        "nothing to go into under a file: back up"
    )
    #expect(state.crumbs.isEmpty)
}

/// With nothing under the pointer to go into, a magnified view goes back
/// to the whole level, as a motion; at the whole scanned root, nothing.
@MainActor
@Test func smartZoomOverAFileGoesBackToTheWhole() throws {
    let state = synthetic([file("a", 3_000), file("b", 1_000)])
    let middle = CGPoint(x: 550, y: 400)
    state.zoom(atX: 550, y: 400, factor: 2, descend: false)
    #expect(state.smartZoom(at: middle) == .zoomed)
    #expect(state.view == .identity)
    #expect(state.transition != nil)
    // The region that was in view starts where it was drawn: over the
    // whole viewport.
    let transition = try #require(state.transition)
    let visible = ViewTransform(scale: 2, originX: 275, originY: 200)
        .visibleBase(treemapArea)
    let from = transition.origin(of: visible)
    #expect(abs(from.x) < 1e-9 && abs(from.y) < 1e-9)
    #expect(abs(from.w - 1_100) < 1e-9 && abs(from.h - 800) < 1e-9)

    #expect(state.smartZoom(at: middle) == .none)
}

// MARK: - Clicks

/// A click says what it did, so the view can answer a ⌘-click's mark with
/// a feel — and a refused one with none.
@MainActor
@Test func aClickSaysWhatItDid() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let junk = try childCrumbs(state, [], "junk")
    let deeper = try childCrumbs(state, junk, "deeper")
    let onJunk = centre(
        state,
        of: try #require(state.layout()?.first { $0.crumbs == junk }?.header)
    )
    let command = PointerModifiers(command: true)
    state.select(nil)
    func click(
        _ point: CGPoint,
        _ button: PointerButton = .left,
        _ modifiers: PointerModifiers = PointerModifiers()
    ) -> ClickOutcome {
        state.mouseDown(
            at: point,
            button: button,
            clickCount: 1,
            modifiers: modifiers
        )
    }
    #expect(click(onJunk) == .selected)
    #expect(click(onJunk, .left, command) == .toggledMark)
    #expect(state.marks.contains(tree.path("junk")))
    #expect(click(onJunk, .middle) == .toggledMark)
    #expect(state.marks.isEmpty)
    #expect(click(onJunk, .right) == .none)
    #expect(click(onJunk) == .changedLevel, "a second click opens it")
    #expect(state.crumbs == junk)

    // Refused: inside a marked directory, nothing changed, nothing felt.
    state.goTo([])
    state.toggleMark(junk)
    let onDeeper = centre(state, of: try #require(state.tileRect(deeper)))
    #expect(click(onDeeper, .left, command) == .none)
    #expect(state.marks.count == 1)
    #expect(!state.toggleMark([]), "nor the scanned root")
}

// MARK: - The panel's width

/// The panel keeps the width its inspector comes to rest at, within its
/// limits, and a narrow window keeps the mosaic its room.
@MainActor
@Test func thePanelKeepsItsWidthWithinItsLimits() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let rem = state.rem
    state.keepPanelWidth(25 * rem)
    #expect(abs(state.panelRems - 25) < 1e-9)
    state.keepPanelWidth(2 * rem)
    #expect(state.panelRems == PanelSize.minRems)
    state.keepPanelWidth(90 * rem)
    #expect(state.panelRems == PanelSize.maxRems)
    // Hidden, the width is an animation's, not a choice.
    state.showSelection = false
    state.keepPanelWidth(30 * rem)
    #expect(state.panelRems == PanelSize.maxRems)
    #expect(
        panelWidthLimits(viewport: 600, rem: 16)
            == PanelSize.minRems...(600 / 16 - PanelSize.minRems),
        "a narrow window keeps the mosaic its room"
    )
}

// MARK: - The toast

/// A hand-over is confirmed in a toast that goes by itself; the notice
/// line keeps what has to stay.
@MainActor
@Test func aHandOverIsConfirmedInAToastThatExpires() throws {
    let tree = try fixture()
    let hooks = Hooks()
    let state = try stateOver(tree.root, hooks: hooks)
    state.toggleMark(try childCrumbs(state, [], "junk"))
    state.notice = Notice("mark something first", status: .warning)
    let serial = state.toastSerial
    let before = ContinuousClock.now
    state.copyCommand()
    let toast = try #require(state.toast)
    #expect(toast.status == .success)
    #expect(toast.text.hasPrefix("Copied: trash for 1 item, "))
    #expect(state.notice == nil, "the stale warning no longer holds")
    #expect(state.toastSerial == serial + 1)
    let expiry = try #require(state.toastExpiry)
    #expect(expiry >= before + AppState.toastDuration)

    state.expireToast(now: expiry - .milliseconds(1))
    #expect(state.toast != nil)
    state.expireToast(now: expiry)
    #expect(state.toast == nil && state.toastExpiry == nil)

    // The same words again are a new toast.
    state.copyCommand()
    #expect(state.toast == toast)
    #expect(state.toastSerial == serial + 2)
}

/// The timer takes it down; a newer toast outlives the older one's timer.
@MainActor
@Test func theToastGoesByItself() async throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    state.showToast(Notice("first", status: .neutral), for: .milliseconds(10))
    for _ in 0..<200 where state.toast != nil {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(state.toast == nil)

    state.showToast(Notice("old", status: .neutral), for: .milliseconds(10))
    state.showToast(Notice("new", status: .success), for: .seconds(30))
    try await Task.sleep(for: .milliseconds(100))
    #expect(state.toast?.text == "new")
    state.dismissToast()
}

/// Escape takes the toast down before it does anything else: the review
/// stays, the find field keeps its text, the selection stays selected.
@MainActor
@Test func escapeTakesTheToastFirst() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    state.toggleMark(try childCrumbs(state, [], "junk"))
    try press(state, "c enter")
    #expect(state.toast != nil && state.screen == .review)
    #expect(try press(state, "escape"))
    #expect(state.toast == nil && state.screen == .review)
    try press(state, "escape")
    #expect(state.screen == .explore)

    let selected = state.selected
    state.showToast(Notice("x", status: .neutral))
    try press(state, "escape")
    #expect(state.toast == nil && state.selected == selected)

    try press(state, "/")
    typeText(state, "ju")
    state.showToast(Notice("x", status: .neutral))
    try press(state, "escape")
    #expect(state.findOpen && state.find == "ju")
    try press(state, "escape")
    #expect(!state.findOpen)
}

/// Finder's reveal is confirmed in a toast too; too many folders is a
/// problem, which stays on the notice line.
@MainActor
@Test func revealingTheMarksIsConfirmedInAToast() throws {
    let tree = try fixture()
    let hooks = Hooks()
    let state = try stateOver(tree.root, hooks: hooks)
    state.toggleMark(try childCrumbs(state, [], "keep"))
    state.revealMarkedInFinder()
    #expect(hooks.revealed == [[tree.path("keep")]])
    #expect(state.toast?.text.hasPrefix("Revealed 1 item in Finder") == true)
    #expect(state.notice == nil)

    // Copy Path says what it copied.
    state.copyPath(try childCrumbs(state, [], "junk"))
    #expect(hooks.copied.last == tree.path("junk").string)
    #expect(state.toast?.text.hasPrefix("Copied ") == true)
    #expect(state.toast?.text.hasSuffix("junk") == true)
}

// MARK: - Quick Look

/// ⌘Y previews the tile a key acts on and closes it again; Escape closes
/// it too, after the toast. Space never opens it: Space marks.
@MainActor
@Test func commandYPreviewsTheTileAKeyActsOn() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let junk = try childCrumbs(state, [], "junk")
    state.select(junk)
    try press(state, "space")
    #expect(state.quickLookTarget == nil)
    #expect(state.marks.count == 1)

    #expect(try press(state, "cmd-y"))
    #expect(state.quickLookTarget == tree.path("junk"))
    #expect(try press(state, "cmd-y"))
    #expect(state.quickLookTarget == nil)

    // Through the window's own dispatcher, as the keyboard sends it.
    let chord = try #require(
        KeyStroke(event: try keyDown(0x10, "y", [.command]))
    )
    #expect(dispatchKey(chord, to: state))
    #expect(state.quickLookTarget == tree.path("junk"))
    // ⇧⌘Y is not Quick Look; it goes on to the menus.
    #expect(!(try press(state, "cmd-shift-y")))

    state.showToast(Notice("x", status: .neutral))
    try press(state, "escape")
    #expect(state.toast == nil && state.quickLookTarget != nil)
    try press(state, "escape")
    #expect(state.quickLookTarget == nil)
    #expect(state.selected == junk, "the preview went, nothing else")

    // Nothing selected: the directory drawn.
    state.select(nil)
    try press(state, "cmd-y")
    #expect(state.quickLookTarget == tree.root)
}

/// While the preview is up it follows the selection, as Finder's does.
@MainActor
@Test func thePreviewFollowsTheSelection() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let junk = try childCrumbs(state, [], "junk")
    state.select(junk)
    try press(state, "cmd-y")
    try press(state, "tab")
    let next = try #require(state.selected)
    #expect(next != junk)
    #expect(state.quickLookTarget == state.path(at: next))

    // A click on another tile too.
    let cache = try childCrumbs(state, [], ".cache")
    let onCache = centre(state, of: try #require(state.tileRect(cache)))
    state.mouseDown(
        at: onCache,
        button: .left,
        clickCount: 1,
        modifiers: PointerModifiers()
    )
    let clicked = try #require(state.selected)
    #expect(clicked.starts(with: cache))
    #expect(state.quickLookTarget == state.path(at: clicked))

    // Closed, it stays closed.
    try press(state, "cmd-y tab")
    #expect(state.quickLookTarget == nil)
}

/// The context menu's Quick Look, and a review row's; the review itself
/// has no tile for ⌘Y, which then goes on to the menus.
@MainActor
@Test func quickLookFromTheMenuAndTheReview() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let keep = try childCrumbs(state, [], "keep")
    state.revealQuickLook(keep)
    #expect(state.quickLookTarget == tree.path("keep"))
    state.revealQuickLook([9, 9, 9])
    #expect(state.quickLookTarget == tree.path("keep"), "no such tile")
    state.quickLookTarget = nil

    state.toggleMark(keep)
    try press(state, "c")
    #expect(!(try press(state, "cmd-y")))
    #expect(state.quickLookTarget == nil)
    state.revealQuickLook(path: tree.path("keep/notes.txt"))
    #expect(try press(state, "cmd-y"), "closes, from any screen")
    #expect(state.quickLookTarget == nil)
}

// MARK: - Preferences

/// What is saved comes back; what was never changed stays unwritten.
@MainActor
@Test func preferencesComeBackAsTheyWereSaved() {
    let store = MemoryPreferences()
    let shipped = Preferences()
    shipped.write(to: store, changedFrom: shipped)
    #expect(store.values.isEmpty, "nothing changed, nothing written")
    #expect(Preferences(store: store) == shipped)

    let tuned = Preferences(
        depth: 5,
        includeHidden: false,
        apparentSize: true,
        oneFilesystem: false,
        commandStyle: .remove,
        showPanel: false,
        colorMode: .age,
        panelRems: 30,
        zoomStep: 4
    )
    tuned.write(to: store, changedFrom: shipped)
    #expect(store.values.count == Preferences.Key.allCases.count)
    #expect(store[.commandStyle] as? String == "remove")
    #expect(store[.colorMode] as? String == "age")
    #expect(Preferences(store: store) == tuned)

    var one = shipped
    one.depth = 2
    let fresh = MemoryPreferences()
    one.write(to: fresh, changedFrom: shipped)
    #expect(Array(fresh.values.keys) == [Preferences.Key.depth.rawValue])
}

/// A value written by another version, or by hand, that the app cannot
/// show falls back rather than opening the window on it.
@MainActor
@Test func preferencesTheAppCannotShowFallBack() {
    let store = MemoryPreferences()
    store.values = [
        Preferences.Key.depth.rawValue: 99,
        Preferences.Key.includeHidden.rawValue: "yes",
        Preferences.Key.commandStyle.rawValue: 3,
        Preferences.Key.colorMode.rawValue: "purple",
        Preferences.Key.panelRems.rawValue: Double.nan,
        Preferences.Key.zoomStep.rawValue: 42,
    ]
    let read = Preferences(store: store)
    #expect(read.depth == 6)
    #expect(read.includeHidden)
    #expect(read.commandStyle == .trash)
    #expect(read.colorMode == .kind)
    #expect(read.panelRems == PanelSize.rems)
    #expect(read.zoomStep == defaultZoomStep)

    store.values = [
        Preferences.Key.depth.rawValue: 0,
        Preferences.Key.panelRems.rawValue: 3.0,
        Preferences.Key.zoomStep.rawValue: -1,
    ]
    let low = Preferences(store: store)
    #expect(low.depth == 1)
    #expect(low.panelRems == PanelSize.minRems)
    #expect(low.zoomStep == defaultZoomStep)
    // Kept as numbers, as `defaults` writes them.
    store.values = [
        Preferences.Key.depth.rawValue: NSNumber(value: 4),
        Preferences.Key.panelRems.rawValue: NSNumber(value: 30),
        Preferences.Key.apparentSize.rawValue: NSNumber(value: true),
    ]
    let numbers = Preferences(store: store)
    #expect(numbers.depth == 4 && numbers.panelRems == 30)
    #expect(numbers.apparentSize)
}

/// The command line starts from the preferences and overrides them for
/// the run.
@Test func theCommandLineOverridesThePreferences() throws {
    let tree = try TempTree([("a.bin", 10)])
    let saved = Preferences(
        depth: 5,
        includeHidden: false,
        apparentSize: true,
        oneFilesystem: false
    )
    func run(_ words: [String]) throws -> Arguments {
        let invocation = try parseArguments(
            words + [tree.root.string],
            home: nil,
            preferences: saved
        )
        guard case .run(let arguments) = invocation else {
            Issue.record("not a run")
            throw UsageError("not a run")
        }
        return arguments
    }
    let plain = try run([])
    #expect(plain.depth == 5)
    #expect(!plain.options.includeHidden)
    #expect(plain.options.apparentSize)
    #expect(!plain.options.oneFilesystem)
    #expect(!plain.isScripted)

    let flagged = try run(["-d", "2", "-x"])
    #expect(flagged.depth == 2)
    #expect(flagged.options.oneFilesystem)
    #expect(flagged.options.apparentSize, "what no flag says is kept")

    let scripted = try run(["--keys", "space"])
    #expect(scripted.isScripted)
}

/// At launch the state takes on what the command line did not decide, and
/// from then on saves what the person tunes by hand — depth, colour, the
/// panel's width, the interface zoom — whatever route the change took.
@MainActor
@Test func theStateAdoptsThePreferencesAndSavesWhatIsTuned() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks(), depth: 5)
    let store = MemoryPreferences()
    state.adopt(
        Preferences(
            depth: 3,
            commandStyle: .remove,
            showPanel: false,
            colorMode: .age,
            panelRems: 30,
            zoomStep: 3
        ),
        store: store
    )
    #expect(store.values.isEmpty, "applying what was read saves nothing")
    #expect(state.layoutOptions.maxDepth == 5, "the command line's, kept")
    #expect(state.commandStyle == .remove)
    #expect(!state.showSelection)
    #expect(state.colorMode == .age)
    #expect(state.panelRems == 30)
    #expect(state.zoomStep == 3)
    #expect(state.effectiveLayoutOptions.header == 1.375 * Double(state.rem))

    try press(state, "]")
    #expect(store[.depth] as? Int == 6)
    try press(state, "t")
    #expect(store[.colorMode] as? String == "kind")
    try press(state, "cmd-=")
    #expect(store[.zoomStep] as? Int == 4)
    state.panelRems = 25
    #expect(store[.panelRems] as? Double == 25)
    #expect(state.preferences.panelRems == 25)

    // For the run only: the panel key, the review's style.
    try press(state, "p")
    state.toggleMark(try childCrumbs(state, [], "junk"))
    try press(state, "c m")
    #expect(state.commandStyle == .trash)
    #expect(store[.showPanel] == nil && store[.commandStyle] == nil)
}

/// The Settings window's changes are saved, and applied at once where the
/// run has them; the scan options wait for the next launch rather than
/// walk the disk again from a switch.
@MainActor
@Test func settingsApplyNowAndSave() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks(), depth: 5)
    let store = MemoryPreferences()
    state.adopt(Preferences(), store: store)

    state.setPreference(\.showPanel, false)
    #expect(!state.showSelection && store[.showPanel] as? Bool == false)
    #expect(state.layoutOptions.maxDepth == 5, "another value is untouched")
    state.setPreference(\.depth, 2)
    #expect(state.layoutOptions.maxDepth == 2 && store[.depth] as? Int == 2)
    state.setPreference(\.depth, 99)
    #expect(state.layoutOptions.maxDepth == 6)
    state.setPreference(\.colorMode, .age)
    #expect(state.colorMode == .age)
    state.setPreference(\.commandStyle, .remove)
    #expect(state.commandStyle == .remove)
    state.setPreference(\.zoomStep, 0)
    #expect(state.zoomStep == 0)
    state.setPreference(\.includeHidden, false)
    #expect(store[.includeHidden] as? Bool == false)
    #expect(state.options.includeHidden, "the tree on screen keeps its own")
    #expect(state.scan == nil, "and no walk started")
    #expect(state.preferences.includeHidden == false)

    // Without a store, the same works and nothing is written anywhere.
    let bare = try stateOver(tree.root, hooks: Hooks())
    bare.setPreference(\.depth, 4)
    try press(bare, "]")
    #expect(bare.preferences.depth == 5 && bare.preferenceStore == nil)
}

// MARK: - The plan, the command, and what is gone

/// Views ask for the plan and its command from `body`: kept while the
/// marks, the root and what is gone stay as they were.
@MainActor
@Test func thePlanIsKeptUntilItsInputsChange() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let junk = try childCrumbs(state, [], "junk")
    state.toggleMark(junk)
    let plan = state.plan()
    #expect(plan.targets.map(\.path) == [tree.path("junk")])
    // Proof it is not worked out again: a memo tampered with is what
    // comes back, until something it is made of changes.
    state.handOverMemo?.plan = Plan()
    #expect(state.plan().targets.isEmpty)
    let command = try #require(state.cleanupCommand())
    #expect(command.hasPrefix("/usr/bin/trash"))
    state.commandStyle = .remove
    #expect(state.cleanupCommand()?.hasPrefix("/bin/rm -rfx --") == true)

    state.toggleMark(try childCrumbs(state, [], "keep"))
    #expect(state.plan().targets.count == 2, "new marks, a fresh plan")
    state.handOverMemo?.plan = Plan()
    state.gone = [tree.path("keep")]
    #expect(state.plan().targets.count == 2, "something went: fresh again")
}

/// What is already gone is left out of the command and out of Finder;
/// once everything is, there is nothing left to hand over, and it says so.
@MainActor
@Test func whatIsGoneIsLeftOutOfTheHandOver() throws {
    let tree = try fixture()
    let hooks = Hooks()
    let state = try stateOver(tree.root, hooks: hooks)
    let junk = try childCrumbs(state, [], "junk")
    let keep = try childCrumbs(state, [], "keep")
    state.toggleMark(junk)
    state.toggleMark(keep)
    state.gone = [tree.path("junk")]

    #expect(state.plan().targets.count == 2, "the review still lists it")
    #expect(state.handOverPlan().targets.map(\.path) == [tree.path("keep")])
    let command = try #require(state.cleanupCommand())
    #expect(!command.contains(shellQuoted(tree.path("junk"))))
    #expect(command.contains(shellQuoted(tree.path("keep"))))
    state.copyCommand()
    #expect(state.toast?.text.hasPrefix("Copied: trash for 1 item") == true)
    state.revealMarkedInFinder()
    #expect(hooks.revealed == [[tree.path("keep")]])

    state.gone = [tree.path("junk"), tree.path("keep")]
    #expect(state.cleanupCommand() == nil)
    state.dismissToast()
    state.copyCommand()
    #expect(state.notice?.text == "the marked paths are gone already")
    #expect(state.toast == nil)
    #expect(hooks.copied.count == 1 && hooks.revealed.count == 1)
}

// MARK: - Loose ends

/// A merged tail is never hovered — nothing may act on it — but it has a
/// hover of its own, which says what it stands for.
@MainActor
@Test func aMergedTailHasAHoverOfItsOwn() throws {
    let flat = try TempTree(
        [("big.bin", 500_000)]
            + (0..<120).map { (path: "small-\($0).bin", count: 100) }
    )
    let state = try stateOver(flat.root, hooks: Hooks())
    let tail = try #require(
        state.layout()?.first {
            if case .others = $0.kind { true } else { false }
        }
    )
    guard case .others(let crumbs, let count) = tail.kind else {
        return
    }
    state.pointerMoved(to: centre(state, of: tail.rect))
    #expect(state.hovered == nil)
    #expect(
        state.hoveredTail
            == HoveredTail(
                crumbs: crumbs, count: count, value: 100 * UInt64(count))
    )

    let big = try childCrumbs(state, [], "big.bin")
    state.pointerMoved(to: centre(state, of: try #require(state.tileRect(big))))
    #expect(state.hovered == big && state.hoveredTail == nil)
    state.pointerMoved(to: centre(state, of: tail.rect))
    #expect(state.hoveredTail != nil)
    state.pointerExited()
    #expect(state.hoveredTail == nil)
}

/// The inner name band has room for a 12-point name's descenders.
@MainActor
@Test func theInnerBandHasRoomForDescenders() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    #expect(state.effectiveLayoutOptions.headerInner == 18)
    try press(state, "cmd-=")
    #expect(
        abs(state.effectiveLayoutOptions.headerInner - 1.125 * state.rem)
            < 1e-9
    )
}

/// Space types a space in the find field, from a real key press.
@MainActor
@Test func spaceTypesASpaceInTheFindField() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    try press(state, "/")
    typeText(state, "a")
    let space = try #require(KeyStroke(event: try keyDown(KeyCode.space, " ")))
    #expect(dispatchKey(space, to: state))
    typeText(state, "b")
    #expect(state.find == "a b")
    #expect(state.marks.isEmpty, "typed, not marked")
}

/// A folder dropped on the window is scanned; a file alone is refused.
@MainActor
@Test func aDroppedFolderIsScanned() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let note = URL(filePath: tree.path("keep/notes.txt").string)
    let folder = URL(
        filePath: tree.path("junk").string,
        directoryHint: .isDirectory
    )
    #expect(!state.scanDropped([note]))
    let web = try #require(URL(string: "https://example.com/"))
    #expect(!state.scanDropped([web]))
    #expect(state.rootPath == tree.root)
    #expect(state.scanDropped([note, folder]))
    defer { state.scan?.cancel() }
    #expect(state.rootPath == canonicalPath(tree.path("junk")))
    #expect(state.scan != nil, "a walk of it started")
}

// MARK: - The chrome's state

/// Run a loop of ours for `seconds`: a timer's turn, never the runner's.
@MainActor
private func spin(_ seconds: Double) {
    let until = Date(timeIntervalSinceNow: seconds)
    while until.timeIntervalSinceNow > 0 {
        _ = CFRunLoopRunInMode(
            .defaultMode,
            max(until.timeIntervalSinceNow, 0),
            false
        )
    }
}

/// A tile's card waits until the pointer has rested on it, and goes at once
/// when the pointer moves on to another: a sweep across the mosaic is not
/// a card jumping from tile to tile.
@MainActor
@Test func theCardWaitsForThePointerToRest() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let tiles = try #require(state.layout())
    let centre = { (crumbs: [Int]) throws -> CGPoint in
        let rect = try #require(tiles.first { $0.crumbs == crumbs }?.rect)
        return CGPoint(x: rect.x + rect.w / 2, y: rect.y + rect.h / 2)
    }
    let junk = try centre(try childCrumbs(state, [], "junk"))
    let cache = try centre(try childCrumbs(state, [], ".cache"))
    #expect(!state.cardHeld, "nothing hovered, nothing held")
    state.pointerMoved(to: junk)
    #expect(state.hovered != nil)
    #expect(state.cardHeld, "a new tile: its card waits")
    spin(Double(AppState.cardDelay.components.seconds) + 0.65)
    #expect(!state.cardHeld, "rested there: the card shows")
    state.pointerMoved(to: CGPoint(x: junk.x + 1, y: junk.y))
    #expect(!state.cardHeld, "a move within the tile keeps it")
    state.pointerMoved(to: cache)
    #expect(state.cardHeld, "on to another: it goes at once")
    state.pointerExited()
    spin(0.65)
}

/// The legend's key under the pointer picks its kind out of the mosaic:
/// every other tile steps back, as a find's misses do, until it moves on.
@MainActor
@Test func aLegendKeyPicksItsKindOutOfTheMosaic() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    #expect(state.prepare().tiles.allSatisfy { $0.filtered == .shown })
    let cache = try childCrumbs(state, [], ".cache")
    let kind = try #require(state.node(at: cache)?.category)
    state.legendFocus = .kind(kind)
    var mosaic = state.prepare()
    #expect(mosaic.tiles.contains { $0.category == kind })
    for tile in mosaic.tiles {
        #expect(tile.filtered == (tile.category == kind ? .shown : .out))
    }
    state.legendFocus = .reclaimable
    mosaic = state.prepare()
    #expect(mosaic.tiles.contains { $0.reclaimable })
    for tile in mosaic.tiles {
        #expect(tile.filtered == (tile.reclaimable ? .shown : .out))
    }
    state.legendFocus = nil
    #expect(state.prepare().tiles.allSatisfy { $0.filtered == .shown })
}

/// Inside a marked directory every tile goes with the mark: it is said
/// once, and the tiles keep their kinds, tinted, and their names read as
/// any other's.
@MainActor
@Test func insideAMarkedDirectoryTheTilesKeepTheirKinds() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let junk = try childCrumbs(state, [], "junk")
    state.toggleMark(junk)
    var mosaic = state.prepare()
    #expect(!mosaic.insideMark)
    #expect(LegendRow.mark(state) == nil)
    state.goTo(junk)
    mosaic = state.prepare()
    #expect(mosaic.insideMark)
    #expect(LegendRow.mark(state) == state.path(at: junk))
    #expect(!mosaic.tiles.isEmpty && mosaic.tiles.allSatisfy(\.covered))
    #expect(mosaic.labels.allSatisfy { !$0.marked })
    for theme in [Theme.dark, .light] {
        let colors = MosaicColors(theme: theme)
        for tile in mosaic.tiles {
            let tinted = colors.fill(tile, insideMark: true).hsla
            #expect(tinted != colors.fill(tile).hsla, "not the marked fill")
            #expect(
                tinted
                    == MosaicColors.insideMark(
                        theme.categoryFill(tile.category, depth: tile.depth),
                        theme: theme
                    ),
                "its own kind, tinted"
            )
        }
    }
    // Deeper still, the same; unmarked, it is an ordinary directory again.
    state.unmark(try #require(state.path(at: junk)))
    #expect(!state.prepare().insideMark)
    #expect(LegendRow.mark(state) == nil)
}

/// What the status bar says: what the directory drawn holds, and how long
/// the scan took; a notice on a line of its own starts with a capital.
@MainActor
@Test func theStatusBarSaysWhatIsHereAndHowLongItTook() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    state.scanElapsed = .milliseconds(1_500)
    let (holds, scan) = KeyBar.status(state)
    #expect(holds == ExploreView.holds(state))
    #expect(scan == "scanned in 1.5 s")
    #expect(KeyBar.summary(state) == "\(holds) \u{00b7} scanned in 1.5 s")
    // What could not be read is the note's, beside it, not the line's.
    state.progress.errors = 2
    #expect(!KeyBar.status(state).holds.contains("unreadable"))
    #expect(ExploreView.subtitle(state).hasSuffix("2 unreadable"))

    #expect(
        Notice("nothing is marked", status: .warning).sentence
            == "Nothing is marked")
    #expect(
        Notice("~/junk goes with ~", status: .neutral).sentence
            == "~/junk goes with ~")
    #expect(Notice("Copied", status: .success).sentence == "Copied")
}
