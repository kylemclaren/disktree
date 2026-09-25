import AppKit
import DisktreeCore
import SwiftUI
import System
import Testing

@testable import DisktreeApp

// The explore chrome, drawn for real: the root view over a real scan of the
// fixture, in an offscreen window, in both appearances and in every state
// the chrome can be in. A screen that crashes while drawing, or draws
// nothing, fails here, as it failed the Rust window harness. The views are
// found by the identifiers they report, as the Rust tests found them by
// debug selector.
//
// The state's methods are another port's; where a check needs one of them
// to answer (the trail, a node under the pointer), it asks the state first
// and only expects what the state says is there.

// MARK: - Drawing every state

/// A frame that drew the chrome: plenty of pixels unlike the window's
/// ground, in more than a handful of colours.
private func expectDrawn(
    _ frame: ExploreFrame,
    _ comment: Comment,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(frame.size.width > 0 && frame.size.height > 0, comment)
    #expect(frame.drawn > 2_000, comment, sourceLocation: sourceLocation)
    #expect(frame.colours > 8, comment, sourceLocation: sourceLocation)
    #expect(
        frame.identifiers.contains("disktree-root"),
        comment,
        sourceLocation: sourceLocation
    )
}

private let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

@MainActor
@Test func theExploreScreenDrawsInBothAppearances() throws {
    let fixture = try ExploreFixture()
    for appearance in appearances {
        let state = try exploreState(fixture)
        let frame = try drawExplore(
            state,
            appearance: appearance,
            name: "scanned-\(appearance.rawValue)"
        )
        expectDrawn(frame, "\(appearance.rawValue)")
        for identifier in ["explore-body", "key-bar", "legend"] {
            #expect(frame.identifiers.contains(identifier), "\(identifier)")
        }
        // The window's toolbar: every control. The fixture's folder has a
        // long name, and the switches may fold into one menu to leave the
        // path room, but they are all there either way.
        for identifier in [
            "up", "trail", "mode-choice", "find-field", "panel-toggle",
        ] {
            #expect(frame.identifiers.contains(identifier), "\(identifier)")
        }
        let switches = ["setting-hidden", "setting-apparent", "depth"]
        #expect(
            frame.identifiers.isSuperset(of: switches)
                || frame.identifiers.contains("view-options")
        )
        // The tree is in, so the mosaic has the viewport, and nothing is
        // open over it; nothing is being found.
        for identifier in ["scanning-panel", "help-overlay", "find-status"] {
            #expect(!frame.identifiers.contains(identifier), "\(identifier)")
        }
        // The trail draws one of its folds, whatever the state says the
        // trail is, and always where you are.
        let steps = state.breadcrumbs()
        let drawn = frame.identifiers.filter {
            $0.hasPrefix("crumb-") && !$0.hasSuffix("-menu")
                && $0 != "crumb-folded"
        }
        if !steps.isEmpty {
            #expect(drawn.contains("crumb-\(steps.count - 1)"))
            let folds = trailFolds(steps.count).map { fold in
                Set(
                    steps.indices.filter { !fold.contains($0) }
                        .map { "crumb-\($0)" }
                )
            }
            #expect(folds.contains(drawn), "\(drawn.sorted())")
        }
    }
}

@MainActor
@Test func thePresetThemesDrawTheScreenshotsLook() throws {
    // The presets are what the look was tuned against; both must draw.
    let fixture = try ExploreFixture()
    for (theme, name) in [(Theme.dark, "dark"), (Theme.light, "light")] {
        let state = try exploreState(fixture)
        let frame = try drawExplore(
            state,
            appearance: theme.isDark ? .darkAqua : .aqua,
            theme: theme,
            name: "preset-\(name)"
        )
        expectDrawn(frame, "\(name)")
    }
}

