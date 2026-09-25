import AppKit
import DisktreeCore
import Foundation
import SwiftUI
import System
import Testing

@testable import DisktreeApp

// The explore chrome's polish, drawn for real: the toast, the breakdown the
// legend opens, the Full Disk Access sheet, a folder dragged over the
// window, the bars that fold what does not fit, glass and Reduce Motion.
// Each is drawn in both appearances, as the rest of the chrome is, and the
// sums the breakdown makes are checked against the tree they come from.
//
// Nothing here asks macOS about Full Disk Access for real: the sheet is
// handed its answer, and the probe is tried on files made for it.

private let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

/// A frame that drew something worth the name.
private func expectDrawn(
    _ frame: ExploreFrame,
    _ comment: Comment,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(frame.drawn > 500, comment, sourceLocation: sourceLocation)
    #expect(frame.colours > 4, comment, sourceLocation: sourceLocation)
}

// MARK: - The toast

@MainActor
@Test func aToastConfirmsOverEveryScreen() throws {
    let fixture = try ExploreFixture()
    for appearance in appearances {
        for screen in [Screen.explore, .review] {
            let state = try exploreState(fixture)
            state.screen = screen
            state.showToast(
                Notice(
                    "Copied: trash for 3 items, 12.4 GiB \u{2014} paste it "
                        + "into Terminal",
                    status: .success
                )
            )
            let frame = try drawExplore(
                state,
                appearance: appearance,
                name: "toast-\(screen)-\(appearance.rawValue)"
            )
            expectDrawn(frame, "\(screen) \(appearance.rawValue)")
            #expect(frame.identifiers.contains("toast"), "\(screen)")
        }
    }
}

@MainActor
@Test func aToastGoesWhenItsTimeIsUpOrEscapeIsPressed() throws {
    let fixture = try ExploreFixture()
    let state = try exploreState(fixture)
    state.showToast(Notice("Revealed 3 items in Finder", status: .success))
    var frame = try drawExplore(state, appearance: .darkAqua, name: "toast-up")
    #expect(frame.identifiers.contains("toast"))
    // Escape goes to the toast before the screen.
    #expect(state.handleKey(KeyStroke("escape")))
    frame = try drawExplore(state, appearance: .darkAqua, name: "toast-gone")
    #expect(!frame.identifiers.contains("toast"))
    // And a toast past its time is not drawn.
    let start = ContinuousClock.now
    state.showToast(Notice("Copied ~/junk", status: .success), now: start)
    state.expireToast(now: start + AppState.toastDuration)
    frame = try drawExplore(state, appearance: .darkAqua, name: "toast-late")
    #expect(!frame.identifiers.contains("toast"))
}

@Test func everyToastHasASign() {
    let symbols = [Status.neutral, .success, .warning, .error].map(
        Toast.symbol
    )
    #expect(Set(symbols).count == 4)
    for symbol in symbols {
        #expect(
            NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                != nil, "\(symbol)")
    }
}

@Test func aToastWithNowhereGivenSitsClearOfTheFoot() {
    let room = ToastLayer.fallback(
        in: CGSize(width: 1_440, height: 900),
        rem: baseRem
    )
    #expect(room.minX == 0 && room.minY == 0 && room.width == 1_440)
    #expect(room.height < 900 && room.height > 700)
    // A window shorter than the foot keeps nothing to sit in, rather than
    // a negative room.
    let tiny = ToastLayer.fallback(in: CGSize(width: 100, height: 20), rem: 16)
    #expect(tiny.height == 0)
}

// MARK: - The breakdown

