// The platform's half of the polish: what each gesture feels like under
// the fingers, pinch zoom through the real view with its detents, a tile
// dragged out as its file, Quick Look kept in step with the state, the
// Settings pane and what it saves, and what VoiceOver is told.
//
// Gestures are fed to the real `TreemapNSView` in an offscreen window. A
// click is a real `NSEvent`; AppKit has no public way to make a pinch, a
// two-finger scroll with its phases or a smart-zoom tap, so those arrive as
// an `NSEvent` whose readings a test sets — the view reads them through the
// same properties it reads a trackpad's through. A recorder stands in for
// the trackpad, a recording panel for Quick Look's, a closure for the
// dragging session and a dictionary for the defaults: nothing here taps a
// trackpad, opens a panel, takes the pointer or writes the person's own
// preferences, the pasteboard or Finder.

import AppKit
import DisktreeCore
import Foundation
import Quartz
import SwiftUI
import System
import Testing

@testable import DisktreeApp

private typealias Support = TreemapSupport

// MARK: - Stand-ins

/// Plays nothing and remembers everything.
@MainActor
private final class HapticRecorder: HapticPerformer {
    var played: [Haptic] = []

    func perform(_ haptic: Haptic) {
        played.append(haptic)
    }

    /// How many times `haptic` was played.
    func count(_ haptic: Haptic) -> Int {
        played.count { $0 == haptic }
    }
}

/// A preview panel that only says what it was asked.
@MainActor
private final class PanelRecorder: QuickLookPanel {
    var isShowing = false
    var calls: [String] = []

    func show() {
        calls.append("show")
        isShowing = true
    }

    func reload() {
        calls.append("reload")
    }

    func close() {
        calls.append("close")
        isShowing = false
    }
}

/// A gesture event: the readings a trackpad's would carry, set by the test.
private final class GestureEvent: NSEvent {
    var kind: NSEvent.EventType = .magnify
    var location = CGPoint.zero
    var time: TimeInterval = 0
    var pinch: CGFloat = 0
    var gesturePhase: NSEvent.Phase = []
    var momentum: NSEvent.Phase = []
    var verticalDelta: CGFloat = 0
    var precise = true
    var flags: NSEvent.ModifierFlags = []
    var button = 0
    var clicks = 1

    override var type: NSEvent.EventType { kind }
    override var locationInWindow: NSPoint { location }
    override var timestamp: TimeInterval { time }
    override var magnification: CGFloat { pinch }
    override var phase: NSEvent.Phase { gesturePhase }
    override var momentumPhase: NSEvent.Phase { momentum }
    override var scrollingDeltaX: CGFloat { 0 }
    override var scrollingDeltaY: CGFloat { verticalDelta }
    override var hasPreciseScrollingDeltas: Bool { precise }
    override var modifierFlags: NSEvent.ModifierFlags { flags }
    override var buttonNumber: Int { button }
    override var clickCount: Int { clicks }
}

// MARK: - A treemap in a window

/// The tree the gestures run over, in memory:
///
///     z.bin 900 000
///     a/   e.bin 400 000
///          b/  c.bin 100 000, d.bin 50 000
///          f.bin 150 000
///     y/   y1.bin 100 000, y2.bin 100 000
///
/// Drawn one level deep, so each directory is a closed tile a pinch goes
/// into. Neither `a` at the top nor `b` inside it spans the mosaic in
/// either direction, so each has a stop of its own to zoom up to before the
/// fingers reach it.
private func gestureTree() -> Node {
    func file(_ name: String, _ bytes: UInt64) -> Node {
        Node.entry(name, kind: .file, bytes: bytes)
    }
    var root = Node.directory(
        "gestures",
        children: [
            file("z.bin", 900_000),
            .directory(
                "a",
                children: [
                    file("e.bin", 400_000),
                    .directory(
                        "b",
                        children: [
                            file("c.bin", 100_000), file("d.bin", 50_000),
                        ]
                    ),
                    file("f.bin", 150_000),
                ]
            ),
            .directory(
                "y",
                children: [file("y1.bin", 100_000), file("y2.bin", 100_000)]
            ),
        ]
    )
    aggregate(&root, metric: .bytes)
    return root
}

/// The real treemap view, in an offscreen window it fills, over a state
/// whose hooks only record, playing its haptics into a recorder.
@MainActor
private final class Rig {
    static let size = CGSize(width: 900, height: 600)

    let state: AppState
    let hooks = Hooks()
    let view: TreemapNSView
    let window: NSWindow
    let haptics = HapticRecorder()
    var drags: [TileDrag] = []
    private var clock: TimeInterval = 100

    init(tree: Node = gestureTree(), depth: Int = 1) {
        state = AppState(
            root: "/nonexistent/disktree-platform",
            tree: tree,
            options: ScanOptions(),
            depth: depth
        )
        hooks.capture(state)
        view = TreemapNSView(state: state)
        window = Support.offscreenWindow(view, size: Self.size)
        view.haptics = haptics
        view.reducesMotion = false
        view.onDragOut = { [weak self] in self?.drags.append($0) }
    }

    /// The crumbs of a path of names below the root.
    func crumbs(_ names: String...) throws -> [Int] {
        var found: [Int] = []
        for name in names {
            found = try childCrumbs(state, found, name)
        }
        return found
    }

