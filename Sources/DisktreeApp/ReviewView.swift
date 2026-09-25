// The review screen: every marked path, what the guards made of it, and the
// hand-over.
//
// disktree removes nothing itself. This is where the marked list leaves the
// app: as a command to paste into a terminal (`trash` unless `rm -rfx` is
// asked for), as a selection in Finder, where Move to Trash can be undone
// with Put Back, or row by row, dragged out of the list. So the screen shows
// exactly what leaves: each mark with the guards' verdict on it, and the
// command spelled out as it will be copied, covered and blocked paths left
// out. Once marked paths start to vanish from disk it says so, and what the
// disk measurably gained (Invariant 9: the projection is labelled as one,
// the measured number as measured).
//
// Like every screen it is a pure reading of the state. `ReviewModel` is read
// once per frame — the plan and the command are asked for once, not per
// row — and the controls act through `ReviewActions`. The screen keeps only
// what is its own: how the list is sorted, which rows are selected, and
// whether Copy Command is still showing that it copied.
//
// It moves only to explain a change: a number rolls to its new value, a row
// going from disk is struck through, the command style's marker slides to
// the chosen side. Nothing takes longer than a quarter of a second, and with
// Reduce Motion nothing moves at all; it only fades.

import AppKit
import DisktreeCore
import SwiftUI
import System

/// How many marks the review screen lists. Everything above the cap is
/// handed over all the same; the list only stops being exhaustive, which it
/// says out loud.
let reviewListLimit = 1200

/// The kept-back paths the summary names; the rest carry their reason in
/// the list.
private let keptBackListed = 6

/// The narrowest the list and the hand-over are worth setting beside the
/// summary: wide enough for every column of the table at its ideal width
/// less the status's. A window with less room than this and the summary
/// column (a large interface zoom, a small window) gets one column, and the
/// summary folds into a strip over the list.
private let listColumn = Rems(34)

/// The list's height when the whole screen has to scroll: a window so short
/// at so large a zoom that the list would otherwise get none.
private let scrolledListHeight = Rems(12)

/// Lines of the command shown before it scrolls: a short list is checked
/// at a glance, and a long one does not push the marked list off the
/// screen.
private let commandLines = 10

/// Lines the command keeps when the window is too short for both it and the
/// list: enough to see it is there and scroll it.
private let commandMinLines = 3

/// How long Copy Command shows its checkmark: long enough to be seen from
/// the corner of an eye already on its way to the terminal, and gone before
/// the toast that says the same.
let reviewCopiedFor = Duration.milliseconds(1_500)

/// Whether Copy Command shows its checkmark at `now`, for a command copied
/// at `copiedAt`. A copy a moment in the future is one whose time was
/// rounded on its way here: it counts.
func reviewShowsCopied(_ copiedAt: Date?, at now: Date) -> Bool {
    guard let copiedAt else {
        return false
    }
    return now.timeIntervalSince(copiedAt) < reviewCopiedFor / .seconds(1)
}

/// How the toast `copyCommand()` raises begins; no other toast does, so the
/// button can tell a copied command from a copied path.
let reviewCopiedToast = "Copied: "

// MARK: - What the screen reads

/// What the review screen shows, read from the state once per frame.
struct ReviewModel {
    /// Every mark, in marking order.
    var items: [Target]
    var plan: Plan
    /// The command exactly as it will be copied; `nil` when nothing may be
    /// removed.
    var command: String?
    var style: CommandStyle
    var space: SpaceInfo?
    /// Free space gained since the first mark, from `statfs`.
    var measuredGain: UInt64?
    /// What a row's share bar is measured against: the whole scan.
    var rootBytes: UInt64
    var home: FilePath?
    var volumeName: String?
    var notice: Notice?
    /// When the command was copied, while the toast that says so is up:
    /// Copy Command shows a checkmark for `reviewCopiedFor` from then,
    /// however the copy was asked for (the button, Enter, the Edit menu).
    var copiedAt: Date?
    /// Quick Look is showing something: a row picked in the list is shown
    /// in it instead.
    var previewing: Bool
    /// The help is up over the screen: the toolbar waits, as it would
    /// behind a sheet.
    var modal = false
    /// Every mark as the list shows it, in marking order.
    private(set) var rows: [ReviewRow] = []

    /// Marked paths no longer on disk, normalized as the plan's paths are,
    /// so a row, a target and a gone path compare alike.
    private var gone: Set<FilePath>
    private var covered: Set<FilePath>
    /// By the path as it was marked: the plan keeps a blocked path
    /// unnormalized, so the list shows the mark.
    private var reasons: [FilePath: String]

    init(
        items: [Target],
        plan: Plan,
        command: String?,
        style: CommandStyle,
        gone: Set<FilePath>,
        space: SpaceInfo?,
        measuredGain: UInt64?,
        rootBytes: UInt64,
        home: FilePath?,
        volumeName: String?,
        notice: Notice?,
        copiedAt: Date? = nil,
        previewing: Bool = false
    ) {
        self.items = items
        self.plan = plan
        self.command = command
        self.style = style
        self.space = space
        self.measuredGain = measuredGain
        self.rootBytes = rootBytes
        self.home = home
        self.volumeName = volumeName
        self.notice = notice
        self.copiedAt = copiedAt
        self.previewing = previewing
        self.gone = Set(gone.map(normalize))
        self.covered = Set(plan.covered.map { normalize($0.path) })
        self.reasons = Dictionary(
            plan.blocked.map { ($0.path, $0.reason) },
            uniquingKeysWith: { first, _ in first }
        )
        self.rows = makeRows()
    }

    /// Read the state, with the plan, the command and the gain given: what
    /// the tests use to draw a state the stubs cannot produce.
    @MainActor
    init(
        _ state: AppState,
        plan: Plan,
        command: String?,
        measuredGain: UInt64?
    ) {
        // The toast went up `toastDuration` before it expires, which is
        // when the command was copied.
        let copiedAt: Date? =
            if let toast = state.toast, let expiry = state.toastExpiry,
                toast.text.hasPrefix(reviewCopiedToast)
            {
                Date.now.addingTimeInterval(
                    (expiry - AppState.toastDuration - .now) / .seconds(1)
                )
            } else {
                nil
            }
        self.init(
            items: state.marks.items,
            plan: plan,
            command: command,
            style: state.commandStyle,
            gone: state.gone,
            space: state.space,
            measuredGain: measuredGain,
            rootBytes: state.tree?.bytes ?? 0,
            home: state.home,
            volumeName: state.volumeName,
            notice: state.notice,
            copiedAt: copiedAt,
            previewing: state.quickLookTarget != nil
        )
        modal = state.showHelp
    }

