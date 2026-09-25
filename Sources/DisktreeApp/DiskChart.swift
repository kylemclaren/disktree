// The disk as one bar: what stays used, what the marks would free, and what
// is free now. The same numbers are written out beside it.
//
// A bar says at a glance what three numbers take a moment to: how the marks
// compare with what is free already. It never says more than can be known
// (Invariant 9). What is free now is `statfs`'s, measured. What the marks
// free and what stays used after them are the marked bytes still on disk
// held against that, a projection. Every figure beside the bar says which it
// is. What the marks have freed so far is not drawn here: once a mark is
// gone its space is part of the free space `statfs` reads, and the review's
// "Freed so far" says, measured, how much of that came back.
//
// The colours are the side panel's meter's, so the two read as one
// instrument: used space in the foreground's grey, the slice that comes back
// hatched in the highlight, free space the empty track. The bar is a
// capsule, as a Mac's storage bar is, and the figures beside it are set in
// rounded digits.

import Charts
import DisktreeCore
import SwiftUI

/// One stacked bar across the disk, with its legend.
struct DiskChart: View {
    /// The disk now, from `statfs`.
    let space: SpaceInfo
    /// What the marks still on disk weigh: what the command would free.
    let pending: UInt64
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A stretch of the bar.
    struct Segment: Identifiable, Sendable, Hashable {
        enum Kind: Sendable, Hashable, CaseIterable {
            /// Used, and still used once the marks are gone.
            case used
            /// Used by the marks: what the command gives back.
            case freeing
            /// Free now.
            case free
        }

        var kind: Kind
        /// Where it starts and ends, in bytes from the left.
        var start: Double
        var end: Double

        var id: Kind { kind }
    }

    /// One line of the legend.
    struct Line: Identifiable, Sendable, Hashable {
        /// The segment it names, or `nil` for the projected free space,
        /// which is a sum and has no stretch of its own.
        var kind: Segment.Kind?
        var label: String
        var bytes: UInt64
        /// `measured` or `projected`: what kind of number it is.
        var note: String

        var id: String { label }
    }

    /// The bar, left to right: what stays used, what the marks free, what
    /// is free now. The three add up to the disk; each keeps its place when
    /// it is empty, so a change moves an edge rather than swapping marks.
    nonisolated static func segments(
        space: SpaceInfo,
        pending: UInt64
    ) -> [Segment] {
        let after = space.afterRemoving(pending)
        // `after.used` is never above `used`: removing only frees.
        let used = Double(space.used)
        let usedAfter = min(Double(after.used), used)
        return [
            Segment(kind: .used, start: 0, end: usedAfter),
            Segment(kind: .freeing, start: usedAfter, end: used),
            Segment(kind: .free, start: used, end: Double(space.total)),
        ]
    }

    /// The numbers beside the bar, each saying whether it was measured or
    /// is a projection. With nothing pending there is nothing to project,
    /// and every number is `statfs`'s.
    nonisolated static func lines(
        space: SpaceInfo,
        pending: UInt64
    ) -> [Line] {
        guard pending > 0 else {
            return [
                Line(
                    kind: .used,
                    label: "Used",
                    bytes: space.used,
                    note: "measured"
                ),
                Line(
                    kind: .free,
                    label: "Free now",
                    bytes: space.available,
                    note: "measured"
                ),
            ]
        }
        let after = space.afterRemoving(pending)
        return [
            Line(
                kind: .used,
                label: "Used after",
                bytes: after.used,
                note: "projected"
            ),
            Line(
                kind: .freeing,
                label: "The marks free",
                bytes: pending,
                note: "projected"
            ),
            Line(
                kind: .free,
                label: "Free now",
                bytes: space.available,
                note: "measured"
            ),
            Line(
                kind: nil,
                label: "Free after",
                bytes: after.available,
                note: "projected"
            ),
        ]
    }

    var body: some View {
        let segments = Self.segments(space: space, pending: pending)
        let lines = Self.lines(space: space, pending: pending)
        VStack(alignment: .leading, spacing: Space.md.at(rem)) {
            bar(segments)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Disk")
                .accessibilityValue(
                    lines.map {
                        "\($0.label) \(humanBytes($0.bytes)), \($0.note)"
                    }
                    .joined(separator: "; ")
                )
            VStack(alignment: .leading, spacing: Space.xs.at(rem)) {
                ForEach(lines) { line in
                    legend(line)
                }
            }
        }
    }