@MainActor
@Test func theFirstScanShowsWhatItIsDoing() throws {
    let fixture = try ExploreFixture()
    for appearance in appearances {
        let state = scanningState(fixture)
        // A walk in flight, and one whose permission errors ask for Full
        // Disk Access.
        let walk = ScanHandle(root: fixture.root, options: exploreOptions())
        defer { walk.cancel() }
        state.scan = walk
        state.progress.files = 48_213
        state.progress.dirs = 5_120
        state.progress.bytes = 12_884_901_888
        state.progress.errors = 3
        state.progress.messages = [
            "\(fixture.root.string)/Mail: Operation not permitted"
        ]
        var frame = try drawExplore(
            state,
            appearance: appearance,
            name: "scanning-\(appearance.rawValue)"
        )
        expectDrawn(frame, "scanning \(appearance.rawValue)")
        #expect(frame.identifiers.contains("scanning-panel"))
        #expect(frame.identifiers.contains("key-bar"))

        // A walk that failed says why, where the mosaic would have been.
        state.scan = nil
        state.scanError = "\(fixture.root.string): Permission denied"
        frame = try drawExplore(
            state,
            appearance: appearance,
            name: "scan-error-\(appearance.rawValue)"
        )
        expectDrawn(frame, "failed \(appearance.rawValue)")
        #expect(frame.identifiers.contains("scanning-panel"))
    }
}

@MainActor
@Test func theFindsMatchesShowWhileOpenOrApplied() throws {
    let fixture = try ExploreFixture()
    for appearance in appearances {
        let state = try exploreState(fixture)
        let tree = try #require(state.tree)

        // Open and empty: it says what typing does. The field itself is
        // the toolbar's, there whether or not anything is being found.
        state.beginFind()
        var frame = try drawExplore(
            state,
            appearance: appearance,
            name: "find-open-\(appearance.rawValue)"
        )
        expectDrawn(frame, "open")
        #expect(frame.identifiers.contains("find-status"))
        #expect(frame.identifiers.contains("find-field"))

        // Typed, while the search runs.
        state.find = "blob"
        state.finding = true
        frame = try drawExplore(
            state,
            appearance: appearance,
            name: "find-searching-\(appearance.rawValue)"
        )
        #expect(frame.identifiers.contains("find-status"))

        // Applied: the matches stay said, closed, in the highlight.
        state.finding = false
        state.matches = filter(tree, base: [], needle: "blob")
        state.findOpen = false
        state.filterApplied = true
        frame = try drawExplore(
            state,
            appearance: appearance,
            name: "find-applied-\(appearance.rawValue)"
        )
        expectDrawn(frame, "applied")
        #expect(frame.identifiers.contains("find-status"))

        // Nothing to find and not finding: nothing said.
        state.find = ""
        state.matches = nil
        state.filterApplied = false
        frame = try drawExplore(
            state,
            appearance: appearance,
            name: "find-closed-\(appearance.rawValue)"
        )
        #expect(!frame.identifiers.contains("find-status"))
        #expect(frame.identifiers.contains("find-field"))
    }
}

@MainActor
@Test func whatTheFindSaysFollowsItsSearch() throws {
    let fixture = try ExploreFixture()
    let state = try exploreState(fixture)
    let tree = try #require(state.tree)
    var (summary, hint) = FindStatus.summaryAndHint(state)
    #expect(summary == "type a name to filter" && hint == nil)
    state.finding = true
    (summary, hint) = FindStatus.summaryAndHint(state)
    #expect(summary.hasPrefix("searching") && hint == nil)
    state.finding = false
    state.matches = filter(tree, base: [], needle: "blob")
    (summary, hint) = FindStatus.summaryAndHint(state)
    #expect(summary.hasPrefix("2 matches"))
    #expect(hint?.keys == "return")
    state.filterApplied = true
    (summary, hint) = FindStatus.summaryAndHint(state)
    #expect(hint?.keys == "esc" && hint?.label == "clears")
    state.matches = filter(tree, base: [], needle: "nothing-by-this-name")
    (summary, hint) = FindStatus.summaryAndHint(state)
    #expect(summary == "no matches" && hint?.keys == "esc")
    // The hints name the keys as a Mac's keyboard and menus print them.
    #expect(KeyHint.name("space") == "Space")
    #expect(KeyHint.name("enter") == "Return")
    #expect(KeyHint.name("return") == "Return")
    #expect(KeyHint.name("esc") == "Esc")
    #expect(KeyHint.name("\u{232b}") == "Delete")
    #expect(KeyHint.name("c") == "C")
    #expect(KeyHint.name("/") == "/")
    #expect(KeyHint.spoken("\u{232b}") == "delete")
}

