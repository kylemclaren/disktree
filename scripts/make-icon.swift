// disktree's app icon, drawn from the mark in assets/disktree.svg.
//
//   swift scripts/make-icon.swift      # or `make icon`
//
// (No #! line: swift format folds the comment after one into it.)
//
// The mark is a treemap with the band a directory keeps for its name, in the
// app's palette (MP300): a body that rises from Indigo Blue into a violet and
// a periwinkle glow, as the upper half of the palette's dark card does; the
// scanned root a Midnight well under a Pear Spritz name band; in it an Indigo
// directory with a Sweet Escape band, a deep turquoise one with a Fresh
// Turquoise band, and a Pear Spritz file. The body starts at Indigo rather
// than Midnight so the icon keeps its outline on a dark Dock. This draws the
// same rectangles on the macOS icon grid — a 1024 px canvas whose body is an
// 824 px square with continuous corners — so the Dock and Finder show it at
// the size and in the shape of every other app icon.
//
// A rounded body cannot keep square corners at the SVG's margins: the curve
// would all but touch them. So corners that face the body's corners are
// concentric with it — each keeps its distance from the curve around it, as
// the straight edges keep theirs — and the corners between tiles get a slight
// rounding so the tiles read as one family.
//
// Every iconset size is drawn at its own pixel size rather than scaled down
// from 1024, with every edge on a whole pixel and no gap or band thinner
// than one, so the 16 px icon is still four tiles and not a smudge: a lime
// bar over an indigo and a turquoise block and a lime square, each on the
// dark well, which is why every colour next to another is far from it in
// lightness or hue. Then `iconutil` packs them into assets/disktree.icns;
// assets/AppIcon.png is the 1024 px preview. Both are committed: a build only
// copies the .icns.

import CoreGraphics
import Foundation
import ImageIO

/// Stops the script with a message, as a failed build step would.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

/// The mark's colours, exactly as the SVG has them, and as `LogoInk.icon`
/// in the app draws the logo: five of the palette's colours, two stops of
/// its dark gradient, and Fresh Turquoise sunk for a directory's body under
/// its band.
enum Ink {
    static let midnight = rgb(0x020035)
    static let indigo = rgb(0x3a18b1)
    static let sweetEscape = rgb(0x8844ff)
    static let turquoise = rgb(0x40e0d0)
    static let pear = rgb(0xcbf85f)

    /// The body's gradient, top to bottom: the upper half of the palette's
    /// dark card, from Indigo Blue into its softened violet and a
    /// periwinkle glow.
    static let ground = [indigo, rgb(0x6137d9), rgb(0x6873e7)]
    static let groundStops: [CGFloat] = [0, 0.75, 1]
    static let panel = midnight
    static let rootBand = pear
    static let directory = indigo
    static let directoryBand = sweetEscape
    /// Fresh Turquoise's hue at a quarter lightness: a directory body dark
    /// enough that its band, and the lime file under it, stand off it, and
    /// still turquoise rather than the steel blue a mix toward Midnight
    /// gave.
    static let column = rgb(0x107066)
    static let columnBand = turquoise
    static let file = pear

    static func rgb(_ hex: UInt32) -> CGColor {
        CGColor(
            srgbRed: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            alpha: 1
        )
    }
}

/// One run along an axis of the mark, in the SVG's 64 units.
enum Segment {
    /// A margin, gap or name band: rounded on its own, never under a pixel.
    case thin(Double)
    /// A tile: shares what the thin runs leave, in proportion.
    case tile(Double)
}

/// The SVG's rectangles as runs along each axis. Across: the ground, the
/// panel's margin, the large directory, a gap, the right-hand column, the
/// margin, the ground. Down the left: the ground, the root's name band, a
/// gap, the large directory, the margin, the ground; down the right the same,
/// with the column split into the small directory and the file.
enum Mark {
    static let across: [Segment] = [
        .thin(5), .thin(3), .tile(30), .thin(3), .tile(15), .thin(3), .thin(5),
    ]
    static let downLeft: [Segment] = [
        .thin(5), .thin(9), .thin(3), .tile(39), .thin(3), .thin(5),
    ]
    static let downRight: [Segment] = [
        .thin(5), .thin(9), .thin(3), .tile(24), .thin(3), .tile(12),
        .thin(3), .thin(5),
    ]
    static let directoryBand = 7.0
    static let columnBand = 6.0

