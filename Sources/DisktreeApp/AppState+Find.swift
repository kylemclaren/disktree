// Find: typing a name dims what does not match, Enter lays out only what
// does.
//
// The search runs off the main actor: a whole disk is millions of names, a
// few hundred milliseconds to search, and typing must not wait for it. Each
// keystroke supersedes the search before it, by epoch.

import DisktreeCore
import Foundation

extension AppState {
    /// Recompute what the find text matches in the directory on screen, off
    /// the main actor; each keystroke supersedes the search before it.
    public func refreshMatches() {
        findEpoch += 1
        // A keystroke after Enter supersedes it: only an Enter pressed after
        // the last edit applies the search that edit starts.
        applyPending = false
        let epoch = findEpoch
        let needle = find
        guard let tree,
            !needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            matches = nil
            filterApplied = false
            finding = false
            filterEpoch += 1
            return
        }
        finding = true
        let base = crumbs
        Task { @MainActor [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                tree.resolve(base).flatMap {
                    DisktreeCore.filter($0, base: base, needle: needle)
                }
            }.value
            guard let self, epoch == self.findEpoch else {
                return
            }
            self.finding = false
            self.matches = found
            self.filterEpoch += 1
            // The view may have gone above where this was typed while it
            // ran; then it lapses on arrival, as it would have on screen.
            self.lapseFilter()
            if self.applyPending {
                self.applyPending = false
                self.applyFilter()
            }
        }
    }

    /// Enter in the find field: lay out only the matches, with the largest
    /// selected so Space marks it.
    public func applyFilter() {
        findOpen = false
        if finding {
            applyPending = true
            return
        }
        guard let matches else {
            return
        }
        if matches.count == 0 {
            notice = Notice(
                "nothing here matches \(matches.needle)",
                status: .warning
            )
            return
        }
        filterApplied = true
        filterEpoch += 1
        view = .identity
        transition = nil
        forgetHover()
        pointerActive = false
        let tree = self.tree
        // The largest whole match. Equal sizes go to the one first in the
        // tree's order: the map has no order of its own to fall back on.
        var best: (bytes: UInt64, crumbs: [Int])?
        for (crumbs, keep) in matches.kept where keep == .whole {
            guard let node = tree?.resolve(crumbs) else {
                continue
            }
            let better =
                best.map {
                    node.bytes > $0.bytes
                        || node.bytes == $0.bytes
                            && crumbs.lexicographicallyPrecedes($0.crumbs)
                } ?? true
            if better {
                best = (node.bytes, crumbs)
            }
        }
        selected = best?.crumbs
        notice = nil
    }

    /// The find text as the toolbar's search field edits it: typed, pasted,
    /// or emptied by its own clear button. Each edit starts a new search,
    /// as a key typed into the find does.
    public func setFind(_ text: String) {
        guard text != find else {
            return
        }
        find = text
        refreshMatches()
    }

    /// The search field took the keyboard, from a click or after `/`: what
    /// is typed is the find's, as it is once `/` opens it. An Enter still
    /// waiting on its search is not what the next edit asks for.
    public func beginFind() {
        applyPending = false
        findOpen = true
    }

    /// The search field gave the keyboard back without Enter or Escape: a
    /// click elsewhere. The text and what it matches stay, dimming the rest
    /// until Escape clears them.
    public func endFind() {
        findOpen = false
    }

    /// Drop the find text and the filter with it.
    public func clearFilter() {
        findEpoch += 1
        finding = false
        applyPending = false
        find = ""
        findOpen = false
        matches = nil
        filterApplied = false
        filterEpoch += 1
    }
}
