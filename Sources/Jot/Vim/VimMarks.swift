import Foundation

/// Where `ma` put a mark, and where `` `a `` and `'a` go back to.
///
/// A mark is one offset into the note, so every edit has to move the marks
/// that sit after it or they would drift onto the wrong words. Vim's own rule
/// is followed: a mark past the edit shifts by the edit's delta, and a mark
/// *inside* what was replaced collapses to the start of the replacement
/// rather than pointing into text that no longer exists.
///
/// Besides `a`–`z` there are the ones vim keeps for you: `'` for the last
/// jump (both `` `` ` `` and `''` read it), `.` for the last change, `^` for
/// where insert mode was left, and `<` / `>` for the last visual selection.
struct VimMarks {

    /// `` ` `` and `'` name the same mark; everything is stored under `'`.
    static func canonical(_ name: Character) -> Character {
        name == "`" ? "'" : name
    }

    /// The marks vim sets for you, which `ma` may not overwrite by hand.
    static let automatic: Set<Character> = ["'", ".", "^", "<", ">"]

    private var marks: [Character: Int] = [:]

    subscript(name: Character) -> Int? {
        get { marks[Self.canonical(name)] }
        set { marks[Self.canonical(name)] = newValue }
    }

    mutating func set(_ name: Character, to location: Int) {
        marks[Self.canonical(name)] = max(0, location)
    }

    func location(_ name: Character) -> Int? {
        marks[Self.canonical(name)]
    }

    mutating func clear() { marks.removeAll() }

    /// What `:marks` lists: the last jump first, then the letters, then the
    /// ones vim keeps for you.
    func listing() -> [(name: Character, location: Int)] {
        let ordered = ["'"] + "abcdefghijklmnopqrstuvwxyz".map(String.init) + [".", "^", "<", ">"]
        return ordered.compactMap { name in
            guard let character = name.first, let location = marks[character] else { return nil }
            return (character, location)
        }
    }

    /// `removed` characters at `location` became `inserted` characters.
    mutating func adjust(at location: Int, removed: Int, inserted: Int) {
        guard removed != 0 || inserted != 0 else { return }
        let end = location + removed
        let delta = inserted - removed
        for (name, mark) in marks {
            if mark >= end {
                marks[name] = mark + delta
            } else if mark > location {
                marks[name] = location
            }
        }
    }
}

// MARK: - Jumping

extension VimEngine {
    /// `` `a `` lands on the exact character the mark was put on; `'a` lands
    /// on the first non-blank of its line and counts as a linewise motion, so
    /// `d'a` takes whole lines and ``d`a`` does not.
    ///
    /// Either one is a jump, and a jump leaves `` `` ` `` behind at the place
    /// it set off from.
    func jumpToMark(_ name: Character, exact: Bool) {
        guard let stored = marks.location(name) else {
            host?.vimShow(message: "Mark not set")
            resetPending()
            return
        }
        let from = caret
        let clamped = min(max(0, stored), text.length)
        let destination = exact ? clamped : VimMotions.firstNonBlank(text, at: clamped)
        if pendingOperator == nil { marks.set("'", to: from) }
        applyMotion(
            VimMotionResult(
                location: destination, kind: exact ? .exclusive : .linewise,
                // A mark that is set is always somewhere to go, even when it
                // is the line the caret is already on — `d'a` there is still
                // a linewise delete of that line.
                moved: true
            )
        )
    }
}
