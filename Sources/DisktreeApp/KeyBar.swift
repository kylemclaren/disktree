// The status bar along the foot of the mosaic's column.
//
// Quiet, as a Finder window's status bar is: a hairline over one line of
// small text. At the leading edge, what the directory drawn holds and how
// long the scan took — the numbers a title's subtitle would carry, here
// where the eye goes after the mosaic — or the walk in flight, with a
// spinner. At the trailing edge, how far the view is magnified while it
// is, one quiet line of the keys a first look needs, and the system's help
// button, which opens every key and gesture.
//
// No key caps: every key is in the help, in the menus, and in the tooltip of
// the control that does the same. As the window narrows the hint gives way
// first, then the scan's time; what the directory holds and the help stay.

import DisktreeCore
import SwiftUI

/// The status bar under the mosaic.
struct KeyBar: View {
    let state: AppState
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem
    @Environment(\.accessibilityReduceMotion) private var reduced

    /// The keys the quiet hint names, most useful first, so a narrow window
    /// drops the least useful. `c` opens the review, where the marks are
    /// handed over; nothing here deletes. Every other key is behind the
    /// help button.
    nonisolated static let hints: [(keys: String, label: String)] = [
        ("space", "mark"),
        ("enter", "open"),
        ("c", "review"),
    ]

    var body: some View {
        let magnified = abs(state.view.scale - 1) > 0.01
        HStack(spacing: Space.md.at(rem)) {
            if state.progress.errors > 0 {
                UnreadableNote(state: state)
            }
            scanSummary
                .layoutPriority(1)
            Spacer(minLength: 0)
            // The magnified view says how far it is magnified, and only
            // while it is. It follows the fingers as they pinch, so it
            // changes at once rather than rolling behind them.
            if magnified {
                Label {
                    Text(String(format: "%.1f\u{00d7}", state.view.scale))
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .labelStyle(.titleAndIcon)
                .foregroundStyle(theme.secondary.color)
                .fixedSize()
                .transition(
                    ChromeMotion.transition(
                        .opacity.combined(with: .scale(scale: 0.9)),
                        reduced: reduced
                    )
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    String(
                        format: "Magnified %.1f times",
                        state.view.scale
                    )
                )
            }
            FittingPrefix(count: Self.hints.count, spacing: 0) { index in
                KeyHint(
                    keys: Self.hints[index].keys,
                    label: "to \(Self.hints[index].label)",
                    leading: index > 0
                )
            }
            .layoutPriority(-1)
            AllKeys(state: state)
        }
        .font(TextSize.caption.font(rem))
        .lineLimit(1)
        .padding(.horizontal, Space.lg.at(rem))
        .padding(.vertical, Space.xs.at(rem) + Space.xxs.at(rem))
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.divider.color)
                .frame(height: hairline)
                .accessibilityHidden(true)
        }
        .animation(
            ChromeMotion.animation(ChromeMotion.arrive, reduced: reduced),
            value: magnified
        )
        .chromeIdentifier("key-bar", container: true)
    }

    /// What the directory drawn holds and how long the scan took, or the
    /// walk in flight with a spinner. The counts roll as they climb; the
    /// scan's time gives way before what the directory holds does.
    private var scanSummary: some View {
        let walking = Self.isWalking(state)
        let (holds, scan) = Self.status(state)
        return HStack(spacing: Space.xs.at(rem)) {
            if walking {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
            }
            ViewThatFits(in: .horizontal) {
                Text(scan.isEmpty ? holds : "\(holds) \u{00b7} \(scan)")
                Text(holds)
            }
            .monospacedDigit()
            // Read while the walk runs: the dim text at full strength,
            // since at 70% a caption falls under 4.5:1.
            .foregroundStyle(theme.secondary.color)
            .rollingNumber(Double(state.progress.files))
        }
        .accessibilityElement(children: .combine)
        .chromeIdentifier("scan-summary")
    }

    /// Whether a walk is out. The handle is not observed; the progress it
    /// publishes is, and is marked finished when the walk ends.
    static func isWalking(_ state: AppState) -> Bool {
        state.scan != nil && !state.progress.finished
    }

    /// The bar's two parts: what the directory drawn holds — the window's
    /// subtitle, but for the folders the scan could not read, which the
    /// note before it counts — and the scan that drew it, or how far the
    /// walk in flight has got.
    static func status(_ state: AppState) -> (holds: String, scan: String) {
        let progress = state.progress
        if isWalking(state) {
            return (
                "Scanning\u{2026} \(humanCount(progress.files)) entries",
                humanBytes(progress.bytes)
            )
        }
        let holds = ExploreView.holds(state)
        let scan = state.scanElapsed.map {
            String(format: "scanned in %.1f s", Self.seconds($0))
        }
        return (holds, scan ?? "")
    }

    /// The walk in flight, or the one that drew the mosaic and how long it
    /// took, as one line.
    static func summary(_ state: AppState) -> String {
        let (holds, scan) = status(state)
        return scan.isEmpty ? holds : "\(holds) \u{00b7} \(scan)"
    }

    nonisolated static func seconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }

    /// The way to every key and gesture: the system's own help button, as
    /// a Mac window puts one at the foot of a pane.
    private struct AllKeys: View {
        let state: AppState

        var body: some View {
            HelpLink {
                state.showHelp = true
            }
            .controlSize(.small)
            .focusEffectDisabled()
            .help("Every key and gesture \u{00b7} ?")
            .accessibilityLabel("All keys and gestures")
            .chromeIdentifier("all-keys")
        }
    }
}

/// A key and what it does, said quietly in words, as a status bar says
/// it: the key's name in the text colour, what it does in the dim one. No
/// cap drawn around the key: the words are the hint, and the help lists
/// every key. `leading` puts the separator before it, for one in a row.
struct KeyHint: View {
    let keys: String
    let label: String
    let leading: Bool
    @Environment(\.theme) private var theme

    init(keys: String, label: String, leading: Bool = false) {
        self.keys = keys
        self.label = label
        self.leading = leading
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if leading {
                Text("  \u{00b7}  ")
                    .foregroundStyle(theme.secondary.color)
                    .accessibilityHidden(true)
            }
            Text(Self.name(keys))
                .fontWeight(.medium)
                .foregroundStyle(theme.foreground.color)
            Text(" \(label)")
                .foregroundStyle(theme.secondary.color)
        }
        .lineLimit(1)
        .fixedSize()
        // "Space: to mark", as the pair reads, rather than two strays.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Self.spoken(keys)): \(label)")
    }

    /// A key's name as a Mac's keyboard and menus print it: Return, not
    /// enter; the letter keys in capitals, as on the keycaps.
    static func name(_ keys: String) -> String {
        switch keys {
        case "space": "Space"
        case "enter", "return": "Return"
        case "esc", "escape": "Esc"
        case "\u{232b}": "Delete"
        default: keys.count == 1 ? keys.uppercased() : keys
        }
    }

    /// The key as it is read out: the names, not the symbols.
    static func spoken(_ keys: String) -> String {
        switch keys {
        case "\u{232b}": "delete"
        case "return", "enter": "return"
        default: keys
        }
    }
}
