import AppKit

/// Running what the `:` line was parsed into.
///
/// Every command is one undo group, the same rule the normal-mode commands
/// keep: `u` after `:%s/a/b/g` puts the whole note back, not one word of it.
/// Anything that has to happen outside the text — saving, closing a tab,
/// opening the find bar — goes out through the host rather than being done
/// here, so the engine stays testable without a window.
extension VimEngine {

    // MARK: - Dispatch

    func execute(_ command: VimExCommand) {
        // A scratch tab refuses before anything is worked out, so the refusal
        // is said once rather than once per line — and no report follows it.
        guard isModifiable || !Self.changesText(command.name) else {
            host?.vimShow(message: Self.notModifiableMessage)
            return
        }

        switch command.name {
        case .goToLine: moveToRange(command.range)
        case .substitute: substitute(command)
        case .delete: deleteLines(command)
        case .yank: yankLines(command)
        case .join: joinRange(command)
        case .move: moveLines(command, copying: false)
        case .copy: moveLines(command, copying: true)
        case .sort: sortLines(command)
        case .shiftRight: shiftRange(command, by: 1)
        case .shiftLeft: shiftRange(command, by: -1)

        case .write:
            _ = host?.vimSave(name: fileName(command.argument))
        case .quit:
            host?.vimClose(force: command.bang)
        case .writeQuit, .exit:
            if host?.vimSave(name: fileName(command.argument)) == true {
                host?.vimClose(force: false)
            }
        case .edit:
            guard !command.argument.isEmpty else {
                host?.vimShow(message: "E32: No file name")
                return
            }
            host?.vimOpen(path: command.argument)

        case .noHighlight:
            host?.vimFind(.hide)
        case .tabNew:
            host?.vimNewTab()
        case .tabNext:
            host?.vimSelectTab(offset: count(command.argument) ?? 1)
        case .tabPrevious:
            host?.vimSelectTab(offset: -(count(command.argument) ?? 1))

        case .help:
            host?.vimOpenScratchTab(title: VimHelp.title, text: VimHelp.text)
        case .registers:
            host?.vimOpenScratchTab(
                title: VimScratch.registersTitle,
                text: VimScratch.registers(registers, unnamed: unnamedRegister)
            )
        case .marks:
            host?.vimOpenScratchTab(
                title: VimScratch.marksTitle, text: VimScratch.marks(marks, in: text)
            )
        case .set:
            setOption(command.argument)

        case .unknown(let typed):
            host?.vimShow(message: "Not an editor command: \(typed)")
        }
    }

    /// Which commands touch the note. `:y` and the rest only read it.
    private static func changesText(_ name: VimExName) -> Bool {
        switch name {
        case .substitute, .delete, .join, .move, .copy, .sort, .shiftRight, .shiftLeft:
            true
        default:
            false
        }
    }

    private func fileName(_ argument: String) -> String? {
        argument.isEmpty ? nil : argument
    }

    private func count(_ argument: String) -> Int? {
        Int(argument.trimmingCharacters(in: .whitespaces))
    }

    /// What `:reg` shows for `""` — the pasteboard, since that is what the
    /// unnamed register is here.
    private var unnamedRegister: VimRegisters.Entry? {
        let jot = pasteboard.string(forType: .jotNote)
        guard let text = jot ?? pasteboard.string(forType: .string) else { return nil }
        return VimRegisters.Entry(
            text: text, isLinewise: registers.isUnnamedLinewise(current: jot)
        )
    }

    // MARK: - Ranges

    /// A range's first and last line, 1-based and clamped to the note. No
    /// range at all means the line the caret is on.
    func exLines(_ range: VimExRange?) -> (first: Int, last: Int)? {
        guard let range else {
            let current = VimMotions.lineNumber(text, at: caret)
            return (current, current)
        }
        guard let start = exLine(range.start), let end = exLine(range.end) else {
            host?.vimShow(message: "Mark not set")
            return nil
        }
        let total = VimMotions.lineCount(text)
        return (
            min(max(1, min(start, end)), total),
            min(max(1, max(start, end)), total)
        )
    }

