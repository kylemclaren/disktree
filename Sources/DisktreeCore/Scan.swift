// Parallel filesystem scanning.
//
// The shape follows dust, because that shape is the reason dust is fast:
//
// * one walk per root over a fixed pool of worker threads fed from one stack
//   of directories, so recursion depth is O(1) however deep the tree is,
// * every directory is a `PendingDir` with an atomic completion counter and a
//   `+1` sentinel, so a directory is only built once its own scan *and* all of
//   its subdirectory tasks have finished,
// * children are handed to the parent as finished `Node`s and sizes are
//   aggregated bottom-up in one serial pass, which is also where hardlinks are
//   de-duplicated.
//
// What is added on top of dust's approach: live progress counters the UI can
// poll without locking, and cooperative cancellation so a re-scan can abandon
// a walk of a large home directory instead of queueing behind it.
//
// On macOS a directory is read with `getattrlistbulk(2)`: one call returns
// the names *and* the types, sizes and identities of a whole batch of
// entries. `readdir` plus an `fstatat` per entry makes the kernel look up
// and build a vnode for every file, and a home directory holds more files
// than the vnode cache (`kern.maxvnodes`), so those lookups never stay warm.
// Measured with eight walkers, to the same byte: 14.6 s against 22.9 s over
// a 3.2-million-file `~/Dev`, 3.7 s against 6.4 s over `~/Library`, where a
// single-threaded `du -sk` takes 61 s and 21 s. `readdir` and `fstatat`
// remain for a filesystem that refuses the bulk call.

import Darwin
import Dispatch
import Foundation
import Synchronization
import System

/// Errors kept verbatim before the list is truncated; the count keeps rising.
private let maxErrorDetail = 50

/// Threads walking at once.
///
/// The work is system calls, not computation. APFS keeps only a small part
/// of its metadata in memory, so even a repeated walk of `~/Dev` reads about
/// 1.5 GB of it back from the disk in small random reads: a walker mostly
/// waits, and what several walkers buy is a deeper queue at the disk. Past
/// that the kernel's own locks are the limit. On an M2 Pro (8 performance
/// cores, 4 efficiency), over `~/Dev` (3.2 M files, 0.39 M directories) and
/// `~/Library` (0.61 M files, 0.12 M directories, much of it in app
/// containers, where every open waits on a permission check):
///
///     walkers        1      4      8     12     16
///     ~/Dev       58.1   21.8   14.6   13.8   13.6  s
///     ~/Library   17.5    4.8    3.5    6.2    6.2  s
///
/// Eight is where the walk stops getting faster. Beyond it `~/Dev` gains a
/// few percent for half as much kernel time again, and `~/Library` loses
/// seconds: with that many opens queued at the permission check, one of
/// them now and then waits out its five-second timeout (see
/// `openDirectory`). Not scaled with the core count, since the limits are
/// the disk and the kernel, and a walker waiting on either costs no core.
let scanWorkerCount = 8

/// Bytes one `getattrlistbulk` call may fill, per walker. Big enough that
/// most directories are one call; an entry takes about 100 bytes here.
private let bulkBufferBytes = 128 * 1024

/// How a scan measures and filters the tree.
public struct ScanOptions: Sendable, Hashable {
    /// Measure apparent length instead of allocated blocks. Apparent size is
    /// what `ls -l` shows; blocks are what the volume actually spends, which
    /// is what a disk-space tool normally wants.
    public var apparentSize: Bool
    /// Follow symlinks. Off by default: a home directory is full of links,
    /// and following them double-counts.
    public var followLinks: Bool
    /// Include dotfiles and dot-directories. On by default, like dust and
    /// `du`: `~/.cache` is frequently the largest directory in a home
    /// directory.
    public var includeHidden: Bool
    /// Stay on the root's volume: skip other disks, pseudo filesystems,
    /// network shares, snapshots and automount points, but keep what the
    /// root's volume reaches through firmlinks. See `foreignMounts`. Holds
    /// for a volume mounted while the walk runs, and for a followed link,
    /// too. On by default: a disk tool measures a disk, and its free-space
    /// meter only means anything for one volume.
    public var oneFilesystem: Bool
    /// Stop descending past this depth. Totals below that depth are then
    /// unknown, which makes an overview scan of a huge tree cheap.
    public var maxDepth: Int?
    /// Count a hardlinked file once instead of once per link.
    public var dedupHardlinks: Bool
    /// Whether children are ranked by bytes or by file count.
    public var metric: Metric

    public init(
        apparentSize: Bool = false,
        followLinks: Bool = false,
        includeHidden: Bool = true,
        oneFilesystem: Bool = true,
        maxDepth: Int? = nil,
        dedupHardlinks: Bool = true,
        metric: Metric = .bytes
    ) {
        self.apparentSize = apparentSize
        self.followLinks = followLinks
        self.includeHidden = includeHidden
        self.oneFilesystem = oneFilesystem
        self.maxDepth = maxDepth
        self.dedupHardlinks = dedupHardlinks
        self.metric = metric
    }
}

/// A point-in-time view of `ScanProgress`.
public struct ScanSnapshot: Sendable, Hashable {
    public var files: UInt64
    public var dirs: UInt64
    public var bytes: UInt64
    public var errors: UInt64
    public var finished: Bool
    public var cancelled: Bool
    /// Up to 50 unreadable paths, as `path: reason`, most recent last; the
    /// `errors` count keeps rising past them.
    public var messages: [String]

    public init() {
        files = 0
        dirs = 0
        bytes = 0
        errors = 0
        finished = false
        cancelled = false
        messages = []
    }
}

/// Counters a running scan publishes for the UI.
///
/// Plain relaxed atomics: this is a progress meter, not a synchronisation
/// point, and the UI reads a snapshot that is allowed to be a few entries
/// stale. Walkers add once per directory rather than once per file, so a
/// dozen threads are not fighting over one cache line for every entry.
public final class ScanProgress: Sendable {
    private let files = Atomic<UInt64>(0)
    private let dirs = Atomic<UInt64>(0)
    private let bytes = Atomic<UInt64>(0)
    private let errors = Atomic<UInt64>(0)
    private let finished = Atomic<Bool>(false)
    private let cancelled = Atomic<Bool>(false)
    private let messages = Mutex<[String]>([])

    public init() {}

    func count(files: UInt64 = 0, bytes: UInt64 = 0, dirs: UInt64 = 0) {
        if files > 0 {
            self.files.wrappingAdd(files, ordering: .relaxed)
        }
        if bytes > 0 {
            self.bytes.wrappingAdd(bytes, ordering: .relaxed)
        }
        if dirs > 0 {
            self.dirs.wrappingAdd(dirs, ordering: .relaxed)
        }
    }

