// The explore screen's toolbar: where you are, and the controls that decide
// what is measured, as the window's own toolbar items.
//
// The hosting controller hands these to the window's `NSToolbar`, so they
// are the system's controls: a Liquid Glass capsule around each group on
// macOS 26, unified with the title bar on macOS 15, and folded into the
// toolbar's overflow menu by AppKit when the window is too narrow for them.
// The title and subtitle beside them are the screen's (`ExploreView`).
//
// Left to right: the way up, the path (the trail, with a menu of siblings at
// each step) where a window's title would be, then the mode, the two
// switches that change what a scan counts and the depth, the find field,
// and the side panel's switch. None of
// them takes the keyboard from the mosaic: every key still goes through the
// one dispatcher, and each control says the key that does the same.

import AppKit
import DisktreeCore
import SwiftUI

/// Everything in the explore screen's toolbar.
struct ExploreToolbar: ToolbarContent {
    let state: AppState
    /// Whether a person sees the window, where the system draws the glass
    /// and the search field itself (`liveWindow`).
    let live: Bool
    /// How the window's width is shared out among the items.
    let budget: ToolbarBudget

    var body: some ToolbarContent {
        // With the help up, the toolbar waits, as it would behind a sheet.
        let modal = state.showHelp
        ToolbarItem(placement: .navigation) {
            UpButton(state: state).quietFocus(modal: modal)
        }
        .quietWhereGlassCannotShow(live)

        // Where a Finder window has its title: the path is the window's
        // name here, so it stands on the toolbar as a title does, with no
        // glass capsule of its own around it.
        ToolbarItem(placement: .navigation) {
            Trail(state: state, room: budget.path).quietFocus(modal: modal)
        }
        .withoutSharedBackground()

        ToolbarItem {
            ModePicker(state: state).quietFocus(modal: modal)
        }
        .quietWhereGlassCannotShow(live)

        if budget.compact {
            ToolbarItem {
                ViewOptionsMenu(state: state).quietFocus(modal: modal)
            }
            .quietWhereGlassCannotShow(live)
        } else {
            ToolbarItemGroup {
                HiddenFilesToggle(state: state).quietFocus(modal: modal)
                ApparentSizeToggle(state: state).quietFocus(modal: modal)
                DepthMenu(state: state).quietFocus(modal: modal)
            }
            .quietWhereGlassCannotShow(live)
        }

        // On screen the find field is the system's, from `.searchable` on
        // the screen itself; a window nobody sees shows what it would say.
        if !live {
            ToolbarItem {
                FindFieldStandIn(state: state, collapsed: budget.compact)
                    .quietFocus(modal: modal)
            }
            .quietWhereGlassCannotShow(live)
        }

        ToolbarItem {
            PanelToggle(state: state).quietFocus(modal: modal)
        }
        .quietWhereGlassCannotShow(live)
    }
}

/// How the toolbar shares out the window's width: how much the path may
/// take, and whether the switches fold into one menu to leave it a name.
///
/// A toolbar item is as wide as it asks to be, and what does not fit goes
/// into the toolbar's overflow menu, whole. So the items are measured here,
/// in AppKit's toolbar metrics — points, not rem, since a toolbar keeps the
/// system's size whatever the interface zoom — and the path folds, and the
/// switches fold, before anything would have to overflow.
struct ToolbarBudget: Equatable {
    /// Points the path may take.
    var path: CGFloat
    /// The two switches and the depth are one menu, and the find field (a
    /// stand-in's) is its button alone.
    var compact: Bool

    /// The window's close, minimise and zoom buttons, and their margin.
    static let windowButtons: CGFloat = 80
    /// Each item's width and the gap after it.
    static let up: CGFloat = 44
    static let mode: CGFloat = 180
    static let switches: CGFloat = 150
    static let switchesMenu: CGFloat = 56
    static let panel: CGFloat = 44
    static let find = FindField.width + 16
    static let findButton: CGFloat = 44
    /// The toolbar's margins, the flexible space around the path, and the
    /// gaps AppKit sets between items it lays out itself: measured, with
    /// room to spare, since a toolbar a point short puts its last item in
    /// the overflow menu.
    static let margins: CGFloat = 72
    /// The path is never given less than where you are, by name.
    static let leastPath: CGFloat = 140
    /// Below this, the path would be only where you are: the switches fold
    /// first.
    static let roomyPath: CGFloat = 240

    /// The budget for a window `width` points wide whose inspector column,
    /// on screen, takes `inspector` of them; `findInBar` when the find
    /// field sits among the screen's items rather than over the panel.
    init(
        width: CGFloat,
        inspector: CGFloat,
        findInBar: Bool,
        titles: CGFloat
    ) {
        let bar = width - inspector - titles
        func left(compact: Bool) -> CGFloat {
            let find =
                findInBar ? (compact ? Self.findButton : Self.find) : 0
            let items =
                Self.windowButtons + Self.up + Self.mode + Self.panel
                + Self.margins
                + (compact ? Self.switchesMenu : Self.switches) + find
            return bar - items
        }
        compact = left(compact: false) < Self.roomyPath
        path = max(left(compact: compact), Self.leastPath)
    }

