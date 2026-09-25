// "Worth a look": the biggest things in a scan that could plausibly go.
//
// Three kinds of finding, each one a directory a person can judge in a
// second: reclaimable space (`Reclaim`), agent worktrees, and experiments
// nobody has written to in a month. Findings never nest, so their total is
// space that really exists once.

/// Seconds in a day.
private let day: Int64 = 86_400

/// An experiment untouched this long is worth a look.
public let staleDays: Int64 = 30

/// Smaller than this is not worth a line.
private let minBytes: UInt64 = 64 * 1024 * 1024

/// Why a directory is on the list.
public enum Finding: Sendable, Hashable {
    /// Its space can be had back, for this reason.
    case reclaimable(Reclaim)
    /// A directory of agent worktrees: how many, and the oldest one's age.
    case worktrees(count: Int, oldestDays: Int64)
    /// Experiments untouched for `staleDays`: only those are counted.
    case staleExperiments(count: Int)
}

/// One line of the list.
public struct Candidate: Sendable, Hashable {
    /// Where it is, from the scanned root.
    public var crumbs: [Int]
    /// What clearing it frees. For stale experiments, only the stale ones.
    public var bytes: UInt64
    /// Why it is on the list.
    public var finding: Finding

    /// A line of the list, as `worthALook` finds it.
    public init(crumbs: [Int], bytes: UInt64, finding: Finding) {
        self.crumbs = crumbs
        self.bytes = bytes
        self.finding = finding
    }
}

/// The `limit` largest findings beneath `root`, largest first. `now` is Unix
/// seconds, passed in so the answer is testable.
public func worthALook(_ root: Node, now: Int64, limit: Int) -> [Candidate] {
    var found: [Candidate] = []
    var crumbs: [Int] = []
    for (index, child) in root.children.enumerated() {
        crumbs.append(index)
        visit(child, crumbs: &crumbs, now: now, found: &found)
        crumbs.removeLast()
    }
    // Equal sizes keep the order the walk found them in, so the list does
    // not reshuffle between two scans of the same tree. That order is the
    // explicit tie-break: `sort` does not promise to be stable.
    let ranked = found.enumerated()
        .filter { $0.element.bytes >= minBytes }
        .sorted { left, right in
            if left.element.bytes != right.element.bytes {
                return left.element.bytes > right.element.bytes
            }
            return left.offset < right.offset
        }
    return ranked.prefix(max(limit, 0)).map(\.element)
}

private func visit(
    _ node: Node,
    crumbs: inout [Int],
    now: Int64,
    found: inout [Candidate]
) {
    guard node.isDir else {
        return
    }
    // Topmost only: everything beneath a reclaimable directory goes with it.
    if let reason = node.reclaim {
        found.append(
            Candidate(
                crumbs: crumbs,
                bytes: node.bytes,
                finding: .reclaimable(reason)
            )
        )
        return
    }
    let scratch = node.category == .agentScratch
    // Folded only inside agent scratch, the one place the name is asked.
    let name = scratch ? asciiLowercased(node.name) : ""
    if scratch && name == "worktrees" {
        let trees = node.children.filter(\.isDir)
        if !trees.isEmpty {
            // An unknown write time (0) says nothing about age, so it is
            // left out; with none known, the oldest is today, not 1970.
            let oldest =
                trees.map(\.modified).filter { $0 > 0 }.min() ?? now
            found.append(
                Candidate(
                    crumbs: crumbs,
                    bytes: node.bytes,
                    finding: .worktrees(
                        count: trees.count,
                        oldestDays: max(now - oldest, 0) / day
                    )
                )
            )
            return
        }
    }
    let experiments = scratch && (name == "tries" || name == "experiments")
    var stale: (count: Int, bytes: UInt64) = (0, 0)
    for (index, child) in node.children.enumerated() {
        let isStale =
            experiments
            && child.isDir
            && child.modified > 0
            && now - child.modified > staleDays * day
        if isStale {
            stale.count += 1
            stale.bytes = stale.bytes.saturatingAdding(child.bytes)
            // A stale experiment is judged whole; its caches go with it.
            continue
        }
        crumbs.append(index)
        visit(child, crumbs: &crumbs, now: now, found: &found)
        crumbs.removeLast()
    }
    if stale.count > 0 {
        found.append(
            Candidate(
                crumbs: crumbs,
                bytes: stale.bytes,
                finding: .staleExperiments(count: stale.count)
            )
        )
    }
}
