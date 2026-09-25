import Testing

@testable import DisktreeCore

private func file(_ name: String, _ bytes: UInt64) -> Node {
    Node.entry(name, kind: .file, bytes: bytes)
}

private func dir(_ name: String, _ children: [Node]) -> Node {
    Node.directory(name, children: children)
}

private func classified(_ root: Node) -> Node {
    var root = root
    aggregate(&root, metric: .bytes)
    classify(&root)
    return root
}

private func home() -> Node {
    classified(
        dir(
            "tobi",
            [
                dir(
                    "src",
                    [dir("tries", [dir("2026-09-01", [file("a", 1)])])]
                ),
                dir(".cache", [dir("kache", [dir("store", [file("b", 1)])])]),
                dir(
                    "world",
                    [
                        dir(".git", [dir("objects", [file("c", 9)])]),
                        file("README", 1),
                    ]
                ),
                dir(
                    "rust-thing",
                    [file("Cargo.toml", 1), dir("target", [file("d", 5)])]
                ),
                dir("js-thing", [dir("target", [file("e", 5)])]),
                dir(
                    ".microsandbox",
                    [
                        dir("cache", [dir("layers", [file("f", 1)])]),
                        dir("snapshots", [file("g", 1)]),
                    ]
                ),
                dir("Sync", [dir(".stversions", [file("h", 1)])]),
                dir("mystery", [file("i", 1)]),
                dir(
                    "monorepo",
                    [
                        dir(
                            "git",
                            [
                                file("HEAD", 1),
                                dir("refs", []),
                                dir("objects", [file("pack", 50)]),
                            ]
                        )
                    ]
                ),
            ]
        )
    )
}

/// `names` as directories, each inside the one before, around `leaf`.
private func chain(_ names: [String], around leaf: Node) -> Node {
    names.reversed().reduce(leaf) { inner, name in dir(name, [inner]) }
}

/// A Mac home directory, laid out the way macOS and Xcode lay one out.
private func macHome() -> Node {
    let library = dir(
        "Library",
        [
            chain(["Caches", "com.apple.Safari"], around: file("db", 40)),
            dir(
                "Developer",
                [
                    chain(
                        ["Xcode", "DerivedData", "App-bzkfqhdxrm"],
                        around: file("App", 30)
                    ),
                    chain(
                        ["CoreSimulator", "Devices"],
                        around: file("device.plist", 20)
                    ),
                ]
            ),
            chain(
                ["Mobile Documents", "com~apple~CloudDocs"],
                around: file("thesis", 10)
            ),
            chain(
                ["CloudStorage", "GoogleDrive-me@example.com"],
                around: file("sheet", 5)
            ),
        ]
    )
    let developer = dir(
        "Developer",
        [
            dir(
                "tool",
                [file("Package.swift", 1), dir(".build", [file("debug", 8)])]
            ),
            chain(["site", ".build"], around: file("page", 2)),
        ]
    )
    return classified(
        dir(
            "kyle",
            [
                library,
                dir(".Trash", [file("old.dmg", 3)]),
                developer,
                chain(["Backup", ".Trashes", "501"], around: file("x", 4)),
                chain(["Homebrew", "Cellar"], around: file("git", 6)),
            ]
        )
    )
}

private func named(_ node: Node, _ path: [String]) throws -> Node {
    var node = node
    for part in path {
        node = try #require(node.childNamed(part), "no \(part)")
    }
    return node
}

@Test func namesAnnounceTheirKindAndChildrenInheritIt() throws {
    let home = home()
    #expect(try named(home, ["src"]).category == .code)
    // `tries` is agent scratch even inside code: it is what agents write.
    #expect(try named(home, ["src", "tries"]).category == .agentScratch)
    #expect(
        try named(home, ["src", "tries", "2026-09-01"]).category
            == .agentScratch,
        "an unknown name inherits"
    )
    #expect(
        try named(home, ["src", "tries", "2026-09-01", "a"]).category
            == .agentScratch,
        "files inherit too"
    )
}

@Test func anUnknownTopLevelDirectoryTakesItsLargestKnownChild() throws {
    let home = home()
    #expect(try named(home, ["world"]).category == .git)
    #expect(try named(home, ["mystery"]).category == .other)
    // A bare repository is git by its shape, whatever it is called.
    #expect(try named(home, ["monorepo"]).category == .git)
    #expect(try named(home, ["monorepo", "git"]).category == .git)
}