    /// Count an unreadable path, keeping its reason while there is room.
    func recordError(_ path: String, code: Int32) {
        recordError("\(path): \(String(cString: strerror(code)))")
    }

    func recordError(_ message: String) {
        recordErrors(1, messages: [message])
    }

    /// Count `count` unreadable paths at once, keeping their reasons while
    /// there is room.
    func recordErrors(_ count: UInt64, messages more: [String]) {
        errors.wrappingAdd(count, ordering: .relaxed)
        messages.withLock { messages in
            let room = max(maxErrorDetail - messages.count, 0)
            messages.append(contentsOf: more.prefix(room))
        }
    }

    func finish() {
        finished.store(true, ordering: .relaxed)
    }

    var isFinished: Bool {
        finished.load(ordering: .relaxed)
    }

    /// Ask the walk to stop at the next directory boundary.
    public func cancel() {
        cancelled.store(true, ordering: .relaxed)
    }

    /// Whether the walk was asked to stop.
    public var isCancelled: Bool {
        cancelled.load(ordering: .relaxed)
    }

    public func snapshot() -> ScanSnapshot {
        var snapshot = ScanSnapshot()
        snapshot.files = files.load(ordering: .relaxed)
        snapshot.dirs = dirs.load(ordering: .relaxed)
        snapshot.bytes = bytes.load(ordering: .relaxed)
        snapshot.errors = errors.load(ordering: .relaxed)
        snapshot.finished = finished.load(ordering: .relaxed)
        snapshot.cancelled = isCancelled
        snapshot.messages = messages.withLock { $0 }
        return snapshot
    }
}

/// Unreadable paths as a scan's progress reported them: how many, and the
/// first reasons.
public typealias Unreadable = (count: UInt64, messages: [String])

/// A subtree already measured, reused by a wider scan instead of walked
/// again: widening from `~` to `/` only reads what is outside `~`.
public struct Known: Sendable {
    /// Where it is. Compared with the walk's own paths, so give it in the
    /// same form as the root (both canonical).
    public var path: FilePath
    public var tree: Node
    /// What the scan that measured it could not read: the count and the
    /// first reasons, as its progress reported them. A wider scan that
    /// reuses the tree reports them as its own, or its "unreadable" would
    /// count only what it walked itself. `nil`: not known, and found again
    /// by looking for unreadable directories in the tree.
    public var unreadable: Unreadable?

    public init(
        path: FilePath,
        tree: Node,
        unreadable: Unreadable? = nil
    ) {
        self.path = path
        self.tree = tree
        self.unreadable = unreadable
    }
}

/// Why a scan produced no tree at all. Unreadable directories *inside* the
/// root are not errors: they are counted in `ScanProgress` and marked with
/// `Node.readError`.
public struct ScanError: Error, Sendable, CustomStringConvertible {
    public var path: FilePath?
    /// The `errno` behind the failure, when there is one.
    public var code: Int32?
    public var message: String

    public init(path: FilePath?, code: Int32?, message: String) {
        self.path = path
        self.code = code
        self.message = message
    }

    /// A failed system call on `path`, described the way `strerror` says it.
    init(path: FilePath, code: Int32) {
        self.init(
            path: path,
            code: code,
            message: String(cString: strerror(code))
        )
    }

    public var description: String {
        guard let path else {
            return message
        }
        return "\(path.string): \(message)"
    }
}

/// A scan running on its own thread.
///
/// `poll()` returns `nil` while the walk runs, then the outcome — the same
/// one on every later call, so a caller may read it more than once.
/// Dropping the handle of a scan still running cancels it: nobody is left
/// to read what it would find.
public final class ScanHandle: Sendable {
    public let progress: ScanProgress
    private let outcome: Outcome

    /// Start walking `root` on a thread of its own, reusing `known` where
    /// the walk reaches it.
    public init(root: FilePath, options: ScanOptions, known: Known? = nil) {
        let progress = ScanProgress()
        let outcome = Outcome()
        self.progress = progress
        self.outcome = outcome

        let thread = Thread {
            let result = Result { () throws(ScanError) -> Node in
                try scanTree(
                    root,
                    options: options,
                    known: known,
                    progress: progress
                )
            }
            // Finished before the result is published, so whoever sees the
            // result also sees a finished snapshot.
            progress.finish()
            outcome.publish(result)
        }
        thread.name = "disktree-scan"
        thread.qualityOfService = .userInitiated
        // The final pass recurses once per level of the tree; a path can be
        // hundreds of levels deep, which the default 512 KiB of a secondary
        // thread does not promise to hold.
        thread.stackSize = 8 << 20
        thread.start()
    }

    deinit {
        if !progress.isFinished {
            progress.cancel()
        }
    }

    /// The finished tree, or why there is none; `nil` while the walk runs.
    public func poll() -> Result<Node, ScanError>? {
        outcome.value
    }

    /// Abandon the walk; the walkers still finish the directories they are
    /// in.
    public func cancel() {
        progress.cancel()
    }
}

/// Where the scan thread leaves its result for `ScanHandle.poll`.
private final class Outcome: Sendable {
    private let slot = Mutex<Result<Node, ScanError>?>(nil)

    func publish(_ result: Result<Node, ScanError>) {
        slot.withLock { $0 = result }
    }

    var value: Result<Node, ScanError>? {
        slot.withLock { $0 }
    }
}

/// Walk `root` and return the aggregated tree. Blocking.
public func scan(
    _ root: FilePath,
    options: ScanOptions
) throws(ScanError) -> Node {
    let progress = ScanProgress()
    let node = try scanTree(root, options: options, progress: progress)
    progress.finish()
    return node
}

/// How a walker lists a directory: in bulk wherever the filesystem accepts
/// it. The other exists as the fallback, and so the tests can hold the two
/// to one answer.
enum ScanReader: Sendable {
    case bulk
    case readdir
}

