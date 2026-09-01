import Foundation

/// How the range between the caret and a motion's destination is taken when
/// an operator is waiting on it.
enum VimMotionKind {
    /// Up to but not including the destination — `w`, `0`, `{`.
    case exclusive
    /// Including the character landed on — `e`, `$`, `f`, `%`.
    case inclusive
    /// Whole lines — `j`, `k`, `gg`, `G`, `}` when it lands on a blank line.
    case linewise
}

struct VimMotionResult: Equatable {
    var location: Int
    var kind: VimMotionKind = .exclusive
    /// `j` and `k` keep the column they set out from, so a run down a ragged
    /// paragraph comes back to the same place.
    var keepsColumn = false
    /// A motion that could not move at all — `h` in the first column. Vim
    /// abandons a pending operator rather than acting on an empty range.
    var moved = true
}

/// Where the motions go.
///
/// Everything here is a pure function of the text and a location, which is
/// what makes them testable without a window — and everything works in
/// UTF-16 offsets over composed character sequences, so no motion can ever
/// land inside an emoji or between a letter and its accent.
enum VimMotions {

    // MARK: - Stepping

    static func nextIndex(_ text: NSString, after index: Int) -> Int {
        guard index < text.length else { return text.length }
        let range = text.rangeOfComposedCharacterSequence(at: index)
        return min(text.length, NSMaxRange(range))
    }

    static func previousIndex(_ text: NSString, before index: Int) -> Int {
        guard index > 0 else { return 0 }
        return text.rangeOfComposedCharacterSequence(at: index - 1).location
    }

    // MARK: - Lines

    static func lineStart(_ text: NSString, at location: Int) -> Int {
        var index = min(max(0, location), text.length)
        while index > 0, text.character(at: index - 1) != 0x0A { index -= 1 }
        return index
    }

    /// The newline that ends the line, or the end of the text.
    static func lineEnd(_ text: NSString, at location: Int) -> Int {
        var index = min(max(0, location), text.length)
        while index < text.length, text.character(at: index) != 0x0A { index += 1 }
        return index
    }

    static func isBlankLine(_ text: NSString, at location: Int) -> Bool {
        lineStart(text, at: location) == lineEnd(text, at: location)
    }

    static func firstNonBlank(_ text: NSString, at location: Int) -> Int {
        let start = lineStart(text, at: location)
        let end = lineEnd(text, at: location)
        var index = start
        while index < end, isBlank(text.character(at: index)) {
            index = nextIndex(text, after: index)
        }
        return index == end ? start : index
    }

    /// 1-based, the way the gutter and `:N` count.
    static func lineNumber(_ text: NSString, at location: Int) -> Int {
        let caret = min(max(0, location), text.length)
        var number = 1
        for index in 0..<caret where text.character(at: index) == 0x0A { number += 1 }
        return number
    }

    static func lineCount(_ text: NSString) -> Int {
        lineNumber(text, at: text.length)
    }

    /// Start of a 1-based line number, clamped to the text.
    static func startOfLine(_ text: NSString, number: Int) -> Int {
        guard number > 1 else { return 0 }
        var remaining = number - 1
        var index = 0
        while index < text.length {
            if text.character(at: index) == 0x0A {
                remaining -= 1
                if remaining == 0 { return index + 1 }
            }
            index += 1
        }
        return lineStart(text, at: text.length)
    }

    /// Column of a location within its line, counted in composed characters
    /// from zero.
    static func column(_ text: NSString, at location: Int) -> Int {
        let start = lineStart(text, at: location)
        var index = start
        var column = 0
        while index < location {
            index = nextIndex(text, after: index)
            column += 1
        }
        return column
    }

    /// The location `column` characters into the line holding `lineLocation`,
    /// never past the line's end.
    static func index(_ text: NSString, inLineAt lineLocation: Int, column: Int) -> Int {
        var index = lineStart(text, at: lineLocation)
        let end = lineEnd(text, at: lineLocation)
        var remaining = column
        while remaining > 0, index < end {
            index = nextIndex(text, after: index)
            remaining -= 1
        }
        return index
    }

