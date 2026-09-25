import AppKit
import CoreGraphics
import DisktreeCore
import SwiftUI
import System
import Testing

@testable import DisktreeApp

// The mosaic's promises, held to the pixels it paints: fills by kind, depth,
// age and find state, the cushion down every leaf, corners rounded by level,
// the hatch over what can be had back, the strip over the first level, the
// rings in their order, the selection's glow and the hover's lift, the
// marked badge, the labels clipped to the region they own and set in their
// faces, in both appearances and at both backing scales, zoomed and
// mid-transition. Then the view's wiring: the size it reports, the points
// its events carry, and the gate that keeps one trackpad flick from
// tunnelling through several levels. Last, the frame budget, measured when
// asked (`DISKTREE_BENCH`).
//
// Set DISKTREE_RENDER_DIR to a directory to keep the frames as PNGs.

private typealias Support = TreemapSupport

/// `files` on disk, scanned, and gone again: the tree stays in memory.
private func scanned(_ files: [(String, Int)]) throws -> Node {
    let fixture = try TreemapFixture.make(files)
    defer { fixture.remove() }
    return try fixture.scan()
}

private func cgRect(_ rect: Rect) -> CGRect {
    CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h)
}

/// Every leaf tile big enough to sample shows its own fill low in its body,
/// clear of its label, its strip and any ring: its fill down its cushion,
/// as far down as the sample is. A leaf is a tile nothing else is drawn
/// inside, and the painter, which tells one from the layout's order, must
/// agree with the tree about which tiles those are. A hatched one is left
/// out, as its stripes cross the sample.
private func expectLeavesShowTheirFill(
    _ frame: TreemapFrame,
    _ painted: PaintedMosaic,
    theme: Theme,
    sourceLocation: SourceLocation = #_sourceLocation
) -> Int {
    let colors = MosaicColors(theme: theme)
    let tiles = frame.tiles()
    let mosaic = frame.mosaic()
    let bounds = CGRect(origin: .zero, size: frame.size)
    let placed = Support.placed(
        mosaic,
        theme: theme,
        size: frame.size,
        scale: painted.scale
    )
    var checked = 0
    for tile in placed {
        let crumbs = tiles[tile.index].crumbs
        let inside = tiles.indices.contains { other in
            other != tile.index
                && tiles[other].crumbs.starts(with: crumbs)
                && (tiles[other].crumbs.count > crumbs.count
                    || Support.isOthers(tiles[other]))
        }
        if !Support.isOthers(tiles[tile.index]) {
            #expect(
                tile.leaf == !inside,
                "tile \(crumbs)",
                sourceLocation: sourceLocation
            )
        }
        let deco = tile.deco
        if inside || MosaicPainter.isHatched(deco) || deco.selected
            || deco.hovered || deco.marked
        {
            continue
        }
        let visible = tile.quad.intersection(bounds)
        guard !visible.isNull, visible.width > 12,
            visible.maxY - tile.quad.minY > 48, visible.height > 12
        else { continue }
        let point = CGPoint(x: visible.midX, y: visible.maxY - 6)
        let expected = Support.body(
            tile,
            y: point.y,
            colors: colors,
            scale: painted.scale
        )
        #expect(
            Support.near(painted.rgb(point.x, point.y), expected),
            "tile \(crumbs) at \(point)",
            sourceLocation: sourceLocation
        )
        checked += 1
    }
    return checked
}

/// The placed tile at `crumbs` in `frame`, as the painter puts it on a
/// canvas at `scale`.
private func placedTile(
    _ frame: TreemapFrame,
    _ crumbs: [Int],
    theme: Theme,
    scale: CGFloat
) throws -> PlacedTile {
    let tiles = frame.tiles()
    return try #require(
        Support.placed(
            frame.mosaic(),
            theme: theme,
            size: frame.size,
            scale: scale
        )
        .first {
            tiles[$0.index].crumbs == crumbs
                && !Support.isOthers(tiles[$0.index])
        },
        "\(crumbs) is drawn"
    )
}

/// `color` over the opaque `ground` bytes, as the raster blends it.
private func over(_ color: HSLA, _ ground: [UInt8]) -> [UInt8] {
    let base = HSLA.fromRGB(
        RGBA(
            r: Double(ground[0]) / 255,
            g: Double(ground[1]) / 255,
            b: Double(ground[2]) / 255,
            a: 1
        )
    )
    return Support.rgbBytes(color.composited(over: base))
}

/// A colour's brightness, roughly: enough to say which of two is lighter.
private func brightness(_ color: [UInt8]) -> Int {
    Int(color[0]) * 3 + Int(color[1]) * 6 + Int(color[2])
}

// MARK: - Fills

@MainActor
@Test func theMosaicPaintsInEveryThemeAtBothScales() throws {
    let home = try scanned(TreemapFixture.home)
    for (name, theme) in try Support.everyTheme() {
        for scale in [1, 2] as [CGFloat] {
            var frame = TreemapFrame(tree: home)
            frame.depth = 4
            let painted = try Support.paint(frame, theme: theme, scale: scale)
            painted.save("home-\(name)@\(Int(scale))x")
            #expect(painted.isOpaque, "\(name)")
            let ground = Support.rgbBytes(theme.inset)
            let pixels = painted.width * painted.height
            #expect(painted.differing(from: ground) > pixels / 2, "\(name)")
            let checked = expectLeavesShowTheirFill(
                frame,
                painted,
                theme: theme
            )
            #expect(checked >= 5, "\(name) @\(scale)x: \(checked) leaves")
        }
    }
}

@Test func theSmallTreePaintsItsTiles() throws {
    let tree = try scanned(TreemapFixture.small)
    for theme in [Theme.dark, .light] {
        let frame = TreemapFrame(tree: tree)
        #expect(frame.tiles().count >= 3)
        let painted = try Support.paint(frame, theme: theme, scale: 2)
        painted.save("small-\(theme.isDark ? "dark" : "light")@2x")
        #expect(expectLeavesShowTheirFill(frame, painted, theme: theme) >= 2)
    }
}

@Test func theSelectionRingIsTheHighlight() throws {
    let tree = try scanned(TreemapFixture.small)
    let junk = try Support.crumbs(tree, path: "junk")
    for theme in [Theme.dark, .light] {
        for scale in [1, 2] as [CGFloat] {
            var frame = TreemapFrame(tree: tree)
            let plain = try Support.paint(frame, theme: theme, scale: scale)
            frame.selected = junk
            // Hovered too: the selection still wins, as it ranks higher.
            frame.hovered = junk
            let tile = try #require(frame.tile(junk))
            let quad = MosaicPainter.snap(cgRect(tile.rect), scale: scale)
            let painted = try Support.paint(frame, theme: theme, scale: scale)
            let highlight = Support.rgbBytes(theme.highlight)
            for point in [
                CGPoint(x: quad.minX + 0.5, y: quad.midY),
                CGPoint(x: quad.minX + 1.5, y: quad.midY),
                CGPoint(x: quad.maxX - 0.5, y: quad.midY),
                CGPoint(x: quad.midX, y: quad.minY + 0.5),
                CGPoint(x: quad.midX, y: quad.maxY - 0.5),
            ] {
                #expect(
                    Support.near(painted.rgb(point.x, point.y), highlight),
                    "\(point) at \(scale)x"
                )
            }
            // Two points wide, drawn inside the tile: no further in, and
            // never out into the gap beside it, where only its glow is.
            #expect(
                !Support.near(
                    painted.rgb(quad.minX + 2.5, quad.midY),
                    highlight
                )
            )
            let outside = painted.rgb(quad.minX - 0.5, quad.midY)
            #expect(!Support.near(outside, highlight))
            #expect(outside != plain.rgb(quad.minX - 0.5, quad.midY))
        }
    }
}

@Test func theHoverOutlineIsAQuietHairline() throws {
    let tree = try scanned(TreemapFixture.small)
    let blob = try Support.crumbs(tree, path: "junk", "blob.bin")
    for theme in [Theme.dark, .light] {
        var frame = TreemapFrame(tree: tree)
        frame.hovered = blob
        let colors = MosaicColors(theme: theme)
        let tile = try placedTile(frame, blob, theme: theme, scale: 2)
        let quad = tile.quad
        let painted = try Support.paint(frame, theme: theme, scale: 2)
        // A touch brighter: the lift washed over the tile's own body.
        let body = Support.body(tile, y: quad.midY, colors: colors, scale: 2)
        let lifted = over(colors.lift.hsla, body)
        #expect(brightness(lifted) > brightness(body))
        let ring = over(colors.hoverBorder.hsla, lifted)
        let edge = painted.rgb(quad.minX + 0.25, quad.midY)
        #expect(Support.near(edge, ring, by: 3), "\(edge)")
        // One point wide: the next pixel in is the lifted body.
        let inside = painted.rgb(quad.minX + 1.25, quad.midY)
        #expect(Support.near(inside, lifted, by: 3), "\(inside)")
    }
}

