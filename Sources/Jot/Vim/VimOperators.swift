import AppKit

/// Everything that takes a motion, a text object or a doubled key and then
/// acts on the range it names.
enum VimOperator: Equatable {
    case delete, change, yank
    case indent, dedent, reindent
    case toggleCase, lowercase, uppercase

    /// The key that doubles the operator into its whole-line form: `dd`,
    /// `>>`, `guu`, `g~~`.
    var doubledKey: Character {
        switch self {
        case .delete: "d"
        case .change: "c"
        case .yank: "y"
        case .indent: ">"
        case .dedent: "<"
        case .reindent: "="
        case .toggleCase: "~"
        case .lowercase: "u"
        case .uppercase: "U"
        }
    }

    /// What showcmd puts beside the badge while the operator waits.
    var keys: String {
        switch self {
        case .delete: "d"
        case .change: "c"
        case .yank: "y"
        case .indent: ">"
        case .dedent: "<"
        case .reindent: "="
        case .toggleCase: "g~"
        case .lowercase: "gu"
        case .uppercase: "gU"
        }
    }

    /// `>`, `<` and `=` take whole lines whatever motion named the range.
    var isAlwaysLinewise: Bool {
        self == .indent || self == .dedent || self == .reindent
    }
}

/// The edits themselves, and the handful of commands that need to know what
/// is on screen.
///
/// Yanks and deletes go out through the text view's own copy path and puts
/// come back through its paste path, which is what keeps inline images alive:
/// an image is one attachment character in the storage and one `jot://` token
/// on the pasteboard, and neither ever has to be understood here.
extension VimEngine {

    enum ScreenPosition { case top, centre, bottom }

    /// How case is bent: `g~`, `gu`, `gU` and their visual-mode twins.
    enum CaseChange { case toggle, lower, upper }

    // MARK: - Yank and put

    /// Writes a range to the unnamed register — that is, the system
    /// pasteboard — without disturbing where the caret was, and to whichever
    /// named register the command asked for.
    ///
    /// Vim fills the unnamed register even when a register was named, so the
    /// pasteboard is written either way; only the black hole `"_` stops it.
    func yank(
        range: NSRange, linewise: Bool, register: Character? = nil, isDelete: Bool = false
    ) {
        guard let textView, range.length > 0 else { return }
        guard register != VimRegisters.blackHole else { return }
        let previous = textView.selectedRange()
        textView.setSelectedRange(range)

        let board = pasteboard
        board.clearContents()
        let types = textView.writablePasteboardTypes
        board.declareTypes(types, owner: nil)
        for type in types { _ = textView.writeSelection(to: board, type: type) }

        let plain = board.string(forType: .jotNote) ?? text.substring(with: range)
        registers.noteUnnamedWrite(text: plain, isLinewise: linewise)

        let entry = VimRegisters.Entry(text: plain, isLinewise: linewise)
        let stored = VimRegisters.isPasteboard(register ?? " ") ? nil : register
        if isDelete {
            // A delete of less than a line is "small" and goes to `"-`;
            // anything bigger shifts the `"1`–`"9` ring along.
            registers.recordDelete(entry, register: stored, small: !linewise && !plain.contains("\n"))
        } else {
            registers.recordYank(entry, register: stored)
        }
        textView.setSelectedRange(previous)
    }

