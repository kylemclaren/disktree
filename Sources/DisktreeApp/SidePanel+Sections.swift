// The side panel's lists and its disk: "worth a look", what is marked, the
// last notice, the free space now and after the marks, and the way to the
// review. Each list is a card of rows that answer the pointer with a
// rounded highlight, as a macOS 26 list does.
//
// Every number of free space here is measured: the volume from `statfs`,
// the projection from the marked bytes still on disk, and what the disk has
// gained from `statfs` again, since the first mark. The panel never claims a
// saving it cannot measure (Invariant 9); a number that rolls to its new
// value still only ever shows a measured one.

import AppKit
import Charts
import DisktreeCore
import SwiftUI
import System

extension AppState {
    /// What the plan's targets still on disk weigh: the projection the free
    /// space "after" is built from.
    ///
    /// A target already gone from disk (removed in Finder or by the copied
    /// command) is in the measured free space already; counting its bytes
    /// again would claim them twice (Invariant 9).
    func bytesStillOnDisk(_ plan: Plan) -> UInt64 {
        plan.targets.reduce(0) { total, target in
            gone.contains(target.path) ? total : total + target.bytes
        }
    }
}

// MARK: - Worth a look

/// The biggest things that could plausibly go, with their total. A row
/// shows its target in its directory, selected.
///
/// The first few rows, and the rest behind "Show All": a panel that lists
/// every finding pushes the disk under the fold of a laptop's window.
struct WorthSection: View {
    let state: AppState
    @State private var showsAll = false
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Rows listed before the rest wait behind "Show All": enough to see
    /// what kinds of thing there are, few enough that the column fits a
    /// 760-point window beside a selection.
    static let rows = 4

    var body: some View {
        let insights = state.insights
        let total = insights.reduce(UInt64(0)) { $0 + $1.bytes }
        let largest = insights.first?.bytes ?? 1
        let selected = state.actionTarget
        // The selection's own row stays in sight even when it is past the
        // fold: the row that is washed as selected must be on screen.
        let chosen = insights.firstIndex { $0.crumbs == selected }
        let listed =
            showsAll
            ? insights.count
            : max(min(insights.count, Self.rows), (chosen ?? -1) + 1)
        VStack(alignment: .leading, spacing: Space.sm.at(rem)) {
            PanelHeader("Worth a Look", symbol: "sparkle.magnifyingglass") {
                if total > 0 {
                    // What can be had back: the highlight.
                    Text(humanBytes(total))
                        .font(TextSize.body.rounded(rem, weight: .semibold))
                        .foregroundStyle(theme.highlight.color)
                        .lineLimit(1)
                        .panelRolling(Double(total))
                        .accessibilityLabel("\(humanBytes(total)) in all")
                }
            }
            Group {
                if insights.isEmpty {
                    if state.tree == nil {
                        PanelPlaceholder(
                            "Waiting for the scan",
                            symbol: "hourglass"
                        )
                    } else {
                        PanelPlaceholder(
                            "Nothing obviously disposable",
                            symbol: "checkmark.seal"
                        )
                    }
                } else {
                    VStack(spacing: Space.xxs.at(rem)) {
                        ForEach(0..<listed, id: \.self) { index in
                            row(
                                insights[index],
                                largest: largest,
                                active: selected == insights[index].crumbs
                            )
                            .accessibilityIdentifier("insight-\(index)")
                            .transition(.opacity)
                        }
                        if insights.count > Self.rows {
                            PanelShowAll(
                                count: insights.count,
                                expanded: showsAll
                            ) {
                                showsAll.toggle()
                            }
                        }
                    }
                    .animation(
                        reduceMotion ? nil : PanelMotion.rows,
                        value: showsAll
                    )
                }
            }
            .cardSurface(padding: Space.xs)
        }
    }

    @ViewBuilder
    private func row(
        _ candidate: Candidate,
        largest: UInt64,
        active: Bool
    ) -> some View {
        if let node = state.node(at: candidate.crumbs) {
            let (title, detail) = Self.text(for: candidate, in: state.tree)
            PanelInsightRow(
                title: title,
                detail: detail,
                path: state.path(at: candidate.crumbs).map {
                    displayPath($0, home: state.home)
                } ?? title,
                symbol: SymbolName.finding(candidate.finding),
                bytes: candidate.bytes,
                fraction: Double(candidate.bytes) / Double(max(largest, 1)),
                accent: theme.categoryAccent(node.category),
                active: active
            ) {
                state.reveal(candidate.crumbs)
            }
        }
    }