@Test func theHoverLiftRisesAndSettlesWithItsEffects() throws {
    let tree = try scanned(TreemapFixture.small)
    let blob = try Support.crumbs(tree, path: "junk", "blob.bin")
    let more = try Support.crumbs(tree, path: "junk", "deeper", "more.bin")
    for theme in [Theme.dark, .light] {
        var frame = TreemapFrame(tree: tree)
        frame.hovered = blob
        let tile = try placedTile(frame, blob, theme: theme, scale: 2)
        let other = try placedTile(frame, more, theme: theme, scale: 2)
        let at = CGPoint(x: tile.quad.midX, y: tile.quad.midY)
        let still = CGPoint(x: other.quad.midX, y: other.quad.midY)
        let mosaic = frame.mosaic()
        let paint = { (effects: MosaicEffects) in
            try Support.paint(
                mosaic,
                theme: theme,
                size: frame.size,
                scale: 2,
                effects: effects
            )
        }
        // Rising: the further up, the brighter.
        let lifts = try [0, 0.5, 1].map {
            brightness(try paint(MosaicEffects(hoverLift: $0)).rgb(at.x, at.y))
        }
        #expect(lifts[0] < lifts[1] && lifts[1] < lifts[2], "\(lifts)")
        // Before it rises, the tile is its own body.
        let colors = MosaicColors(theme: theme)
        let flat = try paint(MosaicEffects(hoverLift: 0))
        #expect(
            Support.near(
                flat.rgb(at.x, at.y),
                Support.body(tile, y: at.y, colors: colors, scale: 2)
            )
        )
        // Settling: the tile the pointer left keeps what is left of its
        // lift, and the one under the pointer is as it is at rest.
        var effects = MosaicEffects(hoverLift: 1)
        effects.fading = FadingTile(index: other.index, lift: 0.5)
        let settling = try paint(effects)
        #expect(
            brightness(settling.rgb(still.x, still.y))
                > brightness(flat.rgb(still.x, still.y))
        )
        #expect(
            settling.rgb(at.x, at.y) == (try paint(.settled)).rgb(at.x, at.y)
        )
    }
}

/// Where the marked badge sits before the name of `label`, at the default
/// rem.
private func badgeFrame(_ label: TileLabel, bounds: CGRect) throws -> CGRect {
    let typesetter = MosaicTypesetter(rem: baseRem)
    let metrics = typesetter.metrics
    let mask = try #require(
        MosaicPainter.mask(
            label,
            view: .identity,
            bounds: bounds,
            metrics: metrics
        )
    )
    let name = typesetter.line(
        label.text,
        face: MosaicPainter.face(label),
        color: MosaicInk(Theme.dark.foreground)
    )
    return try #require(
        MosaicPainter.place(
            label,
            mask: mask,
            metrics: metrics,
            name: name.measure,
            size: nil,
            badged: true
        )
        .badge
    )
}

@Test func aMarkedTileHasTheMarkedFillAndItsContentsGoWithIt() throws {
    let tree = try scanned(TreemapFixture.small)
    let junk = try Support.crumbs(tree, path: "junk")
    let blob = try Support.crumbs(tree, path: "junk", "blob.bin")
    let more = try Support.crumbs(tree, path: "junk", "deeper", "more.bin")
    for theme in [Theme.dark, .light] {
        let colors = MosaicColors(theme: theme)
        let bounds = CGRect(origin: .zero, size: TreemapFrame(tree: tree).size)
        var frame = TreemapFrame(tree: tree)
        frame.marked = [blob]
        var painted = try Support.paint(frame, theme: theme, scale: 2)
        var tile = try placedTile(frame, blob, theme: theme, scale: 2)
        var quad = tile.quad
        let marked = Support.bytes(colors.fill(tile.deco).pixel)
        #expect(Support.near(painted.rgb(quad.midX, quad.maxY - 6), marked))
        // Matte: no cushion, no hatch, one colour down its body.
        #expect(
            painted.colors(
                in: CGRect(
                    x: quad.minX + 4,
                    y: quad.midY,
                    width: quad.width - 8,
                    height: quad.height / 2 - 4
                )
            ) == [marked]
        )
        // Its ring is the danger colour.
        let danger = Support.rgbBytes(theme.danger)
        #expect(
            Support.near(painted.rgb(quad.minX + 0.5, quad.maxY - 20), danger)
        )
        // Under the pointer it keeps its ring: the lift shows the pointer,
        // the ring what is marked.
        frame.hovered = blob
        let hovered = try Support.paint(frame, theme: theme, scale: 2)
        #expect(
            Support.near(hovered.rgb(quad.minX + 0.5, quad.maxY - 20), danger)
        )
        #expect(
            Support.near(hovered.rgb(quad.minX + 1.5, quad.maxY - 20), danger)
        )
        frame.hovered = nil
        // Its name leads with the badge: a danger disc with a bar across.
        // Two files are called blob.bin; this one is junk's.
        let blobRect = try #require(frame.tile(blob)).rect
        let label = try #require(
            frame.mosaic().labels.first { $0.rect == blobRect }
        )
        let badge = try badgeFrame(label, bounds: bounds)
        #expect(
            Support.near(
                painted.rgb(badge.minX + badge.width * 0.15, badge.midY),
                danger
            )
        )
        #expect(
            Support.near(
                painted.rgb(badge.midX, badge.midY),
                Support.rgbBytes(colors.badgeGlyph.hsla)
            )
        )

        // Marking the directory takes everything inside it along: the
        // marked colour a step further at each level, so its structure
        // still reads, and the badge only on the directory's own name.
        frame.marked = [junk]
        painted = try Support.paint(frame, theme: theme, scale: 2)
        painted.save("marked-\(theme.isDark ? "dark" : "light")")
        for crumbs in [blob, more] {
            tile = try placedTile(frame, crumbs, theme: theme, scale: 2)
            quad = tile.quad
            #expect(tile.deco.covered)
            #expect(
                Support.near(
                    painted.rgb(quad.midX, quad.maxY - 6),
                    Support.bytes(colors.fill(tile.deco).pixel)
                ),
                "\(crumbs)"
            )
        }
        let parent = try placedTile(frame, junk, theme: theme, scale: 2)
        #expect(colors.fill(parent.deco).pixel != colors.fill(tile.deco).pixel)
        let inner = try #require(
            frame.mosaic().labels.first { $0.rect == blobRect }
        )
        // A covered tile's name is set in the danger colour too, but
        // carries no badge: nowhere at its start is the badge's bar.
        let unbadged = try badgeFrame(inner, bounds: bounds)
        let bar = Support.rgbBytes(colors.badgeGlyph.hsla)
        #expect(
            !painted.colors(in: unbadged).contains {
                Support.near($0, bar, by: 24)
            }
        )
    }
}

@Test func reclaimableSpaceIsHatchedUnlessItIsMarked() throws {
    let tree = try scanned(TreemapFixture.small)
    let cache = try Support.crumbs(tree, path: ".cache")
    let blob = try Support.crumbs(tree, path: ".cache", "blob.bin")
    #expect(tree.resolve(cache)?.reclaim != nil)
    let period = Int(Hatch.tile.period)
    for theme in [Theme.dark, .light] {
        var frame = TreemapFrame(tree: tree)
        let tile = try placedTile(frame, blob, theme: theme, scale: 2)
        let quad = tile.quad
        // Low in the body, clear of the labels and of any ring.
        let body = CGRect(
            x: quad.minX + 4,
            y: quad.maxY - 40,
            width: quad.width - 8,
            height: 34
        )
        var bare = frame.mosaic()
        bare.tiles = bare.tiles.map { tile in
            var tile = tile
            tile.reclaimable = false
            return tile
        }
        let hatched = try Support.paint(frame, theme: theme, scale: 2)
        let plain = try Support.paint(
            bare,
            theme: theme,
            size: frame.size,
            scale: 2
        )
        // The hatch is what differs: slash stripes one pixel wide and a
        // period apart along a row, one pixel further left on each row
        // down, on the same diagonals every tile's hatch runs on.
        var starts: [Int] = []
        for row in 0..<2 {
            let y = body.minY + (CGFloat(row) + 0.5) / 2
            var stripes: [Int] = []
            var column = Int(body.minX * 2)
            while CGFloat(column) < body.maxX * 2 {
                let x = (CGFloat(column) + 0.5) / 2
                if hatched.rgb(x, y) != plain.rgb(x, y) {
                    stripes.append(column)
                }
                column += 1
            }
            #expect(stripes.count > 10, "\(stripes.count) stripes")
            #expect(
                zip(stripes, stripes.dropFirst()).allSatisfy {
                    $1 - $0 == period
                },
                "\(stripes.prefix(6))"
            )
            starts.append(stripes.first ?? 0)
        }
        #expect((starts[0] - starts[1] + period) % period == 1)

        frame.marked = [cache]
        let marked = try Support.paint(frame, theme: theme, scale: 2)
        let colors = MosaicColors(theme: theme)
        let covered = try placedTile(frame, blob, theme: theme, scale: 2)
        #expect(
            marked.colors(in: body)
                == [Support.bytes(colors.fill(covered.deco).pixel)]
        )

        // Filtered out, it steps back, flat, and the hatch with it.
        frame.marked = []
        frame.matches = filter(tree, base: [], needle: "more")
        let out = try Support.paint(frame, theme: theme, scale: 2)
        #expect(out.colors(in: body).count == 1)
    }
}

@Test func theFirstLevelCarriesAStripInItsKindsColour() throws {
    let tree = try scanned(TreemapFixture.small)
    for theme in [Theme.dark, .light] {
        let colors = MosaicColors(theme: theme)
        var frame = TreemapFrame(tree: tree)
        var painted = try Support.paint(frame, theme: theme, scale: 2)
        var tops = 0
        let placed = Support.placed(
            frame.mosaic(),
            theme: theme,
            size: frame.size,
            scale: 2
        )
        for tile in placed where tile.deco.depth == 0 {
            let quad = tile.quad
            guard quad.width > 4, quad.height > 4 else { continue }
            #expect(
                Support.near(
                    painted.rgb(quad.midX, quad.minY + 0.75),
                    Support.rgbBytes(theme.categoryAccent(tile.deco.category))
                ),
                "\(tile.index)"
            )
            // Two points tall: under it, the tile's own body (a hatch
            // crosses a reclaimable one's).
            if !MosaicPainter.isHatched(tile.deco) {
                let y = quad.minY + 2.25
                #expect(
                    Support.near(
                        painted.rgb(quad.midX, y),
                        Support.body(tile, y: y, colors: colors, scale: 2)
                    ),
                    "\(tile.index)"
                )
            }
            tops += 1
        }
        #expect(tops >= 2)

        // Age mode colours by age alone: no strip.
        frame.colorMode = .age
        painted = try Support.paint(frame, theme: theme, scale: 2)
        painted.save("age-\(theme.isDark ? "dark" : "light")")
        let aged = Support.placed(
            frame.mosaic(),
            theme: theme,
            size: frame.size,
            scale: 2
        )
        for tile in aged where tile.deco.depth == 0 {
            #expect(tile.deco.ageBucket != nil)
            // A hatch crosses the top row too; only the strip is at issue.
            guard !tile.deco.reclaimable else { continue }
            let quad = tile.quad
            guard quad.width > 4, quad.height > 4 else { continue }
            let y = quad.minY + 0.75
            #expect(
                Support.near(
                    painted.rgb(quad.midX, y),
                    Support.body(tile, y: y, colors: colors, scale: 2)
                )
            )
        }
        #expect(expectLeavesShowTheirFill(frame, painted, theme: theme) >= 2)
    }
}

