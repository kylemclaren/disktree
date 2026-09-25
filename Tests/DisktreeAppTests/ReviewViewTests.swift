// The review screen, drawn and pressed through a real window.
//
// Every state the screen can be in is drawn, in both appearances, into real
// pixels: a screen that crashes while drawing, or draws nothing, fails here
// rather than on someone's disk. The controls are clicked the way a mouse
// clicks them, and must reach the action they name.
//
// Ported from the Rust window tests that still apply
// (`a_view_without_flags_or_marks_still_draws`, `both_appearances_draw`,
// `the_review_screen_switches_removal_mode` as the command style). The ones
// about the removal run, the delete dialog and the trash backend
// (`a_permanent_deletion_asks_in_an_alert_dialog_then_removes`,
// `escape_in_the_delete_dialog_cancels`,
// `the_trash_is_the_default_when_there_is_one`) cover code that is gone:
// disktree removes nothing itself. What replaces them is here too — the
// command shown is the command copied, and nothing the screen does removes
// a file.

import AppKit
import DisktreeCore
import Foundation
import SwiftUI
import System
import Testing

@testable import DisktreeApp

// MARK: - The states

/// One state the screen can be in, and how to get there from the fixture.
private struct Scenario: Sendable {
    let name: String
    /// What `statfs` would say the disk gained; the stub cannot.
    var measuredGain: UInt64?
    let setUp: @MainActor @Sendable (ReviewFixture, AppState) throws -> Void
}

private let gib: UInt64 = 1 << 30

/// A disk that is nearly full, as the review is usually opened on.
private let fullDisk = SpaceInfo(
    total: 952 * gib,
    free: 16 * gib,
    available: 14 * gib
)

/// The three marks the Rust tests made: a directory, a hidden directory and
/// a file.
@MainActor
private func markThree(_ state: AppState) throws {
    try reviewMark(state, "junk")
    try reviewMark(state, ".cache")
    try reviewMark(state, "keep/notes.txt")
    state.space = fullDisk
    state.spaceBaseline = fullDisk
}

/// Names that are long, and that a shell would read if they were not
/// quoted: the command has to carry them whole.
private let awkwardNames = [
    "a directory with spaces",
    "it's quoted",
    "$HOME and `backticks`",
    "a-very-long-directory-name-that-keeps-going-well-past-any-column",
]

/// A dozen files at every depth under each awkward name: long lines, and
/// more of them than the command's well shows at once.
private func awkwardPaths() -> [String] {
    awkwardNames.enumerated().flatMap { index, name in
        (0..<12).map { depth in
            "\(name)/\(String(repeating: "deeper/", count: depth))"
                + "file-\(index)-\(depth).bin"
        }
    }
}

private let scenarios: [Scenario] = [
    Scenario(name: "empty") { _, state in
        state.space = fullDisk
    },
    Scenario(name: "one") { _, state in
        try reviewMark(state, "junk")
        state.space = fullDisk
        state.spaceBaseline = fullDisk
    },
    Scenario(name: "trash") { _, state in
        try markThree(state)
        state.commandStyle = .trash
        state.notice = Notice(
            "Copied: trash for 3 items, 586 KiB \u{2014} paste it into "
                + "Terminal",
            status: .success
        )
    },
    Scenario(name: "rm") { _, state in
        try markThree(state)
        state.commandStyle = .remove
    },
    Scenario(name: "covered-and-blocked") { fixture, state in
        try markThree(state)
        // A mark inside another: the treemap refuses to make one, but a
        // re-scan can leave one behind, and the plan must still say so.
        try reviewMark(state, "junk/deeper")
        // The scanned root itself, and the directory holding it.
        state.marks.toggle(
            Target(
                path: fixture.root,
                bytes: 601_000,
                isDir: true,
                hidden: false
            )
        )
        state.marks.toggle(
            Target(
                path: fixture.root.removingLastComponent(),
                bytes: 4 * gib,
                isDir: true,
                hidden: false
            )
        )
    },
    Scenario(name: "some-gone", measuredGain: 200_000) { fixture, state in
        try markThree(state)
        state.gone = [fixture.path("junk")]
    },
    Scenario(name: "all-gone", measuredGain: 601_000) { _, state in
        try markThree(state)
        state.gone = Set(state.marks.items.map(\.path))
    },
    Scenario(name: "gain-short", measuredGain: 4_096) { fixture, state in
        try markThree(state)
        state.gone = [fixture.path("junk"), fixture.path(".cache")]
    },
    Scenario(name: "gone-unmeasured") { fixture, state in
        try markThree(state)
        state.gone = [fixture.path(".cache")]
    },
    Scenario(name: "no-space") { _, state in
        try markThree(state)
        state.space = nil
        state.spaceBaseline = nil
    },
    Scenario(name: "long-command") { fixture, state in
        let paths = awkwardPaths()
        for (index, path) in paths.enumerated() {
            try fixture.write(path, bytes: 1_000 * (index % 12 + 1))
        }
        try rescan(fixture, state)
        for path in paths {
            try reviewMark(state, path)
        }
        state.space = fullDisk
    },
    Scenario(name: "over-the-cap") { fixture, state in
        let count = reviewListLimit + 37
        for index in 0..<count {
            try fixture.write("many/file-\(index).bin", bytes: 100)
        }
        try rescan(fixture, state)
        for index in 0..<count {
            try reviewMark(state, "many/file-\(index).bin")
        }
        state.space = fullDisk
    },
]

