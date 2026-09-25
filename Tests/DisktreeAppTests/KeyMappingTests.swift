// From an AppKit key press to the dispatcher's `KeyStroke`, and what the
// window's key monitor does with it. The events are synthesized as AppKit
// would deliver them: the key code of the physical key, the characters the
// layout types, and the modifier flags.

import AppKit
import DisktreeCore
import Foundation
import SwiftUI
import System
import Testing

@testable import DisktreeApp

/// A key going down, as AppKit delivers one.
private func keyDown(
    _ keyCode: UInt16,
    _ characters: String,
    ignoring: String? = nil,
    _ flags: NSEvent.ModifierFlags = [],
    type: NSEvent.EventType = .keyDown
) throws -> NSEvent {
    try #require(
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: ignoring ?? characters,
            isARepeat: false,
            keyCode: keyCode
        )
    )
}

private func stroke(
    _ keyCode: UInt16,
    _ characters: String,
    ignoring: String? = nil,
    _ flags: NSEvent.ModifierFlags = []
) throws -> KeyStroke? {
    KeyStroke(
        event: try keyDown(keyCode, characters, ignoring: ignoring, flags)
    )
}

@Test func namedKeysComeFromTheKeyCode() throws {
    // What AppKit types for each: the arrows and Home/End type characters
    // from the private use area, and carry the function-key flags.
    let arrows: NSEvent.ModifierFlags = [.function, .numericPad]
    let named: [(UInt16, String, NSEvent.ModifierFlags, String)] = [
        (KeyCode.space, " ", [], "space"),
        (KeyCode.return, "\r", [], "enter"),
        (KeyCode.keypadEnter, "\u{3}", [.numericPad], "enter"),
        (KeyCode.escape, "\u{1B}", [], "escape"),
        (KeyCode.delete, "\u{7F}", [], "backspace"),
        (KeyCode.tab, "\t", [], "tab"),
        (KeyCode.leftArrow, "\u{F702}", arrows, "left"),
        (KeyCode.rightArrow, "\u{F703}", arrows, "right"),
        (KeyCode.upArrow, "\u{F700}", arrows, "up"),
        (KeyCode.downArrow, "\u{F701}", arrows, "down"),
        (KeyCode.home, "\u{F729}", [.function], "home"),
        (KeyCode.end, "\u{F72B}", [.function], "end"),
    ]
    for (code, characters, flags, name) in named {
        let key = try stroke(code, characters, flags)
        // Named keys type nothing into the find field.
        #expect(key == KeyStroke(name), "\(name)")
    }
}

@Test func keypadEnterIsEnter() throws {
    let key = try stroke(0x4C, "\u{3}", [.numericPad])
    #expect(key?.key == "enter")
    #expect(key?.character == nil)
}

@Test func namedKeysKeepTheirModifiers() throws {
    let backTab = try stroke(KeyCode.tab, "\u{19}", ignoring: "\t", [.shift])
    #expect(backTab == KeyStroke("tab", shift: true))
    let controlLeft = try stroke(
        KeyCode.leftArrow,
        "\u{F702}",
        [.control, .function, .numericPad]
    )
    #expect(controlLeft == KeyStroke("left", control: true))
}

@Test func shiftedCharactersAreTheKey() throws {
    // `?` is shift-slash on a US layout; the dispatcher binds `?`.
    let help = try stroke(0x2C, "?", [.shift])
    #expect(help == KeyStroke("?", character: "?", shift: true))
    // `!` unmarks everything in the review.
    let bang = try stroke(0x12, "!", [.shift])
    #expect(bang == KeyStroke("!", character: "!", shift: true))
    let plus = try stroke(0x18, "+", [.shift])
    #expect(plus?.key == "+")
    let plain = try stroke(0x08, "c")
    #expect(plain == KeyStroke("c", character: "c"))
}