    /// One address as a line number, before any clamping — `nil` only when it
    /// names a mark that was never set.
    func exLine(_ address: VimExAddress) -> Int? {
        let base: Int
        switch address.base {
        case .current:
            base = VimMotions.lineNumber(text, at: caret)
        case .last:
            base = VimMotions.lineCount(text)
        case .line(let number):
            base = number
        case .mark(let name):
            guard let location = marks.location(name) else { return nil }
            base = VimMotions.lineNumber(text, at: min(max(0, location), text.length))
        }
        return base + address.offset
    }

    /// The characters of whole lines `first` through `last`, newline included
    /// except at the end of the note.
    func exSpan(_ lines: (first: Int, last: Int)) -> NSRange {
        lineSpan(
            from: VimMotions.startOfLine(text, number: lines.first),
            to: VimMotions.startOfLine(text, number: lines.last)
        )
    }

    /// `:15` — a range with nothing after it just moves the caret.
    private func moveToRange(_ range: VimExRange?) {
        guard let lines = exLines(range) else { return }
        moveCaret(to: VimMotions.firstNonBlank(
            text, at: VimMotions.startOfLine(text, number: lines.last)
        ))
    }

    // MARK: - :s

    private func substitute(_ command: VimExCommand) {
        guard let lines = exLines(command.range) else { return }

        var substitution: VimSubstitution
        if command.argument.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let previous = lastSubstitution else {
                host?.vimShow(message: "E33: No previous substitute regular expression")
                return
            }
            substitution = previous
        } else if let parsed = VimSubstitution.parse(command.argument) {
            substitution = parsed
        } else {
            host?.vimShow(message: "E488: Trailing characters")
            return
        }

        // An empty pattern is vim's "the last thing I searched for", which
        // here is whatever `/`, `*` or the previous `:s` put on the find
        // pasteboard.
        if substitution.pattern.isEmpty {
            guard let previous = lastSearchPattern ?? findPasteboard.string(forType: .string),
                  !previous.isEmpty
            else {
                host?.vimShow(message: "E35: No previous regular expression")
                return
            }
            substitution.pattern = previous
        }

        guard let regex = try? NSRegularExpression(
            pattern: substitution.pattern,
            options: substitution.ignoreCase ? [.caseInsensitive] : []
        ) else {
            host?.vimShow(message: "E486: Pattern not found: \(substitution.pattern)")
            return
        }

        lastSearchPattern = substitution.pattern
        lastSubstitution = substitution
        let template = Self.template(from: substitution.replacement)

        var edits: [(range: NSRange, replacement: String)] = []
        var changedLines = 0
        var lastChangedLine = lines.first
        for number in lines.first...lines.last {
            let start = VimMotions.startOfLine(text, number: number)
            let end = VimMotions.lineEnd(text, at: start)
            let lineRange = NSRange(location: start, length: end - start)
            let matches = regex.matches(in: text as String, range: lineRange)
            guard !matches.isEmpty else { continue }
            for match in (substitution.global ? matches : [matches[0]]) {
                edits.append((
                    match.range,
                    regex.replacementString(
                        for: match, in: text as String, offset: 0, template: template
                    )
                ))
            }
            changedLines += 1
            lastChangedLine = number
        }

        guard !edits.isEmpty else {
            host?.vimShow(message: "E486: Pattern not found: \(substitution.pattern)")
            return
        }

