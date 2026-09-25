// The tooltip that follows the pointer over the mosaic.
//
// It is a layer of the explore screen rather than a child of the treemap, so
// it is never clipped at the edge of the mosaic, and it tracks the pointer
// the hover logic already maintains (`state.pointer`, in the treemap's own
// points), so it cannot lag behind the tile it describes. It never takes a
// hit: the pointer belongs to the tiles beneath it. It floats, so on macOS
// 26 it is a rounded pane of Liquid Glass and the mosaic under it still
// shows; elsewhere the same pane, solid.
//
// What it says is what the tile cannot: its kind, with the symbol and the
// colour the legend gives it, where it is, its size set in rounded figures
// with its share of the directory as a small bar, what it holds, and what
// the two keys that act on it do. It waits for the pointer to rest, and
// with the side panel out it is only a name and a size: the panel says the
// rest.
//
// Assistive apps are not given it: it says again what the treemap tells
// them of the tile under the pointer, and would be read on every move.

import DisktreeCore
import SwiftUI
import System

/// Where the treemap is drawn, for the tooltip to turn its pointer into a
/// place on the screen.
struct TreemapAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(
        value: inout Anchor<CGRect>?,
        nextValue: () -> Anchor<CGRect>?
    ) {
        value = value ?? nextValue()
    }
}

/// The hovered tile's card, beside the pointer, on whichever side has room:
/// the tile's, or, over a merged tail, what the tail stands for.
///
/// It waits until the pointer has rested on a tile (`AppState.cardHeld`),
/// then comes in, a little grown, and goes at once when the pointer moves
/// on to another. With the side panel out, the panel already says all the
/// card would about the tile under the pointer, so the card is only its
/// name and size, in a capsule; the whole card is for when the panel is
/// away.
struct CursorTooltip: View {
    let state: AppState
    /// The treemap's frame in this layer's space.
    let treemap: CGRect
    /// The side panel is out, saying the rest.
    let compact: Bool
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem
    @Environment(\.accessibilityReduceMotion) private var reduced

    var body: some View {
        let shown = state.pointer != nil && !state.cardHeld
        // Placement is in points because the pointer is; the card's own
        // size and gaps come from the rem scale so they follow zoom.
        let pointer = state.pointer ?? .zero
        FloatingPlacement(
            anchor: CGPoint(
                x: treemap.minX + pointer.x,
                y: treemap.minY + pointer.y
            ),
            fit: .flip(gap: Space.md.at(rem)),
            margin: Space.xs.at(rem)
        ) {
            if shown, let card {
                card
                    .foregroundStyle(theme.foreground.color)
                    .font(TextSize.caption.font(rem))
                    .accessibilityHidden(true)
                    .chromeIdentifier("cursor-tooltip", container: true)
                    .transition(
                        .asymmetric(
                            insertion: ChromeMotion.transition(
                                .opacity.combined(
                                    with: .scale(scale: 0.97, anchor: .top)
                                ),
                                reduced: reduced
                            ),
                            // Gone at once: the pointer has moved on.
                            removal: .identity
                        )
                    )
            }
        }
        .animation(ChromeMotion.arrive, value: shown)
    }

    /// The tile's card, the tail's, or nothing to say.
    private var card: AnyView? {
        if compact {
            if let tile = HoverChip(state: state) {
                return AnyView(tile)
            }
        } else if let tile = HoverTooltip(state: state) {
            return AnyView(plate(tile))
        }
        if let tail = state.hoveredTail {
            return AnyView(plate(TailTooltip(state: state, tail: tail)))
        }
        return nil
    }

    /// The whole card's pane: Liquid Glass tinted with the app's own
    /// surface, so its small text keeps its contrast over saturated tiles
    /// rather than taking on their colours.
    private func plate(_ content: some View) -> some View {
        content
            .padding(Space.md.at(rem))
            .frame(width: Size.tooltip.at(rem), alignment: .leading)
            .glassPlate(
                RoundedRectangle(
                    cornerRadius: Rounding.card.at(rem),
                    style: .continuous
                ),
                // Opaque where there is no glass to blur what lies
                // under it: a tile's label seen through the path
                // and the figures would read as a second line of
                // text, not as depth.
                fill: theme.surface,
                border: theme.border.opacity(0.7),
                tint: theme.surface,
                tintOpacity: 0.5
            )
    }
}

