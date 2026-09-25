// The review screen's Mac manners: its actions as the window's toolbar
// items and its summary as the window's subtitle; the marked list as a
// table that sorts, selects several rows, unmarks them with ⌫ and hands a
// row over by dragging it; the disk as one bar that never claims more than
// it can measure; Copy Command answering a copy with a checkmark; and a
// screen that still draws, and still means the same, with Reduce Motion.
//
// The table is AppKit's, so it is pressed as AppKit is: clicks and keys
// sent to the window, never its methods called. Nothing here touches the
// real pasteboard, Finder or Quick Look: the screen's actions go to a
// recorder, and the state's to its hooks.

import AppKit
import DisktreeCore
import Foundation
import SwiftUI
import System
import Testing
import UniformTypeIdentifiers

@testable import DisktreeApp

private let gib: UInt64 = 1 << 30

private let disk = SpaceInfo(
    total: 952 * gib,
    free: 16 * gib,
    available: 14 * gib
)

/// The three marks the Rust tests made, in this order: a directory, a
/// hidden directory and a file. `junk` and `.cache` weigh the same, so the
/// order two equal rows keep is visible.
@MainActor
private func markThree(_ state: AppState) throws {
    try reviewMark(state, "junk")
    try reviewMark(state, ".cache")
    try reviewMark(state, "keep/notes.txt")
    state.space = disk
    state.spaceBaseline = disk
}

/// A model of marks that exist only on paper, for what needs no disk:
/// every mark a target of `bytes`, under `/tmp/marks`.
private func paperModel(_ sizes: [UInt64]) -> ReviewModel {
    let items = sizes.enumerated().map { index, bytes in
        Target(
            path: FilePath("/tmp/marks/file-\(index)"),
            bytes: bytes,
            isDir: false,
            hidden: false
        )
    }
    return ReviewModel(
        items: items,
        plan: Plan(targets: items),
        command: nil,
        style: .trash,
        gone: [],
        space: disk,
        measuredGain: nil,
        rootBytes: sizes.reduce(0, +),
        home: nil,
        volumeName: nil,
        notice: nil
    )
}

// MARK: - The toolbar

/// The names of the screen's controls drawn in its own content, noted as
/// the content is laid out.
@MainActor
private final class DrawnControls {
    var names: Set<String> = []

    func note(_ names: some Sequence<String>) -> Color {
        self.names = Set(names)
        return Color.clear
    }
}

@MainActor
@Test func theActionsAreTheWindowsToolbarItems() throws {
    // In a window whose content hands SwiftUI its toolbar and title, as
    // the app's does, back, the command's style, Reveal in Finder and Copy
    // Command join the toolbar's items, the title and summary are the
    // window's, and the screen draws no bar of its own; the command keeps
    // its copy button.
    let fixture = try ReviewFixture()
    let state = try reviewState(fixture)
    try markThree(state)
    let review = reviewFromCore(state)
    let drawn = DrawnControls()
    _ = NSApplication.shared
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: reviewWindowSize),
        styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    let controller = NSHostingController(
        rootView: ReviewScreen(
            review: review,
            actions: ReviewActionLog().recording
        )
        .environment(\.theme, Theme.dark)
        .backgroundPreferenceValue(ReviewControls.self) { anchors in
            drawn.note(anchors.keys)
        }
        // The window's own item, as the root's are: what makes the
        // toolbar SwiftUI's before the screen says anything.
        .toolbar {
            ToolbarItem(placement: .automatic) { Text(verbatim: "root") }
        }
    )
    controller.sceneBridgingOptions = [.toolbars, .title]
    window.contentViewController = controller
    defer { closeWindow(window) }
    // The toolbar arrives a pass after the content, and the screen hears
    // of it on the turn after that.
    for _ in 0..<6 {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
    }
    #expect(ReviewHost.bridges(window.toolbar))
    let items = try #require(window.toolbar?.items)
    #expect(items.count == 1 + 4, "\(items.map(\.itemIdentifier))")
    #expect(window.title == "Review")
    #expect(window.subtitle == review.subtitle)
    for bar in ["review-back", "review-style", "review-reveal", "review-copy"] {
        #expect(!drawn.names.contains(bar), "\(bar) drawn in the content")
    }
    #expect(drawn.names.contains("review-command-copy"))
    #expect(drawn.names.contains("review-clear"))
}

