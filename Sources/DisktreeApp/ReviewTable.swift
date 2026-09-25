// The review's marked list: a Mac table of every mark and what the guards
// made of it.
//
// A table, because a Mac user already knows what to do with one: click a
// column to sort it, ⌘- and ⇧-click to pick several rows, ⌫ to unmark them,
// ⌘C to copy their paths, right-click for the rest, double-click to look
// inside with Quick Look. A row can also be dragged out of the window, onto
// Finder, into a Terminal window or onto the Trash in the Dock, and it goes
// as its file URL, the way Finder hands a file over. Only a path the command
// would carry can be dragged: one the guards keep back, one that goes with
// a marked directory, or one already gone stays put, so the three ways out
// (the command, Finder, a drag) hand over the same paths.
//
// The system's own table in its inset style, set in a rounded card: rows
// selected with a rounded highlight in the accent colour, as every list on
// the Mac marks what is selected, with their text in the colour AppKit sets
// on it; no stripes, the theme's colours and the rem scale. Each row says
// what it is with a symbol, its size in rounded figures, its share of the
// scan as a small capsule, and what the guards made of it as a tinted tag.

import AppKit
import DisktreeCore
import SwiftUI
import System

// MARK: - A row

/// What the guards and the disk made of one mark, as its row says it.
enum ReviewStatus: Sendable, Hashable {
    /// In the command: still on disk, and let through by the guards.
    case ready
    /// Inside another marked directory: that target, which takes it along.
    case covered(by: FilePath)
    /// Kept back by a guard, and the guard's reason.
    case blocked(String)
    /// No longer on disk.
    case gone
}

/// One mark as the list shows it.
struct ReviewRow: Identifiable, Sendable, Hashable {
    /// Where it stands in marking order: what names its row's controls, so
    /// a name does not change when the list is sorted.
    let index: Int
    let path: FilePath
    let name: String
    /// The folder holding it, written as the rest of the app writes a path.
    let folder: String
    let bytes: UInt64
    let isDir: Bool
    let hidden: Bool
    let status: ReviewStatus

    /// A path is marked once, so it names its row.
    var id: FilePath { path }

    /// The command carries it, so Finder and a drag may too.
    var handedOver: Bool { status == .ready }

    var isGone: Bool { status == .gone }

    /// The order the Status column sorts in: what leaves first, then what
    /// leaves with it, then what stays, then what is gone already.
    var statusRank: Int {
        switch status {
        case .ready: 0
        case .covered: 1
        case .blocked: 2
        case .gone: 3
        }
    }

    /// What the Status column says. A row the command carries says
    /// nothing: that is what every row is for, and a column of it would be
    /// noise around the rows that differ.
    var statusText: String {
        switch status {
        case .ready: ""
        case .covered(let target): "goes with \(reviewName(target))"
        case .blocked(let reason): "kept back: \(reason)"
        case .gone: "gone from disk"
        }
    }

    /// What a screen reader says for the row: its name, its size and its
    /// status, the last spelled out even where the column is blank.
    var spoken: String {
        let status =
            switch status {
            case .ready: "in the command"
            default: statusText
            }
        let kind = isDir ? "folder" : "file"
        let hidden = hidden ? ", hidden" : ""
        return "\(name), \(kind)\(hidden) in \(folder), "
            + "\(humanBytes(bytes)), \(status)"
    }

    /// The SF Symbol before its name: a checkmark once it is gone.
    var symbol: String {
        if isGone {
            "checkmark"
        } else if isDir {
            "folder"
        } else {
            "doc"
        }
    }

    /// Largest first, as the treemap ranks: what is worth reading first.
    static let defaultOrder = [
        KeyPathComparator(\ReviewRow.bytes, order: .reverse)
    ]
}

