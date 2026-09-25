import AppKit
import DisktreeCore
import Testing

@testable import DisktreeApp

// The palette's promises, checked against both presets, and then against
// the system theme in every appearance a Mac can be in, which is what a user
// actually sees. What each colour reads against is `ContrastTests`'.

private let presets: [(name: String, theme: Theme)] = [
    ("dark", .dark), ("light", .light),
]

/// How far apart two hues are around the wheel, `0...0.5`.
private func hueDistance(_ left: Double, _ right: Double) -> Double {
    let apart = abs(left - right).truncatingRemainder(dividingBy: 1)
    return min(apart, 1 - apart)
}

/// How far apart two Oklab hues are around the wheel, in degrees, `0...180`.
private func hueAngle(_ left: Double, _ right: Double) -> Double {
    let apart = abs(left - right).truncatingRemainder(dividingBy: 360)
    return min(apart, 360 - apart)
}

@Test func everyLegendCategoryHasItsOwnHue() {
    // A quarter-turn's third apart on the Oklab wheel, or one of the pair
    // plainly nearer grey.
    for (name, theme) in presets {
        let accents = Category.legend.map { theme.categoryAccent($0).oklab }
        for (index, left) in accents.enumerated() {
            for right in accents[(index + 1)...] {
                let apart =
                    hueAngle(left.hue, right.hue) >= 30
                    || abs(left.chroma - right.chroma) >= 0.05
                #expect(apart, "\(name): \(left) and \(right) read as one")
            }
        }
    }
}

@Test func colourfulCategoriesShareOneLevel() {
    // One level, measured as the eye measures it (Oklab), not in HSL's
    // arithmetic lightness, which put blue and violet far below lime and
    // gold. Its lightness is a band, not a line: a few hues step a little
    // off it so that colour-blind eyes can tell them apart. Colour more
    // loosely: a screen cannot show as much turquoise as violet this dark,
    // nor as much sky blue as lime this pale, and the light card's
    // toolchains and caches carry its lime and turquoise light, a step
    // more than the rest.
    for (name, theme) in presets {
        let fills = Category.allCases
            .filter { ![.documents, .other].contains($0) }
            .map { theme.categoryFill($0, depth: 0).oklab }
        let lightness = fills.map(\.l)
        let chroma = fills.map(\.chroma)
        let band = (lightness.max() ?? 0) - (lightness.min() ?? 0)
        let spread = (chroma.max() ?? 0) - (chroma.min() ?? 0)
        #expect(band <= 0.065, "\(name): \(lightness)")
        #expect(spread <= 0.04, "\(name): \(chroma)")
    }
}

@Test func theIndigoAndVioletNoLongerSink() {
    // On the dark card, the palette's own hues stand at the level or above
    // it, never below the warm ones the palette does not have.
    let theme = Theme.dark
    let level = { (category: DisktreeCore.Category) in
        theme.categoryFill(category, depth: 0).oklab.l
    }
    for cool in [Category.code, .media] {
        for warm in [Category.agentScratch, .toolchain, .documents] {
            #expect(level(cool) >= level(warm) - 0.001, "\(cool) \(warm)")
        }
    }
}

@Test func theNeutralKindsStayNearlyGrey() {
    // Documents and everything unclassified recede: a cream-grey and an
    // indigo-grey, with a fraction of the least colourful fill's colour.
    for (name, theme) in presets {
        let least =
            Category.allCases
            .filter { ![.documents, .other].contains($0) }
            .map { theme.categoryFill($0, depth: 0).oklab.chroma }
            .min() ?? 0
        for category in [Category.documents, .other] {
            let fill = theme.categoryFill(category, depth: 0).oklab
            #expect(fill.chroma < least / 3, "\(name): \(category)")
        }
    }
}

@Test func deeperTilesLiftAwayFromTheBackground() {
    for (name, theme) in presets {
        let ground = theme.background.oklab.l
        for category in Category.allCases {
            let top = theme.categoryFill(category, depth: 0).oklab.l
            let deep = theme.categoryFill(category, depth: 3).oklab.l
            // Away from the background: lighter on dark, darker on light.
            #expect(
                abs(deep - ground) > abs(top - ground) + 0.045,
                "\(name): \(category)"
            )
        }
    }
}