@MainActor
@Test func aToolbarAppKitKeepsIsLeftAlone() throws {
    // A window with a toolbar of its own, as one kept only for the title
    // bar's height: the screen draws its bar, adds nothing to that toolbar
    // and does not take it over.
    let fixture = try ReviewFixture()
    let state = try reviewState(fixture)
    try markThree(state)
    let drawn = DrawnControls()
    _ = NSApplication.shared
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: reviewWindowSize),
        styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    let toolbar = NSToolbar(identifier: "review-test")
    window.toolbar = toolbar
    window.contentView = NSHostingView(
        rootView: ReviewView(state: state)
            .environment(\.theme, Theme.light)
            .backgroundPreferenceValue(ReviewControls.self) { anchors in
                drawn.note(anchors.keys)
            }
    )
    defer { closeWindow(window) }
    for _ in 0..<6 {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
    }
    #expect(window.toolbar === toolbar)
    #expect(toolbar.items.isEmpty)
    #expect(!ReviewHost.bridges(window.toolbar))
    #expect(drawn.names.contains("review-copy"))
}

@Test func theControlsGrowWithTheInterfaceZoom() {
    let sizes = zoomSteps.map { reviewControlSize(baseRem * $0) }
    #expect(reviewControlSize(baseRem) == .large)
    #expect(sizes.first == .regular && sizes.last == .extraLarge)
}

// MARK: - The rows