@MainActor
@Test func theBreakdownAddsUpToTheFolderDrawn() throws {
    let fixture = try ExploreFixture()
    let state = try exploreState(fixture)
    let tree = try #require(state.tree)
    for metric in [Metric.bytes, .files] {
        let breakdown = try #require(
            Breakdown.measure(tree, metric: metric, now: state.scannedAt)
        )
        #expect(breakdown.total == tree.value(metric))
        // Every kind and every age: each file counted once, in both.
        #expect(breakdown.kinds.reduce(0, +) == breakdown.total, "\(metric)")
        #expect(
            breakdown.ages.reduce(0, +) + breakdown.undated == breakdown.total,
            "\(metric)"
        )
    }
    let bytes = try #require(
        Breakdown.measure(tree, metric: .bytes, now: state.scannedAt)
    )
    // `.cache` is a cache, and what can be had back; the rest is nothing
    // the tables know.
    let kinds = DisktreeCore.Category.allCases
    let cache = try #require(kinds.firstIndex(of: .cache))
    let other = try #require(kinds.firstIndex(of: .other))
    #expect(bytes.kinds[cache] == 300_000)
    #expect(bytes.kinds[other] == 301_000)
    #expect(bytes.reclaimable == 300_000)
    // Written a moment ago: all of it this week.
    #expect(bytes.ages[0] == bytes.total)
}

@MainActor
@Test func theBreakdownOfAFolderInsideACacheIsAllReclaimable() throws {
    let fixture = try ExploreFixture()
    let state = try exploreState(fixture)
    let cache = try childCrumbs(state, [], ".cache")
    let node = try #require(state.node(at: cache))
    let breakdown = try #require(
        Breakdown.measure(node, metric: .bytes, now: state.scannedAt)
    )
    #expect(breakdown.total == 300_000)
    #expect(breakdown.reclaimable == breakdown.total)
}

@Test func aCancelledBreakdownStops() {
    var children: [Node] = []
    for index in 0..<40_000 {
        children.append(.entry("f\(index)", kind: .file, bytes: 1))
    }
    var root = Node.directory("wide", children: children)
    aggregate(&root, metric: .bytes)
    #expect(Breakdown.measure(root, metric: .bytes, now: 0) != nil)
    #expect(
        Breakdown.measure(root, metric: .bytes, now: 0) { true } == nil
    )
    // Undated files: no write time was read for them.
    #expect(
        Breakdown.measure(root, metric: .bytes, now: 0)?.undated == 40_000
    )
}

@Test func theChartListsKindsLargestFirstAndAgesInTheirOrder() {
    let kinds = DisktreeCore.Category.allCases
    var values = Array(repeating: UInt64(0), count: kinds.count)
    values[kinds.firstIndex(of: .code) ?? 0] = 10
    values[kinds.firstIndex(of: .cache) ?? 0] = 30
    values[kinds.firstIndex(of: .git) ?? 0] = 10
    let breakdown = Breakdown(
        kinds: values,
        ages: [0, 5, 0, 7, 0],
        undated: 2,
        reclaimable: 30,
        total: 50
    )
    let rows = breakdown.rows(.kind, theme: .dark).map(\.label)
    // Equal ones keep the legend's order: code before git.
    #expect(rows == ["Cache", "Code", "Git"])
    let ages = breakdown.rows(.age, theme: .dark).map(\.label)
    #expect(ages == [ageBuckets[1].label, ageBuckets[3].label, "Unknown"])
}

@MainActor
@Test func theBreakdownDrawsInBothAppearances() throws {
    let fixture = try ExploreFixture()
    let state = try exploreState(fixture)
    let tree = try #require(state.tree)
    let breakdown = try #require(
        Breakdown.measure(tree, metric: .bytes, now: state.scannedAt)
    )
    for (theme, name) in [(Theme.light, "light"), (Theme.dark, "dark")] {
        for mode in [ColorMode.kind, .age] {
            let frame = try drawAlone(
                BreakdownChart(
                    breakdown: breakdown,
                    mode: mode,
                    metric: .bytes,
                    place: "~/Dev/disktree"
                ),
                appearance: theme.isDark ? .darkAqua : .aqua,
                theme: theme,
                name: "breakdown-\(mode)-\(name)"
            )
            expectDrawn(frame, "\(mode) \(name)")
            #expect(frame.identifiers.contains("kind-breakdown"))
        }
    }
    // Measuring, and with nothing in it: still drawn, never a crash.
    let empty = Breakdown(
        kinds: Array(repeating: 0, count: DisktreeCore.Category.allCases.count),
        ages: Array(repeating: 0, count: ageBuckets.count),
        undated: 0,
        reclaimable: 0,
        total: 0
    )
    let frame = try drawAlone(
        BreakdownChart(
            breakdown: empty,
            mode: .kind,
            metric: .files,
            place: "~",
            measuring: true
        ),
        appearance: .darkAqua,
        theme: .dark,
        name: "breakdown-empty"
    )
    #expect(frame.identifiers.contains("kind-breakdown"))
}