@Test func aTileWithUnreadablePartsIsFlaggedInItsCorner() throws {
    let tree = try scanned(TreemapFixture.small)
    let junk = try Support.crumbs(tree, path: "junk")
    for scale in [1, 2] as [CGFloat] {
        var frame = TreemapFrame(tree: tree)
        frame.unreadable = [junk]
        let tile = try #require(frame.tile(junk))
        let quad = MosaicPainter.snap(cgRect(tile.rect), scale: scale)
        let painted = try Support.paint(frame, theme: .dark, scale: scale)
        // A dot tucked into the corner, inside its rounding.
        #expect(
            Support.near(
                painted.rgb(quad.maxX - 5, quad.minY + 5),
                Support.rgbBytes(Theme.dark.caution)
            )
        )
        frame.unreadable = []
        let clean = try Support.paint(frame, theme: .dark, scale: scale)
        #expect(
            !Support.near(
                clean.rgb(quad.maxX - 5, quad.minY + 5),
                Support.rgbBytes(Theme.dark.caution)
            )
        )
    }
}

@Test func whatTheFindTextLeavesOutStepsBackTowardTheGround() throws {
    let tree = try scanned(TreemapFixture.small)
    for theme in [Theme.dark, .light] {
        var frame = TreemapFrame(tree: tree)
        frame.matches = filter(tree, base: [], needle: "more")
        let mosaic = frame.mosaic()
        let states = Set(mosaic.tiles.map(\.filtered))
        #expect(states == [.shown, .holds, .out])
        // The matched name keeps its colour; the rest are dimmed.
        #expect(mosaic.labels.contains { $0.dim })
        let painted = try Support.paint(frame, theme: theme, scale: 2)
        painted.save("find-\(theme.isDark ? "dark" : "light")")
        #expect(expectLeavesShowTheirFill(frame, painted, theme: theme) >= 2)

        // The steps are the Rust ones: 0.55 toward the ground for a
        // directory that holds matches, 0.82 for one that holds none.
        let colors = MosaicColors(theme: theme)
        let deco = try #require(mosaic.tiles.first)
        var shown = deco
        shown.filtered = .shown
        for (state, share) in [(Filtered.holds, 0.55), (.out, 0.82)] {
            var stepped = deco
            stepped.filtered = state
            let expected = colors.fill(shown).hsla
                .mixed(toward: theme.inset, by: share)
            #expect(
                Support.rgbBytes(colors.fill(stepped).hsla)
                    == Support.rgbBytes(expected)
            )
        }
    }
}

// MARK: - Corners, cushions, the glow and the lift

/// A tile of `depth` at `rect`, in the code hue, and nothing else about it.
private func plainTile(
    _ rect: Rect,
    depth: Int,
    marked: Bool = false,
    selected: Bool = false
) -> TileDeco {
    TileDeco(
        rect: rect,
        depth: depth,
        category: .code,
        ageBucket: nil,
        reclaimable: false,
        filtered: .shown,
        unreadable: false,
        marked: marked,
        covered: false,
        hovered: false,
        selected: selected
    )
}

/// How far `color` is from `ground`, over all three channels.
private func distance(_ color: [UInt8], from ground: [UInt8]) -> Int {
    zip(color, ground).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
}

@Test func anOpenDirectoryIsHatchedInItsBandAlone() throws {
    // A reclaimable directory drawn open is hatched where it shows, its
    // band, not again under its children; and a band scrolled up out of a
    // magnified view has nothing to hatch, and paints nothing.
    let size = CGSize(width: 200, height: 160)
    for (name, offset) in [("in view", 0.0), ("band above it", -60.0)] {
        var parent = plainTile(
            Rect(x: 0, y: 10 + offset, w: 200, h: 150),
            depth: 0
        )
        parent.reclaimable = true
        var child = plainTile(
            Rect(x: 4, y: 40 + offset, w: 192, h: 116),
            depth: 1
        )
        child.reclaimable = true
        let painted = try Support.paint(
            Mosaic(tiles: [parent, child]),
            theme: .dark,
            size: size,
            scale: 2
        )
        if offset == 0 {
            // The band's rows, below its strip, carry the hatch.
            let band = CGRect(x: 10, y: 16, width: 180, height: 20)
            #expect(painted.colors(in: band).count > 1, "\(name)")
        }
        // Under the child: its own fill and hatch, once.
        let body = CGRect(x: 20, y: 60 + offset, width: 160, height: 40)
        #expect(painted.colors(in: body).count > 1, "\(name)")
    }
}

@Test func cornersAreRoundedByLevelAndNotWhenTiny() throws {
    let wide = CGRect(x: 0, y: 0, width: 100, height: 80)
    #expect(MosaicPainter.cornerRadius(depth: 0, quad: wide) == 3)
    #expect(MosaicPainter.cornerRadius(depth: 1, quad: wide) == 2)
    #expect(MosaicPainter.cornerRadius(depth: 3, quad: wide) == 2)
    // Small, it rounds less; tiny, not at all.
    let small = CGRect(x: 0, y: 0, width: 6, height: 40)
    #expect(MosaicPainter.cornerRadius(depth: 1, quad: small) == 1.5)
    let tiny = CGRect(x: 0, y: 0, width: 3.5, height: 40)
    #expect(MosaicPainter.cornerRadius(depth: 1, quad: tiny) == 0)

    // A region, a file inside it and a sliver beside that.
    let outer = plainTile(Rect(x: 20, y: 20, w: 160, h: 120), depth: 0)
    let inner = plainTile(Rect(x: 30, y: 50, w: 60, h: 60), depth: 1)
    let sliver = plainTile(Rect(x: 120, y: 60, w: 3.5, h: 40), depth: 1)
    let size = CGSize(width: 200, height: 160)
    for theme in [Theme.dark, .light] {
        let colors = MosaicColors(theme: theme)
        let mosaic = Mosaic(tiles: [outer, inner, sliver])
        let painted = try Support.paint(
            mosaic,
            theme: theme,
            size: size,
            scale: 2
        )
        painted.save("corners-\(theme.isDark ? "dark" : "light")")
        let placed = Support.placed(mosaic, theme: theme, size: size, scale: 2)
        let ground = Support.rgbBytes(theme.inset)
        let region = Support.bytes(colors.fill(outer).pixel)
        // The corner pixel of the region shows the ground beneath it; a
        // little along either edge is the region itself.
        #expect(Support.near(painted.rgb(20.1, 139.9), ground))
        #expect(Support.near(painted.rgb(179.9, 139.9), ground))
        #expect(Support.near(painted.rgb(20.25, 130), region))
        #expect(Support.near(painted.rgb(30, 139.75), region))
        // The file's corner shows the region it sits in, and its edge is
        // its own cushioned body.
        #expect(Support.near(painted.rgb(30.1, 109.9), region))
        #expect(
            Support.near(
                painted.rgb(30.25, 80),
                Support.body(placed[1], y: 80, colors: colors, scale: 2)
            )
        )
        // The sliver is square: its corner pixel is its own.
        #expect(
            Support.near(
                painted.rgb(120.1, 60.1),
                Support.bytes(colors.fill(sliver).pixel)
            )
        )
        // The strip over the region follows its rounded top.
        #expect(Support.near(painted.rgb(20.1, 20.1), ground))
        #expect(
            Support.near(
                painted.rgb(100, 20.25),
                Support.rgbBytes(theme.categoryAccent(.code))
            )
        )
    }
}

@Test func aCornerMaskCoversWhatTheArcCovers() {
    let mask = CornerMask(radius: 6)
    #expect(mask.size == 6)
    // The very corner is outside the arc; the innermost pixel inside it.
    #expect(mask.coverage[0] < 0.05)
    #expect(mask.coverage[5 * 6 + 5] == 1)
    for row in 0..<6 {
        for column in 0..<6 {
            // The same seen from either edge.
            #expect(
                abs(
                    mask.coverage[row * 6 + column]
                        - mask.coverage[column * 6 + row]) < 1e-6
            )
            // Never less covered further in.
            if column > 0 {
                #expect(
                    mask.coverage[row * 6 + column]
                        >= mask.coverage[row * 6 + column - 1]
                )
            }
        }
        // From the first solid column on, a row is solid.
        for column in mask.solidFrom[row]..<6 {
            #expect(mask.coverage[row * 6 + column] == 1)
        }
    }
    // What the arc cuts away is a square less a quarter circle.
    let cut = mask.coverage.reduce(0) { $0 + Double(1 - $1) }
    #expect(abs(cut - 36 * (1 - Double.pi / 4)) < 0.3, "\(cut)")
}

