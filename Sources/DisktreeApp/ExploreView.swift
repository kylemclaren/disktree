// The explore screen: find what is eating the volume, and mark it.
//
// The window's toolbar holds where you are, as a path, and what is
// measured. Under it, the legend sits over the mosaic, the status bar —
// what the directory drawn holds, and the scan — closes the column, and the
// side panel — the selection, the marks, what is worth a look and the disk
// — is the window's inspector beside them. While the first walk runs, the
// mosaic's place counts the work instead.
//
// `p` and the toolbar's panel button show and hide the inspector; it slides
// in from the window's edge and the mosaic takes its new width at once,
// since it lays itself out again for any width and doing that on every
// frame of a slide would be wasted work. Its width is the person's: dragged
// at its edge, and kept for the next launch.

import DisktreeCore
import SwiftUI

/// The window's title and subtitle, read in a body of their own: they
/// follow the directory drawn and the walk's counters, and read in the
/// screen's body they rebuilt the whole screen, legend and all, on every
/// level change and every tick of a walk.
private struct ExploreTitle: ViewModifier {
    let state: AppState

    func body(content: Content) -> some View {
        content
            .navigationTitle(ExploreView.title(state))
            .navigationSubtitle(ExploreView.subtitle(state))
    }
}

/// The explore screen, laid out as the Rust `explore()`.
struct ExploreView: View {
    let state: AppState
    @Environment(\.rem) private var rem
    @Environment(\.theme) private var theme
    @Environment(\.liveWindow) private var live
    @Environment(\.accessibilityReduceMotion) private var reduced

    init(state: AppState) {
        self.state = state
    }

    var body: some View {
        GeometryReader { window in
            let width = window.size.width
            let panel = Self.showsPanel(
                selection: state.showSelection,
                width: width,
                rem: rem
            )
            Group {
                if live {
                    column(panel: panel)
                        .inspector(
                            isPresented: Binding(
                                get: { panel },
                                // Only a change the column itself makes:
                                // the panel given way to a narrow window
                                // is still the person's choice to show.
                                set: { shown in
                                    if shown != panel {
                                        state.showSelection = shown
                                    }
                                }
                            )
                        ) {
                            // The panel declares its own column width and
                            // keeps the width it is left at; a reader or a
                            // second width around it would hide its own
                            // from the inspector.
                            SidePanel(state: state)
                        }
                        .modifier(SystemFindField(state: state))
                        // `p` slides the column in and out, as the
                        // toolbar's button does; with Reduce Motion it
                        // only fades.
                        .animation(
                            ChromeMotion.animation(reduced: reduced),
                            value: panel
                        )
                } else {
                    plain(panel: panel, window: width)
                }
            }
            .toolbar {
                ExploreToolbar(
                    state: state,
                    live: live,
                    budget: ToolbarBudget(
                        width: width,
                        inspector: live && panel
                            ? inspectorWidth(window: width) : 0,
                        live: live
                    )
                )
            }
        }
        // The window's title for the Window menu, Mission Control and
        // VoiceOver; the toolbar itself does not show it. The path already
        // ends in the directory drawn, in bold, and the title beside it
        // would say it twice and take the width the path needs. What the
        // directory holds is said in the status bar under the mosaic.
        .modifier(ExploreTitle(state: state))
        .toolbar(removing: .title)
    }

    /// The panel is where the selection, the marks and the disk live; it
    /// only gives way when the mosaic would be too narrow to read, in a
    /// window `width` points wide at `rem` points to the rem.
    nonisolated static func showsPanel(
        selection: Bool,
        width: CGFloat,
        rem: CGFloat
    ) -> Bool {
        selection && width / rem >= PanelSize.shownRems
    }

    // MARK: The column

