// What the mosaic's place shows while the first walk runs.
//
// The palette's gradient fills the place the mosaic will take, and a card of
// glass floats over it: a stack of layers lighting up in turn while the walk
// goes down through the folders, the folder being read, what has been
// counted so far rolling up as it grows, and the system's own progress bar:
// how far along when the whole volume is walked, and otherwise the bar that
// only says the walk goes on, since a folder's total is what is sought.
// The gradient carries no text of its own; everything to read is on the
// card. When the walk fails, the stack gives way to a warning and the
// reason is said in its own tinted well.

import DisktreeCore
import SwiftUI
import System

/// The widest the card grows: room for the four counts side by side. A
/// narrower mosaic, at a large interface zoom, narrows it.
private let cardWidth = Rems(30)

/// What the walk is doing: how many files and directories it has read, how
/// much it has measured, what it could not read, and a bar that keeps
/// moving while it does. The scan's error, if it failed, underneath.
struct ScanningPanel: View {
    let state: AppState
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem
    @Environment(\.accessibilityReduceMotion) private var reduced

    var body: some View {
        let progress = state.progress
        let walking = state.scan != nil && !progress.finished
        let failed = state.scanError != nil
        VStack(spacing: Space.lg.at(rem)) {
            emblem(walking: walking, failed: failed)
            VStack(spacing: Space.xs.at(rem)) {
                Text(failed ? "The scan stopped" : "Measuring")
                    .font(TextSize.heading.font(rem, weight: .bold))
                    .fontDesign(.rounded)
                    .foregroundStyle(theme.bright.color)
                Label {
                    Text(displayPath(state.rootPath, home: state.home))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(theme.accent.color)
                }
                .font(TextSize.body.font(rem, weight: .medium))
                .foregroundStyle(theme.foreground.color)
                .padding(.horizontal, Space.md.at(rem))
                .padding(.vertical, Space.xs.at(rem))
                .background(
                    theme.foreground.opacity(0.06).color,
                    in: Capsule()
                )
            }
            HStack(alignment: .top, spacing: Space.sm.at(rem)) {
                ScanCount(
                    "Files",
                    symbol: "doc",
                    value: humanCount(progress.files),
                    number: Double(progress.files)
                )
                ScanCount(
                    "Folders",
                    symbol: "folder",
                    value: humanCount(progress.dirs),
                    number: Double(progress.dirs)
                )
                ScanCount(
                    "Measured",
                    symbol: "internaldrive",
                    value: humanBytes(progress.bytes),
                    number: Double(progress.bytes)
                )
                ScanCount(
                    "Unreadable",
                    symbol: "lock",
                    value: humanCount(progress.errors),
                    number: Double(progress.errors),
                    color: progress.errors > 0 ? theme.caution : nil
                )
            }
            .fixedSize(horizontal: false, vertical: true)
            // A failed walk has nothing left to wait for: the bar and the
            // promise under it give way to the reason.
            if !failed {
                meter(bytes: progress.bytes)
                    .tint(theme.accent.color)
                Text(
                    "Marking, zooming and the free-space meter all work as "
                        + "soon as it lands."
                )
                .font(TextSize.caption.font(rem))
                .foregroundStyle(theme.secondary.color)
                .multilineTextAlignment(.center)
            }
            if let error = state.scanError {
                Label(error, systemImage: "exclamationmark.octagon.fill")
                    .font(TextSize.body.font(rem))
                    .foregroundStyle(theme.danger.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Space.md.at(rem))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        theme.danger.opacity(0.1).color,
                        in: RoundedRectangle(
                            cornerRadius: Rounding.control.at(rem),
                            style: .continuous
                        )
                    )
                    .transition(.opacity)
            }
        }
        .padding(Space.xl.at(rem))
        .frame(maxWidth: cardWidth.at(rem))
        .glassPlate(
            RoundedRectangle(
                cornerRadius: Rounding.panel.at(rem),
                style: .continuous
            ),
            // A little of the gradient shows through even where there is
            // no glass: the card sits in the light rather than on it.
            fill: theme.surface.opacity(0.9),
            border: theme.border.opacity(0.6)
        )
        .padding(Space.xl.at(rem))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            BackdropView()
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: Rounding.card.at(rem),
                        style: .continuous
                    )
                )
        }
        .animation(ChromeMotion.fade, value: failed)
        .chromeIdentifier("scanning-panel", container: true)
    }

    /// The stack of layers the walk goes down through, lit layer by layer
    /// while it runs and at rest once it ends; a warning when it failed.
    private func emblem(walking: Bool, failed: Bool) -> some View {
        let side = Rems(4.5).at(rem)
        let tint = failed ? theme.danger : theme.accent
        return ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            tint.opacity(theme.isDark ? 0.34 : 0.2).color,
                            tint.opacity(theme.isDark ? 0.14 : 0.06).color,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay {
                    Circle().strokeBorder(
                        tint.opacity(0.3).color,
                        lineWidth: hairline
                    )
                }
            Image(
                systemName: failed
                    ? "exclamationmark.triangle.fill"
                    : "square.stack.3d.up.fill"
            )
            .font(.system(size: side * 0.46, weight: .medium))
            .foregroundStyle(tint.color)
            .symbolEffect(
                .variableColor.iterative.reversing,
                options: .repeat(.continuous),
                isActive: walking && !reduced
            )
            .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: side, height: side)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(failed ? "Scan failed" : "Scanning")
    }

    /// The system's bar: how far along, where that can be known, and
    /// otherwise the bar that only says the walk goes on, as a Mac shows
    /// work whose end it cannot see.
    @ViewBuilder
    private func meter(bytes: UInt64) -> some View {
        if let fraction = Self.fraction(
            bytes: bytes,
            root: state.rootPath,
            volume: state.diskRoot,
            space: state.space
        ) {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .animation(reduced ? nil : ChromeMotion.move, value: fraction)
                .accessibilityLabel("Measured so far")
                .accessibilityValue(percent(bytes, of: state.space?.used ?? 0))
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .accessibilityLabel("Measuring")
        }
    }

    /// How far a walk of `root` has got, from the `bytes` it has measured:
    /// only when `root` is the whole `volume`, whose space in use is the
    /// total it is counting toward. Any other folder's total is what the
    /// walk is there to find, and a bar that claimed to know it would be
    /// made up. Short of full until the walk lands, since what the volume
    /// holds outside what can be read is never counted.
    nonisolated static func fraction(
        bytes: UInt64,
        root: FilePath,
        volume: FilePath?,
        space: SpaceInfo?
    ) -> Double? {
        guard let volume, root == volume, let space, space.used > 0 else {
            return nil
        }
        return min(Double(bytes) / Double(space.used), 0.99)
    }
}

