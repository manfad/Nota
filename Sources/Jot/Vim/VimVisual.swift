import AppKit

/// Visual mode: `v`, `V`, and the operators that act on what is selected.
///
/// The selection is the text view's own — `NSTextView`'s real selected range —
/// so it is drawn by AppKit in the system's selection colour and looks like
/// every other selection on the Mac. Vim's side of it is two offsets: the
/// anchor the selection was started from and the head the motions move, which
/// `o` swaps. While one is up the head, not the text view, is where vim's
/// caret is; everything else in the engine goes on asking `caret`.
extension VimEngine {

    struct VisualState: Equatable {
        var anchor: Int
        var head: Int
        var isLinewise: Bool
    }

    // MARK: - Entering and leaving

    func enterVisual(linewise: Bool) {
        let location = caret
        visual = VisualState(anchor: location, head: location, isLinewise: linewise)
        setMode(linewise ? .visualLine : .visual)
        syncVisualSelection()
    }

    /// `gv`: back to the last selection, wherever the caret has been since.
    func reselectLastVisual() {
        guard let last = lastVisual else { return }
        let length = text.length
        visual = VisualState(
            anchor: min(last.anchor, length), head: min(last.head, length),
            isLinewise: last.isLinewise
        )
        setMode(last.isLinewise ? .visualLine : .visual)
        syncVisualSelection()
    }

    /// Puts the marks vim leaves behind, drops the selection, and lands the
    /// caret where it asks — the start side of the selection for an operator,
    /// the head for a plain Escape.
    func finishVisual(caretAt location: Int) {
        guard let state = visual else { return }
        let span = visualRange()
        marks.set("<", to: span.range.location)
        marks.set(">", to: max(span.range.location, NSMaxRange(span.range) - 1))
        lastVisual = state
        commandWasVisual = true
        visual = nil
        setMode(.normal)
        moveCaret(to: location)
        clampCaret()
    }

    /// What the selection covers, and whether it is by whole lines.
    func visualRange() -> (range: NSRange, isLinewise: Bool) {
        guard let state = visual else {
            return (NSRange(location: caret, length: 0), false)
        }
        if state.isLinewise {
            return (lineSpan(from: state.anchor, to: state.head), true)
        }
        let low = min(state.anchor, state.head)
        let high = max(state.anchor, state.head)
        let end = VimMotions.nextIndex(text, after: high)
        return (NSRange(location: low, length: max(0, end - low)), false)
    }

    /// Pushes vim's two offsets onto the text view, so AppKit draws it.
    func syncVisualSelection() {
        guard let textView, visual != nil else { return }
        textView.setSelectedRange(visualRange().range)
    }

    // MARK: - Keys

