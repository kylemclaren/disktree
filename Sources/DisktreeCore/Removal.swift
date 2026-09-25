// What may be removed, and the command that removes it.
//
// disktree never deletes anything itself. It finds what is filling a volume,
// lets the user mark it, and then hands the marked list to the tools that
// already do removal well: Finder, where "Move to Trash" can be undone with
// Put Back, or a terminal, through a command copied from the review screen.
// What stays here is the judgement: which marked paths may be removed at
// all, which are already covered by another mark, and how to spell the
// command so that it removes exactly those paths and nothing else.
//
// Three things matter, in this order: never offer to remove something the
// user did not point at, never reach into a different filesystem, and
// always be able to say why a mark was left out.
//
// The command comes in two styles. `trash` (macOS 15 and later) moves the
// paths to the Trash and is the default, because it can be undone.
// `rm -rfx` deletes for good, and `-x` keeps it from crossing into a volume
// mounted somewhere inside a marked directory: the scan never showed what
// is on that volume, so nothing on it was marked. `trash` has no such
// option, nor has Finder, so a directory with a volume mounted inside it is
// refused whatever the style, and `-x` is what still holds for a volume
// mounted after the list was made. Every path is absolute and
// single-quoted, so no name can be read as an option or expanded by the
// shell, and a name holding a control character, which the terminal the
// command is pasted into would act on, is refused.

import Darwin
import Foundation
import System

/// One path the user asked to remove.
public struct Target: Sendable, Hashable {
    /// Absolute, as the scan found it: the only spelling the guards judge.
    public var path: FilePath
    /// Bytes measured when the path was marked; used for the projection.
    public var bytes: UInt64
    /// Whether it was a directory when marked: the review list's icon.
    public var isDir: Bool
    /// A dotfile or dot-directory, by its name.
    public var hidden: Bool

    public init(path: FilePath, bytes: UInt64, isDir: Bool, hidden: Bool) {
        self.path = path
        self.bytes = bytes
        self.isDir = isDir
        self.hidden = hidden
    }
}

/// How the copied command removes the marked paths.
public enum CommandStyle: Sendable, Hashable, CaseIterable {
    /// `trash`: into the Trash, where it can be recovered until the Trash is
    /// emptied.
    case trash
    /// `rm -rfx`: deleted for good.
    case remove

    /// The choice as the review screen names it.
    public var label: String {
        switch self {
        case .trash: "Move to Trash"
        case .remove: "Delete permanently"
        }
    }

    /// What the choice costs, in a few words.
    public var detail: String {
        switch self {
        case .trash: "trash: recoverable until the Trash is emptied"
        case .remove: "rm -rfx: unrecoverable"
        }
    }

    /// The command and the options it is run with.
    var invocation: String {
        switch self {
        // `trash` takes no `--`; every path is absolute, so none can start
        // with a dash and be read as an option.
        case .trash: "/usr/bin/trash"
        // `-x`: never cross a mount point inside a marked directory. `--`
        // ends the options even though no absolute path could start one.
        case .remove: "/bin/rm -rfx --"
        }
    }
}

/// A target that will not be touched, and why.
public struct Blocked: Sendable, Hashable {
    /// As it was marked, not normalized: the review list shows the mark.
    public var path: FilePath
    /// One line for the review list, naming the guard or the right tool.
    public var reason: String

    public init(path: FilePath, reason: String) {
        self.path = path
        self.reason = reason
    }
}

/// What the copied command will remove, and what it leaves out and why.
public struct Plan: Sendable, Hashable {
    /// Targets to act on, with any target contained in another removed first.
    public var targets: [Target]
    /// Marked paths covered by a target above; reported, not acted on.
    public var covered: [Target]
    /// Marked paths that must not be touched.
    public var blocked: [Blocked]

    public init(
        targets: [Target] = [],
        covered: [Target] = [],
        blocked: [Blocked] = []
    ) {
        self.targets = targets
        self.covered = covered
        self.blocked = blocked
    }

    /// What the targets weighed when marked: the projection, never the
    /// result, which only `statfs` before and after can tell.
    public var bytes: UInt64 {
        targets.reduce(0) { $0.saturatingAdding($1.bytes) }
    }

