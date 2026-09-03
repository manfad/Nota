import Foundation

/// The faces a run of LaTeX text can be set in. An option set rather than a
/// single case, because they nest: `\textbf{\texttt{x}}` is both at once, and
/// the render has to know it.
struct LaTeXFace: OptionSet, Hashable {
    let rawValue: Int

    init(rawValue: Int) { self.rawValue = rawValue }

    static let bold = LaTeXFace(rawValue: 1 << 0)
    static let italic = LaTeXFace(rawValue: 1 << 1)
    static let monospaced = LaTeXFace(rawValue: 1 << 2)
    static let underline = LaTeXFace(rawValue: 1 << 3)
    static let smallCaps = LaTeXFace(rawValue: 1 << 4)
}

/// A grey placeholder standing in for machinery Nota does not run: a
/// bibliography, a cross-reference, a page number. The key is shown because
/// the key is the only true thing there is to show — resolving one would mean
/// being TeX, and this is a reading layout, not a typesetter.
enum LaTeXPlaceholder: Equatable {
    /// `\cite{knuth}` → `[knuth]`.
    case citation(String)
    /// `\ref` `\eqref` `\pageref` → `(sec:intro)`.
    case reference(String)
}

/// One piece of running text, and exactly where in the note it came from.
///
/// Every node carries its own `NSRange` in the source, in UTF-16 offsets as
/// `NSString` measures them, so nothing downstream ever has to search the
/// note for a piece of itself — which is the whole reason the LaTeX render
/// has exact block sync where the Markdown one has a source map.
indirect enum LaTeXInline {
    case text(String, NSRange)
    case face(LaTeXFace, [LaTeXInline], NSRange)
    case math(tex: String, display: Bool, NSRange)
    case placeholder(LaTeXPlaceholder, NSRange)
    case link(url: String, text: [LaTeXInline], NSRange)
    case footnote([LaTeXInline], NSRange)
    case image(path: String, NSRange)
    /// `\\` and `\newline`: a break inside a paragraph, not between two.
    case lineBreak(NSRange)
    /// A command the subset has never heard of, kept exactly as it was
    /// written — braces, brackets and all.
    case unknown(String, NSRange)

    var source: NSRange {
        switch self {
        case .text(_, let range), .face(_, _, let range), .math(_, _, let range),
             .placeholder(_, let range), .link(_, _, let range), .footnote(_, let range),
             .image(_, let range), .lineBreak(let range), .unknown(_, let range):
            return range
        }
    }
}

/// One block of the document, flattened out of the source's nesting.
///
/// Flat on purpose: a rendered block is a contiguous run of the pane's text
/// with one source range, so a list item inside a quote inside a figure is one
/// block that happens to know how deep it sits, not a tree the render has to
/// walk twice.
struct LaTeXBlock {
    enum Kind {
        /// `\maketitle`, with whatever the preamble gave it.
        case title(title: [LaTeXInline], author: [LaTeXInline], date: [LaTeXInline])
        /// The word `Abstract` over an `abstract` environment.
        case abstractTitle
        /// 1 = `\section` … 4 = `\paragraph`. `number` is `nil` for the
        /// starred forms, which are unnumbered.
        case heading(level: Int, number: String?, content: [LaTeXInline])
        case paragraph([LaTeXInline])
        /// One item, or a paragraph continuing the one above it (`marker` is
        /// `nil` there, the way the Markdown render marks only an item's
        /// first paragraph).
        case listItem(depth: Int, marker: String?, term: [LaTeXInline], content: [LaTeXInline])
        /// A display formula. One per row of an `align`, each numbered in its
        /// own right unless the environment is starred.
        case math(tex: String, number: Int?)
        /// `verbatim`, `lstlisting`, `minted` — the contents exactly as
        /// written.
        case code(String)
        case table(rows: [[[LaTeXInline]]])
        /// `Figure 1:` / `Table 2:` and what follows it.
        case caption(label: String, content: [LaTeXInline])
        /// An environment the subset has never heard of, whole.
        case unknown(String)
    }

    var kind: Kind
    /// Where this block is in the note, exactly.
    var source: NSRange
    /// How many `quote` / `quotation` environments it sits inside.
    var quoteDepth = 0
    /// Whether a `center` environment holds it.
    var isCentred = false
}

/// A parsed `.tex` file: the title fields the preamble gave up, and the body
/// as blocks.
struct LaTeXDocument {
    var title: [LaTeXInline] = []
    var author: [LaTeXInline] = []
    var date: [LaTeXInline] = []
    var blocks: [LaTeXBlock] = []
}

/// A LaTeX subset, read into blocks.
///
/// Article level, as the spec has it: the preamble renders nothing and only
/// gives up its title fields, the body is sections and paragraphs and lists
/// and maths, and anything the subset has never heard of comes through as the
/// raw source it was. It never throws and never fails — a half-typed command,
/// an unbalanced brace, a `\begin` with no `\end` all have an answer, because
/// the pane re-renders on every keystroke and a note being typed is a note
/// half way through everything.
///
/// It works in UTF-16 code units rather than characters, because every range
/// it hands out has to be the one `NSString` would measure — the ranges are
/// what the editor beside it is indexed by.
struct LaTeXParser {

    /// How deep the environments and groups may nest before the parser stops
    /// following them down and shows the rest as itself. Deep enough for any
    /// real document, shallow enough that a pathological file cannot run the
    /// stack out.
    static let maximumDepth = 24

    private let units: [UInt16]

    /// Where the numbering stands. Sections, and the equations, figures and
    /// tables that number themselves as they go past.
    private var sectionCounters = [0, 0, 0]
    private var equationCounter = 0
    private var figureCounter = 0
    private var tableCounter = 0

    private var document = LaTeXDocument()

    private init(_ source: String) {
        units = Array(source.utf16)
    }

    /// Reads a `.tex` file. Total: every input has an answer.
    static func parse(_ source: String) -> LaTeXDocument {
        var parser = LaTeXParser(source)
        parser.run()
        return parser.document
    }