    /// Read the state: the plan, the command and the gain as it reports
    /// them.
    @MainActor
    init(_ state: AppState) {
        self.init(
            state,
            plan: state.plan(),
            command: state.cleanupCommand(),
            measuredGain: state.measuredGain
        )
    }

    /// Inside another marked directory, so it goes with that one.
    func isCovered(_ item: Target) -> Bool {
        covered.contains(normalize(item.path))
    }

    /// Why the guards keep this mark back, if they do.
    func reason(_ item: Target) -> String? {
        reasons[item.path]
    }

    func isGone(_ path: FilePath) -> Bool {
        gone.contains(normalize(path))
    }

    /// Marks no longer on disk.
    var goneCount: Int {
        items.count { isGone($0.path) }
    }

    /// What the targets still on disk weighed when marked: what the command
    /// would still free. A target already gone has already given its space
    /// back, and the live free space counts it; projecting it again would
    /// count it twice.
    var pendingBytes: UInt64 {
        plan.targets.reduce(0) { sum, target in
            isGone(target.path) ? sum : sum + target.bytes
        }
    }

    /// What the gone marks weighed when marked: what the measured gain is
    /// held against. A mark inside another gone mark went with it, so only
    /// the outermost is counted; a kept-back mark removed by hand all the
    /// same did give its space back, so it counts.
    var goneProjected: UInt64 {
        let paths = Set(items.map { normalize($0.path) }.filter(isGone))
        return items.reduce(0) { sum, item in
            let path = normalize(item.path)
            guard isGone(path), !isInside(path, anyOf: paths) else {
                return sum
            }
            return sum + item.bytes
        }
    }

    /// The disk as the projection has it once the command has run.
    var after: SpaceInfo? {
        space?.afterRemoving(pendingBytes)
    }

    /// The header's line: how many, how much, and how many are gone.
    var subtitle: String {
        guard !items.isEmpty else {
            return "nothing marked"
        }
        var parts = [
            "\(items.count) marked",
            "\(humanBytes(plan.bytes)) projected",
        ]
        let gone = goneCount
        if gone > 0 {
            parts.append(gone == items.count ? "all gone" : "\(gone) gone")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Each mark with its verdict. Gone comes first, since a path no longer
    /// on disk is past any guard; then the guards' refusal, then whether a
    /// marked directory takes it along.
    private func makeRows() -> [ReviewRow] {
        // The targets, to find which one a covered mark goes with by
        // walking up from it: a dozen lookups a row, not one per target.
        let targets = Set(plan.targets.map(\.path))
        return items.enumerated().map { index, item in
            let status: ReviewStatus =
                if isGone(item.path) {
                    .gone
                } else if let reason = reason(item) {
                    .blocked(reason)
                } else if isCovered(item) {
                    .covered(
                        by: outer(normalize(item.path), in: targets)
                            ?? item.path.removingLastComponent()
                    )
                } else {
                    .ready
                }
            return ReviewRow(
                index: index,
                path: item.path,
                name: reviewName(item.path),
                folder: displayPath(
                    item.path.removingLastComponent(),
                    home: home
                ),
                bytes: item.bytes,
                isDir: item.isDir,
                hidden: item.hidden,
                status: status
            )
        }
    }
}

/// Whether a strict ancestor of `path` is in `paths`.
private func isInside(_ path: FilePath, anyOf paths: Set<FilePath>) -> Bool {
    outer(path, in: paths) != nil
}

/// The nearest strict ancestor of `path` that is in `paths`.
private func outer(_ path: FilePath, in paths: Set<FilePath>) -> FilePath? {
    var parent = path
    // `/` has no components: the walk ends there, having asked about it.
    while !parent.components.isEmpty {
        parent = parent.removingLastComponent()
        if paths.contains(parent) {
            return parent
        }
    }
    return nil
}

/// What the review screen's controls do. The screen only reads; every
/// control acts through one of these, which the app points at the state and
/// the tests point at a recorder, so a press can be traced to what it
/// reached.
struct ReviewActions {
    var copy: @MainActor () -> Void
    var reveal: @MainActor () -> Void
    var unmark: @MainActor (FilePath) -> Void
    var clear: @MainActor () -> Void
    var back: @MainActor () -> Void
    var choose: @MainActor (CommandStyle) -> Void
    /// Show these rows in Finder: the list's context menu.
    var revealPaths: @MainActor ([FilePath]) -> Void
    /// Copy these rows' paths, one per line: the context menu, and ⌘C.
    var copyPaths: @MainActor ([FilePath]) -> Void
    /// Preview one row in Quick Look: the context menu, and a double-click.
    var quickLook: @MainActor (FilePath) -> Void
    /// Every key and gesture: the status bar's help button.
    var help: @MainActor () -> Void = {}

    /// Every control, acting on `state`.
    @MainActor
    static func calling(_ state: AppState) -> Self {
        Self(
            copy: { state.copyCommand() },
            reveal: { state.revealMarkedInFinder() },
            unmark: { state.unmark($0) },
            clear: { state.clearMarks() },
            // Back and the style choice are plain assignments, as the Rust
            // buttons made them: there is nothing to decide.
            back: { state.screen = .explore },
            choose: { state.commandStyle = $0 },
            revealPaths: { reveal($0, in: state) },
            copyPaths: { copy($0, in: state) },
            quickLook: { state.revealQuickLook(path: $0) },
            help: { state.showHelp = true }
        )
    }

    /// Select `paths` in Finder, through the state's hook, unless they are
    /// spread over so many folders that Finder would open a window for
    /// each: the same limit, and the same advice, as Reveal in Finder.
    @MainActor
    private static func reveal(_ paths: [FilePath], in state: AppState) {
        let folders = Set(paths.map { $0.removingLastComponent() })
        guard folders.count <= AppState.finderFolderLimit else {
            state.notice = Notice(
                "those rows are in \(folders.count) folders, and Finder "
                    + "would open a window for each: copy the command instead",
                status: .warning
            )
            return
        }
        state.showInFinder(paths)
    }

    /// Copy `paths`, one per line, as Finder's Copy as Pathname does,
    /// through the pasteboard the command goes to, and say so in a toast.
    @MainActor
    private static func copy(_ paths: [FilePath], in state: AppState) {
        guard let first = paths.first else {
            return
        }
        state.copyToPasteboard(paths.map(\.string).joined(separator: "\n"))
        let what =
            paths.count == 1
            ? displayPath(first, home: state.home) : "\(paths.count) paths"
        state.showToast(Notice("Copied \(what)", status: .success))
    }
}

/// Where each named control of the review screen is, by its accessibility
/// identifier: what a test looks a control up by, and where it clicks it.
struct ReviewControls: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }

