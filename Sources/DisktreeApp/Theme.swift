// The theme every screen and the mosaic draw with.
//
// On Omarchy the app took its colours from the active Omarchy theme through
// gpui-omarchy. On a Mac it has a palette of its own: MP300, by Alex
// Cristache, six colours from a midnight blue through indigo and violet to
// turquoise, a lime and a cream. It still follows the system's light or dark
// appearance, but not the accent colour chosen in System Settings: one
// palette, drawn the same on every Mac, is what makes the app recognisable.
// The tokens keep gpui-omarchy's names and roles, so palette maths and the
// screens read exactly as they did; only where the values come from changed.
//
// Colours are HSLA, as in GPUI, because the palette reasons in hue, saturation
// and lightness: "every hue at the same muted level" is a statement about `s`
// and `l`, not about red, green and blue.

import AppKit
import SwiftUI

/// A colour as hue, saturation, lightness and alpha, each in `0...1`.
public struct HSLA: Sendable, Hashable, CustomStringConvertible {
    public var h: Double
    public var s: Double
    public var l: Double
    public var a: Double

    public init(h: Double, s: Double, l: Double, a: Double = 1) {
        self.h = h
        self.s = s
        self.l = l
        self.a = a
    }

    /// `0xRRGGBB`, the way themes write their colours.
    public static func hex(_ value: UInt32, alpha: Double = 1) -> HSLA {
        let channel = { (shift: UInt32) in
            Double((value >> shift) & 0xFF) / 255
        }
        return fromRGB(
            RGBA(r: channel(16), g: channel(8), b: channel(0), a: alpha)
        )
    }

    /// The same colour with its alpha scaled by `factor`: GPUI's `opacity`,
    /// which multiplies rather than replaces, so a translucent token stays
    /// proportionally translucent.
    public func opacity(_ factor: Double) -> HSLA {
        HSLA(h: h, s: s, l: l, a: a * min(max(factor, 0), 1))
    }

    /// The same colour at exactly `alpha`.
    public func withAlpha(_ alpha: Double) -> HSLA {
        HSLA(h: h, s: s, l: l, a: alpha)
    }

    /// sRGB channels. The sector arithmetic is GPUI's, so a colour ported
    /// from the Rust lands on the same pixel values.
    public func toRGB() -> RGBA {
        let chroma = (1 - abs(2 * l - 1)) * s
        let x =
            chroma * (1 - abs((h * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - chroma / 2
        let (cm, xm) = (chroma + m, x + m)
        let (r, g, b) =
            switch Int((h * 6).rounded(.down)) {
            case 0, 6: (cm, xm, m)
            case 1: (xm, cm, m)
            case 2: (m, cm, xm)
            case 3: (m, xm, cm)
            case 4: (xm, m, cm)
            default: (cm, m, xm)
            }
        return RGBA(r: clamp01(r), g: clamp01(g), b: clamp01(b), a: a)
    }

    /// The HSLA for sRGB channels. A grey has no hue: it comes back as `0`,
    /// as GPUI's does.
    public static func fromRGB(_ rgb: RGBA) -> HSLA {
        let high = max(rgb.r, rgb.g, rgb.b)
        let low = min(rgb.r, rgb.g, rgb.b)
        let delta = high - low
        let l = (high + low) / 2
        let s =
            if l == 0 || l == 1 {
                0.0
            } else if l < 0.5 {
                delta / (2 * l)
            } else {
                delta / (2 - 2 * l)
            }
        let h: Double
        if delta == 0 {
            h = 0
        } else if high == rgb.r {
            let sector = ((rgb.g - rgb.b) / delta)
                .truncatingRemainder(dividingBy: 6)
            h = (sector < 0 ? sector + 6 : sector) / 6
        } else if high == rgb.g {
            h = ((rgb.b - rgb.r) / delta + 2) / 6
        } else {
            h = ((rgb.r - rgb.g) / delta + 4) / 6
        }
        return HSLA(h: h, s: s, l: l, a: rgb.a)
    }

    /// This colour painted over `ground`, as one opaque-where-the-ground-is
    /// colour: what a translucent token (a quiet fill, the hatch, a dimmed
    /// name) really looks like where it is drawn, which is what its contrast
    /// has to be measured on.
    public func composited(over ground: HSLA) -> HSLA {
        let (top, bottom) = (toRGB(), ground.toRGB())
        let alpha = top.a + bottom.a * (1 - top.a)
        guard alpha > 0 else { return HSLA(h: 0, s: 0, l: 0, a: 0) }
        let blend = { (upper: Double, lower: Double) in
            (upper * top.a + lower * bottom.a * (1 - top.a)) / alpha
        }
        return .fromRGB(
            RGBA(
                r: blend(top.r, bottom.r),
                g: blend(top.g, bottom.g),
                b: blend(top.b, bottom.b),
                a: alpha
            )
        )
    }

    /// For CoreGraphics: the mosaic paints with these.
    public var cgColor: CGColor {
        let rgb = toRGB()
        return CGColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: rgb.a)
    }

    /// For AppKit: the window background and attributed text.
    public var nsColor: NSColor {
        let rgb = toRGB()
        return NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: rgb.a)
    }

    /// For SwiftUI: every widget.
    public var color: Color {
        let rgb = toRGB()
        return Color(
            .sRGB,
            red: rgb.r,
            green: rgb.g,
            blue: rgb.b,
            opacity: rgb.a
        )
    }

    public var description: String {
        String(format: "hsla(%.3f, %.3f, %.3f, %.3f)", h, s, l, a)
    }
}

/// sRGB channels, each in `0...1`.
public struct RGBA: Sendable, Hashable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }
}

