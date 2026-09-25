import System
import Testing

@testable import DisktreeCore

private func leaf(_ name: String, _ bytes: UInt64) -> Node {
    Node.entry(name, kind: .file, bytes: bytes)
}

private func child(_ node: Node, _ name: String) throws -> Node {
    try #require(node.childNamed(name), "no child named \(name)")
}

@Test func aggregateDerivesTotalsAndOrdersChildren() throws {
    var root = Node.directory(
        "root",
        children: [
            .directory("child", children: [leaf("deep", 7)]),
            leaf("direct", 5),
            leaf("small", 9),
        ]
    )

    aggregate(&root, metric: .bytes)
    #expect(root.ownBytes == 5 + 9, "direct leaves only")
    #expect(root.bytes == 5 + 9 + 7)
    #expect(root.files == 3)
    #expect(root.ownFiles == 2)
    #expect(root.dirs == 2)
    #expect(try child(root, "child").ownBytes == 7)
    #expect(root.children[0].name == "small", "9 bytes, largest first")
    #expect(root.children[2].name == "direct")

    // A file's own size is what it weighs; aggregates never invent more.
    var single = leaf("solo", 3)
    aggregate(&single, metric: .bytes)
    #expect(single.bytes == 3)
    #expect(single.ownBytes == 3)
    #expect(single.files == 1)
    #expect(single.dirs == 0)
}

@Test func aggregateCanRankByFileCount() {
    var root = Node.directory(
        "root",
        children: [
            .directory("many", children: (0..<5).map { leaf("f\($0)", 1) }),
            leaf("huge", 10_000),
        ]
    )

    aggregate(&root, metric: .bytes)
    #expect(root.children[0].name == "huge")
    aggregate(&root, metric: .files)
    #expect(root.children[0].name == "many")
    #expect(root.children[0].files == 5)
}

@Test func aggregateTakesTheNewestWriteBeneath() {
    var old = leaf("old", 1)
    old.modified = 100
    var new = leaf("new", 1)
    new.modified = 900
    var root = Node.directory(
        "root",
        children: [.directory("inner", children: [old, new])]
    )
    aggregate(&root, metric: .bytes)
    #expect(root.modified == 900)
    #expect(root.children[0].modified == 900)
}

@Test func resolveWalksChildIndices() {
    let root = Node.directory(
        "root",
        children: [.directory("child", children: [leaf("deep", 1)])]
    )

    #expect(root.resolve([]) != nil)
    #expect(root.resolve([0, 0])?.name == "deep")
    #expect(root.resolve([0, 1]) == nil)
    #expect(root.resolveChain([0, 0]).count == 3)
}

@Test func pathOfJoinsNamesBeneathTheRoot() {
    let root = Node.directory(
        "root",
        children: [.directory("child", children: [leaf("deep", 1)])]
    )

    let path = pathOf(
        rootPath: FilePath("/Users/tobi"),
        root: root,
        crumbs: [0, 0]
    )
    #expect(path == FilePath("/Users/tobi/child/deep"))
}

@Test func largestChildIsTheFirstChildBecauseChildrenAreSorted() {
    let root = Node.directory(
        "root",
        children: [leaf("big", 10), leaf("small", 1)]
    )
    #expect(root.largestChild == 0)
    #expect(Node.directory("empty").largestChild == nil)
}

@Test func findReportsCrumbsAndIsCaseInsensitive() throws {
    let root = Node.directory(
        "root",
        children: [.directory("target", children: [leaf("needle-file", 1)])]
    )

    let found = try #require(root.find("NEEDLE"))
    #expect(found.crumbs == [0, 0])
    #expect(found.node.name == "needle-file")
    #expect(root.find("") == nil)
    #expect(root.find("absent") == nil)
}

@Test func depthCountsEdges() {
    let root = Node.directory(
        "root",
        children: [.directory("child", children: [leaf("deep", 1)])]
    )
    #expect(root.depth == 2)
    #expect(leaf("x", 0).depth == 0)
}