/// Scan the fixture again after a scenario added to it.
@MainActor
private func rescan(_ fixture: ReviewFixture, _ state: AppState) throws {
    state.tree = try scan(fixture.root, options: reviewOptions)
}

/// A state in `scenario`, and what the screen would read from it once the
/// state is integrated.
@MainActor
private func staged(
    _ scenario: Scenario,
    _ fixture: ReviewFixture
) throws -> (AppState, ReviewModel) {
    let state = try reviewState(fixture)
    try scenario.setUp(fixture, state)
    return (state, reviewFromCore(state, measuredGain: scenario.measuredGain))
}

private let appearances: [(String, NSAppearance.Name)] = [
    ("light", .aqua),
    ("dark", .darkAqua),
]

/// Every control the screen names, whatever state it is in: in a window
/// without a toolbar, as the stage's is, the actions are in the screen's
/// own bar.
private let namedControls = [
    "review-copy", "review-reveal", "review-command", "review-back",
    "review-clear", "review-style", "review-command-copy",
]

// MARK: - Drawing

@MainActor
@Test(arguments: scenarios.map(\.name))
func theReviewScreenDrawsInEveryState(_ name: String) throws {
    let scenario = try #require(scenarios.first { $0.name == name })
    let fixture = try ReviewFixture()
    let (_, review) = try staged(scenario, fixture)
    for (look, appearance) in appearances {
        let recorder = ReviewActionLog()
        let stage = try ReviewStage(
            ReviewScreen(review: review, actions: recorder.recording),
            appearance: appearance
        )
        defer { stage.close() }
        let rep = try stage.render()
        keepReviewSnapshot(rep, "review-\(name)-\(look)")
        let pixels = try ReviewPixels(rep)
        #expect(pixels.width > 0 && pixels.height > 0)
        // Far more than a blank window: text, lanes, wells and borders.
        #expect(
            pixels.differing(from: stage.theme.background) > 20_000,
            "\(name) in \(look) drew almost nothing"
        )
        for control in namedControls {
            #expect(stage.controls[control] != nil, "\(name): no \(control)")
        }
        // Drawing is not acting.
        #expect(recorder.actions.isEmpty)

        // The main action is drawn, whole, in the bar across the top: a
        // prominent button is a filled bezel whether or not there is a
        // command to copy (the system dims it when there is none, and
        // `nothingToHandOverDisablesTheHandOver` presses it).
        let copy = try #require(stage.controls["review-copy"])
        let scale = CGFloat(pixels.width) / reviewWindowSize.width
        let ground = pixels.count(
            stage.theme.background,
            in: copy,
            scale: scale,
            tolerance: 2
        )
        let area = Int(copy.width * copy.height * scale * scale)
        #expect(ground < area / 2, "\(name) in \(look): \(ground)/\(area)")
        #expect(
            copy.minY >= 0 && copy.maxY <= Rems(4).at(baseRem)
        )
    }
}