private func clamp01(_ value: Double) -> Double {
    min(max(value, 0), 1)
}

/// What a message is about, for its colour: gpui-omarchy's alert status.
public enum Status: Sendable, Hashable {
    case neutral
    case success
    case warning
    case error
}

/// The tokens the screens and the mosaic draw with: gpui-omarchy's, by name
/// and by role, and three of the palette's own (`caution`, `markedFill`,
/// `increaseContrast`).
///
/// The content tokens (`background` through `border`, and the status colours)
/// are opaque. The four quiet tokens (`divider`, `controlBorder`,
/// `hoverFill`, `normalFill`) are translucent, as gpui-omarchy derives them,
/// so one value reads on the window, on a surface and on the mosaic's ground
/// alike.
public struct Theme: Sendable, Hashable {
    /// The window: title strip, key bar, dialogs' scrim.
    public var background: HSLA
    /// A raised region: the side panel, menus, the review summary.
    public var surface: HSLA
    /// A recessed region: the mosaic's ground, key caps, the scanning well.
    public var inset: HSLA
    /// Body text.
    public var foreground: HSLA
    /// Dim text: labels, captions, metadata. The most used colour here.
    public var secondary: HSLA
    /// The strongest text: names and numbers worth reading first.
    public var bright: HSLA
    /// An outline around a surface or a key cap.
    public var border: HSLA
    /// A rule between regions.
    public var divider: HSLA
    /// The outline of a control at rest.
    public var controlBorder: HSLA
    /// Under a hovered or current row.
    public var hoverFill: HSLA
    /// Under a control at rest: a field, a checkbox.
    public var normalFill: HSLA
    /// Focus and progress: the palette's violet on dark, its indigo on
    /// light.
    public var accent: HSLA
    /// The highlight: selection, the main action, what can be had back. The
    /// name is gpui-omarchy's, from when it was amber; here it is the
    /// palette's lime on dark and its violet on light.
    public var warning: HSLA
    /// Removal and failure.
    public var danger: HSLA
    /// Space given back, a clean checkout.
    public var success: HSLA
    /// Something to look at, not an error: what could not be read, what a
    /// removal kept back, a notice that asks for care. Its own amber,
    /// because `warning` became the highlight when it stopped being amber,
    /// and a lime or a violet "unreadable" reads as "go" and competes with
    /// the selection.
    public var caution: HSLA
    /// Under a marked tile and everything inside it. Its own colour, not
    /// the ground tinted toward `danger`: a tint of a rose on the navy
    /// lands among the violets and magentas the categories use, and a tile
    /// inside a marked directory has no ring of its own to tell it apart.
    public var markedFill: HSLA
    /// Fills lift toward the light on a dark theme and sink toward the ink
    /// on a light one; the palette branches on this.
    public var isDark: Bool
    /// The user asked for more contrast (Increase Contrast in System
    /// Settings, or a high-contrast appearance): quiet tokens are stronger,
    /// and so are dim labels and the hatch.
    public var increaseContrast: Bool

