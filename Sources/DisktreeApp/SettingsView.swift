// Settings (⌘,): what a launch starts from.
//
// A native grouped form, as System Settings sets one: each group under its
// name, its rows in a rounded well, every control the system's own — a
// stepper, segmented pickers, switches — with a line under each name
// saying what it does and which key changes it as you look. Headed by the
// mark and one sentence on what the pane is for, on the palette's ground.
//
// Every control edits `state.preferences` through `setPreference`, which
// saves to the defaults and applies at once what the run can take: depth,
// colour, the side panel, the command. The scan options wait for the next
// launch, because the tree on screen was measured with the old ones and a
// switch is no place to start a walk of the whole home directory; `i` and
// `d` change them for this run.
//
// The command line still wins for its run, and saves nothing.
//
// Unlike the main window, whose keys all go to the one dispatcher, this
// window's controls take the keyboard themselves, and show where it is.

import AppKit
import DisktreeCore
import SwiftUI

// MARK: - The window

/// The Settings window: one, made when first asked for and kept, so it
/// opens where it was left for the rest of the run.
@MainActor
final class SettingsWindowController: NSWindowController {
    init(state: AppState) {
        let host = NSHostingController(rootView: SettingsView(state: state))
        // The window fits the pane, and follows it when the interface zoom
        // changes its size.
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        // The palette's ground runs up under the title, as it runs under
        // the main window's toolbar, rather than stopping at a grey band.
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.title = "Settings"
        // One Settings window, however many times ⌘, is pressed.
        window.tabbingMode = .disallowed
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

// MARK: - The pane

/// The settings, bound to the state's preferences.
struct SettingsView: View {
    let state: AppState
    /// A fixed theme in place of the system's, for tests.
    let fixedTheme: Theme?
    @Environment(\.colorScheme) private var colorScheme

    init(state: AppState, theme: Theme? = nil) {
        self.state = state
        self.fixedTheme = theme
    }

    var body: some View {
        let theme = fixedTheme ?? systemTheme
        let rem = state.rem
        VStack(spacing: 0) {
            SettingsHero()
            Form {
                Section {
                    // The value beside the arrows, the name level with
                    // both: the stepper's own label spans the row.
                    Stepper(value: binding(\.depth), in: depthRange) {
                        HStack {
                            SettingsLabel("Depth")
                            Spacer(minLength: Space.sm.at(rem))
                            Text("\(state.preferences.depth) levels")
                                .font(TextSize.body.font(rem))
                                .monospacedDigit()
                                .foregroundStyle(theme.foreground.color)
                                .contentTransition(.numericText())
                        }
                    }
                    // The small arrows, a line of text high: the row keeps
                    // the height of its neighbours and its words level with
                    // the arrows.
                    .controlSize(.small)
                    .help("Levels drawn at once")
                    Picker(selection: binding(\.colorMode)) {
                        ForEach(ColorMode.allCases, id: \.self) { mode in
                            Text(Self.label(mode)).tag(mode)
                        }
                    } label: {
                        SettingsLabel("Colour")
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .help("What a tile\u{2019}s colour says")
                    Toggle(isOn: binding(\.showPanel)) {
                        SettingsLabel("Show the selection panel")
                    }
                    .help("Whether the panel shows at launch")
                    // A row, not a section of its own: the pane sizes its
                    // window to fit, and another section's wrapping footer
                    // kept it measuring itself until AppKit gave up.
                    LabeledContent {
                        if TrackpadSetting.allowsHaptics {
                            Text("On")
                                .font(TextSize.body.font(rem))
                                .foregroundStyle(theme.foreground.color)
                        } else if let url = TrackpadSetting.settings {
                            Link(
                                "Off in macOS \u{2014} Trackpad Settings",
                                destination: url
                            )
                            .font(TextSize.body.font(rem))
                        }
                    } label: {
                        SettingsLabel("Haptic feedback")
                    }
                    .help(
                        TrackpadSetting.allowsHaptics
                            ? "A pinch clicks as it comes to rest where a "
                                + "folder fills the view, and taps firmer as "
                                + "it goes in or out."
                            : "\u{201c}Force Click and haptic feedback\u{201d} "
                                + "is off in Trackpad settings, and macOS then "
                                + "drops every app\u{2019}s haptics. Turn it "
                                + "on to feel the stops."
                    )
                } header: {
                    SettingsHeader("Treemap", symbol: "square.grid.2x2")
                } footer: {
                    SettingsFooter(
                        "As you look, [ and ] change the depth, t the "
                            + "colour, and p shows or hides the panel."
                    )
                }
                Section {
                    Toggle(isOn: binding(\.includeHidden)) {
                        SettingsLabel("Hidden files")
                    }
                    .help(
                        "Count files and folders whose names start with a "
                            + "dot, ~/.cache among them."
                    )
                    Toggle(isOn: binding(\.apparentSize)) {
                        SettingsLabel("Apparent size")
                    }
                    .help(
                        "What files say they hold, rather than the space "
                            + "they take on disk, which is what removing them "
                            + "gives back."
                    )
                    Toggle(isOn: binding(\.oneFilesystem)) {
                        SettingsLabel("Stay on one volume")
                    }
                    .help(
                        "Leave out other disks and network shares mounted "
                            + "inside the scanned folder."
                    )
                } header: {
                    SettingsHeader("Scanning", symbol: "magnifyingglass")
                } footer: {
                    SettingsFooter(
                        "From the next launch: i and d change these for this "
                            + "one, and the command line overrides them for "
                            + "its run."
                    )
                }
                Section {
                    Picker(selection: binding(\.commandStyle)) {
                        ForEach(CommandStyle.allCases, id: \.self) { style in
                            Text(style == .trash ? "Trash" : "rm")
                                .tag(style)
                        }
                    } label: {
                        SettingsLabel("Command")
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .help(state.preferences.commandStyle.detail)
                } header: {
                    SettingsHeader("Review", symbol: "checklist")
                } footer: {
                    SettingsFooter(
                        "\(state.preferences.commandStyle.detail). disktree "
                            + "never deletes anything itself: the review "
                            + "copies a command for Terminal, or shows the "
                            + "marks in Finder."
                    )
                }
            }
            .formStyle(.grouped)
            // The palette's ground under the groups, not the window's grey.
            .scrollContentBackground(.hidden)
            // The pane is as tall as its rows: nothing to scroll.
            .scrollDisabled(true)
        }
        .frame(width: Self.width.at(rem), alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        // The window fits the pane, but a form settles its height a pass
        // after it is first measured: the ground fills what it is given,
        // so no band of the window's own grey shows at either edge.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background.color.ignoresSafeArea())
        .tint(theme.accent.color)
        .environment(\.theme, theme)
        .environment(\.rem, rem)
    }

    /// The pane's width: room for the longest label beside its control.
    static let width = Rems(30)

    /// A preference as a control's binding: read from the state's
    /// preferences, written through `setPreference`, which saves it and
    /// applies it.
    func binding<Value: Equatable>(
        _ keyPath: WritableKeyPath<Preferences, Value>
    ) -> Binding<Value> {
        let state = state
        return Binding(
            get: { state.preferences[keyPath: keyPath] },
            set: { state.setPreference(keyPath, $0) }
        )
    }

    /// A colour mode as the choice names it.
    static func label(_ mode: ColorMode) -> String {
        switch mode {
        case .kind: "Kind"
        case .age: "Age"
        }
    }

    /// The theme for the window's appearance, as the main window builds it.
    private var systemTheme: Theme {
        let name: NSAppearance.Name =
            colorScheme == .dark ? .darkAqua : .aqua
        guard let appearance = NSAppearance(named: name) else {
            return colorScheme == .dark ? .dark : .light
        }
        return Theme.system(appearance: appearance)
    }
}

// MARK: - Parts

/// The mark as an app icon, and what the pane is for: the head of the
/// pane, on its ground, as an app's own settings open.
private struct SettingsHero: View {
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    var body: some View {
        let side = Rems(3.5).at(rem)
        let icon = RoundedRectangle(
            cornerRadius: side * 0.225,
            style: .continuous
        )
        HStack(alignment: .center, spacing: Space.md.at(rem)) {
            DisktreeMark()
                .frame(width: side, height: side)
                .clipShape(icon)
                .overlay {
                    icon.strokeBorder(
                        Color.white.opacity(0.25),
                        lineWidth: hairline
                    )
                }
                .shadow(
                    color: MP300.midnightBlue.opacity(0.25).color,
                    radius: Space.xs.at(rem),
                    y: Space.xxs.at(rem)
                )
            VStack(alignment: .leading, spacing: Space.xxs.at(rem)) {
                Text("disktree")
                    .font(TextSize.heading.font(rem, weight: .bold))
                    .foregroundStyle(theme.bright.color)
                Text(
                    "What every launch starts from. The command line still "
                        + "wins for its own run."
                )
                .font(TextSize.caption.font(rem))
                .foregroundStyle(theme.secondary.color)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.xl.at(rem))
        .padding(.top, Space.xl.at(rem))
        .padding(.bottom, Space.sm.at(rem))
    }
}

/// A setting's name, set in the rem scale so the interface zoom reaches
/// this window too. What it does is its tooltip, and the keys that change
/// it as you look are in its group's footer, as System Settings says them.
private struct SettingsLabel: View {
    let title: String
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(TextSize.body.font(rem))
            .foregroundStyle(theme.foreground.color)
    }
}

/// A group's name with its symbol, as System Settings heads one.
private struct SettingsHeader: View {
    let title: String
    let symbol: String
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    init(_ title: String, symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        Label {
            Text(title).foregroundStyle(theme.bright.color)
        } icon: {
            Image(systemName: symbol).foregroundStyle(theme.accent.color)
        }
        .font(TextSize.body.font(rem, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
    }
}

/// What applies to a whole group, under it.
private struct SettingsFooter: View {
    let text: String
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(TextSize.caption.font(rem))
            .foregroundStyle(theme.secondary.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
