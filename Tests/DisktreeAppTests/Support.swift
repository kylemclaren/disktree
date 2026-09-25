// What the state tests share: the Rust tests' fixture on disk, a state over
// a real scan of it, the shell's hooks captured instead of reaching the
// pasteboard, Finder or the app, and the loops that wait for work the state
// hands off — a walk on threads of its own, a search off the main actor.
//
// Screens are tested by their own agents over the same kind of state; these
// helpers are for driving the state the way a person does: press keys, move
// the pointer, and read what changed.

import CoreGraphics
import Darwin
import DisktreeCore
import Foundation
import System
import Testing

@testable import DisktreeApp

/// A directory under the temporary directory, removed when the value goes.
final class TempTree: Sendable {
    let root: FilePath

    /// Files at relative paths, each `count` bytes of `x`.
    init(_ files: [(path: String, count: Int)]) throws {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "disktree-state-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        root = FilePath(url.path(percentEncoded: false))
        try FileManager.default.createDirectory(
            atPath: root.string,
            withIntermediateDirectories: true
        )
        for file in files {
            try write(file.path, count: file.count)
        }
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root.string)
    }

    /// The absolute path of `relative` inside the tree.
    func path(_ relative: String) -> FilePath {
        root.appending(relative)
    }

    /// Write a file inside the tree, making its directories.
    func write(_ relative: String, count: Int) throws {
        let path = path(relative)
        try FileManager.default.createDirectory(
            atPath: path.removingLastComponent().string,
            withIntermediateDirectories: true
        )
        try Data(repeating: UInt8(ascii: "x"), count: count)
            .write(to: URL(filePath: path.string))
    }

    /// Whether the entry itself is there: a symlink counts, whatever it
    /// points at.
    func exists(_ relative: String) -> Bool {
        var info = stat()
        return lstat(path(relative).string, &info) == 0
    }
}

/// A small tree on disk: two directories, a nested file, and a hidden one.
///
/// The hidden directory holds the largest file, which is both the common
/// case in a home directory and the one the ranking has to get right.
/// `.cache` and `junk` weigh the same, so their order is the tree's
/// tie-break by name: `.cache` first.
func fixture() throws -> TempTree {
    try TempTree([
        ("keep/notes.txt", 1_000),
        ("junk/blob.bin", 200_000),
        ("junk/deeper/more.bin", 100_000),
        (".cache/blob.bin", 300_000),
    ])
}

/// Apparent sizes, so the assertions are about the tree and not about how
/// the filesystem rounds a small file up to a block.
let fixtureOptions = ScanOptions(apparentSize: true)

/// The treemap's size in these tests: a 1440×900 window, less the panel.
let treemapArea = CGSize(width: 1_100, height: 800)

/// What the state handed to the shell, captured: nothing here may write to
/// the real pasteboard, open Finder or quit the test runner.
@MainActor
final class Hooks {
    var copied: [String] = []
    var revealed: [[FilePath]] = []
    var quits = 0

    /// Point every hook of `state` here.
    func capture(_ state: AppState) {
        state.copyToPasteboard = { self.copied.append($0) }
        state.showInFinder = { self.revealed.append($0) }
        state.onQuit = { self.quits += 1 }
    }
}

/// A state over a real scan of `root`, without the background walk or the
/// tickers: what the Rust tests' `view_over` opened a window on.
@MainActor
func stateOver(
    _ root: FilePath,
    hooks: Hooks,
    depth: Int = 3
) throws -> AppState {
    let tree = try scan(root, options: fixtureOptions)
    let state = AppState(
        root: root,
        tree: tree,
        options: fixtureOptions,
        depth: depth
    )
    hooks.capture(state)
    state.treemapSize = treemapArea
    return state
}

/// Press keys in the `--keys` notation, separated by spaces. Returns
/// whether every one of them was consumed.
@MainActor
@discardableResult
func press(_ state: AppState, _ keys: String) throws -> Bool {
    var consumed = true
    for notation in keys.split(separator: " ") {
        let key = try #require(KeyStroke(parsing: String(notation)))
        consumed = state.handleKey(key) && consumed
    }
    return consumed
}

/// Type text, one key per character, as a keyboard does.
@MainActor
func typeText(_ state: AppState, _ text: String) {
    for character in text {
        let typed = String(character)
        state.handleKey(KeyStroke(typed, character: typed))
    }
}

/// Drive the walk the state started until its tree lands. The poller the
/// state runs itself may land it first; either is the same landing.
@MainActor
func finishScan(_ state: AppState) async throws {
    let epoch = state.scanEpoch
    for _ in 0..<2_000 {
        if !state.pollScanOnce(epoch: epoch) {
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("the scan never landed")
}

/// Wait for the search in flight, which runs off the main actor and lands
/// back on it.
@MainActor
func awaitSearch(_ state: AppState) async throws {
    for _ in 0..<5_000 {
        if !state.finding {
            return
        }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("the search never landed")
}

/// The crumbs of the entry named `name` directly inside `parent`.
@MainActor
func childCrumbs(
    _ state: AppState,
    _ parent: [Int],
    _ name: String
) throws -> [Int] {
    let node = try #require(state.node(at: parent), "the parent")
    let index = try #require(
        node.children.firstIndex { $0.name == name },
        "no \(name)"
    )
    return parent + [index]
}

/// The names of the nodes the layout draws, in layout order.
@MainActor
func namesDrawn(_ state: AppState) -> [String] {
    (state.layout() ?? []).compactMap { state.node(at: $0.crumbs)?.name }
}

/// The centre of a base-space rect, on screen.
@MainActor
func centre(_ state: AppState, of rect: Rect) -> CGPoint {
    let screen = state.view.project(rect)
    return CGPoint(x: screen.x + screen.w / 2, y: screen.y + screen.h / 2)
}

/// Run a copied command the way the user would: pasted into a shell. Off
/// the main actor, since waiting on a process spins a run loop.
func runInShell(_ command: String) async throws -> Int32 {
    try await Task.detached {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }.value
}

/// Drive walks until none is out: a landing that finds its tree out of
/// date starts another.
@MainActor
func settleScans(_ state: AppState) async throws {
    for _ in 0..<10 where state.scan != nil {
        try await finishScan(state)
    }
    #expect(state.scan == nil, "the walks never settled")
}

/// Preferences kept in a dictionary for the length of a test: a test must
/// never read or write the person's own defaults.
final class MemoryPreferences: PreferenceStore {
    var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? {
        values[key]
    }

    func set(_ value: Any?, forKey key: String) {
        values[key] = value
    }

    /// What is kept under `key`, by its `Preferences.Key`.
    subscript(_ key: Preferences.Key) -> Any? {
        values[key.rawValue]
    }
}
