import AppKit
import CoreGraphics
import DisktreeCore
import SwiftUI
import Testing

@testable import DisktreeApp

// Every widget is drawn, in both presets, into real pixels: a widget that
// crashes while drawing, or draws nothing, fails here rather than on screen.
// The hatch, the rem scale, the corner radii and the symbol table are
// checked here too, as the widgets are built from them.

// MARK: - Pixels

/// An RGBA8 sRGB bitmap, top row first.
private struct Pixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    /// The pixel at column `x`, row `y` from the top.
    func rgba(_ x: Int, _ y: Int) -> [UInt8] {
        let start = (y * width + x) * 4
        return Array(bytes[start..<start + 4])
    }

    func painted(_ x: Int, _ y: Int) -> Bool {
        rgba(x, y)[3] > 0
    }

    /// Nearly covered. A diagonal edge leaves its pixels about half
    /// covered, on both sides of a stripe; only the stripe's core counts.
    func solid(_ x: Int, _ y: Int) -> Bool {
        rgba(x, y)[3] > 192
    }

    /// Pixels with any coverage at all.
    var paintedCount: Int {
        stride(from: 3, to: bytes.count, by: 4).count { bytes[$0] > 0 }
    }

    /// Pixels that differ from `ground` by more than rounding.
    func differing(from ground: [UInt8]) -> Int {
        stride(from: 0, to: bytes.count, by: 4).count { start in
            (0..<3).contains {
                abs(Int(bytes[start + $0]) - Int(ground[$0])) > 2
            }
        }
    }
}

private func bitmap(width: Int, height: Int) throws -> CGContext {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    return try #require(
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
}

/// A bitmap context's memory holds its top row first, whichever way its user
/// space runs.
private func pixels(of context: CGContext) throws -> Pixels {
    let data = try #require(context.data)
    let count = context.bytesPerRow * context.height
    let bytes = Array(
        UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: UInt8.self),
            count: count
        )
    )
    return Pixels(width: context.width, height: context.height, bytes: bytes)
}

private func pixels(of image: CGImage) throws -> Pixels {
    let context = try bitmap(width: image.width, height: image.height)
    context.draw(
        image,
        in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
    )
    return try pixels(of: context)
}

private func bytes(_ color: HSLA) -> [UInt8] {
    let rgb = color.toRGB()
    return [rgb.r, rgb.g, rgb.b].map { UInt8(($0 * 255).rounded()) }
}

// MARK: - The rem scale

@Test func theSpacingScaleIsTheGuidesPoints() {
    let scale = [
        Space.xxs, Space.xs, Space.sm, Space.md, Space.lg, Space.xl,
        Space.xxl,
    ]
    #expect(scale.map { $0.at(baseRem) } == [2, 4, 8, 12, 16, 24, 32])
}

@Test func tokensResolveAgainstAnyRem() {
    #expect(Space.md.at(20) == 15)
    #expect(20 * Space.md == 15)
    #expect((TextSize.figure - TextSize.title) * 0.5 == Rems(0.375))
    #expect(Space.xs + Space.xs == Space.sm)
    #expect(TextSize.caption < TextSize.body)
}

@Test func cornersAreConcentricAndFollowTheRem() {
    // A row `Space.xs` inside a card rounds with it: the card's radius
    // less the inset is the row's.
    #expect(Rounding.card - Space.xs == Rounding.control)
    #expect(Rounding.card.at(baseRem) == 12)
    #expect(Rounding.card.at(baseRem * 1.5) == 18)
    #expect(Rounding.swatch < Rounding.small)
    #expect(Rounding.small < Rounding.control)
    // A swatch rounds its corners without becoming a dot.
    #expect(Rounding.swatch.at(baseRem) * 2 < Size.swatch.at(baseRem))
}

