import AppKit
import Carbon.HIToolbox

/// A key combination the way a menu item wears one: the key equivalent, and
/// the modifiers beside it.
///
/// This is deliberately not `GlobalHotKey.Shortcut`. That one is a virtual key
/// code, because Carbon registers a global hotkey by position on the keyboard;
/// an app shortcut is matched by AppKit against the character the key produces,
/// so the character is what has to be stored.
struct KeyCombo: Hashable, Codable {
    /// `NSMenuItem.keyEquivalent`: lowercase for a letter, "\t" for Tab.
    var key: String
    /// `NSEvent.ModifierFlags` raw value, device-independent flags only.
    var modifiers: UInt

    init(_ key: String, _ modifiers: NSEvent.ModifierFlags = [.command]) {
        self.key = key
        self.modifiers = modifiers.rawValue
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// Something like "⌘P", in the glyph order the menu bar uses.
    var displayName: String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + KeyCodeNames.name(forKey: key)
    }

    /// The combination `event` stands for, or nil when it is not one an app
    /// shortcut may have. ⌘ or ⌃ has to be in it: anything less would swallow
    /// ordinary typing everywhere the key is pressed. ⌘ on its own with a
    /// letter is fine — that is what most of these are.
    static func recorded(from event: NSEvent) -> KeyCombo? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift])
        guard modifiers.contains(.command) || modifiers.contains(.control) else { return nil }
        guard let key = keyEquivalent(for: event) else { return nil }
        return KeyCombo(key, modifiers)
    }

    /// Tab has no character worth reading off the event, and a letter is
    /// stored lowercase with ⇧ beside it — the spelling a menu item wants.
    private static func keyEquivalent(for event: NSEvent) -> String? {
        if event.keyCode == UInt16(kVK_Tab) { return "\t" }
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty
        else { return nil }
        return characters.lowercased()
    }
}

/// Every command whose key the user may change, in the order the Shortcuts tab
/// lists them.
///
/// The system-standard items are deliberately not here: Undo, Redo, Cut, Copy,
/// Paste, Select All, Hide, Quit and Minimize are the Mac's keys, not Nota's,
/// and moving one would only make the app read as broken. They come back below
/// as `reservedCombos`, which nothing else is allowed to take.
enum ShortcutAction: String, CaseIterable, Codable {
    case newTab, newWindow, openFile, closeTab, save, saveAs, export, bookmarkTab, showBookmarks
    case goToTab, nextTab, previousTab
    case find, findNext, findPrevious, searchAllNotes, goToLine
    case toggleComment, indent, outdent
    case increaseFontSize, decreaseFontSize, actualSize
    case showImages, markdownPreview, readingMode, zenMode
    case settings

    /// The menu the command lives in — and the Shortcuts tab's headings.
    enum Group: String, CaseIterable {
        case file = "File"
        case window = "Window"
        case find = "Find"
        case edit = "Edit"
        case view = "View"
        case nota = "Nota"

        var actions: [ShortcutAction] {
            ShortcutAction.allCases.filter { $0.group == self }
        }
    }

    var group: Group {
        switch self {
        case .newTab, .newWindow, .openFile, .closeTab, .save, .saveAs, .export, .bookmarkTab,
             .showBookmarks: .file
        case .goToTab, .nextTab, .previousTab: .window
        case .find, .findNext, .findPrevious, .searchAllNotes, .goToLine: .find
        case .toggleComment, .indent, .outdent: .edit
        case .increaseFontSize, .decreaseFontSize, .actualSize,
             .showImages, .markdownPreview, .readingMode, .zenMode: .view
        case .settings: .nota
        }
    }