        // Back to front, so an edit never moves the range of the next one.
        edit {
            for change in edits.reversed() {
                replace(range: change.range, with: change.replacement)
            }
        }
        let landing = min(lastChangedLine, VimMotions.lineCount(text))
        moveCaret(to: VimMotions.firstNonBlank(
            text, at: VimMotions.startOfLine(text, number: landing)
        ))
        host?.vimShow(message: Self.substitutionReport(edits.count, lines: changedLines))
    }

    static func substitutionReport(_ count: Int, lines: Int) -> String {
        "\(count) substitution\(count == 1 ? "" : "s") on \(lines) line\(lines == 1 ? "" : "s")"
    }

    /// Vim's replacement syntax in `NSRegularExpression`'s terms: `&` and
    /// `\0`–`\9` are the match and its groups, `\r` is a line break, and a
    /// `$` is only ever a dollar sign.
    static func template(from replacement: String) -> String {
        var result = ""
        var escaped = false
        for character in replacement {
            if escaped {
                switch character {
                case "0"..."9": result += "$\(character)"
                case "n", "r": result += "\n"
                case "&": result += "&"
                case "\\": result += "\\\\"
                default: result.append(character)
                }
                escaped = false
                continue
            }
            switch character {
            case "\\": escaped = true
            case "&": result += "$0"
            case "$": result += "\\$"
            default: result.append(character)
            }
        }
        if escaped { result += "\\\\" }
        return result
    }

    // MARK: - :d and :y

    /// `:d`, `:d a`, `:d 3` — a register to put the lines in, a count of
    /// lines, or both.
    private func deleteLines(_ command: VimExCommand) {
        guard var lines = exLines(command.range) else { return }
        let arguments = Self.registerAndCount(command.argument)
        if let count = arguments.count {
            lines = (lines.last, min(lines.last + count - 1, VimMotions.lineCount(text)))
        }
        let previousRegister = pendingRegister
        pendingRegister = arguments.register
        applyOperator(.delete, to: exSpan(lines), kind: .linewise)
        pendingRegister = previousRegister
    }

    private func yankLines(_ command: VimExCommand) {
        guard var lines = exLines(command.range) else { return }
        let arguments = Self.registerAndCount(command.argument)
        if let count = arguments.count {
            lines = (lines.last, min(lines.last + count - 1, VimMotions.lineCount(text)))
        }
        // `:y` is the one operator that leaves the caret where it found it.
        let location = caret
        yank(range: exSpan(lines), linewise: true, register: arguments.register)
        moveCaret(to: location)
    }

    static func registerAndCount(_ argument: String) -> (register: Character?, count: Int?) {
        var register: Character?
        var count: Int?
        for token in argument.split(separator: " ") {
            if let number = Int(token) {
                count = number
            } else if token.count == 1, let character = token.first, character.isLetter {
                register = character
            }
        }
        return (register, count)
    }

    // MARK: - :j

    private func joinRange(_ command: VimExCommand) {
        guard let lines = exLines(command.range) else { return }
        // `:j` on one line joins it with the one below, exactly as `J` does.
        let count = max(2, lines.last - lines.first + 1)
        moveCaret(to: VimMotions.startOfLine(text, number: lines.first))
        joinLines(count: count)
    }

    // MARK: - :m and :t

    private func moveLines(_ command: VimExCommand, copying: Bool) {
        guard let lines = exLines(command.range) else { return }
        guard let address = VimEx.address(command.argument), let target = exLine(address) else {
            host?.vimShow(message: "E14: Invalid address")
            return
        }
        let total = VimMotions.lineCount(text)
        var destination = min(max(0, target), total)
        guard copying || !(destination >= lines.first && destination < lines.last) else {
            host?.vimShow(message: "E134: Cannot move a range of lines into itself")
            return
        }

        let span = exSpan(lines)
        var body = text.substring(with: span)
        if !body.hasSuffix("\n") { body += "\n" }

        edit {
            if !copying {
                replace(range: linewiseDeletionRange(span), with: "")
                // The lines the destination was counted against are gone, so
                // the line it names has moved.
                if destination > lines.last {
                    destination -= lines.last - lines.first + 1
                } else if destination >= lines.first {
                    destination = lines.first - 1
                }
                destination = min(destination, VimMotions.lineCount(text))
            }
            let insertion = insertLines(body, afterLine: destination)
            let moved = lines.last - lines.first
            moveCaret(to: VimMotions.firstNonBlank(
                text, at: VimMotions.startOfLine(
                    text, number: VimMotions.lineNumber(text, at: insertion) + moved
                )
            ))
        }
    }

    /// Whole lines below `destination` — line zero meaning above the first.
    /// Appending below the last line has to give that line a newline, and vim
    /// leaves the note ending without one, so the body's own is dropped.
    private func insertLines(_ body: String, afterLine destination: Int) -> Int {
        var body = body
        guard destination > 0 else {
            replace(range: NSRange(location: 0, length: 0), with: body)
            return 0
        }
        let lineStart = VimMotions.startOfLine(text, number: destination)
        let end = VimMotions.lineEnd(text, at: lineStart)
        guard end >= text.length else {
            replace(range: NSRange(location: end + 1, length: 0), with: body)
            return end + 1
        }
        if body.hasSuffix("\n") { body.removeLast() }
        replace(range: NSRange(location: end, length: 0), with: "\n" + body)
        return end + 1
    }

    // MARK: - :sort

    /// `:sort` with no range takes the whole note, the way vim does. `!`
    /// reverses, `i` ignores case, `n` sorts by the first number in the line,
    /// `u` drops duplicates.
    private func sortLines(_ command: VimExCommand) {
        guard let lines = exLines(command.range ?? .whole) else { return }
        let flags = command.argument
        let span = exSpan(lines)
        guard span.length > 0 else { return }

        let body = text.substring(with: span)
        let hadNewline = body.hasSuffix("\n")
        var rows = body.components(separatedBy: "\n")
        if hadNewline { rows.removeLast() }
        guard rows.count > 1 else { return }

        var sorted = VimSort.sort(
            rows,
            ignoringCase: flags.contains("i"),
            numeric: flags.contains("n"),
            unique: flags.contains("u")
        )
        if command.bang { sorted.reverse() }
        guard sorted != rows else { return }

        let replacement = sorted.joined(separator: "\n") + (hadNewline ? "\n" : "")
        edit { replace(range: span, with: replacement) }
        moveCaret(to: VimMotions.firstNonBlank(text, at: span.location))
    }

    // MARK: - :> and :<

    private func shiftRange(_ command: VimExCommand, by direction: Int) {
        guard var lines = exLines(command.range) else { return }
        if let count = count(command.argument) {
            lines = (lines.last, min(lines.last + count - 1, VimMotions.lineCount(text)))
        }
        // The span is measured again each time round: a shift moves every
        // character after the indent it added.
        for _ in 0..<max(1, command.repetitions) {
            shiftLines(in: exSpan(lines), by: direction)
        }
    }

    // MARK: - :set

    private func setOption(_ argument: String) {
        let option = argument.trimmingCharacters(in: .whitespaces)
        guard !option.isEmpty else {
            host?.vimShow(message: cursorLine ? "cursorline" : "nocursorline")
            return
        }
        switch option {
        case "cursorline", "cul":
            cursorLine = true
        case "nocursorline", "nocul":
            cursorLine = false
        case "cursorline!", "cul!", "invcursorline":
            cursorLine.toggle()
        case "cursorline?", "cul?":
            host?.vimShow(message: cursorLine ? "cursorline" : "nocursorline")
        default:
            host?.vimShow(message: "E518: Unknown option: \(option)")
        }
    }
}

