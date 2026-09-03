import Foundation

/// The maths taken out of the source before Foundation's parser sees it.
///
/// That parser has no idea what a dollar means. It reads the `_` in `$a_1$` as
/// the start of an emphasis, the `*` in `$a*b$` as another, and by the time the
/// runs come back the formula has been taken apart and there is no putting it
/// together again. So the maths is found first, on the raw text, and each span
/// swapped for an image token — `![](math://3)` — which is a shape the parser
/// does understand and carries through headings, lists, quotes and tables
/// exactly the way a picture does. `MarkdownRenderer` puts the formula back
/// where the token lands.
///
/// The finding is deliberately timid. A `$` that never closes on its own line,
/// one with whitespace against it, one inside a code span or a fenced block:
/// every one of them stays the text it is. A note being typed into is full of
/// half-written maths, and the worst thing this pass could do is swallow the
/// rest of the note behind a dollar the writer has not finished yet.
enum MarkdownMath {

    /// One formula found in the source.
    struct Span {
        /// The TeX between the delimiters, trimmed — what `MathRenderer` is
        /// asked to lay out.
        let tex: String
        /// The source the token stands for, delimiters and all. It is what
        /// the render shows as a code span when the TeX cannot be read.
        let raw: String
        /// `$$…$$` and a ```` ```math ```` fence are set in display style; a
        /// `$…$` in a sentence is not.
        let isDisplay: Bool
        /// Whether the span was the whole of its paragraph. Those become a
        /// centred block of their own, with a block of their own in the
        /// source map; a `$$` in the middle of a sentence does not.
        var isOwnBlock: Bool
    }

    /// A note with its formulas taken out, and the formulas.
    struct Extraction {
        /// The source with every formula replaced by its token.
        let markdown: String
        /// The formulas, in the order their tokens are numbered.
        let spans: [Span]
    }

    /// The info strings that make a fence a formula rather than code.
    static let fenceLanguages: Set<String> = ["math", "latex", "tex"]

    /// A scheme of Nota's own, the way `nota://` is: it exists so a formula
    /// can ride through the parser as an image and be recognised on the way
    /// out. Nothing ever fetches one.
    private static let scheme = "math://"

    /// Which span an image token stands for, or `nil` for an ordinary picture.
    static func spanIndex(from url: URL) -> Int? {
        let text = url.absoluteString
        guard text.hasPrefix(scheme) else { return nil }
        return Int(text.dropFirst(scheme.count))
    }

    /// Whether a line opens a ```` ```math ```` fence. The source map needs to
    /// know one when it sees it, to find a display block again in the note.
    static func isFormulaFence(_ line: String) -> Bool {
        Fence(opening: line)?.isMath ?? false
    }

    private static func token(_ index: Int) -> String { "![](\(scheme)\(index))" }

    // MARK: - The pass

    /// Walks the note a block at a time, copying code through untouched and
    /// replacing every formula it finds elsewhere with its token.
    static func extract(from markdown: String) -> Extraction {
        guard markdown.contains("$") || markdown.contains("```") || markdown.contains("~~~")
        else { return Extraction(markdown: markdown, spans: []) }

        let lines = markdown.components(separatedBy: "\n")
        var output: [String] = []
        var spans: [Span] = []
        var index = 0
        // Whether an indented block could start here at all, and whether a
        // list is open — four spaces under a list item are its continuation,
        // not code.
        var afterBlank = true
        var inList = false

        while index < lines.count {
            let line = lines[index]

            if isBlank(line) {
                output.append(line)
                afterBlank = true
                index += 1
                continue
            }

            if let fence = Fence(opening: line) {
                var end = index + 1
                while end < lines.count, !fence.closes(lines[end]) { end += 1 }
                let bodyEnd = min(end, lines.count)
                if fence.isMath {
                    let body = index + 1 < bodyEnd
                        ? lines[(index + 1) ..< bodyEnd].joined(separator: "\n")
                        : ""
                    spans.append(Span(
                        tex: trimmed(body), raw: body, isDisplay: true, isOwnBlock: true
                    ))
                    // Blank lines around the token so the paragraph it becomes
                    // is its own, whatever the fence was sitting against.
                    output.append(contentsOf: ["", token(spans.count - 1), ""])
                } else {
                    output.append(contentsOf: lines[index ..< min(end + 1, lines.count)])
                }
                index = min(end + 1, lines.count)
                afterBlank = true
                continue
            }

            if afterBlank, !inList, isIndented(line) {
                var end = index
                while end < lines.count, isIndented(lines[end]) || isBlank(lines[end]) { end += 1 }
                // The blank lines on the end belong to whatever comes next.
                while end > index, isBlank(lines[end - 1]) { end -= 1 }
                output.append(contentsOf: lines[index ..< end])
                index = end
                afterBlank = false
                continue
            }

            // A paragraph is the run of lines up to the next blank one — the
            // furthest a `$$` is ever allowed to reach.
            var end = index + 1
            while end < lines.count, !isBlank(lines[end]), Fence(opening: lines[end]) == nil {
                end += 1
            }
            let paragraph = lines[index ..< end].joined(separator: "\n")
            output.append(contentsOf: substitute(paragraph, into: &spans)
                .components(separatedBy: "\n"))
            for line in lines[index ..< end] { note(line, inList: &inList) }
            index = end
            afterBlank = false
        }

        return Extraction(markdown: output.joined(separator: "\n"), spans: spans)
    }

