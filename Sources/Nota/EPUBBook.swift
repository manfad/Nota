import Foundation

/// A book, read off the disk and made sense of (SPEC Todo 3).
///
/// An EPUB is a zip with a manifest: `META-INF/container.xml` names the
/// package document, the package document lists every file in the book and
/// the order its chapters are read in, and one of those files is a table of
/// contents. None of that is drawing — this is the whole of the reading, and
/// nothing here touches AppKit, so a book can be opened and asked questions
/// without a window.
///
/// The zip is unpacked to a folder of its own rather than read out of the
/// archive a piece at a time. A chapter is XHTML that pulls in the book's own
/// stylesheets and pictures by relative path, and the pane that draws it is a
/// web view: handing WebKit a folder of real files is what makes those paths
/// resolve, and `/usr/bin/ditto` unpacks the folder without Nota taking on a
/// zip library to do it. The folder is the book's own and goes with it.
final class EPUBBook {

    /// One document of the spine — a chapter, in the order the book is read.
    struct Chapter: Equatable {
        /// Its id in the package manifest, which is what the spine names it
        /// by. `nil` for a spine entry whose item had none.
        let id: String?
        /// The file itself, inside the unpacked folder.
        let url: URL
        /// What the table of contents calls it, or its file name where the
        /// contents say nothing about it.
        let title: String
    }

    /// One line of the book's own table of contents — EPUB 3's `nav`
    /// document, or EPUB 2's NCX. Flattened, with the nesting kept as a
    /// level, because that is the shape the ⇧⌘J switcher lists headings in.
    struct TOCEntry: Equatable {
        /// 1 for a top-level entry, 2 for one nested inside it, and so on.
        let level: Int
        let title: String
        /// The file the entry points at.
        let url: URL
        /// The `#anchor` on the end of it, when the entry is a place inside a
        /// chapter rather than the chapter itself.
        let fragment: String?
        /// Where that file sits in the spine. `nil` for an entry pointing at
        /// something the spine does not hold, which a badly made book has and
        /// which there is nowhere to go to.
        let chapterIndex: Int?
    }

    /// The `.epub` on disk.
    let fileURL: URL
    /// The folder it was unpacked into. Removed when the book is let go.
    let unpackedURL: URL
    /// The package document — the OPF — everything in the book is named
    /// relative to.
    let packageURL: URL
    /// The book's own title, from the package metadata. `nil` when it has
    /// none; the tab is named for the file either way.
    let title: String?
    /// Every chapter, in reading order.
    let chapters: [Chapter]
    /// The table of contents, flattened, in its own order.
    let contents: [TOCEntry]

    private init(fileURL: URL, unpackedURL: URL, packageURL: URL, title: String?,
                 chapters: [Chapter], contents: [TOCEntry]) {
        self.fileURL = fileURL
        self.unpackedURL = unpackedURL
        self.packageURL = packageURL
        self.title = title
        self.chapters = chapters
        self.contents = contents
    }

    /// The unpacked folder belongs to the book and to nothing else, so it
    /// goes when the book does — a tab closed, a file that changed under one,
    /// the app quitting.
    deinit {
        try? FileManager.default.removeItem(at: unpackedURL)
    }

    // MARK: - Opening one

    /// Reads a book: unpack, `META-INF/container.xml`, the package document,
    /// the spine, the contents.
    ///
    /// `nil` for anything that does not come apart into a book — a truncated
    /// file, a zip that is not one, a package with no readable spine. There
    /// is no error to show: the pane says the file could not be opened, the
    /// same thing a PDF that will not parse says, and a book half read is not
    /// a book.
    static func open(_ fileURL: URL) -> EPUBBook? {
        let unpacked = FileManager.default.temporaryDirectory
            .appendingPathComponent("Nota-EPUB-\(UUID().uuidString)", isDirectory: true)
        guard let book = unpack(fileURL, into: unpacked) else {
            try? FileManager.default.removeItem(at: unpacked)
            return nil
        }
        return book
    }