    /// A finding's title, as the last two parts of its path, and why it is
    /// on the list.
    static func text(
        for candidate: Candidate,
        in tree: Node?
    ) -> (title: String, detail: String) {
        let chain = tree?.resolveChain(candidate.crumbs) ?? []
        // The first link is the scanned root: a finding is named from
        // below it.
        let names = chain.dropFirst().map(\.name)
        let tail = names.suffix(2).joined(separator: "/")
        let plural = { (count: Int) in count == 1 ? "" : "s" }
        return switch candidate.finding {
        case .reclaimable(let reason):
            (tail, reason.label)
        case .worktrees(let count, let oldestDays):
            (
                tail,
                "\(count) worktree\(plural(count)) · oldest \(oldestDays) d"
            )
        case .staleExperiments(let count):
            (
                "\(tail) > \(staleDays) days",
                "\(count) experiment\(plural(count)) untouched"
            )
        }
    }
}

/// One finding: why it could go as a symbol on its kind's colour, its name
/// and reason, its size over a meter against the largest finding. A link:
/// it goes to the finding.
private struct PanelInsightRow: View {
    let title: String
    let detail: String
    /// The whole path, which the title cuts to two parts.
    let path: String
    let symbol: String
    let bytes: UInt64
    let fraction: Double
    let accent: HSLA
    /// The selection is this finding: the row is what the keys act on.
    let active: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.sm.at(rem)) {
                PanelIconTile(
                    symbol: symbol,
                    tint: accent,
                    side: PanelIconTile.row
                )
                VStack(alignment: .leading, spacing: Space.xxs.at(rem)) {
                    Text(title)
                        .font(TextSize.body.font(rem, weight: .medium))
                        .foregroundStyle(theme.bright.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detail)
                        .font(TextSize.caption.font(rem))
                        .foregroundStyle(theme.secondary.color)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: Space.xs.at(rem)) {
                    Text(humanBytes(bytes))
                        .font(TextSize.body.rounded(rem, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(theme.bright.color)
                        .lineLimit(1)
                    Bar(fraction, color: accent)
                }
                .frame(width: Size.rowBar.at(rem))
            }
            .padding(.horizontal, Space.sm.at(rem))
            .padding(.vertical, Space.xs.at(rem) + Space.xxs.at(rem))
        }
        .buttonStyle(
            PressableFill(
                .rounded(Rounding.control),
                // The selection's row is washed in the highlight, as a
                // selected row is in a Mac list.
                selected: active ? theme.highlight.opacity(0.14) : nil
            )
        )
        // Keys go to the window's one dispatcher: a row never takes focus.
        .focusEffectDisabled()
        .pointerStyle(.link)
        .help(PanelHelp.finding(path))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(humanBytes(bytes)), \(detail)")
        .accessibilityHint("Shows it in its directory")
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { action() }
    }

}

/// The row at the foot of "worth a look" that lists the rest, or folds
/// them away again.
private struct PanelShowAll: View {
    let count: Int
    let expanded: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs.at(rem)) {
                Text(expanded ? "Show Less" : "Show All (\(count))")
                    .contentTransition(.opacity)
                Spacer(minLength: Space.sm.at(rem))
                Image(systemName: "chevron.down")
                    .font(TextSize.caption.font(rem, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .accessibilityHidden(true)
            }
            .font(TextSize.caption.font(rem, weight: .medium))
            .foregroundStyle(theme.secondary.color)
            .padding(.horizontal, Space.sm.at(rem))
            .padding(.vertical, Space.xs.at(rem))
        }
        .buttonStyle(PressableFill(.rounded(Rounding.control)))
        .focusEffectDisabled()
        .animation(
            reduceMotion ? PanelMotion.fade : PanelMotion.rows,
            value: expanded
        )
        .accessibilityLabel(expanded ? "Show fewer" : "Show all \(count)")
        .accessibilityIdentifier("insights-show-all")
    }
}

// MARK: - Marked

/// What is queued for removal, each with a way off the list; what has gone
/// from disk since, struck through; and what the disk measurably gained.
struct MarkedSection: View {
    let state: AppState
    let plan: Plan
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Marked rows the panel lists before pointing at the review screen.
    static let rows = 6

