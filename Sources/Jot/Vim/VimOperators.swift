import AppKit

/// The edits themselves, and the handful of commands that need to know what
/// is on screen.
///
/// Yanks and deletes go out through the text view's own copy path and puts
/// come back through its paste path, which is what keeps inline images alive:
/// an image is one attachment character in the storage and one `jot://` token
/// on the pasteboard, and neither ever has to be understood here.
extension VimEngine {

    enum ScreenPosition { case top, centre, bottom }

    // MARK: - Yank and put

    /// Writes a range to the unnamed register — that is, the system
    /// pasteboard — without disturbing where the caret was.
    func yank(range: NSRange, linewise: Bool) {
        guard let textView, range.length > 0 else { return }
        let previous = textView.selectedRange()
        textView.setSelectedRange(range)

        let board = pasteboard
        board.clearContents()
        let types = textView.writablePasteboardTypes
        board.declareTypes(types, owner: nil)
        for type in types { _ = textView.writeSelection(to: board, type: type) }

        registers.noteUnnamedWrite(
            text: board.string(forType: .jotNote) ?? "", isLinewise: linewise
        )
        textView.setSelectedRange(previous)
    }

    /// `p` and `P`. Whether the register is linewise decides everything about
    /// where the text lands.
    func put(after: Bool, count: Int) {
        guard textView != nil else { return }
        let linewise = registers.isUnnamedLinewise(
            current: pasteboard.string(forType: .jotNote)
        )
        edit {
            if linewise {
                putLinewise(after: after, count: count)
            } else {
                putCharwise(after: after, count: count)
            }
        }
        clampCaret()
    }

    private func putCharwise(after: Bool, count: Int) {
        guard let textView else { return }
        if after {
            moveCaret(to: VimMotions.nextIndexOnLine(text, from: caret))
        }
        for _ in 0..<count { readPasteboard(into: textView) }
        // Vim leaves the caret on the last character it put down.
        moveCaret(to: VimMotions.previousIndexOnLine(text, from: caret))
    }

    private func putLinewise(after: Bool, count: Int) {
        guard let textView else { return }
        var insertion: Int
        if after {
            let end = VimMotions.lineEnd(text, at: caret)
            if end < text.length {
                insertion = end + 1
            } else {
                // Last line: it needs a newline of its own before anything
                // can go below it.
                replace(range: NSRange(location: text.length, length: 0), with: "\n")
                insertion = text.length
            }
        } else {
            insertion = VimMotions.lineStart(text, at: caret)
        }

        textView.setSelectedRange(NSRange(location: insertion, length: 0))
        for _ in 0..<count {
            let before = text.length
            readPasteboard(into: textView)
            guard text.length > before else { continue }
            // A register taken from the last line of a note has no newline of
            // its own; linewise means whole lines, so one is added.
            let end = textView.selectedRange().location
            if end > 0, text.character(at: end - 1) != 0x0A {
                replace(range: NSRange(location: end, length: 0), with: "\n")
                textView.setSelectedRange(NSRange(location: end + 1, length: 0))
            }
        }
        moveCaret(to: VimMotions.firstNonBlank(text, at: insertion))
    }

    /// The same route `paste(nil)` takes — preferred flavour first, so a
    /// Jot-to-Jot put relinks images rather than copying them.
    private func readPasteboard(into textView: JotTextView) {
        let available = pasteboard.types ?? []
        guard let type = textView.preferredPasteboardType(
            from: available, restrictedToTypesFrom: textView.readablePasteboardTypes
        ) else { return }
        _ = textView.readSelection(from: pasteboard, type: type)
    }

    // MARK: - Deleting characters

    /// `x` and `X`.
    func deleteCharacters(count: Int, forward: Bool) {
        let start = caret
        if forward {
            let lineEnd = VimMotions.lineEnd(text, at: start)
            var end = start
            for _ in 0..<count where end < lineEnd {
                end = VimMotions.nextIndex(text, after: end)
            }
            guard end > start else { return }
            let range = NSRange(location: start, length: end - start)
            yank(range: range, linewise: false)
            edit { replace(range: range, with: "") }
        } else {
            let lineStart = VimMotions.lineStart(text, at: start)
            var begin = start
            for _ in 0..<count where begin > lineStart {
                begin = VimMotions.previousIndex(text, before: begin)
            }
            guard begin < start else { return }
            let range = NSRange(location: begin, length: start - begin)
            yank(range: range, linewise: false)
            edit { replace(range: range, with: "") }
            moveCaret(to: begin)
        }
        clampCaret()
    }

