import DisktreeCore
import Foundation
import Testing

@testable import DisktreeApp

// What the palette promises about reading: every piece of text on every
// ground it is set on, every name and size on every tile, the selection ring
// on every tile, the hatch on every fill, and that a colour-blind eye can
// still tell the categories apart. The ratios are WCAG 2's: 4.5:1 for text,
// 3:1 for large text and for graphics a person has to see (a ring, a bar, a
// swatch, a control's outline). Both cards are checked, in their ordinary
// and their Increase Contrast forms, and they are what the system theme
// returns, so this is what a Mac shows.
//
// The painter's own derivations are mirrored here from the theme's API: a
// tile's name is `labelColor(depth:)`, a size or a filtered-out name is
// `labelDim` (today the painter still draws it at half the name's opacity,
// which is held to the old 3:1 until it moves), a marked tile is
// `markedFill`. Each check says which.

/// The measures the palette is held to.
enum Legibility {
    /// An sRGB channel's light.
    private static func linear(_ channel: Double) -> Double {
        channel <= 0.040_45
            ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    /// A linear channel back through the transfer curve, clamped.
    private static func encoded(_ channel: Double) -> Double {
        let clamped = min(max(channel, 0), 1)
        return clamped <= 0.003_130_8
            ? 12.92 * clamped : 1.055 * pow(clamped, 1 / 2.4) - 0.055
    }

    /// WCAG relative luminance of an opaque colour.
    static func luminance(_ color: HSLA) -> Double {
        let rgb = color.toRGB()
        let (r, g, b) = (linear(rgb.r), linear(rgb.g), linear(rgb.b))
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// The WCAG contrast ratio of `color` set on `ground`, from 1 to 21.
    /// A translucent colour is flattened onto the ground first, as it would
    /// be drawn.
    static func ratio(_ color: HSLA, on ground: HSLA) -> Double {
        let top = color.a < 1 ? color.composited(over: ground) : color
        let (a, b) = (luminance(top), luminance(ground))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// CIELAB, D65: lightness and the two colour axes, as the eye weighs
    /// them rather than as the screen mixes them.
    static func lab(_ color: HSLA) -> (l: Double, a: Double, b: Double) {
        let rgb = color.toRGB()
        let (r, g, b) = (linear(rgb.r), linear(rgb.g), linear(rgb.b))
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.950_47
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.088_83
        let f = { (t: Double) in
            t > 0.008_856 ? cbrt(t) : 7.787 * t + 16.0 / 116
        }
        let (fx, fy, fz) = (f(x), f(y), f(z))
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// How different two colours look (CIE76 ΔE): about 2 is the smallest
    /// difference a person notices side by side, 10 is plain, 50 is a
    /// different colour altogether.
    static func difference(_ left: HSLA, _ right: HSLA) -> Double {
        let (p, q) = (lab(left), lab(right))
        return
            ((p.l - q.l) * (p.l - q.l) + (p.a - q.a) * (p.a - q.a)
            + (p.b - q.b) * (p.b - q.b)).squareRoot()
    }

    /// How different two colours look, by CIEDE2000, which corrects CIE76
    /// where it misjudges: saturated colours, blues, and dark colours whose
    /// lightness differences the eye weighs less. About 1 is the smallest
    /// difference a person notices, 2 is visible side by side, 5 is plain.
    static func difference2000(_ left: HSLA, _ right: HSLA) -> Double {
        let (p, q) = (lab(left), lab(right))
        let degrees = 180 / Double.pi
        let chroma =
            ((p.a * p.a + p.b * p.b).squareRoot()
                + (q.a * q.a + q.b * q.b).squareRoot()) / 2
        let pow7 = pow(chroma, 7)
        let g = 0.5 * (1 - (pow7 / (pow7 + pow(25, 7))).squareRoot())
        let (a1, a2) = ((1 + g) * p.a, (1 + g) * q.a)
        let (c1, c2) = (
            (a1 * a1 + p.b * p.b).squareRoot(),
            (a2 * a2 + q.b * q.b).squareRoot()
        )
        let hue = { (a: Double, b: Double) -> Double in
            guard a != 0 || b != 0 else { return 0 }
            let angle = atan2(b, a) * degrees
            return angle < 0 ? angle + 360 : angle
        }
        let (h1, h2) = (hue(a1, p.b), hue(a2, q.b))
        var turn = h2 - h1
        if c1 * c2 == 0 {
            turn = 0
        } else if turn > 180 {
            turn -= 360
        } else if turn < -180 {
            turn += 360
        }
        let deltaL = q.l - p.l
        let deltaC = c2 - c1
        let deltaH = 2 * (c1 * c2).squareRoot() * sin(turn / 2 / degrees)
        let meanL = (p.l + q.l) / 2
        let meanC = (c1 + c2) / 2
        let meanH: Double =
            if c1 * c2 == 0 {
                h1 + h2
            } else if abs(h1 - h2) <= 180 {
                (h1 + h2) / 2
            } else if h1 + h2 < 360 {
                (h1 + h2 + 360) / 2
            } else {
                (h1 + h2 - 360) / 2
            }
        let t =
            1 - 0.17 * cos((meanH - 30) / degrees)
            + 0.24 * cos(2 * meanH / degrees)
            + 0.32 * cos((3 * meanH + 6) / degrees)
            - 0.2 * cos((4 * meanH - 63) / degrees)
        let rotation = 30 * exp(-pow((meanH - 275) / 25, 2))
        let meanC7 = pow(meanC, 7)
        let rc = 2 * (meanC7 / (meanC7 + pow(25, 7))).squareRoot()
        let offset = (meanL - 50) * (meanL - 50)
        let sl = 1 + 0.015 * offset / (20 + offset).squareRoot()
        let sc = 1 + 0.045 * meanC
        let sh = 1 + 0.015 * meanC * t
        let rt = -sin(2 * rotation / degrees) * rc
        let (l, c, h) = (deltaL / sl, deltaC / sc, deltaH / sh)
        return (l * l + c * c + h * h + rt * c * h).squareRoot()
    }

    /// The two commonest colour-blindnesses, which between them are most
    /// of the one man in twelve who has one.
    enum Deficiency: CaseIterable {
        /// Red-blind: no long-wavelength cones.
        case protanopia
        /// Green-blind: no medium-wavelength cones.
        case deuteranopia
    }

    /// `color` as someone with `deficiency` sees it, at full severity, by
    /// Machado, Oliveira and Fernandes (2009), in linear RGB.
    static func simulate(_ color: HSLA, _ deficiency: Deficiency) -> HSLA {
        let matrix: [[Double]] =
            switch deficiency {
            case .protanopia:
                [
                    [0.152_286, 1.052_583, -0.204_868],
                    [0.114_503, 0.786_281, 0.099_216],
                    [-0.003_882, -0.048_116, 1.051_998],
                ]
            case .deuteranopia:
                [
                    [0.367_322, 0.860_646, -0.227_968],
                    [0.280_085, 0.672_501, 0.047_413],
                    [-0.011_820, 0.042_940, 0.968_881],
                ]
            }
        let rgb = color.toRGB()
        let light = [linear(rgb.r), linear(rgb.g), linear(rgb.b)]
        let seen = matrix.map { row in
            encoded(zip(row, light).map(*).reduce(0, +))
        }
        return .fromRGB(RGBA(r: seen[0], g: seen[1], b: seen[2]))
    }
}

/// Both cards, in their ordinary and their Increase Contrast forms.
private let cards: [(name: String, theme: Theme)] = [
    ("dark", .dark), ("light", .light),
    ("dark, more contrast", .darkHighContrast),
    ("light, more contrast", .lightHighContrast),
]

/// Every fill the mosaic paints a readable tile in: each category and each
/// age bucket, at every depth a fill distinguishes.
private func fills(_ theme: Theme) -> [(what: String, fill: HSLA)] {
    let depths = 0..<5
    let kinds = Category.allCases.flatMap { category in
        depths.map {
            ("\(category) at \($0)", theme.categoryFill(category, depth: $0))
        }
    }
    let ages = ageBuckets.indices.flatMap { bucket in
        depths.map {
            ("age \(bucket) at \($0)", theme.ageFill(bucket: bucket, depth: $0))
        }
    }
    return kinds + ages
}

@Test func textReadsOnEveryGround() {
    for (name, theme) in cards {
        let grounds = [
            ("background", theme.background), ("surface", theme.surface),
            ("inset", theme.inset),
        ]
        for (groundName, ground) in grounds {
            for (tokenName, token) in [
                ("foreground", theme.foreground),
                ("secondary", theme.secondary), ("bright", theme.bright),
            ] {
                let ratio = Legibility.ratio(token, on: ground)
                #expect(ratio >= 4.5, "\(name) \(tokenName) on \(groundName)")
            }
        }
        // Eyebrows and captions set the dim text lighter still, at 70%:
        // small labels over a figure, which 3:1 keeps legible, and which
        // reach text's 4.5:1 for someone who asked for more contrast.
        let floor = theme.increaseContrast ? 4.5 : 3
        for ground in [theme.background, theme.surface] {
            let eyebrow = theme.secondary.opacity(0.7)
            #expect(Legibility.ratio(eyebrow, on: ground) >= floor, "\(name)")
        }
    }
}

@Test func statusColoursReadAsText() {
    // Each of these is text somewhere: the keys in the help and a link
    // (accent), reclaimable totals and the free space after a removal
    // (highlight), a failure (danger), space given back (success), what
    // could not be read (caution). On the mosaic's ground, which is a well
    // for figures and rings rather than for prose, they only need to show
    // as graphics. A chip sets its word over a tenth of its own colour, so
    // that wash is its ground.
    for (name, theme) in cards {
        let tokens = [
            ("accent", theme.accent), ("highlight", theme.highlight),
            ("danger", theme.danger), ("success", theme.success),
            ("caution", theme.caution),
        ]
        for (tokenName, token) in tokens {
            for ground in [theme.background, theme.surface] {
                #expect(
                    Legibility.ratio(token, on: ground) >= 4.5,
                    "\(name) \(tokenName) on \(ground)"
                )
                let chip = token.opacity(0.1).composited(over: ground)
                #expect(
                    Legibility.ratio(token, on: chip) >= 4.5,
                    "\(name) \(tokenName) in a chip on \(ground)"
                )
            }
            #expect(
                Legibility.ratio(token, on: theme.inset) >= 3,
                "\(name) \(tokenName) on the inset"
            )
        }
    }
}

@Test func aFilledButtonsLabelReads() {
    for (name, theme) in cards {
        // The main action: the highlight, labelled in `onHighlight`; a
        // primary button: the accent, labelled in the window's colour. At
        // rest, pointed at and pressed, over the panel they sit on, and a
        // state never takes contrast away.
        let buttons = [
            ("highlight", theme.highlight, theme.onHighlight),
            ("primary", theme.accent, theme.background),
        ]
        for (kind, fill, label) in buttons {
            let rest = Legibility.ratio(label, on: fill)
            #expect(rest >= 4.5, "\(name) \(kind) button")
            for (hovering, pressed) in [(true, false), (false, true)] {
                let state = theme.buttonFill(
                    fill,
                    label: label,
                    hovering: hovering,
                    pressed: pressed
                )
                let ratio = Legibility.ratio(label, on: state)
                #expect(ratio >= rest, "\(name) \(kind) \(pressed)")
                // And it is a visible change.
                #expect(
                    Legibility.difference2000(state, fill) >= 2.5,
                    "\(name) \(kind) \(pressed)"
                )
            }
        }
        // A button labelled in the highlight itself, over its wash.
        for (hovering, pressed) in [
            (false, false), (true, false), (false, true),
        ] {
            let wash = theme.buttonTint(
                theme.highlight,
                hovering: hovering,
                pressed: pressed
            )
            #expect(
                Legibility.ratio(
                    theme.highlight,
                    on: wash.composited(over: theme.surface)
                ) >= 4.5,
                "\(name) review button \(hovering) \(pressed)"
            )
        }
    }
}

