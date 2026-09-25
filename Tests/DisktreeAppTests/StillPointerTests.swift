// A pointer that rests while a key changes what is under it.
//
// Space, X and Enter act on the tile under the pointer when the pointer
// moved last. A key that changes the layout or the view — the depth, a zoom
// about the middle, a pan, the panel, the interface zoom — puts another tile
// under the same point, and the key after it must act on that one, or on
// the visible selection: never on the tile the pointer came to before.

import CoreGraphics
import DisktreeCore
import Foundation
import System
import Testing

@testable import DisktreeApp

/// A point on the deepest tile drawn, and that tile.
@MainActor
private func deepestTile(_ state: AppState) throws -> (CGPoint, [Int]) {
    let tiles = try #require(state.layout()).filter {
        if case .node = $0.kind { true } else { false }
    }
    let deepest = try #require(
        tiles.max { $0.crumbs.count < $1.crumbs.count }
    )
    return (centre(state, of: deepest.rect), deepest.crumbs)
}

@MainActor
@Test func aKeyAfterTheDepthChangesActsOnWhatIsUnderThePointerNow() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let (point, deep) = try deepestTile(state)
    state.pointerMoved(to: point)
    #expect(state.hovered == deep)

    try press(state, "[")
    let under = try #require(state.tile(atX: point.x, y: point.y))
    #expect(under != deep, "a shallower layout draws something else there")
    #expect(state.hovered == under, "the hover follows the layout")
    try press(state, "space")
    #expect(state.marks.items.map(\.path) == [state.path(at: under)])
}

@MainActor
@Test func aKeyAfterAZoomAboutTheMiddleActsOnWhatIsUnderThePointerNow()
    throws
{
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    // Near a corner, where magnifying about the middle moves the most.
    let point = CGPoint(x: 12, y: 12)
    state.pointerMoved(to: point)
    let before = try #require(state.hovered)
    for _ in 0..<6 {
        try press(state, "=")
    }
    let under = try #require(state.tile(atX: point.x, y: point.y))
    #expect(under != before, "the mosaic moved under the pointer")
    try press(state, "x")
    #expect(state.marks.items.map(\.path) == [state.path(at: under)])

    // Panned with shift and the wheel: the same.
    state.unmark(try #require(state.path(at: under)))
    state.scroll(at: point, lines: -8, shift: true)
    let panned = try #require(state.tile(atX: point.x, y: point.y))
    #expect(state.hovered == panned)
}

/// A shifted swipe on a trackpad pans whichever way the fingers go: the
/// left and right of a magnified view are reachable too.
@MainActor
@Test func aShiftedSwipePansSidewaysAsWellAsUpAndDown() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    state.zoom(atX: 550, y: 400, factor: 2, descend: false)
    let before = state.view
    let (across, down) = panLines(deltaX: 30, deltaY: 0)
    #expect(state.pan(lines: across, down) == .zoomed)
    #expect(state.view.originX == before.originX - 30.0 / 24 * 40 / 2)
    #expect(state.view.originY == before.originY, "sideways only")
    #expect(state.pan(lines: -1_000, 0) == .zoomed)
    #expect(
        state.view.originX == Double(treemapArea.width) / 2,
        "held inside the layout"
    )
}

@MainActor
@Test func aKeyAfterThePanelMovesActsOnTheSelectionNotAStaleTile() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let selected = try childCrumbs(state, [], "keep")
    state.select(selected)
    // Near the right edge, where a wider mosaic moves every tile the most.
    let wider = CGSize(
        width: treemapArea.width * 1.4,
        height: treemapArea.height
    )
    let points = stride(from: 4.0, to: treemapArea.height, by: 16).map {
        CGPoint(x: treemapArea.width - 4, y: $0)
    }
    let point = try #require(
        points.first { point in
            let before = state.tile(atX: point.x, y: point.y)
            state.treemapSize = wider
            defer { state.treemapSize = treemapArea }
            let after = state.tile(atX: point.x, y: point.y)
            return before != nil && before != selected && after != before
        }
    )
    state.pointerMoved(to: point)
    let stale = try #require(state.hovered)

    // The panel goes, and the mosaic widens under the resting pointer.
    try press(state, "p")
    state.treemapSize = wider
    #expect(state.tile(atX: point.x, y: point.y) != stale)
    #expect(state.hovered == nil && !state.pointerActive)
    try press(state, "space")
    #expect(state.marks.items.map(\.path) == [state.path(at: selected)])

    // So does the interface zoom, which moves the mosaic under it.
    state.clearMarks()
    state.pointerMoved(to: point)
    #expect(state.pointerActive)
    try press(state, "cmd-=")
    #expect(state.hovered == nil && !state.pointerActive)
}
