// The walk, against real temporary trees: size accounting, hardlinks,
// symlinks, hidden entries, depth limits, reuse of a known subtree, and the
// volume rules.
//
// Beyond the Rust tests: the two ways a directory is listed
// (`getattrlistbulk` and `readdir`) are held to one answer, the volume
// rules are checked against a disk image really mounted inside the tree,
// and totals that sparse files push past 64 bits are held at the top
// rather than crashing the walk or anything that sums them later.

import Darwin
import Foundation
import System
import Testing

@testable import DisktreeCore

// MARK: - Fixtures

/// Apparent sizes, so the assertions are about the tree rather than about
/// how the filesystem rounds a small file up to a block.
private func options(
    followLinks: Bool = false,
    includeHidden: Bool = true,
    oneFilesystem: Bool = true,
    maxDepth: Int? = nil,
    dedupHardlinks: Bool = true,
    metric: Metric = .bytes
) -> ScanOptions {
    ScanOptions(
        apparentSize: true,
        followLinks: followLinks,
        includeHidden: includeHidden,
        oneFilesystem: oneFilesystem,
        maxDepth: maxDepth,
        dedupHardlinks: dedupHardlinks,
        metric: metric
    )
}

/// A fresh directory under the temporary directory; the caller discards it.
///
/// Spelled the way the temporary directory is (`/var/folders/…`), not
/// resolved (`/private/var/folders/…`), so every test also walks a root
/// that differs from what the mount table would call it.
private func scratch() throws -> FilePath {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "disktree-scan-\(UUID().uuidString)",
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

@discardableResult
private func write(
    _ root: FilePath,
    _ relative: String,
    _ count: Int
) throws -> FilePath {
    let path = root.appending(relative)
    try makeDirectory(path.removingLastComponent())
    try Data(repeating: UInt8(ascii: "x"), count: count)
        .write(to: URL(filePath: path.string))
    return path
}

private func symlink(_ link: FilePath, to destination: String) throws {
    try FileManager.default.createSymbolicLink(
        atPath: link.string,
        withDestinationPath: destination
    )
}

private func hardLink(_ link: FilePath, to original: FilePath) throws {
    try FileManager.default.linkItem(
        atPath: original.string,
        toPath: link.string
    )
}

/// `path` with every symlink resolved: `/private/var/…` for `/var/…`.
private func resolved(_ path: FilePath) throws -> FilePath {
    let real = try #require(path.withPlatformString { realpath($0, nil) })
    defer { free(real) }
    return FilePath(platformString: real)
}

private func child(_ node: Node, _ name: String) throws -> Node {
    try #require(
        node.childNamed(name),
        "no child named \(name) in \(node.name)"
    )
}

/// What `stat` says the file spends on disk: `st_blocks * 512`.
private func allocated(_ path: FilePath) throws -> UInt64 {
    var info = stat()
    let status = path.withPlatformString { lstat($0, &info) }
    try #require(status == 0, "lstat \(path)")
    return UInt64(info.st_blocks) * 512
}

/// Poll a spawned scan the way the interface does, until it lands.
private func outcome(
    of handle: ScanHandle,
    within limit: Duration = .seconds(60)
) async throws -> Result<Node, ScanError> {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if let result = handle.poll() {
            return result
        }
        try await Task.sleep(for: .milliseconds(2))
    }
    return try #require(handle.poll(), "the scan finished")
}

// MARK: - Ported from scan.rs

@Test func totalsAreSummedBottomUp() throws {
    let root = try scratch()
    defer { discard(root) }
    try write(root, "a/one.bin", 1000)
    try write(root, "a/nested/two.bin", 2000)
    try write(root, "b/three.bin", 500)

    let tree = try scan(root, options: options())
    #expect(tree.bytes == 3500)
    #expect(tree.files == 3)
    #expect(tree.dirs == 4, "root, a, a/nested, b")
    #expect(try child(tree, "a").bytes == 3000)
    #expect(try child(child(tree, "a"), "nested").bytes == 2000)
    #expect(try child(tree, "b").bytes == 500)
}

@Test func childrenAreRankedLargestFirst() throws {
    let root = try scratch()
    defer { discard(root) }
    try write(root, "small.bin", 10)
    try write(root, "large.bin", 1000)
    try write(root, "medium.bin", 100)

    let tree = try scan(root, options: options())
    let names = tree.children.map(\.name)
    #expect(names == ["large.bin", "medium.bin", "small.bin"])
}

@Test func aDirectoryReportsItsOwnBytesSeparately() throws {
    let root = try scratch()
    defer { discard(root) }
    try write(root, "direct.bin", 700)
    try write(root, "sub/deep.bin", 300)

    let tree = try scan(root, options: options())
    #expect(tree.ownBytes == 700)
    #expect(tree.ownFiles == 1)
    #expect(tree.bytes == 1000)
    #expect(tree.files == 2)
}

@Test func hardlinksAreChargedOnceByDefault() throws {
    let root = try scratch()
    defer { discard(root) }
    let original = try write(root, "original.bin", 4096)
    try hardLink(root.appending("link.bin"), to: original)

    let deduped = try scan(root, options: options())
    #expect(deduped.bytes == 4096)
    #expect(deduped.files == 2, "both names still exist")

    let counted = try scan(root, options: options(dedupHardlinks: false))
    #expect(counted.bytes == 8192)
}

@Test func hiddenEntriesAreIncludedByDefaultAndExcludedOnRequest() throws {
    let root = try scratch()
    defer { discard(root) }
    try write(root, ".cache/blob.bin", 900)
    try write(root, "visible.bin", 100)

    let all = try scan(root, options: options())
    #expect(all.bytes == 1000)
    #expect(try child(all, ".cache").bytes == 900)

    let without = try scan(root, options: options(includeHidden: false))
    #expect(without.bytes == 100)
}

