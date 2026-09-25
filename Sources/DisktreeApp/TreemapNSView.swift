// The mosaic: tiles painted in one pass, labels typeset straight into it.
//
// Tiles are painted rather than composed from views. A treemap can put
// thousands of rectangles on screen, and a view per rectangle would spend the
// frame in layout (Invariant 6). Painting also means the reclaimable hatch,
// the cushions, the selection ring and its glow, the hover's lift and the
// marked badge are drawn in one place, in one order.
//
// The tiles are rasterised by hand, row by row (`MosaicRaster`): rounded
// corners, a restrained cushion on every leaf, the hatch. The rings, the
// badges and the labels go over them with CoreGraphics and CoreText, into
// the same bitmap, which is then copied into the view in one draw. Text is
// typeset once and cached, so setting the visible labels again every frame
// costs a lookup, and each label clips exactly to its own tile instead of
// bleeding into the neighbour.
//
// The painting is a function of a `Mosaic`, a theme, the hover's lift and a
// context and nothing else, so it is tested without a window.
// `TreemapNSView` only wires it to the state: the size it reports, the
// pointer, the wheel, the pinch and the smart-zoom tap and what each feels
// like under the fingers, a tile dragged out as its file, the context menu,
// what VoiceOver is told, and a display link while a level change or the
// hover's lift is animating.

import AppKit
import CoreText
import DisktreeCore
import Observation
import QuartzCore
import System

// MARK: - Colours

/// A colour with its CoreGraphics twin and its canvas pixel, converted once
/// per theme so that a frame never converts one per tile. A tile's fill
/// also carries its cushion's ramp.
struct MosaicInk {
    let hsla: HSLA
    let cgColor: CGColor
    /// The colour as the raster writes it, opaque, in the canvas's colour
    /// space (`MosaicColors.resolved(for:)`).
    private(set) var pixel: MosaicPixel
    /// Its alpha as the raster blends it, out of 256.
    let alpha: MosaicPixel
    /// The cushion from the top row to the bottom, `MosaicCushion.steps + 1`
    /// pixels; empty for a colour that is not a fill.
    private(set) var ramp: [MosaicPixel]

    init(_ hsla: HSLA) {
        self.init(hsla, ramp: [])
    }

    /// A fill, with the ramp `cushion` shades it through.
    init(_ hsla: HSLA, cushion: MosaicCushion) {
        self.init(
            hsla,
            ramp: (0...MosaicCushion.steps).map { step in
                cushion.shade(
                    hsla,
                    at: Double(step) / Double(MosaicCushion.steps)
                ).pixel
            }
        )
    }

    private init(_ hsla: HSLA, ramp: [MosaicPixel]) {
        self.hsla = hsla
        self.cgColor = hsla.cgColor
        self.pixel = hsla.pixel
        self.alpha = hsla.rasterAlpha
        self.ramp = ramp
    }

    /// Every pixel the raster writes for this colour.
    var pixels: [MosaicPixel] { [pixel] + ramp }

    /// The same colour with its pixels looked up in `table`: sRGB pixels as
    /// another colour space holds them.
    func mapped(_ table: [MosaicPixel: MosaicPixel]) -> Self {
        var ink = self
        ink.pixel = table[pixel] ?? pixel
        ink.ramp = ramp.map { table[$0] ?? $0 }
        return ink
    }
}

/// The cushion a leaf is shaded with: its fill lifted toward white toward
/// the top and sunk toward black toward the bottom, in a straight ramp,
/// which is how a cushion lit from above shades (van Wijk and van de
/// Wetering's cushion treemaps, which SequoiaView and KDirStat draw). Kept
/// to a few levels, so the hue and the depth step still read first.
///
/// The ramp passes through the fill itself at `pivot` of the way down.
/// Each card is lit one way only, the way that takes its words further
/// from their ground, since a short tile's name and size can sit anywhere
/// down it (`card(dark:)`).
struct MosaicCushion: Sendable, Hashable {
    /// How far the top row goes toward white.
    var light: Double
    /// How far the bottom row goes toward black.
    var shade: Double
    /// Where the ramp is the fill, from `0` at the top to `1` at the
    /// bottom: a half for a cushion lit above and sunk below, the bottom
    /// for one that is only lit, the top for one that only sinks.
    var pivot: Double = 0.5

    /// Rows of a ramp, top to bottom: fine enough that the step from one
    /// to the next is under half a level on the tallest tile.
    static let steps = 64

    /// The cushion for a card. The light card's names are dark: its tiles
    /// are lit toward white from the top, and never sunk, where a little
    /// black took the palest fills' size captions under 4.5:1. The dark
    /// card's names are light: its tiles sink toward black toward the
    /// bottom, and are never lit, where a little white took captions under
    /// 4.5:1 and names under 7:1 (`ContrastTests`). Its fills sit low,
    /// where black soon turns muddy, so it sinks only a fifth of the way.
    static func card(dark: Bool) -> MosaicCushion {
        dark
            ? MosaicCushion(light: 0, shade: 0.2, pivot: 0)
            : MosaicCushion(light: 0.26, shade: 0, pivot: 1)
    }

    /// `fill` at `fraction` of the way down a tile: lighter above the
    /// pivot, darker below it.
    func shade(_ fill: HSLA, at fraction: Double) -> HSLA {
        let at = min(max(fraction, 0), 1)
        if at < pivot {
            return fill.mixed(
                toward: HSLA(h: 0, s: 0, l: 1),
                by: light * (pivot - at) / pivot
            )
        }
        if at > pivot {
            return fill.mixed(
                toward: HSLA(h: 0, s: 0, l: 0),
                by: shade * (at - pivot) / (1 - pivot)
            )
        }
        return fill
    }
}

/// The canvas's colour space unless the destination's is taken instead.
let canvasSRGB =
    CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

/// The space a canvas drawn into `context` is best made in: the context's
/// own, so the copy converts nothing, when a canvas can be made in it — an
/// RGB space, of 8-bit components. sRGB otherwise.
func canvasSpace(for context: CGContext) -> CGColorSpace {
    canvasSpace(for: context.colorSpace)
}

/// `canvasSpace(for:)` for a destination known by its colour space: a
/// window's, whose layer's drawing context does not say.
func canvasSpace(for target: CGColorSpace?) -> CGColorSpace {
    guard let space = target, space.model == .rgb,
        space.supportsOutput, !CGColorSpaceUsesExtendedRange(space),
        CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: space,
            bitmapInfo: MosaicCanvas.bitmapInfo
        ) != nil
    else {
        return canvasSRGB
    }
    return space
}

/// `pixels`, opaque canvas pixels in `source`, as `destination` holds them:
/// drawn through CoreGraphics once, as one row, which is the conversion
/// the canvas's image went through when it was drawn into the window.
func convertPixels(
    _ pixels: [MosaicPixel],
    from source: CGColorSpace,
    to destination: CGColorSpace
) -> [MosaicPixel: MosaicPixel]? {
    guard !pixels.isEmpty else {
        return [:]
    }
    var input = pixels
    var output = [MosaicPixel](repeating: 0, count: pixels.count)
    let count = pixels.count
    let converted = input.withUnsafeMutableBytes { from in
        output.withUnsafeMutableBytes { into in
            guard
                let row = CGContext(
                    data: from.baseAddress,
                    width: count,
                    height: 1,
                    bitsPerComponent: 8,
                    bytesPerRow: count * 4,
                    space: source,
                    bitmapInfo: MosaicCanvas.bitmapInfo
                ),
                let image = row.makeImage(),
                let target = CGContext(
                    data: into.baseAddress,
                    width: count,
                    height: 1,
                    bitsPerComponent: 8,
                    bytesPerRow: count * 4,
                    space: destination,
                    bitmapInfo: MosaicCanvas.bitmapInfo
                )
            else { return false }
            target.interpolationQuality = .none
            target.setBlendMode(.copy)
            target.draw(image, in: CGRect(x: 0, y: 0, width: count, height: 1))
            return true
        }
    }
    guard converted else {
        return nil
    }
    // Every pixel is opaque: the alpha byte is the canvas's, whatever
    // rounding the draw left there.
    return Dictionary(
        zip(pixels, output.map { $0 | 0xFF00_0000 }),
        uniquingKeysWith: { first, _ in first }
    )
}

/// Theme colours resolved once per theme, not per frame: the view keeps one
/// per appearance and colour space.
struct MosaicColors {
    /// Depth steps a fill distinguishes; deeper clamps.
    static let depths = 5

    /// Names at the first level, then deeper.
    private(set) var labels: [MosaicInk]
    private(set) var labelDim: MosaicInk
    private(set) var hoverBorder: MosaicInk
    private(set) var selectedBorder: MosaicInk
    private(set) var markedBorder: MosaicInk
    private(set) var markedLabel: MosaicInk
    /// The corner on a tile with unreadable parts.
    private(set) var caution: MosaicInk
    private(set) var hatch: MosaicInk
    /// Under a marked tile and everything inside it: the theme's own at
    /// the first level (`markedFill(depth:)` for deeper ones).
    private(set) var markedFill: MosaicInk
    /// The mosaic's ground, and the surface a filtered-out fill steps back
    /// toward.
    private(set) var inset: MosaicInk
    /// Washed over the tile under the pointer, at full lift: a touch
    /// brighter.
    private(set) var lift: MosaicInk
    /// How much of the lift reaches the band at a tile's top where its name
    /// and size are set, `0` to `1`. All of it on the light card, where
    /// white under a dark name only adds contrast; none on the dark card,
    /// where it took names under 7:1: there the light pools below the
    /// words.
    let bandLift: Double
    /// The selection's glow at its edge, fading out from there.
    private(set) var glow: MosaicInk
    /// The badge on a marked tile, and the bar across it.
    private(set) var badge: MosaicInk
    private(set) var badgeGlyph: MosaicInk
    /// How leaves are shaded.
    let cushion: MosaicCushion
    /// The colour space the pixels are in, and the canvas is made in: sRGB
    /// as the theme gives them, until `resolved(for:)`.
    private(set) var space: CGColorSpace = canvasSRGB
    /// The marked fill per depth.
    private var marked: [MosaicInk]
    /// Inside a marked directory, where every tile goes with the mark: each
    /// kind's fill, then each age's, per depth, tinted toward the marked
    /// fill (`Mosaic.insideMark`).
    private var insideKind: [[MosaicInk]]
    private var insideAge: [[MosaicInk]]
    /// Fills per category (in `Category.allCases` order), then per depth,
    /// then per `Filtered` state.
    private var kind: [[[MosaicInk]]]
    /// Fills per age bucket, then per depth, then per `Filtered` state.
    private var age: [[[MosaicInk]]]
    /// The strip over a top-level directory, per category.
    private var strips: [MosaicInk]

