// Full Disk Access: the one switch that opens the folders macOS privacy
// keeps closed to apps, and a sheet that offers it once.
//
// Mail, Messages, Safari's data, other apps' containers and more are closed
// to every app until System Settings gives it Full Disk Access. disktree
// counts what it cannot read as unreadable rather than guessing at it (the
// scan totals say how many), so without access a home directory's treemap
// is missing whole folders, and says so only in a quiet count. The first
// time a scan starts at the home directory, or above it, without access, a
// sheet explains that and offers the setting. Answered once, either way, it
// is not offered again; the scan totals keep the way there from then on.
//
// Whether access is granted is found by opening, for reading, one file that
// privacy protects — never by listing a protected folder, the kind of look
// that makes macOS ask the person — and nothing is read from it.

import AppKit
import Darwin
import DisktreeCore
import SwiftUI
import System

/// Whether disktree has Full Disk Access, and where it is given.
enum FullDiskAccess {
    /// What opening the protected file said.
    enum Access: Sendable, Hashable {
        case granted
        /// Refused for want of permission: not granted.
        case denied
        /// Something else went wrong, such as the file not being there:
        /// no reason to ask the person for anything.
        case unknown
    }

    /// System Settings › Privacy & Security › Full Disk Access.
    static let settingsURL =
        URL(
            string: "x-apple.systempreferences:"
                + "com.apple.preference.security?Privacy_AllFiles"
        ) ?? URL(filePath: "/System/Applications/System Settings.app")

    /// Where the sheet's answer is kept (`@AppStorage`): once asked, never
    /// again.
    static let answeredKey = "fullDiskAccessAnswered"

    /// The file whose opening tells: the privacy database's own, which only
    /// an app with Full Disk Access may open.
    static func witness(home: FilePath) -> FilePath {
        home.appending("Library/Application Support/com.apple.TCC/TCC.db")
    }

    /// Whether `path` can be opened for reading. Opening a single file
    /// asks the person nothing: macOS refuses it with `EPERM` (or `EACCES`)
    /// and says no more.
    nonisolated static func probe(_ path: FilePath) -> Access {
        let descriptor = open(path.string, O_RDONLY | O_CLOEXEC)
        if descriptor >= 0 {
            close(descriptor)
            return .granted
        }
        return switch errno {
        case EPERM, EACCES: .denied
        default: .unknown
        }
    }

    /// Whether disktree has access, asked off the main actor: the answer
    /// comes from the privacy daemon, and the window does not wait on it.
    nonisolated static func checking(home: FilePath?) async -> Access {
        guard let home else {
            return .unknown
        }
        return probe(witness(home: home))
    }

    /// Whether to look at all: not once the sheet was answered, not in a
    /// run that `remembers` nothing (a script, a test), which could not
    /// keep the answer and would ask on every launch, and only for a root
    /// the sheet is for.
    nonisolated static func asks(
        answered: Bool,
        remembers: Bool,
        root: FilePath,
        home: FilePath?
    ) -> Bool {
        !answered && remembers && offers(root: root, home: home)
    }

    /// Whether a scan of `root` is one the sheet is for: the home
    /// directory, or a directory holding it (`/`, `/Users`), where the
    /// protected folders live. A project folder has none of them.
    nonisolated static func offers(root: FilePath, home: FilePath?) -> Bool {
        guard let home else {
            return false
        }
        return home.starts(with: root)
    }
}

// MARK: - The sheet

/// The width of the sheet: a paragraph that reads comfortably.
private let sheetWidth = Rems(30)

/// The height of the sheet's gradient header.
private let headerHeight = Rems(7.5)

/// The one-time offer: why access matters, the way to the setting, and,
/// once it is given, a scan that measures what was closed.
///
/// A native sheet, headed by the palette's gradient with a shield on a disc
/// of glass: the one moment the app asks for something, set apart from the
/// screens without a word of text on the gradient. Below it the reason, the
/// state of the setting, and the system's own buttons.
///
/// While the sheet is up it asks every second whether access has been
/// given, so switching disktree on in System Settings turns the main button
/// into "Scan again" without a word from the person. macOS may instead ask
/// to reopen disktree; the next launch then finds access, and asks nothing.
struct FullDiskAccessSheet: View {
    /// Asks whether access is granted now.
    let check: () async -> FullDiskAccess.Access
    let openSettings: () -> Void
    let scanAgain: () -> Void
    let skip: () -> Void
    @State private var access: FullDiskAccess.Access
    /// System Settings was opened from here: say what is being waited for.
    @State private var waiting = false
    @Environment(\.theme) private var theme
    @Environment(\.rem) private var rem
    @Environment(\.accessibilityReduceMotion) private var reduced

    /// How often the sheet asks again while it is up.
    static let pollInterval = Duration.seconds(1)

    init(
        access: FullDiskAccess.Access = .denied,
        check: @escaping () async -> FullDiskAccess.Access,
        openSettings: @escaping () -> Void,
        scanAgain: @escaping () -> Void,
        skip: @escaping () -> Void
    ) {
        self._access = State(initialValue: access)
        self.check = check
        self.openSettings = openSettings
        self.scanAgain = scanAgain
        self.skip = skip
    }