@MainActor
@Test func thePopoverMeasuresTheFolderDrawnOnItsOwn() async throws {
    // The popover's content, hosted as its window hosts it: it starts by
    // adding up, off the main actor, and lands on the chart.
    let fixture = try ExploreFixture()
    let state = try exploreState(fixture)
    let drawn = DrawnIdentifiers()
    let host = NSHostingView(
        rootView: KindBreakdown(state: state)
            .environment(\.theme, Theme.dark)
            .onPreferenceChange(ChromeIdentifiers.self) { identifiers in
                MainActor.assumeIsolated {
                    drawn.all = Set(identifiers)
                }
            }
    )
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { closeWindow(window) }
    // A fixture this small is measured in a moment.
    for _ in 0..<200 where !drawn.all.contains("kind-breakdown") {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(drawn.all.contains("kind-breakdown"))
}

@MainActor
@Test func theLegendIsTheWayToTheBreakdown() throws {
    let fixture = try ExploreFixture()
    for appearance in appearances {
        let state = try exploreState(fixture)
        let frame = try drawExplore(
            state,
            appearance: appearance,
            name: "legend-\(appearance.rawValue)"
        )
        #expect(frame.identifiers.contains("legend"))
    }
}

// MARK: - Full Disk Access

@Test func accessIsOfferedForTheHomeDirectoryAndAboveOnly() {
    let home: FilePath = "/Users/tobi"
    #expect(FullDiskAccess.offers(root: "/Users/tobi", home: home))
    #expect(FullDiskAccess.offers(root: "/Users", home: home))
    #expect(FullDiskAccess.offers(root: "/", home: home))
    // A project folder holds none of what privacy closes.
    #expect(!FullDiskAccess.offers(root: "/Users/tobi/Dev", home: home))
    // Component-wise: a sibling that shares a prefix is not above it.
    #expect(!FullDiskAccess.offers(root: "/Users/to", home: home))
    #expect(!FullDiskAccess.offers(root: "/Users/tobi", home: nil))
    #expect(
        FullDiskAccess.witness(home: home)
            == "/Users/tobi/Library/Application Support/com.apple.TCC/TCC.db"
    )
}

@Test func theProbeTellsGrantedFromDeniedFromUnknown() throws {
    // A file of its own, never the real one: a test must not look into
    // ~/Library.
    let base = FileManager.default.temporaryDirectory
        .appending(path: "disktree-access-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: base,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: base) }
    let readable = base.appending(path: "open.db")
    let closed = base.appending(path: "closed.db")
    try Data("x".utf8).write(to: readable)
    try Data("x".utf8).write(to: closed)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o000],
        ofItemAtPath: closed.path
    )
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: closed.path
        )
    }
    #expect(FullDiskAccess.probe(FilePath(readable.path)) == .granted)
    #expect(FullDiskAccess.probe(FilePath(closed.path)) == .denied)
    #expect(
        FullDiskAccess.probe(FilePath(base.appending(path: "none").path))
            == .unknown
    )
}

@MainActor
@Test func theAccessSheetDrawsBeforeAndAfterTheGrant() throws {
    for (theme, name) in [(Theme.light, "light"), (Theme.dark, "dark")] {
        for access in [FullDiskAccess.Access.denied, .granted] {
            let frame = try drawAlone(
                FullDiskAccessSheet(
                    access: access,
                    check: { access },
                    openSettings: {},
                    scanAgain: {},
                    skip: {}
                ),
                appearance: theme.isDark ? .darkAqua : .aqua,
                theme: theme,
                name: "access-\(access)-\(name)"
            )
            expectDrawn(frame, "\(access) \(name)")
            #expect(frame.identifiers.contains("full-disk-access"))
            #expect(frame.identifiers.contains("access-skip"))
            let main = access == .granted ? "access-scan" : "access-open"
            #expect(frame.identifiers.contains(main), "\(access)")
        }
    }
}

