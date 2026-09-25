import AppKit
import DisktreeCore
import Foundation
import SwiftUI
import System
import Testing

@testable import DisktreeApp

// The side panel, drawn for real: every state it can be in, in both
// appearances, into pixels through AppKit's own display path, so a section
// that crashes while drawing, or draws nothing, fails here rather than on
// screen. It is presented in a real inspector, as the window presents it,
// to check the width it opens at, the limits it keeps to and the width it
// keeps; and the panel's words and numbers are checked where they are
// computed.

/// A state the panel can be in, set up over the fixture.
enum PanelScene: String, CaseIterable, Sendable {
    /// Before the first scan lands: no tree, no selection.
    case waiting
    /// Nothing selected: the directory on screen is what the panel shows.
    case root
    case file
    case directory
    /// A finding is the selection: its row in "worth a look" is washed in
    /// the highlight.
    case finding
    case checkoutClean
    case checkoutDirty
    case checkoutNoUpstream
    /// A checkout git has not answered for yet.
    case checkoutAsking
    case checkoutUnreadable
    /// The selection is marked.
    case marked
    /// The selection is inside a marked directory: it goes with it.
    case covered
    /// Part of the selection could not be read.
    case unreadable
    /// More marks than the panel lists, one of them covered.
    case manyMarks
    /// Some marks gone from disk, and the disk measurably gained.
    case goneWithGain
    /// Every mark gone, and nothing measured yet.
    case goneNothingMeasured
    /// A volume small enough that the marks' slice of the meter shows.
    case projection
    case noInsights
    case noSpace
    case notice
    case scanError
    case filesMetric
    case narrow
    case wide
    case smallestZoom
    case largestZoom

    @MainActor
    func apply(to state: AppState, fixture: PanelHarness.Fixture) throws {
        let tree = try #require(state.tree)
        let crumbs = { (relative: String) throws -> [Int] in
            try #require(PanelHarness.crumbs(relative, in: tree))
        }
        let mark = { (relative: String) throws in
            let target = try #require(
                PanelHarness.target(relative, in: fixture, tree: tree)
            )
            state.marks.toggle(target)
            state.spaceBaseline = state.spaceBaseline ?? state.space
        }
        state.selected = try crumbs("junk")
        switch self {
        case .waiting:
            state.tree = nil
            state.selected = nil
            state.insights = []
        case .root:
            state.selected = nil
        case .file:
            state.selected = try crumbs("junk/blob.bin")
        case .directory:
            break
        case .finding:
            state.selected = try crumbs("app/node_modules")
        case .checkoutClean, .checkoutDirty, .checkoutNoUpstream,
            .checkoutAsking, .checkoutUnreadable:
            state.selected = try crumbs("repo")
            let git: GitState?? =
                switch self {
                case .checkoutClean:
                    GitState(changed: 0, stashes: 0, unpushed: 0)
                case .checkoutDirty:
                    GitState(changed: 3, stashes: 1, unpushed: 2)
                case .checkoutNoUpstream:
                    GitState(changed: 0, stashes: 0, unpushed: nil)
                case .checkoutUnreadable: .some(nil)
                default: nil
                }
            if let git {
                state.git[fixture.path("repo")] = git
            }
        case .marked:
            try mark("junk")
        case .covered:
            try mark("junk")
            state.selected = try crumbs("junk/deeper")
        case .unreadable:
            let index = try crumbs("junk")
            state.tree?.children[index[0]].readError = true
        case .manyMarks:
            for index in 0..<10 {
                try mark("many/f\(index).bin")
            }
            try mark("junk")
            state.selected = try crumbs("keep")
        case .goneWithGain, .goneNothingMeasured:
            try mark("junk")
            try mark("keep")
            try mark(".cache")
            let now = try #require(state.space)
            state.gone = [fixture.path("junk"), fixture.path("keep")]
            if self == .goneNothingMeasured {
                state.gone.insert(fixture.path(".cache"))
            } else {
                state.spaceBaseline = SpaceInfo(
                    total: now.total,
                    free: now.free - 301_000,
                    available: now.available - 301_000
                )
            }
        case .projection:
            try mark("app/node_modules")
            try mark(".cache")
            let mebibyte: UInt64 = 1_024 * 1_024
            state.space = SpaceInfo(
                total: 1_024 * mebibyte,
                free: 260 * mebibyte,
                available: 240 * mebibyte
            )
        case .noInsights:
            state.insights = []
        case .noSpace:
            state.space = nil
            try mark("junk")
        case .notice:
            state.notice = Notice(
                "Copied: trash for 1 item, 300.3 kB — paste it into Terminal",
                status: .success
            )
        case .scanError:
            state.scanError = "\(fixture.root.string): permission denied"
        case .filesMetric:
            state.options.metric = .files
        case .narrow:
            state.panelRems = PanelSize.minRems
            try mark("app/node_modules")
            state.selected = try crumbs("repo")
            state.git[fixture.path("repo")] = GitState(
                changed: 12,
                stashes: 3,
                unpushed: 4
            )
        case .wide:
            state.panelRems = PanelSize.maxRems
            try mark("app/node_modules")
        case .smallestZoom:
            state.zoomStep = 0
            try mark("junk")
        case .largestZoom:
            state.zoomStep = zoomSteps.count - 1
            try mark("junk")
        }
    }
}

