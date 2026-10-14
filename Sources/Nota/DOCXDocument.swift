import Foundation

/// A Word document, read (SPEC "## Office documents and video"): a `.docx`
/// unpacked into a scratch folder and written out once as one HTML page beside
/// its own `word/media`, which the same web view a book chapter is drawn in
/// then shows.
///
/// Nota's own reading of the format, not AppKit's: `NSAttributedString` takes a
/// `.docx` too, and what it makes of one is TextEdit's — tables flattened, list
/// numbers lost, pictures dropped. This keeps what a reader of a Word document
/// actually looks at: the page's width and margins, the styles' fonts, sizes,
/// colours and spacing, headings, numbered and bulleted lists counted the way
/// Word counts them, tables with merged cells and shading, pictures at their
/// size, links, text boxes, page breaks, and footnotes and endnotes gathered
/// at the foot. Headers, footers, comments, tracked deletions and drawing
/// shapes are left out.
final class DOCXDocument {
    let fileURL: URL
    /// The folder the archive was unpacked into. It goes with the document.
    let unpackedURL: URL
    /// The page itself, at the folder's top so `word/media/…` resolves.
    let pageURL: URL
    /// Every paragraph's words, a line each — what ⇧⌘F searches.
    let plainText: String

    private init(fileURL: URL, unpackedURL: URL, pageURL: URL, plainText: String) {
        self.fileURL = fileURL
        self.unpackedURL = unpackedURL
        self.pageURL = pageURL
        self.plainText = plainText
    }

    deinit {
        try? FileManager.default.removeItem(at: unpackedURL)
    }