    /// One character on from a location, never past the end of its line —
    /// what `a` and Escape use.
    static func nextIndexOnLine(_ text: NSString, from location: Int) -> Int {
        let end = lineEnd(text, at: location)
        return location < end ? nextIndex(text, after: location) : location
    }

    /// One character back, never past the start of its line.
    static func previousIndexOnLine(_ text: NSString, from location: Int) -> Int {
        let start = lineStart(text, at: location)
        return location > start ? previousIndex(text, before: location) : location
    }

    // MARK: - Character classes

    enum CharacterClass: Equatable { case blank, word, punctuation }

    static func isBlank(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
    }

    static func characterClass(_ text: NSString, at index: Int) -> CharacterClass {
        guard index >= 0, index < text.length else { return .blank }
        let unit = text.character(at: index)
        if isBlank(unit) { return .blank }
        let range = text.rangeOfComposedCharacterSequence(at: index)
        let piece = text.substring(with: range)
        guard let scalar = piece.unicodeScalars.first else { return .punctuation }
        if scalar == "_" || CharacterSet.alphanumerics.contains(scalar) { return .word }
        // An inline image is one glyph and reads as a word, so `dw` takes it.
        if scalar == "\u{FFFC}" { return .word }
        return .punctuation
    }

    /// `W`, `B` and `E` know only blanks and non-blanks.
    private static func characterClass(
        _ text: NSString, at index: Int, big: Bool
    ) -> CharacterClass {
        let plain = characterClass(text, at: index)
        guard big, plain != .blank else { return plain }
        return .word
    }

    // MARK: - Horizontal

    static func left(_ text: NSString, from location: Int, count: Int) -> VimMotionResult {
        let start = lineStart(text, at: location)
        var index = location
        for _ in 0..<count where index > start {
            index = previousIndex(text, before: index)
        }
        return VimMotionResult(location: index, kind: .exclusive, moved: index != location)
    }

    static func right(_ text: NSString, from location: Int, count: Int) -> VimMotionResult {
        let end = lineEnd(text, at: location)
        var index = location
        for _ in 0..<count where index < end {
            index = nextIndex(text, after: index)
        }
        return VimMotionResult(location: index, kind: .exclusive, moved: index != location)
    }

    // MARK: - Vertical

    static func down(
        _ text: NSString, from location: Int, count: Int, column desired: Int
    ) -> VimMotionResult {
        let number = lineNumber(text, at: location)
        let target = min(number + count, lineCount(text))
        let start = startOfLine(text, number: target)
        return VimMotionResult(
            location: index(text, inLineAt: start, column: desired),
            kind: .linewise, keepsColumn: true, moved: target != number
        )
    }

    static func up(
        _ text: NSString, from location: Int, count: Int, column desired: Int
    ) -> VimMotionResult {
        let number = lineNumber(text, at: location)
        let target = max(number - count, 1)
        let start = startOfLine(text, number: target)
        return VimMotionResult(
            location: index(text, inLineAt: start, column: desired),
            kind: .linewise, keepsColumn: true, moved: target != number
        )
    }

    /// `gg` and `G`: a line number when there is a count, otherwise the first
    /// or last line. The caret lands on the line's first non-blank.
    static func line(_ text: NSString, number: Int) -> VimMotionResult {
        let clamped = min(max(1, number), lineCount(text))
        let start = startOfLine(text, number: clamped)
        return VimMotionResult(location: firstNonBlank(text, at: start), kind: .linewise)
    }

    /// `+`, `-` and `_`: whole lines, landing on the first non-blank.
    static func lineOffset(
        _ text: NSString, from location: Int, lines: Int
    ) -> VimMotionResult {
        let number = lineNumber(text, at: location)
        let target = min(max(1, number + lines), lineCount(text))
        let start = startOfLine(text, number: target)
        return VimMotionResult(
            location: firstNonBlank(text, at: start), kind: .linewise, moved: target != number
        )
    }

    // MARK: - Line ends

    static func startOfLine(_ text: NSString, from location: Int) -> VimMotionResult {
        let start = lineStart(text, at: location)
        return VimMotionResult(location: start, kind: .exclusive, moved: start != location)
    }

    static func firstNonBlank(_ text: NSString, from location: Int) -> VimMotionResult {
        let target = firstNonBlank(text, at: location)
        return VimMotionResult(location: target, kind: .exclusive, moved: target != location)
    }