@MainActor
@Test func theSearchFieldEditsTheFind() async throws {
    // The search field's edits reach the find as `/` and typing do.
    let fixture = try ExploreFixture()
    let state = try exploreState(fixture)
    state.beginFind()
    #expect(state.findOpen)
    state.setFind("blob")
    #expect(state.find == "blob")
    for _ in 0..<200 where state.matches == nil {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(state.matches?.count == 2)
    // The same text again is no edit: the search is not started over.
    state.setFind("blob")
    #expect(!state.finding)
    // A click elsewhere: the text and its matches stay.
    state.endFind()
    #expect(!state.findOpen && state.find == "blob" && state.matches != nil)
    // Its clear button: nothing is found.
    state.setFind("")
    #expect(state.matches == nil && !state.filterApplied)
}

@MainActor
@Test func theStepWhereYouAreOffersItsSiblings() throws {
    let fixture = try ExploreFixture()
    for appearance in appearances {
        let state = try exploreState(fixture)
        // Into junk, so the trail ends in a step that has siblings.
        let junk = try childCrumbs(state, [], "junk")
        state.crumbs = junk
        state.selected = junk
        let frame = try drawExplore(
            state,
            appearance: appearance,
            name: "siblings-\(appearance.rawValue)"
        )
        expectDrawn(frame, "\(appearance.rawValue)")
        let steps = state.breadcrumbs()
        #expect(
            frame.identifiers.contains("crumb-\(steps.count - 1)-menu"),
            "the step where you are has a menu"
        )
        // The menu's items, drawn as a menu's content is outside one: a
        // row per sibling, never a crash.
        let items = try drawAlone(
            VStack(alignment: .leading) {
                SiblingItems(state: state, parent: [], current: junk[0])
            },
            appearance: appearance,
            theme: appearance == .darkAqua ? .dark : .light,
            name: "sibling-items-\(appearance.rawValue)"
        )
        #expect(items.drawn > 100)
    }
}

@Test func aSiblingsBarIsItsShareInItsColour() throws {
    let image = SiblingMeter.image(
        fraction: 0.5,
        color: Theme.dark.categoryAccent(.code),
        track: Theme.dark.secondary.opacity(0.25)
    )
    #expect(image.size == SiblingMeter.size)
    // Its own colours, not a symbol's ink.
    #expect(!image.isTemplate)
    let symbol = StepSymbol.image("folder.fill", color: Theme.dark.accent)
    #expect(!symbol.isTemplate && symbol.size.width > 0)
}

@Test func eachStepHasItsSymbol() {
    let home: FilePath = "/Users/tobi"
    #expect(
        StepSymbol.name(path: "/", root: true, home: home)
            == "internaldrive.fill"
    )
    #expect(
        StepSymbol.name(path: home, root: false, home: home) == "house.fill")
    #expect(
        StepSymbol.name(path: "/Users", root: false, home: home)
            == "folder.fill"
    )
    #expect(StepSymbol.name(path: nil, root: false, home: nil) == "folder.fill")
}

@MainActor
@Test func theHelpOverlayCoversEveryScreenState() throws {
    let fixture = try ExploreFixture()
    for appearance in appearances {
        let state = try exploreState(fixture)
        state.showHelp = true
        let frame = try drawExplore(
            state,
            appearance: appearance,
            name: "help-\(appearance.rawValue)"
        )
        expectDrawn(frame, "\(appearance.rawValue)")
        #expect(frame.identifiers.contains("help-overlay"))
    }
}

