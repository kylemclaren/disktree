// What the command line asked for: the directory to scan, how to measure it,
// and how many levels to draw.
//
// Read before any window exists, so a mistyped option is a message on stderr
// and exit status 2 rather than a window open on the wrong thing. `--help`
// prints to stdout and exits 0, like any other command.
//
// Two flags are left out of the usage on purpose: `--snapshot FILE.png`
// renders the window to a PNG once the first scan lands and exits, and
// `--keys "space c"` presses keys through the dispatcher first. They are for
// looking at the app from a script, which is how its screens are checked
// without a person at the keyboard.

import Darwin
import DisktreeCore
import Foundation
import System

/// What the command line asked for.
struct Arguments: Sendable, Hashable {
    /// The directory to scan, canonical, so a later widening recognises this
    /// tree in the wider walk.
    var root: FilePath
    var options: ScanOptions
    /// How many levels to draw at once. A display choice rather than a scan
    /// option: the run-time `[` and `]` keys change it too.
    var depth: Int
    /// Render the window here once the first scan lands, then exit.
    var snapshot: FilePath?
    /// Pressed through the dispatcher once the first scan lands.
    var keys: [KeyStroke]

    /// A script is driving: it sees the app as it ships, reads none of the
    /// person's preferences and saves none.
    var isScripted: Bool { snapshot != nil || !keys.isEmpty }
}

/// What `disktree` was asked to do.
enum Invocation: Sendable, Hashable {
    /// `-h`/`--help`: print `usage` and exit.
    case help
    /// Open the window.
    case run(Arguments)
}

/// A command line that cannot be acted on. The message is what is printed.
struct UsageError: Error, Sendable, Hashable, CustomStringConvertible {
    var message: String

    init(_ message: String) {
        self.message = message
    }

    var description: String { message }
}

/// `--help`. The hidden developer flags are not in it.
let usage = """
    disktree — a treemap of what is using your disk

    usage: disktree [OPTIONS] [PATH]

    arguments:
      PATH              directory to scan (default: the home directory)

    The window opens on a treemap of the root, largest first. Space marks the
    selected tile, Enter opens it, c reviews the marked list, ? lists every key.

    disktree never deletes anything itself: the review hands the marked list
    to Finder, or copies a command that removes it for you to run in a
    terminal, then measures what the disk gained.

    options:
      -a, --apparent-size   measure apparent length instead of allocated blocks
          --disk-usage      measure allocated blocks
      -l, --follow-links    follow symlinks
      -H, --no-hidden       skip dotfiles and dot-directories
          --hidden          include dotfiles and dot-directories
      -D, --disk            scan the whole disk the home directory is on
      -X, --cross-filesystems
                            also measure other disks, network shares and system
                            volumes mounted below PATH
      -x, --one-filesystem  stay on the volume PATH is on
      -d, --depth N         how many levels to draw at once (1-6)
          --metric files    rank by file count instead of bytes
      -h, --help            show this help

    Without a flag, each of these is what Settings keeps: as shipped, disk
    usage, hidden files included, one volume and 3 levels. A flag changes it
    for this run only.
    """

/// The depths the treemap can draw at once: one level is a list of boxes,
/// and past six the tiles are too small to read.
let depthRange = 1...6

