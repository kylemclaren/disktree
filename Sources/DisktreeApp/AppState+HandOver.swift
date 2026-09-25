// Handing the marks over: disktree removes nothing itself.
//
// The review screen gives the marked list to the tools that already remove
// things well — Finder, where Move to Trash can be undone with Put Back, or
// a terminal, through a command copied here — and then watches the disk: the
// marked paths vanishing is how it learns the removal happened, and `statfs`
// before and after is how it learns what the removal was worth. The status
// bar never claims a saving it cannot measure (Invariant 9).

import DisktreeCore
import System

extension AppState {
    /// More folders than this and Finder opens a window for each of them:
    /// the list is better served by the command then.
    public static let finderFolderLimit = 12

    /// The command that removes the plan's targets still on disk, in
    /// `commandStyle`; `nil` when nothing may be removed, or all of it is
    /// gone already. Kept, like the plan, until something it is made of
    /// changes.
    public func cleanupCommand() -> String? {
        let memo = handOver()
        let style = commandStyle
        if let command = memo.command, command.style == style {
            return command.text
        }
        let text = DisktreeCore.cleanupCommand(memo.live, style: style)
        handOverMemo?.command = (style, text)
        return text
    }

    /// Copy `cleanupCommand()` to the pasteboard (`copyToPasteboard`) and say
    /// so in a toast: what it removes, how many, how much. When there is
    /// nothing to copy, the notice line says why, and stays.
    public func copyCommand() {
        guard let command = cleanupCommand() else {
            notice = nothingToHandOver()
            return
        }
        let plan = handOverPlan()
        copyToPasteboard(command)
        let tool =
            switch commandStyle {
            case .trash: "trash"
            case .remove: "rm"
            }
        // It worked: a warning left from an earlier try no longer holds.
        notice = nil
        showToast(
            Notice(
                "Copied: \(tool) for \(items(plan.targets.count)), "
                    + "\(humanBytes(plan.bytes)) — paste it into Terminal",
                status: .success
            )
        )
    }

    /// Select the plan's targets still on disk in Finder (`showInFinder`),
    /// where Move to Trash can be undone with Put Back, and say so in a
    /// toast. Refused, with a notice pointing at the command, when they are
    /// spread over so many folders that Finder would open a window for each.
    public func revealMarkedInFinder() {
        let plan = handOverPlan()
        guard !plan.targets.isEmpty else {
            notice = nothingToHandOver()
            return
        }
        let folders = Set(plan.targets.map { $0.path.removingLastComponent() })
        guard folders.count <= Self.finderFolderLimit else {
            notice = Notice(
                "the marks are in \(folders.count) folders, and Finder would "
                    + "open a window for each: copy the command instead",
                status: .warning
            )
            return
        }
        showInFinder(plan.targets.map(\.path))
        notice = nil
        showToast(
            Notice(
                "Revealed \(items(plan.targets.count)) in Finder: Move to "
                    + "Trash there can be undone with Put Back",
                status: .success
            )
        )
    }

    /// Copy the path of the tile at `crumbs` to the pasteboard, and say so
    /// in a toast: the context menu's Copy Path.
    public func copyPath(_ crumbs: [Int]) {
        guard let path = existingPath(crumbs) else {
            return
        }
        copyToPasteboard(path.string)
        showToast(
            Notice(
                "Copied \(displayPath(path, home: home))",
                status: .success
            )
        )
    }

    /// Select one tile's path in Finder: the context menu's and `f`'s
    /// Reveal in Finder. A name the walk could not decode cannot be named:
    /// the folder that holds it is shown instead, where Finder lists it
    /// under its real name.
    public func revealInFinder(_ crumbs: [Int]) {
        guard var path = path(at: crumbs) else {
            return
        }
        while isLossy(path), !path.components.isEmpty {
            path.removeLastComponent()
        }
        showInFinder([path])
    }

    /// Look for marked paths that are gone from disk. When every mark is
    /// gone, report what the disk measurably gained and scan again, so the
    /// numbers on screen match the disk.
    ///
    /// The looking happens off the main actor (`checkDisk`), and what it
    /// finds lands here a moment later.
    public func checkMarks() {
        Task { @MainActor [weak self] in
            await self?.checkDisk()
        }
    }

    /// Read free space and look for the marks off the main actor, then act
    /// on what was seen. `statfs` and `lstat` on a network share that
    /// stopped answering block until the mount gives up; on the main actor,
    /// that would freeze the window on every tick of the ticker.
    func checkDisk() async {
        let root = rootPath
        let home = self.home
        let marked = marks.items
        let volume = rootVolume
        let seen = await Task.detached(priority: .utility) {
            DiskLook(root: root, home: home, marked: marked, volume: volume)
        }.value
        // The root moved while it looked: its numbers are another volume's.
        guard root == rootPath else {
            return
        }
        guard !seen.away else {
            volumeWentAway()
            return
        }
        volumeCameBack()
        assign(\.space, seen.space)
        settle(seen)
    }

