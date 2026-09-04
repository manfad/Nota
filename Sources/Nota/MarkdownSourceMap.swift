import Foundation

/// Where each rendered block came from in the note's own text.
///
/// Foundation's Markdown parser reports no source offsets at all, so the
/// mapping is made here. Blocks arrive in document order and each is found by
/// searching forward from the end of the one before it — never backwards, so a
/// word that appears twice always lands on the right one.
///
/// Markup is skipped rather than matched. A paragraph opening `**bold** start`
/// renders as `bold start`, which appears nowhere in the source, so the first
/// words are tried and then the first word alone. Blocks that render no words
/// of their own — a fence, a rule, an image with no alt text, a table — are
/// found by the punctuation that opens them instead.
///
/// It is a heuristic, and it is allowed to be: the worst a near miss costs is
/// a click landing a line or two off, never a wrong document.
struct MarkdownSourceMap {

    /// How a block is recognised in the source.
    enum Shape {
        /// Found by its words — headings, paragraphs, list items, quotes.
        case prose
        /// Found by its opening ``` or ~~~ line, and closed by the matching one.
        case codeFence
        /// Found by its `---`, `***` or `___` line.
        case thematicBreak
        /// Found by its `![` token, for an image with no alt text to search on.
        case image
        /// Found by its first row, and closed by the last one.
        case table
        /// Found by its opening `$$` line or its ```` ```math ```` fence, and
        /// closed by the matching one. A display formula renders no words of
        /// its own — it is one attachment — so its punctuation is all there is
        /// to find it by.
        case displayMath
    }

    /// The longest run of a block's text worth searching for whole. Beyond
    /// this the odds of an inline `*` or `[` breaking the match only grow.
    private static let needleLength = 24

    private let source: NSString
    /// Everything before here belongs to a block already.
    private var cursor = 0

    init(_ source: String) {
        self.source = source as NSString
    }

    /// The source a block came from, from the first character of its opening
    /// line to the last character of its closing one. Blocks have to be asked
    /// for in document order.
    mutating func next(text: String, shape: Shape) -> NSRange {
        guard source.length > 0 else { return NSRange(location: 0, length: 0) }
        let start = locate(text: text, shape: shape)
        let span = consume(from: start, text: text, shape: shape)
        cursor = max(cursor, span.resume)
        return NSRange(location: start, length: max(0, span.contentsEnd - start))
    }

    // MARK: - Finding the opening line

    private func locate(text: String, shape: Shape) -> Int {
        let from = firstNonBlankLine(at: cursor)
        guard from < source.length else { return max(0, source.length - 1) }

        switch shape {
        case .codeFence:
            return firstLine(from: from, where: Self.isFence) ?? from
        case .thematicBreak:
            return firstLine(from: from, where: Self.isThematicBreak) ?? from
        case .image:
            let token = source.range(
                of: "![", range: NSRange(location: from, length: source.length - from)
            )
            guard token.location != NSNotFound else { return from }
            return max(from, lineBounds(at: token.location).start)
        case .table:
            return firstLine(from: from) { $0.contains("|") } ?? from
        case .displayMath:
            return firstLine(from: from, where: Self.opensDisplayMath) ?? from
        case .prose:
            return locateProse(text: text, from: from) ?? from
        }
    }

    /// The words first, then the first word alone. A paragraph whose opening
    /// is emphasised or linked renders as text the source does not contain,
    /// and one bare word is usually enough to pick the right line out.
    private func locateProse(text: String, from: Int) -> Int? {
        let flattened = Self.flattened(text)
        guard !flattened.isEmpty else { return nil }
        let range = NSRange(location: from, length: source.length - from)

        var found = source.range(of: String(flattened.prefix(Self.needleLength)), range: range)
        if found.location == NSNotFound {
            let word = flattened.prefix { !$0.isWhitespace }
            guard !word.isEmpty else { return nil }
            found = source.range(of: String(word.prefix(Self.needleLength)), range: range)
        }
        guard found.location != NSNotFound else { return nil }
        return max(from, lineBounds(at: found.location).start)
    }

    // MARK: - Finding the closing line

    private func consume(
        from start: Int, text: String, shape: Shape
    ) -> (contentsEnd: Int, resume: Int) {
        switch shape {
        case .codeFence:
            return consumeFence(from: start)
        case .thematicBreak, .image:
            let line = lineBounds(at: start)
            return (line.contentsEnd, line.end)
        case .table:
            return consumeLines(from: start) { $0.contains("|") }
        case .displayMath:
            return consumeDisplayMath(from: start)
        case .prose:
            return consumeProse(from: start, text: text)
        }
    }

    /// A fenced block runs to its closing fence — which is also how the
    /// cursor gets past code that happens to read like the next block.
    private func consumeFence(from start: Int) -> (contentsEnd: Int, resume: Int) {
        let opening = lineBounds(at: start)
        let marker = Self.fenceMarker(of: content(of: opening))
        var index = opening.end
        while index < source.length {
            let line = lineBounds(at: index)
            let text = content(of: line)
            if Self.isFence(text), Self.fenceMarker(of: text) == marker {
                return (line.contentsEnd, line.end)
            }
            guard line.end > index else { break }
            index = line.end
        }
        // An unclosed fence swallows the rest of the note, exactly as the
        // parser reads it.
        return (source.length, source.length)
    }

