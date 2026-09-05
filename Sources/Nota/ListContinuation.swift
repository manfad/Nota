import Foundation

/// Return at the end of a list item opens the next one.
///
/// The marker is whatever the line starts with — a bullet (`-`, `*`, `+`), a
/// number, a letter or a roman numeral, followed by `.` or `)` and at least
/// one space — and the new line gets the same indent, the same delimiter and
/// the counter stepped on once: `2.` → `3.`, `a)` → `b)`, `z.` → `aa.`,
/// `A.` → `B.`, `viii.` → `ix.`, `IV.` → `V.`. Case is carried over exactly,
/// so an upper-case list never turns into a lower-case one. A `- [ ]` box
/// rides along as a fresh, unticked `- [ ]`.
///
/// **The `i.` question.** A single `i`, `v`, `x`, `l`, `c`, `d` or `m` is both
/// a letter and a roman numeral, and the two step on differently — the letter
/// `i` is followed by `j`, the numeral `i` by `ii`. Nota resolves it by
/// looking up: the token is roman only when the nearest non-blank line above
/// it at the same indent also carries a roman marker of the same case. So
/// `h.` above `i.` makes it the letter, `viii.` above it makes it the numeral,
/// and with nothing above it — or nothing above it that is a list item at all
/// — a bare `i.` is a numeral, the far commoner way such a list is opened. A
/// token that can only be read one way never asks: `ii`,
/// `iv` and `xii` are roman, `b`, `k` and `aa` are letters.
///
/// Pressing Return on a line that is only a marker (`3. ` with nothing after
/// it) takes the marker off and leaves an empty line, which is how a list is
/// ended everywhere else. Pressing it in the middle of an item's text still
/// opens the next marker, and what was to the right of the caret follows it
/// onto the new line.
///
/// Everything here is a pure function over the note's characters, and nothing
/// walks further than `scanLimit` units away from the caret: an item longer
/// than that is not a list item worth continuing, and a 100 MB line must not
/// be scanned to answer one key press.
struct ListMarker: Equatable {

    /// What the marker counts with.
    enum Counter: Equatable {
        /// `-`, `*` or `+`, which do not count at all.
        case bullet(Character)
        case arabic(Int)
        /// 1 is `a`, 26 is `z`, 27 is `aa`.
        case letter(Int, uppercase: Bool)
        case roman(Int, uppercase: Bool)

        /// The next one along. A bullet stays as it is.
        var next: Counter {
            switch self {
            case .bullet: self
            case .arabic(let value): .arabic(value + 1)
            case .letter(let value, let uppercase): .letter(value + 1, uppercase: uppercase)
            case .roman(let value, let uppercase): .roman(value + 1, uppercase: uppercase)
            }
        }

        /// How it is spelled on the line.
        var text: String {
            switch self {
            case .bullet(let character): String(character)
            case .arabic(let value): String(value)
            case .letter(let value, let uppercase): ListMarker.letters(value, uppercase: uppercase)
            case .roman(let value, let uppercase): ListMarker.roman(value, uppercase: uppercase)
            }
        }

        var isRoman: Bool {
            if case .roman = self { return true }
            return false
        }
    }

    // MARK: - The marker

    /// The whitespace the line opens with, carried to the next line unchanged.
    let indent: String
    let counter: Counter
    /// `.` or `)` after a counter; nil after a bullet, which has none.
    let delimiter: Character?
    /// The whitespace between the marker and what follows it.
    let spacing: String
    /// A `[ ]` or `[x]` box sits between the marker and the item's text.
    let task: Bool
    /// UTF-16 units from the line's start to the item's own text.
    let prefixLength: Int
    /// Whether anything but whitespace follows the marker on the line.
    let hasText: Bool

    /// What a new line carrying this marker opens with. A task box is always
    /// handed on unticked, and its one space is normalised.
    var prefix: String {
        var text = indent + counter.text
        if let delimiter { text.append(delimiter) }
        text += spacing
        if task { text += "[ ] " }
        return text
    }

    /// The marker the line after this one wants.
    func next() -> ListMarker {
        ListMarker(
            indent: indent, counter: counter.next, delimiter: delimiter, spacing: spacing,
            task: task, prefixLength: prefixLength, hasText: false
        )
    }

    // MARK: - Reading a line

    /// The marker a line opens with, if it opens with one.
    ///
    /// `above` is the nearest non-blank line at the same indent, and is only
    /// ever consulted to settle a lone `i`/`I`, `v`/`V` and their kind — see
    /// the note at the top of the file. Passing nothing reads such a token as
    /// a roman numeral.
    static func parse(line: String, above: String? = nil) -> ListMarker? {
        parse(line: line, romanAbove: above.flatMap { parse(line: $0)?.counter })
    }