@Test func anUnknownDirectoryIsJudgedAtMostThreeLevelsDown() throws {
    let git = dir(".git", [])
    let home = classified(
        dir(
            "tobi",
            [
                chain(["archive", "2024", "project"], around: git),
                chain(["attic", "a", "b", "c"], around: git),
            ]
        )
    )
    #expect(try named(home, ["archive"]).category == .git)
    #expect(try named(home, ["attic"]).category == .other, "too deep to say")
}

@Test func cachesAreReclaimableAllTheWayDown() throws {
    let home = home()
    #expect(try named(home, [".cache"]).reclaim == .regenerable)
    #expect(
        try named(home, [".cache", "kache", "store"]).reclaim == .regenerable
    )
    #expect(try named(home, ["Sync", ".stversions"]).reclaim == .syncHistory)
    #expect(try named(home, ["src"]).reclaim == nil)
}

@Test func targetIsBuildOutputOnlyBesideACargoManifest() throws {
    let home = home()
    #expect(try named(home, ["rust-thing", "target"]).reclaim == .buildOutput)
    #expect(try named(home, ["js-thing", "target"]).reclaim == nil)
}

@Test func sandboxLayersAndSnapshotsAreReclaimableOnlyInSandboxState() throws {
    let home = home()
    // .microsandbox/cache is already a regenerable cache, so its layers
    // inherit that; the snapshots are judged on their own.
    #expect(
        try named(home, [".microsandbox", "cache", "layers"]).reclaim != nil
    )
    #expect(
        try named(home, [".microsandbox", "snapshots"]).reclaim == .snapshots
    )
    #expect(reclaimOf("snapshots", parent: .documents) { _ in false } == nil)
}

@Test func theLegendListsEveryNamedCategoryOnce() {
    var seen: Set<Category> = []
    for category in Category.legend {
        #expect(seen.insert(category).inserted)
        #expect(category != .other)
        #expect(!category.label.isEmpty)
    }
}

// macOS

@Test func xcodeDerivedDataIsBuildOutputWhereverItLives() throws {
    let home = macHome()
    let derived = try named(
        home,
        ["Library", "Developer", "Xcode", "DerivedData"]
    )
    #expect(derived.category == .cache)
    #expect(derived.reclaim == .buildOutput)
    #expect(
        try named(derived, ["App-bzkfqhdxrm", "App"]).reclaim == .buildOutput,
        "everything inside goes with it"
    )
    // Xcode's own name: no manifest is needed beside it.
    #expect(
        reclaimOf("DerivedData", parent: .code) { _ in false } == .buildOutput
    )
}

@Test func swiftBuildIsBuildOutputOnlyBesideAPackageManifest() throws {
    let home = macHome()
    #expect(
        try named(home, ["Developer", "tool", ".build"]).reclaim
            == .buildOutput
    )
    #expect(try named(home, ["Developer", "site", ".build"]).reclaim == nil)
}

@Test func iCloudAndFileProviderFoldersAreSyncedNeverReclaimable() throws {
    let home = macHome()
    let iCloud = try named(home, ["Library", "Mobile Documents"])
    #expect(iCloud.category == .synced)
    #expect(iCloud.reclaim == nil)
    #expect(
        try named(iCloud, ["com~apple~CloudDocs"]).category == .synced,
        "the iCloud Drive folder inherits"
    )
    // Named per account, so only the parent can say what they are.
    let drive = try named(
        home,
        ["Library", "CloudStorage", "GoogleDrive-me@example.com"]
    )
    #expect(drive.category == .synced)
    #expect(drive.reclaim == nil)
}

@Test func simulatorsAndHomebrewAreToolchainsButNotReclaimable() throws {
    let home = macHome()
    let simulators = try named(home, ["Library", "Developer", "CoreSimulator"])
    #expect(simulators.category == .toolchain)
    #expect(simulators.reclaim == nil, "a simulator holds installed apps")
    let brew = try named(home, ["Homebrew"])
    #expect(brew.category == .toolchain)
    #expect(brew.reclaim == nil)
    #expect(try named(home, ["Library", "Caches"]).reclaim == .regenerable)
}

@Test func theHomeTrashAndAVolumesTrashAreBothTrash() throws {
    let home = macHome()
    #expect(try named(home, [".Trash"]).reclaim == .trash)
    let volume = try named(home, ["Backup", ".Trashes"])
    #expect(volume.reclaim == .trash)
    #expect(volume.category == .cache)
}