    init(theme: Theme) {
        let cushion = MosaicCushion.card(dark: theme.isDark)
        self.cushion = cushion
        labels = [
            MosaicInk(theme.labelColor(depth: 0)),
            MosaicInk(theme.labelColor(depth: 1)),
        ]
        labelDim = MosaicInk(theme.labelDim)
        hoverBorder = MosaicInk(theme.bright.opacity(0.55))
        selectedBorder = MosaicInk(theme.highlight)
        markedBorder = MosaicInk(theme.danger)
        markedLabel = MosaicInk(theme.danger)
        // Caution, not the highlight: the highlight is the selection ring,
        // and a lime or violet corner would read as part of it.
        caution = MosaicInk(theme.caution)
        hatch = MosaicInk(theme.hatchColor)
        markedFill = MosaicInk(theme.markedFill)
        // A marked directory is matte, but not a slab: what is inside it
        // steps away from its rose or wine names a level at a time, darker
        // on the dark card and paler on the light one, so the structure
        // still reads and every name gains contrast the deeper it sits.
        let away =
            theme.isDark ? HSLA(h: 0, s: 0, l: 0) : HSLA(h: 0, s: 0, l: 1)
        marked = (0..<Self.depths).map { depth in
            MosaicInk(
                theme.markedFill.mixed(
                    toward: away,
                    by: Double(depth) * (theme.isDark ? 0.11 : 0.09)
                )
            )
        }
        inset = MosaicInk(theme.inset)
        // White on both cards: on the light one's pale fills it takes more
        // of it to show, as it takes more for the cushion's top.
        lift = MosaicInk(
            HSLA(h: 0, s: 0, l: 1, a: theme.isDark ? 0.09 : 0.34)
        )
        bandLift = theme.isDark ? 0 : 1
        // The lime glows on the dark card; the violet on the cream needs
        // less to read and would stain the tiles beside it at as much.
        glow = MosaicInk(theme.highlight.opacity(theme.isDark ? 0.62 : 0.5))
        badge = MosaicInk(theme.danger)
        // What reads on the danger colour: the navy on the dark card's
        // rose, the lightest cream on the light card's wine.
        badgeGlyph = MosaicInk(theme.isDark ? theme.background : theme.surface)

        // Only what matches keeps its colour; a directory holding matches
        // steps back less, so the way to them stays readable.
        let inset = theme.inset
        let states = { (fill: HSLA) in
            [
                MosaicInk(fill, cushion: cushion),
                MosaicInk(fill.mixed(toward: inset, by: 0.55)),
                MosaicInk(fill.mixed(toward: inset, by: 0.82)),
            ]
        }
        let depths = 0..<Self.depths
        kind = DisktreeCore.Category.allCases.map { category in
            depths.map { states(theme.categoryFill(category, depth: $0)) }
        }
        age = ageBuckets.indices.map { bucket in
            depths.map { states(theme.ageFill(bucket: bucket, depth: $0)) }
        }
        let tinted = { (fill: HSLA) in
            MosaicInk(Self.insideMark(fill, theme: theme), cushion: cushion)
        }
        insideKind = DisktreeCore.Category.allCases.map { category in
            depths.map { tinted(theme.categoryFill(category, depth: $0)) }
        }
        insideAge = ageBuckets.indices.map { bucket in
            depths.map { tinted(theme.ageFill(bucket: bucket, depth: $0)) }
        }
        strips = DisktreeCore.Category.allCases.map {
            MosaicInk(theme.categoryAccent($0))
        }
    }

    /// How far a tile inside a marked directory is tinted toward the
    /// marked fill: enough that the whole screen reads as going with the
    /// mark, little enough that the kinds still read.
    static let insideTint = 0.35

    /// `fill` inside a marked directory: its kind, tinted toward the
    /// marked fill.
    static func insideMark(_ fill: HSLA, theme: Theme) -> HSLA {
        fill.mixed(toward: theme.markedFill, by: insideTint)
    }

    /// A tile's fill: its hue and depth, or its age, stepped back when the
    /// find text leaves it out. `insideMark`, the directory drawn goes with
    /// a mark, and so does every tile but those the find leaves out.
    func fill(_ tile: TileDeco, insideMark: Bool = false) -> MosaicInk {
        let depth = min(max(tile.depth, 0), Self.depths - 1)
        if insideMark, tile.covered, !tile.marked, tile.filtered == .shown {
            return if let bucket = tile.ageBucket {
                insideAge[min(max(bucket, 0), insideAge.count - 1)][depth]
            } else {
                insideKind[Self.index(tile.category)][depth]
            }
        }
        // Marked, or inside something marked: it all goes together.
        if tile.marked || tile.covered {
            return marked[depth]
        }
        let ladder =
            if let bucket = tile.ageBucket {
                age[min(max(bucket, 0), age.count - 1)]
            } else {
                kind[Self.index(tile.category)]
            }
        let state =
            switch tile.filtered {
            case .shown: 0
            case .holds: 1
            case .out: 2
            }
        return ladder[depth][state]
    }

    /// The same colours, with every pixel the raster writes converted into
    /// `space`, the colour space of what the canvas is drawn into.
    ///
    /// A canvas in sRGB drawn into a window on a Display P3 or a calibrated
    /// display is colour-matched pixel by pixel, on the main thread, on
    /// every frame: ten milliseconds of a 2x mosaic, three times what
    /// painting it costs. Converted here once, the canvas is made in the
    /// window's space, and the copy into the window is a copy. The
    /// conversion is CoreGraphics' own, the one the copy made.
    func resolved(for space: CGColorSpace) -> Self {
        guard space != self.space else {
            return self
        }
        let all = Array(Set(inks.flatMap(\.pixels)))
        guard let table = convertPixels(all, from: self.space, to: space)
        else {
            return self
        }
        var resolved = self
        resolved.space = space
        let map = { (ink: MosaicInk) in ink.mapped(table) }
        resolved.labels = labels.map(map)
        resolved.labelDim = map(labelDim)
        resolved.hoverBorder = map(hoverBorder)
        resolved.selectedBorder = map(selectedBorder)
        resolved.markedBorder = map(markedBorder)
        resolved.markedLabel = map(markedLabel)
        resolved.caution = map(caution)
        resolved.hatch = map(hatch)
        resolved.markedFill = map(markedFill)
        resolved.inset = map(inset)
        resolved.lift = map(lift)
        resolved.glow = map(glow)
        resolved.badge = map(badge)
        resolved.badgeGlyph = map(badgeGlyph)
        resolved.marked = marked.map(map)
        resolved.insideKind = insideKind.map { $0.map(map) }
        resolved.insideAge = insideAge.map { $0.map(map) }
        resolved.kind = kind.map { $0.map { $0.map(map) } }
        resolved.age = age.map { $0.map { $0.map(map) } }
        resolved.strips = strips.map(map)
        return resolved
    }

    /// Every colour of the set, once each.
    private var inks: [MosaicInk] {
        labels
            + [
                labelDim, hoverBorder, selectedBorder, markedBorder,
                markedLabel, caution, hatch, markedFill, inset, lift, glow,
                badge, badgeGlyph,
            ]
            + marked + insideKind.flatMap { $0 } + insideAge.flatMap { $0 }
            + kind.flatMap { $0.flatMap { $0 } }
            + age.flatMap { $0.flatMap { $0 } } + strips
    }

    /// The strip a top-level directory of `category` carries.
    func strip(_ category: DisktreeCore.Category) -> MosaicInk {
        strips[Self.index(category)]
    }

    /// A name's colour at `depth`: the first level reads strongest.
    func label(depth: Int) -> MosaicInk {
        labels[depth == 0 ? 0 : 1]
    }

    private static func index(_ category: DisktreeCore.Category) -> Int {
        DisktreeCore.Category.allCases.firstIndex(of: category)
            ?? DisktreeCore.Category.allCases.count - 1
    }
}

// MARK: - Type

/// Label geometry, proportioned to the label's own type size.
///
/// The type size already follows `rem`, so padding, thresholds and gaps
/// keep their relationship to the text at every interface zoom step.
struct MosaicLabelMetrics: Hashable {
    /// A tile's name.
    let nameSize: CGFloat
    /// The size beside or under it.
    let sizeSize: CGFloat
    /// The box a name is set in; the name sits centred in it.
    let lineHeight: CGFloat
    /// From the tile's left edge to the text.
    let padding: CGFloat
    /// From the tile's top edge to the line box.
    let inset: CGFloat
    /// Narrower than this, a name cannot be read, so none is set.
    let minWidth: CGFloat
    /// Between a name and the size that follows it.
    let gap: CGFloat

    init(rem: CGFloat) {
        nameSize = TextSize.body.at(rem)
        sizeSize = TextSize.caption.at(rem)
        lineHeight = nameSize * 1.35
        padding = nameSize * 0.42
        inset = nameSize * 0.25
        minWidth = nameSize * 3.3
        gap = nameSize * 0.67
    }
}

/// The measurements a label's layout needs from a typeset line.
struct MosaicLineMeasure: Hashable {
    var width: CGFloat
    /// Above the baseline, positive.
    var ascent: CGFloat
    /// Below the baseline, positive.
    var descent: CGFloat
}

/// One typeset line, ready to draw.
struct MosaicLine {
    let line: CTLine
    let measure: MosaicLineMeasure
}

/// Typesets labels at one rem, and remembers what it has set.
///
/// A frame sets at most a few hundred short lines, and consecutive frames
/// set nearly the same ones, so a label costs a lookup after its first
/// frame. Keyed by colour too, since CoreText bakes the colour into the line.
final class MosaicTypesetter {
    /// Which face a line is set in.
    enum Face: Hashable {
        /// A tile's name.
        case name
        /// A first-level directory's name in its band.
        case bold
        /// The size text.
        case size
    }

    private struct Key: Hashable {
        var text: String
        var face: Face
        var color: HSLA
        /// The width a line was cut to fit, in whole points, negative for
        /// a cut in the middle; `nil` for a line set whole.
        var width: Int? = nil
    }

    /// Lines kept before the cache starts over: several frames' worth, and
    /// small enough that a long session never grows it without bound.
    static let capacity = 4_096

    let rem: CGFloat
    let metrics: MosaicLabelMetrics
    private let fonts: [Face: CTFont]
    private var lines: [Key: MosaicLine] = [:]

    init(rem: CGFloat) {
        self.rem = rem
        let metrics = MosaicLabelMetrics(rem: rem)
        self.metrics = metrics
        fonts = [
            .name: Self.font(.name, size: metrics.nameSize),
            .bold: Self.font(.bold, size: metrics.nameSize),
            .size: Self.font(.size, size: metrics.sizeSize),
        ]
    }

    /// `text` set in `face` and `color`.
    func line(_ text: String, face: Face, color: MosaicInk) -> MosaicLine {
        let key = Key(text: text, face: face, color: color.hsla)
        if let known = lines[key] {
            return known
        }
        return remember(key, Self.measured(set(text, face: face, color: color)))
    }

    /// `text` set in `face` and `color`, cut with an ellipsis to fit
    /// `width` points: at its end, or in its middle for a file's name, so
    /// the extension stays as Finder keeps it. A name is never cut
    /// mid-letter at its tile's edge. The line as a whole when not even
    /// the ellipsis fits; its tile's clip is all that is left then.
    func line(
        _ text: String,
        face: Face,
        color: MosaicInk,
        fitting width: CGFloat,
        cut: CTLineTruncationType
    ) -> MosaicLine {
        let whole = line(text, face: face, color: color)
        guard whole.measure.width > width else {
            return whole
        }
        // Whole points: a tile's width changes by fractions while the
        // layout moves, and one cut per point is as fine as the eye sees.
        let points = Int(width.rounded(.down))
        let key = Key(
            text: text,
            face: face,
            color: color.hsla,
            width: points * (cut == .middle ? -1 : 1)
        )
        if let known = lines[key] {
            return known
        }
        let ellipsis = set("\u{2026}", face: face, color: color)
        guard
            let cutLine = CTLineCreateTruncatedLine(
                whole.line,
                Double(points),
                cut,
                ellipsis
            )
        else {
            return whole
        }
        return remember(key, Self.measured(cutLine))
    }