extension ReviewModel {
    /// The rows in `order`, at most `reviewListLimit` of them: the cap
    /// applies after sorting, so a list sorted by size leaves out the
    /// smallest. Two rows the order calls equal keep their marking order,
    /// said explicitly rather than left to how the sort happens to behave.
    func listed(by order: [KeyPathComparator<ReviewRow>]) -> [ReviewRow] {
        let sorted = rows.sorted(
            using: order + [KeyPathComparator(\ReviewRow.index)]
        )
        return Array(sorted.prefix(reviewListLimit))
    }
}

/// The last component of a path, or the whole path when it has none.
func reviewName(_ path: FilePath) -> String {
    path.lastComponent?.string ?? path.string
}

/// A row as Finder hands a file to whatever it is dropped on: its file URL.
/// `nil` for a row the command does not carry, which cannot be dragged.
func reviewDragItem(_ row: ReviewRow) -> NSItemProvider? {
    guard row.handedOver else {
        return nil
    }
    let url = URL(
        filePath: row.path.string,
        directoryHint: row.isDir ? .isDirectory : .notDirectory
    )
    let provider = NSItemProvider(object: url as NSURL)
    provider.suggestedName = row.name
    return provider
}

// MARK: - The context menu

/// What the rows' context menu offers, for the rows it was opened on.
struct ReviewRowCommand: Identifiable, Hashable {
    enum Kind: Hashable, CaseIterable {
        case quickLook
        case reveal
        case copyPath
        case unmark
    }

    let kind: Kind
    let title: String
    let symbol: String
    let enabled: Bool

    var id: Kind { kind }

    /// The menu for `rows`: empty when the pointer was on no row. Looking
    /// at a path needs it on disk; copying and unmarking do not.
    static func menu(for rows: [ReviewRow]) -> [Self] {
        guard !rows.isEmpty else {
            return []
        }
        let onDisk = rows.filter { !$0.isGone }
        let many = rows.count > 1
        return [
            Self(
                kind: .quickLook,
                title: "Quick Look",
                symbol: "eye",
                enabled: rows.count == 1 && !onDisk.isEmpty
            ),
            Self(
                kind: .reveal,
                title: "Reveal in Finder",
                symbol: "finder",
                enabled: !onDisk.isEmpty
            ),
            Self(
                kind: .copyPath,
                title: many ? "Copy \(rows.count) Paths" : "Copy Path",
                symbol: "doc.on.doc",
                enabled: true
            ),
            Self(
                kind: .unmark,
                title: many ? "Unmark \(rows.count) Items" : "Unmark",
                symbol: "xmark.circle",
                enabled: true
            ),
        ]
    }
}

extension ReviewRowCommand.Kind {
    /// Do it to `rows`, through the screen's actions. A path gone from disk
    /// is left out of what Finder and Quick Look are shown.
    @MainActor
    func perform(on rows: [ReviewRow], _ actions: ReviewActions) {
        let onDisk = rows.filter { !$0.isGone }.map(\.path)
        switch self {
        case .quickLook:
            if rows.count == 1, let path = onDisk.first {
                actions.quickLook(path)
            }
        case .reveal:
            if !onDisk.isEmpty {
                actions.revealPaths(onDisk)
            }
        case .copyPath:
            actions.copyPaths(rows.map(\.path))
        case .unmark:
            for row in rows {
                actions.unmark(row.path)
            }
        }
    }
}

// MARK: - The list