@MainActor
@Test func eachRowSaysWhatTheGuardsMadeOfItsMark() throws {
    let fixture = try ReviewFixture()
    let state = try reviewState(fixture)
    try markThree(state)
    // A mark inside another, left behind by a re-scan; the scanned root.
    try reviewMark(state, "junk/deeper")
    state.marks.toggle(
        Target(path: fixture.root, bytes: 601_000, isDir: true, hidden: false)
    )
    state.gone = [fixture.path("keep/notes.txt")]
    let review = reviewFromCore(state)
    let byName = Dictionary(
        review.rows.map { ($0.name, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    let junk = try #require(byName["junk"])
    #expect(junk.status == .ready && junk.handedOver)
    #expect(junk.statusText.isEmpty)
    #expect(junk.spoken.hasSuffix("in the command"))

    let deeper = try #require(byName["deeper"])
    #expect(deeper.status == .covered(by: normalize(fixture.path("junk"))))
    #expect(deeper.statusText == "goes with junk")
    #expect(!deeper.handedOver)

    let root = try #require(byName[reviewName(fixture.root)])
    #expect(root.status == .blocked("the scanned root cannot be removed"))
    #expect(root.statusText.hasPrefix("kept back: "))

    let notes = try #require(byName["notes.txt"])
    #expect(notes.status == .gone && notes.symbol == "checkmark")
    #expect(notes.spoken.contains("gone from disk"))

    let cache = try #require(byName[".cache"])
    #expect(cache.hidden && cache.spoken.contains("hidden"))
    #expect(cache.folder == displayPath(fixture.root, home: state.home))

    // Marking order names each row's controls, whatever the sort.
    #expect(review.rows.map(\.index) == Array(review.rows.indices))
}

@Test func theListRanksLargestFirstAndEqualRowsKeepMarkingOrder() {
    let review = paperModel([10, 300, 300, 5, 300])
    let sizes = review.listed(by: ReviewRow.defaultOrder)
    #expect(sizes.map(\.index) == [1, 2, 4, 0, 3])
    // The other way up, the equal rows still keep marking order: the
    // tie-break is its own comparator, not the sort's accident.
    let rising = review.listed(
        by: [KeyPathComparator(\ReviewRow.bytes, order: .forward)]
    )
    #expect(rising.map(\.index) == [3, 0, 1, 2, 4])
    let names = review.listed(by: [KeyPathComparator(\ReviewRow.name)])
    #expect(names.map(\.name) == names.map(\.name).sorted())
}

@Test func theCapLeavesOutTheEndOfTheSortedList() {
    // Past the cap, a list sorted by size leaves out the smallest marks,
    // not the last ones made.
    let count = reviewListLimit + 5
    let review = paperModel((0..<count).map { UInt64($0 + 1) })
    let listed = review.listed(by: ReviewRow.defaultOrder)
    #expect(listed.count == reviewListLimit)
    #expect(listed.first?.index == count - 1)
    #expect(!listed.contains { $0.bytes <= 5 })
}

@MainActor
@Test func onlyWhatTheCommandCarriesCanBeDragged() throws {
    let fixture = try ReviewFixture()
    let state = try reviewState(fixture)
    try markThree(state)
    try reviewMark(state, "junk/deeper")
    state.marks.toggle(
        Target(path: fixture.root, bytes: 601_000, isDir: true, hidden: false)
    )
    state.gone = [fixture.path("keep/notes.txt")]
    let rows = reviewFromCore(state).rows
    for row in rows {
        let item = reviewDragItem(row)
        #expect((item != nil) == (row.status == .ready), "\(row.name)")
        if let item {
            // As Finder hands a file over: a file URL, which Finder, a
            // Terminal window and the Trash in the Dock all take.
            #expect(
                item.registeredTypeIdentifiers.contains(
                    UTType.fileURL.identifier
                )
            )
            #expect(item.suggestedName == row.name)
        }
    }
    #expect(rows.count { reviewDragItem($0) != nil } == 2)
}

// MARK: - The context menu

@MainActor
@Test func theContextMenuOffersWhatItsRowsAllow() throws {
    let fixture = try ReviewFixture()
    let state = try reviewState(fixture)
    try markThree(state)
    state.gone = [fixture.path(".cache")]
    let rows = reviewFromCore(state).rows
    let junk = try #require(rows.first { $0.name == "junk" })
    let cache = try #require(rows.first { $0.name == ".cache" })

    let one = ReviewRowCommand.menu(for: [junk])
    #expect(one.map(\.kind) == ReviewRowCommand.Kind.allCases)
    #expect(one.allSatisfy { $0.enabled })
    #expect(one.map(\.title).contains("Copy Path"))

    // A path gone from disk can still be copied or unmarked, not looked at.
    let gone = ReviewRowCommand.menu(for: [cache])
    let enabled = Set(gone.filter(\.enabled).map(\.kind))
    #expect(enabled == [.copyPath, .unmark])

    let both = ReviewRowCommand.menu(for: [junk, cache])
    #expect(both.map(\.title).contains("Copy 2 Paths"))
    #expect(both.map(\.title).contains("Unmark 2 Items"))
    #expect(both.first { $0.kind == .quickLook }?.enabled == false)
    #expect(both.first { $0.kind == .reveal }?.enabled == true)
    #expect(ReviewRowCommand.menu(for: []).isEmpty)

    let recorder = ReviewActionLog()
    let actions = recorder.recording
    ReviewRowCommand.Kind.reveal.perform(on: [junk, cache], actions)
    ReviewRowCommand.Kind.copyPath.perform(on: [junk, cache], actions)
    ReviewRowCommand.Kind.quickLook.perform(on: [cache], actions)
    ReviewRowCommand.Kind.quickLook.perform(on: [junk], actions)
    ReviewRowCommand.Kind.unmark.perform(on: [junk, cache], actions)
    #expect(
        recorder.actions == [
            // Finder is not shown a path that is not there.
            .revealPaths([junk.path]),
            .copyPaths([junk.path, cache.path]),
            .quickLook(junk.path),
            .unmark(junk.path),
            .unmark(cache.path),
        ]
    )
}

@MainActor
@Test func theRowActionsReachTheStatesHooksAndRemoveNothing() throws {
    let fixture = try ReviewFixture()
    let hooks = ReviewHooks()
    let state = try reviewState(fixture, hooks: hooks)
    try markThree(state)
    let actions = ReviewActions.calling(state)
    let junk = fixture.path("junk")
    let notes = fixture.path("keep/notes.txt")

    actions.copyPaths([junk, notes])
    #expect(hooks.copied == ["\(junk.string)\n\(notes.string)"])
    #expect(state.toast?.text == "Copied 2 paths")
    actions.copyPaths([junk])
    let shown = displayPath(junk, home: state.home)
    #expect(state.toast?.text == "Copied \(shown)")

    actions.revealPaths([junk, notes])
    #expect(hooks.revealed == [[junk, notes]])

    // Spread over more folders than Finder should open windows for, the
    // rows are not revealed: the notice points at the command instead.
    let many = (0...AppState.finderFolderLimit).map {
        fixture.root.appending("folder-\($0)/file")
    }
    actions.revealPaths(many)
    #expect(hooks.revealed.count == 1)
    #expect(state.notice?.status == .warning)

    actions.quickLook(junk)
    #expect(state.quickLookTarget == junk)

    for path in ["junk/blob.bin", ".cache/blob.bin", "keep/notes.txt"] {
        let file = fixture.path(path).string
        #expect(FileManager.default.fileExists(atPath: file))
    }
}

// MARK: - The table, pressed

/// The screen over the three marks, in the dark, with its recorder.
@MainActor
private func threeMarks(
    order: [KeyPathComparator<ReviewRow>] = ReviewRow.defaultOrder
) throws -> (ReviewFixture, AppState, ReviewActionLog, ReviewStage) {
    let fixture = try ReviewFixture()
    let state = try reviewState(fixture)
    try markThree(state)
    let recorder = ReviewActionLog()
    let stage = try ReviewStage(
        ReviewScreen(
            review: reviewFromCore(state),
            actions: recorder.recording,
            order: order
        ),
        appearance: .darkAqua
    )
    return (fixture, state, recorder, stage)
}

/// Where to click to pick a row rather than press its unmark button: on
/// its name.
@MainActor
private func nameOf(_ stage: ReviewStage, _ index: Int) throws -> CGPoint {
    let row = try stage.row(index)
    return CGPoint(x: row.minX + Rems(4).at(baseRem), y: row.midY)
}

@MainActor
@Test func theTableShowsTheLargestFirstAndSortsByItsHeader() throws {
    let (_, _, _, stage) = try threeMarks()
    defer { stage.close() }
    // junk and .cache weigh the same and keep marking order; notes.txt is
    // the smallest.
    let heights = try (0..<3).map { try stage.row($0).minY }
    #expect(heights == heights.sorted(), "\(heights)")

    // A click on Size's header turns the order round, as it would in
    // Finder.
    let table = try #require(stage.table)
    let header = try #require(table.headerView)
    let size = try #require(
        table.tableColumns.firstIndex { $0.title == "Size" }
    )
    let rect = header.convert(header.headerRect(ofColumn: size), to: stage.host)
    try stage.pick(at: CGPoint(x: rect.midX, y: rect.midY))
    // The rows move to their new places: read them once they are there.
    stage.settle(0.5)
    let turned = try (0..<3).map { try stage.row($0).minY }
    #expect(turned[2] < turned[0] && turned[0] < turned[1], "\(turned)")
}

