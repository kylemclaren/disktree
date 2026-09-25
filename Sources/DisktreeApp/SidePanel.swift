// The side panel, as the window's inspector: what the keys act on, what is
// marked, what is worth a look, and the disk. Each is a rounded card under a
// header that names it beside its symbol, the way a macOS 26 inspector
// groups what it shows.
//
// The column scrolls as one, as an inspector does, and the disk and the way
// to the review are pinned under it: the number that says what the volume
// has free never leaves the screen, and a card is never cut through by a
// scroll area of its own. What scrolls under the pinned part slips under
// the system's soft edge on macOS 26, and under a hairline before that.
//
// The window hosts it in a native inspector, which the person resizes by
// its edge as any Mac inspector. The panel says how wide it may be — in rem,
// so interface zoom scales the limits with everything it holds — and keeps
// the width it comes to rest at for the next launch. It lays no pane of its
// own on macOS 26, where the inspector is Liquid Glass; on macOS 15 the
// window's ground lies under its cards.
//
// Its numbers roll to their new values when the thing they describe changes
// — a scan landing, a mark — and snap when the selection moves to another
// tile, as Finder's and Xcode's inspectors do, so sweeping the pointer
// across the mosaic does not keep the corner of the eye busy. Its rows
// arrive and leave rather than appear, and answer the pointer as it passes.
// Every movement is short and explains something, and with Reduce Motion
// nothing slides, grows or bounces: what is left is a fade, or nothing.
//
// Nothing here removes anything. The panel marks, unmarks, reveals in
// Finder and opens the review, where the marked list is handed to Finder or
// to a terminal; a marked row can be dragged out to the Dock's Trash, to
// Finder or to Terminal, where what happens to it is theirs. Whatever goes,
// the disk section says so from `statfs`.

import AppKit
import Charts
import DisktreeCore
import SwiftUI
import System

/// The inspector beside the mosaic: the selection, the marks, "worth a
/// look", the last notice and the disk.
///
/// Its width is the inspector's to give: it fills what it is given, and a
/// host that asks for its ideal size gets the kept width. It declares its
/// own `inspectorColumnWidth`, so the host only presents it.
struct SidePanel: View {
    let state: AppState
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(state: AppState) {
        self.state = state
    }

    var body: some View {
        // One plan for the marked list and the disk, so both say the same
        // number, and neither is recomputed when only the pointer moves: the
        // selection reads the pointer in its own view.
        let plan = state.plan()
        let kept = state.panelRems * rem
        ScrollView(.vertical) {
            column(plan: plan)
        }
        .modifier(
            PanelFooter {
                PanelPinned(state: state, plan: plan)
            }
        )
        .frame(
            minWidth: PanelSize.minRems * rem,
            idealWidth: kept,
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .top
        )
        .font(TextSize.body.font(rem))
        .foregroundStyle(theme.foreground.color)
        .background { PanelPane() }
        .modifier(PanelWidthKeeper(state: state))
        // The inspector reads the ideal once, when it first opens; after
        // that the width is the person's, dragged at the edge, and comes
        // back through the keeper above. The limits are read always. This
        // wraps the keeper and not the other way round: a geometry reader
        // around it hides the column width from the inspector, which then
        // opens at its own default and ignores the limits.
        .inspectorColumnWidth(
            min: PanelSize.minRems * rem,
            ideal: kept,
            max: PanelSize.maxRems * rem
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector")
        .accessibilityIdentifier("side-panel")
    }

    /// How long the inspector's width must hold before it is kept: longer
    /// than a frame of a drag or of the inspector sliding in, so only a
    /// width the person let go at is written to the preferences.
    static let widthSettles = Duration.milliseconds(300)

    /// What scrolls, top to bottom: the selection, then the marks once
    /// there are any — the point of marking, so above the suggestions —
    /// then what is worth a look.
    private func column(plan: Plan) -> some View {
        let marking = !state.marks.items.isEmpty
        return VStack(alignment: .leading, spacing: Space.lg.at(rem)) {
            SelectionSection(state: state)
            if marking {
                MarkedSection(state: state, plan: plan)
                    .transition(.opacity)
            }
            WorthSection(state: state)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.lg.at(rem))
        .animation(reduceMotion ? nil : PanelMotion.rows, value: marking)
    }
}

/// The part of the panel that stays put under the scrolling column: the
/// last notice, the disk and the way to the review.
private struct PanelPinned: View {
    let state: AppState
    let plan: Plan
    @Environment(\.rem) private var rem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm.at(rem)) {
            NoticeLine(state: state)
            DiskSection(state: state, plan: plan)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.lg.at(rem))
        .padding(.top, Space.md.at(rem))
        .padding(.bottom, Space.lg.at(rem))
        // A notice arriving takes room from the column above it: the two
        // move together, briefly. With Reduce Motion the column gives way
        // at once, since closing up is movement, and the notice fades in
        // by its own transition's animation.
        .animation(
            reduceMotion ? nil : PanelMotion.rows,
            value: NoticeLine.key(state)
        )
    }
}

