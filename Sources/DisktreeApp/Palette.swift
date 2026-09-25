// Colour that means something.
//
// A tile's hue says what kind of data it is (`Category`); every hue sits at
// one level of lightness and colourfulness, so no block stands out by
// accident, and deeper tiles lift slightly so nesting reads without borders.
// Reclaimable space is a hatch, not a colour, so "what is it" and "can it go"
// are read independently.
//
// The level is set in Oklab, not in HSL. HSL's lightness is arithmetic, not
// perception: at one HSL lightness a blue or a violet looks far darker than
// a lime or a gold, so on the dark card the palette's own indigo and violet
// sank into the ground while bronze and olive, which MP300 does not have,
// covered the map. In Oklab equal numbers look equal, so every hue can stand
// at the same height.
//
// The hues are the palette's family: its indigo, violet, turquoise and lime,
// the sky blue its dark gradient ends in, a gold taken from its cream, and
// one harmonised extension, an orchid-magenta. Documents and everything
// unclassified stay near-neutral, a cream-grey and an indigo-grey, so they
// recede.
//
// One strong colour is kept apart: the highlight, the theme's `warning` (the
// lime on dark, the violet on light). It marks the selection, the main
// action, reclaimable totals and the free space after a removal, and nothing
// else, so the eye goes straight to it. No fill is anywhere near it in
// colourfulness, so a selection ring stands out on any tile.
//
// Lightness and the ground the ages drain into come from the active theme,
// so the mosaic sits inside it, light or dark.

import Darwin
import DisktreeCore

// MARK: - Oklab

/// A colour in Oklab (Björn Ottosson, 2020): a lightness and two colour
/// axes, spaced so that equal steps look like equal steps. The palette sets
/// its levels here, where "the same lightness" means the same to the eye.
public struct Oklab: Sendable, Hashable {
    /// Perceived lightness, from `0` (black) to `1` (white).
    public var l: Double
    /// Green (negative) to red (positive).
    public var a: Double
    /// Blue (negative) to yellow (positive).
    public var b: Double

    public init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }

    /// A lightness, a chroma (how far from grey) and a hue in degrees:
    /// Oklab's polar form, OKLCH.
    public init(l: Double, chroma: Double, hue: Double) {
        let angle = hue * .pi / 180
        self.init(l: l, a: chroma * cos(angle), b: chroma * sin(angle))
    }

    /// How far from grey: `0` for a neutral, about `0.26` for the palette's
    /// most vivid violet.
    public var chroma: Double { (a * a + b * b).squareRoot() }

    /// The hue angle in degrees, `0..<360`: red near 30, yellow near 100,
    /// green near 140, blue near 260.
    public var hue: Double {
        let degrees = atan2(b, a) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// The sRGB colour's Oklab coordinates.
    public init(_ color: HSLA) {
        let rgb = color.toRGB()
        let (r, g, b) = (linear(rgb.r), linear(rgb.g), linear(rgb.b))
        let lms = [
            0.412_221_470_8 * r + 0.536_332_536_3 * g + 0.051_445_992_9 * b,
            0.211_903_498_2 * r + 0.680_699_545_1 * g + 0.107_396_956_6 * b,
            0.088_302_461_9 * r + 0.281_718_837_6 * g + 0.629_978_700_5 * b,
        ].map(cbrt)
        self.init(
            l: 0.210_454_255_3 * lms[0] + 0.793_617_785_0 * lms[1]
                - 0.004_072_046_8 * lms[2],
            a: 1.977_998_495_1 * lms[0] - 2.428_592_205_0 * lms[1]
                + 0.450_593_709_9 * lms[2],
            b: 0.025_904_037_1 * lms[0] + 0.782_771_766_2 * lms[1]
                - 0.808_675_766_0 * lms[2]
        )
    }

    /// Linear sRGB, unclamped: a colour outside the screen's gamut has a
    /// channel below 0 or above 1.
    private var linearRGB: (r: Double, g: Double, b: Double) {
        let l = pow(self.l + 0.396_337_777_4 * a + 0.215_803_757_3 * b, 3)
        let m = pow(self.l - 0.105_561_345_8 * a - 0.063_854_172_8 * b, 3)
        let s = pow(self.l - 0.089_484_177_5 * a - 1.291_485_548_0 * b, 3)
        return (
            4.076_741_662_1 * l - 3.307_711_591_3 * m + 0.230_969_929_2 * s,
            -1.268_438_004_6 * l + 2.609_757_401_1 * m - 0.341_319_396_5 * s,
            -0.004_196_086_3 * l - 0.703_418_614_7 * m + 1.707_614_701_0 * s
        )
    }

    /// Whether a screen can show it: every sRGB channel within `0...1`.
    public var isInGamut: Bool {
        let rgb = linearRGB
        let tolerance = 1e-4
        return [rgb.r, rgb.g, rgb.b].allSatisfy {
            $0 >= -tolerance && $0 <= 1 + tolerance
        }
    }

    /// The sRGB colour, each channel clamped to what a screen can show.
    public var hsla: HSLA {
        let rgb = linearRGB
        return .fromRGB(
            RGBA(r: encoded(rgb.r), g: encoded(rgb.g), b: encoded(rgb.b))
        )
    }

    /// The colour at `l`, `chroma` and `hue`, or, where the screen cannot
    /// show that much colour at that lightness, the most it can. A colour
    /// out of gamut gives up chroma, never lightness or hue: clamping its
    /// channels instead would turn a turquoise toward green and change how
    /// light it looks.
    public static func mapped(l: Double, chroma: Double, hue: Double) -> Oklab {
        let wanted = Oklab(l: l, chroma: chroma, hue: hue)
        if wanted.isInGamut {
            return wanted
        }
        var (inside, outside) = (0.0, chroma)
        // Thirty halvings take the chroma to within a billionth.
        for _ in 0..<30 {
            let middle = (inside + outside) / 2
            if Oklab(l: l, chroma: middle, hue: hue).isInGamut {
                inside = middle
            } else {
                outside = middle
            }
        }
        return Oklab(l: l, chroma: inside, hue: hue)
    }
}

