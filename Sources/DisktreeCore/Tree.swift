// The scanned tree.

import System

/// What a node represents on disk.
public enum NodeKind: Sendable, Hashable {
    case directory
    case file
    case symlink
    /// Sockets, fifos and devices: addressable, but not space.
    case other

    public var isDir: Bool { self == .directory }
}

/// How a node's importance is measured.
public enum Metric: Sendable, Hashable {
    /// Bytes, apparent or on-disk depending on `ScanOptions`.
    case bytes
    /// Number of files at or beneath the node.
    case files

    public var label: String {
        switch self {
        case .bytes: "size"
        case .files: "files"
        }
    }

    public var toggled: Self {
        switch self {
        case .bytes: .files
        case .files: .bytes
        }
    }
}

/// `(device, inode)`: the identity hardlink de-duplication and symlink loop
/// detection both depend on.
public struct FileID: Sendable, Hashable {
    public var device: UInt64
    public var inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

/// One entry in the scanned tree.
///
/// Totals and direct figures are both kept: `ownBytes` and `ownFiles` are
/// what sits directly in a directory, `bytes` and `files` are the subtree
/// totals the treemap draws. The selection line needs both, and keeping them
/// means no second traversal when one of them is displayed.
///
/// A value type: a tree handed to another thread, or kept while a wider scan
/// reuses it, is shared copy-on-write rather than cloned.
public struct Node: Sendable {
    public var name: String
    public var kind: NodeKind
    /// Subtree total: direct contents plus every descendant.
    public var bytes: UInt64
    /// Bytes of the leaf entries directly in this directory, or this file's
    /// own size. Derived by `aggregate`.
    public var ownBytes: UInt64
    /// Files at or beneath this node; `1` for a file.
    public var files: UInt64
    /// Files directly in this directory; `1` for a file. Derived by
    /// `aggregate`.
    public var ownFiles: UInt64
    /// Directories at or beneath this node; `1` for a directory.
    public var dirs: UInt64
    /// `(device, inode)` for files, used to de-duplicate hardlinks.
    public var inode: FileID?
    /// The directory could not be read; its contents are unknown.
    public var readError: Bool
    /// Newest write time at or beneath this node, in Unix seconds; `0` when
    /// unknown. Derived for directories by `aggregate`.
    public var modified: Int64
    /// What kind of data this is, for colour. Set by `classify`.
    public var category: Category
    /// Why this space can be had back, if it can. Set by `classify`;
    /// inherited by everything beneath.
    public var reclaim: Reclaim?
    /// Children, ordered by `Metric` value, descending.
    public var children: [Node]

    public init(
        name: String,
        kind: NodeKind,
        bytes: UInt64,
        ownBytes: UInt64,
        files: UInt64,
        ownFiles: UInt64,
        dirs: UInt64,
        inode: FileID? = nil,
        readError: Bool = false,
        modified: Int64 = 0,
        category: Category = .other,
        reclaim: Reclaim? = nil,
        children: [Node] = []
    ) {
        self.name = name
        self.kind = kind
        self.bytes = bytes
        self.ownBytes = ownBytes
        self.files = files
        self.ownFiles = ownFiles
        self.dirs = dirs
        self.inode = inode
        self.readError = readError
        self.modified = modified
        self.category = category
        self.reclaim = reclaim
        self.children = children
    }

    /// A directory with no children yet.
    public static func directory(
        _ name: String,
        children: [Node] = []
    ) -> Node {
        Node(
            name: name,
            kind: .directory,
            bytes: 0,
            ownBytes: 0,
            files: 0,
            ownFiles: 0,
            dirs: 1,
            children: children
        )
    }

    /// A leaf entry.
    public static func entry(
        _ name: String,
        kind: NodeKind,
        bytes: UInt64
    ) -> Node {
        let files: UInt64 = kind == .file ? 1 : 0
        return Node(
            name: name,
            kind: kind,
            bytes: bytes,
            ownBytes: bytes,
            files: files,
            ownFiles: files,
            dirs: 0
        )
    }

    public var isDir: Bool { kind.isDir }

    /// The value a treemap should weight this node by.
    public func value(_ metric: Metric) -> UInt64 {
        switch metric {
        case .bytes: bytes
        case .files: files
        }
    }

    /// The child with this name, if there is one.
    public func childNamed(_ name: String) -> Node? {
        children.first { $0.name == name }
    }

    public func child(at index: Int) -> Node? {
        children.indices.contains(index) ? children[index] : nil
    }