/// The walk behind `scan` and `ScanHandle`, with its parts open to the tests
/// and the benchmark: the progress to report into, how directories are
/// listed, how many walkers, and where the foreign mounts come from — `nil`
/// from that function means the table is unreadable, and devices are
/// compared instead.
func scanTree(
    _ root: FilePath,
    options: ScanOptions,
    known: Known? = nil,
    progress: ScanProgress,
    reader: ScanReader = .bulk,
    workers: Int = scanWorkerCount,
    foreignMounts: (FilePath) -> [FilePath]? = foreignMountsForWalk
) throws(ScanError) -> Node {
    var rootInfo = stat()
    guard root.withPlatformString({ stat($0, &rootInfo) }) == 0 else {
        throw ScanError(path: root, code: errno)
    }
    guard rootInfo.st_mode & S_IFMT == S_IFDIR else {
        throw ScanError(path: root, code: ENOTDIR)
    }

    let volume: VolumeRule =
        if !options.oneFilesystem {
            .anywhere
        } else if let foreign = foreignMounts(root) {
            .outside(
                Set(foreign.map(cPath)),
                root: root.withPlatformString(mountHolding)
            )
        } else {
            .device(rootInfo.st_dev)
        }
    var visited = Set<FileID>()
    if options.followLinks {
        visited.insert(FileID(rootInfo))
    }
    let context = WalkContext(
        options: options,
        realRoot: options.followLinks ? canonical(root) : nil,
        progress: progress,
        known: known.map {
            (path: cPath($0.path), tree: $0.tree, unreadable: $0.unreadable)
        },
        volume: volume,
        reader: reader,
        visited: visited
    )

    // The display name of a scanned root: its final component, or the path
    // itself for `/`.
    let top = PendingDir(
        path: cPath(root),
        name: root.lastComponent?.string ?? root.string,
        parent: nil,
        depth: 0,
        viaLink: true,
        countsEntries: nil
    )
    context.queue.push([top])
    let walkers = max(1, workers)
    for index in 0..<walkers {
        let thread = Thread {
            walkQueue(context)
        }
        thread.name = "disktree-walk-\(index)"
        thread.qualityOfService = .userInitiated
        thread.start()
    }
    context.done.wait()
    context.queue.close(walkers: walkers)

    guard let node = context.root.withLock({ $0.take() }) else {
        throw ScanError(path: root, code: nil, message: "produced no tree")
    }
    // Handed over, not shared: a tree still referenced here would be
    // copied, every children array of it, the moment the final pass
    // changes it — hundreds of megabytes over a home directory.
    return finishTree(consume node, options: options)
}

/// How the walk decides which directories belong to the root's volume.
private enum VolumeRule: Sendable {
    /// `oneFilesystem` is off.
    case anywhere
    /// Directories at these paths, spelled as the walk spells them, are
    /// other volumes. Checked by path before anything reads the directory,
    /// so an automount point is never triggered.
    ///
    /// The table is read once, and a whole-disk walk takes minutes: Time
    /// Machine mounts a snapshot of the Data volume for every backup, and a
    /// disk can be plugged in at any time. Nor does the table spell what a
    /// followed link leads to. So `root`, the filesystem the root is on as
    /// `statfs` names it, judges what the table could not: a directory the
    /// bulk listing says is a mount point, and a followed link's target.
    /// `statfs` rather than the table's longest mount point because it sees
    /// through firmlinks: a home directory is on the Data volume, and a
    /// link from it to `/` leads onto the system volume, another one.
    case outside(Set<[CChar]>, root: Mount?)
    /// The mount table could not be read: a directory on another device than
    /// the root is another volume. Only a fallback, because a Mac's system
    /// and Data volumes share one device number: a scan of `/` would walk
    /// `/System/Volumes/Data` as well as the firmlinks into it, and count
    /// the disk twice.
    case device(dev_t)
}

private final class WalkContext: Sendable {
    let options: ScanOptions
    /// The root with every symlink resolved, when links are followed: where
    /// a link that stays inside the tree leads.
    let realRoot: FilePath?
    let progress: ScanProgress
    /// A subtree to reuse rather than walk.
    let known: (path: [CChar], tree: Node, unreadable: Unreadable?)?
    let volume: VolumeRule
    let reader: ScanReader
    /// Directories already entered, so followed symlinks cannot loop.
    let visited: Mutex<Set<FileID>>
    /// Hardlinked files the progress has counted the bytes of already.
    let countedLinks = Mutex<Set<FileID>>([])
    /// Set by the root's completion, read once it is signalled on `done`.
    let root = Mutex<Node?>(nil)
    let done = DispatchSemaphore(value: 0)
    let queue = WorkQueue()

    init(
        options: ScanOptions,
        realRoot: FilePath?,
        progress: ScanProgress,
        known: (path: [CChar], tree: Node, unreadable: Unreadable?)?,
        volume: VolumeRule,
        reader: ScanReader,
        visited: Set<FileID>
    ) {
        self.options = options
        self.realRoot = realRoot
        self.progress = progress
        self.known = known
        self.volume = volume
        self.reader = reader
        self.visited = Mutex(visited)
    }

    var cancelled: Bool { progress.isCancelled }
}

/// The directories waiting for a walker.
///
/// A stack, not a queue: the newest directories are the deepest, so the walk
/// goes depth-first and what waits stays about as large as one path's worth
/// of siblings, instead of a whole level of the tree. The semaphore counts
/// what is on the stack, plus one wake-up per walker once the walk is over.
private final class WorkQueue: Sendable {
    private let stack = Mutex<[PendingDir]>([])
    private let ready = DispatchSemaphore(value: 0)

    func push(_ dirs: [PendingDir]) {
        stack.withLock { $0.append(contentsOf: dirs) }
        for _ in dirs {
            ready.signal()
        }
    }

    /// The next directory, or `nil` once the walk is over.
    func pop() -> PendingDir? {
        ready.wait()
        return stack.withLock { $0.popLast() }
    }

    /// Release every walker. Only called once the root is complete, when
    /// nothing is left on the stack: every directory pushed held its parent
    /// open until it was walked.
    func close(walkers: Int) {
        for _ in 0..<walkers {
            ready.signal()
        }
    }
}

/// One directory being walked, plus the counter that decides when it is done.
private final class PendingDir: Sendable {
    /// The path the walk reaches it by, NUL-terminated for `open`.
    let path: [CChar]
    let name: String
    let parent: PendingDir?
    let depth: Int
    /// Reached through a followed symlink, or the root (which may be one):
    /// its last component is allowed to be a link.
    let viaLink: Bool
    /// Whether this directory's filesystem keeps an honest entry count for
    /// each directory; see `keepsEntryCounts`. Inherited from the parent,
    /// since a directory is on its parent's filesystem — except the root, a
    /// mount point, a firmlink and a followed link, which are `nil` and ask
    /// the filesystem once they are open.
    let countsEntries: Bool?
    /// Starts at 1 for the directory itself; one more per subdirectory task.
    /// When it reaches zero the directory is complete.
    let pending = Atomic<Int>(1)
    /// Files found directly here, and finished subdirectories handed back up.
    let children = Mutex<[Node]>([])
    let readError = Atomic<Bool>(false)

    init(
        path: [CChar],
        name: String,
        parent: PendingDir?,
        depth: Int,
        viaLink: Bool,
        countsEntries: Bool?
    ) {
        self.path = path
        self.name = name
        self.parent = parent
        self.depth = depth
        self.viaLink = viaLink
        self.countsEntries = countsEntries
    }

