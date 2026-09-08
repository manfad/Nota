import Foundation

/// The two shapes a `.html` file is kept in, and Nota's own walker between
/// them.
///
/// Nothing here goes through `XMLParser`, `NSAttributedString` or WebKit. Each
/// of those answers the question by throwing the page away and building a new
/// one: attributes come back in a different order, `&nbsp;` comes back as a
/// character, a valueless `disabled` grows `="disabled"`, and a page the author
/// had spelled one way arrives spelled another. The corner button replaces the
/// whole note with the result, so the only safe formatter is one that changes
/// the whitespace *between and around* the tags and nothing else — every tag,
/// comment and doctype goes back down as the exact bytes it occupied in the
/// source. Tag names, attribute names, attribute order, attribute quoting and
/// entity spelling all survive both directions, and beautifying a page and
/// minifying it again gives back exactly what minifying alone gives.
///
/// Three questions, all asked of the text and nothing else:
///
/// * `reformat(_:as:)` — the pretty form (two-space indent by nesting, one
///   block-level element to a line, inline elements kept in the line with their
///   text, and a block whose content is nothing but text and inline markup —
///   `<li><a href="/">Home</a></li>`, `<td>1</td>`, an empty `<div></div>` —
///   left on the one line) or the minified one (no whitespace between the tags
///   at all, and the CSS in a `<style>` and the JavaScript in a `<script>`
///   minified too, through `InlineCodeMinify`).
/// * `isPretty(_:)` — which way the button should point: a newline anywhere
///   outside a tag, a comment and a raw-text element means the page is laid
///   out, and so does a stylesheet or a program that still has something to
///   minify — a page on one line whose `<style>` runs down four hundred is not
///   a minified page. The file's own trailing newline counts as neither, since
///   every well-kept text file has it.
/// * `errorLine(in:)` — where the walk gave up, 1-based, for the tool tip on
///   the disabled button.
///
/// HTML is forgiving and so is this: a stray `</section>` nobody opened is not
/// an error, it is emitted where it stands; an element whose end tag the author
/// left out simply stays open to the end of the file and is written back
/// without one. Nothing is ever added and nothing is ever dropped. What the
/// walker really cannot read — an unterminated comment, a tag or a quoted
/// attribute value that runs off the end of the file, a `<script>` that is
/// never closed, nesting past the depth limit — is a `ParseError` naming the
/// line the construct *began* on, because the end of an unterminated thing is
/// the end of the file and its beginning is where the reader has to look.
///
/// Text is re-flowed only as far as collapsing runs of whitespace to one space
/// and trimming a run of text where it meets a block-level tag: words are never
/// joined, never split, and never respelled. Whitespace *inside* an inline
/// element is left where it is, since `<span>a </span><span>b</span>` renders
/// with a space and `<span>a</span><span>b</span>` does not.
///
/// The one thing inside a raw-text element that does move is code, and only
/// under Minify: a `<style>`, and a `<script>` whose `type` says JavaScript or
/// says nothing, are handed to `InlineCodeMinify`, which takes the whitespace
/// and the comments out of them and changes nothing else. A `<pre>`, a
/// `<textarea>`, a `<title>` and a `<script>` carrying anything else — JSON,
/// an import map, a template — go back down byte for byte, and Beautify never
/// touches any of them: a program re-indented by the button would be a
/// different program's worth of diff on every click.
enum HTMLFormat {

    /// Which of the two shapes to write.
    enum Style {
        case pretty, minified
    }

    /// The parse stopped, and this is the line it stopped on — 1-based, the
    /// way an editor counts.
    struct ParseError: Error, Equatable {
        let line: Int
    }

    /// How deep the nesting may go before the page is called malformed. The
    /// writer recurses, and a file made of ten thousand open `<div>`s is a
    /// crash rather than a page.
    private static let depthLimit = 256

    /// The indent one level costs in the pretty form.
    private static let indentUnit = "  "

    // MARK: - The three questions

    /// The same page, laid out the other way. Throws `ParseError` if the text
    /// cannot be read as a page at all.
    ///
    /// The file's trailing newline is kept if it had one: reformatting is not
    /// the moment to take the last line ending off a file.
    static func reformat(_ text: String, as style: Style) throws -> String {
        let bytes = Array(text.utf8)
        var walker = Walker(bytes: bytes)
        let nodes = try walker.parseDocument()
        var lines: [String] = []
        // A rough guess at the answer's size, so the array is not grown a line
        // at a time through a long page.
        lines.reserveCapacity(bytes.count / 32 + 8)
        write(nodes, bytes: bytes, style: style, indent: 0, into: &lines)
        var out = lines.joined(separator: style == .pretty ? "\n" : "")
        if text.hasSuffix("\n") { out += "\n" }
        return out
    }

