// Free space, the mount table, and which volume a scan measures.
//
// The Rust fixtures were Omarchy's `/proc/self/mounts`; here they are
// written the way `mount(8)` prints a table, which is what `parseMounts`
// reads, so the rules they pinned down — subvolumes of one disk are one
// volume, snapshots are not — still hold. Beside them, a Mac's own table:
// a sealed system volume at `/`, the Data volume behind firmlinks, and the
// volumes a scan of `/` must leave out.

import Darwin
import Foundation
import System
import Testing

@testable import DisktreeCore

// MARK: - Fixtures

/// The Rust fixture, in `mount(8)`'s words.
private let omarchy = """
    sys on /sys (sysfs, rw)
    run on /run (tmpfs, rw)
    /dev/mapper/root on / (btrfs, rw, subvolid=256, subvol=/@)
    /dev/mapper/root on /home (btrfs, rw, subvolid=257, subvol=/@home)
    /dev/mapper/root on /var/log (btrfs, rw, subvolid=258, subvol=/@log)
    /dev/mapper/root on /.snapshots (btrfs, rw, subvolid=260, subvol=/@snapshots)
    /dev/nvme0n1p1 on /boot (vfat, rw)
    systemd-1 on /mnt/nas-home (autofs, rw, direct)
    tmpfs on /tmp (tmpfs, rw)
    portal on /run/user/1000/doc (fuse.portal, rw)
    """

/// A standard Mac, as `mount` printed it on the machine this was ported on,
/// plus an external disk, a network share and a Time Machine snapshot.
private let mac = """
    /dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)
    devfs on /dev (devfs, local, nobrowse)
    /dev/disk3s6 on /System/Volumes/VM (apfs, local, noexec, journaled, noatime, nobrowse)
    /dev/disk3s2 on /System/Volumes/Preboot (apfs, local, journaled, nobrowse)
    /dev/disk3s4 on /System/Volumes/Update (apfs, local, journaled, nobrowse)
    /dev/disk1s2 on /System/Volumes/xarts (apfs, local, noexec, journaled, noatime, nobrowse)
    /dev/disk1s1 on /System/Volumes/iSCPreboot (apfs, local, journaled, nobrowse)
    /dev/disk1s3 on /System/Volumes/Hardware (apfs, local, journaled, nobrowse)
    /dev/disk3s5 on /System/Volumes/Data (apfs, local, journaled, nobrowse, protect, root data)
    map auto_home on /System/Volumes/Data/home (autofs, automounted, nobrowse)
    /dev/disk7s1 on /Library/Developer/CoreSimulator/Volumes/iOS_22C150 (apfs, sealed, local, nodev, nosuid, read-only, journaled, noatime, nobrowse)
    /dev/disk4s1 on /Volumes/Backup (apfs, local, journaled)
    //kyle@nas._smb._tcp.local/home on /Volumes/home (smbfs, nodev, nosuid, mounted by kyle)
    com.apple.TimeMachine.2025-09-20-101500.local@/dev/disk3s5 on /Volumes/com.apple.TimeMachine.localsnapshots/Backups.backupdb/Mac/2025-09-20-101500/Data (apfs, local, read-only, journaled, nobrowse)
    """

private func paths(_ strings: [String]) -> [FilePath] {
    strings.map { FilePath($0) }
}

private func sorted(_ paths: [FilePath]) -> [FilePath] {
    paths.sorted { $0.string < $1.string }
}

// MARK: - Ported from space.rs

@Test func aVolumeIncludesItsSubvolumesAndNothingElse() {
    let mounts = parseMounts(omarchy)
    let foreign = sorted(foreignMounts(mounts, root: "/"))
    let expected = paths([
        "/.snapshots",
        "/boot",
        "/mnt/nas-home",
        "/run",
        "/run/user/1000/doc",
        "/sys",
        "/tmp",
    ])
    #expect(foreign == expected, "/home and /var/log are the same disk")
}

@Test func theWholeDiskIsTheTopOfTheHomeVolume() {
    let mounts = parseMounts(omarchy)
    #expect(
        volumeRoot(mounts, path: "/home/tobi") == "/",
        "@home is on the root disk"
    )
    let separate = parseMounts(
        """
        /dev/sda1 on / (ext4, rw)
        /dev/sdb1 on /home (ext4, rw)
        """
    )
    #expect(
        volumeRoot(separate, path: "/home/tobi") == "/home",
        "a separate home disk"
    )
}