@Test func libraryAndItsAppDataHaveNoKindOfTheirOwn() {
    // They hold every kind of app data, so the names decide nothing; what
    // fills them does.
    for name in ["Library", "Containers", "Application Support", "Developer"] {
        #expect(categoryOfName(name) == nil, "\(name)")
    }
}

@Test func tableNamesAreLowercaseAndListedOnce() {
    let kinds = categoryTable.flatMap(\.names)
    let reasons = reclaimTable.flatMap(\.names)
    #expect(Set(kinds).count == kinds.count, "a name with two kinds")
    #expect(Set(reasons).count == reasons.count, "a name with two reasons")
    // App data has no kind of its own; a kind would contradict that.
    #expect(appDataNames.isDisjoint(with: kinds))
    for name in kinds + reasons + appDataNames {
        // An uppercase letter in a table would never match: lookups fold.
        #expect(asciiLowercased(name) == name, "\(name)")
    }
}

@Test func onlyAsciiLettersFoldWhenANameIsLookedUp() {
    #expect(categoryOfName("SRC") == .code)
    #expect(categoryOfName("Google Drive") == .synced)
    // The Kelvin sign lowercases to `k` in Unicode, not in ASCII.
    #expect(categoryOfName("BOO\u{212A}S") == nil)
    #expect(categoryOfName("BOOKS") == .documents)
    #expect(categoryOfName(String(repeating: "src", count: 40)) == nil)
    #expect(categoryOfName("") == nil)
}

@Test func theHomeLibraryIsNotPaintedByItsCaches() throws {
    // `~/Library` on a working Mac, by `du -k -d 1`: most of it is app data,
    // and `Caches` is only its largest child with a name the tables know.
    let gib: UInt64 = 1 << 30
    let home = classified(
        dir(
            "kyle",
            [
                dir(
                    "Library",
                    [
                        chain(
                            ["Application Support", "MobileSync"],
                            around: file("backup", 82 * gib)
                        ),
                        chain(
                            ["Caches", "com.apple.Safari"],
                            around: file("db", 18 * gib)
                        ),
                        dir("Developer", [file("xcode", 10 * gib)]),
                        dir("Group Containers", [file("group", 4 * gib)]),
                        chain(
                            ["Mobile Documents", "com~apple~CloudDocs"],
                            around: file("thesis", 3 * gib)
                        ),
                    ]
                ),
                chain(["world", ".git"], around: file("pack", gib)),
            ]
        )
    )
    let library = try named(home, ["Library"])
    #expect(library.category == .other)
    for path in [
        ["Application Support"], ["Application Support", "MobileSync"],
        ["Developer"], ["Group Containers"],
    ] {
        #expect(try named(library, path).category == .other, "\(path)")
    }
    // What names itself is still coloured, and hatched, by its name.
    #expect(try named(library, ["Caches"]).category == .cache)
    #expect(try named(library, ["Caches"]).reclaim == .regenerable)
    #expect(try named(library, ["Mobile Documents"]).category == .synced)
    // Everything else at the top still takes its largest known child.
    #expect(try named(home, ["world"]).category == .git)
}

@Test func appDataFoldersAtTheTopOfAScanTakeNoKindFromAChild() throws {
    // A scan of `~/Library` itself puts its app data at the top.
    let library = classified(
        dir(
            "Library",
            [
                dir(
                    "Application Support",
                    [
                        dir("MobileSync", [file("backup", 60)]),
                        dir("Steam", [file("game", 20)]),
                    ]
                ),
                chain(
                    ["Containers", "com.apple.mail", "Data"],
                    around: dir("Caches", [file("mail", 9)])
                ),
                dir("Group Containers", [dir("Dropbox", [file("x", 7)])]),
                chain(["Developer", "CoreSimulator"], around: file("sim", 5)),
            ]
        )
    )
    for name in ["Application Support", "Containers", "Group Containers"] {
        #expect(try named(library, [name]).category == .other, "\(name)")
    }
    #expect(
        try named(library, ["Application Support", "MobileSync"]).category
            == .other
    )
    #expect(
        try named(library, ["Application Support", "Steam"]).category == .media
    )
    // `Developer` is not app data: its tools still say what it is.
    #expect(try named(library, ["Developer"]).category == .toolchain)
}

@Test func aLibraryInsideAProjectStillTakesItsParentsKind() throws {
    // Unity keeps a `Library` in every project; below the top level the
    // name changes nothing.
    let home = classified(
        dir(
            "tobi",
            [chain(["projects", "game", "Library"], around: file("cache", 3))]
        )
    )
    #expect(
        try named(home, ["projects", "game", "Library"]).category == .code
    )
}