    /// Whether the page is already laid out in lines: a newline outside a tag,
    /// a comment and a raw-text element, the file's own trailing newline not
    /// counted — or a stylesheet or a program Minify would still change.
    ///
    /// A newline between two attributes is the author's way of keeping a long
    /// tag readable and says nothing about the page's shape; a newline inside a
    /// `<pre>` or a `<title>` belongs to the content and is not ours to read as
    /// layout either. A `<style>` or a JavaScript `<script>` is the one place
    /// the answer is not about newlines at all: the question the button asks is
    /// "is there anything left to minify?", so the minifier is run over the
    /// content and its answer compared with what is there.
    static func isPretty(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var end = bytes.count
        while end > 0, isWhitespace(bytes[end - 1]) { end -= 1 }
        var walker = Walker(bytes: bytes)
        return walker.hasLayoutOrCodeToMinify(before: end)
    }

    /// The 1-based line the walk stopped at, or `nil` for a page that reads.
    static func errorLine(in text: String) -> Int? {
        var walker = Walker(bytes: Array(text.utf8))
        do {
            _ = try walker.parseDocument()
            return nil
        } catch let error as ParseError {
            return error.line
        } catch {
            return nil
        }
    }

    // MARK: - The page

    /// One token or one element. Every payload is the range of source it came
    /// from and nothing else, which is what keeps it spelled the way its author
    /// spelled it.
    private enum Node {
        /// Character data between tags — the only thing whose whitespace moves.
        case text(Range<Int>)
        /// `<!-- … -->`, `<!DOCTYPE …>`, `<! … >`, `<? … >`: verbatim, always
        /// on a line of its own. A comment may be a conditional or a licence,
        /// and which is which is not the formatter's call.
        case comment(Range<Int>)
        case element(Element)
        case raw(RawElement)
        /// An end tag for something nobody opened. Emitted where it stands.
        case strayEnd(name: String, range: Range<Int>)
    }

    /// An ordinary element. A class, so the walker can hang children on it
    /// while it is still open on the stack.
    private final class Element {
        let name: String
        let open: Range<Int>
        /// `nil` for a void element, a self-closing tag, and an element whose
        /// end tag the author left out — none of which gain one here.
        var close: Range<Int>?
        var children: [Node] = []

        init(name: String, open: Range<Int>) {
            self.name = name
            self.open = open
        }
    }

    /// `script`, `style`, `pre`, `textarea`, `title`: the content is bytes, not
    /// markup, and is never re-indented — a newline added after `<pre>` changes
    /// what the page shows, and one added after `<script>` would be joined by
    /// another on every later click of the button. Beautify writes every one of
    /// them back byte for byte; Minify does too, except for the two that hold
    /// code it knows — see `inlineCodeKind(of:bytes:)`.
    private struct RawElement {
        let name: String
        let open: Range<Int>
        let content: Range<Int>
        let close: Range<Int>?
    }

    // MARK: - Which elements sit on their own line

    /// The elements that each start a line of their own. Void `hr` is here and
    /// `br` is not: `br` is a line break inside a run of text, not a box around
    /// one, and pulling it out of its line would put spaces where the page had
    /// none.
    private static let blockNames: Set<String> = [
        "html", "head", "body", "address", "article", "aside", "blockquote",
        "caption", "col", "colgroup", "dd", "details", "dialog", "div", "dl",
        "dt", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2",
        "h3", "h4", "h5", "h6", "header", "hgroup", "hr", "legend", "li",
        "main", "menu", "nav", "ol", "p", "section", "summary", "table",
        "tbody", "td", "tfoot", "th", "thead", "tr", "ul",
        // The head's furniture, which reads as a list of one thing per line…
        "base", "link", "meta", "noscript", "template", "script", "style",
        // …and the two boxes whose content is bytes rather than markup.
        "pre", "svg",
    ]

