// The bar over a screen that takes the whole window, when the window has no
// toolbar to give it: what the screen is, one line of what it holds, and
// its actions.
//
// In the app's own window a screen's title and actions are the window's
// title and toolbar items. A window without a toolbar — a test's, or one
// hosted without SwiftUI's toolbar — gets this bar in their place, laid out
// as a unified toolbar is: the title over its summary at the leading edge,
// clear of the traffic lights, and the actions at the trailing edge. The
// window draws its content under a hidden title bar, so the bar does what
// the title bar would: it leaves the traffic lights their corner and drags
// the window.
//
// The summary line changes while it is read (a mark goes, a path vanishes
// from disk), so its numbers roll to their new values, or fade with Reduce
// Motion.

import SwiftUI

/// A screen's title and summary, and its actions beside them.
struct ScreenHeader<Actions: View>: View {
    /// Room the traffic lights take at the leading edge of a full-size
    /// content view: the three buttons end 69 points in, and the 9 points
    /// they sit from the window's edge follow them again. In points, not
    /// rem: AppKit draws them at one size whatever the interface zoom.
    static var trafficLightsInset: CGFloat { 78 }

    /// The height AppKit gives a hidden title bar. The traffic lights are
    /// centred in it, so the bar is never shorter, even at the smallest
    /// zoom.
    static var titleBarHeight: CGFloat { 32 }

    let title: String
    let subtitle: String
    let actions: Actions
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        _ title: String,
        subtitle: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.subtitle = subtitle
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .center, spacing: Space.lg.at(rem)) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(TextSize.title.font(rem, weight: .bold))
                    .foregroundStyle(theme.bright.color)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(TextSize.caption.font(rem))
                    .monospacedDigit()
                    .foregroundStyle(theme.secondary.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(
                        reduceMotion ? .opacity : .numericText()
                    )
                    .animation(
                        ReviewMotion.change(reduceMotion),
                        value: subtitle
                    )
            }
            Spacer(minLength: 0)
            // The actions keep their size; the summary gives way first.
            actions
                .layoutPriority(1)
        }
        .padding(.leading, Self.trafficLightsInset + Space.xs.at(rem))
        .padding(.trailing, Space.lg.at(rem))
        .padding(.vertical, Space.xs.at(rem))
        .frame(minHeight: Self.titleBarHeight)
        .background(theme.background.color)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.divider.color)
                .frame(height: hairline)
        }
        // The bar stands where the title bar was: pressing on it and
        // dragging moves the window, as a title bar would.
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents(true)
        .accessibilityElement(children: .contain)
    }
}

extension ScreenHeader where Actions == EmptyView {
    /// A title and its summary, with no actions beside them.
    init(_ title: String, subtitle: String) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}
