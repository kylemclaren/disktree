// What the review screen's tests share: the Rust window tests' fixture, a
// state over a real scan of it, and an offscreen window that draws the
// screen into pixels and clicks its controls the way a person would.
//
// Nothing here reaches outside the process: every state made here has its
// pasteboard and Finder hooks pointed at a recorder, so a test can never
// write to the real pasteboard or open a Finder window.

import AppKit
import DisktreeCore
import Foundation
import SwiftUI
import System
import Testing

@testable import DisktreeApp

// MARK: - The fixture

/// A small tree on disk: two directories, a nested file, and a hidden one
/// holding the largest file (the Rust `fixture()`). Removed from disk when
/// the value is released.
final class ReviewFixture {
    let root: FilePath

    init() throws {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "disktree-review-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        root = FilePath(url.path(percentEncoded: false))
        for (path, bytes) in [
            ("keep/notes.txt", 1_000),
            ("junk/blob.bin", 200_000),
            ("junk/deeper/more.bin", 100_000),
            (".cache/blob.bin", 300_000),
        ] {
            try write(path, bytes: bytes)
        }
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root.string)
    }

    /// Write `bytes` bytes at `relative`, making its directories.
    func write(_ relative: String, bytes: Int) throws {
        let file = root.appending(relative)
        try FileManager.default.createDirectory(
            atPath: file.removingLastComponent().string,
            withIntermediateDirectories: true
        )
        try Data(repeating: UInt8(ascii: "x"), count: bytes)
            .write(to: URL(filePath: file.string))
    }

    func path(_ relative: String) -> FilePath {
        root.appending(relative)
    }
}

/// Apparent sizes, so what is asserted is the tree and not how the
/// filesystem rounds a small file up to a block.
let reviewOptions = ScanOptions(apparentSize: true)

// MARK: - The state

/// What the state's hooks were handed instead of the pasteboard and Finder.
@MainActor
final class ReviewHooks {
    var copied: [String] = []
    var revealed: [[FilePath]] = []
}

/// A state over a real scan of `fixture`, without the background walk, its
/// hooks pointed at `hooks`.
@MainActor
func reviewState(
    _ fixture: ReviewFixture,
    hooks: ReviewHooks = ReviewHooks()
) throws -> AppState {
    let tree = try scan(fixture.root, options: reviewOptions)
    let state = AppState(
        root: fixture.root,
        tree: tree,
        options: reviewOptions,
        depth: 3
    )
    state.copyToPasteboard = { hooks.copied.append($0) }
    state.showInFinder = { hooks.revealed.append($0) }
    state.screen = .review
    return state
}

/// The mark the treemap would make for `relative`: its size and kind as the
/// scan found them.
@MainActor
func reviewTarget(
    _ state: AppState,
    _ relative: String
) throws -> Target {
    let path = state.rootPath.appending(relative)
    let tree = try #require(state.tree)
    let node = try #require(
        findNode(rootPath: state.rootPath, root: tree, path: path)
    )
    return Target(
        path: path,
        bytes: node.value(state.options.metric),
        isDir: node.isDir,
        hidden: isHidden(path)
    )
}

/// Mark `relative`, as a stored property: the marking logic is the state's.
@MainActor
func reviewMark(_ state: AppState, _ relative: String) throws {
    state.marks.toggle(try reviewTarget(state, relative))
}

/// What the review screen would read once the state is integrated: the
/// plan and the command from the core, over the state's own marks and
/// style.
@MainActor
func reviewFromCore(
    _ state: AppState,
    measuredGain: UInt64? = nil
) -> ReviewModel {
    let plan = DisktreeCore.plan(
        state.marks.items,
        root: state.rootPath,
        home: state.home
    )
    return ReviewModel(
        state,
        plan: plan,
        command: cleanupCommand(plan, style: state.commandStyle),
        measuredGain: measuredGain
    )
}

/// Every action the screen can take, recorded instead of taken.
@MainActor
final class ReviewActionLog {
    enum Action: Hashable {
        case copy
        case reveal
        case unmark(FilePath)
        case clear
        case back
        case choose(CommandStyle)
        case revealPaths([FilePath])
        case copyPaths([FilePath])
        case quickLook(FilePath)
    }

    var actions: [Action] = []

