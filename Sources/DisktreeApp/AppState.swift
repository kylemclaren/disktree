// Application state and every mutation the UI can perform.
//
// The screens are pure readings of this state; all the decisions — what is
// selected, what a mark means, what a key does, when to re-scan — live here
// so they can be reasoned about in one place, and tested without a window.
//
// `@Observable`: a SwiftUI view or the treemap's `NSView` re-renders when a
// property it read changes, which replaces GPUI's explicit `cx.notify()`.
// Memo fields that change while drawing are `@ObservationIgnored`, or a
// frame would schedule the next one forever.

import AppKit
import CoreGraphics
import DisktreeCore
import Foundation
import Observation
import System

/// Layout for one (crumbs, area, options, filter) combination.
struct LayoutCache {
    var key: LayoutKey
    var tiles: [Tile]
}

struct LayoutKey: Hashable {
    var crumbs: [Int]
    var width: Double
    var height: Double
    var options: LayoutOptions
    /// Bumped whenever the applied filter changes.
    var filter: Int
}

/// Everything the app knows and everything it can do.
@MainActor
@Observable
public final class AppState {
    // MARK: What was scanned

    /// The directory the tree was scanned from.
    public var rootPath: FilePath
    public let home: FilePath?
    public var options: ScanOptions
    public var tree: Node? {
        didSet { treeGeneration &+= 1 }
    }
    /// Bumped whenever another tree takes the screen, so a re-ranking of the
    /// one before is dropped when it lands.
    @ObservationIgnored var treeGeneration = 0
    /// The metric the tree is being re-ranked by, off the main actor, while
    /// the one on screen keeps its order and `options.metric`: what the
    /// mode picker shows meanwhile.
    public internal(set) var pendingMetric: Metric?
    /// Bumped with every switch of the metric: only the newest re-ranking
    /// lands.
    @ObservationIgnored var rankEpoch = 0
    /// The most entries a tree may hold and still be re-ranked on the main
    /// actor, in one go. A home directory holds millions, and sorting every
    /// directory of those takes a quarter of a second: off the main actor
    /// then, with the old order on screen until the new one is ready.
    @ObservationIgnored var rankInPlaceLimit: UInt64 = 100_000
    @ObservationIgnored var scan: ScanHandle?
    /// The metric the walk in flight orders its tree by. `t` may switch
    /// `options.metric` while it is out, and the tree that lands has to be
    /// ranked by the one on screen.
    @ObservationIgnored var scanMetric: Metric = .bytes
    public internal(set) var scanEpoch = 0
    public var progress = ScanSnapshot()
    /// What the walk that measured the tree on screen could not read, as
    /// its progress said when it landed: a widening reuses the tree, and
    /// reports this as its own. `nil` for a tree no walk here measured.
    @ObservationIgnored var treeUnreadable: Unreadable?
    public var scanError: String?
    /// Where the scan in flight is rooted. Differs from `rootPath` while
    /// widening, when the old tree stays on screen until the wider one lands.
    public var scanRoot: FilePath
    public var scanStarted: ContinuousClock.Instant?
    public var scanElapsed: Duration?
    /// Unix seconds when the tree landed: the "now" ages are measured from.
    public var scannedAt: Int64

    // MARK: What is on screen

