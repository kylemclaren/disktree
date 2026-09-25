// What the explore chrome's tests share: the Rust fixture on disk, a real
// scan of it, and a window that hosts the real `RootView` offscreen and
// draws it into a bitmap.
//
// The window is built as the app builds its own: a full-size content view
// under a transparent title bar, and a hosting controller that hands the
// screen's toolbar and title to the window. So the toolbar is the window's
// real `NSToolbar`, its items report the identifiers they draw like any
// other view, and the frame drawn is the whole window, toolbar and buttons
// included. Nothing here writes to the pasteboard or talks to Finder: every
// state's hooks are replaced with recorders.

import AppKit
import DisktreeCore
import Foundation
import SwiftUI
import System
import Testing

@testable import DisktreeApp

/// A small tree on disk, as the Rust tests build it: two directories, a
/// nested file, and a hidden one. The hidden directory holds the largest
/// file, which is both the common case in a home directory and the one the
/// ranking has to get right. `extra` adds more files, for the long names.
final class ExploreFixture {
    let root: FilePath

    init(extra: [(String, Int)] = []) throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "disktree-explore-\(UUID().uuidString)")
        let files: [(String, Int)] =
            [
                ("keep/notes.txt", 1_000),
                ("junk/blob.bin", 200_000),
                ("junk/deeper/more.bin", 100_000),
                (".cache/blob.bin", 300_000),
            ] + extra
        for (path, bytes) in files {
            let file = base.appending(path: path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(repeating: UInt8(ascii: "x"), count: bytes)
                .write(to: file)
        }
        // The scanner canonicalises its root; the state is given the same
        // path, so a path it builds matches one the scan reports.
        guard let real = realpath(base.path, nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        defer { free(real) }
        root = FilePath(String(cString: real))
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root.string)
    }
}

/// Apparent sizes, so what is drawn is about the tree and not about how the
/// filesystem rounds a small file up to a block.
func exploreOptions() -> ScanOptions {
    ScanOptions(apparentSize: true)
}

/// A state over a real scan of the fixture, without the background walk,
/// its hooks replaced so nothing reaches the pasteboard or Finder.
@MainActor
func exploreState(_ fixture: ExploreFixture) throws -> AppState {
    let tree = try scan(fixture.root, options: exploreOptions())
    let state = AppState(
        root: fixture.root,
        tree: tree,
        options: exploreOptions(),
        depth: 3
    )
    quiet(state)
    return state
}

/// A state whose first walk has not landed: what the window shows at launch.
@MainActor
func scanningState(_ fixture: ExploreFixture) -> AppState {
    let state = AppState(
        root: fixture.root,
        options: exploreOptions(),
        depth: 3,
        startScanning: false
    )
    quiet(state)
    return state
}

@MainActor
private func quiet(_ state: AppState) {
    state.copyToPasteboard = { _ in }
    state.showInFinder = { _ in }
    state.onQuit = {}
}

/// Collects the chrome identifiers the drawn views reported.
@MainActor
final class DrawnIdentifiers {
    var all: Set<String> = []
}

/// One frame of the real root view in an offscreen window.
@MainActor
struct ExploreFrame {
    let identifiers: Set<String>
    let image: CGImage
    let size: CGSize

    /// Pixels that differ from the window's background by more than
    /// rounding: what the chrome actually drew.
    let drawn: Int
    /// Distinct colours, coarsely: a frame of one or two colours drew
    /// nothing worth the name.
    let colours: Int
}