    /// The middle of the tile at `crumbs` as it is drawn now, in
    /// treemap-local points.
    func middle(_ crumbs: [Int]) throws -> CGPoint {
        let rect = try #require(state.tileRect(crumbs), "\(crumbs) is drawn")
        return centre(state, of: rect)
    }

    /// A treemap-local point in the window's coordinates, which run up.
    func windowPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: Self.size.height - point.y)
    }

    private func tick() -> TimeInterval {
        clock += 0.01
        return clock
    }

    /// One event of a pinch at `point`.
    func pinch(
        _ magnification: CGFloat,
        at point: CGPoint,
        phase: NSEvent.Phase = .changed
    ) {
        let event = GestureEvent()
        event.kind = .magnify
        event.location = windowPoint(point)
        event.time = tick()
        event.pinch = magnification
        event.gesturePhase = phase
        view.magnify(with: event)
    }

    /// A pinch from its first touch to its lift, `steps` in between.
    func wholePinch(_ steps: [CGFloat], at point: CGPoint) {
        pinch(0, at: point, phase: .began)
        for step in steps {
            pinch(step, at: point)
        }
        pinch(0, at: point, phase: .ended)
    }

    /// One scroll event at `point`: a trackpad's (precise, with phases)
    /// unless told otherwise.
    func scroll(
        _ deltaY: CGFloat,
        at point: CGPoint,
        phase: NSEvent.Phase = .changed,
        momentum: NSEvent.Phase = [],
        precise: Bool = true
    ) {
        let event = GestureEvent()
        event.kind = .scrollWheel
        event.location = windowPoint(point)
        event.time = tick()
        event.verticalDelta = deltaY
        event.gesturePhase = phase
        event.momentum = momentum
        event.precise = precise
        view.scrollWheel(with: event)
    }

    /// A two-finger double tap at `point`.
    func smartTap(at point: CGPoint) {
        let event = GestureEvent()
        event.kind = .smartMagnify
        event.location = windowPoint(point)
        event.time = tick()
        view.smartMagnify(with: event)
    }

    /// A real mouse event at a treemap-local point.
    func mouse(
        _ type: NSEvent.EventType,
        at point: CGPoint,
        flags: NSEvent.ModifierFlags = [],
        clicks: Int = 1
    ) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type,
                location: windowPoint(point),
                modifierFlags: flags,
                timestamp: tick(),
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: clicks,
                pressure: 1
            )
        )
    }

    /// The middle button going down at `point`. `mouseEvent` cannot say
    /// which button, so its readings are set, as a gesture's are.
    func middleClick(at point: CGPoint) {
        let event = GestureEvent()
        event.kind = .otherMouseDown
        event.location = windowPoint(point)
        event.time = tick()
        event.button = 2
        view.otherMouseDown(with: event)
    }

    /// A left click at `point`: down and up.
    func click(
        at point: CGPoint,
        flags: NSEvent.ModifierFlags = []
    ) throws {
        view.mouseDown(with: try mouse(.leftMouseDown, at: point, flags: flags))
        view.mouseUp(with: try mouse(.leftMouseUp, at: point, flags: flags))
    }
}

