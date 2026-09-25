// The breakdown the legend opens: what each kind of data weighs in the
// directory drawn, as a chart.
//
// The mosaic says the same thing in area, but areas are hard to add up by
// eye when one kind is spread over a hundred tiles; a bar per kind adds them
// up. It measures the directory on screen in the metric on screen — bytes,
// or files in the Files view — and, when the colours say age, by how long
// since anything was written, as the legend it opens from does.
//
// Measuring visits every entry below the directory, which in a home
// directory is millions of them, so it happens off the main actor, once per
// directory, tree and metric, and the chart waits for it. What can be had
// back is added up on the way, and is the one figure in the highlight.

import Charts
import DisktreeCore
import SwiftUI
import System

/// What a directory holds, by kind and by age, in one metric.
struct Breakdown: Sendable, Hashable {
    /// Each kind's value, in `Category.allCases` order.
    var kinds: [UInt64]
    /// Each `ageBuckets` bucket's value, newest first.
    var ages: [UInt64]
    /// What has no write time the scan could read.
    var undated: UInt64
    /// What can be had back: what the mosaic hatches.
    var reclaimable: UInt64
    /// The whole directory: what every row is a share of.
    var total: UInt64

    /// Every entry below `node`, added up by kind and by age in `metric`,
    /// ages as of `now` (Unix seconds). `nil` when `cancelled` says to stop.
    ///
    /// Only files carry weight: a directory's value is its files' (it is
    /// derived, never tracked — Invariant 2), and a file takes the kind of
    /// the directory that holds it, as the mosaic colours it. So every row
    /// is made of the same entries the directory's own total is, and they
    /// add up to it.
    nonisolated static func measure(
        _ node: Node,
        metric: Metric,
        now: Int64,
        cancelled: () -> Bool = { false }
    ) -> Breakdown? {
        let kinds = DisktreeCore.Category.allCases
        var result = Breakdown(
            kinds: Array(repeating: 0, count: kinds.count),
            ages: Array(repeating: 0, count: ageBuckets.count),
            undated: 0,
            reclaimable: 0,
            total: node.value(metric)
        )
        var visited = 0
        // Returns false once cancelled, and the walk unwinds.
        func visit(_ node: Node, reclaimable: Bool) -> Bool {
            visited += 1
            // Often enough that a closed popover stops a long walk at once,
            // rarely enough to cost nothing.
            if visited % 16_384 == 0 && cancelled() {
                return false
            }
            let reclaimable = reclaimable || node.reclaim != nil
            guard node.isDir else {
                let value = node.value(metric)
                if let kind = kinds.firstIndex(of: node.category) {
                    result.kinds[kind] &+= value
                }
                if node.modified > 0 {
                    let days = max(now - node.modified, 0) / 86_400
                    result.ages[ageBucket(days: days)] &+= value
                } else {
                    result.undated &+= value
                }
                if reclaimable {
                    result.reclaimable &+= value
                }
                return true
            }
            for child in node.children {
                if !visit(child, reclaimable: reclaimable) {
                    return false
                }
            }
            return true
        }
        guard visit(node, reclaimable: false) else {
            return nil
        }
        return result
    }

    /// `measure`, off the main actor, stopping when the task asking is
    /// cancelled.
    nonisolated static func measuring(
        _ node: Node,
        metric: Metric,
        now: Int64
    ) async -> Breakdown? {
        measure(node, metric: metric, now: now) { Task.isCancelled }
    }
}

/// One bar of the chart.
struct BreakdownRow: Sendable, Hashable, Identifiable {
    var label: String
    var value: UInt64
    var color: HSLA

    var id: String { label }
}

extension Breakdown {
    /// The rows the chart draws for the legend in `mode`: the kinds that
    /// hold anything, largest first; or the age ramp, newest first, as the
    /// legend lists it, with what has no date last.
    func rows(_ mode: ColorMode, theme: Theme) -> [BreakdownRow] {
        switch mode {
        case .kind:
            let kinds = DisktreeCore.Category.allCases
            return zip(kinds, self.kinds)
                .enumerated()
                .filter { $0.element.1 > 0 }
                // Largest first; equal ones in the legend's own order.
                .sorted {
                    ($0.element.1, $1.offset) > ($1.element.1, $0.offset)
                }
                .map { _, pair in
                    BreakdownRow(
                        label: pair.0.label,
                        value: pair.1,
                        color: theme.categoryAccent(pair.0)
                    )
                }
        case .age:
            var rows = ageBuckets.indices.compactMap { bucket in
                ages[bucket] > 0
                    ? BreakdownRow(
                        label: ageBuckets[bucket].label,
                        value: ages[bucket],
                        color: theme.ageAccent(bucket: bucket)
                    ) : nil
            }
            if undated > 0 {
                rows.append(
                    BreakdownRow(
                        label: "Unknown",
                        value: undated,
                        color: theme.secondary.opacity(0.5)
                    )
                )
            }
            return rows
        }
    }
}