@Test func leavesAreCushionedRestrainedly() throws {
    let size = CGSize(width: 160, height: 240)
    for theme in [Theme.dark, .light] {
        let colors = MosaicColors(theme: theme)
        let leaf = plainTile(Rect(x: 20, y: 20, w: 120, h: 200), depth: 1)
        let painted = try Support.paint(
            Mosaic(tiles: [leaf]),
            theme: theme,
            size: size,
            scale: 2
        )
        painted.save("cushion-\(theme.isDark ? "dark" : "light")")
        let fill = Support.bytes(colors.fill(leaf).pixel)
        // Down the middle: lightest at the top, darkest at the bottom,
        // never lighter again on the way down.
        var column: [[UInt8]] = []
        var y: CGFloat = 20.25
        while y < 220 {
            column.append(painted.rgb(80, y))
            y += 0.5
        }
        let levels = column.map(brightness)
        #expect(zip(levels, levels.dropFirst()).allSatisfy { $0 >= $1 })
        let top = column[0]
        let bottom = column[column.count - 1]
        // Lit one way only: the light card from its top down to the fill,
        // the dark card from the fill down to its sunk bottom, the way that
        // takes the words further from their ground.
        if theme.isDark {
            #expect(Support.near(top, fill))
            #expect(brightness(bottom) < brightness(fill))
        } else {
            #expect(brightness(top) > brightness(fill))
            #expect(Support.near(bottom, fill))
        }
        // Restrained: no channel moves more than a tenth of its range.
        for end in [top, bottom] {
            for channel in 0..<3 {
                #expect(abs(Int(end[channel]) - Int(fill[channel])) <= 26)
            }
        }

        // Flat: a directory drawn open, a marked tile, a tile the find
        // text leaves out.
        let open = plainTile(Rect(x: 20, y: 20, w: 120, h: 200), depth: 1)
        let child = plainTile(Rect(x: 30, y: 60, w: 100, h: 150), depth: 2)
        let band = CGRect(x: 30, y: 24, width: 100, height: 30)
        let parent = try Support.paint(
            Mosaic(tiles: [open, child]),
            theme: theme,
            size: size,
            scale: 2
        )
        #expect(parent.colors(in: band) == [fill])
        let body = CGRect(x: 30, y: 30, width: 100, height: 180)
        let marked = plainTile(
            Rect(x: 20, y: 20, w: 120, h: 200),
            depth: 1,
            marked: true
        )
        let matte = try Support.paint(
            Mosaic(tiles: [marked]),
            theme: theme,
            size: size,
            scale: 2
        )
        #expect(matte.colors(in: body).count == 1)
        var out = leaf
        out.filtered = .out
        let stepped = try Support.paint(
            Mosaic(tiles: [out]),
            theme: theme,
            size: size,
            scale: 2
        )
        #expect(stepped.colors(in: body).count == 1)
    }
}

@Test func theCushionIsLitTheWayItsWordsRead() {
    let fill = HSLA(h: 0.6, s: 0.3, l: 0.5)
    // A cushion lit above and sunk below passes through its fill at its
    // pivot, halfway down.
    let both = MosaicCushion(light: 0.2, shade: 0.1)
    #expect(both.shade(fill, at: 0.5).pixel == fill.pixel)
    #expect(both.shade(fill, at: 0).l > fill.l)
    #expect(both.shade(fill, at: 1).l < fill.l)
    // The light card's names are dark: its tiles are only lit, from the
    // top down to the fill at the bottom.
    let light = MosaicCushion.card(dark: false)
    #expect(light.shade(fill, at: 0).l > fill.l)
    #expect(light.shade(fill, at: 1).pixel == fill.pixel)
    // The dark card's names are light: its tiles only sink, from the fill
    // at the top.
    let dark = MosaicCushion.card(dark: true)
    #expect(dark.shade(fill, at: 0).pixel == fill.pixel)
    #expect(dark.shade(fill, at: 1).l < fill.l)
    for step in 0...20 {
        let at = Double(step) / 20
        #expect(light.shade(fill, at: at).l >= fill.l - 1e-9, "\(at)")
        #expect(dark.shade(fill, at: at).l <= fill.l + 1e-9, "\(at)")
    }
    // Restrained on either card.
    #expect(light.light < 0.5 && dark.shade < 0.25)
    // A ramp has a step per row share, top to bottom.
    let ink = MosaicInk(
        HSLA(h: 0.6, s: 0.3, l: 0.5), cushion: .card(dark: true))
    #expect(ink.ramp.count == MosaicCushion.steps + 1)
    let box = PixelBox(left: 0, top: 10, right: 50, bottom: 110)
    #expect(MosaicPainter.rampStep(row: 10, of: box) == 0)
    #expect(MosaicPainter.rampStep(row: 109, of: box) == MosaicCushion.steps)
    #expect(MosaicPainter.rampStep(row: 60, of: box) == 32)
}

@Test func theSelectionGlowsSoftlyOutsideItsRing() throws {
    let size = CGSize(width: 240, height: 200)
    let rect = Rect(x: 60, y: 60, w: 120, h: 80)
    for theme in [Theme.dark, .light] {
        let selected = try Support.paint(
            Mosaic(tiles: [plainTile(rect, depth: 1, selected: true)]),
            theme: theme,
            size: size,
            scale: 2
        )
        selected.save("glow-\(theme.isDark ? "dark" : "light")")
        let plain = try Support.paint(
            Mosaic(tiles: [plainTile(rect, depth: 1)]),
            theme: theme,
            size: size,
            scale: 2
        )
        let ground = Support.rgbBytes(theme.inset)
        let highlight = Support.rgbBytes(theme.highlight)
        // Out from the left edge: strongest at the ring, fading with
        // distance, and gone past its reach.
        let strengths = [0.25, 1.25, 3.25, 6.25].map {
            distance(selected.rgb(60 - $0, 100), from: ground)
        }
        #expect(
            zip(strengths, strengths.dropFirst()).allSatisfy { $0 > $1 },
            "\(strengths)"
        )
        #expect(strengths.last ?? 0 > 0)
        let beyond = 60 - MosaicPainter.glowReach - 1
        #expect(selected.rgb(beyond, 100) == ground)
        // Soft: never the solid highlight outside the tile.
        #expect(!Support.near(selected.rgb(59.75, 100), highlight))
        // Round the corner too.
        #expect(distance(selected.rgb(58.5, 58.5), from: ground) > 0)
        // And nothing inside the ring changes.
        let inside = CGRect(x: 63, y: 63, width: 114, height: 74)
        #expect(selected.pixels(in: inside) == plain.pixels(in: inside))
    }
}

@Test func theHoverLiftRisesQuicklyAndSettlesAfter() {
    let first = TileDeco(
        rect: Rect(x: 0, y: 0, w: 50, h: 50),
        depth: 0,
        category: .code,
        ageBucket: nil,
        reclaimable: false,
        filtered: .shown,
        unreadable: false,
        marked: false,
        covered: false,
        hovered: true,
        selected: false
    )
    var second = first
    second.rect = Rect(x: 60, y: 0, w: 50, h: 50)
    second.hovered = false
    var mosaic = Mosaic(tiles: [first, second])
    let start = ContinuousClock.now
    var motion = HoverMotion()
    var effects = motion.frame(
        hovered: [0],
        mosaic: mosaic,
        now: start,
        still: false
    )
    #expect(effects.hoverLift == 0)
    #expect(motion.isMoving(at: start))
    effects = motion.frame(
        hovered: [0],
        mosaic: mosaic,
        now: start + HoverMotion.rise / 2,
        still: false
    )
    // Eased out: most of the way up by half its time.
    #expect(effects.hoverLift > 0.8 && effects.hoverLift < 1)
    let up = start + HoverMotion.rise
    effects = motion.frame(hovered: [0], mosaic: mosaic, now: up, still: false)
    #expect(effects.hoverLift == 1)
    #expect(!motion.isMoving(at: up))

    // The pointer moves on: the next tile rises, the first settles back
    // from where it was, more slowly.
    mosaic.tiles[0].hovered = false
    mosaic.tiles[1].hovered = true
    effects = motion.frame(hovered: [1], mosaic: mosaic, now: up, still: false)
    #expect(effects.fading == FadingTile(index: 0, lift: 1))
    #expect(HoverMotion.fall > HoverMotion.rise)
    effects = motion.frame(
        hovered: [1],
        mosaic: mosaic,
        now: up + HoverMotion.fall / 2,
        still: false
    )
    let halfway = effects.fading?.lift ?? 0
    #expect(halfway > 0 && halfway < 0.5)
    #expect(motion.isMoving(at: up + HoverMotion.fall / 2))
    effects = motion.frame(
        hovered: [1],
        mosaic: mosaic,
        now: up + HoverMotion.fall,
        still: false
    )
    #expect(effects.fading == nil)
    #expect(!motion.isMoving(at: up + HoverMotion.fall))

    // A layout that moves the settling tile lets it land at once.
    let later = up + HoverMotion.fall * 2
    _ = motion.frame(hovered: nil, mosaic: mosaic, now: later, still: false)
    mosaic.tiles[1].rect.x += 10
    mosaic.tiles[1].hovered = false
    effects = motion.frame(
        hovered: nil,
        mosaic: mosaic,
        now: later + .milliseconds(10),
        still: false
    )
    #expect(effects.fading == nil)

    // Under Reduce Motion a tile is up at once, and down at once.
    var still = HoverMotion()
    mosaic.tiles[0].hovered = true
    effects = still.frame(hovered: [0], mosaic: mosaic, now: start, still: true)
    #expect(effects.hoverLift == 1)
    #expect(!still.isMoving(at: start))
    mosaic.tiles[0].hovered = false
    effects = still.frame(hovered: nil, mosaic: mosaic, now: start, still: true)
    #expect(effects.fading == nil)
    #expect(!still.isMoving(at: start))
}

// MARK: - The view transform

@Test func zoomIsAppliedWhilePainting() throws {
    let home = try scanned(TreemapFixture.home)
    var frame = TreemapFrame(tree: home)
    frame.depth = 4
    let flat = try Support.paint(frame, theme: .dark, scale: 2)
    frame.view = ViewTransform.identity
        .zoomed(atX: 300, y: 220, factor: 2.6, ceiling: ViewTransform.maxScale)
        .clamped(frame.size)
    // The layout is the same; only the transform differs (Invariant 8).
    #expect(frame.mosaic().tiles.map(\.rect) == frame.tiles().map(\.rect))
    let zoomed = try Support.paint(frame, theme: .dark, scale: 2)
    zoomed.save("zoomed-dark@2x")
    #expect(zoomed.isOpaque)
    #expect(zoomed.bytes != flat.bytes)
    #expect(expectLeavesShowTheirFill(frame, zoomed, theme: .dark) >= 2)
}

