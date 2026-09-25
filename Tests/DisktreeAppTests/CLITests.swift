// The command line: every option, every refusal, and the root it settles on.
// Paths are real temporary directories, because the root is canonicalised
// and checked against the disk before any window exists.

import Darwin
import DisktreeCore
import Foundation
import System
import Testing

@testable import DisktreeApp

/// A fresh directory under the temporary directory, removed after `body`.
private func withDirectory<T>(
    _ body: (FilePath) throws -> T
) throws -> T {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "disktree-cli-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(FilePath(url.path(percentEncoded: false)))
}

/// The arguments `run` was asked for, or a recorded issue.
private func run(
    _ arguments: [String],
    home: FilePath?
) throws -> Arguments {
    switch try parseArguments(arguments, home: home) {
    case .run(let parsed):
        return parsed
    case .help:
        Issue.record("\(arguments) asked for help")
        throw UsageError("help")
    }
}

/// The message `arguments` are refused with.
private func refusal(_ arguments: [String], home: FilePath? = nil) -> String? {
    #expect(throws: UsageError.self) {
        try parseArguments(arguments, home: home)
    }?.message
}

private func resolved(_ path: FilePath) -> FilePath {
    canonicalPath(path) ?? path
}

@Test func noPathScansTheHomeDirectory() throws {
    try withDirectory { home in
        let parsed = try run([], home: home)
        #expect(parsed.root == resolved(home))
        #expect(parsed.options == ScanOptions())
        #expect(parsed.depth == 3)
        #expect(parsed.snapshot == nil)
        #expect(parsed.keys.isEmpty)
    }
}

@Test func noPathAndNoHomeIsRefused() {
    #expect(refusal([]) == "no path given and HOME is not set")
}

@Test func everyFlagSetsItsOption() throws {
    try withDirectory { root in
        for spelling in [
            ["-a", "-l", "-H", "-X"],
            [
                "--apparent-size", "--follow-links", "--no-hidden",
                "--cross-filesystems",
            ],
        ] {
            let parsed = try run(spelling + [root.string], home: nil)
            #expect(parsed.options.apparentSize)
            #expect(parsed.options.followLinks)
            #expect(!parsed.options.includeHidden)
            #expect(!parsed.options.oneFilesystem)
            // Untouched by any flag.
            #expect(parsed.options.dedupHardlinks)
            #expect(parsed.options.maxDepth == nil)
        }
    }
}

/// Without a flag, a run takes what Settings keeps, and says so; every
/// setting a flag changes has a flag back, for one run.
@Test func theDefaultsAreTheSavedOnesAndEveryFlagHasAWayBack() throws {
    #expect(usage.contains("what Settings keeps"))
    #expect(!usage.contains("default 3") && !usage.contains("off by default"))
    let saved = Preferences(
        depth: 5,
        includeHidden: false,
        apparentSize: true,
        oneFilesystem: false
    )
    try withDirectory { root in
        let plain = try parseArguments([root.string], preferences: saved)
        guard case .run(let kept) = plain else {
            Issue.record("asked for help")
            return
        }
        #expect(kept.depth == 5)
        #expect(!kept.options.includeHidden && kept.options.apparentSize)
        #expect(!kept.options.oneFilesystem)

        let back = try parseArguments(
            ["--hidden", "--disk-usage", "-x", "-d", "3", root.string],
            preferences: saved
        )
        guard case .run(let shipped) = back else {
            Issue.record("asked for help")
            return
        }
        #expect(shipped.options == ScanOptions())
        #expect(shipped.depth == 3)
    }
    for flag in ["--hidden", "--disk-usage", "-x, --one-filesystem"] {
        #expect(usage.contains(flag), "\(flag) is listed")
    }
}

@Test func oneFilesystemIsTheDefaultAndStillAccepted() throws {
    try withDirectory { root in
        let plain = try run([root.string], home: nil)
        #expect(plain.options.oneFilesystem)
        for flag in ["-x", "--one-filesystem"] {
            let parsed = try run(["-X", flag, root.string], home: nil)
            #expect(parsed.options.oneFilesystem)
        }
    }
}

@Test func helpWinsWhereverItIs() throws {
    try withDirectory { root in
        for arguments in [["-h"], ["--help"], [root.string, "-a", "--help"]] {
            let parsed = try parseArguments(arguments, home: nil)
            #expect(parsed == .help)
        }
    }
    // Read in order, as the Rust did: a mistake before it is still one.
    #expect(refusal(["--depth", "9", "--help"]) == "--depth must be 1 to 6")
}

@Test func usageSaysNothingIsDeletedHere() {
    #expect(usage.contains("never deletes anything itself"))
    #expect(usage.contains("Finder"))
    // The developer flags stay out of it.
    #expect(!usage.contains("--snapshot"))
    #expect(!usage.contains("--keys"))
}