@Test func chordsTypeNothing() throws {
    let zoomIn = try stroke(0x18, "=", [.control])
    #expect(zoomIn == KeyStroke("=", control: true))
    let zoomOut = try stroke(0x1B, "-", [.control])
    #expect(zoomOut == KeyStroke("-", control: true))
    // A control chord types a control character; the key is the letter.
    let controlA = try stroke(0x00, "\u{1}", ignoring: "a", [.control])
    #expect(controlA == KeyStroke("a", control: true))
    let quit = try stroke(0x0C, "q", [.command])
    #expect(quit == KeyStroke("q", command: true))
    let disk = try stroke(0x05, "G", [.command, .shift])
    #expect(disk == KeyStroke("G", shift: true, command: true))
}

@Test func optionTypesItsCharacter() throws {
    let key = try stroke(0x00, "å", ignoring: "a", [.option])
    #expect(key == KeyStroke("a", character: "å", option: true))
}

@Test func capsLockIsNotShift() throws {
    let key = try stroke(0x08, "C", ignoring: "C", [.capsLock])
    #expect(key == KeyStroke("c", character: "C"))
    let shifted = try stroke(0x08, "C", ignoring: "C", [.capsLock, .shift])
    #expect(shifted == KeyStroke("C", character: "C", shift: true))
}

@Test func globeChordsAreTheSystems() throws {
    // Globe-F is full screen: never `f`, which reveals in Finder.
    #expect(try stroke(0x03, "f", [.function]) == nil)
}

@Test func unnamedFunctionKeysAreNotText() throws {
    // F5 and Page Down type private-use characters that must not reach the
    // find field.
    #expect(try stroke(0x60, "\u{F708}", [.function]) == nil)
    #expect(try stroke(0x79, "\u{F72D}", [.function]) == nil)
}

@Test func aDeadKeyWaitsForItsLetter() throws {
    // ⌥E on a US layout: nothing typed yet.
    #expect(try stroke(0x0E, "", ignoring: "", [.option]) == nil)
}

@Test func onlyAKeyGoingDownIsAKey() throws {
    let up = try keyDown(KeyCode.space, " ", type: .keyUp)
    #expect(KeyStroke(event: up) == nil)
}

@MainActor
private func withState<T>(_ body: (AppState) throws -> T) throws -> T {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "disktree-keys-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: url) }
    let state = AppState(
        root: FilePath(url.path(percentEncoded: false)),
        options: ScanOptions(),
        depth: 3,
        startScanning: false
    )
    // Never the real pasteboard, never Finder.
    state.copyToPasteboard = { _ in Issue.record("copied to the pasteboard") }
    state.showInFinder = { _ in Issue.record("showed Finder") }
    state.onQuit = { Issue.record("quit") }
    return try body(state)
}

@Test @MainActor func commandChordsGoToTheMenus() throws {
    try withState { state in
        // Each is a menu's: Quit, Close, Open Folder…, Rescan, Copy, Copy
        // Cleanup Command, Scan Whole Disk. None may reach the dispatcher,
        // which would read ⌘Q as `q` and ⌘C as `c`.
        for notation in [
            "cmd-q", "cmd-w", "cmd-o", "cmd-r", "cmd-c", "cmd-shift-c",
            "cmd-shift-g", "cmd-g",
        ] {
            let key = try #require(KeyStroke(parsing: notation))
            #expect(!dispatchKey(key, to: state), "\(notation)")
        }
        #expect(state.screen == .explore)
        #expect(!state.showHelp)

        // The same from a real event.
        let quit = try keyDown(0x0C, "q", [.command])
        let key = try #require(KeyStroke(event: quit))
        #expect(!dispatchKey(key, to: state))
    }
}

