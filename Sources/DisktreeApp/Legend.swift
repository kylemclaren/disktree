// The row over the mosaic: what the colours mean, and what the find is
// finding while there is a find.
//
// The legend is a row of keys, one per kind (or per age, in Age mode), each
// a swatch of its colour and its name, as a chart's legend is; the pointer
// on one picks its kind out of the mosaic. The button at its end opens the
// breakdown of the directory drawn, what each kind weighs there, as a chart.
// The find's own field is the toolbar's; this says what it matches and what
// Enter and Escape will do with it.

import AppKit
import DisktreeCore
import SwiftUI
import System

/// The legend and the find's matches, on one row over the mosaic.
struct LegendRow: View {
    let state: AppState
    @Environment(\.rem) private var rem
    @Environment(\.accessibilityReduceMotion) private var reduced

    var body: some View {
        let finding = state.findOpen || !state.find.isEmpty
        let mark = Self.mark(state)
        HStack(spacing: Space.md.at(rem)) {
            Legend(state: state)
                .layoutPriority(1)
            Spacer(minLength: 0)
            if let mark {
                // Said once, here, rather than painted over every tile.
                InsideMarkChip(state: state, mark: mark)
                    .layoutPriority(3)
                    .transition(
                        ChromeMotion.transition(
                            .opacity.combined(with: .scale(scale: 0.96)),
                            reduced: reduced
                        )
                    )
            }
            if finding {
                // What is being found matters more than the key to the
                // colours: the legend gives up its room first.
                FindStatus(state: state)
                    .layoutPriority(2)
                    // It grows a little into place; with Reduce Motion it
                    // only fades.
                    .transition(
                        ChromeMotion.transition(
                            .opacity.combined(with: .scale(scale: 0.96)),
                            reduced: reduced
                        )
                    )
            }
        }
        .padding(.horizontal, Space.lg.at(rem))
        .padding(.vertical, Space.sm.at(rem))
        .animation(
            ChromeMotion.animation(ChromeMotion.arrive, reduced: reduced),
            value: finding
        )
        .animation(
            ChromeMotion.animation(ChromeMotion.arrive, reduced: reduced),
            value: mark
        )
    }

    /// The mark the directory drawn goes with: itself, or the outermost
    /// marked directory holding it.
    static func mark(_ state: AppState) -> FilePath? {
        guard !state.marks.items.isEmpty else { return nil }
        let here = state.currentPath
        return state.markedAncestor(of: here)
            ?? (state.marks.contains(here) ? here : nil)
    }
}

