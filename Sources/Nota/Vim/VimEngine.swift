import AppKit

/// What the engine needs from the app around it — the parts that are not the
/// text: tabs, files, the find bar, and the footer's message line.
protocol VimEngineHost: AnyObject {
    /// `gt` / `gT`, `:tabn` / `:tabp`, `:bn` / `:bp`.
    func vimSelectTab(offset: Int)
    /// A message for the middle of the footer.
    func vimShow(message: String)
    /// The `:` line as it is being typed, and `nil` when it closes. It shows
    /// where showcmd does, so the text view never gives up first responder.
    func vimCommandLineChanged(_ text: String?)
    /// `:w` with no name is ⌘S; a name is a save-as into the last-used
    /// folder. True when the note reached the disk, which is what `:wq`
    /// waits for before closing.
    func vimSave(name: String?) -> Bool
    /// `:q` and `:q!`. Without the bang a dirty tab prompts, exactly as ⌘W
    /// does — the window, not the engine, decides that.
    func vimClose(force: Bool)
    /// `:e path`.
    func vimOpen(path: String)
    /// `:tabnew`.
    func vimNewTab()
    /// `:help`, `:reg`, `:marks`: a read-only tab, reused when one of that
    /// name is already open.
    func vimOpenScratchTab(title: String, text: String)
    /// Takes the last message off the command pane. The next key does this,
    /// which is how long a message stays up.
    func vimClearMessage()
}

/// Vim's normal-mode state machine, driving a real `NSTextView`.
///
/// Every edit goes through `shouldChangeText` / `didChangeText` so the note's
/// own undo manager records it and the cache pipeline hears about it, and one
/// command is wrapped in one undo group — so `u` after `3dd` brings back all
/// three lines at once, the way it should.
final class VimEngine {

    // MARK: - Wiring

    private(set) weak var textView: NotaTextView?
    weak var host: VimEngineHost?

    var onModeChange: ((VimMode) -> Void)?
    var onPendingKeysChange: ((String) -> Void)?