@Test func symlinksAreNotFollowedByDefault() throws {
    let root = try scratch()
    let outside = try scratch()
    defer {
        discard(root)
        discard(outside)
    }
    try write(outside, "elsewhere.bin", 5000)
    try write(root, "real.bin", 100)
    try symlink(root.appending("link"), to: outside.string)

    let tree = try scan(root, options: options())
    // Only the real file's bytes; the link itself holds just its target
    // string, and its 5000-byte destination is outside this tree.
    #expect(tree.bytes < 200, "\(tree.bytes)")
    let link = try child(tree, "link")
    #expect(link.kind == .symlink)
    #expect(link.bytes < 100, "a link holds only its target string")
}

@Test func followedSymlinkLoopsDoNotHangTheScan() throws {
    let root = try scratch()
    defer { discard(root) }
    try write(root, "sub/leaf.bin", 42)
    try symlink(root.appending("sub/loop"), to: root.string)

    let tree = try scan(root, options: options(followLinks: true))
    #expect(tree.bytes == 42)
}

@Test func maxDepthStopsDescendingButKeepsDirectFiles() throws {
    let root = try scratch()
    defer { discard(root) }
    try write(root, "here.bin", 10)
    try write(root, "a/there.bin", 20)
    try write(root, "a/b/far.bin", 30)

    let tree = try scan(root, options: options(maxDepth: 1))
    #expect(tree.ownBytes == 10)
    let a = try child(tree, "a")
    #expect(a.bytes == 20, "direct files at the cut-off depth still count")
    #expect(
        a.children.allSatisfy { !$0.isDir },
        "descending stopped at depth 1"
    )
    #expect(a.files == 1)
}

@Test func fileCountMetricRanksByEntries() throws {
    let root = try scratch()
    defer { discard(root) }
    for index in 0..<5 {
        try write(root, "many/f\(index).bin", 1)
    }
    try write(root, "one/huge.bin", 100_000)

    let tree = try scan(root, options: options())
    #expect(try child(tree, "one").bytes == 100_000)
    #expect(tree.children.first?.name == "one")

    let byFiles = try scan(root, options: options(metric: .files))
    #expect(byFiles.children.first?.name == "many")
    #expect(byFiles.children.first?.files == 5)
}

@Test func anUnreadableDirectoryIsRecordedNotFatal() throws {
    let root = try scratch()
    let locked = root.appending("locked")
    defer {
        chmod(locked.string, 0o700)
        discard(root)
    }
    try write(root, "readable.bin", 11)
    try write(locked, "hidden.bin", 22)
    try #require(chmod(locked.string, 0) == 0)

    // Running as root would bypass the permission bits entirely.
    let readable = opendir(locked.string).map { closedir($0) } != nil
    let progress = ScanProgress()
    let tree = try scanTree(root, options: options(), progress: progress)

    #expect(tree.bytes == 11)
    let node = try child(tree, "locked")
    if !readable {
        #expect(node.readError)
        #expect(progress.snapshot().errors >= 1)
        #expect(!progress.snapshot().messages.isEmpty)
    }
}

@Test func aFileRootIsRejected() throws {
    let root = try scratch()
    defer { discard(root) }
    let path = try write(root, "file.bin", 1)

    let error = #expect(throws: ScanError.self) {
        try scan(path, options: options())
    }
    #expect(error?.code == ENOTDIR)
    #expect(error?.path == path)
}

@Test func aSpawnedScanReportsProgressAndAResult() async throws {
    let root = try scratch()
    defer { discard(root) }
    try write(root, "a/one.bin", 1024)
    try write(root, "b/two.bin", 2048)

    let handle = ScanHandle(root: root, options: options())
    let tree = try await outcome(of: handle).get()
    #expect(tree.bytes == 3072)

    let snapshot = handle.progress.snapshot()
    #expect(snapshot.finished)
    #expect(snapshot.files == 2)
    #expect(snapshot.errors == 0)
}

@Test func aWiderScanReusesTheSubtreeItAlreadyKnows() async throws {
    let scratchRoot = try scratch()
    defer { discard(scratchRoot) }
    let root = try resolved(scratchRoot)
    let inner = root.appending("inner")
    try write(inner, "deep/a.bin", 4096)
    try write(root, "outside.bin", 8192)
    let known = try scan(inner, options: options())

    // Changed on disk after the inner scan: a memoized subtree must not see
    // it, which is how this test knows the walk skipped it.
    try write(inner, "deep/b.bin", 4096)

    let handle = ScanHandle(
        root: root,
        options: options(),
        known: Known(path: inner, tree: known)
    )
    let tree = try await outcome(of: handle).get()
    let reused = try child(tree, "inner")
    #expect(reused.files == known.files, "b.bin was never read")
    #expect(reused.bytes == known.bytes)
    #expect(tree.childNamed("outside.bin") != nil, "the rest was walked")
    #expect(tree.files == known.files + 1)
    // The reused subtree is counted as if it had been walked.
    #expect(handle.progress.snapshot().files == tree.files)
}

