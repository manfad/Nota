import Foundation

/// The ranges `iw`, `aw`, `ip`, `i"`, `a(`, `it` and the rest name.
///
/// Like the motions, everything here is a pure function of the text and a
/// location, so an operator and a visual selection ask the same question and
/// get the same answer — `daw` and `vawd` cannot drift apart.
///
/// Word and quote objects stay on their own line: a notes app is full of
/// prose where a run of blanks spans a line break, and letting `daw` reach
/// across one surprises far more often than it helps.
enum VimTextObject {

    struct Result: Equatable {
        var range: NSRange
        /// `ip` and `ap` take whole lines; nothing else does.
        var isLinewise = false
    }

    /// `inner` is the `i` of `iw`; `a` is the outer form.
    static func range(
        _ text: NSString, at location: Int, object: Character, inner: Bool, count: Int
    ) -> Result? {
        guard text.length > 0 else { return nil }
        let count = max(1, count)
        let location = min(max(0, location), max(0, text.length - 1))

        switch object {
        case "w": return word(text, at: location, big: false, inner: inner, count: count)
        case "W": return word(text, at: location, big: true, inner: inner, count: count)
        case "s": return sentence(text, at: location, inner: inner, count: count)
        case "p": return paragraph(text, at: location, inner: inner, count: count)
        case "\"", "'", "`":
            return quote(text, at: location, quote: object, inner: inner)
        case "(", ")", "b": return pair(text, at: location, open: 0x28, close: 0x29, inner: inner, count: count)
        case "[", "]": return pair(text, at: location, open: 0x5B, close: 0x5D, inner: inner, count: count)
        case "{", "}", "B": return pair(text, at: location, open: 0x7B, close: 0x7D, inner: inner, count: count)
        case "<", ">": return pair(text, at: location, open: 0x3C, close: 0x3E, inner: inner, count: count)
        case "t": return tag(text, at: location, inner: inner, count: count)
        default: return nil
        }
    }

    // MARK: - Words

    /// `W` knows only blanks and non-blanks, the way its motion does.
    private static func characterClass(
        _ text: NSString, at index: Int, big: Bool
    ) -> VimMotions.CharacterClass {
        let plain = VimMotions.characterClass(text, at: index)
        guard big, plain != .blank else { return plain }
        return .word
    }

    /// The run of one character class around an index, never leaving the line.
    private static func chunk(
        _ text: NSString, at index: Int, big: Bool, lineStart: Int, lineEnd: Int
    ) -> NSRange {
        let kind = characterClass(text, at: index, big: big)
        var start = index
        while start > lineStart {
            let previous = VimMotions.previousIndex(text, before: start)
            guard characterClass(text, at: previous, big: big) == kind else { break }
            start = previous
        }
        var end = VimMotions.nextIndex(text, after: index)
        while end < lineEnd, characterClass(text, at: end, big: big) == kind {
            end = VimMotions.nextIndex(text, after: end)
        }
        return NSRange(location: start, length: end - start)
    }

    private static func word(
        _ text: NSString, at location: Int, big: Bool, inner: Bool, count: Int
    ) -> Result? {
        let lineStart = VimMotions.lineStart(text, at: location)
        let lineEnd = VimMotions.lineEnd(text, at: location)
        guard lineEnd > lineStart else {
            // An empty line is a word of its own, and an empty one.
            return Result(range: NSRange(location: lineStart, length: 0))
        }
        let index = min(location, VimMotions.previousIndex(text, before: lineEnd))
        let first = chunk(text, at: index, big: big, lineStart: lineStart, lineEnd: lineEnd)
        var start = first.location
        var end = NSMaxRange(first)

        if inner {
            for _ in 1..<count {
                guard end < lineEnd else { break }
                end = NSMaxRange(chunk(text, at: end, big: big, lineStart: lineStart, lineEnd: lineEnd))
            }
            return Result(range: NSRange(location: start, length: end - start))
        }

        // `aw`: each repetition is a word and the blanks after it. Starting on
        // blanks instead takes the blanks and the word they lead to.
        var tookTrailing = false
        for step in 0..<count {
            if step > 0 {
                guard end < lineEnd else { break }
                end = NSMaxRange(chunk(text, at: end, big: big, lineStart: lineStart, lineEnd: lineEnd))
            }
            let startedOnBlank = step == 0
                && characterClass(text, at: index, big: big) == .blank
            if startedOnBlank {
                if end < lineEnd {
                    end = NSMaxRange(chunk(text, at: end, big: big, lineStart: lineStart, lineEnd: lineEnd))
                }
                tookTrailing = true
                continue
            }
            if end < lineEnd, characterClass(text, at: end, big: big) == .blank {
                end = NSMaxRange(chunk(text, at: end, big: big, lineStart: lineStart, lineEnd: lineEnd))
                tookTrailing = true
            } else {
                tookTrailing = false
            }
        }
        if !tookTrailing, start > lineStart {
            // Nothing to take after it — vim takes the white space in front.
            let previous = VimMotions.previousIndex(text, before: start)
            if characterClass(text, at: previous, big: big) == .blank {
                start = chunk(text, at: previous, big: big, lineStart: lineStart, lineEnd: lineEnd).location
            }
        }
        return Result(range: NSRange(location: start, length: end - start))
    }

