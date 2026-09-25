// Widening: `g`, or a step above the root in the trail, walks the wider
// root and reuses the tree on screen where it reaches it. What the reused
// walk found must still be reported as a fresh walk would report it.

import Darwin
import DisktreeCore
import Foundation
import System
import Testing

@testable import DisktreeApp

/// `g` widens by reusing the tree on screen; what its walk could not read
/// is still counted, and still names its reason, so the note under the
/// mosaic and the way to Full Disk Access say what a fresh scan would.
@MainActor
@Test func wideningKeepsTheUnreadableCount() async throws {
    let tree = try TempTree([("inner/a.bin", 10), ("inner/locked/b.bin", 10)])
    let locked = tree.path("inner/locked")
    defer { chmod(locked.string, 0o700) }
    try #require(chmod(locked.string, 0) == 0)
    let readable = opendir(locked.string).map { closedir($0) } != nil
    try #require(!readable, "the permission bits are bypassed here")

    let inner = try #require(canonicalPath(tree.path("inner")))
    let state = try stateOver(inner, hooks: Hooks())
    state.diskRoot = inner.removingLastComponent()
    state.startScan()
    try await finishScan(state)
    #expect(state.progress.errors == 1)
    let reason = try #require(state.progress.messages.first)

    try press(state, "g")
    try await finishScan(state)
    #expect(state.rootPath == inner.removingLastComponent())
    #expect(state.progress.errors == 1)
    #expect(state.progress.messages == [reason])
}