/// The marked list in its card: the count, what is selected, Unmark All,
/// the table, and a line when the list stops short of every mark.
struct ReviewList: View {
    let review: ReviewModel
    let actions: ReviewActions
    @Binding var selection: Set<FilePath>
    @Binding var order: [KeyPathComparator<ReviewRow>]
    /// A fixed height, when the screen scrolls as a whole; otherwise the
    /// list takes what the rest of the column leaves.
    var height: CGFloat?
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let rows = review.listed(by: order)
        let picked = rows.count { selection.contains($0.path) }
        let shape = RoundedRectangle(
            cornerRadius: Rounding.card.at(rem),
            style: .continuous
        )
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Space.sm.at(rem)) {
                CardHeading("Marked", symbol: "checklist")
                Text(humanCount(UInt64(review.items.count)))
                    .font(TextSize.caption.font(rem, weight: .semibold))
                    .fontDesign(.rounded)
                    .monospacedDigit()
                    .foregroundStyle(theme.secondary.color)
                    .padding(.horizontal, Space.sm.at(rem))
                    .padding(.vertical, Space.xxs.at(rem))
                    .background(
                        theme.foreground.opacity(0.07).color,
                        in: Capsule()
                    )
                    .reviewRolling(
                        Double(review.items.count),
                        reduceMotion: reduceMotion
                    )
                if picked > 0 {
                    // Said where the eye already is, so ⌫ is found without
                    // the status bar.
                    let hint =
                        "\(picked) selected \u{00B7} \u{232B} unmarks them"
                    Text(verbatim: hint)
                        .font(TextSize.caption.font(rem))
                        .monospacedDigit()
                        .foregroundStyle(theme.secondary.color)
                        .lineLimit(1)
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
                Button(action: actions.clear) {
                    Label("Unmark All", systemImage: "xmark.circle")
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.bordered)
                .controlSize(reviewCardControlSize(rem))
                .disabled(review.items.isEmpty)
                // Keys go to the window's one dispatcher (`!`); a focus
                // ring would suggest the button owns them.
                .focusEffectDisabled()
                .help("Unmark everything on this list (!)")
                .reviewControl("review-clear")
            }
            .padding(.horizontal, Space.lg.at(rem))
            .padding(.vertical, Space.md.at(rem))
            .animation(ReviewMotion.fade, value: picked > 0)
            Rectangle()
                .fill(theme.divider.color)
                .frame(height: hairline)
            ReviewTable(
                review: review,
                rows: rows,
                actions: actions,
                selection: $selection,
                order: $order
            )
            // Ideally short: the rows' own height must not decide whether
            // a layout fits, only what is left once everything else has.
            .frame(
                minHeight: height ?? 0,
                idealHeight: height ?? Space.xxl.at(rem),
                maxHeight: height ?? .infinity
            )
            .frame(maxWidth: .infinity)
            if review.items.count > reviewListLimit {
                let more = UInt64(review.items.count - reviewListLimit)
                Label(
                    "\(humanCount(more)) more are marked and handed over "
                        + "too, past the end of this list. Unmark them in "
                        + "the treemap.",
                    systemImage: "ellipsis.circle"
                )
                .font(TextSize.caption.font(rem))
                .foregroundStyle(theme.secondary.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Space.lg.at(rem))
                .padding(.vertical, Space.sm.at(rem))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(theme.divider.color)
                        .frame(height: hairline)
                }
            }
        }
        .background(theme.surface.color, in: shape)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(theme.divider.color, lineWidth: hairline)
        }
    }
}

