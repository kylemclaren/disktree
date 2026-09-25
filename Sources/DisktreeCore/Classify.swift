// What a directory *is*, and whether its space can be had back.
//
// Colour in the treemap means a kind of data, and a hatch means reclaimable
// space, so the two questions a cleanup tool exists to answer — "what is it"
// and "can I delete it" — can be read off a tile at a glance.
//
// Both come from names. A short lookup of well-known directory names covers
// most of a home directory; anything unmatched takes its parent's kind, and a
// top-level directory with an unknown name takes the kind of its largest
// recognisable child (`~/world` is mostly `.git`, so it is git). Reclaimable
// space is the same idea, plus a sibling check where a name alone is too
// common to trust: `target` is only a build directory beside a `Cargo.toml`.
//
// The tables are data, and they are consulted for nearly every directory on
// a disk, so they are dictionaries: a `switch` over strings compares one case
// after another, and there are over a hundred cases.
//
// The common names already cover most of a Mac, because a name is lowercased
// before lookup: `~/Library/Caches` is `caches`, `~/Movies`, `~/Music` and
// `~/Pictures` are media, `~/.Trash` is trash. The macOS entries below add
// only what a Mac names differently and what cannot be mistaken:
//
// * `DerivedData` is Xcode's build output, wherever a project points it.
// * `.build` is SwiftPM's, and only beside a `Package.swift`, the way
//   `target` is Cargo's only beside a `Cargo.toml`.
// * `Mobile Documents` is iCloud Drive and `CloudStorage` holds the File
//   Provider sync clients (Dropbox, Google Drive, OneDrive), whose folders
//   are named per account, so `dropbox` or `google drive` never match them.
//   Synced, and never reclaimable: deleting a copy deletes it everywhere.
// * `CoreSimulator` is Xcode's simulators, as `.android` is the emulator's;
//   `Homebrew` is the package manager, as `mise` or `.nvm` are. A colour
//   only: a simulator holds the apps installed in it, and Homebrew has its
//   own `brew cleanup`.
// * `.Trashes` is the trash of a volume other than the home directory's.
//
// Left out on purpose: `Library`, `Containers` and `Application Support`
// hold every kind of app data, so no one colour would be true of them;
// `Developer` is code at `~/Developer` and tools at `~/Library/Developer`;
// `Pods` is often committed, so its name does not make it reinstallable;
// `iOS DeviceSupport` comes back only when that device is plugged in again
// and Xcode spends minutes copying its symbols, so it is not hatched as if
// the next build wrote it.
//
// For the same reason those app data folders, at the top of a scan, do not
// take their largest recognisable child's kind either. `~/Library` is mostly
// Application Support, and its largest child with a name the tables know is
// `Caches`: the rule that makes `~/world` git would paint the biggest tile of
// a Mac home directory Cache, and everything unnamed inside it with it.

/// Kinds, one group per kind. Lowercase: a name is folded before it is
/// looked up.
let categoryTable: [(category: Category, names: [String])] = [
    (
        .code,
        [
            "src", "code", "projects", "repos", "dev", "work", "workspace",
            "workspaces", "github.com", "gitlab.com", "sites", "development",
        ]
    ),
    (
        .agentScratch,
        [
            ".codex", ".claude", ".herdr", ".pi", ".cursor", ".aider",
            ".gemini", ".continue", ".windsurf", ".microsandbox", ".omp",
            ".agents", ".openai", "tries", "worktrees", "experiments",
            "scratch", "playground",
        ]
    ),
    (
        .toolchain,
        [
            ".cargo", ".rustup", ".local", ".npm", ".pnpm-store", "pnpm",
            ".bun", ".deno", "go", ".gradle", ".m2", ".platformio", "mise",
            ".mise", ".pyenv", ".nvm", ".gem", "gem", ".rbenv", ".espressif",
            ".arduino15", ".config", ".vscode", ".zig", ".rye", ".conda",
            "anaconda3", "miniconda3", ".opam", ".ghcup", ".stack", ".julia",
            ".dotnet", ".android", ".sdkman", ".volta", ".yarn", ".java",
            // macOS: Xcode's simulators, and the package manager.
            "coresimulator", "homebrew",
        ]
    ),
    (
        .synced,
        [
            "sync", "dropbox", "nextcloud", "google drive", "onedrive",
            "pclouddrive", "mega", ".stversions",
            // macOS: iCloud Drive, and the File Provider sync clients.
            "mobile documents", "cloudstorage",
        ]
    ),
    (.git, [".git"]),
    (
        .media,
        [
            "pictures", "photos", "music", "videos", "movies", "steam",
            "models", ".ollama", ".lmstudio", "games", "wineprefix",
        ]
    ),
    (
        .documents,
        [
            "documents", "desktop", "downloads", "books", "notes",
            "obsidian", "public", "templates",
        ]
    ),
    (
        .cache,
        [
            ".cache", "cache", "caches", ".ccache", ".sccache", "_cacache",
            "__pycache__", "node_modules", "trash", ".trash", "tmp", ".tmp",
            // macOS: Xcode's build output, and another volume's trash.
            "deriveddata", ".trashes",
        ]
    ),
]

