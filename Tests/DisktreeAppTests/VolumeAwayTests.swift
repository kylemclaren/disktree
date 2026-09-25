// A scanned volume ejected while marks are out, with a real disk image.
//
// Every path on an ejected volume reads as removed, and `statfs` of its
// mount point answers for the disk below it, or for nothing. Neither is a
// hand-over: the marks are still on the volume, and the difference between
// two disks' free space is no gain (Invariant 9).

import Darwin
import DisktreeCore
import Foundation
import System
import Testing

@testable import DisktreeApp

private let hdiutil = "/usr/bin/hdiutil"

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

private func attach(_ image: FilePath, at point: FilePath) -> Bool {
    run(
        hdiutil,
        [
            "attach", "-quiet", "-nobrowse", "-noverify", "-noautoopen",
            "-mountpoint", point.string, image.string,
        ]
    )
}

private func detach(_ point: FilePath) -> Bool {
    run(hdiutil, ["detach", "-quiet", point.string])
        || run(hdiutil, ["detach", "-quiet", "-force", point.string])
}

// No time limit: a main-actor test waits its turn behind every window the
// suite draws, which takes minutes on a busy run.
@MainActor
@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: hdiutil)))
func anEjectedVolumeIsNeitherGoneNorAGain() async throws {
    let images = try TempTree([])
    let outer = try TempTree([])
    let image = images.path("volume.dmg")
    let point = outer.path("volume")
    try FileManager.default.createDirectory(
        atPath: point.string,
        withIntermediateDirectories: true
    )
    let created = run(
        hdiutil,
        [
            "create", "-quiet", "-size", "4m", "-fs", "HFS+", "-layout",
            "NONE", "-volname", "disktree-away", "-o", image.string,
        ]
    )
    var mounted = created && attach(image, at: point)
    defer {
        // Never leave the image mounted inside a directory about to go:
        // the trees live until it is detached.
        if mounted {
            _ = detach(point)
        }
        withExtendedLifetime((images, outer)) {}
    }
    guard mounted else {
        try Test.cancel("hdiutil could not attach a disk image here")
    }
    let junk = point.appending("junk")
    try FileManager.default.createDirectory(
        atPath: junk.string,
        withIntermediateDirectories: true
    )
    try Data(count: 100_000).write(to: URL(filePath: "\(junk.string)/b.bin"))
    try Data(count: 1_000).write(to: URL(filePath: "\(point.string)/keep"))

    let state = try stateOver(point, hooks: Hooks())
    #expect(state.rootVolume?.type == "hfs")
    state.toggleMark(try childCrumbs(state, [], "junk"))
    await state.checkDisk()
    #expect(state.space != nil && state.spaceBaseline != nil)
    let epoch = state.scanEpoch

    // Ejected: the mount point stays behind, empty, on the disk below.
    #expect(detach(point))
    mounted = false
    await state.checkDisk()
    #expect(state.gone.isEmpty, "nothing was removed")
    #expect(state.marks.items.map(\.path) == [junk])
    #expect(state.space == nil, "the disk below is not this volume")
    #expect(state.measuredGain == nil)
    #expect(state.scanEpoch == epoch, "no hand-over, so no rescan")
    #expect(state.notice?.text.contains("not mounted") == true)
    // Scanned again, the mount point reads empty: still not a removal.
    try press(state, "r")
    try await finishScan(state)
    #expect(state.marks.items.map(\.path) == [junk])

    // The mount point went with it: the walk fails, and keeps the marks.
    try FileManager.default.removeItem(atPath: point.string)
    await state.checkDisk()
    #expect(state.gone.isEmpty && state.space == nil)
    try press(state, "r")
    try await finishScan(state)
    #expect(state.scanError != nil)
    #expect(state.marks.items.map(\.path) == [junk])

    // Back where it was: the marks are there, and nothing went.
    try FileManager.default.createDirectory(
        atPath: point.string,
        withIntermediateDirectories: true
    )
    mounted = attach(image, at: point)
    #expect(mounted)
    await state.checkDisk()
    #expect(state.notice == nil, "back, so no longer said")
    #expect(state.space != nil)
    #expect(state.gone.isEmpty)
    #expect(state.marks.items.map(\.path) == [junk])
}
