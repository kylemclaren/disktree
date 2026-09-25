// The whole window: the screen on show, and what floats over it.
//
// Each screen is a pure reading of `AppState`, so what a screen shows is
// always exactly what the state says — there is no second copy of anything
// to keep in sync. The root adds only what belongs to the window as a whole:
// the theme and the rem every view below reads from the environment, the
// keyboard overlay, the toast, a folder dropped on the window, and the
// one-time offer of Full Disk Access.
//
// Each screen declares its own toolbar, title and subtitle, which the
// hosting controller hands to the window. Only one screen is ever in the
// hierarchy long enough to be asked for them: the one leaving goes at once,
// and the one arriving slides in, so the toolbar changes with the screen in
// one step rather than holding both screens' items for a moment.
//
// Keys are not handled here. On Linux the root element's key listener was
// the dispatcher; on the Mac the shell's event monitor feeds
// `AppState.handleKey`, so no SwiftUI view holds the keyboard but the find
// field, while it is edited.

import AppKit
import DisktreeCore
import SwiftUI
import System

/// The window's content: the explore or review screen, with the keyboard
/// overlay and the toast over it.
public struct RootView: View {
    let state: AppState
    /// A fixed theme in place of the system's: tests and snapshots must not
    /// depend on the machine's appearance or accent colour.
    let fixedTheme: Theme?
    /// Liquid Glass forced on or off, for tests; `nil` follows the window.
    let fixedGlass: Bool?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.accessibilityReduceTransparency) private var opaque
    /// Bumped when a system colour or Increase Contrast changes, so the
    /// theme is built again from the new values.
    @State private var systemColors = 0
    /// The window is on screen: glass has something behind it, and motion
    /// has someone to watch it and a display to run on.
    @State private var onScreen = false
    /// A drag that could be dropped here is over the window.
    @State private var dropping = false
    /// The Full Disk Access sheet is up.
    @State private var offeringAccess = false
    /// The sheet was answered once, either way: it is not offered again,
    /// and the scan totals keep the way to the setting from then on.
    @AppStorage(FullDiskAccess.answeredKey) private var accessAnswered = false

    public init(state: AppState) {
        self.init(state: state, theme: nil)
    }

    init(state: AppState, theme: Theme?, glass: Bool? = nil) {
        self.state = state
        self.fixedTheme = theme
        self.fixedGlass = glass
    }

    public var body: some View {
        let theme = fixedTheme ?? systemTheme
        let rem = state.rem
        let still = !onScreen
        screens
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { HelpOverlay(state: state) }
            .overlayPreferenceValue(ToastAnchor.self) { anchor in
                ToastLayer(state: state, anchor: anchor)
            }
            .overlay {
                if dropping {
                    DropHighlight()
                        .transition(.opacity)
                }
            }
            .animation(ChromeMotion.fade, value: dropping)
            // A window nobody sees has no display to run an animation on,
            // and one started there stops where it began: a snapshot would
            // keep a figure halfway through rolling. Unseen, every change
            // lands at once, as the frame it ends on.
            .transaction { transaction in
                if still {
                    transaction.disablesAnimations = true
                    transaction.animation = nil
                }
            }
            // The screens are laid out under the toolbar; their ground runs
            // up behind it, where the toolbar's controls float over it.
            .background {
                theme.background.color.ignoresSafeArea()
            }
            .foregroundStyle(theme.foreground.color)
            .font(TextSize.body.font(rem))
            // The system's controls — a switch that is on, the toolbar's
            // chosen segment, a focus ring — in the palette's accent rather
            // than the one chosen in System Settings, as the rest of the
            // window is the palette's.
            .tint(theme.accent.color)
            // The window's name when a screen gives none: a screen's own
            // title, deeper in the hierarchy, wins over this one.
            .navigationTitle("disktree")
            // A folder dragged from Finder onto any part of the window is
            // scanned, as one dropped on the Dock icon is. A file alone is
            // refused, so the drag springs back rather than vanish.
            .dropDestination(for: URL.self) { urls, _ in
                Self.accepts(urls, state: state)
            } isTargeted: { targeted in
                dropping = targeted && !DropHighlight.ownDrag
            }
            .chromeIdentifier("disktree-root", container: true)
            .environment(\.theme, theme)
            .environment(\.rem, rem)
            .environment(
                \.floatingGlass,
                fixedGlass ?? (onScreen && !opaque)
            )
            .background {
                WindowPresence { onScreen = $0 }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSColor.systemColorsDidChangeNotification
                )
            ) { _ in
                systemColors &+= 1
            }
            // Increase Contrast is posted on the workspace's own centre,
            // and changes the theme without changing `colorScheme`.
            .onReceive(
                NSWorkspace.shared.notificationCenter.publisher(
                    for: NSWorkspace
                        .accessibilityDisplayOptionsDidChangeNotification
                )
            ) { _ in
                systemColors &+= 1
            }
            .task(id: state.rootPath) {
                await offerFullDiskAccess()
            }
            .sheet(isPresented: $offeringAccess) {
                accessSheet
                    .environment(\.theme, theme)
                    .environment(\.rem, rem)
            }
    }

    /// The screen on show. The review lies to the right of the explore
    /// screen: going there brings it in from a little to the right, and
    /// coming back brings the mosaic in from the left. The screen left
    /// behind goes at once, taking its toolbar with it.
    private var screens: some View {
        ZStack {
            switch state.screen {
            case .explore:
                ExploreView(state: state)
                    .transition(push(from: .leading))
            case .review:
                ReviewView(state: state)
                    .transition(push(from: .trailing))
            }
        }
        .animation(
            ChromeMotion.animation(reduced: reduced), value: state.screen)
    }

    /// A short push in from the `edge` a screen lives on: a nudge, not a
    /// slide across the window, so it reads as going next door. Nothing
    /// leaves by a transition: a screen on its way out would still be asked
    /// for its toolbar, and the window's would show both screens' items.
    /// So the one arriving comes in opaque: faded in over nothing, it let
    /// the bare ground show through for a moment, a flash between the two
    /// screens. With Reduce Motion it fades all the same, as nothing may
    /// slide.
    private func push(from edge: HorizontalEdge) -> AnyTransition {
        let nudge = Space.xxl.at(state.rem) * (edge == .leading ? -1 : 1)
        return .asymmetric(
            insertion: ChromeMotion.transition(
                .offset(x: nudge),
                reduced: reduced
            ),
            removal: .identity
        )
    }

    /// The palette's card for the window's appearance. `colorScheme`
    /// follows the window's effective appearance but drops a high-contrast
    /// name, so `Theme.system` reads Increase Contrast itself; reading
    /// `systemColors` rebuilds it when that setting changes.
    private var systemTheme: Theme {
        _ = systemColors
        let name: NSAppearance.Name =
            colorScheme == .dark ? .darkAqua : .aqua
        guard let appearance = NSAppearance(named: name) else {
            return colorScheme == .dark ? .dark : .light
        }
        return Theme.system(appearance: appearance)
    }

    // MARK: Full Disk Access

    /// Offer Full Disk Access once, when the root is the home directory or
    /// above and macOS privacy is closing folders there; only in a person's
    /// run, the one with somewhere to keep the answer.
    private func offerFullDiskAccess() async {
        guard
            FullDiskAccess.asks(
                answered: accessAnswered,
                remembers: state.preferenceStore != nil,
                root: state.rootPath,
                home: state.home
            )
        else {
            return
        }
        let home = state.home
        let access = await FullDiskAccess.checking(home: home)
        if access == .denied, !Task.isCancelled {
            offeringAccess = true
        }
    }

    /// Whether a drop of `urls` on the window is taken: scanned, when it
    /// holds a folder and is not a tile of this window on its way out.
    ///
    /// Nor a marked folder: a row of the review dragged back over the
    /// window is one on its way to the Trash, and scanning it would put a
    /// root the plan then keeps back under every other mark.
    static func accepts(_ urls: [URL], state: AppState) -> Bool {
        let unmarked = urls.filter { url in
            !state.marks.contains(FilePath(url.path(percentEncoded: false)))
        }
        return !DropHighlight.ownDrag && state.scanDropped(unmarked)
    }

    private var accessSheet: some View {
        let home = state.home
        return FullDiskAccessSheet(
            check: { await FullDiskAccess.checking(home: home) },
            openSettings: {
                NSWorkspace.shared.open(FullDiskAccess.settingsURL)
            },
            scanAgain: {
                accessAnswered = true
                offeringAccess = false
                state.startScan()
            },
            skip: {
                accessAnswered = true
                offeringAccess = false
            }
        )
    }
}