    var recording: ReviewActions {
        ReviewActions(
            copy: { self.actions.append(.copy) },
            reveal: { self.actions.append(.reveal) },
            unmark: { self.actions.append(.unmark($0)) },
            clear: { self.actions.append(.clear) },
            back: { self.actions.append(.back) },
            choose: { self.actions.append(.choose($0)) },
            revealPaths: { self.actions.append(.revealPaths($0)) },
            copyPaths: { self.actions.append(.copyPaths($0)) },
            quickLook: { self.actions.append(.quickLook($0)) }
        )
    }
}

// MARK: - The stage

/// The window size the app opens at.
let reviewWindowSize = CGSize(width: 1440, height: 900)

/// An offscreen window hosting a screen, in one appearance at one rem, as
/// `RootView` would provide them: the system theme for the window's
/// appearance, and the state's rem.
@MainActor
final class ReviewStage {
    let window: NSWindow
    let host: NSHostingView<AnyView>
    let theme: Theme
    /// Where each named control is, in the host's top-left coordinates,
    /// from the last layout.
    private(set) var controls: [String: CGRect] = [:]
    private let sink: FrameSink

    init(
        _ content: some View,
        appearance: NSAppearance.Name,
        rem: CGFloat = baseRem,
        size: CGSize = reviewWindowSize
    ) throws {
        _ = NSApplication.shared
        let look = try #require(NSAppearance(named: appearance))
        theme = Theme.system(appearance: look)
        window = ReviewWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // Ordering a window in or out animates it on another thread, and
        // the animation ends by stopping the main run loop, whichever turn
        // of it is running: while a test awaits, the test runner's own,
        // which then exits with tests still running.
        window.animationBehavior = .none
        window.appearance = look
        let frames = FrameSink()
        host = NSHostingView(
            rootView: AnyView(
                content
                    .frame(width: size.width, height: size.height)
                    .environment(\.theme, theme)
                    .environment(\.rem, rem)
                    .overlayPreferenceValue(ReviewControls.self) { anchors in
                        GeometryReader { proxy in
                            frames.note(anchors.mapValues { proxy[$0] })
                        }
                    }
            )
        )
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        sink = frames
        settle()
    }

    /// Let SwiftUI finish what it does after a change (a lazy list fills in
    /// on the next pass), then lay out. Wait `seconds` for something that
    /// takes longer: an animation to finish.
    func settle(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        controls = sink.frames
    }

    /// The window as it would be drawn now.
    func render() throws -> NSBitmapImageRep {
        settle()
        let rep = try #require(
            host.bitmapImageRepForCachingDisplay(in: host.bounds)
        )
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Click the control named `id` in its centre, the way a mouse does.
    func click(_ id: String) throws {
        settle()
        let frame = try #require(controls[id], "no control \(id)")
        try click(at: CGPoint(x: frame.midX, y: frame.midY))
    }

    /// Click at `point`, in the host's top-left coordinates, the way a
    /// mouse clicks a control.
    ///
    /// A control in a table's row hands its mouse-down to the table, which
    /// reads the rest of the click from the application's queue itself: the
    /// mouse-up is put there first, and sent after the mouse-down only if
    /// nothing took it.
    func click(at point: CGPoint) throws {
        settle()
        putOnScreen()
        let location = host.convert(point, to: nil)
        let down = try mouse(.leftMouseDown, at: location)
        let up = try mouse(.leftMouseUp, at: location)
        let window = window
        try inTurnOfItsOwn {
            let app = NSApplication.shared
            try queue(up)
            window.sendEvent(down)
            if let left = app.nextEvent(
                matching: .leftMouseUp,
                until: .distantPast,
                inMode: .default,
                dequeue: true
            ) {
                window.sendEvent(left)
            }
        }
        handBackTheRunLoop()
        settle()
    }