/// The table itself.
struct ReviewTable: View {
    let review: ReviewModel
    /// Sorted and capped already.
    let rows: [ReviewRow]
    let actions: ReviewActions
    @Binding var selection: Set<FilePath>
    @Binding var order: [KeyPathComparator<ReviewRow>]
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Table(of: ReviewRow.self, selection: $selection, sortOrder: $order) {
            // The name and the status take what the window gives; the
            // numbers keep lanes of their own size, so a wide window does
            // not stretch a bar into a runway. The minimums, 27 rem, fit
            // the smallest window at the largest zoom without the table
            // scrolling sideways.
            TableColumn("Name", value: \ReviewRow.name) { row in
                ReviewNameCell(row: row)
            }
            .width(min: Rems(8).at(rem), ideal: Rems(22).at(rem))
            TableColumn("Size", value: \ReviewRow.bytes) { row in
                ReviewSizeCell(row: row)
            }
            .width(
                min: Size.sizeLane.at(rem),
                ideal: Size.sizeLane.at(rem),
                max: (Size.sizeLane + Rems(2)).at(rem)
            )
            // Comparable numbers right-align, header and all.
            .alignment(.trailing)
            TableColumn("Share") { row in
                ReviewShareCell(row: row, total: review.rootBytes)
            }
            .width(
                min: Size.shareLane.at(rem),
                ideal: (Size.shareLane + Rems(1)).at(rem),
                max: (Size.shareLane + Rems(2)).at(rem)
            )
            // Only while some row has something to say there: a row the
            // command carries says nothing, and a column of nothing under
            // its header reads as something missing.
            if rows.contains(where: { $0.status != .ready }) {
                TableColumn("Status", value: \ReviewRow.statusRank) { row in
                    ReviewStatusCell(row: row)
                }
                .width(min: Rems(6).at(rem), ideal: Rems(14).at(rem))
            }
            TableColumn("") { row in
                ReviewUnmarkCell(row: row) { actions.unmark(row.path) }
            }
            .width(Rems(2).at(rem))
        } rows: {
            ForEach(rows) { row in
                TableRow(row)
                    .itemProvider(
                        row.handedOver ? { reviewDragItem(row) } : nil
                    )
            }
        }
        // The system's inset table: rows selected with a rounded
        // highlight, inside the card's own margins, and no stripes: the
        // rows are told apart by their content, as Finder's are.
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, Rems(2).at(rem))
        .overlay {
            if rows.isEmpty {
                ReviewEmptyList()
                    .allowsHitTesting(false)
            }
        }
        .contextMenu(forSelectionType: FilePath.self) { paths in
            let picked = rows.filter { paths.contains($0.path) }
            ForEach(ReviewRowCommand.menu(for: picked)) { command in
                if command.kind == .unmark {
                    Divider()
                }
                Button(command.title, systemImage: command.symbol) {
                    command.kind.perform(on: picked, actions)
                }
                .disabled(!command.enabled)
            }
        } primaryAction: { paths in
            // A double-click looks inside, as it would in Finder, without
            // leaving the app.
            let picked = rows.filter { paths.contains($0.path) }
            ReviewRowCommand.Kind.quickLook.perform(on: picked, actions)
        }
        .onDeleteCommand {
            let picked = selectedRows
            ReviewRowCommand.Kind.unmark.perform(on: picked, actions)
            selection.subtract(picked.map(\.path))
        }
        // The Edit menu's Copy, while a row is selected: their paths, one
        // per line, through the same pasteboard the command goes to.
        .onCommand(#selector(NSText.copy(_:))) {
            ReviewRowCommand.Kind.copyPath.perform(on: selectedRows, actions)
        }
        // With Quick Look up, the preview follows the selection, as
        // Finder's does.
        .onChange(of: selection) {
            let picked = selectedRows
            if review.previewing, picked.count == 1 {
                ReviewRowCommand.Kind.quickLook.perform(on: picked, actions)
            }
        }
        .animation(ReviewMotion.rows(reduceMotion), value: rows.map(\.id))
        .accessibilityLabel("Marked paths")
    }

    /// The selected rows still on the list, in its order.
    private var selectedRows: [ReviewRow] {
        rows.filter { selection.contains($0.path) }
    }
}

/// What an empty list says: a large quiet symbol and the way back.
private struct ReviewEmptyList: View {
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    var body: some View {
        VStack(spacing: Space.sm.at(rem)) {
            Image(systemName: "checklist.unchecked")
                .font(.system(size: Space.xxl.at(rem), weight: .light))
                .foregroundStyle(theme.secondary.opacity(0.6).color)
            Text("Nothing is marked")
                .font(TextSize.title.font(rem, weight: .semibold))
                .foregroundStyle(theme.bright.color)
            Text("Go back to the treemap and mark what should go.")
                .font(TextSize.caption.font(rem))
                .foregroundStyle(theme.secondary.color)
        }
        .padding(Space.xxl.at(rem))
    }
}

// MARK: - Cells

