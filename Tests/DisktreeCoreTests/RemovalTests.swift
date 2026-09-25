// The removal guards and the copied command, against real temporary trees.
//
// disktree removes nothing itself, so what is tested is what it hands over:
// the plan (what may go, what is covered, what is refused and why) and the
// command a terminal will run. The command is run here too — by sh, bash and
// zsh for the quoting, and for real on scratch trees — because a command
// that looks right but removes a neighbour is the one mistake that matters.
//
// Not ported from the Rust, because the code they cover is gone: the
// in-app removal (`permanent_removal_*`, the removal run's events), the XDG
// trash (`percent_encoding_escapes_what_the_spec_requires`,
// `trash_names_avoid_collisions`,
// `the_xdg_trash_moves_a_file_and_records_where_it_came_from`,
// `a_trash_info_path_is_restorable`) and the trash tools
// (`a_trash_tool_is_called_with_the_path_after_a_separator`,
// `a_failing_trash_tool_reports_its_stderr`).

import Darwin
import Foundation
import System
import Testing

@testable import DisktreeCore

// MARK: - Fixtures

/// A fresh directory under the temporary directory; the caller discards it.
private func scratch() throws -> FilePath {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "disktree-removal-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true
    )
    return FilePath(url.path(percentEncoded: false))
}

private func discard(_ path: FilePath) {
    try? FileManager.default.removeItem(atPath: path.string)
}

private func makeDirectory(_ path: FilePath) throws {
    try FileManager.default.createDirectory(
        atPath: path.string,
        withIntermediateDirectories: true
    )
}

private func write(_ path: FilePath, count: Int) throws {
    try Data(repeating: UInt8(ascii: "x"), count: count)
        .write(to: URL(filePath: path.string))
}

private func symlink(_ link: FilePath, to destination: FilePath) throws {
    try FileManager.default.createSymbolicLink(
        atPath: link.string,
        withDestinationPath: destination.string
    )
}

/// Whether the entry itself exists: a symlink counts, whatever it points at.
private func exists(_ path: FilePath) -> Bool {
    var info = stat()
    return lstat(path.string, &info) == 0
}

private func isDirectory(_ path: FilePath) -> Bool {
    var info = stat()
    return stat(path.string, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
}

private func target(_ path: FilePath, _ bytes: UInt64) -> Target {
    Target(path: path, bytes: bytes, isDir: isDirectory(path), hidden: false)
}

/// `a/b/`, `a/one.bin` (10 bytes), `a/c.bin` (20 bytes) and `other/`.
private func tree() throws -> FilePath {
    let root = try scratch()
    try makeDirectory(root.appending("a/b"))
    try write(root.appending("a/one.bin"), count: 10)
    try write(root.appending("a/c.bin"), count: 20)
    try makeDirectory(root.appending("other"))
    return root
}

/// Run a tool to completion, quietly; whether it succeeded.
private func run(_ tool: String, _ arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(filePath: tool)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return false
    }
    process.waitUntilExit()
    return process.terminationReason == .exit && process.terminationStatus == 0
}

// MARK: - Plans

@Test func aPlanKeepsOnlyTheOutermostTargets() throws {
    let root = try tree()
    defer { discard(root) }
    let inner = target(root.appending("a/b"), 5)
    let outer = target(root.appending("a"), 30)
    let separate = target(root.appending("other"), 0)

    let planned = plan([inner, outer, separate], root: root)
    #expect(planned.targets.count == 2)
    #expect(planned.targets.contains(outer))
    #expect(planned.targets.contains(separate))
    #expect(planned.covered.count == 1)
    #expect(planned.covered.first?.path == inner.path)
    #expect(planned.bytes == 30)
}