/// The hovered tile's name and size, in a capsule: what the card says when
/// the side panel says the rest.
struct HoverChip: View {
    let state: AppState
    let node: Node
    let marked: Bool
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    init?(state: AppState) {
        guard let crumbs = state.hovered,
            let node = state.node(at: crumbs)
        else {
            return nil
        }
        self.state = state
        self.node = node
        self.marked =
            state.path(at: crumbs).map { state.marks.contains($0) } ?? false
    }

    var body: some View {
        let accent = marked ? theme.danger : theme.categoryAccent(node.category)
        HStack(spacing: Space.xs.at(rem)) {
            Image(
                systemName: marked
                    ? HoverTooltip.symbol(dir: node.isDir, marked: true)
                    : HoverTooltip.kindSymbol(node)
            )
            .font(TextSize.caption.font(rem, weight: .semibold))
            .foregroundStyle(accent.color)
            Text(node.name)
                .font(TextSize.caption.font(rem, weight: .semibold))
                .foregroundStyle(theme.bright.color)
                .truncationMode(.middle)
            Text(humanBytes(node.value(.bytes)))
                .font(TextSize.caption.rounded(rem, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(theme.secondary.color)
                .fixedSize()
        }
        .lineLimit(1)
        .frame(maxWidth: Size.tooltip.at(rem), alignment: .leading)
        .fixedSize()
        .padding(.horizontal, Space.sm.at(rem) + Space.xxs.at(rem))
        .padding(.vertical, Space.xs.at(rem))
        .glassPlate(
            Capsule(style: .circular),
            fill: theme.surface,
            border: theme.border.opacity(0.7),
            tint: theme.surface,
            tintOpacity: 0.5
        )
    }
}

/// What a merged "+N" tail stands for: the small entries of a directory,
/// too small to draw one by one, how many and what they weigh together.
struct TailTooltip: View {
    let state: AppState
    let tail: HoveredTail
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    var body: some View {
        let holder = state.node(at: tail.crumbs)
        let whole = holder?.value(state.options.metric) ?? 0
        let noun = tail.count == 1 ? "entry" : "entries"
        VStack(alignment: .leading, spacing: Space.sm.at(rem)) {
            TooltipHeading(
                symbol: "square.grid.3x3.fill",
                color: theme.secondary,
                title: "\(humanCount(UInt64(tail.count))) smaller \(noun)",
                kind: state.path(at: tail.crumbs).map {
                    "in " + displayPath($0, home: state.home)
                } ?? ""
            )
            TooltipFigure(
                value: Self.value(tail.value, metric: state.options.metric),
                part: tail.value,
                whole: whole,
                color: theme.secondary
            )
            // Captions that say what to do: 4.5:1, so the dim text at full
            // strength, not at 70%.
            Label(
                "Too small to draw one by one; zoom in to see them",
                systemImage: "plus.magnifyingglass"
            )
            .font(TextSize.caption.font(rem))
            .foregroundStyle(theme.secondary.color)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A tail's weight in the metric on screen.
    nonisolated static func value(_ value: UInt64, metric: Metric) -> String {
        switch metric {
        case .bytes: humanBytes(value)
        case .files: "\(humanCount(value)) files"
        }
    }
}

/// The tooltip's content for the hovered tile: everything the tile cannot
/// show.
struct HoverTooltip: View {
    let state: AppState
    let node: Node
    let path: FilePath?
    let parentBytes: UInt64
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem
    @Environment(\.accessibilityReduceMotion) private var reduced

    /// The content for `state.hovered`, or `nil` when nothing is hovered or
    /// the tile is no longer in the tree.
    init?(state: AppState) {
        guard let crumbs = state.hovered,
            let node = state.node(at: crumbs)
        else {
            return nil
        }
        self.state = state
        self.node = node
        self.path = state.path(at: crumbs)
        self.parentBytes = state.node(at: Array(crumbs.dropLast()))?.bytes ?? 0
    }

    var body: some View {
        let marked = path.map { state.marks.contains($0) } ?? false
        let covered = Self.marksAncestor(state.marks, of: path)
        let hidden = node.name.hasPrefix(".")
        // A directory counts itself among its directories.
        let subdirectories = node.dirs - min(node.dirs, node.isDir ? 1 : 0)
        let accent = theme.categoryAccent(node.category)
        VStack(alignment: .leading, spacing: Space.sm.at(rem)) {
            TooltipHeading(
                symbol: marked
                    ? Self.symbol(dir: node.isDir, marked: true)
                    : Self.kindSymbol(node),
                color: marked ? theme.danger : accent,
                title: node.name,
                kind: Self.kind(node),
                bounce: reduced ? false : marked
            )
            Text(path.map { displayPath($0, home: state.home) } ?? "")
                .font(TextSize.caption.font(rem))
                .foregroundStyle(theme.secondary.color)
                .lineLimit(2)
                .truncationMode(.middle)
            TooltipFigure(
                value: humanBytes(node.bytes),
                part: node.bytes,
                whole: parentBytes,
                color: marked ? theme.danger : accent
            )
            Text(
                "\(Self.count(node.files, "file")) \u{00b7} "
                    + "\(Self.count(subdirectories, "folder")) "
                    + "\u{00b7} \(humanBytes(node.ownBytes)) direct"
            )
            .font(TextSize.caption.font(rem))
            .monospacedDigit()
            .foregroundStyle(theme.secondary.color)
            if hidden || marked || covered != nil {
                ChipFlow(spacing: Space.xs.at(rem)) {
                    if hidden {
                        TooltipChip(
                            "Hidden",
                            symbol: "eye.slash",
                            color: theme.secondary
                        )
                    }
                    if marked {
                        TooltipChip(
                            "Marked for removal",
                            symbol: "checkmark.circle.fill",
                            color: theme.danger
                        )
                    }
                    if let covered {
                        TooltipChip(
                            "Inside marked \(covered)",
                            symbol: "arrow.turn.down.right",
                            color: theme.secondary
                        )
                    }
                }
            }
            TooltipKeys(open: node.isDir)
        }
    }

    /// The SF Symbol for a hovered tile: a folder or a document, filled
    /// once it is marked.
    nonisolated static func symbol(dir: Bool, marked: Bool) -> String {
        switch (dir, marked) {
        case (true, false): "folder"
        case (true, true): "folder.fill"
        case (false, false): "doc"
        case (false, true): "doc.fill"
        }
    }

    /// A count and its noun, singular for one.
    nonisolated static func count(_ count: UInt64, _ noun: String) -> String {
        "\(humanCount(count)) \(noun)\(count == 1 ? "" : "s")"
    }

    /// The symbol for a tile's kind of data: what the legend's colour
    /// means, drawn. Unclassified space is a plain folder or document.
    nonisolated static func kindSymbol(_ node: Node) -> String {
        switch node.category {
        case .code: "chevron.left.forwardslash.chevron.right"
        case .agentScratch: "sparkles"
        case .toolchain: "hammer.fill"
        case .synced: "icloud.fill"
        case .git: "arrow.triangle.branch"
        case .media: "photo.on.rectangle.angled"
        case .documents: "doc.text.fill"
        case .cache: "arrow.triangle.2.circlepath"
        case .other: node.isDir ? "folder.fill" : "doc.fill"
        }
    }

    /// The kind of data, and why it could go if it could: the words under
    /// the name.
    nonisolated static func kind(_ node: Node) -> String {
        let kind =
            node.category == .other
            ? (node.isDir ? "Folder" : "File") : node.category.label
        guard let reclaim = node.reclaim else {
            return kind
        }
        return "\(kind) \u{00b7} \(reclaim.label)"
    }

    /// The last component of a path, for naming it in a sentence; the whole
    /// path when it has none (`/`).
    nonisolated static func shortName(_ path: FilePath) -> String {
        path.lastComponent?.string ?? path.string
    }

    /// The marked directory `path` is inside, by name, so the UI can explain
    /// nesting. Never `path` itself.
    nonisolated static func marksAncestor(
        _ marks: Marks,
        of path: FilePath?
    ) -> String? {
        guard let path else {
            return nil
        }
        return marks.items
            .first { $0.path != path && path.starts(with: $0.path) }
            .map { shortName($0.path) }
    }
}

// MARK: - The card's parts

/// The kind's symbol on a tile of its colour, the name beside it, and the
/// kind under the name: how Finder and System Settings head a thing.
private struct TooltipHeading: View {
    let symbol: String
    let color: HSLA
    let title: String
    let kind: String
    var bounce = false
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    var body: some View {
        let side = Space.xl.at(rem) + Space.xxs.at(rem)
        HStack(alignment: .center, spacing: Space.sm.at(rem)) {
            RoundedRectangle(
                cornerRadius: Rounding.control.at(rem),
                style: .continuous
            )
            .fill(color.opacity(theme.isDark ? 0.22 : 0.16).color)
            .overlay {
                Image(systemName: symbol)
                    .font(TextSize.body.font(rem, weight: .semibold))
                    .foregroundStyle(color.color)
                    // Filled once marked, and it jumps as the mark goes
                    // on or comes off, under the pointer where the eye is.
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: bounce)
            }
            .frame(width: side, height: side)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(TextSize.body.font(rem, weight: .semibold))
                    .foregroundStyle(theme.bright.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !kind.isEmpty {
                    Text(kind)
                        .font(TextSize.caption.font(rem))
                        .foregroundStyle(theme.secondary.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}

/// The size, set large in rounded figures, its share of the directory it
/// is in written beside it and drawn under it as a small bar.
private struct TooltipFigure: View {
    let value: String
    let part: UInt64
    let whole: UInt64
    let color: HSLA
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    var body: some View {
        let (number, unit) = splitSize(value)
        let fraction = whole == 0 ? 0 : min(share(part, of: whole) / 100, 1)
        VStack(alignment: .leading, spacing: Space.xs.at(rem)) {
            HStack(alignment: .firstTextBaseline, spacing: Space.xs.at(rem)) {
                Text(number)
                    .font(TextSize.heading.font(rem, weight: .bold))
                    .fontDesign(.rounded)
                    .monospacedDigit()
                    .foregroundStyle(theme.bright.color)
                Text(unit)
                    .font(TextSize.caption.font(rem, weight: .medium))
                    .fontDesign(.rounded)
                    .foregroundStyle(theme.secondary.color)
                Spacer(minLength: Space.sm.at(rem))
                Text("\(percent(part, of: whole)) of its folder")
                    .font(TextSize.caption.font(rem))
                    .monospacedDigit()
                    .foregroundStyle(theme.secondary.color)
            }
            .lineLimit(1)
            // A sliver of a share still shows as a dot of colour, so a
            // small tile's bar is never an empty track.
            GeometryReader { track in
                Capsule()
                    .fill(theme.foreground.opacity(0.1).color)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(color.color)
                            .frame(
                                width: max(
                                    track.size.width * fraction,
                                    track.size.height
                                )
                            )
                    }
            }
            .frame(height: Space.xs.at(rem) + Space.xxs.at(rem))
        }
    }
}

/// A state of the tile, as a small capsule with its symbol.
private struct TooltipChip: View {
    let label: String
    let symbol: String
    let color: HSLA
    @Environment(\.rem) private var rem

    init(_ label: String, symbol: String, color: HSLA) {
        self.label = label
        self.symbol = symbol
        self.color = color
    }

    var body: some View {
        Label(label, systemImage: symbol)
            .labelStyle(TightLabel(spacing: Space.xxs.at(rem) * 2))
            .font(TextSize.caption.font(rem, weight: .medium))
            .foregroundStyle(color.color)
            .lineLimit(1)
            .padding(.horizontal, Space.sm.at(rem))
            .padding(.vertical, Space.xxs.at(rem))
            .background(color.opacity(0.12).color, in: Capsule())
    }
}

/// The keys that act on the tile, said as the status bar says them: the
/// two a person reaches for with the pointer on it.
private struct TooltipKeys: View {
    let open: Bool
    @Environment(\.rem) private var rem

    var body: some View {
        HStack(spacing: 0) {
            KeyHint(keys: "space", label: "to mark")
            if open {
                KeyHint(keys: "enter", label: "to open", leading: true)
            }
        }
        .font(TextSize.caption.font(rem))
        .padding(.top, Space.xxs.at(rem))
    }
}

/// A symbol and its title closer together than the system sets them, for
/// a chip that has little room.
private struct TightLabel: LabelStyle {
    var spacing: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: spacing) {
            configuration.icon
            configuration.title
        }
    }
}

// MARK: - Placement

/// Sets its one view at its own size beside a point, kept inside the
/// layer: what GPUI's `anchored()` did for the sibling menu, and the Rust
/// tooltip's own arithmetic for the card.
struct FloatingPlacement: Layout {
    enum Fit {
        /// Below and to the right of the point, `gap` away, flipping to the
        /// other side of it rather than overflow: the tooltip.
        case flip(gap: CGFloat)
        /// Hanging from the point, pushed back inside when it would
        /// overflow: the sibling menu.
        case snap
    }

    var anchor: CGPoint
    var fit: Fit
    /// The closest the view comes to the layer's edge.
    var margin: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let origin = Self.origin(
                of: size,
                at: anchor,
                fit: fit,
                margin: margin,
                in: bounds.size
            )
            subview.place(
                at: CGPoint(
                    x: bounds.minX + origin.x,
                    y: bounds.minY + origin.y
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
        }
    }

    /// Where a view of `size` goes for `anchor` in a layer of `room`.
    static func origin(
        of size: CGSize,
        at anchor: CGPoint,
        fit: Fit,
        margin: CGFloat,
        in room: CGSize
    ) -> CGPoint {
        switch fit {
        case .flip(let gap):
            // Flip to the other side of the pointer rather than overflow
            // the window.
            let along = { (point: CGFloat, length: CGFloat, limit: CGFloat) in
                point + gap + length > limit
                    ? max(point - gap - length, margin) : point + gap
            }
            return CGPoint(
                x: along(anchor.x, size.width, room.width),
                y: along(anchor.y, size.height, room.height)
            )
        case .snap:
            let along = { (point: CGFloat, length: CGFloat, limit: CGFloat) in
                max(min(point, limit - margin - length), margin)
            }
            return CGPoint(
                x: along(anchor.x, size.width, room.width),
                y: along(anchor.y, size.height, room.height)
            )
        }
    }
}

/// Chips in a row that wraps onto the next line when it runs out of width.
struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let frames = Self.frames(
            subviews.map { $0.sizeThatFits(.unspecified) },
            width: proposal.width ?? .infinity,
            spacing: spacing
        )
        return CGSize(
            width: frames.map(\.maxX).max() ?? 0,
            height: frames.map(\.maxY).max() ?? 0
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let frames = Self.frames(
            subviews.map { $0.sizeThatFits(.unspecified) },
            width: bounds.width,
            spacing: spacing
        )
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(
                    x: bounds.minX + frame.minX,
                    y: bounds.minY + frame.minY
                ),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    /// Each chip's frame, row by row. A chip wider than the row gets a row
    /// of its own, cut to the row's width.
    static func frames(
        _ sizes: [CGSize],
        width: CGFloat,
        spacing: CGFloat
    ) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var line: CGFloat = 0
        for size in sizes {
            if x > 0 && x + size.width > width {
                x = 0
                y += line + spacing
                line = 0
            }
            let fitted = CGSize(
                width: min(size.width, width),
                height: size.height
            )
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: fitted))
            x += fitted.width + spacing
            line = max(line, size.height)
        }
        return frames
    }
}
