// Typeahead filtering: which parts of a tree match a name.
//
// A node whose name contains the needle (ignoring ASCII case) matches, and
// is kept whole: everything under a matching directory goes with it. Its
// ancestors are kept only partly, and sized by what matched beneath them,
// so a filtered treemap shows exactly the matches, at their true relative
// sizes, in the places they live.
//
// Names are compared as UTF-8 bytes, read where they already are. Beyond
// ASCII a Mac adds a wrinkle: APFS keeps a name in whatever form it was
// handed, and Foundation — so Finder, and most apps — hands it decomposed,
// while a POSIX call hands it as given and a needle typed on a keyboard is
// precomposed. A typed `café` would never find the folder Finder called
// `Café Photos`. So the needle is searched as typed and in both canonical
// forms, and a name matches if it holds any of them. Only the needle is
// normalized, once per search: normalizing every name would cost an
// allocation per name, on every keystroke. An ASCII needle has one form, and
// costs one pass, as before.

import Foundation

/// How a node takes part in a filtered view.
public enum Keep: Sendable, Hashable {
    /// It matches: drawn as usual, with everything beneath it.
    case whole
    /// It holds matches: drawn with only those, at their size.
    case partial(bytes: UInt64, files: UInt64)
}

/// The outcome of filtering a subtree by name.
public struct Matches: Sendable, Equatable {
    /// The needle, lowercased.
    public var needle: String
    /// Absolute crumbs of the subtree that was searched.
    public var base: [Int]
    /// Keyed by absolute crumbs. Only matches and their ancestors appear;
    /// a match's own descendants are implied, so ask `keep(_:)` about a
    /// node rather than looking it up here.
    public var kept: [[Int]: Keep]
    /// Topmost matches: a match inside a match is not counted again.
    public var count: Int
    /// Bytes that matched beneath the base: the value the base is laid out
    /// by when the metric is bytes.
    public var bytes: UInt64
    /// Files that matched beneath the base: the value the base is laid out
    /// by when the metric is files.
    public var files: UInt64

    /// A search's outcome as it stands; `filter` fills in the rest.
    public init(
        needle: String,
        base: [Int],
        kept: [[Int]: Keep] = [:],
        count: Int = 0,
        bytes: UInt64 = 0,
        files: UInt64 = 0
    ) {
        self.needle = needle
        self.base = base
        self.kept = kept
        self.count = count
        self.bytes = bytes
        self.files = files
    }

    /// How the node at `crumbs` takes part: `nil` when it is filtered out.
    /// Anything outside the searched subtree, and anything beneath a match,
    /// is kept whole.
    public func keep(_ crumbs: [Int]) -> Keep? {
        guard crumbs.starts(with: base) else {
            return .whole
        }
        // One prefix, grown a crumb at a time, instead of a fresh key per
        // level: this runs for every tile of a filtered frame.
        var prefix = base
        prefix.reserveCapacity(crumbs.count)
        for length in base.count...crumbs.count {
            if length > base.count {
                prefix.append(crumbs[length - 1])
            }
            let found = kept[prefix]
            switch found {
            case .whole?:
                return .whole
            case .partial? where length == crumbs.count:
                return found
            // Only the base may be absent: it holds the matches but is not
            // recorded, being where the search started.
            case nil where length > base.count:
                return nil
            default:
                continue
            }
        }
        // The base itself holds the matches.
        return .partial(bytes: bytes, files: files)
    }

    /// The value a kept node is laid out by.
    public static func value(
        _ keep: Keep,
        node: Node,
        metric: Metric
    ) -> UInt64 {
        switch (keep, metric) {
        case (.whole, _): node.value(metric)
        case (.partial(let bytes, _), .bytes): bytes
        case (.partial(_, let files), .files): files
        }
    }
}

/// Search `node`, found at absolute `base`, for names containing `needle`.
/// `nil` for an empty needle: nothing is filtered.
public func filter(_ node: Node, base: [Int], needle: String) -> Matches? {
    let typed = trimmingWhitespace(needle)
    let needle = asciiLowercased(typed)
    if needle.isEmpty {
        return nil
    }
    let needles = needleForms(typed)
    var walk = Walk()
    var crumbs = base
    let total = visit(node, crumbs: &crumbs, needles: needles, walk: &walk)
    // Made a map once, at its final size. Grown a key at a time it would
    // rehash every path so far at each growth, and a one-letter needle over
    // a whole disk keeps millions of them: this is several times faster.
    // Each path is visited once, so no key repeats; the first would win.
    return Matches(
        needle: needle,
        base: base,
        kept: Dictionary(walk.kept, uniquingKeysWith: { first, _ in first }),
        count: walk.count,
        bytes: total.bytes,
        files: total.files
    )
}

