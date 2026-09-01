import AppKit

/// Vim's registers.
///
/// The unnamed register **is** the system pasteboard: a yank in Jot can be
/// pasted into any other app, and anything copied elsewhere can be put with
/// `p`. What the pasteboard cannot carry is whether the text was taken by
/// whole lines, so that one fact is remembered here beside a copy of what was
/// written. If the pasteboard has moved on since — someone copied in another
/// app — the stamp no longer matches and the text is treated as charwise,
/// which is exactly right.
final class VimRegisters {
    struct Entry: Equatable {
        var text: String
        var isLinewise: Bool
    }

    private var stamp: Entry?
    private var named: [Character: Entry] = [:]

    // MARK: - The unnamed register

    /// Called just after the text view has written a yank or delete to the
    /// pasteboard.
    func noteUnnamedWrite(text: String, isLinewise: Bool) {
        stamp = Entry(text: text, isLinewise: isLinewise)
    }

    /// Whether what is on the pasteboard now is the linewise text Jot put
    /// there. Anything else — a fresh copy from another app — is charwise.
    func isUnnamedLinewise(current text: String?) -> Bool {
        guard let stamp, stamp.isLinewise, let text else { return false }
        return stamp.text == text
    }

    // MARK: - Named registers

    /// `"ayy` and friends. Uppercase appends, the way vim does it.
    func write(_ entry: Entry, to name: Character) {
        let lowercased = Character(name.lowercased())
        if name.isUppercase, let existing = named[lowercased] {
            named[lowercased] = Entry(
                text: existing.text + entry.text,
                isLinewise: existing.isLinewise || entry.isLinewise
            )
        } else {
            named[lowercased] = entry
        }
    }

    func read(_ name: Character) -> Entry? {
        named[Character(name.lowercased())]
    }

    func clear() {
        named.removeAll()
        stamp = nil
    }
}