@Test func namesAndSizesReadOnEveryTile() {
    for (name, theme) in cards {
        for (what, fill) in fills(theme) {
            for depth in 0..<5 {
                let label = theme.labelColor(depth: depth)
                #expect(
                    Legibility.ratio(label, on: fill) >= 7,
                    "\(name): a name at \(depth) on \(what)"
                )
            }
            // A size and a filtered-out name: caption text, 4.5:1.
            #expect(
                Legibility.ratio(theme.labelDim, on: fill) >= 4.5,
                "\(name): a size on \(what)"
            )
            // What the painter drew before it adopted `labelDim`: half the
            // name's colour, which keeps the 3:1 it always kept.
            let half = theme.labelColor(depth: 1).opacity(0.5)
            #expect(
                Legibility.ratio(half, on: fill) >= 3,
                "\(name): a half-strength size on \(what)"
            )
        }
    }
}

@Test func namesAndSizesReadOnTheCushionAndUnderTheLift() {
    // What the painter makes of a tile's ground where its name and size
    // are set, not only the flat fill: the cushion, at any height (a short
    // tile's words reach its lower half), and the hover's lift as much of
    // it as reaches the words' band. On the dark card a cushion lit toward
    // white, or a lift over the words, took captions under 4.5:1 and
    // names under 7:1 while the flat fills above still passed.
    let white = HSLA(h: 0, s: 0, l: 1)
    for (name, theme) in cards {
        let colors = MosaicColors(theme: theme)
        let lift = colors.lift.hsla.a * colors.bandLift
        for (what, fill) in fills(theme) {
            for step in 0...20 {
                let shaded = colors.cushion.shade(fill, at: Double(step) / 20)
                let lifted = shaded.mixed(toward: white, by: lift)
                for (how, ground) in [("at rest", shaded), ("lifted", lifted)] {
                    let place = "\(name): \(what), \(step * 5)% down, \(how)"
                    #expect(
                        Legibility.ratio(theme.labelColor(depth: 1), on: ground)
                            >= 7,
                        "a name on \(place)"
                    )
                    #expect(
                        Legibility.ratio(theme.labelDim, on: ground) >= 4.5,
                        "a size on \(place)"
                    )
                }
            }
        }
    }
}

