import AppKit
import CoreGraphics
import DisktreeCore
import Foundation
import ImageIO
import System
import Testing
import UniformTypeIdentifiers

@testable import DisktreeApp

// What the treemap tests share: real trees on disk, mosaics laid out from
// them by the core's `layout()`, and bitmaps painted from those mosaics.
//
// The state's `prepare()` is what builds a mosaic in the app. These tests
// build their own, the same way, so the painting can be held to every
// decoration — marks, filters, age, a transition in flight — without a
// state machine deciding which of them to show.

// MARK: - Trees on disk

/// A temporary directory of files, removed by `remove()`.
struct TreemapFixture {
    let url: URL

    var root: FilePath { FilePath(url.path) }

    /// The Rust tests' tree: two directories, a nested file, and a hidden
    /// one. The hidden directory holds the largest file, which is both the
    /// common case in a home directory and the one the ranking has to get
    /// right.
    static let small: [(String, Int)] = [
        ("keep/notes.txt", 1_000),
        ("junk/blob.bin", 200_000),
        ("junk/deeper/more.bin", 100_000),
        (".cache/blob.bin", 300_000),
    ]

    /// A home directory in miniature, as the screenshot shows one: every
    /// kind of data, reclaimable build output and caches, deep nesting and
    /// a long tail of small files, so a frame holds many labels.
    static let home: [(String, Int)] =
        [
            ("src/app/Cargo.toml", 3_000),
            ("src/app/src/main.rs", 60_000),
            ("src/app/src/lib.rs", 45_000),
            ("src/app/target/debug/app", 260_000),
            ("src/app/target/debug/deps.bin", 140_000),
            ("src/app/target/release/app", 180_000),
            ("src/site/index.html", 30_000),
            ("src/site/node_modules/react/index.js", 120_000),
            ("src/site/node_modules/vite/dist.js", 90_000),
            (".cache/pip/wheels.bin", 380_000),
            (".cache/npm/_cacache/content.bin", 220_000),
            (".cache/thumbnails/large.bin", 60_000),
            ("Sync/Telemetry/26-August/02/log.bin", 210_000),
            ("Sync/Telemetry/26-August/03/log.bin", 150_000),
            ("Sync/Telemetry/26-September/log.bin", 120_000),
            ("Sync/.stversions/old.bin", 90_000),
            (".codex/worktrees/f4b5/walgit/blob.bin", 330_000),
            (".codex/sessions/session.jsonl", 40_000),
            ("Documents/collection/2026/IMSA_11.mov", 290_000),
            ("Documents/Übersicht 日本/notes.txt", 20_000),
            ("models/llama/weights.bin", 420_000),
            (".cargo/registry/cache/crates.bin", 170_000),
            (".cargo/bin/tool", 70_000),
            ("world/.git/objects/pack/pack.bin", 310_000),
            ("world/README.md", 5_000),
        ]
        + (0..<24).map { index in
            (String(format: "misc/file-%02d.dat", index), 4_000 * (index + 1))
        }

    static func make(_ files: [(String, Int)]) throws -> TreemapFixture {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "disktree-treemap-\(UUID().uuidString)")
        for (path, bytes) in files {
            let file = url.appending(path: path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(repeating: UInt8(ascii: "x"), count: bytes)
                .write(to: file)
        }
        return TreemapFixture(url: url)
    }

    /// Apparent sizes, so the tests are about the tree and not about how
    /// the filesystem rounds a small file up to a block.
    static let options = ScanOptions(apparentSize: true)