    /// One paragraph's worth of text with its formulas replaced.
    ///
    /// The code spans come out first and the dollars are read only in the
    /// prose between them. Stepping over a code span as the scan reaches it is
    /// not enough: a `$` that fails to close in the prose would go on looking
    /// and find the one inside `` `$x$` ``, and the sentence would disappear
    /// into a formula. A code span is opaque from both ends, so it is a wall
    /// the scan is never allowed to cross.
    private static func substitute(_ paragraph: String, into spans: inout [Span]) -> String {
        var output = ""
        let before = spans.count

        for segment in segments(of: paragraph) {
            output += segment.isCode ? segment.text : substitute(prose: segment.text, into: &spans)
        }

        // A paragraph that is nothing but one display formula is a block of
        // its own, centred in the pane. One with a sentence around it is not.
        if spans.count == before + 1, spans[before].isDisplay,
           trimmed(output) == token(before) {
            spans[before].isOwnBlock = true
        }
        return output
    }

    /// The paragraph cut into code spans and the prose around them. A run of
    /// N backticks opens a span only a run of exactly N closes; one that never
    /// closes is prose, backticks and all. A `` \` `` is a backtick the writer
    /// meant and opens nothing.
    private static func segments(of paragraph: String) -> [(text: String, isCode: Bool)] {
        let characters = Array(paragraph)
        var segments: [(text: String, isCode: Bool)] = []
        var prose = ""
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character == "\\", index + 1 < characters.count {
                prose.append(character)
                prose.append(characters[index + 1])
                index += 2
                continue
            }
            guard character == "`" else {
                prose.append(character)
                index += 1
                continue
            }

            let length = run(of: "`", in: characters, from: index)
            guard let close = closingRun(of: length, in: characters, from: index + length) else {
                prose.append(contentsOf: characters[index ..< (index + length)])
                index += length
                continue
            }
            if !prose.isEmpty {
                segments.append((prose, false))
                prose = ""
            }
            segments.append((String(characters[index ..< (close + length)]), true))
            index = close + length
        }