@MainActor
@Test func deleteUnmarksTheSelectedRows() throws {
    let (fixture, state, recorder, stage) = try threeMarks()
    defer { stage.close() }
    let items = state.marks.items

    try stage.pick(at: nameOf(stage, 2))
    #expect(recorder.actions.isEmpty, "picking a row is not acting on it")
    try stage.press(keyCode: 51, characters: "\u{7F}")
    #expect(recorder.actions == [.unmark(items[2].path)])

    // Several at once: a click, then ⌘-click another.
    recorder.actions.removeAll()
    try stage.pick(at: nameOf(stage, 0))
    try stage.pick(at: nameOf(stage, 1), modifiers: .command)
    try stage.press(keyCode: 51, characters: "\u{7F}")
    #expect(
        Set(recorder.actions)
            == [.unmark(items[0].path), .unmark(items[1].path)]
    )
    #expect(recorder.actions.count == 2)
    #expect(FileManager.default.fileExists(atPath: fixture.path("junk").string))
}

@MainActor
@Test func copyWithARowSelectedCopiesItsPath() throws {
    let (_, state, recorder, stage) = try threeMarks()
    defer { stage.close() }
    try stage.pick(at: nameOf(stage, 1))
    // Only once the table holds the keyboard: sent anywhere else, Copy
    // could reach a real text view and the real pasteboard.
    let responder = try #require(stage.window.firstResponder as? NSView)
    try #require(responder is NSTableView)
    // As the Edit menu sends it: up the responder chain from the view
    // holding the keyboard. (The app is never active in a test, so there
    // is no key window for `sendAction(_:to:from:)` to start from.)
    #expect(responder.tryToPerform(#selector(NSText.copy(_:)), with: nil))
    stage.settle()
    #expect(recorder.actions == [.copyPaths([state.marks.items[1].path])])
}

@MainActor
@Test func aDoubleClickLooksInside() throws {
    let (_, state, recorder, stage) = try threeMarks()
    defer { stage.close() }
    try stage.pick(at: nameOf(stage, 0), count: 2)
    #expect(recorder.actions == [.quickLook(state.marks.items[0].path)])
}

// MARK: - Copy Command's checkmark