@MainActor
@Test func ageModeDrawsTheAgeRamp() throws {
    let fixture = try ExploreFixture()
    for appearance in appearances {
        let state = try exploreState(fixture)
        state.colorMode = .age
        let frame = try drawExplore(
            state,
            appearance: appearance,
            name: "age-\(appearance.rawValue)"
        )
        expectDrawn(frame, "\(appearance.rawValue)")
    }
}

@MainActor
@Test func aNarrowWindowGivesThePanelsRoomToTheMosaic() throws {
    let fixture = try ExploreFixture()
    for appearance in appearances {
        let state = try exploreState(fixture)
        // The panel would carry the notice; without it, the notice moves
        // under the totals rather than go unseen.
        state.notice = Notice(
            "mark something first: space marks the selected tile",
            status: .warning
        )
        let frame = try drawExplore(
            state,
            appearance: appearance,
            width: 820,
            height: 600,
            name: "narrow-\(appearance.rawValue)"
        )
        expectDrawn(frame, "\(appearance.rawValue)")
        #expect(frame.identifiers.contains("explore-body"))
    }
}

@Test func thePanelGivesWayOnlyToANarrowWindow() {
    // 52 rem: 832 points at the default zoom.
    #expect(ExploreView.showsPanel(selection: true, width: 1440, rem: 16))
    #expect(ExploreView.showsPanel(selection: true, width: 832, rem: 16))
    #expect(!ExploreView.showsPanel(selection: true, width: 831, rem: 16))
    // At a larger interface zoom, the same window is narrower in rem.
    #expect(!ExploreView.showsPanel(selection: true, width: 1440, rem: 28))
    #expect(!ExploreView.showsPanel(selection: false, width: 1440, rem: 16))
}

@MainActor
@Test func interfaceZoomScalesTheWholeChrome() throws {
    let fixture = try ExploreFixture()
    for step in [0, zoomSteps.count - 1] {
        for appearance in appearances {
            let state = try exploreState(fixture)
            state.zoomStep = step
            state.findOpen = true
            var frame = try drawExplore(
                state,
                appearance: appearance,
                name: "zoom-\(step)-\(appearance.rawValue)"
            )
            expectDrawn(frame, "zoom \(step) \(appearance.rawValue)")
            #expect(frame.identifiers.contains("find-status"))
            // The overlay at the largest zoom scrolls its keys in a short
            // window rather than run off its card.
            state.showHelp = true
            frame = try drawExplore(
                state,
                appearance: appearance,
                height: 600,
                name: "zoom-\(step)-help-\(appearance.rawValue)"
            )
            #expect(frame.identifiers.contains("help-overlay"))
        }
    }
}

@MainActor
@Test func longNamesAndTheTooltipStayInTheirPlace() throws {
    let long = String(
        repeating: "a-directory-with-a-name-long-enough-to-crowd-",
        count: 4
    )
    let fixture = try ExploreFixture(extra: [("\(long)/inside.bin", 50_000)])
    for appearance in appearances {
        let state = try exploreState(fixture)
        let crumbs = try childCrumbs(state, [], long)
        state.crumbs = crumbs
        state.selected = crumbs + [0]
        // The pointer in the mosaic's far corner: the card flips to stay
        // in the window.
        state.hovered = crumbs + [0]
        state.pointerActive = true
        state.pointer = CGPoint(x: 1_000, y: 700)
        let frame = try drawExplore(
            state,
            appearance: appearance,
            name: "long-names-\(appearance.rawValue)"
        )
        expectDrawn(frame, "\(appearance.rawValue)")
        if state.node(at: crumbs + [0]) != nil {
            #expect(frame.identifiers.contains("cursor-tooltip"))
        }
    }
}

