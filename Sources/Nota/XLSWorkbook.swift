import Foundation

/// A legacy Excel workbook, read (SPEC "## Office documents and video"): an
/// Excel 97–2003 `.xls`, handed back as the same `XLSXWorkbook` an `.xlsx`
/// becomes, so the grid, the sheet tabs and the number formatting are shared.
///
/// The file is a compound file (`CompoundFile`) whose `Workbook` stream is a
/// run of BIFF8 records: a globals part (sheet names and where each starts,
/// the shared strings, the number formats, the date system) and then one part
/// per sheet, each opening with a BOF record and closing with an EOF. Every
/// record is a type, a length and a body. A cell is one record naming its row,
/// its column and its style (an XF index), so reading a sheet is walking its
/// records and keeping the ones that are cells.
///
/// Only BIFF8 is read. Excel 5 and 95 files (BIFF5, a `Book` stream) keep their
/// text in the machine's code page rather than in Unicode and are rare enough
/// now not to be worth a second string reader; they read as `nil`, as does a
/// workbook with a password.
enum XLSWorkbook {
    static func open(_ fileURL: URL) -> XLSXWorkbook? {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              let sheets = read(data), !sheets.isEmpty else { return nil }
        return XLSXWorkbook(fileURL: fileURL, sheets: sheets)
    }

    /// The reading on its own, over the file's bytes. `nil` for anything that
    /// is not a BIFF8 workbook, or one that is encrypted.
    static func read(_ data: Data) -> [XLSXWorkbook.Sheet]? {
        guard let file = CompoundFile(data: data),
              let stream = file.stream(named: "Workbook") ?? file.stream(named: "Book")
        else { return nil }
        let bytes = [UInt8](stream)
        let records = Record.all(in: bytes)
        guard let globals = Globals(records: records) else { return nil }

        var sheets: [XLSXWorkbook.Sheet] = []
        for sheet in globals.sheets {
            var reader = SheetReader(globals: globals, records: records)
            guard let first = records.firstIndex(where: { $0.offset == sheet.offset }),
                  let table = reader.read(from: first)
            else { continue }
            let name = sheet.name.isEmpty ? "Sheet \(sheets.count + 1)" : sheet.name
            sheets.append(XLSXWorkbook.Sheet(name: name, table: table))
        }
        return sheets
    }

    // MARK: - Records

    private struct Record {
        let type: Int
        /// Where the record's header starts in the stream; a sheet is found by
        /// the offset its BOUNDSHEET gives.
        let offset: Int
        let body: ArraySlice<UInt8>

        static let bof = 0x0809, eof = 0x000A, continuation = 0x003C
        static let filePass = 0x002F, dateMode = 0x0022, format = 0x041E, xf = 0x00E0
        static let boundSheet = 0x0085, sst = 0x00FC
        static let labelSST = 0x00FD, label = 0x0204, richLabel = 0x00D6, rk = 0x027E
        static let mulRK = 0x00BD, number = 0x0203, boolErr = 0x0205, formula = 0x0006
        static let string = 0x0207

        /// Every record in the stream, in order; a length that runs past the
        /// end stops the list there.
        static func all(in bytes: [UInt8]) -> [Record] {
            var records: [Record] = []
            var offset = 0
            while let type = bytes.littleEndian16(at: offset),
                  let length = bytes.littleEndian16(at: offset + 2),
                  offset + 4 + length <= bytes.count {
                records.append(Record(type: type, offset: offset,
                                      body: bytes[offset + 4 ..< offset + 4 + length]))
                offset += 4 + length
            }
            return records
        }

        func uint16(_ at: Int) -> Int? {
            let index = body.startIndex + at
            guard at >= 0, index + 2 <= body.endIndex else { return nil }
            return Int(body[index]) | Int(body[index + 1]) << 8
        }

        func uint32(_ at: Int) -> Int? {
            guard let low = uint16(at), let high = uint16(at + 2) else { return nil }
            return high << 16 | low
        }