/// A directory that can be listed but not searched is unreadable to both
/// listings alike: the bulk call needs both, and `readdir` names entries it
/// then cannot look at.
@Test(arguments: [ScanReader.bulk, .readdir])
func aListableButUnsearchableDirectoryIsUnreadable(reader: ScanReader) throws {
    let root = try scratch()
    let closed = root.appending("noexec")
    defer {
        chmod(closed.string, 0o700)
        discard(root)
    }
    try write(closed, "a", 10)
    try write(closed, "sub/b", 10)
    try #require(chmod(closed.string, 0o444) == 0)
    var info = stat()
    let searchable = stat(closed.appending("a").string, &info) == 0
    try #require(!searchable, "the permission bits are bypassed here")

    let progress = ScanProgress()
    let tree = try scanTree(
        root,
        options: options(),
        progress: progress,
        reader: reader
    )
    let node = try child(tree, "noexec")
    #expect(node.readError)
    #expect(node.children.isEmpty)
    #expect(node.dirs == 1)
    #expect(progress.snapshot().errors == 1)
    #expect(
        progress.snapshot().messages.first?.hasPrefix(closed.string) == true
    )
}

/// The live counters end where the tree that lands does: a link or a
/// socket is no file, and a hardlinked file weighs once.
@Test func theCountersEndWhereTheTreeDoes() async throws {
    let root = try scratch()
    defer { discard(root) }
    let original = try write(root, "a/original.bin", 102_400)
    try makeDirectory(root.appending("b"))
    let second = root.appending("b/link.bin")
    try #require(link(original.string, second.string) == 0)
    try symlink(root.appending("to-a"), to: "a")

    let handle = ScanHandle(root: root, options: options())
    let tree = try await outcome(of: handle).get()
    let snapshot = handle.progress.snapshot()
    #expect(tree.files == 2)
    #expect(snapshot.files == tree.files)
    #expect(snapshot.bytes == tree.bytes)
}

/// A widening reuses what the narrower scan measured, and with it what that
/// scan could not read: the note under the mosaic counts both, as a fresh
/// scan of the wider root would.
@Test func aWideningStillCountsWhatItCouldNotRead() async throws {
    let scratchRoot = try scratch()
    let root = try resolved(scratchRoot)
    let inner = root.appending("inner")
    let locked = inner.appending("locked")
    defer {
        chmod(locked.string, 0o700)
        discard(scratchRoot)
    }
    try write(inner, "a.bin", 10)
    try write(locked, "b.bin", 10)
    try write(root, "outside.bin", 10)
    try #require(chmod(locked.string, 0) == 0)
    // Running as root would bypass the permission bits entirely.
    let readable = opendir(locked.string).map { closedir($0) } != nil
    try #require(!readable, "the permission bits are bypassed here")

    let narrow = ScanProgress()
    let known = try scanTree(inner, options: options(), progress: narrow)
    let seen = narrow.snapshot()
    #expect(seen.errors == 1)

    let told = ScanHandle(
        root: root,
        options: options(),
        known: Known(
            path: inner,
            tree: known,
            unreadable: (seen.errors, seen.messages)
        )
    )
    _ = try await outcome(of: told).get()
    #expect(told.progress.snapshot().errors == 1)
    #expect(told.progress.snapshot().messages == seen.messages)

    // Not told: found again in the tree, by path.
    let untold = ScanHandle(
        root: root,
        options: options(),
        known: Known(path: inner, tree: known)
    )
    _ = try await outcome(of: untold).get()
    #expect(untold.progress.snapshot().errors == 1)
    #expect(
        untold.progress.snapshot().messages
            == ["\(locked.string): could not be read"]
    )
}

/// The root of `wholeDiskSmoke`: `DISKTREE_BENCH_PATH`, or with
/// `DISKTREE_WHOLE_DISK` set, the top of the disk the home directory is on.
private func smokeRoot() -> FilePath? {
    let environment = ProcessInfo.processInfo.environment
    if let path = environment["DISKTREE_BENCH_PATH"], !path.isEmpty {
        return FilePath(path)
    }
    guard environment["DISKTREE_WHOLE_DISK"] != nil else {
        return nil
    }
    return volumeRootFor(FilePath(NSHomeDirectory()))
}

/// A real scan, run by hand:
///
///     DISKTREE_WHOLE_DISK=1 swift test --filter wholeDiskSmoke
///     DISKTREE_BENCH_PATH=~/Library swift test --filter wholeDiskSmoke
///
/// Prints what it found, so the volume rules can be checked against this
/// machine's mounts. Given a path, it also times `du -sk` over the same
/// tree and holds the two totals within a percent of each other: the tree
/// is live and changes between the two walks. A debug build walks several
/// times slower than a release one, so compare timings with `-c release`.
@Test(.enabled(if: smokeRoot() != nil))
func wholeDiskSmoke() async throws {
    let root = try #require(smokeRoot())
    let clock = ContinuousClock()
    let started = clock.now
    let handle = ScanHandle(root: root, options: ScanOptions())
    let tree = try await outcome(of: handle, within: .seconds(3600)).get()
    let elapsed = clock.now - started
    let snapshot = handle.progress.snapshot()
    print("root \(root) in \(elapsed)")
    print(
        "total \(humanBytes(tree.bytes)) files \(tree.files)"
            + " dirs \(tree.dirs) errors \(snapshot.errors)"
    )
    for child in tree.children.prefix(14) {
        print("  \(humanBytes(child.bytes))  \(child.name)")
    }
    print("left out: \(foreignMountsFor(root) ?? [])")
    for needle in ["c", "cache", "node_modules", "zzzz"] {
        let started = clock.now
        let found = try #require(filter(tree, base: [], needle: needle))
        print(
            "filter \"\(needle)\": \(found.count) matches,"
                + " \(humanBytes(found.bytes)) in \(clock.now - started)"
        )
    }

    guard ProcessInfo.processInfo.environment["DISKTREE_BENCH_PATH"] != nil
    else {
        return
    }
    let duStarted = clock.now
    let du = Process()
    du.executableURL = URL(filePath: "/usr/bin/du")
    du.arguments = ["-sk", root.string]
    let output = Pipe()
    du.standardOutput = output
    du.standardError = FileHandle.nullDevice
    try du.run()
    let text = String(
        decoding: output.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    )
    du.waitUntilExit()
    let duElapsed = clock.now - duStarted
    let kibibytes = try #require(
        text.split(separator: "\t").first.flatMap { UInt64($0) }
    )
    print("du -sk: \(humanBytes(kibibytes * 1024)) in \(duElapsed)")
    let ours = Double(tree.bytes) / 1024
    #expect(abs(ours - Double(kibibytes)) <= Double(kibibytes) / 100)
}