@MainActor
@Test func aHoveredDirectoryInsideAMarkShowsItsCard() throws {
    let fixture = try ExploreFixture()
    for appearance in appearances {
        let state = try exploreState(fixture)
        let junk = try childCrumbs(state, [], "junk")
        let deeper = try childCrumbs(state, junk, "deeper")
        // Marked by hand: the state's own marking is another port's.
        state.marks.toggle(
            Target(
                path: fixture.root.appending("junk"),
                bytes: 300_000,
                isDir: true,
                hidden: false
            )
        )
        state.hovered = deeper
        state.pointer = CGPoint(x: 200, y: 160)
        let frame = try drawExplore(
            state,
            appearance: appearance,
            name: "tooltip-\(appearance.rawValue)"
        )
        expectDrawn(frame, "\(appearance.rawValue)")
        if state.node(at: deeper) != nil {
            #expect(frame.identifiers.contains("cursor-tooltip"))
        } else {
            #expect(!frame.identifiers.contains("cursor-tooltip"))
        }
    }
}

@MainActor
@Test func theReviewScreenReplacesTheExploreChrome() throws {
    let fixture = try ExploreFixture()
    let state = try exploreState(fixture)
    state.screen = .review
    let frame = try drawExplore(state, appearance: .darkAqua, name: "review")
    #expect(frame.identifiers.contains("disktree-root"))
    #expect(!frame.identifiers.contains("explore-body"))
    #expect(!frame.identifiers.contains("key-bar"))
    // The toolbar changes with the screen: none of the explore screen's
    // items stays behind on the review's.
    for identifier in ["trail", "mode-choice", "depth", "find-field"] {
        #expect(!frame.identifiers.contains(identifier), "\(identifier)")
    }
}

@MainActor
@Test func theTitleNamesTheDirectoryAndWhatItHolds() throws {
    let fixture = try ExploreFixture()
    let state = try exploreState(fixture)
    let tree = try #require(state.tree)
    #expect(ExploreView.title(state) == fixture.root.lastComponent?.string)
    // At the root, the scan's totals.
    #expect(
        ExploreView.subtitle(state)
            == "\(humanBytes(tree.bytes)) \u{00b7} \(tree.files) files "
            + "\u{00b7} \(tree.dirs) folders"
    )
    // Deeper, what the directory holds and its share of the scan.
    let junk = try childCrumbs(state, [], "junk")
    state.crumbs = junk
    let node = try #require(state.node(at: junk))
    #expect(ExploreView.title(state) == "junk")
    #expect(
        ExploreView.subtitle(state)
            == "\(humanBytes(node.bytes)) \u{00b7} \(node.files) files "
            + "\u{00b7} \(percent(node.bytes, of: tree.bytes)) of scan"
    )
    // What could not be read is counted, never guessed at.
    state.progress.errors = 3
    #expect(ExploreView.subtitle(state).hasSuffix("3 unreadable"))
    // While the first walk runs, how far it has got.
    let scanning = scanningState(fixture)
    scanning.progress.files = 48_213
    #expect(ExploreView.subtitle(scanning).hasPrefix("Scanning\u{2026}"))
    #expect(ExploreView.subtitle(scanning).contains("48.2k files"))
    scanning.scanError = "Permission denied"
    #expect(ExploreView.subtitle(scanning) == "Scan failed")
}

@Test func thePathFoldsToTheRoomItHas() {
    // As many steps as a trail shows before it folds anything.
    let labels = [
        "/", "private", "var", "disktree-explore", "junk", "deeper",
        "deepest",
    ]
    let all = Trail.width(labels, hiding: 0..<0)
    // Room for all of it: nothing folds.
    #expect(Trail.fold(labels, room: all + 1).isEmpty)
    // Less room, more folded; and what is shown fits, down to the last
    // fold, which keeps only where you are.
    var last = 0
    for room in stride(from: all, through: 40, by: -20) {
        let hidden = Trail.fold(labels, room: room)
        #expect(hidden.count >= last, "\(room)")
        #expect(!hidden.contains(labels.count - 1), "\(room)")
        if hidden != trailFolds(labels.count).last {
            #expect(Trail.width(labels, hiding: hidden) <= room, "\(room)")
        }
        last = hidden.count
    }
    #expect(Trail.fold(labels, room: 1) == 0..<labels.count - 1)
}