    /// `$`: the last character of the line, or of the count-1'th line below.
    static func endOfLine(
        _ text: NSString, from location: Int, count: Int
    ) -> VimMotionResult {
        let number = min(lineNumber(text, at: location) + count - 1, lineCount(text))
        let start = startOfLine(text, number: number)
        let end = lineEnd(text, at: start)
        // Inclusive, so the caret sits on the last character; an empty line
        // has nothing to sit on and keeps the caret where it is.
        let target = end > start ? previousIndex(text, before: end) : end
        return VimMotionResult(location: target, kind: .inclusive, moved: target != location)
    }

    /// `|`: a 1-based column on the current line.
    static func column(
        _ text: NSString, from location: Int, column number: Int
    ) -> VimMotionResult {
        let target = index(text, inLineAt: location, column: max(0, number - 1))
        return VimMotionResult(location: target, kind: .exclusive, moved: target != location)
    }

    // MARK: - Words

    /// `w` / `W`: the start of the next word.
    static func wordForward(
        _ text: NSString, from location: Int, count: Int, big: Bool
    ) -> VimMotionResult {
        var index = location
        for _ in 0..<count {
            index = nextWordStart(text, from: index, big: big)
        }
        return VimMotionResult(location: index, kind: .exclusive, moved: index != location)
    }

    private static func nextWordStart(_ text: NSString, from location: Int, big: Bool) -> Int {
        guard location < text.length else { return text.length }
        var index = location
        let startClass = characterClass(text, at: index, big: big)

        if startClass != .blank {
            while index < text.length,
                  characterClass(text, at: index, big: big) == startClass {
                index = nextIndex(text, after: index)
            }
        }
        // An empty line is a word of its own, which is what makes `dw` stop
        // at a paragraph break rather than swallowing it.
        while index < text.length, characterClass(text, at: index, big: big) == .blank {
            if text.character(at: index) == 0x0A, isBlankLine(text, at: index + 1),
               index + 1 <= text.length {
                return min(index + 1, text.length)
            }
            index = nextIndex(text, after: index)
        }
        return index
    }

    /// `b` / `B`: the start of the word before the caret.
    static func wordBackward(
        _ text: NSString, from location: Int, count: Int, big: Bool
    ) -> VimMotionResult {
        var index = location
        for _ in 0..<count {
            index = previousWordStart(text, from: index, big: big)
        }
        return VimMotionResult(location: index, kind: .exclusive, moved: index != location)
    }

    private static func previousWordStart(
        _ text: NSString, from location: Int, big: Bool
    ) -> Int {
        guard location > 0 else { return 0 }
        var index = previousIndex(text, before: location)

        while index > 0, characterClass(text, at: index, big: big) == .blank {
            if text.character(at: index) == 0x0A, isBlankLine(text, at: index) { return index }
            index = previousIndex(text, before: index)
        }
        guard index > 0 else { return index }

        let runClass = characterClass(text, at: index, big: big)
        while index > 0 {
            let previous = previousIndex(text, before: index)
            guard characterClass(text, at: previous, big: big) == runClass else { break }
            index = previous
        }
        return index
    }

    /// `e` / `E`: the last character of this word, or of the next one.
    static func wordEnd(
        _ text: NSString, from location: Int, count: Int, big: Bool
    ) -> VimMotionResult {
        var index = location
        for _ in 0..<count {
            index = nextWordEnd(text, from: index, big: big)
        }
        return VimMotionResult(location: index, kind: .inclusive, moved: index != location)
    }

    private static func nextWordEnd(_ text: NSString, from location: Int, big: Bool) -> Int {
        guard location < text.length else { return location }
        var index = nextIndex(text, after: location)
        while index < text.length, characterClass(text, at: index, big: big) == .blank {
            index = nextIndex(text, after: index)
        }
        guard index < text.length else { return previousIndex(text, before: text.length) }

        let runClass = characterClass(text, at: index, big: big)
        while index < text.length {
            let next = nextIndex(text, after: index)
            guard next < text.length,
                  characterClass(text, at: next, big: big) == runClass else { break }
            index = next
        }
        return index
    }