/// Pins `pinned` under the scrolling column.
///
/// On macOS 26, on screen, it is a bar the scroll view knows about: what
/// scrolls under it fades beneath the system's soft edge, over the
/// inspector's glass. Elsewhere — macOS 15, or a window nobody sees, where
/// no edge effect is drawn — it stands on the pane's own ground behind a
/// hairline, as a Finder window's status bar does, so a row scrolling under
/// it is covered rather than read through.
private struct PanelFooter<Pinned: View>: ViewModifier {
    @ViewBuilder let pinned: () -> Pinned
    @Environment(\.liveWindow) private var live

    func body(content: Content) -> some View {
        if #available(macOS 26, *), live {
            content
                .safeAreaBar(edge: .bottom, spacing: 0) { pinned() }
                .scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            content
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    pinned()
                        .background { PanelFooterGround() }
                }
        }
    }
}

/// The ground of the pinned part where there is no edge effect: the
/// pane's colour, so it covers what scrolls under it, and a hairline along
/// its top.
private struct PanelFooterGround: View {
    @Environment(\.theme) private var theme

    var body: some View {
        PanelPane(plain: theme.surface)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(theme.divider.color)
                    .frame(height: hairline)
            }
    }
}

/// What lies under the cards. On macOS 26 nothing: the inspector is Liquid
/// Glass, drawn by the system behind them, and a fill here would hide it.
/// Before that the inspector has no glass to show, and the window's own
/// ground takes its place, so the cards rise off the same cream or navy the
/// mosaic sits on.
///
/// Given a `plain` colour, it is solid on macOS 26 too: the ground under
/// the pinned part, which must hide what scrolls beneath it. Off screen
/// the explore screen lays the panel on the theme's raised surface, and
/// that is the colour then.
struct PanelPane: View {
    var plain: HSLA?
    @Environment(\.theme) private var theme

    var body: some View {
        if #available(macOS 26, *) {
            if let plain {
                plain.color
            } else {
                Color.clear
            }
        } else {
            theme.background.color
        }
    }
}

extension Theme {
    /// The accent as the fill of a prominent button, under the white
    /// label the system sets on it. On the dark card the accent is Sweet
    /// Escape lightened to read as text on the navy, and white on that
    /// falls near 3:1; the palette's violet itself keeps nearly 5:1. On the
    /// light card the accent is Indigo Blue, under which white is 10:1.
    var inspectorAccent: HSLA {
        isDark ? MP300.sweetEscape : accent
    }
}

// MARK: - The width

extension AppState {
    /// The inspector came to rest `width` points wide: that is the panel's
    /// width from now on, kept for the next launch in rem, within its
    /// limits.
    ///
    /// Only while the panel is meant to show: hidden, or on its way out,
    /// the width is an animation's, not a choice. And only a change of half
    /// a point or more: the split view rounds to the pixel, and a rounding
    /// must not rewrite the preference.
    func keepPanelWidth(_ width: CGFloat) {
        guard showSelection, width.isFinite, width > 0 else { return }
        guard abs(width - panelRems * rem) >= 0.5 else { return }
        panelRems = min(
            max(width / rem, PanelSize.minRems),
            PanelSize.maxRems
        )
    }
}