    /// `r`: overwrite the character under the caret, count times.
    func replaceCharacters(with character: Character, count: Int) {
        let start = caret
        let lineEnd = VimMotions.lineEnd(text, at: start)
        var end = start
        for _ in 0..<count where end < lineEnd {
            end = VimMotions.nextIndex(text, after: end)
        }
        guard end > start else { return }
        let replacement = String(repeating: String(character), count: count)
        edit { replace(range: NSRange(location: start, length: end - start), with: replacement) }
        moveCaret(to: VimMotions.previousIndexOnLine(text, from: start + (replacement as NSString).length))
    }

    // MARK: - Insert entry

    func enterInsert(at location: Int) {
        moveCaret(to: location)
        enterInsertMode()
    }

    /// `o` and `O`.
    func openLine(below: Bool) {
        let insertion = below
            ? VimMotions.lineEnd(text, at: caret)
            : VimMotions.lineStart(text, at: caret)
        edit { replace(range: NSRange(location: insertion, length: 0), with: "\n") }
        moveCaret(to: below ? min(insertion + 1, text.length) : insertion)
        enterInsertMode()
    }

    // MARK: - Insert-mode helpers

    /// ⌃W.
    func deleteWordBeforeCaret() {
        let start = VimMotions.wordBackward(text, from: caret, count: 1, big: false).location
        guard start < caret else { return }
        let range = NSRange(location: start, length: caret - start)
        edit { replace(range: range, with: "") }
        moveCaret(to: start)
    }

    /// ⌃U.
    func deleteToLineStart() {
        let start = VimMotions.lineStart(text, at: caret)
        guard start < caret else { return }
        let range = NSRange(location: start, length: caret - start)
        edit { replace(range: range, with: "") }
        moveCaret(to: start)
    }

    /// ⌃T and ⌃D in insert mode; the same shifting `>>` and `<<` will use.
    func shiftCurrentLine(by direction: Int) {
        let column = VimMotions.column(text, at: caret)
        let start = VimMotions.lineStart(text, at: caret)
        let indent = currentIndentWidth(at: start)
        let target = max(0, indent + direction * shiftWidth)
        let existing = indentRange(at: start)

        edit {
            replace(range: existing, with: String(repeating: " ", count: target))
        }
        let newColumn = max(0, column + (target - existing.length))
        moveCaret(to: VimMotions.index(text, inLineAt: start, column: newColumn))
    }

    private func indentRange(at lineStart: Int) -> NSRange {
        let end = VimMotions.lineEnd(text, at: lineStart)
        var index = lineStart
        while index < end, VimMotions.isBlank(text.character(at: index)) { index += 1 }
        return NSRange(location: lineStart, length: index - lineStart)
    }

    private func currentIndentWidth(at lineStart: Int) -> Int {
        indentRange(at: lineStart).length
    }

    // MARK: - Undo

    func undo() {
        guard let manager = textView?.undoManager, manager.canUndo else { return }
        textView?.breakUndoCoalescing()
        manager.undo()
        clampCaret()
    }

    func redo() {
        guard let manager = textView?.undoManager, manager.canRedo else { return }
        textView?.breakUndoCoalescing()
        manager.redo()
        clampCaret()
    }

    // MARK: - Numbers

    private static let numberPattern = try? NSRegularExpression(pattern: "-?\\d+")

    /// ⌃A and ⌃X: the first number at or after the caret on this line.
    func addToNumber(_ delta: Int) {
        guard let regex = Self.numberPattern else { return }
        let start = VimMotions.lineStart(text, at: caret)
        let end = VimMotions.lineEnd(text, at: caret)
        let lineRange = NSRange(location: start, length: end - start)
        let line = text.substring(with: lineRange) as NSString

        let offset = caret - start
        let matches = regex.matches(
            in: line as String, range: NSRange(location: 0, length: line.length)
        )
        guard let match = matches.first(where: { NSMaxRange($0.range) > offset }) else { return }

        let value = Int(line.substring(with: match.range)) ?? 0
        let replacement = "\(value + delta)"
        let absolute = NSRange(location: start + match.range.location, length: match.range.length)
        edit { replace(range: absolute, with: replacement) }
        moveCaret(to: absolute.location + (replacement as NSString).length - 1)
    }

