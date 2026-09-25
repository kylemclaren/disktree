// The view transform, layout transitions and geometric directions: the
// pure geometry the state moves around with, ported from state.rs's unit
// tests.

import CoreGraphics
import DisktreeCore
import Testing

@testable import DisktreeApp

private func view() -> ViewTransform {
    ViewTransform(scale: 2, originX: 100, originY: 50)
}

private func close(_ a: Double, _ b: Double, within: Double = 0.001) -> Bool {
    abs(a - b) < within
}

@Test func projectingAndUnprojectingAreInverses() {
    let view = view()
    let point = view.unproject(x: 400, y: 300)
    let rect = Rect(x: point.x, y: point.y, w: 10, h: 10)
    let screen = view.project(rect)
    #expect(close(screen.x, 400))
    #expect(close(screen.y, 300))
    #expect(close(screen.w, 20))
}

@Test func zoomingKeepsThePointUnderTheCursorStill() {
    let view = ViewTransform.identity
    let before = view.unproject(x: 300, y: 200)
    let zoomed = view.zoomed(
        atX: 300,
        y: 200,
        factor: 2,
        ceiling: ViewTransform.maxScale
    )
    let screen = zoomed.project(Rect(x: before.x, y: before.y, w: 1, h: 1))
    #expect(close(screen.x, 300, within: 0.01), "\(screen)")
    #expect(close(screen.y, 200, within: 0.01), "\(screen)")
}

@Test func zoomingStopsAtTheCeilingAndTheFloor() {
    let view = ViewTransform.identity
    let high = view.zoomed(atX: 0, y: 0, factor: 100, ceiling: 3)
    #expect(high.scale == 3)
    let low = view.zoomed(atX: 0, y: 0, factor: 0.01, ceiling: 3)
    #expect(low.scale == ViewTransform.minScale)
}

@Test func clampingNeverLeavesAMargin() {
    let area = CGSize(width: 800, height: 600)
    let clamped = ViewTransform(scale: 2, originX: -500, originY: 900)
        .clamped(area)
    #expect(abs(clamped.originX) < .ulpOfOne)
    #expect(abs(clamped.originY - 300) < .ulpOfOne)

    let identity = ViewTransform(scale: 1, originX: 40, originY: 40)
        .clamped(area)
    #expect(abs(identity.originX) < .ulpOfOne)
    #expect(abs(identity.originY) < .ulpOfOne)
}

@Test func theVisibleBaseIsTheViewportInLayoutSpace() {
    let view = ViewTransform(scale: 2, originX: 100, originY: 50)
    let visible = view.visibleBase(CGSize(width: 800, height: 600))
    #expect(visible == Rect(x: 100, y: 50, w: 400, h: 300))
    #expect(
        ViewTransform.fitScale(
            Rect(x: 0, y: 0, w: 200, h: 300),
            area: CGSize(width: 800, height: 600)
        ) == 2
    )
    #expect(
        ViewTransform.fitScale(.zero, area: CGSize(width: 800, height: 600))
            == ViewTransform.minScale
    )
}

@Test func aTransitionStartsWhereTheRegionWasAndEndsWhereItIs() {
    // A region that occupied the whole viewport, landing in the top-left
    // quarter of the new layout: everything inside it must start twice as
    // large and centred where it was.
    let start = ContinuousClock.now
    let transition = LayoutTransition(
        src: Rect(x: 0, y: 0, w: 800, h: 600),
        dst: Rect(x: 0, y: 0, w: 400, h: 300),
        now: start
    )
    // A tile inside the destination, at the far corner.
    let tile = Rect(x: 200, y: 150, w: 200, h: 150)
    #expect(transition.sample(tile, at: start).running, "in flight")
    let origin = transition.origin(of: tile)
    #expect(close(origin.x, 400), "\(origin)")
    #expect(close(origin.y, 300), "\(origin)")
    #expect(close(origin.w, 400), "\(origin)")
    #expect(close(origin.h, 300), "\(origin)")

    // It starts exactly where the region was.
    #expect(transition.sample(tile, at: start).rect == origin)

    let (end, running) = transition.sample(
        tile,
        at: start + .milliseconds(500)
    )
    #expect(!running)
    #expect(end == tile, "it ends exactly at the real layout")
}