    /// A ```` ```math ```` block closes the way any fence does. A `$$` block
    /// closes on its own line when it carries both delimiters, and otherwise
    /// on the next line that carries one.
    private func consumeDisplayMath(from start: Int) -> (contentsEnd: Int, resume: Int) {
        let opening = lineBounds(at: start)
        let text = content(of: opening)
        if Self.isFence(text) { return consumeFence(from: start) }
        if Self.displayDelimiters(in: text) >= 2 {
            return (opening.contentsEnd, opening.end)
        }
        var index = opening.end
        while index < source.length {
            let line = lineBounds(at: index)
            if Self.displayDelimiters(in: content(of: line)) >= 1 {
                return (line.contentsEnd, line.end)
            }
            guard line.end > index else { break }
            index = line.end
        }
        return (opening.contentsEnd, opening.end)
    }

    private func consumeLines(
        from start: Int, while predicate: (String) -> Bool
    ) -> (contentsEnd: Int, resume: Int) {
        var last = lineBounds(at: start)
        var index = last.end
        while index < source.length {
            let line = lineBounds(at: index)
            guard predicate(content(of: line)) else { break }
            last = line
            guard line.end > index else { break }
            index = line.end
        }
        return (last.contentsEnd, last.end)
    }

    /// Walks down the source line by line, spending the block's letters as it
    /// goes: a paragraph the writer hard-wrapped over four lines claims all
    /// four, and stops the moment a line no longer reads as more of it.
    private func consumeProse(
        from start: Int, text: String
    ) -> (contentsEnd: Int, resume: Int) {
        var remaining = Substring(Self.letters(text))
        var last = lineBounds(at: start)
        var index = start
        var isOpeningLine = true

        while index < source.length {
            let line = lineBounds(at: index)
            let text = content(of: line)
            if text.trimmingCharacters(in: .whitespaces).isEmpty { break }
            let lineLetters = Self.letters(text)

            if isOpeningLine {
                // The opening line is this block's whatever it looks like; its
                // own markup — a `#`, a `>`, a list number — is what the
                // leading letters have to be forgiven for.
                remaining = remaining.dropFirst(Self.spent(remaining, on: lineLetters))
            } else {
                guard !remaining.isEmpty else { break }
                let spent = Self.spent(remaining, on: lineLetters)
                if spent > 0 {
                    remaining = remaining.dropFirst(spent)
                } else if !lineLetters.isEmpty, lineLetters.hasPrefix(remaining) {
                    // The last line carries what is left of the block plus a
                    // link's address or some other markup of its own.
                    remaining = ""
                } else {
                    break
                }
            }

            last = line
            isOpeningLine = false
            guard line.end > index else { break }
            index = line.end
        }
        return (last.contentsEnd, last.end)
    }

    /// How many of the block's remaining letters a source line accounts for,
    /// allowing for the markup the line opens with.
    private static func spent(_ remaining: Substring, on lineLetters: String) -> Int {
        guard !lineLetters.isEmpty, !remaining.isEmpty else { return 0 }
        var dropped = 0
        while dropped < lineLetters.count {
            let tail = lineLetters.dropFirst(dropped)
            if remaining.hasPrefix(tail) { return tail.count }
            dropped += 1
        }
        return 0
    }

    // MARK: - Lines

    private func lineBounds(at index: Int) -> (start: Int, contentsEnd: Int, end: Int) {
        guard source.length > 0 else { return (0, 0, 0) }
        let probe = NSRange(location: min(max(0, index), source.length - 1), length: 0)
        var start = 0
        var end = 0
        var contentsEnd = 0
        source.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: probe)
        return (start, contentsEnd, end)
    }

    private func content(of line: (start: Int, contentsEnd: Int, end: Int)) -> String {
        source.substring(with: NSRange(
            location: line.start, length: max(0, line.contentsEnd - line.start)
        ))
    }

    private func firstNonBlankLine(at index: Int) -> Int {
        var cursor = min(max(0, index), source.length)
        while cursor < source.length {
            let line = lineBounds(at: cursor)
            if !content(of: line).trimmingCharacters(in: .whitespaces).isEmpty {
                return line.start
            }
            guard line.end > cursor else { break }
            cursor = line.end
        }
        return min(cursor, source.length)
    }

    private func firstLine(from index: Int, where predicate: (String) -> Bool) -> Int? {
        var cursor = index
        while cursor < source.length {
            let line = lineBounds(at: cursor)
            if predicate(content(of: line)) { return line.start }
            guard line.end > cursor else { break }
            cursor = line.end
        }
        return nil
    }

    // MARK: - Recognising markup

    /// Whether a line opens or closes a fenced code block — shared with
    /// `MarkdownHeadings`, which skips fences the same way.
    static func isFence(_ line: String) -> Bool {
        fenceMarker(of: line) != nil
    }

    static func fenceMarker(of line: String) -> Character? {
        let trimmed = line.drop { $0 == " " }
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        return trimmed.prefix { $0 == first }.count >= 3 ? first : nil
    }

    private static func opensDisplayMath(_ line: String) -> Bool {
        if line.drop(while: { $0 == " " }).hasPrefix("$$") { return true }
        return MarkdownMath.isFormulaFence(line)
    }

    private static func displayDelimiters(in line: String) -> Int {
        var count = 0
        var rest = Substring(line)
        while let found = rest.range(of: "$$") {
            count += 1
            rest = rest[found.upperBound...]
        }
        return count
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let trimmed = line.filter { !$0.isWhitespace }
        guard trimmed.count >= 3, let first = trimmed.first,
              first == "-" || first == "*" || first == "_"
        else { return false }
        return trimmed.allSatisfy { $0 == first }
    }

    /// The letters and digits of a piece of text, lowercased — everything the
    /// markup and the whitespace are stripped down to, so a rendered block and
    /// the source line it came from can be lined up character for character.
    private static func letters(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// A block's text on one line, for searching the source with.
    private static func flattened(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{FFFC}", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
