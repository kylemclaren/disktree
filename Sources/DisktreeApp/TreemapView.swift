// The treemap as the explore screen embeds it.
//
// SwiftUI lays the mosaic out like any other view: it takes whatever room
// the explore screen leaves it, beside the panel and under the top bar. What
// happens inside that room is AppKit's: one `TreemapNSView` paints every
// tile and takes every pointer event (Invariant 6). Nothing in `body` reads
// the state, so SwiftUI never re-renders for a hover or a zoom; the painted
// view redraws itself from what its own frame read.
//
// What the view takes from SwiftUI is what the environment knows about the
// person rather than the tree: where haptics play, and whether they asked
// for less motion.

import SwiftUI

/// The mosaic, for the explore screen: the painted treemap view, sized by
/// SwiftUI.
struct TreemapView: View {
    let state: AppState

    init(state: AppState) {
        self.state = state
    }

    var body: some View {
        TreemapHost(state: state)
    }
}

/// Hosts `TreemapNSView` in SwiftUI.
private struct TreemapHost: NSViewRepresentable {
    let state: AppState

    func makeNSView(context: Context) -> TreemapNSView {
        let view = TreemapNSView(state: state)
        follow(context.environment, in: view)
        return view
    }

    func updateNSView(_ view: TreemapNSView, context: Context) {
        // Only a different state is news: everything inside one is observed
        // by the view itself.
        if view.state !== state {
            view.state = state
        }
        follow(context.environment, in: view)
    }

    /// Hand the view what the environment says about the person: where
    /// haptics play, and whether motion is to be kept to fades.
    private func follow(
        _ environment: EnvironmentValues, in view: TreemapNSView
    ) {
        view.haptics = environment.haptics
        view.reducesMotion = environment.accessibilityReduceMotion
    }
}