    /// The path of the entry `name` inside this directory, NUL-terminated.
    /// Built from bytes, per directory, rather than through `FilePath`.
    func childPath(_ name: UnsafeRawBufferPointer) -> [CChar] {
        let stem = path.count - 1
        let slash = stem > 0 && path[stem - 1] == slashByte ? 0 : 1
        let capacity = stem + slash + name.count + 1
        return [CChar](unsafeUninitializedCapacity: capacity) { buffer, count in
            var at = 0
            for byte in path[..<stem] {
                buffer[at] = byte
                at += 1
            }
            if slash == 1 {
                buffer[at] = slashByte
                at += 1
            }
            for byte in name {
                buffer[at] = CChar(bitPattern: byte)
                at += 1
            }
            buffer[at] = 0
            count = at + 1
        }
    }

    /// Turn a completed directory into a node. Only called when `pending`
    /// has reached zero, so every child is already in `children`.
    ///
    /// `bytes` and `ownBytes` are left at zero on purpose: the walk cannot
    /// know the aggregate, and `aggregate` derives both from the children
    /// once every child is present.
    func build() -> Node {
        var node = Node.directory(name)
        node.readError = readError.load(ordering: .relaxed)
        node.children = children.withLock { children in
            defer { children = [] }
            return children
        }
        return node
    }
}

private let slashByte = CChar(bitPattern: UInt8(ascii: "/"))
private let dotByte = CChar(bitPattern: UInt8(ascii: "."))

/// A path as `open` wants it.
private func cPath(_ path: FilePath) -> [CChar] {
    Array(path.string.utf8CString)
}

/// A NUL-terminated path, for a message.
private func display(_ path: [CChar]) -> String {
    String(
        decoding: path.dropLast().map(UInt8.init(bitPattern:)),
        as: UTF8.self
    )
}

/// One walker: take a directory, read it, repeat until the walk is over.
private func walkQueue(_ context: WalkContext) {
    // Never download an evicted iCloud file or directory listing to measure
    // it: what is not on this disk takes no space on it. This is the system
    // default, set explicitly because a parent process can pass another on.
    _ = setiopolicy_np(
        IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
        IOPOL_SCOPE_THREAD,
        IOPOL_MATERIALIZE_DATALESS_FILES_OFF
    )
    let buffer = UnsafeMutableBufferPointer<CChar>.allocate(
        capacity: bulkBufferBytes
    )
    defer { buffer.deallocate() }
    while let dir = context.queue.pop() {
        walk(dir, context: context, buffer: buffer)
    }
}

/// What one directory's listing produced.
private struct Listing {
    var subdirs: [PendingDir] = []
    /// Children complete as they are: files, links, reused subtrees, and
    /// directories known to be empty without opening them.
    var finished: [Node] = []
    var files: UInt64 = 0
    var bytes: UInt64 = 0
    var dirs: UInt64 = 0
}

/// Read one directory, hand its subdirectories to the walkers, then report
/// completion.
private func walk(
    _ dir: PendingDir,
    context: WalkContext,
    buffer: UnsafeMutableBufferPointer<CChar>
) {
    var listing = Listing()
    // A depth-limited scan still measures what is directly in the directory,
    // it just does not descend further.
    let descend = context.options.maxDepth.map { dir.depth < $0 } ?? true
    if !context.cancelled {
        list(dir, into: &listing, descend: descend, context, buffer)
    }

    context.progress.count(
        files: listing.files,
        bytes: listing.bytes,
        dirs: listing.dirs
    )
    if !listing.subdirs.isEmpty && !context.cancelled {
        // Counted up before any of them can finish and count down.
        dir.pending.wrappingAdd(
            listing.subdirs.count,
            ordering: .acquiringAndReleasing
        )
        context.progress.count(dirs: UInt64(listing.subdirs.count))
        context.queue.push(listing.subdirs)
    }
    if !listing.finished.isEmpty {
        let finished = listing.finished
        dir.children.withLock { $0.append(contentsOf: finished) }
    }
    signalDone(dir, context: context)
}

/// Report that one task for `dir` is done: either its own scan, or one of its
/// children. The last one to report builds the node and bubbles up.
///
/// This is the whole reason for the `+1` sentinel: a directory is only built
/// once its own scan *and* every subdirectory task has finished, no matter
/// which of them lands last. A loop rather than recursion, so a chain of
/// directories completing at once does not grow the walker's stack.
private func signalDone(_ dir: PendingDir, context: WalkContext) {
    var current = dir
    while true {
        let (before, _) = current.pending.wrappingSubtract(
            1,
            ordering: .acquiringAndReleasing
        )
        guard before == 1 else {
            return
        }
        let node = current.build()
        guard let parent = current.parent else {
            context.root.withLock { $0 = node }
            context.done.signal()
            return
        }
        parent.children.withLock { $0.append(node) }
        current = parent
    }
}

/// Open `dir` and feed its entries to `admit`.
private func list(
    _ dir: PendingDir,
    into listing: inout Listing,
    descend: Bool,
    _ context: WalkContext,
    _ buffer: UnsafeMutableBufferPointer<CChar>
) {
    // `O_NOFOLLOW` unless the directory was reached through a link on
    // purpose: an entry that was a directory when it was listed and is a
    // symlink now must not lead the walk somewhere else.
    let flags =
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | (dir.viaLink ? 0 : O_NOFOLLOW)
    let fd = openDirectory(dir.path, flags: flags, context)
    guard fd >= 0 else {
        unreadable(dir, code: errno, context)
        return
    }
    let entries = Entries(
        dir: dir,
        fd: fd,
        descend: descend,
        countsEntries: dir.countsEntries ?? keepsEntryCounts(fd),
        context: context
    )
    if context.reader == .readdir || !listBulk(entries, into: &listing, buffer)
    {
        // `fdopendir` owns the descriptor from here, and closes it.
        listPortably(entries, into: &listing)
    } else {
        close(fd)
    }
}

/// `open`, asked again after `EINTR`.
///
/// Opening a directory inside another app's container
/// (`~/Library/Containers/…`) waits on a system daemon's permission check.
/// Under load that wait now and then gives up after five seconds with
/// `EINTR`; asked again, the same open answers in under a millisecond. A few
/// tries, not a loop: a daemon that never answers must not hold the walk.
private func openDirectory(
    _ path: [CChar],
    flags: Int32,
    _ context: WalkContext
) -> Int32 {
    var tries = 0
    while true {
        let fd = open(path, flags)
        tries += 1
        if fd >= 0 || errno != EINTR || tries == 3 || context.cancelled {
            return fd
        }
    }
}

