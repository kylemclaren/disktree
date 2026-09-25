// `disktree`: find what is eating a volume, mark it, and hand the list over.
//
// The window opens on a treemap of the scanned root — the home directory
// unless another path is given — with a trail, a selection panel and a live
// free-space meter. Marking is never destructive, and nothing else here is
// either: disktree removes nothing itself. The review hands the marked list to
// Finder or copies a command for a terminal, and the app notices the marked
// paths go and measures what the disk gained.
//
// AppKit is the bootstrap — the application, its delegate, the menus and one
// window — and SwiftUI draws what is inside the window.

import AppKit
import DisktreeCore
import Foundation
import System

/// The entry point `Sources/disktree/main.swift` calls.
public enum DisktreeMain {
    /// Read the command line, then run the app until it quits.
    ///
    /// A command line that cannot be acted on is refused before any window
    /// exists: the message on stderr, exit status 2. `--help` prints the
    /// usage on stdout and exits 0.
    public static func run() {
        var invocation: Invocation
        do {
            let words = Array(CommandLine.arguments.dropFirst())
            invocation = try parseArguments(words)
            // Read again over the saved preferences, which the flags
            // override for the run; a script sees the app as it ships.
            if case .run(let plain) = invocation, !plain.isScripted {
                invocation = try parseArguments(
                    words,
                    preferences: Preferences(store: UserDefaults.standard)
                )
            }
        } catch {
            FileHandle.standardError.write(Data("disktree: \(error)\n".utf8))
            exit(2)
        }
        guard case .run(let arguments) = invocation else {
            print(usage)
            exit(0)
        }
        // main.swift runs on the main thread; this says so to the compiler.
        MainActor.assumeIsolated {
            launch(arguments)
        }
    }

    @MainActor
    private static func launch(_ arguments: Arguments) {
        // Where AppKit takes an argument that is not an option for a document
        // to open, a PATH, or the `3` of `-d 3`, would come back as a folder
        // dropped on the app and be scanned twice. The command line has been
        // read already.
        UserDefaults.standard.register(defaults: [
            "NSTreatUnknownArgumentsAsOpen": "NO"
        ])
        let app = NSApplication.shared
        let delegate = AppDelegate(arguments: arguments)
        app.delegate = delegate
        // A snapshot takes no place in the Dock or the menu bar: a script
        // runs it, and nobody is meant to switch to it.
        app.setActivationPolicy(
            arguments.snapshot == nil ? .regular : .accessory
        )
        // The application holds its delegate weakly.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let arguments: Arguments
    private let menus = MenuController()
    private var state: AppState?
    private var windowController: MainWindowController?
    private var snapshot: Snapshot?
    /// A folder the app was asked to open before it had finished launching:
    /// dropped on the Dock icon to start it, or chosen with Open With. It is
    /// scanned first, instead of the command line's root, so the home
    /// directory is not walked for nothing on the way.
    private var opened: FilePath?

    init(arguments: Arguments) {
        self.arguments = arguments
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        menus.install(in: NSApplication.shared)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let snapshotting = arguments.snapshot != nil
        let state = AppState(
            root: opened ?? arguments.root,
            options: arguments.options,
            depth: arguments.depth
        )
        state.onQuit = { NSApplication.shared.terminate(nil) }
        if !arguments.isScripted {
            state.adopt(
                Preferences(store: UserDefaults.standard),
                store: UserDefaults.standard
            )
        }
        let controller = MainWindowController(
            state: state,
            onScreen: !snapshotting
        )
        self.state = state
        windowController = controller
        menus.state = state
        menus.window = controller.window
        // Settings left open would keep the app running with no tree to
        // set anything for once the main window is closed.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: controller.window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.menus.closeSettings()
            }
        }
        if !snapshotting {
            controller.showWindow(nil)
            comeForward()
        }
        if snapshotting || !arguments.keys.isEmpty,
            let window = controller.window
        {
            let snapshot = Snapshot(
                state: state,
                window: window,
                keys: arguments.keys,
                output: arguments.snapshot
            )
            self.snapshot = snapshot
            snapshot.start()
        }
    }

    /// The window owns the keyboard from the first frame, so the app comes
    /// to the front, as the Rust one did with `activate(true)`. Started from
    /// a terminal, a plain request is declined: the terminal is the active
    /// app and never yields. The person who typed `disktree` there wants
    /// its window, so activation is asked for on the terminal's behalf.
    private func comeForward() {
        NSApplication.shared.activate()
        let current = NSRunningApplication.current
        if let front = NSWorkspace.shared.frontmostApplication, front != current
        {
            _ = current.activate(from: front, options: [])
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(
        _ app: NSApplication
    ) -> Bool {
        true
    }

    /// Back in front: the marked paths may have been removed in Finder or by
    /// the copied command meanwhile.
    func applicationDidBecomeActive(_ notification: Notification) {
        state?.checkMarks()
    }

    /// Open With, or a folder dropped on the Dock icon: scan it. One window
    /// holds one tree, so of several folders the first is scanned.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let root = urls.lazy.compactMap(scannableFolder).first else {
            return
        }
        guard let state else {
            opened = root
            return
        }
        state.setRoot(root)
        windowController?.showWindow(nil)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        menus.dockMenu()
    }
}

/// A folder from the Dock, Finder or the open panel, canonical as the command
/// line's root is; `nil` for anything that is not a directory disktree can
/// read.
func scannableFolder(_ url: URL) -> FilePath? {
    guard url.isFileURL else {
        return nil
    }
    return try? scannableDirectory(FilePath(url.path(percentEncoded: false)))
}