@Test func aHomeScanHasNoForeignMountsHere() {
    #expect(foreignMounts(parseMounts(omarchy), root: "/home/tobi").isEmpty)
    #expect(foreignMounts(parseMounts(mac), root: "/Users/kyle").isEmpty)
}

@Test func theDeviceIsTheLongestMatchingMount() {
    let mounts = parseMounts(
        """
        /dev/nvme0n1p2 on / (btrfs, rw)
        tmpfs on /tmp (tmpfs, rw)
        /dev/sda1 on /home/tobi/big disk (ext4, rw)
        """
    )
    #expect(deviceIn(mounts, path: "/home/tobi") == "/dev/nvme0n1p2")
    #expect(deviceIn(mounts, path: "/tmp/x") == "tmpfs")
    #expect(
        deviceIn(mounts, path: "/home/tobi/big disk/a") == "/dev/sda1",
        "spaces in mount points"
    )
    #expect(
        deviceIn(mounts, path: "/home/tobi/big diskette") == "/dev/nvme0n1p2",
        "a mount point is a whole component, not a prefix of one"
    )
}

@Test func aRealVolumeReportsPlausibleNumbers() throws {
    let temp = FilePath(FileManager.default.temporaryDirectory.path())
    let space = try spaceInfo(temp)
    #expect(space.total > 0, "\(space)")
    #expect(space.free <= space.total, "\(space)")
    #expect(space.available <= space.free, "\(space)")
    #expect((0.0...1.0).contains(space.usedFraction), "\(space)")
}

@Test func aMissingPathReportsTheIoError() {
    let error = #expect(throws: SpaceError.self) {
        try spaceInfo("/definitely/not/here")
    }
    #expect(error?.code == ENOENT)
    #expect(error?.path == "/definitely/not/here")
}

@Test func projectingRemovalCannotExceedTheVolume() {
    let space = SpaceInfo(total: 1000, free: 100, available: 100)
    let after = space.afterRemoving(50)
    #expect(after.available == 150)
    #expect(after.free == 150)
    #expect(after.total == 1000)

    let capped = space.afterRemoving(10_000)
    #expect(capped.available == 1000)
    #expect(capped.used == 0)
    #expect(capped.usedFraction == 0)

    let huge = space.afterRemoving(.max)
    #expect(huge.free == 1000, "saturates rather than wrapping")
}

@Test func usedFractionHandlesAnEmptyVolumeReport() {
    let space = SpaceInfo(total: 0, free: 0, available: 0)
    #expect(space.usedFraction == 0)
    #expect(space.used == 0)
}

// MARK: - The mount(8) format

@Test func mountOutputIsParsedEvenWithSpaces() throws {
    let mounts = parseMounts(
        """
        map auto_home on /System/Volumes/Data/home (autofs, automounted, nobrowse)
        /dev/disk5s1 on /Volumes/My Disk (apfs, local, nodev, nosuid, journaled, noowners)
        /dev/disk6s1 on /Volumes/Disk (2) (msdos, local, nodev, nosuid, noowners)
        /dev/disk8s1 on /Volumes/Live on Stage (hfs, local, journaled)
        //kyle@nas._smb._tcp.local/home on /Volumes/home (smbfs, nodev, nosuid, mounted by kyle)

        not a mount line
        /dev/disk9 on /Volumes/no options
        """
    )
    #expect(mounts.count == 5, "the malformed lines are skipped")
    let home = try #require(mounts.first)
    #expect(home.source == "map auto_home")
    #expect(home.point == "/System/Volumes/Data/home")
    #expect(home.fstype == "autofs")
    #expect(home.options == ["automounted", "nobrowse"])

    let points = mounts.dropFirst().map(\.point.string)
    #expect(
        points == [
            "/Volumes/My Disk",
            "/Volumes/Disk (2)",
            "/Volumes/Live on Stage",
            "/Volumes/home",
        ]
    )
    #expect(mounts[2].fstype == "msdos")
    #expect(mounts[3].source == "/dev/disk8s1")
    #expect(mounts[4].source == "//kyle@nas._smb._tcp.local/home")
    #expect(mounts[4].options.last == "mounted by kyle")
}