    /// `p` and `P`. Whether the register is linewise decides everything about
    /// where the text lands.
    ///
    /// With no register named — and with `"+` or `"*`, which are the same
    /// place — the text comes back through the text view's own paste path, so
    /// an image put from the pasteboard is still an image. A named register
    /// holds plain text and is inserted directly.
    func put(after: Bool, count: Int, register: Character? = nil) {
        guard textView != nil else { return }
        if let register, !VimRegisters.isPasteboard(register) {
            guard let entry = registers.read(register), !entry.text.isEmpty else { return }
            edit { putEntry(entry, after: after, count: count) }
            clampCaret()
            return
        }
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

    /// A named register's plain text, put the way its linewise flag asks.
    private func putEntry(_ entry: VimRegisters.Entry, after: Bool, count: Int) {
        let repeated = String(repeating: entry.text, count: max(1, count))
        if entry.isLinewise {
            var body = repeated
            if !body.hasSuffix("\n") { body += "\n" }
            var insertion: Int
            if after {
                let end = VimMotions.lineEnd(text, at: caret)
                if end < text.length {
                    insertion = end + 1
                } else {
                    replace(range: NSRange(location: text.length, length: 0), with: "\n")
                    insertion = text.length
                }
            } else {
                insertion = VimMotions.lineStart(text, at: caret)
            }
            replace(range: NSRange(location: insertion, length: 0), with: body)
            moveCaret(to: VimMotions.firstNonBlank(text, at: insertion))
        } else {
            let insertion = after
                ? VimMotions.nextIndexOnLine(text, from: caret)
                : caret
            replace(range: NSRange(location: insertion, length: 0), with: repeated)
            let end = insertion + (repeated as NSString).length
            moveCaret(to: VimMotions.previousIndexOnLine(text, from: end))
        }
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
    func deleteCharacters(count: Int, forward: Bool, register: Character? = nil) {
        let start = caret
        if forward {
            let lineEnd = VimMotions.lineEnd(text, at: start)
            var end = start
            for _ in 0..<count where end < lineEnd {
                end = VimMotions.nextIndex(text, after: end)
            }
            guard end > start else { return }
            let range = NSRange(location: start, length: end - start)
            yank(range: range, linewise: false, register: register, isDelete: true)
            edit { replace(range: range, with: "") }
        } else {
            let lineStart = VimMotions.lineStart(text, at: start)
            var begin = start
            for _ in 0..<count where begin > lineStart {
                begin = VimMotions.previousIndex(text, before: begin)
            }
            guard begin < start else { return }
            let range = NSRange(location: begin, length: start - begin)
            yank(range: range, linewise: false, register: register, isDelete: true)
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

    // MARK: - Indenting whole lines

    /// `>`, `<`, `>>`, `<<`. Vim indents by whole lines whatever the motion
    /// was, and leaves the caret on the first non-blank of the first one.
    func shiftLines(in range: NSRange, by direction: Int) {
        let span = lineSpan(from: range.location, to: max(range.location, NSMaxRange(range) - 1))
        edit {
            forEachLine(in: span) { start in
                let existing = indentRange(at: start)
                // A blank line has no indent to give or take.
                guard VimMotions.lineEnd(text, at: start) > start else { return }
                let target = max(0, existing.length + direction * shiftWidth)
                replace(range: existing, with: String(repeating: " ", count: target))
            }
        }
        moveCaret(to: VimMotions.firstNonBlank(text, at: span.location))
    }

    /// `=`, `==`.
    ///
    /// A note is prose, not code, so there is no language to indent by. What
    /// `=` does here is the one useful thing left: every line in the range
    /// takes the indent of the last non-blank line above the range, which is
    /// what "line this back up with what it belongs under" means in a plain
    /// text file. With nothing above it, the lines go to column zero.
    func reindentLines(in range: NSRange) {
        let span = lineSpan(from: range.location, to: max(range.location, NSMaxRange(range) - 1))
        let indent = indentWidthAboveLine(at: span.location)
        edit {
            forEachLine(in: span) { start in
                guard VimMotions.lineEnd(text, at: start) > start else { return }
                replace(range: indentRange(at: start), with: String(repeating: " ", count: indent))
            }
        }
        moveCaret(to: VimMotions.firstNonBlank(text, at: span.location))
    }

    /// The indent of the nearest non-blank line above one, or zero.
    private func indentWidthAboveLine(at location: Int) -> Int {
        var start = VimMotions.lineStart(text, at: location)
        while start > 0 {
            start = VimMotions.lineStart(text, at: start - 1)
            guard VimMotions.lineEnd(text, at: start) > start else { continue }
            return indentRange(at: start).length
        }
        return 0
    }

    /// Walks the line starts of a span from the bottom up, so replacing one
    /// line's indent never moves the next one out from under the walk.
    private func forEachLine(in span: NSRange, _ body: (Int) -> Void) {
        var starts: [Int] = []
        var index = VimMotions.lineStart(text, at: span.location)
        let limit = max(span.location, NSMaxRange(span) - 1)
        while index <= limit {
            starts.append(index)
            let end = VimMotions.lineEnd(text, at: index)
            guard end < text.length else { break }
            index = end + 1
        }
        for start in starts.reversed() { body(start) }
    }

    // MARK: - Case

    /// The body of `g~`, `gu`, `gU` and their visual forms.
    func transformCase(in range: NSRange, using op: VimOperator) {
        guard range.length > 0 else { return }
        let original = text.substring(with: range)
        let changed: String
        switch op {
        case .lowercase: changed = original.lowercased()
        case .uppercase: changed = original.uppercased()
        default:
            changed = String(original.map { character in
                character.isUppercase
                    ? Character(character.lowercased())
                    : (character.isLowercase ? Character(character.uppercased()) : character)
            })
        }
        guard changed != original else { return }
        edit { replace(range: range, with: changed) }
    }

    /// `~` on its own: flip the character under the caret and step over it.
    func toggleCaseUnderCaret(count: Int) {
        let start = caret
        let lineEnd = VimMotions.lineEnd(text, at: start)
        var end = start
        for _ in 0..<count where end < lineEnd {
            end = VimMotions.nextIndex(text, after: end)
        }
        guard end > start else { return }
        let range = NSRange(location: start, length: end - start)
        transformCase(in: range, using: .toggleCase)
        moveCaret(to: min(end, VimMotions.lineEnd(text, at: start)))
        clampCaret()
    }

    // MARK: - Joining

    /// `J`: `count` lines become one, with a single space where each break
    /// was — none at all when the next line starts with `)`, and none added
    /// when the line already ends in a space.
    func joinLines(count: Int) {
        let joins = max(1, count - 1)
        var caretAfter = caret
        edit {
            for _ in 0..<joins {
                let end = VimMotions.lineEnd(text, at: caretAfter)
                guard end < text.length else { break }
                var start = end
                while start > VimMotions.lineStart(text, at: end),
                      VimMotions.isBlank(text.character(at: start - 1)) {
                    start -= 1
                }
                var next = end + 1
                let nextEnd = VimMotions.lineEnd(text, at: next)
                while next < nextEnd, VimMotions.isBlank(text.character(at: next)) { next += 1 }

                let separator = (next < text.length && text.character(at: next) == 0x29)
                    || start == VimMotions.lineStart(text, at: end)
                    ? "" : " "
                replace(range: NSRange(location: start, length: next - start), with: separator)
                caretAfter = start + (separator as NSString).length - (separator.isEmpty ? 0 : 1)
                caretAfter = max(VimMotions.lineStart(text, at: start), caretAfter)
            }
        }
        moveCaret(to: caretAfter)
        clampCaret()
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
