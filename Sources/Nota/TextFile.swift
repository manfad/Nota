import AppKit
import Foundation
import UniformTypeIdentifiers

/// How a file's lines end. Nota keeps whatever the file already used rather
/// than rewriting a CRLF file the first time it is saved.
enum LineEnding: String, Codable {
    case lf, crlf

    var characters: String { self == .crlf ? "\r\n" : "\n" }

    /// What the footer's menu, and the footer itself, calls it.
    var displayName: String { self == .crlf ? "CRLF" : "LF" }
}

/// Everything about a file that has to survive a round trip through the
/// editor without being part of the text: which bytes the characters were
/// in, whether a byte-order mark led them, and how the lines ended.
struct TextFileFormat: Equatable {
    var encoding: String.Encoding
    var hadBOM: Bool
    var lineEnding: LineEnding

    /// What a note that has never been a file is written in.
    static let `default` = TextFileFormat(encoding: .utf8, hadBOM: false, lineEnding: .lf)

    /// The four encodings the footer's menu offers, in Todo 2's own order.
    static let selectableEncodings: [String.Encoding] = [
        .utf8, .utf16LittleEndian, .isoLatin1, .windowsCP1252,
    ]

    /// What the footer, and the menu that converts it, calls an encoding.
    /// UTF-16 is offered as one item regardless of which byte order the file
    /// is actually in, so both directions answer the same name here.
    static func displayName(for encoding: String.Encoding) -> String {
        switch encoding {
        case .utf8: return "UTF-8"
        case .utf16LittleEndian, .utf16BigEndian, .utf16: return "UTF-16"
        case .isoLatin1: return "Latin-1"
        case .windowsCP1252: return "Windows-1252"
        default: return "Unknown"
        }
    }
}

extension TextFileFormat: Codable {
    private enum CodingKeys: String, CodingKey { case encoding, hadBOM, lineEnding }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.encoding = String.Encoding(
            rawValue: try container.decode(UInt.self, forKey: .encoding)
        )
        self.hadBOM = try container.decode(Bool.self, forKey: .hadBOM)
        self.lineEnding = try container.decode(LineEnding.self, forKey: .lineEnding)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(encoding.rawValue, forKey: .encoding)
        try container.encode(hadBOM, forKey: .hadBOM)
        try container.encode(lineEnding, forKey: .lineEnding)
    }
}