    private func remember(_ key: Key, _ typeset: MosaicLine) -> MosaicLine {
        if lines.count >= Self.capacity {
            lines.removeAll(keepingCapacity: true)
        }
        lines[key] = typeset
        return typeset
    }

    private func set(_ text: String, face: Face, color: MosaicInk) -> CTLine {
        let font = fonts[face] ?? Self.font(face, size: metrics.nameSize)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                color.cgColor,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        return CTLineCreateWithAttributedString(string)
    }

    private static func measured(_ line: CTLine) -> MosaicLine {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(
            line,
            &ascent,
            &descent,
            &leading
        )
        return MosaicLine(
            line: line,
            measure: MosaicLineMeasure(
                width: CGFloat(width),
                ascent: ascent,
                descent: descent
            )
        )
    }

    /// SF Pro, as Finder sets a file's name: medium for a name, so it holds
    /// its own on a cushioned fill; semibold for a first-level band, which
    /// names a region. Sizes in SF Pro Rounded with tabular figures, so a
    /// column of them lines up and a size changing under a scan does not
    /// jitter, and the numbers read as the app's own, as the panel's do.
    static func font(_ face: Face, size: CGFloat) -> CTFont {
        switch face {
        case .name:
            return NSFont.systemFont(ofSize: size, weight: .medium)
        case .bold:
            return NSFont.systemFont(ofSize: size, weight: .semibold)
        case .size:
            let figures = NSFont.monospacedDigitSystemFont(
                ofSize: size,
                weight: .medium
            )
            return figures.fontDescriptor.withDesign(.rounded)
                .flatMap { NSFont(descriptor: $0, size: size) } ?? figures
        }
    }
}

// MARK: - Painting

/// Where one label's lines go inside the region it owns, as the starts of
/// their baselines.
struct MosaicLabelPlacement: Hashable {
    /// The name's baseline start.
    var name: CGPoint
    /// The size text's baseline start; `nil` when there is no room for it.
    var size: CGPoint?
    /// The marked badge before the name, for the marked tile's own label.
    var badge: CGRect?
}

/// What a frame shows that the mosaic does not say: how far the hover has
/// lifted, as the view eases it in and out.
struct MosaicEffects: Sendable, Hashable {
    /// The hovered tile's lift, `0` to `1`.
    var hoverLift: Double = 1
    /// A tile the pointer has just left, still settling back.
    var fading: FadingTile?

    /// A frame at rest: whatever is hovered, fully lifted.
    static let settled = MosaicEffects()
}

/// A tile settling back after the pointer left it: its index in the
/// mosaic's tiles, and how much of its lift is left.
struct FadingTile: Sendable, Hashable {
    var index: Int
    var lift: Double
}

/// A tile as this frame draws it: where, in points and in pixels, and how.
struct PlacedTile {
    /// Its index in the mosaic's tiles.
    var index: Int
    var deco: TileDeco
    /// On screen, edges on whole pixels.
    var quad: CGRect
    /// The same, in the canvas's pixels.
    var box: PixelBox
    /// Its corners' radius, in points; `0` for a square tile.
    var radius: CGFloat
    /// Nothing is drawn inside it: a file, a closed directory, a tail.
    var leaf: Bool
    /// For a directory drawn open, the canvas row its first child starts
    /// on: what lies above it is the directory's own band, and what lies
    /// below it is painted over by its children, all but the gaps.
    var bodyTop: Int? = nil
}

/// Paints one frame of the mosaic into a context whose user space is in
/// points.
///
/// Everything it draws comes from the `Mosaic` it is handed, already
/// decided by the state: the view and the tests paint through this same
/// code. Tiles are rasterised into the canvas row by row (`MosaicRaster`),
/// then the rings, the badges and the labels are drawn over them with
/// CoreGraphics, and the canvas is copied into the context in one draw.
struct MosaicPainter {
    let colors: MosaicColors
    let typesetter: MosaicTypesetter
    /// Device pixels per point: tile edges land on whole pixels, and the
    /// hatch is measured in them.
    let scale: CGFloat
    /// The bitmap, kept by the view from frame to frame.
    let canvas: MosaicCanvas

    /// Corners at the first level: the regions.
    static let outerRadius: CGFloat = 3
    /// Corners below it.
    static let innerRadius: CGFloat = 2
    /// Below this on its shorter side a leaf is too small for a cushion to
    /// show, and is painted flat.
    static let cushionMinimum: CGFloat = 8
    /// How far the selection's glow reaches past its ring, in points, and
    /// how quickly it falls away (a Gaussian's width).
    static let glowReach: CGFloat = 9
    static let glowSpread: CGFloat = 3.4
    /// A selection ring and a mark's: two points, inside the tile.
    static let ringWidth: CGFloat = 2

    init(
        colors: MosaicColors,
        typesetter: MosaicTypesetter,
        scale: CGFloat,
        canvas: MosaicCanvas = MosaicCanvas()
    ) {
        self.colors = colors
        self.typesetter = typesetter
        self.scale = scale.isFinite && scale > 0 ? scale : 1
        self.canvas = canvas
    }

    /// Paint `mosaic` over `bounds`: the ground, the tiles, their rings,
    /// then the labels. `flipped` says whether `context` already runs from
    /// the top down, as a flipped view's does; a bare bitmap runs up.
    func paint(
        _ mosaic: Mosaic,
        in context: CGContext,
        bounds: CGRect,
        flipped: Bool,
        effects: MosaicEffects = .settled
    ) {
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        guard
            let canvas = canvas.context(
                width: width,
                height: height,
                space: colors.space
            ),
            let raster = MosaicRaster(canvas)
        else {
            // Nothing to draw in, or no room: the ground at least.
            context.setFillColor(colors.inset.cgColor)
            context.fill(bounds)
            return
        }
        let tiles = place(mosaic, bounds: bounds)
        raster.clear(colors.inset.pixel)
        rasterTiles(tiles, insideMark: mosaic.insideMark, into: raster)
        rasterEffects(tiles, effects: effects, into: raster)

        canvas.saveGState()
        // The canvas's user space as the layout thinks: points, from the
        // top-left corner of `bounds`, down.
        canvas.translateBy(x: 0, y: CGFloat(height))
        canvas.scaleBy(x: scale, y: -scale)
        canvas.translateBy(x: -bounds.minX, y: -bounds.minY)
        canvas.setShouldSmoothFonts(false)
        paintMarks(tiles, insideMark: mosaic.insideMark, in: canvas)
        paintLabels(
            mosaic.labels,
            badged: Set(mosaic.tiles.lazy.filter(\.marked).map(\.rect)),
            view: mosaic.view,
            in: canvas,
            bounds: bounds
        )
        canvas.restoreGState()

        guard let image = self.canvas.image() else { return }
        context.saveGState()
        if flipped {
            // An image is drawn upright in a space that runs up; a flipped
            // view's runs down, so it is turned back for the copy.
            context.translateBy(x: 0, y: bounds.minY + bounds.maxY)
            context.scaleBy(x: 1, y: -1)
        }
        // Pixel for pixel: the canvas is the context's size at its scale.
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(image, in: bounds)
        context.restoreGState()
    }

    // MARK: Tiles

    /// Every tile worth drawing this frame, where it lands.
    func place(_ mosaic: Mosaic, bounds: CGRect) -> [PlacedTile] {
        let tiles = mosaic.tiles
        var placed: [PlacedTile] = []
        placed.reserveCapacity(tiles.count)
        for (index, tile) in tiles.enumerated() {
            let rect = mosaic.view.project(tile.rect)
            if rect.w <= 0.5 || rect.h <= 0.5 {
                continue
            }
            let quad = Self.snap(
                CGRect(
                    x: bounds.minX + rect.x,
                    y: bounds.minY + rect.y,
                    width: rect.w,
                    height: rect.h
                ),
                scale: scale
            )
            // Zoomed in, most tiles are off screen.
            guard quad.intersects(bounds) else { continue }
            let pixel = { (value: CGFloat) in Int((value * scale).rounded()) }
            // The layout puts a directory right before what is inside it,
            // so a tile with anything inside it is followed by a deeper one:
            // its first child, laid out from the top of the room below the
            // directory's band.
            let leaf =
                index + 1 == tiles.count || tiles[index + 1].depth <= tile.depth
            let bodyTop: Int? =
                leaf
                ? nil
                : pixel(
                    Self.snap(
                        CGRect(
                            x: bounds.minX,
                            y: bounds.minY
                                + mosaic.view.project(tiles[index + 1].rect).y,
                            width: 1,
                            height: 1
                        ),
                        scale: scale
                    ).minY - bounds.minY
                )
            placed.append(
                PlacedTile(
                    index: index,
                    deco: tile,
                    quad: quad,
                    box: PixelBox(
                        left: pixel(quad.minX - bounds.minX),
                        top: pixel(quad.minY - bounds.minY),
                        right: pixel(quad.maxX - bounds.minX),
                        bottom: pixel(quad.maxY - bounds.minY)
                    ),
                    radius: Self.cornerRadius(depth: tile.depth, quad: quad),
                    leaf: leaf,
                    bodyTop: bodyTop
                )
            )
        }
        return placed
    }

    /// A tile's corner radius: three points for a region, two below, less
    /// when the tile is small, and none once it is tiny, where a rounded
    /// corner would only look smudged.
    static func cornerRadius(depth: Int, quad: CGRect) -> CGFloat {
        let full = depth == 0 ? outerRadius : innerRadius
        let radius = min(full, min(quad.width, quad.height) / 4)
        return radius >= 1 ? radius : 0
    }

    /// Whether a tile is cushioned: a leaf, large enough, in its own
    /// colour. A directory drawn open shows only its band and the gaps
    /// between its children, where a ramp would only be noise; a marked
    /// tile is matte, which is part of what sets it apart; a tile the find
    /// text leaves out steps back, flat.
    /// Inside a marked directory, a tile keeps its kind, and its cushion.
    static func isCushioned(
        _ tile: PlacedTile,
        insideMark: Bool = false
    ) -> Bool {
        tile.leaf && !tile.deco.marked
            && (!tile.deco.covered || insideMark)
            && tile.deco.filtered == .shown
            && min(tile.quad.width, tile.quad.height) >= cushionMinimum
    }

    /// Whether a tile is hatched: reclaimable, and neither marked, which
    /// says more, nor stepped back. Inside a marked directory, where every
    /// tile goes with the mark, the hatch still says what could come back
    /// on its own.
    static func isHatched(_ tile: TileDeco, insideMark: Bool = false) -> Bool {
        tile.reclaimable && !tile.marked && (!tile.covered || insideMark)
            && tile.filtered == .shown
    }

    /// Rows of the strip over a top-level directory: two points, so the
    /// first level of structure reads before any detail. Age mode colours
    /// by age alone, and a stepped-back tile has no strip to show.
    func stripRows(_ tile: PlacedTile) -> Int {
        guard tile.deco.depth == 0, tile.deco.ageBucket == nil,
            tile.deco.filtered != .out
        else { return 0 }
        return Int((min(2, tile.quad.height) * scale).rounded())
    }