    /// Void elements: they have no content and no end tag, and never nest.
    private static let voidNames: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link",
        "meta", "source", "track", "wbr",
    ]

    /// Elements whose content is text rather than markup, kept byte for byte
    /// until their own end tag.
    private static let rawTextNames: Set<String> = [
        "script", "style", "textarea", "title", "pre",
    ]

    /// An element the block list does not name is inline. That is the safe
    /// answer for something nobody has heard of: an inline element keeps its
    /// text in the line, and a line break where the page had no whitespace at
    /// all would show up as a space the author never wrote.
    private static func isBlock(_ node: Node) -> Bool {
        switch node {
        case .text: return false
        case .comment: return true
        case .element(let element): return blockNames.contains(element.name)
        case .raw(let raw): return blockNames.contains(raw.name)
        case .strayEnd(let name, _): return blockNames.contains(name)
        }
    }

    // MARK: - Writing

    /// One pass over a container's children: block-level children each take a
    /// line, and everything between them piles up into one run of inline
    /// markup, collapsed and trimmed where it meets the block boundary.
    private static func write(
        _ nodes: [Node], bytes: [UInt8], style: Style, indent: Int, into lines: inout [String]
    ) {
        var run = ""
        func flushRun() {
            let text = trimmingASCIIWhitespace(run)
            if !text.isEmpty { lines.append(pad(indent, style) + text) }
            run = ""
        }
        for node in nodes {
            if isBlock(node) {
                flushRun()
                writeBlock(node, bytes: bytes, style: style, indent: indent, into: &lines)
            } else {
                run += inlineMarkup(node, bytes: bytes, style: style)
            }
        }
        flushRun()
    }

    private static func writeBlock(
        _ node: Node, bytes: [UInt8], style: Style, indent: Int, into lines: inout [String]
    ) {
        let indentText = pad(indent, style)
        switch node {
        case .text:
            break  // Never block; `write` keeps it in the run.

        case .comment(let range), .strayEnd(_, let range):
            lines.append(indentText + source(bytes, range))

        case .raw:
            lines.append(indentText + inlineMarkup(node, bytes: bytes, style: style))

        case .element(let element):
            let open = source(bytes, element.open)
            let close = element.close.map { source(bytes, $0) } ?? ""
            // An element with nothing but text and inline markup inside stays
            // on one line — and so, as a special case of that, does an empty
            // `<div></div>`, since a pair of tags opened and closed over three
            // lines is noise.
            if element.children.contains(where: { isBlock($0) }) {
                lines.append(indentText + open)
                write(element.children, bytes: bytes, style: style, indent: indent + 1, into: &lines)
                if !close.isEmpty { lines.append(indentText + close) }
            } else {
                var run = ""
                for child in element.children {
                    run += inlineMarkup(child, bytes: bytes, style: style)
                }
                lines.append(indentText + open + trimmingASCIIWhitespace(run) + close)
            }
        }
    }

    /// The node written with no line break of ours anywhere in it. Inside an
    /// inline run everything is inline, however the tag is classified: a
    /// `<div>` a page put inside an `<a>` is still not a place to break the
    /// line the author wrote.
    private static func inlineMarkup(_ node: Node, bytes: [UInt8], style: Style) -> String {
        switch node {
        case .text(let range):
            return collapsedText(bytes, range)

        case .comment(let range), .strayEnd(_, let range):
            return source(bytes, range)

        case .raw(let raw):
            return source(bytes, raw.open) + rawContent(raw, bytes: bytes, style: style)
                + (raw.close.map { source(bytes, $0) } ?? "")

        case .element(let element):
            var out = source(bytes, element.open)
            for child in element.children {
                out += inlineMarkup(child, bytes: bytes, style: style)
            }
            if let close = element.close { out += source(bytes, close) }
            return out
        }
    }

    // MARK: - The code a page carries

    /// What a raw-text element holds, as far as this is concerned.
    private enum InlineCodeKind {
        case css, javascript, other
    }

    /// The `type` values a `<script>` may wear and still be a program. An
    /// absent `type`, an empty one and `module` are all JavaScript; everything
    /// else — `application/json`, `application/ld+json`, `importmap`,
    /// `speculationrules`, `text/template`, somebody's Handlebars — is data or
    /// another language's source, and neither is ours to rewrite.
    private static let javaScriptTypes: Set<String> = [
        "text/javascript", "application/javascript", "module", "text/ecmascript",
        "application/ecmascript", "text/jscript", "application/x-javascript",
    ]

    private static func inlineCodeKind(of raw: RawElement, bytes: [UInt8]) -> InlineCodeKind {
        // A `<style>` is a stylesheet whatever its `type` says; the attribute
        // has meant nothing since HTML5 dropped it.
        if raw.name == "style" { return .css }
        guard raw.name == "script" else { return .other }
        let type = (attributeValue("type", inTag: raw.open, bytes: bytes) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return type.isEmpty || javaScriptTypes.contains(type) ? .javascript : .other
    }

    /// The content of a raw-text element as it goes back down: minified where
    /// it is code and the page is being minified, and the bytes it was
    /// everywhere else.
    private static func rawContent(_ raw: RawElement, bytes: [UInt8], style: Style) -> String {
        let text = source(bytes, raw.content)
        guard style == .minified else { return text }
        switch inlineCodeKind(of: raw, bytes: bytes) {
        case .css: return InlineCodeMinify.css(text)
        case .javascript: return InlineCodeMinify.javascript(text)
        case .other: return text
        }
    }

    /// Whether Minify would still find something to take out of this one. The
    /// minifiers are idempotent, so running one and comparing is the whole
    /// answer.
    private static func hasCodeToMinify(_ raw: RawElement, bytes: [UInt8]) -> Bool {
        let text = source(bytes, raw.content)
        switch inlineCodeKind(of: raw, bytes: bytes) {
        case .css: return InlineCodeMinify.css(text) != text
        case .javascript: return InlineCodeMinify.javascript(text) != text
        case .other: return false
        }
    }

    /// One attribute's value out of an open tag's own bytes, case folded on the
    /// name and taken in whichever of the four forms the author used. The
    /// walker keeps a tag as the range it occupied and never as a dictionary,
    /// which is what keeps every attribute spelled the way it was written, so
    /// the one question anybody asks of a tag is answered by reading it again.
    private static func attributeValue(
        _ name: String, inTag range: Range<Int>, bytes: [UInt8]
    ) -> String? {
        var index = range.lowerBound + 1  // <
        let end = range.upperBound

        func skipWhitespace() {
            while index < end, isWhitespace(bytes[index]) { index += 1 }
        }

        // The tag's own name.
        while index < end, !isWhitespace(bytes[index]), bytes[index] != 0x3E,
            bytes[index] != 0x2F
        {
            index += 1
        }
        while true {
            skipWhitespace()
            guard index < end, bytes[index] != 0x3E else { return nil }
            if bytes[index] == 0x2F {  // a `/` that is not part of `/>`
                index += 1
                continue
            }
            let nameStart = index
            while index < end, !isWhitespace(bytes[index]), bytes[index] != 0x3D,
                bytes[index] != 0x3E, bytes[index] != 0x2F
            {
                index += 1
            }
            let attribute = String(decoding: bytes[nameStart..<index], as: UTF8.self).lowercased()
            let nameEnd = index
            skipWhitespace()
            var value: String?
            if index < end, bytes[index] == 0x3D {
                index += 1  // =
                skipWhitespace()
                guard index < end else { return nil }
                let quote = bytes[index]
                if quote == 0x22 || quote == 0x27 {
                    index += 1
                    let valueStart = index
                    while index < end, bytes[index] != quote { index += 1 }
                    value = String(decoding: bytes[valueStart..<index], as: UTF8.self)
                    if index < end { index += 1 }
                } else {
                    let valueStart = index
                    while index < end, !isWhitespace(bytes[index]), bytes[index] != 0x3E {
                        index += 1
                    }
                    value = String(decoding: bytes[valueStart..<index], as: UTF8.self)
                }
            }
            if attribute == name { return value }
            // Nothing read and nothing to read: a tag nobody can walk any
            // further is a tag with no such attribute.
            if nameEnd == nameStart, value == nil { return nil }
        }
    }

    private static func pad(_ indent: Int, _ style: Style) -> String {
        style == .pretty ? String(repeating: indentUnit, count: indent) : ""
    }

    private static func source(_ bytes: [UInt8], _ range: Range<Int>) -> String {
        String(decoding: bytes[range], as: UTF8.self)
    }

    /// Runs of whitespace become one space. ASCII whitespace only: a no-break
    /// space is a character the author typed, not layout.
    private static func collapsedText(_ bytes: [UInt8], _ range: Range<Int>) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(range.count)
        var lastWasSpace = false
        for position in range {
            let byte = bytes[position]
            if isWhitespace(byte) {
                if !lastWasSpace { out.append(0x20) }
                lastWasSpace = true
            } else {
                out.append(byte)
                lastWasSpace = false
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// ASCII whitespace off both ends, again leaving a no-break space alone —
    /// `trimmingCharacters(in: .whitespacesAndNewlines)` would eat one.
    private static func trimmingASCIIWhitespace(_ text: String) -> String {
        let bytes = Array(text.utf8)
        var start = 0
        var end = bytes.count
        while start < end, isWhitespace(bytes[start]) { start += 1 }
        while end > start, isWhitespace(bytes[end - 1]) { end -= 1 }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    // MARK: - Walking

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (byte | 0x20) >= 0x61 && (byte | 0x20) <= 0x7A
    }

    /// One token, all of it a range of source.
    private enum Token {
        case text(Range<Int>)
        case comment(Range<Int>)
        case start(name: String, range: Range<Int>, selfClosing: Bool)
        case end(name: String, range: Range<Int>)
    }

    /// A cursor over the source bytes. Every failure is a `ParseError` naming
    /// the line the unreadable construct began on, so "not valid HTML: line 12"
    /// is the place the reader has to look.
    private struct Walker {
        let bytes: [UInt8]
        var index = 0

        var isAtEnd: Bool { index >= bytes.count }

        func error(at position: Int) -> ParseError {
            var line = 1
            for scan in 0..<min(position, bytes.count) where bytes[scan] == 0x0A {
                line += 1
            }
            return ParseError(line: line)
        }

        // MARK: The tree

        mutating func parseDocument() throws -> [Node] {
            let root = Element(name: "", open: 0..<0)
            var stack: [Element] = [root]
            while !isAtEnd {
                let tokenStart = index
                switch try nextToken() {
                case .text(let range):
                    stack[stack.count - 1].children.append(.text(range))

                case .comment(let range):
                    stack[stack.count - 1].children.append(.comment(range))

                case .end(let name, let range):
                    // The nearest open element of that name closes, and
                    // whatever is still open inside it closes with it — but
                    // silently, without gaining an end tag it never had.
                    if let position = stack.lastIndex(where: { $0.name == name }), position > 0 {
                        stack[position].close = range
                        stack.removeSubrange(position...)
                    } else {
                        stack[stack.count - 1].children.append(
                            .strayEnd(name: name, range: range))
                    }

                case .start(let name, let range, let selfClosing):
                    if HTMLFormat.rawTextNames.contains(name), !selfClosing {
                        let raw = try scanRawText(name: name, open: range, openedAt: tokenStart)
                        stack[stack.count - 1].children.append(.raw(raw))
                    } else if selfClosing || HTMLFormat.voidNames.contains(name) {
                        stack[stack.count - 1].children.append(
                            .element(Element(name: name, open: range)))
                    } else {
                        guard stack.count <= HTMLFormat.depthLimit else {
                            throw error(at: tokenStart)
                        }
                        let element = Element(name: name, open: range)
                        stack[stack.count - 1].children.append(.element(element))
                        stack.append(element)
                    }
                }
            }
            return root.children
        }

        /// `isPretty`'s pass: the same tokens, but only ever asking whether a
        /// newline turned up in character data, or whether a stylesheet or a
        /// program still has something Minify would take out of it. A page the
        /// walk cannot finish is answered from what it read before it stopped.
        mutating func hasLayoutOrCodeToMinify(before end: Int) -> Bool {
            while !isAtEnd {
                let tokenStart = index
                guard let token = try? nextToken() else { return false }
                switch token {
                case .text(let range):
                    for position in range.lowerBound..<min(range.upperBound, end)
                    where bytes[position] == 0x0A || bytes[position] == 0x0D {
                        return true
                    }
                case .start(let name, let range, let selfClosing):
                    if HTMLFormat.rawTextNames.contains(name), !selfClosing {
                        guard let raw = try? scanRawText(
                            name: name, open: range, openedAt: tokenStart)
                        else { return false }
                        if HTMLFormat.hasCodeToMinify(raw, bytes: bytes) { return true }
                    }
                case .comment, .end:
                    break
                }
            }
            return false
        }

        // MARK: The tokens

        /// Whether a `<` at `position` opens markup. A lone `<` in `a < b` is
        /// text, exactly as a browser reads it.
        func opensMarkup(at position: Int) -> Bool {
            guard position < bytes.count, bytes[position] == 0x3C else { return false }
            guard position + 1 < bytes.count else { return false }
            let next = bytes[position + 1]
            if next == 0x21 || next == 0x3F { return true }  // ! ?
            if HTMLFormat.isLetter(next) { return true }
            if next == 0x2F {  // /
                return position + 2 < bytes.count && HTMLFormat.isLetter(bytes[position + 2])
            }
            return false
        }

        mutating func nextToken() throws -> Token {
            let start = index
            if opensMarkup(at: index) {
                let next = bytes[index + 1]
                if next == 0x21 { return .comment(try scanBang()) }
                if next == 0x3F { return .comment(try scanToGreaterThan(from: start)) }
                if next == 0x2F { return try scanEndTag() }
                return try scanStartTag()
            }
            index += 1
            while !isAtEnd, !opensMarkup(at: index) { index += 1 }
            return .text(start..<index)
        }

        /// `<!-- … -->`, and everything else beginning `<!` — a doctype, or the
        /// bogus comment a browser makes of `<!foo>` — up to its `>`.
        mutating func scanBang() throws -> Range<Int> {
            let start = index
            if index + 3 < bytes.count, bytes[index + 2] == 0x2D, bytes[index + 3] == 0x2D {
                index += 4
                while index + 2 < bytes.count {
                    if bytes[index] == 0x2D, bytes[index + 1] == 0x2D, bytes[index + 2] == 0x3E {
                        index += 3
                        return start..<index
                    }
                    index += 1
                }
                index = bytes.count
                throw error(at: start)  // a comment that never ends
            }
            return try scanToGreaterThan(from: start)
        }

        mutating func scanToGreaterThan(from start: Int) throws -> Range<Int> {
            index = start
            while !isAtEnd {
                if bytes[index] == 0x3E {
                    index += 1
                    return start..<index
                }
                index += 1
            }
            throw error(at: start)
        }

        mutating func scanStartTag() throws -> Token {
            let start = index
            index += 1  // <
            let name = scanName()
            while true {
                skipWhitespace()
                guard !isAtEnd else { throw error(at: start) }
                if bytes[index] == 0x3E {  // >
                    index += 1
                    return .start(name: name, range: start..<index, selfClosing: false)
                }
                if bytes[index] == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x3E {
                    index += 2  // />
                    return .start(name: name, range: start..<index, selfClosing: true)
                }
                try skipAttribute(tagStart: start)
            }
        }

        /// One attribute, in whichever of the four forms the author used —
        /// double-quoted, single-quoted, unquoted, or a bare name with no value
        /// at all. None of them is rewritten; this only walks past it.
        mutating func skipAttribute(tagStart: Int) throws {
            // A `/` that is not part of `/>` is skipped the way a browser
            // skips it.
            if bytes[index] == 0x2F {
                index += 1
                return
            }
            while !isAtEnd, !HTMLFormat.isWhitespace(bytes[index]), bytes[index] != 0x3D,
                bytes[index] != 0x3E, bytes[index] != 0x2F
            {
                index += 1
            }
            skipWhitespace()
            guard !isAtEnd else { throw error(at: tagStart) }
            guard bytes[index] == 0x3D else { return }  // a valueless attribute
            index += 1  // =
            skipWhitespace()
            guard !isAtEnd else { throw error(at: tagStart) }
            let quote = bytes[index]
            if quote == 0x22 || quote == 0x27 {
                index += 1
                // A `>` inside a quoted value is part of the value.
                while !isAtEnd, bytes[index] != quote { index += 1 }
                guard !isAtEnd else { throw error(at: tagStart) }  // an unclosed value
                index += 1
            } else {
                while !isAtEnd, !HTMLFormat.isWhitespace(bytes[index]), bytes[index] != 0x3E {
                    index += 1
                }
            }
        }

        mutating func scanEndTag() throws -> Token {
            let start = index
            index += 2  // </
            let name = scanName()
            while !isAtEnd {
                if bytes[index] == 0x3E {
                    index += 1
                    return .end(name: name, range: start..<index)
                }
                index += 1
            }
            throw error(at: start)
        }

        /// The content of a raw-text element, byte for byte, and then its own
        /// end tag. A `</div>` inside a `<script>` is a string in a program,
        /// not a tag.
        mutating func scanRawText(name: String, open: Range<Int>, openedAt start: Int) throws
            -> RawElement
        {
            let contentStart = index
            while index < bytes.count {
                if bytes[index] == 0x3C, index + 1 < bytes.count, bytes[index + 1] == 0x2F,
                    matchesName(name, at: index + 2)
                {
                    let contentEnd = index
                    guard case .end(_, let closeRange) = try scanEndTag() else {
                        throw error(at: start)
                    }
                    return RawElement(
                        name: name, open: open, content: contentStart..<contentEnd,
                        close: closeRange)
                }
                index += 1
            }
            index = bytes.count
            throw error(at: start)  // a raw-text element that never closes
        }

        /// The element's own name at `position`, case folded, and followed by
        /// something that can end a tag name.
        func matchesName(_ name: String, at position: Int) -> Bool {
            let expected = Array(name.utf8)
            guard position + expected.count <= bytes.count else { return false }
            for offset in 0..<expected.count
            where bytes[position + offset] | 0x20 != expected[offset] {
                return false
            }
            let after = position + expected.count
            guard after < bytes.count else { return true }
            let byte = bytes[after]
            return HTMLFormat.isWhitespace(byte) || byte == 0x3E || byte == 0x2F
        }

        /// A tag name, case folded: HTML does not care and neither does the
        /// walker, but what is written back is the source's own spelling.
        mutating func scanName() -> String {
            let start = index
            while !isAtEnd, !HTMLFormat.isWhitespace(bytes[index]), bytes[index] != 0x3E,
                bytes[index] != 0x2F
            {
                index += 1
            }
            return String(decoding: bytes[start..<index], as: UTF8.self).lowercased()
        }

        mutating func skipWhitespace() {
            while !isAtEnd, HTMLFormat.isWhitespace(bytes[index]) { index += 1 }
        }
    }
}

// MARK: - The elements, as the source spells them

/// The fourth question asked of the same walk, and the only one that is not
/// about writing the page back out: *where is each element written?*
///
/// `HTMLSourceMap` lines the page's own DOM up against this list to answer a
/// press in the preview with a range in the editor. It lives here rather than
/// beside the map because the walker is here — one tokeniser over a page, not
/// two — and because everything it needs is already taken down while the tree
/// is built.
extension HTMLFormat {

    /// One element, as the file writes it.
    struct SourceTag: Equatable {
        /// The tag name, case folded — the DOM's own `tagName.toLowerCase()`.
        let name: String
        /// The start tag itself, `<p class="a">`, in UTF-8 byte offsets.
        let open: Range<Int>
        /// The whole element, its start tag through its end tag, when the
        /// walk found an end tag for it. `nil` for a void element, a
        /// self-closing tag, and an element whose end tag the author left
        /// out — none of which have a span to give.
        let whole: Range<Int>?
        /// Whether everything inside it is text and inline markup: a heading,
        /// a paragraph, a cell, a `<title>`. Those are the ones worth
        /// revealing whole; a `<div>` around half the page is not.
        let holdsTextOnly: Bool
    }

    /// Every element in the page, in document order — which is the order the
    /// start tags are written in, and the order `querySelectorAll('*')` hands
    /// the DOM's own elements back in.
    ///
    /// Throws the same `ParseError` the other three questions do: a page the
    /// walk cannot finish has no map at all rather than half of one.
    static func sourceTags(of text: String) throws -> [SourceTag] {
        let bytes = Array(text.utf8)
        var walker = Walker(bytes: bytes)
        let nodes = try walker.parseDocument()
        var tags: [SourceTag] = []
        tags.reserveCapacity(bytes.count / 24 + 8)
        collectTags(nodes, into: &tags)
        return tags
    }

    private static func collectTags(_ nodes: [Node], into tags: inout [SourceTag]) {
        for node in nodes {
            switch node {
            case .element(let element):
                let close = element.close
                tags.append(SourceTag(
                    name: element.name,
                    open: element.open,
                    whole: close.map { element.open.lowerBound..<$0.upperBound },
                    holdsTextOnly: close != nil && !element.children.contains(where: isBlock)
                ))
                collectTags(element.children, into: &tags)

            case .raw(let raw):
                // `script`, `style`, `pre`, `textarea`, `title`: the content
                // is bytes rather than markup, so there is nothing inside to
                // walk and nothing inside that is a block.
                tags.append(SourceTag(
                    name: raw.name,
                    open: raw.open,
                    whole: raw.close.map { raw.open.lowerBound..<$0.upperBound },
                    holdsTextOnly: raw.close != nil
                ))

            case .text, .comment, .strayEnd:
                break
            }
        }
    }
}