@Test func onlyAPersonsRunIsAskedAndOnlyOnce() {
    let home: FilePath = "/Users/tobi"
    #expect(
        FullDiskAccess.asks(
            answered: false,
            remembers: true,
            root: home,
            home: home
        )
    )
    // Answered either way: never again.
    #expect(
        !FullDiskAccess.asks(
            answered: true,
            remembers: true,
            root: home,
            home: home
        )
    )
    // A script or a test keeps no answer, so it is never asked.
    #expect(
        !FullDiskAccess.asks(
            answered: false,
            remembers: false,
            root: "/",
            home: home
        )
    )
    #expect(
        !FullDiskAccess.asks(
            answered: false,
            remembers: true,
            root: "/Users/tobi/Dev",
            home: home
        )
    )
}

// MARK: - A folder dragged over the window

@MainActor
@Test func aFolderDraggedOverTheWindowIsOfferedAScan() throws {
    for (theme, name) in [(Theme.light, "light"), (Theme.dark, "dark")] {
        let frame = try drawAlone(
            DropHighlight().frame(width: 800, height: 500),
            appearance: theme.isDark ? .darkAqua : .aqua,
            theme: theme,
            width: 800,
            name: "drop-\(name)"
        )
        expectDrawn(frame, "\(name)")
        #expect(frame.identifiers.contains("drop-highlight"))
    }
}

@MainActor
@Test func aDroppedFolderIsScannedAndAFileIsRefused() throws {
    let fixture = try ExploreFixture()
    let state = try exploreState(fixture)
    defer { state.scan?.cancel() }
    let file = URL(filePath: fixture.root.appending("keep/notes.txt").string)
    #expect(!RootView.accepts([file], state: state))
    #expect(state.rootPath == fixture.root)
    let folder = URL(filePath: fixture.root.appending("junk").string)
    // A tile of this window dragged out and let go over it is not a folder
    // brought to it: refused, and nothing is scanned.
    DropHighlight.ownDrag = true
    #expect(!RootView.accepts([folder], state: state))
    #expect(state.rootPath == fixture.root)
    DropHighlight.ownDrag = false
    // Nor is a marked folder, a row of the review on its way to the Trash.
    let junk = try #require(state.crumbs(for: fixture.root.appending("junk")))
    #expect(state.toggleMark(junk))
    #expect(!RootView.accepts([folder], state: state))
    #expect(state.rootPath == fixture.root)
    state.clearMarks()
    #expect(RootView.accepts([file, folder], state: state))
    #expect(state.rootPath == fixture.root.appending("junk"))
}

// MARK: - What folds when room runs short

@MainActor
@Test func theSwitchesFoldOnlyWhenTheToolbarIsShortOfRoom() throws {
    let fixture = try ExploreFixture()
    for appearance in appearances {
        // Into junk: a short title, so a wide window has room for every
        // switch side by side.
        let state = try exploreState(fixture)
        let junk = try childCrumbs(state, [], "junk")
        state.crumbs = junk
        var frame = try drawExplore(
            state,
            appearance: appearance,
            name: "switches-wide-\(appearance.rawValue)"
        )
        for identifier in ["setting-hidden", "setting-apparent", "depth"] {
            #expect(frame.identifiers.contains(identifier), "\(identifier)")
        }
        #expect(!frame.identifiers.contains("view-options"))
        // The narrowest window: they fold into one menu, and the path
        // still says where you are, rather than any of it overflowing.
        frame = try drawExplore(
            state,
            appearance: appearance,
            width: 900,
            height: 600,
            name: "switches-narrow-\(appearance.rawValue)"
        )
        #expect(frame.identifiers.contains("view-options"))
        #expect(!frame.identifiers.contains("setting-hidden"))
        #expect(frame.identifiers.contains("mode-choice"))
        #expect(frame.identifiers.contains("panel-toggle"))
        let steps = state.breadcrumbs()
        #expect(frame.identifiers.contains("crumb-\(steps.count - 1)"))
    }
}