    /// The step of a cushion's ramp that pixel row `y` of `box` takes.
    static func rampStep(row y: Int, of box: PixelBox) -> Int {
        let fraction = (Double(y - box.top) + 0.5) / Double(max(box.height, 1))
        return min(
            max(Int((fraction * Double(MosaicCushion.steps)).rounded()), 0),
            MosaicCushion.steps
        )
    }

    private func mask(_ tile: PlacedTile) -> CornerMask? {
        tile.radius > 0 ? canvas.mask(radius: tile.radius * scale) : nil
    }

    private func rasterTiles(
        _ tiles: [PlacedTile],
        insideMark: Bool,
        into raster: MosaicRaster
    ) {
        // The legend's promise, in the canvas's pixels.
        let stripe = Int(Hatch.tile.width.rounded())
        let period = Int(Hatch.tile.period.rounded())
        for tile in tiles {
            let ink = colors.fill(tile.deco, insideMark: insideMark)
            let mask = mask(tile)
            let box = tile.box
            let strip = stripRows(tile)
            let accent = strip > 0 ? colors.strip(tile.deco.category).pixel : 0
            // No border by default: the gaps between tiles, wider between
            // the top-level directories, are what separate them; the
            // rounded corners and the cushions are what make each one a
            // thing rather than a cell.
            if Self.isCushioned(tile, insideMark: insideMark),
                ink.ramp.count > MosaicCushion.steps
            {
                let ramp = ink.ramp
                raster.fill(box, mask: mask) { y in
                    y - box.top < strip
                        ? accent : ramp[Self.rampStep(row: y, of: box)]
                }
            } else {
                let flat = ink.pixel
                raster.fill(box, mask: mask) { y in
                    y - box.top < strip ? accent : flat
                }
            }
            // Reclaimable space is hatched, over any hue: the hatch answers
            // "can it go", the colour "what is it". Everything inside a
            // reclaimable directory is reclaimable too, and repaints its
            // own fill and hatch over its parent's; so a directory drawn
            // open is hatched in its band alone, not under its children,
            // where every level of a deep `node_modules` hatched the same
            // pixels again. Its gaps, a point or two, show no stripe.
            if Self.isHatched(tile.deco, insideMark: insideMark) {
                var band = box
                if let body = tile.bodyTop {
                    band.bottom = min(box.bottom, max(body, box.top))
                }
                raster.hatch(
                    band,
                    mask: mask,
                    skip: strip,
                    width: stripe,
                    period: period,
                    color: colors.hatch.pixel,
                    alpha: colors.hatch.alpha
                )
            }
        }
    }

    /// The hover's lift and the selection's glow, washed over the tiles
    /// once every one of them is down.
    ///
    /// Only a leaf is lifted. A directory drawn open holds other tiles and
    /// their names, and a wash over all of them took their contrast down
    /// with it; its hairline ring says it is under the pointer.
    private func rasterEffects(
        _ tiles: [PlacedTile],
        effects: MosaicEffects,
        into raster: MosaicRaster
    ) {
        let metrics = typesetter.metrics
        // The rows a leaf's name and a stacked size are set in, and the
        // rows below them over which the lift comes up to full.
        let band = Int(
            ((metrics.inset * 2 + metrics.lineHeight * 2) * scale).rounded()
        )
        let ramp = max(Int((metrics.lineHeight * scale).rounded()), 1)
        for tile in tiles where tile.leaf {
            let lift: Double
            if tile.deco.hovered {
                lift = effects.hoverLift
            } else if let fading = effects.fading, fading.index == tile.index {
                lift = fading.lift
            } else {
                continue
            }
            let full = Double(colors.lift.alpha) * min(max(lift, 0), 1)
            let inBand = full * colors.bandLift
            let top = tile.box.top
            raster.wash(
                tile.box,
                mask: mask(tile),
                color: colors.lift.pixel
            ) { y in
                let below = y - top - band
                let alpha =
                    below < 0
                    ? inBand
                    : inBand + (full - inBand)
                        * min(Double(below + 1) / Double(ramp), 1)
                return MosaicPixel(alpha.rounded())
            }
        }
        guard let selected = tiles.last(where: { $0.deco.selected }) else {
            return
        }
        // A Gaussian from the ring outward, measured in points whatever
        // the scale, and looked up rather than computed per pixel.
        let reach = Int((Self.glowReach * scale).rounded(.up))
        let spread = Double(Self.glowSpread * scale)
        let peak = Double(colors.glow.alpha)
        let table = (0...(reach * 4)).map { step -> MosaicPixel in
            let distance = Double(step) / 4
            return MosaicPixel(
                (peak * exp(-(distance * distance) / (spread * spread)))
                    .rounded()
            )
        }
        raster.glow(
            selected.box,
            radius: Double(selected.radius * scale),
            extent: reach,
            color: colors.glow.pixel
        ) { distance in
            table[min(Int(distance * 4), table.count - 1)]
        }
    }

    // MARK: Rings

    /// A ring to draw once every fill is down.
    private struct Outline {
        var rank: Int
        var order: Int
        var tile: PlacedTile
        var width: CGFloat
        var color: MosaicInk
    }

    /// The rings and the unreadable flag, over the rasterised tiles and
    /// under the labels. (The marked badge leads its tile's name, with the
    /// labels.)
    private func paintMarks(
        _ tiles: [PlacedTile],
        insideMark: Bool,
        in context: CGContext
    ) {
        // Outlines are drawn after every fill: a directory's children paint
        // over its body, and would otherwise cover its selection ring,
        // leaving only slivers of it showing in the gaps between them.
        var outlines: [Outline] = []
        for (order, tile) in tiles.enumerated() {
            let deco = tile.deco
            // Ranked so the most important ring is painted last, on top. A
            // marked tile keeps its ring while the pointer is over it: the
            // hover's lift shows the pointer, the ring what is marked.
            let ring: (rank: Int, width: CGFloat, color: MosaicInk)? =
                if deco.selected {
                    (3, Self.ringWidth, colors.selectedBorder)
                } else if deco.marked {
                    (2, Self.ringWidth, colors.markedBorder)
                } else if deco.hovered {
                    (1, 1, colors.hoverBorder)
                } else if insideMark && deco.covered && deco.depth == 0 {
                    // Inside a mark, a hairline of its colour round each
                    // region: the tint says it, and this says it again
                    // where the eye meets each region's edge.
                    (0, 1, colors.markedBorder)
                } else {
                    nil
                }
            if let ring {
                outlines.append(
                    Outline(
                        rank: ring.rank,
                        order: order,
                        tile: tile,
                        width: ring.width,
                        color: ring.color
                    )
                )
            }
            if deco.unreadable && tile.quad.width > 12 && tile.quad.height > 12
            {
                // A small warning dot: part of this was never measured.
                context.setFillColor(colors.caution.cgColor)
                context.fillEllipse(
                    in: CGRect(
                        x: tile.quad.maxX - 7.5,
                        y: tile.quad.minY + 2.5,
                        width: 5,
                        height: 5
                    )
                )
            }
        }
        // Within a rank, tiles keep their layout order, as a stable sort
        // would keep them.
        outlines.sort { ($0.rank, $0.order) < ($1.rank, $1.order) }
        for outline in outlines {
            Self.ring(
                inside: outline.tile.quad,
                radius: outline.tile.radius,
                width: outline.width,
                color: outline.color.cgColor,
                in: context
            )
        }
    }

    /// A ring drawn inside `rect`, following its rounded corners: it never
    /// reaches past the tile into its neighbour.
    static func ring(
        inside rect: CGRect,
        radius: CGFloat,
        width: CGFloat,
        color: CGColor,
        in context: CGContext
    ) {
        let outer = min(radius, rect.width / 2, rect.height / 2)
        let inner = rect.insetBy(dx: width, dy: width)
        context.setFillColor(color)
        let path = CGMutablePath()
        path.addRoundedRect(in: rect, cornerWidth: outer, cornerHeight: outer)
        if inner.width > 0, inner.height > 0 {
            // Concentric: the inner corner is the outer less the ring.
            let rest = min(
                max(outer - width, 0),
                inner.width / 2,
                inner.height / 2
            )
            path.addRoundedRect(
                in: inner, cornerWidth: rest, cornerHeight: rest)
        }
        context.addPath(path)
        context.fillPath(using: .evenOdd)
    }

    /// Round a rectangle's edges to device pixels. Tiles land on fractional
    /// positions, and a 2 pt strip or ring there smears across a pixel row
    /// and leaves a seam; rounding each edge, not the size, keeps neighbours
    /// flush.
    static func snap(_ rect: CGRect, scale: CGFloat) -> CGRect {
        let round = { (value: CGFloat) in (value * scale).rounded() / scale }
        let left = round(rect.minX)
        let top = round(rect.minY)
        let right = round(rect.maxX)
        let bottom = round(rect.maxY)
        return CGRect(
            x: left,
            y: top,
            width: max(right - left, 0),
            height: max(bottom - top, 0)
        )
    }

    // MARK: Labels

    /// The region a label owns on screen, or `nil` when it is too small to
    /// hold a name.
    ///
    /// A subdivided directory's name lives in the band it reserved; a
    /// leaf's sits at the top of its own tile. Either way the region is the
    /// label's clip, so no label can reach into another tile.
    static func mask(
        _ label: TileLabel,
        view: ViewTransform,
        bounds: CGRect,
        metrics: MosaicLabelMetrics
    ) -> CGRect? {
        let rect = view.project(label.header ?? label.rect)
        if rect.w < metrics.minWidth || rect.h < metrics.nameSize {
            return nil
        }
        return CGRect(
            x: bounds.minX + rect.x,
            y: bounds.minY + rect.y,
            width: rect.w,
            height: rect.h
        )
    }

    /// Where a label's name and size go inside its `mask`.
    ///
    /// A first-level band puts the size at the far end, where the sizes read
    /// as a column; a deeper band follows the name. A closed tile stacks it
    /// under the name when it is tall enough. A size that would crowd the
    /// name is left out.
    static func place(
        _ label: TileLabel,
        mask: CGRect,
        metrics: MosaicLabelMetrics,
        name: MosaicLineMeasure,
        size: MosaicLineMeasure?,
        badged: Bool = false
    ) -> MosaicLabelPlacement {
        // A badge leads the name, and the name and whatever follows it on
        // its line make way for it.
        let lead = badged ? badgeSide(metrics) + metrics.gap * 0.6 : 0
        let origin = CGPoint(
            x: mask.minX + metrics.padding + lead,
            y: mask.minY + metrics.inset
        )
        // A line sits centred in its line box, putting its baseline at
        // `height / 2 + (ascent - descent) / 2` below the box's top. Mixed
        // sizes share the name's baseline, not its box.
        let baseline = { (top: CGFloat, line: MosaicLineMeasure) in
            top + metrics.lineHeight / 2 + (line.ascent - line.descent) / 2
        }
        // The name sits centred in the top line of its region: the line box
        // with the inset above and below it, or the whole region where that
        // is shorter. A band is: it is only as tall as a name needs, and set
        // from the inset down, a 12 point name's descenders — the "pp" of
        // "arm64-apple-macosx", the "y" of "Telemetry" — fell out of its
        // bottom edge. Centred, what room there is is split evenly above
        // the ascenders and below the descenders, at every rem.
        let line = min(mask.height, metrics.lineHeight + metrics.inset * 2)
        let nameBaseline =
            mask.minY + line / 2 + (name.ascent - name.descent) / 2
        let side = badgeSide(metrics)
        let placed = MosaicLabelPlacement(
            name: CGPoint(x: origin.x, y: nameBaseline),
            size: nil,
            // Centred on the capitals: they sit about 0.35 of the type
            // size above the baseline, in SF Pro as in most faces.
            badge: badged
                ? CGRect(
                    x: mask.minX + metrics.padding,
                    y: nameBaseline - metrics.nameSize * 0.35 - side / 2,
                    width: side,
                    height: side
                ) : nil
        )
        guard let size else { return placed }

        let stacked =
            label.header == nil
            && mask.height >= metrics.lineHeight * 2 + metrics.inset
        if stacked {
            // Under the name, whole or not at all: a size cut at the
            // tile's edge reads as a different number.
            guard size.width <= mask.maxX - metrics.padding - origin.x else {
                return placed
            }
            let top = origin.y + metrics.lineHeight * 0.92
            return MosaicLabelPlacement(
                name: placed.name,
                size: CGPoint(x: origin.x, y: baseline(top, size)),
                badge: placed.badge
            )
        }
        let x: CGFloat
        if label.header != nil && label.depth == 0 {
            x = mask.maxX - size.width - metrics.padding
        } else {
            // Only when the whole size fits after the name and its gap:
            // "723MiB" cut to "723MiE" is worse than no size, which the
            // panel and the tooltip give anyway.
            let room = mask.maxX - metrics.padding - origin.x
            if room - name.width - metrics.gap < size.width {
                return placed
            }
            x = origin.x + name.width + metrics.gap
        }
        guard x > origin.x + name.width + metrics.padding else {
            return placed
        }
        return MosaicLabelPlacement(
            name: placed.name,
            size: CGPoint(x: x, y: nameBaseline),
            badge: placed.badge
        )
    }