@MainActor
@Test func theCopyButtonWatchesTheCopyToastAndNoOther() throws {
    let fixture = try ReviewFixture()
    let state = try reviewState(fixture)
    try markThree(state)
    #expect(ReviewModel(state).copiedAt == nil)
    let before = Date.now
    state.copyCommand()
    #expect(state.toast?.text.hasPrefix(reviewCopiedToast) == true)
    // When the toast went up, which is when the command was copied.
    let copiedAt = try #require(ReviewModel(state).copiedAt)
    #expect(abs(copiedAt.timeIntervalSince(before)) < 0.5)
    // A copied path, or Finder shown the marks, is not a copied command.
    ReviewActions.calling(state).copyPaths([fixture.path("junk")])
    #expect(ReviewModel(state).copiedAt == nil)
    state.copyCommand()
    state.revealMarkedInFinder()
    #expect(ReviewModel(state).copiedAt == nil)
    state.copyCommand()
    state.dismissToast()
    #expect(ReviewModel(state).copiedAt == nil)
}

@MainActor
@Test func theCheckmarkLastsAMomentAndNoLonger() {
    let copied = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let moment = reviewCopiedFor / .seconds(1)
    #expect(!reviewShowsCopied(nil, at: copied))
    #expect(reviewShowsCopied(copied, at: copied))
    #expect(reviewShowsCopied(copied, at: copied.addingTimeInterval(1)))
    #expect(!reviewShowsCopied(copied, at: copied.addingTimeInterval(moment)))
    // Well before the toast that says the same goes.
    let toast = AppState.toastDuration / .seconds(1)
    #expect(moment < toast)
}

@MainActor
@Test func copyCommandShowsACheckmarkJustAfterACopy() throws {
    let fixture = try ReviewFixture()
    let state = try reviewState(fixture)
    try markThree(state)
    var review = reviewFromCore(state)
    let plain = try copyButton(review)
    review.copiedAt = .now
    #expect(try copyButton(review) != plain, "no checkmark after a copy")
    // A copy long enough ago is drawn as no copy at all.
    review.copiedAt = Date.now.addingTimeInterval(-2)
    #expect(try copyButton(review) == plain, "the checkmark stayed")
}

/// The Copy Command button's pixels, drawn from `review` without
/// animations: SwiftUI advances one from the display link of the screen a
/// window is on, and this one is on none, so a symbol swapped in with one
/// would be drawn half way.
@MainActor
private func copyButton(_ review: ReviewModel) throws -> [UInt8] {
    let stage = try ReviewStage(
        ReviewScreen(review: review, actions: ReviewActionLog().recording)
            .transaction { $0.disablesAnimations = true },
        appearance: .darkAqua
    )
    defer { stage.close() }
    let rep = try stage.render()
    let frame = try #require(stage.controls["review-copy"])
    let pixels = try ReviewPixels(rep)
    let scale = CGFloat(pixels.width) / reviewWindowSize.width
    let rows = Int(frame.minY * scale)..<Int(frame.maxY * scale)
    let columns = Int(frame.minX * scale)..<Int(frame.maxX * scale)
    var bytes: [UInt8] = []
    for y in rows {
        let start = (y * pixels.width + columns.lowerBound) * 4
        bytes += pixels.bytes[start..<(start + columns.count * 4)]
    }
    return bytes
}

// MARK: - The disk

@Test func theDiskBarAddsUpToTheDisk() {
    for pending: UInt64 in [0, 300_000, 3 * gib, 2_000 * gib] {
        let segments = DiskChart.segments(space: disk, pending: pending)
        #expect(segments.map(\.kind) == DiskChart.Segment.Kind.allCases)
        // Edge to edge, in order, from nothing to the whole disk.
        #expect(segments.first?.start == 0)
        #expect(segments.last?.end == Double(disk.total))
        for (left, right) in zip(segments, segments.dropFirst()) {
            #expect(left.end == right.start)
            #expect(left.start <= left.end)
        }
        // What the marks free is never more than what is used.
        let freeing = segments[1].end - segments[1].start
        #expect(freeing == Double(min(pending, disk.used)))
    }
}

