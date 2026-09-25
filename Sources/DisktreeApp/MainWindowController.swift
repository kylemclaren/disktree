// The one window: SwiftUI in a hosting controller that hands its toolbar and
// its title to the window, and the key monitor that gives the dispatcher the
// keyboard.
//
// The screens declare their toolbars in SwiftUI; the hosting controller
// bridges them into the window's own `NSToolbar` (`sceneBridgingOptions`),
// so they are the system's: unified with the title bar, Liquid Glass on
// macOS 26, and folded into the overflow menu by AppKit when the window is
// narrow. The window's title and subtitle come from the screen as well.
//
// The treemap owns the keyboard from the first frame. So a key is taken
// before any view sees it, by a local event monitor, and handed to
// `AppState.handleKey`, the one dispatcher. What the dispatcher does not
// take goes on its way, so the menus still get their ⌘ shortcuts. The one
// exception is a text field being edited — the find field in the toolbar —
// which keeps what it types.

import AppKit
import Observation
import Quartz
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    /// The size the window opens at: room for the mosaic, the side panel and
    /// the toolbar at once.
    static let size = CGSize(width: 1440, height: 900)
    /// Below this the treemap stops being readable, so the window does not
    /// go there.
    static let minimumSize = CGSize(width: 900, height: 600)

    let state: AppState
    /// Quick Look's panel, kept in step with `state.quickLookTarget`.
    let quickLook: QuickLookController
    private var keyMonitor: Any?
    private var clickMonitor: Any?

    /// `onScreen: false` builds the same window without placing it for a
    /// person: `--snapshot` renders it where nobody sees it, so a script
    /// never takes the screen or the keyboard focus, and its Quick Look
    /// never opens. Such a window cannot show Liquid Glass, so its chrome
    /// is drawn on plain surfaces (`liveWindow`), and it is drawn as the
    /// window a person works in, active (`UnseenWindow`). `quickLookPanel`
    /// stands in for Quick Look's own panel, for a test.
    init(
        state: AppState,
        onScreen: Bool = true,
        quickLookPanel: (any QuickLookPanel)? = nil
    ) {
        self.state = state
        let window = (onScreen ? NSWindow.self : UnseenWindow.self).init(
            contentRect: CGRect(origin: .zero, size: Self.size),
            styleMask: [
                .titled, .closable, .miniaturizable, .resizable,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false
        )
        // The screens' own ground runs up under the toolbar, so the glass
        // controls float over the palette's cream or navy rather than over
        // a grey bar of the system's.
        window.titlebarAppearsTransparent = true
        // A title and a subtitle, and the controls beside them, on one
        // band: the directory drawn and what it holds.
        window.toolbarStyle = .unified
        window.contentMinSize = Self.minimumSize
        // One window, one tree: tabs would be a second of each.
        window.tabbingMode = .disallowed
        // A new launch scans afresh; there is nothing to restore.
        window.isRestorable = false
        // The controller owns the window; AppKit releasing it on close as
        // well would release it twice.
        window.isReleasedWhenClosed = false
        let host = RootView.hostingController(state: state, live: onScreen)
        // A window takes the size of its content view controller's view,
        // and a hosting view starts a point wide: sized first, so the
        // toolbar is never laid out in a sliver of a window, every item in
        // its overflow menu for a moment.
        host.view.frame = CGRect(origin: .zero, size: Self.size)
        window.contentViewController = host
        window.setContentSize(Self.size)

        quickLook = QuickLookController(
            state: state,
            panel: quickLookPanel
                ?? (onScreen ? SystemQuickLookPanel() : HiddenQuickLookPanel())
        )
        super.init(window: window)
        window.delegate = self
        quickLook.sourceFrame = { [weak self] path in
            self?.treemap?.screenFrame(of: path)
        }
        if onScreen {
            place(window)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            let taken = MainActor.assumeIsolated {
                self?.takes(event) ?? false
            }
            return taken ? nil : event
        }
        clickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.endEditing(for: event)
            }
            return event
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// Open at `size`, or as much of it as the screen has, centred.
    private func place(_ window: NSWindow) {
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            let size = CGSize(
                width: min(Self.size.width, visible.width),
                height: min(Self.size.height, visible.height)
            )
            window.setContentSize(size)
        }
        window.center()
    }

    /// The mosaic's view, wherever SwiftUI put it.
    var treemap: TreemapNSView? {
        window?.contentView.flatMap(Self.treemap(in:))
    }

    private static func treemap(in view: NSView) -> TreemapNSView? {
        if let treemap = view as? TreemapNSView {
            return treemap
        }
        for child in view.subviews {
            if let found = treemap(in: child) {
                return found
            }
        }
        return nil
    }

    // MARK: Keys

    /// Whether the key monitor takes `event` away from AppKit: only while
    /// this window is the key window, so the open panel and the About window
    /// keep their keys, and only what `route` consumes.
    func takes(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.isKeyWindow,
            let key = KeyStroke(event: event)
        else {
            return false
        }
        return route(key)
    }

    /// A key for this window: the dispatcher's, unless a text field is being
    /// edited, which keeps what it types.
    func route(_ key: KeyStroke) -> Bool {
        if isEditingText {
            return findFieldTakes(key)
        }
        return dispatchKey(key, to: state)
    }

    /// A text field has the keyboard: its field editor is first responder.
    var isEditingText: Bool {
        window?.firstResponder is NSText
    }

    /// While the find field is edited it keeps its keys, all but two, which
    /// mean what they mean in the dispatcher's own find: Enter lays out
    /// only the matches and Escape clears the filter. Either way the field
    /// gives the keyboard back to the mosaic. Another text field, should a
    /// screen have one, keeps every key: the find is open only while its
    /// own field is.
    private func findFieldTakes(_ key: KeyStroke) -> Bool {
        guard state.findOpen, !key.command, !key.control, !key.option
        else {
            return false
        }
        switch key.key {
        case "enter":
            state.applyFilter()
        case "escape":
            state.clearFilter()
        default:
            return false
        }
        window?.makeFirstResponder(nil)
        return true
    }

    /// A click on the screen below the toolbar ends editing the find field,
    /// as a click in a list does in Finder. The mosaic takes no keyboard
    /// focus of its own, so without this the field would keep the keys
    /// after the pointer had moved on; its text and matches stay.
    func endEditing(for event: NSEvent) {
        guard let window, event.window === window, isEditingText,
            event.locationInWindow.y < window.contentLayoutRect.maxY
        else {
            return
        }
        window.makeFirstResponder(nil)
    }

    /// A key that nothing took ends its trip through the responder chain
    /// here, after the window, and AppKit would beep.
    override func noResponder(for eventSelector: Selector) {
        if eventSelector == #selector(NSResponder.keyDown(with:)),
            Self.isQuiet(NSApplication.shared.currentEvent)
        {
            return
        }
        super.noResponder(for: eventSelector)
    }

    /// Whether a key nothing took goes without a beep. The Rust app ignores
    /// a key it has no binding for, and so does this one; an unknown ⌘
    /// chord still beeps, as it does in every Mac app.
    static func isQuiet(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .keyDown else {
            return false
        }
        return !event.modifierFlags.contains(.command)
    }

    // MARK: Quick Look

    // The panel asks along the responder chain, where this controller
    // follows the window. AppKit declares the questions nonisolated, and
    // asks them on the main thread.

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel?) -> Bool {
        MainActor.assumeIsolated {
            quickLook.acceptsControl()
        }
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel?) {
        MainActor.assumeIsolated {
            if let panel {
                quickLook.beginControl(panel)
            }
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel?) {
        MainActor.assumeIsolated {
            if let panel {
                quickLook.endControl(panel)
            }
        }
    }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        for monitor in [keyMonitor, clickMonitor].compactMap(\.self) {
            NSEvent.removeMonitor(monitor)
        }
        keyMonitor = nil
        clickMonitor = nil
        state.quickLookTarget = nil
    }
}