/// Wait a few turns of the main actor for `condition`: what the state's
/// observers do, they do on the turn after the change.
@MainActor
private func eventually(_ condition: () -> Bool) async {
    for _ in 0..<400 where !condition() {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

// MARK: - What each outcome feels like

@Test func eachOutcomeHasItsFeel() {
    #expect(Haptic.zoom(.reachedEdge) == .alignment)
    #expect(Haptic.zoom(.changedLevel) == .levelChange)
    #expect(Haptic.zoom(.zoomed) == nil)
    #expect(Haptic.zoom(.none) == nil)

    // A scroll's stop is felt only where the wheel cannot go through it;
    // elsewhere the level change right after it is the one click.
    #expect(Haptic.scroll(.reachedEdge, wall: true) == .alignment)
    #expect(Haptic.scroll(.reachedEdge, wall: false) == nil)
    for wall in [true, false] {
        #expect(Haptic.scroll(.changedLevel, wall: wall) == .levelChange)
        #expect(Haptic.scroll(.zoomed, wall: wall) == nil)
        #expect(Haptic.scroll(.none, wall: wall) == nil)
    }

    #expect(Haptic.smartZoom(.changedLevel) == .levelChange)
    #expect(Haptic.smartZoom(.zoomed) == .generic)
    #expect(Haptic.smartZoom(.none) == nil)

    #expect(Haptic.click(.toggledMark) == .generic)
    for quiet in [ClickOutcome.none, .selected, .changedLevel] {
        #expect(Haptic.click(quiet) == nil)
    }

    #expect(
        Haptic.allCases.map(\.pattern) == [.alignment, .levelChange, .generic]
    )
}

@Test func aLevelChangeIsNotClickedAgainWhereItLands() {
    var feel = PinchFeel()
    #expect(feel.haptic(for: .reachedEdge) == .alignment)
    #expect(feel.haptic(for: .none) == nil)
    #expect(feel.haptic(for: .changedLevel) == .levelChange)
    // The new level appeared at a stop: that was the level change.
    #expect(feel.haptic(for: .reachedEdge) == nil)
    #expect(feel.haptic(for: .none) == nil)
    #expect(feel.haptic(for: .reachedEdge) == nil)
    // Moved within the new level, the next stop clicks.
    #expect(feel.haptic(for: .zoomed) == nil)
    #expect(feel.haptic(for: .reachedEdge) == .alignment)

    // A new pinch starts with nothing behind it.
    #expect(feel.haptic(for: .changedLevel) == .levelChange)
    feel.begin()
    #expect(feel.haptic(for: .reachedEdge) == .alignment)
}

// MARK: - Pinch zoom on the cells

@MainActor
@Test func aPinchRestsAtTheStopAndASqueezeGoesThrough() throws {
    let rig = Rig()
    let a = try rig.crumbs("a")
    let point = try rig.middle(a)

    rig.pinch(0, at: point, phase: .began)
    // In small steps, until the zoom stops moving: `a` fills the view.
    var arrived = false
    for _ in 0..<60 where !arrived {
        rig.pinch(0.04, at: point)
        arrived = rig.haptics.count(.alignment) > 0
    }
    #expect(arrived)
    #expect(rig.state.crumbs == [])
    #expect(rig.haptics.played == [.alignment])

    // Pressing on the stop is felt once, however many events it takes.
    rig.pinch(0.03, at: point)
    rig.pinch(0.03, at: point)
    #expect(rig.state.crumbs == [])
    #expect(rig.haptics.played == [.alignment])

    // A little further, past 12% in all, goes through, with a firmer feel.
    rig.pinch(0.03, at: point)
    rig.pinch(0.03, at: point)
    #expect(rig.state.crumbs == a)
    #expect(rig.haptics.played == [.alignment, .levelChange])
}

@MainActor
@Test func aPinchThatWentInKeepsZoomingButNeverTunnels() throws {
    let rig = Rig()
    let a = try rig.crumbs("a")
    let b = try rig.crumbs("a", "b")

    rig.pinch(0, at: try rig.middle(a), phase: .began)
    for _ in 0..<80 where rig.state.crumbs != a {
        rig.pinch(0.05, at: try rig.middle(a))
    }
    #expect(rig.state.crumbs == a)
    #expect(rig.haptics.count(.levelChange) == 1)

    // The same fingers go on pinching, now over `b`: the new level
    // magnifies, and comes to rest against `b`'s stop — it is not dead.
    let inside = try rig.middle(b)
    #expect(rig.state.view.scale == 1)
    for _ in 0..<80 {
        rig.pinch(0.05, at: inside)
    }
    #expect(rig.state.view.scale > 1)
    #expect(rig.haptics.count(.alignment) == 2)
    // However hard they squeeze, this pinch has had its level change.
    #expect(rig.state.crumbs == a)
    #expect(rig.haptics.count(.levelChange) == 1)

    // The fingers lift; the next pinch may go through.
    rig.pinch(0, at: inside, phase: .ended)
    rig.pinch(0, at: inside, phase: .began)
    for _ in 0..<10 where rig.state.crumbs != b {
        rig.pinch(0.05, at: inside)
    }
    #expect(rig.state.crumbs == b)
    #expect(rig.haptics.count(.levelChange) == 2)
}

@MainActor
@Test func pinchingOutAtTheWholeLevelNeedsTheSameSqueeze() throws {
    let rig = Rig()
    let a = try rig.crumbs("a")
    rig.state.select(a)
    rig.state.descend()
    #expect(rig.state.crumbs == a)
    let point = CGPoint(x: 450, y: 300)

    rig.pinch(0, at: point, phase: .began)
    rig.pinch(-0.06, at: point)
    // Resting at the floor already: the stop is felt, nothing moves.
    #expect(rig.haptics.played == [.alignment])
    #expect(rig.state.crumbs == a)
    rig.pinch(-0.06, at: point)
    #expect(rig.state.crumbs == a)
    // 6% twice is past 12%: out it goes.
    rig.pinch(-0.06, at: point)
    #expect(rig.state.crumbs == [])
    #expect(rig.haptics.played == [.alignment, .levelChange])

    // The parent appears whole, at its own floor, and the same fingers
    // squeezing on meet it at once: that was the level change, not a second
    // click a frame after it.
    rig.pinch(-0.06, at: point)
    rig.pinch(-0.06, at: point)
    #expect(rig.state.crumbs == [])
    #expect(rig.haptics.played == [.alignment, .levelChange])

    // Pinched in and back out, the floor is reached by moving: a click.
    rig.pinch(0.1, at: point)
    #expect(rig.state.view.scale > 1)
    rig.pinch(-0.2, at: point)
    #expect(rig.state.view.scale == 1)
    #expect(rig.haptics.played == [.alignment, .levelChange, .alignment])
}

@MainActor
@Test func aPinchWithoutPhasesStartsOverAfterQuiet() throws {
    let rig = Rig()
    let a = try rig.crumbs("a")
    let point = try rig.middle(a)
    for _ in 0..<80 where rig.state.crumbs != a {
        rig.pinch(0.05, at: point, phase: [])
    }
    #expect(rig.state.crumbs == a)
    // Without a phase to say the fingers lifted, the quiet says it.
    let event = GestureEvent()
    event.kind = .magnify
    event.location = rig.windowPoint(point)
    event.time = 10_000
    event.pinch = -0.06
    rig.view.magnify(with: event)
    event.time += 0.01
    rig.view.magnify(with: event)
    event.time += 0.01
    rig.view.magnify(with: event)
    #expect(rig.state.crumbs == [])
}

// MARK: - Scroll

@MainActor
@Test func aTwoFingerScrollGoesThroughAStopWithOneClick() throws {
    let rig = Rig()
    let a = try rig.crumbs("a")
    let point = try rig.middle(a)

    // Three lines a step: 72 points of a trackpad's scroll. The zoom comes
    // to rest where `a` fills the view, and the next event goes in: the
    // wheel goes straight through, so the level change is the one click,
    // not a stop's click a frame before it.
    rig.scroll(0, at: point, phase: .began)
    var events = 0
    for _ in 0..<20 where rig.state.crumbs != a {
        rig.scroll(72, at: point)
        events += 1
    }
    #expect(rig.state.crumbs == a)
    // It did rest at the stop on the way: more than one event went in.
    #expect(events > 1)
    #expect(rig.haptics.played == [.levelChange])

    // The rest of the flick, momentum and all, is let go: nothing moves
    // and nothing is felt.
    let scale = rig.state.view.scale
    rig.scroll(72, at: point)
    rig.scroll(0, at: point, phase: .ended)
    rig.scroll(72, at: point, phase: [], momentum: .began)
    rig.scroll(72, at: point, phase: [], momentum: .changed)
    rig.scroll(0, at: point, phase: [], momentum: .ended)
    #expect(rig.state.crumbs == a)
    #expect(rig.state.view.scale == scale)
    #expect(rig.haptics.played == [.levelChange])
}

@MainActor
@Test func aTwoFingerScrollClicksAgainstAWall() throws {
    let rig = Rig()
    let z = try rig.middle(try rig.crumbs("z.bin"))

    // Out at the whole scanned root there is nowhere to go: a stop.
    rig.scroll(0, at: z, phase: .began)
    rig.scroll(-72, at: z)
    #expect(rig.haptics.played == [.alignment])
    // Felt once, however long the fingers push against it.
    rig.scroll(-72, at: z)
    rig.scroll(-72, at: z)
    #expect(rig.haptics.played == [.alignment])

    // In over a file there is nothing to go into: the zoom comes to rest
    // at its deepest, and that is a stop too.
    for _ in 0..<60 where rig.haptics.played.count < 2 {
        rig.scroll(72, at: z)
    }
    #expect(rig.haptics.played == [.alignment, .alignment])
    #expect(rig.state.view.scale > 1)
    #expect(rig.state.crumbs == [])
    rig.scroll(72, at: z)
    #expect(rig.haptics.played == [.alignment, .alignment])
}

@MainActor
@Test func momentumAndAMouseWheelAreNotFelt() throws {
    let rig = Rig()
    let a = try rig.crumbs("a")
    let point = try rig.middle(a)

    // A mouse wheel's notches: no phases, whole lines. The level changes;
    // the trackpad has no finger on it to feel that.
    for _ in 0..<20 where rig.state.crumbs != a {
        rig.scroll(1, at: point, phase: [], precise: false)
    }
    #expect(rig.state.crumbs == a)
    #expect(rig.haptics.played.isEmpty)

    // Momentum carries on after the fingers lift: arriving at a stop in
    // it, and going through, are not felt either.
    let fresh = Rig()
    let far = try fresh.middle(try fresh.crumbs("a"))
    for _ in 0..<40 {
        fresh.scroll(24, at: far, phase: [], momentum: .changed)
    }
    #expect(fresh.state.crumbs == a)
    #expect(fresh.haptics.played.isEmpty)
}

// MARK: - Smart zoom

@MainActor
@Test func theSmartZoomTapGoesInAndComesBackWithAFeel() throws {
    let rig = Rig()
    let a = try rig.crumbs("a")
    let point = try rig.middle(a)

    rig.smartTap(at: point)
    #expect(rig.state.crumbs == a)
    #expect(rig.haptics.played == [.levelChange])
    rig.smartTap(at: point)
    #expect(rig.state.crumbs == [])
    #expect(rig.haptics.played == [.levelChange, .levelChange])

    // Over a file at the whole scanned root there is nowhere to go, and
    // nothing to feel.
    let z = try rig.middle(try rig.crumbs("z.bin"))
    rig.smartTap(at: z)
    #expect(rig.haptics.played == [.levelChange, .levelChange])

    // Magnified, the tap brings the whole level back: the tap landed.
    for _ in 0..<5 {
        rig.pinch(0.1, at: z)
    }
    #expect(rig.state.view.scale > 1)
    rig.smartTap(at: z)
    #expect(rig.state.view == .identity)
    #expect(rig.haptics.played.last == .generic)
}

// MARK: - Marks by pointer

@MainActor
@Test func marksMadeWithThePointerAreFeltMarksMadeWithKeysAreNot() throws {
    let rig = Rig()
    let z = try rig.crumbs("z.bin")
    let y = try rig.crumbs("y")
    let a = try rig.crumbs("a")

    // A plain click selects: the trackpad's own click says so already.
    try rig.click(at: try rig.middle(a))
    #expect(rig.state.selected == a)
    #expect(rig.haptics.played.isEmpty)

    // ⌘-click marks, and unmarks.
    try rig.click(at: try rig.middle(z), flags: .command)
    #expect(rig.state.path(at: z).map(rig.state.marks.contains) == true)
    #expect(rig.haptics.played == [.generic])
    try rig.click(at: try rig.middle(z), flags: .command)
    #expect(rig.state.marks.isEmpty)
    #expect(rig.haptics.played == [.generic, .generic])

    // The middle button marks too.
    rig.middleClick(at: try rig.middle(y))
    #expect(rig.state.marks.count == 1)
    #expect(rig.haptics.played.count == 3)

    // The context menu's Mark and Unmark.
    rig.view.perform(.mark, on: a)
    rig.view.perform(.unmark, on: a)
    #expect(rig.haptics.played.count == 5)

    // Space marks without a finger on the pad: nothing is felt.
    rig.state.select(z)
    rig.state.pointerExited()
    #expect(try press(rig.state, "space"))
    #expect(rig.state.path(at: z).map(rig.state.marks.contains) == true)
    #expect(rig.haptics.played.count == 5)
    #expect(rig.hooks.copied.isEmpty && rig.hooks.revealed.isEmpty)
}

@MainActor
@Test func theHostHandsTheViewItsEnvironmentsHaptics() throws {
    let state = AppState(
        root: "/nonexistent/disktree-platform",
        tree: gestureTree(),
        options: ScanOptions(),
        depth: 1
    )
    Hooks().capture(state)
    let recorder = HapticRecorder()
    let host = NSHostingView(
        rootView: TreemapView(state: state).environment(\.haptics, recorder)
    )
    let window = Support.offscreenWindow(host, size: Rig.size)
    defer { closeWindow(window) }
    let view = try #require(
        Support.firstSubview(of: TreemapNSView.self, in: host)
    )
    #expect((view.haptics as? HapticRecorder) === recorder)
    // Out of the box, the trackpad's.
    #expect(TreemapNSView(state: state).haptics is TrackpadHaptics)
}