    /// The budget for a window `width` points wide. On screen, with the
    /// side panel out, the toolbar's items past the panel's edge sit over
    /// the panel, the search field among them. The explore screen's
    /// toolbar shows no title (`ExploreView`), so the path has its room.
    init(width: CGFloat, inspector: CGFloat, live: Bool) {
        self.init(
            width: width,
            inspector: inspector,
            findInBar: !live || inspector == 0,
            titles: 0
        )
    }
}

extension View {
    /// No keyboard focus ring on a toolbar control: every key goes to the
    /// window's one dispatcher, which takes Tab, Space and Enter for the
    /// mosaic, so a ring would promise the control keys it never gets.
    /// A control can still be clicked, and is read out by VoiceOver.
    func quietFocus() -> some View {
        focusEffectDisabled()
    }

    /// `quietFocus()`, and disabled while something `modal` is up over the
    /// screen.
    func quietFocus(modal: Bool) -> some View {
        focusEffectDisabled().disabled(modal)
    }
}

extension ToolbarContent {
    /// No glass capsule behind the item on macOS 26, on screen or off: for
    /// what stands on the toolbar as its title does.
    @ToolbarContentBuilder
    func withoutSharedBackground() -> some ToolbarContent {
        if #available(macOS 26, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }

    /// Without the glass capsule a macOS 26 toolbar puts behind each item,
    /// where it cannot be drawn: in a window nobody sees, the capsule comes
    /// out as a white blot over the item, white text and all. The item then
    /// stands on the window's ground, as on macOS 15.
    @ToolbarContentBuilder
    func quietWhereGlassCannotShow(_ live: Bool) -> some ToolbarContent {
        if #available(macOS 26, *) {
            sharedBackgroundVisibility(live ? .automatic : .hidden)
        } else {
            self
        }
    }
}

// MARK: - Up

/// Back to the directory holding the one drawn: `⌫`. At the scanned root
/// there is nowhere to go without scanning more, which the path's dimmer
/// steps offer instead. An arrow up, as Finder's Enclosing Folder is ⌘↑:
/// a back chevron would promise a history this button does not keep.
private struct UpButton: View {
    let state: AppState

    var body: some View {
        Button {
            state.ascend()
        } label: {
            Label("Enclosing Folder", systemImage: "arrow.up")
        }
        .disabled(state.parentCrumbs == nil)
        .help("Enclosing folder \u{00b7} \u{232b}")
        .chromeIdentifier("up")
    }
}

// MARK: - What is measured

/// The Size | Files | Age choice: what areas measure, and what colour says.
/// The system's segmented control, whose chosen segment slides.
struct ModePicker: View {
    let state: AppState

    /// The three choices, and what each says of the mosaic.
    static let modes: [(label: String, help: String)] = [
        ("Size", "Areas are sizes, colours are kinds"),
        ("Files", "Areas count files, colours are kinds"),
        ("Age", "Areas are sizes, colours say how long since a write"),
    ]

