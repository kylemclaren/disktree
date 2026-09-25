// The values the state machine and the screens share: what is on screen,
// how the treemap is transformed, what a key or a click is, and what one
// frame of the mosaic needs. Pure values, so they can be reasoned about and
// tested without a window.

import CoreGraphics
import DisktreeCore
import Foundation
import System

/// What a tile's colour says.
public enum ColorMode: Sendable, Hashable, CaseIterable {
    /// The kind of data it is.
    case kind
    /// How long since anything in it was written.
    case age
}

/// Which screen the app is showing.
///
/// There is no removal screen: disktree removes nothing itself. The review
/// hands the marked list to Finder or to a terminal, and the explore screen
/// notices what has gone since.
public enum Screen: Sendable, Hashable {
    /// Walk the treemap and mark what should go.
    case explore
    /// Review every marked path, then take the list to Finder or a
    /// terminal.
    case review
}

/// One step of the trail.
public enum Crumb: Sendable, Hashable {
    /// A directory above the scanned root: going there scans only what is
    /// new at that level.
    case above(FilePath)
    /// A directory in the tree, by crumbs from the scanned root.
    case tree([Int])
}

/// A labelled step of the trail, from `/` down to the directory drawn.
public struct TrailStep: Sendable, Hashable {
    public var label: String
    public var crumb: Crumb

    public init(label: String, crumb: Crumb) {
        self.label = label
        self.crumb = crumb
    }
}

/// One row of a sibling menu.
public struct Sibling: Sendable, Hashable {
    /// Index among the parent's children.
    public var index: Int
    public var name: String
    public var value: UInt64
    public var category: DisktreeCore.Category
    public var isDir: Bool

    public init(
        index: Int,
        name: String,
        value: UInt64,
        category: DisktreeCore.Category,
        isDir: Bool
    ) {
        self.index = index
        self.name = name
        self.value = value
        self.category = category
        self.isDir = isDir
    }
}

/// Rows a sibling menu lists; the rest are counted.
public let siblingRows = 24

/// The side panel's width in rem: default and limits. In rem, so interface
/// zoom scales it with everything it holds.
public enum PanelSize {
    public static let rems: CGFloat = 23
    public static let minRems: CGFloat = 17
    public static let maxRems: CGFloat = 44
    /// Width, in rem, below which the side panel gives the mosaic its room.
    public static let shownRems: CGFloat = 52
}

/// The narrowest and widest the panel may be, in rem, in a window
/// `viewport` points wide: its own limits, and never so wide that the
/// mosaic is squeezed below the panel's minimum.
public func panelWidthLimits(
    viewport: CGFloat,
    rem: CGFloat
) -> ClosedRange<CGFloat> {
    let ceiling = min(
        max(viewport / rem - PanelSize.minRems, PanelSize.minRems),
        PanelSize.maxRems
    )
    return PanelSize.minRems...ceiling
}

/// The treemap view transform: `screen = (base - origin) * scale`.
///
/// All viewport geometry stays in the base space of an unzoomed layout, so
/// pan and zoom never require a re-layout (Invariant 8). Named
/// `ViewTransform` because `View` is SwiftUI's.
public struct ViewTransform: Sendable, Hashable {
    public var scale: Double
    public var originX: Double
    public var originY: Double

    public init(scale: Double, originX: Double, originY: Double) {
        self.scale = scale
        self.originX = originX
        self.originY = originY
    }

    public static let identity = ViewTransform(
        scale: 1,
        originX: 0,
        originY: 0
    )
    public static let minScale: Double = 1
    /// Past this, zooming again descends into whatever is under the cursor
    /// instead of magnifying further: the continuous "keep zooming and you
    /// are inside" gesture, with a breadcrumb to walk back out.
    public static let maxScale: Double = 5

    public func project(_ rect: Rect) -> Rect {
        Rect(
            x: (rect.x - originX) * scale,
            y: (rect.y - originY) * scale,
            w: rect.w * scale,
            h: rect.h * scale
        )
    }

    /// Viewport point to base-space point.
    public func unproject(x: Double, y: Double) -> (x: Double, y: Double) {
        (x / scale + originX, y / scale + originY)
    }

    /// Zoom by `factor` toward `(x, y)` and no further than `ceiling`.
    ///
    /// The base point under `(x, y)` stays put, which is what makes a wheel
    /// zoom feel pointed at the tile rather than at the window.
    public func zoomed(
        atX x: Double,
        y: Double,
        factor: Double,
        ceiling: Double
    ) -> ViewTransform {
        let scale = min(max(self.scale * factor, Self.minScale), ceiling)
        let base = unproject(x: x, y: y)
        return ViewTransform(
            scale: scale,
            originX: base.x - x / scale,
            originY: base.y - y / scale
        )
    }

