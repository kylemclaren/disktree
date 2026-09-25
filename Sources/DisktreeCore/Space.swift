// Free space on the volume a path lives on, and which volume that is.
//
// This is what makes "amount of crap I found" a real number rather than an
// estimate: the app measures the volume before and after a removal, and shows
// the projection while marking.
//
// macOS has no `/proc/self/mounts`. The live table comes from
// `getmntinfo_r_np`, and `parseMounts` reads the text `mount(8)` prints, so
// the tests keep readable fixture tables.
//
// A Mac also splits one disk in two: a sealed, read-only system volume
// mounted at `/`, and a Data volume at `/System/Volumes/Data`, joined by
// firmlinks. `/Users`, `/Applications`, `/Library`, `/private` and a few more
// are directories on the system volume that lead into the Data volume, and
// they are the canonical way to reach its contents. So two questions get two
// different answers here: *which filesystem holds this path* is asked of
// `statfs`, which sees through a firmlink (`/Users/kyle` is on the Data
// volume); *what does a scan of this root measure* is decided by mount-point
// path, as on Linux (a scan of `/` walks `/Users` through its firmlink and
// leaves `/System/Volumes/Data` out, or it would count the disk twice).

import Darwin
import Foundation
import System

/// A volume's capacity in bytes.
///
/// APFS volumes share their container's free space, so `free` and
/// `available` are the container's: what `df` and the Finder report.
/// Purgeable space (local snapshots, evictable caches) is not counted as
/// free, because nothing guarantees it comes back.
public struct SpaceInfo: Sendable, Hashable {
    /// Total size of the volume.
    public var total: UInt64
    /// Free blocks, including the reserve only root may write to.
    public var free: UInt64
    /// Free blocks this user may actually write; what `df -h` reports.
    public var available: UInt64

    public init(total: UInt64, free: UInt64, available: UInt64) {
        self.total = total
        self.free = free
        self.available = available
    }

    /// Space in use, computed from `free` rather than `available` so the
    /// figure does not jump when a reserve is opened to root.
    public var used: UInt64 { total > free ? total - free : 0 }

    /// Share of the volume in use, `0...1`.
    public var usedFraction: Double {
        total == 0 ? 0 : Double(used) / Double(total)
    }

    /// Free space after `bytes` are removed, saturating at the volume size
    /// and never counting the same byte twice.
    public func afterRemoving(_ bytes: UInt64) -> SpaceInfo {
        SpaceInfo(
            total: total,
            free: min(free.saturatingAdding(bytes), total),
            available: min(available.saturatingAdding(bytes), total)
        )
    }
}

/// A volume that could not be measured: the `errno` of the failing call,
/// and the path it was asked about.
public struct SpaceError: Error, Sendable, Hashable, CustomStringConvertible {
    public var code: Int32
    public var path: FilePath

    public init(code: Int32, path: FilePath) {
        self.code = code
        self.path = path
    }

    public var description: String {
        "\(path.string): \(String(cString: strerror(code)))"
    }
}

/// Read the space on the volume containing `path`.
///
/// `statfs` rather than `statvfs`: on macOS `statvfs` reports 32-bit block
/// counts that have to be rescaled to fit a large volume, while `statfs`
/// is the native call with 64-bit counts. Its `f_bsize` is the unit those
/// counts are in (Linux's `f_frsize`).
public func spaceInfo(_ path: FilePath) throws(SpaceError) -> SpaceInfo {
    var stats = statfs()
    let status = path.withPlatformString { statfs($0, &stats) }
    guard status == 0 else {
        throw SpaceError(code: errno, path: path)
    }
    let block = UInt64(stats.f_bsize)
    return SpaceInfo(
        total: stats.f_blocks.saturatingMultiplied(by: block),
        free: stats.f_bfree.saturatingMultiplied(by: block),
        available: stats.f_bavail.saturatingMultiplied(by: block)
    )
}

/// One line of the mount table.
public struct Mount: Sendable, Hashable {
    /// What is mounted: a device such as `/dev/disk3s5`, a map such as
    /// `map auto_home`, a share such as `//kyle@nas/home`, or a snapshot,
    /// `name@/dev/disk3s5`.
    public var source: String
    public var point: FilePath
    public var fstype: String
    /// Flags in `mount(8)`'s words: `local`, `read-only`, `nobrowse`,
    /// `automounted`, `snapshot`, `root data`, ….
    public var options: [String]