    private static func unpack(_ fileURL: URL, into unpacked: URL) -> EPUBBook? {
        guard (try? FileManager.default.createDirectory(
            at: unpacked, withIntermediateDirectories: true
        )) != nil else { return nil }
        guard ditto(fileURL, into: unpacked) else { return nil }

        let container = unpacked
            .appendingPathComponent("META-INF", isDirectory: true)
            .appendingPathComponent("container.xml")
        guard let containerXML = document(at: container),
              let root = containerXML.rootElement(),
              let rootPath = elements(in: root, named: "rootfile")
                  .compactMap({ attribute(of: $0, named: "full-path") })
                  .first,
              let packageURL = resolve(rootPath, against: unpacked.appendingPathComponent("")),
              let package = document(at: packageURL),
              let packageRoot = package.rootElement()
        else { return nil }

        let base = packageURL.deletingLastPathComponent()
        let manifest = readManifest(packageRoot)
        let spine = elements(in: packageRoot, named: "spine").first
        let order = spine.map { itemrefs(of: $0) } ?? []
        let files: [(id: String?, url: URL)] = order.compactMap { id in
            guard let item = manifest[id], let url = resolve(item.href, against: base)
            else { return nil }
            return (id, url)
        }
        guard !files.isEmpty else { return nil }

        let contents = readContents(
            packageRoot: packageRoot, spine: spine, manifest: manifest, base: base,
            chapterFiles: files.map(\.url)
        )
        let chapters = files.map { file in
            Chapter(
                id: file.id,
                url: file.url,
                title: contents.first { $0.url == file.url && !$0.title.isEmpty }?.title
                    ?? file.url.deletingPathExtension().lastPathComponent
            )
        }

        return EPUBBook(
            fileURL: fileURL, unpackedURL: unpacked, packageURL: packageURL,
            title: bookTitle(packageRoot), chapters: chapters, contents: contents
        )
    }

    /// `/usr/bin/ditto`, which unpacks a PKZip archive and is already on
    /// every Mac. A zip library would be a dependency for the one thing the
    /// system already does, and SPEC says one only earns its keep when the
    /// system does not.
    private static func ditto(_ fileURL: URL, into directory: URL) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-x", "-k", fileURL.path, directory.path]
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

    // MARK: - The package document

    /// Every file the book declares, by the id the spine names it with.
    private static func readManifest(
        _ packageRoot: XMLElement
    ) -> [String: (href: String, properties: String)] {
        var manifest: [String: (href: String, properties: String)] = [:]
        guard let element = elements(in: packageRoot, named: "manifest").first else {
            return manifest
        }
        for item in elements(in: element, named: "item") {
            guard let id = attribute(of: item, named: "id"),
                  let href = attribute(of: item, named: "href")
            else { continue }
            manifest[id] = (href, attribute(of: item, named: "properties") ?? "")
        }
        return manifest
    }

    /// The spine's `itemref`s, in the order they are written — which is the
    /// order the book is read in, and the only thing that says so.
    private static func itemrefs(of spine: XMLElement) -> [String] {
        elements(in: spine, named: "itemref").compactMap { attribute(of: $0, named: "idref") }
    }

    private static func bookTitle(_ packageRoot: XMLElement) -> String? {
        guard let metadata = elements(in: packageRoot, named: "metadata").first,
              let title = elements(in: metadata, named: "title").first?.stringValue?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else { return nil }
        return title
    }

    // MARK: - The table of contents

    /// EPUB 3 names its contents in the manifest — the one item whose
    /// properties say `nav` — and EPUB 2 hangs an NCX off the spine's `toc`
    /// attribute. A book may carry both; the newer one is asked first, and
    /// the older one is what answers for a book that only has that.
    private static func readContents(
        packageRoot: XMLElement, spine: XMLElement?,
        manifest: [String: (href: String, properties: String)], base: URL,
        chapterFiles: [URL]
    ) -> [TOCEntry] {
        var lines: [(level: Int, title: String, href: String)] = []
        var navBase = base

        if let nav = manifest.values.first(where: {
            $0.properties.split(whereSeparator: { $0 == " " }).contains("nav")
        }), let url = resolve(nav.href, against: base), let document = document(at: url) {
            lines = navLines(document)
            navBase = url.deletingLastPathComponent()
        }
        if lines.isEmpty,
           let id = spine.flatMap({ attribute(of: $0, named: "toc") }),
           let item = manifest[id], let url = resolve(item.href, against: base),
           let document = document(at: url) {
            lines = ncxLines(document)
            navBase = url.deletingLastPathComponent()
        }

        return lines.compactMap { line in
            guard let url = resolve(line.href, against: navBase) else { return nil }
            return TOCEntry(
                level: line.level, title: line.title, url: url,
                fragment: fragment(of: line.href),
                chapterIndex: chapterFiles.firstIndex(of: url)
            )
        }
    }