    /// `ge` / `gE`: the last character of the previous word.
    static func wordEndBackward(
        _ text: NSString, from location: Int, count: Int, big: Bool
    ) -> VimMotionResult {
        var index = location
        for _ in 0..<count {
            index = previousWordEnd(text, from: index, big: big)
        }
        return VimMotionResult(location: index, kind: .inclusive, moved: index != location)
    }

    private static func previousWordEnd(
        _ text: NSString, from location: Int, big: Bool
    ) -> Int {
        guard location > 0 else { return 0 }
        var index = previousIndex(text, before: location)
        let startClass = characterClass(text, at: location, big: big)

        // Step off the word the caret is standing in.
        if startClass != .blank {
            while index > 0, characterClass(text, at: index, big: big) == startClass {
                index = previousIndex(text, before: index)
            }
        }
        while index > 0, characterClass(text, at: index, big: big) == .blank {
            index = previousIndex(text, before: index)
        }
        return index
    }

    // MARK: - Paragraphs and sentences

    /// `}`: the next blank line, or the end of the text.
    static func paragraphForward(
        _ text: NSString, from location: Int, count: Int
    ) -> VimMotionResult {
        var index = location
        for _ in 0..<count {
            index = nextParagraphBreak(text, from: index)
        }
        return VimMotionResult(location: index, kind: .exclusive, moved: index != location)
    }

    private static func nextParagraphBreak(_ text: NSString, from location: Int) -> Int {
        var index = lineEnd(text, at: location)
        while index < text.length {
            index += 1                                    // step over the newline
            if isBlankLine(text, at: index), index != location { return index }
            index = lineEnd(text, at: index)
        }
        return text.length
    }

    /// `{`: the previous blank line, or the start of the text.
    static func paragraphBackward(
        _ text: NSString, from location: Int, count: Int
    ) -> VimMotionResult {
        var index = location
        for _ in 0..<count {
            index = previousParagraphBreak(text, from: index)
        }
        return VimMotionResult(location: index, kind: .exclusive, moved: index != location)
    }

    private static func previousParagraphBreak(_ text: NSString, from location: Int) -> Int {
        var index = lineStart(text, at: location)
        while index > 0 {
            index = lineStart(text, at: index - 1)
            if isBlankLine(text, at: index), index != location { return index }
        }
        return 0
    }

    /// `)`: the start of the next sentence — after `.`, `!` or `?` and the
    /// space that follows, with a blank line counting as a break.
    static func sentenceForward(
        _ text: NSString, from location: Int, count: Int
    ) -> VimMotionResult {
        var index = location
        for _ in 0..<count {
            index = nextSentenceStart(text, from: index)
        }
        return VimMotionResult(location: index, kind: .exclusive, moved: index != location)
    }

    private static func nextSentenceStart(_ text: NSString, from location: Int) -> Int {
        var index = location
        while index < text.length {
            let unit = text.character(at: index)
            if unit == 0x0A, isBlankLine(text, at: index + 1) { return min(index + 1, text.length) }
            if isSentenceEnd(text, at: index) {
                var after = nextIndex(text, after: index)
                while after < text.length, isClosing(text.character(at: after)) {
                    after = nextIndex(text, after: after)
                }
                guard after < text.length, isBlank(text.character(at: after)) else {
                    index = nextIndex(text, after: index)
                    continue
                }
                while after < text.length, isBlank(text.character(at: after)) {
                    after = nextIndex(text, after: after)
                }
                if after > location { return after }
            }
            index = nextIndex(text, after: index)
        }
        return text.length
    }

    /// `(`: the start of the sentence the caret is in, or of the one before.
    static func sentenceBackward(
        _ text: NSString, from location: Int, count: Int
    ) -> VimMotionResult {
        var index = location
        for _ in 0..<count {
            index = previousSentenceStart(text, from: index)
        }
        return VimMotionResult(location: index, kind: .exclusive, moved: index != location)
    }

    private static func previousSentenceStart(_ text: NSString, from location: Int) -> Int {
        var starts: [Int] = [0]
        var index = 0
        while index < location {
            let next = nextSentenceStart(text, from: index)
            if next >= location || next <= index { break }
            starts.append(next)
            index = next
        }
        return starts.last ?? 0
    }