@Test func namesReadInsideAMarkedDirectory() {
    // Inside a marked directory every tile keeps its kind, tinted toward
    // the marked fill, and its name and size are set as anywhere else:
    // they read on the tint, cushioned, as on the fill.
    for (name, theme) in cards {
        let colors = MosaicColors(theme: theme)
        for (what, fill) in fills(theme) {
            let tinted = MosaicColors.insideMark(fill, theme: theme)
            for step in 0...20 {
                let ground = colors.cushion.shade(tinted, at: Double(step) / 20)
                let place = "\(name): inside a mark, \(what), \(step * 5)%"
                #expect(
                    Legibility.ratio(theme.labelColor(depth: 1), on: ground)
                        >= 7,
                    "a name on \(place)"
                )
                #expect(
                    Legibility.ratio(theme.labelDim, on: ground) >= 4.5,
                    "a size on \(place)"
                )
            }
            // Still a tile of its own colour, not the marked one.
            #expect(
                Legibility.difference2000(tinted, theme.markedFill) >= 3,
                "\(name): \(what) inside a mark"
            )
        }
    }
}

@Test func theSelectionRingStandsOutOnEveryTile() {
    // WCAG's 3:1 for a focus or selection indicator, on every fill, and on
    // the dark card twice that: lime on its deep fills is far apart in
    // lightness. And a difference in colour far past anything a tile could
    // be mistaken for.
    for (name, theme) in cards {
        let floor = theme.isDark ? 6.0 : 3
        for (what, fill) in fills(theme) {
            #expect(
                Legibility.ratio(theme.highlight, on: fill) >= floor,
                "\(name): the ring on \(what)"
            )
            #expect(
                Legibility.difference(theme.highlight, fill) >= 50,
                "\(name): the ring on \(what)"
            )
        }
    }
}