        if !prose.isEmpty { segments.append((prose, false)) }
        return segments
    }

    /// One run of prose — no code in it anywhere — with its formulas replaced.
    /// A `\$` is a dollar the writer meant and opens nothing.
    private static func substitute(prose: String, into spans: inout [Span]) -> String {
        let characters = Array(prose)
        var output = ""
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character == "\\", index + 1 < characters.count {
                output.append(character)
                output.append(characters[index + 1])
                index += 2
                continue
            }

            if character == "$", let span = read(from: index, in: characters) {
                spans.append(Span(
                    tex: span.tex, raw: span.raw, isDisplay: span.isDisplay, isOwnBlock: false
                ))
                output += token(spans.count - 1)
                index = span.end
                continue
            }

            output.append(character)
            index += 1
        }
        return output
    }

    /// The formula opening at `start`, or `nil` when the dollar there closes
    /// nothing and is plain text.
    private static func read(
        from start: Int, in characters: [Character]
    ) -> (tex: String, raw: String, isDisplay: Bool, end: Int)? {
        if start + 1 < characters.count, characters[start + 1] == "$" {
            guard let close = displayClose(in: characters, from: start + 2) else { return nil }
            return (
                trimmed(String(characters[(start + 2) ..< close])),
                String(characters[start ..< (close + 2)]),
                true,
                close + 2
            )
        }
        guard let close = inlineClose(in: characters, from: start + 1) else { return nil }
        return (
            trimmed(String(characters[(start + 1) ..< close])),
            String(characters[start ..< (close + 1)]),
            false,
            close + 1
        )
    }

    /// Pandoc's rule, and the one thing keeping prices out of the maths: the
    /// opening dollar has a non-space against it, the closing one has a
    /// non-space against it too, and no digit after it — so `costs $5 and $10
    /// more` is a sentence about money. A close is looked for on the opening
    /// line only, and never past a code span.
    private static func inlineClose(in characters: [Character], from start: Int) -> Int? {
        guard start < characters.count else { return nil }
        let opening = characters[start]
        guard !opening.isWhitespace, opening != "$" else { return nil }

        var index = start
        while index < characters.count {
            let character = characters[index]
            if character == "\n" { return nil }
            if character == "\\" {
                index += 2
                continue
            }
            if character == "$", !characters[index - 1].isWhitespace {
                let after = index + 1 < characters.count ? characters[index + 1] : nil
                if !(after?.isNumber ?? false) { return index }
            }
            index += 1
        }
        return nil
    }

    /// `$$` may run over as many lines as its paragraph has; the paragraph —
    /// or the next code span in it — is where it stops.
    private static func displayClose(in characters: [Character], from start: Int) -> Int? {
        var index = start
        while index + 1 < characters.count {
            if characters[index] == "\\" {
                index += 2
                continue
            }
            if characters[index] == "$", characters[index + 1] == "$" { return index }
            index += 1
        }
        return nil
    }

    // MARK: - Lines and runs

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy(\.isWhitespace)
    }

    /// Four spaces, or a tab — code, when there is no list open for it to be
    /// the continuation of.
    private static func isIndented(_ line: String) -> Bool {
        if line.hasPrefix("\t") { return true }
        return line.prefix(4).allSatisfy { $0 == " " } && line.count > 4
    }

    /// A rough note of whether a list is open, kept only so that an indented
    /// line under one is read as its text rather than as code.
    private static func note(_ line: String, inList: inout Bool) {
        if opensListItem(line) {
            inList = true
        } else if !line.hasPrefix(" "), !line.hasPrefix("\t") {
            inList = false
        }
    }

    private static func opensListItem(_ line: String) -> Bool {
        var rest = Substring(line).drop { $0 == " " }
        guard line.prefix(while: { $0 == " " }).count < 4 else { return false }
        if let first = rest.first, first == "-" || first == "*" || first == "+" {
            return rest.dropFirst().first?.isWhitespace ?? true
        }
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return false }
        rest = rest.dropFirst(digits.count)
        guard let marker = rest.first, marker == "." || marker == ")" else { return false }
        return rest.dropFirst().first?.isWhitespace ?? true
    }

    private static func run(
        of character: Character, in characters: [Character], from start: Int
    ) -> Int {
        var length = 0
        while start + length < characters.count, characters[start + length] == character {
            length += 1
        }
        return length
    }

    /// Where a code span opened by `length` backticks closes — the next run of
    /// exactly that many.
    private static func closingRun(
        of length: Int, in characters: [Character], from start: Int
    ) -> Int? {
        var index = start
        while index < characters.count {
            guard characters[index] == "`" else {
                index += 1
                continue
            }
            let here = run(of: "`", in: characters, from: index)
            if here == length { return index }
            index += here
        }
        return nil
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A fenced block's opening line, and what it takes to close it.
    private struct Fence {
        let marker: Character
        let length: Int
        let isMath: Bool

        init?(opening line: String) {
            guard line.prefix(while: { $0 == " " }).count < 4 else { return nil }
            let rest = Substring(line).drop { $0 == " " }
            guard let first = rest.first, first == "`" || first == "~" else { return nil }
            let length = rest.prefix { $0 == first }.count
            guard length >= 3 else { return nil }
            let info = rest.dropFirst(length)
                .split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            marker = first
            self.length = length
            isMath = MarkdownMath.fenceLanguages.contains(info.lowercased())
        }

        func closes(_ line: String) -> Bool {
            let rest = Substring(line).drop { $0 == " " }
            let length = rest.prefix { $0 == marker }.count
            guard length >= self.length else { return false }
            return rest.dropFirst(length).allSatisfy(\.isWhitespace)
        }
    }
}
