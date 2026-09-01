import AppKit

/// The `:` line.
///
/// It is engine state and a string handed to the window, not a text field:
/// giving a real control first responder would move the caret out of the note
/// and scroll it, and the whole point of vim's command line is that the buffer
/// stays exactly where it was. So the keys are read here, the text goes to the
/// footer's left slot where showcmd normally sits, and the text view never
/// stops being first responder — which is also what keeps every ⌘ shortcut
/// working while a command is half typed.
extension VimEngine {

    // MARK: - Opening and closing

    /// `:` in normal mode; from visual mode the selection's range comes with
    /// it, exactly as vim prefills `'<,'>`.
    func beginCommandLine(initialText: String = "") {
        resetPending()
        discardCommandKeys()
        commandLine = initialText
        historyIndex = nil
        historyDraft = nil
        setMode(.commandLine)
        publishCommandLine()
    }

    /// Escape, ⌃C, ⌃[, or a Backspace that runs out of text.
    func cancelCommandLine() {
        closeCommandLine()
    }

    private func closeCommandLine() {
        commandLine = nil
        historyIndex = nil
        historyDraft = nil
        host?.vimCommandLineChanged(nil)
        setMode(.normal)
        clampCaret()
        publishPendingKeys()
    }

    private func publishCommandLine() {
        host?.vimCommandLineChanged(":" + (commandLine ?? ""))
    }

    // MARK: - Keys

    /// Everything the line understands. Anything else is ignored rather than
    /// swallowed silently into the note.
    func handleCommandLine(_ key: VimKey) -> Bool {
        guard var line = commandLine else {
            // The mode without the line is nothing anyone can type into.
            setMode(.normal)
            return false
        }

        if isEscape(key) {
            cancelCommandLine()
            return true
        }

        switch key.base {
        case .enter:
            let typed = line
            closeCommandLine()
            run(typed)
            return true
        case .backspace:
            // An empty line and one more Backspace is the same as Escape,
            // which is how vim leaves a command line you have unwritten.
            guard !line.isEmpty else {
                cancelCommandLine()
                return true
            }
            line.removeLast()
            set(line)
            return true
        case .up:
            walkHistory(back: true)
            return true
        case .down:
            walkHistory(back: false)
            return true
        default:
            break
        }

        if key.control {
            switch key.character {
            case "w":
                set(Self.droppingLastWord(line))
            case "u":
                set("")
            default:
                break
            }
            return true
        }

        guard let character = key.plainCharacter else { return true }
        line.append(character)
        set(line)
        return true
    }

    private func set(_ line: String) {
        commandLine = line
        publishCommandLine()
    }

    /// ⌃W: the trailing run of spaces and then the word before them.
    static func droppingLastWord(_ line: String) -> String {
        var characters = Array(line)
        while let last = characters.last, last == " " { characters.removeLast() }
        while let last = characters.last, last != " " { characters.removeLast() }
        return String(characters)
    }

    // MARK: - History

    /// ↑ and ↓ walk the commands run since the app started. Stepping past the
    /// newest one comes back to whatever was being typed when the walk began.
    private func walkHistory(back: Bool) {
        guard !commandHistory.isEmpty else { return }
        if back {
            if historyIndex == nil {
                historyDraft = commandLine
                historyIndex = commandHistory.count - 1
            } else {
                historyIndex = max(0, (historyIndex ?? 0) - 1)
            }
        } else {
            guard let index = historyIndex else { return }
            if index + 1 < commandHistory.count {
                historyIndex = index + 1
            } else {
                historyIndex = nil
                set(historyDraft ?? "")
                return
            }
        }
        set(commandHistory[historyIndex ?? 0])
    }

    /// Vim keeps one copy of a repeated command, at the end.
    func rememberCommand(_ line: String) {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        commandHistory.removeAll { $0 == line }
        commandHistory.append(line)
    }

    // MARK: - Running

    /// The whole of `:` in one call, so a macro or a test can run a command
    /// without typing it a key at a time.
    func run(_ line: String) {
        rememberCommand(line)
        guard let command = VimEx.parse(line) else { return }
        execute(command)
        clampCaret()
        discardCommandKeys()
    }
}