    private static func parse(line: String, romanAbove: Counter?) -> ListMarker? {
        var rest = Substring(line)
        /// Everything eaten so far, which is the item's prefix once the whole
        /// marker is read. Measured in UTF-16, the unit the storage counts in.
        var prefix = 0
        func eat(_ count: Int) {
            prefix += rest.prefix(count).utf16.count
            rest = rest.dropFirst(count)
        }

        let indent = String(rest.prefix { $0 == " " || $0 == "\t" })
        eat(indent.count)

        var counter: Counter
        var delimiter: Character?
        if let bullet = rest.first, bullet == "-" || bullet == "*" || bullet == "+" {
            counter = .bullet(bullet)
            eat(1)
        } else {
            let token = String(rest.prefix { $0.isLetter || $0.isNumber })
            guard !token.isEmpty, rest.dropFirst(token.count).first == "."
                || rest.dropFirst(token.count).first == ")"
            else { return nil }
            guard let read = self.counter(for: token, romanAbove: romanAbove) else { return nil }
            counter = read
            eat(token.count)
            delimiter = rest.first
            eat(1)
        }

        // A marker with nothing after it is a word, not a list.
        let spacing = String(rest.prefix { $0 == " " || $0 == "\t" })
        guard !spacing.isEmpty else { return nil }
        eat(spacing.count)

        var task = false
        if let box = boxLength(at: rest) {
            task = true
            eat(box)
        }

        return ListMarker(
            indent: indent, counter: counter, delimiter: delimiter, spacing: spacing,
            task: task, prefixLength: prefix,
            hasText: rest.contains { $0 != " " && $0 != "\t" }
        )
    }

    /// `[ ]`, `[x]` or `[X]` with a space or the line's end after it, and how
    /// many characters it takes — the brackets and the space.
    private static func boxLength(at rest: Substring) -> Int? {
        let characters = Array(rest.prefix(4))
        guard characters.count >= 3, characters[0] == "[", characters[2] == "]",
              characters[1] == " " || characters[1] == "x" || characters[1] == "X"
        else { return nil }
        guard characters.count > 3 else { return 3 }
        guard characters[3] == " " || characters[3] == "\t" else { return nil }
        return 4
    }

    /// Which counter a token is. Digits are a number; letters are a roman
    /// numeral when they can only be read as one, a letter when they can only
    /// be read as that, and otherwise whatever the line above says.
    private static func counter(for token: String, romanAbove: Counter?) -> Counter? {
        if token.allSatisfy(\.isNumber) {
            guard token.count <= 9, let value = Int(token) else { return nil }
            return .arabic(value)
        }
        guard token.allSatisfy({ $0.isLetter && $0.isASCII }) else { return nil }
        let uppercase = token.allSatisfy(\.isUppercase)
        guard uppercase || token.allSatisfy(\.isLowercase) else { return nil }

        let lowered = token.lowercased()
        let asRoman = romanValue(of: lowered)
        let asLetter = letterValue(of: lowered)
        switch (asRoman, asLetter) {
        case (let roman?, nil): return .roman(roman, uppercase: uppercase)
        case (nil, let letter?): return .letter(letter, uppercase: uppercase)
        case (let roman?, let letter?):
            // A lone `i` or `x`: the item above settles it, but only if it is
            // an item of the same case — a lower-case list says nothing about
            // an upper-case `I.`, which is opening a list of its own.
            guard let above = romanAbove, above.isCased(uppercase) else {
                return .roman(roman, uppercase: uppercase)
            }
            return above.isRoman
                ? .roman(roman, uppercase: uppercase)
                : .letter(letter, uppercase: uppercase)
        case (nil, nil): return nil
        }
    }

    // MARK: - Letters

    private static func letterValue(of token: String) -> Int? {
        guard (1...2).contains(token.count) else { return nil }
        var value = 0
        for scalar in token.unicodeScalars {
            guard scalar.value >= 97, scalar.value <= 122 else { return nil }
            value = value * 26 + Int(scalar.value - 96)
        }
        return value
    }

    /// Bijective base 26: 26 is `z` and 27 is `aa`, with no `a0` in between.
    static func letters(_ value: Int, uppercase: Bool) -> String {
        guard value > 0 else { return uppercase ? "A" : "a" }
        var remaining = value
        var text = ""
        let base = UInt32(uppercase ? 65 : 97)
        while remaining > 0 {
            let digit = (remaining - 1) % 26
            text = String(UnicodeScalar(base + UInt32(digit))!) + text
            remaining = (remaining - 1) / 26
        }
        return text
    }

    // MARK: - Roman numerals