    public init(
        source: String,
        point: FilePath,
        fstype: String,
        options: [String] = []
    ) {
        self.source = source
        self.point = point
        self.fstype = fstype
        self.options = options
    }
}

/// Parse the table `mount(8)` prints:
/// `/dev/disk3s5 on /System/Volumes/Data (apfs, local, journaled)`.
///
/// Unlike `/proc/self/mounts`, nothing is escaped, and both a source
/// (`map auto_home`) and a mount point (`/Volumes/My Disk`) may contain
/// spaces. A source never contains ` on `, and the options never contain a
/// parenthesis, so the source ends at the first ` on ` and the mount point
/// at the last ` (`: that reads `/Volumes/Disk (2)` and `/Volumes/Live on
/// Stage` correctly too. Lines that do not have that shape are skipped.
public func parseMounts(_ table: String) -> [Mount] {
    table.split(whereSeparator: \.isNewline).compactMap(parseMountLine)
}

private func parseMountLine(_ raw: Substring) -> Mount? {
    let line = raw.trimmingCharacters(in: .whitespaces)
    guard line.hasSuffix(")"),
        let on = line.range(of: " on "),
        let open = line.range(of: " (", options: .backwards),
        on.upperBound <= open.lowerBound
    else {
        return nil
    }
    let source = line[..<on.lowerBound]
    let point = line[on.upperBound..<open.lowerBound]
    let fields = line[open.upperBound..<line.index(before: line.endIndex)]
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
    guard !source.isEmpty, !point.isEmpty, let fstype = fields.first,
        !fstype.isEmpty
    else {
        return nil
    }
    return Mount(
        source: String(source),
        point: FilePath(String(point)),
        fstype: fstype,
        options: Array(fields.dropFirst())
    )
}

/// This machine's mount table, or `nil` when it cannot be read.
///
/// `getmntinfo_r_np` rather than `getmntinfo`: the plain call returns a
/// buffer shared by every caller in the process, and the scan thread and the
/// interface both ask. `MNT_NOWAIT` takes the kernel's cached figures
/// instead of asking every filesystem, so a network share that has gone
/// away cannot hang the call.
public func currentMounts() -> [Mount]? {
    var table: UnsafeMutablePointer<statfs>?
    let count = getmntinfo_r_np(&table, MNT_NOWAIT)
    guard count > 0, let table else {
        return nil
    }
    defer { free(table) }
    return UnsafeBufferPointer(start: table, count: Int(count))
        .map(mountEntry)
}

private func mountEntry(_ stats: statfs) -> Mount {
    var options = mountFlagNames.compactMap { flag, name in
        stats.f_flags & flag != 0 ? name : nil
    }
    if stats.f_flags_ext & UInt32(MNT_EXT_ROOT_DATA_VOL) != 0 {
        options.append(rootDataOption)
    }
    return Mount(
        source: cString(stats.f_mntfromname),
        point: FilePath(cString(stats.f_mntonname)),
        fstype: cString(stats.f_fstypename),
        options: options
    )
}

/// What `mount(8)` calls the Data volume of the boot volume group.
private let rootDataOption = "root data"

/// `statfs` flags in `mount(8)`'s words and order, so the live table reads
/// like the fixtures. `sealed` is missing: it is a volume capability, not a
/// mount flag, and nothing here depends on it.
private let mountFlagNames: [(flag: UInt32, name: String)] = [
    (UInt32(MNT_ASYNC), "asynchronous"),
    (UInt32(MNT_EXPORTED), "NFS exported"),
    (UInt32(MNT_LOCAL), "local"),
    (UInt32(MNT_NODEV), "nodev"),
    (UInt32(MNT_NOEXEC), "noexec"),
    (UInt32(MNT_NOSUID), "nosuid"),
    (UInt32(MNT_QUOTA), "with quotas"),
    (UInt32(MNT_RDONLY), "read-only"),
    (UInt32(MNT_SYNCHRONOUS), "synchronous"),
    (UInt32(MNT_UNION), "union"),
    (UInt32(MNT_AUTOMOUNTED), "automounted"),
    (UInt32(MNT_JOURNALED), "journaled"),
    (UInt32(MNT_DEFWRITE), "defwrite"),
    (UInt32(MNT_IGNORE_OWNERSHIP), "noowners"),
    (UInt32(MNT_NOATIME), "noatime"),
    (MNT_STRICTATIME, "strictatime"),
    (UInt32(MNT_QUARANTINE), "quarantine"),
    (UInt32(MNT_DONTBROWSE), "nobrowse"),
    (UInt32(MNT_CPROTECT), "protect"),
    (UInt32(MNT_NOFOLLOW), "nofollow"),
    (UInt32(MNT_REMOVABLE), "removable"),
    (UInt32(MNT_SNAPSHOT), "snapshot"),
]