@Test func theToolbarSharesOutTheWindowsWidth() {
    // The window the app opens at: every switch in the bar, and the path
    // given what the rest leaves.
    let wide = ToolbarBudget(
        width: 1_440, inspector: 0, findInBar: true, titles: 200
    )
    #expect(!wide.compact)
    // The narrowest window: the switches fold into one menu before the
    // path would be only where you are.
    let narrow = ToolbarBudget(
        width: 900, inspector: 0, findInBar: true, titles: 200
    )
    #expect(narrow.compact)
    #expect(narrow.path >= ToolbarBudget.leastPath)
    #expect(wide.path > narrow.path)
    // A longer title leaves the path less.
    let titled = ToolbarBudget(
        width: 1_440, inspector: 0, findInBar: true, titles: 300
    )
    #expect(titled.path == wide.path - 100)
    // On screen with the panel out, the find field sits over the panel,
    // and the rest share what the panel leaves.
    let inspector = ToolbarBudget(
        width: 1_440, inspector: 368, findInBar: false, titles: 200
    )
    #expect(inspector.path == wide.path - 368 + ToolbarBudget.find)
    // Never less than a name, however little is left.
    let tiny = ToolbarBudget(
        width: 500, inspector: 0, findInBar: true, titles: 400
    )
    #expect(tiny.path == ToolbarBudget.leastPath)
}

// MARK: - Placement

@Test func theTooltipFlipsRatherThanOverflow() {
    let room = CGSize(width: 1_000, height: 800)
    let card = CGSize(width: 200, height: 100)
    func origin(_ x: CGFloat, _ y: CGFloat, in room: CGSize) -> CGPoint {
        FloatingPlacement.origin(
            of: card,
            at: CGPoint(x: x, y: y),
            fit: .flip(gap: 12),
            margin: 4,
            in: room
        )
    }
    // Below and to the right of the pointer, a gap away.
    #expect(origin(100, 100, in: room) == CGPoint(x: 112, y: 112))
    // At the right edge, to the left; at the bottom, above.
    #expect(origin(950, 100, in: room) == CGPoint(x: 738, y: 112))
    #expect(origin(100, 780, in: room) == CGPoint(x: 112, y: 668))
    #expect(origin(950, 780, in: room) == CGPoint(x: 738, y: 668))
    // A window too small for either side keeps the card at its margin.
    let tiny = CGSize(width: 150, height: 120)
    #expect(origin(50, 50, in: tiny) == CGPoint(x: 4, y: 4))
}

@Test func aSnappedCardIsPushedBackInsideTheWindow() {
    let room = CGSize(width: 1_000, height: 800)
    func origin(_ x: CGFloat, _ y: CGFloat, _ size: CGSize) -> CGPoint {
        FloatingPlacement.origin(
            of: size,
            at: CGPoint(x: x, y: y),
            fit: .snap,
            margin: 8,
            in: room
        )
    }
    let menu = CGSize(width: 384, height: 300)
    #expect(origin(200, 60, menu) == CGPoint(x: 200, y: 60))
    // A crumb near the right edge: the menu is pushed back inside.
    #expect(origin(900, 60, menu) == CGPoint(x: 608, y: 60))
    // Taller than the room below the crumb: pushed up, never past the top.
    #expect(
        origin(200, 600, menu) == CGPoint(x: 200, y: 492),
        "bottom edge"
    )
    #expect(
        origin(200, 60, CGSize(width: 384, height: 900))
            == CGPoint(x: 200, y: 8)
    )
}