    var body: some View {
        let items = state.marks.items
        let count = items.count
        let listed = Array(items.prefix(Self.rows))
        let still = state.bytesStillOnDisk(plan)
        let stillSize = humanBytes(still)
        VStack(alignment: .leading, spacing: Space.sm.at(rem)) {
            PanelHeader("Marked", symbol: "checklist", count: count) {
                if count > 0 {
                    Text(stillSize)
                        .font(TextSize.body.rounded(rem, weight: .medium))
                        .foregroundStyle(theme.secondary.color)
                        .lineLimit(1)
                        .panelRolling(Double(still))
                        .accessibilityLabel("\(stillSize) still on disk")
                }
            }
            Group {
                if count == 0 {
                    PanelPlaceholder(
                        "Space marks the tile you point at",
                        symbol: "hand.point.up.left"
                    )
                } else {
                    VStack(alignment: .leading, spacing: Space.xxs.at(rem)) {
                        // By path: a row keeps its identity as the marks
                        // around it change, so the one that went is the
                        // one that leaves.
                        ForEach(
                            Array(listed.enumerated()),
                            id: \.element.path
                        ) { index, item in
                            row(item)
                                .accessibilityIdentifier("marked-\(index)")
                                .transition(rowTransition)
                        }
                        if count > Self.rows {
                            caption(
                                "+\(count - Self.rows) more on the review "
                                    + "screen"
                            )
                        }
                        if !plan.covered.isEmpty || !plan.blocked.isEmpty {
                            caption(
                                "\(plan.covered.count) nested · "
                                    + "\(plan.blocked.count) kept back"
                            )
                        }
                        goneLine(items)
                    }
                }
            }
            .cardSurface(padding: Space.xs)
        }
        // A mark going on or off, from a key, a click or this list: the
        // row arrives or leaves, and the rows below close up. With Reduce
        // Motion the list changes at once, since closing up is movement.
        .animation(
            reduceMotion ? nil : PanelMotion.rows,
            value: listed.map(\.path)
        )
    }

    /// One mark, and what its row does.
    private func row(_ item: Target) -> some View {
        let gone = state.gone.contains(item.path)
        return PanelMarkedRow(
            text: displayPath(item.path, home: state.home),
            url: URL(filePath: item.path.string),
            bytes: item.bytes,
            accent: theme.categoryAccent(category(of: item.path)),
            gone: gone,
            show: { [state] in
                if let crumbs = state.crumbs(for: item.path) {
                    state.reveal(crumbs)
                }
            },
            unmark: { [state] in state.unmark(item.path) },
            dropped: { [state] in
                // The receiver moves it in its own time: the ticker would
                // see it gone within a tick anyway, and asking now shows it
                // struck through sooner when the move was quick.
                state.checkMarks()
            }
        )
    }

    /// A new mark comes in from the mosaic's side, where it was marked;
    /// one that is taken off fades where it stood.
    private var rowTransition: AnyTransition {
        .asymmetric(
            insertion: .offset(x: -Space.lg.at(rem)).combined(with: .opacity),
            removal: .opacity
        )
    }

    /// The colour of a mark's kind, from the tree when it is still in it.
    private func category(of path: FilePath) -> DisktreeCore.Category {
        state.crumbs(for: path).flatMap { state.node(at: $0) }?.category
            ?? .other
    }

    /// A line under the rows, in from the card's edge as a row's text is.
    private func caption(_ text: String) -> some View {
        Text(text)
            .font(TextSize.caption.font(rem))
            .foregroundStyle(theme.secondary.color)
            .padding(.horizontal, Space.sm.at(rem))
            .padding(.vertical, Space.xxs.at(rem))
    }

