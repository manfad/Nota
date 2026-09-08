import Foundation

/// The two little minifiers Minify runs over the code a page keeps inside it:
/// the CSS in a `<style>` and the JavaScript in a `<script>`.
///
/// `HTMLFormat` moves the whitespace between and around tags; everything
/// inside a raw-text element used to go back down byte for byte, which left a
/// minified page carrying four hundred indented lines of stylesheet. These two
/// take that content the rest of the way. Neither is a parser and neither will
/// ever be one: nothing is renamed, nothing is reordered, no rule is dropped,
/// no `if` loses its braces. All they take out is whitespace and comments, and
/// they do it byte by byte with just enough of a state machine to know when a
/// byte is code and when it is the inside of a string.
///
/// The rule both of them keep is that an answer they are not sure of is not
/// worth giving: an unterminated string, template, regular expression or
/// comment means the block is handed back exactly as it came in. A page whose
/// script does not compile is still a page, and the corner button replaces the
/// whole note with what comes out of here.
///
/// Both are idempotent — running either over its own output gives that output
/// back — which is what lets `HTMLFormat.isPretty` ask "would this change?" to
/// decide whether the page has anything left to minify.
enum InlineCodeMinify {

    // MARK: - CSS

    /// The stylesheet with its whitespace pulled together and its comments
    /// taken out.
    ///
    /// Runs of whitespace become one space, and that space then goes wherever
    /// it cannot matter: on both sides of `{`, `}`, `;` and `,`, and *after* a
    /// `:`. Never before a `:` — `a :hover` and `a:hover` are two different
    /// selectors, and one is not the other's tidier spelling. Nothing is
    /// touched around `+`, `-`, `*`, `/`, `>`, `~` or the parentheses either:
    /// `calc(100% - 2rem)` needs both of its spaces, `a > b` reads the same
    /// with or without them, and telling those two apart is a grammar this is
    /// not. A `;` in front of a `}` goes, and so does a second `;` after a
    /// first.
    ///
    /// Strings, and the whole inside of a `url(…)`, are copied out as they were
    /// written. So is a `/*! … */` comment, since the exclamation mark is how
    /// a licence asks to survive; every other comment is dropped.
    static func css(_ text: String) -> String {
        let bytes = Array(text.utf8)
        guard let out = minifiedCSS(bytes) else { return text }
        return String(decoding: out, as: UTF8.self)
    }

    /// `nil` where the scan could not follow the block, which is the caller's
    /// signal to hand the source back untouched.
    private static func minifiedCSS(_ bytes: [UInt8]) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var pendingSpace = false

        /// One run of source that goes down as it was written, with the space
        /// in front of it kept only where it could be read.
        func put(_ range: Range<Int>) {
            let first = bytes[range.lowerBound]
            if pendingSpace {
                if !cssDropsSpace(before: first, after: out.last) { out.append(0x20) }
                pendingSpace = false
            }
            out.append(contentsOf: bytes[range])
        }