    /// Click at `point` on AppKit's own table or its header, with
    /// `modifiers` held; a `count` of two is a double-click, sent as the
    /// click and then the second one, as AppKit sends it.
    ///
    /// A window of an app that is not active spends a plain click on
    /// bringing the app forward, unless the view under it takes the first
    /// click, as SwiftUI's controls do and a table does not; ⌘-click alone
    /// goes through. The test process can never be active (its activation
    /// policy is prohibited, so nothing here takes the focus from anyone),
    /// so the click is handed to the view under the pointer, as the window
    /// would hand it once the app were in front, with the mouse-up already
    /// queued for the table to read.
    func pick(
        at point: CGPoint,
        modifiers: NSEvent.ModifierFlags = [],
        count: Int = 1
    ) throws {
        settle()
        putOnScreen()
        let location = host.convert(point, to: nil)
        let view = try #require(window.contentView?.hitTest(location))
        var clicks: [(NSEvent, NSEvent)] = []
        for click in 1...max(count, 1) {
            clicks.append(
                (
                    try mouse(.leftMouseDown, at: location, modifiers, click),
                    try mouse(.leftMouseUp, at: location, modifiers, click)
                )
            )
        }
        try inTurnOfItsOwn {
            let app = NSApplication.shared
            for (down, up) in clicks {
                try queue(up)
                view.mouseDown(with: down)
                if let left = app.nextEvent(
                    matching: .leftMouseUp,
                    until: .distantPast,
                    inMode: .default,
                    dequeue: true
                ) {
                    view.mouseUp(with: left)
                }
            }
        }
        handBackTheRunLoop()
        settle()
    }

    /// Choose `style` on the command's segmented control, as a click on
    /// its side does: the reversible choice is the left segment, rm the
    /// right. The control is AppKit's, which, like a table, does not take
    /// the first click of an app that is not in front: the click is handed
    /// to it as the window would once the app were (see `pick`). Sent
    /// through the window instead, it is spent on bringing the app forward,
    /// and the window then swallows the next click into the table too.
    func choose(_ style: CommandStyle) throws {
        settle()
        let picker = try #require(controls["review-style"], "no style")
        let side = style == .trash ? 0.25 : 0.75
        try pick(
            at: CGPoint(
                x: picker.minX + picker.width * side,
                y: picker.midY
            )
        )
    }

    /// Press a key and let it go, as the keyboard sends it to the window's
    /// first responder.
    func press(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = []
    ) throws {
        settle()
        putOnScreen()
        var events: [NSEvent] = []
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            events.append(
                try #require(
                    NSEvent.keyEvent(
                        with: type,
                        location: .zero,
                        modifierFlags: modifiers,
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber,
                        context: nil,
                        characters: characters,
                        charactersIgnoringModifiers: characters,
                        isARepeat: false,
                        keyCode: keyCode
                    )
                )
            )
        }
        let window = window
        try inTurnOfItsOwn {
            for event in events {
                window.sendEvent(event)
            }
        }
        handBackTheRunLoop()
        settle()
    }

    /// A mouse event at `location`, in window coordinates, the `clicks`th
    /// of a run of clicks.
    private func mouse(
        _ type: NSEvent.EventType,
        at location: CGPoint,
        _ modifiers: NSEvent.ModifierFlags = [],
        _ clicks: Int = 1
    ) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: clicks,
                pressure: 1
            )
        )
    }

    /// The table AppKit draws the marked list with, if the screen has one.
    var table: NSTableView? {
        func find(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView {
                return table
            }
            for child in view.subviews {
                if let table = find(child) {
                    return table
                }
            }
            return nil
        }
        return find(host)
    }

    /// Where the row of the mark `index` (in marking order) is on screen,
    /// in the host's top-left coordinates: across the table, at the height
    /// of that row's unmark button.
    func row(_ index: Int) throws -> CGRect {
        settle()
        let unmark = try #require(controls["unmark-\(index)"])
        let table = try #require(table)
        let frame = table.convert(table.bounds, to: host)
        return CGRect(
            x: frame.minX,
            y: unmark.minY,
            width: frame.width,
            height: unmark.height
        )
    }

    /// Put the window on screen, where AppKit delivers events to it: fully
    /// transparent, far off every display, and key, so a key press reaches
    /// the view that holds the keyboard.
    private func putOnScreen() {
        guard !window.isVisible else {
            return
        }
        window.alphaValue = 0
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.makeKeyAndOrderFront(nil)
        awaitTheWindowServer(answering: window.windowNumber)
        settle()
    }

    func close() {
        // Put on screen, the window had its answer then; one never shown
        // has it now, as it closes.
        guard window.isVisible else {
            closeWindow(window)
            return
        }
        window.orderOut(nil)
        window.close()
        handBackTheRunLoop(waiting: false)
    }
}