@MainActor
@Test func theKeyBarKeepsItsWayToEveryKey() throws {
    let fixture = try ExploreFixture()
    for step in [defaultZoomStep, zoomSteps.count - 1] {
        let state = try exploreState(fixture)
        state.zoomStep = step
        let frame = try drawExplore(
            state,
            appearance: .darkAqua,
            width: 900,
            height: 600,
            name: "keybar-\(step)"
        )
        #expect(frame.identifiers.contains("all-keys"), "zoom \(step)")
        #expect(frame.identifiers.contains("scan-summary"), "zoom \(step)")
    }
}

// MARK: - Floating surfaces and motion

@MainActor
@Test func whatFloatsDrawsAsGlassAndAsItsFallback() throws {
    // Glass only shows on screen; an offscreen window draws what is on it,
    // and must not crash either way.
    let fixture = try ExploreFixture()
    for glass in [true, false] {
        for appearance in appearances {
            let state = try exploreState(fixture)
            let junk = try childCrumbs(state, [], "junk")
            state.hovered = junk
            state.pointer = CGPoint(x: 300, y: 200)
            state.showToast(Notice("Copied ~/junk", status: .success))
            var frame = try drawExplore(
                state,
                appearance: appearance,
                glass: glass,
                name: "glass-\(glass)-\(appearance.rawValue)"
            )
            #expect(frame.identifiers.contains("toast"))
            if state.node(at: junk) != nil {
                #expect(frame.identifiers.contains("cursor-tooltip"))
            }
            state.showHelp = true
            frame = try drawExplore(
                state,
                appearance: appearance,
                glass: glass,
                name: "glass-help-\(glass)-\(appearance.rawValue)"
            )
            #expect(frame.identifiers.contains("help-overlay"))
        }
    }
}

@MainActor
@Test func reducedMotionDrawsEveryStateAlike() throws {
    let fixture = try ExploreFixture()
    let state = try exploreState(fixture)
    state.showToast(Notice("Copied ~/junk", status: .success))
    state.notice = Notice("mark something first", status: .warning)
    var frame = try drawExplore(
        state,
        appearance: .darkAqua,
        width: 820,
        height: 600,
        reduceMotion: true,
        name: "reduced"
    )
    expectDrawn(frame, "reduced")
    #expect(frame.identifiers.contains("toast"))
    #expect(frame.identifiers.contains("explore-notice"))
    state.showHelp = true
    state.colorMode = .age
    frame = try drawExplore(
        state,
        appearance: .aqua,
        reduceMotion: true,
        name: "reduced-help"
    )
    #expect(frame.identifiers.contains("help-overlay"))
}

@MainActor
@Test func withMotionReducedThePanelOnlyFades() throws {
    // `p` with Reduce Motion on: the panel fades in, and the row over the
    // mosaic is where it ends up from the first frame, rather than sliding
    // across under it. Drawn 30 ms in, the mosaic's side of the window is
    // already the frame it settles on.
    let fixture = try ExploreFixture()
    for reduced in [true, false] {
        let state = try exploreState(fixture)
        state.showSelection = false
        let live = LiveWindow(
            ExploreView(state: state)
                .environment(\.theme, Theme.dark)
                .environment(\.rem, baseRem)
                .environment(\._accessibilityReduceMotion, reduced),
            width: 1_440,
            height: 900
        )
        defer { live.close() }
        let start = ContinuousClock.now
        state.showSelection = true
        live.run(for: .milliseconds(30))
        let early = try live.draw()
        let elapsed = start.duration(to: .now)
        live.run(for: .milliseconds(600))
        let settled = try live.draw()
        // The top of the mosaic's side: the legend row and the tiles'
        // headers, well clear of where the panel fades in.
        let moved = try differingPixels(
            early,
            settled,
            in: CGRect(x: 0, y: 0, width: 900, height: 450),
            points: 1_440
        )
        if reduced {
            #expect(moved == 0)
        } else if elapsed < .milliseconds(120) {
            // The same frame with motion: still on its way, so the frame
            // above could have seen it.
            #expect(moved > 0)
        }
    }
}