extension HSLA {
    /// This colour's Oklab coordinates.
    public var oklab: Oklab { Oklab(self) }
}

/// An sRGB channel's light, the way the transfer curve undoes it.
private func linear(_ channel: Double) -> Double {
    channel <= 0.040_45
        ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
}

/// A linear channel back through the transfer curve, clamped.
private func encoded(_ channel: Double) -> Double {
    let clamped = min(max(channel, 0), 1)
    return clamped <= 0.003_130_8
        ? 12.92 * clamped : 1.055 * pow(clamped, 1 / 2.4) - 0.055
}

// MARK: - Categories

/// How a category is drawn on one of the two cards.
private struct Tone {
    /// How far its fill sits off the card's common level, in Oklab
    /// lightness.
    var lift: Double
    /// How much colour its fill carries.
    var chroma: Double
    /// Its accent's lightness: the strip and the legend swatch.
    var accent: Double
}

/// A category's hue in degrees on the Oklab wheel, and its tone on each
/// card.
private struct Look {
    var hue: Double
    var dark: Tone
    var light: Tone
    /// Documents and everything unclassified: nearly grey, fill and accent.
    var neutral = false
}

/// The table every category colour comes from.
///
/// The fills stand at one level, but not exactly: a few sit up to 0.03 above
/// or below it. At one lightness, a violet and a blue differ only in how much
/// red they carry, and a magenta and a turquoise only in red against green,
/// which is exactly what a colour-blind eye does not see; a step in
/// lightness is what it does. The steps are chosen so that under protanopia
/// and deuteranopia every two fills still differ (`PaletteTests` holds
/// them), and so that the palette's indigo and violet never sit below the
/// warm hues again. The accents' lightness is spread for the same reason,
/// further, since a legend swatch is where a colour-blind reader looks a
/// category up.
///
/// On the light card, toolchains and caches carry twice the colour: the
/// card's light is lime and turquoise, and those two, the lightest hues,
/// have the room for it.
private func look(_ category: Category) -> Look {
    switch category {
    // Indigo Blue turned toward periwinkle, where it reads as blue.
    case .code:
        Look(
            hue: 270,
            dark: Tone(lift: 0.03, chroma: 0.075, accent: 0.62),
            light: Tone(lift: 0.02, chroma: 0.04, accent: 0.42)
        )
    // The gold of Sun Glint, deepened and turned a little toward amber, as
    // agent scratch always was. Kept quieter than the cool hues on the
    // dark card, which has no warm colour of its own.
    case .agentScratch:
        Look(
            hue: 78,
            dark: Tone(lift: 0, chroma: 0.048, accent: 0.75),
            light: Tone(lift: 0, chroma: 0.04, accent: 0.53)
        )
    // Pear Spritz, a little greener, so a strip is never the highlight.
    case .toolchain:
        Look(
            hue: 130,
            dark: Tone(lift: 0.03, chroma: 0.051, accent: 0.88),
            light: Tone(lift: 0, chroma: 0.072, accent: 0.6)
        )
    // The sky blue the dark gradient ends in.
    case .synced:
        Look(
            hue: 230,
            dark: Tone(lift: 0, chroma: 0.06, accent: 0.72),
            light: Tone(lift: -0.04, chroma: 0.04, accent: 0.48)
        )
    // The extension: an orchid-magenta, between the violet and the rose
    // that means danger, far enough from each.
    case .git:
        Look(
            hue: 345,
            dark: Tone(lift: -0.03, chroma: 0.066, accent: 0.66),
            light: Tone(lift: -0.04, chroma: 0.04, accent: 0.45)
        )
    // Sweet Escape, a little redder, so on the light card, where the
    // violet is the highlight, a strip is never it.
    case .media:
        Look(
            hue: 310,
            dark: Tone(lift: 0.03, chroma: 0.075, accent: 0.84),
            light: Tone(lift: 0, chroma: 0.04, accent: 0.56)
        )
    // Sun Glint's hue with almost no colour: a cream-grey.
    case .documents:
        Look(
            hue: 90,
            dark: Tone(lift: 0, chroma: 0.015, accent: 0.74),
            light: Tone(lift: 0, chroma: 0.01, accent: 0.53),
            neutral: true
        )
    // Fresh Turquoise: what regenerates on its own.
    case .cache:
        Look(
            hue: 186,
            dark: Tone(lift: 0.01, chroma: 0.052, accent: 0.8),
            light: Tone(lift: 0.02, chroma: 0.072, accent: 0.58)
        )
    // Indigo's hue with less still: an indigo-grey.
    case .other:
        Look(
            hue: 285,
            dark: Tone(lift: 0.03, chroma: 0.015, accent: 0.7),
            light: Tone(lift: -0.01, chroma: 0.01, accent: 0.48),
            neutral: true
        )
    }
}