    var body: some View {
        Picker(
            "Measure by",
            selection: Binding(
                get: { state.modeIndex },
                set: { state.setMode($0) }
            )
        ) {
            ForEach(Self.modes.indices, id: \.self) { index in
                Text(Self.modes[index].label).tag(index)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("\(Self.modes[state.modeIndex].help) \u{00b7} t")
        .chromeIdentifier("mode-choice")
    }
}

/// What the two scan switches do; the keys and the menus say the same.
@MainActor
enum ViewSwitches {
    nonisolated static let hiddenHelp =
        "Count files and folders whose names start with a dot \u{00b7} i"
    nonisolated static let apparentHelp =
        "Measure what files say they hold, not what they take on disk "
        + "\u{00b7} d"

    /// `i`, from a pointer: the scan is measured again either way.
    static func toggleHidden(_ state: AppState) {
        state.options.includeHidden.toggle()
        state.startScan()
    }

    /// `d`, from a pointer.
    static func toggleApparent(_ state: AppState) {
        state.options.apparentSize.toggle()
        state.startScan()
    }
}

/// Hidden files, counted or not: an eye, open while they are.
private struct HiddenFilesToggle: View {
    let state: AppState

    var body: some View {
        let on = state.options.includeHidden
        Toggle(
            isOn: Binding(
                get: { on },
                set: { _ in ViewSwitches.toggleHidden(state) }
            )
        ) {
            Label("Hidden Files", systemImage: on ? "eye" : "eye.slash")
                .contentTransition(.symbolEffect(.replace))
        }
        .toggleStyle(.button)
        .help(ViewSwitches.hiddenHelp)
        .chromeIdentifier("setting-hidden")
    }
}

/// Apparent size or what the disk holds: a scale, lit while sizes are
/// what files say they weigh. A ruler, at a toolbar's size, read as a
/// keyboard.
private struct ApparentSizeToggle: View {
    let state: AppState

    var body: some View {
        Toggle(
            isOn: Binding(
                get: { state.options.apparentSize },
                set: { _ in ViewSwitches.toggleApparent(state) }
            )
        ) {
            Label("Apparent Size", systemImage: "scalemass")
        }
        .toggleStyle(.button)
        .help(ViewSwitches.apparentHelp)
        .chromeIdentifier("setting-apparent")
    }
}

/// Levels drawn at once, one to six, as a menu that says the depth now.
private struct DepthMenu: View {
    let state: AppState

    var body: some View {
        let depth = state.layoutOptions.maxDepth
        Menu {
            Picker(
                "Depth",
                selection: Binding(
                    get: { state.layoutOptions.maxDepth },
                    set: {
                        state.adjustDepth($0 - state.layoutOptions.maxDepth)
                    }
                )
            ) {
                ForEach(1...6, id: \.self) { levels in
                    Text(Self.levels(levels)).tag(levels)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Fewer Levels \u{00b7} [", systemImage: "minus") {
                state.adjustDepth(-1)
            }
            .disabled(depth <= 1)
            Button("More Levels \u{00b7} ]", systemImage: "plus") {
                state.adjustDepth(1)
            }
            .disabled(depth >= 6)
        } label: {
            Label {
                Text("\(depth)")
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(depth)))
            } icon: {
                Image(systemName: "square.stack.3d.up")
            }
            .labelStyle(.titleAndIcon)
        }
        .help("Levels drawn at once \u{00b7} [ and ]")
        .accessibilityLabel("Depth")
        .accessibilityValue(Self.levels(depth))
        .chromeIdentifier("depth")
    }

    static func levels(_ count: Int) -> String {
        count == 1 ? "1 level" : "\(count) levels"
    }
}

/// The two switches and the depth in one menu, for a window with no room
/// for them side by side: the same switches, ticked as they are.
private struct ViewOptionsMenu: View {
    let state: AppState

    var body: some View {
        Menu {
            Toggle(
                "Hidden Files",
                systemImage: "eye",
                isOn: Binding(
                    get: { state.options.includeHidden },
                    set: { _ in ViewSwitches.toggleHidden(state) }
                )
            )
            .help(ViewSwitches.hiddenHelp)
            Toggle(
                "Apparent Size",
                systemImage: "scalemass",
                isOn: Binding(
                    get: { state.options.apparentSize },
                    set: { _ in ViewSwitches.toggleApparent(state) }
                )
            )
            .help(ViewSwitches.apparentHelp)
            Divider()
            Picker(
                "Depth",
                selection: Binding(
                    get: { state.layoutOptions.maxDepth },
                    set: {
                        state.adjustDepth($0 - state.layoutOptions.maxDepth)
                    }
                )
            ) {
                ForEach(1...6, id: \.self) { levels in
                    Text(DepthMenu.levels(levels)).tag(levels)
                }
            }
        } label: {
            Label("View Options", systemImage: "slider.horizontal.3")
        }
        .help("Hidden files, apparent size and depth \u{00b7} i, d, [ and ]")
        .chromeIdentifier("view-options")
    }
}

// MARK: - The panel

/// The side panel, out or away: `p`.
private struct PanelToggle: View {
    let state: AppState

    var body: some View {
        Button {
            state.showSelection.toggle()
        } label: {
            Label("Side Panel", systemImage: "sidebar.right")
        }
        .help(
            (state.showSelection ? "Hide" : "Show")
                + " the selection, the marks and the disk \u{00b7} p"
        )
        // A button, as every Mac app's sidebar button is, that says
        // whether what it shows is out: the state is in the tooltip for
        // the pointer, and here for VoiceOver.
        .accessibilityValue(state.showSelection ? "Shown" : "Hidden")
        .chromeIdentifier("panel-toggle")
    }
}

// MARK: - Find

/// What the find field shows, in a window nobody sees: the system's search
/// field is only drawn on screen. The same prompt, the same text, and the
/// rounded field it sits in; where the toolbar is short of room, only its
/// button, as the system's field folds to one.
private struct FindFieldStandIn: View {
    let state: AppState
    let collapsed: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if collapsed {
                Button {
                    state.beginFind()
                } label: {
                    Label(FindField.prompt, systemImage: "magnifyingglass")
                }
            } else {
                field
            }
        }
        .chromeIdentifier("find-field")
    }

    // A toolbar control keeps the system's size whatever the interface
    // zoom, so these are the system's metrics: its text, the padding and
    // height of a search field in a toolbar.
    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            Text(state.find.isEmpty ? FindField.prompt : state.find)
                .foregroundStyle(state.find.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
        .font(.body)
        .padding(.horizontal, 8)
        .frame(width: FindField.width, height: 28)
        .background(theme.foreground.opacity(0.06).color, in: Capsule())
        .overlay {
            Capsule().strokeBorder(
                (state.findOpen ? theme.accent : theme.divider).color,
                lineWidth: state.findOpen ? 2 : hairline
            )
        }
    }
}

/// The find field's words and width, the same on screen and off.
enum FindField {
    static let prompt = "Filter by name"
    /// Room for a name worth finding, as Finder's search field has.
    static let width: CGFloat = 180
}