@MainActor
@Test func theRealViewDrawsOverTheState() throws {
    // `ReviewView` reads the state itself: with the contract's stubs it has
    // no plan and no command yet, and it must still draw, as the Rust
    // `a_view_without_flags_or_marks_still_draws` asks of every screen.
    let fixture = try ReviewFixture()
    let hooks = ReviewHooks()
    let state = try reviewState(fixture, hooks: hooks)
    try markThree(state)
    state.gone = [fixture.path("junk")]
    for (look, appearance) in appearances {
        let stage = try ReviewStage(
            ReviewView(state: state),
            appearance: appearance,
            rem: state.rem
        )
        defer { stage.close() }
        let rep = try stage.render()
        keepReviewSnapshot(rep, "review-state-\(look)")
        let pixels = try ReviewPixels(rep)
        #expect(pixels.differing(from: stage.theme.background) > 20_000)
        #expect(stage.controls["review-copy"] != nil)
    }
    #expect(hooks.copied.isEmpty && hooks.revealed.isEmpty)
}

@MainActor
@Test(arguments: [zoomSteps[0], 1, zoomSteps[zoomSteps.count - 1]])
func theReviewScreenFitsAtTheDefaultAndTheExtremeZooms(
    _ step: CGFloat
) throws {
    let fixture = try ReviewFixture()
    let scenario = try #require(scenarios.first { $0.name == "gain-short" })
    let (_, review) = try staged(scenario, fixture)
    // The window the app opens at, and the smallest it can be made.
    for size in [reviewWindowSize, CGSize(width: 900, height: 600)] {
        for (look, appearance) in appearances {
            let stage = try ReviewStage(
                ReviewScreen(
                    review: review,
                    actions: ReviewActionLog().recording
                ),
                appearance: appearance,
                rem: baseRem * step,
                size: size
            )
            defer { stage.close() }
            let rep = try stage.render()
            keepReviewSnapshot(
                rep,
                "review-zoom-\(step)-\(Int(size.width))-\(look)"
            )
            let pixels = try ReviewPixels(rep)
            #expect(pixels.differing(from: stage.theme.background) > 10_000)
            // The hand-over stays in the window: a zoomed interface in a
            // small window squeezes the list, never the buttons. Only the
            // smallest window at a zoom above the default is too short for
            // it, and then the column scrolls; it is never wider.
            let window = CGRect(origin: .zero, size: size)
            let scrolls = size != reviewWindowSize && step > 1
            for control in ["review-copy", "review-reveal", "review-back"] {
                let frame = try #require(stage.controls[control])
                let across = frame.minX >= 0 && frame.maxX <= size.width
                #expect(
                    scrolls
                        ? across && frame.minY >= 0 : window.contains(frame),
                    "\(control) at \(frame) in \(size) at \(step)x"
                )
            }
        }
    }
}

@MainActor
@Test func theScreenFollowsTheRem() throws {
    // Nothing is measured in fixed points: at a larger zoom the controls
    // are larger.
    let fixture = try ReviewFixture()
    let scenario = try #require(scenarios.first { $0.name == "trash" })
    let (_, review) = try staged(scenario, fixture)
    let heights = try [zoomSteps[0], 1, zoomSteps[zoomSteps.count - 1]].map {
        step in
        let stage = try ReviewStage(
            ReviewScreen(review: review, actions: ReviewActionLog().recording),
            appearance: .darkAqua,
            rem: baseRem * step
        )
        defer { stage.close() }
        stage.settle()
        return try #require(stage.controls["review-copy"]).height
    }
    #expect(heights == heights.sorted() && heights[0] < heights[2])
}

// MARK: - What the screen reads

@MainActor
@Test func theModelReadsThePlansVerdicts() throws {
    let fixture = try ReviewFixture()
    let scenario = try #require(
        scenarios.first { $0.name == "covered-and-blocked" }
    )
    let (state, review) = try staged(scenario, fixture)
    let items = state.marks.items
    let byPath = { (path: FilePath) in items.first { $0.path == path } }

    let deeper = try #require(byPath(fixture.path("junk/deeper")))
    #expect(review.isCovered(deeper))
    #expect(review.reason(deeper) == nil)

    let root = try #require(byPath(fixture.root))
    #expect(review.reason(root) == "the scanned root cannot be removed")
    let above = try #require(byPath(fixture.root.removingLastComponent()))
    #expect(review.reason(above) != nil)

    let junk = try #require(byPath(fixture.path("junk")))
    #expect(!review.isCovered(junk) && review.reason(junk) == nil)

    // The command names the targets and nothing else.
    let command = try #require(review.command)
    #expect(command.contains(shellQuoted(fixture.path("junk"))))
    #expect(!command.contains(shellQuoted(fixture.path("junk/deeper"))))
    #expect(!command.contains(shellQuoted(fixture.root) + " "))
}