    private mutating func run() {
        readTitleFields()
        let body = bodyRegion()
        document.blocks = parseBlocks(
            from: body.lowerBound, to: body.upperBound, depth: 0, listDepth: 0
        )
    }

    // MARK: - Reading the units

    private func unit(_ position: Int) -> UInt16? {
        position >= 0 && position < units.count ? units[position] : nil
    }

    private func matches(_ position: Int, _ character: Unicode.Scalar) -> Bool {
        unit(position) == UInt16(character.value)
    }

    private func matches(_ position: Int, _ word: String) -> Bool {
        let wanted = Array(word.utf16)
        guard position >= 0, position + wanted.count <= units.count else { return false }
        for (offset, code) in wanted.enumerated() where units[position + offset] != code {
            return false
        }
        return true
    }

    private func text(_ range: Range<Int>) -> String {
        let clamped = max(0, range.lowerBound) ..< min(units.count, max(0, range.upperBound))
        guard clamped.lowerBound < clamped.upperBound else { return "" }
        return String(decoding: units[clamped], as: UTF16.self)
    }

    private func range(_ from: Int, _ to: Int) -> NSRange {
        NSRange(location: from, length: max(0, to - from))
    }

    private func isLetter(_ position: Int) -> Bool {
        guard let code = unit(position) else { return false }
        return (code >= 65 && code <= 90) || (code >= 97 && code <= 122)
    }

    private func isSpace(_ position: Int) -> Bool {
        guard let code = unit(position) else { return false }
        return code == 32 || code == 9 || code == 10 || code == 13 || code == 12
    }

    private func isNewline(_ position: Int) -> Bool {
        guard let code = unit(position) else { return false }
        return code == 10 || code == 13
    }

    /// A `%` that is a comment rather than a percent sign — the one before it
    /// is not a backslash, or is itself escaped.
    private func isComment(_ position: Int) -> Bool {
        guard matches(position, "%") else { return false }
        var backslashes = 0
        var scan = position - 1
        while scan >= 0, matches(scan, "\\") {
            backslashes += 1
            scan -= 1
        }
        return backslashes % 2 == 0
    }

    /// Past a comment, stopping on the newline that ends it — the break
    /// itself is kept, so a comment on its own line still parts two
    /// paragraphs.
    private func endOfComment(_ position: Int) -> Int {
        var scan = position
        while scan < units.count, !isNewline(scan) { scan += 1 }
        return scan
    }

    /// The command name at a backslash, and where it ends. A name is letters,
    /// or the single character that follows the backslash when it is not one
    /// — `\\`, `\,`, `\%` are all commands with one-character names.
    private func command(at position: Int) -> (name: String, end: Int)? {
        guard matches(position, "\\") else { return nil }
        var scan = position + 1
        guard scan < units.count else { return (name: "", end: scan) }
        guard isLetter(scan) else { return (name: text(scan ..< scan + 1), end: scan + 1) }
        while isLetter(scan) { scan += 1 }
        // `\section*` is the same command asking not to be numbered, so the
        // star belongs to the name rather than to the text after it.
        if matches(scan, "*") { return (name: text(position + 1 ..< scan) + "*", end: scan + 1) }
        return (name: text(position + 1 ..< scan), end: scan)
    }

    // MARK: - Arguments

    /// A `{…}` argument starting at or after `position`, with the braces
    /// balanced. `nil` when there is no group there: a command whose argument
    /// is missing keeps whatever it has rather than swallowing the document.
    private func group(after position: Int) -> (inner: Range<Int>, end: Int)? {
        var scan = position
        while scan < units.count, isSpace(scan), !isParagraphBreak(scan) { scan += 1 }
        guard matches(scan, "{") else { return nil }
        var depth = 0
        var cursor = scan
        while cursor < units.count {
            if matches(cursor, "\\") { cursor += 2; continue }
            if matches(cursor, "{") { depth += 1 }
            if matches(cursor, "}") {
                depth -= 1
                if depth == 0 { return (inner: scan + 1 ..< cursor, end: cursor + 1) }
            }
            cursor += 1
        }
        // An unclosed brace: everything left is the argument, which is what a
        // note being typed into looks like.
        return (inner: scan + 1 ..< units.count, end: units.count)
    }

    /// The same for a `[…]` option list.
    private func option(after position: Int) -> (inner: Range<Int>, end: Int)? {
        var scan = position
        while scan < units.count, isSpace(scan), !isParagraphBreak(scan) { scan += 1 }
        guard matches(scan, "[") else { return nil }
        var depth = 0
        var cursor = scan
        while cursor < units.count {
            if matches(cursor, "\\") { cursor += 2; continue }
            if matches(cursor, "[") { depth += 1 }
            if matches(cursor, "]") {
                depth -= 1
                if depth == 0 { return (inner: scan + 1 ..< cursor, end: cursor + 1) }
            }
            cursor += 1
        }
        return nil
    }

    /// Everything a command took with it — options and groups, in whatever
    /// order they came. What an unknown command has to swallow so that
    /// `\foo{bar}` shows as `\foo{bar}` and not as `\foo` followed by the
    /// word `bar`.
    private func arguments(after position: Int) -> Int {
        var scan = position
        while scan < units.count {
            var probe = scan
            // Across spaces, never across a line: a group on the next line is
            // the next sentence's, not this command's.
            while probe < units.count, matches(probe, " ") || matches(probe, "\t") { probe += 1 }
            if let group = group(after: probe) {
                scan = group.end
            } else if let option = option(after: probe) {
                scan = option.end
            } else {
                return scan
            }
        }
        return scan
    }

    /// Whether a blank line starts here — the one thing that ends a paragraph.
    private func isParagraphBreak(_ position: Int) -> Bool {
        guard isNewline(position) else { return false }
        var scan = position
        var newlines = 0
        while scan < units.count, isSpace(scan) {
            if matches(scan, "\n") { newlines += 1 }
            if newlines >= 2 { return true }
            scan += 1
        }
        return false
    }

    // MARK: - The preamble

