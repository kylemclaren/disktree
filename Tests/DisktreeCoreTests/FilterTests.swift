import Foundation
import Testing

@testable import DisktreeCore

private func file(_ name: String, _ bytes: UInt64) -> Node {
    Node.entry(name, kind: .file, bytes: bytes)
}

private func dir(_ name: String, _ children: [Node]) -> Node {
    Node.directory(name, children: children)
}

private func tree() -> Node {
    var root = dir(
        "root",
        [
            dir("src", [dir("App", [file("main.rs", 10)]), file("notes", 5)]),
            dir("apps", [file("x", 100), dir("apple", [file("y", 7)])]),
            file("readme", 1),
        ]
    )
    aggregate(&root, metric: .bytes)
    return root
}

private func crumbsOf(_ root: Node, _ names: [String]) throws -> [Int] {
    var node = root
    var crumbs: [Int] = []
    for name in names {
        let index = try #require(
            node.children.firstIndex { $0.name == name },
            "no \(name)"
        )
        crumbs.append(index)
        node = node.children[index]
    }
    return crumbs
}

@Test func matchesAreKeptWholeAndTheirAncestorsByWhatMatched() throws {
    let root = tree()
    let found = try #require(filter(root, base: [], needle: "APP"))
    #expect(found.count == 2, "src/App and apps; apple is inside apps")
    #expect(found.bytes == 10 + 107)
    #expect(found.keep(try crumbsOf(root, ["apps"])) == .whole)
    #expect(
        found.keep(try crumbsOf(root, ["apps", "x"])) == .whole,
        "inside a match"
    )
    #expect(
        found.keep(try crumbsOf(root, ["src"]))
            == .partial(bytes: 10, files: 1)
    )
    #expect(found.keep(try crumbsOf(root, ["src", "notes"])) == nil)
    #expect(found.keep(try crumbsOf(root, ["readme"])) == nil)
}

@Test func aSearchBelowTheRootLeavesTheRestAlone() throws {
    let root = tree()
    let src = try crumbsOf(root, ["src"])
    let node = try #require(root.resolve(src))
    let found = try #require(filter(node, base: src, needle: "main"))
    #expect(found.keep(try crumbsOf(root, ["apps"])) == .whole)
    #expect(found.keep(try crumbsOf(root, ["src", "notes"])) == nil)
    #expect(found.keep(src) == .partial(bytes: 10, files: 1))
}

@Test func anEmptyNeedleFiltersNothing() throws {
    #expect(filter(tree(), base: [], needle: "  ") == nil)
    let found = try #require(filter(tree(), base: [], needle: "zzz"))
    #expect(found.count == 0)
    #expect(found.kept.isEmpty)
}

@Test func caseIsIgnoredWithoutAllocating() {
    #expect(containsIgnoringCase("Cargo.TOML", "toml"))
    #expect(!containsIgnoringCase("ab", "abc"))
    #expect(containsIgnoringCase("x", ""))
}

@Test func aKeptNodeIsWeighedByWhatMatchedInIt() throws {
    let root = tree()
    let src = try #require(root.childNamed("src"))
    let partial = Keep.partial(bytes: 10, files: 1)
    #expect(Matches.value(partial, node: src, metric: .bytes) == 10)
    #expect(Matches.value(partial, node: src, metric: .files) == 1)
    #expect(Matches.value(.whole, node: src, metric: .bytes) == 15)
    #expect(Matches.value(.whole, node: src, metric: .files) == 2)
}

@Test func onlyAsciiCaseIsIgnoredBeyondThatBytesMustAgree() {
    #expect(containsIgnoringCase("Ärger", "ärger") == false)
    #expect(containsIgnoringCase("ärger.txt", "ärger"))
    #expect(containsIgnoringCase("ÄRGER.TXT", "ger.txt"))
    // One comparison sees bytes, not letters: a decomposed name, as
    // Foundation writes one, does not hold a precomposed needle. `filter`
    // makes one comparison per form of the needle for that.
    let decomposed = "cafe\u{301}"
    #expect(!containsIgnoringCase(decomposed, "caf\u{e9}"))
    #expect(containsIgnoringCase(decomposed, "cafe\u{301}"))
    let root = Node.directory("root", children: [file(decomposed, 1)])
    #expect(filter(root, base: [], needle: "caf\u{e9}")?.count == 1)
    // The needle is trimmed of any whitespace and folded the same way.
    let upper = Node.directory("root", children: [file("CAFÉ", 1)])
    #expect(filter(upper, base: [], needle: " \u{a0}Caf\n")?.count == 1)
}