@MainActor
@Suite struct SidePanelTests {
    // MARK: Every state, both appearances

    @Test(arguments: PanelScene.allCases, PanelHarness.Look.allCases)
    func everyStateDraws(
        scene: PanelScene,
        look: PanelHarness.Look
    ) throws {
        let fixture = try PanelHarness.fixture()
        defer { fixture.remove() }
        let state = try PanelHarness.state(fixture)
        try scene.apply(to: state, fixture: fixture)
        let height: CGFloat = 900
        let rendered = try PanelHarness.render(
            state,
            look: look,
            height: height,
            name: scene.rawValue
        )
        #expect(rendered.width > 0 && rendered.height > 0)
        // Something is drawn on the panel, at the top (the selection) and
        // at the bottom (the disk): neither was pushed out by the lists.
        #expect(rendered.drawn() > 1_500, "\(scene) drew almost nothing")
        #expect(rendered.drawn(rows: 0...160) > 150, "\(scene): selection")
        let bottom = Double(height)
        #expect(
            rendered.drawn(rows: (bottom - 140)...bottom) > 150,
            "\(scene): disk"
        )
    }

    @Test(arguments: PanelHarness.Look.allCases)
    func thePresetsDrawLikeTheScreenshot(look: PanelHarness.Look) throws {
        // The fixed themes the screenshot was tuned against: the panel
        // with a selection, findings, marks and a projection in each.
        let fixture = try PanelHarness.fixture()
        defer { fixture.remove() }
        let state = try PanelHarness.state(fixture)
        try PanelScene.manyMarks.apply(to: state, fixture: fixture)
        let rendered = try PanelHarness.render(
            state,
            look: look,
            preset: true,
            name: "screenshot"
        )
        #expect(rendered.drawn() > 1_500)
    }

    // MARK: Layout

    @Test func thePanelsIdealWidthIsTheWidthItKeeps() throws {
        // What a host that asks for the panel's own size gets, and what the
        // inspector opens at: the width kept in rem, at every zoom.
        let fixture = try PanelHarness.fixture()
        defer { fixture.remove() }
        let state = try PanelHarness.state(fixture)
        _ = NSApplication.shared
        for step in [0, defaultZoomStep, zoomSteps.count - 1] {
            for rems in [PanelSize.minRems, PanelSize.rems, PanelSize.maxRems] {
                state.zoomStep = step
                state.panelRems = rems
                let host = NSHostingView(
                    rootView: SidePanel(state: state)
                        .environment(\.rem, state.rem)
                )
                let width = host.fittingSize.width
                #expect(
                    abs(width - rems * state.rem) < 0.5,
                    "\(rems) rem at \(state.rem) pt: \(width)"
                )
            }
        }
    }

    @Test func theColumnScrollsWhileTheDiskStaysPut() throws {
        // The same panel in a tall window and in one that leaves the lists
        // a few lines: the column starts at its top, so the selection is
        // drawn exactly alike in both, and the disk pinned at the bottom
        // is too; only what lies between them loses room, scrolled under
        // the disk rather than cut through by a scroll area of its own.
        let fixture = try PanelHarness.fixture()
        defer { fixture.remove() }
        OverlayScrollers.pin()
        let state = try PanelHarness.state(fixture)
        try PanelScene.manyMarks.apply(to: state, fixture: fixture)
        let rem = state.rem
        let padding = Double(Space.lg.at(rem))
        let inner = state.panelRems * rem - 2 * Space.lg.at(rem)
        let height = { (section: AnyView) in
            Double(
                NSHostingView(
                    rootView: section.frame(width: inner)
                        .font(TextSize.body.font(rem))
                        .environment(\.rem, rem)
                )
                .fittingSize.height
            )
        }
        let selection = height(AnyView(SelectionSection(state: state)))
        let disk = height(
            AnyView(DiskSection(state: state, plan: state.plan()))
        )
        #expect(selection > 0 && disk > 0)
        // Room for the selection, the disk and their gaps, and about three
        // rows of the lists: far less than they hold.
        let tallHeight = 1_600.0
        let shortHeight =
            2 * padding + selection + disk + 4 * padding
            + Double(Space.xxl.at(rem)) * 3 + 24
        let tall = try PanelHarness.render(
            state,
            look: .dark,
            height: tallHeight
        )
        let short = try PanelHarness.render(
            state,
            look: .dark,
            height: shortHeight,
            name: "short-window"
        )

        let top = 0...(padding + selection)
        #expect(tall.profile(rows: top) == short.profile(rows: top))
        let bottom = { (rendered: PanelHarness.Rendered, points: Double) in
            rendered.profile(rows: (points - padding - disk)...points)
        }
        #expect(bottom(tall, tallHeight) == bottom(short, shortHeight))
        #expect(short.drawn(rows: top) > 100)
        #expect(bottom(short, shortHeight).reduce(0, +) > 100)
        // And the lists did lose room: less of them is drawn.
        let middle = { (rendered: PanelHarness.Rendered, points: Double) in
            rendered.drawn(rows: top.upperBound...(points - padding - disk))
        }
        #expect(middle(short, shortHeight) < middle(tall, tallHeight))
    }

    @Test func aWindowTooShortForThePanelScrollsItWhole() throws {
        // The largest interface zoom in a short window: the selection and
        // the disk alone are taller than the window. The panel scrolls as
        // one, from its top, rather than being centred and cut at both
        // ends.
        let fixture = try PanelHarness.fixture()
        defer { fixture.remove() }
        let state = try PanelHarness.state(fixture)
        try PanelScene.largestZoom.apply(to: state, fixture: fixture)
        let padding = Double(Space.lg.at(state.rem))
        for height in [520.0, 900.0] {
            let rendered = try PanelHarness.render(
                state,
                look: .dark,
                height: height,
                name: "largest-zoom-\(Int(height))"
            )
            // Nothing above the padding: the top was not pushed off.
            #expect(rendered.drawn(rows: 0...(padding - 2)) == 0)
            #expect(rendered.drawn(rows: padding...(padding + 40)) > 50)
        }
    }

    // MARK: The inspector

    @Test func theInspectorOpensAtTheWidthTheStateKeeps() throws {
        let fixture = try PanelHarness.fixture()
        defer { fixture.remove() }
        let state = try PanelHarness.state(fixture)
        state.panelRems = 31
        let (window, split) = try PanelHarness.inspector(state)
        defer { closeWindow(window) }
        let column = try PanelHarness.column(of: split)
        #expect(abs(column.frame.width - 31 * state.rem) < 1)
        // The panel fills its column, the whole height of the window.
        let panel = try #require(
            PanelHarness.views(NSScrollView.self, in: column).first
        )
        #expect(panel.window === window)
        #expect(column.frame.height > 800)
        // Opening at the kept width is not a new width to keep.
        PanelHarness.turn(for: SidePanel.widthSettles * 2)
        #expect(state.panelRems == 31)
    }

    @Test func resizingTheInspectorKeepsItsWidthForTheNextLaunch() throws {
        // The person drags the inspector's edge: the width it comes to rest
        // at is the panel's, in rem, saved with the preferences.
        let fixture = try PanelHarness.fixture()
        defer { fixture.remove() }
        let state = try PanelHarness.state(fixture)
        let (window, split) = try PanelHarness.inspector(state)
        defer { closeWindow(window) }
        let column = try PanelHarness.column(of: split)
        let before = column.frame.width
        let divider = split.arrangedSubviews.count - 2
        split.setPosition(
            split.bounds.width - before - 160,
            ofDividerAt: divider
        )
        split.layoutSubtreeIfNeeded()
        let dragged = column.frame.width
        #expect(abs(dragged - before - 160) < 1, "\(before) → \(dragged)")
        let kept = { abs(state.panelRems - dragged / state.rem) < 0.05 }
        PanelHarness.eventually(in: window, kept)
        #expect(kept())
        #expect(state.preferences.panelRems == state.panelRems)
    }

    @Test func theInspectorKeepsToThePanelsLimits() throws {
        // However far the edge is pulled, the column stays between the
        // panel's narrowest and widest, and so does the width kept.
        let fixture = try PanelHarness.fixture()
        defer { fixture.remove() }
        let state = try PanelHarness.state(fixture)
        let (window, split) = try PanelHarness.inspector(state, width: 1_600)
        defer { closeWindow(window) }
        let column = try PanelHarness.column(of: split)
        let divider = split.arrangedSubviews.count - 2
        let rem = state.rem

        split.setPosition(0, ofDividerAt: divider)
        split.layoutSubtreeIfNeeded()
        #expect(abs(column.frame.width - PanelSize.maxRems * rem) < 1)
        PanelHarness.eventually(in: window) {
            state.panelRems != PanelSize.rems
        }
        #expect(state.panelRems == PanelSize.maxRems)

        // Short of where the edge would close the inspector: it stops at
        // the narrowest.
        let narrowest = PanelSize.minRems * rem
        split.setPosition(
            split.bounds.width - narrowest + 30,
            ofDividerAt: divider
        )
        split.layoutSubtreeIfNeeded()
        #expect(abs(column.frame.width - narrowest) < 1)
        PanelHarness.eventually(in: window) {
            state.panelRems < PanelSize.rems
        }
        #expect(state.panelRems == PanelSize.minRems)
    }

    @Test func draggingTheInspectorShutHidesItAndKeepsItsWidth() throws {
        // Pulled well past its narrowest, a Mac inspector closes, as `p`
        // would close it; its width is the one it had, not its last frame
        // on the way out.
        let fixture = try PanelHarness.fixture()
        defer { fixture.remove() }
        let state = try PanelHarness.state(fixture)
        state.panelRems = 30
        let (window, split) = try PanelHarness.inspector(state)
        defer { closeWindow(window) }
        let divider = split.arrangedSubviews.count - 2
        split.setPosition(split.bounds.width, ofDividerAt: divider)
        split.layoutSubtreeIfNeeded()
        PanelHarness.eventually(in: window) { !state.showSelection }
        // Long enough for any width seen on the way out to have been kept.
        PanelHarness.turn(for: SidePanel.widthSettles * 2)
        #expect(!state.showSelection)
        #expect(state.panelRems == 30)
    }

    @Test func onlyAWidthThePanelRestsAtIsKept() throws {
        // Within the limits, in rem; not while the panel is hidden or on
        // its way out, and not a rounding of the width it has.
        let fixture = try PanelHarness.fixture()
        defer { fixture.remove() }
        let state = try PanelHarness.state(fixture)
        let rem = state.rem
        state.keepPanelWidth(30 * rem)
        #expect(state.panelRems == 30)
        state.keepPanelWidth(30 * rem + 0.3)
        #expect(state.panelRems == 30)
        state.keepPanelWidth(2 * rem)
        #expect(state.panelRems == PanelSize.minRems)
        state.keepPanelWidth(90 * rem)
        #expect(state.panelRems == PanelSize.maxRems)
        for nonsense in [0, -40, .nan, .infinity] as [CGFloat] {
            state.keepPanelWidth(nonsense)
            #expect(state.panelRems == PanelSize.maxRems)
        }
        state.showSelection = false
        state.keepPanelWidth(25 * rem)
        #expect(state.panelRems == PanelSize.maxRems)
        // At another zoom, the same points are fewer rem.
        state.showSelection = true
        state.zoomStep = zoomSteps.count - 1
        state.keepPanelWidth(28 * state.rem)
        #expect(abs(state.panelRems - 28) < 1e-9)
    }

    @Test func aWidthThatDoesNotHoldIsNotKept() throws {
        // An edge still being dragged, or the inspector sliding in: each
        // new width replaces the last before it has held, and only the one
        // it comes to rest at is written to the preferences, once.
        let fixture = try PanelHarness.fixture()
        defer { fixture.remove() }
        let state = try PanelHarness.state(fixture)
        let written = PanelWrites()
        state.preferenceStore = written
        let (window, split) = try PanelHarness.inspector(state)
        defer { closeWindow(window) }
        let column = try PanelHarness.column(of: split)
        let divider = split.arrangedSubviews.count - 2
        let start = column.frame.width
        for step in 1...4 {
            split.setPosition(
                split.bounds.width - start - CGFloat(step) * 30,
                ofDividerAt: divider
            )
            split.layoutSubtreeIfNeeded()
        }
        #expect(abs(column.frame.width - start - 120) < 1)
        PanelHarness.eventually(in: window) {
            !written.widths.isEmpty
        }
        // And nothing after it: the widths it passed through are not
        // waiting to be written late.
        PanelHarness.turn(for: SidePanel.widthSettles * 2)
        let rems = column.frame.width / state.rem
        #expect(written.widths.count == 1, "\(written.widths)")
        #expect(abs((written.widths.last ?? 0) - Double(rems)) < 1e-6)
    }

    // MARK: Words and numbers

    @Test func aFindingIsNamedByTheLastTwoPartsOfItsPath() {
        let leaf = Node.entry("pack", kind: .file, bytes: 1)
        let worktrees = Node.directory("worktrees", children: [leaf])
        let codex = Node.directory(".codex", children: [worktrees])
        let tries = Node.directory("tries")
        let tree = Node.directory("/home/me", children: [codex, tries])
        let text = { (crumbs: [Int], finding: Finding) in
            WorthSection.text(
                for: Candidate(crumbs: crumbs, bytes: 1, finding: finding),
                in: tree
            )
        }

        let deep = text([0, 0, 0], .reclaimable(.regenerable))
        #expect(deep.title == "worktrees/pack")
        #expect(deep.detail == Reclaim.regenerable.label)

        let many = text([0, 0], .worktrees(count: 3, oldestDays: 12))
        #expect(many.title == ".codex/worktrees")
        #expect(many.detail == "3 worktrees · oldest 12 d")
        let one = text([0, 0], .worktrees(count: 1, oldestDays: 0))
        #expect(one.detail == "1 worktree · oldest 0 d")

        // At the top level the root's own name, a whole path, is left out.
        let stale = text([1], .staleExperiments(count: 2))
        #expect(stale.title == "tries > \(staleDays) days")
        #expect(stale.detail == "2 experiments untouched")
        #expect(
            text([1], .staleExperiments(count: 1)).detail
                == "1 experiment untouched"
        )

        // Crumbs the tree no longer has say what they can.
        #expect(text([0, 9], .reclaimable(.trash)).title == ".codex")
        #expect(
            WorthSection.text(
                for: Candidate(
                    crumbs: [0],
                    bytes: 1,
                    finding: .reclaimable(.trash)
                ),
                in: nil
            ).title == ""
        )
    }

    @Test func theFixturesFindingsReadAsThePanelSaysThem() throws {
        let fixture = try PanelHarness.fixture()
        defer { fixture.remove() }
        let state = try PanelHarness.state(fixture)
        let lines = state.insights.map {
            WorthSection.text(for: $0, in: state.tree)
        }
        let titles = lines.map(\.title)
        // Largest first, as the list reads.
        #expect(
            titles == [
                "app/node_modules", ".cache", ".codex/worktrees",
                "rust/target", "tries > \(staleDays) days",
            ]
        )
        #expect(lines[0].detail == Reclaim.reinstallable.label)
        #expect(lines[2].detail == "2 worktrees · oldest 20 d")
        #expect(lines[4].detail == "1 experiment untouched")
    }

    @Test func theProjectionCountsOnlyWhatIsStillOnDisk() throws {
        // Removed marks are in the measured free space already: counting
        // them in "after" would claim their bytes twice (Invariant 9).
        let fixture = try PanelHarness.fixture()
        defer { fixture.remove() }
        let state = try PanelHarness.state(fixture)
        let target = { (path: String, bytes: UInt64) in
            Target(
                path: fixture.path(path),
                bytes: bytes,
                isDir: true,
                hidden: false
            )
        }
        let plan = Plan(
            targets: [target("junk", 300_000), target("keep", 1_000)],
            covered: [target("junk/deeper", 100_000)]
        )
        #expect(state.bytesStillOnDisk(plan) == 301_000)
        state.gone = [fixture.path("junk")]
        #expect(state.bytesStillOnDisk(plan) == 1_000)
        // A covered mark gone with its directory changes nothing: it was
        // never counted on its own.
        state.gone.insert(fixture.path("junk/deeper"))
        #expect(state.bytesStillOnDisk(plan) == 1_000)
        state.gone.insert(fixture.path("keep"))
        #expect(state.bytesStillOnDisk(plan) == 0)
    }

    @Test func theReviewButtonSaysWhatTheMarksWouldFree() {
        #expect(
            PanelReviewButton.label(count: 0, reclaiming: 0)
                == "Nothing marked to review"
        )
        #expect(
            PanelReviewButton.label(count: 3, reclaiming: 1_024)
                == "Review 3 marked · frees \(humanBytes(1_024))…"
        )
        // Every mark gone from disk: no saving is claimed for them.
        #expect(
            PanelReviewButton.label(count: 3, reclaiming: 0)
                == "Review 3 marked…"
        )
    }

    @Test func aBadgeRowWrapsWhenItRunsOutOfRoom() throws {
        // Chips side by side where there is room, on the next line where
        // there is not; and a chip wider than the whole line wraps inside
        // itself instead of running out of the panel.
        _ = NSApplication.shared
        let marked = Chip("Marked", color: Theme.dark.danger)
        let unreadable = Chip("Partly unreadable", color: Theme.dark.caution)
        let long = Chip(
            "Goes with a-directory-whose-name-runs-on",
            color: Theme.dark.danger
        )
        func height(_ view: some View, _ width: CGFloat) -> CGFloat {
            NSHostingView(rootView: view.frame(width: width)).fittingSize
                .height
        }
        let line = NSHostingView(rootView: marked).fittingSize.height
        let pair = WrappingRow(spacing: 4) {
            marked
            unreadable
        }
        #expect(abs(height(pair, 400) - line) < 0.5)
        #expect(abs(height(pair, 120) - (2 * line + 4)) < 0.5)

        let row = WrappingRow(spacing: 4) {
            marked
            long
        }
        let wrapped = height(long, 120)
        #expect(wrapped > line + 0.5, "the long chip takes two lines")
        #expect(abs(height(row, 120) - (line + 4 + wrapped)) < 0.5)
    }
}

/// A preference store that only listens for the panel's width, each time
/// it is written.
@MainActor
private final class PanelWrites: PreferenceStore {
    var widths: [Double] = []

    nonisolated func object(forKey key: String) -> Any? { nil }

    nonisolated func set(_ value: Any?, forKey key: String) {
        guard key == Preferences.Key.panelRems.rawValue,
            let width = value as? Double
        else { return }
        MainActor.assumeIsolated {
            widths.append(width)
        }
    }
}