    static func reduce(
        value: inout [String: Anchor<CGRect>],
        nextValue: () -> [String: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { _, next in next }
    }
}

extension View {
    /// Name a control of the review screen the way an accessibility client
    /// finds it, and say where it sits.
    func reviewControl(_ id: String) -> some View {
        accessibilityIdentifier(id)
            .anchorPreference(key: ReviewControls.self, value: .bounds) {
                [id: $0]
            }
    }

    /// A number that changes while it is read rolls to its new value, digit
    /// by digit; with Reduce Motion it fades instead.
    func reviewRolling(_ value: Double, reduceMotion: Bool) -> some View {
        contentTransition(
            reduceMotion ? .opacity : .numericText(value: value)
        )
        .animation(ReviewMotion.change(reduceMotion), value: value)
    }
}

/// How the review screen moves. Every change is under a quarter of a
/// second; with Reduce Motion nothing slides, draws on or rolls, it fades.
enum ReviewMotion {
    /// A value changing in place: a number, a symbol.
    static func change(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? fade : .snappy(duration: 0.22)
    }

    /// Something appearing or going: a line of text, a hint.
    static let fade = Animation.easeInOut(duration: 0.15)

    /// The bar across the disk: its edges move to the new numbers, or, with
    /// Reduce Motion, are simply there.
    static func bars(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.22)
    }

    /// Rows coming and going. A table cannot fade a row in place of
    /// sliding it, so with Reduce Motion they are simply there.
    static func rows(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .snappy(duration: 0.2)
    }

    /// The line through a row that went from disk.
    static func strike(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? fade : .easeOut(duration: 0.2)
    }

    /// A symbol swapped for another: replaced in place, or crossfaded.
    static func symbol(_ reduceMotion: Bool) -> ContentTransition {
        reduceMotion ? .opacity : .symbolEffect(.replace)
    }

    /// The notice line arriving from below, or fading in.
    static func notice(_ reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }
}

// MARK: - The screen

/// The review screen, over the state.
struct ReviewView: View {
    let state: AppState

    init(state: AppState) {
        self.state = state
    }

    var body: some View {
        ReviewScreen(review: ReviewModel(state), actions: .calling(state))
    }
}

/// The review screen, drawn from what it reads.
///
/// Its actions — back, the command's style, Reveal in Finder and Copy
/// Command — are the window's toolbar items while it shows, as a Mac
/// app's are, and its title and summary are the window's title and
/// subtitle, wherever the window's toolbar is SwiftUI's. A window without
/// one (a test's, or one whose toolbar AppKit keeps for itself) gets the
/// same controls in a bar across the top of the screen instead, so nothing
/// is ever out of reach, and its own toolbar is left alone.
struct ReviewScreen: View {
    let review: ReviewModel
    let actions: ReviewActions
    /// The list's sort and selection belong to the screen, not to either
    /// layout, so they survive the window changing between the two.
    @State private var order: [KeyPathComparator<ReviewRow>]
    @State private var selection: Set<FilePath> = []
    /// What the window holding the screen offers, once it is known.
    @State private var host = ReviewHost.unknown
    /// The screen's own top inset from the window: what it is given as
    /// its safe area.
    @State private var safeTop: CGFloat = 0
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem
    /// The window hands the screens' toolbars to its own (`bridgesToolbar`),
    /// so the actions go there at once, before the probe has answered.
    @Environment(\.bridgesToolbar) private var bridgesToolbar
    @Environment(\.liveWindow) private var live

    init(
        review: ReviewModel,
        actions: ReviewActions,
        order: [KeyPathComparator<ReviewRow>] = ReviewRow.defaultOrder
    ) {
        self.review = review
        self.actions = actions
        self._order = State(initialValue: order)
    }

    var body: some View {
        let bridged = bridgesToolbar || host.bridged
        let inline = !bridged
        VStack(spacing: 0) {
            if inline {
                ScreenHeader("Review", subtitle: review.subtitle) {
                    ReviewActionBar(review: review, actions: actions)
                }
            }
            ViewThatFits(in: .horizontal) {
                wide
                narrow
            }
            .padding(Space.lg.at(rem))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            ReviewStatusBar(space: review.space, help: actions.help)
        }
        // Under a toolbar, the screen starts below it: by the safe area
        // the window gives, or, where a parent laid the screen out under
        // the title bar regardless, by the title bar's own height.
        .padding(.top, inline ? 0 : max(host.titlebar - safeTop, 0))
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.safeAreaInsets.top
        } action: { top in
            safeTop = top
        }
        .font(TextSize.body.font(rem))
        .foregroundStyle(theme.foreground.color)
        .background(theme.background.color)
        .background {
            ReviewHostProbe { host = $0 }
        }
        .modifier(
            ReviewWindowChrome(
                bridged: bridged,
                live: live,
                review: review,
                actions: actions,
                tint: reviewProminentTint(theme)
            )
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review-screen")
    }