/// One count of the walk: its symbol and name over the figure, which rolls
/// to each new value as the walk goes.
private struct ScanCount: View {
    let label: String
    let symbol: String
    let value: String
    let number: Double
    let color: HSLA?
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem
    @Environment(\.accessibilityReduceMotion) private var reduced

    init(
        _ label: String,
        symbol: String,
        value: String,
        number: Double,
        color: HSLA? = nil
    ) {
        self.label = label
        self.symbol = symbol
        self.value = value
        self.number = number
        self.color = color
    }

    var body: some View {
        VStack(spacing: Space.xs.at(rem)) {
            // Every symbol in one slot, so a tall one does not lower its
            // figure below its neighbours'.
            Label {
                Text(label)
            } icon: {
                Image(systemName: symbol)
                    .frame(height: TextSize.caption.at(rem))
            }
            .labelStyle(.titleAndIcon)
            .font(TextSize.caption.font(rem))
            .foregroundStyle(theme.secondary.color)
            .lineLimit(1)
            Text(value)
                .font(TextSize.title.font(rem, weight: .semibold))
                .fontDesign(.rounded)
                .monospacedDigit()
                .foregroundStyle((color ?? theme.bright).color)
                .lineLimit(1)
                .contentTransition(
                    reduced ? .opacity : .numericText(value: number)
                )
                .animation(
                    ChromeMotion.animation(reduced: reduced),
                    value: number
                )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.sm.at(rem))
        .background(
            theme.foreground.opacity(theme.isDark ? 0.06 : 0.04).color,
            in: RoundedRectangle(
                cornerRadius: Rounding.control.at(rem),
                style: .continuous
            )
        )
        // Read as one: "files, 3.9M", not a label and a number apart.
        .accessibilityElement(children: .combine)
    }
}
