import Testing

@testable import DisktreeCore

private let gib: UInt64 = 1024 * 1024 * 1024
private let now: Int64 = 1_800_000_000
private let day: Int64 = 86_400

private func file(_ name: String, _ bytes: UInt64, daysOld: Int64) -> Node {
    var node = Node.entry(name, kind: .file, bytes: bytes)
    node.modified = now - daysOld * day
    return node
}

private func dir(_ name: String, _ children: [Node]) -> Node {
    Node.directory(name, children: children)
}

private func scanned(_ root: Node) -> Node {
    var root = root
    aggregate(&root, metric: .bytes)
    classify(&root)
    return root
}

private func home() -> Node {
    scanned(
        dir(
            "tobi",
            [
                dir(
                    ".cache",
                    [dir("kache", [file("blob", 5 * gib, daysOld: 1)])]
                ),
                dir(
                    ".codex",
                    [
                        dir(
                            "worktrees",
                            [
                                dir("a1", [file("x", 3 * gib, daysOld: 41)]),
                                dir("b2", [file("y", 2 * gib, daysOld: 3)]),
                            ]
                        )
                    ]
                ),
                dir(
                    "src",
                    [
                        dir(
                            "tries",
                            [
                                dir("old", [file("z", 4 * gib, daysOld: 90)]),
                                dir(
                                    "fresh",
                                    [
                                        file("Cargo.toml", 1, daysOld: 1),
                                        dir(
                                            "target",
                                            [file("o", gib, daysOld: 1)]
                                        ),
                                    ]
                                ),
                            ]
                        )
                    ]
                ),
                dir("Documents", [file("tax.pdf", 9 * gib, daysOld: 400)]),
                dir("tiny", [dir(".cache", [file("t", 1024, daysOld: 1)])]),
            ]
        )
    )
}

@Test func ranksFindingsLargestFirstAndSkipsTheTiny() {
    let found = worthALook(home(), now: now, limit: 10)
    #expect(
        found.map(\.finding) == [
            .reclaimable(.regenerable),
            .worktrees(count: 2, oldestDays: 41),
            .staleExperiments(count: 1),
            .reclaimable(.buildOutput),
        ]
    )
    #expect(found.first?.bytes == 5 * gib)
    #expect(
        found.dropFirst(2).first?.bytes == 4 * gib,
        "only the stale experiment counts"
    )
}

@Test func documentsAreNeverSuggested() {
    let found = worthALook(home(), now: now, limit: 10)
    #expect(found.allSatisfy { $0.crumbs != [3] })
}

@Test func crumbsAddressTheFindingFromTheRoot() throws {
    let root = home()
    for candidate in worthALook(root, now: now, limit: 10) {
        let node = try #require(root.resolve(candidate.crumbs))
        #expect(node.isDir)
    }
}

@Test func theLimitKeepsTheLargest() {
    let found = worthALook(home(), now: now, limit: 2)
    #expect(found.count == 2)
    #expect(found.last?.finding == .worktrees(count: 2, oldestDays: 41))
}

// macOS

@Test func xcodeBuildProductsAreWorthALook() throws {
    let project = dir("App-bzkfqhdxrm", [file("Build", 2 * gib, daysOld: 2)])
    let path = ["Library", "Developer", "Xcode", "DerivedData"]
    let root = scanned(
        dir("kyle", [path.reversed().reduce(project) { dir($1, [$0]) }])
    )
    let found = worthALook(root, now: now, limit: 10)
    let first = try #require(found.first)
    #expect(found.count == 1, "the topmost only, not each project inside")
    #expect(first.finding == .reclaimable(.buildOutput))
    #expect(first.bytes == 2 * gib)
    #expect(root.resolve(first.crumbs)?.name == "DerivedData")
}

@Test func equalFindingsKeepTheOrderTheWalkFoundThem() {
    // Six caches of one size: `aggregate` orders them by name, and the list
    // must keep that order rather than whatever an unstable sort leaves.
    let names = [
        ".cache", ".ccache", ".sccache", "_cacache", "cache", "caches",
    ]
    let root = scanned(
        dir("tobi", names.map { dir($0, [file("blob", gib, daysOld: 1)]) })
    )
    for _ in 0..<20 {
        let found = worthALook(root, now: now, limit: 10)
        #expect(found.map(\.crumbs) == (0..<6).map { [$0] })
        #expect(found.compactMap { root.resolve($0.crumbs)?.name } == names)
    }
}

@Test func aNegativeOrZeroLimitListsNothing() {
    #expect(worthALook(home(), now: now, limit: 0).isEmpty)
    #expect(worthALook(home(), now: now, limit: -1).isEmpty)
}