@Test func theRootAndHomeAreRefused() throws {
    let root = try tree()
    defer { discard(root) }
    let home = defaultHome()
    var targets = [target("/", 0), target(root, 0)]
    if let home {
        targets.append(target(home, 0))
    }

    let planned = plan(targets, root: root)
    #expect(planned.isEmpty)
    #expect(planned.blocked.count == targets.count)
    #expect(
        home == nil
            || planned.blocked.contains { $0.reason.contains("home directory") }
    )
}

/// Removing a directory removes everything in it, so one that holds the
/// home directory is refused as the home directory is. On a standard Mac
/// that is `/` and `/Users`, refused anyway; not so for a home directory
/// on another volume, or wherever `$HOME` points.
@Test func aDirectoryHoldingTheHomeDirectoryIsRefused() throws {
    let root = try tree()
    defer { discard(root) }
    let people = root.appending("people")
    let home = people.appending("tobi")
    try makeDirectory(home.appending("src"))
    try makeDirectory(root.appending("people-other"))

    let planned = plan(
        [
            target(people, 0), target(home.appending("src"), 0),
            target(root.appending("people-other"), 0),
        ],
        root: root,
        home: home
    )
    #expect(planned.blocked.map(\.path) == [people])
    #expect(
        planned.blocked.first?.reason.contains("home directory") == true
    )
    #expect(
        planned.targets.map(\.path) == [
            home.appending("src"), root.appending("people-other"),
        ],
        "inside it is fine, and people-other does not hold people/tobi"
    )
    #expect(
        removalRefusal(for: "/Users", root: "/", home: "/Users/tobi")?
            .contains("home directory") == true
    )
    #expect(
        removalRefusal(
            for: "/Volumes/X/USERS",
            root: "/Volumes/X",
            home: "/Volumes/X/Users/tobi"
        )?.contains("home directory") == true,
        "folded like the other refusals"
    )
}

@Test func pathsOutsideTheRootAreRefused() throws {
    let root = try tree()
    defer { discard(root) }
    let planned = plan([target("/etc/passwd", 1)], root: root)
    #expect(planned.isEmpty)
    #expect(planned.blocked.first?.reason == "outside the scanned root")
}

@Test func siblingPrefixesAreNotTreatedAsContainment() throws {
    let root = try tree()
    defer { discard(root) }
    try makeDirectory(root.appending("a-real"))
    let planned = plan(
        [target(root.appending("a"), 1), target(root.appending("a-real"), 1)],
        root: root
    )
    #expect(planned.targets.count == 2, "a-real is not inside a")
    #expect(planned.covered.isEmpty)
}

@Test func targetsAreOrderedByWholeComponents() throws {
    let root = try tree()
    defer { discard(root) }
    try makeDirectory(root.appending("a-real"))
    let inner = root.appending("a/b")
    let sibling = root.appending("a-real")

    // As text `a-real` sorts before `a/b` ('-' is below '/'); by components
    // `a` comes first, and so does everything inside it.
    let planned = plan(
        [target(sibling, 1), target(inner, 1), target(inner, 1)],
        root: root
    )
    #expect(planned.targets.map(\.path) == [inner, sibling])
    #expect(planned.covered.map(\.path) == [inner], "marked twice")
}

/// A scan with `--follow-links` shows a symlinked directory's contents as
/// if they were inside the root; a mark there would act on wherever the link
/// points.
@Test func pathsReachedThroughASymlinkAreRefused() throws {
    let root = try tree()
    defer { discard(root) }
    let elsewhere = try scratch()
    defer { discard(elsewhere) }
    try write(elsewhere.appending("precious.bin"), count: 4)
    let link = root.appending("link")
    try symlink(link, to: elsewhere)

    let through = link.appending("precious.bin")
    let planned = plan([target(through, 4), target(link, 0)], root: root)
    #expect(planned.blocked.map(\.path) == [through])
    #expect(
        planned.blocked.first?.reason.contains("symlink \(link.string)")
            == true
    )
    #expect(planned.targets.map(\.path) == [link], "the link itself may go")
}

