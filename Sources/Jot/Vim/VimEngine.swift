import AppKit

/// What the engine needs from the app around it — the parts that are not the
/// text: tabs, and the footer's message line.
protocol VimEngineHost: AnyObject {
    /// `gt` / `gT`, and later `:tabn` / `:tabp`.
    func vimSelectTab(offset: Int)
    /// A message for the middle of the footer.
    func vimShow(message: String)
}

/// Vim's normal-mode state machine, driving a real `NSTextView`.
///
/// Every edit goes through `shouldChangeText` / `didChangeText` so the note's
/// own undo manager records it and the cache pipeline hears about it, and one
/// command is wrapped in one undo group — so `u` after `3dd` brings back all
/// three lines at once, the way it should.
final class VimEngine {

    // MARK: - Wiring

    private(set) weak var textView: JotTextView?
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
                mode = .insert          // the caret goes back to a bar
                resetPending()
                applyCursorStyle()
            }
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

    /// How far `>>`, `⌃T` and `⌃D` shift. The vimrc can change it.
    var shiftWidth = 4

    /// The unnamed register. The general pasteboard in the app; the tests
    /// pass a private one so running them never disturbs a real clipboard.
    var pasteboard: NSPasteboard = .general

    init(textView: JotTextView) {
        self.textView = textView
    }

    // MARK: - Pending state

    private var pendingCount: Int?
    private var pendingOperator: Character?
    private var operatorCount: Int?
    /// `g` and `z` wait for a second key.
    private var pendingPrefix: Character?
    /// `f`, `F`, `t`, `T` and `r` wait for a character.
    private var awaitingCharacter: AwaitingCharacter?
    private var lastFind: (character: Character, forward: Bool, till: Bool)?
    /// The column `j` and `k` aim for, kept across a run of them.
    private var desiredColumn = 0

    private enum AwaitingCharacter: Equatable {
        case find(forward: Bool, till: Bool)
        case replaceCharacter
    }

    private func resetPending() {
        pendingCount = nil
        pendingOperator = nil
        operatorCount = nil
        pendingPrefix = nil
        awaitingCharacter = nil
        publishPendingKeys()
    }

    /// What the footer shows beside the badge.
    private func publishPendingKeys() {
        var keys = ""
        if let operatorCount { keys += "\(operatorCount)" }
        if let pendingOperator { keys.append(pendingOperator) }
        if let pendingCount { keys += "\(pendingCount)" }
        if let pendingPrefix { keys.append(pendingPrefix) }
        switch awaitingCharacter {
        case .find(let forward, let till):
            keys.append(forward ? (till ? "t" : "f") : (till ? "T" : "F"))
        case .replaceCharacter:
            keys.append("r")
        case nil:
            break
        }
        onPendingKeysChange?(keys)
    }

    // MARK: - Modes

    func enterNormalMode() {
        resetPending()
        mode = .normal
        clampCaret()
        applyCursorStyle()
    }

    func enterInsertMode() {
        resetPending()
        mode = .insert
    }

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
    /// shortcut keeps working in every mode.
    func handle(_ event: NSEvent) -> Bool {
        guard isEnabled, let key = VimKey(event: event) else { return false }
        return handle(key)
    }

    @discardableResult
    func handle(_ key: VimKey) -> Bool {
        guard isEnabled else { return false }
        switch mode {
        case .insert:
            return handleInsert(key)
        case .replace:
            return handleReplace(key)
        default:
            return handleNormal(key)
        }
    }

    // MARK: - Insert mode

    private var isEscape: (VimKey) -> Bool {
        { key in
            key.base == .escape
                || (key.control && (key.character == "c" || key.character == "["))
        }
    }

    private func handleInsert(_ key: VimKey) -> Bool {
        if isEscape(key) {
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

    private func handleNormal(_ key: VimKey) -> Bool {
        if isEscape(key) {
            resetPending()
            clampCaret()
            return true
        }

        // A character argument outranks everything else.
        if let awaiting = awaitingCharacter {
            awaitingCharacter = nil
            guard let character = key.plainCharacter else {
                resetPending()
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
                replaceCharacters(with: character, count: takeCount())
            }
            finishCommand()
            return true
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
            publishPendingKeys()
            return true
        }

        if key.control {
            return handleControl(key)
        }
        guard let character = key.plainCharacter else {
            // Arrow keys move the way h/j/k/l do.
            switch key.base {
            case .left: applyMotion(VimMotions.left(text, from: caret, count: takeCount()))
            case .right: applyMotion(VimMotions.right(text, from: caret, count: takeCount()))
            case .down: applyMotion(VimMotions.down(text, from: caret, count: takeCount(), column: desiredColumn))
            case .up: applyMotion(VimMotions.up(text, from: caret, count: takeCount(), column: desiredColumn))
            case .enter: applyMotion(VimMotions.lineOffset(text, from: caret, lines: takeCount()))
            default: return true
            }
            finishCommand()
            return true
        }

        return handleCommand(character)
    }

    /// `g…` and `z…`.
    private func handlePrefixed(_ prefix: Character, _ key: VimKey) -> Bool {
        guard let character = key.plainCharacter else {
            resetPending()
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

        // Prefixes and operators
        case "g", "z":
            pendingPrefix = character
            publishPendingKeys()
            return true
        case "d", "c", "y":
            return beginOperator(character)

        // Edits
        case "x": deleteCharacters(count: takeCount(), forward: true)
        case "X": deleteCharacters(count: takeCount(), forward: false)
        case "p": put(after: true, count: takeCount())
        case "P": put(after: false, count: takeCount())
        case "r":
            awaitingCharacter = .replaceCharacter
            publishPendingKeys()
            return true
        case "u": undo()

        // Entering insert
        case "i": enterInsert(at: caret)
        case "a": enterInsert(at: VimMotions.nextIndexOnLine(text, from: caret))
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

    private func beginOperator(_ character: Character) -> Bool {
        if let pending = pendingOperator {
            // `dd`, `yy`, `cc` — the doubled form takes whole lines.
            if pending == character {
                let count = (operatorCount ?? 1) * (pendingCount ?? 1)
                applyOperator(pending, to: lineRange(from: caret, count: count), kind: .linewise)
                finishCommand()
                return true
            }
            resetPending()
            return true
        }
        pendingOperator = character
        operatorCount = pendingCount
        pendingCount = nil
        mode = .operatorPending
        publishPendingKeys()
        return true
    }

    /// Turns a motion into either a caret move or, with an operator waiting,
    /// the range that operator acts on.
    private func applyMotion(_ result: VimMotionResult) {
        guard let pending = pendingOperator else {
            moveCaret(to: result.location, keepingColumn: result.keepsColumn)
            return
        }
        guard result.moved else {
            resetPending()
            return
        }

        let start = min(caret, result.location)
        let end = max(caret, result.location)
        var range = NSRange(location: start, length: end - start)
        if result.kind == .inclusive {
            range.length = VimMotions.nextIndex(text, after: end) - start
        }
        if result.kind == .linewise {
            range = lineSpan(from: caret, to: result.location)
        }
        applyOperator(pending, to: range, kind: result.kind)
    }

    private func applyOperator(_ character: Character, to range: NSRange, kind: VimMotionKind) {
        let linewise = kind == .linewise
        switch character {
        case "d":
            yank(range: range, linewise: linewise)
            let target = linewise ? linewiseDeletionRange(range) : range
            edit { replace(range: target, with: "") }
            moveCaret(to: linewise
                ? VimMotions.firstNonBlank(text, at: min(range.location, text.length))
                : range.location)
            clampCaret()
        case "c":
            yank(range: range, linewise: linewise)
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
        case "y":
            yank(range: range, linewise: linewise)
            moveCaret(to: range.location)
        default:
            break
        }
    }

    // MARK: - Counts and finishing

    private func takeCount() -> Int {
        let count = max(1, (pendingCount ?? 1) * (operatorCount ?? 1))
        pendingCount = nil
        return count
    }

    private func finishCommand() {
        pendingOperator = nil
        pendingCount = nil
        operatorCount = nil
        pendingPrefix = nil
        if mode == .operatorPending { mode = .normal }
        if mode == .normal { clampCaret() }
        publishPendingKeys()
    }

    // MARK: - The text

    var text: NSString { (textView?.string ?? "") as NSString }

    var caret: Int { textView?.selectedRange().location ?? 0 }

    func moveCaret(to location: Int, keepingColumn: Bool = false) {
        guard let textView else { return }
        let clamped = min(max(0, location), text.length)
        textView.setSelectedRange(NSRange(location: clamped, length: 0))
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

    /// One undo group per command, so `u` after `3dd` restores all three.
    func edit(_ body: () -> Void) {
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