/// A breakdown to be replaced while the chart shows it.
@MainActor @Observable
private final class ShownBreakdown {
    var breakdown: Breakdown

    init(_ breakdown: Breakdown) {
        self.breakdown = breakdown
    }
}

private struct ShownChart: View {
    let shown: ShownBreakdown

    var body: some View {
        BreakdownChart(
            breakdown: shown.breakdown,
            mode: .kind,
            metric: .bytes,
            place: "~/Dev"
        )
    }
}

@MainActor
@Test func withMotionReducedTheBarsAreSimplyNew() throws {
    // Two breakdowns of the same total, split differently: with Reduce
    // Motion on, the bars are at their new lengths from the first frame.
    let kinds = DisktreeCore.Category.allCases
    func breakdown(cache: UInt64, code: UInt64) -> Breakdown {
        var values = Array(repeating: UInt64(0), count: kinds.count)
        values[kinds.firstIndex(of: .cache) ?? 0] = cache
        values[kinds.firstIndex(of: .code) ?? 0] = code
        return Breakdown(
            kinds: values,
            ages: [cache + code, 0, 0, 0, 0],
            undated: 0,
            reclaimable: cache,
            total: cache + code
        )
    }
    for reduced in [true, false] {
        let shown = ShownBreakdown(breakdown(cache: 30_000, code: 20_000))
        let live = LiveWindow(
            ShownChart(shown: shown)
                .environment(\.theme, Theme.dark)
                .environment(\.rem, baseRem)
                .environment(\._accessibilityReduceMotion, reduced),
            width: 400,
            height: 240
        )
        defer { live.close() }
        let start = ContinuousClock.now
        shown.breakdown = breakdown(cache: 26_000, code: 24_000)
        live.run(for: .milliseconds(30))
        let early = try live.draw()
        let elapsed = start.duration(to: .now)
        live.run(for: .milliseconds(600))
        let settled = try live.draw()
        let moved = try differingPixels(
            early,
            settled,
            in: CGRect(x: 0, y: 0, width: 400, height: 240),
            points: 400
        )
        if reduced {
            #expect(moved == 0)
        } else if elapsed < .milliseconds(120) {
            #expect(moved > 0)
        }
    }
}

// MARK: - The tooltip over a merged tail

@MainActor
@Test func aMergedTailSaysWhatItStandsFor() throws {
    // Enough small files that the layout merges the smallest of them.
    let extra = (0..<400).map { ("many/f\($0).bin", 100 + $0) }
    let fixture = try ExploreFixture(extra: extra)
    for appearance in appearances {
        let state = try exploreState(fixture)
        let many = try childCrumbs(state, [], "many")
        state.hoveredTail = HoveredTail(crumbs: many, count: 320, value: 60_000)
        state.pointer = CGPoint(x: 400, y: 300)
        let frame = try drawExplore(
            state,
            appearance: appearance,
            name: "tail-\(appearance.rawValue)"
        )
        #expect(frame.identifiers.contains("cursor-tooltip"))
    }
    #expect(TailTooltip.value(2_048, metric: .bytes) == humanBytes(2_048))
    #expect(TailTooltip.value(12, metric: .files) == "12 files")
}

@Test func aMarkedTileIsFilledInItsCard() {
    #expect(HoverTooltip.symbol(dir: true, marked: false) == "folder")
    #expect(HoverTooltip.symbol(dir: true, marked: true) == "folder.fill")
    #expect(HoverTooltip.symbol(dir: false, marked: true) == "doc.fill")
    for dir in [true, false] {
        for marked in [true, false] {
            let symbol = HoverTooltip.symbol(dir: dir, marked: marked)
            #expect(
                NSImage(
                    systemSymbolName: symbol,
                    accessibilityDescription: nil
                ) != nil
            )
        }
    }
}