    /// `\title` `\author` `\date`, wherever they are. They are read from the
    /// whole file rather than from the preamble alone, since a document is
    /// perfectly entitled to set its title after `\begin{document}` and
    /// before `\maketitle` — and `\maketitle` has to have them by then.
    private mutating func readTitleFields() {
        var scan = 0
        while scan < units.count {
            if isComment(scan) {
                scan = endOfComment(scan)
                continue
            }
            guard matches(scan, "\\"), let command = command(at: scan) else {
                scan += 1
                continue
            }
            switch command.name {
            case "title", "author", "date":
                guard let group = group(after: command.end) else {
                    scan = command.end
                    continue
                }
                let content = parseInline(from: group.inner.lowerBound, to: group.inner.upperBound,
                                          depth: 1)
                switch command.name {
                case "title": document.title = content
                case "author": document.author = content
                default: document.date = content
                }
                scan = group.end
            default:
                scan = max(command.end, scan + 1)
            }
        }
    }

    /// What actually renders. Everything before `\begin{document}` is the
    /// preamble and renders nothing; a file with no `\begin{document}` is a
    /// fragment, and the whole of it is body.
    private func bodyRegion() -> Range<Int> {
        var scan = 0
        while scan < units.count {
            if isComment(scan) {
                scan = endOfComment(scan)
                continue
            }
            if matches(scan, "\\"), matches(scan, "\\begin"),
               let group = group(after: scan + 6), text(group.inner) == "document" {
                let end = endOfEnvironment(named: "document", from: group.end) ?? units.count
                return group.end ..< end
            }
            scan += 1
        }
        return 0 ..< units.count
    }

    /// Where the matching `\end{name}` starts, counting the nested
    /// `\begin{name}`s on the way. `nil` when there is none — an environment
    /// that was opened and never closed runs to the end of what it is in.
    private func endOfEnvironment(named name: String, from position: Int) -> Int? {
        var scan = position
        var depth = 1
        while scan < units.count {
            if isComment(scan) {
                scan = endOfComment(scan)
                continue
            }
            guard matches(scan, "\\") else {
                scan += 1
                continue
            }
            if matches(scan, "\\begin"), let group = group(after: scan + 6),
               text(group.inner) == name {
                depth += 1
                scan = group.end
                continue
            }
            if matches(scan, "\\end"), let group = group(after: scan + 4),
               text(group.inner) == name {
                depth -= 1
                if depth == 0 { return scan }
                scan = group.end
                continue
            }
            scan += max(1, (command(at: scan)?.end ?? scan + 1) - scan)
        }
        return nil
    }

    /// The same, without looking through the contents at all: what a
    /// `verbatim` needs, where a `%` is a percent sign and a `\begin` is four
    /// letters someone typed.
    private func endOfVerbatim(named name: String, from position: Int) -> Int? {
        let closing = "\\end{" + name + "}"
        var scan = position
        while scan < units.count {
            if matches(scan, closing) { return scan }
            scan += 1
        }
        return nil
    }

    // MARK: - Blocks

    /// The block loop over one region — the body, an environment's contents,
    /// a list item's. Everything that makes a block is decided here; what a
    /// block is made *of* is `parseInline`'s business.
    private mutating func parseBlocks(
        from start: Int, to end: Int, depth: Int, listDepth: Int,
        quoteDepth: Int = 0, isCentred: Bool = false
    ) -> [LaTeXBlock] {
        guard depth < Self.maximumDepth else {
            let raw = text(start ..< end).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return [] }
            return [LaTeXBlock(kind: .unknown(raw), source: range(start, end))]
        }