@Test func midTransitionTilesAreDrawnOnTheirWay() throws {
    let tree = try scanned(TreemapFixture.small)
    let start = ContinuousClock.now
    var frame = TreemapFrame(tree: tree)
    let settled = try Support.paint(frame, theme: .dark)
    let transition = LayoutTransition(
        src: Rect(x: 400, y: 260, w: 240, h: 160),
        dst: Rect(x: 0, y: 0, w: 960, h: 640),
        now: start
    )
    frame.transition = transition
    frame.at = start + transition.duration / 2
    let mosaic = frame.mosaic()
    #expect(mosaic.tiles.map(\.rect) != frame.tiles().map(\.rect))
    for scale in [1, 2] as [CGFloat] {
        let moving = try Support.paint(frame, theme: .dark, scale: scale)
        moving.save("transition-dark@\(Int(scale))x")
        #expect(moving.isOpaque)
        if scale == 1 {
            #expect(moving.bytes != settled.bytes)
        }
        #expect(expectLeavesShowTheirFill(frame, moving, theme: .dark) >= 1)
    }
}

@Test func tileEdgesLandOnWholePixels() {
    let rect = CGRect(x: 10.3, y: 5.6, width: 20.4, height: 3.3)
    #expect(
        MosaicPainter.snap(rect, scale: 1)
            == CGRect(x: 10, y: 6, width: 21, height: 3)
    )
    #expect(
        MosaicPainter.snap(rect, scale: 2)
            == CGRect(x: 10.5, y: 5.5, width: 20, height: 3.5)
    )
    // Each edge is rounded, not the size, so neighbours stay flush.
    let left = CGRect(x: 0.2, y: 0, width: 10.3, height: 5)
    let right = CGRect(x: 10.5, y: 0, width: 7.45, height: 5)
    for scale in [1, 2, 3] as [CGFloat] {
        #expect(
            MosaicPainter.snap(left, scale: scale).maxX
                == MosaicPainter.snap(right, scale: scale).minX
        )
    }
    // A sliver never comes out with a negative size.
    let sliver = MosaicPainter.snap(
        CGRect(x: 5.4, y: 0, width: 0.05, height: 1),
        scale: 1
    )
    #expect(sliver.width == 0)
}

@Test func tilesBelowHalfAPointAreNotPainted() throws {
    let size = CGSize(width: 40, height: 40)
    let tile = { (width: Double) in
        TileDeco(
            rect: Rect(x: 10, y: 10, w: width, h: 20),
            depth: 1,
            category: .code,
            ageBucket: nil,
            reclaimable: false,
            filtered: .shown,
            unreadable: false,
            marked: false,
            covered: false,
            hovered: false,
            selected: true
        )
    }
    let ground = Support.rgbBytes(Theme.dark.inset)
    let skipped = try Support.paint(
        Mosaic(tiles: [tile(0.5)]),
        theme: .dark,
        size: size
    )
    #expect(skipped.differing(from: ground) == 0)
    let drawn = try Support.paint(
        Mosaic(tiles: [tile(0.6)]),
        theme: .dark,
        size: size
    )
    #expect(drawn.differing(from: ground) > 0)
}

// MARK: - Labels

private func label(
    _ text: String,
    rect: Rect,
    header: Rect? = nil,
    depth: Int = 1,
    size: String = "12K"
) -> TileLabel {
    TileLabel(
        text: text,
        rect: rect,
        header: header,
        depth: depth,
        dim: false,
        marked: false,
        sizeText: size
    )
}

@Test func aLabelIsClippedToTheRegionItOwns() throws {
    let rect = Rect(x: 20, y: 20, w: 60, h: 60)
    let tile = TileDeco(
        rect: rect,
        depth: 1,
        category: .code,
        ageBucket: nil,
        reclaimable: false,
        filtered: .shown,
        unreadable: false,
        marked: false,
        covered: false,
        hovered: false,
        selected: false
    )
    let size = CGSize(width: 200, height: 120)
    let ground = Support.rgbBytes(Theme.dark.inset)
    // The tile alone, nothing written on it.
    let bare = try Support.paint(
        Mosaic(tiles: [tile]),
        theme: .dark,
        size: size,
        scale: 2
    )

    // A closed tile: the name runs out of room at the tile's edge.
    let closed = try Support.paint(
        Mosaic(
            tiles: [tile],
            labels: [label("a-name-far-too-long-for-its-tile", rect: rect)]
        ),
        theme: .dark,
        size: size,
        scale: 2
    )
    closed.save("label-closed")
    #expect(
        closed.colors(in: CGRect(x: 80, y: 0, width: 120, height: 120)) == [
            ground
        ])
    #expect(
        closed.colors(in: CGRect(x: 20, y: 20, width: 60, height: 18)).count > 2
    )

    // A band: the name stays in it, never over the children below.
    let band = Rect(x: 20, y: 20, w: 60, h: 16)
    let banded = try Support.paint(
        Mosaic(
            tiles: [tile],
            labels: [
                label(
                    "a-name-far-too-long-for-its-band",
                    rect: rect,
                    header: band,
                    depth: 0
                )
            ]
        ),
        theme: .dark,
        size: size,
        scale: 2
    )
    #expect(
        banded.colors(in: CGRect(x: 80, y: 0, width: 120, height: 120)) == [
            ground
        ])
    let below = CGRect(x: 20, y: 36, width: 60, height: 44)
    #expect(banded.pixels(in: below) == bare.pixels(in: below))
    #expect(
        banded.colors(in: CGRect(x: 20, y: 20, width: 60, height: 16)).count > 2
    )
}

@Test func theSizeTextHasThreePlaces() {
    let metrics = MosaicLabelMetrics(rem: baseRem)
    let name = MosaicLineMeasure(width: 40, ascent: 11, descent: 3)
    let size = MosaicLineMeasure(width: 30, ascent: 10, descent: 2)
    // A name sits centred in the top line of its region: the line box and
    // the inset either side of it, or all of a region shorter than that.
    let line = metrics.lineHeight + metrics.inset * 2
    let centred = { (height: CGFloat) in
        min(height, line) / 2 + (11 - 3) / 2
    }
    let baseline = centred(line)
    let band = Rect(x: 0, y: 0, w: 300, h: 22)

    // A first-level band: at the far end, where the sizes read as a column.
    let first = MosaicPainter.place(
        label("src", rect: band, header: band, depth: 0),
        mask: CGRect(x: 0, y: 0, width: 300, height: 22),
        metrics: metrics,
        name: name,
        size: size
    )
    #expect(first.name == CGPoint(x: metrics.padding, y: centred(22)))
    #expect(
        first.size == CGPoint(x: 300 - 30 - metrics.padding, y: centred(22))
    )

    // A deeper band: after the name, on the same baseline.
    let deeper = MosaicPainter.place(
        label("tries", rect: band, header: band, depth: 1),
        mask: CGRect(x: 0, y: 0, width: 300, height: 16),
        metrics: metrics,
        name: name,
        size: size
    )
    #expect(
        deeper.size
            == CGPoint(x: metrics.padding + 40 + metrics.gap, y: centred(16))
    )

    // A closed tile tall enough: stacked under the name.
    let tall = MosaicPainter.place(
        label("work", rect: band),
        mask: CGRect(x: 0, y: 0, width: 300, height: 40),
        metrics: metrics,
        name: name,
        size: size
    )
    let stacked =
        metrics.inset + metrics.lineHeight * 0.92 + metrics.lineHeight / 2
        + (10 - 2) / 2
    #expect(tall.size == CGPoint(x: metrics.padding, y: stacked))

    #expect(tall.name == CGPoint(x: metrics.padding, y: baseline))

    // A closed tile too short to stack: after the name, as in a band.
    let short = MosaicPainter.place(
        label("work", rect: band),
        mask: CGRect(x: 0, y: 0, width: 300, height: 30),
        metrics: metrics,
        name: name,
        size: size
    )
    #expect(
        short.size
            == CGPoint(x: metrics.padding + 40 + metrics.gap, y: baseline)
    )

    // No room: the size is left out rather than crowding the name.
    for (header, depth, width) in [
        (band as Rect?, 1, 70.0), (nil, 1, 70), (band, 0, 80),
    ] {
        let crowded = MosaicPainter.place(
            label("target", rect: band, header: header, depth: depth),
            mask: CGRect(x: 0, y: 0, width: width, height: 20),
            metrics: metrics,
            name: MosaicLineMeasure(width: 60, ascent: 11, descent: 3),
            size: size
        )
        #expect(crowded.size == nil, "\(depth) \(width)")
    }

    // And none asked for, none placed.
    let bare = MosaicPainter.place(
        label("x", rect: band, size: ""),
        mask: CGRect(x: 0, y: 0, width: 300, height: 40),
        metrics: metrics,
        name: name,
        size: nil
    )
    #expect(bare.size == nil)
}

@Test func aSizeIsShownWholeOrNotAtAll() {
    // A size after a name only when all of it fits, with its gap: cut at
    // the tile's edge, "723MiB" read as "723MiE".
    let metrics = MosaicLabelMetrics(rem: baseRem)
    let name = MosaicLineMeasure(width: 90, ascent: 11, descent: 3)
    let size = MosaicLineMeasure(width: 49, ascent: 10, descent: 2)
    let band = Rect(x: 0, y: 0, w: 300, h: 16)
    let tight = 90 + 49 + metrics.gap + metrics.padding * 2 - 1
    let crowded = MosaicPainter.place(
        label("dispatchdock", rect: band, header: band, depth: 1),
        mask: CGRect(x: 0, y: 0, width: tight, height: 16),
        metrics: metrics,
        name: name,
        size: size
    )
    #expect(crowded.size == nil)
    let roomy = MosaicPainter.place(
        label("dispatchdock", rect: band, header: band, depth: 1),
        mask: CGRect(x: 0, y: 0, width: tight + 2, height: 16),
        metrics: metrics,
        name: name,
        size: size
    )
    #expect(roomy.size != nil)
    // Stacked under a name, too: a size wider than its tile is left out.
    let narrow = MosaicPainter.place(
        label("work", rect: band),
        mask: CGRect(x: 0, y: 0, width: 40, height: 40),
        metrics: metrics,
        name: MosaicLineMeasure(width: 20, ascent: 11, descent: 3),
        size: size
    )
    #expect(narrow.size == nil)
}