    /// A theme from every token.
    public init(
        background: HSLA,
        surface: HSLA,
        inset: HSLA,
        foreground: HSLA,
        secondary: HSLA,
        bright: HSLA,
        border: HSLA,
        divider: HSLA,
        controlBorder: HSLA,
        hoverFill: HSLA,
        normalFill: HSLA,
        accent: HSLA,
        warning: HSLA,
        danger: HSLA,
        success: HSLA,
        caution: HSLA,
        markedFill: HSLA,
        isDark: Bool,
        increaseContrast: Bool
    ) {
        self.background = background
        self.surface = surface
        self.inset = inset
        self.foreground = foreground
        self.secondary = secondary
        self.bright = bright
        self.border = border
        self.divider = divider
        self.controlBorder = controlBorder
        self.hoverFill = hoverFill
        self.normalFill = normalFill
        self.accent = accent
        self.warning = warning
        self.danger = danger
        self.success = success
        self.caution = caution
        self.markedFill = markedFill
        self.isDark = isDark
        self.increaseContrast = increaseContrast
    }

    /// A theme from gpui-omarchy's tokens: `caution` and `markedFill` are
    /// the palette's for that appearance.
    public init(
        background: HSLA,
        surface: HSLA,
        inset: HSLA,
        foreground: HSLA,
        secondary: HSLA,
        bright: HSLA,
        border: HSLA,
        divider: HSLA,
        controlBorder: HSLA,
        hoverFill: HSLA,
        normalFill: HSLA,
        accent: HSLA,
        warning: HSLA,
        danger: HSLA,
        success: HSLA,
        isDark: Bool
    ) {
        self.init(
            background: background,
            surface: surface,
            inset: inset,
            foreground: foreground,
            secondary: secondary,
            bright: bright,
            border: border,
            divider: divider,
            controlBorder: controlBorder,
            hoverFill: hoverFill,
            normalFill: normalFill,
            accent: accent,
            warning: warning,
            danger: danger,
            success: success,
            caution: isDark ? Card.dark.caution : Card.light.caution,
            markedFill: isDark ? Card.dark.markedFill : Card.light.markedFill,
            isDark: isDark,
            increaseContrast: false
        )
    }

    /// The colour for a message of `status`: gpui-omarchy's `alert_color`.
    /// A warning is `caution`, not `warning`: the token of that name is the
    /// highlight now, and a notice is not the selection.
    public func alertColor(_ status: Status) -> HSLA {
        switch status {
        case .neutral: secondary
        case .success: success
        case .warning: caution
        case .error: danger
        }
    }
}

// MARK: - The palette

/// MP300, by Alex Cristache: the six colours every token is taken or mixed
/// from, by their names in the palette.
///
/// The palette's cards pair them two ways. The dark one is a Midnight Blue
/// ground rising through Indigo Blue into Sweet Escape and a sky-blue glow,
/// with Pear Spritz for names; the light one is a Sun Glint ground with lime
/// and turquoise light, and Indigo Blue for text. The two presets below are
/// those two cards.
public enum MP300 {
    /// A warm cream: the light ground, and the text on the dark one.
    public static let sunGlint = HSLA.hex(0xFAF3D9)
    /// A lime: the highlight on dark. At 1.1:1 on Sun Glint it cannot be a
    /// ring or text on the light ground, only light in its gradient.
    public static let pearSpritz = HSLA.hex(0xCBF85F)
    /// A turquoise: space given back, on dark.
    public static let freshTurquoise = HSLA.hex(0x40E0D0)
    /// A violet: the highlight on light, the accent on dark.
    public static let sweetEscape = HSLA.hex(0x8844FF)
    /// A deep blue-violet: the accent on light, outlines on dark.
    public static let indigoBlue = HSLA.hex(0x3A18B1)
    /// A near-black navy: the dark ground, and the ink on the light one.
    public static let midnightBlue = HSLA.hex(0x020035)