// MARK: - Reduce Motion

@MainActor
@Test func underReduceMotionALevelChangeLandsAtOnce() async throws {
    let rig = Rig()
    let a = try rig.crumbs("a")
    // A frame drawn: what it read is what it hears about.
    _ = try Support.cached(rig.view)
    rig.smartTap(at: try rig.middle(a))
    #expect(rig.state.crumbs == a)
    // Moving, as it grows into place.
    #expect(rig.state.transition != nil)

    let still = Rig()
    still.view.reducesMotion = true
    _ = try Support.cached(still.view)
    still.smartTap(at: try still.middle(try still.crumbs("a")))
    await eventually { still.state.transition == nil }
    #expect(still.state.transition == nil)
    #expect(still.state.crumbs == a)
}

@MainActor
@Test func underReduceMotionAHoveredTileIsUpAtOnce() throws {
    let rig = Rig()
    rig.view.reducesMotion = true
    let z = try rig.crumbs("z.bin")
    let point = try rig.middle(z)
    let before = try Support.cached(rig.view)
    rig.view.mouseMoved(with: try rig.mouse(.mouseMoved, at: point))
    #expect(rig.state.hovered == z)
    // The first frame drawn after the pointer arrives is the settled one:
    // the tile fully lifted, as the painter draws a hovered tile at rest.
    let after = try Support.cached(rig.view)
    let theme = Theme.system(
        appearance: try #require(NSAppearance(named: .darkAqua))
    )
    let settled = try Support.paint(
        rig.state.prepare(),
        theme: theme,
        size: Rig.size,
        scale: after.scale
    )
    #expect(
        Support.near(
            after.rgb(point.x, point.y),
            settled.rgb(point.x, point.y),
            by: 3
        )
    )
    let lifted = after.rgb(point.x, point.y)
    let resting = before.rgb(point.x, point.y)
    #expect(
        lifted.reduce(0) { $0 + Int($1) } > resting.reduce(0) { $0 + Int($1) })
}