@Test func aNameTooLongForItsTileEndsInAnEllipsis() {
    let typesetter = MosaicTypesetter(rem: baseRem)
    let ink = MosaicInk(Theme.dark.foreground)
    let text = "fantasy-surf-league-frontend"
    let whole = typesetter.line(text, face: .name, color: ink)
    // Cut at its end, a little short of the room it has, never mid-letter.
    let cut = typesetter.line(
        text,
        face: .name,
        color: ink,
        fitting: 80,
        cut: .end
    )
    #expect(cut.measure.width <= 80)
    #expect(cut.measure.width > 40, "cut to the room, not to nothing")
    #expect(cut.line !== whole.line)
    // A file keeps its extension: cut in the middle, as Finder cuts one.
    let file = typesetter.line(
        "Photos Library.photoslibrary",
        face: .name,
        color: ink,
        fitting: 90,
        cut: .middle
    )
    #expect(file.measure.width <= 90)
    // What fits is set whole, and a cut is kept for the next frame.
    let fits = typesetter.line(
        "src",
        face: .name,
        color: ink,
        fitting: 200,
        cut: .end
    )
    #expect(fits.line === typesetter.line("src", face: .name, color: ink).line)
    let again = typesetter.line(
        text,
        face: .name,
        color: ink,
        fitting: 80.4,
        cut: .end
    )
    #expect(again.line === cut.line)
}

@Test func aMarkedTilesNameLeadsWithItsBadge() throws {
    let metrics = MosaicLabelMetrics(rem: baseRem)
    let name = MosaicLineMeasure(width: 40, ascent: 11, descent: 3)
    let size = MosaicLineMeasure(width: 30, ascent: 10, descent: 2)
    let band = Rect(x: 0, y: 0, w: 300, h: 16)
    let mask = CGRect(x: 0, y: 0, width: 300, height: 16)
    let tile = label("tries", rect: band, header: band, depth: 1)
    let plain = MosaicPainter.place(
        tile,
        mask: mask,
        metrics: metrics,
        name: name,
        size: size
    )
    #expect(plain.badge == nil)
    let badged = MosaicPainter.place(
        tile,
        mask: mask,
        metrics: metrics,
        name: name,
        size: size,
        badged: true
    )
    let badge = try #require(badged.badge)
    let side = MosaicPainter.badgeSide(metrics)
    #expect(badge.minX == metrics.padding)
    #expect(badge.width == side && badge.height == side)
    // The name makes way for it, and what follows the name on its line
    // moves with it.
    #expect(badged.name.x > badge.maxX)
    #expect(badged.name.y == plain.name.y)
    let shift = badged.name.x - plain.name.x
    let moved = try #require(badged.size).x - (try #require(plain.size)).x
    #expect(abs(moved - shift) < 1e-9)
    // Centred on the capitals, inside the band.
    #expect(badge.minY >= mask.minY && badge.maxY <= mask.maxY)
    #expect(abs(badge.midY - (plain.name.y - metrics.nameSize * 0.35)) < 1e-9)
}

@Test func namesAreSetInSFProAndSizesInRoundedEvenFigures() {
    let weight = { (font: CTFont) -> CGFloat in
        let traits = CTFontCopyTraits(font) as NSDictionary
        return (traits[kCTFontWeightTrait] as? NSNumber).map {
            CGFloat($0.doubleValue)
        } ?? 0
    }
    let name = MosaicTypesetter.font(.name, size: 12)
    let bold = MosaicTypesetter.font(.bold, size: 12)
    let figures = MosaicTypesetter.font(.size, size: 11)
    // Medium for a name, semibold for a region's.
    #expect(abs(weight(name) - NSFont.Weight.medium.rawValue) < 0.01)
    #expect(abs(weight(bold) - NSFont.Weight.semibold.rawValue) < 0.01)
    #expect(
        (CTFontCopyPostScriptName(figures) as String).contains("Rounded")
    )
    // Tabular: every digit as wide as every other.
    let typesetter = MosaicTypesetter(rem: baseRem)
    let ink = MosaicInk(Theme.dark.foreground)
    let widths = (0...9).map {
        typesetter.line("\($0)", face: .size, color: ink).measure.width
    }
    #expect(Set(widths).count == 1, "\(widths)")
}

@Test func onlyAFirstLevelBandIsSetInBold() {
    let rect = Rect(x: 0, y: 0, w: 100, h: 100)
    let band = Rect(x: 0, y: 0, w: 100, h: 20)
    #expect(
        MosaicPainter.face(label("a", rect: rect, header: band, depth: 0))
            == .bold)
    #expect(
        MosaicPainter.face(label("a", rect: rect, header: nil, depth: 0))
            == .name)
    #expect(
        MosaicPainter.face(label("a", rect: rect, header: band, depth: 1))
            == .name)
}

@Test func tooSmallARegionGetsNoLabel() {
    let metrics = MosaicLabelMetrics(rem: baseRem)
    let bounds = CGRect(x: 0, y: 0, width: 500, height: 500)
    let fits = label("a", rect: Rect(x: 0, y: 0, w: 40, h: 12))
    #expect(
        MosaicPainter.mask(
            fits, view: .identity, bounds: bounds, metrics: metrics)
            == CGRect(x: 0, y: 0, width: 40, height: 12)
    )
    let narrow = label("a", rect: Rect(x: 0, y: 0, w: 39, h: 40))
    #expect(
        MosaicPainter.mask(
            narrow, view: .identity, bounds: bounds, metrics: metrics)
            == nil
    )
    let low = label("a", rect: Rect(x: 0, y: 0, w: 100, h: 11.5))
    #expect(
        MosaicPainter.mask(
            low, view: .identity, bounds: bounds, metrics: metrics)
            == nil
    )
    // Zooming in makes room: the check is in screen space.
    let zoomed = ViewTransform(scale: 2, originX: 0, originY: 0)
    #expect(
        MosaicPainter.mask(
            narrow, view: zoomed, bounds: bounds, metrics: metrics)
            == CGRect(x: 0, y: 0, width: 78, height: 80)
    )
    // A band is the region its label owns, not the whole tile.
    let banded = label(
        "a",
        rect: Rect(x: 0, y: 0, w: 100, h: 100),
        header: Rect(x: 0, y: 0, w: 100, h: 16)
    )
    #expect(
        MosaicPainter.mask(
            banded, view: .identity, bounds: bounds, metrics: metrics)
            == CGRect(x: 0, y: 0, width: 100, height: 16)
    )
}

@Test func labelGeometryFollowsTheInterfaceZoom() {
    for step in zoomSteps {
        let rem = baseRem * step
        let metrics = MosaicLabelMetrics(rem: rem)
        #expect(metrics.nameSize == 0.75 * rem)
        #expect(metrics.sizeSize == 0.6875 * rem)
        #expect(abs(metrics.lineHeight - metrics.nameSize * 1.35) < 1e-9)
        #expect(abs(metrics.padding - metrics.nameSize * 0.42) < 1e-9)
        #expect(abs(metrics.inset - metrics.nameSize * 0.25) < 1e-9)
        #expect(abs(metrics.minWidth - metrics.nameSize * 3.3) < 1e-9)
        #expect(abs(metrics.gap - metrics.nameSize * 0.67) < 1e-9)
    }
}

@MainActor
@Test func manyLabelsDrawInEveryTheme() throws {
    let home = try scanned(TreemapFixture.home)
    let src = try Support.crumbs(home, path: "src")
    for (name, theme) in try Support.everyTheme() {
        for rem in [baseRem, baseRem * 1.5] {
            var frame = TreemapFrame(tree: home)
            frame.depth = 4
            frame.rem = rem
            frame.marked = [src]
            let mosaic = frame.mosaic()
            #expect(mosaic.labels.count >= 20, "\(mosaic.labels.count)")
            let painted = try Support.paint(frame, theme: theme, scale: 2)
            painted.save("labels-\(name)-\(Int(rem))")
            // Glyph cores reach the full label colours at 2x.
            let colors = MosaicColors(theme: theme)
            let ink = [
                colors.label(depth: 0).hsla, colors.label(depth: 1).hsla,
                colors.markedLabel.hsla,
            ]
            .map { Support.rgbBytes($0.composited(over: theme.inset)) }
            let found = ink.map { painted.count(near: $0, by: 12) }
            #expect(found[0] + found[1] > 200, "\(name): \(found)")
            // The marked directory's names are set in the danger colour.
            #expect(found[2] > 20, "\(name): \(found)")
        }
    }
}

@Test func theTypesetterRemembersWhatItSet() {
    let typesetter = MosaicTypesetter(rem: baseRem)
    let ink = MosaicInk(Theme.dark.foreground)
    let first = typesetter.line("walgit", face: .name, color: ink)
    let again = typesetter.line("walgit", face: .name, color: ink)
    #expect(first.line === again.line)
    let bold = typesetter.line("walgit", face: .bold, color: ink)
    #expect(bold.line !== first.line)
    #expect(bold.measure.width > first.measure.width)
    #expect(first.measure.ascent > 0 && first.measure.descent > 0)
    let size = typesetter.line("walgit", face: .size, color: ink)
    #expect(size.measure.width < first.measure.width)
    // Past its capacity it starts over rather than growing.
    for index in 0..<MosaicTypesetter.capacity {
        _ = typesetter.line("\(index)", face: .size, color: ink)
    }
    #expect(
        typesetter.line("walgit", face: .name, color: ink).line !== first.line)
}

