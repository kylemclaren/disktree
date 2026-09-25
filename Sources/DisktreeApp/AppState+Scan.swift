// Scanning: the walk in flight, the tree when it lands, and the numbers that
// change under us while it is on screen — free space, whether the marked
// paths are still there, what git knows.
//
// A walk runs on threads of its own (`ScanHandle`); this side only polls it,
// on the main actor, so every change to the state happens in one place and
// in order. An epoch ties each poller to the walk it was started for: a walk
// abandoned for a newer one may still finish, but nobody is listening.

import Darwin
import DisktreeCore
import Foundation
import System

extension AppState {
    /// How many "worth a look" findings the panel lists.
    static let insightLimit = 6

    /// How often a walk in flight is polled: often enough that its counters
    /// read as live, rarely enough that polling costs nothing.
    static let scanPollInterval = Duration.milliseconds(110)

    /// How often free space and the marks are checked. The disk changes
    /// under us all the time, and the marks are removed in another app; a
    /// second is soon enough to notice either, and a `statfs` and an `lstat`
    /// per mark that often cost next to nothing, off the main actor.
    static let spaceInterval = Duration.milliseconds(1_200)

    // MARK: Observation

    /// Assign only when the value changed. An `@Observable` setter notifies
    /// on every assignment, equal or not, and the tickers and the pointer
    /// would otherwise redraw every screen for nothing.
    func assign<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<AppState, Value>,
        _ value: Value
    ) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }

    // MARK: Roots

    /// Scan a different root from scratch. Marks are kept; a mark outside
    /// the new root is shown as kept back, never removed.
    public func setRoot(_ root: FilePath) {
        rootPath = root
        refreshVolume()
        screen = .explore
        startScan()
    }

    /// Folders dropped on the window: scan the first one that is a
    /// directory disktree can read, from scratch, as the open panel's
    /// choice is. Returns whether one was taken, so a drop of files alone
    /// is refused rather than swallowed.
    @discardableResult
    public func scanDropped(_ urls: [URL]) -> Bool {
        guard let root = urls.lazy.compactMap(Self.droppedFolder).first
        else {
            return false
        }
        setRoot(root)
        return true
    }

    /// A dropped item as a root to scan: a directory, canonical as the
    /// command line's root is, so a later widening recognises the tree.
    nonisolated static func droppedFolder(_ url: URL) -> FilePath? {
        guard url.isFileURL else {
            return nil
        }
        return try? scannableDirectory(
            FilePath(url.path(percentEncoded: false))
        )
    }

    /// Go up to `above`, a directory containing the scanned root.
    ///
    /// Memoized: the tree already measured is handed to the walk and reused
    /// where it is reached, so only what is new at the wider level is read,
    /// and the current view stays on screen until the wider tree lands.
    public func widen(to above: FilePath) {
        guard let tree else {
            setRoot(above)
            return
        }
        guard rootPath.starts(with: above), rootPath != above else {
            return
        }
        scan?.cancel()
        scanEpoch += 1
        progress = ScanSnapshot()
        scanError = nil
        scanStarted = .now
        scanElapsed = nil
        scanRoot = above
        scanMetric = options.metric
        scan = ScanHandle(
            root: above,
            options: options,
            known: Known(
                path: rootPath,
                tree: tree,
                unreadable: treeUnreadable
            )
        )
        pollScan(epoch: scanEpoch)
    }

    /// `g`: the whole disk. Widens when the disk is above the scanned root,
    /// and goes to its top when it already is the root.
    public func goToDisk() {
        guard let disk = diskRoot else {
            return
        }
        if disk == rootPath {
            goTo([])
        } else {
            widen(to: disk)
        }
    }

    /// Free space, the device and the volume's name follow the root: a
    /// widened or a new root may sit on another volume than the old one.
    func refreshVolume() {
        let before = (device: device, space: space)
        space = try? spaceInfo(rootPath)
        device = deviceFor(rootPath)
        rootVolume = volumeIdentity(rootPath)
        volumeAway = false
        volumeName = volumeNameFor(rootPath)
        if device != before.device, let spaceBaseline {
            self.spaceBaseline = Self.rebased(
                spaceBaseline,
                from: before.space,
                to: space
            )
        }
    }

    /// A baseline carried from one volume to another: what was gained on
    /// the old one so far is kept, and what follows is measured on the new
    /// one. Subtracting one volume's free space from another's would report
    /// the gap between two disks as a saving (Invariant 9). The volumes of
    /// one APFS container share their free space, so going from the home
    /// directory to `/` carries the baseline over as it was.
    ///
    /// `nil` when either side cannot be read: then there is nothing to
    /// measure from, and the next mark takes a fresh baseline.
    nonisolated static func rebased(
        _ baseline: SpaceInfo,
        from old: SpaceInfo?,
        to new: SpaceInfo?
    ) -> SpaceInfo? {
        guard let old, let new else {
            return nil
        }
        /// `now - (was - base)`, held between zero and the largest value:
        /// a gain larger than the new volume can show is under-reported,
        /// never made up.
        func carried(_ base: UInt64, _ was: UInt64, _ now: UInt64) -> UInt64 {
            if was >= base {
                let gained = was - base
                return now >= gained ? now - gained : 0
            }
            let (sum, overflow) = now.addingReportingOverflow(base - was)
            return overflow ? .max : sum
        }
        return SpaceInfo(
            total: new.total,
            free: carried(baseline.free, old.free, new.free),
            available: carried(
                baseline.available,
                old.available,
                new.available
            )
        )
    }

    // MARK: The walk

    /// Start a fresh scan, abandoning any walk still in progress.
    public func startScan() {
        scan?.cancel()
        scanEpoch += 1
        progress = ScanSnapshot()
        scanError = nil
        replaceTree(with: nil)
        // A switch of metric still being ranked has no tree left to rank:
        // the walk ranks by it instead.
        if let pending = pendingMetric {
            options.metric = pending
            pendingMetric = nil
            rankEpoch &+= 1
        }
        crumbs = []
        selected = nil
        hovered = nil
        hoveredTail = nil
        view = .identity
        // Stops and a smart zoom's way back are places in the tree being
        // dropped.
        detent = nil
        smartZoomed = nil
        cache = nil
        insights = []
        git = [:]
        clearFilter()
        scanStarted = .now
        scanElapsed = nil
        scanRoot = rootPath
        scanMetric = options.metric
        scan = ScanHandle(root: rootPath, options: options)
        pollScan(epoch: scanEpoch)
    }

    /// Poll the walk of `epoch` until it lands, or until a newer walk
    /// replaces it. Holds the state weakly: a closed window ends it.
    func pollScan(epoch: Int) {
        Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(for: AppState.scanPollInterval)
                guard let self, self.pollScanOnce(epoch: epoch) else {
                    return
                }
            }
        }
    }

    /// Drain the scan once. Returns whether the poller should keep ticking.
    /// Driven by the poll task, and by the tests, which cannot sleep the
    /// main actor while a real walker reads a directory.
    @discardableResult
    public func pollScanOnce(epoch: Int) -> Bool {
        guard epoch == scanEpoch, let scan else {
            return false
        }
        assign(\.progress, scan.progress.snapshot())
        guard let outcome = scan.poll() else {
            return true
        }
        // Read again now that it is over: the snapshot above may be from a
        // moment before the last directory was read.
        assign(\.progress, scan.progress.snapshot())
        // Done before landing: a landing that finds its tree out of date
        // starts the next walk itself.
        self.scan = nil
        progress.finished = true
        switch outcome {
        case .success(let node):
            land(node)
        case .failure(let error):
            scanError = error.description
            // Still a look at the disk: what went is gone either way, and a
            // mark kept for a root that cannot be read would bring the
            // hand-over back to rescan it every tick.
            _ = dropVanishedMarks(from: nil)
        }
        // Whatever walk a hand-over was owed has landed, or was replaced
        // by a newer one that just did.
        handOverReported = false
        return false
    }

    /// The walk finished: put its tree on screen.
    private func land(_ node: Node) {
        var node = node
        // `t` switched the metric while the walk was out: rank the tree by
        // the one on screen, or "largest first" means the other one. A
        // large tree lands in the walk's order and is ranked after, off the
        // main actor, as a switch would rank it.
        let wanted = pendingMetric ?? options.metric
        pendingMetric = nil
        options.metric = scanMetric
        if wanted != scanMetric {
            if node.files &+ node.dirs > rankInPlaceLimit {
                pendingMetric = wanted
            } else {
                aggregate(&node, metric: wanted)
                options.metric = wanted
            }
        }
        // A widening scan lands on a new root: move the view up to it, with
        // the directory it came from selected.
        let cameFrom = scanRoot != rootPath ? rootPath : nil
        if cameFrom != nil {
            clearFilter()
            rootPath = scanRoot
            refreshVolume()
        }
        let outOfDate = dropVanishedMarks(from: node)
        marks.refresh(rootPath: rootPath, root: node)
        replaceTree(with: node)
        treeUnreadable = (progress.errors, progress.messages)
        cache = nil
        refreshInsights()
        scanElapsed = scanStarted.map { .now - $0 }
        if let cameFrom {
            let found = crumbs(for: cameFrom)
            crumbs = []
            view = .identity
            transition = nil
            forgetHover()
            selected = found?.first.map { [$0] }
        }
        keepSelectionValid()
        selectLargest()
        // The tree counts something the disk no longer has: it was read
        // before the hand-over, or a widening reused a subtree measured
        // before it. Start over rather than leave numbers that include what
        // was just removed.
        if outOfDate {
            startScan()
        } else if pendingMetric != nil {
            // The switch was made for the tree this one replaced, or before
            // there was one: rank this one instead.
            pendingMetric = nil
            toggleMetric()
        }
    }

    /// Put `next` on screen, and let the tree it replaces go off the main
    /// actor: freeing millions of nodes takes a tenth of a second, and on
    /// the main actor that is a frozen window at every rescan.
    func replaceTree(with next: Node?) {
        let old = tree
        tree = next
        discardInBackground(old)
    }

    /// A mark whose path is gone from disk was removed in Finder or by the
    /// copied command since it was made: drop it. The rest are kept,
    /// wherever they are, and re-measured by the tree that lands
    /// (Invariant 5).
    ///
    /// Returns whether `tree` still holds one of the paths that went.
    func dropVanishedMarks(from tree: Node?) -> Bool {
        // A volume that went away takes its marks' paths along; they are
        // still on it, wherever it went.
        guard Self.isOnItsVolume(rootPath, rootVolume) else {
            return false
        }
        let vanished = marks.items.map(\.path).filter { !Self.isOnDisk($0) }
        guard !vanished.isEmpty else {
            return false
        }
        // The ticker may not have seen them go before the walk landed. Then
        // this is the end of the hand-over, and it is said here, while the
        // baseline the gain is measured from is still there.
        if !handOverReported,
            everyMarkHandled(
                gone: Set(vanished),
                kept: Set(plan().blocked.map(\.path))
            )
        {
            assign(\.space, try? spaceInfo(rootPath))
            reportHandOver(vanished.count)
        }
        for path in vanished {
            marks.remove(path)
        }
        marksChanged()
        guard let tree else {
            return false
        }
        return vanished.contains {
            findNode(rootPath: rootPath, root: tree, path: $0) != nil
        }
    }

    /// Crumbs from an older tree may point past the end of this one.
    func keepSelectionValid() {
        guard let tree else {
            return
        }
        if tree.resolve(crumbs) == nil {
            crumbs = []
            lapseFilter()
        }
        if let selected, tree.resolve(selected) == nil {
            self.selected = nil
        }
    }

    /// Recompute "worth a look" from the tree on screen.
    func refreshInsights() {
        scannedAt = nowSeconds()
        insights =
            tree.map {
                worthALook($0, now: scannedAt, limit: Self.insightLimit)
            } ?? []
    }

    /// Select the largest entry of the current root, so the selection line,
    /// the tooltip and the mark key all have something to act on from the
    /// first frame. The largest entry is also the answer to "what is eating
    /// my disk" most of the time.
    func selectLargest() {
        guard selected == nil, let index = current?.largestChild else {
            return
        }
        selected = crumbs + [index]
    }

    // MARK: What changes under us

    /// Poll free space so the meter is live, and look for marked paths that
    /// were removed in the meantime; neither repaints when nothing moved.
    /// One look at a time: the next waits for the last to come back.
    func startSpaceTicker() {
        let ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: AppState.spaceInterval)
                guard let self else {
                    return
                }
                await self.checkDisk()
            }
        }
        tickers.append(ticker)
    }

    /// Ask git about `path` once, off the main actor, if it is a checkout.
    public func ensureGit(_ path: FilePath) {
        guard git.index(forKey: path) == nil, !gitPending.contains(path) else {
            return
        }
        gitPending.insert(path)
        Task { @MainActor [weak self] in
            // Three processes, run to completion: never on the main actor.
            let state = await Task.detached(priority: .utility) {
                gitState(path)
            }.value
            guard let self else {
                return
            }
            self.gitPending.remove(path)
            // `updateValue`, not a subscript: assigning a `nil` state through
            // the subscript would remove the key instead of recording "not a
            // checkout".
            self.git.updateValue(state, forKey: path)
        }
    }

    /// Whether `root` is still on `volume`, the filesystem it was chosen on:
    /// or, gone itself, whether what held it is. Ejected, a volume leaves
    /// its mount point empty on the volume below, or takes it along; either
    /// way every path on it reads as removed, and free space as another
    /// disk's. `nil` knows no better, and trusts the disk.
    nonisolated static func isOnItsVolume(
        _ root: FilePath,
        _ volume: VolumeIdentity?
    ) -> Bool {
        guard let volume else {
            return true
        }
        return volumeIdentity(root) == volume
    }

    /// Whether anything is at `path`, without following a symlink: a marked
    /// link whose target went is still there. Only "no such entry" counts as
    /// gone; a path that cannot be looked at, because a directory above it
    /// became unreadable or its name was never decoded, may well still be
    /// there.
    nonisolated static func isOnDisk(_ path: FilePath) -> Bool {
        // A name the walk could not decode cannot be looked up by the text
        // it was decoded to: whatever `lstat` says is about another entry.
        if isLossy(path) {
            return true
        }
        var info = stat()
        let code: Int32 = path.withPlatformString {
            lstat($0, &info) == 0 ? 0 : errno
        }
        return code != ENOENT && code != ENOTDIR
    }
}

/// Let `tree` go on a background thread. The last reference is the task's,
/// so the nodes are freed there.
nonisolated func discardInBackground(_ tree: consuming Node?) {
    guard let tree = tree.take() else {
        return
    }
    Task.detached(priority: .background) {
        withExtendedLifetime(tree) {}
    }
}