// MARK: - The window's content

/// The root view as the window hosts it, told whether a person sees it.
struct WindowContent: View {
    let state: AppState
    let live: Bool

    var body: some View {
        RootView(state: state)
            .environment(\.liveWindow, live)
            .environment(\.bridgesToolbar, true)
            .modifier(KeyLook(unseen: !live))
    }
}

/// A window nobody sees is never made key, so the system's controls in it —
/// a prominent button's tint, a switch that is on — would draw grey, as in
/// a window behind another. A snapshot is a picture of the window a person
/// works in, the key one, so it is drawn as that. A window on screen keeps
/// the state the system gives it.
private struct KeyLook: ViewModifier {
    let unseen: Bool

    func body(content: Content) -> some View {
        if unseen {
            content.environment(\.controlActiveState, .key)
        } else {
            content
        }
    }
}

extension EnvironmentValues {
    /// The window is on screen for a person, where the system draws its own
    /// chrome: the toolbar's Liquid Glass, the search field, the inspector's
    /// column. A window nobody sees — a snapshot, a test — cannot draw glass
    /// at all (it comes out blank, or white over white text), so it is given
    /// the same controls on the app's plain surfaces instead, as macOS 15
    /// draws them.
    @Entry var liveWindow = false

    /// The screens' `.toolbar` content becomes the window's toolbar: the
    /// hosting controller bridges it (`sceneBridgingOptions`). A screen
    /// then declares its actions there from its first frame. Were it to
    /// wait to see the toolbar first, the one it replaced would have taken
    /// its items away, and a window whose screen declares none has no
    /// toolbar to see. A screen hosted any other way — a test's window —
    /// draws its actions itself.
    @Entry var bridgesToolbar = false
}

/// The window `--snapshot` and the tests render, which nobody sees and so
/// is never made key. AppKit draws the controls of a window that is not
/// the active one grey — the toolbar's segments, its switches, the
/// traffic lights — and a still picture of the window a person works in
/// would show every action as disabled. It asks the window whether to draw
/// it active before it asks whether it is key, so this answers that one
/// question and nothing else: the window is still not key, and takes no
/// keys, as it must not in a test.
final class UnseenWindow: NSWindow {
    /// AppKit's own question, which has no public name. Were it renamed,
    /// this would simply never be asked, and the picture would be grey.
    @objc(_hasActiveAppearance)
    private func drawsActive() -> Bool { true }
}
