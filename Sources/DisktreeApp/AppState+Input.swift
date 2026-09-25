// Input: the one key dispatcher, and the pointer over the treemap.
//
// Every binding is here, in reading order of the hint bar, so the keys and
// the documented list cannot drift apart. The shell turns an `NSEvent` into
// a `KeyStroke` and the treemap view turns the pointer into treemap-local
// points; neither decides what they mean.

import CoreGraphics
import DisktreeCore
import Foundation

extension AppState {
    /// Keys that act on "the current tile": they start from the pointer when
    /// it moved last.
    private static let pointerKeys: Set<String> = [
        "space", "x", "enter", "tab", "left", "right", "up", "down", "h", "j",
        "k", "l",
    ]

    /// Handle a key press through the one dispatcher. Returns whether the
    /// key was consumed: by a binding, or by a modal state that owns the
    /// keyboard while it is open.
    @discardableResult
    public func handleKey(_ key: KeyStroke) -> Bool {
        if zoomInterface(key) {
            return true
        }
        // ⌘ belongs to the menus: ⌘Q, ⌘O, ⌘R, ⌘W and ⌘C must reach them,
        // whatever is open. ⌘Y is the one that is the dispatcher's too:
        // Quick Look, as in Finder, which has to work from any screen and
        // whatever holds the keyboard, and which the menu's item calls
        // through the same method.
        if key.command {
            if key.key.lowercased() == "y", !key.shift, !key.control,
                !key.option
            {
                rehover()
                return toggleQuickLook()
            }
            return false
        }
        // Escape takes away what floats over the screen first — the toast,
        // then the preview — before it means anything to the screen below.
        if key.key == "escape" {
            if toast != nil {
                dismissToast()
                return true
            }
            if quickLookTarget != nil {
                quickLookTarget = nil
                return true
            }
        }
        let before = selected
        let consumed = dispatch(key)
        // The preview follows the selection, as Finder's does.
        if quickLookTarget != nil, selected != before, let selected {
            followQuickLook(selected)
        }
        return consumed
    }

    /// A key, once nothing floating over the screen took it.
    private func dispatch(_ key: KeyStroke) -> Bool {
        let name = bindingName(key)

        if showHelp {
            if ["escape", "?", "/", "q"].contains(name) {
                showHelp = false
            }
            return true
        }

        // The search field takes the keyboard while it is open. It is a
        // field of three keys on purpose: no editor state to keep in sync
        // with the tree, and Escape always means "give the keyboard back".
        if screen == .explore && findOpen {
            onFindKey(key)
            return true
        }

        return switch screen {
        case .explore:
            onExploreKey(name, control: key.control, shift: key.shift)
        case .review:
            onReviewKey(name)
        }
    }

    /// The binding a key stands for. A letter binds the same with shift, as
    /// it did in Rust, whose dispatcher matched the unshifted key: only what
    /// shift turns into another symbol, like `?`, is a key of its own.
    private func bindingName(_ key: KeyStroke) -> String {
        guard key.key.count == 1, let scalar = key.key.unicodeScalars.first,
            ("A"..."Z").contains(scalar)
        else {
            return key.key
        }
        return key.key.lowercased()
    }

    /// Keys while the find field is open.
    private func onFindKey(_ key: KeyStroke) {
        switch key.key {
        case "escape":
            clearFilter()
        case "enter":
            applyFilter()
        case "backspace":
            if !find.isEmpty {
                find.removeLast()
            }
            refreshMatches()
        default:
            // The text a key types, which a named key has none of; space
            // types itself even where the key is only named. A control
            // chord never types.
            let typed = key.character ?? (key.key == "space" ? " " : nil)
            if !key.control, let typed, typed.count == 1 {
                find += typed
                refreshMatches()
            }
        }
    }