@Test func everySymbolTheScreensNameIsASymbol() {
    // A name SF Symbols does not have draws nothing, silently.
    var names: [String] = []
    for category in DisktreeCore.Category.allCases {
        names.append(SymbolName.kind(category, isDir: true))
        names.append(SymbolName.kind(category, isDir: false))
    }
    for reclaim in Reclaim.allCases {
        names.append(SymbolName.reason(reclaim))
        names.append(SymbolName.finding(.reclaimable(reclaim)))
    }
    names.append(SymbolName.finding(.worktrees(count: 2, oldestDays: 3)))
    names.append(SymbolName.finding(.staleExperiments(count: 1)))
    for name in names {
        #expect(
            NSImage(systemSymbolName: name, accessibilityDescription: nil)
                != nil,
            "\(name)"
        )
    }
    // Each reason reads apart from the others at a glance.
    let reasons = Reclaim.allCases.map(SymbolName.reason)
    #expect(Set(reasons).count == reasons.count)
}

@Test func zoomStepsRiseThroughTheDefault() {
    #expect(zoomSteps[defaultZoomStep] == 1)
    #expect(zoomSteps == zoomSteps.sorted())
    #expect(Set(zoomSteps).count == zoomSteps.count)
}

// MARK: - The hatch

/// Shoelace area of a polygon.
private func area(_ polygon: [CGPoint]) -> CGFloat {
    var twice: CGFloat = 0
    for (index, point) in polygon.enumerated() {
        let next = polygon[(index + 1) % polygon.count]
        twice += point.x * next.y - next.x * point.y
    }
    return abs(twice) / 2
}

@Test func theHatchCoversItsShareOfTheArea() {
    let rect = CGRect(x: 13, y: 7, width: 300, height: 180)
    for hatch in [Hatch.tile, .dense, Hatch(width: 2.5, interval: 4)] {
        for (yDown, scale) in [(true, 1.0), (false, 1.0), (true, 2.0)] {
            let covered = hatch.stripes(in: rect, yDown: yDown, scale: scale)
                .map(area)
                .reduce(0, +)
            let share = covered / (rect.width * rect.height)
            let expected = hatch.width / hatch.period
            #expect(abs(share - expected) < 0.01, "\(hatch): \(share)")
        }
    }
}

@Test func theHatchIsMeasuredInDevicePixels() throws {
    // `pattern_slash` ran over device pixels: at two pixels to the point
    // the same hatch is half as many points wide and apart.
    let retina = Hatch.tile.stripes(
        in: CGRect(x: 0, y: 0, width: 20, height: 12),
        scale: 2
    )
    let plain = Hatch.tile.stripes(
        in: CGRect(x: 0, y: 0, width: 40, height: 24),
        scale: 1
    )
    #expect(!retina.isEmpty)
    try #require(retina.count == plain.count)
    for (small, large) in zip(retina, plain) {
        try #require(small.count == large.count)
        for (point, pixel) in zip(small, large) {
            #expect(abs(point.x * 2 - pixel.x) < 1e-9, "\(point) \(pixel)")
            #expect(abs(point.y * 2 - pixel.y) < 1e-9, "\(point) \(pixel)")
        }
    }
}

/// The distances from one stripe's core to the next along row `y`, in device
/// pixels: the hatch's period as the screen shows it. A core is a pixel
/// mostly covered in red and at least as red as its neighbours.
private func stripePeriods(_ pixels: Pixels, row y: Int) -> [Int] {
    let red = (0..<pixels.width).map { Int(pixels.rgba($0, y)[0]) }
    let cores = red.indices.filter { x in
        red[x] > 128
            && (x == 0 || red[x] >= red[x - 1])
            && (x == red.count - 1 || red[x] > red[x + 1])
    }
    return zip(cores.dropFirst(), cores).map { $0 - $1 }
}