/// When a name in the reclaim table holds.
enum ReclaimRule: Sendable, Hashable {
    /// Wherever it is.
    case always(Reclaim)
    /// Only beside a sibling with exactly this name: the manifest that turns
    /// a common name into a build directory.
    case beside(String, Reclaim)
    /// Only inside a directory of this kind.
    case inside(Category, Reclaim)
}

/// Reasons, one group per rule. Lowercase, like the kinds; a guarded name
/// that fails its guard is simply not reclaimable.
let reclaimTable: [(rule: ReclaimRule, names: [String])] = [
    (
        .always(.regenerable),
        [".cache", "cache", "caches", ".ccache", ".sccache", "_cacache"]
    ),
    (.always(.syncHistory), [".stversions"]),
    (.always(.packageStore), [".pnpm-store", "pnpm"]),
    (
        .always(.buildOutput),
        [
            "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache",
            ".next", ".turbo", ".parcel-cache",
            // macOS: Xcode's own name; the next build writes all of it again.
            "deriveddata",
        ]
    ),
    // Too common to trust alone: only a build directory beside a manifest.
    (.beside("Cargo.toml", .buildOutput), ["target"]),
    (.beside("Package.swift", .buildOutput), [".build"]),
    (.beside("package.json", .reinstallable), ["node_modules"]),
    // Layers and snapshots are only disposable inside sandbox state.
    (.inside(.agentScratch, .sandboxLayers), ["layers"]),
    (.inside(.agentScratch, .snapshots), ["snapshots"]),
    (.always(.trash), ["trash", ".trash", ".trashes"]),
    (.always(.temporary), ["tmp", ".tmp"]),
]

// Should a name ever be listed twice, the first entry wins; a test keeps
// every name to one entry.
private let categoryNames: [String: Category] = Dictionary(
    categoryTable.flatMap { entry in
        entry.names.map { name in (name, entry.category) }
    },
    uniquingKeysWith: { first, _ in first }
)

/// Folders that hold every kind of app data, so what fills them says nothing
/// about the rest of them. Lowercase, like the tables.
///
/// Asked only at the top of a scan, where the largest child would decide.
/// Deeper down a folder takes its parent's kind, and these names should too:
/// `library` is a common source folder, and a Unity project keeps one.
let appDataNames: Set<String> = [
    "library", "application support", "containers", "group containers",
]

private let reclaimRules: [String: ReclaimRule] = Dictionary(
    reclaimTable.flatMap { entry in
        entry.names.map { name in (name, entry.rule) }
    },
    uniquingKeysWith: { first, _ in first }
)

/// No name in the tables is longer than this. A longer name cannot match, so
/// it is not folded at all: folding a name past 15 bytes would allocate.
private let longestTableName =
    (Array(categoryNames.keys) + Array(reclaimRules.keys))
    .map(\.utf8.count).max() ?? 0