    private func onExploreKey(
        _ key: String,
        control: Bool,
        shift: Bool
    ) -> Bool {
        if Self.pointerKeys.contains(key) {
            adoptPointerTarget()
        }
        switch key {
        case "/" where !control, "s" where !control:
            // Back to typing: an Enter pressed before, still waiting on its
            // search, is not what this edit asks for.
            applyPending = false
            findOpen = true
        case "enter":
            descend()
        case "right" where !control, "l" where !control:
            moveSelection(.right)
        case "left" where !control, "h" where !control:
            moveSelection(.left)
        case "up" where !control, "k" where !control:
            moveSelection(.up)
        case "down" where !control, "j" where !control:
            moveSelection(.down)
        case "backspace" where !control, "u" where !control:
            ascend()
        // A filter is the first thing Escape takes away.
        case "escape" where matches != nil:
            clearFilter()
        // Then a tile's selection; the directory drawn, which Enter and
        // the trail leave selected, is no tile to clear, so Escape goes up
        // from it as Backspace does.
        case "escape":
            if let selected, selected != crumbs {
                self.selected = nil
            } else {
                ascend()
            }
        case "space":
            markSelectedTile()
        case "x" where !control:
            markSelectedTile()
        case "tab":
            cycleSibling(shift ? -1 : 1)
        case "c" where !control:
            if marks.isEmpty {
                notice = Notice(
                    "mark something first: space marks the selected tile",
                    status: .warning
                )
            } else {
                screen = .review
            }
        case "[":
            adjustDepth(-1)
        case "]":
            adjustDepth(1)
        case "-":
            zoom(
                atX: halfWidth, y: halfHeight, factor: 1 / 1.25, descend: false)
            // Magnified about the middle, the mosaic moved under the pointer.
            rehover()
        case "=", "+":
            zoom(atX: halfWidth, y: halfHeight, factor: 1.25, descend: false)
            rehover()
        case "0":
            resetView()
        case "t" where !control:
            setMode((modeIndex + 1) % 3)
        case "r" where !control:
            startScan()
        case "g" where !control:
            goToDisk()
        case "i" where !control:
            options.includeHidden.toggle()
            startScan()
        case "d" where !control:
            options.apparentSize.toggle()
            startScan()
        case "p" where !control:
            showSelection.toggle()
        case "f" where !control:
            // What a key acts on, without making it the selection: showing
            // a path in Finder changes nothing here.
            rehover()
            revealInFinder(actionTarget ?? crumbs)
        case "?":
            showHelp = true
        case "q" where !control:
            onQuit?()
        default:
            return false
        }
        return true
    }

    private func onReviewKey(_ key: String) -> Bool {
        switch key {
        case "escape":
            screen = .explore
        case "enter":
            copyCommand()
        case "f":
            revealMarkedInFinder()
        case "!":
            clearMarks()
        case "p":
            commandStyle = .remove
        case "m":
            commandStyle = .trash
        case "?":
            showHelp = true
        default:
            return false
        }
        return true
    }

    private var halfWidth: Double { Double(treemapSize.width) / 2 }

    private var halfHeight: Double { Double(treemapSize.height) / 2 }

    // MARK: The pointer

    /// The pointer moved to a treemap-local point.
    public func pointerMoved(to point: CGPoint) {
        // Outside the mosaic there is nothing to hover, and a stale tooltip
        // would cover whatever the pointer went to — the panel's resize
        // handle, for one.
        let inside =
            point.x >= 0 && point.y >= 0 && point.x < treemapSize.width
            && point.y < treemapSize.height
        guard inside else {
            if pointer != nil || hovered != nil {
                pointerExited()
            }
            return
        }
        // The tooltip is positioned from `pointer`, so a move within one
        // tile still has to reach the view.
        pointer = point
        assign(\.pointerActive, true)
        let before = (hovered, hoveredTail?.crumbs, hoveredTail?.count)
        defer {
            if (hovered, hoveredTail?.crumbs, hoveredTail?.count) != before {
                holdCard()
            }
        }
        switch hitTile(x: Double(point.x), y: Double(point.y))?.kind {
        case .node(let crumbs):
            assign(\.hovered, crumbs)
            assign(\.hoveredTail, nil)
        case .others(let crumbs, let count):
            // A merged tail is never `hovered`: nothing may act on it. Its
            // weight is summed once per tail, not per move across it.
            assign(\.hovered, nil)
            if hoveredTail?.crumbs != crumbs || hoveredTail?.count != count {
                assign(\.hoveredTail, mergedTail(of: crumbs, count: count))
            }
        case nil:
            assign(\.hovered, nil)
            assign(\.hoveredTail, nil)
        }
    }

