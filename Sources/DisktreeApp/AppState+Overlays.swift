// What floats over the screens for a moment: the toast that confirms a
// hand-over, and the Quick Look preview.
//
// Both are state, not views, so a key can take them away: Escape goes to
// them before it means anything to the screen below, through the one
// dispatcher. The views only show them — the toast over the treemap, the
// preview in Quick Look's own panel — and never take the keyboard.

import DisktreeCore
import System

extension AppState {
    /// How long a toast stays up: long enough to read a line, short enough
    /// that it is gone before anyone thinks to dismiss it.
    public static let toastDuration = Duration.milliseconds(2_500)

    /// Confirm something that just happened, for `duration`. A newer toast
    /// replaces this one; the notice line is for what has to stay.
    public func showToast(
        _ notice: Notice,
        for duration: Duration = toastDuration,
        now: ContinuousClock.Instant = .now
    ) {
        let expiry = now + duration
        toast = notice
        toastExpiry = expiry
        toastSerial += 1
        let serial = toastSerial
        Task { @MainActor [weak self] in
            try? await Task.sleep(until: expiry, clock: .continuous)
            // A newer toast has its own timer.
            guard let self, self.toastSerial == serial else {
                return
            }
            self.dismissToast()
        }
    }

    /// Take the toast down: Escape, or its time is up.
    public func dismissToast() {
        assign(\.toast, nil)
        toastExpiry = nil
    }

    /// Take the toast down if its time is up at `now`. The timer does this
    /// on its own; a view that draws a frame after the expiry may ask too.
    public func expireToast(now: ContinuousClock.Instant = .now) {
        if let toastExpiry, now >= toastExpiry {
            dismissToast()
        }
    }

    // MARK: Quick Look

    /// `⌘Y`: preview the tile a key acts on (the directory drawn when there
    /// is none), or close the preview when it is up. Returns whether it did
    /// either: the review has no tile to preview.
    @discardableResult
    public func toggleQuickLook() -> Bool {
        if quickLookTarget != nil {
            quickLookTarget = nil
            return true
        }
        guard screen == .explore,
            let path = existingPath(actionTarget ?? crumbs)
        else {
            return false
        }
        quickLookTarget = path
        return true
    }

    /// Preview the tile at `crumbs`: the context menu's Quick Look.
    public func revealQuickLook(_ crumbs: [Int]) {
        guard let path = existingPath(crumbs) else {
            return
        }
        quickLookTarget = path
    }

    /// Preview `path`, wherever it came from: a row of the review's list.
    public func revealQuickLook(path: FilePath) {
        quickLookTarget = path
    }

    /// While the preview is up, it follows the selection, as Finder's does.
    func followQuickLook(_ crumbs: [Int]) {
        if let path = existingPath(crumbs) {
            assign(\.quickLookTarget, path)
        }
    }

    /// The path of the node at `crumbs`, if the tree has one there.
    /// `path(at:)` stops at the first crumb past the tree, and a preview
    /// or a copied path of the directory above is not what was asked for.
    ///
    /// `nil` for a name the walk could not decode (`isLossy`): its path
    /// names another entry, or none, and a copied path, a preview or a drag
    /// would hand over that one instead.
    func existingPath(_ crumbs: [Int]) -> FilePath? {
        guard node(at: crumbs) != nil, let path = path(at: crumbs),
            !isLossy(path)
        else {
            return nil
        }
        return path
    }
}