    /// Nothing would be removed: every mark was covered or blocked.
    public var isEmpty: Bool { targets.isEmpty }
}

/// The home directory: `$HOME`, else what Foundation says it is. A GUI app
/// launched by launchd has `HOME` set, but a stripped environment must not
/// switch off the home directory's guards.
public func defaultHome() -> FilePath? {
    if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
        return FilePath(home)
    }
    let home = NSHomeDirectory()
    return home.isEmpty ? nil : FilePath(home)
}

/// Build the plan for `targets`, which must all live under `root`.
///
/// Paths outside `root` are blocked rather than removed: the tree the user
/// was looking at is the only thing they consented to act on.
public func plan(
    _ targets: [Target],
    root: FilePath,
    home: FilePath? = defaultHome()
) -> Plan {
    let root = normalize(root)
    let home = home.map(normalize)
    var plan = Plan()
    var accepted: [Target] = []

    for target in targets {
        let path = normalize(target.path)
        if let reason = removalRefusal(for: path, root: root, home: home) {
            plan.blocked.append(Blocked(path: target.path, reason: reason))
            continue
        }
        var normalized = target
        normalized.path = path
        accepted.append(normalized)
    }

    // A path inside another target is removed with it. Keep the outer one and
    // report the inner one so the review screen can explain the nesting.
    // Sorting by components puts every directory before what is inside it;
    // the tie-break on marking order is what keeps the first of two equal
    // marks as the target and the second as covered, as a stable sort would.
    let ordered = accepted.enumerated().sorted { left, right in
        if left.element.path == right.element.path {
            return left.offset < right.offset
        }
        return componentsPrecede(left.element.path, right.element.path)
    }
    var outer: [Target] = []
    for (_, target) in ordered {
        if outer.contains(where: { target.path.starts(with: $0.path) }) {
            plan.covered.append(target)
        } else {
            outer.append(target)
        }
    }
    plan.targets = outer
    return plan
}

/// Path order by whole components, byte by byte, as Rust orders a `Path`:
/// `/a` sorts before `/a/b`, whatever comes between them as text.
///
/// The bytes are the stored ones, not a decoded `String`: two names that
/// are not UTF-8 can decode to the same text, and an order that calls them
/// equal while `==` does not is no order a sort can rely on.
private func componentsPrecede(_ left: FilePath, _ right: FilePath) -> Bool {
    left.components.lexicographicallyPrecedes(right.components) { lhs, rhs in
        lhs.withPlatformString { lhs in
            rhs.withPlatformString { rhs in strcmp(lhs, rhs) < 0 }
        }
    }
}

/// A tree the operating system or a package manager owns, and what to say
/// about it.
struct SystemTree: Sendable {
    var tree: FilePath
    /// What the tree is, as the start of the refusal.
    var what: String
    /// Who owns it, or which tool is the right one.
    var advice: String

    var reason: String { "\(what) under \(tree.string): \(advice)" }
}