        func double(_ at: Int) -> Double? {
            guard let low = uint32(at), let high = uint32(at + 4) else { return nil }
            return Double(bitPattern: UInt64(high) << 32 | UInt64(low))
        }

        func byte(_ at: Int) -> UInt8? {
            let index = body.startIndex + at
            guard at >= 0, index < body.endIndex else { return nil }
            return body[index]
        }

        /// The body and those of the CONTINUE records after `index`: a record
        /// is at most 8224 bytes, and longer data (the shared strings, a long
        /// formula result) carries on in CONTINUEs.
        static func continued(from index: Int, in records: [Record]) -> [ArraySlice<UInt8>] {
            var parts = [records[index].body]
            var next = index + 1
            while next < records.count, records[next].type == continuation {
                parts.append(records[next].body)
                next += 1
            }
            return parts
        }
    }

    /// Reads across a record and its CONTINUEs as one run of bytes, except
    /// inside a string's characters: there a CONTINUE opens with a fresh flag
    /// byte saying whether the rest are one byte or two each.
    private struct Reader {
        let parts: [ArraySlice<UInt8>]
        private var part = 0
        private var position: Int

        init(_ parts: [ArraySlice<UInt8>], skipping skip: Int = 0) {
            self.parts = parts
            position = parts.first?.startIndex ?? 0
            self.skip(skip)
        }

        /// Steps over the ends of parts, so the next byte read is a real one.
        private mutating func settle() {
            while part < parts.count, position >= parts[part].endIndex {
                part += 1
                guard part < parts.count else { return }
                position = parts[part].startIndex
            }
        }

        mutating func byte() -> UInt8? {
            settle()
            guard part < parts.count else { return nil }
            defer { position += 1 }
            return parts[part][position]
        }

        mutating func uint16() -> Int? {
            guard let low = byte(), let high = byte() else { return nil }
            return Int(low) | Int(high) << 8
        }

        mutating func uint32() -> Int? {
            guard let low = uint16(), let high = uint16() else { return nil }
            return high << 16 | low
        }

        /// Moves on `count` bytes across parts, stopping at the last one's
        /// end; a corrupt size can be billions, so it is not walked a byte at
        /// a time.
        mutating func skip(_ count: Int) {
            var left = max(0, count)
            while left > 0 {
                settle()
                guard part < parts.count else { return }
                let step = min(left, parts[part].endIndex - position)
                position += step
                left -= step
            }
        }

        /// An Excel string: a character count (`countBytes` wide), a flag byte,
        /// and then — when `extended` and the flags say so — a run count and a
        /// phonetic-block size, the characters, and the runs and block, both
        /// skipped. Characters one byte wide are Latin-1, the low half of their
        /// UTF-16 unit.
        mutating func string(countBytes: Int = 2, extended: Bool = false) -> String? {
            guard let count = countBytes == 1 ? byte().map(Int.init) : uint16(),
                  var flags = byte() else { return nil }
            var runs = 0
            var phonetic = 0
            if extended {
                if flags & 0x08 != 0 { guard let value = uint16() else { return nil }; runs = value }
                if flags & 0x04 != 0 { guard let value = uint32() else { return nil }; phonetic = value }
            }
            var units: [UInt16] = []
            units.reserveCapacity(count)
            while units.count < count {
                guard part < parts.count else { return nil }
                if position >= parts[part].endIndex {
                    // The characters carry on in the next CONTINUE, which
                    // says afresh how wide they are.
                    part += 1
                    guard part < parts.count else { return nil }
                    position = parts[part].startIndex
                    guard let fresh = byte() else { return nil }
                    flags = fresh
                    continue
                }
                let wide = flags & 0x01 != 0
                let available = (parts[part].endIndex - position) / (wide ? 2 : 1)
                let take = min(available, count - units.count)
                for index in 0 ..< take {
                    let at = position + index * (wide ? 2 : 1)
                    units.append(wide ? UInt16(parts[part][at]) | UInt16(parts[part][at + 1]) << 8
                                      : UInt16(parts[part][at]))
                }
                position += take * (wide ? 2 : 1)
                // A lone byte left at the end of a part is half a character
                // no writer should leave; drop it rather than stall.
                if take == 0 { position = parts[part].endIndex }
            }
            skip(runs * 4 + phonetic)
            return String(decoding: units, as: UTF16.self)
        }
    }