// MARK: - Input as pure functions

@Test func windowPointsBecomeTreemapLocalPoints() {
    // Window coordinates run up from the bottom; the treemap's run down
    // from its own top-left corner.
    let frame = CGRect(x: 100, y: 50, width: 400, height: 300)
    #expect(
        treemapPoint(inWindow: CGPoint(x: 100, y: 350), frame: frame)
            == CGPoint(x: 0, y: 0)
    )
    #expect(
        treemapPoint(inWindow: CGPoint(x: 500, y: 50), frame: frame)
            == CGPoint(x: 400, y: 300)
    )
    #expect(
        treemapPoint(inWindow: CGPoint(x: 130.5, y: 330.25), frame: frame)
            == CGPoint(x: 30.5, y: 19.75)
    )
    let size = frame.size
    #expect(treemapContains(CGPoint(x: 0, y: 0), size: size))
    #expect(treemapContains(CGPoint(x: 399.5, y: 299.5), size: size))
    #expect(!treemapContains(CGPoint(x: 400, y: 10), size: size))
    #expect(!treemapContains(CGPoint(x: 10, y: 300), size: size))
    #expect(!treemapContains(CGPoint(x: -0.5, y: 10), size: size))
}

@Test func wheelDeltasBecomeLines() {
    // A mouse wheel's notches are lines already.
    #expect(wheelLines(deltaX: 0, deltaY: 3, precise: false, shift: false) == 3)
    #expect(
        wheelLines(deltaX: 0, deltaY: -1, precise: false, shift: false) == -1)
    // A trackpad's points: 24 to the line.
    #expect(wheelLines(deltaX: 0, deltaY: 48, precise: true, shift: false) == 2)
    #expect(
        wheelLines(deltaX: 0, deltaY: -6, precise: true, shift: false) == -0.25)
    // Sideways without shift is not a zoom.
    #expect(wheelLines(deltaX: 5, deltaY: 0, precise: false, shift: false) == 0)
    // Shift turns a wheel sideways before the app sees it; the pan still
    // follows it.
    #expect(wheelLines(deltaX: 2, deltaY: 0, precise: false, shift: true) == 2)
    #expect(wheelLines(deltaX: 9, deltaY: 24, precise: true, shift: true) == 1)
}

/// One event for a gate: its time, its phase and its momentum phase.
private typealias GateEvent = (
    time: TimeInterval, phase: NSEvent.Phase, momentum: NSEvent.Phase
)

/// Feed `events` to `gate` in order: whether each was used.
private func feed(_ gate: inout GestureGate, _ events: [GateEvent]) -> [Bool] {
    events.map {
        gate.admits(time: $0.time, phase: $0.phase, momentum: $0.momentum)
    }
}

@Test func anOpenGateAdmitsEveryEvent() {
    var gate = GestureGate()
    let admitted = feed(
        &gate,
        [
            (0, .began, []), (0.01, .changed, []), (0.02, .ended, []),
            (0.03, [], .began),
        ]
    )
    #expect(admitted == [true, true, true, true])
    #expect(!gate.closed)
}

@Test func afterALevelChangeTheRestOfTheFlickIsIgnored() {
    var gate = GestureGate()
    let before = feed(&gate, [(0, .began, []), (0.01, .changed, [])])
    #expect(before == [true, true])
    gate.close(at: 0.01)
    // The fingers keep moving, lift, and momentum carries on: all of it is
    // the same gesture, its last event included.
    let rest = feed(
        &gate,
        [
            (0.02, .changed, []), (0.03, .ended, []), (0.04, [], .began),
            (0.2, [], .changed), (0.4, [], .ended),
        ]
    )
    #expect(rest == [false, false, false, false, false])
    #expect(!gate.closed)
    // The next gesture is not.
    let next = feed(&gate, [(0.41, .changed, [])])
    #expect(next == [true])
}

@Test func freshFingersOpenTheGate() {
    for touch in [NSEvent.Phase.began, .mayBegin] {
        var gate = GestureGate()
        gate.close(at: 0)
        let admitted = feed(
            &gate,
            [(0.05, [], .changed), (0.1, touch, []), (0.11, .changed, [])]
        )
        #expect(admitted == [false, true, true])
    }
}

@Test func quietOpensTheGateForAWheelWithoutPhases() {
    var gate = GestureGate()
    gate.close(at: 10)
    // Notches keep coming, each one extending the gesture; then the wheel
    // rests long enough, and the next notch is a new gesture.
    let admitted = feed(
        &gate,
        [
            (10.1, [], []), (10.35, [], []), (10.6, [], []),
            (10.6 + GestureGate.quiet, [], []),
        ]
    )
    #expect(admitted == [false, false, false, true])
}

@Test func aPinchBeginsWithItsFingersOrAfterQuiet() {
    // A trackpad's pinch says where it begins and ends.
    var pinch = PinchPhases()
    let phased = [NSEvent.Phase.began, .changed, .changed, .ended].enumerated()
        .map { pinch.begins(time: Double($0.offset) * 0.01, phase: $0.element) }
    #expect(phased == [true, false, false, false])
    #expect(PinchPhases.ends(.ended) && PinchPhases.ends(.cancelled))
    #expect(!PinchPhases.ends(.changed) && !PinchPhases.ends([]))

    // One without phases starts again after the quiet a wheel's does.
    var bare = PinchPhases()
    let times = [10, 10.1, 10.2, 10.2 + GestureGate.quiet]
    #expect(
        times.map { bare.begins(time: $0, phase: []) }
            == [true, false, false, true]
    )
}

@Test func clicksCarryTheirModifiersAndButtons() {
    let all = TreemapNSView.modifiers([.command, .control, .shift, .option])
    #expect(
        all
            == PointerModifiers(
                command: true,
                control: true,
                shift: true,
                option: true
            )
    )
    #expect(
        TreemapNSView.modifiers([.command]) == PointerModifiers(command: true))
    #expect(TreemapNSView.modifiers([.capsLock]) == PointerModifiers())
    #expect(TreemapNSView.otherButton(2) == .middle)
    #expect(TreemapNSView.otherButton(3) == nil)
    #expect(TreemapNSView.otherButton(1) == nil)
}

@Test func theContextMenuOffersWhatSuitsTheTile() {
    #expect(
        TreemapMenuAction.sections(isDir: true, marked: false)
            == [[.mark, .open], [.quickLook, .revealInFinder, .copyPath]]
    )
    #expect(
        TreemapMenuAction.sections(isDir: false, marked: true)
            == [[.unmark], [.quickLook, .revealInFinder, .copyPath]]
    )
    #expect(
        [
            TreemapMenuAction.mark, .unmark, .open, .quickLook,
            .revealInFinder, .copyPath,
        ]
        .map(\.title)
            == [
                "Mark", "Unmark", "Open", "Quick Look", "Reveal in Finder",
                "Copy Path",
            ]
    )
}

// MARK: - The view

@MainActor
@Test func theViewReportsItsSizeToTheState() throws {
    let fixture = try TreemapFixture.make(TreemapFixture.small)
    defer { fixture.remove() }
    let harness = TreemapHarness(root: fixture.root, tree: try fixture.scan())
    let view = TreemapNSView(state: harness.state)
    view.setFrameSize(NSSize(width: 640, height: 480))
    #expect(harness.state.treemapSize == CGSize(width: 640, height: 480))
    view.setFrameSize(NSSize(width: 800, height: 500))
    #expect(harness.state.treemapSize == CGSize(width: 800, height: 500))
    #expect(harness.copied.isEmpty && harness.revealed.isEmpty)
}

@MainActor
@Test func theHostedTreemapDrawsInBothAppearances() throws {
    let fixture = try TreemapFixture.make(TreemapFixture.small)
    defer { fixture.remove() }
    let tree = try fixture.scan()
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        let harness = TreemapHarness(root: fixture.root, tree: tree)
        let host = NSHostingView(rootView: TreemapView(state: harness.state))
        let size = CGSize(width: 800, height: 600)
        let window = Support.offscreenWindow(
            host,
            size: size,
            appearance: appearance
        )
        defer { closeWindow(window) }
        let view = try #require(
            Support.firstSubview(of: TreemapNSView.self, in: host)
        )
        #expect(view.bounds.size == size)
        #expect(harness.state.treemapSize == size)

        #expect(view.accessibilityIdentifier() == "disktree-treemap")
        #expect(view.accessibilityRole() == .group)
        #expect(view.accessibilityLabel()?.hasPrefix("Treemap of ") == true)
        #expect(view.accessibilityHelp()?.isEmpty == false)

        let painted = try Support.cached(view)
        painted.save("hosted-\(appearance.rawValue)")
        #expect(painted.isOpaque)
        // The ground is the appearance's own inset, wherever no tile is.
        let theme = Theme.system(
            appearance: try #require(NSAppearance(named: appearance))
        )
        let ground = Support.rgbBytes(theme.inset)
        let pixels = painted.width * painted.height
        #expect(painted.differing(from: ground) < pixels)

        // The canvas lands the right way up: each region's strip runs
        // along its top edge, where the painter puts it.
        let placed = Support.placed(
            harness.state.prepare(),
            theme: theme,
            size: size,
            scale: painted.scale
        )
        var strips = 0
        for tile in placed where tile.deco.depth == 0 && !tile.deco.selected {
            #expect(
                Support.near(
                    painted.rgb(tile.quad.midX, tile.quad.minY + 0.75),
                    Support.rgbBytes(theme.categoryAccent(tile.deco.category)),
                    by: 3
                )
            )
            strips += 1
        }
        #expect(strips >= 1)
    }
}

/// A mouse event at a window point, for `window`.
@MainActor
private func mouse(
    _ type: NSEvent.EventType,
    at point: CGPoint,
    in window: NSWindow,
    flags: NSEvent.ModifierFlags = [],
    clicks: Int = 1
) throws -> NSEvent {
    try #require(
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clicks,
            pressure: 1
        )
    )
}