    /// The legend, the notice while the panel is away, the mosaic and the
    /// status bar, top to bottom.
    private func column(panel: Bool) -> some View {
        VStack(spacing: 0) {
            // The key to the colours, once there are colours to key.
            if state.tree != nil {
                LegendRow(state: state)
            } else {
                Spacer().frame(height: Space.sm.at(rem))
            }
            // The panel carries the notice above the disk; with the panel
            // given way, it would be lost, so it moves under the legend.
            if !panel {
                ExploreNotice(state: state)
            }
            viewport
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // A toast confirms something done here: it sits low over
                // the mosaic, not over the panel.
                .anchorPreference(key: ToastAnchor.self, value: .bounds) {
                    $0
                }
                .padding(.horizontal, Space.lg.at(rem))
                .padding(.bottom, Space.sm.at(rem))
            KeyBar(state: state)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A layer of the whole column rather than of the mosaic, so the
        // tooltip is never clipped at the mosaic's edge.
        .overlayPreferenceValue(TreemapAnchor.self) { anchor in
            if let anchor {
                GeometryReader { screen in
                    CursorTooltip(
                        state: state,
                        treemap: screen[anchor],
                        compact: panel
                    )
                }
                .allowsHitTesting(false)
            }
        }
        .chromeIdentifier("explore-body", container: true)
    }

    /// The mosaic, or while the first walk runs the count of its work, in
    /// one rounded frame, as the window's corners are rounded: a surface
    /// set into the window rather than running square into its edges,
    /// rounded as a card, as the inspector's cards beside it are.
    private var viewport: some View {
        let corner = RoundedRectangle(
            cornerRadius: Rounding.card.at(rem),
            style: .continuous
        )
        return Group {
            if state.tree == nil {
                // The first walk of a home directory takes long enough that
                // an empty viewport would look broken; count the work.
                ScanningPanel(state: state)
            } else {
                TreemapView(state: state)
                    .anchorPreference(
                        key: TreemapAnchor.self,
                        value: .bounds
                    ) { $0 }
                    // The mosaic lays itself out again for its new width;
                    // it does not follow a slide frame by frame.
                    .transaction { $0.animation = nil }
            }
        }
        .clipShape(corner)
        .overlay {
            corner
                .strokeBorder(theme.divider.color, lineWidth: hairline)
                .allowsHitTesting(false)
        }
    }

    // MARK: The panel

    /// The inspector's width, in points, for sharing out the toolbar: the
    /// kept width, within what this window allows. The column itself is
    /// sized by the panel (`SidePanel`), which keeps what it is dragged to.
    private func inspectorWidth(window: CGFloat) -> CGFloat {
        let limits = panelWidthLimits(viewport: window, rem: rem)
        return min(max(state.panelRems, limits.lowerBound), limits.upperBound)
            * rem
    }

    /// In a window nobody sees, where the inspector's glass cannot be drawn,
    /// the same panel in a plain column of the saved width beside the
    /// mosaic, on the app's raised surface. It slides in from the window's
    /// edge, or fades with Reduce Motion, and the mosaic's side takes its
    /// new width at once.
    private func plain(panel: Bool, window: CGFloat) -> some View {
        let limits = panelWidthLimits(viewport: window, rem: rem)
        let rems = min(
            max(state.panelRems, limits.lowerBound),
            limits.upperBound
        )
        let still = reduced
        return HStack(spacing: 0) {
            column(panel: panel)
                // The fade is for the panel's opacity; a width has no
                // fade, and with motion reduced it is simply new.
                .transaction { transaction in
                    if still {
                        transaction.animation = nil
                    }
                }
            if panel {
                SidePanel(state: state)
                    .frame(width: rems * rem)
                    .frame(maxHeight: .infinity, alignment: .top)
                    // A point clear of the toolbar, so the panel's scroll
                    // view does not reach up behind it. One that does is
                    // drawn on macOS 26 through the window server's scroll
                    // edge, which a window nobody sees does not have: the
                    // whole column came out blank, the toolbar's items over
                    // it as white blots. On screen the inspector scrolls
                    // under the toolbar, as it should.
                    .padding(.top, Self.clearOfToolbar)
                    .background {
                        theme.surface.color.ignoresSafeArea()
                    }
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(theme.divider.color)
                            .frame(width: hairline)
                            .ignoresSafeArea()
                    }
                    .transition(
                        ChromeMotion.transition(
                            .move(edge: .trailing),
                            reduced: reduced
                        )
                    )
            }
        }
        .animation(ChromeMotion.animation(reduced: reduced), value: panel)
    }

    /// How far below the toolbar the panel starts in a window nobody
    /// sees: any distance at all keeps its scroll view from running under
    /// the toolbar (`plain(panel:window:)`).
    static let clearOfToolbar: CGFloat = 1

    // MARK: Title

    /// The window's title: the directory drawn, by its own name, as Finder
    /// titles a window. `/` is the one directory whose name is its path.
    static func title(_ state: AppState) -> String {
        let path = state.currentPath
        return path.lastComponent?.string ?? path.string
    }

    /// The subtitle: what the directory drawn holds, and how much of the
    /// scan that is; while the first walk runs, how far it has got. Folders
    /// the scan could not read are counted here, never guessed at.
    static func subtitle(_ state: AppState) -> String {
        let errors = state.progress.errors
        return errors > 0
            ? "\(holds(state)) \u{00b7} \(humanCount(errors)) unreadable"
            : holds(state)
    }

    /// What the directory drawn holds, and how much of the scan that is;
    /// while the first walk runs, how far it has got: the subtitle, less
    /// what could not be read, which the status bar counts on its own.
    static func holds(_ state: AppState) -> String {
        let progress = state.progress
        var parts: [String]
        if let node = state.current, let tree = state.tree {
            parts = [
                humanBytes(node.bytes),
                "\(humanCount(node.files)) files",
            ]
            if state.crumbs.isEmpty {
                parts.append("\(humanCount(node.dirs)) folders")
            } else {
                parts.append("\(percent(node.bytes, of: tree.bytes)) of scan")
            }
        } else if state.scanError != nil {
            parts = ["Scan failed"]
        } else {
            parts = [
                "Scanning\u{2026}",
                "\(humanCount(progress.files)) files",
                humanBytes(progress.bytes),
            ]
        }
        return parts.joined(separator: " \u{00b7} ")
    }
}

// MARK: - The find field

/// The system's search field in the toolbar, bound to the find text.
///
/// `/` opens the find, and the field takes the keyboard; a click in it does
/// the same. While it is edited the window's key monitor steps aside, but
/// for Enter, which lays out only the matches, and Escape, which clears
/// them; either gives the keyboard back to the mosaic, as leaving the field
/// any other way does.
private struct SystemFindField: ViewModifier {
    let state: AppState
    @FocusState private var editing: Bool

    func body(content: Content) -> some View {
        content
            .searchable(
                text: Binding(
                    get: { state.find },
                    set: { state.setFind($0) }
                ),
                placement: .toolbar,
                prompt: Text(FindField.prompt)
            )
            .searchFocused($editing)
            // The key monitor takes Enter first; this is for a field that
            // was given Enter all the same.
            .onSubmit(of: .search) {
                state.applyFilter()
            }
            .onChange(of: state.findOpen, initial: true) {
                if editing != state.findOpen {
                    editing = state.findOpen
                }
            }
            .onChange(of: editing) {
                if editing, !state.findOpen {
                    state.beginFind()
                } else if !editing, state.findOpen {
                    state.endFind()
                }
            }
    }
}