/// What the whole screen goes with, when the directory drawn is marked or
/// inside a marked one: the mark's name in its colour, and the way to keep
/// it after all.
private struct InsideMarkChip: View {
    let state: AppState
    let mark: FilePath
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    var body: some View {
        let name = SelectionSection.shortName(mark)
        let here = mark == state.currentPath
        HStack(spacing: Space.sm.at(rem)) {
            Label(
                here ? "\(name) is marked" : "Inside marked \(name)",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(theme.danger.color)
            .lineLimit(1)
            Button {
                state.unmark(mark)
            } label: {
                Text("Unmark")
                    .padding(.horizontal, Space.sm.at(rem))
                    .padding(.vertical, Space.xxs.at(rem))
            }
            .buttonStyle(PressableFill(.capsule))
            .foregroundStyle(theme.bright.color)
            .fontWeight(.medium)
            .focusEffectDisabled()
            .help("Unmark \(name): everything here stays")
        }
        .font(TextSize.caption.font(rem))
        .padding(.leading, Space.md.at(rem))
        .padding(.trailing, Space.xs.at(rem))
        .padding(.vertical, Space.xxs.at(rem))
        .background(theme.danger.opacity(0.1).color, in: Capsule())
        .overlay {
            Capsule().strokeBorder(
                theme.danger.opacity(0.35).color,
                lineWidth: hairline
            )
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .chromeIdentifier("inside-mark")
    }
}

// MARK: - What the scan could not read

/// What the scan found it could not read, and the way to the one switch
/// that opens most of it.
enum ScanTotals {
    /// Whether any unreadable path was refused for want of permission.
    ///
    /// The scanner reports each one as `path: reason`, the reason as
    /// `strerror` says it. macOS privacy refuses a protected folder with
    /// `EPERM`, and Full Disk Access is what opens it. `EACCES` is a
    /// folder's own permissions, which that setting does not lift; it is
    /// offered for those too, since a scan refused either way should point
    /// at the one switch the user has, and System Settings says what it
    /// covers.
    nonisolated static func needsFullDiskAccess(_ messages: [String]) -> Bool {
        let reasons = [EPERM, EACCES].map {
            ": " + String(cString: strerror($0))
        }
        return messages.contains { message in
            reasons.contains { message.hasSuffix($0) }
        }
    }
}

/// Folders the scan could not read, counted in the caution colour, and the
/// way to Full Disk Access when macOS privacy is what kept them closed.
struct UnreadableNote: View {
    let state: AppState
    @State private var hovering = false
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    var body: some View {
        let progress = state.progress
        HStack(spacing: Space.xs.at(rem)) {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.hierarchical)
            Text("\(humanCount(progress.errors)) unreadable")
                .monospacedDigit()
                .help(
                    "Folders the scan could not read: counted as "
                        + "unreadable, never guessed at"
                )
            if ScanTotals.needsFullDiskAccess(progress.messages) {
                Button("Grant Full Disk Access\u{2026}") {
                    NSWorkspace.shared.open(FullDiskAccess.settingsURL)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .foregroundStyle(theme.accent.color)
                .underline(hovering)
                .onHover { hovering = $0 }
                .pointerStyle(.link)
                .help(
                    "Some folders are closed to apps until System Settings "
                        + "gives them Full Disk Access"
                )
                .chromeIdentifier("grant-access")
            }
        }
        .font(TextSize.caption.font(rem))
        .foregroundStyle(theme.caution.color)
        .lineLimit(1)
        .fixedSize()
        .chromeIdentifier("unreadable")
    }
}

// MARK: - Find status

/// What the find text matches as it is typed, and what Enter and Escape
/// will do with it; the text itself is in the toolbar's field. In the
/// highlight once Enter has laid out only the matches.
struct FindStatus: View {
    let state: AppState
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    var body: some View {
        let (summary, hint) = Self.summaryAndHint(state)
        let applied = state.filterApplied
        let tint = applied ? theme.highlight : theme.accent
        HStack(spacing: Space.sm.at(rem)) {
            Image(
                systemName: applied
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "magnifyingglass"
            )
            .foregroundStyle(tint.color)
            .contentTransition(.symbolEffect(.replace))
            if !state.find.isEmpty {
                Text("\u{201c}\(state.find)\u{201d}")
                    .foregroundStyle(theme.bright.color)
                    .truncationMode(.middle)
                    .layoutPriority(1)
            }
            if !summary.isEmpty {
                Text(summary)
                    .monospacedDigit()
                    .foregroundStyle(
                        (applied ? theme.bright : theme.secondary).color
                    )
                    .fixedSize()
                    .rollingDigits(summary)
            }
            if let hint {
                KeyHint(keys: hint.keys, label: hint.label)
            }
            if !state.find.isEmpty {
                Button {
                    state.clearFilter()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(theme.secondary.color)
                        .padding(Space.xxs.at(rem))
                }
                .buttonStyle(PressableFill(.circle))
                .focusEffectDisabled()
                .help("Clear the filter \u{00b7} esc")
                .accessibilityLabel("Clear the filter")
            }
        }
        .font(TextSize.caption.font(rem))
        .lineLimit(1)
        .padding(.horizontal, Space.md.at(rem))
        .padding(.vertical, Space.xs.at(rem))
        .background(tint.opacity(applied ? 0.18 : 0.1).color, in: Capsule())
        .overlay {
            Capsule().strokeBorder(
                tint.opacity(0.45).color, lineWidth: hairline)
        }
        .animation(ChromeMotion.fade, value: applied)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Filter by name: " + (state.find.isEmpty ? "empty" : state.find)
        )
        .accessibilityValue(summary)
        .chromeIdentifier("find-status")
    }

    /// What the text matches, said beside it, and the key that acts on it.
    static func summaryAndHint(
        _ state: AppState
    ) -> (String, (keys: String, label: String)?) {
        guard let matches = state.matches else {
            return state.finding
                ? ("searching\u{2026}", nil)
                : ("type a name to filter", nil)
        }
        if matches.count == 0 {
            return ("no matches", ("esc", "clears"))
        }
        let noun = matches.count == 1 ? "match" : "matches"
        return (
            "\(humanCount(UInt64(matches.count))) \(noun) \u{00b7} "
                + humanBytes(matches.bytes),
            state.filterApplied
                ? ("esc", "clears") : ("return", "shows only these")
        )
    }
}

// MARK: - Legend

/// The key to the colours: a swatch and a name for each kind, or for each
/// age in Age mode, as Swift Charts draws a chart's legend — no capsule, no
/// border — and at its end the one button that opens the breakdown. When
/// the row runs out of room it drops keys from the trailing end, whole.
///
/// A key under the pointer picks its kind out of the mosaic: every other
/// tile steps back, as a chart's legend picks out its series, and comes
/// back when the pointer moves on.
struct Legend: View {
    let state: AppState
    /// The breakdown is open.
    @State private var open = false
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem
    @Environment(\.floatingGlass) private var glass

