import AppKit
import Darwin
import DisktreeCore
import Foundation
import SwiftUI
import System
import Testing

@testable import DisktreeApp

// What the side panel's tests share: a real tree on disk that has something
// in every section, the state over a real scan of it, a way to draw the
// panel into pixels in an offscreen window, and a window that presents it
// as the app does, in a native inspector.
//
// Every name is inside `PanelHarness`, so nothing here can collide with
// another screen's test support.

enum PanelHarness {
    /// The appearances a Mac can be in; the panel must read in both.
    enum Look: String, CaseIterable, Sendable {
        case light
        case dark

        var name: NSAppearance.Name {
            switch self {
            case .light: .aqua
            case .dark: .darkAqua
            }
        }
    }

    /// Apparent sizes, so the numbers are about the tree and not about how
    /// the filesystem rounds a small file up to a block, and so the large
    /// files below can be sparse: they weigh what "worth a look" needs
    /// without taking the space.
    static let options = ScanOptions(apparentSize: true)

    /// A tree on disk, removed when the test is done with it.
    struct Fixture {
        let root: FilePath

        func path(_ relative: String) -> FilePath {
            root.appending(relative)
        }

        func remove() {
            try? FileManager.default.removeItem(atPath: root.string)
        }
    }

    private static let mebibyte = 1_024 * 1_024

    /// The Rust `fixture()` (two directories, a nested file, a hidden one
    /// holding the largest file), plus what the panel has sections for:
    /// findings large enough for "worth a look" (sparse, so they cost
    /// nothing), a checkout, and enough files to mark more than the panel
    /// lists.
    static func fixture() throws -> Fixture {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "disktree-panel-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        // `/var` is a symlink into `/private`: the scanned root is spelled
        // the way the kernel resolves it, as the app's own roots are.
        let root = try canonical(FilePath(url.path(percentEncoded: false)))
        let fixture = Fixture(root: root)
        let files: [(String, Int)] = [
            ("keep/notes.txt", 1_000),
            ("junk/blob.bin", 200_000),
            ("junk/deeper/more.bin", 100_000),
            (".cache/blob.bin", 300_000),
            ("app/package.json", 20),
            ("rust/Cargo.toml", 20),
            ("repo/README.md", 2_000),
            ("repo/.git/HEAD", 23),
        ]
        for (path, bytes) in files {
            try write(fixture.path(path), bytes: bytes)
        }
        let sparse: [(String, Int)] = [
            ("app/node_modules/pkg/index.bin", 150 * mebibyte),
            (".cache/models/weights.bin", 120 * mebibyte),
            ("rust/target/debug/app.bin", 80 * mebibyte),
            (".codex/worktrees/a/data.bin", 50 * mebibyte),
            (".codex/worktrees/b/data.bin", 40 * mebibyte),
            ("tries/2026-05-01-idea/data.bin", 70 * mebibyte),
        ]
        for (path, bytes) in sparse {
            try reserve(fixture.path(path), bytes: bytes)
        }
        for index in 0..<10 {
            try write(fixture.path("many/f\(index).bin"), bytes: 10_000)
        }
        // An experiment nobody has written to in three months, and
        // worktrees a few weeks old, so the findings have ages to report.
        let now = Date()
        try age(
            fixture.path("tries/2026-05-01-idea/data.bin"),
            to: now.addingTimeInterval(-90 * 86_400)
        )
        try age(
            fixture.path(".codex/worktrees/a/data.bin"),
            to: now.addingTimeInterval(-20 * 86_400)
        )
        return fixture
    }

    /// The state over a real scan of `fixture`, without the background walk
    /// or the tickers, as `AppState(root:tree:options:depth:)` builds it for
    /// every screen test.
    @MainActor
    static func state(_ fixture: Fixture) throws -> AppState {
        let tree = try scan(fixture.root, options: options)
        let state = AppState(
            root: fixture.root,
            tree: tree,
            options: options,
            depth: 3
        )
        // Tests never reach the pasteboard or Finder.
        state.copyToPasteboard = { _ in }
        state.showInFinder = { _ in }
        // "Worth a look" as a scan landing would fill it: the contract's
        // refresh may not have run.
        state.insights = worthALook(tree, now: nowSeconds(), limit: 6)
        return state
    }

