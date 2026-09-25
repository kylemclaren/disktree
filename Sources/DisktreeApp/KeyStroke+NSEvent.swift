// Key presses, from AppKit's vocabulary to the dispatcher's.
//
// The window's one key monitor turns each `keyDown` into a `KeyStroke` and
// hands it to `AppState.handleKey`, which is the only place a key means
// anything — the interface zoom and Quick Look's `⌘Y` included. Quick Look's
// panel hands on the keys it does not take the same way. Named keys come from
// the key code, so they are the same on every keyboard layout; every other
// key is the character the layout types with shift applied, so `?` is `?`
// wherever a layout puts it.

import AppKit

/// Virtual key codes of the keys the dispatcher knows by name: Carbon's
/// `kVK_` numbers, which name physical keys rather than characters.
enum KeyCode {
    static let `return`: UInt16 = 0x24
    static let tab: UInt16 = 0x30
    static let space: UInt16 = 0x31
    static let delete: UInt16 = 0x33
    static let escape: UInt16 = 0x35
    static let keypadEnter: UInt16 = 0x4C
    static let home: UInt16 = 0x73
    static let end: UInt16 = 0x77
    static let leftArrow: UInt16 = 0x7B
    static let rightArrow: UInt16 = 0x7C
    static let downArrow: UInt16 = 0x7D
    static let upArrow: UInt16 = 0x7E

    /// The dispatcher's name for each. Return and the keypad's Enter are one
    /// key to it, as they are to anyone pressing them; Delete is the key
    /// that deletes backwards, which the dispatcher calls `backspace`.
    static let names: [UInt16: String] = [
        `return`: "enter",
        keypadEnter: "enter",
        tab: "tab",
        space: "space",
        delete: "backspace",
        escape: "escape",
        home: "home",
        end: "end",
        leftArrow: "left",
        rightArrow: "right",
        downArrow: "down",
        upArrow: "up",
    ]
}

extension KeyStroke {
    /// The dispatcher's reading of a key press, or `nil` for what it has no
    /// reading of: anything but a key going down, a dead key still waiting
    /// for the letter it accents, a function key it has no name for, and a
    /// chord with the Globe key, which belongs to the system (Globe-F is full
    /// screen, Globe-E the character viewer).
    public init?(event: NSEvent) {
        guard event.type == .keyDown else {
            return nil
        }
        let flags = event.modifierFlags.intersection(
            .deviceIndependentFlagsMask
        )
        let control = flags.contains(.control)
        let shift = flags.contains(.shift)
        let command = flags.contains(.command)
        let option = flags.contains(.option)

        if let name = KeyCode.names[event.keyCode] {
            self.init(
                name,
                control: control,
                shift: shift,
                command: command,
                option: option
            )
            return
        }

        // Shift applied, every other modifier ignored: `?` rather than `/`,
        // and `a` for ⌥A, whose `characters` is `å`.
        guard let ignoring = event.charactersIgnoringModifiers,
            let scalar = ignoring.unicodeScalars.first,
            ignoring.count == 1
        else {
            return nil
        }
        // AppKit spells the keys it has no character for in this block of
        // the private use area (NSUpArrowFunctionKey is U+F700). Passed on
        // as characters, they would be typed into the find field.
        if (0xF700...0xF8FF).contains(scalar.value) {
            return nil
        }
        // The arrows and the other named keys carry `.function` too, but
        // they are settled above; on a character it means the Globe key.
        if flags.contains(.function) {
            return nil
        }
        // Caps Lock is not shift: `C` is not `c` to the dispatcher, and a
        // stray Caps Lock must not turn every letter binding off. It still
        // types capitals into the find field, through `characters`.
        let key =
            flags.contains(.capsLock) && !shift
            ? ignoring.lowercased()
            : ignoring

        self.init(
            key,
            character: control || command
                ? nil : Self.typed(event.characters),
            control: control,
            shift: shift,
            command: command,
            option: option
        )
    }

    /// The text a key types, when it is text: one printable character. A
    /// control character is a key, not text.
    private static func typed(_ characters: String?) -> String? {
        guard let characters, characters.count == 1,
            let scalar = characters.unicodeScalars.first,
            scalar.properties.generalCategory != .control
        else {
            return nil
        }
        return characters
    }
}

/// The key monitor's decision for one key press: whether the app consumes
/// it, so that it goes no further.
///
/// Every key goes to the one dispatcher, which knows the only ⌘ chords that
/// are its own — the interface zoom (`⌘=`, `⌘-`, `⌘0`, and ctrl as on
/// Linux) and Quick Look (`⌘Y`) — and lets every other ⌘ chord go on to the
/// menus: `⌘Q` must reach Quit, and `⌘C` must never be read as `c`, which
/// opens the review.
@MainActor
func dispatchKey(_ key: KeyStroke, to state: AppState) -> Bool {
    state.handleKey(key)
}