/// Depth as a lightness step: the fifth level and below look alike, since
/// by then the tiles are too small for another step to be seen.
private func step(_ depth: Int) -> Double {
    Double(min(max(depth, 0), 4))
}

// MARK: - Ages

/// The age ramp, newest first: this week, this month, this half-year, this
/// year, older. Each limit is inclusive, in days.
public let ageBuckets: [(limit: Int64, label: String)] = [
    (7, "This week"),
    (30, "This month"),
    (182, "Six months"),
    (365, "This year"),
    (Int64.max, "Older"),
]

/// Which `ageBuckets` entry an age in days falls in.
public func ageBucket(days: Int64) -> Int {
    ageBuckets.firstIndex { days <= $0.limit } ?? ageBuckets.count - 1
}

/// How far colour has drained out of a bucket: `0` for this week, `1` for
/// older.
private func fade(_ bucket: Int) -> Double {
    Double(min(max(bucket, 0), ageBuckets.count - 1)) / 4
}

// MARK: - Fills

extension Theme {
    /// The fill for a tile of `category`, `depth` levels into the view.
    ///
    /// The level is set by what has to read on every fill, at every depth:
    /// a name at 7:1, a size in `labelDim` at 4.5:1, and the highlight's
    /// ring at 3:1. On dark the tiles stand between 0.27 and 0.43 in Oklab
    /// lightness, the deepest as light as a cream size label allows; on
    /// light between 0.93 and 0.8, the deepest as dark as the violet ring
    /// allows.
    public func categoryFill(_ category: Category, depth: Int) -> HSLA {
        let look = look(category)
        let tone = isDark ? look.dark : look.light
        let step = step(depth)
        let level = isDark ? 0.295 + step * 0.025 : 0.905 - step * 0.017
        return Oklab.mapped(
            l: level + tone.lift,
            chroma: tone.chroma,
            hue: look.hue
        ).hsla
    }

    /// The saturated version of a category's hue: the strip over a top-level
    /// directory and the legend swatch. Graphics, so at least 3:1 on the
    /// window and the panel: light on the dark card, deep on the light one.
    public func categoryAccent(_ category: Category) -> HSLA {
        let look = look(category)
        let tone = isDark ? look.dark : look.light
        return Oklab.mapped(
            l: tone.accent,
            chroma: look.neutral ? 0.024 : 0.13,
            hue: look.hue
        ).hsla
    }