@Test func normalizeResolvesDotsWithoutTheFilesystem() {
    #expect(normalize("/Users/tobi/./src/../src/") == "/Users/tobi/src")
    #expect(normalize("a/../b") == "b")
    #expect(normalize("/..") == "/")
    #expect(normalize("../x") == "../x")
}

@Test func relativeAndUnnormalizedPathsNeverReachARemoval() throws {
    let root = try tree()
    defer { discard(root) }

    let planned = plan(
        [target("a/b", 1), target(root.appending("a/b/.."), 30)],
        root: root
    )
    #expect(planned.blocked.map(\.reason) == ["not an absolute path"])
    #expect(
        planned.targets.map(\.path) == [root.appending("a")],
        "a plan acts on the normalized path"
    )

    // Nor does the command: it names only the normalized target.
    let command = try #require(cleanupCommand(planned, style: .remove))
    #expect(!command.contains(".."))
    #expect(!command.contains("'a/b'"))
}

@Test func aNameThatIsNotUTF8IsRefused() throws {
    let root = try tree()
    defer { discard(root) }
    // `/x` and then 0xFF, a byte that never appears in UTF-8.
    let raw = Array(root.string.utf8) + [0x2F, 0x78, 0xFF, 0]
    let path = raw.map { CChar(bitPattern: $0) }.withUnsafeBufferPointer {
        buffer in buffer.baseAddress.map { FilePath(platformString: $0) }
    }
    let named = try #require(path)
    #expect(FilePath(named.string) != named, "it does not survive as text")
    #expect(
        removalRefusal(for: named, root: root, home: nil)?.contains("UTF-8")
            == true
    )
}

@Test func aNameTheScanCouldNotDecodeIsRefused() throws {
    let root = try tree()
    defer { discard(root) }
    // `a`, 0xFF, `b`, as a network or user-space filesystem may hold it
    // (APFS refuses it), and as the walk decodes it: the byte becomes a
    // replacement character. Every mark's path is built from such names.
    let decoded = String(decoding: [0x61, 0xFF, 0x62], as: UTF8.self)
    // An unmarked neighbour whose name really is that text.
    let neighbour = root.appending("a\u{FFFD}b")
    try write(neighbour, count: 10)
    let scanned = Node.directory(
        "root",
        children: [.entry(decoded, kind: .file, bytes: 10)]
    )
    let marked = pathOf(rootPath: root, root: scanned, crumbs: [0])
    #expect(marked == neighbour, "the decoded name names the neighbour")

    let planned = plan([target(marked, 10)], root: root, home: nil)
    #expect(planned.targets.isEmpty)
    #expect(planned.blocked.first?.reason.contains("UTF-8") == true)
    #expect(cleanupCommand(planned, style: .remove) == nil)

    // Followed by a combining mark, the replacement character is part of
    // a character that does not equal it; it is refused all the same.
    let combined = String(decoding: [0x61, 0xFF, 0xCC, 0x81], as: UTF8.self)
    let accented = root.appending(combined)
    #expect(removalRefusal(for: accented, root: root, home: nil) != nil)
}

@Test func mountPointsAreRecognized() throws {
    let root = try tree()
    defer { discard(root) }
    #expect(!isMountPoint(root))
    #expect(!isMountPoint(root.appending("a")))
    #expect(!isMountPoint(root.appending("a/one.bin")), "only directories")
    // devfs is mounted at /dev on every Mac.
    #expect(isMountPoint("/dev"))
    #expect(isMountPoint("/"), "the root has no parent to share a volume with")
}

