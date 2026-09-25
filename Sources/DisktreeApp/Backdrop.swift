// The palette's gradients, and the mark drawn in its colours.
//
// MP300 comes as two cards, each a gradient: dusk, Midnight Blue rising
// through Indigo Blue and Sweet Escape into a sky-blue glow, and dawn, a lime
// light over Sun Glint that runs down through mint and turquoise into
// periwinkle and violet. They are the palette's character, and they belong
// where nothing has to be read against them: behind the scanning screen, the
// Full Disk Access sheet and the empty states, and in the app icon. Never
// behind the mosaic or behind text, where a ground that changes from one
// edge to the other would change every contrast on it.
//
// The stops are measured from the palette's swatch card, which shows both
// gradients edge to edge, and are anchored on the palette's own colours
// wherever the card passes through one.
//
// The mark is `assets/disktree.svg`: a treemap with the band a directory
// keeps for its name. The app icon, the top bar's logo and the SVG draw the
// same rectangles in the same colours, which live here so the three cannot
// drift apart.

import SwiftUI

// MARK: - Gradients

/// One of the palette's two gradients: colours at locations from `0` (the
/// top edge) to `1` (the bottom).
public struct Backdrop: Sendable, Hashable {
    /// A colour at a location along the gradient.
    public struct Stop: Sendable, Hashable {
        public var color: HSLA
        public var location: Double

        public init(_ color: HSLA, at location: Double) {
            self.color = color
            self.location = location
        }
    }

    /// In order of location, first at `0` and last at `1`.
    public var stops: [Stop]

    public init(stops: [Stop]) {
        self.stops = stops
    }

    /// The dark card: Midnight Blue at the top, Indigo Blue a little under
    /// halfway, then a softened Sweet Escape, periwinkle and the sky blue at
    /// the foot. The violet is softened because the card's is: at full
    /// strength across a whole region it glares.
    public static let dusk = Backdrop(stops: [
        Stop(MP300.midnightBlue, at: 0),
        Stop(.hex(0x100654), at: 0.17),
        Stop(MP300.indigoBlue, at: 0.45),
        Stop(.hex(0x6137D9), at: 0.6),
        Stop(.hex(0x6873E7), at: 0.78),
        Stop(.hex(0x52B2DB), at: 1),
    ])

    /// The light card: a lime light near the top of Sun Glint, then mint,
    /// a light Fresh Turquoise, the sky blue, periwinkle and a light Sweet
    /// Escape at the foot.
    ///
    /// It starts at Sun Glint itself, not at the lime: the light window is
    /// Sun Glint, and a gradient that opened on lime drew a hard seam where
    /// the top bar met it. The lime comes in a tenth of the way down, still
    /// the card's glow at the top.
    public static let dawn = Backdrop(stops: [
        Stop(MP300.sunGlint, at: 0),
        Stop(.hex(0xE6F4A6), at: 0.1),
        Stop(MP300.sunGlint, at: 0.36),
        Stop(.hex(0xE2F0D8), at: 0.5),
        Stop(.hex(0x83DFD4), at: 0.67),
        Stop(.hex(0x6CB5DD), at: 0.78),
        Stop(.hex(0x7F7FEE), at: 0.89),
        Stop(.hex(0x886BF4), at: 1),
    ])

    /// The colour at `location`, mixed in RGB between the stops either side
    /// of it, as a gradient paints it. Clamped to the ends.
    public func color(at location: Double) -> HSLA {
        guard let first = stops.first, let last = stops.last else {
            return HSLA(h: 0, s: 0, l: 0, a: 0)
        }
        if location <= first.location {
            return first.color
        }
        for (lower, upper) in zip(stops, stops.dropFirst())
        where location <= upper.location {
            let span = upper.location - lower.location
            let t = span > 0 ? (location - lower.location) / span : 1
            return lower.color.mixed(toward: upper.color, by: t)
        }
        return last.color
    }

    /// For SwiftUI's gradients.
    public var gradient: Gradient {
        Gradient(
            stops: stops.map {
                Gradient.Stop(color: $0.color.color, location: $0.location)
            }
        )
    }

    /// The gradient from `start` to `end`: top to bottom unless told, as
    /// the palette's cards run.
    public func linear(
        from start: UnitPoint = .top,
        to end: UnitPoint = .bottom
    ) -> LinearGradient {
        LinearGradient(gradient: gradient, startPoint: start, endPoint: end)
    }

    /// The gradient as a mesh whose left edge runs a little ahead of its
    /// right, so the light rises from the lower left as it does on the
    /// palette's cards, rather than in flat bands. A row of the mesh sits at
    /// every stop: a mesh blends only between its own points, and three rows
    /// would have mixed dawn's mint straight into its violet through grey,
    /// losing the turquoise between them.
    public var mesh: MeshGradient {
        let columns: [Double] = [0, 0.5, 1]
        let rows = stops.map(\.location)
        // How far ahead of the right edge the left one runs: enough to
        // lean the bands, not so much that the ends go missing.
        let lead = 0.12
        var points: [SIMD2<Float>] = []
        var colors: [Color] = []
        for row in rows {
            for column in columns {
                points.append(SIMD2(Float(column), Float(row)))
                colors.append(color(at: row + lead * (0.5 - column)).color)
            }
        }
        return MeshGradient(
            width: columns.count,
            height: rows.count,
            points: points,
            colors: colors
        )
    }
}

/// The appearance's gradient over its whole frame. For grounds that carry
/// no text of their own; put a surface over it for anything to read.
public struct BackdropView: View {
    @Environment(\.theme) private var theme