/// Leave the main run loop as the test runner expects to find it: nothing
/// of ours queued, and no stop pending.
///
/// A double click that a table settles on leaves the second mouse-up
/// unread, and it must not reach the next test. And a stop that lands
/// while no loop of ours is running is remembered by the run loop: the next
/// one to run — the runner's own `CFRunLoopRun` — returns at once, and the
/// run ends with tests unfinished and exit status 0. Empty turns consume
/// it. A table also waits out the double-click interval before it acts on a
/// single click, and posts an event when it does: the wait runs here, in a
/// loop of ours, so that stop lands on it and not on the runner.
@MainActor
func handBackTheRunLoop(waiting: Bool = true) {
    let wait = waiting ? NSEvent.doubleClickInterval + 0.1 : 0
    let settled = Date(timeIntervalSinceNow: wait)
    while settled.timeIntervalSinceNow > 0 {
        _ = CFRunLoopRunInMode(
            .defaultMode,
            max(settled.timeIntervalSinceNow, 0),
            false
        )
    }
    let app = NSApplication.shared
    while app.nextEvent(
        matching: .any,
        until: .distantPast,
        inMode: .default,
        dequeue: true
    ) != nil {}
    var turns = 0
    while turns < 8, CFRunLoopRunInMode(.defaultMode, 0, true) == .stopped {
        turns += 1
    }
}

/// Close `window`, wait in a loop of ours for the window server to answer,
/// and leave the run loop as the runner expects to find it.
///
/// The first time a window is ordered in or out, and closing a window that
/// was never on screen orders it out, the window server answers about a
/// tenth of a second later with an event that says where the window is.
/// The event stops whichever loop is running when it arrives. If that is
/// the runner's own, because the test that closed the window has returned,
/// the run ends there with tests unfinished and exit status 0. It is waited
/// for here instead, so the stop it brings ends a loop of ours.
@MainActor
func closeWindow(_ window: NSWindow) {
    let number = window.windowNumber
    window.close()
    awaitTheWindowServer(answering: number)
}

/// Close the window `controller` holds, as `closeWindow(_:)` closes one.
@MainActor
func closeWindow(of controller: NSWindowController) {
    let number = controller.window?.windowNumber ?? 0
    controller.close()
    awaitTheWindowServer(answering: number)
}

/// Wait, in a loop of ours, for the window server's answer about window
/// `number` (see `closeWindow(_:)`), then hand the run loop back.
///
/// A window the server has not made yet, as one made with `defer` is until
/// it is shown, has no number and gets no answer. A second has room for the
/// server's slowest answer, which comes when the process has only just
/// connected to it.
@MainActor
func awaitTheWindowServer(answering number: Int) {
    if number > 0 {
        let app = NSApplication.shared
        let deadline = Date(timeIntervalSinceNow: 1)
        while let event = app.nextEvent(
            matching: .appKitDefined,
            until: deadline,
            inMode: .default,
            dequeue: true
        ), event.windowNumber != number {}
    }
    handBackTheRunLoop(waiting: false)
}

/// Run `work` in a turn of the main run loop of its own, and return once
/// it has run.
///
/// Posting an event, which a click here does and which a table does while
/// it tells a click from a drag, stops the run loop that is running, so
/// that whatever waits for events wakes up. Called from a test, that is
/// the test runner's own loop, `CFRunLoopRun`: it returns, and the runner
/// exits with tests still running. In a turn of its own, the stop ends
/// that turn instead.
@MainActor
private func inTurnOfItsOwn(
    _ work: @escaping @MainActor () throws -> Void
) throws {
    let main = CFRunLoopGetMain()
    var outcome: Result<Void, any Error>?
    CFRunLoopPerformBlock(main, CFRunLoopMode.defaultMode.rawValue) {
        outcome = Result { try MainActor.assumeIsolated { try work() } }
    }
    CFRunLoopWakeUp(main)
    while outcome == nil {
        _ = CFRunLoopRunInMode(.defaultMode, 1, false)
    }
    try outcome?.get()
}