/// Whether the filesystem holding the open directory `fd` keeps each
/// directory's entry count in the directory's own record, so that a count of
/// zero means empty. APFS and HFS+ do. Anything else — a network share, a
/// FAT stick, a user-space filesystem — is not trusted with it: a filesystem
/// that says zero for "unknown" would have the walk pass over full
/// directories and silently drop whole subtrees.
private func keepsEntryCounts(_ fd: Int32) -> Bool {
    var stats = statfs()
    guard fstatfs(fd, &stats) == 0 else {
        return false
    }
    let type = withUnsafeBytes(of: stats.f_fstypename) { bytes in
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
    return type == "apfs" || type == "hfs"
}

/// A directory whose contents could not be listed.
private func unreadable(
    _ dir: PendingDir,
    code: Int32,
    _ context: WalkContext
) {
    // An evicted iCloud directory: its listing is not on this disk, and
    // neither is anything in it. Not an error; there is nothing to count.
    guard code != EDEADLK else {
        return
    }
    context.progress.recordError(display(dir.path), code: code)
    dir.readError.store(true, ordering: .relaxed)
}

/// The open directory a listing is read from, and what the walk needs to
/// decide about each entry.
private struct Entries {
    let dir: PendingDir
    let fd: Int32
    let descend: Bool
    /// An entry count of zero here means an empty directory.
    var countsEntries: Bool
    let context: WalkContext

    /// Report a listing that failed part-way, or before it began.
    func failed(code: Int32, first: Bool) {
        if first {
            unreadable(dir, code: code, context)
        } else {
            context.progress.recordError(display(dir.path), code: code)
        }
    }

    func failed(entry name: UnsafeRawBufferPointer, code: Int32) {
        context.progress.recordError(
            display(dir.childPath(name)),
            code: code
        )
    }
}

/// One directory entry as the kernel described it, before any decision.
private struct RawEntry {
    /// NUL-terminated, pointing into the lister's buffer.
    var name: UnsafePointer<CChar>
    var nameLength: Int
    var kind: NodeKind
    var device: dev_t = 0
    var inode: UInt64 = 0
    var links: UInt32 = 1
    var modified: Int64 = 0
    /// Bytes on disk, `st_blocks * 512`.
    var allocated: UInt64 = 0
    /// Apparent length, `st_size`.
    var length: UInt64 = 0
    /// A directory the listing already shows to be empty, or to have
    /// nothing on this disk: there is nothing to open it for.
    var nothingInside = false
    /// What the bulk listing says is mounted on a directory:
    /// `DIR_MNTSTATUS_MNTPOINT` for a filesystem, `DIR_MNTSTATUS_TRIGGER`
    /// for an automount waiting to happen. Always zero from `readdir`,
    /// which cannot tell.
    var mountStatus: UInt32 = 0
    /// A firmlink, such as `/Users` on the system volume: a way into the
    /// Data volume that is judged by its path, not as a mount point.
    var firmlink = false
    /// Whether the listing gave everything a leaf is measured by. A
    /// filesystem may leave attributes out of a bulk listing — FAT has no
    /// `ALLOCSIZE` there, though `stat` counts its clusters — and a leaf
    /// measured without them would weigh nothing.
    var complete = true

    /// A mount point or a firmlink: what is inside may be another
    /// filesystem, with other habits.
    var crossesFilesystem: Bool { mountStatus != 0 || firmlink }

    var nameBytes: UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: name, count: nameLength)
    }

    /// Non-UTF-8 names are lossy for display. The scan still measures them
    /// correctly; only the reported name is approximate, and a path built
    /// from it names some other file, or none — which is why the removal
    /// guards refuse a name holding the replacement character. APFS and
    /// HFS+ refuse such a name (`EILSEQ`); a network or user-space
    /// filesystem may hold one.
    var displayName: String {
        String(decoding: nameBytes, as: UTF8.self)
    }

    var isHidden: Bool { nameLength > 0 && name[0] == dotByte }

    /// Take everything but the name from a `stat`.
    mutating func fill(from info: stat) {
        kind = nodeKind(mode: info.st_mode)
        device = info.st_dev
        inode = info.st_ino
        links = UInt32(info.st_nlink)
        modified = Int64(info.st_mtimespec.tv_sec)
        allocated = blockBytes(blocks: info.st_blocks)
        length = UInt64(max(0, info.st_size))
    }
}

/// List with `getattrlistbulk`. Returns `false` only when the filesystem
/// refuses the call outright, before any entry was read, so the caller can
/// list it the portable way instead.
private func listBulk(
    _ entries: Entries,
    into listing: inout Listing,
    _ buffer: UnsafeMutableBufferPointer<CChar>
) -> Bool {
    guard let base = buffer.baseAddress else {
        return false
    }
    var request = attrlist()
    request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    request.commonattr =
        ATTR_CMN_RETURNED_ATTRS
        | attrgroup_t(
            ATTR_CMN_NAME | ATTR_CMN_ERROR | ATTR_CMN_DEVID
                | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_FLAGS
                | ATTR_CMN_FILEID
        )
    request.dirattr = attrgroup_t(ATTR_DIR_ENTRYCOUNT | ATTR_DIR_MOUNTSTATUS)
    // `ALLOCSIZE` is every fork's allocation, the figure `st_blocks` is made
    // from; `DATALENGTH` is the data fork's length, which is `st_size`.
    request.fileattr = attrgroup_t(
        ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE | ATTR_FILE_DATALENGTH
    )

    var first = true
    while !entries.context.cancelled {
        let count = getattrlistbulk(entries.fd, &request, base, buffer.count, 0)
        if count == 0 {
            break
        }
        if count < 0 {
            let code = errno
            if code == EINTR {
                continue
            }
            if first && (code == ENOTSUP || code == EINVAL) {
                return false
            }
            entries.failed(code: code, first: first)
            break
        }
        first = false
        var start = 0
        for _ in 0..<count {
            var record = PackedRecord(base: base, offset: start)
            start += Int(record.next(UInt32.self))
            if let entry = record.entry(entries) {
                admit(entry, entries, into: &listing)
            }
        }
    }
    return true
}

/// One entry of a `getattrlistbulk` buffer: its length, the set of
/// attributes actually returned, then those attributes in the order of their
/// bits (`ERROR` first, right after the set), each 4-byte aligned, so 8-byte
/// fields are read unaligned.
private struct PackedRecord {
    let base: UnsafeMutablePointer<CChar>
    var offset: Int

    mutating func next<Field: BitwiseCopyable>(_: Field.Type) -> Field {
        defer { offset += MemoryLayout<Field>.size }
        return UnsafeRawPointer(base).loadUnaligned(
            fromByteOffset: offset,
            as: Field.self
        )
    }

