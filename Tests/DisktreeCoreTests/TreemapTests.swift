import Testing

@testable import DisktreeCore

private func file(_ name: String, _ bytes: UInt64) -> Node {
    Node.entry(name, kind: .file, bytes: bytes)
}

/// A directory whose direct contents are the given children, so aggregate
/// totals are consistent before layout runs.
private func dir(_ name: String, _ children: [Node]) -> Node {
    var node = Node.directory(name, children: children)
    aggregate(&node, metric: .bytes)
    return node
}

private let area = Rect(x: 0, y: 0, w: 800, h: 500)

private func laidOut(
    _ root: Node,
    _ crumbs: [Int] = [],
    options: LayoutOptions = LayoutOptions()
) -> [Tile] {
    layout(
        root,
        rootCrumbs: crumbs,
        area: area,
        metric: .bytes,
        options: options
    )
}

@Test func squarifyFillsTheArea() {
    let values = [40.0, 30, 20, 5, 3, 2]
    let rects = squarify(values, in: area)
    let covered = rects.map(\.area).reduce(0, +)
    #expect(abs(covered - area.area) < 1, "covered \(covered) of \(area.area)")
    for rect in rects {
        #expect(rect.x >= -0.01 && rect.y >= -0.01)
        #expect(rect.right <= area.right + 0.01)
        #expect(rect.bottom <= area.bottom + 0.01)
    }
}

@Test func squarifyKeepsAspectRatiosReasonable() {
    // Same distribution as the canonical squarify example: 6, 6, 4, 3, 2, 2,
    // 1 on a 6x4 canvas.
    let values = [6.0, 6, 4, 3, 2, 2, 1]
    let rects = squarify(values, in: Rect(x: 0, y: 0, w: 600, h: 400))
    for rect in rects {
        let ratio = max(rect.w / rect.h, rect.h / rect.w)
        #expect(ratio <= 4, "aspect ratio \(ratio) in \(rect)")
    }
}

@Test func squarifySurvivesDegenerateInput() {
    #expect(squarify([], in: area).isEmpty)
    #expect(squarify([0, 0], in: area).allSatisfy { $0.area == 0 })
    let flat = squarify([1], in: Rect(x: 0, y: 0, w: 0, h: 10))
    #expect(flat.map(\.area) == [0])
}

@Test func layoutNestsChildrenInsideTheirParent() throws {
    // Depth first, parent before its own children: that order is what lets
    // the view paint in sequence and hit-test in reverse.
    let root = dir(
        "root",
        [
            dir("big", [file("inside", 100), file("also", 50)]),
            file("small", 10),
        ]
    )

    let tiles = laidOut(root)
    #expect(tiles.map(\.crumbs) == [[0], [0, 0], [0, 1], [1]])

    let parent = tiles[0]
    let child = tiles[1]
    #expect(child.depth == 1)
    #expect(parent.rect.contains(x: child.rect.x, y: child.rect.y))
    #expect(
        parent.rect.contains(
            x: child.rect.right - 0.5,
            y: child.rect.bottom - 0.5
        )
    )
}

@Test func layoutDepthOneStopsAtDirectChildren() {
    let root = dir("root", [dir("big", [file("inside", 100)])])

    let tiles = laidOut(root, options: LayoutOptions(maxDepth: 1))
    #expect(tiles.count == 1)
    #expect(tiles.first?.crumbs == [0])
}

@Test func aSubdividedDirectoryKeepsAHeaderForItsOwnName() throws {
    let root = dir(
        "root",
        [dir("big", [file("inside", 100), file("also", 50)])]
    )
    let tiles = laidOut(root)

    let parent = try #require(
        tiles.first { $0.crumbs == [0] },
        "the parent tile"
    )
    let header = try #require(parent.header, "a parent keeps a header")
    #expect(header.w > 0 && header.h > 0)
    #expect(header.y == parent.rect.y, "the band sits at the top of its tile")
    #expect(header.bottom <= parent.rect.bottom)

    // Every descendant starts below the band, so no child is drawn under
    // the parent's name.
    for tile in tiles where tile.crumbs.count > 1 {
        #expect(
            tile.rect.y >= header.bottom,
            "\(tile.crumbs) overlaps the header"
        )
    }

    // And the band belongs to the parent for hit-testing.
    let found = try #require(
        hit(tiles, x: header.x + header.w / 2, y: header.y + header.h / 2),
        "a hit"
    )
    #expect(found.crumbs == [0])
}

