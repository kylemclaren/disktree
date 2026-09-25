// The path in the toolbar, from `/`, as Finder draws one: a symbol and a
// name for each folder, chevrons between them, and at each step in the tree
// a menu of the folders beside it.
//
// Above the scanned root a step widens the scan to there, and is set dimmer,
// being outside it. In the tree a step goes there; its menu lists its
// siblings, largest first with their share and size, to jump sideways
// without going up first. The menus are the system's, so the arrow keys,
// type-to-select and Escape work in them as in any Mac menu.
//
// A toolbar item is as wide as it asks to be, so the path folds itself: it
// keeps its first steps and the last ones, and puts the middle in a menu
// behind an ellipsis, as much as the window's width leaves it room for.
//
// Its sizes are points, the system's, not rem: a toolbar keeps its size
// whatever the interface zoom, as every Mac app's does.

import AppKit
import DisktreeCore
import SwiftUI
import System

/// Steps a trail shows before it folds its middle into an ellipsis: the
/// first two and the last four, which are where you came from and where
/// you are.
let trailSteps = 7

/// The steps a trail of `count` hides behind its ellipsis.
func hiddenTrailSteps(_ count: Int) -> Range<Int> {
    count > trailSteps ? 2..<count - (trailSteps - 3) : 0..<0
}

/// The folds a trail of `count` steps tries, in order, until one fits its
/// room: the usual one, then fewer of the last steps (the first two stay,
/// as long as anything else does), and last of all where you are alone.
/// A narrow window loses the middle of the path before it loses any name.
func trailFolds(_ count: Int) -> [Range<Int>] {
    var folds = [hiddenTrailSteps(count)]
    for kept in stride(from: trailSteps - 4, through: 1, by: -1)
    where count - kept > 2 {
        let fold = 2..<count - kept
        if fold.count > folds[folds.count - 1].count {
            folds.append(fold)
        }
    }
    if count > 1 {
        folds.append(0..<count - 1)
    }
    return folds
}

/// The trail, from `/`, folded to the room it has.
struct Trail: View {
    let state: AppState
    /// Points the path may take in the toolbar.
    let room: CGFloat

    var body: some View {
        let steps = state.breadcrumbs()
        let hidden = Self.fold(steps.map(\.label), room: room)
        // Only a widening scan in flight points at a step above the root.
        // The handle is not observed; the walk's progress is, and says when
        // it ends, whether it lands or fails. Read last, so the trail
        // follows the progress only while it widens.
        let widening =
            state.scanRoot != state.rootPath && state.scan != nil
            && !state.progress.finished
        HStack(spacing: Self.gap) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                if hidden.contains(index) {
                    if index == hidden.lowerBound {
                        if index > 0 {
                            Separator()
                        }
                        FoldedSteps(
                            state: state,
                            steps: Array(steps[hidden]),
                            first: hidden.lowerBound
                        )
                    }
                } else {
                    if index > 0 {
                        Separator()
                    }
                    StepView(
                        state: state,
                        index: index,
                        step: step,
                        current: index == steps.count - 1,
                        widening: widening
                    )
                }
            }
        }
        .font(.body)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Path")
        .chromeIdentifier("trail", container: true)
    }

    // MARK: Folding

    /// Between one step and the chevron after it.
    nonisolated static let gap: CGFloat = 2

    /// The steps hidden behind the ellipsis for `labels` in `room` points:
    /// the first fold whose path fits, or the last, which keeps only where
    /// you are.
    nonisolated static func fold(
        _ labels: [String],
        room: CGFloat
    ) -> Range<Int> {
        let folds = trailFolds(labels.count)
        return folds.first { width(labels, hiding: $0) <= room }
            ?? folds[folds.count - 1]
    }

    /// How wide the path is drawn with `hidden` behind its ellipsis: each
    /// step's name in the toolbar's font, its symbol and its padding, the
    /// chevrons between, and the ellipsis's button.
    nonisolated static func width(
        _ labels: [String],
        hiding hidden: Range<Int>
    ) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        var total: CGFloat = 0
        var shown = 0
        for (index, label) in labels.enumerated() where !hidden.contains(index)
        {
            shown += 1
            // The root is its symbol alone.
            total +=
                index == 0
                ? StepView.symbolOnly
                : StepView.chrome
                    + (label as NSString).size(withAttributes: [.font: font])
                    .width
        }
        let pieces = shown + (hidden.isEmpty ? 0 : 1)
        return total + (hidden.isEmpty ? 0 : FoldedSteps.width)
            + CGFloat(max(pieces - 1, 0)) * (Separator.width + gap * 2)
    }

}

