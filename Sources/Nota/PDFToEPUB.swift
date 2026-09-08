import Foundation
import NaturalLanguage
import PDFKit

/// A PDF turned back into a book: the document's text layer, rebuilt into
/// paragraphs and written out as a reflowable EPUB 3 (SPEC Todo 1).
///
/// A PDF is paper. Every line in it was placed where the typesetter put it,
/// on a sheet of a fixed size, and a phone or a Kindle showing that sheet
/// shows a photograph of a page rather than a book. What makes it a book
/// again is throwing the sheet away and keeping the sentences — so this reads
/// the text layer, joins the lines back into paragraphs, and writes XHTML
/// that reflows to whatever the reader is holding.
///
/// What it cannot do is invent a text layer. A scan is a stack of pictures
/// with no words in it at all, and there is no honest reflowable book to be
/// made from one; that is refused at the door rather than exported as a
/// hundred empty chapters.
///
/// The chapters are the document's own outline, since that is the only place
/// a PDF says where its parts begin. A document without one is a document
/// nobody divided, and its pages are its chapters.
///
/// Pictures inside the pages are out of scope for this pass: a PDF's images
/// are placed rather than flowed, and lifting them out means deciding where
/// in a reflowed paragraph each one belongs. The words go; the pictures stay
/// behind.
enum PDFToEPUB {

    /// Every way the export ends without a book.
    enum Failure: LocalizedError {
        /// The file is not a PDF at all — PDFKit would not open it.
        case notADocument
        /// A document with no text layer worth the name: a scan.
        case noText
        /// The pieces were written and `/usr/bin/zip` would not put them
        /// together.
        case couldNotPack
        /// The archive was made and could not be put where it was asked for.
        case couldNotWrite

        var errorDescription: String? {
            switch self {
            case .notADocument: L10n.text("This file is not a PDF.")
            case .noText:
                L10n.text("This PDF has no text to read — it is probably a scan.")
            case .couldNotPack: L10n.text("The book could not be packed.")
            case .couldNotWrite: L10n.text("The book could not be written.")
            }
        }
    }

    /// The share of a document's pages that has to carry some text before it
    /// is treated as a book rather than a scan. One page in twenty: a real
    /// book has a plate section, a title page and a colophon with nothing on
    /// them, and a scan has nothing anywhere.
    static let textThreshold = 0.05

    // MARK: - The door

    /// Reads the PDF at `fileURL` and writes it out as an EPUB at `url`.
    ///
    /// The file-shaped door, for a tab that has one. A file PDFKit will not
    /// open is `notADocument` — a `.pdf` that is really a text file included.
    static func export(pdfAt fileURL: URL, title: String, to url: URL) throws {
        guard let document = PDFDocument(url: fileURL) else { throw Failure.notADocument }
        let name = title.isEmpty
            ? fileURL.deletingPathExtension().lastPathComponent : title
        try export(document: document, title: name, to: url)
    }

    /// Writes `document` out as an EPUB at `url`.
    ///
    /// Synchronous: reading a text layer and writing a handful of small files
    /// is work the machine does at once, unlike printing a page, which waits
    /// on WebKit. A very long document is the caller's to put on a queue.
    static func export(document: PDFDocument, title: String, to url: URL) throws {
        let pages = pageText(of: document)
        guard !pages.isEmpty else { throw Failure.noText }
        let withText = pages.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard Double(withText.count) / Double(pages.count) >= textThreshold else {
            throw Failure.noText
        }

        let name = title.isEmpty ? UntitledNaming.base : title
        let chapters = chapters(of: document, pages: pages)
        let book = Book(
            title: name,
            language: language(of: document, sample: withText.prefix(3).joined(separator: "\n")),
            identifier: "urn:uuid:\(UUID().uuidString.lowercased())",
            chapters: chapters
        )
        try write(book, to: url)
    }

    // MARK: - The text

    /// Every page's text, in order, with the characters XML will not hold
    /// taken out. A page with no text layer is an empty string rather than a
    /// missing entry, so the count still matches the document's.
    private static func pageText(of document: PDFDocument) -> [String] {
        (0 ..< document.pageCount).map { index in
            guard let page = document.page(at: index), let text = page.string else { return "" }
            return sanitized(text)
        }
    }

