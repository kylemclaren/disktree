// The scale this app draws with: spacing, type, icons and region widths.
//
// Everything is in rem: type, spacing, controls and icons share one zoom
// axis, so interface zoom (`⌘=`, `⌘-`, `⌘0`, and ctrl as on Linux) keeps
// every relationship intact instead of only enlarging text. Choose a step by
// what two things mean to each other, not by the points it happens to
// resolve to today. A token is a multiplier; `rem * Space.md` or
// `Space.md.at(rem)` is the size in points.
//
// Radius has a single tier here: Omarchy's surfaces are square, so nothing in
// this app rounds a corner, and nested surfaces stay concentric by
// construction. That stays true on the Mac.
//
// Points remain only where a value is physical: hairline borders, the
// treemap's own geometry (laid out in viewport points, then scaled by the
// view), and positions that come from the pointer.
//
// No SwiftUI here: the mosaic paints with CoreGraphics and reads the same
// tokens.

import CoreGraphics

/// A length in rem: a multiple of the interface's base size.
public struct Rems: Sendable, Hashable, Comparable {
    public var value: CGFloat

    public init(_ value: CGFloat) {
        self.value = value
    }

    /// This length in points, at `rem` points to the rem.
    public func at(_ rem: CGFloat) -> CGFloat {
        value * rem
    }

    public static func * (rem: CGFloat, length: Rems) -> CGFloat {
        length.at(rem)
    }

    public static func + (left: Rems, right: Rems) -> Rems {
        Rems(left.value + right.value)
    }

    public static func - (left: Rems, right: Rems) -> Rems {
        Rems(left.value - right.value)
    }

    public static func * (length: Rems, factor: CGFloat) -> Rems {
        Rems(length.value * factor)
    }

    public static func < (left: Rems, right: Rems) -> Bool {
        left.value < right.value
    }
}

/// The guide's semantic spacing scale: 2, 4, 8, 12, 16, 24 and 32 pt at the
/// default 16 pt rem.
public enum Space {
    /// Optical correction: an icon baseline, a compact separator.
    public static let xxs = Rems(0.125)
    /// Parts of one control: icon and label, title and its description.
    public static let xs = Rems(0.25)
    /// Closely related controls: a button group, dialog actions.
    public static let sm = Rems(0.5)
    /// One content group: columns of a row, compact form rows.
    public static let md = Rems(0.75)
    /// Separate groups in one section, and region padding.
    public static let lg = Rems(1.0)
    /// Separate sections.
    public static let xl = Rems(1.5)
    /// A major region boundary: empty-state breathing room.
    public static let xxl = Rems(2.0)
}

/// Type steps. Omarchy's own sizes, so the app reads like its components.
public enum TextSize {
    /// Metadata, key caps and tooltips.
    public static let caption = Rems(0.6875)
    /// Body text and control labels.
    public static let body = Rems(0.75)
    /// Window, section and dialog titles.
    public static let title = Rems(0.875)
    /// The app name and the selection's name.
    public static let heading = Rems(1.125)
    /// A figure worth reading from across the room: the free space.
    public static let figure = Rems(1.625)
    /// The selection's size: the one number the panel exists to show.
    public static let display = Rems(2.5)
}

/// Icon slots, sized with the text they sit beside.
public enum IconSize {
    public static let sm = Rems(0.75)
    public static let md = Rems(0.875)
    public static let lg = Rems(1.375)
}

/// Region and lane widths. Each is the comfortable default for its content
/// at the default rem; they scale with zoom like everything else.
public enum Size {
    /// A crumb's sibling menu.
    public static let siblingMenu = Rems(24.0)
    public static let siblingMenuHeight = Rems(32.0)
    /// A list row's share bar.
    public static let rowBar = Rems(5.5)
    /// A legend or identity swatch.
    public static let swatch = Rems(0.625)
    /// A thin meter: share of the scan, the disk.
    public static let meter = Rems(0.3125)
    /// The meter on the scanning panel.
    public static let scanningMeter = Rems(26.25)
    /// The Size | Files | Age choice in the settings row.
    public static let rankingChoice = Rems(11.0)
    /// The review screen's summary column.
    public static let reviewSummary = Rems(22.5)
    /// The review list's share-bar lane.
    public static let shareLane = Rems(6.0)
    /// The review list's size lane: right-aligned, so sizes compare.
    public static let sizeLane = Rems(5.0)
    /// The cursor tooltip.
    public static let tooltip = Rems(16.75)
    /// The keyboard overlay.
    public static let help = Rems(32.5)
    /// The key column of the keyboard overlay.
    public static let keyLane = Rems(7.0)
}

/// Interface zoom steps, as a factor of the 16 pt default rem.
public let zoomSteps: [CGFloat] = [0.75, 0.875, 1.0, 1.125, 1.25, 1.5, 1.75]

/// The index of `1.0` in `zoomSteps`: where `⌘0` returns to.
public let defaultZoomStep = 2

/// The default rem, in points.
public let baseRem: CGFloat = 16

/// A hairline: one point, whatever the zoom, because a border is physical.
public let hairline: CGFloat = 1