    var body: some View {
        let age = state.colorMode == .age
        let keys: [LegendFocus] =
            [.reclaimable]
            + (age
                ? ageBuckets.indices.map(LegendFocus.age)
                : DisktreeCore.Category.legend.map(LegendFocus.kind))
        HStack(spacing: Space.md.at(rem)) {
            FittingPrefix(count: keys.count, spacing: Space.md.at(rem)) {
                index in
                LegendKey(
                    state: state,
                    focus: keys[index],
                    label: label(keys[index])
                ) {
                    swatch(keys[index])
                }
            }
            // Stays when the keys run short of room: the breakdown says
            // more than the colours do.
            breakdown(age: age)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(age ? "Legend: age" : "Legend: kinds")
        .chromeIdentifier("legend", container: true)
    }

    /// What each kind, or each age, weighs in the directory drawn, as a
    /// chart in a popover.
    private func breakdown(age: Bool) -> some View {
        Button {
            open.toggle()
        } label: {
            Label("Breakdown", systemImage: "chart.bar.xaxis")
                .font(TextSize.caption.font(rem, weight: .medium))
        }
        .modifier(LegendButtonLook(glass: glass))
        .controlSize(.small)
        .focusEffectDisabled()
        .help(
            age
                ? "What was written when, in this folder"
                : "What each kind weighs in this folder"
        )
        .accessibilityHint(
            "Shows what each \(age ? "age" : "kind") weighs in this folder"
        )
        .popover(isPresented: $open, arrowEdge: .bottom) {
            // A popover is a window of its own: it is handed what the
            // screens read from the root.
            KindBreakdown(state: state)
                .environment(\.theme, theme)
                .environment(\.rem, rem)
        }
        .chromeIdentifier("legend-breakdown")
    }

    @ViewBuilder
    private func swatch(_ key: LegendFocus) -> some View {
        switch key {
        case .reclaimable:
            RoundedRectangle(
                cornerRadius: Rounding.swatch.at(rem),
                style: .continuous
            )
            .fill(theme.categoryFill(.other, depth: 0).color)
            .overlay {
                HatchFill(.dense, color: theme.bright.opacity(0.5))
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: Rounding.swatch.at(rem),
                            style: .continuous
                        )
                    )
            }
            .overlay {
                RoundedRectangle(
                    cornerRadius: Rounding.swatch.at(rem),
                    style: .continuous
                )
                .strokeBorder(
                    theme.secondary.opacity(0.5).color,
                    lineWidth: hairline
                )
            }
        case .kind(let category):
            RoundedRectangle(
                cornerRadius: Rounding.swatch.at(rem),
                style: .continuous
            )
            .fill(theme.categoryAccent(category).color)
        case .age(let bucket):
            RoundedRectangle(
                cornerRadius: Rounding.swatch.at(rem),
                style: .continuous
            )
            .fill(theme.ageAccent(bucket: bucket).color)
        }
    }

    private func label(_ key: LegendFocus) -> String {
        switch key {
        case .reclaimable: "Reclaimable"
        case .kind(let category): category.label
        case .age(let bucket): ageBuckets[bucket].label
        }
    }
}

/// The breakdown's button: Liquid Glass where it can be seen, the bordered
/// button elsewhere.
private struct LegendButtonLook: ViewModifier {
    let glass: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26, *), glass {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

/// One key of the legend: its swatch and its name, in the dim text. Under
/// the pointer its name comes up to the text colour and its kind is picked
/// out of the mosaic; that is all it does, so it is no button.
private struct LegendKey<Swatch: View>: View {
    let state: AppState
    let focus: LegendFocus
    let label: String
    @ViewBuilder let swatch: () -> Swatch
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    var body: some View {
        let lit = state.legendFocus == focus
        HStack(spacing: Space.xs.at(rem)) {
            swatch()
                .frame(width: Size.swatch.at(rem), height: Size.swatch.at(rem))
            Text(label)
                .foregroundStyle((lit ? theme.bright : theme.secondary).color)
                .lineLimit(1)
        }
        .font(TextSize.caption.font(rem))
        .fixedSize()
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                state.legendFocus = focus
            } else if state.legendFocus == focus {
                state.legendFocus = nil
            }
        }
        // A key that goes while pointed at — the row runs short of room,
        // the colours change to ages, the screen changes — takes its pick
        // with it, or the mosaic would stay stepped back with no key lit.
        .onDisappear {
            if state.legendFocus == focus {
                state.legendFocus = nil
            }
        }
        .animation(ChromeMotion.hover, value: lit)
        .accessibilityElement(children: .combine)
    }
}

