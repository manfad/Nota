import Foundation

/// One address in an ex range: `.`, `$`, `15`, `'a`, each with an optional
/// `+N` / `-N` after it.
struct VimExAddress: Equatable {
    enum Base: Equatable {
        case current
        case last
        case line(Int)
        case mark(Character)
    }

    var base: Base
    var offset: Int = 0

    static let current = VimExAddress(base: .current)
    static let last = VimExAddress(base: .last)
    static func line(_ number: Int) -> VimExAddress { VimExAddress(base: .line(number)) }
    static func mark(_ name: Character) -> VimExAddress { VimExAddress(base: .mark(name)) }
}

struct VimExRange: Equatable {
    var start: VimExAddress
    var end: VimExAddress

    /// `%`.
    static let whole = VimExRange(start: .line(1), end: .last)
    /// `'<,'>`, which visual mode's `:` writes for you.
    static let visual = VimExRange(start: .mark("<"), end: .mark(">"))
}

/// The commands the ex line knows. Anything else is `unknown`, which is what
/// puts "Not an editor command" in the footer.
enum VimExName: Equatable {
    /// A range and nothing else — `:15` — which just moves the caret.
    case goToLine
    case substitute, delete, yank, join, move, copy, sort
    case write, quit, writeQuit, exit, edit
    case noHighlight, tabNew, tabNext, tabPrevious
    case help, registers, marks, set
    case shiftRight, shiftLeft
    case unknown(String)
}

struct VimExCommand: Equatable {
    var range: VimExRange?
    var name: VimExName
    /// `:q!`, `:sort!`.
    var bang = false
    var argument = ""
    /// `:>>` shifts twice, `:<<<` three times.
    var repetitions = 1
}

/// Reads a typed `:` line into something the engine can run.
///
/// This is only the parse — nothing here touches the note — so every range
/// form, abbreviation and `:s` flag can be tested on its own.
enum VimEx {

    // MARK: - The line

    /// `nil` when the line holds nothing at all.
    static func parse(_ line: String) -> VimExCommand? {
        var source = Array(line)
        var index = 0
        // Leading colons and blanks are the user's, not ours.
        while index < source.count, source[index] == ":" || source[index] == " " { index += 1 }
        source = Array(source[index...])
        index = 0

        let range = parseRange(source, &index)
        skipBlanks(source, &index)
        guard index < source.count else {
            guard range != nil else { return nil }
            return VimExCommand(range: range, name: .goToLine)
        }

        // `>` and `<` are the only commands not spelled with letters, and they
        // repeat by being typed again.
        if source[index] == ">" || source[index] == "<" {
            let shift = source[index]
            var repetitions = 0
            while index < source.count, source[index] == shift {
                repetitions += 1
                index += 1
            }
            return VimExCommand(
                range: range,
                name: shift == ">" ? .shiftRight : .shiftLeft,
                argument: remainder(source, index),
                repetitions: repetitions
            )
        }

        var typed = ""
        while index < source.count, source[index].isLetter {
            typed.append(source[index])
            index += 1
        }
        var bang = false
        if index < source.count, source[index] == "!" {
            bang = true
            index += 1
        }
        guard !typed.isEmpty else {
            guard range != nil else { return nil }
            return VimExCommand(range: range, name: .goToLine)
        }

        let name = resolve(typed)
        // A substitution's argument starts at the separator, so its leading
        // blanks are not the argument's; everything else trims.
        let argument = name == .substitute
            ? String(source[index...])
            : remainder(source, index)
        return VimExCommand(range: range, name: name, bang: bang, argument: argument)
    }

    private static func remainder(_ source: [Character], _ index: Int) -> String {
        String(source[index...]).trimmingCharacters(in: .whitespaces)
    }

    private static func skipBlanks(_ source: [Character], _ index: inout Int) {
        while index < source.count, source[index] == " " { index += 1 }
    }

    // MARK: - Ranges

    private static func parseRange(_ source: [Character], _ index: inout Int) -> VimExRange? {
        skipBlanks(source, &index)
        guard index < source.count else { return nil }

        if source[index] == "%" {
            index += 1
            return .whole
        }
        guard let first = parseAddress(source, &index) else { return nil }
        skipBlanks(source, &index)
        guard index < source.count, source[index] == "," || source[index] == ";" else {
            return VimExRange(start: first, end: first)
        }
        index += 1
        skipBlanks(source, &index)
        let second = parseAddress(source, &index) ?? .current
        return VimExRange(start: first, end: second)
    }