    /// The side of the badge that leads a marked tile's name, in points:
    /// about the height of the name's capitals and ascenders, as an icon
    /// beside a name in Finder's list is.
    static func badgeSide(_ metrics: MosaicLabelMetrics) -> CGFloat {
        (metrics.nameSize * 0.92).rounded()
    }

    /// The face a label's name is set in. The first level is set in bold
    /// in its band: it names a region.
    static func face(_ label: TileLabel) -> MosaicTypesetter.Face {
        label.depth == 0 && label.header != nil ? .bold : .name
    }

    /// The labels, each clipped to the region it owns. A label whose tile
    /// is in `badged` — a marked tile's own, not one inside it — leads with
    /// the marked badge.
    private func paintLabels(
        _ labels: [TileLabel],
        badged: Set<Rect>,
        view: ViewTransform,
        in context: CGContext,
        bounds: CGRect
    ) {
        let metrics = typesetter.metrics
        // CoreText sets glyphs rising up the y axis; this space runs down.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for label in labels {
            guard
                let mask = Self.mask(
                    label,
                    view: view,
                    bounds: bounds,
                    metrics: metrics
                ), mask.intersects(bounds)
            else { continue }
            let color =
                if label.marked {
                    colors.markedLabel
                } else if label.dim {
                    colors.labelDim
                } else {
                    colors.label(depth: label.depth)
                }
            let name = typesetter.line(
                label.text,
                face: Self.face(label),
                color: color
            )
            let size =
                label.sizeText.isEmpty
                ? nil
                : typesetter.line(
                    label.sizeText,
                    face: .size,
                    color: colors.labelDim
                )
            let placement = Self.place(
                label,
                mask: mask,
                metrics: metrics,
                name: name.measure,
                size: size?.measure,
                badged: label.marked && badged.contains(label.rect)
            )

            // A name longer than its region ends in an ellipsis inside
            // it, a little short of the edge, rather than running into
            // the clip mid-letter.
            let shown = typesetter.line(
                label.text,
                face: Self.face(label),
                color: color,
                fitting: mask.maxX - metrics.padding * 0.5
                    - placement.name.x,
                cut: label.isFile ? .middle : .end
            )

            context.saveGState()
            context.clip(to: mask)
            if let badge = placement.badge {
                paintBadge(badge, in: context)
            }
            Self.draw(shown, at: placement.name, in: context)
            if let size, let point = placement.size {
                Self.draw(size, at: point, in: context)
            }
            context.restoreGState()
        }
    }

    /// The marked badge: a disc in the danger colour with a bar across it,
    /// the mark a Mac puts on what is about to be taken away. With the ring
    /// and the matte fill it makes a mark unmistakable, for a colour-blind
    /// eye too, and set before the name it says which tile the mark is on
    /// when a whole directory has gone the danger colour.
    private func paintBadge(_ frame: CGRect, in context: CGContext) {
        context.setFillColor(colors.badge.cgColor)
        context.fillEllipse(in: frame)
        let bar = CGRect(
            x: frame.midX - frame.width * 0.28,
            y: frame.midY - frame.height * 0.075,
            width: frame.width * 0.56,
            height: frame.height * 0.15
        )
        context.setFillColor(colors.badgeGlyph.cgColor)
        context.addPath(
            CGPath(
                roundedRect: bar,
                cornerWidth: bar.height / 2,
                cornerHeight: bar.height / 2,
                transform: nil
            )
        )
        context.fillPath()
    }

    private static func draw(
        _ line: MosaicLine,
        at baseline: CGPoint,
        in context: CGContext
    ) {
        context.textPosition = baseline
        CTLineDraw(line.line, context)
    }
}

/// Paint `mosaic` as the treemap view does, with `theme`'s colours, labels
/// at `rem` points to the rem and tile edges on whole pixels at `scale`
/// pixels to the point: the entry point for drawing a mosaic without a
/// window. `flipped` says whether `context` already runs from the top down.
func paintMosaic(
    _ mosaic: Mosaic,
    theme: Theme,
    bounds: CGRect,
    in context: CGContext,
    rem: CGFloat = baseRem,
    scale: CGFloat = 1,
    flipped: Bool = false,
    effects: MosaicEffects = .settled
) {
    MosaicPainter(
        colors: MosaicColors(theme: theme)
            .resolved(for: canvasSpace(for: context)),
        typesetter: MosaicTypesetter(rem: rem),
        scale: scale
    )
    .paint(
        mosaic,
        in: context,
        bounds: bounds,
        flipped: flipped,
        effects: effects
    )
}

// MARK: - Input, as pure functions

/// A point in window coordinates as a treemap-local point: from the
/// treemap's top-left corner, y growing down, in points, which is the space
/// the layout, the hit-test and the tooltip all think in. `frame` is the
/// treemap's bounds in window coordinates, which run up from the bottom.
func treemapPoint(inWindow point: CGPoint, frame: CGRect) -> CGPoint {
    CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y)
}

/// Whether a treemap-local point is on the treemap. The right and bottom
/// edges belong to whatever is beyond them.
func treemapContains(_ point: CGPoint, size: CGSize) -> Bool {
    point.x >= 0 && point.y >= 0 && point.x < size.width
        && point.y < size.height
}

/// Wheel notches in a scroll event: positive zooms in.
///
/// A mouse wheel reports whole lines; a trackpad or a smooth wheel reports
/// points, many small ones, and 24 points count as a line, as they did on
/// Linux. Shift turns a vertical wheel horizontal on a Mac before the app
/// sees it, so a shifted scroll, which pans, takes whichever axis moved.
func wheelLines(
    deltaX: CGFloat,
    deltaY: CGFloat,
    precise: Bool,
    shift: Bool
) -> Double {
    let delta = shift && deltaY == 0 ? deltaX : deltaY
    return Double(precise ? delta / 24 : delta)
}

/// A trackpad's scroll deltas, in points, as wheel lines along each axis:
/// 24 points to a line, as `wheelLines` counts them.
func panLines(deltaX: CGFloat, deltaY: CGFloat) -> (Double, Double) {
    (Double(deltaX / 24), Double(deltaY / 24))
}

/// Lets the rest of a gesture go once it has changed the directory on
/// screen.
///
/// Zooming in at the ceiling enters the directory under the pointer, and
/// zooming out at the floor leaves it. A trackpad flick is a stream of
/// small deltas and then momentum; followed to the end, one flick would
/// enter a level, zoom through it, enter the next and tunnel several levels
/// deep. So once a gesture has changed levels, nothing more of it is used:
/// the gate opens again when fresh fingers touch down, when its momentum
/// runs out, or after `quiet` without an event, which is how a wheel
/// without phases says a gesture is over.
struct GestureGate: Sendable, Hashable {
    /// Seconds without an event that end a gesture.
    static let quiet: TimeInterval = 0.3

    /// Set from a level change until the gesture that made it is over.
    private(set) var closed = false
    /// The last event's time, admitted or not: quiet is measured from it.
    private var last: TimeInterval?

    /// The gesture whose event arrived at `time` just changed levels.
    mutating func close(at time: TimeInterval) {
        closed = true
        last = time
    }

    /// Whether to act on an event at `time` with these phases (both empty
    /// for a wheel without phases). Every event is seen, used or not, so
    /// the quiet that reopens the gate is quiet since the last one.
    mutating func admits(
        time: TimeInterval,
        phase: NSEvent.Phase,
        momentum: NSEvent.Phase
    ) -> Bool {
        defer { last = time }
        guard closed else { return true }
        let quietSince = last.map { time - $0 >= Self.quiet } ?? true
        // Fingers on the trackpad again: a new gesture, even if the old
        // one's momentum never reported its end.
        let touched = phase.contains(.began) || phase.contains(.mayBegin)
        if quietSince || touched {
            closed = false
            return true
        }
        // The gesture's last event: its momentum ran out, or was stopped.
        // Still part of the gesture, so it is not used either.
        if momentum.contains(.ended) || momentum.contains(.cancelled) {
            closed = false
        }
        return false
    }
}

/// Where one pinch starts and ends.
///
/// A pinch that went through a stop cannot go through another until the
/// fingers lift (`AppState.endMagnify`), so the view has to know when they
/// do. A trackpad says so in every event's phase. A pinch without phases —
/// synthesized, or from a device that sends none — is taken to start again
/// after `GestureGate.quiet` without an event, as a wheel's gesture is.
struct PinchPhases: Sendable, Hashable {
    /// The last event's time.
    private var last: TimeInterval?

    /// Whether the event at `time` with `phase` starts a new pinch. Every
    /// event is seen, so quiet is measured from the last one.
    mutating func begins(time: TimeInterval, phase: NSEvent.Phase) -> Bool {
        defer { last = time }
        if phase.contains(.began) || phase.contains(.mayBegin) {
            return true
        }
        guard phase.isEmpty else {
            return false
        }
        return last.map { time - $0 >= GestureGate.quiet } ?? true
    }

    /// Whether `phase` is a pinch's last: the fingers lifted, or the system
    /// took the gesture away.
    static func ends(_ phase: NSEvent.Phase) -> Bool {
        phase.contains(.ended) || phase.contains(.cancelled)
    }
}

/// A tile dragged out of the mosaic: its file, for Finder, the Dock's Trash
/// or a Terminal window.
struct TileDrag: Sendable, Hashable {
    var crumbs: [Int]
    /// The file URL the drag carries.
    var url: URL
    /// Where the button went down, in treemap-local points: the drag image
    /// starts there.
    var origin: CGPoint
}

/// Dragging a tile out, as pure functions.
enum TileDragging {
    /// How far the pointer must move with the button down before a press
    /// is a drag, in points: a few, so a hand that trembles on a click
    /// still clicks, as it does on a file in Finder.
    static let threshold: CGFloat = 4

