import AppKit

/// A Word 97–2003 `.doc`, read (SPEC "## Office documents and video").
///
/// The binary format is a compound file of interleaved text, formatting and
/// piece tables, and the system already reads it: `NSAttributedString` takes
/// a `.doc` the way TextEdit opens one, and writes the same text out as a
/// `.docx`. So the `.doc` is turned into a `.docx` in a scratch file and read
/// by `DOCXDocument` like any other, and the tab gets the same printed pages.
/// What survives is what TextEdit keeps — the words, their fonts, sizes,
/// colours and emphasis, paragraph alignment and spacing, lists and simple
/// tables; pictures, headers and footers are lost on the way through.
enum LegacyWord {
    static func open(_ fileURL: URL) -> DOCXDocument? {
        guard let text = try? NSAttributedString(
            url: fileURL, options: [.documentType: NSAttributedString.DocumentType.docFormat],
            documentAttributes: nil
        ), let data = try? text.data(
            from: NSRange(location: 0, length: text.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
        ) else { return nil }
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("Nota-DOC-\(UUID().uuidString).docx")
        guard (try? data.write(to: archive)) != nil else { return nil }
        // Unpacked into a folder of its own by `open`, so the scratch file
        // has done its work as soon as that returns.
        defer { try? FileManager.default.removeItem(at: archive) }
        return DOCXDocument.open(fileURL, archive: archive)
    }
}