    // swiftlint:disable:next cyclomatic_complexity
    func handleVisual(_ key: VimKey) -> Bool {
        if isEscape(key) {
            // Vim leaves the caret where the head was, not at the start.
            let head = caret
            resetPending()
            finishVisual(caretAt: head)
            discardCommandKeys()
            return true
        }

        // Character arguments and half-typed prefixes belong to normal mode's
        // machinery, which visual mode borrows wholesale.
        if awaitingCharacter != nil || pendingPrefix != nil {
            return handleNormal(key)
        }
        guard let character = key.plainCharacter else { return handleNormal(key) }
        if character.isNumber, !(character == "0" && pendingCount == nil) {
            return handleNormal(key)
        }

        switch character {
        case "v":
            if visual?.isLinewise == true {
                visual?.isLinewise = false
                setMode(.visual)
                syncVisualSelection()
            } else {
                finishVisual(caretAt: caret)
            }
        case "V":
            if visual?.isLinewise == false {
                visual?.isLinewise = true
                setMode(.visualLine)
                syncVisualSelection()
            } else {
                finishVisual(caretAt: caret)
            }
        case "o", "O":
            guard let state = visual else { break }
            visual = VisualState(
                anchor: state.head, head: state.anchor, isLinewise: state.isLinewise
            )
            syncVisualSelection()
            desiredColumn = VimMotions.column(text, at: caret)

        case "I", "A":
            // Nothing here is blockwise, so these are ordinary insert entries
            // — but the selection has to go before the caret moves for them.
            finishVisual(caretAt: caret)
            return handleNormal(key)

        case "i", "a":
            awaitingCharacter = .textObject(inner: character == "i")
            publishPendingKeys()
            return true
        case "\"":
            awaitingCharacter = .register
            publishPendingKeys()
            return true

        case "d", "x": applyVisualOperator(.delete)
        case "c", "s": applyVisualOperator(.change)
        case "y": applyVisualOperator(.yank)
        case ">": applyVisualOperator(.indent)
        case "<": applyVisualOperator(.dedent)
        case "=": applyVisualOperator(.reindent)
        case "~": applyVisualOperator(.toggleCase)
        case "u": applyVisualOperator(.lowercase)
        case "U": applyVisualOperator(.uppercase)
        case "Y":
            visual?.isLinewise = true
            applyVisualOperator(.yank)
        case "D", "X":
            visual?.isLinewise = true
            applyVisualOperator(.delete)
        case "C", "S", "R":
            visual?.isLinewise = true
            applyVisualOperator(.change)
        case "J": joinVisual()
        case "p", "P": putOverVisual()
        case "r":
            awaitingCharacter = .replaceCharacter
            publishPendingKeys()
            return true

        default:
            // Motions, `f`, `g…`, marks — all of them just move the head.
            return handleNormal(key)
        }
        finishCommand()
        return true
    }

    // MARK: - Operators on a selection

    /// A count typed in visual mode multiplies how far `>` and `<` shift, the
    /// way `3>` does in vim; everything else ignores it.
    func applyVisualOperator(_ op: VimOperator) {
        let span = visualRange()
        // Read before the selection goes: leaving visual mode moves the caret.
        let shifts = max(1, pendingCount ?? 1)
        finishVisual(caretAt: span.range.location)

        switch op {
        case .indent, .dedent:
            for _ in 0..<shifts {
                shiftLines(in: span.range, by: op == .indent ? 1 : -1)
            }
        case .toggleCase, .lowercase, .uppercase:
            let target = span.isLinewise ? rangeWithoutTrailingNewline(span.range) : span.range
            transformCase(in: target, using: op)
            moveCaret(to: target.location)
        default:
            applyOperator(op, to: span.range, kind: span.isLinewise ? .linewise : .exclusive)
        }
        finishCommand()
    }

    /// Visual `r`: every character in the selection becomes the same one,
    /// with the line breaks left where they are.
    func replaceVisual(with character: Character) {
        let span = visualRange()
        finishVisual(caretAt: span.range.location)
        guard span.range.length > 0 else { return }
        let replacement = String(text.substring(with: span.range).map {
            $0.isNewline ? $0 : character
        })
        edit { replace(range: span.range, with: replacement) }
        moveCaret(to: span.range.location)
        clampCaret()
    }

    /// Visual `J`: the selected lines become one.
    private func joinVisual() {
        let span = visualRange()
        let lines = max(
            2,
            VimMotions.lineNumber(text, at: max(span.range.location, NSMaxRange(span.range) - 1))
                - VimMotions.lineNumber(text, at: span.range.location) + 1
        )
        finishVisual(caretAt: span.range.location)
        joinLines(count: lines)
        finishCommand()
    }

    /// Visual `p`: the selection is replaced by the register.
    ///
    /// Vim would put the replaced text into the unnamed register on the way
    /// out. Here the unnamed register *is* the pasteboard being pasted from,
    /// so overwriting it would destroy the thing being put; the selection is
    /// dropped into the black hole instead.
    private func putOverVisual() {
        let span = visualRange()
        let register = pendingRegister
        finishVisual(caretAt: span.range.location)

        let target = span.isLinewise ? linewiseDeletionRange(span.range) : span.range
        edit { replace(range: target, with: "") }
        moveCaret(to: min(span.range.location, text.length))
        // The hole is where the text goes, so it is always a put *before*.
        put(after: false, count: 1, register: register)
        finishCommand()
    }
}