    /// Follow `crumbs` from this node. Crumbs are child indices, so they stay
    /// valid across re-sorting only for the tree they were produced from.
    public func resolve(_ crumbs: [Int]) -> Node? {
        resolve(crumbs[...])
    }

    public func resolve(_ crumbs: ArraySlice<Int>) -> Node? {
        var node = self
        for index in crumbs {
            guard node.children.indices.contains(index) else { return nil }
            node = node.children[index]
        }
        return node
    }

    /// The chain of nodes ending at `crumbs`, including this node. Stops at
    /// the first crumb that does not resolve.
    public func resolveChain(_ crumbs: [Int]) -> [Node] {
        var chain = [self]
        var node = self
        for index in crumbs {
            guard node.children.indices.contains(index) else { break }
            node = node.children[index]
            chain.append(node)
        }
        return chain
    }

    /// Index of the largest child, used to pick a useful descent target.
    /// Children are sorted, so it is the first one.
    public var largestChild: Int? { children.isEmpty ? nil : 0 }

    /// Depth of the deepest descendant, in edges.
    public var depth: Int {
        children.map { $0.depth + 1 }.max() ?? 0
    }

    /// Search for the first node whose name contains `needle`
    /// (case-insensitive), returning its crumbs and the node.
    public func find(_ needle: String) -> (crumbs: [Int], node: Node)? {
        let needle = needle.lowercased()
        if needle.isEmpty {
            return nil
        }
        var queue: [([Int], Node)] = [([], self)]
        while let (crumbs, node) = queue.popLast() {
            for (index, child) in node.children.enumerated() {
                if child.name.lowercased().contains(needle) {
                    return (crumbs + [index], child)
                }
                if child.isDir && !child.children.isEmpty {
                    queue.append((crumbs + [index], child))
                }
            }
        }
        return nil
    }
}

/// Recompute `bytes`, `files`, `dirs` and the direct totals bottom-up, then
/// order children by `metric`, largest first.
///
/// `bytes` and `files` are the subtree totals; `ownBytes` and `ownFiles` are
/// the direct contents, derived from the leaf children rather than tracked
/// separately. Deriving them is what keeps the two consistent: hardlink
/// de-duplication rewrites a leaf's weight, and every total above it —
/// including its parent's "direct" figure — follows without a second pass.
public func aggregate(_ node: inout Node, metric: Metric) {
    guard node.isDir else {
        node.bytes = node.ownBytes
        node.files = node.ownFiles
        node.dirs = 0
        return
    }

    var bytes: UInt64 = 0
    var files: UInt64 = 0
    var ownBytes: UInt64 = 0
    var ownFiles: UInt64 = 0
    var dirs: UInt64 = 1
    var modified: Int64 = 0
    // Index-based so each child is mutated in place: the children array is
    // uniquely owned here, and a `for child in` copy would duplicate it.
    for index in node.children.indices {
        aggregate(&node.children[index], metric: metric)
        let child = node.children[index]
        modified = max(modified, child.modified)
        // Held at the top rather than trapping: apparent sizes are what a
        // filesystem claims, and a few hundred sparse files can claim more
        // than 64 bits hold.
        bytes = bytes.saturatingAdding(child.bytes)
        files += child.files
        dirs += child.dirs
        if !child.isDir {
            ownBytes = ownBytes.saturatingAdding(child.bytes)
            ownFiles += child.files
        }
    }
    node.bytes = bytes
    node.files = files
    node.ownBytes = ownBytes
    node.ownFiles = ownFiles
    node.dirs = dirs
    node.modified = modified

    // Largest first: a treemap lays out big tiles best, and the order is what
    // makes "descend into the largest child" meaningful. Ties break on the
    // name's bytes, not Unicode collation, so the order is the same on every
    // machine.
    node.children.sort { left, right in
        let (lhs, rhs) = (left.value(metric), right.value(metric))
        if lhs != rhs {
            return lhs > rhs
        }
        return left.name.utf8.lexicographicallyPrecedes(right.name.utf8)
    }
}

/// Absolute path of the node at `crumbs` beneath a scanned root. Stops at the
/// first crumb that does not resolve.
public func pathOf(
    rootPath: FilePath,
    root: Node,
    crumbs: [Int]
) -> FilePath {
    var path = rootPath
    var node = root
    for index in crumbs {
        guard node.children.indices.contains(index) else { break }
        node = node.children[index]
        path.append(node.name)
    }
    return path
}
