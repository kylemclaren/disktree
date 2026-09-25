// Preferences: what the person chose in Settings, and what they tuned while
// looking, kept from one launch to the next.
//
// Two kinds live here. Settings are the defaults a launch starts from: how
// deep to draw, whether hidden files and apparent sizes count, whether to
// stay on one volume, which command the review copies, whether the side
// panel shows, what colour says. Some of those are also tuned by hand while
// looking — the depth (`[`, `]`), the colour (`t`), and, with no Settings
// control of their own, the panel's width and the interface zoom — and a
// relaunch should come back as they were left, so a change by hand is saved
// as it happens. One key per value: the Settings window and the key that
// tunes it edit the same thing, and neither can disagree with the other
// about what the next launch shows.
//
// The command line overrides for the run and saves nothing: `--depth 5`
// once is not a new habit. A scripted run (`--snapshot`, `--keys`) reads
// none of it either, so a script sees the app as it ships on every Mac, and
// a `]` it presses is not the person's choice.

import CoreGraphics
import DisktreeCore
import Foundation

/// Where preferences are kept: `UserDefaults` in the app. The tests keep
/// theirs in a dictionary, since a test must never write the person's own
/// defaults.
public protocol PreferenceStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: PreferenceStore {}

/// What a launch starts from, and what the person last tuned.
public struct Preferences: Sendable, Hashable {
    /// Levels drawn at once, `depthRange`.
    public var depth: Int
    public var includeHidden: Bool
    public var apparentSize: Bool
    /// Stay on the scanned root's volume.
    public var oneFilesystem: Bool
    /// What the review's command does: the Trash unless asked otherwise.
    public var commandStyle: CommandStyle
    /// Whether the side panel shows at launch; `p` hides it for the run.
    public var showPanel: Bool
    public var colorMode: ColorMode
    /// The side panel's width, in rem.
    public var panelRems: CGFloat
    /// The interface zoom: an index into `zoomSteps`.
    public var zoomStep: Int

    /// The app as it ships: every value the same as a launch with no
    /// preferences at all, and as the command line's own defaults.
    public init(
        depth: Int = 3,
        includeHidden: Bool = true,
        apparentSize: Bool = false,
        oneFilesystem: Bool = true,
        commandStyle: CommandStyle = .trash,
        showPanel: Bool = true,
        colorMode: ColorMode = .kind,
        panelRems: CGFloat = PanelSize.rems,
        zoomStep: Int = defaultZoomStep
    ) {
        self.depth = depth
        self.includeHidden = includeHidden
        self.apparentSize = apparentSize
        self.oneFilesystem = oneFilesystem
        self.commandStyle = commandStyle
        self.showPanel = showPanel
        self.colorMode = colorMode
        self.panelRems = panelRems
        self.zoomStep = zoomStep
    }

    /// The names the values are kept under. Public, so a Settings pane
    /// that binds a control straight to the defaults uses the same ones.
    public enum Key: String, Sendable, CaseIterable {
        case depth = "treemapDepth"
        case includeHidden = "includeHidden"
        case apparentSize = "apparentSize"
        case oneFilesystem = "oneFilesystem"
        case commandStyle = "commandStyle"
        case showPanel = "showPanel"
        case colorMode = "colorMode"
        case panelRems = "panelWidthRems"
        case zoomStep = "interfaceZoomStep"
    }

    /// Read what `store` keeps. A value that is missing, of the wrong type
    /// or out of range — written by an older version, or by hand with
    /// `defaults write` — falls back to the default rather than open the
    /// window on something impossible.
    public init(store: any PreferenceStore) {
        let shipped = Preferences()
        func value<Value>(_ key: Key, _ fallback: Value) -> Value {
            store.object(forKey: key.rawValue) as? Value ?? fallback
        }
        self.init(
            depth: value(.depth, shipped.depth),
            includeHidden: value(.includeHidden, shipped.includeHidden),
            apparentSize: value(.apparentSize, shipped.apparentSize),
            oneFilesystem: value(.oneFilesystem, shipped.oneFilesystem),
            commandStyle: CommandStyle(
                stored: value(.commandStyle, "")
            ) ?? shipped.commandStyle,
            showPanel: value(.showPanel, shipped.showPanel),
            colorMode: ColorMode(stored: value(.colorMode, ""))
                ?? shipped.colorMode,
            panelRems: CGFloat(
                value(.panelRems, Double(shipped.panelRems))
            ),
            zoomStep: value(.zoomStep, shipped.zoomStep)
        )
        self = validated()
    }

    /// Every value inside what the app can show: depth in `depthRange`, the
    /// zoom a step that exists, the panel between its limits.
    public func validated() -> Preferences {
        var valid = self
        valid.depth = min(
            max(depth, depthRange.lowerBound),
            depthRange.upperBound
        )
        if !zoomSteps.indices.contains(zoomStep) {
            valid.zoomStep = defaultZoomStep
        }
        valid.panelRems =
            panelRems.isFinite
            ? min(max(panelRems, PanelSize.minRems), PanelSize.maxRems)
            : PanelSize.rems
        return valid
    }

    /// Write the values that differ from `old` into `store`. Only those: a
    /// value the person never changed stays unwritten, so a later version
    /// that ships a better default gives it to them.
    public func write(to store: any PreferenceStore, changedFrom old: Self) {
        func write<Value: Equatable>(
            _ key: Key,
            _ path: KeyPath<Self, Value>,
            _ stored: (Value) -> Any
        ) {
            if self[keyPath: path] != old[keyPath: path] {
                store.set(stored(self[keyPath: path]), forKey: key.rawValue)
            }
        }
        write(.depth, \.depth) { $0 }
        write(.includeHidden, \.includeHidden) { $0 }
        write(.apparentSize, \.apparentSize) { $0 }
        write(.oneFilesystem, \.oneFilesystem) { $0 }
        write(.commandStyle, \.commandStyle) { $0.stored }
        write(.showPanel, \.showPanel) { $0 }
        write(.colorMode, \.colorMode) { $0.stored }
        write(.panelRems, \.panelRems) { Double($0) }
        write(.zoomStep, \.zoomStep) { $0 }
    }

    /// The scan options a launch starts from, before the command line has
    /// its say: the three the Settings window has a control for, and the
    /// rest as they ship.
    public var scanOptions: ScanOptions {
        ScanOptions(
            apparentSize: apparentSize,
            includeHidden: includeHidden,
            oneFilesystem: oneFilesystem
        )
    }
}

extension CommandStyle {
    /// How the choice is kept: a word, so the defaults stay readable.
    var stored: String {
        switch self {
        case .trash: "trash"
        case .remove: "remove"
        }
    }

    init?(stored: String) {
        switch stored {
        case "trash": self = .trash
        case "remove": self = .remove
        default: return nil
        }
    }
}

extension ColorMode {
    /// How the choice is kept: a word, so the defaults stay readable.
    var stored: String {
        switch self {
        case .kind: "kind"
        case .age: "age"
        }
    }

    init?(stored: String) {
        switch stored {
        case "kind": self = .kind
        case "age": self = .age
        default: return nil
        }
    }
}