    /// The list and the hand-over, with the summary column beside them.
    private var wide: some View {
        HStack(alignment: .top, spacing: Space.lg.at(rem)) {
            VStack(alignment: .leading, spacing: Space.lg.at(rem)) {
                list(height: nil)
                HandOver(review: review, actions: actions)
            }
            // Its ideal width is what decides whether this layout fits, not
            // the length of the longest path in it.
            .frame(
                minWidth: listColumn.at(rem),
                idealWidth: listColumn.at(rem),
                maxWidth: .infinity,
                maxHeight: .infinity
            )
            ReviewSummary(review: review)
                .frame(width: Size.reviewSummary.at(rem))
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// One column, the summary folded into a strip over the list. When even
    /// that does not fit the height, the whole column scrolls rather than
    /// push the buttons out of the window.
    private var narrow: some View {
        ViewThatFits(in: .vertical) {
            column(listHeight: nil)
            ScrollView(.vertical) {
                column(listHeight: scrolledListHeight.at(rem))
            }
        }
    }

    private func column(listHeight: CGFloat?) -> some View {
        VStack(alignment: .leading, spacing: Space.lg.at(rem)) {
            SummaryStrip(review: review)
            list(height: listHeight)
            HandOver(review: review, actions: actions)
        }
    }

    private func list(height: CGFloat?) -> some View {
        ReviewList(
            review: review,
            actions: actions,
            selection: $selection,
            order: $order,
            height: height
        )
    }
}

// MARK: - The window around it

/// What the window holding the review offers it.
struct ReviewHost: Equatable {
    /// The window's toolbar is SwiftUI's, which the screen's toolbar items
    /// join.
    var bridged: Bool
    /// How far the title bar and toolbar reach down into the content.
    var titlebar: CGFloat

    /// Before the screen is in a window: its own bar, and no toolbar items
    /// declared, since declaring them would hand SwiftUI a toolbar AppKit
    /// may be keeping. A screen arriving is transparent on its first
    /// frame, so the bar is never seen before the answer comes.
    static let unknown = Self(bridged: false, titlebar: 0)

    /// Whether `toolbar` is one SwiftUI made and fills from the views'
    /// `.toolbar` content: its delegate is SwiftUI's own. An app's own
    /// toolbar has the app's delegate, or none.
    @MainActor
    static func bridges(_ toolbar: NSToolbar?) -> Bool {
        guard let delegate = toolbar?.delegate else {
            return false
        }
        return String(reflecting: type(of: delegate)).hasPrefix("SwiftUI.")
    }
}

/// The screen's actions as toolbar items, and its title and summary as the
/// window's, when the window's toolbar is SwiftUI's; nothing otherwise.
private struct ReviewWindowChrome: ViewModifier {
    let bridged: Bool
    /// A person sees the window, where the toolbar's glass can be drawn.
    let live: Bool
    let review: ReviewModel
    let actions: ReviewActions
    let tint: Color

    func body(content: Content) -> some View {
        if bridged {
            content
                .toolbar {
                    ReviewToolbar(
                        review: review,
                        actions: actions,
                        tint: tint,
                        live: live
                    )
                }
                .navigationTitle("Review")
                .navigationSubtitle(review.subtitle)
        } else {
            content
        }
    }
}

/// Reports whether the window holding it has a toolbar and how tall its
/// title bar is, and again whenever either changes: both are observed, never
/// read in a layout pass.
private struct ReviewHostProbe: NSViewRepresentable {
    let changed: (ReviewHost) -> Void

    func makeNSView(context: Context) -> ReviewHostView {
        ReviewHostView(changed: changed)
    }

    func updateNSView(_ view: ReviewHostView, context: Context) {
        view.changed = changed
    }
}

private final class ReviewHostView: NSView {
    var changed: (ReviewHost) -> Void
    private var observations: [NSKeyValueObservation] = []

    init(changed: @escaping (ReviewHost) -> Void) {
        self.changed = changed
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observations = []
        guard let window else {
            return
        }
        // SwiftUI installs its toolbar items after the first pass, and a
        // toolbar changes how far the title bar reaches: both are key-value
        // observable on the window.
        observations = [
            window.observe(\.toolbar, options: [.initial]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.report() }
            },
            window.observe(\.contentLayoutRect) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.report() }
            },
        ]
    }

    private func report() {
        guard let window else {
            return
        }
        let host = ReviewHost(
            bridged: ReviewHost.bridges(window.toolbar),
            titlebar: window.styleMask.contains(.fullSizeContentView)
                ? max(
                    window.frame.height - window.contentLayoutRect.height,
                    0
                )
                : 0
        )
        // Never from inside the update that moved this view: the answer is
        // state, and state changes wait for the update to end. On the next
        // turn of the run loop rather than as a task: a turn is taken by
        // any loop that runs, a nested one too, where the main actor's
        // queue waits for the outermost.
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) {
            [weak self] in
            MainActor.assumeIsolated { self?.changed(host) }
        }
        CFRunLoopWakeUp(main)
    }
}

// MARK: - The actions

/// The screen's actions as the window's toolbar items: back at the leading
/// edge, then the command's style, Reveal in Finder, and the main action,
/// Copy Command, prominent at the trailing edge.
private struct ReviewToolbar: ToolbarContent {
    let review: ReviewModel
    let actions: ReviewActions
    /// The main action's tint, from the theme the screen reads.
    let tint: Color
    /// Whether the toolbar's glass can be drawn (`liveWindow`).
    let live: Bool

    var body: some ToolbarContent {
        let available = review.command != nil
        let modal = review.modal
        ToolbarItem(placement: .navigation) {
            Button(action: actions.back) {
                Label("Treemap", systemImage: "chevron.backward")
            }
            .help("Back to the treemap, marks and all (Esc)")
            .disabled(modal)
            .quietFocus()
        }
        .quietWhereGlassCannotShow(live)
        ToolbarItem(placement: .primaryAction) {
            StylePicker(selected: review.style, choose: actions.choose)
                .disabled(modal)
                .quietFocus()
        }
        .quietWhereGlassCannotShow(live)
        ToolbarItem(placement: .primaryAction) {
            Button(action: actions.reveal) {
                Label("Reveal in Finder", systemImage: "finder")
            }
            .disabled(!available || modal)
            .help(revealHelp)
            .quietFocus()
        }
        .quietWhereGlassCannotShow(live)
        ToolbarItem(placement: .primaryAction) {
            CopyButton(
                copiedAt: review.copiedAt,
                disabled: !available || modal,
                action: actions.copy
            )
            .labelStyle(.titleAndIcon)
            .modifier(ProminentInToolbar(tint: tint, live: live))
            .quietFocus()
        }
        .quietWhereGlassCannotShow(live)
    }
}

/// The toolbar's one prominent button. On screen, the system's: on macOS
/// 26 its capsule of glass, tinted. In a window nobody sees the toolbar's
/// glass cannot be drawn — shown there, it blanks the whole window — and
/// the prominent fill goes with it, so the button would come out as plain
/// text beside the others; there it is filled by hand, in the same tint,
/// so a still picture shows which action is the main one.
private struct ProminentInToolbar: ViewModifier {
    let tint: Color
    let live: Bool

    func body(content: Content) -> some View {
        if live {
            content
                .buttonStyle(.borderedProminent)
                .tint(tint)
        } else {
            content.buttonStyle(FilledCapsule(tint: tint))
        }
    }
}

/// A prominent button drawn without the system's bezel: white on a capsule
/// of `tint`, a little darker while pressed.
private struct FilledCapsule: ButtonStyle {
    let tint: Color
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        // The metrics of a toolbar's own capsule: a toolbar keeps the
        // system's size whatever the interface zoom.
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(tint, in: Capsule())
            .overlay {
                Capsule().fill(
                    .black.opacity(configuration.isPressed ? 0.15 : 0))
            }
            .opacity(enabled ? 1 : 0.45)
    }
}