@Test func theHighlightIsNotACategoryColour() {
    // No fill comes near the highlight's colourfulness, so the ring is the
    // one saturated thing on the mosaic in kind mode.
    for (name, theme) in presets {
        let highlight = theme.highlight.oklab.chroma
        for category in Category.allCases {
            for depth in 0..<5 {
                let fill = theme.categoryFill(category, depth: depth)
                #expect(
                    highlight - fill.oklab.chroma >= 0.1,
                    "\(name): \(category) at \(depth) competes"
                )
            }
        }
    }
}

@Test func ageBucketsCoverEveryAgeInOrder() {
    #expect(ageBucket(days: 0) == 0)
    #expect(ageBucket(days: 8) == 1)
    #expect(ageBucket(days: 100) == 2)
    #expect(ageBucket(days: 300) == 3)
    #expect(ageBucket(days: 5000) == 4)
    for (name, theme) in presets {
        let chroma = ageBuckets.indices.map {
            theme.ageFill(bucket: $0, depth: 0).oklab.chroma
        }
        #expect(chroma[0] > chroma[4], "\(name): \(chroma)")
    }
}

@Test func theAgeRampRunsFromTheAccentTowardTheGround() {
    // Recent writes carry the accent's hue (violet on dark, indigo on
    // light); untouched ones drain toward the mosaic's ground.
    for (name, theme) in presets {
        let fresh = theme.ageFill(bucket: 0, depth: 0).oklab
        #expect(
            hueAngle(fresh.hue, theme.accent.oklab.hue) < 3,
            "\(name): \(fresh.hue)"
        )
        // Measured in RGB: the dark ground is a saturated navy, and a
        // perceptual distance to a colour that saturated flattens out long
        // before the tile reaches it.
        let ground = theme.inset.toRGB()
        let distances = ageBuckets.indices.map { bucket in
            let fill = theme.ageFill(bucket: bucket, depth: 0).toRGB()
            let (r, g, b) = (
                fill.r - ground.r, fill.g - ground.g, fill.b - ground.b
            )
            return (r * r + g * g + b * b).squareRoot()
        }
        for (newer, older) in zip(distances, distances.dropFirst()) {
            #expect(older < newer, "\(name): \(distances)")
        }
    }
}

@Test func mixingTowardAGreyKeepsTheHue() {
    let theme = Theme.dark
    let gold = theme.categoryAccent(.agentScratch)
    let mixed = gold.mixed(toward: HSLA(h: 0, s: 0, l: 0.1), by: 0.3)
    #expect(abs(mixed.h - gold.h) < 0.02, "\(mixed)")
}

@Test func mixClampsItsParameter() {
    let theme = Theme.dark
    let clampedLow = theme.background.mixed(toward: theme.accent, by: -1).l
    let clampedHigh = theme.background.mixed(toward: theme.accent, by: 2).l
    #expect(abs(clampedLow - theme.background.l) < 1e-3)
    #expect(abs(clampedHigh - theme.accent.l) < 1e-3)
}

// MARK: - The palette

/// The 8-bit channels of a colour, as a theme file would write them.
private func bytes(_ color: HSLA) -> [Int] {
    let rgb = color.toRGB()
    return [rgb.r, rgb.g, rgb.b].map { Int(($0 * 255).rounded()) }
}

@Test func thePaletteIsMP300() {
    let expected: [(HSLA, [Int])] = [
        (MP300.sunGlint, [0xFA, 0xF3, 0xD9]),
        (MP300.pearSpritz, [0xCB, 0xF8, 0x5F]),
        (MP300.freshTurquoise, [0x40, 0xE0, 0xD0]),
        (MP300.sweetEscape, [0x88, 0x44, 0xFF]),
        (MP300.indigoBlue, [0x3A, 0x18, 0xB1]),
        (MP300.midnightBlue, [0x02, 0x00, 0x35]),
    ]
    for (color, channels) in expected {
        #expect(bytes(color) == channels, "\(color)")
    }
    #expect(MP300.all.map(bytes) == expected.map(\.1))
}