    /// EPUB 3: a `nav` element marked `epub:type="toc"`, holding nested
    /// `<ol><li><a href>` lists. The nesting is the level.
    private static func navLines(
        _ document: XMLDocument
    ) -> [(level: Int, title: String, href: String)] {
        guard let root = document.rootElement() else { return [] }
        let navs = elements(in: root, named: "nav")
        let toc = navs.first {
            (attribute(of: $0, named: "type") ?? "").contains("toc")
        } ?? navs.first
        guard let toc, let list = elements(in: toc, named: "ol").first else { return [] }

        var lines: [(level: Int, title: String, href: String)] = []
        func walk(_ list: XMLElement, level: Int) {
            for item in children(of: list, named: "li") {
                if let link = children(of: item, named: "a").first,
                   let href = attribute(of: link, named: "href"), !href.isEmpty {
                    lines.append((level, text(of: link), href))
                }
                for nested in children(of: item, named: "ol") {
                    walk(nested, level: level + 1)
                }
            }
        }
        walk(list, level: 1)
        return lines
    }

    /// EPUB 2: an NCX whose `navMap` holds nested `navPoint`s, each with a
    /// label and a `content` element pointing at the file.
    private static func ncxLines(
        _ document: XMLDocument
    ) -> [(level: Int, title: String, href: String)] {
        guard let root = document.rootElement(),
              let map = elements(in: root, named: "navmap").first
        else { return [] }

        var lines: [(level: Int, title: String, href: String)] = []
        func walk(_ parent: XMLElement, level: Int) {
            for point in children(of: parent, named: "navpoint") {
                let label = children(of: point, named: "navlabel").first
                let title = label.flatMap { elements(in: $0, named: "text").first }
                    .map { text(of: $0) } ?? ""
                if let content = children(of: point, named: "content").first,
                   let href = attribute(of: content, named: "src"), !href.isEmpty {
                    lines.append((level, title, href))
                }
                walk(point, level: level + 1)
            }
        }
        walk(map, level: 1)
        return lines
    }

    // MARK: - What the sidebar lists

    /// The contents as the sidebar's list wants them: a line per entry, the
    /// nesting as the level, and the entry's own place in the list as the
    /// line — which is what comes back when one is chosen, since a book has
    /// no text for an offset to point into. An entry the contents left
    /// unnamed is called after the file it points at rather than nothing.
    var contentsEntries: [ContentsEntry] {
        contents.enumerated().map { entry in
            ContentsEntry(
                level: max(1, entry.element.level),
                title: entry.element.title.isEmpty
                    ? entry.element.url.lastPathComponent : entry.element.title,
                line: entry.offset
            )
        }
    }

    /// Where a chosen contents line goes: the chapter it names and the anchor
    /// inside it. An entry pointing at a file the spine does not hold has
    /// nowhere to go, and is left alone rather than landing somewhere else.
    func destination(ofContentsLine index: Int) -> (chapter: Int, fragment: String?)? {
        guard contents.indices.contains(index),
              let chapter = contents[index].chapterIndex
        else { return nil }
        return (chapter, contents[index].fragment)
    }

    /// Which line of the contents names a chapter — the first entry pointing
    /// at it, which is the chapter's own line rather than a section inside
    /// it. That is the line the sidebar rings while the chapter is on screen.
    /// `nil` for a chapter the contents never mention, which a book with a
    /// partial table of contents has: nothing is rung rather than the wrong
    /// thing.
    func contentsLine(ofChapter index: Int) -> Int? {
        contents.firstIndex { $0.chapterIndex == index }
    }

    // MARK: - The words of a chapter