// MARK: - The two listings

/// Every figure a listing decides, compared node by node, so a mismatch
/// names the path where the two disagree.
private func expectSame(_ bulk: Node, _ portable: Node, at parent: String) {
    let path = "\(parent)/\(bulk.name)"
    #expect(bulk.name == portable.name, "\(path)")
    #expect(bulk.kind == portable.kind, "\(path)")
    #expect(bulk.bytes == portable.bytes, "\(path)")
    #expect(bulk.ownBytes == portable.ownBytes, "\(path)")
    #expect(bulk.files == portable.files, "\(path)")
    #expect(bulk.ownFiles == portable.ownFiles, "\(path)")
    #expect(bulk.dirs == portable.dirs, "\(path)")
    #expect(bulk.inode == portable.inode, "\(path)")
    #expect(bulk.readError == portable.readError, "\(path)")
    #expect(bulk.modified == portable.modified, "\(path)")
    #expect(bulk.children.count == portable.children.count, "\(path)")
    for (left, right) in zip(bulk.children, portable.children) {
        expectSame(left, right, at: path)
    }
}

/// A tree with one of everything the walk treats differently.
private func mixedTree(_ root: FilePath) throws {
    try write(root, "a/one.bin", 1000)
    try write(root, "a/nested/two.bin", 2000)
    try write(root, "a/café ☕ with spaces.txt", 333)
    try write(root, ".hidden/blob.bin", 900)
    try makeDirectory(root.appending("empty"))
    try makeDirectory(root.appending("a/empty too"))
    let original = try write(root, "hard/original.bin", 4096)
    try hardLink(root.appending("hard/link.bin"), to: original)
    try hardLink(root.appending("a/far link.bin"), to: original)
    try symlink(root.appending("to-a"), to: "a")
    try symlink(root.appending("to-file"), to: "a/one.bin")
    try symlink(root.appending("dangling"), to: "nothing/here")
    try #require(mkfifo(root.appending("pipe").string, 0o600) == 0)

    // Sparse: a megabyte long, a block or so on disk.
    let sparse = try write(root, "sparse.bin", 1)
    try #require(truncate(sparse.string, 1 << 20) == 0)

    // More entries than one bulk call returns: its buffer holds about a
    // thousand of these, so the listing takes several calls.
    let wide = root.appending("wide")
    try makeDirectory(wide)
    let stem = String(repeating: "n", count: 40)
    for index in 0..<3000 {
        let path = wide.appending("\(stem)-\(index)")
        let fd = open(path.string, O_CREAT | O_WRONLY | O_CLOEXEC, 0o600)
        try #require(fd >= 0, "create \(path)")
        close(fd)
    }
}

@Test(arguments: [
    ScanOptions(),
    ScanOptions(apparentSize: true),
    ScanOptions(followLinks: true),
    ScanOptions(includeHidden: false, maxDepth: 1),
    ScanOptions(oneFilesystem: false),
])
func theBulkListingAgreesWithReaddir(_ options: ScanOptions) throws {
    let root = try scratch()
    defer { discard(root) }
    try mixedTree(root)

    let bulk = try scanTree(
        root,
        options: options,
        progress: ScanProgress(),
        reader: .bulk
    )
    let portable = try scanTree(
        root,
        options: options,
        progress: ScanProgress(),
        reader: .readdir
    )
    expectSame(bulk, portable, at: "")
    if options.maxDepth == nil {
        #expect(try child(bulk, "wide").files == 3000)
    }
}

@Test func anEmptyDirectoryIsANodeOfItsOwn() throws {
    let root = try scratch()
    defer { discard(root) }
    try makeDirectory(root.appending("empty"))
    try write(root, "full/one.bin", 10)

    for reader in [ScanReader.bulk, .readdir] {
        let tree = try scanTree(
            root,
            options: options(),
            progress: ScanProgress(),
            reader: reader
        )
        let empty = try child(tree, "empty")
        #expect(empty.isDir)
        #expect(empty.children.isEmpty)
        #expect(empty.dirs == 1)
        #expect(!empty.readError)
        #expect(tree.dirs == 3, "root, empty, full")
    }
}

// MARK: - Measuring

@Test func sizesAreAllocatedBlocksUnlessApparentSizeIsAsked() throws {
    let root = try scratch()
    defer { discard(root) }
    let small = try write(root, "small.bin", 1)
    let sparse = try write(root, "sparse.bin", 1)
    try #require(truncate(sparse.string, 8 << 20) == 0)

    // Invariant 1: what comes back when the file is deleted.
    let blocks = try scan(root, options: ScanOptions())
    #expect(try child(blocks, "small.bin").bytes == allocated(small))
    #expect(try child(blocks, "sparse.bin").bytes == allocated(sparse))
    #expect(try child(blocks, "sparse.bin").bytes < 8 << 20)

    let apparent = try scan(root, options: ScanOptions(apparentSize: true))
    #expect(try child(apparent, "small.bin").bytes == 1)
    #expect(try child(apparent, "sparse.bin").bytes == 8 << 20)
}

