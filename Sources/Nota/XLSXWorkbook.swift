import Foundation

/// An Excel workbook, read (SPEC "## Office documents and video"): every sheet
/// of an `.xlsx` as a `CSVTable`, so the grid a `.csv` is read in reads it too
/// — paging, sorting, ⌘F and ⌘C all come with it.
///
/// A sheet is laid out the way Excel shows it rather than the way a CSV is
/// read: the columns are named `A`, `B`, `C`, and every row from 1 to the last
/// one with anything in it is a row, empty ones included, so the `#` gutter
/// says the row number Excel would. What a cell shows is its value as Excel
/// would print it in the common cases — shared and inline strings, booleans,
/// errors, dates and times by their number format, percentages, and numbers
/// without a trailing `.0` — and the formula's last result rather than the
/// formula. Merged cells, colours and charts are not drawn.
final class XLSXWorkbook {
    struct Sheet {
        let name: String
        let table: CSVTable
    }

    let fileURL: URL
    let sheets: [Sheet]

    init(fileURL: URL, sheets: [Sheet]) {
        self.fileURL = fileURL
        self.sheets = sheets
    }

    /// `nil` for anything that is not a workbook: no `xl/workbook.xml`, or no
    /// sheet in it that could be read.
    static func open(_ fileURL: URL) -> XLSXWorkbook? {
        guard let folder = Unzip.toTemporaryFolder(fileURL, prefix: "Nota-XLSX") else { return nil }
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let sheets = read(unpacked: folder), !sheets.isEmpty else { return nil }
        return XLSXWorkbook(fileURL: fileURL, sheets: sheets)
    }

    /// The reading on its own, over a folder already unpacked.
    static func read(unpacked root: URL) -> [Sheet]? {
        let workbookURL = root.appendingPathComponent("xl/workbook.xml")
        guard let workbook = (try? XMLDocument(contentsOf: workbookURL, options: []))?
            .rootElement() else { return nil }
        let relationships = OfficeRelationships(
            relsAt: root.appendingPathComponent("xl/_rels/workbook.xml.rels"), ownerFolder: "xl/"
        )
        let uses1904 = workbook.child("workbookPr")?.attr("date1904")
            .map { $0 == "1" || $0 == "true" } ?? false
        let shared = SharedStrings.read(root.appendingPathComponent("xl/sharedStrings.xml"))
        let formats = NumberFormats.read(root.appendingPathComponent("xl/styles.xml"))

        var sheets: [Sheet] = []
        for sheet in workbook.child("sheets")?.children(named: "sheet") ?? [] {
            // A chart sheet has no cells, and a hidden one is hidden for a reason.
            guard sheet.attr("state") != "hidden", sheet.attr("state") != "veryHidden",
                  let id = sheet.attr("id"), let target = relationships[id],
                  target.path.hasPrefix("xl/worksheets/")
            else { continue }
            let name = sheet.attr("name") ?? "Sheet \(sheets.count + 1)"
            let reader = SheetReader(shared: shared, formats: formats, uses1904: uses1904)
            guard let table = reader.read(root.appendingPathComponent(target.path)) else { continue }
            sheets.append(Sheet(name: name, table: table))
        }
        return sheets
    }

    /// `A` for 0, `Z` for 25, `AA` for 26.
    static func columnName(_ index: Int) -> String {
        var name = ""
        var rest = index + 1
        while rest > 0 {
            let remainder = (rest - 1) % 26
            name = String(Character(UnicodeScalar(65 + remainder)!)) + name
            rest = (rest - 1) / 26
        }
        return name
    }

    /// `C7` → column 2. `nil` for a reference with no letters.
    static func columnIndex(ofReference reference: String) -> Int? {
        var index = 0
        var sawLetter = false
        for scalar in reference.unicodeScalars {
            guard scalar.value >= 65, scalar.value <= 90 else {
                guard scalar.value >= 97, scalar.value <= 122 else { break }
                index = index * 26 + Int(scalar.value - 96)
                sawLetter = true
                continue
            }
            index = index * 26 + Int(scalar.value - 64)
            sawLetter = true
        }
        return sawLetter ? index - 1 : nil
    }

    // MARK: - Shared strings