@Test @MainActor func aKeyForAnotherWindowIsLetThrough() throws {
    try withState { state in
        _ = NSApplication.shared
        let controller = MainWindowController(state: state, onScreen: false)
        defer { closeWindow(of: controller) }
        // Not the key window, and not this window's event: an open panel
        // or the About window keeps its keys.
        let space = try keyDown(KeyCode.space, " ")
        let help = try keyDown(0x2C, "?", [.shift])
        #expect(!controller.takes(space))
        #expect(!controller.takes(help))
    }
}

@Test @MainActor func theWindowHandsItsToolbarAndTitleToTheSystem() async throws
{
    let url = FileManager.default.temporaryDirectory.appending(
        path: "disktree-window-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: url) }
    let root = FilePath(url.path(percentEncoded: false))
    let state = AppState(
        root: root,
        options: ScanOptions(),
        depth: 3,
        startScanning: false
    )
    _ = NSApplication.shared
    let controller = MainWindowController(state: state, onScreen: false)
    defer { closeWindow(of: controller) }
    let window = try #require(controller.window)

    #expect(window.contentView?.frame.size == MainWindowController.size)
    #expect(window.contentMinSize == MainWindowController.minimumSize)
    #expect(window.styleMask.contains(.fullSizeContentView))
    #expect(window.styleMask.contains(.resizable))
    // The screens' ground runs up under the toolbar's controls.
    #expect(window.titlebarAppearsTransparent)
    #expect(window.toolbarStyle == .unified)
    // SwiftUI's toolbar and title are the window's own.
    let host = try #require(
        window.contentViewController as? NSHostingController<WindowContent>
    )
    #expect(host.sceneBridgingOptions == [.toolbars, .title])
    #expect(host.sizingOptions.isEmpty)
    for _ in 0..<100 where (window.toolbar?.items ?? []).isEmpty {
        try await Task.sleep(for: .milliseconds(10))
    }
    let toolbar = try #require(window.toolbar)
    #expect(!toolbar.items.isEmpty)
    #expect(toolbar.isVisible)
    // A key nothing took ends its trip here, where the beep is silenced.
    #expect(window.nextResponder === controller)
    // The directory drawn, by name, and what it holds; the Window menu and
    // Mission Control use the title too.
    for _ in 0..<100 where window.title != ExploreView.title(state) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(window.title == url.lastPathComponent)
    #expect(window.subtitle == ExploreView.subtitle(state))

    // Kept in step with the directory on screen.
    state.rootPath = root.appending("elsewhere")
    for _ in 0..<100 where window.title != "elsewhere" {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(window.title == "elsewhere")
}

@MainActor
@Test func theReviewsActionsAreTheWindowsToolbar() async throws {
    // The window says its toolbar is SwiftUI's, so the review declares its
    // actions and its title there on its first frame, rather than waiting
    // to see a toolbar the explore screen took with it as it left.
    let state = AppState(
        root: "/nonexistent/disktree-review-toolbar",
        tree: Node.directory("window", children: []),
        options: ScanOptions(),
        depth: 3
    )
    _ = NSApplication.shared
    let controller = MainWindowController(state: state, onScreen: false)
    defer { closeWindow(of: controller) }
    let window = try #require(controller.window)
    for _ in 0..<100 where (window.toolbar?.items ?? []).isEmpty {
        try await Task.sleep(for: .milliseconds(10))
    }
    state.screen = .review
    for _ in 0..<100 where window.title != "Review" {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(window.title == "Review")
    let toolbar = try #require(window.toolbar)
    #expect(toolbar.isVisible)
    #expect(!toolbar.items.isEmpty)
    #expect(ReviewHost.bridges(toolbar))
}

@MainActor
@Test func theWindowButtonsStayPutAsScreensAndZoomChange() async throws {
    let state = AppState(
        root: "/nonexistent/disktree-window",
        tree: Node.directory("window", children: []),
        options: ScanOptions(),
        depth: 3
    )
    _ = NSApplication.shared
    let controller = MainWindowController(state: state, onScreen: false)
    defer { closeWindow(of: controller) }
    let window = try #require(controller.window)
    let content = try #require(window.contentView)
    let kinds: [NSWindow.ButtonType] = [
        .closeButton, .miniaturizeButton, .zoomButton,
    ]
    func buttons() throws -> [CGRect] {
        content.superview?.layoutSubtreeIfNeeded()
        return try kinds.map {
            let button = try #require(window.standardWindowButton($0))
            return button.convert(button.bounds, to: content)
        }
    }
    await Task.yield()
    let home = try buttons()

    // A key that changes the screen or the zoom moves nothing in the
    // window's corner: the buttons stay under the pointer.
    for screen in [Screen.review, .explore] {
        state.screen = screen
        for step in zoomSteps.indices {
            state.zoomStep = step
            await Task.yield()
            #expect(try buttons() == home, "\(screen) at step \(step)")
            #expect(window.toolbarStyle == .unified)
        }
    }
}

@MainActor
@Test func aTextFieldBeingEditedKeepsItsKeys() throws {
    let fixture = try ExploreFixture()
    let state = try exploreState(fixture)
    _ = NSApplication.shared
    let controller = MainWindowController(state: state, onScreen: false)
    defer { closeWindow(of: controller) }
    let window = try #require(controller.window)
    let content = try #require(window.contentView)
    // Nothing edited: every key is the dispatcher's.
    #expect(!controller.isEditingText)
    #expect(controller.route(KeyStroke("?", character: "?", shift: true)))
    #expect(state.showHelp)
    state.showHelp = false

    // A field being edited keeps what it types: the mosaic's keys pass by.
    let field = NSTextField(frame: CGRect(x: 20, y: 20, width: 200, height: 24))
    content.addSubview(field)
    defer { field.removeFromSuperview() }
    #expect(window.makeFirstResponder(field))
    #expect(controller.isEditingText)
    let selected = state.selected
    #expect(!controller.route(KeyStroke("space")))
    #expect(!controller.route(KeyStroke("c", character: "c")))
    #expect(state.screen == .explore && state.selected == selected)
    // Not the find's field: Escape and Enter are the field's too.
    #expect(!controller.route(KeyStroke("escape")))
    #expect(!controller.route(KeyStroke("enter")))

    // The find's field: Escape clears the filter and gives the keyboard
    // back to the mosaic.
    state.beginFind()
    state.setFind("blob")
    #expect(!controller.route(KeyStroke("b", character: "b")))
    #expect(controller.route(KeyStroke("escape")))
    #expect(state.find.isEmpty && !state.findOpen)
    #expect(!controller.isEditingText)

    // And Enter lays out the matches, and gives it back too.
    #expect(window.makeFirstResponder(field))
    state.beginFind()
    state.setFind("blob")
    #expect(controller.route(KeyStroke("enter")))
    #expect(!state.findOpen)
    #expect(!controller.isEditingText)
    // A chord is never the find's to take.
    #expect(window.makeFirstResponder(field))
    state.beginFind()
    #expect(!controller.route(KeyStroke("escape", control: true)))
    #expect(state.findOpen)
}

@MainActor
@Test func aClickOnTheScreenEndsEditingTheFind() throws {
    let fixture = try ExploreFixture()
    let state = try exploreState(fixture)
    _ = NSApplication.shared
    let controller = MainWindowController(state: state, onScreen: false)
    defer { closeWindow(of: controller) }
    let window = try #require(controller.window)
    let content = try #require(window.contentView)
    let field = NSTextField(frame: CGRect(x: 20, y: 20, width: 200, height: 24))
    content.addSubview(field)
    defer { field.removeFromSuperview() }
    func click(at point: CGPoint) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: point,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
    }
    // In the toolbar's band the field keeps the keyboard: a click there is
    // on the toolbar's own controls.
    #expect(window.makeFirstResponder(field))
    let band = CGPoint(x: 400, y: window.contentLayoutRect.maxY + 4)
    controller.endEditing(for: try click(at: band))
    #expect(controller.isEditingText)
    // On the screen below it, the field lets go; its text stays.
    controller.endEditing(for: try click(at: CGPoint(x: 400, y: 300)))
    #expect(!controller.isEditingText)
}

@Test @MainActor func menusShowTheKeysTheyAnswer() throws {
    let menus = MenuController()
    let bar = menus.mainMenu()
    #expect(
        bar.items.map(\.title) == [
            "disktree", "File", "Edit", "View", "Window", "Help",
        ]
    )

    func item(_ menu: String, _ title: String) throws -> NSMenuItem {
        try #require(bar.item(withTitle: menu)?.submenu?.item(withTitle: title))
    }
    let expected: [(String, String, String, NSEvent.ModifierFlags)] = [
        ("disktree", "Settings…", ",", .command),
        ("disktree", "Quit disktree", "q", .command),
        ("File", "Open Folder…", "o", .command),
        ("File", "Scan Whole Disk", "g", [.command, .shift]),
        ("File", "Rescan", "r", .command),
        ("File", "Quick Look", "y", .command),
        ("File", "Close", "w", .command),
        ("Edit", "Copy Cleanup Command", "c", [.command, .shift]),
        ("View", "Actual Size", "0", .command),
        ("View", "Zoom In", "=", .command),
        ("View", "Zoom Out", "-", .command),
        ("View", "Show All Keys", "?", []),
    ]
    for (menu, title, key, modifiers) in expected {
        let found = try item(menu, title)
        #expect(found.keyEquivalent == key, "\(title)")
        #expect(found.keyEquivalentModifierMask == modifiers, "\(title)")
    }

    // Before the state exists, nothing that needs it is on.
    #expect(!menus.validateMenuItem(try item("File", "Rescan")))
    #expect(menus.validateMenuItem(try item("Help", "disktree on GitHub")))

    let dock = menus.dockMenu()
    #expect(dock.items.map(\.title) == ["Scan the Whole Disk"])
}

