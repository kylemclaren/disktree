// Every key and gesture, on a card of glass over the dimmed window.
//
// Set the way System Settings sets a list: each group under its symbol and
// name, its rows in one rounded well with a hairline between them. A key is
// drawn as a key cap, lit from above with its lower edge showing, and a
// gesture as a capsule with the symbol of what the hand does, so the eye
// finds the key before it reads the words.

import DisktreeCore
import SwiftUI

/// The keyboard overlay (`?`): every key, the pointer and the trackpad, then
/// the review screen's keys, and what disktree will not do.
///
/// It is always in the window and shows only while `state.showHelp` is on,
/// so it can arrive: the window dims, and the card grows into place from
/// just smaller than itself.
struct HelpOverlay: View {
    let state: AppState
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem
    @Environment(\.accessibilityReduceMotion) private var reduced

    /// One group of the overlay: a heading, its rows, and a closing note.
    struct KeyGroup: Sendable {
        var title: String
        var rows: [(key: String, label: String)]
        var note: String?
    }

    /// Sentence case, and the tile a key acts on is always the one under
    /// the pointer if the pointer moved last, else the keyboard selection.
    nonisolated static let groups: [KeyGroup] = [
        KeyGroup(
            title: "Keys",
            rows: [
                ("space / x", "Mark or unmark the tile you point at"),
                ("enter", "Open that directory, at any depth"),
                (
                    "\u{232b} / esc",
                    "Go up one directory; esc clears a selected tile first"
                ),
                (
                    "\u{2190} \u{2191} \u{2193} \u{2192}",
                    "Move between tiles at this level"
                ),
                ("tab", "Next largest sibling"),
                ("[ / ]", "Draw fewer or more levels at once"),
                ("= / - / 0", "Magnify, shrink, or reset the view"),
                (
                    "/",
                    "Filter by name: only matches keep their colour; enter "
                        + "shows only them"
                ),
                ("f", "Reveal it in Finder"),
                (
                    "\u{2318}Y",
                    "Quick Look it; \u{2318}Y or esc closes the preview"
                ),
                ("c", "Review the marked list"),
                ("t", "Size, files or age: what areas and colours say"),
                ("r", "Scan again from the same root"),
                ("g", "The whole disk; click any directory above to widen"),
                ("d", "Disk usage or apparent size"),
                ("i", "Include or skip hidden entries"),
                ("p", "Show or hide the side panel"),
                ("\u{2318}= / \u{2318}- / \u{2318}0", "Interface zoom"),
                ("q", "Quit"),
            ],
            note: nil
        ),
        KeyGroup(
            title: "Pointer and trackpad",
            rows: [
                ("\u{2318}-click", "Mark without moving the selection"),
                (
                    "right-click",
                    "Mark, open, Quick Look, reveal in Finder or copy the "
                        + "path"
                ),
                ("scroll", "Zoom toward a directory, then go into it"),
                ("shift-scroll", "Pan the magnified view"),
                (
                    "pinch",
                    "Zoom until the directory fills the view; it stops there "
                        + "with a click, and a little further squeeze goes "
                        + "in or out"
                ),
                (
                    "double-tap",
                    "Two fingers: into the directory under them, and again "
                        + "to come back"
                ),
                (
                    "drag a tile",
                    "Out to Finder, a Terminal window or the Trash"
                ),
                ("drop a folder", "Onto the window to scan it"),
            ],
            note: nil
        ),
        KeyGroup(
            title: "Review screen",
            rows: [
                ("enter", "Copy the command for Terminal"),
                ("f", "Reveal them in Finder"),
                ("m / p", "The command moves to the Trash, or uses rm"),
                ("!", "Unmark all"),
                ("esc", "Back to the treemap"),
            ],
            note:
                "disktree never deletes anything itself: Finder or the "
                + "command you run does"
        ),
    ]

    /// Every row, group by group: what the overlay says, in reading order.
    nonisolated static var rows: [(key: String, label: String)] {
        groups.flatMap { group in
            group.rows + (group.note.map { [("", $0)] } ?? [])
        }
    }

    /// One column's width: a key lane and a label that reads at a glance.
    /// Two of them side by side where the window has the room.
    private nonisolated static let column = Size.help - Space.xl - Space.xl

    /// The narrowest a column may be and still read: the key lane, and a
    /// label of some thirty characters a line beside it. Narrower than
    /// this, the card takes one column instead of two.
    nonisolated static let narrowestColumn = Rems(20)