/// The same actions in a bar of the screen's own, for a window without a
/// toolbar: the system's buttons at the size a toolbar sets them.
private struct ReviewActionBar: View {
    let review: ReviewModel
    let actions: ReviewActions
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    var body: some View {
        // Titled where there is room, as a toolbar shows its items; only
        // their symbols where there is not, rather than cut words.
        ViewThatFits(in: .horizontal) {
            bar.labelStyle(.titleAndIcon)
            bar.labelStyle(.iconOnly)
        }
    }

    private var bar: some View {
        let available = review.command != nil
        return HStack(spacing: Space.sm.at(rem)) {
            Button(action: actions.back) {
                Label("Treemap", systemImage: "chevron.backward")
            }
            .help("Back to the treemap, marks and all (Esc)")
            .reviewControl("review-back")
            StylePicker(selected: review.style, choose: actions.choose)
                .reviewControl("review-style")
            Button(action: actions.reveal) {
                Label("Reveal in Finder", systemImage: "finder")
            }
            .disabled(!available)
            .help(revealHelp)
            .reviewControl("review-reveal")
            CopyButton(
                copiedAt: review.copiedAt,
                disabled: !available,
                action: actions.copy
            )
            .buttonStyle(.borderedProminent)
            .tint(reviewProminentTint(theme))
            .reviewControl("review-copy")
        }
        .fixedSize()
        .buttonStyle(.bordered)
        .controlSize(reviewControlSize(rem))
        // Keys go to the window's one dispatcher; a focus ring would
        // suggest a button owns them.
        .focusEffectDisabled()
    }
}

/// The system's control size for the interface zoom at `rem`: the size a
/// toolbar sets its controls at the default zoom, a step down below it and
/// a step up above it, so the controls grow with everything else.
func reviewControlSize(_ rem: CGFloat) -> ControlSize {
    switch rem / baseRem {
    case ..<0.9: .regular
    case ..<1.2: .large
    default: .extraLarge
    }
}

/// The control size for a button set inside a card, a step under the bar's
/// at every zoom.
func reviewCardControlSize(_ rem: CGFloat) -> ControlSize {
    switch rem / baseRem {
    case ..<0.9: .mini
    case ..<1.2: .small
    default: .regular
    }
}

/// What Reveal in Finder does, and its key.
private let revealHelp =
    "Select the marked paths in Finder, where Move to Trash can be undone "
    + "with Put Back (F)"

/// The tint of the one prominent button: the app's one fill for a main
/// action (`Theme.inspectorAccent`), as the inspector's Unmark and Review
/// buttons take. Only marking itself is filled with the highlight, which
/// is what can be had back; a copy hands that over, and so looks like the
/// way to the review that led here.
func reviewProminentTint(_ theme: Theme) -> Color {
    theme.inspectorAccent.color
}

/// Trash or rm: the system's segmented control, the reversible choice
/// first, its marker sliding across as it changes.
private struct StylePicker: View {
    let selected: CommandStyle
    let choose: @MainActor (CommandStyle) -> Void

    var body: some View {
        Picker(
            "Command",
            selection: Binding(
                get: { selected },
                set: { style in
                    MainActor.assumeIsolated { choose(style) }
                }
            )
        ) {
            // Words, not symbols, even in the toolbar: "rm" says what the
            // command runs, where a symbol would only suggest it (Mail's
            // crossed-out bin means junk). The keys, M and P, are in the
            // tooltips.
            ForEach(CommandStyle.allCases, id: \.self) { style in
                Text(style == .trash ? "Trash" : "rm")
                    .help(Self.help(style))
                    .tag(style)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("How the copied command removes the marks (M, P)")
    }

    static func help(_ style: CommandStyle) -> String {
        switch style {
        case .trash:
            "Copy a command that moves the marks to the Trash, where they "
                + "can be put back (M)"
        case .remove:
            "Copy a command that deletes the marks for good, with nothing to "
                + "put back (P)"
        }
    }
}

/// The screen's one main action: its symbol turns into a checkmark once
/// the command is copied, and back again `reviewCopiedFor` later. The copy
/// itself redraws it; the timeline redraws it once more, when the checkmark
/// is due to go, and never again.
private struct CopyButton: View {
    let copiedAt: Date?
    let disabled: Bool
    var title = "Copy Command"
    let action: @MainActor () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Now, and the moment the checkmark goes if that is still to come.
        // A timeline hands each update the date it was given for it, the
        // first one included, so the first is now.
        let now = Date.now
        let end = copiedAt?.addingTimeInterval(reviewCopiedFor / .seconds(1))
        let moments = [now] + [end].compactMap { $0 }.filter { $0 > now }
        TimelineView(.explicit(moments)) { context in
            // Never earlier than the clock: an update drawn late is drawn
            // for when it is drawn.
            let copied = reviewShowsCopied(
                copiedAt, at: max(context.date, .now))
            Button(action: action) {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(ReviewMotion.symbol(reduceMotion))
                        .animation(
                            ReviewMotion.change(reduceMotion),
                            value: copied
                        )
                }
            }
            .disabled(disabled)
            .help("Copy the command, to paste into Terminal (Return)")
            .accessibilityLabel(copied ? "Copied" : title)
        }
    }
}

// MARK: - The hand-over