/// Keeps the width the inspector settles at. The width is reported, never
/// read back into the layout that measured it: the inspector's ideal is
/// read only when it opens, so writing the width here cannot move the edge
/// under the person's pointer, or schedule another layout pass after this
/// one.
private struct PanelWidthKeeper: ViewModifier {
    let state: AppState
    @State private var settler = PanelWidthSettler()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { [state, settler] width in
                settler.settle(width) { state.keepPanelWidth($0) }
            }
            .onDisappear { settler.cancel() }
    }
}

/// Waits for a width to hold for `SidePanel.widthSettles` before it is
/// kept; a new width replaces the one waiting.
///
/// A run-loop timer in the default mode rather than a task: while the
/// person drags the inspector's edge the run loop tracks the drag in a mode
/// of its own, so nothing is kept until the edge is let go; and the width
/// is kept whatever the main queue is doing, as a timer fires in any loop
/// that runs, a test's included.
@MainActor
private final class PanelWidthSettler {
    private var timer: Timer?

    func settle(
        _ width: CGFloat,
        keep: @escaping @MainActor (CGFloat) -> Void
    ) {
        timer?.invalidate()
        let seconds =
            Double(SidePanel.widthSettles.components.seconds)
            + Double(SidePanel.widthSettles.components.attoseconds) / 1e18
        timer = Timer.scheduledTimer(
            withTimeInterval: seconds,
            repeats: false
        ) { _ in
            // Scheduled on the main run loop, so it fires on the main
            // thread.
            MainActor.assumeIsolated { keep(width) }
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Headers and tiles

/// A section's header over its card: its name beside the symbol that stands
/// for it, a count when it has one, and on the right what it adds up to.
struct PanelHeader<Accessory: View>: View {
    let title: String
    let symbol: String
    let count: Int?
    let accessory: Accessory
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    init(
        _ title: String,
        symbol: String,
        count: Int? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.symbol = symbol
        self.count = count
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: Space.sm.at(rem)) {
            HStack(spacing: Space.xs.at(rem) + Space.xxs.at(rem)) {
                // The accent marks the symbols as the panel's wayfinding;
                // the words stay in the text colours, where they read.
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(theme.accent.color)
                    .frame(width: IconSize.md.at(rem))
                    .accessibilityHidden(true)
                Text(title)
                    .foregroundStyle(theme.bright.color)
                    .lineLimit(1)
                if let count, count > 0 {
                    PanelCountBadge(count: count, color: theme.secondary)
                }
            }
            .font(TextSize.body.font(rem, weight: .semibold))
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                count.map { $0 > 0 ? "\(title), \($0)" : title } ?? title
            )
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Space.sm.at(rem))
            accessory
        }
        // In from the card's edge by what the card's content is, so the
        // header's symbol stands over the card's first column.
        .padding(.horizontal, Space.xs.at(rem))
    }
}

extension PanelHeader where Accessory == EmptyView {
    init(_ title: String, symbol: String, count: Int? = nil) {
        self.init(title, symbol: symbol, count: count) { EmptyView() }
    }
}

/// A count in a capsule, rolling to its new value: how many are marked.
struct PanelCountBadge: View {
    let count: Int
    let color: HSLA
    @Environment(\.rem) private var rem

    var body: some View {
        Text("\(count)")
            .font(TextSize.caption.rounded(rem, weight: .bold))
            .foregroundStyle(color.color)
            .padding(.horizontal, Space.xs.at(rem) + Space.xxs.at(rem))
            .padding(.vertical, Space.xxs.at(rem) / 2)
            .background(color.opacity(0.14).color, in: Capsule())
            .panelRolling(Double(count))
    }
}

/// A symbol on a rounded tile washed in its colour, as macOS sets a
/// setting's or a file's icon in a list: the kind of the thing at a glance,
/// before its name is read.
struct PanelIconTile: View {
    let symbol: String
    let tint: HSLA
    let side: Rems
    @Environment(\.rem) private var rem