    /// The width of each column in a window `width` points wide at `rem`
    /// points to the rem, and whether there are two: two where two fit at
    /// least `narrowestColumn` wide, and no wider than they read best.
    /// The card is padded, and kept off the window's edges, by `Space.xl`
    /// either side of it.
    nonisolated static func columns(
        width: CGFloat,
        rem: CGFloat
    ) -> (width: CGFloat, paired: Bool) {
        let room = width - Space.xl.at(rem) * 4
        let comfortable = column.at(rem)
        let paired = min(comfortable, (room - Space.xl.at(rem)) / 2)
        if paired >= narrowestColumn.at(rem) {
            return (paired, true)
        }
        return (max(min(comfortable, room), 0), false)
    }

    var body: some View {
        let shown = state.showHelp
        ZStack {
            if shown {
                // Over the whole window, so a click anywhere outside the
                // card closes it, as it would a sheet. Dimmed, as a sheet
                // dims what is behind it — a shade of black, not a wash of
                // the cream, which fogged the screen rather than dim it —
                // and not hidden: the card explains what is under it.
                Color.black.opacity(theme.isDark ? 0.32 : 0.18)
                    .contentShape(Rectangle())
                    .onTapGesture { state.showHelp = false }
                    .transition(.opacity)
                // The card's columns are sized from the window it is in.
                GeometryReader { window in
                    card(in: window.size)
                        .frame(
                            width: window.size.width,
                            height: window.size.height
                        )
                }
                .transition(
                    ChromeMotion.transition(
                        .scale(scale: 0.94).combined(with: .opacity),
                        reduced: reduced
                    )
                )
            }
        }
        .animation(
            ChromeMotion.animation(Self.spring, reduced: reduced),
            value: shown
        )
    }

    /// The card grows into place with a touch of spring, as a sheet
    /// settles, and is still well inside a third of a second.
    private static let spring = Animation.spring(duration: 0.3, bounce: 0.18)