/// The chevron between two steps.
private struct Separator: View {
    nonisolated static let width: CGFloat = 8

    var body: some View {
        Image(systemName: "chevron.forward")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: Self.width)
            .accessibilityHidden(true)
    }
}

/// One step of the path.
private struct StepView: View {
    let state: AppState
    let index: Int
    let step: TrailStep
    let current: Bool
    let widening: Bool
    @Environment(\.theme) private var theme

    /// A step's padding either side, inside its hover capsule.
    nonisolated static let padding: CGFloat = 6
    /// A step's symbol, its gap to the name, and its padding either side.
    nonisolated static let chrome: CGFloat = 34
    /// The root's step, which is its symbol alone.
    nonisolated static let symbolOnly: CGFloat = 28

    var body: some View {
        switch step.crumb {
        case .above(let path):
            let pending = widening && state.scanRoot == path
            Button {
                state.widen(to: path)
            } label: {
                label(path: path, pending: pending)
            }
            .buttonStyle(StepStyle())
            // A step quieter than the scanned path, being outside it.
            .foregroundStyle(pending ? theme.highlight.color : .secondary)
            .help("Scan from \(step.label) \u{00b7} what is below is reused")
            .accessibilityHint("Widens the scan to this folder")
            .chromeIdentifier("crumb-\(index)")
        case .tree(let crumbs):
            TreeStep(
                state: state,
                index: index,
                crumbs: crumbs,
                current: current,
                label: label(path: state.path(at: crumbs), pending: false)
            )
        }
    }

    /// The step's symbol and name: the disk for `/`, a house for the home
    /// directory, a folder for the rest, and a spinner in place of the
    /// symbol while the scan widens to it.
    private func label(path: FilePath?, pending: Bool) -> some View {
        let root = index == 0
        return HStack(spacing: 4) {
            if pending {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(
                    nsImage: StepSymbol.image(
                        StepSymbol.name(
                            path: path,
                            root: root,
                            home: state.home
                        ),
                        color: theme.accent.opacity(current ? 1 : 0.8)
                    )
                )
                .renderingMode(.original)
            }
            if !root {
                Text(step.label)
                    .fontWeight(current ? .semibold : .regular)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(root ? "The disk" : step.label)
    }
}

/// A step's symbol in the palette's accent, as Finder colours the folders
/// of its path. An image in its own colour rather than a tinted symbol: a
/// menu's label is drawn by AppKit, which draws a symbol in the label's ink
/// and would leave the steps with menus grey beside the ones without.
enum StepSymbol {
    /// The symbol a step is drawn with: the disk for `/`, a house for the
    /// home directory, a folder for the rest.
    static func name(path: FilePath?, root: Bool, home: FilePath?) -> String {
        if root {
            "internaldrive.fill"
        } else if let path, path == home {
            "house.fill"
        } else {
            "folder.fill"
        }
    }

    static func image(_ name: String, color: HSLA) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: NSFont.systemFontSize,
            weight: .regular
        )
        .applying(.init(paletteColors: [color.nsColor]))
        let symbol =
            NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage()
        symbol.isTemplate = false
        return symbol
    }
}

/// A step in the tree. Its name goes there, and a secondary click lists
/// the folders beside it; the step where you are lists them on a click, and
/// says so with a chevron, being there already. The scanned root has no
/// siblings in the tree to offer, and only goes.
private struct TreeStep<Name: View>: View {
    let state: AppState
    let index: Int
    let crumbs: [Int]
    let current: Bool
    let label: Name

    var body: some View {
        if let child = crumbs.last {
            let parent = Array(crumbs.dropLast())
            let name = state.node(at: crumbs)?.name ?? ""
            if current {
                Menu {
                    SiblingItems(state: state, parent: parent, current: child)
                } label: {
                    HStack(spacing: 3) {
                        label
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.button)
                .buttonStyle(StepStyle())
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Folders beside \(name), largest first")
                .accessibilityHint("Lists its siblings")
                .chromeIdentifier("crumb-\(index)-menu")
                .chromeIdentifier("crumb-\(index)")
            } else {
                Button {
                    state.goTo(crumbs)
                } label: {
                    label
                }
                .buttonStyle(StepStyle())
                .contextMenu {
                    SiblingItems(state: state, parent: parent, current: child)
                }
                .help("Go to \(name) \u{00b7} secondary click for its siblings")
                // VoiceOver's own Show Menu (VO-Shift-M) opens the context
                // menu; the hint says it is there.
                .accessibilityHint(
                    "Goes to this folder. Its menu lists the folders beside it"
                )
                .chromeIdentifier("crumb-\(index)")
            }
        } else {
            Button {
                state.goTo([])
            } label: {
                label
            }
            .buttonStyle(StepStyle())
            .help(current ? "The scanned folder" : "Back to the scanned folder")
            .chromeIdentifier("crumb-\(index)")
        }
    }
}

/// How a step of the path answers the pointer: a capsule that lights under
/// it and deepens while pressed, as a toolbar's own buttons do.
private struct StepStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StepBody(configuration: configuration)
    }

    private struct StepBody: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var reduced

        var body: some View {
            configuration.label
                .padding(.horizontal, StepView.padding)
                .padding(.vertical, 3)
                .background {
                    Capsule().fill(
                        Color.primary.opacity(
                            configuration.isPressed
                                ? 0.14 : hovering ? 0.07 : 0
                        )
                    )
                }
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(
                    reduced ? nil : .easeOut(duration: 0.12),
                    value: hovering
                )
        }
    }
}