    /// The English menu title, which is also the `L10n` key it is looked up
    /// under — so the row and the menu item can never drift apart.
    var titleKey: String {
        switch self {
        case .newTab: "New Tab"
        case .newWindow: "New Window"
        case .openFile: "Open…"
        case .closeTab: "Close Tab"
        case .save: "Save"
        case .saveAs: "Save As…"
        case .export: "Export…"
        case .bookmarkTab: "Bookmark This Tab"
        case .showBookmarks: "Show Bookmarks…"
        case .goToTab: "Jump to Tab…"
        case .nextTab: "Next Tab"
        case .previousTab: "Previous Tab"
        case .find: "Find…"
        case .findNext: "Find Next"
        case .findPrevious: "Find Previous"
        case .searchAllNotes: "Search All Tabs…"
        case .goToLine: "Jump to Line…"
        case .toggleComment: "Toggle Comment"
        case .indent: "Indent"
        case .outdent: "Outdent"
        case .increaseFontSize: "Increase Font Size"
        case .decreaseFontSize: "Decrease Font Size"
        case .actualSize: "Actual Size"
        case .showImages: "Sidebar"
        case .markdownPreview: "Mode Toggle"
        case .readingMode: "Reading Mode"
        case .zenMode: "Zen Mode"
        case .settings: "Settings…"
        }
    }

    var title: String { L10n.text(titleKey) }

    /// The key the command ships with — the one `AppDelegate.buildMenu` used
    /// to spell out at the call site.
    var defaultCombo: KeyCombo {
        switch self {
        case .newTab: KeyCombo("t")
        case .newWindow: KeyCombo("n", [.command, .shift])
        case .openFile: KeyCombo("o")
        case .closeTab: KeyCombo("w")
        case .save: KeyCombo("s")
        case .saveAs: KeyCombo("s", [.command, .shift])
        // ⌘E is the Mac's Use Selection for Find and stays where it is; ⇧⌘E
        // is free, and reads as the Save As… beside it.
        case .export: KeyCombo("e", [.command, .shift])
        // ⌘D and ⇧⌘D are the bookmark pair; duplicating a line is ⇧⌥↓.
        case .bookmarkTab: KeyCombo("d")
        case .showBookmarks: KeyCombo("d", [.command, .shift])
        case .goToTab: KeyCombo("j", [.command, .shift])
        case .nextTab: KeyCombo("\t", [.control])
        case .previousTab: KeyCombo("\t", [.control, .shift])
        case .find: KeyCombo("f")
        case .findNext: KeyCombo("g")
        case .findPrevious: KeyCombo("g", [.command, .shift])
        case .searchAllNotes: KeyCombo("f", [.command, .shift])
        case .goToLine: KeyCombo("j")
        case .toggleComment: KeyCombo("/")
        case .indent: KeyCombo("]")
        case .outdent: KeyCombo("[")
        case .increaseFontSize: KeyCombo("+")
        case .decreaseFontSize: KeyCombo("-")
        case .actualSize: KeyCombo("0")
        case .showImages: KeyCombo("b")
        case .markdownPreview: KeyCombo("p")
        case .readingMode: KeyCombo("p", [.command, .shift])
        case .zenMode: KeyCombo("z", [.command, .option])
        case .settings: KeyCombo(",")
        }
    }

    /// The combinations no command may be moved onto, and the command each one
    /// belongs to. Every Mac has these, and a note-taking app that ate ⌘C
    /// would simply be broken.
    static let reservedCombos: [(combo: KeyCombo, titleKey: String)] = [
        (KeyCombo("q"), "Quit Nota"),
        (KeyCombo("h"), "Hide Nota"),
        (KeyCombo("z"), "Undo"),
        (KeyCombo("z", [.command, .shift]), "Redo"),
        (KeyCombo("x"), "Cut"),
        (KeyCombo("c"), "Copy"),
        (KeyCombo("v"), "Paste"),
        (KeyCombo("a"), "Select All"),
        (KeyCombo("m"), "Minimize"),
        // Nota's own fixed keys: the older new-tab key that also brings a
        // hidden window back, the two Find items that stay put, and ⌘1–⌘9,
        // which pick a tab by number.
        (KeyCombo("n"), "New Tab"),
        (KeyCombo("r"), "Find and Replace…"),
        (KeyCombo("e"), "Use Selection for Find"),
    ] + (1...9).map { (KeyCombo("\($0)"), "Tab \($0)") }
}

extension NSMenuItem {
    /// Puts the user's key for `action` on the item — the one place a menu
    /// item and the shortcut table meet.
    func applyShortcut(_ action: ShortcutAction, preferences: Preferences = .shared) {
        let combo = preferences.combo(for: action)
        keyEquivalent = combo.key
        keyEquivalentModifierMask = combo.flags
    }
}