// MARK: - The help

@Test func theHelpsColumnsAreSizedFromTheWindow() {
    // A wide window: two columns, each as wide as reads best.
    let wide = HelpOverlay.columns(width: 1_440, rem: baseRem)
    #expect(wide.paired)
    #expect(wide.width == (Size.help - Space.xl - Space.xl).at(baseRem))
    // The narrowest window: still two, sharing what there is.
    let narrow = HelpOverlay.columns(width: 900, rem: baseRem)
    #expect(narrow.paired)
    #expect(narrow.width < wide.width)
    #expect(narrow.width >= HelpOverlay.narrowestColumn.at(baseRem))
    // And at the largest zoom, one, no wider than the room.
    let rem = baseRem * (zoomSteps.last ?? 1)
    let large = HelpOverlay.columns(width: 900, rem: rem)
    #expect(!large.paired)
    #expect(large.width <= 900 - Space.xl.at(rem) * 4)
    #expect(large.width > 0)
}

@MainActor
@Test func theGesturesAreInSightInTheNarrowestWindow() throws {
    // The pointer and the trackpad sit beside the keys in the smallest
    // window disktree allows, not below them out of sight; a short window
    // scrolls the columns, and says so.
    let fixture = try ExploreFixture()
    for appearance in appearances {
        let state = try exploreState(fixture)
        state.showHelp = true
        var frame = try drawExplore(
            state,
            appearance: appearance,
            width: 900,
            height: 600,
            name: "help-narrow-\(appearance.rawValue)"
        )
        #expect(frame.identifiers.contains("help-two-columns"))
        #expect(frame.identifiers.contains("help-scrolls"))
        // Where there is room, all of it at once.
        frame = try drawExplore(
            state,
            appearance: appearance,
            name: "help-wide-\(appearance.rawValue)"
        )
        #expect(frame.identifiers.contains("help-two-columns"))
        #expect(!frame.identifiers.contains("help-scrolls"))
        // The largest zoom in the narrowest window: one column, scrolling.
        state.zoomStep = zoomSteps.count - 1
        frame = try drawExplore(
            state,
            appearance: appearance,
            width: 900,
            height: 600,
            name: "help-large-\(appearance.rawValue)"
        )
        #expect(!frame.identifiers.contains("help-two-columns"))
        #expect(frame.identifiers.contains("help-scrolls"))
    }
}

@Test func theHelpNamesEveryNewGestureAndKey() {
    let keys = Set(HelpOverlay.rows.map(\.key))
    for key in [
        "pinch", "double-tap", "\u{2318}Y", "drag a tile", "drop a folder",
        "scroll", "shift-scroll",
    ] {
        #expect(keys.contains(key), "\(key)")
    }
    // The detent is what makes the pinch feel physical: the help says so.
    let pinch = HelpOverlay.rows.first { $0.key == "pinch" }?.label ?? ""
    #expect(pinch.contains("stops") && pinch.contains("squeeze"))
    #expect(
        HelpOverlay.groups.map(\.title)
            == ["Keys", "Pointer and trackpad", "Review screen"]
    )
}

// MARK: - The window a person sees