    /// How long the pointer rests on a tile before its card shows: about
    /// as long as the system waits before a tooltip, a little less, since
    /// the card is what the mosaic is read by.
    nonisolated static let cardDelay = Duration.milliseconds(450)

    /// The pointer came to another tile: its card waits until it has
    /// rested there, and a card already out goes at once.
    ///
    /// A run-loop timer rather than a task, as the panel's width settler
    /// is: it fires in whatever loop is running, a test's nested one too,
    /// where the main actor's queue waits for the outermost.
    func holdCard() {
        assign(\.cardHeld, true)
        cardRelease?.invalidate()
        let (seconds, attoseconds) = Self.cardDelay.components
        let timer = Timer(
            timeInterval: Double(seconds) + Double(attoseconds) / 1e18,
            repeats: false
        ) { [weak self] _ in
            // Added to the main run loop below, so it fires on the main
            // thread.
            MainActor.assumeIsolated { self?.cardHeld = false }
        }
        RunLoop.main.add(timer, forMode: .common)
        cardRelease = timer
    }

    /// The layout or the view changed under a pointer that did not move:
    /// what it rests on is whatever is there now, not the tile it came to.
    /// A deeper or shallower layout, a zoom about the middle, a pan, a
    /// narrower mosaic — each puts another tile under the same point, and
    /// Space, X and Enter act on the tile under the pointer.
    func rehover() {
        guard pointerActive, let pointer else {
            return
        }
        pointerMoved(to: pointer)
    }

    /// The pointer left the treemap.
    public func pointerExited() {
        assign(\.pointer, nil)
        assign(\.pointerActive, false)
        assign(\.hovered, nil)
        assign(\.hoveredTail, nil)
    }

    /// Click: select, then act on a repeat click, like a file manager.
    /// Returns what the click did, for the view's feedback: a mark made
    /// with a ⌘-click is felt, where the same mark made with Space is not.
    @discardableResult
    public func mouseDown(
        at point: CGPoint,
        button: PointerButton,
        clickCount: Int,
        modifiers: PointerModifiers
    ) -> ClickOutcome {
        let crumbs = tile(atX: Double(point.x), y: Double(point.y))
        // A new click sequence has opened nothing yet.
        if button == .left, clickCount < 2 {
            clickOpened = nil
        }
        let before = (level: self.crumbs, selected: selected)
        switch button {
        case .left where clickCount >= 2:
            // The first click of this double click already opened the
            // selection; going on into what now lies under the pointer
            // would take two levels for one gesture.
            if let clickOpened, clickOpened == self.crumbs {
                return .none
            }
            if let crumbs {
                select(crumbs)
                openFromClick()
            }
        case .left where modifiers.command || modifiers.control:
            guard let crumbs else {
                return .none
            }
            return toggleMark(crumbs) ? .toggledMark : .none
        case .left:
            if let crumbs, crumbs == selected, node(at: crumbs)?.isDir == true {
                // A second click on the selection opens it, like a file
                // manager, without needing a double click.
                openFromClick()
            } else {
                select(crumbs)
            }
        case .middle:
            guard let crumbs else {
                return .none
            }
            return toggleMark(crumbs) ? .toggledMark : .none
        case .right:
            // The view shows a context menu, which acts through the same
            // methods as the keys.
            return .none
        }
        if quickLookTarget != nil, let selected, selected != before.selected {
            followQuickLook(selected)
        }
        if self.crumbs != before.level {
            return .changedLevel
        }
        return selected != before.selected ? .selected : .none
    }

    /// Descend, remembering what the click sequence opened.
    private func openFromClick() {
        let before = crumbs
        descend()
        if crumbs != before {
            clickOpened = crumbs
        }
    }
}
