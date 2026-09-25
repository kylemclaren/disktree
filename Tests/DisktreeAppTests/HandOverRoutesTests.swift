// The routes a single tile is handed over by — the context menu, Copy Path,
// Reveal in Finder, Quick Look, a mark — and the two ways they could name
// the wrong entry: crumbs from a tree that has since been replaced, and a
// name the walk could not decode.

import AppKit
import DisktreeCore
import Foundation
import System
import Testing

@testable import DisktreeApp

/// A right-click at a view-local point of `view`, which fills `window`.
@MainActor
private func rightClick(
    at local: CGPoint,
    in view: NSView,
    window: NSWindow
) throws -> NSEvent {
    try #require(
        NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: view.convert(local, to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    )
}

/// Choose the item titled `title` from `menu`, as a person would.
@MainActor
private func choose(_ title: String, from menu: NSMenu) throws {
    let index = menu.indexOfItem(withTitle: title)
    try #require(index >= 0, "no \(title) in \(menu.items.map(\.title))")
    menu.performActionForItem(at: index)
}

/// A menu opened on one tile, then a tree landing while it is open, which
/// renumbers every crumb: the items still act on the tile it was opened on.
@MainActor
@Test func aContextMenuActsOnItsTileAfterANewTreeLands() throws {
    let fixture = try TreemapFixture.make(TreemapFixture.small)
    defer { fixture.remove() }
    let harness = TreemapHarness(root: fixture.root, tree: try fixture.scan())
    let state = harness.state
    let view = TreemapNSView(state: state)
    let window = TreemapSupport.offscreenWindow(
        view,
        size: CGSize(width: 800, height: 600)
    )
    defer { closeWindow(window) }
    view.layoutSubtreeIfNeeded()

    let cache = try #require(
        state.crumbs(for: fixture.root.appending(".cache"))
    )
    #expect(cache == [0], "largest by size")
    let tile = try #require(
        state.layout()?.first { $0.crumbs == cache }
    )
    let point = centre(state, of: tile.rect)
    let opened = try #require(state.tile(atX: point.x, y: point.y))
    let path = try #require(state.path(at: opened))
    #expect(path.starts(with: fixture.root.appending(".cache")))
    let menu = try #require(
        view.menu(for: try rightClick(at: point, in: view, window: window))
    )

    // Ranked by files, `junk` is first: the crumbs the menu was opened on
    // name something else now.
    state.toggleMetric()
    #expect(state.node(at: [0])?.name == "junk")
    #expect(state.path(at: opened) != path)

    try choose("Copy Path", from: menu)
    #expect(harness.copied == [path.string])
    try choose("Reveal in Finder", from: menu)
    #expect(harness.revealed == [[path]])
    try choose("Mark", from: menu)
    #expect(state.marks.items.map(\.path) == [path])
}

/// A tile inside a marked directory cannot be marked on its own: its menu
/// offers to unmark the directory, as the panel does.
@MainActor
@Test func aTileInsideAMarkedDirectoryOffersToUnmarkIt() throws {
    let fixture = try TreemapFixture.make(TreemapFixture.small)
    defer { fixture.remove() }
    let harness = TreemapHarness(root: fixture.root, tree: try fixture.scan())
    let state = harness.state
    let view = TreemapNSView(state: state)
    let window = TreemapSupport.offscreenWindow(
        view,
        size: CGSize(width: 800, height: 600)
    )
    defer { closeWindow(window) }
    view.layoutSubtreeIfNeeded()

    let junk = try #require(state.crumbs(for: fixture.root.appending("junk")))
    state.toggleMark(junk)
    let deeper = try #require(
        state.crumbs(for: fixture.root.appending("junk/deeper"))
    )
    let tile = try #require(state.layout()?.first { $0.crumbs == deeper })
    let menu = try #require(
        view.menu(
            for: try rightClick(
                at: centre(state, of: tile.rect),
                in: view,
                window: window
            )
        )
    )
    let titles = menu.items.map { $0.title }
    #expect(!titles.contains("Mark"))
    #expect(titles.contains("Unmark junk"))
    try choose("Unmark junk", from: menu)
    #expect(state.marks.isEmpty)
    #expect(state.notice == nil)
}

/// A name the walk could not decode, as a network or user-space filesystem
/// may hold one: its decoded spelling names another entry — here an
/// unmarked neighbour whose name really is that text — or none. Nothing
/// hands that spelling over, and a mark on it is never read as gone.
@MainActor
@Test func aNameTheScanCouldNotDecodeIsNeverHandedOver() async throws {
    let files = try TempTree([("a\u{FFFD}b", 10), ("plain", 10)])
    let decoded = String(decoding: [0x61, 0xFF, 0x62], as: UTF8.self)
    let tree = Node.directory(
        "root",
        children: [
            .entry(decoded, kind: .file, bytes: 10),
            .entry("plain", kind: .file, bytes: 10),
        ]
    )
    let hooks = Hooks()
    let state = AppState(
        root: files.root,
        tree: tree,
        options: fixtureOptions,
        depth: 3
    )
    hooks.capture(state)
    let lossy = try #require(
        state.tree?.children.firstIndex { $0.name == decoded }
    )

    #expect(!state.toggleMark([lossy]))
    #expect(state.marks.isEmpty)
    #expect(state.notice?.text.contains("Finder") == true)

    state.copyPath([lossy])
    #expect(hooks.copied.isEmpty)
    state.revealInFinder([lossy])
    #expect(hooks.revealed == [[files.root]], "the folder that holds it")
    state.select([lossy])
    #expect(!state.toggleQuickLook())
    #expect(state.quickLookTarget == nil)

    // A mark on it all the same — from before, from a test — is never gone
    // by the look of its decoded spelling.
    let path = files.root.appending(decoded)
    state.marks.toggle(
        Target(path: path, bytes: 10, isDir: false, hidden: false)
    )
    try FileManager.default.removeItem(atPath: files.path("a\u{FFFD}b").string)
    await state.checkDisk()
    #expect(state.gone.isEmpty)
    #expect(state.marks.items.map(\.path) == [path])
}