    /// Decode the record, or `nil` for an entry the kernel could not
    /// describe (which is counted as an error).
    mutating func entry(_ entries: Entries) -> RawEntry? {
        let returned = next(attribute_set_t.self)
        let common = returned.commonattr
        let failure = common.has(ATTR_CMN_ERROR) ? next(UInt32.self) : 0
        guard common.has(ATTR_CMN_NAME) else {
            return nil
        }
        let referenceAt = offset
        let reference = next(attrreference_t.self)
        let name = UnsafePointer(
            base + referenceAt + Int(reference.attr_dataoffset)
        )
        // The length counts the terminating NUL.
        var entry = RawEntry(
            name: name,
            nameLength: max(0, Int(reference.attr_length) - 1),
            kind: .other
        )
        guard failure == 0 else {
            let code = Int32(bitPattern: failure)
            entries.failed(entry: entry.nameBytes, code: code)
            return nil
        }

        if common.has(ATTR_CMN_DEVID) {
            entry.device = next(dev_t.self)
        }
        if common.has(ATTR_CMN_OBJTYPE) {
            entry.kind = nodeKind(vnodeType: next(fsobj_type_t.self))
        }
        // Last write time from the same call that lists the entry: age
        // costs no extra system call.
        if common.has(ATTR_CMN_MODTIME) {
            entry.modified = Int64(next(timespec.self).tv_sec)
        }
        let flags = common.has(ATTR_CMN_FLAGS) ? next(UInt32.self) : 0
        if common.has(ATTR_CMN_FILEID) {
            entry.inode = next(UInt64.self)
        }

        let dirAttrs = returned.dirattr
        let count = dirAttrs.has(ATTR_DIR_ENTRYCOUNT) ? next(UInt32.self) : nil
        let mount = dirAttrs.has(ATTR_DIR_MOUNTSTATUS) ? next(UInt32.self) : 0
        // A quarter of the directories in `~/Library` are empty, and every
        // open costs a lookup (in an app container, a permission check too).
        // Only an ordinary directory's count is its contents, though: a mount
        // point counts the directory it covers, and a firmlink (`/Users` on
        // the system volume) the empty placeholder it stands on. An evicted
        // iCloud directory has nothing on this disk at all.
        entry.mountStatus = mount
        entry.firmlink = flags & UInt32(SF_FIRMLINK) != 0
        entry.nothingInside =
            flags & UInt32(SF_DATALESS) != 0
            || (entries.countsEntries && count == 0
                && !entry.crossesFilesystem)

        let fileAttrs = returned.fileattr
        if fileAttrs.has(ATTR_FILE_LINKCOUNT) {
            entry.links = next(UInt32.self)
        }
        if fileAttrs.has(ATTR_FILE_ALLOCSIZE) {
            entry.allocated = blockBytes(next(off_t.self))
        }
        if fileAttrs.has(ATTR_FILE_DATALENGTH) {
            entry.length = UInt64(max(0, next(off_t.self)))
        }
        // A directory is measured by what is in it; anything else by what
        // the listing said about it, which must all be there. The set
        // returned is the filesystem's to choose: FAT gives the length but
        // not the allocation (Invariant 1's figure), and leaving it at zero
        // would make every file on a USB stick weigh nothing.
        let size =
            entries.context.options.apparentSize
            ? ATTR_FILE_DATALENGTH : ATTR_FILE_ALLOCSIZE
        let identity = ATTR_CMN_DEVID | ATTR_CMN_FILEID | ATTR_CMN_MODTIME
        let measured =
            common.hasAll(identity)
            && fileAttrs.hasAll(ATTR_FILE_LINKCOUNT | size)
        entry.complete =
            common.has(ATTR_CMN_OBJTYPE)
            && (entry.kind == .directory || measured)
        return entry
    }
}

extension attrgroup_t {
    fileprivate func has(_ attribute: Int32) -> Bool {
        self & attrgroup_t(attribute) != 0
    }

    fileprivate func hasAll(_ attributes: Int32) -> Bool {
        self & attrgroup_t(attributes) == attrgroup_t(attributes)
    }
}

/// List the portable way: `readdir` for names and types, `fstatat` for
/// everything else. Takes ownership of the descriptor.
private func listPortably(
    _ listed: Entries,
    into listing: inout Listing
) {
    // `readdir` cannot tell a mount point from any other directory, so
    // nothing it lists is trusted with an entry count. Asking each directory's
    // filesystem instead would cost a `statfs` per directory, which a network
    // share may answer over the network. For the same reason only the mount
    // table keeps other volumes out of a portable listing: one mounted after
    // the table was read is entered. This listing is only for a filesystem
    // that refuses the bulk call, where that is a small risk.
    var entries = listed
    entries.countsEntries = false
    // A directory that can be listed but not searched names its entries and
    // lets none of them be looked at: unreadable, as the bulk listing, which
    // needs both, finds it — not a directory of unreadable entries.
    if faccessat(entries.fd, ".", X_OK, AT_EACCESS) != 0 {
        entries.failed(code: errno, first: true)
        close(entries.fd)
        return
    }
    guard let stream = fdopendir(entries.fd) else {
        entries.failed(code: errno, first: true)
        close(entries.fd)
        return
    }
    defer { closedir(stream) }
    var first = true
    while !entries.context.cancelled {
        errno = 0
        guard let item = readdir(stream) else {
            if errno != 0 {
                entries.failed(code: errno, first: first)
            }
            return
        }
        first = false
        let length = Int(item.pointee.d_namlen)
        let isDirectory = item.pointee.d_type == DT_DIR
        withUnsafePointer(to: &item.pointee.d_name) { tuple in
            let name = UnsafeRawPointer(tuple).assumingMemoryBound(
                to: CChar.self
            )
            let entry = RawEntry(name: name, nameLength: length, kind: .other)
            admitListed(entry, isDirectory: isDirectory, entries, &listing)
        }
    }
}

/// One `readdir` entry: skip `.` and `..`, then measure it unless it is a
/// directory, which needs nothing but its name to be walked.
private func admitListed(
    _ listed: RawEntry,
    isDirectory: Bool,
    _ entries: Entries,
    _ listing: inout Listing
) {
    var entry = listed
    if isDotOrDotDot(entry) {
        return
    }
    // Filtered before the `fstatat` it would otherwise cost.
    if !entries.context.options.includeHidden && entry.isHidden {
        return
    }
    if isDirectory {
        entry.kind = .directory
    } else {
        var info = stat()
        let flags = AT_SYMLINK_NOFOLLOW
        guard fstatat(entries.fd, entry.name, &info, flags) == 0 else {
            entries.failed(entry: entry.nameBytes, code: errno)
            return
        }
        entry.fill(from: info)
    }
    admit(entry, entries, into: &listing)
}