    // MARK: - Globals

    private struct Globals {
        struct SheetEntry {
            let name: String
            let offset: Int
        }

        var sheets: [SheetEntry] = []
        var strings: [String] = []
        var uses1904 = false
        var formats = XLSXWorkbook.NumberFormats()

        /// `nil` unless the stream opens with a BIFF8 globals BOF, or when it
        /// carries a FILEPASS (the rest is encrypted).
        init?(records: [Record]) {
            guard let bof = records.first, bof.type == Record.bof,
                  bof.uint16(0) == 0x0600, bof.uint16(2) == 0x0005
            else { return nil }
            var codes: [Int: String] = [:]
            var styleFormats: [Int] = []
            scan: for index in records.indices.dropFirst() {
                let record = records[index]
                switch record.type {
                case Record.eof:
                    break scan
                case Record.filePass:
                    return nil
                case Record.dateMode:
                    uses1904 = record.uint16(0) == 1
                case Record.format:
                    var reader = Reader([record.body], skipping: 2)
                    if let id = record.uint16(0), let code = reader.string() { codes[id] = code }
                case Record.xf:
                    styleFormats.append(record.uint16(2) ?? 0)
                case Record.boundSheet:
                    // The low two bits of the state byte: 1 hidden, 2 very
                    // hidden. The type byte: 0 a worksheet (2 a chart, 6 a
                    // macro module), and only worksheets have cells.
                    guard let offset = record.uint32(0), let state = record.byte(4),
                          state & 0x03 == 0, record.byte(5) == 0
                    else { continue }
                    var reader = Reader([record.body], skipping: 6)
                    sheets.append(SheetEntry(name: reader.string(countBytes: 1) ?? "", offset: offset))
                case Record.sst:
                    var reader = Reader(Record.continued(from: index, in: records), skipping: 8)
                    let unique = record.uint32(4) ?? 0
                    // The count is read from the file; the strings are what
                    // bounds the loop.
                    while strings.count < unique, let text = reader.string(extended: true) {
                        strings.append(text)
                    }
                default:
                    continue
                }
            }
            formats.kinds = styleFormats.map { XLSXWorkbook.NumberFormats.kind(id: $0, code: codes[$0]) }
        }
    }

    // MARK: - A sheet

    private struct SheetReader {
        let globals: Globals
        let records: [Record]

        /// Row number (1-based) → column → shown value.
        private var cells: [Int: [Int: String]] = [:]
        private var maxRow = 0
        private var maxColumn = -1

        init(globals: Globals, records: [Record]) {
            self.globals = globals
            self.records = records
        }