    private final class SharedStrings: NSObject, XMLParserDelegate {
        private(set) var strings: [String] = []
        private var current = ""
        private var inText = false
        /// Phonetic guides (`rPh`) carry text that is not the cell's.
        private var inPhonetic = false

        static func read(_ url: URL) -> [String] {
            guard let parser = XMLParser(contentsOf: url) else { return [] }
            let reader = SharedStrings()
            parser.delegate = reader
            parser.parse()
            return reader.strings
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            switch local(name) {
            case "si": current = ""
            case "t": inText = !inPhonetic
            case "rPh": inPhonetic = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                    qualifiedName: String?) {
            switch local(name) {
            case "si": strings.append(current)
            case "t": inText = false
            case "rPh": inPhonetic = false
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { current += string }
        }
    }

    // MARK: - Number formats

    /// Which style index (`s` on a cell) is a date, a time, a percentage, or
    /// a plain number.
    struct NumberFormats {
        enum Kind { case general, date, time, dateTime, percent }
        var kinds: [Kind] = []

        static func read(_ url: URL) -> NumberFormats {
            var formats = NumberFormats()
            guard let root = (try? XMLDocument(contentsOf: url, options: []))?.rootElement()
            else { return formats }
            var custom: [Int: String] = [:]
            for format in root.child("numFmts")?.children(named: "numFmt") ?? [] {
                if let id = format.attr("numFmtId").flatMap(Int.init), let code = format.attr("formatCode") {
                    custom[id] = code
                }
            }
            for xf in root.child("cellXfs")?.children(named: "xf") ?? [] {
                let id = xf.attr("numFmtId").flatMap(Int.init) ?? 0
                formats.kinds.append(kind(id: id, code: custom[id]))
            }
            return formats
        }

        static func kind(id: Int, code: String?) -> Kind {
            switch id {
            case 9, 10: return .percent
            case 14 ... 17, 27 ... 36, 50 ... 58: return .date
            case 18 ... 21, 45 ... 47: return .time
            case 22: return .dateTime
            default: break
            }
            guard let code else { return .general }
            // The quoted and bracketed parts are literal text and colours,
            // not the format's letters.
            var bare = ""
            var inQuote = false
            var inBracket = false
            for character in code {
                switch character {
                case "\"": inQuote.toggle()
                case "[" where !inQuote: inBracket = true
                case "]" where !inQuote: inBracket = false
                default: if !inQuote && !inBracket { bare.append(character) }
                }
            }
            let lower = bare.lowercased()
            if lower.contains("%") { return .percent }
            let hasDate = lower.contains("y") || lower.contains("d")
                || (lower.contains("m") && !lower.contains("h") && !lower.contains("s"))
            let hasTime = lower.contains("h") || lower.contains("s")
            if code.contains("[h]") || code.contains("[mm]") { return .time }
            switch (hasDate, hasTime) {
            case (true, true): return .dateTime
            case (true, false): return .date
            case (false, true): return .time
            default: return .general
            }
        }

        func kind(ofStyle index: Int?) -> Kind {
            guard let index, kinds.indices.contains(index) else { return .general }
            return kinds[index]
        }
    }

    // MARK: - A sheet

    /// A sheet's cells — row number (1-based) → column (0-based) → what the
    /// cell shows — laid out the way Excel shows them. Every reader of a
    /// workbook, whatever the file, hands its cells over here.
    ///
    /// The first row with anything in it is the header, the way a sheet of
    /// records is written: its words name the columns, so a sort never moves
    /// it in among the rows. A blank header cell is named by its column
    /// letter.
    static func table(cells: [Int: [Int: String]], maxRow: Int, maxColumn: Int) -> CSVTable {
        let width = maxColumn + 1
        guard let headerRow = cells.keys.min() else {
            return CSVTable(columns: (0 ..< width).map(columnName), rows: [])
        }
        let header = cells[headerRow] ?? [:]
        let columns = (0 ..< width).map { index -> String in
            let name = header[index]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? columnName(index) : name
        }
        let rows: [[String]] = headerRow >= maxRow ? [] : (headerRow + 1 ... maxRow).map {
            let line = cells[$0] ?? [:]
            return (0 ..< width).map { line[$0] ?? "" }
        }
        return CSVTable(columns: columns, rows: rows)
    }

    private final class SheetReader: NSObject, XMLParserDelegate {
        let shared: [String]
        let formats: NumberFormats
        let uses1904: Bool

        /// Row number (1-based) → column → shown value.
        private var cells: [Int: [Int: String]] = [:]
        private var maxRow = 0
        private var maxColumn = -1
        private var row = 0
        private var nextColumnInRow = 0

        private var cellColumn = 0
        private var cellType: String?
        private var cellStyle: Int?
        private var value = ""
        private var inline = ""
        private var collecting: String?
        private var inInline = false

        init(shared: [String], formats: NumberFormats, uses1904: Bool) {
            self.shared = shared
            self.formats = formats
            self.uses1904 = uses1904
        }

        func read(_ url: URL) -> CSVTable? {
            guard let parser = XMLParser(contentsOf: url) else { return nil }
            parser.delegate = self
            guard parser.parse() else { return nil }
            return XLSXWorkbook.table(cells: cells, maxRow: maxRow, maxColumn: maxColumn)
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            switch local(name) {
            case "row":
                row = attributes["r"].flatMap(Int.init) ?? row + 1
                nextColumnInRow = 0
            case "c":
                cellColumn = attributes["r"].flatMap(XLSXWorkbook.columnIndex(ofReference:))
                    ?? nextColumnInRow
                nextColumnInRow = cellColumn + 1
                cellType = attributes["t"]
                cellStyle = attributes["s"].flatMap(Int.init)
                value = ""
                inline = ""
            case "v":
                collecting = "v"
            case "is":
                inInline = true
            case "t" where inInline:
                collecting = "t"
            case "rPh":
                inInline = false
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                    qualifiedName: String?) {
            switch local(name) {
            case "v", "t":
                collecting = nil
            case "is":
                inInline = false
            case "c":
                let shown = display()
                guard !shown.isEmpty else { return }
                cells[row, default: [:]][cellColumn] = shown
                maxRow = max(maxRow, row)
                maxColumn = max(maxColumn, cellColumn)
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            switch collecting {
            case "v": value += string
            case "t": inline += string
            default: break
            }
        }

        private func display() -> String {
            switch cellType {
            case "s":
                guard let index = Int(value), shared.indices.contains(index) else { return "" }
                return shared[index]
            case "inlineStr":
                return inline
            case "str", "e":
                return value
            case "b":
                return value == "1" ? "TRUE" : "FALSE"
            default:
                guard let number = Double(value) else { return value }
                return XLSXWorkbook.format(number, as: formats.kind(ofStyle: cellStyle),
                                           uses1904: uses1904)
            }
        }
    }

    // MARK: - Showing a number

    static func format(_ number: Double, as kind: NumberFormats.Kind, uses1904: Bool) -> String {
        switch kind {
        case .general:
            return plain(number)
        case .percent:
            return plain((number * 100 * 1e8).rounded() / 1e8) + "%"
        case .date, .time, .dateTime:
            let epoch = uses1904
                ? DateComponents(year: 1904, month: 1, day: 1)
                : DateComponents(year: 1899, month: 12, day: 30)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            guard let start = calendar.date(from: epoch) else { return plain(number) }
            let seconds = (number * 86_400).rounded()
            let date = start.addingTimeInterval(seconds)
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            switch kind {
            case .date: formatter.dateFormat = "yyyy-MM-dd"
            case .time: formatter.dateFormat = "HH:mm:ss"
            default:
                formatter.dateFormat = seconds.truncatingRemainder(dividingBy: 86_400) == 0
                    ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm"
            }
            return formatter.string(from: date)
        }
    }

    /// A number the way General shows it: no trailing `.0`, and the
    /// floating-point dust Excel stores (`0.30000000000000004`) cut back to
    /// fifteen significant digits, which is all Excel keeps.
    static func plain(_ number: Double) -> String {
        if number == number.rounded(), abs(number) < 1e15 { return String(Int64(number)) }
        let text = String(format: "%.15g", number)
        return text
    }
}

private func local(_ name: String) -> String {
    guard let colon = name.lastIndex(of: ":") else { return name }
    return String(name[name.index(after: colon)...])
}