/// What `lstat` says a path is: `(st_dev, st_ino)`.
private func identity(_ path: FilePath) throws -> FileID {
    var info = stat()
    let status = path.withPlatformString { lstat($0, &info) }
    try #require(status == 0, "lstat \(path)")
    return FileID(
        device: UInt64(UInt32(bitPattern: info.st_dev)),
        inode: info.st_ino
    )
}

@Test func aWalkThatMayCrossMountsKnowsEveryFileByItsIdentity() throws {
    // With the volume rule off, a scan of `/` walks `/Users` and
    // `/System/Volumes/Data/Users` both: every file twice, one link each.
    // Only its identity lets the second name be charged nothing.
    let root = try scratch()
    defer { discard(root) }
    let plain = try write(root, "plain.bin", 10)
    let nested = try write(root, "sub/nested.bin", 20)

    for reader in [ScanReader.bulk, .readdir] {
        let crossing = try scanTree(
            root,
            options: options(oneFilesystem: false),
            progress: ScanProgress(),
            reader: reader
        )
        #expect(try child(crossing, "plain.bin").inode == identity(plain))
        let sub = try child(crossing, "sub")
        #expect(try child(sub, "nested.bin").inode == identity(nested))

        // On one volume, a file with one link cannot be met twice, and
        // de-duplication is spared hashing it.
        let staying = try scanTree(
            root,
            options: options(),
            progress: ScanProgress(),
            reader: reader
        )
        #expect(try child(staying, "plain.bin").inode == nil)
    }
}

/// The most APFS lets a file claim, spending no blocks at all: 2^55 - 1
/// bytes. 513 of them are more than 64 bits can count.
private func claimHuge(_ path: FilePath) throws {
    let fd = open(path.string, O_CREAT | O_WRONLY | O_CLOEXEC, 0o600)
    try #require(fd >= 0, "create \(path)")
    defer { close(fd) }
    try #require(ftruncate(fd, (1 << 55) - 1) == 0, "truncate \(path)")
}

@Test func sizesPastWhatSixtyFourBitsHoldSaturateInsteadOfCrashing() throws {
    let root = try scratch()
    defer { discard(root) }
    // Over the top within one directory, and again where two meet.
    for (directory, count) in [("many", 520), ("few", 2)] {
        try makeDirectory(root.appending(directory))
        for index in 0..<count {
            try claimHuge(root.appending("\(directory)/huge-\(index)"))
        }
    }

    let tree = try scan(root, options: ScanOptions(apparentSize: true))
    let huge = UInt64((1 << 55) - 1)
    #expect(try child(tree, "many").bytes == .max)
    #expect(try child(tree, "few").bytes == 2 * huge)
    #expect(tree.bytes == .max)
    #expect(tree.files == 522)

    // And downstream, where the totals are summed again.
    let found = try #require(filter(tree, base: [], needle: "huge"))
    #expect(found.bytes == .max)
    #expect(found.files == 522)
    let marks = ["many", "few"].map { name in
        Target(
            path: root.appending(name),
            bytes: tree.childNamed(name)?.bytes ?? 0,
            isDir: true,
            hidden: false
        )
    }
    #expect(plan(marks, root: root, home: nil).bytes == .max)

    // Stale experiments in an agent's scratch space are summed too.
    var stale = Node.directory("old")
    stale.bytes = .max
    stale.modified = 1
    var tries = Node.directory("tries", children: [stale, stale])
    tries.category = .agentScratch
    let candidates = worthALook(
        Node.directory("root", children: [tries]),
        now: 1_000_000_000,
        limit: 5
    )
    #expect(candidates.first?.bytes == .max)
}

@Test func aBlockCountNoDiskHasSaturates() {
    #expect(blockBytes(blocks: 3) == 1536)
    #expect(blockBytes(blocks: -1) == 0)
    #expect(blockBytes(blocks: .max) == .max)
    #expect(blockBytes(1) == 512, "an allocation rounds up to a block")
    #expect(blockBytes(.max) == UInt64(Int64.max) + 1)
}

@Test func aLeafCarriesItsModificationTime() throws {
    let root = try scratch()
    defer { discard(root) }
    let old = try write(root, "old.bin", 1)
    let new = try write(root, "sub/new.bin", 1)
    for (path, seconds) in [(old, 1_000_000_000), (new, 1_500_000_000)] {
        var times = [
            timeval(tv_sec: seconds, tv_usec: 0),
            timeval(tv_sec: seconds, tv_usec: 0),
        ]
        try #require(utimes(path.string, &times) == 0)
    }

    let tree = try scan(root, options: options())
    #expect(try child(tree, "old.bin").modified == 1_000_000_000)
    #expect(try child(tree, "sub").modified == 1_500_000_000)
    #expect(tree.modified == 1_500_000_000, "the newest write beneath")
}

@Test func aFollowedLinkToAFileWeighsWhatItPointsAt() throws {
    let root = try scratch()
    let outside = try scratch()
    defer {
        discard(root)
        discard(outside)
    }
    let target = try write(outside, "target.bin", 5000)
    try symlink(root.appending("link"), to: target.string)

    let tree = try scan(root, options: options(followLinks: true))
    let link = try child(tree, "link")
    #expect(link.kind == .file)
    #expect(link.bytes == 5000)
}

