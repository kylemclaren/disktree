// The toast: a moment's confirmation that a hand-over happened — the
// command is on the pasteboard, Finder has the marks selected, a path was
// copied.
//
// It is the state's (`state.toast`, gone by itself after `toastDuration`,
// or at Escape through the dispatcher), and this only shows it: low over
// the mosaic on the explore screen, low over the window on the review, over
// every screen alike. It never takes a click or the keyboard — it covers
// nothing that matters for long, and a person who clicks where it is means
// the tile under it. What has to stay, a problem above all, goes on the
// notice line instead.
//
// It is a capsule of Liquid Glass, as the system's own confirmations are on
// macOS 26, that springs up into place with its symbol bouncing once; with
// Reduce Motion it only fades.
//
// This file also holds what every floating surface of the app is drawn
// with (`glassPlate`); how round each one is, is `Rounding`'s.

import DisktreeCore
import SwiftUI

// MARK: - Floating surfaces

extension View {
    /// The surface of something that floats over the screen: Liquid Glass
    /// in `shape` on macOS 26, the system's material on macOS 15, and —
    /// wherever neither can be seen, as in a window rendered offscreen for
    /// a snapshot — `fill` with a hairline `border`, lifted by a soft
    /// shadow in the palette's own navy.
    ///
    /// Glass is drawn by the window server from what lies behind the
    /// window, so it exists only on screen; the root says when it does
    /// (`floatingGlass`). A `tint` colours the glass, `tintOpacity` of
    /// it: a little for a surface that means something (a warning), half
    /// the app's own surface for one whose small text must read over
    /// saturated tiles.
    func glassPlate<S: InsettableShape>(
        _ shape: S,
        fill: HSLA,
        border: HSLA,
        tint: HSLA? = nil,
        tintOpacity: Double = 0.18,
        lifted: Bool = true
    ) -> some View {
        modifier(
            GlassPlate(
                shape: shape,
                fill: fill,
                border: border,
                tint: tint?.opacity(tintOpacity),
                lifted: lifted
            )
        )
    }
}

private struct GlassPlate<S: InsettableShape>: ViewModifier {
    let shape: S
    let fill: HSLA
    let border: HSLA
    let tint: HSLA?
    let lifted: Bool
    @Environment(\.floatingGlass) private var glass
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    func body(content: Content) -> some View {
        if #available(macOS 26, *), glass {
            content.glassEffect(.regular.tint(tint?.color), in: shape)
        } else if glass {
            // macOS 15 on screen: the material behind-window blending
            // gives, with the rim the plain surface has.
            shadowed(
                content
                    .background(.regularMaterial, in: shape)
                    .overlay { rim }
            )
        } else {
            shadowed(
                content
                    .background(fill.color, in: shape)
                    .overlay { rim }
            )
        }
    }

    /// A hairline in the border colour, catching a little light along the
    /// top edge the way glass does, so even the plain surface reads as a
    /// pane rather than a box.
    private var rim: some View {
        shape.strokeBorder(
            LinearGradient(
                colors: [
                    theme.isDark
                        ? theme.bright.opacity(0.22).color
                        : Color.white.opacity(0.9),
                    border.color,
                ],
                startPoint: .top,
                endPoint: .center
            ),
            lineWidth: hairline
        )
    }

    @ViewBuilder
    private func shadowed(_ view: some View) -> some View {
        if lifted {
            view
                .compositingGroup()
                // The palette's own darkest ink rather than a neutral
                // black, so the shadow on the cream is a navy one; on the
                // navy, black, which is the only thing darker.
                .shadow(
                    color: (theme.isDark
                        ? HSLA(h: 0, s: 0, l: 0).opacity(0.45)
                        : MP300.midnightBlue.opacity(0.16)).color,
                    radius: Space.lg.at(rem),
                    y: Space.xs.at(rem)
                )
        } else {
            view
        }
    }
}

// MARK: - Where toasts go

/// Where a screen wants its toasts: the region they sit low in, centred.
/// The explore screen gives its mosaic; a screen that gives nothing has
/// them low over the whole window, clear of its footer.
struct ToastAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(
        value: inout Anchor<CGRect>?,
        nextValue: () -> Anchor<CGRect>?
    ) {
        value = value ?? nextValue()
    }
}

