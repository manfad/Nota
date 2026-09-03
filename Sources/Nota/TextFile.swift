import Foundation
import UniformTypeIdentifiers

/// How a file's lines end. Nota keeps whatever the file already used rather
/// than rewriting a CRLF file the first time it is saved.
enum LineEnding: String, Codable {
    case lf, crlf

    var characters: String { self == .crlf ? "\r\n" : "\n" }
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

    /// Text on paper but not text to Nota: SPEC rules out rich text and
    /// binaries, and an image belongs to the asset store, not to a tab.
    private static let excludedTypes: [UTType] = [
        .rtf, .pdf, .image, .audiovisualContent, .archive,
    ]

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

    /// The first 8 KB, so sniffing a huge log does not read the whole thing.
    private static func head(of url: URL) -> Data? {
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
