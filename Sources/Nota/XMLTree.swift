import Foundation

/// An `.xml` file read into a `StructuredDocument` — the tree the preview
/// column draws beside the source.
///
/// Unlike JSON, this one is not Nota's own parser. Foundation ships
/// `XMLParser`, a SAX reader that already answers the one question a tree
/// needs and a hand-written scanner would have to earn: which line every
/// event happened on. So the walk is Foundation's and the shape is Nota's —
/// the delegate below is nothing but the translation from events into
/// `StructuredNode`s.
///
/// How the two grammars line up:
///
/// * An element is an `.object` keyed by its **qualified** name — `svg:rect`
///   stays `svg:rect`, because a prefix is part of what the author wrote and
///   a tree that dropped it would be lying about the file. Namespace
///   processing is off for the same reason, which also leaves `xmlns:svg`
///   standing as the attribute it is written as.
/// * Its attributes come first among its children, keyed `@name` with
///   `.string` values, so they read as the metadata they are and never
///   collide with a child element of the same name.
/// * A run of text, and a `<![CDATA[…]]>` block, is a `.text` child.
///   Whitespace-only runs are dropped — the indentation of a pretty-printed
///   file is not content — and the rest are trimmed at both ends.
/// * A comment is a `.comment` child.
/// * A processing instruction and the doctype are skipped: neither is part of
///   the document's own shape.
///
/// The roots are the root element and any comments written beside it.
///
/// Every node also carries the span of source it was made from, so a click on
/// a row selects the element rather than pointing at a line. That is where
/// Foundation's reader stops being generous: it says *where* an event
/// happened and never how wide it was, so the extents are read back off the
/// text. `columnNumber` is 1-based and counted in Unicode scalars — an emoji
/// is one column, a combining accent is one of two — and it stands one past
/// the thing just read for an end tag, a run of text and a comment. A start
/// tag reports the `>` it ends on, and its `<` is found by looking back for
/// the nearest one, which is exact because XML forbids a `<` inside a tag,
/// attribute values included. An attribute's own `name="value"` is then read
/// out of that tag's text — the reader hands attributes over as a dictionary,
/// so the tag is the only place their extents survive.
enum XMLTree {

    static func parse(_ text: String) throws -> StructuredDocument {
        // The parser reads bytes, and the text it is handed is the editor's
        // own — whatever the file's declared encoding said, it is Unicode by
        // the time it reaches here, so it is handed over as UTF-8.
        let parser = XMLParser(data: Data(text.utf8))
        // Off: `elementName` is then the qualified name exactly as written,
        // and `xmlns:` attributes stay in the attribute list.
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        let builder = Builder(source: Source(text: text))
        parser.delegate = builder
        guard parser.parse(), builder.failure == nil else {
            throw builder.failure ?? XMLTree.error(from: parser)
        }
        guard !builder.roots.isEmpty else {
            throw StructuredParseError(line: 1, message: "Empty file")
        }
        return StructuredDocument(roots: builder.roots)
    }