    /// A PDF's text layer can hand back the control characters a form feed or
    /// a broken encoding leaves behind, and XML holds none of them. Tab,
    /// newline and carriage return stay; everything else below space goes.
    private static func sanitized(_ text: String) -> String {
        String(text.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 || scalar == "\t" || scalar == "\n" || scalar == "\r"
        })
    }

    // MARK: - The chapters

    /// One chapter of the book being written.
    struct Chapter {
        let title: String
        let blocks: [Block]
    }

    /// What a chapter is made of. A heading is an outline entry nested inside
    /// the chapter it falls in; everything else is a paragraph.
    enum Block {
        /// 2 or 3 — the chapter's own title is the 1.
        case heading(level: Int, text: String)
        case paragraph(String)
    }

    /// One line of a PDF's outline, flattened, with the nesting kept as a
    /// level — the same shape `EPUBBook` reads a table of contents into.
    private struct OutlineLine {
        let level: Int
        let title: String
        let page: Int
    }

    /// The document's chapters: its outline where it has one, its pages where
    /// it has not.
    ///
    /// A chapter runs from the page its outline entry lands on up to the page
    /// the next top-level entry lands on. Pages before the first entry — a
    /// cover, a title page, a contents nobody needs twice — go into the first
    /// chapter rather than into a chapter of their own, which would be a
    /// chapter with no name.
    private static func chapters(of document: PDFDocument, pages: [String]) -> [Chapter] {
        let lines = outlineLines(of: document)
        let tops = lines.enumerated().filter { $0.element.level == 1 }
        guard !tops.isEmpty else {
            return pages.enumerated().map { page in
                Chapter(
                    title: "\(L10n.text("Page")) \(page.offset + 1)",
                    blocks: paragraphs(of: page.element).map { Block.paragraph($0) }
                )
            }
        }

        var chapters: [Chapter] = []
        for (order, top) in tops.enumerated() {
            let start = order == 0 ? 0 : top.element.page
            let end = order + 1 < tops.count ? tops[order + 1].element.page : pages.count
            guard start < end else { continue }

            // The outline entries nested under this one, by the page each
            // falls on, so a heading is written where its section starts.
            var headings: [Int: [OutlineLine]] = [:]
            var index = top.offset + 1
            while index < lines.count, lines[index].level > 1 {
                headings[lines[index].page, default: []].append(lines[index])
                index += 1
            }

            var blocks: [Block] = []
            for page in start ..< min(end, pages.count) {
                for heading in headings[page] ?? [] {
                    blocks.append(.heading(level: min(heading.level, 3), text: heading.title))
                }
                blocks.append(contentsOf: paragraphs(of: pages[page]).map { Block.paragraph($0) })
            }
            chapters.append(Chapter(title: top.element.title, blocks: blocks))
        }
        return chapters.isEmpty
            ? pages.enumerated().map { page in
                Chapter(
                    title: "\(L10n.text("Page")) \(page.offset + 1)",
                    blocks: paragraphs(of: page.element).map { Block.paragraph($0) }
                )
            }
            : chapters
    }

    /// The outline, walked depth first. An entry says where it goes either as
    /// a destination or as a go-to action, and a badly made document has one
    /// or the other, so both are asked. An entry pointing nowhere is skipped
    /// along with what hangs off it.
    private static func outlineLines(of document: PDFDocument) -> [OutlineLine] {
        guard let root = document.outlineRoot else { return [] }
        var lines: [OutlineLine] = []

        func walk(_ outline: PDFOutline, level: Int) {
            for index in 0 ..< outline.numberOfChildren {
                guard let child = outline.child(at: index) else { continue }
                let destination = child.destination
                    ?? (child.action as? PDFActionGoTo)?.destination
                if let page = destination?.page {
                    let number = document.index(for: page)
                    guard number != NSNotFound, number >= 0 else { continue }
                    let title = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    lines.append(OutlineLine(
                        level: level,
                        title: title.isEmpty ? "\(L10n.text("Page")) \(number + 1)" : title,
                        page: number
                    ))
                }
                walk(child, level: level + 1)
            }
        }
        walk(root, level: 1)
        return lines
    }

    // MARK: - Lines back into paragraphs

    /// A page's text as paragraphs.
    ///
    /// A PDF has no paragraphs — it has lines, each one placed where it was
    /// typeset, and the line breaks in `PDFPage.string` are where the column
    /// ran out rather than where the writer stopped. Joining them all would
    /// give one paragraph a page long; keeping them would give a paragraph a
    /// line long. So the breaks are read:
    ///
    /// - a blank line always ends a paragraph;
    /// - a line indented past the rest of the page starts one, which is how
    ///   most books mark them;
    /// - and a line that ends a sentence, stops well short of the column's
    ///   width, and is followed by something that begins one — a capital, a
    ///   digit, an opening quote, a CJK character — ends one too.
    ///
    /// The third rule is the guess, and it is deliberately narrow: all three
    /// of its conditions have to hold. A capital after a full stop is not
    /// enough on its own, because a line that wrapped mid-sentence often
    /// starts with a name.
    static func paragraphs(of pageText: String) -> [String] {
        let lines = pageText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        guard !lines.isEmpty else { return [] }

        let filled = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let longest = filled.map { $0.trimmingCharacters(in: .whitespaces).count }.max() ?? 0
        let baseIndent = filled.map(indent(of:)).min() ?? 0

        var paragraphs: [String] = []
        var current = ""
        var previous = ""

        func flush() {
            let text = current.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { paragraphs.append(text) }
            current = ""
        }

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                flush()
                previous = ""
                continue
            }
            if !current.isEmpty,
               indent(of: raw) >= baseIndent + 2 || breaks(after: previous, before: line,
                                                           longest: longest) {
                flush()
            }
            append(line, to: &current, within: pageText)
            previous = line
        }
        flush()
        return paragraphs
    }

    private static func indent(of line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
    }

    /// The characters a sentence ends on, and the ones that may sit after one
    /// — a closing quote or bracket does not end a sentence but does not stop
    /// the thing before it from having ended.
    private static let terminators: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    private static let closers: Set<Character> = [
        "\"", "'", "”", "’", ")", "]", "»", "」", "』", "）",
    ]
    private static let openers: Set<Character> = ["\"", "'", "“", "‘", "(", "«", "「", "『", "（"]

    private static func breaks(after previous: String, before line: String, longest: Int) -> Bool {
        var tail = Substring(previous)
        while let last = tail.last, closers.contains(last) { tail = tail.dropLast() }
        guard let last = tail.last, terminators.contains(last) else { return false }
        // A line that ran the full width of the column is where the column
        // ran out, not where the writer stopped.
        guard longest > 0, previous.count < Int(Double(longest) * 0.85) else { return false }
        guard let first = line.first else { return false }
        // `isLetter && !isLowercase` is the capital rule in both scripts: a
        // Latin capital and a CJK character both answer to it, and a lower
        // case letter does not.
        return openers.contains(first) || first.isNumber || (first.isLetter && !first.isLowercase)
    }

    /// Puts a line on the end of the paragraph being built, healing the line
    /// break as it goes: a hyphen the typesetter added, or the space between
    /// two words that a CJK page does not want.
    private static func append(_ line: String, to current: inout String, within page: String) {
        guard !current.isEmpty else {
            current = line
            return
        }
        if current.hasSuffix("-"), let healed = healingHyphen(current, line, within: page) {
            current = healed
            return
        }
        if let last = current.last, let first = line.first, isCJK(last), isCJK(first) {
            current += line
        } else {
            current += " " + line
        }
    }

    /// A word the typesetter broke across two lines, put back together.
    ///
    /// Conservatively, because a hyphen is a real character too: `well-known`
    /// broken after the hyphen must come back as `well-known`, not
    /// `wellknown`. So the hyphen is only dropped when the second half starts
    /// in lower case — the shape of a word split by a typesetter — or when
    /// the whole word, joined up, is written somewhere else on the same page,
    /// which is the page telling us what the word is. `nil` when neither
    /// holds, and the hyphen stays.
    private static func healingHyphen(
        _ current: String, _ line: String, within page: String
    ) -> String? {
        let head = current.dropLast()
        guard let tail = head.split(separator: " ").last, let letter = tail.last,
              letter.isLetter
        else { return nil }
        let next = line.prefix { $0.isLetter }
        guard let first = next.first else { return nil }
        if first.isLowercase { return head + line }
        return page.contains(tail + next) ? head + line : nil
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000 ... 0x303F, 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF,
             0xF900 ... 0xFAFF, 0xFF00 ... 0xFFEF, 0x20000 ... 0x2FA1F:
            return true
        default:
            return false
        }
    }

    // MARK: - The language

    /// What `dc:language` says. A PDF rarely carries one — the catalogue's
    /// `/Lang` is optional and most producers leave it out — so where the
    /// document does not say, the text is asked: a reading system that knows
    /// a book is Chinese picks a font that can draw it, and one told `en`
    /// does not.
    private static func language(of document: PDFDocument, sample: String) -> String {
        if let stated = document.documentAttributes?["Lang"] as? String,
           !stated.trimmingCharacters(in: .whitespaces).isEmpty {
            return stated
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(sample.prefix(2000)))
        return recognizer.dominantLanguage?.rawValue ?? "en"
    }

    // MARK: - Writing the book

    /// Everything the archive is written from.
    private struct Book {
        let title: String
        let language: String
        let identifier: String
        let chapters: [Chapter]
    }

    /// Lays the book out in a staging folder and zips it into place.
    private static func write(_ book: Book, to url: URL) throws {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("Nota-PDF-EPUB-\(UUID().uuidString)", isDirectory: true)
        let oebps = staging.appendingPathComponent("OEBPS", isDirectory: true)
        let meta = staging.appendingPathComponent("META-INF", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let files = FileManager.default
        do {
            try files.createDirectory(at: oebps, withIntermediateDirectories: true)
            try files.createDirectory(at: meta, withIntermediateDirectories: true)

            // No trailing newline and no BOM: the OCF specification wants the
            // first entry to be exactly these twenty bytes.
            try Data("application/epub+zip".utf8)
                .write(to: staging.appendingPathComponent("mimetype"))
            try text(container, to: meta.appendingPathComponent("container.xml"))
            try text(stylesheet, to: oebps.appendingPathComponent("style.css"))

            for (index, chapter) in book.chapters.enumerated() {
                try text(xhtml(chapter, of: book),
                         to: oebps.appendingPathComponent(chapterFile(index)))
            }
            try text(package(book), to: oebps.appendingPathComponent("content.opf"))
            try text(nav(book), to: oebps.appendingPathComponent("nav.xhtml"))
            try text(ncx(book), to: oebps.appendingPathComponent("toc.ncx"))
        } catch {
            throw Failure.couldNotWrite
        }

        let archive = staging.appendingPathComponent("book.epub")
        // `mimetype` first and stored, then everything else however zip likes
        // it. That order is the whole of what tells a book from any other
        // archive — `FileSniff` reads it, and so does every reading system.
        guard zip(["-X", "-0", archive.path, "mimetype"], in: staging),
              zip(["-X", "-r", archive.path, "META-INF", "OEBPS"], in: staging)
        else { throw Failure.couldNotPack }

        do {
            if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
            try files.moveItem(at: archive, to: url)
        } catch {
            throw Failure.couldNotWrite
        }
    }

    private static func text(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
    }

    private static func chapterFile(_ index: Int) -> String {
        String(format: "chapter-%04d.xhtml", index + 1)
    }

    /// `/usr/bin/zip`, which every Mac has and which writes a stored entry on
    /// demand — the one thing an EPUB's first entry has to be. A zip library
    /// would be a dependency for something the system already does.
    private static func zip(_ arguments: [String], in directory: URL) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        task.arguments = arguments
        task.currentDirectoryURL = directory
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return false
        }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    // MARK: - The files themselves

    private static let container = """
    <?xml version="1.0" encoding="utf-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """

    /// Small on purpose. A reflowable book belongs to whoever is reading it —
    /// their font, their size, their margins — so this sets the little a
    /// reading system will not: paragraphs that flow rather than sit in a
    /// stack, and headings that start a page.
    private static let stylesheet = """
    html, body { margin: 0; padding: 0; }
    body { line-height: 1.5; }
    h1 { page-break-before: always; margin: 1.5em 0 0.8em; font-size: 1.5em; }
    h2 { margin: 1.4em 0 0.6em; font-size: 1.2em; }
    h3 { margin: 1.2em 0 0.5em; font-size: 1.05em; }
    p { margin: 0; text-indent: 1.2em; }
    p:first-of-type, h1 + p, h2 + p, h3 + p { text-indent: 0; margin-top: 0.6em; }
    """

    /// The id a nested heading is linked to from the contents. Per chapter,
    /// so the numbers start again in each file and stay short.
    private static func headingID(_ index: Int) -> String { "h\(index + 1)" }

    private static func xhtml(_ chapter: Chapter, of book: Book) -> String {
        var body = "<h1>\(escaped(chapter.title))</h1>\n"
        var headings = 0
        for block in chapter.blocks {
            switch block {
            case .heading(let level, let text):
                body += "<h\(level) id=\"\(headingID(headings))\">\(escaped(text))</h\(level)>\n"
                headings += 1
            case .paragraph(let text):
                body += "<p>\(escaped(text))</p>\n"
            }
        }
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" \
        lang="\(escaped(book.language))" xml:lang="\(escaped(book.language))">
        <head><meta charset="utf-8"/><title>\(escaped(chapter.title))</title>\
        <link rel="stylesheet" type="text/css" href="style.css"/></head>
        <body>
        \(body)</body>
        </html>

        """
    }

    private static func package(_ book: Book) -> String {
        var manifest = """
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="css" href="style.css" media-type="text/css"/>

        """
        var spine = "  <spine toc=\"ncx\">\n"
        for index in book.chapters.indices {
            manifest += "    <item id=\"c\(index + 1)\" href=\"\(chapterFile(index))\" "
                + "media-type=\"application/xhtml+xml\"/>\n"
            spine += "    <itemref idref=\"c\(index + 1)\"/>\n"
        }
        manifest += "  </manifest>\n"
        spine += "  </spine>\n"

        // EPUB 3 insists on a `dcterms:modified` to the second, in UTC, with
        // no fractional part.
        let stamp = ISO8601DateFormatter()
        stamp.timeZone = TimeZone(secondsFromGMT: 0)
        stamp.formatOptions = [.withInternetDateTime]

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>\(escaped(book.title))</dc:title>
            <dc:identifier id="book-id">\(escaped(book.identifier))</dc:identifier>
            <dc:language>\(escaped(book.language))</dc:language>
            <meta property="dcterms:modified">\(stamp.string(from: Date()))</meta>
          </metadata>
        \(manifest)\(spine)</package>

        """
    }

    /// EPUB 3's own table of contents: nested `<ol>`s, which is what
    /// `EPUBBook` reads the nesting out of.
    private static func nav(_ book: Book) -> String {
        var list = ""
        for (index, chapter) in book.chapters.enumerated() {
            let file = chapterFile(index)
            list += "      <li><a href=\"\(file)\">\(escaped(chapter.title))</a>\n"
            var headings = 0
            var nested = ""
            for block in chapter.blocks {
                guard case .heading(_, let text) = block else { continue }
                nested += "        <li><a href=\"\(file)#\(headingID(headings))\">"
                    + "\(escaped(text))</a></li>\n"
                headings += 1
            }
            if !nested.isEmpty { list += "        <ol>\n\(nested)        </ol>\n" }
            list += "      </li>\n"
        }
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" \
        lang="\(escaped(book.language))" xml:lang="\(escaped(book.language))">
        <head><meta charset="utf-8"/><title>\(escaped(book.title))</title></head>
        <body>
          <nav epub:type="toc" id="toc">
            <h1>\(escaped(book.title))</h1>
            <ol>
        \(list)    </ol>
          </nav>
        </body>
        </html>

        """
    }

    /// EPUB 2's contents, written as well as EPUB 3's. Kindle's own tools
    /// still read the NCX, and a book that carries both opens everywhere.
    private static func ncx(_ book: Book) -> String {
        var points = ""
        var order = 0
        for (index, chapter) in book.chapters.enumerated() {
            let file = chapterFile(index)
            order += 1
            points += """
                <navPoint id="np-\(order)" playOrder="\(order)">
                  <navLabel><text>\(escaped(chapter.title))</text></navLabel>
                  <content src="\(file)"/>

            """
            var headings = 0
            for block in chapter.blocks {
                guard case .heading(_, let text) = block else { continue }
                order += 1
                points += """
                      <navPoint id="np-\(order)" playOrder="\(order)">
                        <navLabel><text>\(escaped(text))</text></navLabel>
                        <content src="\(file)#\(headingID(headings))"/>
                      </navPoint>

                """
                headings += 1
            }
            points += "    </navPoint>\n"
        }
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <head>
            <meta name="dtb:uid" content="\(escaped(book.identifier))"/>
          </head>
          <docTitle><text>\(escaped(book.title))</text></docTitle>
          <navMap>
        \(points)  </navMap>
        </ncx>

        """
    }

    /// The five characters XML will not take raw. Attribute values and text
    /// both go through it, so there is one escaper rather than two that
    /// disagree.
    private static func escaped(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&apos;"
            default: escaped.append(character)
            }
        }
        return escaped
    }
}
