// The directory drawn, selected: what Enter, Backspace and the trail leave
// behind. It has no tile of its own at its level, so it is no tile for the
// keys that act on one: the arrows start from this level's first tile,
// Space and X say where it is marked from instead of taking everything on
// screen, and Escape goes up from it, as Backspace does.

import DisktreeCore
import Foundation
import System
import Testing

@testable import DisktreeApp

@MainActor
@Test func theArrowsMoveAfterEnteringALevel() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    state.select(try childCrumbs(state, [], "junk"))
    try press(state, "enter")
    let junk = state.crumbs
    #expect(state.selected == junk, "the directory drawn")

    try press(state, "right")
    let first = try #require(state.selected)
    #expect(first.count == junk.count + 1, "a tile at this level")
    #expect(first.starts(with: junk))
    // And on from there, whichever way the next tile lies.
    for arrow in ["right", "down", "left", "up"] where state.selected == first {
        try press(state, arrow)
    }
    #expect(state.selected != first)
    #expect(state.selected?.count == junk.count + 1)

    // Backspace and the trail leave the same selection behind.
    try press(state, "backspace")
    #expect(state.selected == [])
    try press(state, "down")
    #expect(state.selected?.count == 1)
    state.goTo(junk)
    try press(state, "left")
    #expect(state.selected?.count == junk.count + 1)
}

@MainActor
@Test func spaceNeverMarksTheDirectoryOnScreen() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    state.select(try childCrumbs(state, [], "junk"))
    try press(state, "enter")
    try press(state, "space")
    #expect(state.marks.isEmpty)
    #expect(state.notice?.text.contains("directory on screen") == true)
    try press(state, "x")
    #expect(state.marks.isEmpty)

    // A tile in it is marked as ever.
    try press(state, "right space")
    #expect(state.marks.count == 1)
    #expect(
        state.marks.items.first?.path.starts(with: tree.path("junk")) == true)
    #expect(state.marks.items.first?.path != tree.path("junk"))
}

@MainActor
@Test func escapeGoesUpFromTheDirectoryOnScreen() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let junk = try childCrumbs(state, [], "junk")
    state.select(junk)
    try press(state, "enter")
    #expect(state.crumbs == junk)
    try press(state, "escape")
    #expect(state.crumbs == [], "one press, as Backspace")

    // A tile selected is still what Escape takes first.
    state.select(junk)
    try press(state, "enter right")
    #expect(state.crumbs == junk)
    try press(state, "escape")
    #expect(state.crumbs == junk && state.selected == nil)
    try press(state, "escape")
    #expect(state.crumbs == [])
}
