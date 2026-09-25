// The menu bar, and the Dock icon's menu.
//
// Every item calls the same `AppState` method as its key, so a menu and a key
// can never disagree about what an action does. The menus are where a Mac
// user looks for what an app can do; the keys stay the fast way. The
// dispatcher lets every ⌘ chord through to the menus but the interface zoom
// and Quick Look, whose items call the very methods it does, so the two
// cannot fight over one.

import AppKit

/// Where "disktree on GitHub" goes.
let repository = "https://github.com/kylemclaren/disktree"

@MainActor
final class MenuController: NSObject, NSMenuItemValidation {
    /// Set once the app has finished launching. The menu bar exists before
    /// the state does, so that a folder dropped on the Dock icon at launch is
    /// the first thing scanned; until then the items that need it are off.
    var state: AppState?
    /// The window the open panel is attached to.
    weak var window: NSWindow?
    /// The Settings window, made the first time it is asked for.
    private var settings: SettingsWindowController?

    // MARK: Building

    /// Put the menu bar up, and tell AppKit which menus are its to fill: the
    /// open windows go in Window, the search field in Help.
    func install(in app: NSApplication) {
        let bar = mainMenu()
        app.mainMenu = bar
        app.windowsMenu = bar.item(withTitle: "Window")?.submenu
        app.helpMenu = bar.item(withTitle: "Help")?.submenu
    }

    /// The menu bar: disktree, File, Edit, View, Window, Help.
    func mainMenu() -> NSMenu {
        let bar = NSMenu()
        for menu in [
            appMenu(), fileMenu(), editMenu(), viewMenu(), windowMenu(),
            helpMenu(),
        ] {
            let holder = NSMenuItem(
                title: menu.title,
                action: nil,
                keyEquivalent: ""
            )
            holder.submenu = menu
            bar.addItem(holder)
        }
        return bar
    }