// MARK: - A Mac's volumes

@Test func aScanOfTheWholeMacLeavesOutEveryOtherVolume() {
    let foreign = sorted(foreignMounts(parseMounts(mac), root: "/"))
    let expected = paths([
        "/Library/Developer/CoreSimulator/Volumes/iOS_22C150",
        "/System/Volumes/Data",
        "/System/Volumes/Data/home",
        "/System/Volumes/Hardware",
        "/System/Volumes/Preboot",
        "/System/Volumes/Update",
        "/System/Volumes/VM",
        "/System/Volumes/iSCPreboot",
        "/System/Volumes/xarts",
        "/Volumes/Backup",
        "/Volumes/com.apple.TimeMachine.localsnapshots/Backups.backupdb"
            + "/Mac/2025-09-20-101500/Data",
        "/Volumes/home",
        "/dev",
    ])
    #expect(foreign == expected)
    // The Data volume's contents are reached through the firmlinks, which
    // are directories of `/`, not mount points: they are walked.
    for firmlinked in ["/Users", "/Applications", "/Library", "/private"] {
        #expect(!foreign.contains(FilePath(firmlinked)), "\(firmlinked)")
    }
}

@Test func theHomeDirectoryIsOnTheDiskAtTheRoot() {
    let mounts = parseMounts(mac)
    // Reached through the `/Users` firmlink, so the disk is `/`, and "the
    // whole disk" is a scan of `/`.
    #expect(volumeRoot(mounts, path: "/Users/kyle") == "/")
    // The table knows mount points, not firmlinks: it names the system
    // volume here, which is why `deviceFor` asks `statfs` instead.
    #expect(deviceIn(mounts, path: "/Users/kyle") == "/dev/disk3s1s1")
    #expect(
        volumeRoot(mounts, path: "/System/Volumes/Data/Users/kyle")
            == "/System/Volumes/Data"
    )
}

@Test func anExternalDiskIsItsOwnVolume() {
    let mounts = parseMounts(mac)
    let photos = FilePath("/Volumes/Backup/photos")
    #expect(volumeRoot(mounts, path: photos) == "/Volumes/Backup")
    #expect(foreignMounts(mounts, root: "/Volumes/Backup").isEmpty)
    #expect(deviceIn(mounts, path: photos) == "/dev/disk4s1")
    #expect(
        deviceIn(mounts, path: "/Volumes/Backup2") == "/dev/disk3s1s1",
        "a sibling whose name starts the same is not inside it"
    )
}

@Test func snapshotsAreLeftOutEvenFromTheSameSource() {
    let mounts = parseMounts(
        """
        /dev/disk3s5 on / (apfs, local, journaled)
        /dev/disk3s5 on /mnt/before (apfs, local, read-only, snapshot)
        snap-1@/dev/disk3s5 on /mnt/snap (apfs, local, read-only)
        /dev/disk3s5 on /mnt/same (apfs, local, journaled)
        """
    )
    let foreign = sorted(foreignMounts(mounts, root: "/"))
    #expect(foreign == paths(["/mnt/before", "/mnt/snap"]))
}

@Test func firmlinkAliasesOnlyApplyInsideTheDataVolume() {
    let mounts = parseMounts(mac)
    let firmlinks = paths(["/Applications", "/Library", "/Users", "/Volumes"])

    let fromRoot = withFirmlinkAliases(mounts, root: "/", firmlinks: firmlinks)
    #expect(fromRoot.map(\.point) == mounts.map(\.point))

    let data = FilePath("/System/Volumes/Data")
    let aliased = withFirmlinkAliases(mounts, root: data, firmlinks: firmlinks)
    let foreign = sorted(foreignMounts(aliased, root: data))
    #expect(
        foreign
            == paths([
                "/System/Volumes/Data/Library/Developer/CoreSimulator"
                    + "/Volumes/iOS_22C150",
                "/System/Volumes/Data/Volumes/Backup",
                "/System/Volumes/Data/Volumes/com.apple.TimeMachine"
                    + ".localsnapshots/Backups.backupdb/Mac"
                    + "/2025-09-20-101500/Data",
                "/System/Volumes/Data/Volumes/home",
                "/System/Volumes/Data/home",
            ])
    )
}