    /// All six, lightest first, as the palette's swatch card lists them.
    public static let all: [HSLA] = [
        sunGlint, pearSpritz, freshTurquoise, sweetEscape, indigoBlue,
        midnightBlue,
    ]
}

/// Plain white and black, for the mixes that lift or sink a palette colour
/// without turning its hue.
private let white = HSLA(h: 0, s: 0, l: 1)
private let black = HSLA(h: 0, s: 0, l: 0)

// MARK: - Presets

/// What each card adds to gpui-omarchy's tokens.
private enum Card {
    struct Extra {
        var caution: HSLA
        var markedFill: HSLA
    }

    static let dark = Extra(
        // The palette has no amber, as it has no red. One sits with it as
        // the rose does: Sun Glint's gold turned toward orange, far from
        // the rose that means danger and from the agent-scratch gold, and
        // 9.6:1 on the window.
        caution: HSLA(h: 0.065, s: 1, l: 0.68),
        // The rose's hue, deep: an oxblood, darker than every fill, so a
        // marked tile sinks, for a colour-blind eye too, where hue alone
        // would not tell it from a magenta or a gold. The rose that names
        // it is 6.4:1 on it, a cream name 15:1.
        markedFill: Oklab(l: 0.24, chroma: 0.08, hue: 18).hsla
    )

    static let light = Extra(
        // The same amber, burnt until it reads as text on the cream (6.2:1)
        // and in a chip (5.3:1).
        caution: HSLA(h: 0.075, s: 1, l: 0.29),
        // The oxblood's hue and colour, as pale as a fill may be while the
        // wine that names it keeps 4.5:1: a dusty rose, deeper than every
        // fill, and nothing like the gold or the pink beside it.
        markedFill: Oklab(l: 0.77, chroma: 0.08, hue: 18).hsla
    )
}

extension Theme {
    /// The palette's dark card: a Midnight Blue window, cream text, the lime
    /// highlight. What a Mac in Dark Mode shows, and what tests draw with.
    ///
    /// The contrast ratios in the comments are WCAG 2's, which
    /// `ContrastTests` holds them to. The palette's own card quotes each
    /// colour against white or black instead, so its numbers differ.
    public static let dark = derived(
        background: MP300.midnightBlue,
        // Raised a quarter of the way toward Indigo Blue, as the dark card
        // rises. Two blues this dark barely differ in luminance (1.12:1),
        // so the step reads as a warmer, more violet blue, not as a lighter
        // grey.
        surface: MP300.midnightBlue.mixed(toward: MP300.indigoBlue, by: 0.25),
        // Sunk toward black, so the tiles, which lift toward the light,
        // stand off a ground that is darker than the window around it.
        inset: MP300.midnightBlue.mixed(toward: black, by: 0.3),
        // Body text a step under the cream, so names set in `bright` still
        // lead: 13.7:1 on the window.
        foreground: MP300.sunGlint.mixed(
            toward: MP300.midnightBlue,
            by: 0.12
        ),
        // Cream with a third of the violet in it, taken down a quarter
        // toward the ground: a cream-lavender between the text and the
        // window, 6.8:1 on it and 6.1:1 on the panel.
        secondary: MP300.sunGlint
            .mixed(toward: MP300.sweetEscape, by: 0.3)
            .mixed(toward: MP300.midnightBlue, by: 0.25),
        bright: MP300.sunGlint,
        // The colour the dark card rises through: an outline that is part
        // of the palette rather than a grey, 1.65:1 on the panel.
        border: MP300.indigoBlue,
        // Sweet Escape is 4.1:1 on Midnight Blue, under the 4.5:1 text
        // needs, and the accent is text: the keys in the help, the Full
        // Disk Access link, a primary button's fill under Midnight. A
        // quarter of the way to white keeps its hue and reaches 6.2:1 on
        // the window, 5.5:1 on the panel, and 6.2:1 under a Midnight label.
        accent: MP300.sweetEscape.mixed(toward: white, by: 0.25),
        // 16:1 on the window: the one thing on screen that glows.
        warning: MP300.pearSpritz,
        // The palette has no red. A rose sits with it: opposite the
        // turquoise on the wheel, a neighbour of the violet through
        // magenta, and at this lightness 7.6:1 on the window.
        danger: HSLA(h: 0.96, s: 1, l: 0.72),
        success: MP300.freshTurquoise,
        caution: Card.dark.caution,
        markedFill: Card.dark.markedFill,
        isDark: true
    )