/// The command as it will be copied, in a card with its own copy button,
/// and what disktree does and does not do with it.
private struct HandOver: View {
    let review: ReviewModel
    let actions: ReviewActions
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let available = review.command != nil
        let remove = review.style == .remove
        VStack(alignment: .leading, spacing: Space.sm.at(rem)) {
            // What the last hand-over said, or why it could not: over the
            // command it is about, as a banner, where it cannot be taken
            // for the fine print.
            if let notice = review.notice {
                ReviewNoticeBanner(notice: notice)
                    .transition(ReviewMotion.notice(reduceMotion))
                    .id(notice)
            }
            ReviewCard {
                VStack(alignment: .leading, spacing: Space.sm.at(rem)) {
                    HStack(alignment: .center, spacing: Space.sm.at(rem)) {
                        CardHeading("Command", symbol: "terminal")
                        // Said in the danger colour when nothing comes back
                        // from it.
                        Label(
                            review.style.detail,
                            systemImage: remove
                                ? "exclamationmark.triangle.fill"
                                : "arrow.uturn.backward.circle"
                        )
                        .labelStyle(ReviewTightLabel(spacing: Space.xs.at(rem)))
                        .font(TextSize.caption.font(rem, weight: .medium))
                        .foregroundStyle(
                            (remove ? theme.danger : theme.secondary).color
                        )
                        .lineLimit(1)
                        .padding(.horizontal, Space.sm.at(rem))
                        .padding(.vertical, Space.xxs.at(rem))
                        .background(
                            (remove ? theme.danger : theme.foreground)
                                .opacity(remove ? 0.12 : 0.06).color,
                            in: Capsule()
                        )
                        .contentTransition(.opacity)
                        .animation(ReviewMotion.fade, value: review.style)
                        Spacer(minLength: 0)
                        CopyIconButton(
                            copiedAt: review.copiedAt,
                            disabled: !available,
                            action: actions.copy
                        )
                        .reviewControl("review-command-copy")
                    }
                    CommandBlock(command: review.command, empty: emptyCommand)
                }
            }
            Label(
                "disktree never deletes anything itself: Finder\u{2019}s "
                    + "Move to Trash can be undone with Put Back, and the "
                    + "copied command runs in your terminal.",
                systemImage: "hand.raised"
            )
            .font(TextSize.caption.font(rem))
            .foregroundStyle(theme.secondary.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Space.xs.at(rem))
        }
        .animation(ReviewMotion.change(reduceMotion), value: review.notice)
    }

    private var emptyCommand: String {
        review.items.isEmpty
            ? "Nothing is marked, so there is nothing to hand over."
            : "Nothing here may be removed: every mark is kept back, "
                + "inside another, or gone already."
    }
}

/// A notice on the review, as the inspector sets one over the disk: its
/// symbol and its sentence in the notice's colour, on a tenth of that
/// colour, in a rounded banner with a hairline of it.
private struct ReviewNoticeBanner: View {
    let notice: Notice
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    var body: some View {
        let color = theme.alertColor(notice.status)
        let shape = roundedShape(Rounding.control, rem: rem)
        Label {
            Text(notice.sentence)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: Toast.symbol(notice.status))
        }
        .font(TextSize.caption.font(rem, weight: .medium))
        .foregroundStyle(color.color)
        .padding(.horizontal, Space.md.at(rem))
        .padding(.vertical, Space.sm.at(rem))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1).color, in: shape)
        .overlay {
            shape.strokeBorder(color.opacity(0.35).color, lineWidth: hairline)
        }
        .accessibilityElement(children: .combine)
        .chromeIdentifier("review-notice")
    }
}

/// Copy, as a small button in the command's corner: the same action as
/// Copy Command, where the eye is when reading the command.
private struct CopyIconButton: View {
    let copiedAt: Date?
    let disabled: Bool
    let action: @MainActor () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    var body: some View {
        CopyButton(
            copiedAt: copiedAt,
            disabled: disabled,
            title: "Copy",
            action: action
        )
        .labelStyle(.titleAndIcon)
        .buttonStyle(.bordered)
        .controlSize(reviewCardControlSize(rem))
        .focusEffectDisabled()
    }
}

/// The command as it will be copied, byte for byte: monospaced, never
/// wrapped (a wrapped path reads as two), selectable, and scrolled rather
/// than cut when it is long, in a rounded well.
private struct CommandBlock: View {
    let command: String?
    let empty: String
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    var body: some View {
        let lines = command.map {
            $0.utf8.count { $0 == UInt8(ascii: "\n") } + 1
        }
        let well = RoundedRectangle(
            cornerRadius: Rounding.control.at(rem),
            style: .continuous
        )
        Group {
            if let command, let lines {
                ScrollView([.horizontal, .vertical]) {
                    Text(verbatim: command)
                        .font(
                            .system(
                                size: TextSize.caption.at(rem),
                                design: .monospaced
                            )
                        )
                        .foregroundStyle(theme.bright.color)
                        .textSelection(.enabled)
                        .fixedSize()
                        .padding(Space.md.at(rem))
                }
                // A command narrower than the well starts at its left edge,
                // as it will in the terminal, rather than centred.
                .defaultScrollAnchor(.topLeading)
                // As tall as the command, up to `commandLines`, and no
                // taller: a two-line command is not set in a ten-line well.
                // Short of room it gives way down to `commandMinLines`, so
                // the buttons under it stay in the window.
                .frame(
                    minHeight: height(min(lines, commandMinLines)),
                    idealHeight: height(min(lines, commandLines)),
                    maxHeight: height(min(lines, commandLines))
                )
                .accessibilityLabel("The command, as it will be copied")
            } else {
                Label(empty, systemImage: "tray")
                    .font(TextSize.caption.font(rem))
                    .foregroundStyle(theme.secondary.color)
                    .padding(Space.md.at(rem))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.inset.color, in: well)
        .overlay {
            well.strokeBorder(theme.divider.color, lineWidth: hairline)
        }
        .clipShape(well)
        .accessibilityElement(children: .contain)
        .reviewControl("review-command")
    }

    /// The block's height for `lines` lines of the command: SwiftUI sets
    /// monospaced text on the font's own line height, which AppKit can
    /// measure, so the well fits its lines exactly.
    private func height(_ lines: Int) -> CGFloat {
        let font = NSFont.monospacedSystemFont(
            ofSize: TextSize.caption.at(rem),
            weight: .regular
        )
        let line = NSLayoutManager().defaultLineHeight(for: font)
        return CGFloat(lines) * line + 2 * Space.md.at(rem)
    }
}

// MARK: - Cards

/// A card on the review screen: a rounded surface a little off the window,
/// with a hairline, as a group sits in a Mac window.
struct ReviewCard<Content: View>: View {
    var padding: Rems = Space.lg
    let content: Content
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    init(padding: Rems = Space.lg, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: Rounding.card.at(rem),
            style: .continuous
        )
        content
            .padding(padding.at(rem))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface.color, in: shape)
            .overlay {
                shape.strokeBorder(theme.divider.color, lineWidth: hairline)
            }
    }
}

/// A card's heading: its symbol in the accent and its name.
struct CardHeading: View {
    let title: String
    let symbol: String
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    init(_ title: String, symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(theme.bright.color)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(theme.accent.color)
        }
        .labelStyle(ReviewTightLabel(spacing: Space.xs.at(rem) * 1.5))
        .font(TextSize.body.font(rem, weight: .semibold))
        .lineLimit(1)
        .fixedSize()
        .accessibilityAddTraits(.isHeader)
    }
}