    /// The selection's tile, beside its name at heading size.
    static let selection = Rems(2.25)
    /// A finding's tile, beside two lines of a row.
    static let row = Rems(1.75)

    var body: some View {
        let side = side.at(rem)
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            // Half the tile: the symbol's own padding leaves it the optical
            // weight of an icon in a Finder list.
            .font(.system(size: side * 0.46, weight: .semibold))
            .foregroundStyle(tint.color)
            .frame(width: side, height: side)
            .background(
                tint.opacity(0.16).color,
                in: roundedShape(Rounding.control, rem: rem)
            )
            .accessibilityHidden(true)
    }
}

/// A line that stands in for a card's content: why there is none yet.
struct PanelPlaceholder: View {
    let text: String
    let symbol: String
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    init(_ text: String, symbol: String) {
        self.text = text
        self.symbol = symbol
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm.at(rem)) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(TextSize.caption.font(rem))
        .foregroundStyle(theme.secondary.color)
        .padding(.horizontal, Space.sm.at(rem))
        .padding(.vertical, Space.sm.at(rem))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Motion

/// How the panel moves: briefly, and only to say what changed. Every
/// duration is under a quarter of a second, long enough to follow and
/// short enough never to wait for.
enum PanelMotion {
    /// A figure rolling to its new value, a ring sweeping to its share.
    static let figure = Animation.snappy(duration: 0.22)
    /// Marked rows arriving and leaving, and the rows below closing up.
    static let rows = Animation.snappy(duration: 0.24)
    /// A line drawn through a row whose path has gone from disk.
    static let strike = Animation.easeOut(duration: 0.2)
    /// What Reduce Motion keeps: a fade, in place.
    static let fade = Animation.easeInOut(duration: 0.18)
    /// A row answering the pointer: a colour, not a movement, so Reduce
    /// Motion keeps it.
    static let hover = ChromeMotion.hover
}

extension View {
    /// A figure that rolls to its new value, digit by digit, instead of
    /// blinking; `value` says which way it rolls. Monospaced digits keep
    /// the figure's width still while it does. With Reduce Motion it
    /// cross-fades.
    func panelRolling(_ value: Double) -> some View {
        modifier(PanelRolling(value: value))
    }

    /// Two views read as one element: a figure's name and its value, the
    /// way VoiceOver should say them.
    func panelFigure(_ label: String, _ value: String) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value)
    }
}

/// `panelRolling(_:)`. The transition is an environment value, so it
/// reaches every text inside: a `Measure` rolls its number and its unit
/// together.
private struct PanelRolling: ViewModifier {
    let value: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .monospacedDigit()
            .contentTransition(
                reduceMotion ? .opacity : .numericText(value: value)
            )
            .animation(
                reduceMotion ? PanelMotion.fade : PanelMotion.figure,
                value: value
            )
    }
}

// MARK: - What the controls say

/// What the panel's controls say when the pointer rests on them: what the
/// control does and, where a key does the same from anywhere in the
/// window, that key.
enum PanelHelp {
    static let open = "Open it in the mosaic · Enter"
    static let reveal = "Show it selected in Finder · f"
    static let mark =
        "Mark it for the review; nothing is removed here · Space"
    static let unmark = "Take it off the marked list · Space"
    static let review =
        "Review the marks, then hand them to Finder or Terminal · c"
    static let unmarkRow = "Unmark: take it off the list, and keep it"
    static let git =
        "What git says: changes not committed, stashes, commits not pushed"
    static let meter =
        "Used space around the ring; the highlighted arc is what the marks "
        + "still on disk would give back"
    static let share = "Its share of everything the scan measured"

    /// Inside a marked directory there is nothing to mark on its own.
    static func covering(_ name: String) -> String {
        "It goes with the marked \(name): unmark that to keep this"
    }

    /// A finding's row: its whole path, which the row cuts to two parts.
    static func finding(_ path: String) -> String {
        "\(path)\nShow it in its directory"
    }

    /// A marked row: its whole path, which the row cuts in the middle, and
    /// what the row does with a click and with a drag.
    static func marked(_ path: String) -> String {
        "\(path)\nClick to show it in the mosaic; drag it to the Trash, "
            + "Finder or Terminal"
    }
}