        var index = 0
        while index < bytes.count {
            let byte = bytes[index]

            if isWhitespace(byte) {
                if !out.isEmpty { pendingSpace = true }
                index += 1
                continue
            }

            if byte == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x2A {  // /*
                guard let end = endOfBlockComment(bytes, from: index) else { return nil }
                if index + 2 < bytes.count, bytes[index + 2] == 0x21 {  // /*!
                    put(index..<end)
                    pendingSpace = false
                } else if !out.isEmpty {
                    pendingSpace = true
                }
                index = end
                continue
            }

            if byte == 0x22 || byte == 0x27 {
                guard let end = endOfString(bytes, from: index) else { return nil }
                put(index..<end)
                index = end
                continue
            }

            if isURLFunction(bytes, at: index) {
                guard let end = endOfURL(bytes, from: index) else { return nil }
                put(index..<end)
                index = end
                continue
            }

            // A `;` the block already has, or one standing in front of the `}`
            // that ends the rule, says nothing a browser reads.
            if byte == 0x3B, out.last == 0x3B {
                pendingSpace = false
                index += 1
                continue
            }
            if byte == 0x7D {
                while out.last == 0x3B { out.removeLast() }
            }
            put(index..<(index + 1))
            index += 1
        }
        return out
    }

    /// The bytes either side of which a space is only layout.
    private static let cssTightBytes: Set<UInt8> = [0x7B, 0x7D, 0x3B, 0x2C]  // { } ; ,

    private static func cssDropsSpace(before next: UInt8, after previous: UInt8?) -> Bool {
        guard let previous else { return true }
        if cssTightBytes.contains(next) { return true }
        return cssTightBytes.contains(previous) || previous == 0x3A  // …and after a `:`
    }

    /// Whether a `url(` token starts here. What is inside one is a URL, not
    /// CSS — its spaces, its `;` and its `,` all belong to whoever wrote it.
    private static func isURLFunction(_ bytes: [UInt8], at index: Int) -> Bool {
        guard index + 4 <= bytes.count else { return false }
        guard bytes[index] | 0x20 == 0x75, bytes[index + 1] | 0x20 == 0x72,
            bytes[index + 2] | 0x20 == 0x6C, bytes[index + 3] == 0x28
        else { return false }
        // `myurl(` is somebody else's function.
        if index > 0, isIdentifier(bytes[index - 1]) { return false }
        return true
    }

    private static func endOfURL(_ bytes: [UInt8], from start: Int) -> Int? {
        var index = start + 4  // url(
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 || byte == 0x27 {
                guard let end = endOfString(bytes, from: index) else { return nil }
                index = end
                continue
            }
            if byte == 0x29 { return index + 1 }
            index += 1
        }
        return nil
    }

    // MARK: - JavaScript

    /// The program with its whitespace pulled together and its comments taken
    /// out, and nothing else done to it at all.
    ///
    /// Strings, template literals — `${ … }` nesting and all — and regular
    /// expressions are copied out as they were written. A `//` line comment
    /// and a `/* … */` block comment go, unless the block one opens `/*!` or
    /// names `@license` or `@preserve`.
    ///
    /// Whitespace is the careful part, because a newline in JavaScript is
    /// sometimes a semicolon. A run with no newline in it becomes one space,
    /// and that space is dropped unless it is holding two things apart: two
    /// identifier characters, two `+` or two `-` (so `a + +b` survives), two
    /// `/` (or the pair would read as a comment), or a digit and the `.` after
    /// it. A run *with* a newline in it is dropped wherever the language could
    /// not have read it as a semicolon: after `;` `{` `,` `(` `[` and after an
    /// operator (`=` `?` `:` `.` `+` `-` `*` `/` `%` `<` `>` `&` `|` `^` `!`
    /// `~`), or in front of `}` `)` `]` `;` `(` `[` and in front of a byte that
    /// can only carry an expression on — an operator, a `.`, a `,` — since the
    /// grammar accepts every one of those as the next token and inserts no
    /// semicolon before it. What stays a line break is the newline in front of
    /// something that could begin a statement (`let a = {}` over `let b`,
    /// `return` over `x`, `foo()` over `bar()`) and the two restricted spots —
    /// a `++` or `--` on the line below, and one ending the line above — which
    /// cost a few bytes and never a meaning.
    static func javascript(_ text: String) -> String {
        let bytes = Array(text.utf8)
        guard let out = minifiedJavaScript(bytes) else { return text }
        return String(decoding: out, as: UTF8.self)
    }

    private static func minifiedJavaScript(_ bytes: [UInt8]) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var pendingSpace = false
        var pendingNewline = false
        /// The last byte written that was not whitespace, and — while that
        /// byte is part of a word — the word it belongs to. Both are what a
        /// `/` is read against.
        var previous: UInt8?
        var word: [UInt8] = []

        func put(_ range: Range<Int>) {
            let first = bytes[range.lowerBound]
            if pendingSpace || pendingNewline {
                let after = range.lowerBound + 1 < bytes.count ? bytes[range.lowerBound + 1] : nil
                let beforePrevious = out.count > 1 ? out[out.count - 2] : nil
                if pendingNewline,
                    !joinsLines(
                        previous: previous, beforePrevious: beforePrevious, next: first,
                        then: after)
                {
                    out.append(0x0A)
                } else if keepsSpace(previous: previous, next: first) {
                    out.append(0x20)
                }
                pendingSpace = false
                pendingNewline = false
            }
            out.append(contentsOf: bytes[range])
            previous = bytes[range.upperBound - 1]
            if range.count == 1, isIdentifier(first) {
                word.append(first)
            } else {
                word = []
            }
        }

        var index = 0
        while index < bytes.count {
            let byte = bytes[index]

            if isWhitespace(byte) {
                var sawNewline = false
                while index < bytes.count, isWhitespace(bytes[index]) {
                    if bytes[index] == 0x0A || bytes[index] == 0x0D { sawNewline = true }
                    index += 1
                }
                if !out.isEmpty {
                    pendingSpace = true
                    if sawNewline { pendingNewline = true }
                }
                continue
            }

            if byte == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x2F {
                while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D {
                    index += 1
                }
                if !out.isEmpty { pendingSpace = true }
                continue
            }

            if byte == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x2A {
                guard let end = endOfBlockComment(bytes, from: index) else { return nil }
                if keepsComment(bytes, index..<end) {
                    put(index..<end)
                    // The comment has just written a `/`, and the next thing
                    // written must not be able to lean on it: a break here is
                    // both safe and where a licence wants to be.
                    pendingSpace = true
                    pendingNewline = true
                } else if !out.isEmpty {
                    pendingSpace = true
                    // A block comment carrying a newline *is* a newline, as
                    // far as the semicolon the language inserts is concerned.
                    if bytes[index..<end].contains(0x0A) { pendingNewline = true }
                }
                index = end
                continue
            }

            if byte == 0x2F, allowsRegex(after: previous, word: word) {
                guard let end = endOfRegex(bytes, from: index) else { return nil }
                put(index..<end)
                index = end
                continue
            }

            if byte == 0x27 || byte == 0x22 {
                guard let end = endOfString(bytes, from: index) else { return nil }
                put(index..<end)
                index = end
                continue
            }

            if byte == 0x60 {
                guard let end = endOfTemplate(bytes, from: index) else { return nil }
                put(index..<end)
                index = end
                continue
            }

            put(index..<(index + 1))
            index += 1
        }
        return out
    }

    /// Whether the one space a run of whitespace came down to is holding two
    /// things apart.
    private static func keepsSpace(previous: UInt8?, next: UInt8) -> Bool {
        guard let previous else { return false }
        if isIdentifier(previous), isIdentifier(next) { return true }
        if previous == 0x2B, next == 0x2B { return true }  // a + +b
        if previous == 0x2D, next == 0x2D { return true }  // a - -b
        if previous == 0x2F, next == 0x2F { return true }  // or the two make a comment
        if isDigit(previous), next == 0x2E { return true }  // 1 .toString()
        return false
    }

    /// The bytes after which a line has plainly not ended, so a newline there
    /// is layout rather than the semicolon the language would insert: the
    /// openers `;` `{` `,` `(` `[` and every operator a line can end on.
    private static let openBytes: Set<UInt8> = [
        0x3B, 0x7B, 0x2C, 0x28, 0x5B,  // ; { , ( [
        0x3D, 0x3F, 0x3A, 0x2E, 0x2B, 0x2D, 0x2A, 0x2F, 0x25,  // = ? : . + - * / %
        0x3C, 0x3E, 0x26, 0x7C, 0x5E, 0x21, 0x7E,  // < > & | ^ ! ~
    ]
    /// …and the bytes in front of which the same is true: the closers, and
    /// every byte that can only carry an expression on. A `(` and a `[` are
    /// here because the grammar reads them as a call and a subscript whether
    /// or not there is a newline in front — `x = {}` over `(f)()` is already
    /// the call it looks like it is not, and joining it changes nothing. A `!`
    /// and a `~` are not, since either can begin a statement of its own.
    private static let closeBytes: Set<UInt8> = [
        0x7D, 0x29, 0x5D, 0x3B, 0x28, 0x5B,  // } ) ] ; ( [
        0x3D, 0x3F, 0x3A, 0x2E, 0x2C, 0x2B, 0x2D, 0x2A, 0x2F, 0x25,  // = ? : . , + - * / %
        0x3C, 0x3E, 0x26, 0x7C, 0x5E,  // < > & | ^
    ]

    private static func joinsLines(
        previous: UInt8?, beforePrevious: UInt8?, next: UInt8, then after: UInt8?
    ) -> Bool {
        guard let previous else { return true }  // a leading newline is only air
        // The two spots the grammar itself forbids a line break from being
        // taken out of: a `++` or `--` may not be carried up onto the line
        // before it (`a` over `++b` is two statements), and a line ending in
        // one may not carry the next line up (`x++` over `y` is two as well).
        if next == 0x2B, after == 0x2B { return false }
        if next == 0x2D, after == 0x2D { return false }
        if previous == 0x2B, beforePrevious == 0x2B { return false }
        if previous == 0x2D, beforePrevious == 0x2D { return false }
        // A `}` says nothing about the line it ends: it closes a block, where
        // the newline after it is air, and it closes an object literal, where
        // the newline after it is the end of a statement. `let a = {}` and the
        // `let` on the line below it have to stay two lines, so a `}` never
        // joins on its own account — only what follows it can.
        return openBytes.contains(previous) || closeBytes.contains(next)
    }

    /// The bytes after which a `/` opens a regular expression rather than
    /// dividing what came before it.
    private static let regexOpeners: Set<UInt8> = [
        0x28, 0x2C, 0x3D, 0x3A, 0x5B, 0x21, 0x26, 0x7C, 0x3F, 0x7B, 0x7D, 0x3B, 0x2B, 0x2D,
        0x2A, 0x25, 0x3C, 0x3E, 0x7E, 0x5E,
    ]

    /// …and the words after which the same is true. `return /x/` is a regular
    /// expression; `a / x` is a division.
    private static let regexKeywords: Set<String> = [
        "return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw", "case",
        "do", "else", "yield", "await",
    ]

    private static func allowsRegex(after previous: UInt8?, word: [UInt8]) -> Bool {
        guard let previous else { return true }
        if regexOpeners.contains(previous) { return true }
        guard isIdentifier(previous) else { return false }
        return regexKeywords.contains(String(decoding: word, as: UTF8.self))
    }

    /// A comment worth keeping: the `/*!` a minifier has always honoured, and
    /// the two words a licence header announces itself with.
    private static func keepsComment(_ bytes: [UInt8], _ range: Range<Int>) -> Bool {
        if range.count > 2, bytes[range.lowerBound + 2] == 0x21 { return true }
        return contains(bytes, range, "@license") || contains(bytes, range, "@preserve")
    }

    private static func contains(_ bytes: [UInt8], _ range: Range<Int>, _ needle: String) -> Bool {
        let wanted = Array(needle.utf8)
        guard range.count >= wanted.count else { return false }
        for start in range.lowerBound...(range.upperBound - wanted.count) {
            var matched = true
            for offset in 0..<wanted.count where bytes[start + offset] != wanted[offset] {
                matched = false
                break
            }
            if matched { return true }
        }
        return false
    }

    // MARK: - Reading one thing at a time

    /// A quoted string, escapes and all, ending just past its closing quote.
    /// A raw newline inside one is nobody's string, and is answered the way
    /// everything else the scan cannot follow is.
    private static func endOfString(_ bytes: [UInt8], from start: Int) -> Int? {
        let quote = bytes[start]
        var index = start + 1
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x5C {
                index += 2
                continue
            }
            if byte == quote { return index + 1 }
            if byte == 0x0A || byte == 0x0D { return nil }
            index += 1
        }
        return nil
    }

    private static func endOfBlockComment(_ bytes: [UInt8], from start: Int) -> Int? {
        var index = start + 2
        while index + 1 < bytes.count {
            if bytes[index] == 0x2A, bytes[index + 1] == 0x2F { return index + 2 }
            index += 1
        }
        return nil
    }

    /// A regular expression literal and the flags after it. A `/` inside a
    /// `[…]` character class is a character, not the end of the literal.
    private static func endOfRegex(_ bytes: [UInt8], from start: Int) -> Int? {
        var index = start + 1
        var inClass = false
        var closed = false
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x5C {
                index += 2
                continue
            }
            if byte == 0x0A || byte == 0x0D { return nil }
            if inClass {
                if byte == 0x5D { inClass = false }
            } else if byte == 0x5B {
                inClass = true
            } else if byte == 0x2F {
                index += 1
                closed = true
                break
            }
            index += 1
        }
        guard closed else { return nil }
        while index < bytes.count, isIdentifier(bytes[index]) { index += 1 }
        return index
    }

    /// One level of a template literal: either the text of a template, or the
    /// expression inside a `${ … }` of one. A template may hold an expression
    /// which holds a template, so the scan carries a stack of them.
    private struct TemplateFrame {
        let isTemplate: Bool
        var braceDepth: Int
    }

    /// A template literal, ending just past its closing backtick. Everything
    /// in it is copied out as written, so all this has to get right is where
    /// it ends — which means following the expressions inside it far enough to
    /// know which `}` and which backtick are theirs and which are the
    /// template's.
    private static func endOfTemplate(_ bytes: [UInt8], from start: Int) -> Int? {
        var stack = [TemplateFrame(isTemplate: true, braceDepth: 0)]
        var index = start + 1
        var previous: UInt8?
        var word: [UInt8] = []

        while index < bytes.count, let frame = stack.last {
            let byte = bytes[index]

            if frame.isTemplate {
                if byte == 0x5C {
                    index += 2
                    continue
                }
                if byte == 0x60 {
                    stack.removeLast()
                    index += 1
                    if stack.isEmpty { return index }
                    continue
                }
                if byte == 0x24, index + 1 < bytes.count, bytes[index + 1] == 0x7B {  // ${
                    stack.append(TemplateFrame(isTemplate: false, braceDepth: 0))
                    previous = nil
                    word = []
                    index += 2
                    continue
                }
                index += 1
                continue
            }

            switch byte {
            case 0x27, 0x22:
                guard let end = endOfString(bytes, from: index) else { return nil }
                index = end
                previous = byte
                word = []

            case 0x60:
                stack.append(TemplateFrame(isTemplate: true, braceDepth: 0))
                index += 1

            case 0x7B:
                stack[stack.count - 1].braceDepth += 1
                index += 1
                previous = byte
                word = []

            case 0x7D:
                if stack[stack.count - 1].braceDepth == 0 {
                    stack.removeLast()  // back into the template around it
                    if stack.isEmpty { return nil }
                } else {
                    stack[stack.count - 1].braceDepth -= 1
                }
                index += 1
                previous = byte
                word = []

            case 0x2F:
                if index + 1 < bytes.count, bytes[index + 1] == 0x2F {
                    while index < bytes.count, bytes[index] != 0x0A { index += 1 }
                } else if index + 1 < bytes.count, bytes[index + 1] == 0x2A {
                    guard let end = endOfBlockComment(bytes, from: index) else { return nil }
                    index = end
                } else if allowsRegex(after: previous, word: word) {
                    guard let end = endOfRegex(bytes, from: index) else { return nil }
                    index = end
                    previous = 0x2F
                    word = []
                } else {
                    index += 1
                    previous = byte
                    word = []
                }

            default:
                if isWhitespace(byte) {
                    index += 1  // a word is still the word it was
                } else if isIdentifier(byte) {
                    word.append(byte)
                    previous = byte
                    index += 1
                } else {
                    word = []
                    previous = byte
                    index += 1
                }
            }
        }
        return nil
    }

    // MARK: - Bytes

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }

    /// What may sit next to another one of itself without the space between
    /// them being redundant. Everything outside ASCII counts: a letter with an
    /// accent on it is a letter.
    private static func isIdentifier(_ byte: UInt8) -> Bool {
        if byte >= 0x80 { return true }
        if isDigit(byte) { return true }
        if (byte | 0x20) >= 0x61 && (byte | 0x20) <= 0x7A { return true }
        return byte == 0x5F || byte == 0x24  // _ $
    }
}