@Test func theTileHatchHasTheScreenshotsPixelPeriod() throws {
    // assets/screenshot.png is a 2x capture (every border is two pixels),
    // and in it the tile hatch, `pattern_slash(hatch, 1.0, 6.0)`, puts a
    // one-pixel core every seven device pixels along a row. The pixels stay
    // the same at any backing scale; only the points they cover change.
    for scale in [1, 2, 3] as [CGFloat] {
        let side = Int(64 * scale)
        let context = try bitmap(width: side, height: side)
        context.scaleBy(x: scale, y: scale)
        Hatch.tile.fill(
            CGRect(x: 0, y: 0, width: 64, height: 64),
            color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
            in: context,
            yDown: false,
            scale: scale
        )
        let periods = stripePeriods(try pixels(of: context), row: side / 2)
        #expect(periods.count > 4, "scale \(scale)")
        #expect(periods.allSatisfy { $0 == 7 }, "scale \(scale): \(periods)")
    }
}

@Test func theHatchStaysInsideItsRect() {
    let rect = CGRect(x: -40, y: 25.5, width: 97.25, height: 31)
    let stripes = Hatch.tile.stripes(in: rect, scale: 2)
    #expect(!stripes.isEmpty)
    let slack = rect.insetBy(dx: -1e-9, dy: -1e-9)
    for point in stripes.joined() {
        #expect(slack.contains(point), "\(point)")
    }
}

@Test func aHatchOfNothingIsEmpty() {
    #expect(Hatch.tile.stripes(in: .zero, scale: 1).isEmpty)
    #expect(Hatch.tile.stripes(in: .null, scale: 1).isEmpty)
    #expect(Hatch.tile.stripes(in: .infinite, scale: 1).isEmpty)
    let square = CGRect(x: 0, y: 0, width: 10, height: 10)
    #expect(Hatch(width: 0, interval: 3).stripes(in: square, scale: 1).isEmpty)
    #expect(Hatch.tile.path(in: .zero, scale: 1).isEmpty)
    // A scale that is not a number of pixels draws nothing rather than a
    // runaway hatch.
    for scale in [0, -2, .nan, .infinity] as [CGFloat] {
        #expect(Hatch.tile.stripes(in: square, scale: scale).isEmpty)
    }
}

@Test func aStripeRunsThroughTheAnchor() {
    let rect = CGRect(x: 10, y: 10, width: 40, height: 40)
    let path = Hatch.tile.path(in: rect, scale: 1)
    // The anchor is the rect's corner: a stripe is centred on it, and the
    // middle of the gap after it is bare.
    #expect(path.contains(CGPoint(x: 10.2, y: 10.1)))
    #expect(!path.contains(CGPoint(x: 13.5, y: 10.1)))
    // An explicit anchor half a period along moves a stripe into that gap.
    let shifted = Hatch.tile.path(
        in: rect,
        anchor: CGPoint(x: 13.5, y: 10),
        scale: 1
    )
    #expect(shifted.contains(CGPoint(x: 13.4, y: 10.1)))
    #expect(!path.contains(CGPoint(x: 13.4, y: 10.1)))
}

/// How much more often a stripe's core continues up-right than down-right.
/// A slash at least a few pixels wide scores about three, a backslash about
/// a third, so two separates them at any backing scale.
private func slashBias(_ pixels: Pixels) -> Double {
    var rising = 0
    var falling = 0
    for y in 1..<pixels.height - 1 {
        for x in 0..<pixels.width - 1 where pixels.solid(x, y) {
            if pixels.solid(x + 1, y - 1) { rising += 1 }
            if pixels.solid(x + 1, y + 1) { falling += 1 }
        }
    }
    return Double(rising) / Double(max(falling, 1))
}

@Test func bitmapRowsRunFromTheTop() throws {
    // What the lean test below relies on: in an unflipped context, user
    // space y = 0 is the bottom row, and memory holds the top row first.
    let context = try bitmap(width: 8, height: 8)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 1))
    let pixels = try pixels(of: context)
    #expect(pixels.painted(0, 7))
    #expect(!pixels.painted(0, 0))
}