/// A symbol and its title closer together than the system sets them.
struct ReviewTightLabel: LabelStyle {
    var spacing: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: spacing) {
            configuration.icon
            configuration.title
        }
    }
}

// MARK: - The summary

/// What goes, what it weighs, what the disk will look like, and — once
/// marked paths have gone — what it measurably gained: a column of cards.
private struct ReviewSummary: View {
    let review: ReviewModel
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem

    var body: some View {
        // It scrolls only when the zoom leaves it too little height.
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Space.lg.at(rem)) {
                whatGoes
                volume
                if review.goneCount > 0 {
                    freed
                }
                if !review.plan.blocked.isEmpty {
                    keptBack
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // What was freed arrives when the first mark goes, and the
            // guards' refusals when a mark is kept back: they fade in.
            .animation(ReviewMotion.fade, value: review.goneCount > 0)
            .animation(ReviewMotion.fade, value: review.plan.blocked.count)
        }
        .scrollIndicators(.automatic)
        .scrollBounceBehavior(.basedOnSize)
    }

    private var whatGoes: some View {
        let plan = review.plan
        return ReviewCard {
            VStack(alignment: .leading, spacing: Space.md.at(rem)) {
                CardHeading("What goes", symbol: "shippingbox")
                // What the marks weighed when they were marked: a
                // projection, and called one. Only `statfs` can say what
                // came back.
                Amount(plan.bytes, note: "projected", color: theme.bright)
                VStack(spacing: 0) {
                    FigureRow("Marked", review.items.count, symbol: "checklist")
                    FigureRow(
                        "In the command",
                        plan.targets.count,
                        symbol: "terminal"
                    )
                    FigureRow(
                        "Nested, go with a parent",
                        plan.covered.count,
                        symbol: "arrow.turn.down.right"
                    )
                    FigureRow(
                        "Kept back",
                        plan.blocked.count,
                        symbol: "hand.raised",
                        last: true
                    )
                }
            }
        }
    }

    private var volume: some View {
        ReviewCard {
            VStack(alignment: .leading, spacing: Space.md.at(rem)) {
                HStack(
                    alignment: .firstTextBaseline,
                    spacing: Space.sm.at(rem)
                ) {
                    CardHeading(
                        review.volumeName ?? "Volume",
                        symbol: "internaldrive"
                    )
                    Spacer(minLength: 0)
                    if let space = review.space {
                        Text("\(humanBytes(space.total)) in all")
                            .font(TextSize.caption.font(rem))
                            .monospacedDigit()
                            .foregroundStyle(theme.secondary.color)
                            .lineLimit(1)
                    }
                }
                if let space = review.space {
                    DiskChart(space: space, pending: review.pendingBytes)
                } else {
                    // Nothing to project against: saying so beats a bar
                    // that pretends.
                    Label(
                        "Its free space could not be read.",
                        systemImage: "questionmark.circle"
                    )
                    .font(TextSize.caption.font(rem))
                    .foregroundStyle(theme.secondary.color)
                }
            }
        }
    }