/// Put `event` in the application's queue, and wait until it is there: a
/// posted event arrives on the next turn of the run loop, and whatever
/// reads the queue before then finds it empty.
@MainActor
private func queue(_ event: NSEvent) throws {
    let app = NSApplication.shared
    app.postEvent(event, atStart: false)
    try #require(
        app.nextEvent(
            matching: NSEvent.EventTypeMask(type: event.type),
            until: Date(timeIntervalSinceNow: 1),
            inMode: .default,
            dequeue: false
        ) != nil,
        "the event never reached the queue"
    )
}

/// A borderless window that behaves as the app's own window does while it
/// is in front: it takes the keyboard, and a click lands on what it was
/// aimed at.
///
/// A test process can never become the active app, so AppKit would never
/// make this window key, and it spends the first click on a window that is
/// not key on bringing it forward. Activating the process instead would
/// take the focus from whatever the person running the tests is doing.
private final class ReviewWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { isVisible }
}

/// Where the controls were in the last layout. Written while the overlay is
/// drawn, which is the only moment their anchors can be resolved.
@MainActor
private final class FrameSink {
    var frames: [String: CGRect] = [:]

    func note(_ frames: [String: CGRect]) -> Color {
        self.frames = frames
        return Color.clear
    }
}

// MARK: - Pixels

/// An RGBA8 copy of a rendered window, top row first.
struct ReviewPixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ rep: NSBitmapImageRep) throws {
        let image = try #require(rep.cgImage)
        width = image.width
        height = image.height
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        let data = try #require(context.data)
        bytes = Array(
            UnsafeBufferPointer(
                start: data.assumingMemoryBound(to: UInt8.self),
                count: width * height * 4
            )
        )
    }

    /// Pixels that differ from `color` by more than rounding.
    func differing(from color: HSLA) -> Int {
        width * height
            - tally(color, 0..<width, 0..<height, tolerance: 2)
    }

    /// Pixels within `rect` (in points, top-left origin, at `scale` pixels
    /// to the point) that are `color`, give or take rounding.
    func count(
        _ color: HSLA,
        in rect: CGRect,
        scale: CGFloat,
        tolerance: Int = 6
    ) -> Int {
        let columns =
            max(Int(rect.minX * scale), 0)..<min(Int(rect.maxX * scale), width)
        let rows =
            max(Int(rect.minY * scale), 0)..<min(Int(rect.maxY * scale), height)
        return tally(color, columns, rows, tolerance: tolerance)
    }

    /// Pixels in a block within `tolerance` of `color` on every channel. A
    /// plain loop over the buffer: a window at two pixels to the point is
    /// five million of them, and the tests run unoptimized.
    private func tally(
        _ color: HSLA,
        _ columns: Range<Int>,
        _ rows: Range<Int>,
        tolerance: Int
    ) -> Int {
        guard !columns.isEmpty, !rows.isEmpty else {
            return 0
        }
        let want = channels(color)
        let (r, g, b) = (Int(want[0]), Int(want[1]), Int(want[2]))
        let stride = width * 4
        return bytes.withUnsafeBufferPointer { buffer in
            var found = 0
            for y in rows {
                var index = y * stride + columns.lowerBound * 4
                let end = y * stride + columns.upperBound * 4
                while index < end {
                    if abs(Int(buffer[index]) - r) <= tolerance,
                        abs(Int(buffer[index + 1]) - g) <= tolerance,
                        abs(Int(buffer[index + 2]) - b) <= tolerance
                    {
                        found += 1
                    }
                    index += 4
                }
            }
            return found
        }
    }

    private func channels(_ color: HSLA) -> [UInt8] {
        let rgb = color.toRGB()
        return [rgb.r, rgb.g, rgb.b].map { UInt8(($0 * 255).rounded()) }
    }
}

// MARK: - Looking at it

/// Write the rendering to `$DISKTREE_REVIEW_SNAPSHOTS/<name>.png` when that
/// variable names a directory, so the screens can be looked at; otherwise
/// nothing is written.
func keepReviewSnapshot(_ rep: NSBitmapImageRep, _ name: String) {
    guard
        let directory = ProcessInfo.processInfo
            .environment["DISKTREE_REVIEW_SNAPSHOTS"],
        !directory.isEmpty,
        let png = rep.representation(using: .png, properties: [:])
    else {
        return
    }
    let url = URL(filePath: directory).appending(path: "\(name).png")
    try? png.write(to: url)
}