@Test func aRowShowsTheLongestRunOfItemsThatFitsWhole() {
    // The longest run from the first that fits, spacing and all; a row too
    // narrow for any shows none, and an unbounded one shows every item.
    let widths: [CGFloat] = [40, 30, 20]
    #expect(PrefixRow.fitting(widths, spacing: 5, room: nil) == 3)
    #expect(PrefixRow.fitting(widths, spacing: 5, room: .infinity) == 3)
    #expect(PrefixRow.fitting(widths, spacing: 5, room: 100) == 3)
    #expect(PrefixRow.fitting(widths, spacing: 5, room: 99) == 2)
    #expect(PrefixRow.fitting(widths, spacing: 5, room: 75) == 2)
    #expect(PrefixRow.fitting(widths, spacing: 5, room: 74) == 1)
    #expect(PrefixRow.fitting(widths, spacing: 5, room: 39) == 0)
    #expect(PrefixRow.fitting([], spacing: 5, room: 10) == 0)
}

/// Drawn, a row short of room shows the longest run that fits, whole, and
/// nothing of the rest: not drawn, not read out.
@MainActor
@Test func aRowShortOfRoomDropsWholeItemsFromItsEnd() throws {
    for (width, shown) in [(130.0, 3), (250.0, 5), (30.0, 0)] {
        let frame = try drawAlone(
            FittingPrefix(count: 5, spacing: 0) { index in
                Text("\(index)")
                    .frame(width: 40)
                    .chromeIdentifier("prefix-\(index)")
            },
            appearance: .darkAqua,
            theme: .dark,
            width: width,
            name: "prefix-\(Int(width))"
        )
        let drawn = (0..<5).filter {
            frame.identifiers.contains("prefix-\($0)")
        }
        #expect(drawn == Array(0..<shown), "\(width): \(drawn)")
    }
}

@Test func chipsWrapOntoTheNextLine() {
    let chip = CGSize(width: 50, height: 10)
    let frames = ChipFlow.frames([chip, chip, chip], width: 120, spacing: 4)
    let origins = [
        CGPoint(x: 0, y: 0), CGPoint(x: 54, y: 0), CGPoint(x: 0, y: 14),
    ]
    #expect(frames.map(\.origin) == origins)
    // A chip wider than the row gets a row of its own, cut to fit.
    let wide = ChipFlow.frames(
        [chip, CGSize(width: 200, height: 10)],
        width: 120,
        spacing: 4
    )
    #expect(wide[1] == CGRect(x: 0, y: 14, width: 120, height: 10))
}

// MARK: - What the chrome says

@Test func aDeepTrailKeepsItsEndsAndFoldsItsMiddle() {
    #expect(hiddenTrailSteps(0).isEmpty)
    #expect(hiddenTrailSteps(trailSteps).isEmpty)
    // One step too many: the third goes behind the ellipsis.
    #expect(hiddenTrailSteps(trailSteps + 1) == 2..<4)
    // However deep, the first two and the last four stay.
    let deep = 14
    let hidden = hiddenTrailSteps(deep)
    let shown = (0..<deep).filter { !hidden.contains($0) }
    #expect(shown == [0, 1, 10, 11, 12, 13])
}

@Test func aTrailShortOfRoomFoldsFurtherBeforeCuttingAName() {
    // The usual fold first, then fewer of the last steps, then where you
    // are alone.
    #expect(trailFolds(8) == [2..<4, 2..<5, 2..<6, 2..<7, 0..<7])
    #expect(trailFolds(5) == [0..<0, 2..<3, 2..<4, 0..<4])
    #expect(trailFolds(3) == [0..<0, 0..<2])
    // One step is all there is: nothing to fold.
    #expect(trailFolds(1) == [0..<0])
    #expect(trailFolds(0) == [0..<0])
    // Every fold keeps the last step.
    for count in 1...20 {
        for fold in trailFolds(count) {
            #expect(!fold.contains(count - 1), "\(count) \(fold)")
        }
    }
}