    /// The scale at which `rect` exactly fits the viewport.
    public static func fitScale(_ rect: Rect, area: CGSize) -> Double {
        let width = max(Double(area.width), 1)
        let height = max(Double(area.height), 1)
        if rect.w <= 0 || rect.h <= 0 {
            return minScale
        }
        return min(width / rect.w, height / rect.h)
    }

    /// The region of the base layout the viewport currently shows.
    public func visibleBase(_ area: CGSize) -> Rect {
        let width = max(Double(area.width), 1)
        let height = max(Double(area.height), 1)
        return Rect(x: originX, y: originY, w: width / scale, h: height / scale)
    }

    /// Keep the viewport inside the layout: no empty margins, ever.
    public func clamped(_ area: CGSize) -> ViewTransform {
        let width = Double(area.width)
        let height = Double(area.height)
        let maxX = max(width - width / scale, 0)
        let maxY = max(height - height / scale, 0)
        return ViewTransform(
            scale: scale,
            originX: min(max(originX, 0), maxX),
            originY: min(max(originY, 0), maxY)
        )
    }
}

/// A layout transition: the region the user is looking at, and where that
/// same region lands in the layout being switched to.
///
/// Every descending or ascending move is one region of the tree changing
/// address. Rather than moving a camera, each tile is drawn from where that
/// region *was* to where it *is*, so the tiles inside the directory that is
/// being entered grow into place and the ones being left slide out. That is
/// what makes "zoom in and descend" read as one motion: the newly visible
/// level is always larger than it was a moment ago, never smaller.
public struct LayoutTransition: Sendable, Hashable {
    /// The region in the old frame, in viewport coordinates.
    public var src: Rect
    /// The same region in the new frame, in viewport coordinates.
    public var dst: Rect
    public var started: ContinuousClock.Instant
    public var duration: Duration

    public init(src: Rect, dst: Rect, now: ContinuousClock.Instant = .now) {
        self.src = src
        self.dst = dst
        self.started = now
        // Longer pulls take a little longer, but never enough to feel slow.
        let ratio = dst.w > 1 ? src.w / dst.w : 1
        let magnitude = min(max(log2(max(abs(ratio), 1)), 0), 4)
        self.duration = .milliseconds(130 + Int(magnitude * 45))
    }

    /// Where a rectangle in the new layout was, before the switch.
    public func origin(of rect: Rect) -> Rect {
        let scale = dst.w > 0 ? src.w / dst.w : 1
        return Rect(
            x: (rect.x - dst.x) * scale + src.x,
            y: (rect.y - dst.y) * scale + src.y,
            w: rect.w * scale,
            h: rect.h * scale
        )
    }

    /// The rectangle to draw at `now`, and whether the transition is still
    /// running.
    public func sample(
        _ rect: Rect,
        at now: ContinuousClock.Instant = .now
    ) -> (rect: Rect, running: Bool) {
        let elapsed = (now - started) / duration
        if elapsed >= 1 {
            return (rect, false)
        }
        // Ease out: fast at first, settling into place.
        let eased = 1 - pow(1 - max(elapsed, 0), 3)
        let from = origin(of: rect)
        func lerp(_ a: Double, _ b: Double) -> Double { (b - a) * eased + a }
        return (
            Rect(
                x: lerp(from.x, rect.x),
                y: lerp(from.y, rect.y),
                w: lerp(from.w, rect.w),
                h: lerp(from.h, rect.h)
            ),
            true
        )
    }
}

/// What a zoom gesture did: the view answers it with a feel under the
/// fingers, which the state cannot play itself — it cannot tell a trackpad
/// from a mouse wheel, and only the view knows a finger is on the pad.
public enum ZoomOutcome: Sendable, Hashable {
    /// Nothing moved: no zoom asked, or a pinch pressing on a stop without
    /// going through it yet.
    case none
    /// The view moved within the level: magnified, shrunk or panned.
    case zoomed
    /// The zoom came to rest against a stop — the directory under the
    /// pointer fills the view, or the level is back to its whole — this
    /// event, and not before: once per arrival, never per event.
    case reachedEdge
    /// The directory on screen changed: in or out a level. The rest of a
    /// scroll gesture is the view's to let go.
    case changedLevel
}

/// What a click on the mosaic did, for the view's feedback. Only the view
/// knows a click came from a pointer; the same marks made by a key must
/// not be felt.
public enum ClickOutcome: Sendable, Hashable {
    /// Nothing changed: over the ground, a refused mark, a right click.
    case none
    /// Another tile became the selection.
    case selected
    /// A directory opened.
    case changedLevel
    /// A mark went on or came off.
    case toggledMark
}