@Test func theDiskSaysWhichNumbersAreMeasured() {
    // Nothing marked: nothing to project, and nothing called projected.
    let idle = DiskChart.lines(space: disk, pending: 0)
    #expect(idle.allSatisfy { $0.note == "measured" })
    #expect(idle.map(\.label) == ["Used", "Free now"])
    #expect(idle.last?.bytes == disk.available)

    let pending: UInt64 = 3 * gib
    let lines = DiskChart.lines(space: disk, pending: pending)
    let after = disk.afterRemoving(pending)
    let byLabel = Dictionary(uniqueKeysWithValues: lines.map { ($0.label, $0) })
    // `statfs` said this; the rest is the marked bytes held against it
    // (Invariant 9).
    #expect(byLabel["Free now"]?.note == "measured")
    #expect(byLabel["Free now"]?.bytes == disk.available)
    #expect(byLabel["The marks free"]?.note == "projected")
    #expect(byLabel["The marks free"]?.bytes == pending)
    #expect(byLabel["Used after"]?.bytes == after.used)
    #expect(byLabel["Free after"]?.bytes == after.available)
    #expect(byLabel["Free after"]?.note == "projected")
}

@MainActor
@Test func theChartDrawsTheSliceTheMarksFree() throws {
    // A disk nearly all marked, so the slice is wide enough to find: the
    // hatched highlight is drawn where the chart put it, and nowhere with
    // nothing marked.
    let space = SpaceInfo(total: 100 * gib, free: 20 * gib, available: 20 * gib)
    /// Pixels of the bar, and not its legend, whose swatch is hatched too,
    /// that are amber rather than grey: red well above blue.
    // The middle of the bar is the slice the marks free when there are
    // marks — hatched in the highlight — and plain "used" when there are
    // none. Compare how much colour it carries, whatever the palette: in
    // this one "used" shares the highlight's hue family, and a stripe one
    // pixel wide is blended with the tint beneath it, so neither a hue nor
    // an exact colour tells them apart; saturation does.
    func middleSaturation(_ pending: UInt64) throws -> Double {
        let stage = try ReviewStage(
            DiskChart(space: space, pending: pending)
                .padding(20)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .top
                ),
            appearance: .aqua,
            size: CGSize(width: 400, height: 200)
        )
        defer { stage.close() }
        let rep = try stage.render()
        keepReviewSnapshot(rep, "review-disk-chart-\(pending / gib)")
        let pixels = try ReviewPixels(rep)
        let scale = pixels.width / 400
        let bar = Int(Space.md.at(baseRem)) * scale
        var total = 0.0
        var count = 0
        for y in (20 * scale)..<(20 * scale + bar) {
            for x in (140 * scale)..<(260 * scale) {
                let at = (y * pixels.width + x) * 4
                let alpha = Double(pixels.bytes[at + 3]) / 255
                guard alpha > 0.5 else { continue }
                let pixel = HSLA.fromRGB(
                    RGBA(
                        r: Double(pixels.bytes[at]) / 255 / alpha,
                        g: Double(pixels.bytes[at + 1]) / 255 / alpha,
                        b: Double(pixels.bytes[at + 2]) / 255 / alpha
                    )
                )
                total += pixel.s
                count += 1
            }
        }
        return count == 0 ? 0 : total / Double(count)
    }
    let without = try middleSaturation(0)
    let with = try middleSaturation(60 * gib)
    #expect(with > without + 0.15, "\(with) against \(without)")
}

// MARK: - Motion

@Test func reduceMotionOnlyFades() {
    #expect(ReviewMotion.bars(true) == nil)
    #expect(ReviewMotion.rows(true) == nil)
    #expect(ReviewMotion.bars(false) != nil)
    #expect(ReviewMotion.rows(false) != nil)
    #expect(ReviewMotion.change(true) == ReviewMotion.fade)
    #expect(ReviewMotion.strike(true) == ReviewMotion.fade)
}

@MainActor
@Test func theScreenDrawsWithReduceMotion() throws {
    let fixture = try ReviewFixture()
    let state = try reviewState(fixture)
    try markThree(state)
    state.gone = [fixture.path("junk")]
    var review = reviewFromCore(state, measuredGain: 200_000)
    review.copiedAt = .now
    for (look, appearance) in [
        ("light", NSAppearance.Name.aqua), ("dark", .darkAqua),
    ] {
        let stage = try ReviewStage(
            ReviewScreen(review: review, actions: ReviewActionLog().recording)
                .environment(\._accessibilityReduceMotion, true),
            appearance: appearance
        )
        defer { stage.close() }
        let rep = try stage.render()
        keepReviewSnapshot(rep, "review-reduce-motion-\(look)")
        let pixels = try ReviewPixels(rep)
        #expect(pixels.differing(from: stage.theme.background) > 20_000)
        #expect(stage.controls["unmark-0"] != nil)
    }
}
