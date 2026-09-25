// What git knows about a checkout, for the selection panel.
//
// Before deleting an agent worktree the question is "would anything be
// lost": uncommitted changes, stashes, commits nobody pushed. That is three
// cheap git calls, run off the main actor when a checkout is selected and
// remembered per path.
//
// On a Mac without the developer tools, `/usr/bin/git` is not git but a shim
// that answers by offering to install them, in a dialog. Selecting a
// directory must never do that, so git is looked for where Homebrew and
// installers put it too, and the shim is only used once `xcode-select -p`
// says the tools behind it are there.

import Foundation
import System

/// A checkout's state, as far as losing work is concerned.
public struct GitState: Sendable, Hashable {
    /// Paths `git status --porcelain` lists: changed, staged or untracked.
    public var changed: Int
    /// Entries `git stash list` shows: work set aside and easily forgotten.
    public var stashes: Int
    /// Commits ahead of the upstream; `nil` when there is no upstream.
    public var unpushed: Int?

    public init(changed: Int = 0, stashes: Int = 0, unpushed: Int? = nil) {
        self.changed = changed
        self.stashes = stashes
        self.unpushed = unpushed
    }

    /// Nothing would be lost by deleting it.
    public var isClean: Bool {
        changed == 0 && stashes == 0 && unpushed == 0
    }

    /// One short line: `clean, no stash`, `3 changed, 1 stash, 2 unpushed`.
    public var summary: String {
        let stash =
            switch stashes {
            case 0: "no stash"
            case 1: "1 stash"
            default: "\(stashes) stashes"
            }
        var parts = [changed == 0 ? "clean" : "\(changed) changed", stash]
        switch unpushed {
        case .some(0): break
        case .some(let count): parts.append("\(count) unpushed")
        case .none: parts.append("no upstream")
        }
        return parts.joined(separator: ", ")
    }
}

/// Whether `path` is the top of a checkout: it has a `.git` directory, or
/// the `.git` file a worktree gets.
public func isCheckout(_ path: FilePath) -> Bool {
    var info = stat()
    return lstat(path.appending(".git").string, &info) == 0
}

/// Ask git. `nil` when `path` is not a checkout or git is not installed.
///
/// Blocking: three processes run to completion, so call it off the main
/// actor.
public func gitState(_ path: FilePath) -> GitState? {
    guard isCheckout(path), let git = gitExecutable else {
        return nil
    }
    guard
        let status = runGit(git, in: path, ["status", "--porcelain=v1", "-z"])
    else {
        return nil
    }
    let changed = status.split(separator: "\0").count
    let stashes =
        runGit(git, in: path, ["stash", "list"])
        .map { $0.split(separator: "\n").count } ?? 0
    let unpushed =
        runGit(git, in: path, ["rev-list", "--count", "@{upstream}..HEAD"])
        .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return GitState(changed: changed, stashes: stashes, unpushed: unpushed)
}

/// Where git is, looked for once: a GUI app's `PATH` does not change under
/// it, and the developer tools question costs a process.
let gitExecutable: FilePath? = locateGit(
    searchPath: ProcessInfo.processInfo.environment["PATH"],
    isExecutable: { FileManager.default.isExecutableFile(atPath: $0.string) },
    developerToolsInstalled: developerToolsInstalled
)

/// The shim that stands in for the developer tools until they are
/// installed.
private let xcodeShim = FilePath("/usr/bin/git")

/// The first git in `searchPath`, then in Homebrew's and the installers'
/// directories, which the minimal `PATH` launchd gives a GUI app leaves out.
///
/// `/usr/bin/git` only counts when the developer tools behind the shim are
/// installed, and that is only asked when the shim is reached, once. A
/// relative `PATH` entry is skipped: it would be resolved against whatever
/// the working directory is, which for an app is not a choice anybody made.
func locateGit(
    searchPath: String?,
    isExecutable: (FilePath) -> Bool,
    developerToolsInstalled: () -> Bool
) -> FilePath? {
    let listed = (searchPath ?? "").split(separator: ":").map {
        FilePath(String($0))
    }
    let wellKnown: [FilePath] = ["/opt/homebrew/bin", "/usr/local/bin"]
    var seen: Set<FilePath> = []
    var toolsInstalled: Bool?
    for directory in listed + wellKnown {
        guard directory.isAbsolute, seen.insert(directory).inserted else {
            continue
        }
        let candidate = directory.appending("git")
        guard isExecutable(candidate) else {
            continue
        }
        if candidate == xcodeShim {
            let installed = toolsInstalled ?? developerToolsInstalled()
            toolsInstalled = installed
            guard installed else {
                continue
            }
        }
        return candidate
    }
    return nil
}

/// Whether `xcode-select -p` names a developer directory: asking it never
/// offers to install anything, unlike running the shim.
private func developerToolsInstalled() -> Bool {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/xcode-select")
    process.arguments = ["-p"]
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

/// Run git in `path`; its standard output when it succeeds.
func runGit(
    _ git: FilePath,
    in path: FilePath,
    _ arguments: [String]
) -> String? {
    let process = Process()
    process.executableURL = URL(filePath: git.string)
    process.arguments = ["-C", path.string] + arguments
    var environment = ProcessInfo.processInfo.environment
    // Never prompt, never page, never take a lock for the index refresh.
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let output = Pipe()
    process.standardOutput = output
    do {
        try process.run()
    } catch {
        return nil
    }
    // Read to the end before waiting: a checkout with thousands of changes
    // fills the pipe, and git would block on it while this blocks on git.
    let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0
    else {
        return nil
    }
    return String(decoding: data, as: UTF8.self)
}