/// Trees macOS or a package manager owns. A whole-disk scan shows them,
/// because they are part of what fills the disk, but files there belong to
/// the system or to packages, and removing them by hand breaks it; the
/// owner's own tool is the right one. Refused even where permissions would
/// allow it, and even inside them.
///
/// `/etc`, `/var` and `/tmp` are symlinks into `/private`, and the guards
/// compare paths lexically, so what is listed under `/private` is listed
/// under both spellings.
///
/// Deliberately not listed:
/// * `/cores`: kernel core dumps, often gigabytes, disposable by design and
///   read back by nothing. The directory itself is a firmlink, so it is
///   refused as a mount point; the dumps in it may go.
/// * `/private/var/folders`, `/private/tmp`, `/private/var/log`: per-user
///   caches, temporary files and logs, the counterparts of the `/tmp`,
///   `/var/cache` and `/var/log` the Linux port leaves removable.
/// * `/Applications` and `/Library`: an app is removed by moving it to the
///   Trash, and `/Library/Caches` exists to be cleared. What in `/Library`
///   is the system's is under `/Library/Apple`.
private let systemTrees: [SystemTree] = {
    let macOS = "part of macOS"
    let owned = "macOS owns it"
    return [
        // The sealed system volume, and the mount points of every other
        // system volume, the Data volume included: what is on that one is
        // reached through its firmlinks (/Users, /Applications, …) instead.
        SystemTree(tree: "/System", what: macOS, advice: owned),
        // The Data volume under its own name holds the same files as the
        // firmlinks, but every guard here compares paths lexically:
        // `/System/Volumes/Data/Users/<me>` is the home directory without
        // being spelled like it. Its own entry, so the refusal says where
        // the same files can be marked instead.
        SystemTree(
            tree: "/System/Volumes/Data",
            what: "the Data volume",
            advice: "mark it where the firmlinks show it, such as /Users"
        ),
        SystemTree(tree: "/bin", what: macOS, advice: owned),
        SystemTree(tree: "/sbin", what: macOS, advice: owned),
        SystemTree(tree: "/usr", what: macOS, advice: owned),
        // Writable, unlike the rest of /usr, but Homebrew's prefix on Intel
        // Macs and where installers put their files.
        SystemTree(
            tree: "/usr/local",
            what: "installed software",
            advice: "use brew, or the uninstaller that came with it"
        ),
        SystemTree(
            tree: "/dev",
            what: macOS,
            advice: "devices, not files"
        ),
        SystemTree(tree: "/etc", what: macOS, advice: owned),
        SystemTree(tree: "/private/etc", what: macOS, advice: owned),
        // Local accounts, receipts, launchd and Gatekeeper state, the
        // unified log: losing any of it breaks logins or updates.
        SystemTree(tree: "/var/db", what: macOS, advice: owned),
        SystemTree(tree: "/private/var/db", what: macOS, advice: owned),
        // Swap files and the sleep image, in use while the Mac runs.
        SystemTree(
            tree: "/var/vm",
            what: macOS,
            advice: "swap and the sleep image, managed by macOS"
        ),
        SystemTree(
            tree: "/private/var/vm",
            what: macOS,
            advice: "swap and the sleep image, managed by macOS"
        ),
        SystemTree(
            tree: "/var/root",
            what: macOS,
            advice: "the root user's home"
        ),
        SystemTree(
            tree: "/private/var/root",
            what: macOS,
            advice: "the root user's home"
        ),
        // Rosetta, XProtect and the other payloads Software Update installs
        // outside the sealed volume.
        SystemTree(
            tree: "/Library/Apple",
            what: macOS,
            advice: "Software Update owns it"
        ),
        SystemTree(
            tree: "/opt/homebrew",
            what: "Homebrew's prefix",
            advice: "use brew uninstall or brew cleanup"
        ),
        SystemTree(
            tree: "/opt/local",
            what: "MacPorts' prefix",
            advice: "use port uninstall or port reclaim"
        ),
        SystemTree(
            tree: "/nix/store",
            what: "the Nix store",
            advice: "use nix-collect-garbage"
        ),
    ]
}()

/// The system tree `path` is in, if any: the innermost, so `/usr/local`
/// speaks for itself rather than as `/usr`. The home directory is never
/// system, wherever it lives.
func systemTree(containing path: FilePath, home: FilePath?) -> SystemTree? {
    if let home, path.starts(with: normalize(home)) {
        return nil
    }
    let folded = FoldedPath(path)
    return
        systemTrees
        .filter { folded.isWithin(FoldedPath($0.tree)) }
        .max { $0.tree.components.count < $1.tree.components.count }
}