    func scan() throws -> Node {
        try DisktreeCore.scan(root, options: Self.options)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Frames

/// Everything `prepare()` reads to build one frame, set by the test.
struct TreemapFrame {
    var tree: Node
    /// The directory drawn, by crumbs from the scanned root.
    var crumbs: [Int] = []
    var size = CGSize(width: 960, height: 640)
    var rem: CGFloat = baseRem
    var depth = 3
    var metric: Metric = .bytes
    var view = ViewTransform.identity
    var colorMode = ColorMode.kind
    var now = nowSeconds()
    var matches: Matches?
    var filterApplied = false
    var marked: Set<[Int]> = []
    var unreadable: Set<[Int]> = []
    var selected: [Int]?
    var hovered: [Int]?
    var transition: LayoutTransition?
    var at = ContinuousClock.now

    init(tree: Node) {
        self.tree = tree
    }

    /// The layout options the state runs with: its header bands in rem.
    var options: LayoutOptions {
        LayoutOptions(
            maxDepth: depth,
            header: 1.375 * rem,
            headerInner: 1.125 * rem
        )
    }

    /// The tiles, laid out by the core, in base space.
    func tiles() -> [Tile] {
        guard let node = tree.resolve(crumbs) else { return [] }
        return layout(
            node,
            rootCrumbs: crumbs,
            area: Rect(
                x: 0,
                y: 0,
                w: size.width.rounded(),
                h: size.height.rounded()
            ),
            metric: metric,
            options: options,
            filter: filterApplied ? matches : nil
        )
    }

    /// The tile at `crumbs`, if it is drawn.
    func tile(_ crumbs: [Int]) -> Tile? {
        tiles().first { $0.crumbs == crumbs && !TreemapSupport.isOthers($0) }
    }

    /// A tile's rectangle this frame: mid-transition, on its way.
    func animated(_ rect: Rect) -> Rect {
        transition?.sample(rect, at: at).rect ?? rect
    }

    /// The frame, decorated as `prepare()` decorates it.
    func mosaic() -> Mosaic {
        var decorations: [TileDeco] = []
        var labels: [(order: Int, label: TileLabel)] = []
        for tile in tiles() {
            let crumbs = tile.crumbs
            let node =
                TreemapSupport.isOthers(tile) ? nil : tree.resolve(crumbs)
            let ageBucket: Int? =
                if colorMode == .age, let node, node.modified > 0 {
                    DisktreeApp.ageBucket(days: (now - node.modified) / 86_400)
                } else {
                    nil
                }
            let filtered: Filtered =
                switch matches.map({ $0.keep(crumbs) }) {
                case nil, .some(.some(.whole)): .shown
                case .some(.some(.partial)): .holds
                case .some(nil): .out
                }
            let isMarked = marked.contains(crumbs)
            let isCovered = crumbs.indices.dropFirst().contains {
                marked.contains(Array(crumbs.prefix($0)))
            }
            decorations.append(
                TileDeco(
                    rect: animated(tile.rect),
                    depth: tile.depth,
                    category: node?.category ?? .other,
                    ageBucket: ageBucket,
                    reclaimable: node?.reclaim != nil,
                    filtered: filtered,
                    unreadable: unreadable.contains(crumbs)
                        || node?.readError == true,
                    marked: isMarked,
                    covered: isCovered,
                    hovered: hovered == crumbs,
                    selected: selected == crumbs
                )
            )

            // Labels are chosen in screen space: zooming in makes room for
            // more of them.
            let screen = view.project(animated(tile.header ?? tile.rect))
            if screen.w < 3.375 * rem || screen.h < 0.9375 * rem {
                continue
            }
            let label: TileLabel
            if case .others(_, let count) = tile.kind {
                label = TileLabel(
                    text: "+\(count) more",
                    rect: animated(tile.rect),
                    header: nil,
                    depth: tile.depth,
                    dim: matches != nil,
                    marked: false,
                    sizeText: ""
                )
            } else if let node {
                label = TileLabel(
                    text: node.name,
                    rect: animated(tile.rect),
                    header: tile.header.map(animated),
                    depth: tile.depth,
                    dim: filtered == .out,
                    marked: isMarked || isCovered,
                    sizeText: shortValue(node, metric: metric)
                )
            } else {
                continue
            }
            labels.append((labels.count, label))
        }
        // Largest first, the layout's order breaking ties, then the most a
        // frame shapes.
        labels.sort { left, right in
            let (lhs, rhs) = (left.label.rect.area, right.label.rect.area)
            return lhs != rhs ? lhs > rhs : left.order < right.order
        }
        return Mosaic(
            tiles: decorations,
            labels: labels.prefix(150).map(\.label),
            view: view
        )
    }
}

// MARK: - Bitmaps

/// A mosaic painted into an sRGB bitmap.
struct PaintedMosaic {
    let context: CGContext
    let scale: CGFloat
    let bytes: [UInt8]

    var width: Int { context.width }
    var height: Int { context.height }

    /// The pixel covering treemap-local point `(x, y)`, as `[r, g, b, a]`.
    func rgba(_ x: CGFloat, _ y: CGFloat) -> [UInt8] {
        let column = min(max(Int((x * scale).rounded(.down)), 0), width - 1)
        let row = min(max(Int((y * scale).rounded(.down)), 0), height - 1)
        let start = row * context.bytesPerRow + column * 4
        return Array(bytes[start..<start + 4])
    }

    /// The colour at `(x, y)`, without alpha.
    func rgb(_ x: CGFloat, _ y: CGFloat) -> [UInt8] {
        Array(rgba(x, y).prefix(3))
    }

    /// Pixels whose colour is not `ground`, within rounding.
    func differing(from ground: [UInt8]) -> Int {
        count(where: { !within($0, ground, 2) })
    }

    /// Pixels within `tolerance` of `color` in every channel.
    func count(near color: [UInt8], by tolerance: Int = 2) -> Int {
        count(where: { within($0, color, tolerance) })
    }

    /// Pixels whose colour satisfies `test`, handed the first channel's
    /// offset. A plain loop: a frame at 2x is millions of pixels.
    private func count(where test: (Int) -> Bool) -> Int {
        var found = 0
        var start = 0
        while start < bytes.count {
            if test(start) {
                found += 1
            }
            start += 4
        }
        return found
    }

    private func within(
        _ start: Int, _ color: [UInt8], _ tolerance: Int
    )
        -> Bool
    {
        abs(Int(bytes[start]) - Int(color[0])) <= tolerance
            && abs(Int(bytes[start + 1]) - Int(color[1])) <= tolerance
            && abs(Int(bytes[start + 2]) - Int(color[2])) <= tolerance
    }

    /// Every pixel inside `rect`, in points, row by row: for comparing one
    /// region of two frames exactly.
    func pixels(in rect: CGRect) -> [[UInt8]] {
        var found: [[UInt8]] = []
        let step = 1 / scale
        var y = rect.minY
        while y < rect.maxY {
            var x = rect.minX
            while x < rect.maxX {
                found.append(rgb(x, y))
                x += step
            }
            y += step
        }
        return found
    }

    /// Distinct colours inside `rect`, in points.
    func colors(in rect: CGRect) -> Set<[UInt8]> {
        var found: Set<[UInt8]> = []
        let step = 1 / scale
        var y = rect.minY
        while y < rect.maxY {
            var x = rect.minX
            while x < rect.maxX {
                found.insert(rgb(x, y))
                x += step
            }
            y += step
        }
        return found
    }

    /// Every pixel is fully covered: the ground reaches every edge.
    var isOpaque: Bool {
        stride(from: 3, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 255 }
    }

    /// Write the bitmap as a PNG to `DISKTREE_RENDER_DIR`, when it is set,
    /// for looking at: nothing is written otherwise.
    func save(_ name: String) {
        guard
            let directory = ProcessInfo.processInfo
                .environment["DISKTREE_RENDER_DIR"],
            let image = context.makeImage()
        else { return }
        let url = URL(filePath: directory).appending(path: "\(name).png")
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

// MARK: - A state and a window

/// A state over `tree`, whose pasteboard and Finder hooks only record: a
/// test must never write to the real pasteboard or open Finder.
@MainActor
final class TreemapHarness {
    let state: AppState
    private(set) var copied: [String] = []
    private(set) var revealed: [[FilePath]] = []

    init(root: FilePath, tree: Node) {
        state = AppState(
            root: root,
            tree: tree,
            options: TreemapFixture.options,
            depth: 3
        )
        state.copyToPasteboard = { [weak self] text in
            self?.copied.append(text)
        }
        state.showInFinder = { [weak self] paths in
            self?.revealed.append(paths)
        }
    }
}

// MARK: - Helpers

/// The helpers, in one namespace so they never meet another suite's.
enum TreemapSupport {
    /// The crumbs of the child of `parent` named `name`.
    static func crumbs(
        _ tree: Node,
        _ parent: [Int],
        _ name: String
    ) throws -> [Int] {
        let node = try #require(tree.resolve(parent))
        let index = try #require(node.children.firstIndex { $0.name == name })
        return parent + [index]
    }

    /// The crumbs of a path of names below the scanned root.
    static func crumbs(_ tree: Node, path names: String...) throws -> [Int] {
        var found: [Int] = []
        for name in names {
            found = try crumbs(tree, found, name)
        }
        return found
    }

    /// Whether a tile is a directory's merged tail rather than a node.
    static func isOthers(_ tile: Tile) -> Bool {
        if case .others = tile.kind { true } else { false }
    }

    /// The tiles `mosaic` puts on a canvas of `size` points at `scale`, as
    /// the painter places them: where, how rounded, and which are leaves.
    static func placed(
        _ mosaic: Mosaic,
        theme: Theme,
        size: CGSize,
        scale: CGFloat
    ) -> [PlacedTile] {
        MosaicPainter(
            colors: MosaicColors(theme: theme),
            typesetter: MosaicTypesetter(rem: baseRem),
            scale: scale
        )
        .place(mosaic, bounds: CGRect(origin: .zero, size: size))
    }

    /// A canvas pixel's colour as a painted bitmap holds it.
    static func bytes(_ pixel: MosaicPixel) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: pixel >> 16),
            UInt8(truncatingIfNeeded: pixel >> 8),
            UInt8(truncatingIfNeeded: pixel),
        ]
    }

    /// What a tile's body shows `y` points down the canvas, as its fill and
    /// its cushion shade it: no hatch, strip, ring, lift or label.
    static func body(
        _ tile: PlacedTile,
        y: CGFloat,
        colors: MosaicColors,
        scale: CGFloat
    ) -> [UInt8] {
        let ink = colors.fill(tile.deco)
        guard MosaicPainter.isCushioned(tile) else {
            return bytes(ink.pixel)
        }
        let row = Int((y * scale).rounded(.down))
        return bytes(ink.ramp[MosaicPainter.rampStep(row: row, of: tile.box)])
    }

    /// Paint `mosaic` over `size` points at `scale` pixels to the point.
    static func paint(
        _ mosaic: Mosaic,
        theme: Theme,
        size: CGSize,
        scale: CGFloat = 1,
        rem: CGFloat = baseRem,
        effects: MosaicEffects = .settled
    ) throws -> PaintedMosaic {
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
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
        context.scaleBy(x: scale, y: scale)
        paintMosaic(
            mosaic,
            theme: theme,
            bounds: CGRect(origin: .zero, size: size),
            in: context,
            rem: rem,
            scale: scale,
            flipped: false,
            effects: effects
        )
        let data = try #require(context.data)
        let bytes = Array(
            UnsafeBufferPointer(
                start: data.assumingMemoryBound(to: UInt8.self),
                count: context.bytesPerRow * height
            )
        )
        return PaintedMosaic(context: context, scale: scale, bytes: bytes)
    }

    /// Paint a frame of `frame`.
    static func paint(
        _ frame: TreemapFrame,
        theme: Theme,
        scale: CGFloat = 1
    ) throws -> PaintedMosaic {
        try paint(
            frame.mosaic(),
            theme: theme,
            size: frame.size,
            scale: scale,
            rem: frame.rem
        )
    }

    /// A colour's sRGB bytes, as a painted pixel holds them.
    static func rgbBytes(_ color: HSLA) -> [UInt8] {
        let rgb = color.toRGB()
        return [rgb.r, rgb.g, rgb.b].map { UInt8(($0 * 255).rounded()) }
    }

    /// Two colours within rounding of each other.
    static func near(
        _ left: [UInt8], _ right: [UInt8], by tolerance: Int = 2
    ) -> Bool {
        left.count == right.count
            && zip(left, right).allSatisfy {
                abs(Int($0) - Int($1)) <= tolerance
            }
    }

    /// The themes a Mac shows: both presets, and the system's own in both
    /// appearances.
    @MainActor
    static func everyTheme() throws -> [(name: String, theme: Theme)] {
        let aqua = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        return [
            ("dark", .dark),
            ("light", .light),
            ("aqua", .system(appearance: aqua)),
            ("darkAqua", .system(appearance: dark)),
        ]
    }

    /// An offscreen window of `size` in `appearance`, holding `content`.
    @MainActor
    static func offscreenWindow(
        _ content: NSView,
        size: CGSize,
        appearance: NSAppearance.Name = .darkAqua
    ) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = content
        content.frame = NSRect(origin: .zero, size: size)
        content.layoutSubtreeIfNeeded()
        return window
    }

    /// `view` drawn the way AppKit draws it into a window, as an sRGB bitmap.
    @MainActor
    static func cached(_ view: NSView) throws -> PaintedMosaic {
        view.displayIfNeeded()
        let rep = try #require(
            view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = try #require(rep.cgImage)
        let scale = CGFloat(image.width) / max(view.bounds.width, 1)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil,
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
        let data = try #require(context.data)
        let bytes = Array(
            UnsafeBufferPointer(
                start: data.assumingMemoryBound(to: UInt8.self),
                count: context.bytesPerRow * image.height
            )
        )
        return PaintedMosaic(context: context, scale: scale, bytes: bytes)
    }

    /// The first view of type `T` in `view`'s subtree.
    @MainActor
    static func firstSubview<T: NSView>(of type: T.Type, in view: NSView) -> T?
    {
        if let match = view as? T {
            return match
        }
        for child in view.subviews {
            if let match = firstSubview(of: type, in: child) {
                return match
            }
        }
        return nil
    }
}