    /// Crumbs from the scanned root to `relative`, walked by name
    /// (Invariant 7).
    static func crumbs(_ relative: String, in tree: Node) -> [Int]? {
        var node = tree
        var crumbs: [Int] = []
        for name in FilePath(relative).components.map(\.string) {
            guard
                let index = node.children.firstIndex(where: {
                    $0.name == name
                })
            else { return nil }
            crumbs.append(index)
            node = node.children[index]
        }
        return crumbs
    }

    /// The target the panel's mark button would make for `relative`.
    static func target(
        _ relative: String,
        in fixture: Fixture,
        tree: Node
    ) -> Target? {
        let path = fixture.path(relative)
        guard
            let node = findNode(rootPath: fixture.root, root: tree, path: path)
        else { return nil }
        return Target(
            path: path,
            bytes: node.bytes,
            isDir: node.isDir,
            hidden: isHidden(path)
        )
    }

    // MARK: Drawing

    /// A strip of the mosaic's ground left of the panel, where the window
    /// has it.
    static let ground: CGFloat = 120

    /// The panel beside a strip of mosaic, in the environment `RootView`
    /// gives it: the system theme for `look`, and the state's rem; and, with
    /// `reduceMotion`, the accessibility setting as a person may have it.
    ///
    /// The panel is as wide as the inspector would make it, the width kept
    /// in the state, on the window's ground: what the inspector's glass
    /// shows through on macOS 26, and the pane the panel lays itself
    /// before that. Its controls draw as in the window a person is using,
    /// the key window, where a prominent button wears its tint; an
    /// offscreen window is never key.
    @MainActor
    static func container(
        _ state: AppState,
        theme: Theme,
        reduceMotion: Bool = false
    ) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(theme.inset.color).frame(width: ground)
            SidePanel(state: state)
                .frame(width: state.panelRems * state.rem)
        }
        .background(theme.background.color)
        .environment(\.theme, theme)
        .environment(\.rem, state.rem)
        .environment(\._accessibilityReduceMotion, reduceMotion)
        .environment(\.controlActiveState, .key)
    }

    /// Draw the panel in an offscreen window `height` points tall, in
    /// `look`, through AppKit's own display path, and return the pixels.
    /// `name` saves a PNG when `DISKTREE_PANEL_SNAPSHOTS` names a directory,
    /// for a person to look at.
    @MainActor
    static func render(
        _ state: AppState,
        look: Look,
        height: CGFloat = 900,
        preset: Bool = false,
        reduceMotion: Bool = false,
        name: String? = nil
    ) throws -> Rendered {
        _ = NSApplication.shared
        let appearance = try #require(NSAppearance(named: look.name))
        let theme =
            preset
            ? (look == .dark ? Theme.dark : Theme.light)
            : Theme.system(appearance: appearance)
        let width = ground + state.panelRems * state.rem
        let host = NSHostingView(
            rootView: container(
                state,
                theme: theme,
                reduceMotion: reduceMotion
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let rep = try #require(
            host.bitmapImageRepForCachingDisplay(in: host.bounds)
        )
        host.cacheDisplay(in: host.bounds, to: rep)
        closeWindow(window)
        let image = try #require(rep.cgImage)
        if let name {
            save(
                image, as: "\(name)-\(look.rawValue)\(preset ? "-preset" : "")")
        }
        return try Rendered(image: image, points: width, theme: theme)
    }

    /// A drawn panel, reduced to what the tests ask of it: how much was
    /// drawn on the panel in each row of points.
    struct Rendered {
        let width: Int
        let height: Int
        /// Device pixels per point.
        let scale: Double
        /// The drawing itself, for the questions the row counts cannot
        /// answer: where a colour is.
        let image: CGImage
        /// For each row of device pixels, the sampled pixels inside the
        /// panel whose colour is not the pane it lies on.
        private let rows: [Int]

        init(image: CGImage, points: CGFloat, theme: Theme) throws {
            self.image = image
            width = image.width
            height = image.height
            scale = Double(image.width) / Double(points)
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
            let pixels = data.assumingMemoryBound(to: UInt8.self)
            let pane = theme.background.toRGB()
            let (red, green, blue) = (
                Int((pane.r * 255).rounded()),
                Int((pane.g * 255).rounded()),
                Int((pane.b * 255).rounded())
            )
            // Two points in from the panel's left edge.
            let left = Int((PanelHarness.ground + 2) * scale)
            var rows = [Int](repeating: 0, count: height)
            // Every other pixel of every row: a test build is unoptimised,
            // and a quarter of a window's pixels says the same thing.
            for y in 0..<height {
                var count = 0
                var x = left
                while x < width {
                    let at = (y * width + x) * 4
                    if abs(Int(pixels[at]) - red) > 8
                        || abs(Int(pixels[at + 1]) - green) > 8
                        || abs(Int(pixels[at + 2]) - blue) > 8
                    {
                        count += 1
                    }
                    x += 2
                }
                rows[y] = count
            }
            self.rows = rows
        }

        /// Sampled pixels drawn on the panel, in the band of points `rows`
        /// from the top, or in all of it.
        func drawn(rows band: ClosedRange<Double>? = nil) -> Int {
            let top = max(band.map { Int($0.lowerBound * scale) } ?? 0, 0)
            let bottom = min(
                band.map { Int($0.upperBound * scale) } ?? height,
                height
            )
            guard top < bottom else { return 0 }
            return rows[top..<bottom].reduce(0, +)
        }

        /// Sampled pixels on the panel within `tolerance` of `color`, in
        /// every channel, in the band of points `rows` from the top.
        func pixels(
            near color: HSLA,
            rows band: ClosedRange<Double>,
            tolerance: Int = 10
        ) throws -> Int {
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
            let pixels = data.assumingMemoryBound(to: UInt8.self)
            let rgb = color.toRGB()
            let want = [rgb.r, rgb.g, rgb.b].map { Int(($0 * 255).rounded()) }
            let left = Int((PanelHarness.ground + 2) * scale)
            let top = max(Int(band.lowerBound * scale), 0)
            let bottom = min(Int(band.upperBound * scale), height)
            var count = 0
            for y in stride(from: top, to: bottom, by: 2) {
                for x in stride(from: left, to: width, by: 2) {
                    let at = (y * width + x) * 4
                    if (0..<3).allSatisfy({
                        abs(Int(pixels[at + $0]) - want[$0]) <= tolerance
                    }) {
                        count += 1
                    }
                }
            }
            return count
        }

        /// The sampled counts row by row in a band, to compare two
        /// drawings of the same region.
        func profile(rows band: ClosedRange<Double>) -> [Int] {
            let top = max(Int(band.lowerBound * scale), 0)
            let bottom = min(Int(band.upperBound * scale), height)
            guard top < bottom else { return [] }
            return Array(rows[top..<bottom])
        }
    }

    // MARK: A window to use

    /// The panel beside a stand-in for the mosaic, in a window as wide as
    /// the app's default, laid out, as wide as the state keeps it.
    @MainActor
    static func window(
        _ state: AppState,
        width: CGFloat = 1_440,
        reduceMotion: Bool = false
    ) -> (NSWindow, NSView) {
        _ = NSApplication.shared
        let content = HStack(spacing: 0) {
            Rectangle().fill(Color.gray)
            SidePanel(state: state)
                .frame(width: state.panelRems * state.rem)
        }
        .frame(width: width, height: 900)
        .environment(\.theme, Theme.dark)
        .environment(\.rem, state.rem)
        .environment(\._accessibilityReduceMotion, reduceMotion)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        return (window, host)
    }

    /// The panel presented as the app presents it: a native inspector
    /// beside a stand-in for the mosaic, shown while the state says so, in
    /// a titled window `width` points wide. Returns the window, and the
    /// split view that holds the inspector's column.
    @MainActor
    static func inspector(
        _ state: AppState,
        width: CGFloat = 1_440
    ) throws -> (NSWindow, NSSplitView) {
        _ = NSApplication.shared
        let controller = NSHostingController(
            rootView: InspectorHost(state: state)
                .environment(\.theme, Theme.dark)
                .environment(\.rem, state.rem)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: width, height: 900))
        turn(for: .milliseconds(100))
        let split = try #require(
            views(NSSplitView.self, in: controller.view).first,
            "the inspector is a column of a split view"
        )
        return (window, split)
    }

    /// The inspector's column in `split`: the last of its panes.
    @MainActor
    static func column(of split: NSSplitView) throws -> NSView {
        try #require(split.arrangedSubviews.last)
    }

    /// Turn the run loop, in a loop of ours, until `condition` holds or
    /// `limit` has passed, laying `window` out on every turn: the pass that
    /// tells the panel its new width, and the timer that keeps it, both run
    /// here. Every wait is a loop of ours, never the runner's: a window
    /// server's answer that lands on the runner's loop would end the run.
    @MainActor
    static func eventually(
        in window: NSWindow,
        within limit: Duration = .seconds(5),
        _ condition: () -> Bool
    ) {
        let deadline = ContinuousClock.now + limit
        while !condition(), ContinuousClock.now < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            turn(for: .milliseconds(20))
        }
    }

    /// Let the run loop turn for `duration`, laying out what changed.
    @MainActor
    static func turn(for duration: Duration) {
        let seconds =
            Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Every view of `type` under `view`, in the order AppKit holds them.
    @MainActor
    static func views<Found: NSView>(
        _ type: Found.Type,
        in view: NSView
    ) -> [Found] {
        let here = (view as? Found).map { [$0] } ?? []
        return here + view.subviews.flatMap { views(type, in: $0) }
    }

    /// A mouse event at `point` in `window`'s coordinates.
    @MainActor
    static func mouse(
        _ type: NSEvent.EventType,
        at point: NSPoint,
        in window: NSWindow,
        clicks: Int = 1
    ) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: clicks,
                pressure: 1
            )
        )
    }

    // MARK: Files

    private static func write(_ path: FilePath, bytes: Int) throws {
        try FileManager.default.createDirectory(
            atPath: path.removingLastComponent().string,
            withIntermediateDirectories: true
        )
        try Data(repeating: UInt8(ascii: "x"), count: bytes)
            .write(to: URL(filePath: path.string))
    }

    /// A file `bytes` long that holds nothing: a hole the filesystem does
    /// not allocate, so it weighs its size only in apparent sizes.
    private static func reserve(_ path: FilePath, bytes: Int) throws {
        try write(path, bytes: 0)
        let handle = try FileHandle(forWritingTo: URL(filePath: path.string))
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
    }

    private static func age(_ path: FilePath, to date: Date) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: path.string
        )
    }

    private static func canonical(_ path: FilePath) throws -> FilePath {
        let resolved = try #require(realpath(path.string, nil))
        defer { free(resolved) }
        return FilePath(String(cString: resolved))
    }

    private static func save(_ image: CGImage, as name: String) {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["DISKTREE_PANEL_SNAPSHOTS"],
            !directory.isEmpty
        else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:])
        else { return }
        try? png.write(
            to: URL(filePath: directory).appending(path: "\(name).png")
        )
    }
}

/// The mosaic's stand-in with the panel as its inspector, presented while
/// the state's `showSelection` says so, as the window presents it.
private struct InspectorHost: View {
    @Bindable var state: AppState

    var body: some View {
        Rectangle()
            .fill(Color.gray)
            .inspector(isPresented: $state.showSelection) {
                SidePanel(state: state)
            }
    }
}