/// A merged "+N more" tail under the pointer: nothing to act on, since its
/// crumbs are its directory's, but worth a tooltip saying what it stands
/// for.
public struct HoveredTail: Sendable, Hashable {
    /// The directory whose small entries it merges.
    public var crumbs: [Int]
    /// How many entries it merges.
    public var count: Int
    /// What they weigh together, in the metric on screen, or in what the
    /// applied filter keeps of them.
    public var value: UInt64

    public init(crumbs: [Int], count: Int, value: UInt64) {
        self.crumbs = crumbs
        self.count = count
        self.value = value
    }
}

/// A one-line message under the scan totals, with the status that colours
/// it.
public struct Notice: Sendable, Hashable {
    public var text: String
    public var status: Status

    public init(_ text: String, status: Status) {
        self.text = text
        self.status = status
    }

    /// The notice on a line of its own, as a sentence: its first letter
    /// in capitals. Notices are written as clauses, so one can be joined
    /// to another; a line that starts with a path keeps the path as it is.
    public var sentence: String {
        guard let first = text.first, first.isLowercase else {
            return text
        }
        return first.uppercased() + text.dropFirst()
    }
}

/// How a tile stands against the find text.
public enum Filtered: Sendable, Hashable {
    /// It matches, is inside a match, or nothing is being found.
    case shown
    /// It holds matches: its fill steps back, its name stays readable.
    case holds
    /// Nothing in it matches.
    case out
}

/// How one tile should be drawn, resolved before painting so that painting
/// never has to look anything up.
public struct TileDeco: Sendable, Hashable {
    /// Base-space rectangle: the view transform is applied while painting.
    public var rect: Rect
    /// Nesting depth in this view; `0` is the first level.
    public var depth: Int
    /// What kind of data it is: the hue.
    public var category: DisktreeCore.Category
    /// In age mode, which `ageBuckets` entry it falls in.
    public var ageBucket: Int?
    /// Its space can be had back: hatched.
    public var reclaimable: Bool
    /// How it stands against the find text.
    public var filtered: Filtered
    /// Part of it could not be read: flagged in its corner.
    public var unreadable: Bool
    public var marked: Bool
    /// Inside another marked directory, so it goes with its parent.
    public var covered: Bool
    public var hovered: Bool
    public var selected: Bool

    public init(
        rect: Rect,
        depth: Int,
        category: DisktreeCore.Category,
        ageBucket: Int?,
        reclaimable: Bool,
        filtered: Filtered,
        unreadable: Bool,
        marked: Bool,
        covered: Bool,
        hovered: Bool,
        selected: Bool
    ) {
        self.rect = rect
        self.depth = depth
        self.category = category
        self.ageBucket = ageBucket
        self.reclaimable = reclaimable
        self.filtered = filtered
        self.unreadable = unreadable
        self.marked = marked
        self.covered = covered
        self.hovered = hovered
        self.selected = selected
    }
}

/// A tile's label, resolved for painting. (`TileLabel`, not `Label`:
/// SwiftUI has one.)
/// What a legend key stands for, and so what it picks out of the mosaic.
public enum LegendFocus: Sendable, Hashable {
    /// Space a known tool would make again: the hatched tiles.
    case reclaimable
    case kind(DisktreeCore.Category)
    /// An index into `ageBuckets`, in Age mode.
    case age(Int)
}

public struct TileLabel: Sendable, Hashable {
    public var text: String
    /// Base-space rectangle; the view transform is applied while painting.
    public var rect: Rect
    /// The band this label belongs in, when its tile reserved one. A
    /// parent's name goes in its own band, never over its children.
    public var header: Rect?
    /// Nesting depth in this view: the first level is set in bold.
    public var depth: Int
    /// Filtered out while typing: drawn quietly.
    public var dim: Bool
    public var marked: Bool
    public var sizeText: String
    /// A file's name: cut in the middle when it is too long for its tile,
    /// as Finder cuts one, so its extension still says what it is. A
    /// directory's name is cut at its end.
    public var isFile: Bool

    public init(
        text: String,
        rect: Rect,
        header: Rect?,
        depth: Int,
        dim: Bool,
        marked: Bool,
        sizeText: String,
        isFile: Bool = false
    ) {
        self.text = text
        self.rect = rect
        self.header = header
        self.depth = depth
        self.dim = dim
        self.marked = marked
        self.sizeText = sizeText
        self.isFile = isFile
    }
}

/// Everything the mosaic needs for one frame.
public struct Mosaic: Sendable, Hashable {
    public var tiles: [TileDeco]
    public var labels: [TileLabel]
    public var view: ViewTransform
    /// The directory drawn is marked, or inside a marked one: every tile
    /// goes with it. The legend says so once, and the tiles keep their
    /// kinds, tinted, rather than every one of them turning the marked
    /// colour, which read as an error over the whole screen.
    public var insideMark: Bool

