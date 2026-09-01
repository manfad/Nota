import AppKit

/// One line being typed in the footer: the character that opened it, and what
/// has been typed since.
///
/// `:` runs an ex command and `/` and `?` search; all three are the same
/// editing keys, the same history and the same pane, and differ only in what
/// Return does at the end of them.
struct VimPrompt: Equatable {
    var prefix: Character
    var text: String
}

/// The command pane's line.
///
/// It is engine state and a string handed to the window, not a text field:
/// giving a real control first responder would move the caret out of the note
/// and scroll it, and the whole point of vim's command line is that the buffer
/// stays exactly where it was. So the keys are read here, the text goes to the
/// pane above the footer, and the text view never stops being first responder
/// — which is also what keeps every ⌘ shortcut working while a command is half
/// typed.
extension VimEngine {

    /// The open prompt's text, without its prefix.
    var commandLine: String? { prompt?.text }

    // MARK: - Opening and closing

    /// Whether the open prompt is a search rather than an ex command.
    var isSearchPrompt: Bool {
        prompt.map { $0.prefix == "/" || $0.prefix == "?" } ?? false
    }

    /// `:` in normal mode; from visual mode the selection's range comes with
    /// it, exactly as vim prefills `'<,'>`. `/` and `?` come through
    /// `beginSearch`, which puts the caret and the operator aside first.
    func beginPrompt(_ prefix: Character = ":", initialText: String = "") {
        resetPending()
        discardCommandKeys()
        prompt = VimPrompt(prefix: prefix, text: initialText)
        historyIndex = nil
        historyDraft = nil
        setMode(.commandLine)
        publishPrompt()
    }

    /// Escape, ⌃C, ⌃[, or a Backspace that runs out of text. A search that is
    /// cancelled leaves nothing behind: the caret and the view go back to
    /// where they were before the first keystroke of it.
    func cancelPrompt() {
        closePrompt(cancelled: true)
    }

    private func closePrompt(cancelled: Bool) {
        prompt = nil
        historyIndex = nil
        historyDraft = nil
        host?.vimCommandLineChanged(nil)
        if cancelled, let session = searchSession {
            searchSession = nil
            moveCaret(to: session.origin)
            restoreScroll(to: session.scroll)
            refreshSearchHighlights()
        }
        // A selection is still up when `/` was typed in visual mode, and the
        // mode has to agree with it.
        if let visual {
            setMode(visual.isLinewise ? .visualLine : .visual)
        } else {
            setMode(.normal)
        }
        clampCaret()
        publishPendingKeys()
    }

    /// The footer shows the prompt's character in front of the text, the way
    /// vim's command line does.
    private func publishPrompt() {
        guard let prompt else { return }
        host?.vimCommandLineChanged(String(prompt.prefix) + prompt.text)
    }

    // MARK: - Keys

    /// Everything the line understands. Anything else is ignored rather than
    /// swallowed silently into the note.
    func handlePrompt(_ key: VimKey) -> Bool {
        guard var open = prompt else {
            // The mode without the line is nothing anyone can type into.
            setMode(.normal)
            return false
        }

        if isEscape(key) {
            cancelPrompt()
            return true
        }

        switch key.base {
        case .enter:
            closePrompt(cancelled: false)
            submit(open)
            return true
        case .backspace:
            // An empty line and one more Backspace is the same as Escape,
            // which is how vim leaves a command line you have unwritten.
            guard !open.text.isEmpty else {
                cancelPrompt()
                return true
            }
            open.text.removeLast()
            set(open.text)
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
                set(Self.droppingLastWord(open.text))
            case "u":
                set("")
            default:
                break
            }
            return true
        }

        guard let character = key.plainCharacter else { return true }
        open.text.append(character)
        set(open.text)
        return true
    }

    private func set(_ text: String) {
        prompt?.text = text
        publishPrompt()
        // Vim's `'incsearch'`: the note moves under the pane as you type.
        if let prompt, prompt.prefix == "/" || prompt.prefix == "?" {
            searchIncrementally(text, forward: prompt.prefix == "/")
        }
    }

    /// ⌃W: the trailing run of spaces and then the word before them.
    static func droppingLastWord(_ line: String) -> String {
        var characters = Array(line)
        while let last = characters.last, last == " " { characters.removeLast() }
        while let last = characters.last, last != " " { characters.removeLast() }
        return String(characters)
    }

    // MARK: - History

    /// What ↑ and ↓ walk: everything run at that prompt since the app started.
    func history(for prefix: Character) -> [String] {
        promptHistories[prefix] ?? []
    }

    /// Vim keeps one copy of a repeated command, at the end.
    func remember(_ line: String, for prefix: Character) {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var entries = history(for: prefix)
        entries.removeAll { $0 == line }
        entries.append(line)
        promptHistories[prefix] = entries
    }

    /// Stepping past the newest entry comes back to whatever was being typed
    /// when the walk began.
    private func walkHistory(back: Bool) {
        guard let prefix = prompt?.prefix else { return }
        let entries = history(for: prefix)
        guard !entries.isEmpty else { return }

        if back {
            if historyIndex == nil {
                historyDraft = prompt?.text
                historyIndex = entries.count - 1
            } else {
                historyIndex = max(0, (historyIndex ?? 0) - 1)
            }
        } else {
            guard let index = historyIndex else { return }
            if index + 1 < entries.count {
                historyIndex = index + 1
            } else {
                historyIndex = nil
                set(historyDraft ?? "")
                return
            }
        }
        set(entries[historyIndex ?? 0])
    }

    // MARK: - Running

    /// What Return does: `:` runs an ex command, `/` and `?` commit the
    /// search. Either way the line joins that prompt's history.
    private func submit(_ prompt: VimPrompt) {
        switch prompt.prefix {
        case ":":
            run(prompt.text)
        case "/", "?":
            remember(prompt.text, for: prompt.prefix)
            commitSearch(prompt.text, forward: prompt.prefix == "/")
        default:
            remember(prompt.text, for: prompt.prefix)
        }
    }

    /// The whole of `:` in one call, so a macro or a test can run a command
    /// without typing it a key at a time.
    func run(_ line: String) {
        remember(line, for: ":")
        guard let command = VimEx.parse(line) else { return }
        execute(command)
        clampCaret()
        discardCommandKeys()
    }
}