/// Why this path must not be removed, if it must not.
///
/// Refusals that name a place compare names the way a case-insensitive
/// volume does, which is how macOS formats its disks unless asked otherwise:
/// `/USR/lib` is `/usr/lib` there, and a guard that compared bytes would let
/// that spelling through. Only the check that *permits* — being inside the
/// scanned root — compares exactly, so folding can only ever refuse more.
func removalRefusal(
    for path: FilePath,
    root: FilePath,
    home: FilePath?
) -> String? {
    // Every path from a scan is absolute. A relative one would be resolved
    // against whatever the working directory is when the command runs.
    if !path.isAbsolute {
        return "not an absolute path"
    }
    // The command spells the path as text. A name that is not UTF-8 would be
    // written with a replacement character, and name some other path, or
    // none. APFS and HFS+ never hold one; a foreign filesystem might.
    //
    // A path built from the scan never gets here with its bytes: the walk
    // decodes a name to text as it reads it, and the replacement character
    // is the only trace of the bytes it lost. A name that really holds one
    // is refused with it, which can only ever refuse more. Scalars, not
    // characters: followed by a combining mark, the replacement character
    // is part of a character that does not equal it.
    if FilePath(path.string) != path || isLossy(path) {
        return "its name is not UTF-8: remove it in Finder instead"
    }
    // Single quotes keep a name from the shell, not from the terminal it is
    // pasted into: the tty reads a pasted carriage return as a newline, so
    // `Icon\r` names its neighbour `Icon\n`, and ^C, ^U or the end of a
    // bracketed paste act before any shell sees a quote. Refused whole,
    // since no spelling of such a name survives a paste.
    if path.string.unicodeScalars.contains(where: isControl) {
        return "its name holds a control character: remove it in Finder "
            + "instead"
    }
    if path.components.isEmpty {
        return "the filesystem root cannot be removed"
    }
    let folded = FoldedPath(path)
    if folded == FoldedPath(root) {
        return "the scanned root cannot be removed"
    }
    if let home {
        let homeFolded = FoldedPath(home)
        if folded == homeFolded {
            return "the home directory cannot be removed"
        }
        // Removing a directory removes what is in it. On a standard Mac the
        // home directory's only ancestors, `/` and `/Users`, are refused
        // anyway, as the root and as a firmlink; one on another volume, or
        // wherever `$HOME` points, has ancestors that are not. The Rust
        // guard compares for equality only, and so lets them through.
        if homeFolded.isWithin(folded) {
            return "it holds the home directory, which cannot be removed"
        }
        // Every app keeps its settings and data there. What is inside it —
        // Caches above all — is fair game; the folder itself is not.
        if folded == FoldedPath(home.appending("Library")) {
            return "~/Library holds every app's settings: remove what is "
                + "inside it instead"
        }
    }
    if !root.isAbsolute || !path.starts(with: root) {
        return "outside the scanned root"
    }
    // Before the symlink check, which would refuse `/etc/hosts` too, but
    // only for `/etc` being a link: who owns a tree is the better answer.
    if let system = systemTree(containing: path, home: home) {
        return system.reason
    }
    // Lexically inside the root is not really inside it when the way there
    // runs through a symlink, which a scan that follows links shows as a
    // directory: every guard here would be judging the wrong path.
    if let link = symlinkOnTheWay(from: root, to: path) {
        return "reached through the symlink \(link.string): remove it where "
            + "it really is"
    }
    if isMountPoint(path) {
        return "a mount point: removing it would cross onto another "
            + "filesystem"
    }
    // Moved to the Trash, in Finder or by `trash`, a directory takes a
    // volume mounted inside it along, still mounted, into the Trash; only
    // `rm` has `-x` to stop at it. What is on that volume was never shown,
    // so nothing on it was marked.
    if let inside = mountsInside(path), let mount = inside.first {
        return "a volume is mounted inside it, at \(mount.string): eject "
            + "it first"
    }
    return nil
}

/// Whether `path` holds a name the walk could not decode: the replacement
/// character is the only trace of the bytes it lost, so the path names
/// some other entry, or none. Scalars, not characters: followed by a
/// combining mark, the replacement character is part of a character that
/// does not equal it. A name that really holds one is taken for lossy too,
/// which can only ever refuse more.
public func isLossy(_ path: FilePath) -> Bool {
    path.string.unicodeScalars.contains("\u{FFFD}")
}

/// C0 (tab and newline among them), DEL and C1: what a terminal acts on
/// rather than shows.
private func isControl(_ scalar: Unicode.Scalar) -> Bool {
    scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
}