    // MARK: - Scrolling

    /// `H`, `M`, `L` — the first non-blank of the top, middle or bottom line
    /// on screen.
    func screenLine(_ position: ScreenPosition) -> VimMotionResult {
        guard let textView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let clip = textView.enclosingScrollView?.contentView
        else { return VimMotionResult(location: caret, kind: .linewise, moved: false) }

        let visible = textView.convert(clip.bounds, from: clip)
        let origin = textView.textContainerOrigin
        let y: CGFloat
        switch position {
        case .top: y = visible.minY + 1
        case .centre: y = visible.midY
        case .bottom: y = max(visible.minY, visible.maxY - 1)
        }
        let point = NSPoint(x: origin.x + 1, y: y - origin.y)
        let glyph = layoutManager.glyphIndex(for: point, in: container)
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        return VimMotionResult(
            location: VimMotions.firstNonBlank(text, at: character), kind: .linewise
        )
    }

    /// `zz`, `zt`, `zb`.
    func scrollCaretLine(to position: ScreenPosition) {
        guard let textView, let scrollView = textView.enclosingScrollView,
              let layoutManager = textView.layoutManager, let container = textView.textContainer
        else { return }

        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: caret, length: 0), actualCharacterRange: nil
        )
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        rect.origin.y += textView.textContainerOrigin.y

        let clip = scrollView.contentView
        let height = clip.bounds.height
        let y: CGFloat
        switch position {
        case .top: y = rect.minY
        case .centre: y = rect.midY - height / 2
        case .bottom: y = rect.maxY - height
        }
        scroll(to: y)
    }

    /// ⌃D / ⌃U and ⌃F / ⌃B: the view and the caret move together.
    func scrollHalfPage(down: Bool) {
        let lines = max(1, visibleLineCount / 2)
        scrollAndMove(lines: down ? lines : -lines)
    }

    func scrollFullPage(down: Bool) {
        let lines = max(1, visibleLineCount - 2)
        scrollAndMove(lines: down ? lines : -lines)
    }

    /// ⌃E / ⌃Y: the view moves, the caret only follows if it would be left
    /// off screen.
    func scrollLines(_ lines: Int) {
        guard let textView, let scrollView = textView.enclosingScrollView else { return }
        let clip = scrollView.contentView
        scroll(to: clip.bounds.minY + CGFloat(lines) * lineHeight)

        let visible = textView.convert(scrollView.contentView.bounds, from: scrollView.contentView)
        let caretRect = caretRectInView()
        if caretRect.maxY > visible.maxY {
            moveCaret(to: screenLine(.bottom).location)
        } else if caretRect.minY < visible.minY {
            moveCaret(to: screenLine(.top).location)
        }
    }

    private func scrollAndMove(lines: Int) {
        guard let textView, let scrollView = textView.enclosingScrollView else {
            moveByLines(lines)
            return
        }
        let clip = scrollView.contentView
        scroll(to: clip.bounds.minY + CGFloat(lines) * lineHeight)
        moveByLines(lines)
    }

    private func moveByLines(_ lines: Int) {
        let result = lines >= 0
            ? VimMotions.down(text, from: caret, count: lines, column: VimMotions.column(text, at: caret))
            : VimMotions.up(text, from: caret, count: -lines, column: VimMotions.column(text, at: caret))
        moveCaret(to: result.location, keepingColumn: true)
    }

    private func scroll(to y: CGFloat) {
        guard let textView, let scrollView = textView.enclosingScrollView else { return }
        let clip = scrollView.contentView
        let maximum = max(0, textView.bounds.height - clip.bounds.height)
        let clamped = max(0, min(y, maximum))
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clamped))
        scrollView.reflectScrolledClipView(clip)
    }

    private func caretRectInView() -> NSRect {
        guard let textView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else { return .zero }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: caret, length: 0), actualCharacterRange: nil
        )
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        rect.origin.y += textView.textContainerOrigin.y
        return rect
    }

    private var lineHeight: CGFloat {
        guard let textView, let layoutManager = textView.layoutManager else { return 16 }
        let font = textView.font ?? .systemFont(ofSize: 13)
        return max(1, layoutManager.defaultLineHeight(for: font))
    }

    private var visibleLineCount: Int {
        guard let clip = textView?.enclosingScrollView?.contentView else { return 10 }
        return max(1, Int(clip.bounds.height / lineHeight))
    }
}