@Test func noCategoryLooksSelected() {
    // A legend swatch or a top-level strip in the highlight's colour would
    // read as a selection. Toolchains share the lime's family on dark and
    // media the violet's on light, so those two are the close ones; each
    // stays a plainly different colour.
    for (name, theme) in cards {
        for category in Category.legend {
            let accent = theme.categoryAccent(category)
            #expect(
                Legibility.difference(accent, theme.highlight) >= 20,
                "\(name): \(category)"
            )
        }
    }
}

@Test func categorySwatchesShowOnTheirGrounds() {
    // Graphics: the legend's swatches on the window, the bars and strips in
    // the side panel on the surface, and the age legend's swatches, the
    // oldest included.
    for (name, theme) in cards {
        let swatches =
            Category.legend.map { theme.categoryAccent($0) }
            + ageBuckets.indices.map { theme.ageAccent(bucket: $0) }
        for swatch in swatches {
            for ground in [theme.background, theme.surface] {
                #expect(
                    Legibility.ratio(swatch, on: ground) >= 3,
                    "\(name): \(swatch)"
                )
            }
        }
    }
}

@Test func theGroundShowsBetweenTiles() {
    // The gaps between tiles are the mosaic's only borders. A pale gold on
    // the cream is the closest pair; it still has to be told apart.
    for (name, theme) in cards {
        for category in Category.allCases {
            let fill = theme.categoryFill(category, depth: 0)
            #expect(
                Legibility.difference(fill, theme.inset) >= 5,
                "\(name): \(category)"
            )
        }
    }
}