    /// Whether a press at `start` has become a drag at `now`.
    static func begins(from start: CGPoint, to now: CGPoint) -> Bool {
        hypot(now.x - start.x, now.y - start.y) >= threshold
    }

    /// What a drag may do where it lands. Outside the app: whatever a drag
    /// from Finder may, so each destination does with the file what it
    /// would with Finder's — the Dock's Trash moves it to the Trash (Put
    /// Back returns it), a Finder window moves or copies it, a Terminal
    /// types its path. The destination does it; disktree removes nothing
    /// itself, whatever the drag ends in. Inside the app: nothing, or a
    /// tile let go over the window would be dropped on it and scanned.
    static func operations(_ context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .outsideApplication: [.copy, .link, .generic, .move, .delete]
        case .withinApplication: []
        @unknown default: []
        }
    }

    /// The file URL of `path`, spelled as a directory's when it is one, so
    /// a receiver need not look.
    static func url(_ path: FilePath, isDir: Bool) -> URL {
        URL(
            filePath: path.string,
            directoryHint: isDir ? .isDirectory : .notDirectory
        )
    }
}

/// What the treemap's context menu can do to the tile under the pointer.
enum TreemapMenuAction: Sendable, Hashable {
    case mark
    case unmark
    /// Inside a marked directory, which it goes with: unmark that one, as
    /// the panel offers, since the tile cannot be marked on its own.
    case unmarkEnclosing
    /// Directories only: select it and go inside.
    case open
    case quickLook
    case revealInFinder
    case copyPath

    var title: String {
        switch self {
        case .mark: "Mark"
        case .unmark: "Unmark"
        case .unmarkEnclosing: "Unmark Enclosing Folder"
        case .open: "Open"
        case .quickLook: "Quick Look"
        case .revealInFinder: "Reveal in Finder"
        case .copyPath: "Copy Path"
        }
    }

    /// The menu for a tile, in groups a separator divides: what disktree
    /// does with it, then what the rest of the Mac can. A tile inside a
    /// marked directory cannot be marked on its own; its menu offers to
    /// unmark that directory instead.
    static func sections(
        isDir: Bool,
        marked: Bool,
        inMarked: Bool = false
    ) -> [[Self]] {
        let mark: Self =
            marked ? .unmark : inMarked ? .unmarkEnclosing : .mark
        let own: [Self] = [mark] + (isDir ? [.open] : [])
        return [own, [.quickLook, .revealInFinder, .copyPath]]
    }
}

/// A context menu item's payload: the action and the tile it was opened on,
/// captured when the menu opened, so it acts on that tile even if the
/// pointer's tile changes underneath the menu.
///
/// By path as well as crumbs: a tree can land while the menu is open — the
/// rescan after a hand-over, a widening, a re-ranking — and renumber every
/// crumb, and the item must still act on the tile it was opened on.
struct TreemapMenuCommand: Sendable, Hashable {
    var action: TreemapMenuAction
    var crumbs: [Int]
    var path: FilePath
}

// MARK: - The hover's lift

/// The hover's lift, eased in over a moment and out again as the pointer
/// moves on. The view keeps it, not the state: it is how a tile feels under
/// the pointer, and nothing else reads it.
///
/// The tile coming up is known by its crumbs, which a transition does not
/// change; the tile settling back by where it stood, since the pointer has
/// left it and the state no longer names it. A layout that moves it — a
/// level change, a resize — simply lets it land at once.
struct HoverMotion {
    /// How long a tile takes to come up under the pointer: quick enough to
    /// follow a sweep across the mosaic, slow enough to be seen rising.
    static let rise: Duration = .milliseconds(140)
    /// How long it takes to settle back once the pointer has moved on.
    static let fall: Duration = .milliseconds(220)

    private var hovered: [Int]?
    private var since: ContinuousClock.Instant?
    /// The hovered tile as the last frame drew it.
    private var last: (index: Int, rect: Rect, lift: Double)?
    /// The tile settling back, from how high, since when.
    private var fading:
        (
            index: Int, rect: Rect, from: Double,
            since: ContinuousClock.Instant
        )?

    init() {}

    /// The lift for a frame at `now` in which `hovered` is under the
    /// pointer. `still` is Reduce Motion: a tile is up or down at once.
    mutating func frame(
        hovered: [Int]?,
        mosaic: Mosaic,
        now: ContinuousClock.Instant,
        still: Bool
    ) -> MosaicEffects {
        if hovered != self.hovered {
            if let last, !still, last.lift > 0 {
                fading = (last.index, last.rect, last.lift, now)
            } else {
                fading = nil
            }
            self.hovered = hovered
            // Under Reduce Motion nothing rises: no start to rise from.
            since = hovered == nil || still ? nil : now
        }
        let lift =
            still
            ? 1 : Self.eased(since.map { (now - $0) / Self.rise } ?? 1)
        if let index = mosaic.tiles.firstIndex(where: \.hovered) {
            last = (index, mosaic.tiles[index].rect, lift)
        } else {
            last = nil
        }
        var effects = MosaicEffects(hoverLift: lift)
        if let fading {
            let left =
                fading.from
                * (1 - Self.eased((now - fading.since) / Self.fall))
            let tiles = mosaic.tiles
            if left > 0.001, fading.index < tiles.count,
                tiles[fading.index].rect == fading.rect,
                !tiles[fading.index].hovered
            {
                effects.fading = FadingTile(index: fading.index, lift: left)
            } else {
                self.fading = nil
            }
        }
        return effects
    }

    /// Whether a tile is still coming up or settling back at `now`, so the
    /// view keeps drawing frames.
    func isMoving(at now: ContinuousClock.Instant) -> Bool {
        if let since, hovered != nil, now - since < Self.rise {
            return true
        }
        if let fading, now - fading.since < Self.fall {
            return true
        }
        return false
    }

    /// Ease out: fast at first, settling into place, as the level
    /// transitions move.
    static func eased(_ progress: Double) -> Double {
        let clamped = min(max(progress, 0), 1)
        return 1 - pow(1 - clamped, 3)
    }
}

// MARK: - The view

/// The treemap on screen: one view, painted in one `draw(_:)`.
///
/// It reads the frame from `state.prepare()` inside observation tracking,
/// so any property the frame read redraws it, and it reports its size and
/// every pointer event back to the state in treemap-local points. Nothing
/// is decided here but what a gesture feels like: the state says what a
/// zoom or a click did, and the view, which knows a finger made it, plays
/// the haptic.
final class TreemapNSView: NSView {
    /// What is drawn, and where the pointer's events go.
    var state: AppState {
        didSet {
            reportedSize = nil
            reportSize()
            press = nil
            tileElements = []
            hover = HoverMotion()
            needsDisplay = true
        }
    }
    /// The size last told to the state, so telling it again can be skipped
    /// without reading the state (see `reportSize`).
    private var reportedSize: CGSize?

    /// Where the gestures' haptics play: the trackpad, or a test's
    /// recorder. The SwiftUI host passes on its environment's.
    var haptics: any HapticPerformer = TrackpadHaptics()
    /// A level change lands at once, the new level fading in, instead of
    /// growing out of the old one: the system's Reduce Motion, which the
    /// SwiftUI host keeps in step.
    var reducesMotion = NSWorkspace.shared
        .accessibilityDisplayShouldReduceMotion
    /// A test watches drags start here, in place of a real dragging
    /// session, which would take the pointer from whoever is at the Mac.
    var onDragOut: ((TileDrag) -> Void)?

    /// Colours for the appearance, and the Increase Contrast setting, they
    /// were resolved in: the setting changes the theme without changing
    /// the appearance's name.
    private var palette:
        (
            appearance: NSAppearance.Name, increaseContrast: Bool,
            space: CGColorSpace, colors: MosaicColors
        )?
    private var typesetter: MosaicTypesetter?
    /// The last frame's destination colour space, and the canvas's for it:
    /// asked once per space, not once per frame.
    private var spaces: (target: CGColorSpace?, canvas: CGColorSpace)?
    /// The bitmap the mosaic is painted into, kept from frame to frame.
    private let canvas = MosaicCanvas()
    /// The hovered tile's lift, rising and settling.
    private var hover = HoverMotion()
    /// Runs while a level change or the hover's lift is animating, and only
    /// then.
    private var link: CADisplayLink?
    private var scrollGate = GestureGate()
    private var pinch = PinchPhases()
    private var pinchFeel = PinchFeel()
    /// The left button's press, from going down until it comes up or turns
    /// into a drag.
    private var press: Press?
    /// The largest tiles as VoiceOver sees them, largest first: the same
    /// element for the same tile from one call to the next, so its cursor
    /// stays on a tile while the frame changes around it.
    ///
    /// `nonisolated(unsafe)` because the accessibility hit test reads it,
    /// and AppKit declares that nonisolated although it only ever calls it
    /// on the main thread, which is where this is written.
    nonisolated(unsafe) private var tileElements: [TreemapTileElement] = []
    /// The accessibility value last announced, so a change is announced
    /// once.
    private var announced: String?