// MARK: - Dragging a tile out

@Test func aDragIsAFewPointsAwayAndStaysOutsideTheApp() {
    let start = CGPoint(x: 100, y: 100)
    #expect(!TileDragging.begins(from: start, to: start))
    #expect(!TileDragging.begins(from: start, to: CGPoint(x: 102, y: 102)))
    #expect(TileDragging.begins(from: start, to: CGPoint(x: 104, y: 100)))
    #expect(TileDragging.begins(from: start, to: CGPoint(x: 97, y: 97)))

    // Out of the app, whatever a drag from Finder may do: the destination
    // does it. Inside, nothing — the window would scan a tile dropped on it.
    let outside = TileDragging.operations(.outsideApplication)
    #expect(outside.contains([.copy, .link, .generic, .move, .delete]))
    #expect(TileDragging.operations(.withinApplication).isEmpty)

    let folder = TileDragging.url("/tmp/a folder", isDir: true)
    #expect(folder.hasDirectoryPath)
    #expect(folder.path(percentEncoded: false) == "/tmp/a folder/")
    #expect(!TileDragging.url("/tmp/a.bin", isDir: false).hasDirectoryPath)
}

@MainActor
@Test func aTileIsDraggedOutOnlyPastTheThreshold() throws {
    let rig = Rig()
    let z = try rig.crumbs("z.bin")
    let point = try rig.middle(z)

    rig.view.mouseDown(with: try rig.mouse(.leftMouseDown, at: point))
    #expect(rig.state.selected == z)
    // A trembling click is still a click.
    let nudge = CGPoint(x: point.x + 2, y: point.y + 1)
    rig.view.mouseDragged(with: try rig.mouse(.leftMouseDragged, at: nudge))
    #expect(rig.drags.isEmpty)
    // Past the threshold, the tile goes out as its file, once.
    let away = CGPoint(x: point.x + 12, y: point.y + 5)
    rig.view.mouseDragged(with: try rig.mouse(.leftMouseDragged, at: away))
    rig.view.mouseDragged(
        with: try rig.mouse(
            .leftMouseDragged,
            at: CGPoint(x: away.x + 30, y: away.y)
        )
    )
    let path = try #require(rig.state.path(at: z))
    #expect(
        rig.drags == [
            TileDrag(
                crumbs: z,
                url: URL(filePath: path.string, directoryHint: .notDirectory),
                origin: point
            )
        ]
    )
    // The hover and its tooltip stay behind, not under the drag.
    #expect(rig.state.pointer == nil)

    // A ⌘-press marks, and does not drag.
    let y = try rig.crumbs("y")
    let marking = try rig.middle(y)
    rig.view.mouseDown(
        with: try rig.mouse(.leftMouseDown, at: marking, flags: .command)
    )
    rig.view.mouseDragged(
        with: try rig.mouse(
            .leftMouseDragged,
            at: CGPoint(x: marking.x + 20, y: marking.y),
            flags: .command
        )
    )
    #expect(rig.drags.count == 1)
    #expect(rig.state.marks.count == 1)
}