@Test func theHatchShowsOnEveryFill() {
    for (name, theme) in cards {
        let floor = theme.increaseContrast ? 1.5 : 1.3
        for (what, fill) in fills(theme) {
            let hatched = theme.hatchColor.composited(over: fill)
            #expect(
                Legibility.ratio(hatched, on: fill) >= floor,
                "\(name): the hatch on \(what)"
            )
        }
    }
}

@Test func aMarkedTileReadsAsMarked() {
    // The painter fills a marked tile, and everything inside it, with
    // `markedFill`, rings it and names it in `danger`. A tile inside has no
    // ring of its own, so the fill alone has to say "marked": far from
    // every category and age fill at every depth, for a colour-blind eye
    // too.
    for (name, theme) in cards {
        let fill = theme.markedFill
        #expect(Legibility.ratio(theme.danger, on: fill) >= 4.5, "\(name)")
        #expect(Legibility.ratio(theme.bright, on: fill) >= 7, "\(name)")
        #expect(Legibility.ratio(theme.labelDim, on: fill) >= 4.5, "\(name)")
        #expect(Legibility.ratio(theme.highlight, on: fill) >= 3, "\(name)")
        // And it is still a tile, not a hole in the ground.
        #expect(Legibility.difference(fill, theme.inset) >= 5, "\(name)")
        for (what, other) in fills(theme) {
            #expect(
                Legibility.difference2000(fill, other) >= 8,
                "\(name): marked looks like \(what)"
            )
            for deficiency in Legibility.Deficiency.allCases {
                let seen = Legibility.difference2000(
                    Legibility.simulate(fill, deficiency),
                    Legibility.simulate(other, deficiency)
                )
                #expect(seen >= 4, "\(name) \(deficiency): \(what)")
            }
        }
    }
}