    /// How many marks are gone from disk, and what the disk gained since
    /// the first mark: measured by `statfs`, never summed from the marks,
    /// and only said once there is a gain to measure.
    @ViewBuilder
    private func goneLine(_ items: [Target]) -> some View {
        let goneCount = items.count { state.gone.contains($0.path) }
        if goneCount > 0 {
            HStack(alignment: .firstTextBaseline) {
                Text(
                    goneCount == items.count
                        ? "All gone from disk"
                        : "\(goneCount) of \(items.count) gone from disk"
                )
                .foregroundStyle(theme.secondary.color)
                .panelRolling(Double(goneCount))
                Spacer(minLength: Space.sm.at(rem))
                if let gain = state.measuredGain {
                    Label(
                        "\(humanBytes(gain)) freed, measured",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(theme.success.color)
                    .panelRolling(Double(gain))
                } else {
                    // APFS snapshots and a Trash not yet emptied can hold
                    // the space: nothing is claimed until `statfs` shows it.
                    Text("nothing measured yet")
                        .foregroundStyle(theme.secondary.color)
                }
            }
            .font(TextSize.caption.font(rem))
            .lineLimit(1)
            .padding(.horizontal, Space.sm.at(rem))
            .padding(.vertical, Space.xs.at(rem))
            .accessibilityElement(children: .combine)
        }
    }
}

/// One mark: its kind as a dot, its path, its size, and a way off the list.
/// A link to the mark's tile, and a file that can be dragged out of the
/// panel, until it is gone from disk.
private struct PanelMarkedRow: View {
    let text: String
    let url: URL
    let bytes: UInt64
    let accent: HSLA
    /// Removed since it was marked: struck through until the rescan drops
    /// it, and nothing left to show or to drag.
    let gone: Bool
    let show: @MainActor () -> Void
    let unmark: @MainActor () -> Void
    let dropped: @MainActor () -> Void
    @State private var hovering = false
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    var body: some View {
        let size = humanBytes(bytes)
        HStack(spacing: Space.sm.at(rem)) {
            HStack(spacing: Space.sm.at(rem)) {
                Circle()
                    .fill(accent.opacity(gone ? 0.4 : 1).color)
                    .frame(width: Space.sm.at(rem), height: Space.sm.at(rem))
                // Cut in the middle, as a Mac cuts a path: two marks in one
                // deep directory still read apart by their names.
                Text(text)
                    .foregroundStyle(
                        (gone ? theme.secondary : theme.foreground).color
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .panelStrike(gone, color: theme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(size)
                    .fontDesign(.rounded)
                    .monospacedDigit()
                    .foregroundStyle(theme.secondary.color)
                    .lineLimit(1)
                    .fixedSize()
                    .panelStrike(gone, color: theme.secondary)
            }
            .contentShape(Rectangle())
            .overlay {
                PanelDragArea(
                    url: gone ? nil : url,
                    help: gone ? text : PanelHelp.marked(text),
                    click: show,
                    hover: { hovering = $0 },
                    dropped: dropped
                )
                .accessibilityHidden(true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .accessibilityValue(gone ? "\(size), gone from disk" : size)
            .modifier(PanelRowAction(enabled: !gone, action: show))
            PanelUnmarkButton(name: text, action: unmark)
        }
        .font(TextSize.caption.font(rem))
        .padding(.leading, Space.sm.at(rem))
        .padding(.trailing, Space.xs.at(rem))
        .padding(.vertical, Space.xs.at(rem))
        .background(
            (hovering && !gone ? theme.hoverFill : theme.hoverFill.opacity(0))
                .color,
            in: roundedShape(Rounding.control, rem: rem)
        )
        .animation(PanelMotion.hover, value: hovering)
    }
}

/// A row that does something when pressed, for assistive technology, as
/// its click does for the pointer; a gone row does nothing, and says so by
/// being no button.
///
/// The same modifiers whether it is enabled or not, only their values
/// change. With a branch here, a row going from disk would be a new view:
/// its line would be drawn whole instead of struck, and its drag area
/// rebuilt under the pointer.
private struct PanelRowAction: ViewModifier {
    let enabled: Bool
    let action: @MainActor () -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityAddTraits(enabled ? .isButton : [])
            .accessibilityHint(enabled ? "Shows it in the mosaic" : "")
            .accessibilityRespondsToUserInteraction(enabled)
            // The default action, so VoiceOver's press shows a live row as
            // a click does; a named one would only be in the actions menu.
            // On a gone row it is let go, as a click on it is.
            .accessibilityAction {
                if enabled {
                    action()
                }
            }
    }
}

extension View {
    /// A line through the text, drawn from its start as the path goes from
    /// disk, as a hand strikes an item off a list. With Reduce Motion the
    /// line fades in, whole.
    fileprivate func panelStrike(_ active: Bool, color: HSLA) -> some View {
        modifier(PanelStrike(active: active, color: color))
    }
}

private struct PanelStrike: ViewModifier {
    let active: Bool
    let color: HSLA
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(color.color)
                    .frame(height: hairline)
                    .scaleEffect(
                        x: active || reduceMotion ? 1 : 0,
                        anchor: .leading
                    )
                    .opacity(active ? 1 : 0)
                    .animation(
                        reduceMotion ? PanelMotion.fade : PanelMotion.strike,
                        value: active
                    )
            }
    }
}

/// The `×` at the end of a marked row: a quiet filled circle until pointed
/// at, then the danger colour.
private struct PanelUnmarkButton: View {
    let name: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .font(TextSize.body.font(rem, weight: .medium))
                .foregroundStyle(
                    (hovering ? theme.danger : theme.secondary.opacity(0.7))
                        .color
                )
                .padding(Space.xxs.at(rem))
        }
        // Deepens under a press, as every plain button here does.
        .buttonStyle(PressableFill(.circle))
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .animation(PanelMotion.hover, value: hovering)
        .help(PanelHelp.unmarkRow)
        .accessibilityLabel("Unmark \(name)")
    }
}