@MainActor
@Test func aClickOnTheSelectionOpensOnlyIfItWasNotADrag() throws {
    let rig = Rig()
    let a = try rig.crumbs("a")
    let point = try rig.middle(a)
    try rig.click(at: point)
    #expect(rig.state.selected == a)

    // Pressed again and dragged: the directory goes out as a folder, and
    // is not opened on the way.
    rig.view.mouseDown(with: try rig.mouse(.leftMouseDown, at: point))
    #expect(rig.state.crumbs == [])
    rig.view.mouseDragged(
        with: try rig.mouse(
            .leftMouseDragged,
            at: CGPoint(x: point.x, y: point.y + 10)
        )
    )
    rig.view.mouseUp(with: try rig.mouse(.leftMouseUp, at: point))
    #expect(rig.state.crumbs == [])
    #expect(rig.drags.map(\.crumbs) == [a])
    #expect(rig.drags.first?.url.hasDirectoryPath == true)

    // Pressed and let go where it was: a second click, which opens it.
    rig.view.mouseDown(with: try rig.mouse(.leftMouseDown, at: point))
    #expect(rig.state.crumbs == [])
    rig.view.mouseUp(with: try rig.mouse(.leftMouseUp, at: point))
    #expect(rig.state.crumbs == a)
    #expect(rig.drags.count == 1)
}

// MARK: - Quick Look

@MainActor
@Test func thePanelFollowsTheQuickLookTarget() async throws {
    let rig = Rig()
    let panel = PanelRecorder()
    let quickLook = QuickLookController(state: rig.state, panel: panel)
    #expect(panel.calls.isEmpty)
    #expect(!quickLook.acceptsControl())

    // ⌘Y previews the tile a key acts on.
    let z = try rig.crumbs("z.bin")
    rig.state.select(z)
    let key = try #require(KeyStroke(parsing: "cmd-y"))
    #expect(dispatchKey(key, to: rig.state))
    await eventually { panel.isShowing }
    #expect(panel.calls == ["show"])
    #expect(quickLook.acceptsControl())
    let path = try #require(rig.state.path(at: z))
    #expect(quickLook.shown == path)
    #expect(quickLook.numberOfPreviewItems(in: nil) == 1)
    let item = quickLook.previewPanel(nil, previewItemAt: 0) as? NSURL
    #expect(item?.path == path.string)

    // The context menu's Quick Look on another tile moves it along.
    let y = try rig.crumbs("y")
    rig.view.perform(.quickLook, on: y)
    await eventually { panel.calls.count == 2 }
    #expect(panel.calls == ["show", "reload"])
    #expect(quickLook.shown == rig.state.path(at: y))

    // Escape takes it down.
    #expect(try press(rig.state, "escape"))
    await eventually { !panel.isShowing }
    #expect(panel.calls == ["show", "reload", "close"])
    #expect(quickLook.numberOfPreviewItems(in: nil) == 0)

    // Closed from the panel itself, the state names no target.
    rig.state.revealQuickLook(z)
    await eventually { panel.isShowing }
    quickLook.panelClosed()
    #expect(rig.state.quickLookTarget == nil)
    #expect(rig.hooks.copied.isEmpty && rig.hooks.revealed.isEmpty)
}