/// The first directory between `root` and `path`, both excluded, that is a
/// symlink. The target itself may be one: a symlink is unlinked, never
/// followed.
private func symlinkOnTheWay(
    from root: FilePath,
    to path: FilePath
) -> FilePath? {
    var relative = path
    guard relative.removePrefix(root) else {
        return nil
    }
    var directory = root
    for name in relative.components.dropLast() {
        directory.append(name)
        var info = stat()
        if lstat(directory.string, &info) == 0,
            info.st_mode & S_IFMT == S_IFLNK
        {
            return directory
        }
    }
    return nil
}

/// A path's names as a case-insensitive volume compares them.
private struct FoldedPath: Equatable {
    var isAbsolute: Bool
    var names: [String]

    init(_ path: FilePath) {
        isAbsolute = path.isAbsolute
        names = path.components.map {
            $0.string.folding(options: .caseInsensitive, locale: nil)
        }
    }

    /// Whether this is `other` or inside it, by whole components.
    func isWithin(_ other: Self) -> Bool {
        isAbsolute == other.isAbsolute && names.starts(with: other.names)
    }
}

/// Whether `path` is where another filesystem begins, i.e. a mount point.
/// Descending into one would delete data the user never marked.
///
/// The device number alone does not say so on macOS: the sealed system
/// volume and the Data volume form one volume group and report the same
/// `st_dev`, so `/Users` — a firmlink from one into the other — and
/// `/System/Volumes/Data` itself look like plain directories to `lstat`.
/// `statfs` tells the two volumes apart, so both are asked.
public func isMountPoint(_ path: FilePath) -> Bool {
    var entry = stat()
    guard lstat(path.string, &entry) == 0 else {
        return false
    }
    guard entry.st_mode & S_IFMT == S_IFDIR else {
        return false
    }
    guard path.lastComponent != nil else {
        return true
    }
    // The parent is resolved the way the kernel resolves it when it removes
    // the entry, symlinks in its own path included.
    let parent = path.removingLastComponent().string
    var container = stat()
    // A directory whose parent cannot be stat'ed is not worth the risk.
    guard stat(parent, &container) == 0 else {
        return true
    }
    // Checked first so an automount trigger, which has its own device, is
    // never asked for its filesystem and so never mounted.
    if container.st_dev != entry.st_dev {
        return true
    }
    var own = statfs()
    var parents = statfs()
    guard statfs(path.string, &own) == 0, statfs(parent, &parents) == 0
    else {
        return true
    }
    return !sameFilesystem(own, parents)
}

/// Whether two `statfs` results describe the same mounted filesystem.
private func sameFilesystem(_ left: statfs, _ right: statfs) -> Bool {
    left.f_fsid.val.0 == right.f_fsid.val.0
        && left.f_fsid.val.1 == right.f_fsid.val.1
        && mountPoint(left) == mountPoint(right)
}

private func mountPoint(_ info: statfs) -> String {
    withUnsafeBytes(of: info.f_mntonname) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
}

/// Lexically normalize a path: resolve `.` and `..` without touching the
/// filesystem, so a symlink can never redirect a guard.
///
/// A `..` at the root has nowhere to go, so `/..` is `/` rather than the
/// empty path. A leading `..` on a relative path is preserved.
public func normalize(_ path: FilePath) -> FilePath {
    path.lexicallyNormalized()
}

/// The shell command that removes exactly the plan's targets: never a
/// covered path (its outer target takes it) and never a blocked one.
///
/// One path per line, joined with backslash-newlines, so a long list stays
/// readable in the terminal it is pasted into and each line can be checked
/// before pressing return. `nil` when there is nothing to remove.
public func cleanupCommand(_ plan: Plan, style: CommandStyle) -> String? {
    guard !plan.targets.isEmpty else {
        return nil
    }
    let paths = plan.targets.map { "    " + shellQuoted($0.path) }
    return ([style.invocation] + paths).joined(separator: " \\\n")
}

/// `path` as one POSIX shell word: single-quoted, with each `'` written as
/// `'\''`. Inside single quotes nothing is special — not `$`, not a
/// backtick, not a space or a newline — so the word is the path, byte for
/// byte, in sh, bash and zsh alike.
public func shellQuoted(_ path: FilePath) -> String {
    "'" + path.string.replacing("'", with: "'\\''") + "'"
}
