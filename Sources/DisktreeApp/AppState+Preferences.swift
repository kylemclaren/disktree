// Preferences, as the state applies and saves them: read once at launch,
// saved whenever the person tunes something they will want back, and
// changed from the Settings window.
//
// The run is what is on screen; `preferences` is what the next launch will
// start from. They differ only where the command line overrode a value for
// this run, which is never saved.

import CoreGraphics
import DisktreeCore

extension AppState {
    /// Take on the saved preferences at launch, then save every change to
    /// `store` (`nil`: save nothing, for a scripted run).
    ///
    /// Depth and the scan options are not applied here: they reached the
    /// state through the command line, which starts from these same
    /// preferences and overrides them for the run (`parseArguments`).
    public func adopt(
        _ preferences: Preferences,
        store: (any PreferenceStore)?
    ) {
        // Applying what was just read is not a change to save.
        preferenceStore = nil
        let preferences = preferences.validated()
        self.preferences = preferences
        // Age is drawn over areas by size: a run the command line ranks by
        // files is coloured by kind, for this run.
        colorMode =
            preferences.colorMode == .age && options.metric == .files
            ? .kind : preferences.colorMode
        commandStyle = preferences.commandStyle
        showSelection = preferences.showPanel
        panelRems = preferences.panelRems
        if zoomStep != preferences.zoomStep {
            zoomStep = preferences.zoomStep
            // The header bands are in rem.
            cache = nil
        }
        preferenceStore = store
    }

    /// Change one preference, from the Settings window: saved, and applied
    /// now where the run has it — depth, colour, the panel, the command
    /// style, the panel's width and the interface zoom.
    ///
    /// The scan options are the exception: the tree on screen was measured
    /// with the old ones, and a Settings switch is not the place to start a
    /// walk of the whole home directory. They apply from the next launch;
    /// `i` and `d` change them for this one.
    public func setPreference<Value: Equatable>(
        _ keyPath: WritableKeyPath<Preferences, Value>,
        _ value: Value
    ) {
        let old = preferences
        var next = old
        next[keyPath: keyPath] = value
        next = next.validated()
        save(next)
        // Only what changed: another value may differ from the run on
        // purpose, where the command line overrode it.
        if next.depth != old.depth {
            layoutOptions.maxDepth = next.depth
            cache = nil
            rehover()
        }
        if next.colorMode != old.colorMode {
            // Age keeps areas by size, as the mode picker's Age does: a
            // Settings switch must not make a combination the picker has
            // no place for.
            if next.colorMode == .age {
                setMode(2)
            } else {
                colorMode = next.colorMode
            }
        }
        if next.showPanel != old.showPanel {
            showSelection = next.showPanel
        }
        if next.commandStyle != old.commandStyle {
            commandStyle = next.commandStyle
        }
        if next.panelRems != old.panelRems {
            panelRems = next.panelRems
        }
        if next.zoomStep != old.zoomStep {
            zoomStep = next.zoomStep
            cache = nil
        }
    }

    /// Something the person tunes by hand changed: keep it for the next
    /// launch. Called from the tuned properties' observers, so every route
    /// to them — a key, a drag, a menu — is saved alike.
    func remember(_ change: (inout Preferences) -> Void) {
        var next = preferences
        change(&next)
        save(next.validated())
    }

    /// Make `next` the preferences, writing to the store what changed.
    private func save(_ next: Preferences) {
        guard next != preferences else {
            return
        }
        let old = preferences
        preferences = next
        if let preferenceStore {
            next.write(to: preferenceStore, changedFrom: old)
        }
    }
}