@MainActor
@Test func forceClickPreviewsTheTileAndThePanelZoomsFromIt() throws {
    let rig = Rig()
    let y = try rig.crumbs("y")
    let point = try rig.middle(y)
    let event = GestureEvent()
    event.kind = .pressure
    event.location = rig.windowPoint(point)
    rig.view.quickLook(with: event)
    #expect(rig.state.quickLookTarget == rig.state.path(at: y))

    // Where the tile is on the screen, for the panel's zoom.
    let path = try #require(rig.state.path(at: y))
    let rect = rig.state.view.project(try #require(rig.state.tileRect(y)))
    let local = CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h)
    let expected = rig.window.convertToScreen(rig.view.convert(local, to: nil))
    #expect(rig.view.screenFrame(of: path) == expected)
    // The directory drawn is the whole mosaic; what is not drawn, nothing.
    #expect(
        rig.view.screenFrame(of: rig.state.rootPath)
            == rig.window.convertToScreen(
                rig.view.convert(rig.view.bounds, to: nil)
            )
    )
    #expect(rig.view.screenFrame(of: "/nonexistent/elsewhere") == nil)
}

@MainActor
@Test func aForceClickOnTheSelectionPreviewsWithoutOpening() throws {
    let rig = Rig()
    let a = try rig.crumbs("a")
    let point = try rig.middle(a)
    try rig.click(at: point)
    #expect(rig.state.selected == a)

    // Down on the selection, pressed deeper, and let go: Quick Look shows
    // it, and the button coming up does not open it as a second click
    // would.
    rig.view.mouseDown(with: try rig.mouse(.leftMouseDown, at: point))
    let deep = GestureEvent()
    deep.kind = .pressure
    deep.location = rig.windowPoint(point)
    rig.view.quickLook(with: deep)
    rig.view.mouseUp(with: try rig.mouse(.leftMouseUp, at: point))
    #expect(rig.state.quickLookTarget == rig.state.path(at: a))
    #expect(rig.state.crumbs == [])
    #expect(rig.state.selected == a)

    // Nor does the pointer moving on with the button still down drag it.
    rig.view.mouseDown(with: try rig.mouse(.leftMouseDown, at: point))
    rig.view.quickLook(with: deep)
    rig.view.mouseDragged(
        with: try rig.mouse(
            .leftMouseDragged,
            at: CGPoint(x: point.x + 20, y: point.y)
        )
    )
    rig.view.mouseUp(with: try rig.mouse(.leftMouseUp, at: point))
    #expect(rig.drags.isEmpty)
    #expect(rig.state.crumbs == [])
}

@MainActor
@Test func theWindowHandsQuickLookItsQuestions() async throws {
    let state = AppState(
        root: "/nonexistent/disktree-platform",
        tree: gestureTree(),
        options: ScanOptions(),
        depth: 1
    )
    Hooks().capture(state)
    _ = NSApplication.shared
    let panel = PanelRecorder()
    let controller = MainWindowController(
        state: state,
        onScreen: false,
        quickLookPanel: panel
    )
    let window = try #require(controller.window)
    window.contentView?.layoutSubtreeIfNeeded()

    // Nothing to preview: the panel is not this window's to feed.
    #expect(!controller.acceptsPreviewPanelControl(nil))
    state.revealQuickLook([1])
    await eventually { panel.isShowing }
    #expect(controller.acceptsPreviewPanelControl(nil))
    #expect(controller.treemap != nil)

    // The window going takes the preview with it.
    closeWindow(of: controller)
    #expect(state.quickLookTarget == nil)
    await eventually { !panel.isShowing }
    #expect(panel.calls == ["show", "close"])
}

// MARK: - Settings

@MainActor
@Test func settingsAreSavedAndComeBack() throws {
    let rig = Rig()
    let store = MemoryPreferences()
    rig.state.adopt(Preferences(), store: store)
    let settings = SettingsView(state: rig.state)

    settings.binding(\.depth).wrappedValue = 5
    settings.binding(\.colorMode).wrappedValue = .age
    settings.binding(\.showPanel).wrappedValue = false
    settings.binding(\.commandStyle).wrappedValue = .remove
    settings.binding(\.includeHidden).wrappedValue = false
    settings.binding(\.apparentSize).wrappedValue = true
    settings.binding(\.oneFilesystem).wrappedValue = false

    // Saved as they were chosen, under the keys the next launch reads.
    #expect(store[.depth] as? Int == 5)
    #expect(store[.colorMode] as? String == "age")
    #expect(store[.showPanel] as? Bool == false)
    #expect(store[.commandStyle] as? String == "remove")
    #expect(store[.includeHidden] as? Bool == false)
    #expect(store[.apparentSize] as? Bool == true)
    #expect(store[.oneFilesystem] as? Bool == false)
    let relaunched = Preferences(store: store)
    #expect(relaunched == rig.state.preferences)
    #expect(settings.binding(\.depth).wrappedValue == 5)

    // What the run can take, it takes now; the scan options wait for the
    // next launch.
    #expect(rig.state.layoutOptions.maxDepth == 5)
    #expect(rig.state.colorMode == .age)
    #expect(!rig.state.showSelection)
    #expect(rig.state.commandStyle == .remove)
    #expect(rig.state.options.includeHidden)

    // And a value tuned by hand is what Settings shows.
    rig.state.adjustDepth(-1)
    #expect(settings.binding(\.depth).wrappedValue == 4)
    #expect(store[.depth] as? Int == 4)
}