@MainActor
@Test func eventsReachTheStateInTreemapLocalPoints() throws {
    let fixture = try TreemapFixture.make(TreemapFixture.small)
    defer { fixture.remove() }
    let harness = TreemapHarness(root: fixture.root, tree: try fixture.scan())
    let state = harness.state
    // The treemap sits inside a larger content view, off its origin, as it
    // does beside the panel and under the top bar.
    let content = NSView()
    let window = Support.offscreenWindow(
        content,
        size: CGSize(width: 900, height: 700)
    )
    defer { closeWindow(window) }
    let view = TreemapNSView(state: state)
    content.addSubview(view)
    view.frame = NSRect(x: 40, y: 30, width: 600, height: 400)

    // The pure conversion agrees with AppKit's own.
    let frame = view.convert(view.bounds, to: nil)
    for point in [
        CGPoint(x: 40, y: 430), CGPoint(x: 340.5, y: 230.25),
        CGPoint(x: 639, y: 31),
    ] {
        let local = treemapPoint(inWindow: point, frame: frame)
        let appkit = view.convert(point, from: nil)
        #expect(
            abs(local.x - appkit.x) < 1e-9 && abs(local.y - appkit.y) < 1e-9)
    }

    let inside = CGPoint(x: 340, y: 230)
    let local = treemapPoint(inWindow: inside, frame: frame)
    let move = try mouse(.mouseMoved, at: inside, in: window)
    #expect(view.localPoint(move) == local)
    view.mouseMoved(with: move)
    if let pointer = state.pointer {
        #expect(pointer == local)
    }
    // A drag that leaves the treemap leaves nothing hovered behind.
    view.mouseDragged(
        with: try mouse(
            .leftMouseDragged, at: CGPoint(x: 800, y: 600), in: window))
    #expect(state.pointer == nil)

    // Clicks of every kind go through without touching the pasteboard or
    // Finder.
    view.mouseDown(with: try mouse(.leftMouseDown, at: inside, in: window))
    view.mouseDown(
        with: try mouse(.leftMouseDown, at: inside, in: window, flags: .command)
    )
    view.otherMouseDown(
        with: try mouse(.otherMouseDown, at: inside, in: window))
    view.mouseExited(with: try mouse(.mouseMoved, at: inside, in: window))
    #expect(state.pointer == nil)
    #expect(harness.copied.isEmpty && harness.revealed.isEmpty)
}

@MainActor
@Test func theContextMenuActsOnTheTileUnderThePointer() throws {
    let fixture = try TreemapFixture.make(TreemapFixture.small)
    defer { fixture.remove() }
    let tree = try fixture.scan()
    let harness = TreemapHarness(root: fixture.root, tree: tree)
    let state = harness.state
    let view = TreemapNSView(state: state)
    let window = Support.offscreenWindow(
        view, size: CGSize(width: 800, height: 600))
    defer { closeWindow(window) }

    // Over the ground there is nothing to act on.
    let corner = try mouse(
        .rightMouseDown, at: CGPoint(x: 0.5, y: 599.5), in: window)
    let cornerPoint = view.localPoint(corner)
    if state.tile(atX: cornerPoint.x, y: cornerPoint.y) == nil {
        #expect(view.menu(for: corner) == nil)
    }

    // Over a tile, the menu is that tile's.
    let centre = try mouse(
        .rightMouseDown, at: CGPoint(x: 400, y: 300), in: window)
    let point = view.localPoint(centre)
    let menu = view.menu(for: centre)
    if let crumbs = state.tile(atX: point.x, y: point.y),
        let node = state.node(at: crumbs)
    {
        let items = try #require(menu).items.filter { !$0.isSeparatorItem }
        let marked = state.path(at: crumbs).map(state.marks.contains) ?? false
        let sections = TreemapMenuAction.sections(
            isDir: node.isDir, marked: marked)
        #expect(items.map(\.title) == sections.flatMap { $0 }.map(\.title))
        #expect(
            items.allSatisfy {
                ($0.representedObject as? TreemapMenuCommand)?.crumbs == crumbs
            }
        )
    } else {
        #expect(menu == nil)
    }

    // Copy Path and Reveal in Finder go through the state's hooks, which
    // this harness records instead of touching the pasteboard or Finder.
    let largest = [0]
    let path = state.path(at: largest)
    view.perform(.copyPath, on: largest)
    #expect(harness.copied == (path.map { [$0.string] } ?? []))
    view.perform(.revealInFinder, on: largest)
    #expect(harness.revealed.count <= 1)
    if let shown = harness.revealed.first {
        // The one tile, however the state spells its path.
        #expect(shown.count == 1)
        #expect(shown.first?.lastComponent == path?.lastComponent)
    }
}

// MARK: - The frame budget

/// A home directory in memory, shaped the way one is: a few large
/// directories and a long tail, three and four levels deep, with caches,
/// build output and repositories among them. Deterministic, so every run
/// measures the same frame.
private func benchmarkTree() -> Node {
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    func next(_ bound: UInt64) -> UInt64 {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return (seed >> 33) % bound
    }
    // Sizes spread over three orders of magnitude, as files' do.
    func bytes() -> UInt64 {
        let base = next(1_000) + 1
        return base * base * (next(4) + 1) + 4_096
    }
    let names = [
        "src", "node_modules", ".cache", "target", ".git", "Documents",
        "Movies", "models", "Sync", ".cargo", "Library", "misc",
    ]
    func directory(_ name: String, depth: Int) -> Node {
        let count = depth == 0 ? 36 : Int(6 + next(16))
        var children: [Node] = []
        for index in 0..<count {
            if depth >= 3 || (depth > 0 && next(3) == 0) {
                children.append(
                    .entry("file-\(index).bin", kind: .file, bytes: bytes())
                )
            } else {
                let label = names[Int(next(UInt64(names.count)))]
                children.append(directory("\(label)", depth: depth + 1))
            }
        }
        // A manifest beside every level, so `target` and `node_modules`
        // are the reclaimable kinds they are in a real checkout.
        children.append(.entry("Cargo.toml", kind: .file, bytes: 2_000))
        children.append(.entry("package.json", kind: .file, bytes: 2_000))
        return .directory(name, children: children)
    }
    var root = directory("bench", depth: 0)
    aggregate(&root, metric: .bytes)
    classify(&root)
    return root
}

/// Paints `mosaic` `rounds` times with one painter, as the view does frame
/// after frame, and answers the median and the slowest tenth, in ms.
private func timePainting(
    _ mosaic: Mosaic,
    size: CGSize,
    scale: CGFloat,
    theme: Theme,
    rounds: Int = 40
) throws -> (median: Double, p90: Double) {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
        CGContext(
            data: nil,
            width: Int(size.width * scale),
            height: Int(size.height * scale),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )
    )
    context.scaleBy(x: scale, y: scale)
    let painter = MosaicPainter(
        colors: MosaicColors(theme: theme),
        typesetter: MosaicTypesetter(rem: baseRem),
        scale: scale
    )
    let bounds = CGRect(origin: .zero, size: size)
    // The first frame typesets every label; the view's later ones find
    // them set.
    painter.paint(mosaic, in: context, bounds: bounds, flipped: false)
    var samples: [Double] = []
    for _ in 0..<rounds {
        let start = ContinuousClock.now
        painter.paint(mosaic, in: context, bounds: bounds, flipped: false)
        let elapsed = ContinuousClock.now - start
        samples.append(
            Double(elapsed.components.attoseconds) / 1e15
                + Double(elapsed.components.seconds) * 1e3
        )
    }
    samples.sort()
    return (samples[samples.count / 2], samples[samples.count * 9 / 10])
}

/// A frame of a few thousand tiles paints well inside the 8 ms a 120 Hz
/// display leaves, settled and mid-transition, at 2x. Timing belongs to a
/// quiet machine and an optimised build, so it runs only when asked:
///
///     DISKTREE_BENCH=1 swift test -c release -Xswiftc -enable-testing \
///         --filter aFrameOfThousandsOfTiles
@Test(
    .enabled(
        if: ProcessInfo.processInfo.environment["DISKTREE_BENCH"] != nil
    )
)
func aFrameOfThousandsOfTilesPaintsInsideTheBudget() throws {
    let tree = benchmarkTree()
    let start = ContinuousClock.now
    var frame = TreemapFrame(tree: tree)
    frame.size = CGSize(width: 1_440, height: 900)
    frame.depth = 4
    frame.selected = frame.tiles().dropFirst(40).first?.crumbs
    frame.hovered = frame.tiles().dropFirst(90).first?.crumbs
    let settled = frame.mosaic()
    let transition = LayoutTransition(
        src: Rect(x: 400, y: 260, w: 360, h: 225),
        dst: Rect(x: 0, y: 0, w: 1_440, h: 900),
        now: start
    )
    frame.transition = transition
    frame.at = start + transition.duration / 2
    let moving = frame.mosaic()
    #expect(settled.tiles.count >= 2_500, "\(settled.tiles.count) tiles")
    // Half of them hatched: the costliest frame a home directory full of
    // `node_modules` and caches draws.
    #expect(settled.tiles.count(where: \.reclaimable) * 3 > settled.tiles.count)
    for (name, theme) in [("dark", Theme.dark), ("light", .light)] {
        for (phase, mosaic) in [("settled", settled), ("moving", moving)] {
            let time = try timePainting(
                mosaic,
                size: frame.size,
                scale: 2,
                theme: theme
            )
            print(
                "frame budget: \(name) \(phase) \(mosaic.tiles.count) tiles "
                    + "\(mosaic.labels.count) labels: median "
                    + String(
                        format: "%.2f ms, p90 %.2f ms", time.median, time.p90)
            )
            #expect(time.median < 6, "\(name) \(phase): \(time.median) ms")
            #expect(time.p90 < 8, "\(name) \(phase): \(time.p90) ms")
        }
    }
}