// MARK: - Selection

/// What the keys act on: its name and place, its size set large beside its
/// share of the scan, how many files, when it was last written, its kind or
/// what git says, and the things to do with it.
///
/// Its own view, because it follows the pointer: a hover redraws this and
/// nothing else in the panel.
struct SelectionSection: View {
    let state: AppState
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    var body: some View {
        let target = state.actionTarget ?? state.crumbs
        VStack(alignment: .leading, spacing: Space.sm.at(rem)) {
            PanelHeader("Selection", symbol: "scope")
            Group {
                if let node = state.node(at: target) {
                    SelectionDetail(state: state, target: target, node: node)
                        // A new identity per tile: the pointer moving to
                        // another tile is not the size changing, and the
                        // figures, the ring and the counts snap to the new
                        // tile's rather than roll, as an inspector does on
                        // a change of selection. The same tile's numbers
                        // changing — a scan landing — still roll.
                        .id(target)
                } else {
                    PanelPlaceholder(
                        "Point at a tile or select one with the arrows",
                        symbol: "cursorarrow.rays"
                    )
                }
            }
            .cardSurface()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The last part of a path, for a label with little room.
    static func shortName(_ path: FilePath) -> String {
        path.lastComponent?.string ?? path.string
    }
}

/// The selection, once there is a node to describe.
private struct SelectionDetail: View {
    let state: AppState
    let target: [Int]
    let node: Node
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    var body: some View {
        let path = state.path(at: target)
        let marked = path.map { state.marks.contains($0) } ?? false
        // Inside a marked directory it goes with that directory: said in a
        // badge, and the mark button offers to unmark the directory.
        let ancestor = path.flatMap { state.markedAncestor(of: $0) }
        let checkout = checkout(path)
        VStack(alignment: .leading, spacing: Space.md.at(rem)) {
            identity(path)
            measure
            facts(checkout: checkout)
            badges(marked: marked, ancestor: ancestor)
            actions(marked: marked, ancestor: ancestor)
        }
        // Git is asked once per checkout, off the main actor, and only
        // while a checkout is what the panel shows; never from `body`.
        .task(id: checkout) {
            if let checkout {
                state.ensureGit(checkout)
            }
        }
    }

    /// The directory on screen: it has no Open and no mark here.
    private var isCurrentRoot: Bool { target == state.crumbs }

    /// The selection's path, when it is a directory git can say something
    /// about.
    private func checkout(_ path: FilePath?) -> FilePath? {
        guard node.isDir, let path, isCheckout(path) else { return nil }
        return path
    }

    /// Its icon in its kind's colour, its name, and where it is.
    private func identity(_ path: FilePath?) -> some View {
        let place = path.map { displayPath($0, home: state.home) } ?? ""
        return HStack(spacing: Space.sm.at(rem)) {
            PanelIconTile(
                symbol: node.isDir ? "folder.fill" : "doc.fill",
                tint: theme.categoryAccent(node.category),
                side: PanelIconTile.selection
            )
            VStack(alignment: .leading, spacing: Space.xxs.at(rem)) {
                Text(node.name)
                    .font(TextSize.heading.font(rem, weight: .semibold))
                    .foregroundStyle(theme.bright.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // Cut in the middle, as a Mac cuts a path: the top of it
                // and the directory it is in both stay readable.
                Text(place)
                    .font(TextSize.caption.font(rem))
                    .foregroundStyle(theme.secondary.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(place)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(node.name)
        .accessibilityValue(
            "\(node.isDir ? "folder" : node.category.label) in \(place)"
        )
        .accessibilityAddTraits(.isHeader)
    }

    /// Its size, set large in SF Pro Rounded, beside a ring that is its
    /// share of the scan in the highlight. The number rolls and the ring
    /// sweeps as the selection moves from tile to tile.
    private var measure: some View {
        let rootValue = state.tree?.bytes ?? 0
        let metric = state.options.metric
        let (number, unit) =
            switch metric {
            case .bytes: splitSize(humanBytes(node.bytes))
            case .files: (humanCount(node.files), "files")
            }
        let share = Double(node.bytes) / Double(max(rootValue, 1))
        let written = percent(node.bytes, of: rootValue)
        return HStack(alignment: .center, spacing: Space.md.at(rem)) {
            Measure(
                number,
                size: TextSize.display,
                unit: unit,
                unitSize: TextSize.title
            )
            // A long size in a narrow panel at a large zoom gives a little
            // of its size rather than its last digit.
            .minimumScaleFactor(0.6)
            .panelRolling(Double(node.value(metric)))
            .frame(maxWidth: .infinity, alignment: .leading)
            PanelShareRing(share: share, label: written)
                .help(PanelHelp.share)
        }
        .panelFigure("Size", "\(number) \(unit), \(written) of the scan")
    }

    /// Files, last write, and either its kind or, for a checkout, what git
    /// says: an inspector's rows, each a symbol, a name and a value.
    private func facts(checkout: FilePath?) -> some View {
        let files = humanCount(node.files)
        let written = ago(now: nowSeconds(), then: node.modified)
        return VStack(spacing: 0) {
            PanelFact("Files", symbol: "doc.on.doc", value: files)
                .panelRolling(Double(node.files))
            PanelFactDivider()
            PanelFact("Last write", symbol: "clock", value: written)
            PanelFactDivider()
            fourth(checkout: checkout)
        }
    }

    /// Git for a checkout, the kind for everything else.
    @ViewBuilder
    private func fourth(checkout: FilePath?) -> some View {
        if let checkout {
            // Asked and answered, asked and unreadable, or still asking.
            let (value, clean): (String, Bool) =
                switch state.git[checkout] {
                case .some(.some(let git)): (git.summary, git.isClean)
                case .some(.none): ("not readable", false)
                case .none: ("asking…", false)
                }
            // The line that says whether work would be lost wraps under
            // itself rather than lose its end: "2 unpushed" is the part
            // that matters, and a narrow panel cuts it off. Three lines
            // hold its three parts at any width one part fits.
            PanelFact(
                "Git",
                symbol: "arrow.triangle.branch",
                value: value,
                color: clean ? theme.success : nil,
                lines: 3
            )
            .help(PanelHelp.git)
        } else {
            let kind =
                node.reclaim.map { "\(node.category.label) · \($0.label)" }
                ?? node.category.label
            PanelFact(
                "Kind",
                symbol: SymbolName.kind(node.category, isDir: node.isDir),
                value: kind
            )
        }
    }

    /// Only states that change the decision earn a badge. "Marked" only
    /// where no button says so already: beside the mark button it would
    /// say what the button's own label and symbol say, and appearing above
    /// the button as it is pressed would push the button down from under
    /// the pointer, so that a second click landed on the row above it.
    @ViewBuilder
    private func badges(marked: Bool, ancestor: FilePath?) -> some View {
        let chips: [(String, HSLA, String)] = [
            marked && isCurrentRoot
                ? ("Marked", theme.danger, "checkmark.circle.fill") : nil,
            ancestor.map {
                (
                    "Goes with \(SelectionSection.shortName($0))",
                    theme.danger, "link"
                )
            },
            node.readError
                ? (
                    "Partly unreadable", theme.caution,
                    "exclamationmark.triangle.fill"
                ) : nil,
        ]
        .compactMap { $0 }
        if !chips.isEmpty {
            WrappingRow(spacing: Space.xs.at(rem)) {
                ForEach(chips.indices, id: \.self) { index in
                    Chip(
                        chips[index].0,
                        color: chips[index].1,
                        systemImage: chips[index].2
                    )
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// Open and Reveal in Finder are secondary, bordered: Enter and `f`
    /// already do them. Marking is the action this tool exists for, so it
    /// is the prominent button, in the highlight, on a row of its own.
    private func actions(marked: Bool, ancestor: FilePath?) -> some View {
        VStack(spacing: Space.sm.at(rem)) {
            // Side by side while both labels fit; one over the other in a
            // narrow panel, rather than cut to "Reveal in Fi…".
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.sm.at(rem)) { secondaryButtons }
                VStack(spacing: Space.sm.at(rem)) { secondaryButtons }
            }
            // A bordered button draws its label in the tint.
            .tint(secondaryInk)
            // The directory on screen has no Open and no mark here: it is
            // open already, and it is marked from its parent's view, where
            // it is a tile. The scanned root cannot be marked at all.
            if !isCurrentRoot {
                markButton(marked: marked, ancestor: ancestor)
            }
        }
        .controlSize(.large)
        // Keys go to the window's one dispatcher; a focus ring would say a
        // button owns them.
        .focusEffectDisabled()
    }

    /// A button's label, set on the label itself: a native button sets its
    /// own control font over the one the panel passes down, and would stay
    /// one size at every interface zoom. Set here, the bezel grows with the
    /// label, as everything else in the panel does.
    static func buttonFont(
        _ rem: CGFloat,
        weight: Font.Weight = .medium
    ) -> Font {
        TextSize.body.font(rem, weight: weight)
    }

    @ViewBuilder private var secondaryButtons: some View {
        if !isCurrentRoot && node.isDir {
            Button {
                state.goTo(target)
            } label: {
                // Going into it, as a navigation: a forward arrow, where
                // the full-screen arrows would say "enlarge".
                Label("Open", systemImage: "arrow.forward.circle")
                    .font(Self.buttonFont(rem))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .help(PanelHelp.open)
        }
        Button {
            state.revealInFinder(target)
        } label: {
            Label("Reveal in Finder", systemImage: "folder")
                .font(Self.buttonFont(rem))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .help(PanelHelp.reveal)
    }

    /// The secondary buttons' ink: the text colour, not the accent the
    /// window tints its controls with, so only Mark carries a colour and
    /// the two bordered ones read as its quieter neighbours — on the navy
    /// the accent's text on a faint bezel all but vanished.
    private var secondaryInk: Color { theme.bright.color }

    /// Inside a marked directory there is nothing to mark on its own: it
    /// goes with that directory, so the button offers to keep it by
    /// unmarking the directory instead.
    ///
    /// One button whatever it says, tinted by what it will do: the
    /// highlight to mark, the accent to take a mark off. Only the tint and
    /// the words change, so the symbol inside can turn from an empty
    /// circle to a check in place.
    private func markButton(marked: Bool, ancestor: FilePath?) -> some View {
        let covering = marked ? nil : ancestor
        let (label, help) =
            if let covering {
                (
                    "Unmark \(SelectionSection.shortName(covering))",
                    PanelHelp.covering(SelectionSection.shortName(covering))
                )
            } else if marked {
                ("Unmark", PanelHelp.unmark)
            } else {
                ("Mark for removal", PanelHelp.mark)
            }
        let marking = !marked && ancestor == nil
        return Button {
            if let covering {
                state.unmark(covering)
            } else {
                state.toggleMark(target)
            }
        } label: {
            Label {
                Text(label)
                    .lineLimit(1)
            } icon: {
                // A new identity per tile: moving the selection to a tile
                // marked differently is not a mark toggling, and must not
                // bounce as one.
                PanelMarkSymbol(on: marked || covering != nil)
                    .id(target)
            }
            .font(Self.buttonFont(rem, weight: .semibold))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint((marking ? theme.highlight : theme.inspectorAccent).color)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityHint(help)
        .accessibilityIdentifier("panel-mark")
    }
}

/// One fact about the selection, as an inspector lists them: its symbol
/// and name on the left in the dim colour, its value on the right in SF Pro
/// Rounded, where the eye runs down a column of them.
private struct PanelFact: View {
    let label: String
    let symbol: String
    let value: String
    let color: HSLA?
    /// How many lines the value may take before it is cut.
    let lines: Int
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    init(
        _ label: String,
        symbol: String,
        value: String,
        color: HSLA? = nil,
        lines: Int = 1
    ) {
        self.label = label
        self.symbol = symbol
        self.value = value
        self.color = color
        self.lines = lines
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm.at(rem)) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm.at(rem)) {
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
                    // One slot for every symbol, so the names line up
                    // however wide each symbol is drawn.
                    .frame(width: IconSize.md.at(rem))
                    .accessibilityHidden(true)
                Text(label)
            }
            .foregroundStyle(theme.secondary.color)
            .fixedSize()
            Spacer(minLength: Space.sm.at(rem))
            Text(value)
                .font(TextSize.body.rounded(rem, weight: .medium))
                .monospacedDigit()
                .foregroundStyle((color ?? theme.bright).color)
                .multilineTextAlignment(.trailing)
                .lineLimit(lines)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: lines > 1)
        }
        .padding(.vertical, Space.xs.at(rem) + Space.xxs.at(rem))
        .panelFigure(label, value)
    }
}

/// The hairline between two facts, from under the first name to the card's
/// edge, as a grouped list inset its separators.
private struct PanelFactDivider: View {
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    var body: some View {
        Rectangle()
            .fill(theme.divider.color)
            .frame(height: hairline)
            .padding(.leading, IconSize.md.at(rem) + Space.sm.at(rem))
            .accessibilityHidden(true)
    }
}

/// The selection's share of the scan, as a ring swept in the highlight
/// over a faint track, with the percentage inside. Swift Charts draws it,
/// so a new share sweeps the arc to its new angle.
private struct PanelShareRing: View {
    let share: Double
    let label: String
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// About the height of the size beside it.
    static let side = Rems(3.25)

    var body: some View {
        let side = Self.side.at(rem)
        let share = min(max(share, 0), 1)
        Chart {
            SectorMark(
                angle: .value("Share", share),
                innerRadius: .ratio(0.74)
            )
            .foregroundStyle(theme.highlight.color)
            .cornerRadius(side / 16)
            SectorMark(
                angle: .value("Rest", 1 - share),
                innerRadius: .ratio(0.74)
            )
            .foregroundStyle(theme.foreground.opacity(0.1).color)
        }
        .chartLegend(.hidden)
        .overlay {
            Text(label)
                .font(TextSize.caption.rounded(rem, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(theme.bright.color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(Space.sm.at(rem))
        }
        .frame(width: side, height: side)
        .animation(reduceMotion ? nil : PanelMotion.figure, value: share)
        .accessibilityHidden(true)
    }
}

/// The mark button's symbol, as a checkbox is: an empty circle that fills
/// with a check as the mark goes on and empties as it comes off, bouncing
/// as it does, so the toggle is seen where the pointer is and not only in
/// the list below.
private struct PanelMarkSymbol: View {
    let on: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: on ? "checkmark.circle.fill" : "circle")
            .contentTransition(
                reduceMotion ? .opacity : .symbolEffect(.replace)
            )
            // A constant under Reduce Motion: nothing to bounce for.
            .symbolEffect(.bounce, value: reduceMotion ? false : on)
            .animation(
                reduceMotion ? PanelMotion.fade : PanelMotion.figure,
                value: on
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Layout

/// Views in a row that wraps onto the next line when it runs out of room,
/// as `flex_wrap` did for the selection's badges.
struct WrappingRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let lines = lines(width: proposal.width, subviews: subviews)
        let width = lines.map(\.width).max() ?? 0
        let height =
            lines.map(\.height).reduce(0, +)
            + spacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var y = bounds.minY
        for line in lines(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for (index, size) in zip(line.members, line.sizes) {
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += line.height + spacing
        }
    }

    private struct Line {
        var members: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// Subviews broken into lines no wider than `width`. Each is offered the
    /// whole line, so one wider than that (a badge naming a long directory)
    /// wraps inside itself on a line of its own instead of running out of
    /// the panel.
    private func lines(width: CGFloat?, subviews: Subviews) -> [Line] {
        let limit = width ?? .infinity
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(
                ProposedViewSize(width: width, height: nil)
            )
            if !line.members.isEmpty
                && line.width + spacing + size.width > limit
            {
                lines.append(line)
                line = Line()
            }
            line.width += (line.members.isEmpty ? 0 : spacing) + size.width
            line.height = max(line.height, size.height)
            line.members.append(index)
            line.sizes.append(size)
        }
        if !line.members.isEmpty {
            lines.append(line)
        }
        return lines
    }
}