@Test func aTransitionGrowsATileThatIsBeingEntered() {
    // Entering a child: the child's region becomes the viewport, so
    // everything inside it gets bigger, never smaller.
    let transition = LayoutTransition(
        src: Rect(x: 100, y: 100, w: 200, h: 200),
        dst: Rect(x: 0, y: 0, w: 800, h: 600)
    )
    let tile = Rect(x: 400, y: 300, w: 100, h: 100)
    let origin = transition.origin(of: tile)
    #expect(origin.w < tile.w, "it starts smaller: \(origin)")
    #expect(
        origin.x > 100 && origin.x < 300,
        "and where the child was: \(origin)"
    )
}

@Test func longerPullsTakeALittleLongerButNeverLong() {
    let short = LayoutTransition(
        src: Rect(x: 0, y: 0, w: 800, h: 600),
        dst: Rect(x: 0, y: 0, w: 800, h: 600)
    )
    let long = LayoutTransition(
        src: Rect(x: 0, y: 0, w: 800_000, h: 600),
        dst: Rect(x: 0, y: 0, w: 8, h: 6)
    )
    #expect(short.duration == .milliseconds(130))
    #expect(long.duration == .milliseconds(130 + 4 * 45))
}

/// A frame samples the easing once for all of its tiles; it must land every
/// tile exactly where `sample` would.
@Test func aFramesMotionIsTheSampleOfEveryTile() {
    let start = ContinuousClock.now
    let transition = LayoutTransition(
        src: Rect(x: 100, y: 100, w: 200, h: 200),
        dst: Rect(x: 0, y: 0, w: 800, h: 600),
        now: start
    )
    let tiles = [
        Rect(x: 400, y: 300, w: 100, h: 100),
        Rect(x: 0, y: 0, w: 800, h: 600),
        Rect(x: 12.5, y: 7.25, w: 3, h: 900),
    ]
    for offset in [0, 20, 65, 129] {
        let now = start + .milliseconds(offset)
        let motion = transition.motion(at: now)
        #expect(motion != nil, "running at \(offset) ms")
        for tile in tiles {
            #expect(
                motion?.apply(tile) == transition.sample(tile, at: now).rect)
        }
    }
    #expect(transition.motion(at: start + .seconds(1)) == nil)
}

@Test func directionsOnlySeeGapsOnTheirOwnSide() {
    let from = Rect(x: 100, y: 100, w: 50, h: 50)
    let right = Rect(x: 200, y: 100, w: 50, h: 50)
    let left = Rect(x: 0, y: 100, w: 50, h: 50)
    #expect(Direction.right.gap(from: from, to: right) != nil)
    #expect(Direction.right.gap(from: from, to: left) == nil)
    #expect(Direction.left.gap(from: from, to: left) != nil)
    #expect(Direction.down.gap(from: from, to: right) == nil)
    #expect(Direction.right.gap(from: from, to: right) == 50)
    // Aligned neighbours have no perpendicular offset; stacked ones do.
    #expect(abs(Direction.right.offset(from: from, to: right)) < .ulpOfOne)
    #expect(
        Direction.right.offset(
            from: from,
            to: Rect(x: 200, y: 160, w: 20, h: 20)
        ) > 0
    )
}

@Test func halfAPointOfOverlapStillCountsAsThatWay() {
    let from = Rect(x: 0, y: 0, w: 50, h: 50)
    let touching = Rect(x: 49.6, y: 0, w: 50, h: 50)
    #expect(Direction.right.gap(from: from, to: touching) == 0)
    let overlapping = Rect(x: 49, y: 0, w: 50, h: 50)
    #expect(Direction.right.gap(from: from, to: overlapping) == nil)
}

@Test func thePanelWidthStaysWithinItsLimits() {
    // The limits, for any window: a minimum, a maximum, and never so wide
    // that the mosaic gets less room than the panel's own minimum.
    #expect(
        panelWidthLimits(viewport: 3_000, rem: 16)
            == PanelSize.minRems...PanelSize.maxRems
    )
    let squeezed = panelWidthLimits(viewport: 800, rem: 16)
    #expect(abs(squeezed.upperBound - (800 / 16 - PanelSize.minRems)) < 1e-3)
    // A window too narrow for both keeps the panel its own minimum.
    #expect(
        panelWidthLimits(viewport: 300, rem: 16)
            == PanelSize.minRems...PanelSize.minRems
    )
}