// MARK: - The popover

/// The popover's width: a label, a bar worth comparing, and a figure.
private let breakdownWidth = Rems(24)

/// The breakdown of the directory drawn, measured when it opens and again
/// whenever the directory, the tree or the metric changes under it.
struct KindBreakdown: View {
    let state: AppState
    @State private var measured: Measured?
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    /// What a breakdown was measured for.
    private struct Key: Hashable {
        var root: FilePath
        var crumbs: [Int]
        var metric: Metric
        var epoch: Int
        var landed: Int64
    }

    private struct Measured: Equatable {
        var key: Key
        var breakdown: Breakdown
    }

    var body: some View {
        let key = Key(
            root: state.rootPath,
            crumbs: state.crumbs,
            metric: state.options.metric,
            epoch: state.scanEpoch,
            landed: state.scannedAt
        )
        let place = displayPath(state.currentPath, home: state.home)
        Group {
            if let measured {
                BreakdownChart(
                    breakdown: measured.breakdown,
                    mode: state.colorMode,
                    metric: key.metric,
                    place: place,
                    measuring: measured.key != key
                )
            } else {
                HStack(spacing: Space.sm.at(rem)) {
                    Spinner(fitting: IconSize.lg.at(rem), color: theme.accent)
                    Text("Adding up \(place)\u{2026}")
                        .font(TextSize.caption.font(rem))
                        .foregroundStyle(theme.secondary.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(Space.lg.at(rem))
                .frame(width: breakdownWidth.at(rem), alignment: .leading)
            }
        }
        .task(id: key) {
            guard measured?.key != key, let node = state.current else {
                return
            }
            let breakdown = await Breakdown.measuring(
                node,
                metric: key.metric,
                now: key.landed
            )
            if let breakdown, !Task.isCancelled {
                measured = Measured(key: key, breakdown: breakdown)
            }
        }
    }
}

/// The chart itself, drawn from a breakdown already measured: a bar per
/// kind (or per age) in the legend's colours, its value and share written
/// beside it, and what can be had back underneath.
struct BreakdownChart: View {
    let breakdown: Breakdown
    let mode: ColorMode
    let metric: Metric
    /// Where it was measured, as the trail would say it.
    let place: String
    /// A newer breakdown is being measured: this one is shown until then.
    var measuring = false
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem
    @Environment(\.accessibilityReduceMotion) private var reduced

    /// One bar's band: a caption line with room above and below.
    private static let rowHeight = Rems(1.625)

    var body: some View {
        let rows = breakdown.rows(mode, theme: theme)
        let largest = Double(rows.map(\.value).max() ?? 1)
        VStack(alignment: .leading, spacing: Space.md.at(rem)) {
            header
            if rows.isEmpty {
                Text("Nothing here weighs anything yet")
                    .font(TextSize.caption.font(rem))
                    .foregroundStyle(theme.secondary.color)
            } else {
                chart(rows, largest: largest)
            }
            reclaimable
        }
        .padding(Space.lg.at(rem))
        .frame(width: breakdownWidth.at(rem), alignment: .leading)
        // The bars grow to their new lengths. A length has no fade: with
        // motion reduced, they are simply new, as `growing` has them.
        .animation(reduced ? nil : ChromeMotion.arrive, value: breakdown)
        // Only the dimming fades, whatever the motion: scoped to the
        // opacity, so it never carries the bars with it.
        .animation(ChromeMotion.fade) { chart in
            chart.opacity(measuring ? 0.6 : 1)
        }
        .chromeIdentifier("kind-breakdown", container: true)
    }

    /// What the chart is of, and where, over the whole of it in the
    /// rounded figures the panel uses.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm.at(rem)) {
            VStack(alignment: .leading, spacing: Space.xxs.at(rem)) {
                // The symbol in the accent, drawn in layers, as every other
                // header's is; the words in the text colour.
                Label {
                    Text(mode == .age ? "By last write" : "By kind")
                        .foregroundStyle(theme.bright.color)
                } icon: {
                    Image(
                        systemName: mode == .age
                            ? "clock.arrow.circlepath" : "chart.bar.xaxis"
                    )
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(theme.accent.color)
                }
                .font(TextSize.title.font(rem, weight: .semibold))
                .labelStyle(.titleAndIcon)
                Text(place)
                    .font(TextSize.caption.font(rem))
                    .foregroundStyle(theme.secondary.color)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
            if measuring {
                Spinner(fitting: IconSize.sm.at(rem), color: theme.accent)
            }
            Text(format(breakdown.total))
                .font(
                    .system(
                        size: TextSize.heading.at(rem),
                        weight: .bold,
                        design: .rounded
                    )
                )
                .monospacedDigit()
                .foregroundStyle(theme.bright.color)
                .rollingDigits(format(breakdown.total))
        }
    }

    private func chart(_ rows: [BreakdownRow], largest: Double) -> some View {
        Chart(rows) { row in
            BarMark(
                x: .value("Weight", Double(row.value)),
                y: .value("Kind", row.label),
                // Twice a meter's thickness: a bar to compare, not a rule.
                height: .fixed(Size.meter.at(rem) * 2)
            )
            // Round-ended, as the panel's meters are.
            .clipShape(Capsule())
            .foregroundStyle(row.color.color)
            .annotation(position: .trailing, alignment: .leading) {
                Text(
                    "\(format(row.value)) \u{00b7} "
                        + percent(row.value, of: breakdown.total)
                )
                .font(
                    .system(
                        size: TextSize.caption.at(rem),
                        design: .rounded
                    )
                )
                .monospacedDigit()
                .foregroundStyle(theme.secondary.color)
                .fixedSize()
            }
            .accessibilityLabel(row.label)
            .accessibilityValue(
                "\(format(row.value)), "
                    + percent(row.value, of: breakdown.total)
            )
        }
        // The values are written beside the bars; an axis would say them
        // again, less exactly. Room on the right for the longest of them.
        .chartXAxis(.hidden)
        .chartXScale(domain: 0...max(largest * 1.6, 1))
        // The names beside their bars, set against the plot's edge.
        .chartYAxis {
            AxisMarks(preset: .aligned, position: .leading) { _ in
                AxisValueLabel()
                    .font(TextSize.caption.font(rem))
                    .foregroundStyle(theme.foreground.color)
            }
        }
        .chartLegend(.hidden)
        .frame(height: Self.rowHeight.at(rem) * CGFloat(rows.count))
    }

    /// What the mosaic hatches, added up: the one figure here in the
    /// highlight, as it is space that can be had back.
    private var reclaimable: some View {
        let some = breakdown.reclaimable > 0
        return HStack(spacing: Space.sm.at(rem)) {
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
            .frame(width: IconSize.md.at(rem), height: IconSize.md.at(rem))
            Text("Reclaimable")
                .font(TextSize.caption.font(rem, weight: .medium))
                .foregroundStyle(theme.foreground.color)
            Spacer(minLength: 0)
            Text(
                "\(format(breakdown.reclaimable)) \u{00b7} "
                    + percent(breakdown.reclaimable, of: breakdown.total)
            )
            .font(
                .system(
                    size: TextSize.caption.at(rem),
                    weight: .semibold,
                    design: .rounded
                )
            )
            .monospacedDigit()
            .foregroundStyle((some ? theme.highlight : theme.secondary).color)
        }
        .padding(.horizontal, Space.sm.at(rem))
        .padding(.vertical, Space.sm.at(rem))
        .background(
            (some ? theme.highlight.opacity(0.1) : theme.normalFill).color,
            in: RoundedRectangle(
                cornerRadius: Rounding.card.at(rem) - Space.xs.at(rem),
                style: .continuous
            )
        )
        .accessibilityElement(children: .combine)
    }

    private func format(_ value: UInt64) -> String {
        metric == .bytes ? humanBytes(value) : "\(humanCount(value)) files"
    }
}