    /// Apple's icon body has a 185.4 px corner on 824 px: 22.5 % of the side.
    static let bodyCorner = 0.225
    /// Between tiles, where nothing curves around them: enough to soften the
    /// corner at 1024 px, too little to notice at 16. In SVG units.
    static let innerCorner = 0.8
}

/// Where each run starts and ends, in whole pixels: `edges[i]` to
/// `edges[i + 1]` is segment `i`. Thin runs round to their share of `length`
/// but keep at least a pixel, so no gap closes and no band vanishes at 16 px;
/// tiles share the rest in proportion, largest remainder first.
func edges(_ segments: [Segment], from start: Int, length: Int) -> [Int] {
    let unit = Double(length) / 64
    var sizes = segments.map { segment in
        switch segment {
        case .thin(let units): max(1, Int((units * unit).rounded()))
        case .tile: 0
        }
    }
    let tiles = segments.indices.compactMap { index -> (Int, Double)? in
        if case .tile(let units) = segments[index] {
            (index, units)
        } else {
            nil
        }
    }
    let left = length - sizes.reduce(0, +)
    let weight = tiles.reduce(0) { $0 + $1.1 }
    let shares = tiles.map { index, units in
        (index, Double(left) * units / weight)
    }
    for (index, share) in shares {
        sizes[index] = Int(share.rounded(.down))
    }
    // Rounding every share down leaves fewer spare pixels than tiles. Ties
    // go to the earlier run, so the result never depends on how the sort
    // orders equals.
    let spare = max(0, length - sizes.reduce(0, +))
    let byRemainder = shares.sorted { a, b in
        let (ra, rb) = (a.1 - a.1.rounded(.down), b.1 - b.1.rounded(.down))
        return ra != rb ? ra > rb : a.0 < b.0
    }
    for (index, _) in byRemainder.prefix(spare) {
        sizes[index] += 1
    }
    return sizes.reduce(into: [start]) { edges, size in
        edges.append((edges.last ?? start) + size)
    }
}

/// Corner radii in pixels, clockwise from the top left.
struct Corners {
    var topLeft: Double
    var topRight: Double
    var bottomRight: Double
    var bottomLeft: Double

    static func all(_ radius: Double) -> Corners {
        Corners(
            topLeft: radius,
            topRight: radius,
            bottomRight: radius,
            bottomLeft: radius
        )
    }
}

/// One corner of a continuous ("squircle") rounded rectangle, as the points
/// its three curves pass through, in multiples of the radius: how far back
/// along the edge coming in, and how far along the edge going out. Its
/// curvature ramps up from the straight edge instead of jumping to a circle's,
/// which is the shape macOS gives its icons; it reaches 1.528 radii along
/// each edge. The corner is symmetric, so the second half mirrors the first.
let halfCorner: [(Double, Double)] = [
    (1.528_664_83, 0),
    (1.088_493_23, 0),
    (0.868_406_89, 0),
    (0.669_934_27, 0.065_496_00),
    (0.372_823_92, 0.191_492_39),
]
let cornerCurve =
    halfCorner + halfCorner.reversed().map { along, across in (across, along) }
let cornerReach = halfCorner[0].0