/// On a Mac `/` is the sealed system volume, mounted as a snapshot; a
/// followed link that stays on it — `/usr/lib` holds several, into
/// `/System` — is followed, and one that leaves it is still listed.
@Test func aLinkThatStaysOnTheSealedSystemVolumeIsFollowed() throws {
    let lib = FilePath("/usr/lib")
    let own = try #require(lib.withPlatformString(mountHolding))
    let names = try FileManager.default.contentsOfDirectory(atPath: lib.string)
    // By `statfs`, not the device number: the Data volume shares the
    // system volume's, and `/usr/lib/cron` leads into it.
    let staying = names.sorted().first { name in
        let path = lib.appending(name).string
        var link = stat()
        var target = stat()
        return lstat(path, &link) == 0 && link.st_mode & S_IFMT == S_IFLNK
            && stat(path, &target) == 0 && target.st_mode & S_IFMT == S_IFDIR
            && path.withCString(mountHolding)?.point == own.point
    }
    guard let staying else {
        try Test.cancel("no link to a directory on /usr/lib's volume here")
    }
    let tree = try scan(lib, options: options(followLinks: true, maxDepth: 1))
    #expect(tree.childNamed(staying)?.kind == .directory, "\(staying)")
}

/// A link into the scanned tree leads where the walk goes anyway, by the
/// real path: it is not followed, so which of several links, or the real
/// path, holds the files never depends on which walker got there first.
@Test func aLinkIntoTheTreeIsNeverFollowed() throws {
    let root = try scratch()
    defer { discard(root) }
    for index in 0..<40 {
        try write(root, "real/pad-\(index).bin", 10)
    }
    for name in ["a", "b", "c", "d"] {
        try makeDirectory(root.appending(name))
        try symlink(root.appending("\(name)/link"), to: "../real")
    }
    for _ in 0..<10 {
        let tree = try scan(root, options: options(followLinks: true))
        #expect(try child(tree, "real").bytes == 400)
        for name in ["a", "b", "c", "d"] {
            #expect(try child(tree, name).childNamed("link") == nil)
        }
        #expect(tree.bytes == 400)
    }
}

@Test func aDanglingLinkIsSkippedSilentlyWhenFollowing() throws {
    let root = try scratch()
    defer { discard(root) }
    try write(root, "real.bin", 10)
    try symlink(root.appending("dangling"), to: "nothing/here")

    let progress = ScanProgress()
    let tree = try scanTree(
        root,
        options: options(followLinks: true),
        progress: progress
    )
    #expect(tree.childNamed("dangling") == nil)
    #expect(tree.bytes == 10)
    #expect(progress.snapshot().errors == 0, "a dangling link is normal")
}

@Test func aRootReachedThroughALinkIsWalked() throws {
    let root = try scratch()
    defer { discard(root) }
    try write(root, "real/one.bin", 100)
    let link = root.appending("link")
    try symlink(link, to: "real")

    let tree = try scan(link, options: options())
    #expect(tree.name == "link")
    #expect(tree.bytes == 100)
}

@Test func aMissingRootReportsTheErrno() throws {
    let root = try scratch()
    defer { discard(root) }
    let missing = root.appending("not/here")

    let error = #expect(throws: ScanError.self) {
        try scan(missing, options: options())
    }
    #expect(error?.code == ENOENT)
    let expected = "\(missing.string): No such file or directory"
    #expect(error?.description == expected)
}

@Test func aDeepTreeIsWalkedToTheBottom() throws {
    let root = try scratch()
    defer { discard(root) }
    let levels = 150
    let relative = Array(repeating: "d", count: levels).joined(separator: "/")
    try write(root, relative + "/bottom.bin", 77)

    let tree = try scan(root, options: options())
    #expect(tree.bytes == 77)
    #expect(tree.depth == levels + 1, "every level and the file")
    #expect(tree.dirs == UInt64(levels) + 1)
}

@Test func aFinishedScanCountsWhatItFound() throws {
    let root = try scratch()
    defer { discard(root) }
    try write(root, "a/one.bin", 1000)
    try write(root, "a/b/two.bin", 2000)
    try makeDirectory(root.appending("empty"))

    let progress = ScanProgress()
    let tree = try scanTree(root, options: options(), progress: progress)
    let snapshot = progress.snapshot()
    #expect(snapshot.files == tree.files)
    #expect(snapshot.bytes == tree.bytes)
    #expect(snapshot.dirs == tree.dirs - 1, "the root is given, not found")
    #expect(snapshot.errors == 0)
    #expect(snapshot.messages.isEmpty)
}

@Test func aDepthLimitedScanCountsOnlyWhatItKeeps() throws {
    let root = try scratch()
    defer { discard(root) }
    try write(root, "a/b/c/far.bin", 30)
    try write(root, "a/near.bin", 20)

    let progress = ScanProgress()
    let tree = try scanTree(
        root,
        options: options(maxDepth: 1),
        progress: progress
    )
    // `a` is kept; `b`, past the limit, is not in the tree, and so not
    // counted as found either.
    #expect(tree.dirs == 2, "root and a")
    #expect(progress.snapshot().dirs == tree.dirs - 1)
    #expect(progress.snapshot().files == tree.files)
}

@Test func errorMessagesAreKeptForTheFirstFifty() throws {
    let root = try scratch()
    let names = (0..<60).map { String(format: "locked-%02d", $0) }
    defer {
        for name in names {
            chmod(root.appending(name).string, 0o700)
        }
        discard(root)
    }
    for name in names {
        let locked = root.appending(name)
        // Not empty: an empty directory needs no reading at all.
        try write(locked, "inside.bin", 1)
        try #require(chmod(locked.string, 0) == 0)
    }
    let first = root.appending(names[0])
    // Running as root would bypass the permission bits entirely.
    guard opendir(first.string).map({ closedir($0) }) == nil else {
        return
    }

    let progress = ScanProgress()
    _ = try scanTree(root, options: options(), progress: progress)
    let snapshot = progress.snapshot()
    #expect(snapshot.errors == 60, "the count keeps rising")
    #expect(snapshot.messages.count == 50)
    let expected = Set(names.map { "\(root.appending($0)): Permission denied" })
    for message in snapshot.messages {
        #expect(expected.contains(message), "\(message)")
    }
}

