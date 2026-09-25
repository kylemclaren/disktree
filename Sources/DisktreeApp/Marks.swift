// The set of paths marked for removal.
//
// Marks are keyed by absolute path, not by tree position: the tree is
// re-scanned after a removal, and a mark must survive that (or be reported
// as gone) rather than silently pointing at a different node.

import DisktreeCore
import System

/// Marked paths, in the order they were marked.
public struct Marks: Sendable {
    private var marked: [Target] = []
    /// The same paths as `marked`, so asking whether a path is marked does
    /// not walk the list; the list alone keeps the marking order.
    private var index: Set<FilePath> = []

    public init() {}

    /// Whether exactly this path is marked; being inside a marked directory
    /// is the caller's question.
    public func contains(_ path: FilePath) -> Bool {
        index.contains(path)
    }

    /// Marked targets, in marking order.
    public var items: [Target] { marked }

    /// How many paths are marked, covered ones included: the plan, not
    /// this count, says how many will be acted on.
    public var count: Int { marked.count }

    public var isEmpty: Bool { marked.isEmpty }

    /// Mark `target`, or unmark it when it is already marked.
    ///
    /// Returns `true` when the path ended up marked.
    @discardableResult
    public mutating func toggle(_ target: Target) -> Bool {
        if index.remove(target.path) != nil {
            marked.removeAll { $0.path == target.path }
            return false
        }
        index.insert(target.path)
        marked.append(target)
        return true
    }

    /// Unmark `path`; nothing happens when it is not marked.
    public mutating func remove(_ path: FilePath) {
        if index.remove(path) != nil {
            marked.removeAll { $0.path == path }
        }
    }

    /// Unmark everything.
    public mutating func clear() {
        marked.removeAll()
        index.removeAll()
    }

    /// Re-read sizes from a freshly scanned tree, and count a mark whose
    /// path no longer exists as zero bytes, so the tally never claims space
    /// that is already gone.
    ///
    /// Bytes whatever the mosaic is ranked by: a mark's size is what the
    /// projection sums (Invariant 9), and a file count is no size.
    public mutating func refresh(rootPath: FilePath, root: Node) {
        marked = marked.map { item in
            let node = findNode(rootPath: rootPath, root: root, path: item.path)
            guard let node else {
                var gone = item
                gone.bytes = 0
                return gone
            }
            return Target(
                path: item.path,
                bytes: node.bytes,
                isDir: node.isDir,
                hidden: isHidden(item.path)
            )
        }
    }
}

/// Walk the tree to the node at an absolute path. Path components are
/// compared one at a time, so a name containing a path separator cannot
/// confuse it.
///
/// Names are compared byte for byte, as the filesystem stores them: Swift's
/// `==` treats canonically equivalent spellings as equal, and a volume that
/// keeps both spellings apart holds two different entries.
public func findNode(rootPath: FilePath, root: Node, path: FilePath) -> Node? {
    var relative = path
    guard relative.removePrefix(rootPath) else {
        return nil
    }
    var node = root
    for component in relative.components {
        let name = component.string
        guard
            let child = node.children.first(where: {
                $0.name.utf8.elementsEqual(name.utf8)
            })
        else {
            return nil
        }
        node = child
    }
    return node
}

/// A dotfile or dot-directory by name. A path that ends in `.` or `..` has
/// no name of its own, so it is not hidden.
public func isHidden(_ path: FilePath) -> Bool {
    guard let name = path.lastComponent, name.kind == .regular else {
        return false
    }
    return name.string.hasPrefix(".")
}

/// Shorten a path for display: `~` for the home directory, and the path with
/// the home prefix replaced when it is below it.
public func displayPath(_ path: FilePath, home: FilePath?) -> String {
    guard let home else {
        return path.string
    }
    var rest = path
    guard rest.removePrefix(home) else {
        return path.string
    }
    return rest.isEmpty ? "~" : "~/\(rest.string)"
}
