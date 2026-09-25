// What the metric changes, and what it must not.
//
// Files mode ranks and sizes the mosaic by file count; a mark is still a
// number of bytes, since the projection sums them (Invariant 9). A large
// tree is re-ranked off the main actor, with the old order on screen until
// the new one lands.

import DisktreeCore
import Foundation
import System
import Testing

@testable import DisktreeApp

@MainActor
@Test func aMarkIsBytesInFilesModeToo() throws {
    let tree = try fixture()
    let hooks = Hooks()
    let state = try stateOver(tree.root, hooks: hooks)
    // Marked in Size mode, then switched: still bytes.
    state.toggleMark(try childCrumbs(state, [], "keep"))
    try press(state, "t")
    #expect(state.options.metric == .files)
    // Marked in Files mode.
    let junk = try childCrumbs(state, [], "junk")
    state.toggleMark(junk)
    let node = try #require(state.node(at: junk))
    #expect(node.files == 2 && node.bytes == 300_000)

    let bytes = Dictionary(
        uniqueKeysWithValues: state.marks.items.map { ($0.path, $0.bytes) }
    )
    #expect(bytes[tree.path("junk")] == 300_000)
    #expect(bytes[tree.path("keep")] == 1_000)
    #expect(state.plan().bytes == 301_000)

    state.copyCommand()
    #expect(state.toast?.text.contains(humanBytes(301_000)) == true)
}

@MainActor
@Test func ageFromSettingsRanksBySizeAsThePickerDoes() throws {
    let tree = try fixture()
    let state = try stateOver(tree.root, hooks: Hooks())
    try press(state, "t")
    #expect(state.modeIndex == 1 && state.options.metric == .files)
    state.setPreference(\.colorMode, .age)
    #expect(state.colorMode == .age)
    #expect(state.options.metric == .bytes, "age keeps areas by size")
    #expect(state.modeIndex == 2)
}

/// Waits for the re-ranking in flight to land.
@MainActor
private func awaitRanking(_ state: AppState) async throws {
    for _ in 0..<2_000 where state.pendingMetric != nil {
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(state.pendingMetric == nil, "the re-ranking never landed")
}

@MainActor
@Test func aLargeTreeIsReRankedOffTheMainActor() async throws {
    let tree = try TempTree([
        ("big/one.bin", 900_000),
        ("many/a.bin", 10), ("many/b.bin", 10), ("many/c.bin", 10),
    ])
    let state = try stateOver(tree.root, hooks: Hooks())
    // Every tree counts as large here.
    state.rankInPlaceLimit = 0
    let big = try childCrumbs(state, [], "big")
    state.goTo(big)
    state.select(try childCrumbs(state, big, "one.bin"))

    try press(state, "t")
    // The picker shows the switch; the tree on screen keeps its order, and
    // everything that reads the metric reads the one it is ranked by.
    #expect(state.modeIndex == 1)
    #expect(state.pendingMetric == .files)
    #expect(state.options.metric == .bytes)
    #expect(state.node(at: [0])?.name == "big")

    try await awaitRanking(state)
    #expect(state.options.metric == .files)
    #expect(state.node(at: [0])?.name == "many", "re-ranked by files")
    #expect(state.currentPath == tree.path("big"))
    #expect(
        state.selected.flatMap { state.path(at: $0) }
            == tree.path("big/one.bin")
    )
    #expect(state.insights.allSatisfy { state.node(at: $0.crumbs) != nil })

    // Switched back before it lands: nothing lands.
    try press(state, "t")
    #expect(state.pendingMetric == .bytes && state.modeIndex == 2)
    state.setMode(1)
    #expect(state.pendingMetric == nil)
    try await Task.sleep(for: .milliseconds(100))
    #expect(state.options.metric == .files)
    #expect(state.node(at: [0])?.name == "many")
}