    // MARK: - Sentences

    private static func sentence(
        _ text: NSString, at location: Int, inner: Bool, count: Int
    ) -> Result? {
        var start = 0
        var scan = 0
        while true {
            let next = VimMotions.sentenceForward(text, from: scan, count: 1).location
            guard next > scan, next <= location else { break }
            start = next
            scan = next
        }

        var end = location
        for _ in 0..<count {
            let next = VimMotions.sentenceForward(text, from: end, count: 1).location
            guard next > end else { end = text.length; break }
            end = next
        }
        if inner {
            // `is` stops at the full stop; `as` swallows the space after it.
            while end > start, VimMotions.isBlank(text.character(at: end - 1)) { end -= 1 }
        }
        guard end > start else { return nil }
        return Result(range: NSRange(location: start, length: end - start))
    }

    // MARK: - Paragraphs

    /// A paragraph is a run of blank lines or a run of non-blank ones; `ap`
    /// is one of each.
    private static func paragraph(
        _ text: NSString, at location: Int, inner: Bool, count: Int
    ) -> Result? {
        var start = VimMotions.lineStart(text, at: location)
        let blank = VimMotions.isBlankLine(text, at: start)
        while start > 0 {
            let previous = VimMotions.lineStart(text, at: start - 1)
            guard VimMotions.isBlankLine(text, at: previous) == blank else { break }
            start = previous
        }

        var end = runEnd(text, fromLineStart: start)
        var extended = true
        for _ in 1..<(inner ? count : count * 2) {
            guard end < text.length else { extended = false; break }
            end = runEnd(text, fromLineStart: end)
        }
        if !inner, !extended, start > 0 {
            // No blank lines below: `ap` takes the ones above instead.
            let previous = VimMotions.lineStart(text, at: start - 1)
            if VimMotions.isBlankLine(text, at: previous) != blank {
                var above = previous
                while above > 0 {
                    let step = VimMotions.lineStart(text, at: above - 1)
                    guard VimMotions.isBlankLine(text, at: step) != blank else { break }
                    above = step
                }
                start = above
            }
        }
        return Result(range: NSRange(location: start, length: end - start), isLinewise: true)
    }

    /// The end of the run of same-blankness lines starting at a line start,
    /// newline included.
    private static func runEnd(_ text: NSString, fromLineStart start: Int) -> Int {
        let blank = VimMotions.isBlankLine(text, at: start)
        var index = start
        while true {
            let lineEnd = VimMotions.lineEnd(text, at: index)
            let next = lineEnd < text.length ? lineEnd + 1 : lineEnd
            if next >= text.length { return next }
            if VimMotions.isBlankLine(text, at: next) != blank { return next }
            index = next
        }
    }

    // MARK: - Quotes

    private static func quote(
        _ text: NSString, at location: Int, quote character: Character, inner: Bool
    ) -> Result? {
        let lineStart = VimMotions.lineStart(text, at: location)
        let lineEnd = VimMotions.lineEnd(text, at: location)
        let target = String(character)

        var positions: [Int] = []
        var index = lineStart
        while index < lineEnd {
            let range = text.rangeOfComposedCharacterSequence(at: index)
            if text.substring(with: range) == target,
               !(index > lineStart && text.character(at: index - 1) == 0x5C) {
                positions.append(index)
            }
            index = NSMaxRange(range)
        }

        // Quotes pair off from the left, the way vim reads a line.
        var open: Int?
        var close: Int?
        var pairIndex = 0
        while pairIndex + 1 < positions.count {
            let first = positions[pairIndex]
            let second = positions[pairIndex + 1]
            if second >= location {
                open = first
                close = second
                break
            }
            pairIndex += 2
        }
        guard let open, let close else { return nil }

        if inner {
            let start = VimMotions.nextIndex(text, after: open)
            return Result(range: NSRange(location: start, length: max(0, close - start)))
        }
        var start = open
        var end = VimMotions.nextIndex(text, after: close)
        if end < lineEnd, VimMotions.isBlank(text.character(at: end)) {
            while end < lineEnd, VimMotions.isBlank(text.character(at: end)) { end += 1 }
        } else {
            while start > lineStart, VimMotions.isBlank(text.character(at: start - 1)) { start -= 1 }
        }
        return Result(range: NSRange(location: start, length: end - start))
    }