private func isDotOrDotDot(_ entry: RawEntry) -> Bool {
    let name = entry.name
    return (entry.nameLength == 1 && name[0] == dotByte)
        || (entry.nameLength == 2 && name[0] == dotByte && name[1] == dotByte)
}

/// Decide what to do with an entry, and account for the work it implies.
private func admit(
    _ listed: RawEntry,
    _ entries: Entries,
    into listing: inout Listing
) {
    let options = entries.context.options
    if !options.includeHidden && listed.isHidden {
        return
    }
    var entry = listed
    if !entry.complete {
        // Asked of `stat`, as the portable listing asks: Invariant 1 holds
        // on every filesystem, not only where the bulk call is whole.
        var info = stat()
        let flags = AT_SYMLINK_NOFOLLOW
        guard fstatat(entries.fd, entry.name, &info, flags) == 0 else {
            entries.failed(entry: entry.nameBytes, code: errno)
            return
        }
        entry.fill(from: info)
    }
    switch entry.kind {
    case .symlink:
        admitSymlink(entry, entries, into: &listing)
    case .directory:
        admitDirectory(entry, entries, into: &listing)
    case .file, .other:
        listing.add(entry, entries.context)
    }
}

private func admitDirectory(
    _ entry: RawEntry,
    _ entries: Entries,
    into listing: inout Listing
) {
    let context = entries.context
    let path = entries.dir.childPath(entry.nameBytes)
    // Past the depth limit a directory is left out of the tree, and so out
    // of the progress count too: the Rust walk counted it before deciding
    // not to descend, and its `dirs` ran ahead of the tree it built.
    guard entries.descend else {
        return
    }
    switch context.volume {
    case .anywhere:
        break
    case .outside(let foreign, let root):
        if foreign.contains(path) {
            return
        }
        // Not in the table, yet the listing says a filesystem is mounted
        // here, or waits to be: mounted since the table was read, or
        // reached beneath a followed link, where the table's spelling
        // does not reach. A firmlink is no mount point; it is judged by
        // its path alone. An automount trigger is left out unasked:
        // asking would mount it, and an automount is someone else's
        // filesystem by design.
        if entry.mountStatus != 0 && !entry.firmlink {
            let trigger =
                entry.mountStatus & UInt32(DIR_MNTSTATUS_TRIGGER) != 0
            if trigger || !onRootVolume(path, root: root) {
                return
            }
        }
    case .device(let rootDevice):
        var info = stat()
        let flags = AT_SYMLINK_NOFOLLOW
        guard fstatat(entries.fd, entry.name, &info, flags) == 0 else {
            entries.failed(entry: entry.nameBytes, code: errno)
            return
        }
        if info.st_dev != rootDevice {
            return
        }
    }
    // Memoized: the subtree a narrower scan already measured is taken whole
    // — once the volume rules let it in. It was measured under the same
    // rules, but from inside: a narrower scan of another disk's mount point
    // measured that disk, which a scan from above leaves out.
    if let known = context.known, known.path == path {
        reuse(known, named: entry.displayName, context, into: &listing)
        return
    }
    if entry.nothingInside {
        listing.finished.append(Node.directory(entry.displayName))
        listing.dirs += 1
        return
    }
    listing.subdirs.append(
        PendingDir(
            path: path,
            name: entry.displayName,
            parent: entries.dir,
            depth: entries.dir.depth + 1,
            viaLink: false,
            countsEntries: entry.crossesFilesystem
                ? nil : entries.countsEntries
        )
    )
}

/// Take a known subtree whole, with what it weighs and what could not be
/// read in it counted as if walked.
private func reuse(
    _ known: (path: [CChar], tree: Node, unreadable: Unreadable?),
    named name: String,
    _ context: WalkContext,
    into listing: inout Listing
) {
    var tree = known.tree
    tree.name = name
    context.progress.count(
        files: tree.files,
        bytes: tree.bytes,
        dirs: tree.dirs
    )
    if let unreadable = known.unreadable {
        context.progress.recordErrors(
            unreadable.count,
            messages: unreadable.messages
        )
    } else {
        recordUnreadable(tree, at: display(known.path), context.progress)
    }
    listing.finished.append(tree)
}

/// Record every directory in `node` the scan that measured it could not
/// read, as that scan did: by path, with no reason left to give.
private func recordUnreadable(
    _ node: Node,
    at path: String,
    _ progress: ScanProgress
) {
    if node.readError {
        progress.recordError("\(path): could not be read")
    }
    for child in node.children where child.isDir {
        recordUnreadable(child, at: path + "/" + child.name, progress)
    }
}

private func admitSymlink(
    _ entry: RawEntry,
    _ entries: Entries,
    into listing: inout Listing
) {
    let context = entries.context
    guard context.options.followLinks else {
        // Not followed: the link occupies only its target string, which
        // `du` reports as a handful of bytes or nothing at all.
        listing.add(entry, context)
        return
    }
    var info = stat()
    guard fstatat(entries.fd, entry.name, &info, 0) == 0 else {
        let code = errno
        // A dangling link is normal, not an error worth counting.
        if code != ENOENT {
            entries.failed(entry: entry.nameBytes, code: code)
        }
        return
    }
    var target = entry
    target.fill(from: info)
    guard target.kind == .directory else {
        listing.add(target, context)
        return
    }
    // Only a link the walk will follow may use up its target: one at the
    // depth limit, or onto another volume, must not keep the same
    // directory from being walked where another link reaches it.
    let path = entries.dir.childPath(entry.nameBytes)
    guard entries.descend else {
        return
    }
    // Into the tree itself: the walk reaches that directory by its real
    // path. Followed, the link would race that path, and every other link
    // to it, for the one walk `visited` allows, and which name holds the
    // files would depend on which walker got there first.
    if let inside = context.realRoot,
        canonical(FilePath(platformString: path)).starts(with: inside)
    {
        return
    }
    // Onto another volume: not followed, and kept as the link it is, as a
    // walk that follows no link keeps it, rather than left out of the tree.
    guard linkStaysOnVolume(path, target: info, context.volume) else {
        listing.add(entry, context)
        return
    }
    guard context.visited.withLock({ $0.insert(FileID(info)).inserted })
    else {
        return
    }
    listing.subdirs.append(
        PendingDir(
            path: path,
            name: entry.displayName,
            parent: entries.dir,
            depth: entries.dir.depth + 1,
            viaLink: true,
            countsEntries: nil
        )
    )
}