@Test func eachPresetIsOneOfThePalettesCards() {
    // Dark: a Midnight Blue window, cream names, the lime highlight and
    // the turquoise for space given back.
    let dark = Theme.dark
    #expect(bytes(dark.background) == bytes(MP300.midnightBlue))
    #expect(bytes(dark.bright) == bytes(MP300.sunGlint))
    #expect(bytes(dark.highlight) == bytes(MP300.pearSpritz))
    #expect(bytes(dark.success) == bytes(MP300.freshTurquoise))
    #expect(bytes(dark.border) == bytes(MP300.indigoBlue))
    #expect(hueDistance(dark.accent.h, MP300.sweetEscape.h) < 0.005)
    // Light: a Sun Glint window, Midnight ink, Indigo for focus, and the
    // violet highlight, a shade deeper than Sweet Escape so it reads as
    // text on the cream.
    let light = Theme.light
    #expect(bytes(light.background) == bytes(MP300.sunGlint))
    #expect(bytes(light.bright) == bytes(MP300.midnightBlue))
    #expect(bytes(light.accent) == bytes(MP300.indigoBlue))
    #expect(hueDistance(light.highlight.h, MP300.sweetEscape.h) < 0.01)
    #expect(hueDistance(light.success.h, MP300.freshTurquoise.h) < 0.01)
}

@Test func hexColoursSurviveTheTripThroughHSLA() {
    // Navy, a grey (no hue), pure red (hue 0) and a pink just short of the
    // wheel's end (hue near 1), where a wrap mistake would show, then the
    // palette's own six.
    let cases: [(UInt32, [Int])] = [
        (0x1A1B26, [0x1A, 0x1B, 0x26]),
        (0x808080, [0x80, 0x80, 0x80]),
        (0xFF0000, [0xFF, 0x00, 0x00]),
        (0xFF0080, [0xFF, 0x00, 0x80]),
        (0xFAF3D9, [0xFA, 0xF3, 0xD9]),
        (0xCBF85F, [0xCB, 0xF8, 0x5F]),
        (0x40E0D0, [0x40, 0xE0, 0xD0]),
        (0x8844FF, [0x88, 0x44, 0xFF]),
        (0x3A18B1, [0x3A, 0x18, 0xB1]),
        (0x020035, [0x02, 0x00, 0x35]),
    ]
    for (hex, expected) in cases {
        #expect(bytes(.hex(hex)) == expected, "\(String(hex, radix: 16))")
    }
    #expect(HSLA.hex(0x808080).h == 0)
}

@Test func opacityScalesAlphaRatherThanReplacingIt() {
    let half = HSLA.hex(0xFFFFFF, alpha: 0.5)
    #expect(abs(half.opacity(0.5).a - 0.25) < 1e-9)
    #expect(half.opacity(3).a == 0.5)
    #expect(half.opacity(-1).a == 0)
}

@Test func compositingFlattensOntoTheGround() {
    let white = HSLA.hex(0xFFFFFF, alpha: 0.5)
    let black = HSLA.hex(0x000000)
    let grey = white.composited(over: black)
    #expect(grey.a == 1)
    #expect(bytes(grey) == [128, 128, 128])
    // Nothing over nothing stays nothing, rather than dividing by zero.
    #expect(black.withAlpha(0).composited(over: black.withAlpha(0)).a == 0)
}

@Test func everyStatusHasItsColour() {
    for (_, theme) in presets {
        #expect(theme.alertColor(.neutral) == theme.secondary)
        #expect(theme.alertColor(.success) == theme.success)
        #expect(theme.alertColor(.warning) == theme.caution)
        #expect(theme.alertColor(.error) == theme.danger)
        // `warning` is still the highlight, under the name every caller
        // knows it by; a notice is just not drawn in it any more.
        #expect(theme.warning == theme.highlight)
    }
}