@MainActor
@Test func theProjectionLeavesOutWhatIsAlreadyGone() throws {
    // A gone target already gave its space back, and the live free space
    // counts it: projecting it again would count it twice (Invariant 9).
    let fixture = try ReviewFixture()
    let scenario = try #require(scenarios.first { $0.name == "some-gone" })
    let (_, review) = try staged(scenario, fixture)
    #expect(review.plan.bytes == 601_000)
    #expect(review.goneCount == 1)
    #expect(review.pendingBytes == 301_000)
    #expect(review.goneProjected == 300_000)
    let after = try #require(review.after)
    #expect(after.available == fullDisk.available + 301_000)
}

@MainActor
@Test func aMarkInsideAGoneMarkIsCountedOnce() throws {
    let fixture = try ReviewFixture()
    let state = try reviewState(fixture)
    try reviewMark(state, "junk")
    try reviewMark(state, "junk/deeper")
    state.gone = [fixture.path("junk"), fixture.path("junk/deeper")]
    let review = reviewFromCore(state)
    #expect(review.goneCount == 2)
    #expect(review.goneProjected == 300_000)
    #expect(review.pendingBytes == 0)
}

@MainActor
@Test func theHeaderLabelsTheProjectionAsOne() throws {
    let fixture = try ReviewFixture()
    let state = try reviewState(fixture)
    #expect(reviewFromCore(state).subtitle == "nothing marked")
    try markThree(state)
    #expect(
        reviewFromCore(state).subtitle
            == "3 marked \u{00B7} \(humanBytes(601_000)) projected"
    )
    state.gone = [fixture.path("junk")]
    #expect(reviewFromCore(state).subtitle.hasSuffix("\u{00B7} 1 gone"))
    state.gone = Set(state.marks.items.map(\.path))
    #expect(reviewFromCore(state).subtitle.hasSuffix("\u{00B7} all gone"))
}

@MainActor
@Test func theScreenReadsTheCommandTheStateCopies() throws {
    // What the block shows is what Copy Command copies: both come from
    // `cleanupCommand()`, never from a second spelling of it.
    let fixture = try ReviewFixture()
    let state = try reviewState(fixture)
    try markThree(state)
    for style in CommandStyle.allCases {
        state.commandStyle = style
        let review = ReviewModel(state)
        #expect(review.command == state.cleanupCommand())
        #expect(review.style == style)
        #expect(review.plan.targets == state.plan().targets)
    }
}

@Test func theListStopsAtTwelveHundred() {
    #expect(reviewListLimit == 1200)
}

// MARK: - The controls

@MainActor
@Test func everyControlReachesItsAction() throws {
    let fixture = try ReviewFixture()
    let scenario = try #require(scenarios.first { $0.name == "trash" })
    let (state, review) = try staged(scenario, fixture)
    let recorder = ReviewActionLog()
    let stage = try ReviewStage(
        ReviewScreen(review: review, actions: recorder.recording),
        appearance: .darkAqua
    )
    defer { stage.close() }
    let presses: [(String, ReviewActionLog.Action)] = [
        ("review-copy", .copy),
        ("review-reveal", .reveal),
        ("review-clear", .clear),
        ("review-back", .back),
        ("unmark-0", .unmark(state.marks.items[0].path)),
        ("unmark-2", .unmark(state.marks.items[2].path)),
    ]
    for (control, action) in presses {
        recorder.actions.removeAll()
        try stage.click(control)
        #expect(recorder.actions == [action], "\(control)")
    }
    // The command's own copy button copies it too.
    recorder.actions.removeAll()
    try stage.click("review-command-copy")
    #expect(recorder.actions == [.copy])
    // Each side of the style's segmented control chooses its style.
    for style in [CommandStyle.remove, .trash] {
        recorder.actions.removeAll()
        try stage.choose(style)
        #expect(recorder.actions == [.choose(style)], "\(style)")
    }
}