        /// The sheet whose BOF is `records[first]`. A chart drawn on the sheet
        /// is a part of its own nested inside, BOF to EOF, and its records are
        /// not the sheet's cells.
        mutating func read(from first: Int) -> CSVTable? {
            guard records[first].type == Record.bof, records[first].uint16(0) == 0x0600,
                  records[first].uint16(2) == 0x0010
            else { return nil }
            var depth = 0
            // A formula whose result is text names the cell; the text is in
            // the STRING record that follows it.
            var awaitingString: (row: Int, column: Int)?
            for index in first ..< records.count {
                let record = records[index]
                if record.type == Record.bof { depth += 1; continue }
                if record.type == Record.eof {
                    depth -= 1
                    if depth == 0 { break }
                    continue
                }
                guard depth == 1 else { continue }
                if record.type == Record.string, let cell = awaitingString {
                    var reader = Reader(Record.continued(from: index, in: records))
                    put(reader.string() ?? "", row: cell.row, column: cell.column)
                    awaitingString = nil
                    continue
                }
                guard let row = record.uint16(0), let column = record.uint16(2) else { continue }
                let style = record.uint16(4)
                switch record.type {
                case Record.labelSST:
                    guard let shared = record.uint32(6), globals.strings.indices.contains(shared) else { continue }
                    put(globals.strings[shared], row: row, column: column)
                case Record.label, Record.richLabel:
                    var reader = Reader([record.body], skipping: 6)
                    put(reader.string() ?? "", row: row, column: column)
                case Record.rk:
                    guard let raw = record.uint32(6) else { continue }
                    put(number(Self.rk(UInt32(raw)), style: style), row: row, column: column)
                case Record.mulRK:
                    // Style and value pairs, six bytes each, from the first
                    // column on; the last column closes the record.
                    let count = (record.body.count - 6) / 6
                    for offset in 0 ..< max(0, count) {
                        guard let raw = record.uint32(6 + offset * 6) else { break }
                        put(number(Self.rk(UInt32(raw)), style: record.uint16(4 + offset * 6)),
                            row: row, column: column + offset)
                    }
                case Record.number:
                    guard let value = record.double(6) else { continue }
                    put(number(value, style: style), row: row, column: column)
                case Record.boolErr:
                    guard let value = record.byte(6), let isError = record.byte(7) else { continue }
                    put(isError != 0 ? Self.error(value) : value != 0 ? "TRUE" : "FALSE",
                        row: row, column: column)
                case Record.formula:
                    // The last result, eight bytes: a number, or — when the
                    // top two bytes are FFFF — a tag in the first byte.
                    guard let tag = record.byte(6), record.body.count >= 14 else { continue }
                    guard record.uint16(12) == 0xFFFF else {
                        if let value = record.double(6) { put(number(value, style: style), row: row, column: column) }
                        continue
                    }
                    switch tag {
                    case 0: awaitingString = (row, column)
                    case 1: put(record.byte(8) != 0 ? "TRUE" : "FALSE", row: row, column: column)
                    case 2: put(Self.error(record.byte(8) ?? 0), row: row, column: column)
                    default: break
                    }
                default:
                    continue
                }
            }
            return XLSXWorkbook.table(cells: cells, maxRow: maxRow, maxColumn: maxColumn)
        }

        private mutating func put(_ shown: String, row: Int, column: Int) {
            guard !shown.isEmpty else { return }
            cells[row + 1, default: [:]][column] = shown
            maxRow = max(maxRow, row + 1)
            maxColumn = max(maxColumn, column)
        }

        private func number(_ value: Double, style: Int?) -> String {
            XLSXWorkbook.format(value, as: globals.formats.kind(ofStyle: style), uses1904: globals.uses1904)
        }

        /// An RK is a number packed into 32 bits: the low bit says divide by
        /// 100, the next says the rest is a signed 30-bit integer rather than
        /// the top 30 bits of a double.
        static func rk(_ raw: UInt32) -> Double {
            let value = raw & 0x02 != 0
                ? Double(Int32(bitPattern: raw) >> 2)
                : Double(bitPattern: UInt64(raw & 0xFFFF_FFFC) << 32)
            return raw & 0x01 != 0 ? value / 100 : value
        }

        static func error(_ code: UInt8) -> String {
            switch code {
            case 0x00: return "#NULL!"
            case 0x07: return "#DIV/0!"
            case 0x0F: return "#VALUE!"
            case 0x17: return "#REF!"
            case 0x1D: return "#NAME?"
            case 0x24: return "#NUM!"
            case 0x2A: return "#N/A"
            case 0x2B: return "#GETTING_DATA"
            default: return "#ERROR!"
            }
        }
    }
}