@Test func cautionIsNeitherTheHighlightNorDanger() {
    // A notice that asks for care must not read as the selection (the
    // lime, the violet) nor as a failure (the rose).
    for (name, theme) in presets {
        for other in [theme.highlight, theme.danger, theme.success] {
            #expect(
                Legibility.difference(theme.caution, other) >= 25,
                "\(name): \(other)"
            )
        }
    }
}

@Test func aThemeFromOmarchysTokensGetsTheCardsOwn() {
    // A theme built the old way, from gpui-omarchy's tokens alone, gets
    // the caution and the marked fill of its appearance.
    for (_, card) in presets {
        let theme = Theme(
            background: card.background,
            surface: card.surface,
            inset: card.inset,
            foreground: card.foreground,
            secondary: card.secondary,
            bright: card.bright,
            border: card.border,
            divider: card.divider,
            controlBorder: card.controlBorder,
            hoverFill: card.hoverFill,
            normalFill: card.normalFill,
            accent: card.accent,
            warning: card.warning,
            danger: card.danger,
            success: card.success,
            isDark: card.isDark
        )
        #expect(theme == card)
    }
}

@Test func contentTokensAreOpaqueAndQuietOnesTranslucent() {
    // `opacity(_:)` on a content token must mean the share it says, as it
    // does for an Omarchy token; the quiet tokens stay translucent, so one
    // value reads on any ground.
    for (name, theme) in presets {
        let tokens = [
            theme.background, theme.surface, theme.inset, theme.foreground,
            theme.secondary, theme.bright, theme.border, theme.accent,
            theme.warning, theme.danger, theme.success, theme.caution,
            theme.markedFill,
        ]
        for token in tokens {
            #expect(abs(token.a - 1) < 1e-6, "\(name): \(token)")
        }
        for token in [
            theme.divider, theme.controlBorder, theme.hoverFill,
            theme.normalFill,
        ] {
            #expect(token.a <= 0.5, "\(name): \(token)")
        }
    }
}

// MARK: - Oklab

@Test func oklabRoundTripsThePalette() {
    for color in MP300.all + [HSLA.hex(0x808080), .hex(0xFF0000)] {
        #expect(bytes(color.oklab.hsla) == bytes(color), "\(color)")
    }
    // The ends of the scale, and the palette's own hues where they are
    // known: Sun Glint a cream (yellow, near 95), Sweet Escape a violet.
    #expect(abs(HSLA.hex(0xFFFFFF).oklab.l - 1) < 1e-3)
    #expect(abs(HSLA.hex(0x000000).oklab.l) < 1e-6)
    #expect(abs(MP300.sunGlint.oklab.hue - 94.5) < 1)
    #expect(abs(MP300.sweetEscape.oklab.hue - 293.3) < 1)
}

@Test func aColourOutOfGamutGivesUpChromaOnly() {
    // Far more turquoise than a screen can show this dark: it keeps its
    // lightness and hue and loses only colour.
    let wanted = Oklab(l: 0.3, chroma: 0.2, hue: 186)
    #expect(!wanted.isInGamut)
    let mapped = Oklab.mapped(l: 0.3, chroma: 0.2, hue: 186)
    #expect(mapped.isInGamut)
    #expect(mapped.chroma < 0.2 && mapped.chroma > 0.04)
    let shown = mapped.hsla.oklab
    #expect(abs(shown.l - 0.3) < 0.005)
    #expect(hueAngle(shown.hue, 186) < 2)
}

// MARK: - The system theme

/// The system theme for `name`, with Increase Contrast off unless told:
/// the Mac running the tests may have it on.
private func system(
    _ name: NSAppearance.Name,
    increaseContrast: Bool = false
) throws -> Theme {
    .system(
        appearance: try #require(NSAppearance(named: name)),
        increaseContrast: increaseContrast
    )
}