/// A fixed-size C string field, such as `f_mntonname`, as a `String`.
private func cString<Field>(_ field: Field) -> String {
    withUnsafeBytes(of: field) { bytes in
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}

/// Mount points below `root` that are not part of `root`'s volume, which a
/// scan of that volume must not enter.
///
/// "The volume" is the mount *source* and filesystem type, not the device
/// number: btrfs gives every subvolume its own `st_dev`, and a Mac's
/// firmlinks lead from `/` into the Data volume's device, yet each is the
/// natural way to measure its disk. Everything else is left out: devfs,
/// other volumes of the same container (`/System/Volumes/*`, which a scan of
/// `/` already reaches through firmlinks where it should), other disks
/// under `/Volumes`, simulator runtimes, network shares, and automount
/// points — entering one of those would mount a NAS just to measure it.
/// Snapshots are left out too, because every file in them shares its blocks
/// with the live one and counting them would count the disk twice.
public func foreignMounts(_ mounts: [Mount], root: FilePath) -> [FilePath] {
    guard let own = containingMount(mounts, path: root) else {
        return []
    }
    return mounts.filter { mount in
        mount.point != root && mount.point.starts(with: root)
            && isForeign(mount, to: own)
    }
    .map(\.point)
}

/// Whether `mount` is another volume than `own`: another source or
/// filesystem type, or a snapshot of the live one. The rule
/// `foreignMounts` applies to the table, and the walk to a mount the table
/// did not list.
///
/// A snapshot is foreign to the volume it was taken of, whose blocks it
/// shares, but not to itself: a Mac's sealed system volume is mounted at
/// `/` *as* a snapshot, and a scan of `/usr` compares it with itself.
func isForeign(_ mount: Mount, to own: Mount) -> Bool {
    mount.source != own.source || mount.fstype != own.fstype
        || (isSnapshot(mount) && !isSnapshot(own))
}

/// The mounted filesystem holding `path`, as `statfs` names it: wherever
/// the path leads, through a symlink or a firmlink or onto a mount point.
/// `nil` when it cannot be asked.
///
/// Never asked of an automount trigger, since asking would mount it.
func mountHolding(_ path: UnsafePointer<CChar>) -> Mount? {
    var stats = statfs()
    guard statfs(path, &stats) == 0 else {
        return nil
    }
    return mountEntry(stats)
}

/// The mount `path` is under: the longest mount point above it. On a tie,
/// the later entry, which was mounted on top and is the one a path reaches.
private func containingMount(_ mounts: [Mount], path: FilePath) -> Mount? {
    var best: Mount?
    for mount in mounts where path.starts(with: mount.point) {
        if let current = best,
            current.point.string.utf8.count > mount.point.string.utf8.count
        {
            continue
        }
        best = mount
    }
    return best
}

private func isSnapshot(_ mount: Mount) -> Bool {
    // APFS: `mount(8)` says `snapshot`, and a mounted snapshot's source is
    // `name@/dev/diskN` — Time Machine's local snapshots look like this. A
    // share's source has an `@` too (`//kyle@nas/home`), hence `@/dev/`.
    let apfs =
        mount.options.contains("snapshot") || mount.source.contains("@/dev/")
    // btrfs, as on Omarchy: snapper's `.snapshots`, or a subvolume named for
    // them. Kept so the rules stay the ones the Linux original tested.
    let btrfs =
        mount.point.lastComponent?.string == ".snapshots"
        || mount.options.contains { option in
            option.hasPrefix("subvol=") && option.contains("snapshots")
        }
    return apfs || btrfs
}

/// The top of the disk `path` lives on.
///
/// The shortest mount point above it with the same source. On a Mac the
/// home directory is reached through the `/Users` firmlink, so the disk is
/// `/`; a directory on an external disk gives that disk's mount point.
public func volumeRoot(_ mounts: [Mount], path: FilePath) -> FilePath? {
    guard let own = containingMount(mounts, path: path) else {
        return nil
    }
    var best: Mount?
    for mount in mounts
    where mount.source == own.source && mount.fstype == own.fstype
        && path.starts(with: mount.point)
    {
        // The first of equally short points wins, as it did in Rust.
        if let current = best,
            current.point.string.utf8.count <= mount.point.string.utf8.count
        {
            continue
        }
        best = mount
    }
    return best?.point
}

/// `volumeRoot` for this machine.
public func volumeRootFor(_ path: FilePath) -> FilePath? {
    guard let mounts = currentMounts() else {
        return nil
    }
    return volumeRoot(mounts, path: canonical(path))
}

/// Mount points strictly inside `path`, spelled as the table spells them;
/// `nil` when the table cannot be read. A directory holding one takes that
/// volume along wherever it is moved.
public func mountsInside(_ path: FilePath) -> [FilePath]? {
    guard let mounts = currentMounts() else {
        return nil
    }
    // Resolved as the table's points are (`/tmp` is `/private/tmp` there),
    // all but the last name: a symlink is removed, never followed, so what
    // it points at holds nothing of its own.
    guard let name = path.lastComponent else {
        return mounts.map(\.point).filter { !$0.components.isEmpty }
    }
    let real = canonical(path.removingLastComponent()).appending(name)
    return mounts.map(\.point).filter { $0 != real && $0.starts(with: real) }
}

/// `foreignMounts` for this machine; `nil` when the mount table cannot be
/// read, so the caller can fall back to comparing devices.
///
/// The root is resolved first (`/tmp` is `/private/tmp`), because the table
/// only knows real paths. When the root is inside the Data volume's own
/// mount point, the mounts behind a firmlink are listed a second time under
/// it: `/Volumes/Backup` is also `/System/Volumes/Data/Volumes/Backup`, and
/// a walk of the Data volume would otherwise enter it by that name.
public func foreignMountsFor(_ root: FilePath) -> [FilePath]? {
    guard let mounts = currentMounts() else {
        return nil
    }
    let root = canonical(root)
    let table = withFirmlinkAliases(
        mounts,
        root: root,
        firmlinks: systemFirmlinks
    )
    return foreignMounts(table, root: root)
}

/// `foreignMountsFor`, spelled the way a walk of `root` spells its paths.
///
/// A walk joins names onto the root it was given, which need not be the
/// resolved one: the temporary directory is `/var/folders/…`, and the table
/// says `/private/var/folders/…`. Checking by path only works if both sides
/// say it the same way.
func foreignMountsForWalk(_ root: FilePath) -> [FilePath]? {
    guard let foreign = foreignMountsFor(root) else {
        return nil
    }
    return relocate(foreign, from: canonical(root), to: root)
}

/// Re-root `paths` from beneath `base` to beneath `root`. A path that is not
/// beneath `base` is kept as it is.
func relocate(
    _ paths: [FilePath],
    from base: FilePath,
    to root: FilePath
) -> [FilePath] {
    guard base != root else {
        return paths
    }
    let depth = base.components.count
    return paths.map { path in
        guard path.starts(with: base) else {
            return path
        }
        return root.appending(path.components.dropFirst(depth))
    }
}

/// Add, for each mount behind a firmlink, the same mount as seen from the
/// Data volume's own mount point — but only when `root` is inside that
/// mount point, the one place the second name can be walked into.
func withFirmlinkAliases(
    _ mounts: [Mount],
    root: FilePath,
    firmlinks: [FilePath]
) -> [Mount] {
    guard
        let data = mounts.last(where: { $0.options.contains(rootDataOption) }),
        root.starts(with: data.point)
    else {
        return mounts
    }
    var table = mounts
    for mount in mounts
    where firmlinks.contains(where: { mount.point.starts(with: $0) }) {
        var alias = mount
        alias.point = data.point.appending(mount.point.components)
        table.append(alias)
    }
    return table
}

/// The system volume's firmlinks, from the list the OS itself mounts them
/// from: one `path<TAB>target` per line.
private let systemFirmlinks: [FilePath] = {
    guard
        let text = try? String(
            contentsOfFile: "/usr/share/firmlinks",
            encoding: .utf8
        )
    else {
        return []
    }
    return text.split(whereSeparator: \.isNewline).compactMap { line in
        line.split(separator: "\t").first.map { FilePath(String($0)) }
    }
}()

/// The device a path's filesystem is mounted from, such as `/dev/disk3s5`.
///
/// Asked of `statfs`, which answers for the filesystem that really holds the
/// path: the home directory is on the Data volume even though the longest
/// mount point above `/Users/kyle` is `/`. A path that does not exist yet
/// answers for its nearest existing ancestor, which is where it would be.
public func deviceFor(_ path: FilePath) -> String? {
    var candidate = path
    while !candidate.isEmpty {
        var stats = statfs()
        if candidate.withPlatformString({ statfs($0, &stats) }) == 0 {
            return cString(stats.f_mntfromname)
        }
        let parent = candidate.removingLastComponent()
        if parent == candidate {
            break
        }
        candidate = parent
    }
    return nil
}

/// Which mounted filesystem holds a path: where it is mounted and what kind
/// it is, as `statfs` names them. Not the device, which a disk image
/// attached again at the same place changes.
public struct VolumeIdentity: Sendable, Hashable {
    public var point: String
    public var type: String

    public init(point: String, type: String) {
        self.point = point
        self.type = type
    }
}

/// The filesystem holding `path`, or its nearest existing ancestor when it
/// is not there. That is how a removed directory is told from a volume that
/// went away: the parent of a removed one is still on its volume, while an
/// ejected volume leaves its mount point empty on the volume below, or
/// takes it along.
public func volumeIdentity(_ path: FilePath) -> VolumeIdentity? {
    var candidate = path
    while !candidate.isEmpty {
        var stats = statfs()
        if candidate.withPlatformString({ statfs($0, &stats) }) == 0 {
            return VolumeIdentity(
                point: cString(stats.f_mntonname),
                type: cString(stats.f_fstypename)
            )
        }
        let parent = candidate.removingLastComponent()
        if parent == candidate {
            break
        }
        candidate = parent
    }
    return nil
}

/// The source of the mount with the longest prefix of `path`, from a given
/// table: `deviceFor` without asking the kernel, for testing. It knows mount
/// points, not firmlinks.
public func deviceIn(_ mounts: [Mount], path: FilePath) -> String? {
    containingMount(mounts, path: path)?.source
}

/// The volume's name as the Finder shows it, such as `Macintosh HD`, for the
/// panel. The system and Data volumes share one name there.
public func volumeNameFor(_ path: FilePath) -> String? {
    let url = URL(filePath: path.string, directoryHint: .isDirectory)
    let values = try? url.resourceValues(forKeys: [
        .volumeLocalizedNameKey, .volumeNameKey,
    ])
    return values?.volumeLocalizedName ?? values?.volumeName
}

/// `path` with every symlink resolved, or as given when it cannot be.
func canonical(_ path: FilePath) -> FilePath {
    guard let resolved = path.withPlatformString({ realpath($0, nil) }) else {
        return path
    }
    defer { free(resolved) }
    return FilePath(platformString: resolved)
}

extension UInt64 {
    /// `self + other`, held at `.max` instead of trapping.
    ///
    /// Sizes are summed from what filesystems report, and that is not
    /// bounded by any disk: a sparse file's apparent length can be 2^55
    /// bytes on APFS, and a network or user-space filesystem can report
    /// whatever it likes. A few hundred such files overflow a 64-bit total,
    /// and a disk tool must not crash on a number it was told. The Rust
    /// original wrapped silently there instead; held at the top, a total
    /// at least says it is enormous.
    func saturatingAdding(_ other: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? .max : sum
    }

    /// `self * other`, held at `.max` instead of trapping.
    func saturatingMultiplied(by other: UInt64) -> UInt64 {
        let (product, overflow) = multipliedReportingOverflow(by: other)
        return overflow ? .max : product
    }
}