/// The icon, the name, whether Finder hides it, and the folder it is in,
/// dim beside it: the name keeps its room, the folder gives way.
private struct ReviewNameCell: View {
    let row: ReviewRow
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let ink = ReviewInk(theme: theme, prominence: prominence)
        // A mark the command leaves out, or that is gone already, steps
        // back; one the command removes reads first.
        let quiet = !row.handedOver
        HStack(alignment: .center, spacing: Space.sm.at(rem)) {
            Image(
                systemName: row.symbol + (row.isGone ? ".circle.fill" : ".fill")
            )
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: IconSize.md.at(rem)))
            .foregroundStyle(
                ink(
                    row.isGone
                        ? theme.success
                        : quiet ? theme.secondary : theme.accent
                )
            )
            .frame(width: IconSize.lg.at(rem))
            .contentTransition(ReviewMotion.symbol(reduceMotion))
            .animation(ReviewMotion.change(reduceMotion), value: row.symbol)
            Text(verbatim: row.name)
                .fontWeight(.medium)
                .foregroundStyle(
                    ink(quiet ? theme.secondary : theme.bright)
                )
                .lineLimit(1)
                .truncationMode(.middle)
                .reviewStruck(row.isGone, color: ink(theme.secondary))
                .layoutPriority(1)
            if row.hidden {
                // Finder hides dotfiles: revealed there, this one is only
                // seen once ⌘⇧. shows hidden files.
                Image(systemName: "eye.slash")
                    .font(TextSize.caption.font(rem))
                    .foregroundStyle(ink(theme.secondary))
                    .help(
                        "Hidden: Finder shows it once \u{2318}\u{21E7}. "
                            + "shows hidden files"
                    )
            }
            // Cut in the middle, as a Mac cuts a path everywhere else in
            // the app: where it starts, `~` or the volume, and the folder
            // holding the mark both stay.
            // Never cut to a sliver: a long name gives up enough room for
            // the folder's last few letters.
            Text(verbatim: row.folder)
                .font(TextSize.caption.font(rem))
                .foregroundStyle(ink(theme.secondary))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: Rems(3).at(rem), alignment: .leading)
            Spacer(minLength: 0)
        }
        .font(TextSize.body.font(rem))
        .padding(.vertical, Space.xxs.at(rem))
        .contentShape(Rectangle())
        // What can be dragged out says so under the pointer.
        .pointerStyle(row.handedOver ? .grabIdle : nil)
        .help(row.path.string)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spoken)
    }
}

/// The size in rounded figures, right-aligned so sizes compare down the
/// column.
private struct ReviewSizeCell: View {
    let row: ReviewRow
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let ink = ReviewInk(theme: theme, prominence: prominence)
        Text(humanBytes(row.bytes))
            .font(TextSize.body.font(rem, weight: .medium))
            .fontDesign(.rounded)
            .monospacedDigit()
            .foregroundStyle(ink(row.isGone ? theme.secondary : theme.bright))
            .lineLimit(1)
            .reviewStruck(row.isGone, color: ink(theme.secondary))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel(humanBytes(row.bytes))
    }
}

/// Its share of the whole scan: a small capsule, and the number beside it
/// for a share too small to see.
private struct ReviewShareCell: View {
    let row: ReviewRow
    let total: UInt64
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let ink = ReviewInk(theme: theme, prominence: prominence)
        // More than the whole scan is a mark outside it (the directory
        // holding the root, say): a share of the scan means nothing there.
        let outside = row.bytes > total
        let fraction = outside ? 0 : share(row.bytes, of: total) / 100
        let figure = outside ? "\u{2014}" : percent(row.bytes, of: total)
        HStack(spacing: Space.xs.at(rem)) {
            GeometryReader { track in
                Capsule()
                    .fill(ink(theme.foreground.opacity(0.1)))
                    .overlay(alignment: .leading) {
                        if fraction > 0 {
                            // A sliver still shows as a dot of colour.
                            Capsule()
                                .fill(
                                    ink(
                                        row.handedOver
                                            ? theme.accent : theme.secondary)
                                )
                                .frame(
                                    width: max(
                                        track.size.width * fraction,
                                        track.size.height
                                    )
                                )
                        }
                    }
            }
            .frame(height: Size.meter.at(rem) + Space.xxs.at(rem))
            .frame(maxWidth: .infinity)
            Text(verbatim: figure)
                .font(TextSize.caption.font(rem))
                .monospacedDigit()
                .foregroundStyle(ink(theme.secondary))
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            outside ? "outside the scan" : "\(figure) of the scan"
        )
    }
}