/// Reading and writing plain text of any kind — the Notepad++ model. Nota
/// opens whatever is text, remembers the shape it was in, and puts that shape
/// back on ⌘S; the only thing it refuses is bytes that are not text at all.
///
/// Inside the app there is exactly one shape: UTF-8 characters with LF line
/// breaks. The editor, the counts, the gutter and vim all assume `\n`, so a
/// CRLF file is normalised on the way in and re-broken on the way out.
enum TextFile {
    /// How much of a file is looked at before deciding whether it is text.
    static let sniffLength = 8 * 1024

    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]
    private static let utf16LittleEndianBOM: [UInt8] = [0xFF, 0xFE]
    private static let utf16BigEndianBOM: [UInt8] = [0xFE, 0xFF]

    // MARK: - Reading

    /// Opens a file as text. `nil` means it could not be read, or it is not
    /// text — the caller is the one that says so to the user.
    static func read(at url: URL) -> (text: String, format: TextFileFormat)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    /// Bytes to text, working out the encoding the way Notepad++ does: a
    /// byte-order mark if there is one, then UTF-8, then the 8-bit fallbacks
    /// — Windows-1252 first, since that is what "ANSI" means in practice, and
    /// Latin-1 after it, which can never fail. `nil` means the bytes are not
    /// text: only a real binary gets that far.
    static func decode(_ data: Data) -> (text: String, format: TextFileFormat)? {
        // The mark is asked first because UTF-16 is full of NUL bytes and
        // would otherwise look binary.
        if data.starts(with: utf8BOM) {
            guard let text = String(data: data.dropFirst(utf8BOM.count), encoding: .utf8)
            else { return nil }
            return interpret(text, encoding: .utf8, hadBOM: true)
        }
        if data.starts(with: utf16LittleEndianBOM),
           let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
            return interpret(text, encoding: .utf16LittleEndian, hadBOM: true)
        }
        if data.starts(with: utf16BigEndianBOM),
           let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
            return interpret(text, encoding: .utf16BigEndian, hadBOM: true)
        }

        guard !isBinary(data) else { return nil }
        if let text = String(data: data, encoding: .utf8) {
            return interpret(text, encoding: .utf8, hadBOM: false)
        }
        if let text = String(data: data, encoding: .windowsCP1252) {
            return interpret(text, encoding: .windowsCP1252, hadBOM: false)
        }
        guard let text = String(data: data, encoding: .isoLatin1) else { return nil }
        return interpret(text, encoding: .isoLatin1, hadBOM: false)
    }

    /// A NUL byte in the first 8 KB is what tells an executable, an archive
    /// or a `.docx` from a text file. Nothing else is refused.
    static func isBinary(_ data: Data) -> Bool {
        data.prefix(sniffLength).contains(0)
    }

    /// Majority wins, and a file with no line breaks at all is LF — the same
    /// thing a brand new note is.
    static func lineEnding(of text: String) -> LineEnding {
        var crlf = 0
        var lf = 0
        var previous: UInt8 = 0
        for byte in text.utf8 {
            if byte == 0x0A {
                if previous == 0x0D { crlf += 1 } else { lf += 1 }
            }
            previous = byte
        }
        return crlf > lf ? .crlf : .lf
    }

    /// The one shape the storage ever holds. A lone CR — a file from System 9
    /// — is a line break too, and becomes one rather than a stray character
    /// the editor would have to reason about.
    static func normalized(_ text: String) -> String {
        // Asked of the bytes, not the characters: Swift reads CRLF as one
        // Character, which `contains("\r")` would say nothing about.
        guard text.utf8.contains(0x0D) else { return text }
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func interpret(
        _ raw: String, encoding: String.Encoding, hadBOM: Bool
    ) -> (text: String, format: TextFileFormat) {
        let format = TextFileFormat(
            encoding: encoding, hadBOM: hadBOM, lineEnding: lineEnding(of: raw)
        )
        return (normalized(raw), format)
    }

    // MARK: - Writing

    /// The bytes for `text` in the shape the file was opened in — and the
    /// format they are actually in, which is the one asked for unless the
    /// note has since grown characters that encoding cannot hold. Losing an
    /// emoji would be worse than widening a Latin-1 file to UTF-8, so the
    /// widening is what happens, and the caller remembers it.
    static func encode(
        _ text: String, format: TextFileFormat
    ) -> (data: Data, format: TextFileFormat) {
        let broken = format.lineEnding == .crlf
            ? text.replacingOccurrences(of: "\n", with: "\r\n")
            : text
        if let body = broken.data(using: format.encoding) {
            return (byteOrderMark(for: format) + body, format)
        }
        var widened = format
        widened.encoding = .utf8
        widened.hadBOM = false
        return (Data(broken.utf8), widened)
    }

    /// Whether `text` survives a trip through `encoding` unchanged — an `é`
    /// in Windows-1252 does, an emoji does not. What the footer's menu asks
    /// before it lets a conversion be picked, and `encode` itself never has
    /// to widen from a shape the menu already refused.
    static func canRepresent(_ text: String, in encoding: String.Encoding) -> Bool {
        text.data(using: encoding) != nil
    }

    private static func byteOrderMark(for format: TextFileFormat) -> Data {
        guard format.hadBOM else { return Data() }
        switch format.encoding {
        case .utf8: return Data(utf8BOM)
        case .utf16LittleEndian: return Data(utf16LittleEndianBOM)
        case .utf16BigEndian: return Data(utf16BigEndianBOM)
        default: return Data()
        }
    }

    // MARK: - Types

    /// Text on paper but not text to Nota on purpose: an RTF's or an
    /// archive's own wrapper is plain ASCII and would decode as text as
    /// happily as a real note, but SPEC rules them out by what they are
    /// regardless — an image belongs to the asset store, not to a tab, and a
    /// rich-text or zipped file is not a note either. PDF is not in this
    /// list: it is content Nota opens, only as a viewer instead of an
    /// editor, so `FileSniff` decides it by its magic bytes rather than by
    /// exclusion. Nor is video: the system files `.ts` and `.mts` under
    /// MPEG-2 transport stream, and a TypeScript module dropped on the window
    /// used to be refused for it. A real video never decodes as text, so when
    /// the bytes say text the name's claim to be a film is simply wrong.
    static let deliberatelyExcludedTypes: [UTType] = [
        .rtf, .image, .archive,
    ]

    /// The same list, plus PDF and video, for the places that are still
    /// deciding by extension alone rather than by content — where a `.ts`
    /// that cannot be read really might be a film.
    private static let excludedTypes: [UTType] = deliberatelyExcludedTypes
        + [.pdf, .audiovisualContent]

    /// Whether a file dropped on the editor is one to open in a tab. A type
    /// the system knows answers for itself; a `.toml` or a `.env` has no UTI
    /// at all, so its first bytes are asked instead.
    static func isTextFile(at url: URL) -> Bool {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return false
        }
        if let type = UTType(filenameExtension: url.pathExtension) {
            if excludedTypes.contains(where: type.conforms(to:)) { return false }
            if type.conforms(to: .text) || type.conforms(to: .sourceCode) { return true }
        }
        guard let head = head(of: url) else { return false }
        return decode(head) != nil
    }

    /// Whether `url`'s extension is one of the types Nota refuses to open as
    /// a note no matter what its bytes look like.
    static func isDeliberatelyExcluded(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return deliberatelyExcludedTypes.contains(where: type.conforms(to:))
    }

    /// The plain text of an RTF file or an RTFD package, if `url` really is
    /// one — decided by asking `NSAttributedString` to parse it rather than
    /// by its extension alone, so a `.rtf` that turns out to hold something
    /// else (plain text under the wrong suffix, say) comes back `nil` and is
    /// left to the ordinary open rules instead of being imported. `nil` for
    /// any other extension without even trying. This is `MainWindowController
    /// .open(url:)`'s one look at an RTF's bytes, asked before
    /// `isDeliberatelyExcluded` would otherwise refuse it outright: import
    /// rather than the ordinary text-editing path, since Nota drops the
    /// formatting and any pictures rather than keeping them.
    static func rtfPlainText(at url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if ext == "rtfd" {
            guard let wrapper = try? FileWrapper(url: url, options: []),
                  let attributed = NSAttributedString(rtfdFileWrapper: wrapper, documentAttributes: nil)
            else { return nil }
            return attributed.string
        }
        guard ext == "rtf",
              let data = try? Data(contentsOf: url),
              let attributed = NSAttributedString(rtf: data, documentAttributes: nil)
        else { return nil }
        return attributed.string
    }

    /// The first 8 KB, so sniffing a huge log does not read the whole thing.
    /// `nil` means the file could not be opened at all — missing, a
    /// directory, or no permission — which is what `FileSniff` calls
    /// unreadable rather than binary.
    static func head(of url: URL) -> Data? {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return nil
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: sniffLength)) ?? Data()
    }

    /// What the save panel offers. Markdown leads because that is Nota's
    /// default; everything else the panel accepts comes from
    /// `allowsOtherFileTypes`, which is what keeps a typed `.toml` a `.toml`.
    static let contentTypes: [UTType] = {
        var types: [UTType] = []
        for name in ["md", "tex", "txt", "json", "xml", "html", "css", "js", "yaml",
                     "csv", "log", "sh", "py", "swift"] {
            if let type = UTType(filenameExtension: name), !types.contains(type) {
                types.append(type)
            }
        }
        for umbrella in [UTType.plainText, .sourceCode, .text] where !types.contains(umbrella) {
            types.append(umbrella)
        }
        return types
    }()
}