@Test func controlsShowTheirEdges() {
    // A control's outline is the only edge an unchecked box, an outline
    // button or a field has: 3:1 on the window and on the panel. Under
    // Increase Contrast the surfaces' own outline reaches it too.
    for (name, theme) in cards {
        for ground in [theme.background, theme.surface] {
            #expect(
                Legibility.ratio(theme.controlBorder, on: ground) >= 3,
                "\(name) \(ground)"
            )
            if theme.increaseContrast {
                #expect(
                    Legibility.ratio(theme.border, on: ground) >= 3,
                    "\(name) \(ground)"
                )
            }
        }
    }
}

@Test func colourBlindReadersCanTellTheLegendApart() {
    // The legend is where a category is looked up, so its swatches differ
    // plainly for everyone and still clearly under protanopia and
    // deuteranopia. The accents' lightness is spread for this: at one
    // lightness a violet and a blue differ only in red.
    for (name, theme) in cards {
        let accents = Category.legend.map { ($0, theme.categoryAccent($0)) }
        for (index, (left, one)) in accents.enumerated() {
            for (right, other) in accents[(index + 1)...] {
                #expect(
                    Legibility.difference2000(one, other) >= 12,
                    "\(name): \(left) and \(right)"
                )
                for deficiency in Legibility.Deficiency.allCases {
                    let seen = Legibility.difference2000(
                        Legibility.simulate(one, deficiency),
                        Legibility.simulate(other, deficiency)
                    )
                    #expect(
                        seen >= 5, "\(name) \(deficiency): \(left) \(right)")
                }
            }
        }
    }
}

@Test func colourBlindReadersCanTellFillsApart() {
    // The fills stand at one level, so they can only differ a little for a
    // colour-blind eye; they still differ, every pair past what is seen
    // side by side, which the level's small lightness steps are for.
    for (name, theme) in cards {
        let fills = Category.allCases.map {
            ($0, theme.categoryFill($0, depth: 0))
        }
        for (index, (left, one)) in fills.enumerated() {
            for (right, other) in fills[(index + 1)...] {
                #expect(
                    Legibility.difference2000(one, other) >= 6,
                    "\(name): \(left) and \(right)"
                )
                for deficiency in Legibility.Deficiency.allCases {
                    let seen = Legibility.difference2000(
                        Legibility.simulate(one, deficiency),
                        Legibility.simulate(other, deficiency)
                    )
                    #expect(
                        seen >= 2, "\(name) \(deficiency): \(left) \(right)")
                }
            }
        }
    }
}

@Test func ageBucketsStayApart() {
    // Side by side at one depth, two neighbouring buckets are plainly
    // different; at any two depths they are still told apart, since depth
    // lifts a tile toward the newer colour only a little; buckets further
    // apart than neighbours are never close. "This year" against "older"
    // matters most: the stale data is what is worth deleting.
    for (name, theme) in cards {
        let ramp = ageBuckets.indices.map { bucket in
            (0..<5).map { theme.ageFill(bucket: bucket, depth: $0) }
        }
        for (newer, older) in zip(ramp.indices, ramp.indices.dropFirst()) {
            for depth in 0..<5 {
                #expect(
                    Legibility.difference2000(
                        ramp[newer][depth],
                        ramp[older][depth]
                    ) >= 3.5,
                    "\(name): buckets \(newer) and \(older) at \(depth)"
                )
            }
        }
        for (first, row) in ramp.enumerated() {
            for (second, other) in ramp.enumerated() where second > first {
                let floor = second == first + 1 ? 2.0 : 5
                for one in row {
                    for two in other {
                        #expect(
                            Legibility.difference2000(one, two) >= floor,
                            "\(name): buckets \(first) and \(second)"
                        )
                    }
                }
            }
        }
    }
}