/// A continuous rounded rectangle with its own radius at each corner, in
/// y-down pixels. Radii shrink together when two corners would overlap along
/// an edge, as they do on the smallest tiles at 16 px.
func roundedPath(_ rect: CGRect, _ corners: Corners) -> CGPath {
    let (minX, minY, maxX, maxY) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
    let c = corners
    let fit =
        [
            rect.width / (c.topLeft + c.topRight),
            rect.height / (c.topRight + c.bottomRight),
            rect.width / (c.bottomRight + c.bottomLeft),
            rect.height / (c.bottomLeft + c.topLeft),
        ].map { $0 / cornerReach }.filter(\.isFinite).min() ?? 1
    let shrink = min(1, fit)
    // Clockwise on screen: each corner is its point, the direction of the
    // edge arriving at it and of the edge leaving it, and its radius.
    let walk: [(CGPoint, CGVector, CGVector, Double)] = [
        (
            CGPoint(x: maxX, y: minY), CGVector(dx: 1, dy: 0),
            CGVector(dx: 0, dy: 1), c.topRight
        ),
        (
            CGPoint(x: maxX, y: maxY), CGVector(dx: 0, dy: 1),
            CGVector(dx: -1, dy: 0), c.bottomRight
        ),
        (
            CGPoint(x: minX, y: maxY), CGVector(dx: -1, dy: 0),
            CGVector(dx: 0, dy: -1), c.bottomLeft
        ),
        (
            CGPoint(x: minX, y: minY), CGVector(dx: 0, dy: -1),
            CGVector(dx: 1, dy: 0), c.topLeft
        ),
    ]
    let path = CGMutablePath()
    path.move(to: CGPoint(x: minX + cornerReach * c.topLeft * shrink, y: minY))
    for (corner, arriving, leaving, radius) in walk {
        let r = radius * shrink
        let points = cornerCurve.map { back, on in
            CGPoint(
                x: corner.x - arriving.dx * back * r + leaving.dx * on * r,
                y: corner.y - arriving.dy * back * r + leaving.dy * on * r
            )
        }
        path.addLine(to: points[0])
        for curve in stride(from: 1, to: points.count, by: 3) {
            path.addCurve(
                to: points[curve + 2],
                control1: points[curve],
                control2: points[curve + 1]
            )
        }
    }
    path.closeSubpath()
    return path
}

/// Fills a directory: its colour, then its name band clipped to its corners.
func fillDirectory(
    _ context: CGContext,
    _ rect: CGRect,
    corners: Corners,
    fill: CGColor,
    band: Double,
    bandFill: CGColor
) {
    let shape = roundedPath(rect, corners)
    context.saveGState()
    context.addPath(shape)
    context.setFillColor(fill)
    context.fillPath()
    context.addPath(shape)
    context.clip()
    context.setFillColor(bandFill)
    context.fill(
        CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: band)
    )
    context.restoreGState()
}

func rect(_ x: [Int], _ i: Int, _ y: [Int], _ j: Int) -> CGRect {
    CGRect(x: x[i], y: y[j], width: x[i + 1] - x[i], height: y[j + 1] - y[j])
}