@MainActor
@Test func nothingToHandOverDisablesTheHandOver() throws {
    // Every mark kept back: there is no command, so neither way out does
    // anything; going back and unmarking still do.
    let fixture = try ReviewFixture()
    let state = try reviewState(fixture)
    state.marks.toggle(
        Target(path: fixture.root, bytes: 601_000, isDir: true, hidden: false)
    )
    let review = reviewFromCore(state)
    #expect(review.command == nil)
    let recorder = ReviewActionLog()
    let stage = try ReviewStage(
        ReviewScreen(review: review, actions: recorder.recording),
        appearance: .aqua
    )
    defer { stage.close() }
    try stage.click("review-copy")
    try stage.click("review-reveal")
    #expect(recorder.actions.isEmpty)
    try stage.click("unmark-0")
    try stage.click("review-back")
    #expect(recorder.actions == [.unmark(fixture.root), .back])
}

@MainActor
@Test func theStyleChoiceAndBackActOnTheState() throws {
    // The command style is a choice with two channels, the keys and the
    // buttons, and both must reach the same state (the Rust
    // `the_review_screen_switches_removal_mode`); the buttons set it.
    let fixture = try ReviewFixture()
    let state = try reviewState(fixture)
    try markThree(state)
    let actions = ReviewActions.calling(state)
    actions.choose(.remove)
    #expect(state.commandStyle == .remove)
    actions.choose(.trash)
    #expect(state.commandStyle == .trash)
    actions.back()
    #expect(state.screen == .explore)
}

@MainActor
@Test func theHandOverButtonsActOnTheState() throws {
    // Through the real view and the real state: Copy Command hands the
    // command to the pasteboard hook, Reveal in Finder hands Finder the
    // targets, and unmarking takes the mark off. Nothing on disk changes.
    let fixture = try ReviewFixture()
    let hooks = ReviewHooks()
    let state = try reviewState(fixture, hooks: hooks)
    try markThree(state)
    let stage = try ReviewStage(
        ReviewView(state: state),
        appearance: .darkAqua,
        rem: state.rem
    )
    defer { stage.close() }

    let command = try #require(state.cleanupCommand())
    try stage.click("review-copy")
    #expect(hooks.copied == [command])
    #expect(state.toast != nil)

    try stage.click("review-reveal")
    let targets = Set(state.plan().targets.map(\.path))
    let revealed = try #require(hooks.revealed.last)
    #expect(!revealed.isEmpty && Set(revealed).isSubset(of: targets))

    try stage.choose(.remove)
    #expect(state.commandStyle == .remove)
    #expect(state.cleanupCommand()?.hasPrefix("/bin/rm -rfx --") == true)

    let first = state.marks.items[0].path
    try stage.click("unmark-0")
    #expect(!state.marks.contains(first))
    try stage.click("review-clear")
    #expect(state.marks.isEmpty)

    for path in ["junk", ".cache", "keep/notes.txt"] {
        #expect(
            FileManager.default.fileExists(atPath: fixture.path(path).string),
            "\(path) is still there: the screen removes nothing"
        )
    }
}

@MainActor
@Test func pressingEverythingRemovesNothing() throws {
    // disktree never deletes anything itself: every control of the screen,
    // pressed through the real state, leaves the disk as it was.
    let fixture = try ReviewFixture()
    let hooks = ReviewHooks()
    let state = try reviewState(fixture, hooks: hooks)
    try markThree(state)
    let stage = try ReviewStage(
        ReviewView(state: state),
        appearance: .aqua,
        rem: state.rem
    )
    defer { stage.close() }
    try stage.choose(.remove)
    for control in [
        "review-copy", "review-command-copy", "review-reveal",
    ] where stage.controls[control] != nil {
        try stage.click(control)
    }
    try stage.choose(.trash)
    for control in [
        "review-copy", "unmark-0", "review-clear", "review-back",
    ] where stage.controls[control] != nil {
        try stage.click(control)
    }
    for path in ["junk/blob.bin", "junk/deeper/more.bin", ".cache/blob.bin"] {
        #expect(
            FileManager.default.fileExists(atPath: fixture.path(path).string)
        )
    }
    // What reached the pasteboard hook, if anything, is the command and
    // nothing else.
    #expect(
        hooks.copied.allSatisfy {
            $0.hasPrefix("/usr/bin/trash \\\n")
                || $0.hasPrefix("/bin/rm -rfx -- \\\n")
        }
    )
}
