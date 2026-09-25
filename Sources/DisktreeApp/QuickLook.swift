// Quick Look: the system's preview panel, for the file or folder the state
// names.
//
// `⌘Y`, the context menu's Quick Look and a Force Click on a tile set
// `state.quickLookTarget`; this puts Quick Look's own panel up for it,
// keeps it in step while the target follows the selection, and takes it
// down when the target goes (Escape, `⌘Y` again). When the panel is closed
// from the panel itself, the state hears of it and names no target. Never
// on Space: Space marks.
//
// The panel finds whoever feeds it along the responder chain, as it does in
// Finder. The window controller is in that chain and hands the questions on
// to the controller here, which answers from the state: one item, the
// target, zooming out of its tile.
//
// The panel itself sits behind a small protocol. A test must never put a
// panel on anyone's screen, so it records instead; a `--snapshot` run gets
// one that does nothing, as nothing may open in front of the person.

import AppKit
import Observation
import Quartz
import System

/// Shows, refreshes and closes the preview panel.
@MainActor
protocol QuickLookPanel: AnyObject {
    /// The panel is up.
    var isShowing: Bool { get }
    /// Put the panel up; it asks its data source what to show.
    func show()
    /// The panel is up and its item changed: ask again.
    func reload()
    /// Take the panel down.
    func close()
}

/// Quick Look's shared panel.
@MainActor
final class SystemQuickLookPanel: QuickLookPanel {
    var isShowing: Bool {
        // Asking `shared()` makes the panel; a question must not.
        QLPreviewPanel.sharedPreviewPanelExists()
            && QLPreviewPanel.shared()?.isVisible == true
    }

    func show() {
        // The panel only becomes key when a click in it needs the keyboard,
        // so the treemap's window keeps its keys: the arrows move the
        // selection, and the preview follows.
        QLPreviewPanel.shared()?.makeKeyAndOrderFront(nil)
    }

    func reload() {
        QLPreviewPanel.shared()?.reloadData()
    }

    func close() {
        if isShowing {
            QLPreviewPanel.shared()?.orderOut(nil)
        }
    }
}

/// A panel that never shows: for `--snapshot`, which may open nothing in
/// front of the person running it.
@MainActor
final class HiddenQuickLookPanel: QuickLookPanel {
    var isShowing: Bool { false }
    func show() {}
    func reload() {}
    func close() {}
}

/// Keeps the preview panel in step with `state.quickLookTarget`, and feeds
/// it while it is up.
@MainActor
final class QuickLookController: NSObject,
    @preconcurrency QLPreviewPanelDataSource,
    @preconcurrency QLPreviewPanelDelegate
{
    let state: AppState
    private let panel: any QuickLookPanel
    /// What the panel was last asked to show.
    private(set) var shown: FilePath?
    /// Where a previewed path is on screen, so the panel can zoom out of
    /// its tile and back into it; `nil` when it is not drawn, and the
    /// panel fades instead.
    var sourceFrame: ((FilePath) -> CGRect?)?

    init(state: AppState, panel: any QuickLookPanel) {
        self.state = state
        self.panel = panel
        super.init()
        follow()
    }

    /// Show whatever the state names now, and again whenever that changes.
    private func follow() {
        let target = withObservationTracking {
            state.quickLookTarget
        } onChange: { [weak self] in
            // Called before the change lands; read the new target after it.
            Task { @MainActor [weak self] in
                self?.follow()
            }
        }
        show(target)
    }

    /// Put the panel up for `target`, move it on to a new one, or take it
    /// down for none.
    private func show(_ target: FilePath?) {
        let previous = shown
        shown = target
        guard target != nil else {
            if panel.isShowing {
                panel.close()
            }
            return
        }
        if !panel.isShowing {
            panel.show()
        } else if previous != target {
            panel.reload()
        }
    }

    /// The panel went away by itself — its close button, or Escape while
    /// it held the keyboard — or another window took it over. Either way
    /// nothing is being previewed, and the state stops saying so.
    func panelClosed() {
        shown = nil
        if state.quickLookTarget != nil {
            state.quickLookTarget = nil
        }
    }

    // MARK: The responder chain's questions

    /// The panel is looking for a controller: this one takes it while
    /// there is something to preview.
    func acceptsControl() -> Bool {
        state.quickLookTarget != nil
    }

    func beginControl(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
    }

    func endControl(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
        panelClosed()
    }

    // MARK: Data source

    func numberOfPreviewItems(in panel: QLPreviewPanel?) -> Int {
        state.quickLookTarget == nil ? 0 : 1
    }

    func previewPanel(
        _ panel: QLPreviewPanel?,
        previewItemAt index: Int
    ) -> (any QLPreviewItem)? {
        state.quickLookTarget.map { Self.item($0) }
    }

    /// A path as the panel takes it: a file URL, which previews a file's
    /// contents and a folder's icon and size.
    static func item(_ path: FilePath) -> NSURL {
        URL(filePath: path.string) as NSURL
    }

    // MARK: Delegate

    /// A key the panel did not take while it had the keyboard: the same
    /// dispatcher the window uses, so the arrows still move the selection
    /// and Escape still closes the preview.
    func previewPanel(_ panel: QLPreviewPanel?, handle event: NSEvent?) -> Bool
    {
        guard let event, let key = KeyStroke(event: event) else {
            return false
        }
        return dispatchKey(key, to: state)
    }

    func previewPanel(
        _ panel: QLPreviewPanel?,
        sourceFrameOnScreenFor item: (any QLPreviewItem)?
    ) -> NSRect {
        guard let target = state.quickLookTarget else {
            return .zero
        }
        return sourceFrame?(target) ?? .zero
    }
}