/// Read the command line, without the program name.
///
/// `home` is where a scan starts when no path is given, and whose disk
/// `--disk` scans; the environment's unless a test says otherwise.
/// `preferences` are what the flags override for the run: the saved ones,
/// or the app as it ships.
func parseArguments(
    _ arguments: [String],
    home: FilePath? = defaultHome(),
    preferences: Preferences = Preferences()
) throws(UsageError) -> Invocation {
    var root: FilePath?
    var options = preferences.scanOptions
    var depth = preferences.depth
    var disk = false
    var snapshot: FilePath?
    var keys: [KeyStroke] = []
    var rest = arguments[...]

    func value(_ option: String, _ what: String) throws(UsageError) -> String {
        guard let value = rest.popFirst() else {
            throw UsageError("\(option) needs \(what)")
        }
        return value
    }

    while let argument = rest.popFirst() {
        switch argument {
        case "-h", "--help":
            return .help
        case "-a", "--apparent-size":
            options.apparentSize = true
        // The way back to what ships, for a run, when Settings keeps the
        // other.
        case "--disk-usage":
            options.apparentSize = false
        case "--hidden":
            options.includeHidden = true
        case "-l", "--follow-links":
            options.followLinks = true
        case "-H", "--no-hidden":
            options.includeHidden = false
        // Staying on one volume is the default; the flag is kept so old
        // invocations still work.
        case "-x", "--one-filesystem":
            options.oneFilesystem = true
        case "-X", "--cross-filesystems":
            options.oneFilesystem = false
        case "-D", "--disk":
            disk = true
        case "-d", "--depth":
            // Unsigned, as the Rust parsed it: `-1` is not a number of
            // levels, where `0` is one that is out of range.
            guard let levels = UInt32(try value("--depth", "a number")) else {
                throw UsageError("--depth needs a number")
            }
            guard depthRange.contains(Int(levels)) else {
                throw UsageError("--depth must be 1 to 6")
            }
            depth = Int(levels)
        case "--metric":
            options.metric =
                switch try value("--metric", "a value") {
                case "files": .files
                case "bytes", "size": .bytes
                case let other:
                    throw UsageError(
                        "unknown metric \(other); try bytes or files"
                    )
                }
        case "--snapshot":
            snapshot = absolute(FilePath(try value("--snapshot", "a file")))
        case "--keys":
            keys = try parseKeys(try value("--keys", "a list of keys"))
        // A Mac started from the Finder on older systems adds its process
        // serial number; it is not the user's to be refused.
        case let serial where serial.hasPrefix("-psn_"):
            continue
        case let other where other.hasPrefix("-"):
            throw UsageError("unknown option \(other)\n\n\(usage)")
        case let path:
            guard root == nil else {
                throw UsageError("only one path can be scanned")
            }
            root = FilePath(path)
        }
    }

    if disk && root != nil {
        throw UsageError("--disk and a PATH cannot be combined")
    }
    let chosen: FilePath
    if disk {
        chosen = home.flatMap(volumeRootFor) ?? "/"
    } else if let root {
        chosen = root
    } else if let home {
        chosen = home
    } else {
        throw UsageError("no path given and HOME is not set")
    }
    return .run(
        Arguments(
            root: try scannableDirectory(chosen),
            options: options,
            depth: depth,
            snapshot: snapshot,
            keys: keys
        )
    )
}

/// `--keys`: the notation the tests use, separated by spaces.
private func parseKeys(_ list: String) throws(UsageError) -> [KeyStroke] {
    var keys: [KeyStroke] = []
    for word in list.split(whereSeparator: \.isWhitespace) {
        guard let key = KeyStroke(parsing: String(word)) else {
            throw UsageError("--keys: \(word) is not a key")
        }
        keys.append(key)
    }
    return keys
}

/// `path` canonical and checked: a directory this process can read the
/// metadata of.
///
/// Canonical, so a later widening recognises this tree in the wider walk:
/// `/tmp` is `/private/tmp` to the scanner and to the mount table.
func scannableDirectory(_ path: FilePath) throws(UsageError) -> FilePath {
    let root = canonicalPath(path) ?? path
    var info = stat()
    guard root.withPlatformString({ stat($0, &info) }) == 0 else {
        let reason = String(cString: strerror(errno))
        throw UsageError("cannot read \(root.string): \(reason)")
    }
    guard info.st_mode & S_IFMT == S_IFDIR else {
        throw UsageError("\(root.string) is not a directory")
    }
    return root
}

/// `path` with every symlink resolved, or `nil` when it cannot be, as when
/// it does not exist.
func canonicalPath(_ path: FilePath) -> FilePath? {
    guard let resolved = path.withPlatformString({ realpath($0, nil) }) else {
        return nil
    }
    defer { free(resolved) }
    return FilePath(platformString: resolved)
}

/// `path` against the working directory, so a snapshot lands where the
/// command line meant whatever the app's own working directory becomes.
private func absolute(_ path: FilePath) -> FilePath {
    path.isAbsolute
        ? path
        : FilePath(FileManager.default.currentDirectoryPath).pushing(path)
}