/// Draw `state` in a `width` × `height` window of `appearance`, with the
/// system theme or a fixed one, as the app's window hosts it: toolbar,
/// title and all. `glass` forces Liquid Glass on or off for what floats
/// (the window is never on screen, so it is off otherwise), and
/// `reduceMotion` draws it as it is drawn with Reduce Motion on.
@MainActor
func drawExplore(
    _ state: AppState,
    appearance: NSAppearance.Name,
    theme: Theme? = nil,
    width: CGFloat = 1440,
    height: CGFloat = 900,
    glass: Bool? = nil,
    reduceMotion: Bool = false,
    name: String
) throws -> ExploreFrame {
    _ = NSApplication.shared
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height),
        styleMask: [
            .titled, .closable, .miniaturizable, .resizable,
            .fullSizeContentView,
        ],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.titlebarAppearsTransparent = true
    window.toolbarStyle = .unified
    window.appearance = NSAppearance(named: appearance)
    let drawn = DrawnIdentifiers()
    let host = NSHostingController(
        rootView: RootView(state: state, theme: theme, glass: glass)
            .environment(\._accessibilityReduceMotion, reduceMotion)
            // As `WindowContent` tells the app's screens.
            .environment(\.bridgesToolbar, true)
            .onPreferenceChange(ChromeIdentifiers.self) { identifiers in
                MainActor.assumeIsolated {
                    drawn.all = Set(identifiers)
                }
            }
    )
    // As `RootView.hostingController` builds the app's.
    host.sceneBridgingOptions = [.toolbars, .title]
    host.sizingOptions = []
    host.view.frame = NSRect(x: 0, y: 0, width: width, height: height)
    window.contentViewController = host
    window.setContentSize(NSSize(width: width, height: height))
    let frame = try #require(window.contentView?.superview)
    frame.layoutSubtreeIfNeeded()
    frame.displayIfNeeded()
    // A few turns of the run loop let SwiftUI deliver what the first pass
    // scheduled (preferences, geometry the layout read back) and hand the
    // toolbar's items to the window, which lays them out on a turn of its
    // own.
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    frame.layoutSubtreeIfNeeded()
    let rep = try #require(
        frame.bitmapImageRepForCachingDisplay(in: frame.bounds)
    )
    frame.cacheDisplay(in: frame.bounds, to: rep)
    let image = try #require(rep.cgImage)
    let size = host.view.bounds.size
    closeWindow(window)
    let (count, colours) = try measure(image)
    try save(image, name: name)
    return ExploreFrame(
        identifiers: drawn.all,
        image: image,
        size: size,
        drawn: count,
        colours: colours
    )
}

/// Draw any `view` alone, in a window of `appearance` with `theme` in its
/// environment, at its own size (no wider than `width`): for what the
/// window shows only in a sheet or a popover, which offscreen windows never
/// present.
@MainActor
func drawAlone(
    _ view: some View,
    appearance: NSAppearance.Name,
    theme: Theme,
    width: CGFloat = 640,
    name: String
) throws -> ExploreFrame {
    _ = NSApplication.shared
    let drawn = DrawnIdentifiers()
    let host = NSHostingView(
        rootView:
            view
            .environment(\.theme, theme)
            .environment(\.rem, baseRem)
            .background(theme.background.color)
            .onPreferenceChange(ChromeIdentifiers.self) { identifiers in
                MainActor.assumeIsolated {
                    drawn.all = Set(identifiers)
                }
            }
    )
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: appearance)
    window.contentView = host
    let fitting = host.fittingSize
    host.frame = NSRect(
        x: 0,
        y: 0,
        width: min(max(fitting.width, 1), width),
        height: max(fitting.height, 1)
    )
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    host.layoutSubtreeIfNeeded()
    let rep = try #require(
        host.bitmapImageRepForCachingDisplay(in: host.bounds)
    )
    host.cacheDisplay(in: host.bounds, to: rep)
    let image = try #require(rep.cgImage)
    closeWindow(window)
    let (count, colours) = try measure(image)
    try save(image, name: name)
    return ExploreFrame(
        identifiers: drawn.all,
        image: image,
        size: host.bounds.size,
        drawn: count,
        colours: colours
    )
}