    private static let romanDigits: [(symbol: String, value: Int)] = [
        ("m", 1000), ("cm", 900), ("d", 500), ("cd", 400), ("c", 100), ("xc", 90),
        ("l", 50), ("xl", 40), ("x", 10), ("ix", 9), ("v", 5), ("iv", 4), ("i", 1),
    ]

    /// The value of a canonical lower-case numeral. Anything the spelling
    /// below would not have produced — `iiii`, `vv`, `ic` — is not one.
    static func romanValue(of token: String) -> Int? {
        guard !token.isEmpty, token.count <= 15 else { return nil }
        var rest = Substring(token)
        var value = 0
        for (symbol, amount) in romanDigits {
            while rest.hasPrefix(symbol) {
                value += amount
                rest = rest.dropFirst(symbol.count)
            }
        }
        guard rest.isEmpty, value > 0, roman(value, uppercase: false) == token else { return nil }
        return value
    }

    static func roman(_ value: Int, uppercase: Bool) -> String {
        guard value > 0 else { return uppercase ? "I" : "i" }
        var remaining = value
        var text = ""
        for (symbol, amount) in romanDigits {
            while remaining >= amount {
                text += symbol
                remaining -= amount
            }
        }
        return uppercase ? text.uppercased() : text
    }
}

private extension ListMarker.Counter {
    /// Whether this counter is spelled in letters of the given case. A number
    /// or a bullet is spelled in neither and answers no to both.
    func isCased(_ uppercase: Bool) -> Bool {
        switch self {
        case .letter(_, let its), .roman(_, let its): its == uppercase
        case .arabic, .bullet: false
        }
    }
}

/// The one call the editor makes on Return: hand it the note's characters and
/// the selection, and it says what to replace with what.
enum ListContinuation {

    /// One edit, the way `LineOperations` hands them over — a range, the text
    /// that goes in its place, and where the caret lands afterwards.
    struct Edit: Equatable {
        let range: NSRange
        let text: String
        let caret: Int
    }

    /// How far from the caret the line's start and end are looked for. An
    /// item longer than this gets a plain newline.
    static let scanLimit = 4096

    /// What Return should do, or nil when it should do what it always does.
    static func edit(forReturnIn text: NSString, at selection: NSRange) -> Edit? {
        guard selection.length == 0 else { return nil }
        let caret = max(0, min(selection.location, text.length))
        guard let start = lineStart(in: text, before: caret),
              let line = lineText(in: text, from: start)
        else { return nil }

        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let above = lineAbove(in: text, before: start, indent: String(indent))
        guard let marker = ListMarker.parse(line: line, above: above) else { return nil }
        // Inside the marker itself Return is just a newline.
        guard caret - start >= marker.prefixLength else { return nil }

        guard marker.hasText else {
            // A marker with nothing on it: the gesture that ends the list.
            let end = start + (line as NSString).length
            return Edit(range: NSRange(location: start, length: end - start), text: "", caret: start)
        }
        let insert = "\n" + marker.next().prefix
        return Edit(
            range: NSRange(location: caret, length: 0), text: insert,
            caret: caret + (insert as NSString).length
        )
    }

    // MARK: - Lines

    private static func lineStart(in text: NSString, before caret: Int) -> Int? {
        var index = caret
        while index > 0, caret - index <= scanLimit {
            if text.character(at: index - 1) == 0x0A { return index }
            index -= 1
        }
        return index == 0 ? 0 : nil
    }

    /// The line at `start`, without its newline. Nil when it runs on past the
    /// scan limit, since then nothing here can say what is on it.
    private static func lineText(in text: NSString, from start: Int) -> String? {
        let length = min(scanLimit, text.length - start)
        let head = text.substring(with: NSRange(location: start, length: length))
        if let newline = head.firstIndex(of: "\n") { return String(head[head.startIndex..<newline]) }
        return start + length == text.length ? head : nil
    }

    /// The nearest non-blank line above `start` at the same indent — what
    /// settles a lone `i.`. Blank lines and lines indented further belong to
    /// the item or to a list of their own and are stepped over; the first line
    /// indented as far or less stops the walk, and answers only if it is
    /// indented exactly as far.
    private static func lineAbove(in text: NSString, before start: Int, indent: String) -> String? {
        var end = start
        var budget = scanLimit
        while end > 0, budget > 0 {
            guard let above = lineStart(in: text, before: end - 1),
                  let line = lineText(in: text, from: above)
            else { return nil }
            budget -= (end - above)
            end = above
            guard line.contains(where: { $0 != " " && $0 != "\t" }) else { continue }
            let its = String(line.prefix { $0 == " " || $0 == "\t" })
            guard its.count >= indent.count else { return nil }
            if its == indent { return line }
        }
        return nil
    }
}
