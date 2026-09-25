// Small presentation pieces shared by the screens.
//
// Every piece reads the theme and the rem from the environment, so it follows
// the system appearance and the interface zoom without being told, and takes
// only the plain values it shows, so the screens stay readable.
//
// They speak the Mac's own language, in the palette's colours: continuous
// rounded corners from one scale (`Rounding`), capsule chips, SF Symbols
// beside the words they stand for, and figures in SF Pro Rounded, the face
// macOS sets its own gauges and counts in. Numbers that sit in a column or
// change while they are read (sizes, counts, percentages) ask for
// monospaced digits, so a column of sizes lines up and a live count does not
// jitter.
//
// Motion is short and says what changed: a figure rolls its digits to the
// new value, a bar grows to its new length. With Reduce Motion on, nothing
// moves; a figure cross-fades, a bar takes its new length at once.

import DisktreeCore
import SwiftUI

extension Rems {
    /// The system font at this type step.
    public func font(_ rem: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: at(rem), weight: weight)
    }

    /// SF Pro Rounded at this type step: the face for figures. Its round
    /// terminals read as a measurement rather than as prose, as the
    /// system's own gauges and badges do.
    public func rounded(
        _ rem: CGFloat,
        weight: Font.Weight = .regular
    ) -> Font {
        .system(size: at(rem), weight: weight, design: .rounded)
    }
}

/// Corner radii, in rem, so a card and what is in it round alike at every
/// interface zoom: the app's one scale of them, four steps from a key cap
/// to what floats over the window, and a legend swatch's, which samples
/// the tiles'. Nested shapes stay concentric: a row inside a card that is
/// `Space.xs` in from its edge takes `control`, the card's radius less that
/// inset.
public enum Rounding {
    /// A key cap in the help, a crumb's hover.
    public static let small = Rems(0.3125)
    /// A control or a row inside a card, a notice, a well of rows, an
    /// icon's tile.
    public static let control = Rems(0.5)
    /// A card, a floating surface, the mosaic's frame: 12 points at the
    /// default rem, as macOS 26 rounds the groups in an inspector or a
    /// settings pane.
    public static let card = Rems(0.75)
    /// What floats over the whole window — the help, the scanning card —
    /// and the drop target drawn around it: rounder, as a sheet is.
    public static let panel = Rems(1.125)
    /// A legend swatch: a sample of the tiles, whose corners are three
    /// points, so it reads as a chip of their colour.
    public static let swatch = Rems(0.1875)
}

/// The continuous rounded rectangle every surface here is cut to, `radius`
/// at `rem`.
public func roundedShape(
    _ radius: Rems,
    rem: CGFloat
) -> RoundedRectangle {
    RoundedRectangle(cornerRadius: radius.at(rem), style: .continuous)
}

// MARK: - Figures

/// A dim label above a number, for the scanning panel and the run summary.
/// Given a `color`, the value takes it instead of the neutral one: a status
/// colour for a count that means something (`stat_colored`).
public struct Stat: View {
    let label: String
    let value: String
    let color: HSLA?
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    public init(_ label: String, _ value: String, color: HSLA? = nil) {
        self.label = label
        self.value = value
        self.color = color
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs.at(rem)) {
            // The dim text at full strength: a caption that names the
            // figure is read, and under 85% it falls below 4.5:1.
            Text(label)
                .font(TextSize.caption.font(rem))
                .foregroundStyle(theme.secondary.color)
            Text(value)
                .font(TextSize.title.rounded(rem, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle((color ?? theme.bright).color)
                .rollingDigits(value)
        }
        // Read as one: "files, 3.9M", not a label and a number apart.
        .accessibilityElement(children: .combine)
    }
}

/// A small label over a region or a figure, with the symbol that stands for
/// it when there is one: "Selection" beside a scope, as macOS 26 heads the
/// groups of an inspector. Set as written, in title case; the capitals the
/// Omarchy look shouted in are gone.
public struct Eyebrow: View {
    let label: String
    let systemImage: String?
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    public init(_ label: String, systemImage: String? = nil) {
        self.label = label
        self.systemImage = systemImage
    }