@Test func theSystemThemeFollowsTheAppearance() throws {
    let dark = try system(.darkAqua)
    let light = try system(.aqua)
    #expect(dark.isDark)
    #expect(!light.isDark)
    #expect(dark.background.l < dark.foreground.l)
    #expect(light.background.l > light.foreground.l)
    // Increase Contrast is still dark or light.
    #expect(try system(.accessibilityHighContrastDarkAqua).isDark)
    #expect(try !system(.accessibilityHighContrastAqua).isDark)
}

@Test func theSystemThemeIsThePalette() throws {
    // Every appearance gets one of the two cards, whatever the accent
    // colour in System Settings: the app's colours are its own.
    let cases: [(NSAppearance.Name, Theme)] = [
        (.darkAqua, .dark), (.vibrantDark, .dark),
        (.aqua, .light), (.vibrantLight, .light),
    ]
    for (name, expected) in cases {
        #expect(try system(name) == expected, "\(name.rawValue)")
    }
    // A high-contrast appearance gets its card, in the high-contrast form
    // when AppKit hands one out. It only does while Increase Contrast is
    // on for the whole Mac; asked for by name otherwise, it gives back the
    // plain appearance, which is why the setting is also read directly.
    let high: [(NSAppearance.Name, [Theme])] = [
        (.accessibilityHighContrastDarkAqua, [.dark, .darkHighContrast]),
        (.accessibilityHighContrastAqua, [.light, .lightHighContrast]),
    ]
    for (name, expected) in high {
        #expect(try expected.contains(system(name)), "\(name.rawValue)")
    }
}

@Test func increaseContrastStrengthensTheQuietTokens() throws {
    // Asked for directly, as a caller that builds the appearance from a
    // colour scheme must: the plain appearance names lose the setting.
    #expect(try system(.darkAqua, increaseContrast: true) == .darkHighContrast)
    #expect(try system(.aqua, increaseContrast: true) == .lightHighContrast)
    for (plain, high) in [
        (Theme.dark, Theme.darkHighContrast), (.light, .lightHighContrast),
    ] {
        #expect(high.increaseContrast && !plain.increaseContrast)
        #expect(high.isDark == plain.isDark)
        for (quiet, strong) in [
            (plain.divider, high.divider),
            (plain.controlBorder, high.controlBorder),
            (plain.hoverFill, high.hoverFill),
            (plain.normalFill, high.normalFill),
            (plain.labelDim, high.labelDim),
            (plain.hatchColor, high.hatchColor),
        ] {
            #expect(strong.a > quiet.a, "\(quiet) \(strong)")
        }
        let ground = plain.surface
        #expect(
            Legibility.ratio(high.secondary, on: ground)
                > Legibility.ratio(plain.secondary, on: ground)
        )
        #expect(
            Legibility.ratio(high.border, on: ground)
                > Legibility.ratio(plain.border, on: ground)
        )
        // What means something stays: the fills, the highlight, the rest.
        #expect(high.highlight == plain.highlight)
        #expect(high.markedFill == plain.markedFill)
        #expect(
            high.categoryFill(.code, depth: 2)
                == plain.categoryFill(.code, depth: 2)
        )
    }
}

@Test func theHighlightReadsOnBothAppearances() throws {
    // 3:1 is WCAG's floor for bold text and for graphics, which is how the
    // highlight is used on the grounds: a selection ring, a bar, a figure.
    // A filled button's label is text proper, so 4.5:1.
    let themes = [
        Theme.dark, Theme.light, .darkHighContrast, .lightHighContrast,
        try system(.darkAqua), try system(.aqua),
    ]
    for theme in themes {
        for ground in [theme.background, theme.surface, theme.inset] {
            #expect(
                Legibility.ratio(theme.highlight, on: ground) >= 3,
                "\(theme.highlight) on \(ground)"
            )
        }
        #expect(
            Legibility.ratio(theme.onHighlight, on: theme.highlight) >= 4.5
        )
    }
}

// MARK: - Gradients and the mark

