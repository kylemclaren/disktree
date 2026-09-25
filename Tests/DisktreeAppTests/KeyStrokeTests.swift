// The key notation the tests and `--keys` use, and what the dispatcher
// makes of modifiers: ⌘ belongs to the menus, ctrl chords never type, and a
// letter binds the same with shift, as it did in Rust.

import DisktreeCore
import Testing

@testable import DisktreeApp

@Test func namedKeysParseWithoutText() throws {
    for name in [
        "space", "enter", "escape", "backspace", "tab", "left", "right", "up",
        "down", "home", "end",
    ] {
        let key = try #require(KeyStroke(parsing: name))
        #expect(key.key == name)
        #expect(key.character == nil, "\(name) types nothing")
        #expect(!key.control && !key.shift && !key.command && !key.option)
    }
}

@Test func aCharacterKeyTypesItself() throws {
    for text in ["c", "?", "=", "+", "!", "[", "/", "0"] {
        let key = try #require(KeyStroke(parsing: text))
        #expect(key.key == text)
        #expect(key.character == text)
    }
}

@Test func modifiersArePeeledOffOneAtATime() throws {
    let zoom = try #require(KeyStroke(parsing: "ctrl-="))
    #expect(zoom.key == "=" && zoom.control && !zoom.command)
    #expect(zoom.character == nil, "a control chord never types")

    let goTo = try #require(KeyStroke(parsing: "cmd-shift-g"))
    #expect(goTo.key == "g" && goTo.command && goTo.shift)
    #expect(goTo.character == nil)

    // A key that is itself `-` survives its modifier's dash.
    let out = try #require(KeyStroke(parsing: "ctrl--"))
    #expect(out.key == "-" && out.control)

    let dash = try #require(KeyStroke(parsing: "-"))
    #expect(dash.key == "-" && dash.character == "-")

    let option = try #require(KeyStroke(parsing: "alt-x"))
    #expect(option.key == "x" && option.option)
    #expect(option.character == "x", "option still types")

    let shifted = try #require(KeyStroke(parsing: "shift-tab"))
    #expect(shifted.key == "tab" && shifted.shift)
}

@Test func nonsenseDoesNotParse() {
    #expect(KeyStroke(parsing: "") == nil)
    #expect(KeyStroke(parsing: "ctrl-") == nil)
    #expect(KeyStroke(parsing: "cmd-") == nil)
    #expect(KeyStroke(parsing: "foo") == nil)
    #expect(KeyStroke(parsing: "ctrl-foo") == nil)
}

@MainActor
@Test func commandChordsAreLeftForTheMenus() throws {
    let tree = try fixture()
    let hooks = Hooks()
    let state = try stateOver(tree.root, hooks: hooks)
    let junk = try childCrumbs(state, [], "junk")
    state.toggleMark(junk)
    let epoch = state.scanEpoch

    for chord in ["cmd-q", "cmd-o", "cmd-r", "cmd-w", "cmd-c"] {
        #expect(try !press(state, chord), "\(chord) reaches the menus")
    }
    #expect(hooks.quits == 0, "⌘Q is the app menu's, not q")
    #expect(state.scanEpoch == epoch, "⌘R is the menu's Rescan")
    #expect(state.screen == .explore, "⌘C is Copy, not the review")

    // Even over a modal state: the overlay does not swallow ⌘Q.
    try press(state, "?")
    #expect(state.showHelp)
    #expect(try !press(state, "cmd-q"))
    #expect(state.showHelp)
    try press(state, "escape")
}

@MainActor
@Test func interfaceZoomTakesCommandAndControl() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    let base = state.rem
    #expect(try press(state, "cmd-="))
    #expect(state.rem > base)
    #expect(try press(state, "cmd-0"))
    #expect(state.rem == base)
    #expect(try press(state, "ctrl-+"))
    #expect(state.rem > base)
    #expect(try press(state, "ctrl-0"))
    // Every other chord is not the interface's.
    #expect(!state.zoomInterface(KeyStroke("x", control: true)))
    #expect(!state.zoomInterface(KeyStroke("=", character: "=")))
    // The steps end where they end.
    for _ in 0..<20 {
        state.zoomInterface(KeyStroke("=", command: true))
    }
    #expect(state.zoomStep == zoomSteps.count - 1)
    for _ in 0..<20 {
        state.zoomInterface(KeyStroke("-", command: true))
    }
    #expect(state.zoomStep == 0)
}

@MainActor
@Test func qQuitsAndAShiftedLetterIsTheSameKey() throws {
    let tree = try fixture()
    let hooks = Hooks()
    let state = try stateOver(tree.root, hooks: hooks)
    try press(state, "q")
    #expect(hooks.quits == 1)

    // Shift-c, as the shell spells it: the letter it types.
    state.toggleMark(try childCrumbs(state, [], "junk"))
    #expect(state.handleKey(KeyStroke("C", character: "C", shift: true)))
    #expect(state.screen == .review)
}

@MainActor
@Test func controlChordsNeverTypeInTheFindField() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    try press(state, "/")
    #expect(state.findOpen)
    #expect(try press(state, "ctrl-x"), "the field owns the keyboard")
    typeText(state, "ju")
    #expect(try press(state, "left"), "a named key types nothing")
    #expect(state.find == "ju")
    try press(state, "space")
    #expect(state.find == "ju ", "space types itself")
    try press(state, "backspace")
    #expect(state.find == "ju")
    try press(state, "escape")
    #expect(!state.findOpen && state.find.isEmpty)
}

@MainActor
@Test func aKeyNothingIsBoundToIsNotConsumed() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    #expect(try !press(state, "z"))
    #expect(try !press(state, "ctrl-x"), "x marks only without control")
    state.screen = .review
    #expect(try !press(state, "z"))
    #expect(try press(state, "escape"))
    #expect(state.screen == .explore)
}