/// What a walk has kept so far, in the order it found it.
private struct Walk {
    var kept: [([Int], Keep)] = []
    var count = 0
}

/// Returns the bytes and files that matched at or beneath `node`'s
/// children, recording what to keep.
private func visit(
    _ node: Node,
    crumbs: inout [Int],
    needles: [[UInt8]],
    walk: inout Walk
) -> (bytes: UInt64, files: UInt64) {
    var total: (bytes: UInt64, files: UInt64) = (0, 0)
    for (index, child) in node.children.enumerated() {
        crumbs.append(index)
        if name(child.name, holdsAny: needles) {
            walk.kept.append((crumbs, .whole))
            walk.count += 1
            total.bytes = total.bytes.saturatingAdding(child.bytes)
            total.files += child.files
        } else if !child.children.isEmpty {
            let found = visit(
                child,
                crumbs: &crumbs,
                needles: needles,
                walk: &walk
            )
            if found.bytes > 0 || found.files > 0 {
                walk.kept.append(
                    (crumbs, .partial(bytes: found.bytes, files: found.files))
                )
                total.bytes = total.bytes.saturatingAdding(found.bytes)
                total.files += found.files
            }
        }
        crumbs.removeLast()
    }
    return total
}

/// `text` without leading or trailing whitespace, Unicode's definition of
/// it, as a typed needle may carry a stray space from either end.
private func trimmingWhitespace(_ text: String) -> Substring {
    var trimmed = Substring(text)
    while trimmed.first?.isWhitespace == true {
        trimmed.removeFirst()
    }
    while trimmed.last?.isWhitespace == true {
        trimmed.removeLast()
    }
    return trimmed
}

/// The byte strings a typed needle is searched as: as typed, precomposed
/// and decomposed, each with its ASCII folded, and each only once.
///
/// Normalized before it is folded, so a decomposed capital (`É` is an `E`
/// and an accent) folds like the ASCII letter it is. Kept apart as bytes:
/// as `String`s the forms are equal, and the decomposed one would be lost.
/// The form as typed stays too, so a name holding exactly the bytes typed
/// is always found, even one in neither canonical form.
func needleForms(_ typed: some StringProtocol) -> [[UInt8]] {
    var forms: [[UInt8]] = []
    for form in [
        String(typed),
        typed.precomposedStringWithCanonicalMapping,
        typed.decomposedStringWithCanonicalMapping,
    ] {
        let bytes = Array(asciiLowercased(form).utf8)
        if !forms.contains(bytes) {
            forms.append(bytes)
        }
    }
    return forms
}

/// Whether `haystack` contains `lowerNeedle`, byte for byte but for ASCII
/// case. The comparison a filter makes, one form of the needle at a time.
func containsIgnoringCase(_ haystack: String, _ lowerNeedle: String) -> Bool {
    name(haystack, holdsAny: [Array(lowerNeedle.utf8)])
}

/// Substring search ignoring ASCII case, without allocating: a filter runs
/// over every name in view on every keystroke. A name is read once for all
/// the needle's forms.
private func name(_ name: String, holdsAny needles: [[UInt8]]) -> Bool {
    // A native string, which is every name the scanner makes, lends its
    // UTF-8 in place (a short one from a copy on the stack).
    let lent = name.utf8.withContiguousStorageIfAvailable { hay in
        holds(hay, anyOf: needles)
    }
    if let lent {
        return lent
    }
    // A name bridged from an `NSString` may have no UTF-8 of its own to lend;
    // copying it out is the price of reading it, and only such a name pays.
    return Array(name.utf8).withUnsafeBufferPointer { hay in
        holds(hay, anyOf: needles)
    }
}

private func holds(
    _ hay: UnsafeBufferPointer<UInt8>,
    anyOf needles: [[UInt8]]
) -> Bool {
    needles.contains { needle in
        needle.withUnsafeBufferPointer { needle in contains(hay, needle) }
    }
}

private func contains(
    _ hay: UnsafeBufferPointer<UInt8>,
    _ needle: UnsafeBufferPointer<UInt8>
) -> Bool {
    if needle.isEmpty {
        return true
    }
    if needle.count > hay.count {
        return false
    }
    for start in 0...(hay.count - needle.count) {
        var offset = 0
        while offset < needle.count,
            asciiLowercased(hay[start + offset]) == needle[offset]
        {
            offset += 1
        }
        if offset == needle.count {
            return true
        }
    }
    return false
}