    public var body: some View {
        // The dim text at full strength: an eyebrow names what is under
        // it, and at 70% it would be 3.5:1 on the panel.
        HStack(spacing: Space.xs.at(rem)) {
            if let systemImage {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.hierarchical)
                    .imageScale(.medium)
                    .accessibilityHidden(true)
            }
            Text(label)
                .lineLimit(1)
        }
        .font(TextSize.caption.font(rem, weight: .semibold))
        .foregroundStyle(theme.secondary.color)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// An eyebrow over a value, for the selection grid. The value stays on one
/// line; a long one is cut rather than pushing its neighbour aside.
public struct Figure: View {
    let label: String
    let value: String
    let color: HSLA
    @Environment(\.rem) private var rem

    public init(_ label: String, _ value: String, color: HSLA) {
        self.label = label
        self.value = value
        self.color = color
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs.at(rem)) {
            Eyebrow(label)
            Text(value)
                .font(TextSize.title.rounded(rem, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(color.color)
                .lineLimit(1)
                .rollingDigits(value)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A large number followed by its small unit, sharing one baseline:
/// `881` set large, `GiB` beside it, both in SF Pro Rounded.
///
/// GPUI's flex could not line up text of two sizes, so the Rust set both on
/// bottom-aligned boxes one line tall and lifted the unit by the difference
/// in their descents. SwiftUI aligns text baselines itself, and does it from
/// the font's real metrics.
public struct Measure: View {
    let number: String
    let numberSize: Rems
    let unit: String
    let unitSize: Rems
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    public init(
        _ number: String,
        size numberSize: Rems,
        unit: String,
        unitSize: Rems
    ) {
        self.number = number
        self.numberSize = numberSize
        self.unit = unit
        self.unitSize = unitSize
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs.at(rem)) {
            Text(number)
                .font(numberSize.rounded(rem, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(theme.bright.color)
                .lineLimit(1)
                .rollingDigits(number)
            Text(unit)
                .font(unitSize.rounded(rem, weight: .medium))
                .foregroundStyle(theme.secondary.color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Labels

/// A capsule chip, for counts and states: the word in its colour over a
/// tenth of that colour, which is the wash its contrast is measured on,
/// with the symbol that says the same at a glance when there is one.
public struct Chip: View {
    let label: String
    let color: HSLA
    let systemImage: String?
    @Environment(\.rem) private var rem

    public init(_ label: String, color: HSLA, systemImage: String? = nil) {
        self.label = label
        self.color = color
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(spacing: Space.xs.at(rem)) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            Text(label)
        }
        .font(TextSize.caption.font(rem, weight: .medium))
        .foregroundStyle(color.color)
        .padding(.horizontal, Space.sm.at(rem))
        .padding(.vertical, Space.xxs.at(rem))
        .background(color.opacity(0.1).color, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(color.opacity(0.3).color, lineWidth: hairline)
        }
    }
}

/// A key as the key bar and the overlay show it: a small rounded cap, sunk
/// into the ground like the mosaic, its glyph in SF Pro Rounded.
public struct Keycap: View {
    let keys: String
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    public init(_ keys: String) {
        self.keys = keys
    }

    public var body: some View {
        let shape = roundedShape(Rounding.small, rem: rem)
        Text(keys)
            .font(TextSize.caption.rounded(rem, weight: .medium))
            .foregroundStyle(theme.foreground.color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Space.xs.at(rem) + Space.xxs.at(rem))
            .padding(.vertical, Space.xxs.at(rem))
            .frame(minWidth: TextSize.caption.at(rem) * 1.6)
            .background(theme.inset.color, in: shape)
            .overlay {
                shape.strokeBorder(theme.border.color, lineWidth: hairline)
            }
    }
}

/// A `key label` hint pair for the key bar.
public struct Hint: View {
    let keys: String
    let label: String
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    public init(_ keys: String, _ label: String) {
        self.keys = keys
        self.label = label
    }

    public var body: some View {
        HStack(spacing: Space.xs.at(rem)) {
            Keycap(keys)
            Text(label)
                .font(TextSize.caption.font(rem))
                .foregroundStyle(theme.secondary.color)
                .lineLimit(1)
                .fixedSize()
        }
        // "space: mark", as the pair reads, rather than two strays.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(keys): \(label)")
    }
}

/// A section heading inside a panel, with its symbol when there is one.
public struct SectionHeading: View {
    let label: String
    let systemImage: String?
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    public init(_ label: String, systemImage: String? = nil) {
        self.label = label
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(spacing: Space.xs.at(rem)) {
            if let systemImage {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
            }
            Text(label)
        }
        .font(TextSize.caption.font(rem, weight: .semibold))
        .foregroundStyle(theme.secondary.opacity(0.85).color)
    }
}

/// A definition row: label on the left, value on the right. The label keeps
/// its width; a long value wraps under itself instead.
public struct DefinitionRow: View {
    let label: String
    let value: String
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm.at(rem)) {
            Text(label)
                .foregroundStyle(theme.secondary.color)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
            Text(value)
                .fontDesign(.rounded)
                .monospacedDigit()
                .foregroundStyle(theme.bright.color)
                .multilineTextAlignment(.trailing)
        }
        .font(TextSize.caption.font(rem))
    }
}

/// A clickable breadcrumb segment. The current one is set in bold and
/// needs no hover: it is where you are already. `color` overrides the text
/// colour, for a crumb above the scanned root.
///
/// The crumbs sit in the top bar, which runs up under the title bar; the
/// hover fill is laid out with the crumb and never stretched into the
/// title bar's band, however the window hosts it.
public struct CrumbButton: View {
    let label: String
    let active: Bool
    let color: HSLA?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    public init(
        _ label: String,
        active: Bool,
        color: HSLA? = nil,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.active = active
        self.color = color
        self.action = action
    }

    public var body: some View {
        let weight: Font.Weight = active ? .semibold : .regular
        Button(action: action) {
            Text(label)
                .font(TextSize.body.font(rem, weight: weight))
                .foregroundStyle(
                    (color ?? (active ? theme.bright : theme.secondary)).color
                )
                .lineLimit(1)
                .padding(.horizontal, Space.xs.at(rem))
                .padding(.vertical, Space.xxs.at(rem))
                .background(
                    hovering && !active ? theme.hoverFill.color : Color.clear,
                    in: roundedShape(Rounding.small, rem: rem)
                )
                .contentShape(roundedShape(Rounding.small, rem: rem))
        }
        .buttonStyle(.plain)
        // Keys go to the window's one dispatcher; a focus ring here would
        // suggest the crumb owns them.
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .animation(ChromeMotion.hover, value: hovering)
        // A crumb is a place to go, as a link is.
        .pointerStyle(.link)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

// MARK: - Bars

/// The part of a track from `from` to `to`, as fractions of its width.
/// Clamped to the track, so a rounding error never paints past its end.
/// `rounded`, its ends are round, as a capsule's are: a bar on its own. A
/// segment between two others keeps square ends, so the three meet flush.
public struct BarSegment: Shape {
    public var from: Double
    public var to: Double
    public var rounded: Bool

    public init(from: Double = 0, to: Double, rounded: Bool = false) {
        self.from = from
        self.to = to
        self.rounded = rounded
    }

    /// Both ends move, so a bar grows or shrinks to its new length rather
    /// than jumping there.
    public var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(from, to) }
        set {
            from = newValue.first
            to = newValue.second
        }
    }

    public func path(in rect: CGRect) -> Path {
        let start = min(max(from, 0), 1)
        let end = min(max(to, start), 1)
        let part = CGRect(
            x: rect.minX + rect.width * start,
            y: rect.minY,
            width: rect.width * (end - start),
            height: rect.height
        )
        guard rounded else {
            return Path(part)
        }
        // Never rounder than the part is long: a sliver stays a sliver
        // rather than swelling into a dot wider than its share.
        let radius = min(part.height, part.width) / 2
        return Path(
            roundedRect: part,
            cornerRadius: radius,
            style: .continuous
        )
    }
}

/// A thin capsule meter: `fraction` of a track, in `color`.
public struct Bar: View {
    let fraction: Double
    let color: HSLA
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    public init(_ fraction: Double, color: HSLA) {
        self.fraction = fraction
        self.color = color
    }

    public var body: some View {
        ZStack {
            Capsule().fill(theme.foreground.opacity(0.08).color)
            BarSegment(to: fraction, rounded: true).fill(color.color)
                .growing(fraction)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Size.meter.at(rem))
        // A bar always stands beside the figure it draws, which is what
        // an assistive app reads.
        .accessibilityHidden(true)
    }
}

/// A block-glyph share bar, which reads as a bar at any font size. Set in
/// the monospaced system font so every block is the same width.
public struct GlyphBar: View {
    let part: UInt64
    let total: UInt64
    let width: Int
    let color: HSLA
    @Environment(\.rem) private var rem

    public init(_ part: UInt64, of total: UInt64, width: Int, color: HSLA) {
        self.part = part
        self.total = total
        self.width = width
        self.color = color
    }

    public var body: some View {
        Text(shareBar(part, of: total, width: width))
            .font(.system(size: TextSize.caption.at(rem), design: .monospaced))
            .foregroundStyle(color.color)
            .lineLimit(1)
            .fixedSize()
            // Block glyphs would be read out one by one; the share is
            // written beside it.
            .accessibilityHidden(true)
    }
}

/// A labelled meter: `label · value` over a bar.
public struct MeterRow: View {
    let label: String
    let value: String
    let fraction: Double
    let color: HSLA
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    public init(
        _ label: String,
        _ value: String,
        fraction: Double,
        color: HSLA
    ) {
        self.label = label
        self.value = value
        self.fraction = fraction
        self.color = color
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.xs.at(rem)) {
            HStack(spacing: 0) {
                Text(label)
                Spacer(minLength: Space.sm.at(rem))
                Text(value)
                    .fontWeight(.medium)
                    .foregroundStyle(theme.bright.color)
            }
            .font(TextSize.caption.font(rem))
            .monospacedDigit()
            .foregroundStyle(theme.secondary.color)
            ZStack {
                Capsule().fill(theme.foreground.opacity(0.08).color)
                BarSegment(to: fraction, rounded: true).fill(color.color)
                    .growing(fraction)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Space.xs.at(rem))
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The volume meter: what is used, what is free, and what the marks will
/// free.
///
/// The projection is drawn as a separate segment so "this much comes back"
/// is visible rather than only stated. Only measured numbers are shown: the
/// projection is marked bytes against `statfs`, never a guess.
public struct SpaceMeter: View {
    let space: SpaceInfo
    let reclaiming: UInt64
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    public init(_ space: SpaceInfo, reclaiming: UInt64) {
        self.space = space
        self.reclaiming = reclaiming
    }

    public var body: some View {
        let total = Double(max(space.total, 1))
        let projected = space.afterRemoving(reclaiming)
        let usedNow = min(max(Double(space.used) / total, 0), 1)
        let usedAfter = min(max(Double(projected.used) / total, 0), usedNow)
        let label =
            reclaiming > 0
            ? "\(humanBytes(space.available)) free · "
                + "\(humanBytes(projected.available)) after removing "
                + humanBytes(reclaiming)
            : "\(humanBytes(space.available)) free of "
                + humanBytes(space.total)

        VStack(alignment: .leading, spacing: Space.xs.at(rem)) {
            Text(label)
                .font(TextSize.caption.font(rem))
                .monospacedDigit()
                .foregroundStyle(theme.secondary.color)
            ZStack {
                Rectangle().fill(theme.foreground.opacity(0.08).color)
                // Used space, as a bar from the left.
                BarSegment(to: usedNow)
                    .fill(theme.foreground.opacity(0.22).color)
                // What stays used after the removals: the bar shrinks to
                // here, so the gap is exactly what comes back. Deeper, not
                // `danger`, which is kept for removal and failure.
                BarSegment(to: usedAfter)
                    .fill(theme.foreground.opacity(0.22).color)
                // The reclaimed slice sits at the right edge of what is
                // currently used, in the highlight, as the explore panel's
                // meter draws what can be had back.
                BarSegment(from: usedAfter, to: usedNow)
                    .fill(theme.highlight.color)
            }
            .growing([usedAfter, usedNow])
            .frame(maxWidth: .infinity)
            .frame(height: Space.xs.at(rem))
            // One capsule: the segments meet flush inside it, and only the
            // track's own ends are round.
            .clipShape(Capsule())
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Swatches

/// A rounded square of colour, for a legend or an identity.
public struct Swatch: View {
    let color: HSLA
    @Environment(\.rem) private var rem

    public init(_ color: HSLA) {
        self.color = color
    }

    public var body: some View {
        roundedShape(Rounding.swatch, rem: rem)
            .fill(color.color)
            .frame(width: Size.swatch.at(rem), height: Size.swatch.at(rem))
    }
}

/// The hatch swatch that stands for reclaimable space in the legend: the
/// same stripes as on the tiles, set denser so they read at swatch size.
/// The stripes are device pixels, like the tiles', so the swatch grows with
/// the zoom but its stripes do not.
public struct HatchSwatch: View {
    let color: HSLA
    let ground: HSLA
    @Environment(\.rem) private var rem

    public init(_ color: HSLA, ground: HSLA) {
        self.color = color
        self.ground = ground
    }

    public var body: some View {
        Rectangle()
            .fill(ground.color)
            .overlay { HatchFill(.dense, color: color) }
            .frame(width: Size.swatch.at(rem), height: Size.swatch.at(rem))
            // Cut to the same corners as its neighbours in the legend; the
            // stripes are laid over the whole square first, so the cut
            // never shifts their phase.
            .clipShape(roundedShape(Rounding.swatch, rem: rem))
    }
}

// MARK: - Icons

/// The icons the screens use, as SF Symbols.
public enum IconName: Sendable, Hashable, CaseIterable {
    case check
    case file
    case folderOpen
    case keyboard
    /// Work in progress: drawn as a spinner, not a symbol.
    case loader
    case search
    case x

    /// The SF Symbol, or `nil` for the loader.
    public var systemName: String? {
        switch self {
        case .check: "checkmark"
        case .file: "doc"
        case .folderOpen: "folder"
        case .keyboard: "keyboard"
        case .loader: nil
        case .search: "magnifyingglass"
        case .x: "xmark"
        }
    }
}

/// The SF Symbols that stand for what the screens name: a kind of data, a
/// reason something can go, a finding. One table, so a kind wears the same
/// symbol in the inspector, a tooltip and the legend.
enum SymbolName {
    /// The symbol for data of `category`; for the unrecognised, a folder or
    /// a document, as Finder shows it.
    static func kind(
        _ category: DisktreeCore.Category,
        isDir: Bool = true
    ) -> String {
        switch category {
        case .code: "chevron.left.forwardslash.chevron.right"
        case .agentScratch: "sparkles"
        case .toolchain: "hammer"
        case .synced: "icloud"
        case .git: "arrow.triangle.branch"
        case .media: "photo.on.rectangle"
        case .documents: "doc.text"
        case .cache: "archivebox"
        case .other: isDir ? "folder" : "doc"
        }
    }

    /// Why space can be had back: what would write it again, or where it
    /// came from.
    static func reason(_ reclaim: Reclaim) -> String {
        switch reclaim {
        case .regenerable: "arrow.triangle.2.circlepath"
        case .syncHistory: "clock.arrow.circlepath"
        case .packageStore: "shippingbox"
        case .buildOutput: "hammer"
        case .reinstallable: "shippingbox.and.arrow.backward"
        case .sandboxLayers: "square.stack.3d.up"
        case .snapshots: "camera.on.rectangle"
        case .trash: "trash"
        case .temporary: "hourglass"
        }
    }

    /// A line of "worth a look".
    static func finding(_ finding: Finding) -> String {
        switch finding {
        case .reclaimable(let reclaim): reason(reclaim)
        case .worktrees: "arrow.triangle.branch"
        case .staleExperiments: "flask"
        }
    }
}

/// An icon in a slot `size` square, in `color` (or the inherited foreground
/// style).
public struct Icon: View {
    let name: IconName
    let size: Rems
    let color: HSLA?
    @Environment(\.rem) private var rem

    public init(
        _ name: IconName,
        size: Rems = IconSize.md,
        color: HSLA? = nil
    ) {
        self.name = name
        self.size = size
        self.color = color
    }

    public var body: some View {
        let side = size.at(rem)
        Group {
            if let symbol = name.systemName {
                if let color {
                    Image(systemName: symbol).foregroundStyle(color.color)
                } else {
                    Image(systemName: symbol)
                }
            } else {
                Spinner(fitting: side, color: color)
            }
        }
        .font(.system(size: side))
        .frame(width: side, height: side)
    }
}

/// The system spinner, the largest that fits a slot `side` points square:
/// a Mac user reads it as "working" without a label.
struct Spinner: View {
    let side: CGFloat
    let color: HSLA?

    init(fitting side: CGFloat, color: HSLA? = nil) {
        self.side = side
        self.color = color
    }

    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(Spinner.controlSize(fitting: side))
            .tint(color?.color)
    }

    /// The largest spinner that fits a slot `side` points square.
    ///
    /// macOS draws its spinner at three sizes only, 10, 16 and 32 points
    /// (large and extra large are the regular one again), whatever the frame
    /// around it, so a spinner too large for its slot spills over its
    /// neighbours: the regular one in the scanning panel's 22 point slot
    /// overlapped the text beside it. Scaling one to fit would blur it, so
    /// the slot takes the largest that fits and centres it, as it would any
    /// control. Only a slot under ten points (the smallest icon at the
    /// smallest zoom) fits none, and gets the mini one.
    static func controlSize(fitting side: CGFloat) -> ControlSize {
        if side >= 32 {
            .regular
        } else if side >= 16 {
            .small
        } else {
            .mini
        }
    }
}

// MARK: - Motion

/// How the chrome moves. A change of place is a spring that settles in
/// under a quarter of a second, quick enough never to hold up the next key;
/// with Reduce Motion, only a short fade is left.
enum ChromeMotion {
    /// A change of place or size: a segment's indicator, a panel sliding
    /// in, a screen pushed aside, a bar's new length.
    static let move = Animation.snappy(duration: 0.22)
    /// Something arriving or leaving: an overlay, a menu, a toast.
    static let arrive = Animation.smooth(duration: 0.2)
    /// All that Reduce Motion leaves: a cross-fade.
    static let fade = Animation.easeInOut(duration: 0.15)
    /// A row or a control answering the pointer: quick enough to follow a
    /// sweep across a list, and only a colour, so Reduce Motion keeps it.
    static let hover = Animation.easeOut(duration: 0.12)

    /// `animation`, or the fade when motion is `reduced`.
    static func animation(
        _ animation: Animation = move,
        reduced: Bool
    ) -> Animation {
        reduced ? fade : animation
    }

    /// `transition`, or a fade when motion is `reduced`.
    static func transition(
        _ transition: AnyTransition,
        reduced: Bool
    ) -> AnyTransition {
        reduced ? .opacity : transition
    }
}

// MARK: - Plain buttons that answer the pointer

/// The shape a `PressableFill` washes.
enum PressShape: Sendable, Hashable {
    /// A rounded rectangle at one of `Rounding`'s radii: a row, a chip.
    case rounded(Rems)
    case capsule
    /// A round icon button.
    case circle
}

/// A plain button that answers the pointer as a Mac list row or toolbar
/// icon does: a quiet fill under the pointer, a deeper one while pressed,
/// and nothing at rest — or `selected`'s wash, for the row that is the
/// selection. Only a colour changes, so Reduce Motion keeps it; the label
/// never grows, which is not how a Mac answers a hover.
struct PressableFill: ButtonStyle {
    let shape: PressShape
    let selected: HSLA?

    init(_ shape: PressShape, selected: HSLA? = nil) {
        self.shape = shape
        self.selected = selected
    }

    func makeBody(configuration: Configuration) -> some View {
        PressableFillBody(
            label: configuration.label,
            pressed: configuration.isPressed,
            shape: shape,
            selected: selected
        )
    }
}

private struct PressableFillBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    let shape: PressShape
    let selected: HSLA?
    @State private var hovering = false
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let outline = self.outline
        label
            .background(fill.color, in: outline)
            .contentShape(outline)
            .onHover { hovering = $0 }
            .animation(ChromeMotion.hover, value: hovering)
            .animation(ChromeMotion.hover, value: pressed)
    }

    /// Pressed, the hover fill nearly twice as deep: enough to see under a
    /// finger on a trackpad, still a wash rather than a bezel.
    private var fill: HSLA {
        let hover = theme.hoverFill
        if enabled && pressed {
            return hover.withAlpha(hover.a * 1.8)
        }
        if enabled && hovering {
            return hover
        }
        return selected ?? hover.withAlpha(0)
    }

    private var outline: AnyShape {
        switch shape {
        case .rounded(let radius): AnyShape(roundedShape(radius, rem: rem))
        case .capsule: AnyShape(Capsule())
        case .circle: AnyShape(Circle())
        }
    }
}

extension View {
    /// Roll the digits to `value` when it changes, counting up or down
    /// with it: a live count reads as counting rather than flickering.
    func rollingNumber(_ value: Double) -> some View {
        modifier(RollingNumber(value: value))
    }

    /// Roll the digits of a figure already written out, such as `3.9M` or
    /// `881 GiB`, when it changes.
    func rollingDigits(_ text: String) -> some View {
        modifier(RollingDigits(text: text))
    }

    /// Move a bar to its new length when `value` changes.
    func growing<Value: Equatable>(_ value: Value) -> some View {
        modifier(Growing(value: value))
    }
}

private struct RollingNumber: ViewModifier {
    let value: Double
    @Environment(\.accessibilityReduceMotion) private var reduced

    func body(content: Content) -> some View {
        content
            .contentTransition(
                reduced ? .opacity : .numericText(value: value)
            )
            .animation(ChromeMotion.animation(reduced: reduced), value: value)
    }
}

private struct RollingDigits: ViewModifier {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduced

    func body(content: Content) -> some View {
        content
            .contentTransition(reduced ? .opacity : .numericText())
            .animation(ChromeMotion.animation(reduced: reduced), value: text)
    }
}

private struct Growing<Value: Equatable>: ViewModifier {
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduced

    func body(content: Content) -> some View {
        // A length has no fade: with motion reduced, it is simply new.
        content.animation(reduced ? nil : ChromeMotion.move, value: value)
    }
}

// MARK: - Floating surfaces

extension EnvironmentValues {
    /// Whether what floats over the screen for a moment — the tooltip, the
    /// sibling menu, the help card, a toast — is Liquid Glass. The root
    /// decides: macOS 26, a window on screen, transparency not reduced.
    @Entry var floatingGlass = false
}

extension View {
    /// The surface of something that floats over the screen for a moment.
    ///
    /// On macOS 26 it is Liquid Glass, cut to `shape`, so what it covers
    /// still shows through. Elsewhere, and wherever glass cannot be seen,
    /// it is `fill` with a hairline `border` in the same shape: a theme
    /// surface, which is what the app's own grounds are. Glass is left to
    /// what floats; the mosaic and the bars are the app's ground and stay
    /// solid. `lifted` adds a shadow to the plain surface, for one that
    /// hangs over busy content; glass carries its own.
    func floatingSurface(
        _ fill: HSLA,
        border: HSLA,
        lifted: Bool = false,
        shape: FloatingShape = .card
    ) -> some View {
        modifier(
            FloatingSurface(
                fill: fill,
                border: border,
                lifted: lifted,
                shape: shape
            )
        )
    }

    /// A card on a pane: a group of related content, rounded and quietly
    /// raised on a hairline, as macOS 26 groups an inspector's sections.
    /// Its fill is the theme's raised surface, so on the window's ground it
    /// reads as a sheet of whiter paper on the cream, or a warmer blue on
    /// the navy; content inside is `padding` in from its edge.
    func cardSurface(padding: Rems = Space.md) -> some View {
        modifier(CardSurface(padding: padding))
    }
}

/// The outline a floating surface is cut to.
enum FloatingShape: Sendable, Hashable {
    /// A rounded rectangle at `Rounding.card`: a tooltip, a menu, a card.
    case card
    /// A capsule: a toast, a single line that comes and goes.
    case capsule
}

/// A `FloatingShape` at a radius in points, as a shape that can be inset,
/// so its hairline is stroked inside the edge rather than half past it.
struct FloatingOutline: InsettableShape {
    let kind: FloatingShape
    let radius: CGFloat
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let inner = rect.insetBy(dx: inset, dy: inset)
        return switch kind {
        case .card:
            RoundedRectangle(
                cornerRadius: max(radius - inset, 0),
                style: .continuous
            )
            .path(in: inner)
        case .capsule:
            // Circular ends: a continuous curve cannot turn a whole end
            // in half the height, and its stroke frays at the tips.
            Capsule(style: .circular).path(in: inner)
        }
    }

    func inset(by amount: CGFloat) -> FloatingOutline {
        var shape = self
        shape.inset += amount
        return shape
    }
}

private struct FloatingSurface: ViewModifier {
    let fill: HSLA
    let border: HSLA
    let lifted: Bool
    let shape: FloatingShape
    @Environment(\.floatingGlass) private var glass
    @Environment(\.rem) private var rem

    func body(content: Content) -> some View {
        let outline = FloatingOutline(
            kind: shape,
            radius: Rounding.card.at(rem)
        )
        if #available(macOS 26, *), glass {
            content.glassEffect(.regular, in: outline)
        } else {
            let plain =
                content
                .background(fill.color, in: outline)
                .overlay {
                    outline.strokeBorder(border.color, lineWidth: hairline)
                }
            if lifted {
                plain
                    .compositingGroup()
                    // The palette's own darkest ink rather than a neutral
                    // black, so the shadow on the cream is a navy one.
                    .shadow(
                        color: MP300.midnightBlue.opacity(0.25).color,
                        radius: Space.md.at(rem),
                        y: Space.xs.at(rem)
                    )
            } else {
                plain
            }
        }
    }
}

private struct CardSurface: ViewModifier {
    let padding: Rems
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    func body(content: Content) -> some View {
        let shape = roundedShape(Rounding.card, rem: rem)
        content
            .padding(padding.at(rem))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface.color, in: shape)
            .overlay {
                shape.strokeBorder(theme.divider.color, lineWidth: hairline)
            }
    }
}
