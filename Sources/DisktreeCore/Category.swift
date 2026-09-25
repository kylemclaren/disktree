// What a directory *is*, and whether its space can be had back: the two
// values `classify` assigns to every node. The rules that assign them live in
// Classify.swift; these are the vocabulary the tree, the layout and the
// screens share.

/// A kind of data, for colour.
///
/// Declaration order is the order the mosaic's colour tables use, so
/// `allCases` doubles as that index.
public enum Category: Sendable, Hashable, CaseIterable {
    /// Source code and checkouts.
    case code
    /// Space agents write into: worktrees, sandboxes, experiments.
    case agentScratch
    /// Compilers, package managers and their installs.
    case toolchain
    /// Folders a sync client owns.
    case synced
    /// Version-control object stores.
    case git
    /// Pictures, music, video, games and models.
    case media
    /// Documents, downloads and the desktop.
    case documents
    /// Caches and other regenerable state.
    case cache
    /// Nothing recognisable.
    case other

    /// The categories the legend lists, in its order.
    public static let legend: [Category] = [
        .code, .agentScratch, .toolchain, .synced, .git, .media, .documents,
        .cache,
    ]

    public var label: String {
        switch self {
        case .code: "Code"
        case .agentScratch: "Agent scratch"
        case .toolchain: "Toolchains"
        case .synced: "Synced"
        case .git: "Git"
        case .media: "Media"
        case .documents: "Documents"
        case .cache: "Cache"
        case .other: "Other"
        }
    }
}

/// Why a directory's space can be had back.
public enum Reclaim: Sendable, Hashable, CaseIterable {
    /// A cache: whatever wrote it will write it again.
    case regenerable
    /// A sync client's old versions of files.
    case syncHistory
    /// A package manager's content store.
    case packageStore
    /// Compiler or bundler output beside its sources.
    case buildOutput
    /// Installed dependencies beside their manifest.
    case reinstallable
    /// Container or sandbox image layers.
    case sandboxLayers
    /// Sandbox or VM snapshots.
    case snapshots
    /// Already deleted, still on disk.
    case trash
    /// Scratch space meant to be thrown away.
    case temporary

    /// The reason, as the "Worth a look" list says it.
    public var label: String {
        switch self {
        case .regenerable: "regenerable"
        case .syncHistory: "sync history"
        case .packageStore: "package store"
        case .buildOutput: "build output"
        case .reinstallable: "reinstallable"
        case .sandboxLayers: "sandbox layers"
        case .snapshots: "snapshots"
        case .trash: "trash"
        case .temporary: "temporary"
        }
    }
}