// MARK: - A folder dragged over the window

/// What the window says while a folder is dragged over it: the whole window
/// is the target, outlined in the accent, with the one thing a drop does.
struct DropHighlight: View {
    /// A drag this app began itself is out: a tile dragged from the mosaic
    /// to Finder, a Terminal or the Trash. It starts over this window, but
    /// is not meant for it; the window neither lights up for it nor takes
    /// it. The treemap view sets this while its drag session lasts, from
    /// `dragOut` until the session ends.
    static var ownDrag = false

    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    var body: some View {
        ZStack {
            theme.background.opacity(0.55).color
            // The whole window is the target: a rounded, dashed outline
            // inset from its edge, as a Mac drop area is drawn.
            RoundedRectangle(
                cornerRadius: Rounding.panel.at(rem), style: .continuous
            )
            .strokeBorder(
                theme.accent.color,
                style: StrokeStyle(
                    lineWidth: Space.xxs.at(rem),
                    dash: [Space.sm.at(rem), Space.xs.at(rem)]
                )
            )
            .padding(Space.sm.at(rem))
            VStack(spacing: Space.sm.at(rem)) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: Space.xxl.at(rem)))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(theme.accent.color)
                Text("Drop a folder to scan it")
                    .font(TextSize.title.font(rem, weight: .semibold))
                    .foregroundStyle(theme.bright.color)
                Text("The marks are kept; the treemap starts from there")
                    .font(TextSize.caption.font(rem))
                    .foregroundStyle(theme.secondary.color)
            }
            .padding(Space.xl.at(rem))
            // The app's own surface: glass is kept for what floats over
            // the screen as it is used, and this stands in for the screen.
            .background(
                theme.surface.color,
                in: RoundedRectangle(
                    cornerRadius: Rounding.card.at(rem), style: .continuous)
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: Rounding.card.at(rem), style: .continuous
                )
                .strokeBorder(
                    theme.accent.opacity(0.6).color,
                    lineWidth: hairline
                )
            }
            .shadow(
                color: .black.opacity(theme.isDark ? 0.4 : 0.12),
                radius: Space.lg.at(rem),
                y: Space.xs.at(rem)
            )
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .chromeIdentifier("drop-highlight")
    }
}