    /// `nil` for anything that does not come apart into a Word document: a
    /// zip with no `word/document.xml`, or one whose XML will not parse.
    static func open(_ fileURL: URL) -> DOCXDocument? {
        guard let folder = Unzip.toTemporaryFolder(fileURL, prefix: "Nota-DOCX") else {
            return nil
        }
        guard var converter = DOCXConverter(root: folder) else {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        let converted = converter.convert()
        let page = folder.appendingPathComponent("nota-document.html")
        do {
            try converted.html.write(to: page, atomically: true, encoding: .utf8)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        return DOCXDocument(
            fileURL: fileURL, unpackedURL: folder, pageURL: page, plainText: converted.text
        )
    }

    /// The conversion on its own, for a folder already unpacked — the tests'
    /// way in, which builds a document part by part rather than as a zip.
    static func html(ofUnpacked folder: URL) -> (html: String, text: String)? {
        guard var converter = DOCXConverter(root: folder) else { return nil }
        return converter.convert()
    }
}

// MARK: - Properties

/// A run's character formatting. Every field is optional: `nil` is "not said
/// here", so a style chain is folded by letting the nearer one's said values
/// win — and `false` is said, which is how a run turns its style's bold off.
struct DOCXRunProps {
    var bold: Bool?
    var italic: Bool?
    var underline: Bool?
    var strike: Bool?
    var caps: Bool?
    var smallCaps: Bool?
    var hidden: Bool?
    /// Points.
    var size: Double?
    /// `#RRGGBB`.
    var color: String?
    var highlight: String?
    var shading: String?
    var font: String?
    var vertAlign: String?

    mutating func merge(_ nearer: DOCXRunProps) {
        bold = nearer.bold ?? bold
        italic = nearer.italic ?? italic
        underline = nearer.underline ?? underline
        strike = nearer.strike ?? strike
        caps = nearer.caps ?? caps
        smallCaps = nearer.smallCaps ?? smallCaps
        hidden = nearer.hidden ?? hidden
        size = nearer.size ?? size
        color = nearer.color ?? color
        highlight = nearer.highlight ?? highlight
        shading = nearer.shading ?? shading
        font = nearer.font ?? font
        vertAlign = nearer.vertAlign ?? vertAlign
    }

    func merged(_ nearer: DOCXRunProps) -> DOCXRunProps {
        var copy = self
        copy.merge(nearer)
        return copy
    }

    /// The CSS for what is said, and nothing for what is not.
    var css: String {
        var parts: [String] = []
        if let bold { parts.append("font-weight:\(bold ? "bold" : "normal")") }
        if let italic { parts.append("font-style:\(italic ? "italic" : "normal")") }
        var lines: [String] = []
        if underline == true { lines.append("underline") }
        if strike == true { lines.append("line-through") }
        if !lines.isEmpty {
            parts.append("text-decoration:\(lines.joined(separator: " "))")
        } else if underline == false || strike == false {
            parts.append("text-decoration:none")
        }
        if caps == true { parts.append("text-transform:uppercase") }
        if smallCaps == true { parts.append("font-variant:small-caps") }
        if let size {
            // A superscript is drawn smaller by the browser already.
            parts.append("font-size:\(DOCXConverter.number(size))pt")
        }
        if let color { parts.append("color:\(color)") }
        if let background = highlight ?? shading { parts.append("background:\(background)") }
        if let font { parts.append("font-family:\(DOCXConverter.fontStack(font))") }
        if let vertAlign {
            if vertAlign == "superscript" {
                parts.append("vertical-align:super;font-size:smaller")
            } else if vertAlign == "subscript" {
                parts.append("vertical-align:sub;font-size:smaller")
            }
        }
        return parts.joined(separator: ";")
    }
}

/// A paragraph's formatting, in points, on the same "nearer wins" rule.
struct DOCXParaProps {
    var align: String?
    var left: Double?
    var right: Double?
    var firstLine: Double?
    var hanging: Double?
    var before: Double?
    var after: Double?
    /// Unitless (a share of single spacing) when `lineIsMultiple`, else points.
    var line: Double?
    var lineIsMultiple: Bool?
    var contextual: Bool?
    var numId: String?
    var level: Int?
    var outline: Int?
    var shading: String?
    var pageBreakBefore: Bool?

    mutating func merge(_ nearer: DOCXParaProps) {
        align = nearer.align ?? align
        left = nearer.left ?? left
        right = nearer.right ?? right
        // A first-line indent and a hanging one are one setting said two ways.
        if nearer.firstLine != nil || nearer.hanging != nil {
            firstLine = nearer.firstLine
            hanging = nearer.hanging
        }
        before = nearer.before ?? before
        after = nearer.after ?? after
        if nearer.line != nil {
            line = nearer.line
            lineIsMultiple = nearer.lineIsMultiple
        }
        contextual = nearer.contextual ?? contextual
        numId = nearer.numId ?? numId
        level = nearer.level ?? level
        outline = nearer.outline ?? outline
        shading = nearer.shading ?? shading
        pageBreakBefore = nearer.pageBreakBefore ?? pageBreakBefore
    }
}

// MARK: - The conversion

private struct DOCXStyle {
    var name: String
    var basedOn: String?
    var para = DOCXParaProps()
    var run = DOCXRunProps()
    /// A table style's own paragraph defaults and whether it rules its cells.
    var bordersTable = false
}

private struct DOCXLevel {
    var format = "decimal"
    var text = "%1."
    var start = 1
    var indent = DOCXParaProps()
    var font: String?
}

/// One pass over `word/document.xml`, with the parts it leans on read first.
/// A struct with the walk's own state in it — the list counters, the notes
/// met so far — so the whole conversion is one value that is used once.
private struct DOCXConverter {
    let root: URL
    let body: XMLElement
    var relationships: OfficeRelationships
    var styles: [String: DOCXStyle] = [:]
    var defaultParagraphStyle: String?
    var defaultRun = DOCXRunProps()
    var defaultPara = DOCXParaProps()
    var themeFonts: [String: String] = [:]
    /// abstractNumId → levels; numId → (abstractNumId, start overrides).
    var abstractLevels: [String: [Int: DOCXLevel]] = [:]
    var numbers: [String: (abstract: String, starts: [Int: Int])] = [:]
    var counters: [String: [Int: Int]] = [:]
    var notes: [String: [String: XMLElement]] = ["footnote": [:], "endnote": [:]]
    var noteOrder: [(kind: String, id: String)] = []
    var plain: [String] = []
    var pageWidth: Double = 612
    var margins = (top: 72.0, right: 72.0, bottom: 72.0, left: 72.0)
    var title: String?

    init?(root: URL) {
        self.root = root
        let documentURL = root.appendingPathComponent("word/document.xml")
        guard let document = try? XMLDocument(contentsOf: documentURL, options: []),
              let documentRoot = document.rootElement(),
              let body = documentRoot.child("body")
        else { return nil }
        self.body = body
        relationships = OfficeRelationships(
            relsAt: root.appendingPathComponent("word/_rels/document.xml.rels"),
            ownerFolder: "word/"
        )
        readTheme()
        readStyles()
        readNumbering()
        readNotes("footnote", file: "word/footnotes.xml")
        readNotes("endnote", file: "word/endnotes.xml")
        readTitle()
        if let section = body.child("sectPr") { readSection(section) }
    }

    // MARK: Parts

    private func xml(_ path: String) -> XMLElement? {
        let url = root.appendingPathComponent(path)
        return (try? XMLDocument(contentsOf: url, options: []))?.rootElement()
    }

    private mutating func readTheme() {
        guard let theme = xml("word/theme/theme1.xml") else { return }
        for (key, element) in [("major", "majorFont"), ("minor", "minorFont")] {
            if let face = theme.descendants(named: element).first?.child("latin")?
                .attr("typeface"), !face.isEmpty {
                themeFonts[key] = face
            }
        }
    }

    private mutating func readStyles() {
        guard let root = xml("word/styles.xml") else { return }
        if let defaults = root.child("docDefaults") {
            if let rPr = defaults.child("rPrDefault")?.child("rPr") { defaultRun = runProps(rPr) }
            if let pPr = defaults.child("pPrDefault")?.child("pPr") { defaultPara = paraProps(pPr) }
        }
        for element in root.children(named: "style") {
            guard let id = element.attr("styleId") else { continue }
            var style = DOCXStyle(name: element.val(of: "name") ?? id)
            style.basedOn = element.val(of: "basedOn")
            if let pPr = element.child("pPr") { style.para = paraProps(pPr) }
            if let rPr = element.child("rPr") { style.run = runProps(rPr) }
            if let borders = element.child("tblPr")?.child("tblBorders") {
                style.bordersTable = Self.hasBorders(borders)
            }
            styles[id] = style
            if element.attr("type") == "paragraph", element.attr("default") == "1" {
                defaultParagraphStyle = id
            }
        }
    }

    private mutating func readNumbering() {
        guard let root = xml("word/numbering.xml") else { return }
        for abstract in root.children(named: "abstractNum") {
            guard let id = abstract.attr("abstractNumId") else { continue }
            var levels: [Int: DOCXLevel] = [:]
            for lvl in abstract.children(named: "lvl") {
                guard let index = lvl.attr("ilvl").flatMap(Int.init) else { continue }
                var level = DOCXLevel()
                level.format = lvl.val(of: "numFmt") ?? "decimal"
                level.text = lvl.val(of: "lvlText") ?? ""
                level.start = lvl.val(of: "start").flatMap(Int.init) ?? 1
                if let pPr = lvl.child("pPr") { level.indent = paraProps(pPr) }
                level.font = lvl.child("rPr")?.child("rFonts")?.attr("ascii")
                levels[index] = level
            }
            abstractLevels[id] = levels
        }
        for num in root.children(named: "num") {
            guard let id = num.attr("numId"),
                  let abstract = num.val(of: "abstractNumId") else { continue }
            var starts: [Int: Int] = [:]
            for override in num.children(named: "lvlOverride") {
                if let level = override.attr("ilvl").flatMap(Int.init),
                   let start = override.val(of: "startOverride").flatMap(Int.init) {
                    starts[level] = start
                }
            }
            numbers[id] = (abstract, starts)
        }
    }

    private mutating func readNotes(_ kind: String, file: String) {
        guard let root = xml(file) else { return }
        for note in root.children(named: kind) {
            // The separator and continuation notes Word keeps for itself.
            guard let id = note.attr("id"), note.attr("type") == nil else { continue }
            notes[kind]?[id] = note
        }
    }

    private mutating func readTitle() {
        guard let core = xml("docProps/core.xml"),
              let value = core.child("title")?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return }
        title = value
    }

    private mutating func readSection(_ section: XMLElement) {
        if let width = section.child("pgSz")?.attr("w").flatMap(Double.init) {
            pageWidth = width / 20
        }
        if let margin = section.child("pgMar") {
            func twips(_ name: String, _ fallback: Double) -> Double {
                margin.attr(name).flatMap(Double.init).map { max(0, $0 / 20) } ?? fallback
            }
            margins = (twips("top", 72), twips("right", 72), twips("bottom", 72), twips("left", 72))
        }
    }

    // MARK: Reading properties

    private func runProps(_ rPr: XMLElement) -> DOCXRunProps {
        var props = DOCXRunProps()
        props.bold = rPr.toggle("b")
        props.italic = rPr.toggle("i")
        if let underline = rPr.child("u") {
            props.underline = (underline.attr("val") ?? "single") != "none"
        }
        props.strike = rPr.toggle("strike") ?? rPr.toggle("dstrike")
        props.caps = rPr.toggle("caps")
        props.smallCaps = rPr.toggle("smallCaps")
        props.hidden = rPr.toggle("vanish")
        props.size = rPr.val(of: "sz").flatMap(Double.init).map { $0 / 2 }
        if let color = rPr.val(of: "color"), let hex = Self.hex(color) { props.color = hex }
        if let highlight = rPr.val(of: "highlight") { props.highlight = Self.highlightColor(highlight) }
        if let fill = rPr.child("shd")?.attr("fill"), let hex = Self.hex(fill) { props.shading = hex }
        if let fonts = rPr.child("rFonts") { props.font = font(of: fonts) }
        props.vertAlign = rPr.val(of: "vertAlign")
        return props
    }

    private func font(of fonts: XMLElement) -> String? {
        if let name = fonts.attr("ascii") ?? fonts.attr("hAnsi") { return name }
        if let theme = fonts.attr("asciiTheme") ?? fonts.attr("hAnsiTheme") {
            return themeFonts[theme.hasPrefix("major") ? "major" : "minor"]
        }
        return fonts.attr("eastAsia")
    }

    private func paraProps(_ pPr: XMLElement) -> DOCXParaProps {
        var props = DOCXParaProps()
        if let jc = pPr.val(of: "jc") {
            switch jc {
            case "center": props.align = "center"
            case "right", "end": props.align = "right"
            case "both", "distribute": props.align = "justify"
            default: props.align = "left"
            }
        }
        if let ind = pPr.child("ind") {
            func twips(_ names: String...) -> Double? {
                for name in names {
                    if let value = ind.attr(name).flatMap(Double.init) { return value / 20 }
                }
                return nil
            }
            props.left = twips("left", "start")
            props.right = twips("right", "end")
            props.firstLine = twips("firstLine")
            props.hanging = twips("hanging")
        }
        if let spacing = pPr.child("spacing") {
            props.before = spacing.attr("before").flatMap(Double.init).map { $0 / 20 }
            props.after = spacing.attr("after").flatMap(Double.init).map { $0 / 20 }
            if spacing.attr("beforeAutospacing") == "1" { props.before = 14 }
            if spacing.attr("afterAutospacing") == "1" { props.after = 14 }
            if let line = spacing.attr("line").flatMap(Double.init) {
                let rule = spacing.attr("lineRule") ?? "auto"
                props.lineIsMultiple = rule == "auto"
                props.line = rule == "auto" ? line / 240 : line / 20
            }
        }
        props.contextual = pPr.toggle("contextualSpacing")
        if let numPr = pPr.child("numPr") {
            props.numId = numPr.val(of: "numId")
            props.level = numPr.val(of: "ilvl").flatMap(Int.init)
        }
        props.outline = pPr.val(of: "outlineLvl").flatMap(Int.init)
        if let fill = pPr.child("shd")?.attr("fill"), let hex = Self.hex(fill) { props.shading = hex }
        props.pageBreakBefore = pPr.toggle("pageBreakBefore")
        return props
    }

    /// A style's properties with everything it is based on folded under them.
    private func resolved(_ id: String?) -> DOCXStyle? {
        guard let id, let style = styles[id] else { return nil }
        var chain: [DOCXStyle] = [style]
        var next = style.basedOn
        var seen: Set<String> = [id]
        while let parent = next, !seen.contains(parent), let found = styles[parent] {
            seen.insert(parent)
            chain.append(found)
            next = found.basedOn
        }
        var result = DOCXStyle(name: style.name)
        for link in chain.reversed() {
            result.para.merge(link.para)
            result.run.merge(link.run)
            result.bordersTable = result.bordersTable || link.bordersTable
        }
        return result
    }

    // MARK: The walk

    mutating func convert() -> (html: String, text: String) {
        let content = blocks(of: body, tableDefaults: nil)
        var notesHTML = ""
        if !noteOrder.isEmpty {
            var items: [String] = []
            for (number, entry) in noteOrder.enumerated() {
                guard let note = notes[entry.kind]?[entry.id] else { continue }
                let inner = blocks(of: note, tableDefaults: nil)
                items.append(
                    "<li id=\"note-\(entry.kind)-\(entry.id)\" value=\"\(number + 1)\">\(inner)</li>"
                )
            }
            notesHTML = "<hr class=\"notes-rule\"><ol class=\"notes\">\(items.joined())</ol>"
        }
        return (page(content + notesHTML), plain.joined(separator: "\n"))
    }

    /// The paragraphs and tables of a body, a cell, a note or a text box.
    private mutating func blocks(of container: XMLElement, tableDefaults: DOCXParaProps?) -> String {
        var out: [String] = []
        let items = flattened(container.elementChildren)
        for (index, element) in items.enumerated() {
            switch element.local {
            case "p":
                let previous = index > 0 && items[index - 1].local == "p" ? items[index - 1] : nil
                let next = index + 1 < items.count && items[index + 1].local == "p"
                    ? items[index + 1] : nil
                out.append(paragraph(element, previous: previous, next: next,
                                     tableDefaults: tableDefaults))
            case "tbl":
                out.append(table(element))
            default:
                break
            }
        }
        return out.joined()
    }

    /// Content controls and custom XML hold paragraphs of their own; they are
    /// read as though they were not there.
    private func flattened(_ elements: [XMLElement]) -> [XMLElement] {
        elements.flatMap { element -> [XMLElement] in
            switch element.local {
            case "sdt": return flattened(element.child("sdtContent")?.elementChildren ?? [])
            case "customXml", "ins", "smartTag": return flattened(element.elementChildren)
            default: return [element]
            }
        }
    }

    private func styleID(of paragraph: XMLElement?) -> String? {
        paragraph?.child("pPr")?.val(of: "pStyle") ?? defaultParagraphStyle
    }

    private mutating func paragraph(
        _ element: XMLElement, previous: XMLElement?, next: XMLElement?,
        tableDefaults: DOCXParaProps?
    ) -> String {
        let pPr = element.child("pPr")
        let styleID = self.styleID(of: element)
        let style = resolved(styleID)

        var props = defaultPara
        if let tableDefaults { props.merge(tableDefaults) }
        if let style { props.merge(style.para) }
        let direct = pPr.map(paraProps) ?? DOCXParaProps()
        // A list's own indents sit between the style and what the paragraph
        // says itself.
        let listID = direct.numId ?? style?.para.numId
        let listLevel = direct.level ?? style?.para.level ?? 0
        var marker: String?
        if let listID, listID != "0", let level = level(listID, listLevel) {
            props.merge(level.indent)
            marker = nextMarker(listID, listLevel)
        }
        props.merge(direct)

        var css: [String] = []
        if let align = props.align { css.append("text-align:\(align)") }
        let left = props.left ?? 0
        if left != 0 { css.append("padding-left:\(Self.number(left))pt") }
        if let right = props.right, right != 0 { css.append("padding-right:\(Self.number(right))pt") }
        if let hanging = props.hanging, hanging != 0 {
            css.append("text-indent:-\(Self.number(hanging))pt")
        } else if let first = props.firstLine, first != 0 {
            css.append("text-indent:\(Self.number(first))pt")
        }
        var before = props.before ?? 0
        var after = props.after ?? 0
        if props.contextual == true {
            if previous != nil, self.styleID(of: previous) == styleID { before = 0 }
            if next != nil, self.styleID(of: next) == styleID { after = 0 }
        }
        if before != 0 { css.append("padding-top:\(Self.number(before))pt") }
        if after != 0 { css.append("padding-bottom:\(Self.number(after))pt") }
        if let line = props.line {
            css.append(props.lineIsMultiple == true
                ? "line-height:\(Self.number(line * 1.15))"
                : "line-height:\(Self.number(line))pt")
        }
        if let shading = props.shading { css.append("background:\(shading)") }
        if let run = style?.run.css, !run.isEmpty { css.append(run) }

        var inner = ""
        var words = ""
        if let marker {
            let markerCSS = props.hanging.map { "min-width:\(Self.number($0))pt" } ?? ""
            inner += "<span class=\"marker\" style=\"\(markerCSS)\">\(Self.escape(marker))</span>"
        }
        let runs = inline(element.elementChildren, words: &words)
        inner += runs
        plain.append(words)
        if words.isEmpty, !runs.contains("<img"), !runs.contains("<div") { inner += "<br>" }

        let headingLevel = style.flatMap { headingLevel(of: $0) }
        let tag = headingLevel.map { "h\(min(6, $0 + 1))" } ?? "p"
        var html = ""
        if props.pageBreakBefore == true { html += Self.pageBreak }
        // A page break inside a paragraph splits it: a rule cannot sit inside
        // a `<p>`, and the half on either side keeps the paragraph's look. A
        // half with nothing in it is left out.
        let open = "<\(tag) style=\"\(css.joined(separator: ";"))\">"
        let halves = inner.components(separatedBy: Self.pageBreak)
        for (index, half) in halves.enumerated() {
            if index > 0 { html += Self.pageBreak }
            let bare = half.replacingOccurrences(of: "<br>", with: "")
            if halves.count > 1, bare.isEmpty { continue }
            html += open + half + "</\(tag)>"
        }
        if pPr?.child("sectPr") != nil { html += Self.pageBreak }
        return html
    }

    static let pageBreak = "<hr class=\"page-break\">"

    private func headingLevel(of style: DOCXStyle) -> Int? {
        if let outline = style.para.outline, outline < 9 { return outline }
        let name = style.name.lowercased()
        if name == "title" { return 0 }
        if name.hasPrefix("heading "), let n = Int(name.dropFirst(8)), n >= 1 { return n - 1 }
        return nil
    }

    // MARK: Lists

    private func level(_ numID: String, _ index: Int) -> DOCXLevel? {
        guard let number = numbers[numID] else { return nil }
        return abstractLevels[number.abstract]?[index]
    }

    /// The next marker of a list at a level, counted the way Word counts: a
    /// level steps on, every level under it starts again.
    private mutating func nextMarker(_ numID: String, _ index: Int) -> String? {
        guard let number = numbers[numID], let levels = abstractLevels[number.abstract],
              let level = levels[index] else { return nil }
        var counts = counters[numID] ?? [:]
        let start = number.starts[index] ?? level.start
        counts[index] = counts[index].map { $0 + 1 } ?? start
        for deeper in counts.keys where deeper > index { counts[deeper] = nil }
        counters[numID] = counts

        if level.format == "bullet" { return Self.bullet(level.text, font: level.font) }
        if level.format == "none" { return level.text.isEmpty ? nil : level.text }
        var text = level.text
        for shown in 0 ... index {
            let placeholder = "%\(shown + 1)"
            guard text.contains(placeholder) else { continue }
            let value = counts[shown] ?? (number.starts[shown] ?? levels[shown]?.start ?? 1)
            let format = shown == index ? level.format : (levels[shown]?.format ?? "decimal")
            text = text.replacingOccurrences(of: placeholder, with: Self.counter(value, format))
        }
        return text
    }

    static func counter(_ value: Int, _ format: String) -> String {
        switch format {
        case "lowerLetter": return letters(value).lowercased()
        case "upperLetter": return letters(value)
        case "lowerRoman": return roman(value).lowercased()
        case "upperRoman": return roman(value)
        case "decimalZero": return value < 10 ? "0\(value)" : "\(value)"
        default: return "\(value)"
        }
    }

    private static func letters(_ value: Int) -> String {
        guard value > 0 else { return "\(value)" }
        // Word's way: a, b, …, z, aa, bb, … — the letter repeated.
        let letter = Character(UnicodeScalar(65 + (value - 1) % 26)!)
        return String(repeating: letter, count: (value - 1) / 26 + 1)
    }

    private static func roman(_ value: Int) -> String {
        guard value > 0, value < 4000 else { return "\(value)" }
        let table: [(Int, String)] = [
            (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
            (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
        ]
        var rest = value
        var out = ""
        for (amount, glyph) in table {
            while rest >= amount {
                out += glyph
                rest -= amount
            }
        }
        return out
    }

    /// A bullet as Word writes it is often a private-use character in Symbol
    /// or Wingdings; this is the character it draws.
    static func bullet(_ text: String, font: String?) -> String {
        guard let scalar = text.unicodeScalars.first else { return "•" }
        switch scalar.value {
        case 0xF0B7, 0xB7: return "•"
        case 0xF0A7, 0xA7: return "▪"
        case 0xF0D8: return "➢"
        case 0xF0FC: return "✓"
        case 0xF076: return "❖"
        case 0xF0E0: return "→"
        case 0xF000 ... 0xF0FF: return "•"
        default:
            if text == "o", font?.lowercased().contains("courier") == true { return "◦" }
            return text
        }
    }

    // MARK: Runs

    /// The inline content of a paragraph or a hyperlink: runs, links, fields
    /// and bookmarks, in order.
    private mutating func inline(_ elements: [XMLElement], words: inout String) -> String {
        var out = ""
        for element in elements {
            switch element.local {
            case "r":
                out += run(element, words: &words)
            case "hyperlink":
                let inner = inline(element.elementChildren, words: &words)
                if let id = element.attr("id"), let target = relationships[id], target.isExternal {
                    out += "<a href=\"\(Self.escape(target.path))\">\(inner)</a>"
                } else if let anchor = element.attr("anchor") {
                    out += "<a href=\"#\(Self.escape(anchor))\">\(inner)</a>"
                } else {
                    out += inner
                }
            case "bookmarkStart":
                if let name = element.attr("name"), !name.hasPrefix("_GoBack") {
                    out += "<a id=\"\(Self.escape(name))\"></a>"
                }
            case "fldSimple", "smartTag", "customXml", "ins", "dir", "bdo":
                out += inline(element.elementChildren, words: &words)
            case "sdt":
                out += inline(element.child("sdtContent")?.elementChildren ?? [], words: &words)
            case "AlternateContent":
                if let choice = element.child("Choice") {
                    out += inline(choice.elementChildren, words: &words)
                }
            default:
                break
            }
        }
        return out
    }

    private mutating func run(_ element: XMLElement, words: inout String) -> String {
        var props = DOCXRunProps()
        if let rPr = element.child("rPr") {
            if let id = rPr.val(of: "rStyle"), let style = resolved(id) { props.merge(style.run) }
            props.merge(runProps(rPr))
        }
        if props.hidden == true { return "" }
        var out = ""
        for part in element.elementChildren {
            switch part.local {
            case "t":
                let text = part.stringValue ?? ""
                words += text
                out += Self.escape(text)
            case "tab", "ptab":
                words += "\t"
                out += "<span class=\"tab\">\t</span>"
            case "br":
                out += part.attr("type") == "page" ? Self.pageBreak : "<br>"
            case "cr":
                out += "<br>"
            case "noBreakHyphen":
                words += "-"
                out += "&#8209;"
            case "softHyphen":
                out += "&shy;"
            case "sym":
                if let code = part.attr("char").flatMap({ UInt32($0, radix: 16) }),
                   let scalar = UnicodeScalar(code) {
                    out += Self.escape(Self.bullet(String(Character(scalar)), font: part.attr("font")))
                }
            case "drawing":
                out += drawing(part, words: &words)
            case "pict", "object":
                out += picture(part)
            case "AlternateContent":
                if let choice = part.child("Choice") {
                    for inner in choice.elementChildren where inner.local == "drawing" {
                        out += drawing(inner, words: &words)
                    }
                }
            case "footnoteReference", "endnoteReference":
                let kind = part.local == "footnoteReference" ? "footnote" : "endnote"
                if let id = part.attr("id") {
                    noteOrder.append((kind, id))
                    out += "<sup class=\"note-ref\"><a href=\"#note-\(kind)-\(id)\">"
                        + "\(noteOrder.count)</a></sup>"
                }
            default:
                break
            }
        }
        let css = props.css
        guard !css.isEmpty, !out.isEmpty else { return out }
        return "<span style=\"\(css)\">\(out)</span>"
    }

    // MARK: Pictures and text boxes

    private mutating func drawing(_ element: XMLElement, words: inout String) -> String {
        let isAnchored = element.child("anchor") != nil
        let frame = element.child("inline") ?? element.child("anchor")
        var width: Double?
        var height: Double?
        if let extent = frame?.child("extent") {
            width = extent.attr("cx").flatMap(Double.init).map { $0 / 12_700 }
            height = extent.attr("cy").flatMap(Double.init).map { $0 / 12_700 }
        }
        if let blip = element.descendants(named: "blip").first,
           let id = blip.attr("embed"), let target = relationships[id], !target.isExternal {
            return image(target.path, width: width, height: height, block: isAnchored)
        }
        // A text box: its paragraphs, in a frame of their own.
        if let box = element.descendants(named: "txbxContent").first {
            let inner = blocks(of: box, tableDefaults: nil)
            let size = width.map { "max-width:\(Self.number($0))pt" } ?? ""
            return "<div class=\"text-box\" style=\"\(size)\">\(inner)</div>"
        }
        return ""
    }

    /// The older VML picture an `<w:pict>` carries.
    private func picture(_ element: XMLElement) -> String {
        guard let data = element.descendants(named: "imagedata").first,
              let id = data.attr("id"), let target = relationships[id], !target.isExternal
        else { return "" }
        return image(target.path, width: nil, height: nil, block: false)
    }

    private func image(_ path: String, width: Double?, height: Double?, block: Bool) -> String {
        // A metafile is a Windows drawing WebKit cannot draw: a picture that
        // would be a broken-image box is better left out.
        let lower = path.lowercased()
        if lower.hasSuffix(".emf") || lower.hasSuffix(".wmf") { return "" }
        var css: [String] = []
        if let width { css.append("width:\(Self.number(width))pt") }
        if let height, width != nil { css.append("aspect-ratio:\(Self.number(width! / max(height, 1)))") }
        if block { css.append("display:block;margin:6pt auto") }
        return "<img src=\"\(Self.escape(path))\" style=\"\(css.joined(separator: ";"))\" alt=\"\">"
    }

    // MARK: Tables

    private struct Cell {
        let element: XMLElement
        let column: Int
        let span: Int
        /// `restart`, `continue`, or nil for a cell that merges nothing.
        let vMerge: String?
    }

    private mutating func table(_ element: XMLElement) -> String {
        let tblPr = element.child("tblPr")
        let style = resolved(tblPr?.val(of: "tblStyle"))
        var bordered = style?.bordersTable ?? false
        if let borders = tblPr?.child("tblBorders") { bordered = Self.hasBorders(borders) }
        let cellDefaults = style?.para

        // Every cell placed on the grid first, so a vertical merge can count
        // how many rows down it runs.
        var rows: [[Cell]] = []
        var rowElements: [XMLElement] = []
        for row in flattened(element.elementChildren) where row.local == "tr" {
            var column = row.child("trPr")?.val(of: "gridBefore").flatMap(Int.init) ?? 0
            var cells: [Cell] = []
            for cell in flattened(row.elementChildren) where cell.local == "tc" {
                let tcPr = cell.child("tcPr")
                let span = tcPr?.val(of: "gridSpan").flatMap(Int.init) ?? 1
                var vMerge: String?
                if let merge = tcPr?.child("vMerge") {
                    vMerge = merge.attr("val") == "restart" ? "restart" : "continue"
                }
                cells.append(Cell(element: cell, column: column, span: span, vMerge: vMerge))
                column += span
            }
            rows.append(cells)
            rowElements.append(row)
        }

        var widths: [Double] = []
        if let grid = element.child("tblGrid") {
            widths = grid.children(named: "gridCol").map {
                ($0.attr("w").flatMap(Double.init) ?? 0) / 20
            }
        }
        var css = ["border-collapse:collapse"]
        let total = widths.reduce(0, +)
        if let jc = tblPr?.val(of: "jc"), jc == "center" { css.append("margin-left:auto;margin-right:auto") }
        if total > 0 { css.append("width:\(Self.number(total))pt;max-width:100%") }

        var out = "<table class=\"\(bordered ? "ruled" : "plain")\" style=\"\(css.joined(separator: ";"))\">"
        if !widths.isEmpty {
            out += "<colgroup>" + widths.map { "<col style=\"width:\(Self.number($0))pt\">" }
                .joined() + "</colgroup>"
        }
        for (rowIndex, cells) in rows.enumerated() {
            var rowCSS = ""
            if let height = rowElements[rowIndex].child("trPr")?.child("trHeight")?.attr("val")
                .flatMap(Double.init) {
                rowCSS = "height:\(Self.number(height / 20))pt"
            }
            out += "<tr style=\"\(rowCSS)\">"
            for cell in cells where cell.vMerge != "continue" {
                var rowspan = 1
                if cell.vMerge == "restart" {
                    var below = rowIndex + 1
                    while below < rows.count,
                          rows[below].contains(where: {
                              $0.column == cell.column && $0.vMerge == "continue"
                          }) {
                        rowspan += 1
                        below += 1
                    }
                }
                let tcPr = cell.element.child("tcPr")
                var cellCSS: [String] = []
                if let fill = tcPr?.child("shd")?.attr("fill"), let hex = Self.hex(fill) {
                    cellCSS.append("background:\(hex)")
                }
                if let align = tcPr?.val(of: "vAlign") {
                    cellCSS.append("vertical-align:\(align == "center" ? "middle" : align)")
                }
                if let borders = tcPr?.child("tcBorders"), !bordered, Self.hasBorders(borders) {
                    cellCSS.append("border:0.5pt solid #000")
                }
                let inner = blocks(of: cell.element, tableDefaults: cellDefaults)
                out += "<td"
                if cell.span > 1 { out += " colspan=\"\(cell.span)\"" }
                if rowspan > 1 { out += " rowspan=\"\(rowspan)\"" }
                out += " style=\"\(cellCSS.joined(separator: ";"))\">\(inner)</td>"
            }
            out += "</tr>"
        }
        return out + "</table>"
    }

    private static func hasBorders(_ borders: XMLElement) -> Bool {
        borders.elementChildren.contains {
            let value = $0.attr("val") ?? "nil"
            return value != "nil" && value != "none"
        }
    }

    // MARK: The page

    private func page(_ content: String) -> String {
        let fontName = defaultRun.font ?? themeFonts["minor"] ?? "Calibri"
        let size = defaultRun.size ?? 11
        let width = Self.number(pageWidth)
        let pad = "\(Self.number(margins.top))pt \(Self.number(margins.right))pt "
            + "\(Self.number(margins.bottom))pt \(Self.number(margins.left))pt"
        let titleTag = title.map { "<title>\(Self.escape($0))</title>" } ?? ""
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width">\(titleTag)
        <style>
        html { background: #e8e8e8; }
        @media (prefers-color-scheme: dark) { html { background: #1f1f1f; } }
        body { margin: 0; padding: 28px 16px 56px; }
        .page {
          box-sizing: border-box; max-width: \(width)pt; margin: 0 auto; padding: \(pad);
          background: #fff; color: #000; color-scheme: light;
          font-family: \(Self.fontStack(fontName)); font-size: \(Self.number(size))pt;
          line-height: 1.15; overflow-wrap: break-word;
          box-shadow: 0 1px 4px rgba(0,0,0,.18), 0 0 0 .5px rgba(0,0,0,.08);
        }
        @media (max-width: 640px) { .page { padding: 28px 22px; } }
        .page p, .page h1, .page h2, .page h3, .page h4, .page h5, .page h6 {
          margin: 0; font-size: inherit; font-weight: normal; white-space: pre-wrap;
        }
        .marker { display: inline-block; text-indent: 0; padding-right: .4em; box-sizing: border-box; }
        .tab { white-space: pre; tab-size: 4; }
        img { max-width: 100%; height: auto; vertical-align: bottom; }
        table { margin: 2pt 0; }
        td { vertical-align: top; padding: 0 5.4pt; }
        table.ruled td { border: .5pt solid #000; }
        .text-box { border: .5pt solid #bbb; padding: 4pt 6pt; margin: 4pt 0; }
        hr.page-break { border: 0; border-top: 1px dashed #c8c8c8; margin: 18pt -12pt; }
        hr.notes-rule { border: 0; border-top: .5pt solid #000; width: 33%; margin: 24pt 0 8pt; }
        ol.notes { font-size: 85%; padding-left: 1.6em; margin: 0; }
        a { color: #0563c1; }
        @media print {
          html { background: none; }
          body { padding: 0; }
          .page { max-width: none; padding: 0; box-shadow: none; }
          hr.page-break { border: 0; margin: 0; break-after: page; }
        }
        </style></head>
        <body><div class="page">\(content)</div></body></html>
        """
    }

    // MARK: Helpers

    static func fontStack(_ name: String) -> String {
        let lower = name.lowercased()
        let generic: String
        if ["courier", "consolas", "mono", "menlo", "lucida console"].contains(where: lower.contains) {
            generic = "Menlo, monospace"
        } else if !lower.contains("sans"),
                  ["times", "cambria", "georgia", "garamond", "book", "baskerville", "palatino",
                   "serif", "minion", "constantia", "song", "ming", "宋", "明"]
                  .contains(where: lower.contains) {
            generic = "'Times New Roman', Georgia, serif"
        } else {
            generic = "'Helvetica Neue', Helvetica, Arial, sans-serif"
        }
        let quoted = name.replacingOccurrences(of: "'", with: "")
        return "'\(quoted)', \(generic)"
    }

    static func hex(_ value: String) -> String? {
        guard value.count == 6, value.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + value
    }

    static func highlightColor(_ name: String) -> String? {
        let table: [String: String] = [
            "yellow": "#ffff00", "green": "#00ff00", "cyan": "#00ffff", "magenta": "#ff00ff",
            "blue": "#0000ff", "red": "#ff0000", "darkBlue": "#000080", "darkCyan": "#008080",
            "darkGreen": "#008000", "darkMagenta": "#800080", "darkRed": "#800000",
            "darkYellow": "#808000", "darkGray": "#808080", "lightGray": "#c0c0c0",
            "black": "#000000", "white": "#ffffff",
        ]
        return table[name]
    }

    static func number(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(character)
            }
        }
        return out
    }
}