/// The widest a toast grows before its words wrap: a line that can be read
/// at a glance, two at most.
private let toastWidth = Rems(30)

/// The toast layer over the whole window: the current toast, if any, low in
/// the region its screen gave.
struct ToastLayer: View {
    let state: AppState
    let anchor: Anchor<CGRect>?
    @Environment(\.rem) private var rem
    @Environment(\.accessibilityReduceMotion) private var reduced

    /// A toast arrives with a little life, as a system confirmation does,
    /// and settles well inside half a second.
    static let spring = Animation.spring(duration: 0.38, bounce: 0.28)

    var body: some View {
        GeometryReader { proxy in
            let room =
                anchor.map { proxy[$0] }
                ?? Self.fallback(in: proxy.size, rem: rem)
            ZStack(alignment: .bottom) {
                if let toast = state.toast {
                    Toast(notice: toast, serial: state.toastSerial)
                        .frame(maxWidth: toastWidth.at(rem))
                        .fixedSize(horizontal: false, vertical: true)
                        // A new toast arrives as new, even with the words
                        // of the last one.
                        .id(state.toastSerial)
                        // Springs up from just below where it rests,
                        // growing into its capsule, and fades away where
                        // it is.
                        .transition(
                            ChromeMotion.transition(
                                .asymmetric(
                                    insertion: .opacity
                                        .combined(
                                            with: .offset(y: Space.lg.at(rem))
                                        )
                                        .combined(
                                            with: .scale(
                                                scale: 0.9,
                                                anchor: .bottom
                                            )
                                        ),
                                    removal: .opacity.combined(
                                        with: .scale(scale: 0.96)
                                    )
                                ),
                                reduced: reduced
                            )
                        )
                }
            }
            .frame(
                width: room.width,
                height: max(room.height - Space.lg.at(rem), 0),
                alignment: .bottom
            )
            .offset(x: room.minX, y: room.minY)
            .animation(
                ChromeMotion.animation(Self.spring, reduced: reduced),
                value: ToastKey(
                    serial: state.toastSerial, up: state.toast != nil)
            )
        }
        .allowsHitTesting(false)
        .onChange(of: state.toastSerial) {
            // Seen and gone in a moment: VoiceOver says it instead.
            if let toast = state.toast {
                AccessibilityNotification.Announcement(toast.text).post()
            }
        }
    }

    /// Where a toast goes when its screen gave no region: the whole window
    /// less its foot, where a screen keeps its key hints and its actions.
    nonisolated static func fallback(in size: CGSize, rem: CGFloat) -> CGRect {
        let foot = min(Space.xxl.at(rem) * 3, size.height)
        return CGRect(
            x: 0,
            y: 0,
            width: size.width,
            height: size.height - foot
        )
    }

    private struct ToastKey: Equatable {
        var serial: Int
        var up: Bool
    }
}

// MARK: - A toast

/// One toast: what happened, with a sign of how it went, in a capsule.
struct Toast: View {
    let notice: Notice
    /// Which toast this is, so its symbol bounces once for each new one.
    var serial = 0
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var shown = false

    var body: some View {
        let color = theme.alertColor(notice.status)
        HStack(alignment: .center, spacing: Space.sm.at(rem)) {
            Image(systemName: Self.symbol(notice.status))
                .symbolRenderingMode(.hierarchical)
                .font(TextSize.title.font(rem, weight: .semibold))
                .foregroundStyle(color.color)
                .symbolEffect(.bounce, value: reduced ? false : shown)
                .accessibilityHidden(true)
            Text(notice.text)
                .font(TextSize.body.font(rem, weight: .medium))
                .foregroundStyle(theme.bright.color)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, Space.md.at(rem))
        .padding(.trailing, Space.lg.at(rem))
        .padding(.vertical, Space.sm.at(rem) + Space.xxs.at(rem))
        .glassPlate(
            Capsule(),
            fill: theme.surface,
            border: color.opacity(0.35)
        )
        .onAppear { shown = true }
        .accessibilityElement(children: .combine)
        .chromeIdentifier("toast")
    }

    /// The SF Symbol for a toast of `status`: a tick for what worked.
    nonisolated static func symbol(_ status: Status) -> String {
        switch status {
        case .success: "checkmark.circle.fill"
        case .neutral: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
}