    private var freed: some View {
        let projected = review.goneProjected
        let gain = review.measuredGain
        return ReviewCard {
            VStack(alignment: .leading, spacing: Space.md.at(rem)) {
                CardHeading("Freed so far", symbol: "checkmark.seal")
                if let gain {
                    Amount(gain, note: "measured", color: theme.success)
                } else {
                    Text("Nothing measurably freed yet")
                        .font(TextSize.title.font(rem, weight: .semibold))
                        .fontDesign(.rounded)
                        .foregroundStyle(theme.bright.color)
                }
                VStack(spacing: 0) {
                    FigureRow(
                        "Gone from disk",
                        "\(review.goneCount) of \(review.items.count)",
                        number: Double(review.goneCount),
                        symbol: "checkmark.circle"
                    )
                    FigureRow(
                        "Projected for them",
                        humanBytes(projected),
                        number: Double(projected),
                        symbol: "chart.bar",
                        last: true
                    )
                }
                // The measured number is the disk's free space now against
                // when the first mark was made. It can trail the projection
                // for reasons that have nothing to do with the marks.
                if (gain ?? 0) < projected {
                    Text(
                        "The disk gives space back only when nothing holds "
                            + "it: the Trash keeps what was moved there until "
                            + "it is emptied, and an APFS snapshot keeps what "
                            + "it saw."
                    )
                    .font(TextSize.caption.font(rem))
                    .foregroundStyle(theme.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Text("Measured with statfs since the first mark.")
                    .font(TextSize.caption.font(rem))
                    .foregroundStyle(theme.secondary.color)
            }
        }
        .transition(.opacity)
    }

    private var keptBack: some View {
        let blocked = review.plan.blocked
        return ReviewCard {
            VStack(alignment: .leading, spacing: Space.sm.at(rem)) {
                CardHeading("Kept back", symbol: "hand.raised.fill")
                // A path is marked once, so it names its row.
                ForEach(blocked.prefix(keptBackListed), id: \.path) { item in
                    Label {
                        Text(
                            verbatim: "\(reviewName(item.path)): \(item.reason)"
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                    }
                    .font(TextSize.caption.font(rem))
                    .foregroundStyle(theme.caution.color)
                }
                if blocked.count > keptBackListed {
                    Text(
                        "and \(blocked.count - keptBackListed) more, in the "
                            + "list"
                    )
                    .font(TextSize.caption.font(rem))
                    .foregroundStyle(theme.secondary.color)
                }
            }
        }
        .transition(.opacity)
    }
}

/// A figure beside its label and symbol, rolling when it changes: the
/// definition row, for a number that moves while it is read. Rows are
/// ruled apart by a hairline, as a grouped list's are.
private struct FigureRow: View {
    let label: String
    let value: String
    /// What the figure counts, for its digits to roll by.
    let number: Double
    let symbol: String
    let last: Bool
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A count, as a count in a column of counts is written: verbatim, not
    /// a phrase to localize, which would group its digits.
    init(_ label: String, _ count: Int, symbol: String, last: Bool = false) {
        self.init(
            label,
            "\(count)",
            number: Double(count),
            symbol: symbol,
            last: last
        )
    }

    init(
        _ label: String,
        _ value: String,
        number: Double,
        symbol: String,
        last: Bool = false
    ) {
        self.label = label
        self.value = value
        self.number = number
        self.symbol = symbol
        self.last = last
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm.at(rem)) {
            Image(systemName: symbol)
                .foregroundStyle(theme.secondary.color)
                .frame(width: IconSize.md.at(rem))
                .accessibilityHidden(true)
            Text(label)
                .foregroundStyle(theme.foreground.color)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
            Text(verbatim: value)
                .fontDesign(.rounded)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(theme.bright.color)
                .reviewRolling(number, reduceMotion: reduceMotion)
        }
        .font(TextSize.caption.font(rem))
        .padding(.vertical, Space.xs.at(rem) + Space.xxs.at(rem))
        .overlay(alignment: .bottom) {
            if !last {
                Rectangle()
                    .fill(theme.divider.color)
                    .frame(height: hairline)
                    .padding(.leading, IconSize.md.at(rem) + Space.sm.at(rem))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The summary in one wrapping line, for a window too narrow for its
/// column: the same numbers, each still called projected or measured.
private struct SummaryStrip: View {
    let review: ReviewModel
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let line = line
        ReviewCard(padding: Space.md) {
            Text(line)
                .font(TextSize.caption.font(rem))
                .monospacedDigit()
                .contentTransition(reduceMotion ? .opacity : .numericText())
                .animation(
                    ReviewMotion.change(reduceMotion),
                    value: String(line.characters)
                )
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// `number words · number words`, the numbers set bright.
    private var line: AttributedString {
        let plan = review.plan
        var parts: [(String, String, HSLA)] = [
            (humanBytes(plan.bytes), "projected", theme.bright),
            ("\(plan.targets.count)", "in the command", theme.bright),
        ]
        if !plan.covered.isEmpty {
            parts.append(("\(plan.covered.count)", "nested", theme.bright))
        }
        if !plan.blocked.isEmpty {
            parts.append(("\(plan.blocked.count)", "kept back", theme.caution))
        }
        if let space = review.space, let after = review.after {
            parts.append((humanBytes(space.available), "free", theme.bright))
            if review.pendingBytes > 0 {
                parts.append(
                    (
                        humanBytes(after.available),
                        "free after, projected",
                        theme.highlight
                    )
                )
            }
        } else {
            parts.append(("?", "free", theme.bright))
        }
        let gone = review.goneCount
        if gone > 0 {
            parts.append(
                ("\(gone) of \(review.items.count)", "gone", theme.bright))
            if let gain = review.measuredGain {
                parts.append(
                    (humanBytes(gain), "freed, measured", theme.success))
            } else {
                parts.append(("nothing", "measurably freed yet", theme.bright))
            }
        }
        var line = AttributedString()
        for (index, (number, words, color)) in parts.enumerated() {
            if index > 0 {
                var dot = AttributedString("  \u{00B7}  ")
                dot.foregroundColor = theme.secondary.opacity(0.6).color
                line += dot
            }
            var figure = AttributedString(number)
            figure.foregroundColor = color.color
            figure.font = TextSize.caption.font(rem, weight: .semibold)
            var label = AttributedString(" \(words)")
            label.foregroundColor = theme.secondary.color
            line += figure + label
        }
        return line
    }
}

/// A size set large in rounded figures, its unit beside it, and a tag on
/// what kind of number it is. The number rolls when it changes.
private struct Amount: View {
    let bytes: UInt64
    let note: String
    let color: HSLA
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ bytes: UInt64, note: String, color: HSLA) {
        self.bytes = bytes
        self.note = note
        self.color = color
    }

    var body: some View {
        let (number, unit) = splitSize(humanBytes(bytes))
        HStack(alignment: .firstTextBaseline, spacing: Space.xs.at(rem)) {
            Text(number)
                .font(TextSize.display.font(rem, weight: .bold))
                .fontDesign(.rounded)
                .monospacedDigit()
                .foregroundStyle(color.color)
                .reviewRolling(Double(bytes), reduceMotion: reduceMotion)
            Text(unit)
                .font(TextSize.title.font(rem, weight: .semibold))
                .fontDesign(.rounded)
                .foregroundStyle(theme.secondary.color)
                .contentTransition(.opacity)
                .animation(ReviewMotion.fade, value: unit)
            Spacer(minLength: Space.sm.at(rem))
            Text(note)
                .font(TextSize.caption.font(rem, weight: .medium))
                .foregroundStyle(theme.secondary.color)
                .padding(.horizontal, Space.sm.at(rem))
                .padding(.vertical, Space.xxs.at(rem))
                .background(theme.foreground.opacity(0.07).color, in: Capsule())
                .alignmentGuide(.firstTextBaseline) { dimensions in
                    dimensions[.firstTextBaseline]
                }
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(humanBytes(bytes)), \(note)")
    }
}

// MARK: - The status bar

/// The keys this screen answers to, quietly, in words, the free space, and
/// the system's help button: the explore screen's status bar, in the same
/// quiet line.
private struct ReviewStatusBar: View {
    let space: SpaceInfo?
    let help: @MainActor () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Most useful first, so a narrow window loses the least useful. A
    /// few, as the treemap's status bar has: the style's keys are in its
    /// tooltips, unmarking is the rows' own buttons, and every key is
    /// behind the help button.
    static let hints: [(keys: String, label: String)] = [
        ("enter", "to copy the command"),
        ("f", "to reveal in Finder"),
        ("esc", "to go back"),
    ]

    var body: some View {
        HStack(alignment: .center, spacing: Space.md.at(rem)) {
            Label {
                Text(
                    "\(space.map { humanBytes($0.available) } ?? "?") "
                        + "available"
                )
                .monospacedDigit()
                .reviewRolling(
                    Double(space?.available ?? 0),
                    reduceMotion: reduceMotion
                )
            } icon: {
                Image(systemName: "internaldrive")
            }
            .foregroundStyle(theme.secondary.color)
            .fixedSize()
            Spacer(minLength: 0)
            FittingPrefix(count: Self.hints.count, spacing: 0) { index in
                KeyHint(
                    keys: Self.hints[index].keys,
                    label: Self.hints[index].label,
                    leading: index > 0
                )
            }
            .layoutPriority(-1)
            HelpLink { help() }
                .controlSize(.small)
                .focusEffectDisabled()
                .help("Every key and gesture \u{00b7} ?")
                .accessibilityLabel("All keys and gestures")
        }
        .font(TextSize.caption.font(rem))
        .lineLimit(1)
        .padding(.horizontal, Space.lg.at(rem))
        .padding(.vertical, Space.xs.at(rem) + Space.xxs.at(rem))
        .overlay(alignment: .top) {
            Rectangle().fill(theme.divider.color).frame(height: hairline)
        }
    }
}