@Test func depthIsOneToSix() throws {
    try withDirectory { root in
        for levels in depthRange {
            for flag in ["-d", "--depth"] {
                let parsed = try run(
                    [flag, "\(levels)", root.string], home: nil)
                #expect(parsed.depth == levels)
            }
        }
    }
    #expect(refusal(["-d", "0"]) == "--depth must be 1 to 6")
    #expect(refusal(["--depth", "7"]) == "--depth must be 1 to 6")
    #expect(refusal(["-d", "three"]) == "--depth needs a number")
    // Unsigned, as in the Rust: a negative is not a number of levels.
    #expect(refusal(["-d", "-1"]) == "--depth needs a number")
    #expect(refusal(["-d"]) == "--depth needs a number")
}

@Test func metricNamesBytesOrFiles() throws {
    try withDirectory { root in
        let metric = { (name: String) in
            try run(["--metric", name, root.string], home: nil).options.metric
        }
        let files = try metric("files")
        let bytes = try metric("bytes")
        let size = try metric("size")
        #expect(files == .files)
        #expect(bytes == .bytes)
        #expect(size == .bytes)
    }
    #expect(
        refusal(["--metric", "blocks"])
            == "unknown metric blocks; try bytes or files"
    )
    #expect(refusal(["--metric"]) == "--metric needs a value")
}

@Test func anUnknownOptionIsRefusedWithTheUsage() {
    let message = refusal(["--frobnicate"])
    #expect(message?.hasPrefix("unknown option --frobnicate\n\n") == true)
    #expect(message?.hasSuffix(usage) == true)
}

@Test func onlyOnePathCanBeScanned() throws {
    try withDirectory { root in
        #expect(
            refusal([root.string, root.string])
                == "only one path can be scanned"
        )
    }
}

@Test func diskScansTheDiskTheHomeDirectoryIsOn() throws {
    try withDirectory { home in
        for flag in ["-D", "--disk"] {
            let parsed = try run([flag], home: home)
            #expect(parsed.root == resolved(volumeRootFor(home) ?? "/"))
        }
        #expect(
            refusal(["--disk", home.string], home: home)
                == "--disk and a PATH cannot be combined"
        )
        #expect(
            refusal([home.string, "-D"], home: home)
                == "--disk and a PATH cannot be combined"
        )
    }
}

@Test func theRootIsCanonical() throws {
    try withDirectory { directory in
        let real = directory.appending("real")
        let link = directory.appending("link")
        #expect(mkdir(real.string, 0o755) == 0)
        #expect(symlink(real.string, link.string) == 0)
        let parsed = try run([link.string], home: nil)
        #expect(parsed.root == resolved(real))
        // The temporary directory is itself behind a symlink on macOS
        // (`/var` is `/private/var`); the scanner and the mount table only
        // know the real path.
        #expect(parsed.root.string.hasPrefix("/private/"))
        let dotted = try run([directory.string + "/real/../real/."], home: nil)
        #expect(dotted.root == parsed.root)
    }
}

@Test func aFileIsRefused() throws {
    try withDirectory { directory in
        let file = directory.appending("notes.txt")
        #expect(
            FileManager.default.createFile(
                atPath: file.string,
                contents: Data("x".utf8)
            )
        )
        #expect(
            refusal([file.string])
                == "\(resolved(file).string) is not a directory"
        )
    }
}

@Test func aMissingPathIsRefused() throws {
    try withDirectory { directory in
        let missing = directory.appending("gone")
        #expect(
            refusal([missing.string])
                == "cannot read \(missing.string): No such file or directory"
        )
    }
}

@Test func theProcessSerialNumberIsIgnored() throws {
    try withDirectory { home in
        let parsed = try run(["-psn_0_1234567"], home: home)
        #expect(parsed.root == resolved(home))
    }
}

@Test func snapshotAndKeysAreReadButHidden() throws {
    try withDirectory { root in
        let parsed = try run(
            [
                "--snapshot", "/tmp/shot.png", "--keys", "space  c ctrl-= ?",
                root.string,
            ],
            home: nil
        )
        #expect(parsed.snapshot == "/tmp/shot.png")
        #expect(
            parsed.keys == [
                KeyStroke("space"),
                KeyStroke("c", character: "c"),
                KeyStroke("=", control: true),
                KeyStroke("?", character: "?"),
            ]
        )
    }
}

@Test func aRelativeSnapshotIsTheWorkingDirectorys() throws {
    try withDirectory { root in
        let parsed = try run(
            ["--snapshot", "shot.png", root.string], home: nil)
        let here = FilePath(FileManager.default.currentDirectoryPath)
        #expect(parsed.snapshot == here.appending("shot.png"))
    }
}

@Test func snapshotAndKeysNeedValues() {
    #expect(refusal(["--snapshot"]) == "--snapshot needs a file")
    #expect(refusal(["--keys"]) == "--keys needs a list of keys")
    #expect(
        refusal(["--keys", "space spacebar"]) == "--keys: spacebar is not a key"
    )
}

@Test func aFolderFromFinderIsCanonicalAndADirectory() throws {
    try withDirectory { directory in
        let url = URL(filePath: directory.string, directoryHint: .isDirectory)
        #expect(scannableFolder(url) == resolved(directory))
        let file = directory.appending("notes.txt")
        FileManager.default.createFile(atPath: file.string, contents: nil)
        #expect(scannableFolder(URL(filePath: file.string)) == nil)
        let web = try #require(URL(string: "https://example.com/"))
        #expect(scannableFolder(web) == nil)
    }
}