    /// The fill for age mode: recent writes carry the theme accent's hue
    /// (violet on dark, indigo on light), and colour drains out of a tile
    /// as it goes untouched, toward the ground. Toward the ground itself,
    /// not toward a grey: the dark card's ground is a navy, and a tile gone
    /// grey on it would stand out again. So the dark ramp is the dark card,
    /// Sweet Escape sinking into Midnight, and the light one runs from a
    /// periwinkle into the cream.
    ///
    /// Each bucket is a long step from the next, in colour and lightness at
    /// once, so "this year" and "older", the stale data worth deleting,
    /// stay apart. Depth lifts a tile far less here than in kind mode: a
    /// lift is a step toward a newer bucket's colour, and a lift as large as
    /// a bucket's step would make a deep old tile read as a newer one.
    public func ageFill(bucket: Int, depth: Int) -> HSLA {
        let fade = fade(bucket)
        let step = step(depth)
        let (l, chroma, drain) =
            isDark
            ? (0.38 - fade * 0.19 + step * 0.008, 0.14, fade * 0.85)
            : (0.8 + fade * 0.06 - step * 0.01, 0.08, fade)
        let fresh = Oklab.mapped(l: l, chroma: chroma, hue: accent.oklab.hue)
        let ground = inset.oklab
        return Oklab(
            l: l,
            a: fresh.a + (ground.a - fresh.a) * drain,
            b: fresh.b + (ground.b - fresh.b) * drain
        ).hsla
    }

    /// The age swatch for the legend: the bucket's colour at a level that
    /// shows on the window, 3:1 or more for the oldest too.
    public func ageAccent(bucket: Int) -> HSLA {
        let fade = fade(bucket)
        return Oklab.mapped(
            l: isDark ? 0.74 - fade * 0.14 : 0.45 + fade * 0.13,
            chroma: 0.02 + (1 - fade) * 0.16,
            hue: accent.oklab.hue
        ).hsla
    }

    /// The one strong colour: selection, the main action, what can be had
    /// back.
    public var highlight: HSLA { warning }

    /// Text on a filled highlight: the dark card's own ground on the lime
    /// (16:1), the lightest cream on the violet (6.4:1). Ink on the violet
    /// would be 3:1.
    public var onHighlight: HSLA { isDark ? background : surface }

    /// The diagonal hatch over reclaimable space: quiet enough to leave the
    /// hue readable, visible on every fill; stronger under Increase
    /// Contrast.
    public var hatchColor: HSLA {
        isDark
            ? bright.opacity(increaseContrast ? 0.24 : 0.16)
            : foreground.opacity(increaseContrast ? 0.26 : 0.18)
    }

    /// A tile's name on top of its fill, at every depth. The first level
    /// reads strongest by its bold face, not by a stronger colour.
    public func labelColor(depth _: Int) -> HSLA {
        bright
    }

    /// A tile's size, and a name the find text leaves out: the name's
    /// colour, dimmer. Caption-sized text, so 4.5:1 on every fill, not the
    /// 3:1 half the name's opacity gave; under Increase Contrast nearly the
    /// name's own.
    public var labelDim: HSLA {
        bright.opacity(increaseContrast ? 0.85 : isDark ? 0.7 : 0.65)
    }

    /// A filled button's ground while it is pointed at or pressed.
    ///
    /// Fading the fill, as a translucent state would, moves it toward the
    /// ground behind it, and on these cards that is toward the label: a
    /// cream label on the violet fell to 3.2:1 when pressed, and a Midnight
    /// one on the dark accent to 3.5:1. This moves the fill away from its
    /// label instead, toward Midnight Blue under a light label and toward
    /// white under a dark one, so a state only ever adds contrast.
    public func buttonFill(
        _ fill: HSLA,
        label: HSLA,
        hovering: Bool,
        pressed: Bool
    ) -> HSLA {
        let share = pressed ? 0.32 : hovering ? 0.18 : 0
        let away =
            label.l > fill.l ? MP300.midnightBlue : HSLA(h: 0, s: 0, l: 1)
        return fill.mixed(toward: away, by: share)
    }

    /// The wash under a button whose label is set in `color` itself, such
    /// as the review button's highlight: light enough at every state that
    /// the label keeps 4.5:1 over it.
    public func buttonTint(
        _ color: HSLA,
        hovering: Bool,
        pressed: Bool
    ) -> HSLA {
        color.opacity(pressed ? 0.18 : hovering ? 0.13 : 0.08)
    }
}

extension HSLA {
    /// Linear interpolation toward `target`, in RGB: interpolating hue would
    /// drag a colour around the wheel on its way to a grey. `t` is clamped
    /// to `0...1`.
    public func mixed(toward target: HSLA, by t: Double) -> HSLA {
        let t = min(max(t, 0), 1)
        let lerp = { (from: Double, to: Double) in from + (to - from) * t }
        let (from, to) = (toRGB(), target.toRGB())
        return .fromRGB(
            RGBA(
                r: lerp(from.r, to.r),
                g: lerp(from.g, to.g),
                b: lerp(from.b, to.b),
                a: lerp(from.a, to.a)
            )
        )
    }
}
