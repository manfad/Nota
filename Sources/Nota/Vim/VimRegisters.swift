import AppKit

/// Vim's registers.
///
/// The unnamed register **is** the system pasteboard: a yank in Nota can be
/// pasted into any other app, and anything copied elsewhere can be put with
/// `p`. What the pasteboard cannot carry is whether the text was taken by
/// whole lines, so that one fact is remembered here beside a copy of what was
/// written. If the pasteboard has moved on since — someone copied in another
/// app — the stamp no longer matches and the text is treated as charwise,
/// which is exactly right.
///
/// Everything else vim names — `"a`–`"z`, the yank register `"0`, the delete
/// ring `"1`–`"9`, the small-delete register `"-` — is plain text kept here.
/// `"_` is the black hole and `"+` / `"*` are the pasteboard under another
/// name, so neither is ever stored; the engine recognises both.
final class VimRegisters {
    struct Entry: Equatable {
        var text: String
        var isLinewise: Bool
    }

    /// Writes to it vanish and reads from it come back empty.
    static let blackHole: Character = "_"

    /// `"+` and `"*` are the system pasteboard, which is already the unnamed
    /// register, so the engine routes them there rather than storing them.
    static func isPasteboard(_ name: Character) -> Bool { name == "+" || name == "*" }

    private var stamp: Entry?
    private var storage: [Character: Entry] = [:]

    // MARK: - The unnamed register

    /// Called just after the text view has written a yank or delete to the
    /// pasteboard.
    func noteUnnamedWrite(text: String, isLinewise: Bool) {
        stamp = Entry(text: text, isLinewise: isLinewise)
    }

    /// Whether what is on the pasteboard now is the linewise text Nota put
    /// there. Anything else — a fresh copy from another app — is charwise.
    func isUnnamedLinewise(current text: String?) -> Bool {
        guard let stamp, stamp.isLinewise, let text else { return false }
        return stamp.text == text
    }

    // MARK: - Writing

    /// A yank. Naming no register fills `"0`, which is what makes `"0p` put
    /// back the last thing yanked however many deletes have happened since.
    func recordYank(_ entry: Entry, register: Character?) {
        guard let register else {
            storage["0"] = entry
            return
        }
        guard register != Self.blackHole, !Self.isPasteboard(register) else { return }
        write(entry, to: register)
    }

    /// A delete. Naming no register sends a small delete — less than a line,
    /// charwise — to `"-`, and anything bigger to the head of the `"1`–`"9`
    /// ring, shifting what was there along.
    func recordDelete(_ entry: Entry, register: Character?, small: Bool) {
        guard let register else {
            if small {
                storage["-"] = entry
            } else {
                shiftNumbered(entry)
            }
            return
        }
        guard register != Self.blackHole, !Self.isPasteboard(register) else { return }
        write(entry, to: register)
    }

    private func shiftNumbered(_ entry: Entry) {
        for number in stride(from: 8, through: 1, by: -1) {
            storage[Character("\(number + 1)")] = storage[Character("\(number)")]
        }
        storage["1"] = entry
    }

    // MARK: - Named registers

    /// `"ayy` and friends. Uppercase appends, the way vim does it — and an
    /// append onto a linewise register keeps whole lines whole.
    func write(_ entry: Entry, to name: Character) {
        guard name != Self.blackHole, !Self.isPasteboard(name) else { return }
        let key = Character(name.lowercased())
        if name.isUppercase, let existing = storage[key] {
            var text = existing.text
            if existing.isLinewise, !text.hasSuffix("\n") { text += "\n" }
            storage[key] = Entry(
                text: text + entry.text,
                isLinewise: existing.isLinewise || entry.isLinewise
            )
        } else {
            storage[key] = entry
        }
    }

    func read(_ name: Character) -> Entry? {
        guard name != Self.blackHole else { return nil }
        return storage[Character(name.lowercased())]
    }

    /// What `:reg` lists: everything with something in it, in vim's order —
    /// the yank register, the delete ring, the small delete, then `a`–`z`.
    /// The unnamed register is the pasteboard and is not kept here, so it is
    /// not in the list.
    func listing() -> [(name: Character, entry: Entry)] {
        let ordered = Array("0123456789-") + Array("abcdefghijklmnopqrstuvwxyz")
        return ordered.compactMap { name in
            storage[name].map { (name, $0) }
        }
    }

    func clear() {
        storage.removeAll()
        stamp = nil
    }
}