// MARK: - Whether the window is on screen

/// Reports whether the window holding it is on screen, and again whenever
/// that changes.
///
/// Liquid Glass is drawn by the window server from what lies behind the
/// window, so it only exists on screen: a window rendered where nobody sees
/// it — a snapshot, a test — has nothing behind it, and its glass comes out
/// as nothing at all. The root gives such a window the plain surfaces
/// instead, which draw the same everywhere.
private struct WindowPresence: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> PresenceView {
        PresenceView(changed: changed)
    }

    func updateNSView(_ view: PresenceView, context: Context) {
        view.changed = changed
    }
}

private final class PresenceView: NSView {
    var changed: (Bool) -> Void
    private var observer: (any NSObjectProtocol)?

    init(changed: @escaping (Bool) -> Void) {
        self.changed = changed
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        // Ordering a window in or out, and covering it whole, all change
        // its occlusion state.
        observer = window.map { window in
            NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
        }
        report()
    }

    private func report() {
        let visible = window?.isVisible ?? false
        // Never from inside the update that moved this view: the answer
        // is state, and state changes wait for the update to end.
        Task { @MainActor [weak self] in
            self?.changed(visible)
        }
    }
}

// MARK: - The window's content

extension RootView {
    /// The window's content view controller: the root, handing the toolbar
    /// and the title each screen declares to the window it is put in, and
    /// never asking the window to fit it. `live` says whether a person sees
    /// the window, and so whether the system can draw its glass.
    static func hostingController(
        state: AppState,
        live: Bool
    ) -> NSHostingController<WindowContent> {
        let host = NSHostingController(
            rootView: WindowContent(state: state, live: live)
        )
        host.sceneBridgingOptions = [.toolbars, .title]
        // The window decides its size, not the content's ideal size: the
        // mosaic fills whatever it is given.
        host.sizingOptions = []
        return host
    }

    /// The root alone, in a hosting view, for a host that has no toolbar to
    /// give it: the screens lay themselves out without one, and the window's
    /// title is left to that host.
    public static func hostingView(state: AppState) -> NSHostingView<RootView> {
        NSHostingView(rootView: RootView(state: state))
    }
}

// MARK: - Identifiers

/// Every chrome identifier drawn in a view's subtree.
///
/// SwiftUI builds its accessibility tree only for an assistive client, so a
/// test cannot walk it offscreen; the identifiers are also collected here,
/// from the views actually in the hierarchy, where a test can read them.
struct ChromeIdentifiers: PreferenceKey {
    static let defaultValue: [String] = []

    static func reduce(value: inout [String], nextValue: () -> [String]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// The accessibility identifier tests and assistive apps find this view
    /// by, as the Rust tests used debug selectors. A `container` groups its
    /// children under it instead of being a leaf.
    func chromeIdentifier(
        _ identifier: String,
        container: Bool = false
    ) -> some View {
        Group {
            if container {
                accessibilityElement(children: .contain)
                    .accessibilityIdentifier(identifier)
            } else {
                accessibilityIdentifier(identifier)
            }
        }
        .transformPreference(ChromeIdentifiers.self) {
            $0.append(identifier)
        }
    }
}

/// A one-point rule across a region: a border between two of them.
struct ChromeRule: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Rectangle()
            .fill(theme.divider.color)
            .frame(height: hairline)
    }
}