@MainActor
@Test func aShortWindowStillDrawsItsPanel() throws {
    // Off screen — a snapshot, a test — the panel's scroll view once ran up
    // behind the toolbar, where macOS 26 draws a scroll view through the
    // window server's scroll edge, and in a window under 700 points tall
    // the whole column came out blank, the toolbar's items over it as white
    // blots. The smallest window, and a laptop's short one, draw it.
    let fixture = try ExploreFixture()
    _ = NSApplication.shared
    for size in [
        CGSize(width: 900, height: 600), CGSize(width: 1_440, height: 640),
    ] {
        let state = try exploreState(fixture)
        let controller = MainWindowController(
            state: state,
            onScreen: false,
            quickLookPanel: HiddenQuickLookPanel()
        )
        let window = try #require(controller.window)
        window.setContentSize(size)
        // Turns of a loop of ours, for SwiftUI to lay the window out and
        // the window server to answer: never the runner's (`closeWindow`).
        for _ in 0..<3 {
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            handBackTheRunLoop()
        }
        let frame = try #require(window.contentView?.superview)
        frame.layoutSubtreeIfNeeded()
        frame.displayIfNeeded()
        let rep = try #require(
            frame.bitmapImageRepForCachingDisplay(in: frame.bounds)
        )
        frame.cacheDisplay(in: frame.bounds, to: rep)
        closeWindow(of: controller)
        // The panel's column, clear of its edges: drawn, opaque, and not
        // one colour.
        let perPoint = CGFloat(rep.pixelsWide) / frame.bounds.width
        let panel = PanelSize.rems * state.rem
        var opaque = 0
        var seen = 0
        var colors = Set<[Int]>()
        for y in stride(from: 80, to: size.height - 40, by: 6) {
            for x in stride(
                from: size.width - panel + 16,
                to: size.width - 16,
                by: 6
            ) {
                guard
                    let color = rep.colorAt(
                        x: Int(x * perPoint),
                        y: Int(y * perPoint)
                    )
                else { continue }
                seen += 1
                if color.alphaComponent > 0.98 {
                    opaque += 1
                }
                colors.insert(
                    [
                        color.redComponent, color.greenComponent,
                        color.blueComponent,
                    ].map { Int($0 * 255) }
                )
            }
        }
        #expect(seen > 0)
        #expect(opaque == seen, "\(size): \(opaque) of \(seen) opaque")
        #expect(colors.count > 8, "\(size): \(colors.count) colours")
    }
}

/// Every view of `root` and below.
@MainActor
private func descendants(of root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap { descendants(of: $0) }
}

@MainActor
@Test func aPersonsWindowHasTheSystemsSearchAndInspector() async throws {
    // Built as a person's window is, but never shown: its toolbar has the
    // system's search field, and the panel is the window's inspector, as
    // wide as it was left.
    let fixture = try ExploreFixture()
    let state = try exploreState(fixture)
    state.panelRems = 30
    _ = NSApplication.shared
    let controller = MainWindowController(
        state: state,
        onScreen: true,
        quickLookPanel: HiddenQuickLookPanel()
    )
    defer { closeWindow(of: controller) }
    let window = try #require(controller.window)
    for _ in 0..<10 {
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(10))
    }
    let items = window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
    #expect(items.contains { $0.localizedStandardContains("search") })
    let content = try #require(window.contentView)
    let split = try #require(
        descendants(of: content).lazy.compactMap { $0 as? NSSplitView }.first
    )
    let column = try #require(split.arrangedSubviews.last)
    #expect(abs(column.frame.width - 30 * state.rem) < 1, "\(column.frame)")
    // Opening it is no change of width, and nothing is saved.
    #expect(state.panelRems == 30)

    // `/` gives the search field the keyboard; typing is its own, and
    // Escape clears the find and gives the keyboard back.
    #expect(controller.route(KeyStroke("/", character: "/")))
    for _ in 0..<100 where !controller.isEditingText {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(controller.isEditingText)
    #expect(state.findOpen)
    // What is typed there is the find, and the keys pass the dispatcher.
    #expect(!controller.route(KeyStroke("b", character: "b")))
    let editor = try #require(window.firstResponder as? NSTextView)
    editor.insertText("blob", replacementRange: editor.selectedRange())
    for _ in 0..<100 where state.find != "blob" {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(state.find == "blob")
    // Escape: the find is cleared, the field lets go, and the mosaic has
    // the keys again.
    #expect(controller.route(KeyStroke("escape")))
    for _ in 0..<100 where controller.isEditingText {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!controller.isEditingText)
    #expect(state.find.isEmpty && !state.findOpen)
    #expect(controller.route(KeyStroke("?", character: "?", shift: true)))
    #expect(state.showHelp)
}