/// The system and Data volumes share one device number, so only `statfs`
/// sees that `/Users` crosses from one into the other, and that the Data
/// volume is mounted at `/System/Volumes/Data` at all.
@Test(
    .enabled(if: FileManager.default.fileExists(atPath: "/System/Volumes/Data"))
)
func firmlinksAndTheDataVolumeAreMountPoints() {
    #expect(isMountPoint("/Users"))
    #expect(isMountPoint("/Applications"))
    #expect(isMountPoint("/System/Volumes/Data"))
    #expect(!isMountPoint("/System/Volumes/Data/Users"))

    // Not `/Users`: holding the home directory is the first thing said
    // about that one.
    let planned = plan(
        [target("/Applications", 0)],
        root: "/",
        home: "/Users/tobi"
    )
    #expect(planned.blocked.first?.reason.contains("mount point") == true)
}

@Test func systemTreesAreRefusedInAWholeDiskScan() {
    let home: FilePath = "/Users/tobi"
    #expect(
        systemTree(containing: "/usr/lib/libfoo.dylib", home: home)?.tree
            == "/usr"
    )
    #expect(
        systemTree(containing: "/private/var/db/receipts", home: home)?.tree
            == "/private/var/db"
    )
    #expect(
        systemTree(containing: "/var/db/receipts", home: home)?.tree
            == "/var/db",
        "the spelling through the /var symlink"
    )
    #expect(
        systemTree(containing: "/private/var/folders/xy/T", home: home) == nil
    )
    #expect(systemTree(containing: "/opt/thing", home: home) == nil)
    #expect(
        systemTree(containing: "/usrlocal", home: home) == nil,
        "components, not prefixes"
    )
    let oddHome: FilePath = "/usr/home/tobi"
    #expect(
        systemTree(containing: "/usr/home/tobi/.cache", home: oddHome) == nil
    )
    // `/etc` is also a symlink, which would be refused on its own; who owns
    // the tree is the better answer, so it is the one given.
    let reason = removalRefusal(for: "/etc/hosts", root: "/", home: home)
    #expect(reason == "part of macOS under /etc: macOS owns it")
}

@Test func systemTreesNameTheirOwnersTool() {
    let home: FilePath = "/Users/tobi"
    func reason(_ path: FilePath) -> String? {
        removalRefusal(for: path, root: "/", home: home)
    }

    #expect(reason("/opt/homebrew/Cellar/node")?.contains("brew") == true)
    #expect(
        systemTree(containing: "/usr/local/Cellar/node", home: home)?.tree
            == "/usr/local",
        "the innermost tree speaks"
    )
    #expect(reason("/usr/local/Cellar/node")?.contains("brew") == true)
    #expect(reason("/opt/local/var/macports")?.contains("port") == true)
    #expect(reason("/nix/store/abc-hello")?.contains("nix-collect") == true)
    #expect(reason("/private/var/vm/swapfile0")?.contains("swap") == true)
    #expect(reason("/Library/Apple/usr/libexec")?.contains("macOS") == true)
    #expect(
        reason("/System/Volumes/Data/Users/tobi/big.iso")?.contains("/Users")
            == true,
        "the Data volume is reached through its firmlinks, not here"
    )
    // Core dumps are disposable by design; caches are there to be cleared.
    #expect(systemTree(containing: "/cores/core.1234", home: home) == nil)
    #expect(systemTree(containing: "/Library/Caches/x", home: home) == nil)
}

@Test func refusalsIgnoreCaseButTheRootCheckDoesNot() {
    let home: FilePath = "/Users/tobi"
    #expect(
        removalRefusal(for: "/USR/lib/x", root: "/", home: home)?
            .contains("/usr") == true
    )
    #expect(
        removalRefusal(for: "/users/TOBI", root: "/", home: home)
            == "the home directory cannot be removed"
    )
    #expect(
        removalRefusal(
            for: "/Users/tobi/work",
            root: "/users/tobi/WORK",
            home: nil
        ) == "the scanned root cannot be removed"
    )
    // Being inside the root is what permits a removal, so it stays exact.
    #expect(
        removalRefusal(for: "/Users/Tobi/x", root: "/Users/tobi", home: nil)
            == "outside the scanned root"
    )
}