@Test func paintedStripesLeanLikeASlashInEitherSpace() throws {
    for flipped in [false, true] {
        let context = try bitmap(width: 64, height: 64)
        if flipped {
            // A flipped view's space: y runs down the screen.
            context.translateBy(x: 0, y: 64)
            context.scaleBy(x: 1, y: -1)
        }
        Hatch(width: 2, interval: 6).fill(
            CGRect(x: 0, y: 0, width: 64, height: 64),
            color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
            in: context,
            yDown: flipped,
            scale: 1
        )
        let pixels = try pixels(of: context)
        #expect(pixels.paintedCount > 0)
        #expect(slashBias(pixels) > 2, "flipped: \(flipped)")
    }
}

/// A view that hatches itself, as the mosaic does.
private final class HatchedView: NSView {
    private let runsDown: Bool
    /// Device pixels per point: the mosaic reads its window's
    /// `backingScaleFactor`; this view has no window, so the test says.
    var scale: CGFloat = 1

    init(flipped: Bool) {
        self.runsDown = flipped
        super.init(frame: NSRect(x: 0, y: 0, width: 48, height: 48))
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { runsDown }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        Hatch(width: 2, interval: 6).fill(
            bounds,
            color: CGColor(gray: 1, alpha: 1),
            in: context,
            yDown: isFlipped,
            scale: scale
        )
    }
}

@MainActor
@Test func aViewHatchesLikeASlashWhenItPassesItsFlip() throws {
    // The contract the mosaic relies on: `yDown` is the view's `isFlipped`,
    // in a flipped view and an unflipped one alike.
    _ = NSApplication.shared
    for flipped in [false, true] {
        let view = HatchedView(flipped: flipped)
        let rep = try #require(
            view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.scale = CGFloat(rep.pixelsWide) / view.bounds.width
        view.cacheDisplay(in: view.bounds, to: rep)
        let pixels = try pixels(of: try #require(rep.cgImage))
        #expect(pixels.paintedCount > 0)
        #expect(slashBias(pixels) > 2, "flipped: \(flipped)")
    }
}

@Test func paintedStripesStayInsideTheirRect() throws {
    let context = try bitmap(width: 64, height: 64)
    Hatch.dense.fill(
        CGRect(x: 16, y: 16, width: 32, height: 32),
        color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
        in: context,
        yDown: false,
        scale: 1
    )
    let pixels = try pixels(of: context)
    #expect(pixels.paintedCount > 0)
    for y in 0..<64 {
        for x in 0..<64 where pixels.painted(x, y) {
            #expect((16..<48).contains(x) && (16..<48).contains(y))
        }
    }
}

@Test func paintingOnlyStripesWhatTheClipShows() throws {
    // A tile zoomed far past the viewport: only the visible part is
    // striped, and the phase is still the whole tile's.
    let context = try bitmap(width: 32, height: 32)
    context.clip(to: CGRect(x: 0, y: 0, width: 32, height: 32))
    let huge = CGRect(x: -1e7, y: -1e7, width: 2e7, height: 2e7)
    Hatch.tile.fill(
        huge,
        color: CGColor(gray: 1, alpha: 1),
        in: context,
        yDown: false,
        scale: 1
    )
    let pixels = try pixels(of: context)
    let share = Double(pixels.paintedCount) / Double(32 * 32)
    #expect(share > 0.1 && share < 0.5, "\(share)")
}

// MARK: - Motion

@Test func aBarSegmentMovesBothEnds() {
    // A bar's new length is reached from its old one, both ends at once:
    // what SwiftUI interpolates is the pair.
    var segment = BarSegment(from: 0.2, to: 0.6)
    #expect(segment.animatableData == AnimatablePair(0.2, 0.6))
    segment.animatableData = AnimatablePair(0.1, 0.9)
    #expect(segment.from == 0.1 && segment.to == 0.9)
    // Halfway through a move, the path is where halfway says.
    segment.animatableData = AnimatablePair(0.15, 0.75)
    let rect = segment.path(in: CGRect(x: 0, y: 0, width: 100, height: 4))
        .boundingRect
    #expect(abs(rect.minX - 15) < 1e-9 && abs(rect.maxX - 75) < 1e-9)
}

@Test func aRoundedSegmentKeepsItsLengthAndRoundsItsEnds() {
    let rect = CGRect(x: 0, y: 0, width: 100, height: 6)
    let square = BarSegment(from: 0.2, to: 0.7).path(in: rect)
    let round = BarSegment(from: 0.2, to: 0.7, rounded: true).path(in: rect)
    // The same stretch of the track...
    #expect(abs(round.boundingRect.minX - 20) < 1e-9)
    #expect(abs(round.boundingRect.maxX - 70) < 1e-9)
    // ...with its corners taken off, and its middle whole.
    #expect(square.contains(CGPoint(x: 20.2, y: 0.2)))
    #expect(!round.contains(CGPoint(x: 20.2, y: 0.2)))
    #expect(round.contains(CGPoint(x: 45, y: 3)))
    // A sliver shorter than the bar is thick stays inside its own length.
    let sliver = BarSegment(from: 0.5, to: 0.52, rounded: true)
        .path(in: rect)
        .boundingRect
    #expect(sliver.minX >= 50 - 1e-9 && sliver.maxX <= 52 + 1e-9)
    // Nothing to draw is nothing, rounded or not.
    #expect(
        BarSegment(from: 0.4, to: 0.4, rounded: true).path(in: rect)
            .boundingRect.width == 0)
}