/// The icon at one pixel size, on a transparent square canvas.
func render(pixels: Int) -> CGImage {
    guard
        let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { fail("cannot make a \(pixels) px bitmap") }
    // Pixels, y down, as the SVG and the runs above are written.
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: 1, y: -1)

    // Apple's grid: the body is 824 of 1024 px, centred, which leaves the
    // shadow its room and lines the icon up with every other in the Dock.
    // Rounded down to whole pixels on each side, and at least one: at 16 px
    // that is a 14 px body, where the grid's 12.9 would sit on half pixels.
    let scale = Double(pixels) / 1024
    let margin = max(1, Int((100 * scale).rounded(.down)))
    let body = pixels - 2 * margin
    let x = edges(Mark.across, from: margin, length: body)
    let left = edges(Mark.downLeft, from: margin, length: body)
    let right = edges(Mark.downRight, from: margin, length: body)
    let unit = Double(body) / 64

    // Concentric corners: each is the one around it less the distance
    // between them, so the space between two curves is as wide as between
    // their straight edges.
    let bodyCorner = Mark.bodyCorner * Double(body)
    let panelCorner = bodyCorner - Double(x[1] - x[0])
    let tileCorner = panelCorner - Double(x[2] - x[1])
    let inner = Mark.innerCorner * unit

    // The template's drop shadow, kept faint. Shadow offsets are in device
    // space whatever the transform, so "down" is a negative height here.
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -10 * scale),
        blur: 20 * scale,
        color: CGColor(gray: 0, alpha: 0.3)
    )
    let bodyRect = CGRect(x: margin, y: margin, width: body, height: body)
    context.addPath(roundedPath(bodyRect, .all(bodyCorner)))
    // The shadow needs a fill to fall from; the gradient is drawn over it.
    context.setFillColor(Ink.midnight)
    context.fillPath()
    context.restoreGState()
    guard
        let gradient = CGGradient(
            colorsSpace: space,
            colors: Ink.ground as CFArray,
            locations: Ink.groundStops
        )
    else { fail("cannot make the body's gradient") }
    context.saveGState()
    context.addPath(roundedPath(bodyRect, .all(bodyCorner)))
    context.clip()
    // Top to bottom in the y-down space the mark is drawn in.
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: bodyRect.midX, y: bodyRect.minY),
        end: CGPoint(x: bodyRect.midX, y: bodyRect.maxY),
        options: []
    )
    context.restoreGState()

    // The panel spans from the ground's inner edge to the ground's, band on
    // top: runs 1 to 5 across and 1 to 4 down the left.
    fillDirectory(
        context,
        CGRect(
            x: x[1],
            y: left[1],
            width: x[6] - x[1],
            height: left[5] - left[1]
        ),
        corners: .all(panelCorner),
        fill: Ink.panel,
        band: Double(left[2] - left[1]),
        bandFill: Ink.rootBand
    )
    fillDirectory(
        context,
        rect(x, 2, left, 3),
        corners: Corners(
            topLeft: inner,
            topRight: inner,
            bottomRight: inner,
            bottomLeft: tileCorner
        ),
        fill: Ink.directory,
        band: max(1, (Mark.directoryBand * unit).rounded()),
        bandFill: Ink.directoryBand
    )
    fillDirectory(
        context,
        rect(x, 4, right, 3),
        corners: .all(inner),
        fill: Ink.column,
        band: max(1, (Mark.columnBand * unit).rounded()),
        bandFill: Ink.columnBand
    )
    // A file, not a directory: no band, all lime.
    context.addPath(
        roundedPath(
            rect(x, 4, right, 5),
            Corners(
                topLeft: inner,
                topRight: inner,
                bottomRight: tileCorner,
                bottomLeft: inner
            )
        )
    )
    context.setFillColor(Ink.file)
    context.fillPath()

    guard let image = context.makeImage() else {
        fail("cannot finish the \(pixels) px image")
    }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    guard
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        )
    else { fail("cannot write \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fail("cannot write \(url.path)")
    }
}

// Paths from the script's own place, so it runs from any directory.
let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let assets = repository.appendingPathComponent("assets")
let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent(
        "disktree-\(ProcessInfo.processInfo.processIdentifier).iconset"
    )

do {
    try FileManager.default.createDirectory(
        at: iconset,
        withIntermediateDirectories: true
    )
} catch {
    fail("cannot create \(iconset.path): \(error)")
}

// The names and sizes iconutil expects: each point size once at 1x and once
// at 2x, 16 to 512 points.
for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name =
            factor == 1
            ? "icon_\(points)x\(points).png"
            : "icon_\(points)x\(points)@2x.png"
        writePNG(
            render(pixels: points * factor),
            to: iconset.appendingPathComponent(name)
        )
    }
}

let icns = assets.appendingPathComponent("disktree.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "-o", icns.path, iconset.path]
do {
    try iconutil.run()
} catch {
    fail("cannot run iconutil: \(error)")
}
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else {
    fail("iconutil failed with status \(iconutil.terminationStatus)")
}

let preview = assets.appendingPathComponent("AppIcon.png")
writePNG(render(pixels: 1024), to: preview)
print("wrote \(icns.path)")
print("wrote \(preview.path)")