@Test @MainActor func copyCleanupCommandNeedsACommand() throws {
    try withState { state in
        let menus = MenuController()
        menus.state = state
        let bar = menus.mainMenu()
        let copy = try #require(
            bar.item(withTitle: "Edit")?.submenu?.item(
                withTitle: "Copy Cleanup Command"
            )
        )
        // Nothing is marked, so there is nothing to copy.
        #expect(state.cleanupCommand() == nil)
        #expect(!menus.validateMenuItem(copy))
        let rescan = try #require(
            bar.item(withTitle: "File")?.submenu?.item(withTitle: "Rescan")
        )
        #expect(menus.validateMenuItem(rescan))
    }
}

/// `?` is the menu's only while nothing is typed in: in the search field
/// it is a character of the filter.
@Test @MainActor func showAllKeysLeavesTheSearchFieldItsQuestionMark() throws {
    try withState { state in
        @MainActor func offered(key: Bool = true, typing: Bool = false) -> Bool
        {
            MenuController.offersAllKeys(
                state,
                windowIsKey: key,
                typing: typing
            )
        }
        #expect(offered())
        #expect(!offered(key: false))
        #expect(!offered(typing: true))
        state.findOpen = true
        #expect(!offered())
        state.findOpen = false
        state.showHelp = true
        #expect(!offered())
    }
}

@Test @MainActor func anUnboundKeyIsQuietAnUnknownChordIsNot() throws {
    #expect(MainWindowController.isQuiet(try keyDown(0x06, "z")))
    #expect(MainWindowController.isQuiet(try keyDown(0x06, "Z", [.shift])))
    #expect(!MainWindowController.isQuiet(try keyDown(0x28, "k", [.command])))
    #expect(!MainWindowController.isQuiet(nil))
    let up = try keyDown(0x06, "z", type: .keyUp)
    #expect(!MainWindowController.isQuiet(up))
}