    /// Off means the engine sees nothing: plain `NSTextView` behaviour.
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled {
                enterNormalMode()
            } else {
                visual = nil
                prompt = nil
                searchSession = nil
                host?.vimCommandLineChanged(nil)
                textView?.clearSearchHighlights()
                mode = .insert          // the caret goes back to a bar
                resetPending()
                applyCursorStyle()
            }
            // Vim's own half of the band goes when vim does and comes back
            // with it if it was on; the preference's half is untouched.
            textView?.vimCursorLine = isEnabled && cursorLine
        }
    }

    private(set) var mode: VimMode = .normal {
        didSet {
            guard mode != oldValue else { return }
            applyCursorStyle()
            onModeChange?(mode)
        }
    }

    let registers = VimRegisters()
    var marks = VimMarks()

    /// How far `>>`, `<<`, `⌃T` and `⌃D` shift. The vimrc can change it.
    var shiftWidth = 4

    /// `set cursorline`: the caret's line wears a quiet band. Off by default;
    /// the text view draws it. `:set nocursorline` only turns vim's own half
    /// off — the Settings preference, if it is on, keeps the band lit.
    var cursorLine = false {
        didSet {
            guard cursorLine != oldValue else { return }
            textView?.vimCursorLine = cursorLine
        }
    }

    /// False on a scratch tab — `:help`, `:reg`, `:marks`. Motions still
    /// work; anything that would change the text says so instead.
    var isModifiable = true

    /// The unnamed register. The general pasteboard in the app; the tests
    /// pass a private one so running them never disturbs a real clipboard.
    var pasteboard: NSPasteboard = .general

    init(textView: NotaTextView) {
        self.textView = textView
    }

    // MARK: - Pending state

    var pendingCount: Int?
    var pendingOperator: VimOperator?
    var operatorCount: Int?
    /// `"a` in front of a command.
    var pendingRegister: Character?
    /// `g` and `z` wait for a second key.
    var pendingPrefix: Character?
    /// `f`, `r`, `m`, `"`, `q`, `@`, `i`/`a` … all wait for a character.
    var awaitingCharacter: AwaitingCharacter?
    var lastFind: (character: Character, forward: Bool, till: Bool)?
    /// The column `j` and `k` aim for, kept across a run of them.
    var desiredColumn = 0

    /// The visual selection, when there is one. While it exists it — not the
    /// text view — says where the caret is.
    var visual: VisualState?
    /// What `gv` reselects.
    var lastVisual: VisualState?

    // MARK: - Command line and search

    /// The footer prompt being typed. `:` is the only one that opens today;
    /// the machinery is written in terms of the prompt's character so a `/`
    /// search prompt would be the same typing, history and footer slot.
    var prompt: VimPrompt?
    /// One history per prompt character, which is how vim keeps `:` and `/`
    /// apart.
    var promptHistories: [Character: [String]] = [:]
    /// Where the history walk has got to.
    var historyIndex: Int?
    /// What was typed before the history walk started, so ↓ can come back.
    var historyDraft: String?

    /// Which way `n` goes: `/` sets it forward, `?` backward.
    var searchIsForward = true
    /// The last thing `/`, `*`, `#` or `:s` looked for — what `n` repeats and
    /// what an empty `:s//new/` pattern falls back to.
    var lastSearchPattern: String?
    /// What a bare `:s` runs again.
    var lastSubstitution: VimSubstitution?
    /// What a search prompt has to put back if it is cancelled.
    var searchSession: VimSearchSession?

    /// `'hlsearch'`: every match of the current search wears a quiet band.
    /// On by default until the vimrc has a say.
    var hlsearch = true
    /// Whether the highlights are up. `:noh` puts them down without
    /// forgetting the pattern; the next search brings them back.
    var searchHighlightsVisible = false
    /// `'ignorecase'` and `'smartcase'`, both off, as vim ships them.
    var ignoreCase = false
    var smartCase = false

    /// True while the pane is holding a message, so the next key can take it
    /// away again.
    var isShowingMessage = false

    // MARK: - Recording state

    /// The keys of the command being typed, and which of them were counts —
    /// everything `.` needs to do it again, and `3.` needs to do it three
    /// times.
    var commandKeys: [VimKey] = []
    var countKeyIndices: Set<Int> = []
    var commandChangedText = false
    /// A change made from visual mode. `.` cannot replay one — the keys that
    /// made the selection have already been forgotten — so it is left alone.
    var commandWasVisual = false
    var lastChange: ChangeRecord?
    var insertSession: InsertSession?
    /// True while `.` is replaying, so a replay never records itself.
    var isReplaying = false

    /// `qa` … `q`.
    var recordingRegister: Character?
    var recordedKeys: [VimKey] = []
    var lastPlayedRegister: Character?
    /// Guards a macro that plays itself.
    var macroDepth = 0

    enum AwaitingCharacter: Equatable {
        case find(forward: Bool, till: Bool)
        case replaceCharacter
        case register
        case textObject(inner: Bool)
        case markSet
        case markJump(exact: Bool)
        case macroRecord
        case macroPlay
    }

    func resetPending() {
        pendingCount = nil
        pendingOperator = nil
        operatorCount = nil
        pendingRegister = nil
        pendingPrefix = nil
        awaitingCharacter = nil
        publishPendingKeys()
    }

    /// What the footer shows beside the badge — showcmd, and the macro being
    /// recorded, in the same quiet type as everything else down there.
    func publishPendingKeys() {
        // The `:` line borrows that same slot, and while it is up it owns it.
        guard prompt == nil else { return }
        var keys = ""
        if let operatorCount { keys += "\(operatorCount)" }
        if let pendingRegister { keys += "\"\(pendingRegister)" }
        if let pendingOperator { keys += pendingOperator.keys }
        if let pendingCount { keys += "\(pendingCount)" }
        if let pendingPrefix { keys.append(pendingPrefix) }
        switch awaitingCharacter {
        case .find(let forward, let till):
            keys.append(forward ? (till ? "t" : "f") : (till ? "T" : "F"))
        case .replaceCharacter: keys.append("r")
        case .register: keys.append("\"")
        case .textObject(let inner): keys.append(inner ? "i" : "a")
        case .markSet: keys.append("m")
        case .markJump(let exact): keys.append(exact ? "`" : "'")
        case .macroRecord: keys.append("q")
        case .macroPlay: keys.append("@")
        case nil: break
        }
        if let recordingRegister {
            if !keys.isEmpty { keys += " " }
            keys += "recording @\(recordingRegister)"
        }
        onPendingKeysChange?(keys)
    }

    // MARK: - Modes

    func enterNormalMode() {
        visual = nil
        resetPending()
        mode = .normal
        clampCaret()
        applyCursorStyle()
    }

    func enterInsertMode() {
        // Insert mode has no selection to extend, so anything that reaches it
        // from visual mode leaves visual mode properly on the way — marks and
        // all — rather than stranding a selection behind the caret.
        if visual != nil { finishVisual(caretAt: caret) }
        guard isModifiable else {
            refuseChange()
            return
        }
        resetPending()
        beginInsertSession()
        mode = .insert
    }

    /// The one way the mode is set from outside this file — visual mode
    /// lives in `VimVisual`, and `mode` stays `private(set)` so nothing else
    /// can reach in.
    func setMode(_ newMode: VimMode) { mode = newMode }

    private func applyCursorStyle() {
        textView?.vimCursorStyle = cursorStyle
    }

    var cursorStyle: VimCursorStyle {
        guard isEnabled else { return .bar }
        switch mode {
        case .insert: return .bar
        case .replace: return .halfBlock
        default: return .block
        }
    }

    // MARK: - Entry points

    /// `true` when the key was ours. ⌘ combinations never are, so every menu
    /// shortcut keeps working in every mode — bar the four cursor keys, which
    /// no menu has and which `handleCommandCursor` only borrows.
    func handle(_ event: NSEvent) -> Bool {
        guard isEnabled else { return false }
        if handleCommandCursor(event) { return true }
        guard let key = VimKey(event: event) else { return false }
        return handle(key)
    }

    /// ⌘←/→/↑/↓ in normal and visual mode.
    ///
    /// The Mac's own line and document keys, and they stay the Mac's:
    /// `NSTextView` does the moving, so they land exactly where they land in
    /// every other editor here. All vim adds is what it adds after a click —
    /// the caret pulled back off the end of the line, which normal mode never
    /// sits past, and the column the next `j` or `k` aims for. ⇧⌘ and the
    /// rest are left alone entirely.
    private func handleCommandCursor(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        guard flags.contains(.command),
              !flags.contains(.shift), !flags.contains(.control), !flags.contains(.option),
              mode == .normal || mode == .visual || mode == .visualLine,
              let textView
        else { return false }

        let command: Selector
        switch event.keyCode {
        case 123: command = #selector(NSTextView.moveToBeginningOfLine(_:))
        case 124: command = #selector(NSTextView.moveToEndOfLine(_:))
        case 125: command = #selector(NSTextView.moveToEndOfDocument(_:))
        case 126: command = #selector(NSTextView.moveToBeginningOfDocument(_:))
        default: return false
        }

        textView.doCommand(by: command)
        let landed = textView.selectedRange().location
        if visual != nil {
            // The head is vim's, not the text view's: it follows the caret
            // and the selection is drawn from it again.
            moveCaret(to: landed)
        } else {
            clampCaret()
            desiredColumn = VimMotions.column(text, at: caret)
        }
        return true
    }

    @discardableResult
    func handle(_ key: VimKey) -> Bool {
        guard isEnabled else { return false }
        // A message stays up until the next key, whatever that key turns out
        // to be — including one that puts a new message there.
        if isShowingMessage {
            isShowingMessage = false
            host?.vimClearMessage()
        }
        let wasRecording = recordingRegister
        let handled = dispatch(key)
        noteRecordedKey(key, wasRecording: wasRecording)
        return handled
    }

    /// The key without the macro recorder listening — what `.` and `@a` use
    /// to play keys back without writing them down again.
    @discardableResult
    func dispatch(_ key: VimKey) -> Bool {
        switch mode {
        case .insert:
            return handleInsert(key)
        case .replace:
            return handleReplace(key)
        case .commandLine:
            return handlePrompt(key)
        case .visual, .visualLine:
            commandKeys.append(key)
            return handleVisual(key)
        default:
            commandKeys.append(key)
            return handleNormal(key)
        }
    }

    // MARK: - Insert mode

    var isEscape: (VimKey) -> Bool {
        { key in
            key.base == .escape
                || (key.control && (key.character == "c" || key.character == "["))
        }
    }

    private func handleInsert(_ key: VimKey) -> Bool {
        if isEscape(key) {
            endInsertSession()
            // Vim steps the caret back off the character it just typed past.
            moveCaret(to: VimMotions.previousIndexOnLine(text, from: caret))
            enterNormalMode()
            return true
        }
        guard key.control else { return false }
        switch key.character {
        case "w": deleteWordBeforeCaret(); return true
        case "u": deleteToLineStart(); return true
        case "t": shiftCurrentLine(by: 1); return true
        case "d": shiftCurrentLine(by: -1); return true
        default: return false
        }
    }

    /// `R`: typing overwrites rather than inserts.
    private func handleReplace(_ key: VimKey) -> Bool {
        if isEscape(key) {
            moveCaret(to: VimMotions.previousIndexOnLine(text, from: caret))
            enterNormalMode()
            return true
        }
        guard let character = key.plainCharacter, !character.isNewline else { return false }
        let location = caret
        let end = VimMotions.lineEnd(text, at: location)
        let range = location < end
            ? NSRange(location: location, length: VimMotions.nextIndex(text, after: location) - location)
            : NSRange(location: location, length: 0)
        edit {
            replace(range: range, with: String(character))
        }
        return true
    }

    // MARK: - Normal mode

    func handleNormal(_ key: VimKey) -> Bool {
        if isEscape(key) {
            resetPending()
            discardCommandKeys()
            clampCaret()
            return true
        }

        // A character argument outranks everything else.
        if let awaiting = awaitingCharacter {
            return handleAwaited(awaiting, key)
        }

        if let prefix = pendingPrefix {
            pendingPrefix = nil
            return handlePrefixed(prefix, key)
        }

        // Counts: `0` is a motion until a count is already under way.
        if let digit = key.plainCharacter, digit.isNumber,
           !(digit == "0" && pendingCount == nil) {
            let value = Int(String(digit)) ?? 0
            pendingCount = (pendingCount ?? 0) * 10 + value
            countKeyIndices.insert(commandKeys.count - 1)
            publishPendingKeys()
            return true
        }

        if key.control {
            return handleControl(key)
        }
        guard let character = key.plainCharacter else {
            // Arrow keys move the way h/j/k/l do — and the Mac's own cursor
            // keys move the way they do in every other editor on the Mac:
            // ⌥ by word and paragraph, Home and End to the ends of the line,
            // the page keys as ⌃F and ⌃B. Vim's own motions do the moving,
            // so ⌥→ is `w` down to the last edge case, and an operator
            // waiting in front of it takes the same range `dw` would.
            switch key.base {
            case .left:
                applyMotion(key.option
                    ? VimMotions.wordBackward(text, from: caret, count: takeCount(), big: false)
                    : VimMotions.left(text, from: caret, count: takeCount()))
            case .right:
                applyMotion(key.option
                    ? VimMotions.wordForward(text, from: caret, count: takeCount(), big: false)
                    : VimMotions.right(text, from: caret, count: takeCount()))
            case .down:
                applyMotion(key.option
                    ? VimMotions.paragraphForward(text, from: caret, count: takeCount())
                    : VimMotions.down(text, from: caret, count: takeCount(), column: desiredColumn))
            case .up:
                applyMotion(key.option
                    ? VimMotions.paragraphBackward(text, from: caret, count: takeCount())
                    : VimMotions.up(text, from: caret, count: takeCount(), column: desiredColumn))
            case .home: applyMotion(VimMotions.startOfLine(text, from: caret))
            case .end: applyMotion(VimMotions.endOfLine(text, from: caret, count: takeCount()))
            case .pageDown: return handleControl(.char("f", control: true))
            case .pageUp: return handleControl(.char("b", control: true))
            case .enter: applyMotion(VimMotions.lineOffset(text, from: caret, lines: takeCount()))
            default: return true
            }
            finishCommand()
            return true
        }

        return handleCommand(character)
    }

    /// The second half of `fx`, `ra`, `"a`, `diw`, `ma`, `` `a ``, `qa`, `@a`.
    private func handleAwaited(_ awaiting: AwaitingCharacter, _ key: VimKey) -> Bool {
        awaitingCharacter = nil
        guard let character = key.plainCharacter else {
            resetPending()
            discardCommandKeys()
            return true
        }
        switch awaiting {
        case .find(let forward, let till):
            lastFind = (character, forward, till)
            applyMotion(
                VimMotions.find(
                    text, from: caret, count: takeCount(),
                    character: character, forward: forward, till: till
                )
            )
        case .replaceCharacter:
            if visual != nil {
                replaceVisual(with: character)
            } else {
                replaceCharacters(with: character, count: takeCount())
            }
        case .register:
            // The register waits for the command it belongs to, so nothing
            // finishes here.
            pendingRegister = character
            publishPendingKeys()
            return true
        case .textObject(let inner):
            applyTextObject(character, inner: inner)
        case .markSet:
            guard !VimMarks.automatic.contains(character) else { break }
            marks.set(character, to: caret)
        case .markJump(let exact):
            jumpToMark(character, exact: exact)
        case .macroRecord:
            startRecording(into: character)
        case .macroPlay:
            playMacro(register: character, count: takeCount())
        }
        finishCommand()
        return true
    }

    /// `g…` and `z…`.
    private func handlePrefixed(_ prefix: Character, _ key: VimKey) -> Bool {
        guard let character = key.plainCharacter else {
            resetPending()
            discardCommandKeys()
            return true
        }
        switch (prefix, character) {
        case ("g", "g"):
            applyMotion(VimMotions.line(text, number: pendingCount ?? 1))
        case ("g", "e"), ("g", "E"):
            applyMotion(
                VimMotions.wordEndBackward(
                    text, from: caret, count: takeCount(), big: character == "E"
                )
            )
        case ("g", "t"):
            host?.vimSelectTab(offset: takeCount())
        case ("g", "T"):
            host?.vimSelectTab(offset: -takeCount())
        case ("g", "v"):
            reselectLastVisual()
        case ("g", "~"), ("g", "u"), ("g", "U"):
            let op: VimOperator = character == "~" ? .toggleCase
                : (character == "u" ? .lowercase : .uppercase)
            if visual != nil {
                applyVisualOperator(op)
                return true
            }
            return beginOperator(op)
        case ("z", "z"): scrollCaretLine(to: .centre)
        case ("z", "t"): scrollCaretLine(to: .top)
        case ("z", "b"): scrollCaretLine(to: .bottom)
        default:
            break
        }
        finishCommand()
        return true
    }

    private func handleControl(_ key: VimKey) -> Bool {
        switch key.character {
        case "r": redo()
        case "d": scrollHalfPage(down: true)
        case "u": scrollHalfPage(down: false)
        case "f": scrollFullPage(down: true)
        case "b": scrollFullPage(down: false)
        case "e": scrollLines(1)
        case "y": scrollLines(-1)
        case "a": addToNumber(takeCount())
        case "x": addToNumber(-takeCount())
        default: break
        }
        finishCommand()
        return true
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func handleCommand(_ character: Character) -> Bool {
        // A doubled operator takes whole lines: `dd`, `>>`, `guu`, `g~~`.
        if let pending = pendingOperator, character == pending.doubledKey {
            let count = (operatorCount ?? 1) * (pendingCount ?? 1)
            applyOperator(pending, to: lineRange(from: caret, count: count), kind: .linewise)
            finishCommand()
            return true
        }

        switch character {
        // Motions
        case "h": applyMotion(VimMotions.left(text, from: caret, count: takeCount()))
        case "l", " ": applyMotion(VimMotions.right(text, from: caret, count: takeCount()))
        case "j": applyMotion(VimMotions.down(text, from: caret, count: takeCount(), column: desiredColumn))
        case "k": applyMotion(VimMotions.up(text, from: caret, count: takeCount(), column: desiredColumn))
        case "w": applyMotion(VimMotions.wordForward(text, from: caret, count: takeCount(), big: false))
        case "W": applyMotion(VimMotions.wordForward(text, from: caret, count: takeCount(), big: true))
        case "b": applyMotion(VimMotions.wordBackward(text, from: caret, count: takeCount(), big: false))
        case "B": applyMotion(VimMotions.wordBackward(text, from: caret, count: takeCount(), big: true))
        case "e": applyMotion(VimMotions.wordEnd(text, from: caret, count: takeCount(), big: false))
        case "E": applyMotion(VimMotions.wordEnd(text, from: caret, count: takeCount(), big: true))
        case "0": applyMotion(VimMotions.startOfLine(text, from: caret))
        case "^": applyMotion(VimMotions.firstNonBlank(text, from: caret))
        case "$": applyMotion(VimMotions.endOfLine(text, from: caret, count: takeCount()))
        case "G": applyMotion(VimMotions.line(text, number: pendingCount ?? VimMotions.lineCount(text)))
        case "{": applyMotion(VimMotions.paragraphBackward(text, from: caret, count: takeCount()))
        case "}": applyMotion(VimMotions.paragraphForward(text, from: caret, count: takeCount()))
        case "(": applyMotion(VimMotions.sentenceBackward(text, from: caret, count: takeCount()))
        case ")": applyMotion(VimMotions.sentenceForward(text, from: caret, count: takeCount()))
        case "%": applyMotion(VimMotions.matchingBracket(text, from: caret))
        case "|": applyMotion(VimMotions.column(text, from: caret, column: pendingCount ?? 1))
        case "_": applyMotion(VimMotions.lineOffset(text, from: caret, lines: takeCount() - 1))
        case "+": applyMotion(VimMotions.lineOffset(text, from: caret, lines: takeCount()))
        case "-": applyMotion(VimMotions.lineOffset(text, from: caret, lines: -takeCount()))
        case "H": applyMotion(screenLine(.top))
        case "M": applyMotion(screenLine(.centre))
        case "L": applyMotion(screenLine(.bottom))

        case "f", "F", "t", "T":
            awaitingCharacter = .find(
                forward: character == "f" || character == "t",
                till: character == "t" || character == "T"
            )
            publishPendingKeys()
            return true
        case ";", ",":
            guard let last = lastFind else { break }
            let reversed = character == ","
            applyMotion(
                VimMotions.find(
                    text, from: caret, count: takeCount(), character: last.character,
                    forward: reversed ? !last.forward : last.forward, till: last.till
                )
            )

        // Marks
        case "m":
            awaitingCharacter = .markSet
            publishPendingKeys()
            return true
        case "`", "'":
            awaitingCharacter = .markJump(exact: character == "`")
            publishPendingKeys()
            return true

        // Registers and macros
        case "\"":
            awaitingCharacter = .register
            publishPendingKeys()
            return true
        case "q":
            if recordingRegister != nil {
                stopRecording()
                break
            }
            awaitingCharacter = .macroRecord
            publishPendingKeys()
            return true
        case "@":
            awaitingCharacter = .macroPlay
            publishPendingKeys()
            return true

        // Prefixes and operators
        case "g", "z":
            pendingPrefix = character
            publishPendingKeys()
            return true
        case "d": return beginOperator(.delete)
        case "c": return beginOperator(.change)
        case "y": return beginOperator(.yank)
        case ">": return beginOperator(.indent)
        case "<": return beginOperator(.dedent)
        case "=": return beginOperator(.reindent)

        // `i` and `a` name a text object once an operator is waiting, and
        // enter insert mode when nothing is.
        case "i", "a":
            if pendingOperator != nil {
                awaitingCharacter = .textObject(inner: character == "i")
                publishPendingKeys()
                return true
            }
            enterInsert(at: character == "i"
                ? caret
                : VimMotions.nextIndexOnLine(text, from: caret))

        // Edits
        case "x": deleteCharacters(count: takeCount(), forward: true, register: pendingRegister)
        case "X": deleteCharacters(count: takeCount(), forward: false, register: pendingRegister)
        case "p": put(after: true, count: takeCount(), register: pendingRegister)
        case "P": put(after: false, count: takeCount(), register: pendingRegister)
        case "~": toggleCaseUnderCaret(count: takeCount())
        case "J": joinLines(count: max(2, pendingCount ?? 2))
        case "r":
            awaitingCharacter = .replaceCharacter
            publishPendingKeys()
            return true
        case "u": undo()
        case ".":
            // The count belongs to the repeat, not to the keys it replays.
            let count = pendingCount
            pendingCount = nil
            repeatLastChange(count: count)

        // The command line, and the searching the find bar does
        case ":":
            beginPrompt()
            return true
        case "/", "?": beginSearch(forward: character == "/")
        case "n": repeatSearch(reversed: false)
        case "N": repeatSearch(reversed: true)
        case "*", "#": searchWordUnderCaret(forward: character == "*")

        // Visual
        case "v": enterVisual(linewise: false)
        case "V": enterVisual(linewise: true)

        // Entering insert
        case "I": enterInsert(at: VimMotions.firstNonBlank(text, at: caret))
        case "A": enterInsert(at: VimMotions.lineEnd(text, at: caret))
        case "o": openLine(below: true)
        case "O": openLine(below: false)
        case "R":
            resetPending()
            mode = .replace
            return true

        default:
            break
        }
        finishCommand()
        return true
    }

    // MARK: - Operators

    func beginOperator(_ op: VimOperator) -> Bool {
        if pendingOperator != nil {
            // A second, different operator abandons the first.
            resetPending()
            discardCommandKeys()
            return true
        }
        pendingOperator = op
        operatorCount = pendingCount
        pendingCount = nil
        mode = .operatorPending
        publishPendingKeys()
        return true
    }

    /// Turns a motion into either a caret move or, with an operator waiting,
    /// the range that operator acts on.
    func applyMotion(_ result: VimMotionResult) {
        guard let pending = pendingOperator else {
            moveCaret(to: result.location, keepingColumn: result.keepsColumn)
            return
        }
        guard result.moved else {
            resetPending()
            discardCommandKeys()
            return
        }

        let start = min(caret, result.location)
        let end = max(caret, result.location)
        var range = NSRange(location: start, length: end - start)
        var kind = result.kind
        if kind == .inclusive {
            range.length = VimMotions.nextIndex(text, after: end) - start
        }
        if kind == .linewise || pending.isAlwaysLinewise {
            range = lineSpan(from: caret, to: result.location)
            kind = .linewise
        }
        applyOperator(pending, to: range, kind: kind)
    }

    /// The second half of `diw`, `ca(`, `>ip` — and of `viw`, where the
    /// object becomes the selection rather than an operator's range.
    private func applyTextObject(_ object: Character, inner: Bool) {
        guard let result = VimTextObject.range(
            text, at: caret, object: object, inner: inner, count: takeCount()
        ), result.range.length > 0 else {
            resetPending()
            discardCommandKeys()
            return
        }
        if visual != nil {
            let linewise = visual?.isLinewise == true || result.isLinewise
            visual = VisualState(
                anchor: result.range.location,
                head: max(result.range.location, NSMaxRange(result.range) - 1),
                isLinewise: linewise
            )
            setMode(linewise ? .visualLine : .visual)
            syncVisualSelection()
            return
        }
        guard let pending = pendingOperator else {
            resetPending()
            discardCommandKeys()
            return
        }
        var range = result.range
        var kind: VimMotionKind = result.isLinewise ? .linewise : .exclusive
        if pending.isAlwaysLinewise, !result.isLinewise {
            range = lineSpan(from: range.location, to: max(range.location, NSMaxRange(range) - 1))
            kind = .linewise
        }
        applyOperator(pending, to: range, kind: kind)
    }

    func applyOperator(_ op: VimOperator, to range: NSRange, kind: VimMotionKind) {
        // A yank changes nothing, so it is the one operator a scratch tab
        // still allows; the rest stop before the register is written.
        guard op == .yank || isModifiable else {
            refuseChange()
            return
        }
        let linewise = kind == .linewise
        let register = pendingRegister
        switch op {
        case .delete:
            yank(range: range, linewise: linewise, register: register, isDelete: true)
            let target = linewise ? linewiseDeletionRange(range) : range
            edit { replace(range: target, with: "") }
            moveCaret(to: linewise
                ? VimMotions.firstNonBlank(text, at: min(range.location, text.length))
                : range.location)
            clampCaret()
        case .change:
            yank(range: range, linewise: linewise, register: register, isDelete: true)
            if linewise {
                // `cc` keeps the line itself and puts you on it, empty.
                let trimmed = rangeWithoutTrailingNewline(range)
                edit { replace(range: trimmed, with: "") }
                moveCaret(to: trimmed.location)
            } else {
                edit { replace(range: range, with: "") }
                moveCaret(to: range.location)
            }
            enterInsertMode()
        case .yank:
            yank(range: range, linewise: linewise, register: register, isDelete: false)
            moveCaret(to: range.location)
        case .indent, .dedent:
            shiftLines(in: range, by: op == .indent ? 1 : -1)
        case .reindent:
            reindentLines(in: range)
        case .toggleCase, .lowercase, .uppercase:
            let target = linewise ? rangeWithoutTrailingNewline(range) : range
            transformCase(in: target, using: op)
            moveCaret(to: target.location)
        }
    }

    // MARK: - Counts and finishing

    func takeCount() -> Int {
        let count = max(1, (pendingCount ?? 1) * (operatorCount ?? 1))
        pendingCount = nil
        return count
    }

    func finishCommand() {
        pendingOperator = nil
        pendingCount = nil
        operatorCount = nil
        pendingPrefix = nil
        pendingRegister = nil
        if mode == .operatorPending { mode = .normal }
        if mode == .normal { clampCaret() }
        publishPendingKeys()
        concludeCommand()
    }

    // MARK: - The text

    var text: NSString { (textView?.string ?? "") as NSString }

    /// While a visual selection is up it is the selection's head, not the
    /// text view, that says where vim's caret is.
    var caret: Int {
        if let visual { return min(visual.head, text.length) }
        return textView?.selectedRange().location ?? 0
    }

    func moveCaret(to location: Int, keepingColumn: Bool = false) {
        guard let textView else { return }
        let clamped = min(max(0, location), text.length)
        if visual != nil {
            visual?.head = clamped
            syncVisualSelection()
        } else {
            textView.setSelectedRange(NSRange(location: clamped, length: 0))
        }
        if !keepingColumn { desiredColumn = VimMotions.column(text, at: clamped) }
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    /// Normal mode never lets the caret sit past the last character of a line.
    func clampCaret() {
        guard mode == .normal || mode == .operatorPending else { return }
        let location = caret
        let start = VimMotions.lineStart(text, at: location)
        let end = VimMotions.lineEnd(text, at: location)
        var target = min(location, end)
        if target == end, end > start {
            target = VimMotions.previousIndex(text, before: end)
        }
        if target != location {
            textView?.setSelectedRange(NSRange(location: target, length: 0))
        }
    }

    /// What a scratch tab says when something tries to change it. Vim's own
    /// words, since it is vim's own rule.
    static let notModifiableMessage = "E21: Cannot make changes, 'modifiable' is off"

    /// Everything the engine says goes through here, so the pane knows it is
    /// holding a message and the next key can take it away.
    func show(_ message: String) {
        isShowingMessage = true
        host?.vimShow(message: message)
    }

    /// Once per command, not once per edit inside it.
    func refuseChange() {
        show(Self.notModifiableMessage)
        resetPending()
        discardCommandKeys()
    }

    /// One undo group per command, so `u` after `3dd` restores all three.
    func edit(_ body: () -> Void) {
        guard isModifiable else {
            refuseChange()
            return
        }
        guard let textView else { return }
        textView.breakUndoCoalescing()
        let manager = textView.undoManager
        manager?.beginUndoGrouping()
        body()
        manager?.endUndoGrouping()
    }

    @discardableResult
    func replace(range: NSRange, with string: String) -> Bool {
        guard let textView, let storage = textView.textStorage else { return false }
        let clamped = NSRange(
            location: min(range.location, storage.length),
            length: min(range.length, max(0, storage.length - min(range.location, storage.length)))
        )
        guard textView.shouldChangeText(in: clamped, replacementString: string) else { return false }
        if string.isEmpty {
            storage.replaceCharacters(in: clamped, with: "")
        } else {
            storage.replaceCharacters(
                in: clamped,
                with: NSAttributedString(string: string, attributes: textView.typingAttributes)
            )
        }
        textView.didChangeText()
        marks.adjust(
            at: clamped.location, removed: clamped.length,
            inserted: (string as NSString).length
        )
        marks.set(".", to: clamped.location)
        commandChangedText = true
        return true
    }

    // MARK: - Line ranges

    /// `count` whole lines from the caret's, newline included.
    func lineRange(from location: Int, count: Int) -> NSRange {
        let start = VimMotions.lineStart(text, at: location)
        var end = start
        for _ in 0..<count {
            let lineEnd = VimMotions.lineEnd(text, at: end)
            end = lineEnd < text.length ? lineEnd + 1 : lineEnd
        }
        return NSRange(location: start, length: end - start)
    }

    /// Every line touched between two locations.
    func lineSpan(from: Int, to: Int) -> NSRange {
        let low = min(from, to)
        let high = max(from, to)
        let start = VimMotions.lineStart(text, at: low)
        let lineEnd = VimMotions.lineEnd(text, at: high)
        let end = lineEnd < text.length ? lineEnd + 1 : lineEnd
        return NSRange(location: start, length: end - start)
    }

    /// The last line has no newline of its own, so deleting it takes the one
    /// in front of it instead — otherwise `dd` would leave a blank line where
    /// the last line used to be.
    func linewiseDeletionRange(_ range: NSRange) -> NSRange {
        guard NSMaxRange(range) == text.length, range.location > 0,
              text.character(at: range.location - 1) == 0x0A
        else { return range }
        return NSRange(location: range.location - 1, length: range.length + 1)
    }

    func rangeWithoutTrailingNewline(_ range: NSRange) -> NSRange {
        var range = range
        while range.length > 0,
              text.character(at: range.location + range.length - 1) == 0x0A {
            range.length -= 1
        }
        return range
    }
}