    var body: some View {
        let granted = access == .granted
        VStack(spacing: 0) {
            header(granted: granted)
            VStack(alignment: .leading, spacing: Space.md.at(rem)) {
                VStack(alignment: .leading, spacing: Space.xxs.at(rem)) {
                    Text("Full Disk Access")
                        .font(TextSize.caption.font(rem, weight: .semibold))
                        .foregroundStyle(theme.accent.color)
                    Text("Let disktree measure every folder")
                        .font(TextSize.heading.font(rem, weight: .bold))
                        .foregroundStyle(theme.bright.color)
                        .accessibilityAddTraits(.isHeader)
                }
                Text(
                    "macOS keeps some folders closed to apps \u{2014} Mail, "
                        + "Messages, Safari and other apps\u{2019} data among "
                        + "them \u{2014} until System Settings gives the app "
                        + "Full Disk Access. disktree counts what it cannot "
                        + "read as unreadable rather than guessing at its "
                        + "size, so without access those folders are missing "
                        + "from the treemap."
                )
                .font(TextSize.body.font(rem))
                .foregroundStyle(theme.foreground.color)
                .fixedSize(horizontal: false, vertical: true)
                // What the access is used for, said no wider than it is.
                Label(
                    "The access is for measuring: the scan reads names, "
                        + "sizes and dates, and disktree removes nothing "
                        + "itself.",
                    systemImage: "hand.raised.fill"
                )
                .font(TextSize.caption.font(rem))
                .foregroundStyle(theme.secondary.color)
                .fixedSize(horizontal: false, vertical: true)
                status
            }
            .padding(.horizontal, Space.xl.at(rem))
            .padding(.top, Space.lg.at(rem))
            .padding(.bottom, Space.lg.at(rem))
            buttons(granted: granted)
                .padding(.horizontal, Space.xl.at(rem))
                .padding(.bottom, Space.lg.at(rem))
        }
        .frame(width: sheetWidth.at(rem))
        .background(theme.surface.color)
        .animation(
            ChromeMotion.animation(ChromeMotion.arrive, reduced: reduced),
            value: access
        )
        .chromeIdentifier("full-disk-access", container: true)
        .task {
            // Live: the setting is switched in another app, and the sheet
            // follows it there.
            while !Task.isCancelled {
                let now = await check()
                if now != access {
                    access = now
                }
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    /// The palette's gradient, and a shield on a disc of glass that opens
    /// its lock once access is given.
    private func header(granted: Bool) -> some View {
        let disc = Rems(4.5).at(rem)
        return ZStack {
            BackdropView()
            // A disc of glass over the gradient where there is glass, and
            // a frosted one where there is not.
            Color.clear
                .glassPlate(
                    Circle(),
                    fill: HSLA(h: 0, s: 0, l: 1)
                        .opacity(theme.isDark ? 0.14 : 0.45),
                    border: HSLA(h: 0, s: 0, l: 1)
                        .opacity(theme.isDark ? 0.3 : 0.8)
                )
                .frame(width: disc, height: disc)
            Image(
                systemName: granted
                    ? "checkmark.shield.fill" : "lock.shield.fill"
            )
            .font(.system(size: disc * 0.46, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(
                (granted ? theme.success : theme.accent).color
            )
            .contentTransition(
                reduced ? .opacity : .symbolEffect(.replace)
            )
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
        .frame(height: headerHeight.at(rem))
        .clipped()
    }

    /// Continue without it, and the way to the setting or, once it is
    /// given, the scan that measures what was closed: the system's own
    /// buttons, the main one prominent and the default.
    private func buttons(granted: Bool) -> some View {
        HStack(spacing: Space.sm.at(rem)) {
            Spacer(minLength: 0)
            // Once it is given, there is nothing to go without.
            Button(granted ? "Not Now" : "Continue Without", action: skip)
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .help("Scan without it; the scan totals keep the way here")
                .chromeIdentifier("access-skip")
            if granted {
                Button("Scan Again", systemImage: "arrow.clockwise") {
                    scanAgain()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .help("Measure the folders that were closed")
                .chromeIdentifier("access-scan")
            } else {
                Button(
                    "Open Privacy & Security",
                    systemImage: "gearshape.fill"
                ) {
                    waiting = true
                    openSettings()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .help(
                    "System Settings \u{203a} Privacy & Security \u{203a} "
                        + "Full Disk Access: switch disktree on there"
                )
                .chromeIdentifier("access-open")
            }
        }
        .controlSize(.large)
        // The app's one fill for a main action, as the review's Copy
        // Command and the inspector's Review button.
        .tint(reviewProminentTint(theme))
    }

    /// Where things stand, in a line.
    private var status: some View {
        let (symbol, text, color): (String, String, HSLA) =
            switch access {
            case .granted:
                (
                    "checkmark.circle.fill",
                    "Granted \u{00b7} scan again to measure what was closed",
                    theme.success
                )
            case .denied where waiting:
                (
                    "hourglass",
                    "Waiting for System Settings \u{00b7} switch disktree on; "
                        + "macOS may ask to reopen it",
                    theme.secondary
                )
            case .denied, .unknown:
                (
                    "circle.dashed",
                    "Not granted \u{00b7} Privacy & Security \u{203a} Full "
                        + "Disk Access",
                    theme.secondary
                )
            }
        return HStack(alignment: .center, spacing: Space.sm.at(rem)) {
            Image(systemName: symbol)
                .font(TextSize.body.font(rem, weight: .semibold))
                .foregroundStyle(color.color)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(
                    .pulse,
                    options: .repeat(.continuous),
                    isActive: waiting && access != .granted && !reduced
                )
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(
                    (access == .granted ? color : theme.foreground).color
                )
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(TextSize.caption.font(rem))
        .padding(.horizontal, Space.md.at(rem))
        .padding(.vertical, Space.sm.at(rem))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            color.opacity(access == .granted ? 0.12 : 0.07).color,
            in: RoundedRectangle(
                cornerRadius: Rounding.control.at(rem),
                style: .continuous
            )
        )
        .accessibilityElement(children: .combine)
        .chromeIdentifier("access-status")
    }
}