    /// The palette's light card: a Sun Glint window, Midnight and Indigo
    /// text, the violet highlight.
    public static let light = derived(
        background: MP300.sunGlint,
        // Lighter than the window: a card of whiter paper on the cream.
        surface: MP300.sunGlint.mixed(toward: white, by: 0.6),
        // The same cream, deeper, so the mosaic's pale tiles keep a ground
        // to show their gaps against. Its hue is Sun Glint's own.
        inset: HSLA(h: MP300.sunGlint.h, s: 0.6, l: 0.86),
        // Midnight a quarter toward Indigo: the ink the light card writes
        // in, 16:1 on the window.
        foreground: MP300.midnightBlue.mixed(
            toward: MP300.indigoBlue,
            by: 0.25
        ),
        // An indigo-grey: a hue beside Indigo's with most of its colour
        // taken out, 6.9:1 on the window and 6.2:1 on the mosaic's ground.
        secondary: HSLA(h: 0.69, s: 0.25, l: 0.4),
        bright: MP300.midnightBlue,
        // The ink's own blue, faint: a lavender-grey line on the cream.
        border: MP300.sunGlint.mixed(toward: MP300.indigoBlue, by: 0.22),
        accent: MP300.indigoBlue,
        // Sweet Escape is 4.4:1 on Sun Glint, and the highlight is text
        // and a selection ring as often as a fill. Two fifths of the way to
        // Indigo Blue it is still plainly the violet, and reaches 6:1 on
        // the window, 3:1 as a ring on the deepest tile, and 6.4:1 under
        // the cream label of the main action.
        warning: MP300.sweetEscape.mixed(toward: MP300.indigoBlue, by: 0.4),
        // The rose, deepened to a wine: 8.9:1 as text on the cream, and
        // 4.6:1 on a marked tile.
        danger: HSLA(h: 0.965, s: 0.72, l: 0.3),
        // Fresh Turquoise is 1.5:1 on the cream: invisible as text. Its
        // hue, taken down until the figure it colours reads at 5.4:1, and
        // 4.7:1 in a chip over its own wash.
        success: HSLA(h: MP300.freshTurquoise.h, s: 0.9, l: 0.23),
        caution: Card.light.caution,
        markedFill: Card.light.markedFill,
        isDark: false
    )