// MARK: - Dragging a mark out

/// The part of a marked row that is a file: a click shows it in the mosaic,
/// a drag takes its URL out of the app. AppKit, because the Dock's Trash
/// takes only a drag that offers to be deleted or moved, and what a drag
/// offers is its source's to say: here, this view's.
private struct PanelDragArea: NSViewRepresentable {
    /// `nil` once it is gone from disk: nothing to drag, nothing to show.
    let url: URL?
    let help: String
    let click: @MainActor () -> Void
    let hover: @MainActor (Bool) -> Void
    let dropped: @MainActor () -> Void

    func makeNSView(context: Context) -> PanelDragView {
        PanelDragView()
    }

    func updateNSView(_ view: PanelDragView, context: Context) {
        view.url = url
        view.toolTip = help
        view.onClick = click
        view.onHover = hover
        view.onDropped = dropped
    }
}

/// A file under the pointer, as Finder's rows are: pressed and moved a few
/// points, it is dragged out; pressed and let go, it is clicked.
///
/// disktree removes nothing itself, and a drag does not change that: the
/// Trash, Finder or Terminal decides what to do with a file dropped on it,
/// and disktree only sees the mark's path go from disk afterwards.
final class PanelDragView: NSView, NSDraggingSource {
    /// Past this many points a press is a drag; short of it, a click. A
    /// finger on a trackpad wobbles a point or two as it clicks.
    static let threshold: CGFloat = 4

    /// The file, or `nil` when there is none to offer.
    var url: URL? {
        didSet {
            if url != oldValue {
                window?.invalidateCursorRects(for: self)
            }
        }
    }
    var onClick: (@MainActor () -> Void)?
    var onHover: (@MainActor (Bool) -> Void)?
    /// The drag ended on something that took it.
    var onDropped: (@MainActor () -> Void)?
    /// Starts the drag session from this event. A test, with no pointer
    /// for a session to follow, records it instead.
    var startDrag: (@MainActor (NSEvent) -> Void)?