    public var screen: Screen = .explore
    /// Path from the scanned root to the directory currently drawn.
    public var crumbs: [Int] = []
    public var selected: [Int]?
    public var hovered: [Int]?
    /// The pointer moved more recently than the keyboard navigated. Then the
    /// tile under the pointer is what Space, X and Enter act on; after an
    /// arrow or Tab it is the keyboard selection again.
    public var pointerActive = false
    /// The directory the current click sequence opened. A double click
    /// arrives as a click, which may already have opened the selection,
    /// then a second one: that one must not open what now lies under the
    /// pointer as well.
    @ObservationIgnored var clickOpened: [Int]?
    public var view = ViewTransform.identity
    /// The in-flight layout transition, if a level was just entered or left.
    public var transition: LayoutTransition?
    public var layoutOptions: LayoutOptions {
        // Depth is tuned by hand, and a relaunch comes back to it.
        didSet { remember { $0.depth = layoutOptions.maxDepth } }
    }
    @ObservationIgnored var cache: LayoutCache?
    /// Pointer position in treemap-local points, for hit-testing and the
    /// tooltip.
    public var pointer: CGPoint?
    /// The merged "+N more" tail under the pointer, which `hovered` never
    /// names: it is nothing to act on, but the tooltip can say what it
    /// stands for.
    public internal(set) var hoveredTail: HoveredTail?
    /// The pointer came to a new tile a moment ago: its card waits until
    /// the pointer has rested there (`AppState.cardDelay`), so a sweep
    /// across the mosaic is not a card jumping from tile to tile.
    public internal(set) var cardHeld = false
    @ObservationIgnored var cardRelease: Timer?
    /// The treemap's size in points, recorded by the treemap view whenever
    /// its frame changes.
    public var treemapSize: CGSize = .zero
    /// Interface zoom: an index into `zoomSteps`. Every size in the app is
    /// in rem, so this one number scales the whole interface.
    public var zoomStep: Int = defaultZoomStep {
        didSet {
            remember { $0.zoomStep = zoomStep }
            // The bands above the mosaic are in rem: it moved under the
            // pointer, which says where it is only when it moves again.
            if zoomStep != oldValue {
                forgetHover()
            }
        }
    }
    /// The window's rem in points: 16 at the default zoom.
    public var rem: CGFloat { baseRem * zoomSteps[zoomStep] }
    public var showHelp = false
    public var showSelection = true {
        // The mosaic narrows or widens under the pointer: the tile it was
        // on is no longer the one under it, until it moves again.
        didSet {
            if showSelection != oldValue {
                forgetHover()
            }
        }
    }
    /// The legend key under the pointer: its kind keeps its colour in the
    /// mosaic and every other tile steps back, as a chart's legend picks
    /// out its series.
    public var legendFocus: LegendFocus?
    public var colorMode: ColorMode = .kind {
        didSet { remember { $0.colorMode = colorMode } }
    }
    /// The side panel's width, in rem: where its inspector column was left
    /// (`keepPanelWidth`). Kept for the next launch, however it was set.
    public var panelRems: CGFloat = PanelSize.rems {
        didSet { remember { $0.panelRems = panelRems } }
    }

    // MARK: Zoom gestures

    /// The stop the zoom rests against, and how hard a pinch presses on it.
    @ObservationIgnored var detent: ZoomDetent?
    /// This pinch has changed level once already: it goes on magnifying,
    /// but it cannot go through another level until the fingers lift.
    @ObservationIgnored var pinchSpent = false
    /// Where the last smart zoom went, and where from: the same tap again
    /// goes back.
    @ObservationIgnored var smartZoomed: SmartZoom?

    // MARK: Marks, and handing them over

    public var marks = Marks()
    /// Which command the review screen copies: `trash` unless the user asks
    /// for `rm`.
    public var commandStyle: CommandStyle = .trash
    /// Marked paths that are no longer on disk: removed in Finder or by the
    /// copied command since they were marked. Checked on a timer and when
    /// the app comes back to the front.
    public var gone: Set<FilePath> = []
    public var space: SpaceInfo?
    /// Free space when the first mark was made: what "freed so far" is
    /// measured from, with `statfs`, never from the marked sum (Invariant 9).
    /// Carried over, gain and all, when the root moves to another volume.
    public var spaceBaseline: SpaceInfo?
    /// Every mark was seen gone, and the notice said what that was worth;
    /// the walk in flight is the rescan the hand-over is owed. Until it
    /// lands, nothing says it again.
    @ObservationIgnored var handOverReported = false
    public var notice: Notice?
    /// The plan and its command, kept while nothing they are made of
    /// changes: views ask for them from `body`, and each fresh plan
    /// `lstat`s and `statfs`es every mark on the main actor.
    @ObservationIgnored var handOverMemo: HandOverMemo?

    // MARK: What floats above the screens

    /// A passing confirmation — the command was copied, Finder was shown the
    /// marks — shown over the treemap until `toastExpiry` or Escape. What
    /// lasts, a problem above all, stays on the notice line instead.
    public internal(set) var toast: Notice?
    /// When the toast goes by itself.
    @ObservationIgnored public internal(set) var toastExpiry:
        ContinuousClock.Instant?
    /// Bumped with every toast, so the same words twice still arrive as a
    /// new one rather than as nothing happening.
    public internal(set) var toastSerial = 0
    /// What Quick Look previews while its panel is up; `nil` when it is not.
    /// The view shows the panel for it, and sets this back to `nil` when the
    /// panel is closed from the panel itself.
    public var quickLookTarget: FilePath?