@Test func motionFadesWhenItIsReduced() {
    // With Reduce Motion, a move becomes the fade; without it, it stays.
    #expect(ChromeMotion.animation(reduced: true) == ChromeMotion.fade)
    #expect(ChromeMotion.animation(reduced: false) == ChromeMotion.move)
    #expect(
        ChromeMotion.animation(ChromeMotion.arrive, reduced: false)
            == ChromeMotion.arrive
    )
}

// MARK: - The widgets

/// One of every widget, as the screens use them.
@MainActor
private func gallery(_ theme: Theme) -> [(String, AnyView)] {
    let gib: UInt64 = 1 << 30
    let disk = SpaceInfo(
        total: 952 * gib, free: 116 * gib, available: 107 * gib)
    var widgets: [(String, AnyView)] = [
        ("stat", AnyView(Stat("files", "3.9M"))),
        (
            "statColored",
            AnyView(Stat("unreadable", "12", color: theme.caution))
        ),
        ("chip", AnyView(Chip("Marked", color: theme.danger))),
        (
            "chipSymbol",
            AnyView(
                Chip(
                    "Partly unreadable",
                    color: theme.caution,
                    systemImage: "exclamationmark.triangle.fill"
                )
            )
        ),
        (
            "meterRow",
            AnyView(
                MeterRow(
                    "Removed", "3 of 7", fraction: 0.4, color: theme.accent))
        ),
        // The scanning panel's meter has no label or value.
        (
            "meterRowBare",
            AnyView(MeterRow("", "", fraction: 0.2, color: theme.accent))
        ),
        ("spaceMeter", AnyView(SpaceMeter(disk, reclaiming: 94 * gib))),
        ("spaceMeterIdle", AnyView(SpaceMeter(disk, reclaiming: 0))),
        (
            "spaceMeterEmptyVolume",
            AnyView(
                SpaceMeter(
                    SpaceInfo(total: 0, free: 0, available: 0),
                    reclaiming: 1
                )
            )
        ),
        ("hint", AnyView(Hint("space", "mark"))),
        ("keycap", AnyView(Keycap("\u{232B}"))),
        ("section", AnyView(SectionHeading("Totals"))),
        (
            "sectionSymbol",
            AnyView(SectionHeading("Command", systemImage: "terminal"))
        ),
        ("row", AnyView(DefinitionRow("Marked", "12 items · 94 GiB"))),
        (
            "glyphBar",
            AnyView(GlyphBar(3, of: 10, width: 8, color: theme.secondary))
        ),
        ("crumbActive", AnyView(CrumbButton("tobi", active: true) {})),
        (
            "crumbAbove",
            AnyView(
                CrumbButton("home", active: false, color: theme.highlight) {}
            )
        ),
        ("eyebrow", AnyView(Eyebrow("Selection"))),
        (
            "eyebrowSymbol",
            AnyView(Eyebrow("Disk", systemImage: "internaldrive"))
        ),
        ("card", AnyView(Text("In a card").cardSurface())),
        ("figure", AnyView(Figure("Of scan", "100%", color: theme.bright))),
        (
            "measure",
            AnyView(
                Measure(
                    "881",
                    size: TextSize.display,
                    unit: "GiB",
                    unitSize: TextSize.title
                )
            )
        ),
        ("bar", AnyView(Bar(0.6, color: theme.highlight))),
        // What floats: plain, and lifted off busy content.
        (
            "floating",
            AnyView(
                Text("Copied ~/junk")
                    .padding(8)
                    .floatingSurface(theme.surface, border: theme.border)
            )
        ),
        (
            "floatingLifted",
            AnyView(
                Text("Siblings")
                    .padding(8)
                    .floatingSurface(
                        theme.surface,
                        border: theme.controlBorder,
                        lifted: true
                    )
            )
        ),
        (
            "floatingCapsule",
            AnyView(
                Text("Revealed in Finder")
                    .padding(8)
                    .floatingSurface(
                        theme.surface,
                        border: theme.border,
                        shape: .capsule
                    )
            )
        ),
        (
            "rolling",
            AnyView(
                Text("3.9M files")
                    .monospacedDigit()
                    .rollingDigits("3.9M files")
                    .rollingNumber(3_900_000)
            )
        ),
        // Out-of-range fractions clamp rather than paint past the track.
        ("barOverfull", AnyView(Bar(1.7, color: theme.highlight))),
        ("barNegative", AnyView(Bar(-0.3, color: theme.highlight))),
        ("swatch", AnyView(Swatch(theme.categoryAccent(.code)))),
        (
            "hatchSwatch",
            AnyView(
                HatchSwatch(
                    theme.bright.opacity(0.5),
                    ground: theme.categoryFill(.other, depth: 0)
                )
            )
        ),
    ]
    for name in IconName.allCases {
        widgets.append(
            (
                "icon.\(name)",
                AnyView(Icon(name, size: IconSize.lg, color: theme.accent))
            )
        )
    }
    return widgets
}