// MARK: - Sorting

/// `:sort`'s comparisons, kept out of the engine so they can be tested on
/// their own.
enum VimSort {
    static func sort(
        _ rows: [String], ignoringCase: Bool, numeric: Bool, unique: Bool
    ) -> [String] {
        var sorted = rows.enumerated().sorted { left, right in
            let order = compare(
                left.element, right.element, ignoringCase: ignoringCase, numeric: numeric
            )
            // A stable sort: equal lines keep the order they were written in.
            return order == .orderedSame ? left.offset < right.offset : order == .orderedAscending
        }.map(\.element)

        guard unique else { return sorted }
        var seen: [String] = []
        sorted = sorted.filter { row in
            let key = ignoringCase ? row.lowercased() : row
            guard !seen.contains(key) else { return false }
            seen.append(key)
            return true
        }
        return sorted
    }

    private static func compare(
        _ left: String, _ right: String, ignoringCase: Bool, numeric: Bool
    ) -> ComparisonResult {
        if numeric {
            // Vim sorts the lines without a number first, in their own order.
            switch (number(in: left), number(in: right)) {
            case (nil, nil): return .orderedSame
            case (nil, _): return .orderedAscending
            case (_, nil): return .orderedDescending
            case (let first?, let second?):
                if first == second { return .orderedSame }
                return first < second ? .orderedAscending : .orderedDescending
            }
        }
        let first = ignoringCase ? left.lowercased() : left
        let second = ignoringCase ? right.lowercased() : right
        if first == second { return .orderedSame }
        return first < second ? .orderedAscending : .orderedDescending
    }

    /// The first number in a line, with a minus sign directly in front of it
    /// counting as part of it.
    static func number(in row: String) -> Int? {
        let characters = Array(row)
        var index = 0
        while index < characters.count {
            guard characters[index].isNumber else {
                index += 1
                continue
            }
            var start = index
            if start > 0, characters[start - 1] == "-" { start -= 1 }
            var digits = String(characters[start])
            var scan = start + 1
            while scan < characters.count, characters[scan].isNumber {
                digits.append(characters[scan])
                scan += 1
            }
            return Int(digits)
        }
        return nil
    }
}