    /// A theme whose quiet tokens are derived from its foreground, the way
    /// gpui-omarchy derives `divider()`, `control_border()`, `hover_fill()`
    /// and `normal_fill()`: translucent cream on the dark card, translucent
    /// ink on the light one. The shares are measured from the screenshot,
    /// except the control's outline: at gpui-omarchy's 0.4 it was 2.8:1 on
    /// these grounds, and it is the only edge an unchecked box or an
    /// outline button has, which WCAG wants at 3:1; at half it is 3.5:1 or
    /// more on the window and the panel.
    private static func derived(
        background: HSLA,
        surface: HSLA,
        inset: HSLA,
        foreground: HSLA,
        secondary: HSLA,
        bright: HSLA,
        border: HSLA,
        accent: HSLA,
        warning: HSLA,
        danger: HSLA,
        success: HSLA,
        caution: HSLA,
        markedFill: HSLA,
        isDark: Bool
    ) -> Theme {
        Theme(
            background: background,
            surface: surface,
            inset: inset,
            foreground: foreground,
            secondary: secondary,
            bright: bright,
            border: border,
            divider: foreground.opacity(0.12),
            controlBorder: foreground.opacity(0.5),
            hoverFill: foreground.opacity(0.08),
            normalFill: foreground.opacity(0.04),
            accent: accent,
            warning: warning,
            danger: danger,
            success: success,
            caution: caution,
            markedFill: markedFill,
            isDark: isDark,
            increaseContrast: false
        )
    }
}

// MARK: - Increase Contrast

extension Theme {
    /// The dark card for someone who asked for more contrast. Its outline
    /// is Indigo Blue lifted a third toward the cream, 3.8:1 on the panel.
    public static let darkHighContrast = dark.increasingContrast(
        border: MP300.indigoBlue.mixed(toward: MP300.sunGlint, by: 0.35)
    )

    /// The light card for someone who asked for more contrast. Its outline
    /// is the cream three fifths of the way to Indigo Blue, 3.7:1 on the
    /// window.
    public static let lightHighContrast = light.increasingContrast(
        border: MP300.sunGlint.mixed(toward: MP300.indigoBlue, by: 0.6)
    )

    /// This card with every quiet line and dim label made plain: outlines
    /// at 3:1 and more, dividers two and a half times as strong, the dim
    /// text halfway to the body text. The colours that mean something stay
    /// as they are; they already read.
    private func increasingContrast(border: HSLA) -> Theme {
        var theme = self
        theme.secondary = secondary.mixed(toward: foreground, by: 0.5)
        theme.border = border
        theme.divider = foreground.opacity(0.3)
        theme.controlBorder = foreground.opacity(0.7)
        theme.hoverFill = foreground.opacity(0.14)
        theme.normalFill = foreground.opacity(0.08)
        theme.increaseContrast = true
        return theme
    }
}

// MARK: - The system theme

extension Theme {
    /// The theme for `appearance`: the palette's dark card in Dark Mode, its
    /// light card otherwise, each in its high-contrast form when the
    /// appearance is a high-contrast one or `increaseContrast` says the
    /// user asked for it.
    ///
    /// Nothing is read from AppKit's semantic colours or the accent colour
    /// any more: the palette is the app's own, and a system accent would be
    /// a seventh colour it was never tuned against. Increase Contrast is
    /// read, because it is a need rather than a taste. It comes both ways:
    /// a caller may build the appearance from a colour scheme, which loses
    /// the high-contrast name, so the setting is asked for directly too.
    public static func system(
        appearance: NSAppearance,
        increaseContrast: Bool = NSWorkspace.shared
            .accessibilityDisplayShouldIncreaseContrast
    ) -> Theme {
        let match = appearance.bestMatch(from: [
            .aqua, .darkAqua, .accessibilityHighContrastAqua,
            .accessibilityHighContrastDarkAqua,
        ])
        let dark =
            match == .darkAqua || match == .accessibilityHighContrastDarkAqua
        let high =
            increaseContrast || match == .accessibilityHighContrastAqua
            || match == .accessibilityHighContrastDarkAqua
        return switch (dark, high) {
        case (true, false): .dark
        case (true, true): .darkHighContrast
        case (false, false): .light
        case (false, true): .lightHighContrast
        }
    }
}

// MARK: - SwiftUI

extension EnvironmentValues {
    /// The theme widgets read. The app sets the system theme at the root;
    /// the default is the dark preset, so a widget drawn on its own, as the
    /// tests draw them, still has every token.
    @Entry public var theme: Theme = .dark

    /// The size of one rem, in points: `baseRem` times the interface zoom
    /// step. Every widget measures itself in it.
    @Entry public var rem: CGFloat = baseRem
}