@MainActor
private func render(_ widget: AnyView, _ theme: Theme) throws -> Pixels {
    let renderer = ImageRenderer(
        content:
            widget
            .frame(width: 240, alignment: .leading)
            .environment(\.theme, theme)
            .environment(\.rem, baseRem)
    )
    renderer.scale = 2
    return try pixels(of: try #require(renderer.cgImage))
}

@MainActor
@Test func everyWidgetDrawsInBothPresets() throws {
    for theme in [Theme.dark, .light] {
        for (name, widget) in gallery(theme) {
            let pixels = try render(widget, theme)
            #expect(pixels.width > 0 && pixels.height > 0, "\(name)")
            #expect(pixels.paintedCount > 0, "\(name) drew nothing")
        }
    }
}

/// A widget alone at 2x on nothing, its pixels.
@MainActor
private func alone(_ widget: some View, theme: Theme) throws -> Pixels {
    let renderer = ImageRenderer(
        content:
            widget
            .environment(\.theme, theme)
            .environment(\.rem, baseRem)
    )
    renderer.scale = 2
    return try pixels(of: try #require(renderer.cgImage))
}

@MainActor
@Test func surfacesAndChipsAreRounded() throws {
    // The Omarchy squares are gone: a chip is a capsule, a card and what
    // floats are rounded rectangles. Each is drawn on nothing, so its
    // corner is bare where a square would have painted it, and its middle
    // is not.
    let theme = Theme.light
    let shapes: [(String, AnyView)] = [
        (
            "chip",
            AnyView(Chip("Goes with a directory", color: theme.danger))
        ),
        (
            "card",
            AnyView(
                Text("In a card")
                    .frame(width: 160, height: 60)
                    .cardSurface()
            )
        ),
        (
            "floating",
            AnyView(
                Text("A tooltip")
                    .frame(width: 160, height: 60)
                    .floatingSurface(theme.surface, border: theme.border)
            )
        ),
        (
            "toast",
            AnyView(
                Text("Copied")
                    .padding(8)
                    .floatingSurface(
                        theme.surface,
                        border: theme.border,
                        shape: .capsule
                    )
            )
        ),
        ("keycap", AnyView(Keycap("enter"))),
    ]
    for (name, shape) in shapes {
        let pixels = try alone(shape, theme: theme)
        #expect(!pixels.painted(0, 0), "\(name): a square corner")
        #expect(
            !pixels.painted(pixels.width - 1, pixels.height - 1),
            "\(name): a square corner"
        )
        #expect(
            pixels.painted(pixels.width / 2, pixels.height - 2),
            "\(name): no edge"
        )
    }
}