@Test func theHomeLibraryIsRefusedButNotWhatIsInIt() {
    let home: FilePath = "/Users/tobi"
    #expect(
        removalRefusal(for: "/Users/tobi/Library", root: home, home: home)?
            .contains("~/Library") == true
    )
    #expect(
        removalRefusal(for: "/Users/tobi/library", root: home, home: home)?
            .contains("~/Library") == true
    )
    #expect(
        removalRefusal(
            for: "/Users/tobi/Library/Caches/com.example",
            root: home,
            home: home
        ) == nil
    )
}

/// The Data volume's own name reaches the same files as the firmlinks, but
/// spelled so that no guard recognizes them: the home directory under it is
/// not `home` to a lexical comparison.
@Test func theDataVolumeUnderItsOwnNameIsRefused() {
    let home: FilePath = "/Users/tobi"
    for path: FilePath in [
        "/System/Volumes/Data/Users/tobi",
        "/System/Volumes/Data/Users/tobi/Library",
        "/System/Volumes/Data/private/var/db/receipts",
    ] {
        #expect(
            systemTree(containing: path, home: home)?.tree
                == "/System/Volumes/Data"
        )
        #expect(
            removalRefusal(for: path, root: "/", home: home)?
                .contains("firmlinks") == true
        )
    }
    let planned = plan(
        [target("/System/Volumes/Data/Users/tobi", 0)],
        root: "/System/Volumes/Data",
        home: home
    )
    #expect(planned.isEmpty, "a scan rooted there removes nothing either")
}
// MARK: - The command

/// What `sh -c script` prints and whether it exited 0.
private func shell(
    _ shell: String,
    _ script: String
) throws -> (output: String, ok: Bool) {
    let process = Process()
    process.executableURL = URL(filePath: shell)
    process.arguments = ["-c", script]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (
        String(decoding: data, as: UTF8.self),
        process.terminationReason == .exit && process.terminationStatus == 0
    )
}

/// Names a shell would otherwise split, expand, glob or read as an option.
private let awkwardNames = [
    "plain",
    "with space",
    "it's",
    "''",
    "\"double\"",
    "$HOME",
    "`echo pwned`",
    "$(echo pwned)",
    "*",
    "-rf",
    "back\\slash",
    "new\nline",
    "tab\there",
    "e\u{301}te\u{301}",
    "été",
    "📦 box",
    "!bang",
    "semi;colon",
    "amp&rsand",
    "pipe|name",
    "~tilde",
]

/// Names a terminal acts on rather than passes along: a carriage return it
/// reads as a newline (`Icon\r` is the file behind a folder's custom icon),
/// ^C it turns into an interrupt, ^U and DEL it edits the line with, the end
/// of a bracketed paste. No quoting keeps them from the tty a command is
/// pasted into, so they are refused.
private let controlNames = [
    "Icon\r",
    "new\nline",
    "tab\there",
    "cache\u{3}touch INJECTED\r",
    "cache\u{1B}[201~\u{3}touch INJECTED\r",
    "kill\u{15}line",
    "erase\u{7F}",
    "next\u{85}line",
]

/// The awkward names that reach a shell through a terminal as they are.
private let pasteableNames = awkwardNames.filter { name in
    !name.unicodeScalars.contains {
        $0.value < 0x20 || (0x7F...0x9F).contains($0.value)
    }
}

@Test func quotingGivesEveryShellThePathBackByteForByte() throws {
    for shellPath in ["/bin/sh", "/bin/bash", "/bin/zsh"] {
        for name in awkwardNames {
            let path = FilePath("/tmp/disktree-quoting").appending(name)
            let (output, ok) = try shell(
                shellPath,
                "printf '%s' " + shellQuoted(path)
            )
            #expect(ok, "\(shellPath) rejected \(name.debugDescription)")
            #expect(
                output == path.string,
                "\(shellPath) turned \(name.debugDescription) into \(output.debugDescription)"
            )
        }
    }
}