    /// What `XMLParser` said, said shorter. Its `localizedDescription` is one
    /// sentence and sometimes two; the tree's message is a phrase, so only
    /// the first sentence survives.
    private static func error(from parser: XMLParser) -> StructuredParseError {
        let line = max(1, parser.lineNumber)
        guard let reason = (parser.parserError as NSError?)?.localizedDescription,
              !reason.isEmpty
        else { return StructuredParseError(line: line, message: "Not readable as XML") }
        let first = reason.split(separator: ".", maxSplits: 1).first.map(String.init) ?? reason
        return StructuredParseError(line: line, message: first.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - The text, held the way the reader counts it

    /// The source under the parse, kept as the scalars `XMLParser`'s columns
    /// are counted in, so a line and a column can be turned back into a place
    /// in the file — and from there, through `SourceOffsets`, into the UTF-16
    /// an `NSRange` is spelled in.
    private struct Source {
        let scalars: [Unicode.Scalar]
        /// Where each line begins, so the *n*th of them is one lookup.
        let lineStarts: [Int]
        let offsets: SourceOffsets

        init(text: String) {
            let scalars = Array(text.unicodeScalars)
            var starts = [0]
            for (index, scalar) in scalars.enumerated() where scalar == "\n" {
                starts.append(index + 1)
            }
            self.scalars = scalars
            self.lineStarts = starts
            self.offsets = .scalars(of: text)
        }

        /// Where the reader has reached. Its column is 1-based and stands one
        /// past the thing it has just read, so `column - 1` is the offset
        /// after it.
        func position(line: Int, column: Int) -> Int {
            let start = lineStarts[min(max(line, 1), lineStarts.count) - 1]
            return min(max(start + max(column - 1, 0), 0), scalars.count)
        }

        /// The 1-based line an offset is on — a node's line is its span's,
        /// which is the `<` it opens on rather than the `>` the reader
        /// happened to report.
        func line(at position: Int) -> Int {
            var low = 0
            var high = lineStarts.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if lineStarts[middle] <= position { low = middle } else { high = middle - 1 }
            }
            return low + 1
        }

        /// The `<` that opens the tag the reader has just finished. Exact,
        /// because a tag holds no `<` of its own: XML forbids one even inside
        /// an attribute's value.
        func tagStart(endingAt position: Int) -> Int {
            guard !scalars.isEmpty else { return 0 }
            var index = min(position, scalars.count - 1)
            while index > 0, scalars[index] != "<" { index -= 1 }
            return max(0, index)
        }

        /// One past the `>` that closes it. A start tag is reported at its
        /// `>`, an empty one at the `/` just before it, so the same look
        /// forward serves both.
        func tagEnd(from position: Int) -> Int {
            var index = position
            while index < scalars.count, scalars[index] != ">" { index += 1 }
            return min(index + 1, scalars.count)
        }

        /// The first `]]>` at or after a place, one past its end — where a
        /// CDATA block stops, which the reader reports the *start* of.
        func cdataEnd(from position: Int) -> Int {
            var index = position
            while index + 2 < scalars.count {
                if scalars[index] == "]", scalars[index + 1] == "]", scalars[index + 2] == ">" {
                    return index + 3
                }
                index += 1
            }
            return scalars.count
        }

        /// A run of text, with the file's own layout taken off both ends —
        /// the extent of what the row actually shows.
        func trimming(from start: Int, to end: Int) -> (Int, Int) {
            var first = max(0, start)
            var last = min(end, scalars.count)
            while first < last, isSpace(scalars[first]) { first += 1 }
            while last > first, isSpace(scalars[last - 1]) { last -= 1 }
            return (first, last)
        }

        func range(from start: Int, to end: Int) -> NSRange {
            offsets.range(from: start, to: end)
        }

        /// Where each of a start tag's attributes is written, by name: the
        /// whole `name="value"`, and the quoted value inside it. The reader
        /// hands attributes over as a dictionary, so this is the only place
        /// their extents can come from.
        func attributeSpans(
            tagStart: Int, tagEnd: Int
        ) -> [String: (whole: NSRange, value: NSRange)] {
            var spans: [String: (whole: NSRange, value: NSRange)] = [:]
            var index = min(tagStart + 1, tagEnd)
            // Past the element's own name.
            while index < tagEnd, !isSpace(scalars[index]),
                  scalars[index] != ">", scalars[index] != "/" { index += 1 }
            while index < tagEnd {
                while index < tagEnd, isSpace(scalars[index]) { index += 1 }
                guard index < tagEnd, scalars[index] != ">", scalars[index] != "/" else { break }
                let nameStart = index
                while index < tagEnd, !isSpace(scalars[index]), scalars[index] != "=",
                      scalars[index] != ">", scalars[index] != "/" { index += 1 }
                guard index > nameStart else {
                    // Nothing a name could be made of: step over it rather
                    // than stand still.
                    index += 1
                    continue
                }
                let name = String(String.UnicodeScalarView(scalars[nameStart..<index]))
                while index < tagEnd, isSpace(scalars[index]) { index += 1 }
                guard index < tagEnd, scalars[index] == "=" else { continue }
                index += 1
                while index < tagEnd, isSpace(scalars[index]) { index += 1 }
                guard index < tagEnd, scalars[index] == "\"" || scalars[index] == "'" else {
                    continue
                }
                let quote = scalars[index]
                let valueStart = index
                index += 1
                while index < tagEnd, scalars[index] != quote { index += 1 }
                if index < tagEnd { index += 1 }
                if spans[name] == nil {
                    // The quotes are the value's own characters: a selection
                    // that left them out would point at something the file
                    // does not say.
                    spans[name] = (range(from: nameStart, to: index),
                                   range(from: valueStart, to: index))
                }
            }
            return spans
        }

        private func isSpace(_ scalar: Unicode.Scalar) -> Bool {
            scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r"
        }
    }

    // MARK: - Events into nodes

    /// The stack of elements being read, and the text piling up inside the
    /// one on top. Nothing here knows about the tree beyond "the node being
    /// built has children"; the shape is `StructuredNode`'s.
    private final class Builder: NSObject, XMLParserDelegate {
        /// The whole document's top level: the root element, and any comment
        /// written beside it.
        var roots: [StructuredNode] = []
        /// The first thing that went wrong, kept because `XMLParser` reports
        /// an error and then stops, and the parse's own return value alone
        /// does not say where.
        var failure: StructuredParseError?

        private let source: Source
        /// An element being read, and the `<` it opened on — which is where
        /// its span begins and its `</name>` is where it ends.
        private var stack: [(node: StructuredNode, start: Int)] = []
        /// The characters read since the last event, and where the run began.
        /// A run arrives in as many callbacks as the reader feels like, so it
        /// is joined up and only settled when something else happens.
        private var pendingText = ""
        private var pendingStart = 0
        private var pendingEnd = 0
        /// One past the last thing the reader has finished. A run of text is
        /// the only node whose *start* is never reported, so it is taken from
        /// wherever the thing before it stopped.
        private var cursor = 0

        init(source: Source) {
            self.source = source
        }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName: String?, attributes: [String: String]
        ) {
            flushText()
            let reported = source.position(line: parser.lineNumber, column: parser.columnNumber)
            let start = source.tagStart(endingAt: reported)
            let tagEnd = source.tagEnd(from: reported)
            cursor = tagEnd
            var element = StructuredNode(
                key: elementName, value: .object, line: source.line(at: start)
            )
            let spans: [String: (whole: NSRange, value: NSRange)] = attributes.isEmpty
                ? [:] : source.attributeSpans(tagStart: start, tagEnd: tagEnd)
            // In the order the author wrote them: `attributes` is a
            // dictionary, so the order is whatever hashing felt like, and a
            // tree that reshuffled `x` and `y` between two reads of the same
            // file would be unreadable. Sorted by name is arbitrary but it is
            // at least the same every time.
            for name in attributes.keys.sorted() {
                element.children.append(StructuredNode(
                    key: "@" + name, value: .string(attributes[name] ?? ""),
                    line: element.line, range: spans[name]?.whole,
                    valueRange: spans[name]?.value
                ))
            }
            stack.append((element, start))
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName: String?
        ) {
            flushText()
            guard var finished = stack.popLast() else { return }
            let end = source.position(line: parser.lineNumber, column: parser.columnNumber)
            cursor = end
            finished.node.range = source.range(from: finished.start, to: end)
            append(finished.node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if pendingText.isEmpty { pendingStart = cursor }
            pendingText += string
            pendingEnd = source.position(line: parser.lineNumber, column: parser.columnNumber)
            cursor = pendingEnd
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            // The reader reports where the *content* of a block starts, so
            // the block itself is nine scalars back — `<![CDATA[` — and runs
            // to the `]]>` that ends it.
            let content = source.position(line: parser.lineNumber, column: parser.columnNumber)
            let start = max(0, content - 9)
            let end = source.cdataEnd(from: content)
            if pendingText.isEmpty { pendingStart = start }
            pendingText += String(decoding: CDATABlock, as: UTF8.self)
            pendingEnd = end
            cursor = end
        }

        func parser(_ parser: XMLParser, foundComment comment: String) {
            flushText()
            let end = source.position(line: parser.lineNumber, column: parser.columnNumber)
            // `<!--` and `-->` around the text the reader hands back verbatim.
            let start = max(0, end - comment.unicodeScalars.count - 7)
            cursor = end
            let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
            let span = source.range(from: start, to: end)
            append(StructuredNode(
                key: nil, value: .comment(trimmed), line: source.line(at: start),
                range: span, valueRange: span
            ))
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            guard failure == nil else { return }
            failure = XMLTree.error(from: parser)
        }

        /// The text piled up since the last event, settled onto the element
        /// holding it. Whitespace between tags is the file's own layout and
        /// not a run of text, so it is dropped rather than shown as a blank
        /// row.
        private func flushText() {
            defer { pendingText = "" }
            let trimmed = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let (start, end) = source.trimming(from: pendingStart, to: pendingEnd)
            // A run of text is nothing but its value, so both spans are the
            // same — the trimmed run, or the whole `<![CDATA[…]]>`.
            let span = source.range(from: start, to: end)
            append(StructuredNode(
                key: nil, value: .text(trimmed), line: source.line(at: start),
                range: span, valueRange: span
            ))
        }

        /// Onto the element being read, or onto the document itself when
        /// there is none — which is the root element, and the comments beside
        /// it.
        private func append(_ node: StructuredNode) {
            if stack.isEmpty {
                roots.append(node)
            } else {
                stack[stack.count - 1].node.children.append(node)
            }
        }
    }
}