@MainActor
@Test func figuresAreSetInSFProRounded() throws {
    // The same number, rounded and not, is drawn differently: the face is
    // really the rounded one, not the system font under another name.
    let rounded = try alone(
        Text("2468").font(TextSize.display.rounded(baseRem, weight: .bold)),
        theme: .dark
    )
    let plain = try alone(
        Text("2468").font(TextSize.display.font(baseRem, weight: .bold)),
        theme: .dark
    )
    #expect(rounded.bytes != plain.bytes)
}

@MainActor
@Test func aFloatingSurfaceDrawsAsGlassToo() throws {
    // Glass is drawn by the window server, so offscreen it may come out as
    // nothing; the text on it must still draw, and nothing may crash.
    for theme in [Theme.dark, .light] {
        let renderer = ImageRenderer(
            content: Text("Copied ~/junk")
                .padding(8)
                .floatingSurface(theme.surface, border: theme.border)
                .environment(\.floatingGlass, true)
                .environment(\.theme, theme)
                .foregroundStyle(theme.bright.color)
        )
        let pixels = try pixels(of: try #require(renderer.cgImage))
        #expect(pixels.paintedCount > 0)
    }
}

@MainActor
@Test func widgetsFollowTheRem() throws {
    // The same widget at a larger interface zoom is larger: nothing is
    // measured in fixed points.
    let widget = AnyView(Hint("enter", "open").fixedSize())
    let sizes = try [baseRem, baseRem * 1.75].map { rem in
        let renderer = ImageRenderer(
            content: widget.environment(\.rem, rem)
        )
        let image = try #require(renderer.cgImage)
        return (image.width, image.height)
    }
    #expect(sizes[1].0 > sizes[0].0)
    #expect(sizes[1].1 > sizes[0].1)
}

@MainActor
@Test func aSwatchIsItsColour() throws {
    let theme = Theme.dark
    let color = theme.categoryAccent(.git)
    let pixels = try render(AnyView(Swatch(color)), theme)
    // The swatch sits at the leading edge, vertically centred.
    let centre = pixels.rgba(10, pixels.height / 2)
    for (got, want) in zip(centre, bytes(color)) {
        #expect(abs(Int(got) - Int(want)) <= 2, "\(centre)")
    }
}

/// The legend's hatch swatch at `rem`, red stripes on black so a core reads
/// in the red channel.
@MainActor
private func redOnBlack(rem: CGFloat) -> some View {
    HatchSwatch(HSLA(h: 0, s: 1, l: 0.5), ground: HSLA(h: 0, s: 0, l: 0))
        .environment(\.rem, rem)
}

@MainActor
@Test func theLegendHatchHasTheScreenshotsPixelPeriod() throws {
    // In the 2x screenshot the legend swatch, 0.625 rem, is 20 pixels
    // square, and its hatch, `pattern_slash(color, 1.0, 3.0)`, puts a core
    // every four device pixels: five stripes across. SwiftUI hands the
    // swatch its `displayScale`, which must turn into the same pixels.
    for scale in [1, 2, 3] as [CGFloat] {
        let renderer = ImageRenderer(
            content: redOnBlack(rem: baseRem)
        )
        renderer.scale = scale
        let image = try #require(renderer.cgImage)
        #expect(image.width == Int(10 * scale))
        let periods = stripePeriods(
            try pixels(of: image), row: image.height / 2)
        #expect(!periods.isEmpty, "scale \(scale)")
        #expect(periods.allSatisfy { $0 == 4 }, "scale \(scale): \(periods)")
    }
}

@MainActor
@Test func theLegendHatchKeepsItsPixelsInAWindow() throws {
    // The real AppKit path: the window's backing scale reaches the swatch
    // as `displayScale`, whatever the display this runs on.
    _ = NSApplication.shared
    let host = NSHostingView(
        rootView: redOnBlack(rem: baseRem * 4)
    )
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    host.layoutSubtreeIfNeeded()
    let rep = try #require(
        host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    let pixels = try pixels(of: try #require(rep.cgImage))
    let periods = stripePeriods(pixels, row: pixels.height / 2)
    #expect(periods.count > 4)
    #expect(periods.allSatisfy { $0 == 4 }, "\(periods)")
    closeWindow(window)
}

/// How large a circular spinner of `size` lays out, whatever it is offered.
@MainActor
private func spinnerSide(_ size: ControlSize) -> CGFloat {
    NSHostingView(
        rootView: ProgressView().progressViewStyle(.circular)
            .controlSize(size)
    )
    .fittingSize.width
}

@MainActor
@Test func theLoaderFitsItsIconSlotAtEveryZoom() throws {
    // The scanning panel shows the loader at `IconSize.lg`, 22 points at the
    // default rem. macOS lays its spinner out at a fixed size whatever its
    // frame, so one too large spills out of the slot over the text beside
    // it. The slot takes the largest that fits.
    _ = NSApplication.shared
    let sizes: [ControlSize] = [.mini, .small, .regular]
    let sides = sizes.map(spinnerSide)
    #expect(sides == sides.sorted() && sides.allSatisfy { $0 > 0 })
    for icon in [IconSize.sm, IconSize.md, IconSize.lg] {
        for step in zoomSteps {
            let slot = icon.at(baseRem * step)
            let chosen = Spinner.controlSize(fitting: slot)
            let spinner = NSHostingView(rootView: Spinner(fitting: slot))
                .fittingSize
            let index = try #require(sizes.firstIndex(of: chosen))
            #expect(spinner.width == sides[index], "slot \(slot)")
            // Nothing fits a slot under the mini spinner: it is the least.
            let room = max(slot, sides[0])
            #expect(
                spinner.width <= room && spinner.height <= room,
                "\(spinner) in a \(slot) slot"
            )
            // And the next size up would not have fitted.
            if index + 1 < sizes.count {
                #expect(sides[index + 1] > slot, "slot \(slot)")
            }
        }
    }
}

@MainActor
@Test func theWidgetsDrawInAnOffscreenWindow() throws {
    // The real AppKit path: a hosting view in a window, as the app hosts its
    // chrome. This one also draws what an image renderer cannot, such as the
    // spinner.
    _ = NSApplication.shared
    for theme in [Theme.dark, .light] {
        let widgets = gallery(theme)
        let content = VStack(alignment: .leading, spacing: 4) {
            ForEach(widgets.indices, id: \.self) { index in
                widgets[index].1
            }
        }
        .frame(width: 320, alignment: .leading)
        .padding(8)
        .background(theme.background.color)
        .environment(\.theme, theme)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 336, height: 1200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        #expect(host.bounds.width > 0 && host.bounds.height > 0)
        let rep = try #require(
            host.bitmapImageRepForCachingDisplay(in: host.bounds)
        )
        host.cacheDisplay(in: host.bounds, to: rep)
        let pixels = try pixels(of: try #require(rep.cgImage))
        // The ground is the theme's background; the widgets are what differs.
        #expect(pixels.differing(from: bytes(theme.background)) > 1000)
        closeWindow(window)
    }
}