    // MARK: Find

    public var find = ""
    public var findOpen = false
    /// What the find text matches in the directory on screen, recomputed on
    /// every keystroke. While typing it only dims what does not match.
    public var matches: Matches?
    /// Enter was pressed: the mosaic lays out only the matches.
    public var filterApplied = false
    @ObservationIgnored var filterEpoch = 0
    /// Bumped per keystroke; only the newest search's result is kept.
    @ObservationIgnored var findEpoch = 0
    /// A search is running off the main actor.
    public var finding = false
    /// Enter was pressed before the search finished: apply on arrival.
    @ObservationIgnored var applyPending = false

    // MARK: What the panel knows

    /// The largest things worth clearing, recomputed when a scan lands.
    public var insights: [Candidate] = []
    /// What git knows about each checkout that has been selected; `nil` once
    /// asked and found not to be one.
    public var git: [FilePath: GitState?] = [:]
    @ObservationIgnored var gitPending: Set<FilePath> = []
    /// The device the scanned volume is mounted from.
    public var device: String?
    /// The filesystem the scanned root was on when it was chosen: a look at
    /// the disk that finds the root on another one, or on none, is a volume
    /// that went away, not marks that were removed (Invariant 9).
    @ObservationIgnored var rootVolume: VolumeIdentity?
    /// The scanned volume is not mounted: the marks on it are kept, and
    /// nothing is measured, until it is back.
    @ObservationIgnored var volumeAway = false
    /// The volume's name, as Finder shows it.
    public var volumeName: String?
    /// The top of the disk the home directory lives on: what "Whole disk"
    /// scans.
    public var diskRoot: FilePath?

    // MARK: Hooks for the shell

    /// Asked to quit (`q`). The app shell terminates; tests record it.
    @ObservationIgnored public var onQuit: (() -> Void)?
    /// Where a copied command goes: the general pasteboard. Tests capture it
    /// instead.
    @ObservationIgnored public var copyToPasteboard: (String) -> Void = {
        text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    /// Show these paths selected in Finder. Tests capture them instead.
    @ObservationIgnored public var showInFinder: ([FilePath]) -> Void = {
        paths in
        NSWorkspace.shared.activateFileViewerSelecting(
            paths.map { URL(filePath: $0.string) }
        )
    }
    @ObservationIgnored var tickers: [Task<Void, Never>] = []

    // MARK: Preferences

    /// What the Settings window shows: the saved preferences, with what the
    /// person tuned since launch. The run may differ where the command line
    /// overrode them.
    public internal(set) var preferences = Preferences()
    /// Where a change is saved; `nil` saves nothing, which is what tests and
    /// scripted runs want. The shell sets it with `adopt(_:store:)`.
    @ObservationIgnored public internal(set) var preferenceStore:
        (any PreferenceStore)?

    /// Scan `root` and show it. `startScanning: false` builds the state
    /// without starting the walk or the tickers, for tests that drive them
    /// by hand.
    public init(
        root: FilePath,
        options: ScanOptions,
        depth: Int,
        startScanning: Bool = true
    ) {
        let home = defaultHome()
        self.rootPath = root
        self.home = home
        self.options = options
        self.scanRoot = root
        self.scannedAt = nowSeconds()
        self.layoutOptions = LayoutOptions(maxDepth: min(max(depth, 1), 6))
        self.space = try? spaceInfo(root)
        self.device = deviceFor(root)
        self.rootVolume = volumeIdentity(root)
        self.volumeName = volumeNameFor(root)
        self.diskRoot = volumeRootFor(home ?? root)
        if startScanning {
            startScan()
            startSpaceTicker()
        }
    }

    /// Build a view over a tree that is already known, without starting a
    /// walk: what tests hand the screens instead of waiting on a real one.
    public convenience init(
        root: FilePath,
        tree: Node,
        options: ScanOptions,
        depth: Int
    ) {
        self.init(
            root: root,
            options: options,
            depth: depth,
            startScanning: false
        )
        marks.refresh(rootPath: root, root: tree)
        self.tree = tree
        cache = nil
        refreshInsights()
        selectLargest()
    }

    // `isolated deinit` would let this cancel the tickers directly; they hold
    // the state weakly instead, so they end on their own once it is gone.
}

/// Now, in Unix seconds.
public func nowSeconds() -> Int64 {
    Int64(Date().timeIntervalSince1970)
}