    public init(
        tiles: [TileDeco] = [],
        labels: [TileLabel] = [],
        view: ViewTransform = .identity,
        insideMark: Bool = false
    ) {
        self.tiles = tiles
        self.labels = labels
        self.view = view
        self.insideMark = insideMark
    }
}

/// A direction for geometric selection movement.
public enum Direction: Sendable, Hashable {
    case left
    case right
    case up
    case down

    var isBackwards: Bool { self == .left || self == .up }

    /// Distance from `from` to `rect` along the axis, if `rect` lies that
    /// way. Half a point of overlap still counts as that way, so neighbours
    /// that share an edge after rounding are found.
    func gap(from: Rect, to rect: Rect) -> Double? {
        let epsilon = 0.5
        let gap =
            switch self {
            case .right: rect.x - from.right
            case .left: from.x - rect.right
            case .down: rect.y - from.bottom
            case .up: from.y - rect.bottom
            }
        return gap >= -epsilon ? max(gap, 0) : nil
    }

    /// How far off the direction's axis `rect` sits, so the nearest tile in
    /// the direction wins rather than any tile in that half-plane.
    func offset(from: Rect, to rect: Rect) -> Double {
        func overlap(
            _ aStart: Double,
            _ aEnd: Double,
            _ bStart: Double,
            _ bEnd: Double
        ) -> Double {
            max(min(aEnd, bEnd) - max(aStart, bStart), 0)
        }
        switch self {
        case .left, .right:
            let shared = overlap(from.y, from.bottom, rect.y, rect.bottom)
            return max(min(from.h, rect.h) - shared, 0)
        case .up, .down:
            let shared = overlap(from.x, from.right, rect.x, rect.right)
            return max(min(from.w, rect.w) - shared, 0)
        }
    }
}

/// A key press, in the dispatcher's vocabulary.
///
/// Named keys use the names the Rust dispatcher matched on — `space`,
/// `enter`, `escape`, `backspace`, `tab`, `left`, `right`, `up`, `down`,
/// `home`, `end` — and every other key is the character it types with shift
/// applied (`?`, `=`, `+`, `c`), so the bindings read the same in both.
public struct KeyStroke: Sendable, Hashable {
    public var key: String
    /// The text the key types, for the find field; `nil` for named keys.
    public var character: String?
    public var control: Bool
    public var shift: Bool
    public var command: Bool
    public var option: Bool

    public init(
        _ key: String,
        character: String? = nil,
        control: Bool = false,
        shift: Bool = false,
        command: Bool = false,
        option: Bool = false
    ) {
        self.key = key
        self.character = character
        self.control = control
        self.shift = shift
        self.command = command
        self.option = option
    }

    private static let named: Set<String> = [
        "space", "enter", "escape", "backspace", "tab", "left", "right", "up",
        "down", "home", "end",
    ]

    /// Parse the notation tests and `--keys` use: `space`, `c`, `?`,
    /// `ctrl-=`, `cmd-shift-g`, `ctrl--`. Modifier prefixes are peeled off
    /// one at a time, so a key that is itself `-` survives.
    public init?(parsing notation: String) {
        var rest = Substring(notation)
        var control = false
        var shift = false
        var command = false
        var option = false
        while true {
            if rest.hasPrefix("ctrl-") && rest.count > 5 {
                control = true
                rest = rest.dropFirst(5)
            } else if rest.hasPrefix("cmd-") && rest.count > 4 {
                command = true
                rest = rest.dropFirst(4)
            } else if rest.hasPrefix("shift-") && rest.count > 6 {
                shift = true
                rest = rest.dropFirst(6)
            } else if rest.hasPrefix("alt-") && rest.count > 4 {
                option = true
                rest = rest.dropFirst(4)
            } else {
                break
            }
        }
        guard !rest.isEmpty else { return nil }
        let key = String(rest)
        let isNamed = Self.named.contains(key)
        guard isNamed || key.count == 1 else { return nil }
        self.init(
            key,
            character: isNamed || control || command ? nil : key,
            control: control,
            shift: shift,
            command: command,
            option: option
        )
    }
}

/// Which mouse button went down.
public enum PointerButton: Sendable, Hashable {
    case left
    case middle
    case right
}

/// Modifier keys held during a click.
public struct PointerModifiers: Sendable, Hashable {
    public var command: Bool
    public var control: Bool
    public var shift: Bool
    public var option: Bool

    public init(
        command: Bool = false,
        control: Bool = false,
        shift: Bool = false,
        option: Bool = false
    ) {
        self.command = command
        self.control = control
        self.shift = shift
        self.option = option
    }
}