/// `byte`, with A–Z folded to a–z and everything else untouched.
@inline(__always)
func asciiLowercased(_ byte: UInt8) -> UInt8 {
    (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte | 0x20 : byte
}

/// `text` with only its ASCII letters folded.
///
/// Not `lowercased()`: Unicode case mapping folds some letters beyond ASCII
/// onto ASCII ones (the Kelvin sign becomes a `k`), so a name in no table
/// could look up as one that is. A result of 15 bytes or fewer lives inline
/// in the `String`, so a short name folds without touching the heap.
func asciiLowercased(_ text: some StringProtocol) -> String {
    let utf8 = text.utf8
    return String(unsafeUninitializedCapacity: utf8.count) { buffer in
        var count = 0
        for byte in utf8 {
            buffer[count] = asciiLowercased(byte)
            count += 1
        }
        return count
    }
}

/// `name` as the tables spell it, or `nil` when it is too long to be in one.
private func tableKey(_ name: String) -> String? {
    name.utf8.count <= longestTableName ? asciiLowercased(name) : nil
}

/// The kind a directory name announces on its own, if any.
public func categoryOfName(_ name: String) -> Category? {
    tableKey(name).flatMap { categoryNames[$0] }
}

/// Whether a directory's space can be had back, judged from its name, the
/// kind of the directory holding it, and its siblings' names.
public func reclaimOf(
    _ name: String,
    parent: Category,
    hasSibling: (String) -> Bool
) -> Reclaim? {
    guard let key = tableKey(name), let rule = reclaimRules[key] else {
        return nil
    }
    return switch rule {
    case .always(let reclaim): reclaim
    case .beside(let manifest, let reclaim):
        hasSibling(manifest) ? reclaim : nil
    case .inside(let kind, let reclaim): parent == kind ? reclaim : nil
    }
}

/// Assign a category and a reclaim reason to every node beneath `root`.
///
/// Top-down: a node's own name wins, otherwise it inherits. Reclaimable
/// space is inherited too, so everything under a cache is hatched.
public func classify(_ root: inout Node) {
    root.category = .other
    root.reclaim = nil
    // Judged first and applied after, one child at a time: the judgement
    // reads the siblings, and nothing may hold a copy of a child while it is
    // rewritten in place, or the whole subtree would be copied.
    for index in root.children.indices {
        let kind = topLevelKind(root.children[index], among: root.children)
        classifyBelow(
            &root.children[index],
            category: kind.category,
            reclaim: kind.reclaim
        )
    }
}

private func topLevelKind(
    _ child: Node,
    among siblings: [Node]
) -> (category: Category, reclaim: Reclaim?) {
    // A top-level directory with an unknown name takes the kind of its
    // largest recognisable child: `~/world` is mostly `.git`. Not app data,
    // which holds every kind: only its children that name themselves get a
    // colour. Folded in full rather than through `tableKey`, which gives up
    // on anything longer than the tables' longest name, as `application
    // support` is; once per top-level entry, the fold costs nothing.
    let appData = appDataNames.contains(asciiLowercased(child.name))
    let category =
        announcedCategory(child)
        ?? (appData ? nil : dominantChildCategory(child))
        ?? .other
    let reclaim =
        child.isDir
        ? reclaimOf(child.name, parent: .other) { wanted in
            siblings.contains { $0.name == wanted }
        }
        : nil
    return (category, reclaim)
}

private func classifyBelow(
    _ node: inout Node,
    category: Category,
    reclaim: Reclaim?
) {
    node.category = category
    node.reclaim = reclaim
    for index in node.children.indices {
        let kind = kindBeneath(
            node.children[index],
            among: node.children,
            parent: category,
            inherited: reclaim
        )
        classifyBelow(
            &node.children[index],
            category: kind.category,
            reclaim: kind.reclaim
        )
    }
}

private func kindBeneath(
    _ child: Node,
    among siblings: [Node],
    parent: Category,
    inherited: Reclaim?
) -> (category: Category, reclaim: Reclaim?) {
    // A file takes the kind of what holds it: the tables name directories,
    // and a file called `notes` or `cache` is not one.
    guard child.isDir else {
        return (parent, inherited)
    }
    let category = announcedCategory(child) ?? parent
    let reclaim =
        inherited
        ?? reclaimOf(child.name, parent: parent) { wanted in
            siblings.contains { $0.name == wanted }
        }
    return (category, reclaim)
}

/// The kind a node announces by itself: its name, or else the shape of a git
/// object store.
private func announcedCategory(_ node: Node) -> Category? {
    categoryOfName(node.name) ?? (isGitStore(node) ? .git : nil)
}

/// The kind of an unknown directory, from what fills it: the first
/// recognisable name down the largest children, a few levels deep.
private func dominantChildCategory(_ node: Node) -> Category? {
    var node = node
    // Three levels: deep enough to see through a wrapper or two
    // (`~/archive/2024/project/.git`), shallow enough that a stray name far
    // down cannot decide a whole top-level directory.
    for _ in 0..<3 {
        for child in node.children where child.isDir {
            if let category = announcedCategory(child) {
                return category
            }
        }
        // Children are ordered largest first, so this is the largest one.
        guard let largest = node.children.first(where: \.isDir) else {
            return nil
        }
        node = largest
    }
    return nil
}

/// A git object store by its shape, whatever it is called: a bare
/// repository, or a `.git` directory, has `objects`, `refs` and `HEAD`.
public func isGitStore(_ node: Node) -> Bool {
    func has(_ wanted: String) -> Bool {
        node.children.contains { $0.name == wanted }
    }
    return node.isDir && has("objects") && has("refs") && has("HEAD")
}