    // MARK: The bar

    private func bar(_ segments: [Segment]) -> some View {
        let total = max(Double(space.total), 1)
        return Chart(segments) { segment in
            BarMark(
                xStart: .value("From", segment.start),
                xEnd: .value("To", segment.end),
                y: .value("Disk", "disk"),
                height: .ratio(1)
            )
            .foregroundStyle(fill(segment.kind).color)
        }
        .chartXScale(domain: 0...total)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        // The slice that comes back is hatched, as it is in the panel's
        // meter and on a reclaimable tile: Charts fills a mark with one
        // style, so the hatch is laid over where the chart put it.
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let plot = proxy.plotFrame,
                    let freeing = segments.first(where: {
                        $0.kind == .freeing
                    }),
                    let from = proxy.position(forX: freeing.start),
                    let to = proxy.position(forX: freeing.end)
                {
                    let frame = geometry[plot]
                    HatchFill(.dense, color: theme.highlight)
                        .frame(width: max(to - from, 0), height: frame.height)
                        .offset(x: frame.minX + from, y: frame.minY)
                }
            }
            .allowsHitTesting(false)
        }
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .strokeBorder(
                    theme.foreground.opacity(0.12).color,
                    lineWidth: hairline
                )
        }
        .frame(height: Space.lg.at(rem))
        .animation(ReviewMotion.bars(reduceMotion), value: segments)
    }

    private func fill(_ kind: Segment.Kind) -> HSLA {
        switch kind {
        case .used: theme.foreground.opacity(0.28)
        case .freeing: theme.highlight.opacity(0.25)
        case .free: theme.foreground.opacity(0.06)
        }
    }

    // MARK: The legend

    /// A swatch, what it is, the number set right, and whether it was
    /// measured: the notes share a lane, so the numbers line up.
    private func legend(_ line: Line) -> some View {
        // Free after is the number the marks are for: the highlight, as the
        // panel sets it.
        let after = line.kind == nil
        let figure = after ? theme.highlight : theme.bright
        // One size of text throughout, so centring the line centres the
        // swatch on it too.
        return HStack(alignment: .center, spacing: Space.sm.at(rem)) {
            swatch(line.kind)
            Text(line.label)
                .foregroundStyle(
                    (after ? theme.foreground : theme.secondary).color
                )
                .fontWeight(after ? .semibold : .regular)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: Space.sm.at(rem))
            Text(humanBytes(line.bytes))
                .fontDesign(.rounded)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(figure.color)
                .lineLimit(1)
                .reviewRolling(Double(line.bytes), reduceMotion: reduceMotion)
            // A step under the label beside it, but read: 85% keeps 4.5:1.
            Text(line.note)
                .foregroundStyle(theme.secondary.opacity(0.85).color)
                .lineLimit(1)
                .frame(width: Rems(4.25).at(rem), alignment: .leading)
        }
        .font(TextSize.caption.font(rem))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func swatch(_ kind: Segment.Kind?) -> some View {
        let side = Size.swatch.at(rem)
        switch kind {
        case .freeing:
            Circle()
                .fill(fill(.freeing).color)
                .overlay { HatchFill(.dense, color: theme.highlight) }
                .clipShape(Circle())
                .overlay {
                    Circle().strokeBorder(
                        theme.highlight.opacity(0.6).color,
                        lineWidth: hairline
                    )
                }
                .frame(width: side, height: side)
        case .free:
            Circle()
                .fill(fill(.free).color)
                .overlay {
                    Circle()
                        .strokeBorder(
                            theme.foreground.opacity(0.25).color,
                            lineWidth: hairline
                        )
                }
                .frame(width: side, height: side)
        case .used:
            Circle()
                .fill(fill(.used).color)
                .frame(width: side, height: side)
        case nil:
            // A sum has no stretch of the bar: its row keeps the swatch's
            // room, and says what it is the sum of with an arrow.
            Image(systemName: "arrow.right")
                .font(.system(size: side, weight: .bold))
                .foregroundStyle(theme.highlight.color)
                .frame(width: side, height: side)
        }
    }
}