@Test func theBackdropsRunThroughThePalette() {
    for backdrop in [Backdrop.dusk, .dawn] {
        let locations = backdrop.stops.map(\.location)
        #expect(locations.first == 0)
        #expect(locations.last == 1)
        #expect(locations == locations.sorted())
        // The ends are the ends, and past them the colour holds.
        #expect(backdrop.color(at: -1) == backdrop.stops[0].color)
        #expect(backdrop.color(at: 2) == backdrop.stops.last?.color)
    }
    // Dusk rises from Midnight Blue through Indigo Blue.
    #expect(
        Backdrop.dusk.stops.contains { $0.color == MP300.indigoBlue }
    )
    // Each starts at its card's window colour, so where the top bar meets
    // it there is no seam: dusk at Midnight Blue, dawn at Sun Glint.
    #expect(Backdrop.dusk.color(at: 0) == Theme.dark.background)
    #expect(Backdrop.dawn.color(at: 0) == Theme.light.background)
    // Dawn's lime comes in close under the top.
    let lime = Backdrop.dawn.color(at: 0.1).oklab
    #expect(hueAngle(lime.hue, MP300.pearSpritz.oklab.hue) < 15)
    // Between two stops the colour is between them.
    let (low, high) = (Backdrop.dusk.stops[0], Backdrop.dusk.stops[1])
    let middle = Backdrop.dusk.color(at: (low.location + high.location) / 2)
    #expect(middle.l > low.color.l && middle.l < high.color.l)
    // Each appearance has its own.
    #expect(Theme.dark.backdrop == .dusk)
    #expect(Theme.light.backdrop == .dawn)
}

@Test func theMarkIsDrawnInThePalette() {
    let ink = LogoInk.icon
    #expect(ink.blocks.count == 8)
    #expect(ink.blocks.first == MP300.indigoBlue)
    #expect(ink.panel == MP300.midnightBlue)
    #expect(ink.directory == MP300.indigoBlue)
    #expect(ink.rootBand == MP300.pearSpritz)
    #expect(ink.file == MP300.pearSpritz)
    #expect(ink.directoryBand == MP300.sweetEscape)
    #expect(ink.columnBand == MP300.freshTurquoise)
    #expect(ink.ground.color(at: 0) == MP300.indigoBlue)
    // The turquoise directory is turquoise, not a steel blue.
    #expect(
        hueAngle(ink.column.oklab.hue, MP300.freshTurquoise.oklab.hue) < 5
    )
    // The mark keeps its outline on either window, and on a dark Dock:
    // its body's top edge stands off the dark card's Midnight.
    for window in [Theme.dark.background, Theme.light.background] {
        #expect(Legibility.difference(ink.ground.color(at: 0), window) >= 15)
    }
    // A band stands off its directory's body, and the body off the well
    // it sits in, or the mark is a smudge at 16 px.
    let pairs = [
        (ink.rootBand, ink.panel), (ink.directoryBand, ink.directory),
        (ink.columnBand, ink.column), (ink.directory, ink.panel),
        (ink.column, ink.panel), (ink.file, ink.panel),
    ]
    for (top, under) in pairs {
        #expect(Legibility.difference(top, under) >= 15, "\(top) \(under)")
    }
    // The logo is the icon in both appearances, as an app icon is.
    #expect(Theme.dark.logo == .icon)
    #expect(Theme.light.logo == .icon)
}

@Test func theSVGAndTheIconScriptDrawTheSameMark() throws {
    // The icon script runs on its own, outside the app, so it repeats the
    // mark's colours rather than importing them; this keeps the three
    // copies (the app's, the SVG's, the script's) from drifting apart.
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let svg = try String(
        contentsOf: repository.appending(path: "assets/disktree.svg"),
        encoding: .utf8
    )
    let script = try String(
        contentsOf: repository.appending(path: "scripts/make-icon.swift"),
        encoding: .utf8
    )
    let ink = LogoInk.icon
    let colours = ink.blocks.dropFirst() + ink.ground.stops.map(\.color)
    for colour in colours {
        let hex = bytes(colour).map { String(format: "%02x", $0) }.joined()
        #expect(svg.contains("#\(hex)"), "the SVG lacks #\(hex)")
        #expect(script.contains("0x\(hex)"), "the script lacks 0x\(hex)")
    }
}