@Test func theScanningMeterClaimsNoFractionItCannotKnow() {
    let space = SpaceInfo(total: 1_000, free: 600, available: 500)
    // A folder's total is what the walk is there to find: no fraction.
    #expect(
        ScanningPanel.fraction(
            bytes: 100,
            root: "/Users/tobi/Dev",
            volume: "/",
            space: space
        ) == nil
    )
    // The whole volume counts toward what it has in use.
    #expect(
        ScanningPanel.fraction(bytes: 100, root: "/", volume: "/", space: space)
            == 0.25
    )
    // Never full before the walk lands, however much it has counted.
    #expect(
        ScanningPanel.fraction(bytes: 900, root: "/", volume: "/", space: space)
            == 0.99
    )
    // Nothing to measure against: no fraction.
    #expect(
        ScanningPanel.fraction(bytes: 100, root: "/", volume: "/", space: nil)
            == nil
    )
    #expect(
        ScanningPanel.fraction(bytes: 100, root: "/", volume: nil, space: space)
            == nil
    )
}

@Test func permissionErrorsOfferFullDiskAccess() {
    #expect(
        ScanTotals.needsFullDiskAccess([
            "/Users/tobi/Library/Mail: Operation not permitted"
        ])
    )
    #expect(
        ScanTotals.needsFullDiskAccess([
            "/Users/tobi/a: No such file or directory",
            "/private/var/db/x: Permission denied",
        ])
    )
    #expect(
        !ScanTotals.needsFullDiskAccess([
            "/Users/tobi/a: No such file or directory"
        ])
    )
    #expect(!ScanTotals.needsFullDiskAccess([]))
    #expect(FullDiskAccess.settingsURL.scheme == "x-apple.systempreferences")
    #expect(
        FullDiskAccess.settingsURL.absoluteString.hasSuffix(
            "Privacy_AllFiles"
        )
    )
}

@Test func theNestingCardNamesTheMarkedAncestor() {
    var marks = Marks()
    marks.toggle(
        Target(path: "/Users/tobi/junk", bytes: 1, isDir: true, hidden: false)
    )
    #expect(
        HoverTooltip.marksAncestor(marks, of: "/Users/tobi/junk/deeper")
            == "junk"
    )
    // Never the path itself, and component-wise: `junk-real` is not in it.
    #expect(HoverTooltip.marksAncestor(marks, of: "/Users/tobi/junk") == nil)
    #expect(
        HoverTooltip.marksAncestor(marks, of: "/Users/tobi/junk-real") == nil
    )
    #expect(HoverTooltip.marksAncestor(marks, of: nil) == nil)
    #expect(HoverTooltip.shortName("/Users/tobi/junk") == "junk")
    #expect(HoverTooltip.shortName("/") == "/")
}

@Test func theKeysNeverSoundLikeDeleting() {
    // disktree removes nothing itself: `c` is a review, and the only line
    // that speaks of deleting says so.
    #expect(KeyBar.hints.contains { $0 == ("c", "review") })
    for hint in KeyBar.hints {
        let label = hint.label.lowercased()
        #expect(
            !label.contains("delet") && !label.contains("remov")
                && !label.contains("trash"),
            "\(hint)"
        )
    }
    let speaking = HelpOverlay.rows.filter {
        $0.label.lowercased().contains("delet")
    }
    #expect(speaking.count == 1)
    #expect(speaking.first?.label.contains("never deletes") == true)
    // The Mac's own keys and gestures are there, and the hand-over's.
    let keys = Set(HelpOverlay.rows.map(\.key))
    for key in ["\u{2318}-click", "right-click", "f", "c"] {
        #expect(keys.contains(key), "\(key)")
    }
    #expect(HelpOverlay.groups.map(\.title).contains("Review screen"))
}

@Test func elapsedTimeReadsInSeconds() {
    #expect(KeyBar.seconds(.milliseconds(1_500)) == 1.5)
    #expect(KeyBar.seconds(.zero) == 0)
}

@MainActor
@Test func theWindowsContentHandsItsToolbarToTheWindow() throws {
    let fixture = try ExploreFixture()
    let state = try exploreState(fixture)
    let host = RootView.hostingController(state: state, live: false)
    #expect(host.sceneBridgingOptions == [.toolbars, .title])
    // The window decides its size; the mosaic fills it.
    #expect(host.sizingOptions.isEmpty)
    #expect(!host.rootView.live)
    #expect(RootView.hostingController(state: state, live: true).rootView.live)
}