/// Covered, kept back and why, or gone, as a tinted tag with its symbol:
/// blank for a row the command carries.
private struct ReviewStatusCell: View {
    let row: ReviewRow
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let ink = ReviewInk(theme: theme, prominence: prominence)
        let (color, symbol): (HSLA, String) =
            switch row.status {
            case .ready: (theme.secondary, "")
            case .covered: (theme.secondary, "arrow.turn.down.right")
            case .blocked: (theme.caution, "hand.raised.fill")
            case .gone: (theme.success, "checkmark.circle.fill")
            }
        HStack(spacing: 0) {
            if !row.statusText.isEmpty {
                Label {
                    Text(verbatim: row.statusText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } icon: {
                    Image(systemName: symbol)
                }
                .labelStyle(ReviewTightLabel(spacing: Space.xs.at(rem)))
                .font(TextSize.caption.font(rem, weight: .medium))
                .foregroundStyle(ink(color))
                .padding(.horizontal, Space.sm.at(rem))
                .padding(.vertical, Space.xxs.at(rem))
                .background(
                    prominence == .increased
                        ? Color.white.opacity(0.18)
                        : color.opacity(0.12).color,
                    in: Capsule()
                )
            }
            Spacer(minLength: 0)
        }
        // The whole reason, when the column cuts it short.
        .help(row.statusText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            row.handedOver ? "in the command" : row.statusText
        )
    }
}

/// Unmark this row: the one control repeated down the list, so it is an
/// icon, quiet until the pointer is on it.
private struct ReviewUnmarkCell: View {
    let row: ReviewRow
    let unmark: @MainActor () -> Void
    @State private var hovering = false
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let ink = ReviewInk(theme: theme, prominence: prominence)
        Button(action: unmark) {
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: IconSize.md.at(rem) + Space.xxs.at(rem)))
                .foregroundStyle(
                    ink(
                        hovering
                            ? theme.danger : theme.secondary.opacity(0.7)
                    )
                )
                // It grows a touch under the pointer; with Reduce Motion it
                // only changes colour.
                .scaleEffect(hovering && !reduceMotion ? 1.12 : 1)
                .animation(ChromeMotion.move, value: hovering)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Keys go to the window's one dispatcher, and ⌫ to the table; a
        // focus ring here would suggest the button owns them.
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .help(
            "Unmark \(row.name). Select rows and press \u{232B} to unmark "
                + "several."
        )
        .accessibilityLabel("Unmark \(row.name)")
        .reviewControl("unmark-\(row.index)")
    }
}

/// A theme colour in a cell, or the selected-row text colour while the row
/// is selected in a focused table: AppKit fills that row with the accent
/// colour, and the theme's greys and amber do not read on it.
private struct ReviewInk {
    let theme: Theme
    let prominence: BackgroundProminence

    func callAsFunction(_ color: HSLA) -> Color {
        guard prominence == .increased else {
            return color.color
        }
        // The selection's own text colour, as dim as the theme colour is
        // translucent, so a quiet row stays quieter than a loud one.
        return Color(nsColor: .alternateSelectedControlTextColor)
            .opacity(max(color.a, 0.6))
    }
}

// MARK: - The strike

extension View {
    /// Struck through while `on`: a hairline across the middle that draws
    /// from the leading edge as a row goes from disk, and simply fades in
    /// with Reduce Motion.
    func reviewStruck(_ on: Bool, color: Color) -> some View {
        modifier(ReviewStrike(on: on, color: color))
    }
}

private struct ReviewStrike: ViewModifier {
    let on: Bool
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .leading) {
            Rectangle()
                .fill(color)
                .frame(height: hairline)
                .scaleEffect(x: on || reduceMotion ? 1 : 0, anchor: .leading)
                .opacity(on ? 1 : 0)
                .animation(ReviewMotion.strike(reduceMotion), value: on)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