    /// The scanned volume is not mounted. Nothing on it was removed, and
    /// the free space `statfs` reports now is another disk's: measure
    /// nothing, keep every mark, and say so once.
    func volumeWentAway() {
        assign(\.space, nil)
        guard !volumeAway else {
            return
        }
        volumeAway = true
        notice = Notice(volumeAwayText, status: .warning)
    }

    /// The scanned volume is mounted again: its free space and its marks
    /// are measured as before.
    func volumeCameBack() {
        guard volumeAway else {
            return
        }
        volumeAway = false
        if notice?.text == volumeAwayText {
            notice = nil
        }
    }

    private var volumeAwayText: String {
        "the volume holding \(displayPath(rootPath, home: home)) is not "
            + "mounted: its marks are kept until it is back"
    }

    /// Act on a look at the disk: name the marks that are gone, and once
    /// every one is, say what that was worth and scan again.
    func settle(_ seen: DiskLook) {
        guard !marks.isEmpty else {
            return
        }
        // A mark made or dropped while it looked is not in the look.
        let vanished = seen.vanished.filter { marks.contains($0) }
        assign(\.gone, vanished)
        guard !vanished.isEmpty, !handOverReported,
            everyMarkHandled(gone: vanished, kept: seen.kept)
        else {
            return
        }
        reportHandOver(vanished.count)
        // The tree on screen still counts what went. A walk already out may
        // have read it before it went, or reuse a subtree measured before
        // that: it is checked when it lands, and read again if it did.
        if scan == nil {
            startScan()
        }
    }

    /// Whether the hand-over is over: every mark is gone, or one the guards
    /// keep back. Such a mark was never in the command, nor fit for Finder:
    /// waiting for it to go would wait forever.
    func everyMarkHandled(gone: Set<FilePath>, kept: Set<FilePath>) -> Bool {
        marks.items.allSatisfy {
            gone.contains($0.path) || kept.contains($0.path)
        }
    }

    /// Say what the hand-over was worth, measured with `statfs`, and leave
    /// the review, which has nothing left to act on.
    func reportHandOver(_ count: Int) {
        let what = "\(items(count, marked: true)) gone"
        notice =
            if let gain = measuredGain {
                Notice(
                    "\(what): the disk gained \(humanBytes(gain))",
                    status: .success
                )
            } else {
                // Moved to the Trash is still on the disk, and a local
                // Time Machine snapshot keeps what it holds: the number
                // says so rather than rounding a hope up to a saving.
                Notice(
                    "\(what); nothing measurably freed yet — the Trash and "
                        + "APFS snapshots can hold space",
                    status: .neutral
                )
            }
        screen = .explore
        handOverReported = true
    }

    /// Free space gained since the first mark, from `statfs`; `nil` until
    /// there is a baseline and a measurable gain.
    public var measuredGain: UInt64? {
        guard let space, let spaceBaseline,
            space.available > spaceBaseline.available
        else {
            return nil
        }
        return space.available - spaceBaseline.available
    }

    /// Why nothing was handed over: nothing marked, everything that could
    /// go is gone already, or nothing the guards let through.
    private func nothingToHandOver() -> Notice {
        if marks.isEmpty {
            Notice("nothing is marked", status: .warning)
        } else if !plan().targets.isEmpty {
            Notice("the marked paths are gone already", status: .neutral)
        } else {
            Notice(
                "nothing to hand over: every mark is kept back",
                status: .warning
            )
        }
    }

    /// `1 item`, `3 items`; `3 marked items`.
    private func items(_ count: Int, marked: Bool = false) -> String {
        "\(count) \(marked ? "marked " : "")item\(count == 1 ? "" : "s")"
    }
}

/// One look at the disk, taken off the main actor: free space at the root,
/// which marked paths are gone, and which ones the guards keep back — or
/// that the root's volume is not there to look at.
struct DiskLook: Sendable {
    var space: SpaceInfo?
    var vanished: Set<FilePath>
    var kept: Set<FilePath>
    /// The root is no longer on `volume`: nothing else was looked at.
    var away = false

    init(
        root: FilePath,
        home: FilePath?,
        marked: [Target],
        volume: VolumeIdentity? = nil
    ) {
        guard AppState.isOnItsVolume(root, volume) else {
            away = true
            vanished = []
            kept = []
            return
        }
        space = try? spaceInfo(root)
        vanished = Set(marked.map(\.path).filter { !AppState.isOnDisk($0) })
        // The guards are system calls too, and only matter once something
        // went.
        kept =
            vanished.isEmpty
            ? []
            : Set(
                DisktreeCore.plan(marked, root: root, home: home)
                    .blocked.map(\.path)
            )
    }
}