/// Sampled pixels unlike the top-left corner's (outside the window's
/// rounded corner, where nothing is drawn), and the distinct colours at six
/// bits a channel.
private func measure(_ image: CGImage) throws -> (Int, Int) {
    let width = image.width
    let height = image.height
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
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let data = try #require(context.data)
    let bytes = data.assumingMemoryBound(to: UInt8.self)
    let ground = (bytes[0], bytes[1], bytes[2])
    var differing = 0
    var colours = Set<UInt32>()
    // Every third pixel each way is plenty to tell a drawn frame from an
    // empty one, and a ninth of the work at 2x.
    for y in stride(from: 0, to: height, by: 3) {
        for x in stride(from: 0, to: width, by: 3) {
            let pixel = (y * width + x) * 4
            let (r, g, b) = (bytes[pixel], bytes[pixel + 1], bytes[pixel + 2])
            if abs(Int(r) - Int(ground.0)) > 2
                || abs(Int(g) - Int(ground.1)) > 2
                || abs(Int(b) - Int(ground.2)) > 2
            {
                differing += 1
            }
            colours.insert(
                UInt32(r >> 2) << 12 | UInt32(g >> 2) << 6 | UInt32(b >> 2)
            )
        }
    }
    return (differing, colours.count)
}

/// Keep the frame as a PNG when `DISKTREE_EXPLORE_PNGS` names a directory,
/// to look at what the tests drew.
private func save(_ image: CGImage, name: String) throws {
    guard
        let directory = ProcessInfo.processInfo
            .environment["DISKTREE_EXPLORE_PNGS"]
    else {
        return
    }
    let rep = NSBitmapImageRep(cgImage: image)
    let png = try #require(rep.representation(using: .png, properties: [:]))
    try png.write(to: URL(filePath: directory).appending(path: "\(name).png"))
}

// MARK: - Motion

/// A view kept in an offscreen window, so a test can change what it shows
/// and draw it again while a change is still animating.
///
/// Unlike `RootView`, which lands every change at once in a window nobody
/// sees, a screen hosted alone animates here as it does on screen.
@MainActor
final class LiveWindow {
    private let window: NSWindow
    private let host: NSView

    init(_ view: some View, width: CGFloat, height: CGFloat) {
        _ = NSApplication.shared
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingView(rootView: view)
        hosting.safeAreaRegions = []
        host = hosting
        window.contentView = hosting
        window.setContentSize(NSSize(width: width, height: height))
        run(for: .milliseconds(100))
    }

    /// Let the run loop turn for `duration`: what was changed is laid out,
    /// and whatever it animates moves on.
    func run(for duration: Duration) {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let seconds =
            Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        host.layoutSubtreeIfNeeded()
    }

    /// What the window shows now, mid-animation or not.
    func draw() throws -> CGImage {
        let rep = try #require(
            host.bitmapImageRepForCachingDisplay(in: host.bounds)
        )
        host.cacheDisplay(in: host.bounds, to: rep)
        return try #require(rep.cgImage)
    }

    func close() {
        closeWindow(window)
    }
}

/// Pixels in `rect` (in points, from the top left) that differ between two
/// frames of the same window by more than rounding, every other pixel each
/// way.
func differingPixels(
    _ first: CGImage,
    _ second: CGImage,
    in rect: CGRect,
    points: CGFloat
) throws -> Int {
    let scale = CGFloat(first.width) / points
    let one = try rgba(first)
    let other = try rgba(second)
    let width = first.width
    let columns = Int(rect.minX * scale)..<min(Int(rect.maxX * scale), width)
    let rows =
        Int(rect.minY * scale)..<min(Int(rect.maxY * scale), first.height)
    var count = 0
    for y in stride(from: rows.lowerBound, to: rows.upperBound, by: 2) {
        for x in stride(
            from: columns.lowerBound,
            to: columns.upperBound,
            by: 2
        ) {
            let pixel = (y * width + x) * 4
            for channel in 0..<3
            where abs(Int(one[pixel + channel]) - Int(other[pixel + channel]))
                > 4
            {
                count += 1
                break
            }
        }
    }
    return count
}

/// A frame's pixels as bytes, four to a pixel, rows from the top.
private func rgba(_ image: CGImage) throws -> [UInt8] {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    try bytes.withUnsafeMutableBytes { buffer in
        let context = try #require(
            CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
    }
    return bytes
}

/// A view's ideal size, alone, with the chrome's environment: what a
/// `ViewThatFits` measures it by.
@MainActor
func idealSize(_ view: some View, rem: CGFloat) -> CGSize {
    NSHostingView(
        rootView:
            view
            .environment(\.theme, Theme.dark)
            .environment(\.rem, rem)
    )
    .fittingSize
}