        var blocks: [LaTeXBlock] = []
        var scan = start
        while scan < end {
            if isSpace(scan) {
                scan += 1
                continue
            }
            if isComment(scan) {
                scan = endOfComment(scan)
                continue
            }
            let before = scan
            blocks.append(contentsOf: parseBlock(
                at: &scan, limit: end, depth: depth, listDepth: listDepth,
                quoteDepth: quoteDepth, isCentred: isCentred
            ))
            // Nothing may stand still: a note being typed into is full of
            // half-written commands, and one that consumed nothing would spin
            // here forever.
            if scan <= before { scan = before + 1 }
        }
        return blocks
    }

    /// One block, or the handful an environment unfolds into.
    private mutating func parseBlock(
        at scan: inout Int, limit: Int, depth: Int, listDepth: Int,
        quoteDepth: Int, isCentred: Bool
    ) -> [LaTeXBlock] {
        func decorate(_ blocks: [LaTeXBlock]) -> [LaTeXBlock] {
            blocks.map { block in
                var block = block
                block.quoteDepth = max(block.quoteDepth, quoteDepth)
                block.isCentred = block.isCentred || isCentred
                return block
            }
        }

        if matches(scan, "\\"), let command = command(at: scan) {
            switch command.name {
            case "begin":
                return decorate(parseEnvironment(
                    at: &scan, limit: limit, depth: depth, listDepth: listDepth,
                    quoteDepth: quoteDepth, isCentred: isCentred
                ))
            case "end":
                // Region-bounded, so a stray `\end` belongs to nothing.
                scan = group(after: command.end)?.end ?? command.end
                return []
            case "maketitle":
                let block = LaTeXBlock(
                    kind: .title(title: document.title, author: document.author,
                                 date: document.date),
                    source: range(scan, command.end)
                )
                scan = command.end
                return decorate([block])
            case "section", "section*", "subsection", "subsection*",
                 "subsubsection", "subsubsection*", "paragraph", "paragraph*",
                 "subparagraph", "subparagraph*":
                return decorate([heading(command, at: &scan)])
            case "[":
                let block = displayMath(at: &scan, limit: limit, closing: "\\]", numbered: false)
                return decorate([block])
            case "title", "author", "date":
                // Already taken, and they render nothing where they stand.
                scan = arguments(after: command.end)
                return []
            default:
                break
            }
        }

        // Everything else is running text, up to the blank line or the block
        // command that ends it.
        var end = blockContentEnd(from: scan, limit: limit)
        if end <= scan {
            // A block command standing where no block of its own can be — a
            // stray `\item`, a `\caption` outside a float. It is read as the
            // text it is, so the loop always moves on.
            let past = min(limit, max(command(at: scan)?.end ?? scan + 1, scan + 1))
            end = max(past, blockContentEnd(from: past, limit: limit))
        }
        let content = parseInline(from: scan, to: end, depth: depth + 1)
        let source = trimmedRange(scan, end)
        scan = end
        guard !content.isEmpty, source.length > 0 else { return [] }
        let kind: LaTeXBlock.Kind = listDepth > 0
            ? .listItem(depth: listDepth, marker: nil, term: [], content: content)
            : .paragraph(content)
        return decorate([LaTeXBlock(kind: kind, source: source)])
    }

    private mutating func heading(
        _ command: (name: String, end: Int), at scan: inout Int
    ) -> LaTeXBlock {
        let start = scan
        let isStarred = command.name.hasSuffix("*")
        let base = isStarred ? String(command.name.dropLast()) : command.name
        let level: Int
        switch base {
        case "section": level = 1
        case "subsection": level = 2
        case "subsubsection": level = 3
        default: level = 4
        }
        // A `\section[short]{long}` gives its short form to the table of
        // contents; the long one is the heading.
        var cursor = command.end
        if let option = option(after: cursor) { cursor = option.end }
        let group = group(after: cursor)
        let content = group.map {
            parseInline(from: $0.inner.lowerBound, to: $0.inner.upperBound, depth: 1)
        } ?? []
        scan = group?.end ?? cursor

        var number: String?
        if !isStarred, level <= 3 {
            sectionCounters[level - 1] += 1
            for deeper in level ..< 3 { sectionCounters[deeper] = 0 }
            number = sectionCounters[0 ..< level].map(String.init).joined(separator: ".")
        }
        return LaTeXBlock(
            kind: .heading(level: level, number: number, content: content),
            source: range(start, scan)
        )
    }

    /// Where the running text starting here stops: at a blank line, at the
    /// next thing that is a block in its own right, or at the end of the
    /// region. Braces are counted, so a `\section` inside a group is text
    /// like anything else inside one.
    private func blockContentEnd(from start: Int, limit: Int) -> Int {
        var scan = start
        var braces = 0
        while scan < limit {
            if isComment(scan) {
                scan = endOfComment(scan)
                continue
            }
            if braces == 0, isParagraphBreak(scan) { return scan }
            if matches(scan, "{") { braces += 1 }
            if matches(scan, "}") { braces = max(0, braces - 1) }
            if matches(scan, "$") {
                // A `$…$` is a region of its own; nothing in it is a block.
                scan = endOfInlineMath(from: scan)
                continue
            }
            guard matches(scan, "\\"), let command = command(at: scan) else {
                scan += 1
                continue
            }
            if command.name == "verb" || command.name == "verb*",
               let verb = endOfVerb(from: command.end) {
                scan = verb.end
                continue
            }
            if braces == 0, Self.blockCommands.contains(command.name) { return scan }
            scan = max(command.end, scan + 1)
        }
        return limit
    }

    /// The commands that end a paragraph by starting something else.
    private static let blockCommands: Set<String> = [
        "begin", "end", "item", "caption", "maketitle", "[",
        "section", "section*", "subsection", "subsection*",
        "subsubsection", "subsubsection*", "paragraph", "paragraph*",
        "subparagraph", "subparagraph*",
    ]

    /// A region with the whitespace taken off both ends, so a block's range
    /// is the block and not the air around it — and so no node ever carries a
    /// range wider than the characters it was made from.
    private func trimmed(_ start: Int, _ end: Int) -> (start: Int, end: Int) {
        var from = max(0, start)
        var to = min(end, units.count)
        while from < to, isSpace(from) { from += 1 }
        while to > from, isSpace(to - 1) { to -= 1 }
        return (from, to)
    }

    private func trimmedRange(_ start: Int, _ end: Int) -> NSRange {
        let region = trimmed(start, end)
        return range(region.start, region.end)
    }

    // MARK: - Environments

    private mutating func parseEnvironment(
        at scan: inout Int, limit: Int, depth: Int, listDepth: Int,
        quoteDepth: Int, isCentred: Bool
    ) -> [LaTeXBlock] {
        let start = scan
        guard let nameGroup = group(after: scan + 6) else {
            scan += 6
            return []
        }
        let name = text(nameGroup.inner)
        let isVerbatim = Self.codeEnvironments.contains(name)
        let closing = isVerbatim
            ? endOfVerbatim(named: name, from: nameGroup.end)
            : endOfEnvironment(named: name, from: nameGroup.end)
        let bodyEnd = min(closing ?? limit, limit)
        // Past the whole `\begin{x}…\end{x}`, closing brace included.
        let whole: Int
        if let closing, closing < limit {
            whole = min(limit, group(after: closing + 4)?.end ?? closing)
        } else {
            whole = limit
        }
        defer { scan = max(whole, start + 1) }

        // `\begin{minted}{python}` and `\begin{lstlisting}[…]` take arguments
        // between the name and the contents.
        var bodyStart = nameGroup.end
        if !isVerbatim || name == "minted" || name == "lstlisting" {
            if let option = option(after: bodyStart), option.end <= bodyEnd {
                bodyStart = option.end
            }
            if name == "minted", let group = group(after: bodyStart), group.end <= bodyEnd {
                bodyStart = group.end
            }
        }

        if isVerbatim {
            var code = text(bodyStart ..< bodyEnd)
            while code.hasPrefix("\n") || code.hasPrefix("\r") { code.removeFirst() }
            while let last = code.last, last == "\n" || last == "\r" { code.removeLast() }
            return [LaTeXBlock(kind: .code(code), source: range(start, whole))]
        }

        switch name {
        case "document":
            return parseBlocks(from: bodyStart, to: bodyEnd, depth: depth + 1,
                               listDepth: listDepth, quoteDepth: quoteDepth,
                               isCentred: isCentred)
        case "abstract":
            var blocks = [LaTeXBlock(kind: .abstractTitle, source: range(start, nameGroup.end))]
            blocks.append(contentsOf: parseBlocks(
                from: bodyStart, to: bodyEnd, depth: depth + 1, listDepth: listDepth,
                quoteDepth: quoteDepth, isCentred: isCentred
            ))
            return blocks
        case "quote", "quotation", "verse":
            return parseBlocks(from: bodyStart, to: bodyEnd, depth: depth + 1,
                               listDepth: listDepth, quoteDepth: quoteDepth + 1,
                               isCentred: isCentred)
        case "center", "centering", "flushleft", "flushright":
            return parseBlocks(from: bodyStart, to: bodyEnd, depth: depth + 1,
                               listDepth: listDepth, quoteDepth: quoteDepth,
                               isCentred: name == "center" || name == "centering")
        case "itemize", "enumerate", "description":
            return parseList(kind: name, from: bodyStart, to: bodyEnd,
                             depth: depth + 1, listDepth: listDepth + 1,
                             quoteDepth: quoteDepth, isCentred: isCentred)
        case "figure", "figure*", "table", "table*":
            return parseFloat(name: name, from: bodyStart, to: bodyEnd, depth: depth + 1,
                              listDepth: listDepth, quoteDepth: quoteDepth,
                              isCentred: isCentred)
        case "tabular", "tabular*", "array", "longtable":
            var contentStart = bodyStart
            if name == "tabular*", let group = group(after: contentStart), group.end <= bodyEnd {
                contentStart = group.end
            }
            // The column spec — `{|l|c|r|}` — says nothing a reading layout
            // can use, so it is read past rather than read.
            if let group = group(after: contentStart), group.end <= bodyEnd {
                contentStart = group.end
            }
            return [parseTabular(from: contentStart, to: bodyEnd,
                                 source: range(start, whole), depth: depth + 1)]
        case _ where Self.mathEnvironments.contains(name):
            return parseMathEnvironment(name: name, from: bodyStart, to: bodyEnd,
                                        source: range(start, whole))
        default:
            let raw = text(start ..< whole).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return [] }
            return [LaTeXBlock(kind: .unknown(raw), source: range(start, whole))]
        }
    }

    private static let codeEnvironments: Set<String> = [
        "verbatim", "verbatim*", "Verbatim", "lstlisting", "minted", "alltt",
    ]

    private static let mathEnvironments: Set<String> = [
        "equation", "equation*", "displaymath", "align", "align*", "alignat", "alignat*",
        "gather", "gather*", "multline", "multline*", "eqnarray", "eqnarray*", "flalign",
        "flalign*",
    ]

    // MARK: - Lists

    private mutating func parseList(
        kind: String, from start: Int, to end: Int, depth: Int, listDepth: Int,
        quoteDepth: Int, isCentred: Bool
    ) -> [LaTeXBlock] {
        guard depth < Self.maximumDepth else { return [] }
        var blocks: [LaTeXBlock] = []
        var counter = 0
        var scan = start
        while scan < end {
            if isSpace(scan) {
                scan += 1
                continue
            }
            if isComment(scan) {
                scan = endOfComment(scan)
                continue
            }
            let before = scan
            if matches(scan, "\\"), let command = command(at: scan), command.name == "item" {
                let itemStart = scan
                var cursor = command.end
                var term: [LaTeXInline] = []
                if let label = option(after: cursor) {
                    term = parseInline(from: label.inner.lowerBound, to: label.inner.upperBound,
                                       depth: depth + 1)
                    cursor = label.end
                }
                counter += 1
                let contentEnd = blockContentEnd(from: cursor, limit: end)
                let content = parseInline(from: cursor, to: contentEnd, depth: depth + 1)
                let marker: String?
                switch kind {
                case "enumerate": marker = "\(counter)."
                case "description": marker = term.isEmpty ? "•" : nil
                default: marker = "•"
                }
                blocks.append(LaTeXBlock(
                    kind: .listItem(depth: listDepth, marker: marker, term: term,
                                    content: content),
                    source: trimmedRange(itemStart, contentEnd),
                    quoteDepth: quoteDepth, isCentred: isCentred
                ))
                scan = contentEnd
            } else {
                blocks.append(contentsOf: parseBlock(
                    at: &scan, limit: end, depth: depth, listDepth: listDepth,
                    quoteDepth: quoteDepth, isCentred: isCentred
                ))
            }
            if scan <= before { scan = before + 1 }
        }
        return blocks
    }

    // MARK: - Figures and tables

    /// A `figure` or a `table`: the blocks inside it, with `\caption` turned
    /// into the numbered line under them.
    private mutating func parseFloat(
        name: String, from start: Int, to end: Int, depth: Int, listDepth: Int,
        quoteDepth: Int, isCentred: Bool
    ) -> [LaTeXBlock] {
        guard depth < Self.maximumDepth else { return [] }
        let isFigure = name.hasPrefix("figure")
        var blocks: [LaTeXBlock] = []
        var scan = start
        while scan < end {
            if isSpace(scan) {
                scan += 1
                continue
            }
            if isComment(scan) {
                scan = endOfComment(scan)
                continue
            }
            let before = scan
            if matches(scan, "\\"), let command = command(at: scan), command.name == "caption" {
                let captionStart = scan
                var cursor = command.end
                if let option = option(after: cursor) { cursor = option.end }
                let group = group(after: cursor)
                let content = group.map {
                    parseInline(from: $0.inner.lowerBound, to: $0.inner.upperBound,
                                depth: depth + 1)
                } ?? []
                scan = group?.end ?? cursor
                if isFigure { figureCounter += 1 } else { tableCounter += 1 }
                let label = isFigure ? "Figure \(figureCounter):" : "Table \(tableCounter):"
                blocks.append(LaTeXBlock(
                    kind: .caption(label: label, content: content),
                    source: trimmedRange(captionStart, scan),
                    quoteDepth: quoteDepth, isCentred: isCentred
                ))
            } else {
                blocks.append(contentsOf: parseBlock(
                    at: &scan, limit: end, depth: depth, listDepth: listDepth,
                    quoteDepth: quoteDepth, isCentred: isCentred
                ))
            }
            if scan <= before { scan = before + 1 }
        }
        return blocks
    }

    /// `tabular`, best effort like the Markdown table: rows parted by `\\`,
    /// cells by `&`, and the rules thrown away — a reading layout lines the
    /// columns up as text rather than drawing a grid.
    private mutating func parseTabular(
        from start: Int, to end: Int, source: NSRange, depth: Int
    ) -> LaTeXBlock {
        var rows: [[[LaTeXInline]]] = []
        for row in split(from: start, to: end, on: .rowBreak) {
            var cells: [[LaTeXInline]] = []
            for cell in split(from: row.lowerBound, to: row.upperBound, on: .cell) {
                cells.append(parseInline(from: cell.lowerBound, to: cell.upperBound,
                                         depth: depth + 1))
            }
            // A row that is nothing but an `\hline` is a rule, and a reading
            // layout has no rules to draw.
            let isEmpty = cells.allSatisfy { $0.isEmpty }
            if !isEmpty { rows.append(cells) }
        }
        return LaTeXBlock(kind: .table(rows: rows), source: source)
    }

    private enum Separator {
        case rowBreak, cell
    }

    /// The regions between the `\\`s of a table or the `&`s of a row, at
    /// brace depth zero so a `\\` inside a cell's own group stays in it.
    private func split(from start: Int, to end: Int, on separator: Separator) -> [Range<Int>] {
        var pieces: [Range<Int>] = []
        var pieceStart = start
        var braces = 0
        var scan = start
        while scan < end {
            if isComment(scan) {
                scan = endOfComment(scan)
                continue
            }
            if matches(scan, "{") { braces += 1 }
            if matches(scan, "}") { braces = max(0, braces - 1) }
            if matches(scan, "$") {
                scan = endOfInlineMath(from: scan)
                continue
            }
            if braces == 0, separator == .cell, matches(scan, "&"), !matches(scan - 1, "\\") {
                pieces.append(pieceStart ..< scan)
                pieceStart = scan + 1
                scan += 1
                continue
            }
            if braces == 0, separator == .rowBreak, matches(scan, "\\\\") {
                pieces.append(pieceStart ..< scan)
                var after = scan + 2
                if let option = option(after: after) { after = option.end }
                pieceStart = after
                scan = after
                continue
            }
            guard matches(scan, "\\"), let command = command(at: scan) else {
                scan += 1
                continue
            }
            scan = max(command.end, scan + 1)
        }
        if pieceStart < end { pieces.append(pieceStart ..< end) }
        return pieces
    }

    // MARK: - Maths

    /// A `\[…\]`, and the shape every display formula ends up in.
    private mutating func displayMath(
        at scan: inout Int, limit: Int, closing: String, numbered: Bool
    ) -> LaTeXBlock {
        let start = scan
        let bodyStart = scan + 2
        var cursor = bodyStart
        while cursor < limit, !matches(cursor, closing) { cursor += 1 }
        let bodyEnd = min(cursor, limit)
        scan = min(limit, cursor < limit ? cursor + 2 : limit)
        var number: Int?
        if numbered {
            equationCounter += 1
            number = equationCounter
        }
        return LaTeXBlock(
            kind: .math(tex: cleanedMath(bodyStart ..< bodyEnd), number: number),
            source: range(start, scan)
        )
    }

    /// `equation` and friends. An `align` is rows, and each row is a display
    /// formula of its own with its own number — which is also what makes each
    /// one its own block for the caret to light.
    private mutating func parseMathEnvironment(
        name: String, from start: Int, to end: Int, source: NSRange
    ) -> [LaTeXBlock] {
        let isStarred = name.hasSuffix("*")
        let base = isStarred ? String(name.dropLast()) : name
        let splitsRows = base != "equation" && base != "displaymath"
        // A `multline` is one equation broken over lines and numbered once,
        // at the end; every other multi-row environment numbers each row.
        let numbersEveryRow = base != "multline"

        let rows = splitsRows
            ? split(from: start, to: end, on: .rowBreak)
            : [start ..< end]
        var blocks: [LaTeXBlock] = []
        for (position, row) in rows.enumerated() {
            let tex = cleanedMath(row)
            guard !tex.isEmpty else { continue }
            let isLast = position == rows.count - 1
            var number: Int?
            if !isStarred, !hasNoNumber(row), numbersEveryRow || isLast {
                equationCounter += 1
                number = equationCounter
            }
            blocks.append(LaTeXBlock(
                kind: .math(tex: tex, number: number),
                // One row: the environment itself, so a click lands on the
                // `\begin`. Several: each row's own line.
                source: rows.count == 1 ? source : trimmedRange(row.lowerBound, row.upperBound)
            ))
        }
        if blocks.isEmpty {
            blocks.append(LaTeXBlock(kind: .math(tex: "", number: nil), source: source))
        }
        return blocks
    }

    private func hasNoNumber(_ region: Range<Int>) -> Bool {
        let raw = text(region)
        return raw.contains("\\nonumber") || raw.contains("\\notag")
    }

    /// A row as the maths engine wants it: the alignment `&`s dropped, the
    /// `\label` and `\nonumber` bookkeeping dropped, the comments gone.
    private func cleanedMath(_ region: Range<Int>) -> String {
        var result = ""
        var scan = region.lowerBound
        let end = min(region.upperBound, units.count)
        while scan < end {
            if isComment(scan) {
                scan = endOfComment(scan)
                continue
            }
            if matches(scan, "&"), !matches(scan - 1, "\\") {
                result.append(" ")
                scan += 1
                continue
            }
            if matches(scan, "\\"), let command = command(at: scan) {
                switch command.name {
                case "label", "tag":
                    scan = group(after: command.end)?.end ?? command.end
                    continue
                case "nonumber", "notag":
                    scan = command.end
                    continue
                case "\\":
                    result.append(" ")
                    scan += 2
                    continue
                default:
                    result += text(scan ..< command.end)
                    scan = command.end
                    continue
                }
            }
            result += text(scan ..< scan + 1)
            scan += 1
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Past a `\verb|…|`, whatever character it chose as its fence. The
    /// contents are characters and nothing else, so nothing inside is looked
    /// at — which is the whole point of it.
    private func endOfVerb(from position: Int) -> (inner: Range<Int>, end: Int)? {
        var scan = position
        while scan < units.count, matches(scan, " ") || matches(scan, "\t") { scan += 1 }
        guard let fence = unit(scan), !isNewline(scan) else { return nil }
        let contentStart = scan + 1
        var cursor = contentStart
        while cursor < units.count, units[cursor] != fence, !isNewline(cursor) { cursor += 1 }
        guard cursor < units.count, units[cursor] == fence else { return nil }
        return (inner: contentStart ..< cursor, end: cursor + 1)
    }

    /// Past a `$…$` or a `$$…$$`, whichever this is. An unclosed one runs to
    /// the end of what it is in rather than eating the rest of the file: a
    /// note with a `$` being typed into it is a note, not a formula.
    private func endOfInlineMath(from position: Int) -> Int {
        let isDouble = matches(position, "$$")
        var scan = position + (isDouble ? 2 : 1)
        while scan < units.count {
            if matches(scan, "\\") {
                scan += 2
                continue
            }
            if isDouble, matches(scan, "$$") { return scan + 2 }
            if !isDouble, matches(scan, "$") { return scan + 1 }
            scan += 1
        }
        return units.count
    }

    // MARK: - Inline

    /// The running text of one block, with every node's source range in it.
    private mutating func parseInline(
        from regionStart: Int, to regionEnd: Int, depth: Int
    ) -> [LaTeXInline] {
        // The air around a block is the source's own line breaks, not the
        // author's spacing, and a node must never claim source it did not
        // come from — so the region is trimmed before anything reads it.
        let (start, end) = trimmed(regionStart, regionEnd)
        guard depth < Self.maximumDepth else {
            let raw = text(start ..< end)
            return raw.isEmpty ? [] : [.text(raw, range(start, end))]
        }

        var nodes: [LaTeXInline] = []
        var runStart = start
        var run = ""
        var scan = start
        // Whitespace in the source is not whitespace on the page: TeX turns
        // any run of it into one space. It is held rather than written, so a
        // run of it that turns out to be trailing — the end of a block, or
        // the space before a comment that renders nothing — leaves nothing
        // behind at all.
        var pendingSpace = false
        var pendingSpaceStart = start

        func flushRun(_ upTo: Int) {
            guard !run.isEmpty else {
                runStart = upTo
                return
            }
            nodes.append(.text(run, range(runStart, upTo)))
            run = ""
            runStart = upTo
        }
        /// Writes the held space down, now that something real has arrived
        /// after it.
        func absorbSpace() {
            guard pendingSpace else { return }
            pendingSpace = false
            if run.isEmpty { runStart = pendingSpaceStart }
            run.append(" ")
        }

        while scan < end {
            let before = scan
            if isComment(scan) {
                // A comment is not there at all: the words on either side of
                // it are one run, parted by whatever space they already had.
                scan = endOfComment(scan)
                continue
            }
            if isSpace(scan) {
                if !pendingSpace {
                    pendingSpace = true
                    pendingSpaceStart = scan
                }
                scan += 1
                continue
            }
            absorbSpace()
            if matches(scan, "~") {
                run.append("\u{00A0}")
                scan += 1
                continue
            }
            if matches(scan, "---") {
                run.append("—")
                scan += 3
                continue
            }
            if matches(scan, "--") {
                run.append("–")
                scan += 2
                continue
            }
            if matches(scan, "``") {
                run.append("“")
                scan += 2
                continue
            }
            if matches(scan, "''") {
                run.append("”")
                scan += 2
                continue
            }
            if matches(scan, "`") {
                run.append("‘")
                scan += 1
                continue
            }
            if matches(scan, "'") {
                run.append("’")
                scan += 1
                continue
            }
            if matches(scan, "{") {
                flushRun(scan)
                if let group = group(after: scan) {
                    nodes.append(contentsOf: parseInline(
                        from: group.inner.lowerBound, to: min(group.inner.upperBound, end),
                        depth: depth + 1
                    ))
                    scan = min(group.end, end)
                } else {
                    scan += 1
                }
                runStart = scan
                continue
            }
            if matches(scan, "}") {
                scan += 1
                runStart = scan
                continue
            }
            if matches(scan, "$") {
                flushRun(scan)
                let isDouble = matches(scan, "$$")
                let mathEnd = min(endOfInlineMath(from: scan), end)
                let delimiter = isDouble ? 2 : 1
                let inner = (scan + delimiter) ..< max(scan + delimiter, mathEnd - delimiter)
                nodes.append(.math(tex: cleanedMath(inner), display: isDouble,
                                   range(scan, mathEnd)))
                scan = max(mathEnd, scan + 1)
                runStart = scan
                continue
            }
            if matches(scan, "\\") {
                // What a command adds to the run is kept apart until it is
                // known whether there was a run: a `\ldots` that lands in the
                // middle of a sentence belongs to that sentence's range, and
                // one that starts a fresh run begins it at the backslash.
                var addition = ""
                let node = parseCommand(at: &scan, limit: end, depth: depth, run: &addition)
                if let node {
                    flushRun(before)
                    nodes.append(node)
                    runStart = scan
                } else {
                    if run.isEmpty { runStart = before }
                    run += addition
                }
                if scan <= before { scan = before + 1 }
                continue
            }
            run += text(scan ..< scan + 1)
            scan += 1
        }
        flushRun(end)
        return nodes.filter { node in
            if case .text(let string, _) = node { return !string.isEmpty }
            return true
        }
    }

    /// One command inside running text. Returns a node, or nothing when the
    /// command only added characters to the run being built.
    private mutating func parseCommand(
        at scan: inout Int, limit: Int, depth: Int, run: inout String
    ) -> LaTeXInline? {
        let start = scan
        guard let command = command(at: scan) else {
            scan += 1
            return nil
        }
        scan = command.end

        /// The one `{…}` argument a command like `\textbf` takes, parsed.
        func argument() -> (nodes: [LaTeXInline], raw: Range<Int>)? {
            guard let group = group(after: scan), group.end <= limit else { return nil }
            let nodes = parseInline(from: group.inner.lowerBound, to: group.inner.upperBound,
                                    depth: depth + 1)
            scan = group.end
            return (nodes: nodes, raw: group.inner)
        }
        /// The same, kept as the characters it is — a path, a URL, a key.
        func rawArgument() -> String? {
            guard let group = group(after: scan), group.end <= limit else { return nil }
            scan = group.end
            return text(group.inner).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func faced(_ face: LaTeXFace) -> LaTeXInline? {
            guard let argument = argument() else { return literalCommand(start, scan, run: &run) }
            return .face(face, argument.nodes, range(start, scan))
        }

        switch command.name {
        case "textbf", "bf", "textmd", "strong":
            return faced(.bold)
        case "textit", "emph", "it", "textsl":
            return faced(.italic)
        case "texttt", "tt", "lstinline":
            return faced(.monospaced)
        case "verb", "verb*":
            guard let verb = endOfVerb(from: scan), verb.end <= limit else {
                return literalCommand(start, scan, run: &run)
            }
            scan = verb.end
            return .face(.monospaced, [.text(text(verb.inner), range(verb.inner.lowerBound,
                                                                    verb.inner.upperBound))],
                         range(start, scan))
        case "underline", "uline":
            return faced(.underline)
        case "textsc", "sc":
            return faced(.smallCaps)
        case "textrm", "textnormal", "textsf", "mbox", "text":
            return faced([])

        case "\\", "newline", "linebreak", "cr":
            if command.name == "\\" { _ = option(after: scan).map { scan = $0.end } }
            if command.name == "linebreak" { _ = option(after: scan).map { scan = $0.end } }
            return .lineBreak(range(start, scan))

        case "(":
            var cursor = scan
            while cursor < limit, !matches(cursor, "\\)") { cursor += 1 }
            let inner = scan ..< min(cursor, limit)
            scan = min(limit, cursor < limit ? cursor + 2 : limit)
            return .math(tex: cleanedMath(inner), display: false, range(start, scan))
        case "[":
            var cursor = scan
            while cursor < limit, !matches(cursor, "\\]") { cursor += 1 }
            let inner = scan ..< min(cursor, limit)
            scan = min(limit, cursor < limit ? cursor + 2 : limit)
            return .math(tex: cleanedMath(inner), display: true, range(start, scan))

        case "footnote", "footnotetext":
            _ = option(after: scan).map { scan = $0.end }
            guard let argument = argument() else { return literalCommand(start, scan, run: &run) }
            return .footnote(argument.nodes, range(start, scan))

        case "cite", "citep", "citet", "nocite":
            _ = option(after: scan).map { scan = $0.end }
            guard let key = rawArgument() else { return literalCommand(start, scan, run: &run) }
            return .placeholder(.citation(key), range(start, scan))
        case "ref", "eqref", "pageref", "autoref", "cref", "Cref":
            guard let key = rawArgument() else { return literalCommand(start, scan, run: &run) }
            return .placeholder(.reference(key), range(start, scan))
        case "label", "index", "vspace", "hspace", "centering", "noindent",
             "bigskip", "medskip", "smallskip", "hline", "toprule", "midrule",
             "bottomrule", "clearpage", "newpage", "par", "protect", "hfill":
            // Bookkeeping: it renders nothing where it stands.
            scan = arguments(after: scan)
            return nil

        case "url":
            guard let url = rawArgument() else { return literalCommand(start, scan, run: &run) }
            return .link(url: url, text: [], range(start, scan))
        case "href":
            guard let url = rawArgument() else { return literalCommand(start, scan, run: &run) }
            guard let argument = argument() else {
                return .link(url: url, text: [], range(start, scan))
            }
            return .link(url: url, text: argument.nodes, range(start, scan))

        case "includegraphics":
            while let option = option(after: scan), option.end <= limit { scan = option.end }
            guard let path = rawArgument() else { return literalCommand(start, scan, run: &run) }
            return .image(path: path, range(start, scan))

        case "title", "author", "date", "thanks":
            scan = arguments(after: scan)
            return nil

        case "ldots", "dots", "textellipsis":
            run.append("…")
            return nil
        case "LaTeX":
            run.append("LaTeX")
            return nil
        case "TeX":
            run.append("TeX")
            return nil
        case "LaTeXe":
            run.append("LaTeX2ε")
            return nil
        case "today":
            run.append("today")
            return nil
        case ",", ";", ":", " ", "quad", "qquad", "enspace", "thinspace":
            run.append(command.name == "quad" || command.name == "qquad" ? "\u{2003}" : " ")
            return nil
        case "!", "@", "/", "-":
            // Kerning and hyphenation hints: nothing on the page.
            return nil
        case "%", "$", "&", "#", "_", "{", "}":
            run += command.name
            return nil
        case "textbackslash":
            run.append("\\")
            return nil
        case "S":
            run.append("§")
            return nil
        case "P":
            run.append("¶")
            return nil
        case "copyright":
            run.append("©")
            return nil

        default:
            let end = min(arguments(after: scan), limit)
            scan = max(end, command.end)
            return .unknown(text(start ..< scan), range(start, scan))
        }
    }

    /// A known command whose argument never turned up — a `\textbf` with
    /// nothing after it, which is what half a keystroke looks like. It shows
    /// as the letters it is.
    private func literalCommand(_ start: Int, _ end: Int, run: inout String) -> LaTeXInline? {
        run += text(start ..< end)
        return nil
    }
}
