import AppKit

/// `.`, and the bookkeeping that makes it possible.
///
/// What is remembered is the *change*, not the keystrokes as they arrived:
/// the keys of the command with its counts marked (so `3.` can put a
/// different count in their place) and, when the command ended in insert
/// mode, the text that was typed there. That is what lets `.` after
/// `ciwfoo⎋` redo the whole thing, text and all.
///
/// A replay runs inside one undo group, so `u` after `.` puts back everything
/// `.` did — the same one-command-one-undo rule the rest of the engine keeps.
extension VimEngine {

    struct ChangeRecord {
        var keys: [VimKey]
        /// Which of `keys` were typed as a count.
        var countIndices: Set<Int>
        /// What was typed before Escape, when the change ended in insert mode.
        var insertedText: String?
    }

    /// Where insert mode was entered, and what the note looked like then.
    struct InsertSession {
        var keys: [VimKey]
        var countIndices: Set<Int>
        var location: Int
        var length: Int
    }

    // MARK: - Recording

    func discardCommandKeys() {
        commandKeys = []
        countKeyIndices = []
        commandChangedText = false
        commandWasVisual = false
    }

    /// Called by `finishCommand`: a command that changed the text becomes the
    /// thing `.` will do again. One that ended in insert mode waits for the
    /// Escape, so the typing counts as part of it.
    func concludeCommand() {
        guard mode != .insert else {
            discardCommandKeys()
            return
        }
        if !isReplaying, commandChangedText, !commandWasVisual {
            lastChange = ChangeRecord(
                keys: commandKeys, countIndices: countKeyIndices, insertedText: nil
            )
        }
        discardCommandKeys()
    }

    func beginInsertSession() {
        insertSession = InsertSession(
            keys: commandKeys, countIndices: countKeyIndices,
            location: caret, length: text.length
        )
    }

    func endInsertSession() {
        guard let session = insertSession else { return }
        insertSession = nil
        let typed = typedText(in: session)
        if !typed.isEmpty {
            // Typing goes straight through `NSTextView`, never through
            // `replace`, so the marks have to be told about it here.
            marks.adjust(at: session.location, removed: 0, inserted: (typed as NSString).length)
        }
        marks.set("^", to: caret)
        guard !isReplaying else { return }
        lastChange = ChangeRecord(
            keys: session.keys, countIndices: session.countIndices, insertedText: typed
        )
    }

    /// What was typed during an insert session — the text between where it
    /// started and where the caret ended up, when the two agree on how much
    /// the note grew. Anything more adventurous (arrow keys, a click) and
    /// `.` repeats the command without the typing rather than guessing.
    private func typedText(in session: InsertSession) -> String {
        let delta = text.length - session.length
        guard delta > 0, caret == session.location + delta,
              session.location + delta <= text.length
        else { return "" }
        return text.substring(with: NSRange(location: session.location, length: delta))
    }

    // MARK: - Replaying

    /// `.`, and `3.` with a count of its own to put in place of the original.
    func repeatLastChange(count: Int?) {
        guard let change = lastChange, !isReplaying, !change.keys.isEmpty else { return }
        isReplaying = true
        textView?.breakUndoCoalescing()
        let manager = textView?.undoManager
        manager?.beginUndoGrouping()

        var keys = change.keys
        if let count {
            keys = VimKey.parse("\(count)")
                + change.keys.enumerated()
                    .filter { !change.countIndices.contains($0.offset) }
                    .map(\.element)
        }
        for key in keys { feed(key) }
        if mode == .insert {
            if let typed = change.insertedText, !typed.isEmpty { insertLiteral(typed) }
            feed(.escape)
        }

        manager?.endUndoGrouping()
        isReplaying = false
        discardCommandKeys()
    }

    /// One key, played rather than struck. Insert mode leans on `NSTextView`
    /// for the typing itself, and there is no `keyDown` behind a replay, so
    /// anything the engine declines is inserted here instead.
    func feed(_ key: VimKey) {
        guard !dispatch(key) else { return }
        switch mode {
        case .insert, .replace:
            if let character = key.plainCharacter {
                insertLiteral(String(character))
            } else if key.base == .enter {
                insertLiteral("\n")
            } else if key.base == .tab {
                insertLiteral("\t")
            }
        default:
            break
        }
    }

    func insertLiteral(_ string: String) {
        guard let textView else { return }
        textView.insertText(string, replacementRange: textView.selectedRange())
    }
}
