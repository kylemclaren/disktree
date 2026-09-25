// `--keys` and `--snapshot`: the app driven by a script, for looking at its
// screens without a person at the keyboard.
//
// Both wait for the first scan to land, as a person would, then press the
// keys through the same dispatcher the keyboard feeds, letting each one
// settle before the next. A ⌘ chord other than the interface zoom and Quick
// Look is a menu's, so it does nothing here, as it would do nothing in the
// dispatcher; Quick Look's panel never opens in a snapshot.
// A snapshot then renders the window, its buttons included, to a PNG at the
// backing scale and exits.
//
// A snapshot never touches the pasteboard or Finder: a scripted Copy Command
// must not replace what the user last copied, and nothing may open a window
// in front of them.

import AppKit
import DisktreeCore
import Foundation
import System

@MainActor
final class Snapshot {
    /// The longest a snapshot may take, from launch to PNG. A fixture scans
    /// in well under a second; a minute means something is stuck, and a
    /// script waiting on it deserves an answer rather than a hang.
    nonisolated static let timeout = 60

    private let state: AppState
    private let window: NSWindow
    private let keys: [KeyStroke]
    private let output: FilePath?

    /// Press `keys` once the first scan lands, then render to `output`, if
    /// one is given, and exit.
    init(
        state: AppState,
        window: NSWindow,
        keys: [KeyStroke],
        output: FilePath?
    ) {
        self.state = state
        self.window = window
        self.keys = keys
        self.output = output
    }

    func start() {
        if output != nil {
            state.copyToPasteboard = { _ in }
            state.showInFinder = { _ in }
            // `q` among the keys would end the run before the frame it was
            // pressed for.
            state.onQuit = {}
            // Off the main thread, so it fires even when the main thread is
            // the thing that is stuck.
            DispatchQueue.global().asyncAfter(
                deadline: .now() + .seconds(Self.timeout)
            ) {
                Self.fail(
                    "no snapshot after \(Self.timeout) s: the scan, a search "
                        + "or a transition never settled"
                )
            }
        }
        Task { await perform() }
    }

    private func perform() async {
        await settle()
        if let error = state.scanError {
            report("the scan failed: \(error)")
        }
        // The keys act on what is drawn, as a person's would: an arrow
        // moves between tiles and a mark takes the one selected, and the
        // mosaic has no tiles until it has been laid out for its size. A
        // hosting controller lays its view out only when asked, so the
        // tree landing is not yet the mosaic drawn.
        if !keys.isEmpty {
            await flush()
        }
        for key in keys {
            _ = dispatchKey(key, to: state)
            await settle()
        }
        guard let output else {
            return
        }
        await flush()
        do throws(RenderError) {
            let bitmap = try render(to: output)
            print(
                "wrote \(output.string) "
                    + "(\(bitmap.pixelsWide)×\(bitmap.pixelsHigh))"
            )
            exit(0)
        } catch {
            Self.fail(error.message)
        }
    }

    /// Wait until nothing on screen is still moving: the walk has landed or
    /// failed, no search or re-ranking is running, and the layout
    /// transition is over.
    ///
    /// A window that is not on screen has no display link, so the
    /// transition is ticked from here.
    private func settle() async {
        while true {
            let landed = state.tree != nil || state.scanError != nil
            let walking = state.scan != nil && !state.progress.finished
            if landed && !walking && !state.finding
                && state.pendingMetric == nil && !state.tickTransition()
            {
                return
            }
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    /// Give SwiftUI and the mosaic a few turns of the run loop to draw what
    /// the state says now. It takes more than one: the treemap view reports
    /// its size when it is first laid out, and the mosaic is laid out for
    /// that size on the turn after.
    private func flush() async {
        for _ in 0..<4 {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
            await settle()
        }
    }

    /// Render the window into a bitmap at the backing scale, and write it as
    /// a PNG.
    ///
    /// The content runs under the title bar, so the frame around it is the
    /// same size; drawing the frame puts the window's buttons in the
    /// picture too, which is what shows whether the top strip leaves them
    /// their corner and sits level with them.
    private func render(
        to output: FilePath
    ) throws(RenderError) -> NSBitmapImageRep {
        guard let content = window.contentView else {
            throw RenderError("the window has no content")
        }
        let view = content.superview ?? content
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bounds = view.bounds
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds)
        else {
            throw RenderError(
                "cannot make a \(Int(bounds.width))×\(Int(bounds.height)) "
                    + "bitmap"
            )
        }
        view.cacheDisplay(in: bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw RenderError("cannot encode the PNG")
        }
        do {
            try png.write(to: URL(filePath: output.string), options: .atomic)
        } catch {
            throw RenderError(
                "cannot write \(output.string): \(error.localizedDescription)"
            )
        }
        return bitmap
    }

    private func report(_ message: String) {
        FileHandle.standardError.write(Data("disktree: \(message)\n".utf8))
    }

    /// Say why, and exit non-zero: a script must not mistake a missing
    /// snapshot for a taken one.
    nonisolated static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("disktree: \(message)\n".utf8))
        exit(1)
    }
}

/// Why a snapshot could not be written.
private struct RenderError: Error {
    var message: String

    init(_ message: String) {
        self.message = message
    }
}