/// Whether the filesystem `path` leads to is the root's own volume, judged
/// as the table would have judged it had it listed it. One that cannot be
/// named is not: a disk tool measures one disk, and this one is not known
/// to be it.
private func onRootVolume(_ path: [CChar], root: Mount?) -> Bool {
    guard let root, let mount = mountHolding(path) else {
        return false
    }
    return !isForeign(mount, to: root)
}

/// Whether the directory a followed link leads to is on the root's volume.
///
/// A link is the one way the walk leaves the root's tree, so the table,
/// which lists mounts beneath the root, says nothing about where it goes: a
/// link to `/Volumes/NAS` would walk the share, and one to `/` the whole
/// disk again, the Data volume included. The Rust walk followed both.
/// Whatever is mounted beneath a target that is followed is then met as a
/// mount point in its listing.
///
/// By `statfs`, the system volume and the Data volume are two, so from a
/// scan of `/` a link into the Data volume is left out as the Data
/// volume's own mount point is: the walk reaches what it points at through
/// the firmlinks.
private func linkStaysOnVolume(
    _ path: [CChar],
    target: stat,
    _ volume: VolumeRule
) -> Bool {
    switch volume {
    case .anywhere: true
    case .outside(_, let root): onRootVolume(path, root: root)
    case .device(let rootDevice): target.st_dev == rootDevice
    }
}

extension Listing {
    /// A leaf that contributes size.
    fileprivate mutating func add(_ entry: RawEntry, _ context: WalkContext) {
        let options = context.options
        let size = options.apparentSize ? entry.length : entry.allocated
        var node = Node.entry(entry.displayName, kind: entry.kind, bytes: size)
        // Identity only where a second name can reach the same file: a
        // hardlink, anything once links are followed, and anything once the
        // walk may cross into other mounts — a scan of `/` that enters
        // `/System/Volumes/Data` meets every file under `/Users` again, one
        // link each. Keeping it for every file otherwise would make
        // de-duplication hash millions of entries that cannot collide.
        if entry.links > 1 || options.followLinks || !options.oneFilesystem {
            node.inode = FileID(
                device: UInt64(UInt32(bitPattern: entry.device)),
                inode: entry.inode
            )
        }
        node.modified = entry.modified
        // Counted as the tree will count it, so the live figures end where
        // the tree that lands does: files are files, not links or sockets,
        // and a hardlinked file weighs once, under the first name met.
        if entry.kind == .file {
            files += 1
        }
        let first =
            entry.links <= 1 || !options.dedupHardlinks
            || context.countedLinks.withLock {
                $0.insert(
                    FileID(
                        device: UInt64(UInt32(bitPattern: entry.device)),
                        inode: entry.inode
                    )
                ).inserted
            }
        if first {
            bytes = bytes.saturatingAdding(size)
        }
        finished.append(node)
    }
}

private func nodeKind(vnodeType: fsobj_type_t) -> NodeKind {
    switch vnodeType {
    case VDIR.rawValue: .directory
    case VLNK.rawValue: .symlink
    case VREG.rawValue: .file
    default: .other
    }
}

private func nodeKind(mode: mode_t) -> NodeKind {
    switch mode & S_IFMT {
    case S_IFDIR: .directory
    case S_IFLNK: .symlink
    case S_IFREG: .file
    default: .other
    }
}

/// Allocated bytes, rounded up to the 512-byte blocks `stat` counts in:
/// sparse files spend less than they claim, and this is the number that
/// matches `du`.
func blockBytes(_ allocated: off_t) -> UInt64 {
    // At most `Int64.max`, so rounding up cannot overflow.
    let bytes = UInt64(max(0, allocated))
    return (bytes + 511) / 512 * 512
}

/// `st_blocks * 512`, held at the top rather than trapping on a block
/// count no disk has, which a user-space filesystem can still report. The
/// Rust original saturated here too.
func blockBytes(blocks: blkcnt_t) -> UInt64 {
    UInt64(max(0, blocks)).saturatingMultiplied(by: 512)
}

extension FileID {
    /// `(st_dev, st_ino)`: the identity symlink loop detection depends on.
    fileprivate init(_ info: stat) {
        self.init(
            device: UInt64(UInt32(bitPattern: info.st_dev)),
            inode: info.st_ino
        )
    }
}

/// Charge a hardlinked file once, then derive every aggregate from the
/// result.
///
/// Zeroing `ownBytes` rather than `bytes` is deliberate: `aggregate`
/// recomputes totals from the direct contents, so a patched `bytes` would be
/// overwritten.
///
/// The first name met keeps a shared file's bytes, and as the walk hands
/// them over, children are in the order the walkers happened to finish. So
/// when anything is shared the tree is ranked first, and the bytes go to the
/// first name in the order the treemap shows — largest first, then by name —
/// the same on every scan of the same tree. Otherwise a rescan could move a
/// `pnpm` store's bytes from one project to another. Ranking twice costs a
/// quarter of a second over the 3.6 M entries of `~/Dev`, and nothing is
/// ranked twice when nothing is shared.
func finishTree(_ node: consuming Node, options: ScanOptions) -> Node {
    if options.dedupHardlinks && sharesFiles(node) {
        aggregate(&node, metric: options.metric)
        var seen = Set<FileID>()
        markDuplicateHardlinks(&node, seen: &seen)
    }
    aggregate(&node, metric: options.metric)
    classify(&node)
    return node
}

/// Whether two leaves carry one identity. Only a hardlinked file, or any
/// file once links are followed, carries one at all, so for most trees this
/// is one pass that allocates nothing.
func sharesFiles(_ node: Node) -> Bool {
    var seen = Set<FileID>()
    return sharesFiles(node, seen: &seen)
}

private func sharesFiles(_ node: Node, seen: inout Set<FileID>) -> Bool {
    guard node.isDir else {
        guard let key = node.inode else {
            return false
        }
        return !seen.insert(key).inserted
    }
    for child in node.children where sharesFiles(child, seen: &seen) {
        return true
    }
    return false
}

/// Zero every link to a file but the first that still carries its bytes.
///
/// A link already zeroed never claims the file: a reused subtree arrives
/// de-duplicated on its own terms, and if its zeroed link were met first,
/// the link that still carries the bytes would be zeroed too and the file
/// would count for nothing.
func markDuplicateHardlinks(_ node: inout Node, seen: inout Set<FileID>) {
    guard node.isDir else {
        if let key = node.inode, node.ownBytes > 0,
            !seen.insert(key).inserted
        {
            node.ownBytes = 0
        }
        return
    }
    // Index-based so each child is mutated in place, as in `aggregate`.
    for index in node.children.indices {
        markDuplicateHardlinks(&node.children[index], seen: &seen)
    }
}