/// The steps folded away behind the ellipsis, as a menu of their own.
private struct FoldedSteps: View {
    let state: AppState
    let steps: [TrailStep]
    /// The index of the first of them in the whole trail.
    let first: Int

    nonisolated static let width: CGFloat = 30

    var body: some View {
        Menu {
            ForEach(Array(steps.enumerated()), id: \.offset) { offset, step in
                Button(step.label, systemImage: "folder") {
                    switch step.crumb {
                    case .above(let path):
                        state.widen(to: path)
                    case .tree(let crumbs):
                        state.goTo(crumbs)
                    }
                }
                .id(first + offset)
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Folders on the way here")
        .accessibilityLabel("More of the path")
        .chromeIdentifier("crumb-folded")
    }
}

// MARK: - Siblings

/// The folders beside a step, largest first: each with a bar of its share
/// in its kind's colour, and its size and share beneath its name. The one
/// the step stands for is ticked.
struct SiblingItems: View {
    let state: AppState
    let parent: [Int]
    let current: Int
    @Environment(\.theme) private var theme

    var body: some View {
        let (rows, more) = state.siblings(parent)
        let largest = max(rows.first?.value ?? 1, 1)
        let total = max(
            state.node(at: parent)?.value(state.options.metric) ?? 1, 1)
        let metric = state.options.metric
        Section("In \(parentName), largest first") {
            ForEach(rows, id: \.index) { row in
                let value =
                    metric == .bytes
                    ? humanBytes(row.value) : "\(humanCount(row.value)) files"
                let detail =
                    "\(value) \u{00b7} \(percent(row.value, of: total))"
                let meter = Image(
                    nsImage: SiblingMeter.image(
                        fraction: Double(row.value) / Double(largest),
                        color: theme.categoryAccent(row.category),
                        track: theme.secondary.opacity(0.25)
                    )
                )
                if row.index == current {
                    Toggle(isOn: .constant(true)) {
                        SwiftUI.Label {
                            Text(row.name)
                            Text(detail)
                        } icon: {
                            meter
                        }
                    }
                } else {
                    Button {
                        state.chooseSibling(parent: parent, index: row.index)
                    } label: {
                        SwiftUI.Label {
                            Text(row.name)
                            Text(detail)
                        } icon: {
                            meter
                        }
                    }
                }
            }
        }
        if more > 0 {
            Text("+\(more) smaller")
        }
    }

    /// The folder they are all in, by its own name: a menu's header has no
    /// room for a path.
    private var parentName: String {
        if parent.isEmpty {
            let root = state.rootPath
            return root.lastComponent?.string ?? root.string
        }
        return state.node(at: parent)?.name ?? ""
    }
}

/// A sibling's share of the largest, as a small bar in its kind's colour:
/// the image a menu item carries, since a menu draws no views of its own.
enum SiblingMeter {
    /// Long enough to compare, short enough to sit where a symbol would.
    static let size = CGSize(width: 22, height: 6)

    static func image(fraction: Double, color: HSLA, track: HSLA) -> NSImage {
        let fill = color.nsColor
        let ground = track.nsColor
        let fraction = min(max(fraction, 0), 1)
        let image = NSImage(size: size, flipped: false) { rect in
            let radius = rect.height / 2
            ground.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
                .fill()
            // At least a dot, so the smallest still shows its colour.
            let width = max(rect.width * fraction, rect.height)
            fill.setFill()
            NSBezierPath(
                roundedRect: CGRect(
                    x: rect.minX,
                    y: rect.minY,
                    width: width,
                    height: rect.height
                ),
                xRadius: radius,
                yRadius: radius
            )
            .fill()
            return true
        }
        // In the kind's colour, not tinted as a symbol would be.
        image.isTemplate = false
        return image
    }
}