@Test func aTileWithoutRoomForAHeaderStaysWhole() {
    let root = dir("root", [dir("big", [file("inside", 100)])])
    // A band this tall leaves no usable body under it.
    let options = LayoutOptions(minTile: 150, header: 400)
    let tiles = laidOut(root, options: options)
    #expect(tiles.count == 1, "the child was not subdivided")
    #expect(tiles.first?.header == nil, "and it has no band of its own")
}

@Test func aNarrowTileKeepsNoHeader() {
    // Narrower than a name the view would write, however tall.
    let root = dir("root", [dir("big", [file("inside", 100)])])
    let narrow = layout(
        root,
        rootCrumbs: [],
        area: Rect(x: 0, y: 0, w: 46, h: 500),
        metric: .bytes,
        options: LayoutOptions()
    )
    #expect(narrow.count == 1)
    #expect(narrow.first?.header == nil)
}

@Test func tileCrumbsAddressTheScannedTreeNotTheDrawnNode() {
    // Draw the node at [3, 1] of some larger tree: its tiles must be
    // [3, 1, …], or anything resolving them from the scanned root would
    // find a stranger.
    let node = dir("inner", [file("a", 10), file("b", 5)])
    let tiles = laidOut(node, [3, 1])
    #expect(!tiles.isEmpty)
    for tile in tiles {
        #expect(tile.crumbs.starts(with: [3, 1]), "\(tile.crumbs)")
        #expect(tile.crumbs.count == 3)
    }
}

@Test func aLeafNeverClaimsAHeader() {
    let root = dir("root", [file("solo", 10)])
    #expect(laidOut(root).allSatisfy { $0.header == nil })
}

@Test func layoutMergesTheChildTailIntoOneTile() {
    let root = dir("root", (0..<10).map { file("f\($0)", 10 - UInt64($0)) })
    let tiles = laidOut(root, options: LayoutOptions(maxChildren: 4))
    let others = tiles.filter {
        if case .others = $0.kind { true } else { false }
    }
    #expect(others.count == 1)
    #expect(others.first?.kind == .others(crumbs: [], count: 6))
}

@Test func hitReturnsTheDeepestTile() throws {
    let root = dir(
        "root",
        [dir("big", [file("inside", 100)]), file("small", 1)]
    )

    let tiles = laidOut(root)
    let child = try #require(
        tiles.first { $0.crumbs == [0, 0] },
        "child tile"
    )
    let found = try #require(
        hit(
            tiles,
            x: child.rect.x + child.rect.w / 2,
            y: child.rect.y + child.rect.h / 2
        ),
        "a hit"
    )
    #expect(found.crumbs == [0, 0])
    #expect(hit(tiles, x: -50, y: -50) == nil)
}

@Test func aFilteredLayoutShowsOnlyTheMatchesAtTheirSize() throws {
    var root = Node.directory(
        "root",
        children: [
            .directory(
                "src",
                children: [file("big_test.rs", 300), file("other.rs", 700)]
            ),
            file("unit_test.txt", 100),
            file("huge.iso", 5000),
        ]
    )
    aggregate(&root, metric: .bytes)

    let matches = try #require(filter(root, base: [], needle: "test"))
    let tiles = layout(
        root,
        rootCrumbs: [],
        area: Rect(x: 0, y: 0, w: 400, h: 400),
        metric: .bytes,
        options: LayoutOptions(padding: 0, paddingOuter: 0),
        filter: matches
    )
    let names = tiles.compactMap { root.resolve($0.crumbs)?.name }
    #expect(names.contains("big_test.rs"))
    #expect(names.contains("unit_test.txt"))
    #expect(!names.contains { $0 == "huge.iso" || $0 == "other.rs" })

    // src is sized by its 300 matched bytes, not its 1000: three times
    // the 100-byte match beside it.
    func areaOf(_ name: String) throws -> Double {
        let tile = try #require(
            tiles.first { root.resolve($0.crumbs)?.name == name },
            "\(name) drawn"
        )
        return tile.rect.w * tile.rect.h
    }
    let ratio = try areaOf("src") / areaOf("unit_test.txt")
    #expect(abs(ratio - 3) < 0.05, "ratio \(ratio)")
}