    init(state: AppState) {
        self.state = state
        super.init(frame: .zero)
        // Since macOS 14 a view draws past its bounds unless told not to; a
        // tile zoomed past the edge must not paint over its neighbours.
        clipsToBounds = true
        // `.inVisibleRect` keeps the area in step with the view's size, so
        // it is added once rather than rebuilt on every resize.
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [
                    .mouseMoved, .mouseEnteredAndExited, .activeInActiveApp,
                    .inVisibleRect,
                ],
                owner: self,
                userInfo: nil
            )
        )
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("disktree-treemap")
        setAccessibilityHelp(
            "Click selects, a second click opens. Command-click marks. "
                + "Pinch or scroll to zoom. Drag a tile to Finder."
        )
        // The colours are resolved again whenever the root would build its
        // theme again: a change of the system's colours, and of Increase
        // Contrast, which strengthens the dim labels and the hatch. That
        // one is posted on the workspace's own centre, not the default one.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(colorSettingsChanged(_:)),
            name: NSColor.systemColorsDidChangeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(colorSettingsChanged(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// The layout and the pointer both measure from the top-left corner.
    override var isFlipped: Bool { true }

    /// The ground is painted edge to edge in the inset colour, which is
    /// opaque in every theme.
    override var isOpaque: Bool { true }

    /// A click on the mosaic selects, even in a window that is not yet key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    /// The window's content runs under a transparent title bar, and the
    /// mosaic's clicks are its own, never a window drag.
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Size

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reportSize()
    }

    override func layout() {
        super.layout()
        reportSize()
    }

    /// The state lays out for the size it was told, so it is told whenever
    /// the frame changes, and never from `draw`, which must not change what
    /// it reads.
    ///
    /// Written, never read: this runs inside AppKit's layout pass, and AppKit
    /// observes what a layout pass reads. Reading `treemapSize` here made the
    /// write that follows schedule another layout pass for every one it
    /// answered, until AppKit gave up with an exception — which an interface
    /// zoom, resizing the view several times in one pass, set off.
    private func reportSize() {
        let size = bounds.size
        guard size != reportedSize else {
            return
        }
        reportedSize = size
        state.treemapSize = size
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        let state = state
        let now = ContinuousClock.now
        let (mosaic, rem, animating, hovered) = withObservationTracking {
            (
                state.prepare(now: now), state.rem, state.transition != nil,
                state.hovered
            )
        } onChange: { [weak self] in
            // Called as the change is being made; the frame is drawn after.
            Task { @MainActor [weak self] in
                self?.stateChanged()
            }
        }
        let effects = hover.frame(
            hovered: hovered,
            mosaic: mosaic,
            now: now,
            still: reducesMotion
        )
        if (animating && !reducesMotion) || hover.isMoving(at: now) {
            startLink()
        }
        MosaicPainter(
            colors: colors(for: canvasSpaceKept(for: context)),
            typesetter: typesetter(rem: rem),
            scale: backingScale,
            canvas: canvas
        )
        .paint(
            mosaic,
            in: context,
            bounds: bounds,
            flipped: isFlipped,
            effects: effects
        )
    }

    /// Something the last frame read has changed: draw again, and do what
    /// the change asks of the platform rather than of the state.
    private func stateChanged() {
        needsDisplay = true
        if reducesMotion {
            landTransition()
        }
        announceValue()
    }

    /// Device pixels per point, for snapping and the hatch.
    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? 1
    }

    /// `canvasSpace(for:)`, kept while the destination's space stays.
    ///
    /// A layer-backed view draws into a context that names no colour space;
    /// what it is drawn into is the window's backing store, in the window's
    /// colour space, which follows the display the window is on.
    private func canvasSpaceKept(for context: CGContext) -> CGColorSpace {
        let target = context.colorSpace ?? window?.colorSpace?.cgColorSpace
        if let spaces, spaces.target == target {
            return spaces.canvas
        }
        let canvas = canvasSpace(for: target)
        spaces = (target, canvas)
        return canvas
    }

    /// The colours for the appearance, resolved for `space`, the window's
    /// colour space as the frame being drawn has it: a window moved to
    /// another display gets them again.
    private func colors(for space: CGColorSpace) -> MosaicColors {
        let appearance = effectiveAppearance
        let increaseContrast = NSWorkspace.shared
            .accessibilityDisplayShouldIncreaseContrast
        if let palette, palette.appearance == appearance.name,
            palette.increaseContrast == increaseContrast,
            palette.space == space
        {
            return palette.colors
        }
        let colors = MosaicColors(
            theme: .system(
                appearance: appearance,
                increaseContrast: increaseContrast
            )
        )
        .resolved(for: space)
        palette = (appearance.name, increaseContrast, space, colors)
        return colors
    }

    private func typesetter(rem: CGFloat) -> MosaicTypesetter {
        if let typesetter, typesetter.rem == rem {
            return typesetter
        }
        let typesetter = MosaicTypesetter(rem: rem)
        self.typesetter = typesetter
        return typesetter
    }

    /// Forget the colours, and the lines typeset in them.
    private func dropPalette() {
        palette = nil
        typesetter = nil
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        dropPalette()
    }

    @objc private func colorSettingsChanged(_ notification: Notification) {
        dropPalette()
    }

    /// Moved to a display with another scale: edges snap to its pixels and
    /// the hatch is measured in them.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopLink()
        } else {
            needsDisplay = true
        }
    }

    // MARK: Transitions

    /// How long the new level takes to fade in over the old under Reduce
    /// Motion: short enough to read as the click that caused it.
    static let fade: CFTimeInterval = 0.15

    private func startLink() {
        guard link == nil, window != nil else { return }
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    /// One display frame of a level change or of the hover's lift:
    /// nothing observed changes while the tiles move, so the frame is asked
    /// for here.
    @objc private func step(_ link: CADisplayLink) {
        let now = ContinuousClock.now
        let running = state.tickTransition(now: now)
        needsDisplay = true
        if !running && !hover.isMoving(at: now) {
            stopLink()
        }
    }

    /// Under Reduce Motion a level change does not move: it lands at once,
    /// and the layer fades from the old level to the new, which is the only
    /// motion Reduce Motion keeps.
    private func landTransition() {
        guard let transition = state.transition else {
            return
        }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = Self.fade
        layer?.add(fade, forKey: "level")
        stopLink()
        // Well past its end: exactly at it, rounding may leave it running.
        state.tickTransition(
            now: transition.started + transition.duration * 2
        )
    }

    // MARK: Pointer

    /// A left-button press on the mosaic.
    private struct Press {
        /// Where it went down, in window coordinates: how far the pointer
        /// has moved is measured from here, whatever the view does.
        var start: CGPoint
        /// The same, in treemap-local points.
        var point: CGPoint
        var modifiers: PointerModifiers
        /// The tile it went down on, and its file: what a drag carries.
        var crumbs: [Int]?
        var path: FilePath?
        var isDir: Bool
        /// A click on the selection opens it, but only once the button comes
        /// up: a press that turns into a drag must not first open what it
        /// is dragging.
        var held: Bool
        /// It turned into a drag, whose session has the pointer until it
        /// ends.
        var dragging = false
    }

    /// Where `event` happened, in treemap-local points.
    func localPoint(_ event: NSEvent) -> CGPoint {
        treemapPoint(
            inWindow: event.locationInWindow,
            frame: convert(bounds, to: nil)
        )
    }

    /// The modifiers a click carries, in the state's vocabulary.
    nonisolated static func modifiers(
        _ flags: NSEvent.ModifierFlags
    ) -> PointerModifiers {
        PointerModifiers(
            command: flags.contains(.command),
            control: flags.contains(.control),
            shift: flags.contains(.shift),
            option: flags.contains(.option)
        )
    }

    /// The button `NSEvent.buttonNumber` names, among the ones the mosaic
    /// answers to with a click: the middle button marks. The right button
    /// opens the context menu instead, and the rest (back, forward) mean
    /// nothing here.
    nonisolated static func otherButton(_ number: Int) -> PointerButton? {
        number == 2 ? .middle : nil
    }

    /// Play `haptic`, when there is one to play.
    private func feel(_ haptic: Haptic?) {
        if let haptic {
            haptics.perform(haptic)
        }
    }

    private func pointerMoved(_ event: NSEvent) {
        let point = localPoint(event)
        // A drag keeps reporting once the pointer has left the mosaic.
        // Outside it there is nothing to hover, and a stale tooltip would
        // cover whatever the pointer went to.
        if treemapContains(point, size: bounds.size) {
            state.pointerMoved(to: point)
        } else {
            state.pointerExited()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        pointerMoved(event)
    }

    override func mouseMoved(with event: NSEvent) {
        pointerMoved(event)
    }

    override func mouseExited(with event: NSEvent) {
        state.pointerExited()
    }

    /// A click, through the state; felt when it marked or unmarked, which a
    /// ⌘-click and the middle button do.
    private func click(
        at point: CGPoint,
        button: PointerButton,
        count: Int,
        modifiers: PointerModifiers
    ) {
        feel(
            Haptic.click(
                state.mouseDown(
                    at: point,
                    button: button,
                    clickCount: count,
                    modifiers: modifiers
                )
            )
        )
    }

    override func mouseDown(with event: NSEvent) {
        let point = localPoint(event)
        let modifiers = Self.modifiers(event.modifierFlags)
        press = nil
        // Only a plain press can become a drag: a ⌘-click has marked by the
        // time the pointer moves, and a double click has opened.
        if event.clickCount == 1, !modifiers.command, !modifiers.control {
            let crumbs = state.tile(atX: point.x, y: point.y)
            let press = Press(
                start: event.locationInWindow,
                point: point,
                modifiers: modifiers,
                crumbs: crumbs,
                path: crumbs.flatMap(state.existingPath),
                isDir: crumbs.flatMap(state.node(at:))?.isDir ?? false,
                held: crumbs != nil && crumbs == state.selected
            )
            self.press = press
            if press.held {
                return
            }
        }
        click(
            at: point,
            button: .left,
            count: event.clickCount,
            modifiers: modifiers
        )
    }

    override func mouseDragged(with event: NSEvent) {
        // A drag under way is its session's, pointer and all.
        if press?.dragging == true {
            return
        }
        pointerMoved(event)
        guard var press, let crumbs = press.crumbs,
            let path = press.path,
            TileDragging.begins(from: press.start, to: event.locationInWindow)
        else { return }
        press.dragging = true
        self.press = press
        dragOut(
            TileDrag(
                crumbs: crumbs,
                url: TileDragging.url(path, isDir: press.isDir),
                origin: press.point
            ),
            event: event
        )
    }

    override func mouseUp(with event: NSEvent) {
        guard let press else {
            return
        }
        self.press = nil
        // The click held back from the button going down, now that it has
        // come up without dragging anything.
        if press.held && !press.dragging {
            click(
                at: press.point,
                button: .left,
                count: 1,
                modifiers: press.modifiers
            )
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let button = Self.otherButton(event.buttonNumber) else {
            super.otherMouseDown(with: event)
            return
        }
        click(
            at: localPoint(event),
            button: button,
            count: event.clickCount,
            modifiers: Self.modifiers(event.modifierFlags)
        )
    }

    // MARK: Zoom gestures

    override func scrollWheel(with event: NSEvent) {
        guard
            scrollGate.admits(
                time: event.timestamp,
                phase: event.phase,
                momentum: event.momentumPhase
            )
        else { return }
        let shift = event.modifierFlags.contains(.shift)
        // A shifted swipe on a trackpad pans whichever way the fingers go;
        // a shifted wheel has one axis, and `scroll` pans it up and down.
        if shift, event.hasPreciseScrollingDeltas {
            let (across, down) = panLines(
                deltaX: event.scrollingDeltaX,
                deltaY: event.scrollingDeltaY
            )
            state.pan(lines: across, down)
            return
        }
        let lines = wheelLines(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            precise: event.hasPreciseScrollingDeltas,
            shift: shift
        )
        // A trackpad opens and closes every gesture with an empty event.
        guard lines != 0 else { return }
        let point = localPoint(event)
        // Felt only while fingers are on the pad, which is what a phase
        // says. A mouse wheel's notches are felt in the wheel, and momentum
        // carries on after the fingers have lifted.
        let felt = !event.phase.isEmpty
        // Asked before the zoom moves, as the state asks it: the stop this
        // event may reach is the one under the pointer now.
        let wall = felt && !shift && isWall(inward: lines > 0, at: point)
        let outcome = state.scroll(at: point, lines: lines, shift: shift)
        if outcome == .changedLevel {
            scrollGate.close(at: event.timestamp)
        }
        if felt {
            feel(Haptic.scroll(outcome, wall: wall))
        }
    }

    /// Whether a zoom `inward` at `point` would rest against its stop
    /// rather than go through it: nothing to go into under the pointer at
    /// the ceiling, nothing above the scanned root at the floor.
    private func isWall(inward: Bool, at point: CGPoint) -> Bool {
        inward
            ? state.zoomTarget(x: Double(point.x), y: Double(point.y)) == nil
            : state.parentCrumbs == nil
    }

    /// A pinch. At a stop the zoom rests with a click under the fingers;
    /// squeezing on goes through with a firmer one. After that the same
    /// pinch goes on magnifying the level it arrived in, and cannot go
    /// through another until the fingers lift: the state keeps that rule,
    /// told here when a pinch begins and ends. The stop the new level
    /// appears at was felt as the level change (`PinchFeel`).
    override func magnify(with event: NSEvent) {
        if pinch.begins(time: event.timestamp, phase: event.phase) {
            state.endMagnify()
            pinchFeel.begin()
        }
        let factor = 1 + Double(event.magnification)
        if factor > 0, factor != 1 {
            feel(
                pinchFeel.haptic(
                    for: state.magnify(at: localPoint(event), factor: factor)
                )
            )
        }
        if PinchPhases.ends(event.phase) {
            state.endMagnify()
        }
    }

    /// A two-finger double tap: into the directory under the fingers, or
    /// back out of the one the last tap went into.
    override func smartMagnify(with event: NSEvent) {
        feel(Haptic.smartZoom(state.smartZoom(at: localPoint(event))))
    }

    /// Force Click, or a three-finger tap, where the system is set to look
    /// things up that way: the tile under the finger in Quick Look, as
    /// Finder answers the same gesture on a file.
    override func quickLook(with event: NSEvent) {
        // The deep press ends the click it began as: when the button comes
        // up it has previewed, as Finder's does, and must not go on to open
        // the selection it was pressed on, or turn into a drag.
        press = nil
        let point = localPoint(event)
        guard let crumbs = state.tile(atX: point.x, y: point.y) else {
            return
        }
        state.revealQuickLook(crumbs)
    }

    /// Where `path` is drawn, on the screen: the whole mosaic for the
    /// directory drawn, its tile for one inside it, and `nil` for anything
    /// not on screen. Quick Look's panel zooms out of it and back in.
    func screenFrame(of path: FilePath) -> CGRect? {
        guard let window, let crumbs = state.crumbs(for: path) else {
            return nil
        }
        var local = bounds
        if crumbs != state.crumbs {
            guard let rect = state.tileRect(crumbs) else {
                return nil
            }
            let shown = state.view.project(rect)
            local = CGRect(
                x: shown.x, y: shown.y, width: shown.w, height: shown.h
            )
            .intersection(bounds)
        }
        guard !local.isEmpty else {
            return nil
        }
        return window.convertToScreen(convert(local, to: nil))
    }

    // MARK: Dragging a tile out

    /// Hand the tile's file to a dragging session: Finder, the Dock's
    /// Trash, a Terminal window, anything that takes a file.
    private func dragOut(_ drag: TileDrag, event: NSEvent) {
        // The hover ring and the tooltip would stay behind under the drag.
        state.pointerExited()
        if let onDragOut {
            onDragOut(drag)
            return
        }
        let image = Self.dragImage(for: drag.url)
        let item = NSDraggingItem(pasteboardWriter: drag.url as NSURL)
        item.setDraggingFrame(
            CGRect(
                x: drag.origin.x - image.size.width / 2,
                y: drag.origin.y - image.size.height / 2,
                width: image.size.width,
                height: image.size.height
            ),
            contents: image
        )
        // The drag starts over this window, whose drop target takes a
        // folder to scan: it is told this one is on its way out.
        DropHighlight.ownDrag = true
        let session = beginDraggingSession(
            with: [item],
            event: event,
            source: self
        )
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    /// The side of a dragged tile's icon, in points: Finder's icon view at
    /// its default size, which is what a file being dragged looks like on a
    /// Mac.
    static let dragIconSide: CGFloat = 48

    /// A dragged tile looks like the file it carries: the file's own icon.
    static func dragImage(for url: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(
            forFile: url.path(percentEncoded: false)
        )
        // A copy: the icon may be shared with Finder's own cache.
        let image = icon.copy() as? NSImage ?? icon
        image.size = NSSize(width: dragIconSide, height: dragIconSide)
        return image
    }

    // MARK: Context menu

    /// Right-click, and control-click, which AppKit turns into this same
    /// question before any `mouseDown`: a menu for the tile under the
    /// pointer, or none over the ground.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = localPoint(event)
        guard let crumbs = state.tile(atX: point.x, y: point.y),
            let node = state.node(at: crumbs),
            let path = state.path(at: crumbs)
        else { return nil }
        let marked = state.marks.contains(path)
        let enclosing = marked ? nil : state.markedAncestor(of: path)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let sections = TreemapMenuAction.sections(
            isDir: node.isDir,
            marked: marked,
            inMarked: enclosing != nil
        )
        for (index, section) in sections.enumerated() {
            if index > 0 {
                menu.addItem(.separator())
            }
            for action in section {
                // Named as the panel names it: "Unmark big".
                let title =
                    if action == .unmarkEnclosing, let enclosing {
                        "Unmark \(SelectionSection.shortName(enclosing))"
                    } else {
                        action.title
                    }
                let item = NSMenuItem(
                    title: title,
                    action: #selector(chooseMenuItem(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = TreemapMenuCommand(
                    action: action,
                    crumbs: crumbs,
                    path: path
                )
                menu.addItem(item)
            }
        }
        return menu
    }

    @objc private func chooseMenuItem(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? TreemapMenuCommand
        else { return }
        perform(command)
    }

    /// Do what a menu item says to the tile it was opened on, found again
    /// by its path in whatever tree is on screen now; gone from it, the
    /// item does nothing, and says so.
    func perform(_ command: TreemapMenuCommand) {
        let crumbs =
            state.path(at: command.crumbs) == command.path
            ? command.crumbs : state.crumbs(for: command.path)
        guard let crumbs else {
            state.notice = Notice(
                "\(displayPath(command.path, home: state.home)) is no longer "
                    + "in the tree",
                status: .warning
            )
            return
        }
        perform(command.action, on: crumbs)
    }

    /// Do what a context menu item says, through the same state methods the
    /// keys use. A mark made here is felt, as a ⌘-click's is: the menu was
    /// chosen with a finger on the pad.
    func perform(_ action: TreemapMenuAction, on crumbs: [Int]) {
        switch action {
        case .mark, .unmark:
            if state.toggleMark(crumbs) {
                haptics.perform(.generic)
            }
        case .unmarkEnclosing:
            if let path = state.path(at: crumbs),
                let enclosing = state.markedAncestor(of: path)
            {
                state.unmark(enclosing)
                haptics.perform(.generic)
            }
        case .open:
            state.select(crumbs)
            state.descend()
        case .quickLook:
            state.revealQuickLook(crumbs)
        case .revealInFinder:
            state.revealInFinder(crumbs)
        case .copyPath:
            state.copyPath(crumbs)
        }
    }

    // MARK: Accessibility

    /// How many tiles VoiceOver is offered: the largest of the first
    /// level, as many as a person can move through one by one. The rest are
    /// a level down, a press and an Enter away.
    static let accessibleTiles = 32

    /// Names the directory drawn, the one thing a glance at the mosaic
    /// tells a sighted user first.
    override func accessibilityLabel() -> String? {
        "Treemap of \(displayPath(state.currentPath, home: state.home))"
    }

    /// What the mosaic says at a glance: the directory drawn and what it
    /// weighs, then the selection and what that weighs.
    override func accessibilityValue() -> Any? {
        accessibilitySummary()
    }

    /// The accessibility value, as words.
    func accessibilitySummary() -> String {
        let metric = state.options.metric
        var parts: [String] = []
        if let current = state.current {
            parts.append(
                displayPath(state.currentPath, home: state.home) + ", "
                    + Self.spoken(current, metric: metric)
            )
        }
        if let selected = state.selected, selected.count > state.crumbs.count,
            let node = state.node(at: selected)
        {
            let marked = state.path(at: selected).map(state.marks.contains)
            parts.append(
                "selected \(node.name), \(Self.spoken(node, metric: metric))"
                    + (marked == true ? ", marked" : "")
            )
        } else {
            parts.append("nothing selected")
        }
        return parts.joined(separator: "; ")
    }

    /// A node's size as it is read out: in full, unlike a label's.
    static func spoken(_ node: Node, metric: Metric) -> String {
        switch metric {
        case .bytes: humanBytes(node.bytes)
        case .files:
            node.files == 1 ? "1 file" : "\(humanCount(node.files)) files"
        }
    }

    override func accessibilityChildren() -> [Any]? {
        accessibleTileElements()
    }

    /// The tile VoiceOver's pointer is over, among the ones it is offered;
    /// `point` is on the screen, where their frames are answered too.
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        MainActor.assumeIsolated {
            _ = accessibleTileElements()
        }
        return tileElements.first { $0.accessibilityFrame().contains(point) }
            ?? self
    }

    /// The first level's largest tiles as accessibility elements, where
    /// they are on screen now.
    func accessibleTileElements() -> [TreemapTileElement] {
        guard let tiles = state.layout() else {
            tileElements = []
            return []
        }
        let view = state.view
        let metric = state.options.metric
        let known = Dictionary(
            tileElements.map { ($0.crumbs, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var elements: [TreemapTileElement] = []
        // The layout puts the first level largest first.
        for tile in tiles where tile.depth == 0 {
            guard case .node(let crumbs) = tile.kind,
                let node = state.node(at: crumbs)
            else { continue }
            let rect = view.project(tile.rect)
            let frame = CGRect(
                x: rect.x, y: rect.y, width: rect.w, height: rect.h
            )
            .intersection(bounds)
            // Zoomed in, most of the level is off screen: nothing there to
            // point at.
            guard frame.width >= 1, frame.height >= 1 else { continue }
            let element =
                known[crumbs]
                ?? TreemapTileElement(crumbs: crumbs, treemap: self)
            let marked = state.path(at: crumbs).map(state.marks.contains)
            // The parent space runs up from the bottom whether or not the
            // parent is flipped, as AppKit's own conversion reads it.
            element.setAccessibilityFrameInParentSpace(
                CGRect(
                    x: frame.minX,
                    y: bounds.height - frame.maxY,
                    width: frame.width,
                    height: frame.height
                )
            )
            element.setAccessibilityLabel(
                "\(node.name), \(Self.spoken(node, metric: metric))"
                    + (node.isDir ? ", folder" : "")
                    + (marked == true ? ", marked" : "")
            )
            element.setAccessibilitySelected(state.selected == crumbs)
            elements.append(element)
            if elements.count == Self.accessibleTiles {
                break
            }
        }
        tileElements = elements
        return elements
    }

    /// Say so when what the value says has changed: the directory drawn,
    /// or the selection.
    private func announceValue() {
        let value = accessibilitySummary()
        guard value != announced else {
            return
        }
        let first = announced == nil
        announced = value
        if !first {
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    /// VoiceOver pressed a tile: select it, as a click would.
    fileprivate func pressTile(_ crumbs: [Int]) -> Bool {
        guard state.node(at: crumbs) != nil else {
            return false
        }
        state.select(crumbs)
        return true
    }
}

// MARK: - Dragging source

extension TreemapNSView: NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        TileDragging.operations(context)
    }

    /// Whatever the drag ended in, the press is over. Nothing else is done
    /// here: a destination that moved the file did so itself, and the marks
    /// notice anything gone on their own.
    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        press = nil
        DropHighlight.ownDrag = false
    }
}

// MARK: - A tile for VoiceOver

/// One of the treemap's largest tiles, as VoiceOver finds it: its name and
/// its size, where it is on screen, and pressed to select it.
final class TreemapTileElement: NSAccessibilityElement {
    let crumbs: [Int]
    private weak var treemap: TreemapNSView?

    init(crumbs: [Int], treemap: TreemapNSView) {
        self.crumbs = crumbs
        self.treemap = treemap
        super.init()
        setAccessibilityParent(treemap)
        setAccessibilityRole(.button)
    }

    /// AppKit asks on the main thread, as it asks everything of a view.
    override func accessibilityPerformPress() -> Bool {
        let treemap = treemap
        let crumbs = crumbs
        return MainActor.assumeIsolated {
            treemap?.pressTile(crumbs) ?? false
        }
    }
}