@Test func theCommandNamesTheTargetsAndNothingElse() throws {
    let root = try tree()
    defer { discard(root) }
    let planned = plan(
        [
            target(root.appending("a/b"), 5),
            target(root.appending("a"), 30),
            target(root, 0),
            target("/etc/hosts", 1),
        ],
        root: root,
        home: nil
    )
    #expect(planned.targets.map(\.path) == [root.appending("a")])

    let trash = try #require(cleanupCommand(planned, style: .trash))
    let lines = trash.split(separator: "\n").map(String.init)
    #expect(
        lines == [
            "/usr/bin/trash \\", "    " + shellQuoted(root.appending("a")),
        ])

    let remove = try #require(cleanupCommand(planned, style: .remove))
    #expect(remove.hasPrefix("/bin/rm -rfx -- \\\n"))
    #expect(!remove.contains(shellQuoted(root.appending("a/b"))), "covered")
    #expect(!remove.contains("/etc/hosts"), "blocked")
    #expect(!remove.contains(shellQuoted(root) + "\n"), "the root, refused")

    #expect(cleanupCommand(Plan(), style: .trash) == nil)
}

/// The copied command, run for real: every marked path goes, however it is
/// spelled, and nothing beside it does — not a neighbour whose name is a
/// prefix, not what a marked symlink points at.
@Test func theDeleteCommandRemovesExactlyTheMarkedPaths() throws {
    let root = try scratch()
    let outside = try scratch()
    defer {
        discard(root)
        discard(outside)
    }
    var marked: [FilePath] = []
    var kept: [FilePath] = []
    for name in pasteableNames {
        let doomed = root.appending(name)
        try makeDirectory(doomed.appending("inner"))
        try write(doomed.appending("inner/file.bin"), count: 3)
        marked.append(doomed)
        // A sibling whose name starts with the marked one's.
        let neighbour = root.appending(name + "-kept")
        try write(neighbour, count: 1)
        kept.append(neighbour)
    }
    // A marked symlink goes; what it points at stays. So does what a symlink
    // inside a marked directory points at.
    let precious = outside.appending("precious.bin")
    try write(precious, count: 9)
    let link = root.appending("link")
    try symlink(link, to: outside)
    marked.append(link)
    try symlink(marked[0].appending("inner/escape"), to: outside)

    let planned = plan(marked.map { target($0, 1) }, root: root, home: nil)
    #expect(planned.blocked.isEmpty, "\(planned.blocked)")
    let command = try #require(cleanupCommand(planned, style: .remove))
    let (_, ok) = try shell("/bin/sh", command)
    #expect(ok)

    for path in marked {
        #expect(!exists(path), "\(path.string.debugDescription) is gone")
    }
    for path in kept {
        #expect(exists(path), "\(path.string.debugDescription) stays")
    }
    #expect(exists(precious), "a symlink's target is never followed")
    #expect(exists(outside))
}

@Test func aNameHoldingAControlCharacterIsRefused() throws {
    let root = try tree()
    defer { discard(root) }
    for name in controlNames {
        let path = root.appending(name)
        try write(path, count: 1)
        let reason = removalRefusal(for: path, root: root, home: nil)
        #expect(
            reason?.contains("control character") == true,
            "\(name.debugDescription): \(reason ?? "let through")"
        )
    }
    // The command names only the marked directory, whatever is inside it.
    let folder = root.appending("with an icon")
    try makeDirectory(folder)
    try write(folder.appending("Icon\r"), count: 1)
    #expect(removalRefusal(for: folder, root: root, home: nil) == nil)
}