@MainActor
@Test func theSettingsPaneDrawsInBothAppearances() throws {
    let rig = Rig()
    for (name, theme, appearance) in [
        ("dark", Theme.dark, NSAppearance.Name.darkAqua),
        ("light", Theme.light, .aqua),
    ] {
        let host = NSHostingView(
            rootView: SettingsView(state: rig.state, theme: theme)
        )
        let size = host.fittingSize
        #expect(size.width > 300 && size.height > 300, "\(size)")
        let window = Support.offscreenWindow(
            host,
            size: size,
            appearance: appearance
        )
        defer { closeWindow(window) }
        let painted = try Support.cached(host)
        painted.save("settings-\(name)")
        let ground = Support.rgbBytes(theme.background)
        #expect(
            painted.count(near: ground) > painted.width * painted.height / 2)
        #expect(painted.differing(from: ground) > 1_000)
    }

    // The window is one fixed pane, made without being shown.
    let controller = SettingsWindowController(state: rig.state)
    let window = try #require(controller.window)
    #expect(window.title == "Settings")
    #expect(!window.styleMask.contains(.resizable))
    #expect(window.styleMask.contains(.closable))
    #expect(!window.isVisible)
    closeWindow(window)
}

// MARK: - What VoiceOver is told

@MainActor
@Test func theTreemapTellsVoiceOverWhatAGlanceWould() throws {
    let rig = Rig()
    let a = try rig.crumbs("a")
    rig.state.select(a)
    let summary = rig.view.accessibilitySummary()
    #expect(summary.contains("/nonexistent/disktree-platform"))
    #expect(summary.contains(humanBytes(1_800_000)))
    #expect(summary.contains("selected a, \(humanBytes(700_000))"))
    #expect(rig.view.accessibilityValue() as? String == summary)
    rig.state.select(nil)
    #expect(rig.view.accessibilitySummary().hasSuffix("nothing selected"))

    // The first level, largest first, where each is on the screen.
    let elements = rig.view.accessibleTileElements()
    #expect(
        elements.map(\.crumbs)
            == [try rig.crumbs("z.bin"), a, try rig.crumbs("y")]
    )
    let first = try #require(elements.first { $0.crumbs == a })
    #expect(first.accessibilityLabel() == "a, \(humanBytes(700_000)), folder")
    #expect(first.accessibilityRole() == .button)
    let rect = rig.state.view.project(try #require(rig.state.tileRect(a)))
    let onScreen = rig.window.convertToScreen(
        rig.view.convert(
            CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h),
            to: nil
        )
    )
    #expect(first.accessibilityFrame() == onScreen)
    #expect(rig.view.accessibilityChildren()?.count == 3)

    // Found under VoiceOver's pointer, and pressed to select.
    let hit = rig.view.accessibilityHitTest(
        CGPoint(x: onScreen.midX, y: onScreen.midY)
    )
    #expect((hit as? TreemapTileElement)?.crumbs == a)
    #expect(first.accessibilityPerformPress())
    #expect(rig.state.selected == a)
    let again = rig.view.accessibleTileElements().first { $0.crumbs == a }
    #expect(again?.isAccessibilitySelected() == true)
    // The same element, so VoiceOver's cursor stays put.
    #expect(again === first)

    // Marked, it says so.
    rig.state.toggleMark(a)
    let marked = rig.view.accessibleTileElements().first { $0.crumbs == a }
    #expect(marked?.accessibilityLabel()?.hasSuffix(", marked") == true)
}

// MARK: - Labels in their bands

@MainActor
@Test func aNameInAnInnerBandKeepsItsDescenders() throws {
    // At every interface zoom, a name with descenders set in an inner band
    // keeps them inside it: what the band is for.
    for rem in zoomSteps.map({ baseRem * $0 }) {
        let typesetter = MosaicTypesetter(rem: rem)
        let metrics = typesetter.metrics
        let band = Rect(x: 0, y: 0, w: 400, h: 1.125 * rem)
        let label = TileLabel(
            text: "arm64-apple-macosx",
            rect: Rect(x: 0, y: 0, w: 400, h: 200),
            header: band,
            depth: 1,
            dim: false,
            marked: false,
            sizeText: "350MiB"
        )
        let mask = CGRect(x: 0, y: 0, width: 400, height: band.h)
        let ink = MosaicInk(Theme.dark.foreground)
        let name = typesetter.line(label.text, face: .name, color: ink)
        let size = typesetter.line(label.sizeText, face: .size, color: ink)
        let placed = MosaicPainter.place(
            label,
            mask: mask,
            metrics: metrics,
            name: name.measure,
            size: size.measure
        )
        #expect(placed.name.y + name.measure.descent <= mask.maxY, "\(rem)")
        #expect(placed.name.y - name.measure.ascent >= mask.minY, "\(rem)")
        let sizeBaseline = try #require(placed.size).y
        #expect(sizeBaseline + size.measure.descent <= mask.maxY, "\(rem)")
    }
}
