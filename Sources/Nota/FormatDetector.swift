import Foundation

/// What a note's text looks like, when its name has nothing to say.
///
/// A `.txt` and an untitled note have no preview: the extension is the only
/// thing Nota reads a format out of, and neither has one worth reading. This
/// is the second opinion — a look at the characters themselves, offered to
/// the reader in a pill rather than applied behind their back.
///
/// Deliberately shy. Every signal here is punctuation an author had to type
/// on purpose: a brace that parses, a `\documentclass`, a `CREATE TABLE`, a
/// `[section]` with keys under it. Prose that happens to hold a colon, a
/// shopping list of dashes and two lines of anything at all all come back
/// `nil`, because an offer that is wrong is worse than no offer — the reader
/// has to read it, and dismiss it, and then it was noise.
///
/// Pure text: no AppKit, no file, no note. `detect(_:)` is the whole of it,
/// and the order the signals are asked in is the whole of its judgement —
/// first hit wins, and the ones that can only be one thing are asked first.
enum FormatDetector {

    /// How little text is not worth looking at. Three lines with something on
    /// them, or sixty characters — either is enough to have said something,
    /// and under both there is nothing here but the first word of a note
    /// somebody has just started typing.
    static let minimumLines = 3
    static let minimumCharacters = 60

    /// What the text reads as, or `nil` — which is the answer for most text,
    /// and is meant to be.
    static func detect(_ text: String) -> RenderedPreviewKind? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let filled = lines.filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard filled.count >= minimumLines || trimmed.count >= minimumCharacters else {
            return nil
        }