/// What a shell gets when the command is pasted into a terminal, rather than
/// handed to `sh -c`: the terminal writes the paste to a pseudo-terminal,
/// whose line discipline reads it before any shell does — a carriage
/// return as a newline, ^C as an interrupt, ^U as "erase the line". What
/// comes out the other side must be the command, byte for byte, and a
/// marked `Icon\r` must not become its unmarked neighbour `Icon\n`.
@Test(
    .enabled(if: FileManager.default.isExecutableFile(atPath: script)),
    .timeLimit(.minutes(1))
)
func aCopiedCommandReachesTheShellThroughATerminalUnchanged() throws {
    let root = try scratch()
    defer { discard(root) }
    let names = pasteableNames + controlNames
    for name in names {
        try write(root.appending(name), count: 1)
    }
    let planned = plan(
        names.map { target(root.appending($0), 1) },
        root: root,
        home: nil
    )
    #expect(
        Set(planned.blocked.map(\.path))
            == Set(controlNames.map { root.appending($0) })
    )
    #expect(planned.targets.count == pasteableNames.count)
    for style in CommandStyle.allCases {
        let command = try #require(cleanupCommand(planned, style: style))
        #expect(try throughATerminal(command + "\n") == command + "\n")
    }
}

private let script = "/usr/bin/script"

/// `text` written to a pseudo-terminal the way a terminal writes a paste,
/// and what a program reading it in the default line discipline — canonical
/// input, signals, a carriage return read as a newline — receives: `head`,
/// which stops once as many lines arrived as were sent.
private func throughATerminal(_ text: String) throws -> String {
    let folder = try scratch()
    defer { discard(folder) }
    let received = folder.appending("received")
    let lines = text.utf8.count { $0 == UInt8(ascii: "\n") }
    let process = Process()
    process.executableURL = URL(filePath: script)
    process.arguments = [
        "-q", "/dev/null", "/bin/sh", "-c", "head -n \(lines) > \"$0\"",
        received.string,
    ]
    let input = Pipe()
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    try input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
    // A line the terminal swallowed never arrives, and `head` waits for it:
    // closing the input is an end of file, and then it gives up.
    if !exits(process, within: 10) {
        try input.fileHandleForWriting.close()
        if !exits(process, within: 5) {
            process.terminate()
            process.waitUntilExit()
        }
    }
    let data = FileManager.default.contents(atPath: received.string)
    return String(decoding: data ?? Data(), as: UTF8.self)
}

/// Whether `process` ends within `seconds`.
private func exits(_ process: Process, within seconds: Double) -> Bool {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while process.isRunning, Date() < deadline {
        usleep(10_000)
    }
    return !process.isRunning
}

/// `trash` really moves the marked path to the Trash. The test then takes it
/// back out, by its unique name, so the user's Trash is left as it was.
///
/// Opt-in, with `DISKTREE_TEST_TRASH=1`: it writes to and reads from
/// `~/.Trash`, which the tests otherwise never touch, since a privacy prompt
/// there would stall the run until someone answered it.
@Test(
    .enabled(
        if: ProcessInfo.processInfo.environment["DISKTREE_TEST_TRASH"] == "1",
        "reads ~/.Trash: set DISKTREE_TEST_TRASH=1 to run it"
    ),
    .timeLimit(.minutes(1))
)
func theTrashCommandMovesTheMarkedPathToTheTrash() throws {
    let root = try scratch()
    defer { discard(root) }
    let name = "disktree-test-\(UUID().uuidString) it's"
    let doomed = root.appending(name)
    try write(doomed, count: 4)
    let beside = root.appending(name + "-kept")
    try write(beside, count: 4)

    let planned = plan([target(doomed, 4)], root: root, home: nil)
    let command = try #require(cleanupCommand(planned, style: .trash))
    let (_, ok) = try shell("/bin/sh", command)
    let home = try #require(defaultHome())
    let trashed = home.appending(".Trash").appending(name)
    defer { discard(trashed) }

    #expect(ok)
    #expect(!exists(doomed))
    #expect(exists(beside))
    #expect(exists(trashed), "in the Trash, where Put Back can find it")
}