/// The longest run of items, from the first, that fits the room whole:
/// most useful first, so a narrow window loses the least useful, and an
/// item is never cut through the middle. What does not fit is not drawn at
/// all, so it is not read out either.
///
/// Each item is measured once, and the run is counted from those widths
/// (`PrefixRow`). A `ViewThatFits` over every run measured every item once
/// per run, all over again whenever the row around it laid out, which it
/// does on every keystroke of a find: a third of a second of layout, for a
/// row of nine keys.
struct FittingPrefix<Item: View>: View {
    let count: Int
    let spacing: CGFloat
    @ViewBuilder let item: (Int) -> Item

    var body: some View {
        PrefixRow(spacing: spacing) {
            ForEach(0..<max(count, 0), id: \.self) { index in
                // Given no room, an item left out draws nothing and says
                // nothing; given its own width, it is itself.
                ViewThatFits(in: .horizontal) {
                    item(index)
                    Color.clear
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

/// A row of items, as an `HStack` lays them out, of which only the longest
/// run from the first that fits the room whole takes room: the rest are
/// offered none, which `FittingPrefix`'s items answer by drawing nothing.
struct PrefixRow: Layout {
    var spacing: CGFloat

    struct Cache {
        /// Each item at its own width, measured once per update.
        var sizes: [CGSize]
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        let widths = cache.sizes.map(\.width)
        let shown = Self.fitting(widths, spacing: spacing, room: proposal.width)
        let run = cache.sizes.prefix(shown)
        return CGSize(
            width: run.map(\.width).reduce(0, +)
                + spacing * CGFloat(max(shown - 1, 0)),
            height: run.map(\.height).max() ?? 0
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        let widths = cache.sizes.map(\.width)
        let shown = Self.fitting(widths, spacing: spacing, room: bounds.width)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let origin = CGPoint(x: x, y: bounds.midY)
            guard index < shown else {
                subview.place(at: origin, anchor: .leading, proposal: .zero)
                continue
            }
            let size = cache.sizes[index]
            subview.place(
                at: origin,
                anchor: .leading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
        }
    }

    /// How many of `widths`, from the first, fit `room` whole with
    /// `spacing` between them: all of them when the room is unbounded.
    /// A hair of slack, so an item offered exactly its own measured width
    /// is not refused for rounding.
    nonisolated static func fitting(
        _ widths: [CGFloat],
        spacing: CGFloat,
        room: CGFloat?
    ) -> Int {
        guard let room, room.isFinite else {
            return widths.count
        }
        var used: CGFloat = 0
        for (index, width) in widths.enumerated() {
            used += (index > 0 ? spacing : 0) + width
            if used > room + 0.01 {
                return index
            }
        }
        return widths.count
    }
}

// MARK: - Notice

/// The last thing that happened, or a scan error, under the legend. The
/// side panel shows it above the disk; this stands in only while the panel
/// has given way to a narrow window, so the notice is never lost. A new
/// notice slides down into place.
struct ExploreNotice: View {
    let state: AppState
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem
    @Environment(\.accessibilityReduceMotion) private var reduced

    var body: some View {
        VStack(spacing: 0) {
            if let line {
                let color = line.color
                HStack(alignment: .firstTextBaseline, spacing: Space.sm.at(rem))
                {
                    Image(systemName: line.symbol)
                        .symbolRenderingMode(.hierarchical)
                    Text(line.message)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(TextSize.caption.font(rem))
                .foregroundStyle(color.color)
                .padding(.horizontal, Space.md.at(rem))
                .padding(.vertical, Space.sm.at(rem))
                .background(
                    color.opacity(0.1).color,
                    in: RoundedRectangle(
                        cornerRadius: Rounding.card.at(rem),
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: Rounding.card.at(rem),
                        style: .continuous
                    )
                    .strokeBorder(color.opacity(0.4).color, lineWidth: hairline)
                }
                .padding(.horizontal, Space.lg.at(rem))
                .padding(.bottom, Space.sm.at(rem))
                .id(line.message)
                .transition(
                    ChromeMotion.transition(
                        .move(edge: .top).combined(with: .opacity),
                        reduced: reduced
                    )
                )
                .chromeIdentifier("explore-notice")
            }
        }
        .clipped()
        .animation(
            ChromeMotion.animation(ChromeMotion.arrive, reduced: reduced),
            value: line?.message
        )
    }

    private var line: (message: String, color: HSLA, symbol: String)? {
        if let error = state.scanError {
            return (error, theme.danger, "xmark.octagon.fill")
        }
        guard let notice = state.notice else {
            return nil
        }
        let symbol =
            switch notice.status {
            case .success: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .error: "xmark.octagon.fill"
            case .neutral: "info.circle.fill"
            }
        return (notice.sentence, theme.alertColor(notice.status), symbol)
    }
}