        if isJSON(trimmed) { return .tree(.json) }
        if let markup = markupKind(trimmed) { return markup }
        if isLaTeX(filled) { return .latex }
        if isSQL(filled) { return .sql }
        if isTOML(filled) { return .tree(.toml) }
        if isYAML(trimmed, lines: filled) { return .tree(.yaml) }
        if isCSV(text) { return .csv }
        if isMarkdown(filled) { return .markdown }
        return nil
    }

    // MARK: - JSON

    /// A brace or a bracket, and the whole of it parses. Nota's own walker
    /// answers, so what counts as JSON here is exactly what the tree pane
    /// would draw — a file this says yes to is a file the preview can show.
    private static func isJSON(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return false }
        return (try? JSONTree.parse(trimmed)) != nil
    }

    // MARK: - The three that start with an angle bracket

    /// XML, SVG or HTML — one question, because the three are told apart by
    /// the same first tag.
    ///
    /// A prolog says XML, but not *which* XML: a drawing written by Inkscape
    /// or Illustrator opens `<?xml …?>` and only then `<svg`. So the prolog
    /// is read and the root element after it decides, which is the one place
    /// this leans past "first hit wins" — and it leans towards the more
    /// specific answer, never the vaguer one.
    private static func markupKind(_ trimmed: String) -> RenderedPreviewKind? {
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("<?xml") {
            return rootElement(of: lowered) == "svg" ? .svg : .tree(.xml)
        }
        if lowered.hasPrefix("<svg") { return .svg }
        if lowered.hasPrefix("<!doctype html") || lowered.hasPrefix("<html") { return .html }
        // No doctype and no root tag: a fragment is a page all the same if it
        // is plainly written in page tags. Three different ones, so a single
        // `<div>` in a paragraph of prose says nothing.
        if htmlTagVariety(lowered) >= 3 { return .html }
        // A bare root element with no prolog — `<catalog>` — is XML only when
        // it closes itself again, which is more than one angle bracket's
        // worth of evidence.
        if lowered.hasPrefix("<"), let root = rootElement(of: lowered),
           !Self.htmlTagNames.contains(root), lowered.contains("</\(root)>") {
            return .tree(.xml)
        }
        return nil
    }

    /// The name of the first real element in a lowercased document: the
    /// prolog, comments and a doctype stepped over.
    private static func rootElement(of lowered: String) -> String? {
        var rest = Substring(lowered)
        while let open = rest.firstIndex(of: "<") {
            let after = rest.index(after: open)
            guard after < rest.endIndex else { return nil }
            let head = rest[after...]
            if head.hasPrefix("?") || head.hasPrefix("!") {
                // A prolog, a comment or a doctype: step past its own close.
                guard let close = rest[after...].firstIndex(of: ">") else { return nil }
                rest = rest[rest.index(after: close)...]
                continue
            }
            let name = head.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            return name.isEmpty ? nil : String(name)
        }
        return nil
    }

    /// The tags a page is made of. Counted by *variety* rather than by how
    /// many there are, so a hundred `<div>`s are still one signal.
    private static let htmlTagNames: Set<String> = [
        "html", "head", "body", "p", "div", "span", "ul", "ol", "li", "a",
        "h1", "h2", "h3", "h4", "h5", "h6", "table", "tr", "td", "script", "style",
    ]

    private static func htmlTagVariety(_ lowered: String) -> Int {
        var found = 0
        for tag in ["<p>", "<p ", "<div", "<ul", "<ol", "<li", "<a href",
                    "<h1", "<h2", "<h3", "<h4", "<h5", "<h6", "<table", "<span"]
        where lowered.contains(tag) {
            found += 1
        }
        return found
    }

    // MARK: - LaTeX

    /// The two lines every document has, or three lines that begin with a
    /// backslash command — which is what a fragment of maths or macros looks
    /// like without a preamble round it.
    private static func isLaTeX(_ lines: [String]) -> Bool {
        let joined = lines.joined(separator: "\n")
        if joined.contains("\\documentclass") || joined.contains("\\begin{document}") {
            return true
        }
        var commands = 0
        for line in lines {
            let head = line.drop { $0 == " " || $0 == "\t" }
            guard head.hasPrefix("\\") else { continue }
            let name = head.dropFirst().prefix { $0.isLetter }
            if !name.isEmpty { commands += 1 }
        }
        return commands >= 3
    }

    // MARK: - SQL

    /// Two statements, spelled the way a dump spells them. One `SELECT` is a
    /// sentence somebody wrote about a query; two lines of them is a file.
    private static let sqlOpeners = ["create table", "insert into", "select", "pragma"]

    private static func isSQL(_ lines: [String]) -> Bool {
        var statements = 0
        for line in lines {
            let head = line.trimmingCharacters(in: .whitespaces).lowercased()
            if Self.sqlOpeners.contains(where: { head.hasPrefix($0) }) { statements += 1 }
        }
        return statements >= 2
    }

    // MARK: - TOML

    /// A table header and two keys under it. The header alone is a Markdown
    /// link's other half; the keys alone are an ini file, a YAML file, or a
    /// line of prose with an equals sign in it.
    private static func isTOML(_ lines: [String]) -> Bool {
        var hasSection = false
        var keys = 0
        for line in lines {
            let head = line.trimmingCharacters(in: .whitespaces)
            if head.hasPrefix("#") { continue }
            if head.hasPrefix("["), head.hasSuffix("]"), head.count > 2 {
                hasSection = true
                continue
            }
            if isKeyValue(head, separator: "=") { keys += 1 }
        }
        return hasSection && keys >= 2
    }

    /// `name = value`, with a bare key on the left. Deliberately narrow: a
    /// sentence with an equals sign in it has spaces in its left half.
    private static func isKeyValue(_ line: String, separator: Character) -> Bool {
        guard let split = line.firstIndex(of: separator) else { return false }
        let key = line[line.startIndex ..< split].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !value.isEmpty else { return false }
        let quoted = key.hasPrefix("\"") && key.hasSuffix("\"")
        return quoted || key.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "."
        }
    }

    // MARK: - YAML

    /// A document marker, or three mapping lines.
    ///
    /// Guarded against Markdown, but not against all of it: a `- ` line and a
    /// `#` comment are YAML's own punctuation as much as Markdown's, so those
    /// two signals are allowed here. The rest — a fence, a link, bold, a
    /// quote, a table row, a task box — are not YAML at all, and one of them
    /// is enough to hand the text on to the Markdown rule below.
    private static func isYAML(_ trimmed: String, lines: [String]) -> Bool {
        guard !hasMarkdownOnlySignals(lines) else { return false }
        if trimmed.hasPrefix("---") { return true }
        var mappings = 0
        for line in lines {
            let head = line.trimmingCharacters(in: .whitespaces)
            if head.hasPrefix("#") { continue }
            guard let colon = head.firstIndex(of: ":") else { continue }
            let key = head[head.startIndex ..< colon]
            let rest = head[head.index(after: colon)...]
            // `key:` alone opens a block; `key: value` is one. `key:value` is
            // neither — YAML wants the space, and prose does not.
            guard rest.isEmpty || rest.hasPrefix(" ") else { continue }
            guard !key.isEmpty, key.allSatisfy({
                $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-"
            }) else { continue }
            mappings += 1
        }
        return mappings >= 3
    }

    // MARK: - CSV

    /// Read as the table it would be. Three records is a header and two rows,
    /// two columns is the least that is a table at all, and every record has
    /// to have written every field — a file where one line has four commas
    /// and the next has none is prose with commas in it.
    private static func isCSV(_ text: String) -> Bool {
        for separator in [CSVTable.Separator.comma, .tab] {
            let table = CSVTable(text: text, separator: separator)
            guard table.columns.count >= 2, table.rows.count >= 2 else { continue }
            guard table.fieldSources.allSatisfy({ $0.count == table.columns.count })
            else { continue }
            return true
        }
        return false
    }

    // MARK: - Markdown

    /// The signals a Markdown document is made of. Any two different ones is
    /// enough; any one of them alone is not, because every one of them is
    /// also something a plain note does — a dash at the start of a line most
    /// of all.
    private enum MarkdownSignal: CaseIterable {
        case heading, list, fence, link, emphasis, quote, table, task

        /// Whether this signal is Markdown's alone. A dash and a hash belong
        /// to YAML as much as to Markdown, so they do not veto YAML above.
        var isMarkdownOnly: Bool {
            switch self {
            case .heading, .list: false
            default: true
            }
        }
    }

    private static func markdownSignals(_ lines: [String]) -> Set<MarkdownSignal> {
        var found: Set<MarkdownSignal> = []
        for line in lines {
            let head = line.trimmingCharacters(in: .whitespaces)
            if head.hasPrefix("#"), head.dropFirst().first == " " { found.insert(.heading) }
            if head.hasPrefix("- [ ]") || head.hasPrefix("- [x]") || head.hasPrefix("- [X]") {
                found.insert(.task)
            }
            if head.hasPrefix("- ") || head.hasPrefix("* ") || head.hasPrefix("+ ") {
                found.insert(.list)
            }
            if head.hasPrefix("> ") { found.insert(.quote) }
            if head.hasPrefix("```") || head.hasPrefix("~~~") { found.insert(.fence) }
            if head.hasPrefix("|"), head.hasSuffix("|"), head.dropFirst().contains("|") {
                found.insert(.table)
            }
            if hasOrderedListMarker(head) { found.insert(.list) }
            if hasInlineLink(head) { found.insert(.link) }
            if hasEmphasis(head) { found.insert(.emphasis) }
        }
        return found
    }

    private static func hasMarkdownOnlySignals(_ lines: [String]) -> Bool {
        markdownSignals(lines).contains { $0.isMarkdownOnly }
    }

    private static func isMarkdown(_ lines: [String]) -> Bool {
        markdownSignals(lines).count >= 2
    }

    /// `1. `, `12) ` — a number, a delimiter and a space.
    private static func hasOrderedListMarker(_ line: String) -> Bool {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty else { return false }
        let rest = line.dropFirst(digits.count)
        guard let delimiter = rest.first, delimiter == "." || delimiter == ")" else { return false }
        return rest.dropFirst().first == " "
    }

    /// `[text](url)`, in that order and with something in both halves.
    private static func hasInlineLink(_ line: String) -> Bool {
        guard let open = line.firstIndex(of: "["),
              let close = line[open...].firstIndex(of: "]"),
              line.index(after: close) < line.endIndex,
              line[line.index(after: close)] == "("
        else { return false }
        let afterParen = line.index(close, offsetBy: 2)
        guard let end = line[afterParen...].firstIndex(of: ")") else { return false }
        return close > line.index(after: open) && end > afterParen
    }

    /// `**bold**` or `_em_`, both halves on the same line.
    private static func hasEmphasis(_ line: String) -> Bool {
        if let first = line.range(of: "**"),
           line[first.upperBound...].contains("**") { return true }
        guard let first = line.firstIndex(of: "_") else { return false }
        let rest = line[line.index(after: first)...]
        // `_em_` and not `snake_case_name`: the opener has to start a word.
        let before = first == line.startIndex
            ? nil : line[line.index(before: first)]
        guard before == nil || before == " " || before == "(" else { return false }
        guard let closing = rest.firstIndex(of: "_"), closing > rest.startIndex else {
            return false
        }
        return true
    }
}