@Test func markingHardlinksZeroesOwnBytesNotTotals() {
    let identity = FileID(device: 1, inode: 42)
    var first = Node.entry("first", kind: .file, bytes: 4096)
    first.inode = identity
    var second = Node.entry("second", kind: .file, bytes: 4096)
    second.inode = identity
    var root = Node.directory("root", children: [first, second])
    root.bytes = 12_345

    var seen = Set<FileID>()
    markDuplicateHardlinks(&root, seen: &seen)
    #expect(root.children[0].ownBytes == 4096)
    #expect(root.children[1].ownBytes == 0)
    #expect(root.bytes == 12_345, "totals are aggregate's to derive")

    // Invariant 2: the derived totals follow the zeroed leaf.
    let finished = finishTree(root, options: ScanOptions())
    #expect(finished.bytes == 4096)
    #expect(finished.files == 2)
}

@Test func aLinkAlreadyZeroedNeverClaimsTheFile() {
    // A reused subtree arrives de-duplicated on its own terms: here its
    // zeroed link is met before the link that still carries the bytes.
    let identity = FileID(device: 1, inode: 42)
    var zeroed = Node.entry("zeroed", kind: .file, bytes: 0)
    zeroed.inode = identity
    var carrying = Node.entry("carrying", kind: .file, bytes: 4096)
    carrying.inode = identity
    var root = Node.directory(
        "root",
        children: [
            .directory("known", children: [zeroed]),
            .directory("fresh", children: [carrying]),
        ]
    )

    var seen = Set<FileID>()
    markDuplicateHardlinks(&root, seen: &seen)
    aggregate(&root, metric: .bytes)
    #expect(root.bytes == 4096, "the file is still charged once")
}

@Test func whichNameKeepsASharedFileIsDecidedByTheTree() throws {
    // The same tree, handed over in two orders, as two walks may finish.
    let identity = FileID(device: 1, inode: 7)
    func link(_ name: String) -> Node {
        var node = Node.entry(name, kind: .file, bytes: 4096)
        node.inode = identity
        return node
    }
    let small = Node.directory(
        "small",
        children: [link("one"), .entry("extra", kind: .file, bytes: 10)]
    )
    let large = Node.directory(
        "large",
        children: [link("two"), .entry("extra", kind: .file, bytes: 5000)]
    )
    let orders = [[small, large], [large, small]]
    let finished = orders.map { children in
        finishTree(
            Node.directory("root", children: children),
            options: ScanOptions()
        )
    }

    for tree in finished {
        #expect(tree.bytes == 4096 + 10 + 5000)
        #expect(tree.children.map(\.name) == ["large", "small"])
        // The first name in the order the treemap shows keeps the bytes.
        #expect(try child(tree, "large").bytes == 4096 + 5000)
        #expect(try child(tree, "small").bytes == 10)
    }
}

// MARK: - Cancelling

@Test func aCancelledScanStillLandsWithWhatItHad() throws {
    let root = try scratch()
    defer { discard(root) }
    try write(root, "a/one.bin", 1000)
    try write(root, "b/two.bin", 2000)

    let progress = ScanProgress()
    progress.cancel()
    let tree = try scanTree(root, options: options(), progress: progress)
    #expect(tree.isDir)
    #expect(tree.children.isEmpty, "cancelled before the root was read")
    #expect(progress.snapshot().cancelled)
}

@Test func aCancelledHandleStillReportsAnOutcome() async throws {
    let root = try scratch()
    defer { discard(root) }
    for index in 0..<50 {
        try write(root, "d\(index)/e/f.bin", 10)
    }

    let handle = ScanHandle(root: root, options: options())
    handle.cancel()
    let tree = try await outcome(of: handle).get()
    #expect(tree.isDir, "a partial tree, not an error")
    let snapshot = handle.progress.snapshot()
    #expect(snapshot.cancelled)
    #expect(snapshot.finished)
}

@Test func pollKeepsReturningTheOutcome() async throws {
    let root = try scratch()
    defer { discard(root) }
    try write(root, "one.bin", 64)

    let handle = ScanHandle(root: root, options: options())
    let first = try await outcome(of: handle).get()
    let again = try #require(handle.poll()).get()
    #expect(first.bytes == 64)
    #expect(again.bytes == first.bytes)
    #expect(again.children.map(\.name) == first.children.map(\.name))
}

@Test func droppingARunningHandleCancelsItsWalk() throws {
    let root = try scratch()
    defer { discard(root) }
    for index in 0..<200 {
        try write(root, "d\(index)/e/f.bin", 10)
    }

    var handle: ScanHandle? = ScanHandle(root: root, options: options())
    let progress = try #require(handle?.progress)
    handle = nil
    // Either the walk was over before the handle went, or it was told to
    // stop: nobody is left to read what it would find.
    let snapshot = progress.snapshot()
    #expect(snapshot.cancelled || snapshot.finished)
}

// MARK: - Volumes

@Test func aForeignMountIsLeftOutByItsPath() throws {
    let root = try scratch()
    defer { discard(root) }
    try write(root, "kept/one.bin", 100)
    try write(root, "mount/two.bin", 200)
    let foreign: (FilePath) -> [FilePath]? = { walked in
        [walked.appending("mount")]
    }

    let tree = try scanTree(
        root,
        options: options(),
        progress: ScanProgress(),
        foreignMounts: foreign
    )
    #expect(tree.childNamed("mount") == nil, "never entered")
    #expect(tree.bytes == 100)

    let anywhere = try scanTree(
        root,
        options: options(oneFilesystem: false),
        progress: ScanProgress(),
        foreignMounts: foreign
    )
    #expect(anywhere.bytes == 300, "oneFilesystem off enters everything")
}