    public init() {}

    public var body: some View {
        theme.backdrop.mesh
            .accessibilityHidden(true)
    }
}

extension Theme {
    /// The palette's gradient for this appearance: dusk on dark, dawn on
    /// light.
    public var backdrop: Backdrop {
        isDark ? .dusk : .dawn
    }
}

// MARK: - The mark

/// The mark's colours: its body, the scanned root's panel and name band,
/// the two directories inside with their own bands, and the one file.
public struct LogoInk: Sendable, Hashable {
    /// The body, top to bottom.
    public var ground: Backdrop
    /// The scanned root, and its name band across the top.
    public var panel: HSLA
    public var rootBand: HSLA
    /// The large directory on the left, and its band.
    public var directory: HSLA
    public var directoryBand: HSLA
    /// The directory at the top of the right-hand column, and its band.
    public var column: HSLA
    public var columnBand: HSLA
    /// The file at the foot of the right-hand column.
    public var file: HSLA

    /// The app icon's colours, which `scripts/make-icon.swift` and
    /// `assets/disktree.svg` repeat: a body that rises from Indigo Blue
    /// into a violet and a periwinkle glow, the upper half of the dark
    /// card's gradient; the scanned root a Midnight well under a Pear
    /// Spritz name; an Indigo Blue directory under a Sweet Escape band; a
    /// deep turquoise one under a Fresh Turquoise band; a Pear Spritz file.
    ///
    /// The body starts at Indigo Blue, not Midnight: on the dark top bar
    /// and on a dark Dock, which are Midnight or near it, a body that
    /// started there lost its top edge and its sides, and the mark its
    /// silhouette. Indigo stands off Midnight by its colour, and the
    /// Midnight well inside it still reads as the dark card.
    ///
    /// Every colour meets its neighbours far apart in lightness or in hue,
    /// because at 16 px each band is one pixel tall and has only that to
    /// show by. The turquoise directory's body is Fresh Turquoise's own hue
    /// sunk to a quarter lightness: dark enough that the band over it and
    /// the lime file under it stand off it, and still turquoise, where a mix
    /// toward Midnight turned it a steel blue.
    public static let icon = LogoInk(
        ground: Backdrop(stops: [
            .init(MP300.indigoBlue, at: 0),
            .init(.hex(0x6137D9), at: 0.75),
            .init(.hex(0x6873E7), at: 1),
        ]),
        panel: MP300.midnightBlue,
        rootBand: MP300.pearSpritz,
        directory: MP300.indigoBlue,
        directoryBand: MP300.sweetEscape,
        column: HSLA(h: MP300.freshTurquoise.h, s: 0.75, l: 0.25),
        columnBand: MP300.freshTurquoise,
        file: MP300.pearSpritz
    )

    /// The SVG's eight rectangles' colours, back to front, in the order the
    /// top bar's logo lists its blocks: ground, panel, root band, directory,
    /// its band, column, its band, file. The ground is its top colour, for a
    /// drawing that fills each block flat; `DisktreeMark` keeps its
    /// gradient, and is the better way to draw the logo.
    public var blocks: [HSLA] {
        [
            ground.color(at: 0), panel, rootBand, directory, directoryBand,
            column, columnBand, file,
        ]
    }
}

extension Theme {
    /// The mark's colours. The same in both appearances, as an app icon is:
    /// the logo in the top bar is the icon, not a glyph in the text colour.
    public var logo: LogoInk { .icon }
}

/// The mark, drawn to fill its frame (a square frame keeps its
/// proportions): the same rectangles as `assets/disktree.svg`, in
/// `theme.logo`, with the body's gradient.
public struct DisktreeMark: View {
    @Environment(\.theme) private var theme

    public init() {}

    /// One of the SVG's rectangles in its own 64-unit square, and where its
    /// colour sits in `LogoInk.blocks`.
    private struct Block {
        var x: Double
        var y: Double
        var w: Double
        var h: Double
        var layer: Int
    }

    /// Back to front, as the SVG lists them. The ground, layer 0, is drawn
    /// apart, with its gradient.
    private static let blocks = [
        Block(x: 5, y: 5, w: 54, h: 54, layer: 1),
        Block(x: 5, y: 5, w: 54, h: 9, layer: 2),
        Block(x: 8, y: 17, w: 30, h: 39, layer: 3),
        Block(x: 8, y: 17, w: 30, h: 7, layer: 4),
        Block(x: 41, y: 17, w: 15, h: 24, layer: 5),
        Block(x: 41, y: 17, w: 15, h: 6, layer: 6),
        Block(x: 41, y: 44, w: 15, h: 12, layer: 7),
    ]

    public var body: some View {
        let ink = theme.logo
        let colors = ink.blocks
        Canvas { context, size in
            let scale = min(size.width, size.height) / 64
            let square = CGRect(
                x: 0,
                y: 0,
                width: 64 * scale,
                height: 64 * scale
            )
            context.fill(
                Path(square),
                with: .linearGradient(
                    ink.ground.gradient,
                    startPoint: CGPoint(x: square.midX, y: square.minY),
                    endPoint: CGPoint(x: square.midX, y: square.maxY)
                )
            )
            for block in Self.blocks {
                let frame = CGRect(
                    x: block.x * scale,
                    y: block.y * scale,
                    width: block.w * scale,
                    height: block.h * scale
                )
                context.fill(
                    Path(frame),
                    with: .color(colors[block.layer].color)
                )
            }
        }
        .accessibilityHidden(true)
    }
}