// MARK: - Sniffing

/// What a file's own bytes say it is, decided before its name is ever asked.
/// This is the one place Nota reads a file's content to answer that
/// question; everywhere else — `MainWindowController.open(url:)`,
/// `Note.isOpenable`, restoring a session tab — asks `FileSniff` first and
/// only falls back to the extension when the bytes cannot say anything at
/// all.
enum FileClass {
    /// `%PDF-` at the start of the file, a byte-order mark or not.
    case pdf
    /// A zip whose first entry is a stored `mimetype` reading
    /// `application/epub+zip` — which is what an EPUB is, by specification.
    case epub
    /// One of the picture formats `NSImage` draws, known by the bytes every
    /// one of them starts with.
    case image
    /// Not a PDF or a picture, and `TextFile.decode` can make sense of the
    /// bytes.
    case text
    /// Readable, but none of the above — a real binary.
    case binary
    /// Could not be read at all: missing, a directory, or no permission.
    /// Nothing about the file is known, so the caller falls back to its
    /// name, the one thing left to go on.
    case unreadable
}

enum FileSniff {
    private static let pdfMagic: [UInt8] = Array("%PDF-".utf8)
    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]
    /// A zip's local file header, which every archive starts with.
    private static let zipMagic: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
    private static let epubEntryName: [UInt8] = Array("mimetype".utf8)
    private static let epubMediaType: [UInt8] = Array("application/epub+zip".utf8)

    /// Classifies a file by its first 8 KB, in order: the PDF signature, the
    /// picture signatures, the EPUB container's own first entry, then whether
    /// `TextFile.decode` reads the bytes as text, and binary for everything
    /// else that could still be read.
    static func classify(at url: URL) -> FileClass {
        guard let head = TextFile.head(of: url) else { return .unreadable }
        if isPDF(head) { return .pdf }
        if isImage(head) { return .image }
        if isEPUB(head) { return .epub }
        if TextFile.decode(head) != nil { return .text }
        return .binary
    }

    /// A PDF is never actually preceded by a byte-order mark, but a file
    /// that somehow was should still be known for what it is rather than
    /// mistaken for text with a stray mark at the front.
    private static func isPDF(_ head: Data) -> Bool {
        var bytes = head
        if bytes.starts(with: utf8BOM) { bytes = bytes.dropFirst(utf8BOM.count) }
        return bytes.starts(with: pdfMagic)
    }

    /// What every picture Nota opens starts with. Each of these is long
    /// enough not to be mistaken for the first line of a file of prose —
    /// which is why `BM`, all a bitmap has, is not in the list and a `.bmp`
    /// is known by its name instead.
    private static let imageMagics: [[UInt8]] = [
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],   // PNG
        [0xFF, 0xD8, 0xFF],                                  // JPEG
        Array("GIF87a".utf8), Array("GIF89a".utf8),          // GIF
        [0x49, 0x49, 0x2A, 0x00], [0x4D, 0x4D, 0x00, 0x2A],  // TIFF, either way round
    ]

    /// The brands of the ISO container HEIC and its relatives use. They sit
    /// four bytes in, after the box length, rather than at the front.
    private static let heifBrands = ["heic", "heix", "hevc", "hevx", "mif1", "msf1"]

    /// An EPUB, told from every other zip by the one thing the OCF
    /// specification insists on: the archive's first entry is called
    /// `mimetype`, is stored rather than deflated, and holds exactly
    /// `application/epub+zip`. That makes it a fixed-offset read into the
    /// local file header at the front of the file — no zip library, and no
    /// walking a central directory that sits at the other end of a file the
    /// sniff never reads.
    ///
    /// A plain `.zip`, and a zip whose first entry says something else, are
    /// archives and stay archives: Nota does not open one.
    private static func isEPUB(_ head: Data) -> Bool {
        let bytes = [UInt8](head.prefix(128))
        guard bytes.starts(with: zipMagic), bytes.count >= 30 else { return false }
        // The mimetype entry is stored, never compressed, so what follows the
        // header is the media type itself rather than a deflate stream.
        guard word(bytes, at: 8) == 0 else { return false }
        let nameLength = word(bytes, at: 26)
        let extraLength = word(bytes, at: 28)
        let nameEnd = 30 + nameLength
        guard nameLength == epubEntryName.count, bytes.count >= nameEnd,
              Array(bytes[30 ..< nameEnd]) == epubEntryName
        else { return false }
        let start = nameEnd + extraLength
        let end = start + epubMediaType.count
        guard bytes.count >= end else { return false }
        return Array(bytes[start ..< end]) == epubMediaType
    }

    /// A little-endian 16-bit field of a zip header.
    private static func word(_ bytes: [UInt8], at offset: Int) -> Int {
        guard bytes.count >= offset + 2 else { return -1 }
        return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
    }

    private static func isImage(_ head: Data) -> Bool {
        let bytes = [UInt8](head.prefix(16))
        if imageMagics.contains(where: bytes.starts(with:)) { return true }
        // WebP is a RIFF container that says so in its fourth word.
        if bytes.starts(with: Array("RIFF".utf8)), bytes.count >= 12,
           Array(bytes[8..<12]) == Array("WEBP".utf8) { return true }
        // HEIC and friends: `ftyp` and then the brand, both after the length.
        guard bytes.count >= 12, Array(bytes[4..<8]) == Array("ftyp".utf8) else { return false }
        return heifBrands.contains(String(decoding: bytes[8..<12], as: UTF8.self))
    }
}