    /// Where the press began, in window coordinates, until it is let go or
    /// becomes a drag.
    private var pressedAt: NSPoint?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    /// A file can be dragged out of a window at the back, as from Finder.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Not an element of its own: the row it covers is, with its path, its
    // size and whether it is gone.
    override func isAccessibilityElement() -> Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    /// A link while there is something to go to.
    override func resetCursorRects() {
        if url != nil {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        pressedAt = url == nil ? nil : event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressedAt, let url else { return }
        let at = event.locationInWindow
        guard hypot(at.x - pressedAt.x, at.y - pressedAt.y) >= Self.threshold
        else { return }
        // A drag now, never a click: the session takes the pointer from
        // here, and no mouse-up comes back to this view.
        self.pressedAt = nil
        if let startDrag {
            startDrag(event)
            return
        }
        let item = Self.item(url, at: convert(at, from: nil))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard pressedAt != nil else { return }
        pressedAt = nil
        onClick?()
    }

    /// What a mark carries out of the panel: its file URL, shown as its
    /// Finder icon under the pointer.
    static func item(_ url: URL, at point: NSPoint) -> NSDraggingItem {
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let icon = NSWorkspace.shared.icon(
            forFile: url.path(percentEncoded: false)
        )
        // The size Finder drags an icon at in a list.
        let side: CGFloat = 32
        item.setDraggingFrame(
            NSRect(
                x: point.x - side / 2,
                y: point.y - side / 2,
                width: side,
                height: side
            ),
            contents: icon
        )
        return item
    }

    /// Everything a drag from Finder itself offers, outside the app: the
    /// Dock's Trash takes it as a delete (a move to the Trash, which Put
    /// Back undoes), a Finder window as a move (a copy across volumes, or
    /// with Option), Terminal as its path. Nothing inside the app takes
    /// it: dropped on the window, a mark would start a scan of itself.
    static func operations(_ context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .outsideApplication: [.copy, .link, .generic, .move, .delete]
        case .withinApplication: []
        @unknown default: []
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        Self.operations(context)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        if !operation.isEmpty {
            onDropped?()
        }
    }
}

// MARK: - Notice

/// The last thing that happened, or a scan error, above the disk. It rises
/// into its place as it arrives, animated by the panel's column, whose
/// room it takes; with Reduce Motion it fades in where it will stand, and
/// the column makes room at once.
struct NoticeLine: View {
    let state: AppState
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let message:
            (text: String, color: HSLA, word: String, symbol: String)? =
                if let error = state.scanError {
                    (error, theme.danger, "Error", Self.symbol(.error))
                } else if let notice = state.notice {
                    (
                        notice.sentence,
                        theme.alertColor(notice.status),
                        Self.word(notice.status),
                        Self.symbol(notice.status)
                    )
                } else {
                    nil
                }
        if let message {
            let shape = roundedShape(Rounding.control, rem: rem)
            HStack(alignment: .firstTextBaseline, spacing: Space.sm.at(rem)) {
                Image(systemName: message.symbol)
                    .accessibilityHidden(true)
                Text(message.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(TextSize.caption.font(rem, weight: .medium))
            .foregroundStyle(message.color.color)
            .padding(.horizontal, Space.sm.at(rem))
            .padding(.vertical, Space.sm.at(rem))
            .frame(maxWidth: .infinity, alignment: .leading)
            // The notice's colour over a tenth of itself, as a chip is: the
            // wash its contrast is measured on.
            .background(message.color.opacity(0.1).color, in: shape)
            .overlay {
                shape.strokeBorder(
                    message.color.opacity(0.35).color,
                    lineWidth: hairline
                )
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(message.word): \(message.text)")
            .transition(
                reduceMotion
                    // The column does not animate under Reduce Motion,
                    // so the fade brings its own.
                    ? .opacity.animation(PanelMotion.fade)
                    : .asymmetric(
                        insertion: .offset(y: Space.md.at(rem))
                            .combined(with: .opacity),
                        removal: .opacity
                    )
            )
        }
    }

    /// What the notice says, for the column to animate by: a new one, or
    /// none, is a change of the room the lists have.
    static func key(_ state: AppState) -> String? {
        state.scanError ?? state.notice?.text
    }

    /// The symbol before the notice, which says at a glance what its colour
    /// says.
    private static func symbol(_ status: Status) -> String {
        switch status {
        case .neutral: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    /// What VoiceOver says before the notice, where its colour says it on
    /// screen.
    private static func word(_ status: Status) -> String {
        switch status {
        case .neutral: "Note"
        case .success: "Done"
        case .warning: "Warning"
        case .error: "Error"
        }
    }
}

// MARK: - Disk

/// Free space on the volume now, and after the marks still on disk go.
struct DiskSection: View {
    let state: AppState
    let plan: Plan
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    var body: some View {
        let reclaiming = state.bytesStillOnDisk(plan)
        let volume = state.volumeName ?? state.device ?? ""
        VStack(alignment: .leading, spacing: Space.sm.at(rem)) {
            PanelHeader("Disk", symbol: "internaldrive") {
                // The name Finder gives the volume, which a Mac user
                // knows; the device only when there is no name.
                Text(volume)
                    .font(TextSize.caption.font(rem))
                    .foregroundStyle(theme.secondary.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(state.device ?? volume)
            }
            Group {
                if let space = state.space {
                    measured(space, reclaiming: reclaiming, volume: volume)
                } else {
                    PanelPlaceholder(
                        "Free space is not available here",
                        symbol: "questionmark.circle"
                    )
                }
            }
            .cardSurface()
            if state.marks.count > 0 {
                PanelReviewButton(
                    count: state.marks.count,
                    reclaiming: reclaiming
                ) {
                    state.screen = .review
                }
                .transition(.opacity)
            } else {
                // Nothing to review: no dead button the width of the
                // panel, but the one thing to do next, where it reads.
                PanelMarkingHint()
                    .transition(.opacity)
            }
        }
    }

    /// The ring of the disk beside the free space set large, what it would
    /// be once the marks still on disk are gone, and used against total.
    /// Each rolls, and the ring sweeps, as the ticker measures the disk
    /// again.
    private func measured(
        _ space: SpaceInfo,
        reclaiming: UInt64,
        volume: String
    ) -> some View {
        let after = space.afterRemoving(reclaiming)
        let (number, unit) = splitSize(humanBytes(space.available))
        return HStack(alignment: .center, spacing: Space.md.at(rem)) {
            PanelDiskRing(space: space, after: after)
                .help(PanelHelp.meter)
                .panelFigure(
                    "Used",
                    "\(percent(space.used, of: space.total)) of the disk"
                )
            VStack(alignment: .leading, spacing: Space.xxs.at(rem)) {
                VStack(alignment: .leading, spacing: Space.xxs.at(rem)) {
                    Measure(
                        number,
                        size: TextSize.figure,
                        unit: "\(unit) free",
                        unitSize: TextSize.body
                    )
                    .minimumScaleFactor(0.7)
                    .panelRolling(Double(space.available))
                    if reclaiming > 0 {
                        // In the highlight: what the disk would have free
                        // once the marks still on it are gone.
                        Label(
                            "\(humanBytes(after.available)) after the marks",
                            systemImage: "arrow.forward"
                        )
                        .font(TextSize.body.rounded(rem, weight: .semibold))
                        .foregroundStyle(theme.highlight.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .panelRolling(Double(after.available))
                    }
                }
                .panelFigure(
                    volume.isEmpty ? "Free" : "Free on \(volume)",
                    reclaiming > 0
                        ? "\(humanBytes(space.available)), "
                            + "\(humanBytes(after.available)) once the marks go"
                        : humanBytes(space.available)
                )
                Text(
                    "\(humanBytes(space.used)) used of "
                        + humanBytes(space.total)
                )
                .font(TextSize.caption.font(rem))
                .foregroundStyle(theme.secondary.color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .panelRolling(Double(space.used))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The disk as a ring, as macOS draws storage: what stays used, then the
/// arc the marks give back in the highlight, then what is free, the faint
/// track. The used share is written inside. Only measured numbers and the
/// marked bytes still on disk draw it (Invariant 9).
private struct PanelDiskRing: View {
    let space: SpaceInfo
    /// The disk once the marks still on it are gone: a projection.
    let after: SpaceInfo
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Wide enough for "100%" inside a ring as thick as the share ring's.
    static let side = Rems(4)

    /// One arc of the ring.
    struct Slice: Identifiable, Hashable {
        enum Kind: Hashable {
            /// Used, and still used once the marks are gone.
            case kept
            /// Used by the marks still on disk.
            case freeing
            /// Free now.
            case free
        }

        var kind: Kind
        var bytes: Double

        var id: Kind { kind }
    }

    /// The arcs clockwise from the top. Each keeps its place when it is
    /// empty, so a change moves an edge rather than swapping arcs.
    static func slices(space: SpaceInfo, after: SpaceInfo) -> [Slice] {
        // `after.used` is never above `used`: removing only frees.
        let used = Double(space.used)
        let kept = min(Double(after.used), used)
        let total = max(Double(space.total), used)
        return [
            Slice(kind: .kept, bytes: kept),
            Slice(kind: .freeing, bytes: used - kept),
            Slice(kind: .free, bytes: total - used),
        ]
    }

    var body: some View {
        let side = Self.side.at(rem)
        let slices = Self.slices(space: space, after: after)
        Chart(slices) { slice in
            SectorMark(
                angle: .value("Bytes", slice.bytes),
                innerRadius: .ratio(0.74)
            )
            .foregroundStyle(color(slice.kind).color)
        }
        .chartLegend(.hidden)
        .overlay {
            VStack(spacing: 0) {
                Text(percent(space.used, of: space.total))
                    .font(TextSize.caption.rounded(rem, weight: .bold))
                    .foregroundStyle(theme.bright.color)
                Text("used")
                    .font(TextSize.caption.font(rem))
                    .foregroundStyle(theme.secondary.color)
            }
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(Space.sm.at(rem))
        }
        .frame(width: side, height: side)
        .animation(reduceMotion ? nil : PanelMotion.figure, value: slices)
    }

    /// Used space in the ink's own grey, as the review's chart draws it;
    /// what comes back in the highlight; free space the empty track.
    private func color(_ kind: Slice.Kind) -> HSLA {
        switch kind {
        case .kept: theme.foreground.opacity(0.45)
        case .freeing: theme.highlight
        case .free: theme.foreground.opacity(0.1)
        }
    }
}

// MARK: - Review

/// The way to the review screen, where the marks are handed over: a
/// prominent button the width of the panel, with the count in a badge and
/// what the marks would free under its title, so the number that matters
/// is the thing to press. In the accent, so it does not compete with the
/// highlight of "Mark for removal" above it, and in the same shape as its
/// neighbours, which the system chooses: a capsule on macOS 26. Shown once
/// something is marked; until then the panel says how to mark instead.
struct PanelReviewButton: View {
    let count: Int
    let reclaiming: UInt64
    let action: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    var body: some View {
        let label = Self.label(count: count, reclaiming: reclaiming)
        Button(action: action) { content }
            .buttonStyle(.borderedProminent)
            .tint(theme.inspectorAccent.color)
            .controlSize(.large)
            .disabled(count == 0)
            .focusEffectDisabled()
            .help(PanelHelp.review)
            .accessibilityLabel(label)
            .accessibilityHint(
                "Opens the review, where the marks are handed to Finder or "
                    + "Terminal"
            )
            .accessibilityIdentifier("panel-review")
            .padding(.top, Space.xs.at(rem))
    }

    private var content: some View {
        HStack(spacing: Space.sm.at(rem)) {
            Image(systemName: "checklist")
                .font(TextSize.title.font(rem, weight: .medium))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(Self.title(count: count))
                    .font(TextSize.body.font(rem, weight: .semibold))
                if let detail = Self.detail(
                    count: count, reclaiming: reclaiming)
                {
                    Text(detail)
                        .font(TextSize.caption.rounded(rem))
                        .foregroundStyle(.secondary)
                        .panelRolling(Double(reclaiming))
                }
            }
            // A narrow panel would cut the number that matters: the label
            // takes a second line instead.
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            if count > 0 {
                Text("\(count)")
                    .font(TextSize.caption.rounded(rem, weight: .bold))
                    .padding(.horizontal, Space.sm.at(rem))
                    .padding(.vertical, Space.xxs.at(rem))
                    .background(.quaternary, in: Capsule())
                    .panelRolling(Double(count))
                    .accessibilityHidden(true)
            }
            Image(systemName: "chevron.forward")
                .font(TextSize.caption.font(rem, weight: .bold))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Space.xxs.at(rem))
        .padding(.vertical, Space.xxs.at(rem))
    }
}

/// Where the review button goes once something is marked: how to mark, in
/// the dim text at full strength, which reads at 4.5:1 on the pane.
struct PanelMarkingHint: View {
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    var body: some View {
        Label {
            Text(Self.text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "hand.point.up.left")
                .symbolRenderingMode(.hierarchical)
        }
        .font(TextSize.caption.font(rem))
        .foregroundStyle(theme.secondary.color)
        .padding(.horizontal, Space.xs.at(rem))
        .padding(.top, Space.xxs.at(rem))
        .frame(maxWidth: .infinity, alignment: .leading)
        .chromeIdentifier("panel-marking-hint")
    }

    static let text = "Nothing marked yet. Space marks the tile you point at."
}

extension PanelReviewButton {
    /// What the button says, whole, as VoiceOver reads it. Nothing is
    /// claimed once the marks still on disk weigh nothing: they are gone,
    /// and the disk says what came back.
    static func label(count: Int, reclaiming: UInt64) -> String {
        if count == 0 {
            "Nothing marked to review"
        } else if reclaiming == 0 {
            "Review \(count) marked…"
        } else {
            "Review \(count) marked · frees \(humanBytes(reclaiming))…"
        }
    }

    /// The button's title; the count is in its badge.
    static func title(count: Int) -> String {
        count == 0 ? "Nothing marked to review" : "Review marks…"
    }

    /// The line under the title: what the marks still on disk would free,
    /// or nothing to claim once they weigh nothing, or nothing is marked.
    static func detail(count: Int, reclaiming: UInt64) -> String? {
        count == 0 || reclaiming == 0
            ? nil : "frees \(humanBytes(reclaiming))"
    }
}