    // MARK: - Bracket pairs

    private static func pair(
        _ text: NSString, at location: Int, open: unichar, close: unichar,
        inner: Bool, count: Int
    ) -> Result? {
        var from = location
        var found: (open: Int, close: Int)?
        for _ in 0..<count {
            guard let openIndex = enclosingOpen(text, at: from, open: open, close: close),
                  let closeIndex = matchingClose(text, from: openIndex, open: open, close: close)
            else { return found.map { result($0, inner: inner, text: text) } }
            found = (openIndex, closeIndex)
            guard openIndex > 0 else { break }
            from = openIndex - 1
        }
        guard let found else { return nil }
        return result(found, inner: inner, text: text)
    }

    private static func result(
        _ pair: (open: Int, close: Int), inner: Bool, text: NSString
    ) -> Result {
        if inner {
            let start = VimMotions.nextIndex(text, after: pair.open)
            return Result(range: NSRange(location: start, length: max(0, pair.close - start)))
        }
        let end = VimMotions.nextIndex(text, after: pair.close)
        return Result(range: NSRange(location: pair.open, length: end - pair.open))
    }

    private static func enclosingOpen(
        _ text: NSString, at location: Int, open: unichar, close: unichar
    ) -> Int? {
        guard location < text.length else { return nil }
        if text.character(at: location) == open { return location }
        var depth = 0
        var index = location
        while index > 0 {
            index -= 1
            let unit = text.character(at: index)
            if unit == close {
                depth += 1
            } else if unit == open {
                if depth == 0 { return index }
                depth -= 1
            }
        }
        return nil
    }

    private static func matchingClose(
        _ text: NSString, from openIndex: Int, open: unichar, close: unichar
    ) -> Int? {
        var depth = 0
        var index = openIndex
        while index < text.length {
            let unit = text.character(at: index)
            if unit == open {
                depth += 1
            } else if unit == close {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    // MARK: - Tags

    private static let tagPattern = try? NSRegularExpression(
        pattern: "<(/?)([A-Za-z][-A-Za-z0-9_:.]*)(?:\\s[^>]*?)?(/?)>"
    )

    /// `it` / `at`, best effort: the note is plain text, so this is a scan for
    /// balanced `<tag>`…`</tag>` rather than anything that knows HTML.
    private static func tag(
        _ text: NSString, at location: Int, inner: Bool, count: Int
    ) -> Result? {
        guard let regex = tagPattern else { return nil }
        var stack: [(name: String, range: NSRange)] = []
        var enclosing: [(open: NSRange, close: NSRange)] = []

        regex.enumerateMatches(
            in: text as String, range: NSRange(location: 0, length: text.length)
        ) { match, _, _ in
            guard let match else { return }
            let isClosing = match.range(at: 1).length > 0
            let selfClosing = match.range(at: 3).length > 0
            let name = text.substring(with: match.range(at: 2))
            guard !selfClosing else { return }
            if isClosing {
                guard let top = stack.lastIndex(where: { $0.name == name }) else { return }
                let opening = stack[top]
                stack.removeSubrange(top...)
                if opening.range.location <= location, location < NSMaxRange(match.range) {
                    enclosing.append((opening.range, match.range))
                }
            } else {
                stack.append((name, match.range))
            }
        }

        guard !enclosing.isEmpty else { return nil }
        // Innermost first, so a count walks outwards.
        enclosing.sort { NSMaxRange($0.close) - $0.open.location < NSMaxRange($1.close) - $1.open.location }
        let chosen = enclosing[min(count - 1, enclosing.count - 1)]
        if inner {
            let start = NSMaxRange(chosen.open)
            return Result(range: NSRange(location: start, length: max(0, chosen.close.location - start)))
        }
        return Result(range: NSRange(
            location: chosen.open.location,
            length: NSMaxRange(chosen.close) - chosen.open.location
        ))
    }
}