@Test func withoutAMountTableDevicesAreCompared() throws {
    let root = try scratch()
    defer { discard(root) }
    try write(root, "a/one.bin", 100)
    try write(root, "a/b/two.bin", 200)

    let tree = try scanTree(
        root,
        options: options(),
        progress: ScanProgress(),
        foreignMounts: { _ in nil }
    )
    #expect(tree.bytes == 300, "one device throughout")
}

private func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(filePath: tool)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

/// A real volume, attached from a disk image inside the tree. HFS+ keeps an
/// entry count per directory that the walk trusts; FAT is a filesystem it
/// does not trust with one, and whose bulk listing leaves the allocation
/// out. On either, the volume is left out by its path, by what the listing
/// says when the table was read before it was mounted, and by where a
/// followed link leads; when it is entered, both listings agree on what is
/// there, measured either way.
@Test(
    .enabled(
        if: FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil")
    ),
    arguments: ["HFS+", "MS-DOS"]
)
func aDiskMountedInsideTheRootIsLeftOut(filesystem: String) throws {
    let root = try scratch()
    let images = try scratch()
    let point = root.appending("mounted")
    defer {
        _ = try? run("/usr/bin/hdiutil", ["detach", point.string, "-force"])
        discard(root)
        discard(images)
    }
    try write(root, "kept.bin", 100)
    try makeDirectory(point)
    let image = images.appending("disk.dmg")
    try #require(
        run(
            "/usr/bin/hdiutil",
            [
                "create", "-size", "4m", "-fs", filesystem, "-layout",
                "MBRSPUD", "-volname", "DISKTREE", image.string,
            ]
        ) == 0
    )
    try #require(
        run(
            "/usr/bin/hdiutil",
            [
                "attach", "-nobrowse", "-noverify", "-noautoopen",
                "-mountpoint", point.string, image.string,
            ]
        ) == 0
    )
    try write(point, "on-the-image.bin", 50_000)
    try write(point, "nested/deeper/file.bin", 700)
    try makeDirectory(point.appending("nested/empty"))

    // The table names the mount point `/private/var/…`; the walk, rooted at
    // `/var/…`, must still recognise it.
    #expect(foreignMountsForWalk(root) == [point])

    let tree = try scan(root, options: options())
    #expect(tree.childNamed("mounted") == nil, "another volume")
    #expect(tree.bytes == 100)

    let byDevice = try scanTree(
        root,
        options: options(),
        progress: ScanProgress(),
        foreignMounts: { _ in nil }
    )
    #expect(byDevice.childNamed("mounted") == nil, "another device")

    let anywhere = options(oneFilesystem: false)
    let bulk = try scanTree(
        root,
        options: anywhere,
        progress: ScanProgress(),
        reader: .bulk
    )
    let portable = try scanTree(
        root,
        options: anywhere,
        progress: ScanProgress(),
        reader: .readdir
    )
    expectSame(bulk, portable, at: "")
    let mounted = try child(bulk, "mounted")
    #expect(mounted.bytes >= 50_700)
    #expect(try child(child(mounted, "nested"), "empty").children.isEmpty)

    // Invariant 1 on a foreign filesystem too: FAT's bulk listing leaves the
    // allocation out, and a file must not weigh nothing for it.
    let blocks = ScanOptions(oneFilesystem: false)
    let bulkBlocks = try scanTree(
        root,
        options: blocks,
        progress: ScanProgress(),
        reader: .bulk
    )
    let portableBlocks = try scanTree(
        root,
        options: blocks,
        progress: ScanProgress(),
        reader: .readdir
    )
    expectSame(bulkBlocks, portableBlocks, at: "")
    let onImage = try child(child(bulkBlocks, "mounted"), "on-the-image.bin")
    #expect(try onImage.bytes == allocated(point.appending("on-the-image.bin")))

    // A table read before the image was attached: the bulk listing still
    // says a filesystem is mounted there, and `statfs` names another one.
    let mountedSince = try scanTree(
        root,
        options: options(),
        progress: ScanProgress(),
        reader: .bulk,
        foreignMounts: { _ in [] }
    )
    #expect(mountedSince.childNamed("mounted") == nil, "mounted mid-walk")
    #expect(mountedSince.bytes == 100)

    // A followed link onto the image leaves the root's volume just as a
    // walk into it would, whichever rule decides.
    let links = images.appending("links")
    try makeDirectory(links)
    try symlink(links.appending("to-image"), to: point.string)
    let following = options(followLinks: true)
    let byTable = try scan(links, options: following)
    #expect(byTable.childNamed("to-image")?.kind == .symlink, "not followed")
    let linkByDevice = try scanTree(
        links,
        options: following,
        progress: ScanProgress(),
        foreignMounts: { _ in nil }
    )
    #expect(
        linkByDevice.childNamed("to-image")?.kind == .symlink,
        "another device"
    )
    let crossing = try scan(
        links, options: options(followLinks: true, oneFilesystem: false))
    #expect(try child(crossing, "to-image").bytes >= 50_700)

    // Widened from the mount point, as `g` from a scan of another disk
    // does: the disk measured from inside stays out of the wider tree, as
    // a fresh scan of it leaves it out.
    let narrow = try scan(point, options: options())
    #expect(narrow.bytes >= 50_700)
    let widened = try scanTree(
        root,
        options: options(),
        known: Known(path: point, tree: narrow),
        progress: ScanProgress()
    )
    #expect(widened.childNamed("mounted") == nil, "another volume")
    #expect(widened.bytes == 100)
}