@Test func aNameBridgedFromFoundationIsSearchedToo() {
    // Names that come through Foundation (a URL's last component, a
    // drag and drop) may be `NSString`s that lend no UTF-8 in place.
    let bridged = NSString(string: "Ünïcödé Projects — Archive 2024") as String
    #expect(containsIgnoringCase(bridged, "archive"))
    #expect(!containsIgnoringCase(bridged, "missing"))
    let root = Node.directory("root", children: [file(bridged, 3)])
    let found = filter(root, base: [], needle: "PROJECTS")
    #expect(found?.count == 1)
    #expect(found?.bytes == 3)
}

// macOS

/// The names in `directory` as the scanner reads them: the bytes on disk.
private func namesOnDisk(_ directory: String) throws -> [String] {
    let stream = try #require(opendir(directory))
    defer { closedir(stream) }
    var names: [String] = []
    while let entry = readdir(stream) {
        let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        if name != "." && name != ".." {
            names.append(name)
        }
    }
    return names
}

@Test func aTypedAccentFindsAFolderWhateverMadeIt() throws {
    let manager = FileManager.default
    let base = manager.temporaryDirectory.appendingPathComponent(
        "disktree-filter-\(UUID().uuidString)"
    )
    try manager.createDirectory(at: base, withIntermediateDirectories: false)
    defer { try? manager.removeItem(at: base) }
    // Finder, and every app that saves through Foundation, hands the disk a
    // decomposed name; a POSIX call hands it the bytes it was given.
    try manager.createDirectory(
        at: base.appendingPathComponent("Caf\u{e9} Photos"),
        withIntermediateDirectories: false
    )
    #expect(mkdir(base.path + "/caf\u{e9} posix", 0o755) == 0)
    var root = Node.directory(
        "root",
        children: try namesOnDisk(base.path).map { name in
            Node.directory(name, children: [file("a.jpg", 5)])
        }
    )
    aggregate(&root, metric: .bytes)
    // Typed on a Mac keyboard (option-e, e): precomposed.
    let found = try #require(filter(root, base: [], needle: "caf\u{e9}"))
    #expect(found.count == 2, "\(root.children.map { Array($0.name.utf8) })")
    #expect(found.bytes == 10)
}

@Test func eitherFormOfANeedleFindsEitherFormOfAName() throws {
    let root = Node.directory(
        "root",
        children: [
            file("caf\u{e9}.txt", 1),  // precomposed
            file("Cafe\u{301} Photos", 2),  // decomposed, as Foundation writes
            file("cafe", 4),  // no accent at all
        ]
    )
    for needle in ["caf\u{e9}", "cafe\u{301}", "CAF\u{e9}"] {
        let found = try #require(filter(root, base: [], needle: needle))
        #expect(found.count == 2, "\(Array(needle.utf8))")
        #expect(found.bytes == 3)
        // The needle is reported as it was typed, only its ASCII folded.
        #expect(Array(found.needle.utf8) == Array(asciiLowercased(needle).utf8))
    }
    // Beyond ASCII, case still has to agree, as in the byte comparison: a
    // precomposed capital is its own letter. A decomposed one is an ASCII
    // letter and an accent, so it folds like any other.
    let capital = Node.directory("root", children: [file("CAF\u{c9}", 1)])
    #expect(filter(capital, base: [], needle: "caf\u{e9}")?.count == 0)
    let decomposed = Node.directory("root", children: [file("CAFE\u{301}", 1)])
    #expect(filter(decomposed, base: [], needle: "caf\u{e9}")?.count == 1)
}

@Test func aNeedleIsSearchedInEachOfItsFormsOnce() {
    // ASCII has one form: one pass over the names, as before.
    #expect(needleForms("Cargo") == [Array("cargo".utf8)])
    // Precomposed as typed, and decomposed.
    #expect(
        needleForms("Caf\u{e9}")
            == [Array("caf\u{e9}".utf8), Array("cafe\u{301}".utf8)]
    )
    // Typed decomposed, it is still searched precomposed too.
    #expect(needleForms("cafe\u{301}").count == 2)
    // The Angstrom sign is in neither canonical form: as typed, it is kept
    // as well, so a name holding exactly those bytes is still found.
    #expect(
        needleForms("\u{212b}")
            == [
                Array("\u{212b}".utf8), Array("\u{c5}".utf8),
                Array("a\u{30a}".utf8),
            ]
    )
}