// Beyond the Rust tests

@Test func equalValuesAreLaidOutInTheirOwnOrder() {
    // Four equal values on a square: the first takes the top-left, and the
    // rest follow in order, every time. The sort's tie-break is what
    // promises it.
    let square = Rect(x: 0, y: 0, w: 400, h: 400)
    let rects = squarify([1, 1, 1, 1], in: square)
    #expect(
        rects == [
            Rect(x: 0, y: 0, w: 200, h: 200),
            Rect(x: 0, y: 200, w: 200, h: 200),
            Rect(x: 200, y: 0, w: 200, h: 200),
            Rect(x: 200, y: 200, w: 200, h: 200),
        ]
    )
    let root = dir("root", (0..<4).map { file("f\($0)", 7) })
    #expect(laidOut(root).map(\.crumbs) == [[0], [1], [2], [3]])
}

@Test func beneathAMatchEverythingIsShown() throws {
    let root = dir(
        "root",
        [
            dir("tests", [file("a.rs", 60), file("b.rs", 40)]),
            file("readme", 900),
        ]
    )
    let matches = try #require(filter(root, base: [], needle: "tests"))
    let tiles = layout(
        root,
        rootCrumbs: [],
        area: area,
        metric: .bytes,
        options: LayoutOptions(),
        filter: matches
    )
    // `tests` is the smaller child, so it sits second.
    #expect(tiles.map(\.crumbs) == [[1], [1, 0], [1, 1]])
}

/// An applied filter shows the matches: one deeper than the depth drawn
/// still gets a tile, inside its ancestors opened for it.
@Test func aMatchDeeperThanTheDepthDrawnStillHasATile() throws {
    let root = dir(
        "root",
        [
            dir("big", [dir("inner", [dir("deep", [file("d1.bin", 500)])])]),
            file("readme", 900),
        ]
    )
    let matches = try #require(filter(root, base: [], needle: "d1"))
    let tiles = layout(
        root,
        rootCrumbs: [],
        area: area,
        metric: .bytes,
        options: LayoutOptions(maxDepth: 2),
        filter: matches
    )
    let names = tiles.compactMap { root.resolve($0.crumbs)?.name }
    #expect(names == ["big", "inner", "deep", "d1.bin"])
    // Unfiltered, the same depth draws two levels.
    let plain = laidOut(root, options: LayoutOptions(maxDepth: 2))
    #expect(plain.map(\.crumbs.count).max() == 2)
}

@Test func rectsAreHalfOpenAndNeverInsideOut() {
    let rect = Rect(x: 10, y: 20, w: 30, h: 40)
    #expect(rect.contains(x: 10, y: 20))
    #expect(!rect.contains(x: 40, y: 30), "the right edge is the neighbour's")
    #expect(!rect.contains(x: 20, y: 60), "and so is the bottom")
    #expect(rect.inset(100) == Rect(x: 110, y: 120, w: 0, h: 0))
    #expect(rect.inset(100).area == 0)
    #expect(rect.scaled(2) == Rect(x: 20, y: 40, w: 60, h: 80))
    #expect(rect.translated(dx: -10, dy: 5) == Rect(x: 0, y: 25, w: 30, h: 40))
    #expect(Rect(x: 0, y: 0, w: -5, h: 10).area == 0)
    #expect(Rect.zero.area == 0)
}