    private static func parseAddress(
        _ source: [Character], _ index: inout Int
    ) -> VimExAddress? {
        guard index < source.count else { return nil }
        var address: VimExAddress?

        switch source[index] {
        case ".":
            address = .current
            index += 1
        case "$":
            address = .last
            index += 1
        case "'":
            index += 1
            guard index < source.count else { return nil }
            address = .mark(source[index])
            index += 1
        case let character where character.isNumber:
            var digits = ""
            while index < source.count, source[index].isNumber {
                digits.append(source[index])
                index += 1
            }
            address = .line(Int(digits) ?? 1)
        case "+", "-":
            // A bare offset counts from the current line.
            address = .current
        default:
            return nil
        }

        // `+`/`-`, with the count optional and repeatable: `.+2`, `$-`, `'a++`.
        var offset = 0
        while index < source.count, source[index] == "+" || source[index] == "-" {
            let sign = source[index] == "+" ? 1 : -1
            index += 1
            var digits = ""
            while index < source.count, source[index].isNumber {
                digits.append(source[index])
                index += 1
            }
            offset += sign * (Int(digits) ?? 1)
        }
        address?.offset = offset
        return address
    }

    /// A whole string as one address — the `{addr}` `:m` and `:t` take. Zero
    /// is a real one there: `:m0` puts the lines above the first.
    static func address(_ text: String) -> VimExAddress? {
        let source = Array(text.trimmingCharacters(in: .whitespaces))
        guard !source.isEmpty else { return nil }
        var index = 0
        return parseAddress(source, &index)
    }

    // MARK: - Names

    /// Full name, shortest form vim accepts, and what it means. The order is
    /// the order they are tried in, which is what decides an ambiguous prefix:
    /// `:tabn` is `:tabnext` because `:tabnew` has no short form, exactly as
    /// vim documents it.
    private static let names: [(full: String, minimum: String, name: VimExName)] = [
        ("substitute", "s", .substitute),
        ("delete", "d", .delete),
        ("yank", "y", .yank),
        ("join", "j", .join),
        ("move", "m", .move),
        ("copy", "co", .copy),
        ("t", "t", .copy),
        ("sort", "sor", .sort),
        ("write", "w", .write),
        ("wq", "wq", .writeQuit),
        ("xit", "x", .exit),
        ("quit", "q", .quit),
        ("edit", "e", .edit),
        ("nohlsearch", "noh", .noHighlight),
        ("tabnext", "tabn", .tabNext),
        ("tabprevious", "tabp", .tabPrevious),
        ("tabnew", "tabnew", .tabNew),
        ("bnext", "bn", .tabNext),
        ("bprevious", "bp", .tabPrevious),
        ("help", "h", .help),
        ("registers", "reg", .registers),
        ("display", "di", .registers),
        ("marks", "marks", .marks),
        ("set", "se", .set),
    ]

    static func resolve(_ typed: String) -> VimExName {
        for entry in names
        where typed.count >= entry.minimum.count && entry.full.hasPrefix(typed) {
            return entry.name
        }
        return .unknown(typed)
    }
}

// MARK: - :s

/// The three parts of `:s/pattern/replacement/flags`.
struct VimSubstitution: Equatable {
    var pattern: String
    var replacement: String
    var global = false
    var ignoreCase = false

    /// Any non-alphanumeric character separates the parts — `:s#a#b#` is as
    /// good as `:s/a/b/` — and the separator can be escaped inside them. A
    /// trailing separator may be left off, the way vim allows.
    ///
    /// An empty argument means "again", which the engine answers with the
    /// last substitution it ran.
    static func parse(_ argument: String) -> VimSubstitution? {
        let source = Array(argument)
        guard let separator = source.first,
              !separator.isLetter, !separator.isNumber, separator != " "
        else { return nil }

        var parts: [String] = []
        var current = ""
        var index = 1
        var escaped = false
        while index < source.count, parts.count < 2 {
            let character = source[index]
            index += 1
            if escaped {
                // The separator loses its backslash; anything else keeps it,
                // so `\d` and `\1` reach the regex intact.
                if character != separator { current.append("\\") }
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == separator {
                parts.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        if escaped { current.append("\\") }
        if parts.count < 2 {
            parts.append(current)
            current = ""
        }

        let flags = index < source.count ? String(source[index...]) : ""
        return VimSubstitution(
            pattern: parts.first ?? "",
            replacement: parts.count > 1 ? parts[1] : "",
            global: flags.contains("g"),
            ignoreCase: flags.contains("i")
        )
    }
}