    /// A chapter's words with the markup left behind — what ⇧⌘F searches a
    /// book by (SPEC Done 37).
    ///
    /// Block elements are kept apart by a line break, so a hit's snippet is
    /// the paragraph it sits in rather than the whole chapter run together;
    /// the whitespace an indented XHTML file leaves inside a paragraph is
    /// collapsed the way `text(of:)` collapses a contents label's. A
    /// stylesheet and a script are not words and are left out.
    ///
    /// The file is read and parsed on the spot. The tab holding the book
    /// keeps what comes back, so a chapter is read once per book rather than
    /// once per keystroke.
    func words(ofChapter index: Int) -> String {
        guard chapters.indices.contains(index),
              let document = Self.document(at: chapters[index].url),
              let root = document.rootElement()
        else { return "" }
        let body = Self.elements(in: root, named: "body").first ?? root
        var text = ""
        Self.appendWords(of: body, to: &text)
        return text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// The elements a line ends at. Everything else is inline, and its words
    /// belong to the line around it.
    private static let blockElements: Set<String> = [
        "address", "article", "aside", "blockquote", "br", "dd", "div", "dl",
        "dt", "figcaption", "figure", "footer", "h1", "h2", "h3", "h4", "h5",
        "h6", "header", "hr", "li", "main", "nav", "ol", "p", "pre", "section",
        "table", "td", "th", "tr", "ul",
    ]

    /// The elements whose contents are not the book's words at all.
    private static let wordlessElements: Set<String> = ["head", "script", "style", "title"]

    private static func appendWords(of node: XMLNode, to text: inout String) {
        switch node.kind {
        case .text:
            let words = (node.stringValue ?? "")
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !words.isEmpty else { return }
            if !text.isEmpty, !text.hasSuffix("\n"), !text.hasSuffix(" ") { text += " " }
            text += words
        case .element:
            guard let element = node as? XMLElement else { return }
            let name = (element.localName ?? element.name ?? "").lowercased()
            guard !wordlessElements.contains(name) else { return }
            let breaks = blockElements.contains(name)
            if breaks, !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
            for child in element.children ?? [] { appendWords(of: child, to: &text) }
            if breaks, !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        default:
            return
        }
    }

    // MARK: - XML

    /// The strict parse first, since every one of these files is XML by
    /// specification. A book that is not quite — a nav document with an HTML
    /// entity in it — is read through libxml2's forgiving parser rather than
    /// refused, which is what a browser would do with the same file.
    private static func document(at url: URL) -> XMLDocument? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let strict = try? XMLDocument(
            data: data, options: [.nodeLoadExternalEntitiesNever]
        ) { return strict }
        return try? XMLDocument(
            data: data, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]
        )
    }

    /// Every descendant element of that name, in document order.
    ///
    /// By local name and case-insensitively, because none of these documents
    /// can be relied on to spell an element the same way twice: an OPF may
    /// put the package namespace on a prefix, and the forgiving parser
    /// lower-cases everything it touches.
    private static func elements(in node: XMLNode, named localName: String) -> [XMLElement] {
        var found: [XMLElement] = []
        func walk(_ node: XMLNode) {
            if let element = node as? XMLElement, matches(element, localName) {
                found.append(element)
            }
            for child in node.children ?? [] { walk(child) }
        }
        walk(node)
        return found
    }

    /// The direct children of that name — what a nested list needs, where
    /// every descendant would fold the whole tree into one level.
    private static func children(of element: XMLElement, named localName: String) -> [XMLElement] {
        (element.children ?? []).compactMap { $0 as? XMLElement }
            .filter { matches($0, localName) }
    }

    private static func matches(_ element: XMLElement, _ localName: String) -> Bool {
        let name = element.localName ?? element.name ?? ""
        return name.caseInsensitiveCompare(localName) == .orderedSame
    }

    /// An attribute by local name, so `epub:type` and a bare `type` are the
    /// same question.
    private static func attribute(of element: XMLElement, named localName: String) -> String? {
        for attribute in element.attributes ?? [] {
            let name = attribute.localName ?? attribute.name ?? ""
            if name.caseInsensitiveCompare(localName) == .orderedSame {
                return attribute.stringValue
            }
        }
        return nil
    }

    /// An element's words, with the whitespace an indented XML file leaves
    /// around them collapsed — a contents line is a label, not a paragraph.
    private static func text(of element: XMLElement) -> String {
        (element.stringValue ?? "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Paths

    /// The file an href in the book points at. Hrefs are URL-encoded and
    /// relative to the document they are written in, so they are resolved as
    /// URLs rather than pasted onto a path — a chapter called `part 1.xhtml`
    /// is written `part%201.xhtml`, and joining that as a path would look for
    /// a file of that name.
    private static func resolve(_ href: String, against base: URL) -> URL? {
        let path = href.split(separator: "#", maxSplits: 1,
                              omittingEmptySubsequences: false).first.map(String.init) ?? href
        guard !path.isEmpty else { return nil }
        if let url = URL(string: path, relativeTo: base)?.absoluteURL, url.isFileURL {
            return url.standardizedFileURL
        }
        let decoded = path.removingPercentEncoding ?? path
        return URL(fileURLWithPath: decoded, relativeTo: base).standardizedFileURL
    }

    /// The `#anchor` on the end of an href, when there is one.
    private static func fragment(of href: String) -> String? {
        guard let hash = href.firstIndex(of: "#") else { return nil }
        let anchor = String(href[href.index(after: hash)...])
        guard !anchor.isEmpty else { return nil }
        return anchor.removingPercentEncoding ?? anchor
    }
}
