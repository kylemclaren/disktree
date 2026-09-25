import Darwin
import Foundation
import System
import Testing

@testable import DisktreeApp

/// A fresh directory under the temporary directory; the caller discards it.
private func scratch() throws -> FilePath {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "disktree-git-\(UUID().uuidString)",
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

@Test func summariesSayWhatWouldBeLost() {
    let clean = GitState(unpushed: 0)
    #expect(clean.isClean)
    #expect(clean.summary == "clean, no stash")
    let busy = GitState(changed: 3, stashes: 1, unpushed: 2)
    #expect(!busy.isClean)
    #expect(busy.summary == "3 changed, 1 stash, 2 unpushed")
    let local = GitState()
    #expect(local.summary == "clean, no stash, no upstream")
    #expect(!local.isClean, "unpushed history could be lost")
    #expect(GitState(stashes: 4, unpushed: 0).summary == "clean, 4 stashes")
}

@Test func aCheckoutHasADotGitDirectoryOrFile() throws {
    let root = try scratch()
    defer { discard(root) }
    let plain = root.appending("plain")
    let checkout = root.appending("checkout")
    let worktree = root.appending("worktree")
    for directory in [plain, checkout, worktree] {
        try FileManager.default.createDirectory(
            atPath: directory.string,
            withIntermediateDirectories: true
        )
    }
    try FileManager.default.createDirectory(
        atPath: checkout.appending(".git").string,
        withIntermediateDirectories: true
    )
    // What `git worktree add` leaves: a file pointing at the real one.
    try Data("gitdir: /elsewhere/.git/worktrees/w\n".utf8)
        .write(to: URL(filePath: worktree.appending(".git").string))

    #expect(!isCheckout(plain))
    #expect(isCheckout(checkout))
    #expect(isCheckout(worktree))
}

@Test func readsARealCheckout() throws {
    let root = try scratch()
    defer { discard(root) }
    #expect(gitState(root) == nil, "not a checkout")
    // No git on this machine, or only the shim that would offer to install
    // the developer tools: nothing to read, and no dialog either.
    guard let git = gitExecutable, runGit(git, in: root, ["init", "-q"]) != nil
    else {
        try Test.cancel("no git on this machine")
    }
    try Data("hi".utf8).write(to: URL(filePath: root.appending("a.txt").string))
    let state = try #require(gitState(root), "a checkout")
    #expect(state.changed == 1, "one untracked file")
    #expect(state.stashes == 0)
    #expect(state.unpushed == nil, "a fresh repository has no upstream")
}

// MARK: - Finding git without the install dialog

@Test func theShimIsSkippedWithoutTheDeveloperTools() {
    let found = locateGit(
        searchPath: "/usr/bin:/bin:/usr/sbin:/sbin",
        isExecutable: { $0 == "/usr/bin/git" || $0 == "/opt/homebrew/bin/git" },
        developerToolsInstalled: { false }
    )
    #expect(found == "/opt/homebrew/bin/git", "the minimal PATH misses it")

    let nothing = locateGit(
        searchPath: "/usr/bin:/bin",
        isExecutable: { $0 == "/usr/bin/git" },
        developerToolsInstalled: { false }
    )
    #expect(nothing == nil, "never the shim alone")
}

@Test func theShimIsGitOnceTheDeveloperToolsAreThere() {
    let found = locateGit(
        searchPath: "/usr/bin:/bin",
        isExecutable: { $0 == "/usr/bin/git" || $0 == "/usr/local/bin/git" },
        developerToolsInstalled: { true }
    )
    #expect(found == "/usr/bin/git", "PATH order decides")
}

@Test func theDeveloperToolsAreAskedAboutOnlyWhenTheShimIsReached() {
    var asked = 0
    let early = locateGit(
        searchPath: "/opt/homebrew/bin:/usr/bin",
        isExecutable: { _ in true },
        developerToolsInstalled: {
            asked += 1
            return true
        }
    )
    #expect(early == "/opt/homebrew/bin/git")
    #expect(asked == 0)

    let twice = locateGit(
        searchPath: "/usr/bin:/usr/bin/:/bin",
        isExecutable: { $0 == "/usr/bin/git" },
        developerToolsInstalled: {
            asked += 1
            return false
        }
    )
    #expect(twice == nil)
    #expect(asked == 1, "once, however often the shim is listed")
}

@Test func relativePathEntriesAreIgnored() {
    let found = locateGit(
        searchPath: ".:bin::tools",
        isExecutable: { _ in true },
        developerToolsInstalled: { true }
    )
    #expect(found == "/opt/homebrew/bin/git")
    #expect(
        locateGit(
            searchPath: nil,
            isExecutable: { $0 == "/usr/local/bin/git" },
            developerToolsInstalled: { false }
        ) == "/usr/local/bin/git",
        "no PATH at all"
    )
}