    /// The Dock icon's menu: the one scan worth starting from there.
    func dockMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Scan the Whole Disk", #selector(scanWholeDisk)))
        return menu
    }

    private func appMenu() -> NSMenu {
        let menu = NSMenu(title: "disktree")
        menu.addItem(item("About disktree", #selector(showAbout)))
        menu.addItem(.separator())
        menu.addItem(item("Settings\u{2026}", #selector(showSettings), ","))
        menu.addItem(.separator())
        menu.addItem(
            chained("Hide disktree", #selector(NSApplication.hide), "h")
        )
        menu.addItem(
            chained(
                "Hide Others",
                #selector(NSApplication.hideOtherApplications),
                "h",
                [.command, .option]
            )
        )
        menu.addItem(
            chained("Show All", #selector(NSApplication.unhideAllApplications))
        )
        menu.addItem(.separator())
        menu.addItem(
            chained("Quit disktree", #selector(NSApplication.terminate), "q")
        )
        return menu
    }

    private func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("Open Folder…", #selector(openFolder), "o"))
        menu.addItem(
            item(
                "Scan Whole Disk",
                #selector(scanWholeDisk),
                "g",
                [.command, .shift]
            )
        )
        menu.addItem(item("Rescan", #selector(rescan), "r"))
        menu.addItem(.separator())
        menu.addItem(item("Quick Look", #selector(toggleQuickLook), "y"))
        menu.addItem(.separator())
        menu.addItem(chained("Close", #selector(NSWindow.performClose), "w"))
        return menu
    }

    private func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        // For the review's command block, which is selectable text: without
        // these, ⌘C over a selection would do nothing.
        menu.addItem(chained("Copy", #selector(NSText.copy), "c"))
        menu.addItem(chained("Select All", #selector(NSText.selectAll), "a"))
        menu.addItem(.separator())
        menu.addItem(
            item(
                "Copy Cleanup Command",
                #selector(copyCleanupCommand),
                "c",
                [.command, .shift]
            )
        )
        return menu
    }

    private func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Actual Size", #selector(actualSize), "0"))
        menu.addItem(item("Zoom In", #selector(zoomIn), "="))
        menu.addItem(item("Zoom Out", #selector(zoomOut), "-"))
        menu.addItem(.separator())
        menu.addItem(item("Show All Keys", #selector(showAllKeys), "?", []))
        return menu
    }

    private func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(
            chained("Minimize", #selector(NSWindow.performMiniaturize), "m")
        )
        menu.addItem(chained("Zoom", #selector(NSWindow.performZoom)))
        menu.addItem(.separator())
        menu.addItem(
            chained(
                "Bring All to Front",
                #selector(NSApplication.arrangeInFront)
            )
        )
        return menu
    }

    private func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(item("disktree on GitHub", #selector(openRepository)))
        return menu
    }

    /// An item this controller answers, calling into the state.
    private func item(
        _ title: String,
        _ action: Selector,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = chained(title, action, key, modifiers)
        item.target = self
        return item
    }

    /// An item whose action goes along the responder chain: to the key
    /// window for Close, to selected text for Copy, to the application for
    /// Quit. AppKit enables it when something there answers.
    private func chained(
        _ title: String,
        _ action: Selector,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    // MARK: Actions

    @objc func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(
            string: "A treemap of what is using your disk. It never deletes "
                + "anything itself.",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .credits: credits
        ])
    }

    /// ⌘,: the Settings window, in front.
    @objc func showSettings(_ sender: Any?) {
        guard let state else {
            return
        }
        let settings = settings ?? SettingsWindowController(state: state)
        self.settings = settings
        settings.showWindow(nil)
        settings.window?.makeKeyAndOrderFront(nil)
    }

    /// The main window is going, and Settings with it: they are one app's
    /// window and its settings, and the app ends with the last window.
    func closeSettings() {
        settings?.close()
    }

    /// ⌘Y: the action target in Quick Look, or the preview closed. The
    /// dispatcher takes ⌘Y first while the main window has the keyboard;
    /// this is the menu's way to the same method.
    @objc func toggleQuickLook(_ sender: Any?) {
        state?.toggleQuickLook()
    }

    /// ⌘O: a folder from the open panel, scanned from scratch.
    @objc func openFolder(_ sender: Any?) {
        guard let state else {
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder to scan."
        panel.directoryURL = URL(
            filePath: state.currentPath.string,
            directoryHint: .isDirectory
        )
        let chosen = { (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url,
                let root = scannableFolder(url)
            else {
                return
            }
            state.setRoot(root)
        }
        if let window, window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: chosen)
        } else {
            chosen(panel.runModal())
        }
    }

    /// ⇧⌘G, and the Dock menu: `g`. From the Dock the app may be behind
    /// another, so the window comes forward to show the scan.
    @objc func scanWholeDisk(_ sender: Any?) {
        state?.goToDisk()
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }

    /// ⌘R: `r`.
    @objc func rescan(_ sender: Any?) {
        state?.startScan()
    }

    /// ⇧⌘C: the review's Copy Command, from any screen.
    @objc func copyCleanupCommand(_ sender: Any?) {
        state?.copyCommand()
    }

    /// The interface zoom, through the same method as `⌘0`, `⌘=` and `⌘-`.
    @objc func actualSize(_ sender: Any?) {
        state?.zoomInterface(KeyStroke("0", command: true))
    }

    @objc func zoomIn(_ sender: Any?) {
        state?.zoomInterface(KeyStroke("=", command: true))
    }

    @objc func zoomOut(_ sender: Any?) {
        state?.zoomInterface(KeyStroke("-", command: true))
    }

    /// `?`.
    @objc func showAllKeys(_ sender: Any?) {
        state?.showHelp = true
    }

    @objc func openRepository(_ sender: Any?) {
        if let url = URL(string: repository) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Validation

    /// Whether View › Show All Keys may take `?`. A key equivalent with no
    /// modifier would otherwise take it from whatever else is key, such as
    /// the open panel's fields — or from this window's own search field
    /// while it is typed in, which the key monitor lets `?` through to.
    static func offersAllKeys(
        _ state: AppState,
        windowIsKey: Bool,
        typing: Bool
    ) -> Bool {
        !state.showHelp && windowIsKey && !state.findOpen && !typing
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let independent: Set<Selector> = [
            #selector(showAbout), #selector(openRepository),
        ]
        if let action = menuItem.action, independent.contains(action) {
            return true
        }
        guard let state else {
            return false
        }
        switch menuItem.action {
        case #selector(copyCleanupCommand):
            return state.cleanupCommand() != nil
        case #selector(toggleQuickLook):
            // The item says what it will do: open the preview, or close it.
            menuItem.title =
                state.quickLookTarget == nil ? "Quick Look" : "Close Quick Look"
            return state.quickLookTarget != nil || state.screen == .explore
        case #selector(scanWholeDisk):
            return state.diskRoot != nil
        case #selector(actualSize):
            return state.zoomStep != defaultZoomStep
        case #selector(zoomIn):
            return state.zoomStep < zoomSteps.count - 1
        case #selector(zoomOut):
            return state.zoomStep > 0
        case #selector(showAllKeys):
            return Self.offersAllKeys(
                state,
                windowIsKey: window?.isKeyWindow == true,
                typing: window?.firstResponder is NSText
            )
        default:
            return true
        }
    }
}