    private func card(in window: CGSize) -> some View {
        let (column, paired) = Self.columns(width: window.width, rem: rem)
        let gap = Space.xl.at(rem)
        let width = paired ? column * 2 + gap : column
        return VStack(alignment: .leading, spacing: Space.lg.at(rem)) {
            heading
                .frame(width: width, alignment: .leading)
            // The keys beside the pointer and the trackpad wherever two
            // columns can be read, however narrow the window, so the
            // gestures are never below the fold; one column only at a
            // large interface zoom. In a short window the columns scroll,
            // under the footer, with the scroller showing: no key scrolls
            // them, since every key goes to the dispatcher.
            ViewThatFits(in: .vertical) {
                VStack(alignment: .leading, spacing: Space.lg.at(rem)) {
                    columns(column, paired: paired, gap: gap)
                    footerText
                        .frame(width: width, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: Space.md.at(rem)) {
                    ScrollView(.vertical) {
                        columns(column, paired: paired, gap: gap)
                            // Clear of the scroller, whichever kind the
                            // person has chosen, and of the fade at the
                            // foot once scrolled to the end.
                            .padding(.trailing, Space.lg.at(rem))
                            .padding(.bottom, Space.xl.at(rem))
                    }
                    .scrollIndicators(.visible)
                    .scrollIndicatorsFlash(onAppear: true)
                    // What runs on below the card fades out rather than
                    // stop at a row cut in half: there is more.
                    .mask {
                        VStack(spacing: 0) {
                            Rectangle()
                            LinearGradient(
                                colors: [.black, .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: Space.xl.at(rem))
                        }
                    }
                    .chromeIdentifier("help-scrolls")
                    footerText
                        .frame(width: width, alignment: .leading)
                }
            }
        }
        .padding(Space.xl.at(rem))
        .glassPlate(
            RoundedRectangle(
                cornerRadius: Rounding.panel.at(rem),
                style: .continuous
            ),
            fill: theme.surface,
            border: theme.border.opacity(0.8),
            // A dense table of small text: the glass half the app's own
            // surface, so the mosaic under it does not show through the
            // words.
            tint: theme.surface,
            tintOpacity: 0.6
        )
        // The card keeps its clicks: only the dimmed window around it
        // closes the overlay.
        .contentShape(Rectangle())
        .onTapGesture {}
        .padding(Space.xl.at(rem))
        .accessibilityAddTraits(.isModal)
        .chromeIdentifier("help-overlay", container: true)
    }

    /// The keyboard on a tile of the accent, the title, and the way out.
    private var heading: some View {
        let side = Space.xxl.at(rem)
        return HStack(alignment: .center, spacing: Space.md.at(rem)) {
            RoundedRectangle(
                cornerRadius: Rounding.control.at(rem),
                style: .continuous
            )
            .fill(
                LinearGradient(
                    colors: [
                        theme.accent.mixed(toward: theme.bright, by: 0.15)
                            .color,
                        theme.accent.color,
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                Image(systemName: "keyboard")
                    .font(TextSize.title.font(rem, weight: .semibold))
                    .foregroundStyle(
                        (theme.isDark ? theme.background : theme.surface)
                            .color
                    )
            }
            .frame(width: side, height: side)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs.at(rem)) {
                Text("Keys and Gestures")
                    .font(TextSize.heading.font(rem, weight: .bold))
                    .foregroundStyle(theme.bright.color)
                    .accessibilityAddTraits(.isHeader)
                Text(
                    "Every key acts on the tile under the pointer, or on "
                        + "the selection once you use the arrows"
                )
                .font(TextSize.caption.font(rem))
                .foregroundStyle(theme.secondary.color)
                .lineLimit(1)
            }
            Spacer(minLength: Space.md.at(rem))
            // The system's close button as a sheet or a popover draws it:
            // a filled circle with a cross, which darkens as it is pressed.
            Button {
                state.showHelp = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(TextSize.title.font(rem, weight: .medium))
                    .foregroundStyle(theme.secondary.color)
            }
            .buttonStyle(.borderless)
            // Keys go to the window's one dispatcher, where ? and esc
            // close this; a focus ring would suggest the button owns them.
            .focusEffectDisabled()
            .help("Close (? or esc)")
            .accessibilityLabel("Close")
        }
    }

    /// Every group, in two columns (the keys, then the pointer and the
    /// review screen) or in one.
    @ViewBuilder
    private func columns(
        _ column: CGFloat,
        paired: Bool,
        gap: CGFloat
    ) -> some View {
        if paired {
            HStack(alignment: .top, spacing: gap) {
                groups(Self.groups.prefix(1))
                    .frame(width: column, alignment: .leading)
                groups(Self.groups.dropFirst())
                    .frame(width: column, alignment: .leading)
            }
            .chromeIdentifier("help-two-columns", container: true)
        } else {
            groups(Self.groups[...])
                .frame(width: column, alignment: .leading)
        }
    }

    private func groups(_ groups: ArraySlice<KeyGroup>) -> some View {
        VStack(alignment: .leading, spacing: Space.lg.at(rem)) {
            ForEach(groups.indices, id: \.self) { index in
                group(groups[index])
            }
        }
    }

    /// A group as System Settings sets one: its name over a rounded well
    /// of rows, a hairline between them.
    private func group(_ group: KeyGroup) -> some View {
        VStack(alignment: .leading, spacing: Space.sm.at(rem)) {
            Label(group.title, systemImage: Self.symbol(group.title))
                .font(TextSize.caption.font(rem, weight: .semibold))
                .foregroundStyle(theme.secondary.color)
                .padding(.leading, Space.xs.at(rem))
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(group.rows.indices, id: \.self) { index in
                    let row = group.rows[index]
                    if index > 0 {
                        Rectangle()
                            .fill(theme.divider.color)
                            .frame(height: hairline)
                            .padding(.leading, Space.md.at(rem))
                    }
                    HStack(alignment: .center, spacing: Space.md.at(rem)) {
                        HelpKeys(row.key)
                            .frame(
                                width: Size.keyLane.at(rem),
                                alignment: .leading
                            )
                        Text(row.label)
                            .font(TextSize.body.font(rem))
                            .foregroundStyle(theme.foreground.color)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Space.md.at(rem))
                    // Tight enough that every key fits in a window of the
                    // size the app opens at without scrolling.
                    .padding(.vertical, Space.xs.at(rem) + Space.xxs.at(rem))
                    .accessibilityElement(children: .combine)
                }
            }
            .background(
                theme.foreground.opacity(theme.isDark ? 0.06 : 0.045).color,
                in: RoundedRectangle(
                    cornerRadius: Rounding.control.at(rem),
                    style: .continuous
                )
            )
            if let note = group.note {
                Label(note, systemImage: "info.circle")
                    .font(TextSize.caption.font(rem))
                    .foregroundStyle(theme.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Space.xs.at(rem))
            }
        }
    }

    /// The symbol a group is headed with.
    private nonisolated static func symbol(_ title: String) -> String {
        switch title {
        case "Keys": "keyboard"
        case "Pointer and trackpad": "rectangle.and.hand.point.up.left"
        default: "list.bullet.rectangle"
        }
    }

    /// How to close it by the keyboard, as a sheet's footer says.
    private var footerText: some View {
        HStack(spacing: 0) {
            Text("Press ")
            KeyHint(keys: "?", label: "or")
            Text(" ")
            KeyHint(keys: "esc", label: "to close")
        }
        .font(TextSize.caption.font(rem))
        .foregroundStyle(theme.secondary.color)
        .lineLimit(1)
    }
}

// MARK: - Key caps

/// A row's keys as key caps: `space / x` is a cap, a quiet slash and
/// another cap; arrows side by side are a cap each; a gesture is a capsule
/// with the symbol of what the hand does.
private struct HelpKeys: View {
    let keys: String
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    init(_ keys: String) {
        self.keys = keys
    }

    var body: some View {
        let choices = keys.components(separatedBy: " / ")
        HStack(spacing: Space.xs.at(rem)) {
            ForEach(choices.indices, id: \.self) { index in
                if index > 0 {
                    Text("/")
                        .font(TextSize.caption.font(rem))
                        .foregroundStyle(theme.secondary.opacity(0.7).color)
                }
                choice(choices[index])
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys)
    }

    @ViewBuilder
    private func choice(_ keys: String) -> some View {
        let parts = keys.split(separator: " ").map(String.init)
        if let symbol = Self.gesture(keys) {
            GestureChip(label: keys, symbol: symbol)
        } else if parts.count > 1, parts.allSatisfy({ $0.count == 1 }) {
            // Arrows, one cap each, the way they sit on the keyboard.
            HStack(spacing: Space.xxs.at(rem)) {
                ForEach(parts, id: \.self) { KeyCap($0) }
            }
        } else {
            KeyCap(keys)
        }
    }

    /// The symbol for a pointer or trackpad gesture; `nil` for a key.
    nonisolated static func gesture(_ keys: String) -> String? {
        switch keys {
        case "\u{2318}-click": "cursorarrow.click"
        case "right-click": "contextualmenu.and.cursorarrow"
        case "scroll": "arrow.up.and.down"
        case "shift-scroll": "arrow.left.and.right"
        case "pinch": "hand.pinch"
        case "double-tap": "hand.tap"
        case "drag a tile": "hand.draw"
        case "drop a folder": "folder.badge.plus"
        default: nil
        }
    }
}

/// One key, as it sits on the keyboard: a rounded cap, lit from above,
/// with its lower edge showing.
private struct KeyCap: View {
    let key: String
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    init(_ key: String) {
        self.key = key
    }

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: Rounding.small.at(rem),
            style: .continuous
        )
        // The glyph in SF Pro Rounded, as every key cap in the app.
        Text(key)
            .font(TextSize.caption.rounded(rem, weight: .medium))
            .foregroundStyle(theme.bright.color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Space.xs.at(rem) + Space.xxs.at(rem))
            .frame(
                minWidth: Space.lg.at(rem) + Space.xs.at(rem),
                minHeight: Space.lg.at(rem) + Space.xxs.at(rem)
            )
            .background {
                shape
                    .fill(
                        (theme.isDark
                            ? theme.bright.opacity(0.1) : theme.surface).color
                    )
                    // The key's lower edge: a darker lip under the cap.
                    .shadow(
                        color: theme.foreground.opacity(
                            theme.isDark ? 0.5 : 0.22
                        ).color,
                        radius: 0,
                        y: 1
                    )
            }
            .overlay {
                shape.strokeBorder(
                    theme.foreground.opacity(0.14).color,
                    lineWidth: hairline
                )
            }
    }
}

/// A gesture, as the hand makes it: its symbol and its name in a capsule.
private struct GestureChip: View {
    let label: String
    let symbol: String
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    var body: some View {
        HStack(spacing: Space.xs.at(rem)) {
            Image(systemName: symbol)
                .font(TextSize.caption.font(rem, weight: .semibold))
                .foregroundStyle(theme.accent.color)
            Text(label)
                .font(TextSize.caption.font(rem, weight: .medium))
                .foregroundStyle(theme.bright.color)
                .lineLimit(1)
        }
        .fixedSize()
        .padding(.horizontal, Space.sm.at(rem))
        .frame(minHeight: Space.lg.at(rem) + Space.xxs.at(rem))
        .background(theme.accent.opacity(0.12).color, in: Capsule())
    }
}