    private static func isSentenceEnd(_ text: NSString, at index: Int) -> Bool {
        let unit = text.character(at: index)
        return unit == 0x2E || unit == 0x21 || unit == 0x3F   // . ! ?
    }

    private static func isClosing(_ unit: unichar) -> Bool {
        unit == 0x29 || unit == 0x5D || unit == 0x22 || unit == 0x27   // ) ] " '
    }

    // MARK: - Finding a character on the line

    /// `f`, `F`, `t`, `T`. Never leaves the line, and fails rather than
    /// settling for a near miss — which is what stops `dfx` deleting to the
    /// end of the line when there is no `x`.
    static func find(
        _ text: NSString, from location: Int, count: Int,
        character target: Character, forward: Bool, till: Bool
    ) -> VimMotionResult {
        let start = lineStart(text, at: location)
        let end = lineEnd(text, at: location)
        let targetString = String(target)
        var index = location
        var found = location

        for step in 0..<count {
            if forward {
                // `t` starts from just after the caret so `;` can carry on.
                var scan = nextIndex(text, after: index)
                if till, step == 0, scan < end,
                   text.substring(with: text.rangeOfComposedCharacterSequence(at: scan))
                       == targetString {
                    scan = nextIndex(text, after: scan)
                }
                var hit: Int?
                while scan < end {
                    let range = text.rangeOfComposedCharacterSequence(at: scan)
                    if text.substring(with: range) == targetString { hit = scan; break }
                    scan = NSMaxRange(range)
                }
                guard let hit else {
                    return VimMotionResult(location: location, kind: .inclusive, moved: false)
                }
                index = hit
                found = hit
            } else {
                var scan = index
                var hit: Int?
                while scan > start {
                    scan = previousIndex(text, before: scan)
                    let range = text.rangeOfComposedCharacterSequence(at: scan)
                    if text.substring(with: range) == targetString { hit = scan; break }
                }
                guard let hit else {
                    return VimMotionResult(location: location, kind: .exclusive, moved: false)
                }
                index = hit
                found = hit
            }
        }

        if till {
            found = forward
                ? previousIndex(text, before: found)
                : nextIndex(text, after: found)
        }
        // Forward finds take the character landed on; backward ones stop
        // short of where they came from.
        return VimMotionResult(
            location: found, kind: forward ? .inclusive : .exclusive, moved: found != location
        )
    }

    // MARK: - Matching bracket

    private static let pairs: [(open: unichar, close: unichar)] = [
        (0x28, 0x29),   // ( )
        (0x5B, 0x5D),   // [ ]
        (0x7B, 0x7D),   // { }
    ]

    /// `%`: from the first bracket at or after the caret on this line, to its
    /// partner, counting nesting on the way.
    static func matchingBracket(_ text: NSString, from location: Int) -> VimMotionResult {
        let end = lineEnd(text, at: location)
        var index = location
        var opening: (open: unichar, close: unichar)?
        var isOpening = false

        while index < end {
            let unit = text.character(at: index)
            if let pair = pairs.first(where: { $0.open == unit }) {
                opening = pair
                isOpening = true
                break
            }
            if let pair = pairs.first(where: { $0.close == unit }) {
                opening = pair
                isOpening = false
                break
            }
            index = nextIndex(text, after: index)
        }

        guard let pair = opening else {
            return VimMotionResult(location: location, kind: .inclusive, moved: false)
        }

        var depth = 0
        var scan = index
        while scan >= 0, scan < text.length {
            let unit = text.character(at: scan)
            if unit == (isOpening ? pair.open : pair.close) { depth += 1 }
            if unit == (isOpening ? pair.close : pair.open) {
                depth -= 1
                if depth == 0 {
                    return VimMotionResult(location: scan, kind: .inclusive)
                }
            }
            scan = isOpening ? nextIndex(text, after: scan) : previousIndex(text, before: scan)
            if !isOpening, scan == 0, text.character(at: 0) == pair.open, depth == 1 {
                return VimMotionResult(location: 0, kind: .inclusive)
            }
        }
        return VimMotionResult(location: location, kind: .inclusive, moved: false)
    }
}