@Test func foreignMountsAreSpelledTheWayTheWalkSpellsItsRoot() {
    let walked = relocate(
        paths(["/private/var/folders/x/mount", "/elsewhere"]),
        from: "/private/var/folders/x",
        to: "/var/folders/x"
    )
    #expect(walked == paths(["/var/folders/x/mount", "/elsewhere"]))
    let same = relocate(paths(["/a/b"]), from: "/a", to: "/a")
    #expect(same == paths(["/a/b"]))
}

// MARK: - This machine

/// Not one of the disk images tests attach under the temporary directory,
/// which may come and go between two reads of the table.
private func isSettled(_ mount: Mount) -> Bool {
    !mount.point.string.contains("disktree-")
}

/// The live table read through `getmntinfo` against `mount(8)` reading the
/// same kernel table: the same mounts, sources and types, and the flags
/// both know by the same name.
@Test func theLiveTableReadsLikeMount() throws {
    let process = Process()
    process.executableURL = URL(filePath: "/sbin/mount")
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let text = String(
        decoding: output.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    )
    process.waitUntilExit()

    let printed = parseMounts(text).filter(isSettled)
    let live = try #require(currentMounts()).filter(isSettled)
    #expect(live.map(\.point) == printed.map(\.point))
    for (ours, theirs) in zip(live, printed) {
        #expect(ours.source == theirs.source, "\(ours.point)")
        #expect(ours.fstype == theirs.fstype, "\(ours.point)")
        for flag in ["read-only", "nobrowse", "automounted", "root data"] {
            #expect(
                ours.options.contains(flag) == theirs.options.contains(flag),
                "\(flag) on \(ours.point)"
            )
        }
    }
}

/// On a standard Mac — a system volume at `/` and a Data volume behind it —
/// the home directory's disk is `/`, and a scan of `/` walks `/Users`
/// through its firmlink while leaving the Data volume's own mount point
/// out, or it would count the disk twice.
@Test func thisMacIsMeasuredFromTheSystemVolume() throws {
    let mounts = try #require(currentMounts())
    guard let data = mounts.first(where: { $0.options.contains("root data") })
    else {
        return
    }
    let home = FilePath(NSHomeDirectory())
    #expect(volumeRootFor(home) == "/")
    let foreign = try #require(foreignMountsFor("/"))
    #expect(foreign.contains(data.point))
    #expect(foreign.contains("/dev"))
    #expect(!foreign.contains("/Users"))
    #expect(foreignMountsFor(home)?.isEmpty == true)
    #expect(deviceFor(home) == data.source, "statfs sees through firmlinks")
    #expect(deviceFor("/") != deviceFor(home))
    #expect(volumeNameFor("/")?.isEmpty == false)
    #expect(volumeNameFor(home) == volumeNameFor("/"), "one name for both")
}

/// What the walk asks of a mount the table did not list: which filesystem
/// holds a path, named as the table names it, and judged by the same rule.
@Test func theFilesystemHoldingAPathIsJudgedAsTheTableWould() throws {
    let temp = FilePath(FileManager.default.temporaryDirectory.path())
    let system = try #require(mountHolding("/"))
    let here = try #require(temp.withPlatformString(mountHolding))
    #expect(here.source == deviceFor(temp))
    #expect(!isForeign(here, to: here))
    let table = try #require(currentMounts())
    #expect(table.contains { $0.point == system.point })

    // On a standard Mac the temporary directory is on the Data volume,
    // which is another volume than the system one by `statfs`.
    if table.contains(where: { $0.options.contains("root data") }) {
        #expect(system.point == "/")
        #expect(isForeign(here, to: system))
    }

    // A snapshot of the very same volume is another all the same, but a
    // snapshot is no other volume to itself: the sealed system volume is
    // mounted as one.
    var snapshot = here
    snapshot.options.append("snapshot")
    #expect(isForeign(snapshot, to: here))
    #expect(!isForeign(snapshot, to: snapshot))
    #expect(!isForeign(system, to: system))
    #expect(mountHolding("/definitely/not/here") == nil)
}

@Test func aPathNotThereYetIsOnItsParentsDevice() throws {
    let temp = FilePath(FileManager.default.temporaryDirectory.path())
    let device = try #require(deviceFor(temp))
    #expect(device.hasPrefix("/dev/"))
    #expect(deviceFor(temp.appending("not/there/yet")) == device)
}
