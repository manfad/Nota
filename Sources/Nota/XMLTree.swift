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
        let builder = Builder()
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

        private var stack: [StructuredNode] = []
        /// The characters read since the last event, and the line the run
        /// started on. A run arrives in as many callbacks as the reader feels
        /// like, so it is joined up and only settled when something else
        /// happens.
        private var pendingText = ""
        private var pendingTextLine = 1

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName: String?, attributes: [String: String]
        ) {
            flushText()
            let line = max(1, parser.lineNumber)
            var element = StructuredNode(key: elementName, value: .object, line: line)
            // In the order the author wrote them: `attributes` is a
            // dictionary, so the order is whatever hashing felt like, and a
            // tree that reshuffled `x` and `y` between two reads of the same
            // file would be unreadable. Sorted by name is arbitrary but it is
            // at least the same every time.
            for name in attributes.keys.sorted() {
                element.children.append(StructuredNode(
                    key: "@" + name, value: .string(attributes[name] ?? ""), line: line
                ))
            }
            stack.append(element)
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName: String?
        ) {
            flushText()
            guard let finished = stack.popLast() else { return }
            append(finished)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if pendingText.isEmpty { pendingTextLine = max(1, parser.lineNumber) }
            pendingText += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if pendingText.isEmpty { pendingTextLine = max(1, parser.lineNumber) }
            pendingText += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, foundComment comment: String) {
            flushText()
            let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
            append(StructuredNode(
                key: nil, value: .comment(trimmed), line: max(1, parser.lineNumber)
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
            append(StructuredNode(key: nil, value: .text(trimmed), line: pendingTextLine))
        }

        /// Onto the element being read, or onto the document itself when
        /// there is none — which is the root element, and the comments beside
        /// it.
        private func append(_ node: StructuredNode) {
            if stack.isEmpty {
                roots.append(node)
            } else {
                stack[stack.count - 1].children.append(node)
            }
        }
    }
}