/// The scan never showed what is on a volume mounted inside a marked
/// directory, so nothing on it was marked. Moved to the Trash, by `trash` or
/// in Finder, the directory would take the volume along, still mounted: so
/// a directory holding one is refused, whatever the style. A volume mounted
/// after the command was copied is `rm -x`'s to leave: it takes everything
/// else. Proved with a real disk image attached inside the scratch
/// directory.
@Test(
    .enabled(if: FileManager.default.isExecutableFile(atPath: hdiutil)),
    .timeLimit(.minutes(1))
)
func theDeleteCommandLeavesAVolumeMountedInsideATarget() throws {
    let root = try scratch()
    let image = root.appending("volume.dmg")
    let doomed = root.appending("doomed")
    let mount = doomed.appending("mnt")
    try makeDirectory(mount)
    try makeDirectory(doomed.appending("sub"))
    try write(doomed.appending("a.bin"), count: 10)
    try write(doomed.appending("sub/b.bin"), count: 10)

    // Copied before the volume is mounted, and run after.
    let copied = plan([target(doomed, 20)], root: root, home: nil)
    let command = try #require(cleanupCommand(copied, style: .remove))

    let created = run(
        hdiutil,
        [
            "create", "-quiet", "-size", "1m", "-fs", "HFS+", "-layout", "NONE",
            "-volname", "disktree-test", "-o", image.string,
        ]
    )
    let attached =
        created
        && run(
            hdiutil,
            [
                "attach", "-quiet", "-nobrowse", "-noverify", "-noautoopen",
                "-mountpoint", mount.string, image.string,
            ]
        )
    // Detached by device, which finds the volume wherever it has got to;
    // by the mount point when the device cannot be read back.
    let device = attached ? mountSource(mount) : nil
    defer {
        // Always detach before the scratch directory goes: removing it with
        // the volume still mounted would reach into the volume. Only then is
        // the scratch directory discarded, and not at all while something
        // is still mounted in it.
        if attached {
            let volume = device ?? mount.string
            if !run(hdiutil, ["detach", "-quiet", volume]) {
                _ = run(hdiutil, ["detach", "-quiet", "-force", volume])
            }
        }
        if !isMountPoint(mount) {
            discard(root)
        }
    }
    // No disk images here (a sandbox, a container): nothing to prove it
    // with, and said so rather than passed.
    guard attached, device != nil else {
        try Test.cancel("hdiutil could not attach a disk image here")
    }
    let precious = mount.appending("precious.bin")
    try write(precious, count: 7)

    #expect(isMountPoint(mount))
    #expect(!isMountPoint(doomed))
    let refused = plan([target(mount, 0)], root: root, home: nil)
    #expect(refused.blocked.first?.reason.contains("mount point") == true)
    #expect(cleanupCommand(refused, style: .remove) == nil)

    let holding = plan([target(doomed, 20)], root: root, home: nil)
    #expect(
        holding.blocked.first?.reason.contains("mounted inside it") == true,
        "\(holding.blocked)"
    )
    for style in CommandStyle.allCases {
        #expect(cleanupCommand(holding, style: style) == nil, "\(style)")
    }

    let (_, ok) = try shell("/bin/sh", command)
    #expect(!ok, "rm says it could not remove the directory holding the volume")
    #expect(exists(precious), "the volume is untouched")
    #expect(!exists(doomed.appending("a.bin")))
    #expect(!exists(doomed.appending("sub")))
    #expect(exists(doomed), "it still holds the mount point")
}

private let hdiutil = "/usr/bin/hdiutil"

/// What is mounted at `path`, such as `/dev/disk9`.
private func mountSource(_ path: FilePath) -> String? {
    var info = statfs()
    guard statfs(path.string, &info) == 0 else {
        return nil
    }
    return withUnsafeBytes(of: info.f_mntfromname) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
}
