import DisktreeCore
import System
import Testing

@testable import DisktreeApp

private func file(_ name: String, _ bytes: UInt64) -> Node {
    Node.entry(name, kind: .file, bytes: bytes)
}

private func tree() -> Node {
    var root = Node.directory(
        "home",
        children: [
            .directory(".cache", children: [file("blob.bin", 900)]),
            file("notes.bin", 100),
        ]
    )
    aggregate(&root, metric: .bytes)
    return root
}

private func target(_ path: FilePath, _ bytes: UInt64) -> Target {
    Target(path: path, bytes: bytes, isDir: false, hidden: false)
}

@Test func togglingMarksAndUnmarks() {
    var marks = Marks()
    // Bound first: `#expect` cannot call a mutating method.
    let marked = marks.toggle(target("/Users/tobi/a", 1))
    #expect(marked)
    #expect(marks.contains("/Users/tobi/a"))
    #expect(marks.count == 1)
    let unmarked = !marks.toggle(target("/Users/tobi/a", 1))
    #expect(unmarked)
    #expect(marks.isEmpty)
}

@Test func markingTheSamePathTwiceKeepsOneEntry() {
    var marks = Marks()
    marks.toggle(target("/Users/tobi/a", 1))
    marks.toggle(target("/Users/tobi/a", 1))
    marks.toggle(target("/Users/tobi/a", 1))
    #expect(marks.count == 1)
}

@Test func removingAndClearingKeepTheLookupInStep() {
    var marks = Marks()
    marks.toggle(target("/Users/tobi/a", 1))
    marks.toggle(target("/Users/tobi/b", 2))
    marks.remove("/Users/tobi/a")
    #expect(!marks.contains("/Users/tobi/a"))
    #expect(marks.items.map(\.path) == ["/Users/tobi/b"])
    marks.remove("/Users/tobi/never-marked")
    #expect(marks.count == 1)
    marks.clear()
    #expect(marks.isEmpty)
    #expect(!marks.contains("/Users/tobi/b"))
    let again = marks.toggle(target("/Users/tobi/b", 2))
    #expect(again, "marks again after")
}

@Test func refreshReReadsSizesFromANewTree() throws {
    let rootPath: FilePath = "/Users/tobi"
    let root = tree()
    var marks = Marks()
    marks.toggle(target("/Users/tobi/.cache", 0))
    marks.toggle(target("/Users/tobi/gone", 500))

    marks.refresh(rootPath: rootPath, root: root)
    let cache = try #require(marks.items.first)
    #expect(cache.bytes == 900)
    #expect(cache.isDir)
    #expect(cache.hidden, "the .cache mark is hidden")
    #expect(marks.items.last?.bytes == 0, "a path that no longer exists")
    #expect(
        marks.items.map(\.path) == ["/Users/tobi/.cache", "/Users/tobi/gone"])
}

@Test func findMatchesWholeComponentsOnly() {
    let root = tree()
    let rootPath: FilePath = "/Users/tobi"
    #expect(
        findNode(rootPath: rootPath, root: root, path: "/Users/tobi/.cache")
            != nil
    )
    #expect(
        findNode(
            rootPath: rootPath,
            root: root,
            path: "/Users/tobi/.cache/blob.bin"
        ) != nil
    )
    #expect(
        findNode(rootPath: rootPath, root: root, path: "/Users/tobi/cache")
            == nil
    )
    #expect(
        findNode(
            rootPath: "/elsewhere",
            root: root,
            path: "/Users/tobi/notes.bin"
        ) == nil
    )
    #expect(
        findNode(rootPath: rootPath, root: root, path: rootPath)?.name
            == "home",
        "the root itself"
    )
}

@Test func findComparesNamesByTheirBytes() {
    // "é" precomposed and decomposed: equal to Swift's `==`, but two
    // different names to a volume that keeps them apart.
    let composed = "caf\u{E9}"
    let decomposed = "cafe\u{301}"
    var root = Node.directory("home", children: [file(composed, 1)])
    aggregate(&root, metric: .bytes)
    let rootPath: FilePath = "/Users/tobi"
    #expect(
        findNode(
            rootPath: rootPath,
            root: root,
            path: rootPath.appending(composed)
        ) != nil
    )
    #expect(
        findNode(
            rootPath: rootPath,
            root: root,
            path: rootPath.appending(decomposed)
        ) == nil
    )
}

@Test func hiddenMeansADotName() {
    #expect(isHidden("/Users/tobi/.cache"))
    #expect(!isHidden("/Users/tobi/cache"))
    #expect(!isHidden("/Users/tobi/.."), "no name of its own")
    #expect(!isHidden("/"))
}

@Test func displayPathShortensTheHomePrefix() {
    let home: FilePath = "/Users/tobi"
    #expect(displayPath("/Users/tobi/.cache/npm", home: home) == "~/.cache/npm")
    #expect(displayPath(home, home: home) == "~")
    #expect(displayPath("/var/log", home: home) == "/var/log")
    #expect(displayPath("/var/log", home: nil) == "/var/log")
    #expect(
        displayPath("/Users/tobias/x", home: home) == "/Users/tobias/x",
        "whole components only"
    )
}
