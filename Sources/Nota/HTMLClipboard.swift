import AppKit
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// Safari's flavour: the copied fragment's markup *and* the bytes of the
    /// pictures in it, wrapped in one property list.
    static let webArchive = NSPasteboard.PasteboardType("com.apple.webarchive")
    /// The same thing under the name Safari has always written it as. Which
    /// of the two turns up depends on the version, so both are read.
    static let legacyWebArchive = NSPasteboard.PasteboardType(
        "Apple Web Archive pasteboard type"
    )
}

/// Reading the flavour a web page copies.
///
/// Copying text and a picture out of Chrome, Safari, Notion or Obsidian puts
/// `public.html` on the board beside the plain text, and — in Safari — a web
/// archive as well. Neither of the RTF flavours is offered, so without this
/// the paste fell through to `.string` and the picture was simply lost.
///
/// What is here is the markup, the bytes a web archive brought with it, and
/// the `<img src>` list that fills in the rest: the HTML importer hands back
/// attachments with no bytes in them often enough — a remote URL it would not
/// fetch, a `data:` URI it did not decode — that the sources have to be
/// resolved by hand, in document order.
///
/// Browser markup is messy, so everything here is forgiving: a source that
/// cannot be resolved drops that one picture and keeps the words.
enum HTMLClipboard {

    /// A copied fragment: its markup, plus whatever bytes travelled with it.
    /// Only a web archive carries resources; `public.html` is markup alone.
    struct Payload {
        var html: String
        var resources: [String: Data] = [:]
    }

    /// One picture's bytes and the extension they should be kept under, so a
    /// JPEG from a page stays a JPEG instead of being re-encoded as PNG.
    struct ImageBytes: Equatable {
        var data: Data
        var preferredExtension: String?
    }

    /// The pasteboard flavours this file understands, best first: the web
    /// archive already has the pictures in it, where plain HTML may have to
    /// go and fetch them.
    static let types: [NSPasteboard.PasteboardType] = [.webArchive, .legacyWebArchive, .html]

    /// How long a picture referenced by URL is waited for. A paste is a
    /// keystroke; it cannot hang on a slow server.
    static let timeout: TimeInterval = 5

    // MARK: - Reading the board

    static func payload(from data: Data, type: NSPasteboard.PasteboardType) -> Payload? {
        guard type != .html else {
            return markup(data, encodingName: nil).map { Payload(html: $0) }
        }
        return webArchivePayload(data)
    }

    /// The fragment on a pasteboard, whichever of the flavours it carries.
    static func payload(on pboard: NSPasteboard) -> Payload? {
        let available = pboard.types ?? []
        for type in types where available.contains(type) {
            if let data = pboard.data(forType: type), let payload = payload(from: data, type: type) {
                return payload
            }
        }
        return nil
    }

    /// A web archive is a property list: one main resource holding the
    /// markup, and a subresource per picture, keyed by the URL the markup
    /// refers to it with.
    private static func webArchivePayload(_ data: Data) -> Payload? {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any],
            let main = plist["WebMainResource"] as? [String: Any],
            let body = main["WebResourceData"] as? Data,
            let html = markup(body, encodingName: main["WebResourceTextEncodingName"] as? String)
        else { return nil }

        var resources: [String: Data] = [:]
        for case let subresource as [String: Any] in plist["WebSubresources"] as? [Any] ?? [] {
            guard let url = subresource["WebResourceURL"] as? String,
                  let bytes = subresource["WebResourceData"] as? Data
            else { continue }
            resources[url] = bytes
        }
        return Payload(html: html, resources: resources)
    }

    /// Bytes to markup. The page says what it was written in when it knows;
    /// otherwise the same sniffing a text file gets, which covers a UTF-8
    /// byte-order mark and the 8-bit fallbacks.
    private static func markup(_ data: Data, encodingName: String?) -> String? {
        if let encodingName {
            let identifier = CFStringConvertIANACharSetNameToEncoding(encodingName as CFString)
            if identifier != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(
                    rawValue: CFStringConvertEncodingToNSStringEncoding(identifier)
                )
                if let text = String(data: data, encoding: encoding) { return text }
            }
        }
        return TextFile.decode(data)?.text
    }

    // MARK: - The precondition

    /// Whether a fragment is worth taking as HTML at all.
    ///
    /// Only a copy with a picture in it is: a text-only browser copy has
    /// nothing HTML can carry that `.string` cannot, and going through the
    /// importer would cost it its lists, its code blocks and its whitespace
    /// for nothing.
    static func containsImage(_ html: String) -> Bool {
        html.range(of: "<img", options: .caseInsensitive) != nil
    }

    // MARK: - The pictures

    private static let imageTagRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "<img\\b[^>]*?\\bsrc\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))",
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    /// Every `<img>` source in the markup, in document order — which is the
    /// order the importer's attachments come back in, and so the only thing
    /// the two lists can be matched on.
    ///
    /// A regex rather than a parser on purpose: half the markup a browser
    /// puts on the board would not survive an XML parser, and the only thing
    /// wanted from it is one attribute.
    static func imageSources(in html: String) -> [String] {
        guard let imageTagRegex else { return [] }
        let text = html as NSString
        let matches = imageTagRegex.matches(
            in: html, range: NSRange(location: 0, length: text.length)
        )
        return matches.compactMap { match in
            for group in 1...3 where match.range(at: group).location != NSNotFound {
                return decodingEntities(text.substring(with: match.range(at: group)))
            }
            return nil
        }
    }

    /// The bytes behind one `<img src>`, or `nil` for a source there is no
    /// way to resolve — a relative URL with no page behind it, a scheme that
    /// is not the web's. The caller drops that picture and keeps the text.
    static func imageBytes(
        forSource source: String,
        in payload: Payload,
        fetch: (URL) -> Data? = HTMLClipboard.download
    ) -> ImageBytes? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.lowercased().hasPrefix("data:") { return dataURI(trimmed) }

        if let bytes = resource(for: trimmed, in: payload.resources) {
            return ImageBytes(data: bytes, preferredExtension: pathExtension(of: trimmed))
        }

        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let data = fetch(url), !data.isEmpty
        else { return nil }
        return ImageBytes(data: data, preferredExtension: pathExtension(of: trimmed))
    }

    /// `data:image/png;base64,…` — the whole picture, inline in the markup,
    /// which is how a copy from Notion and most editors carries one.
    static func dataURI(_ uri: String) -> ImageBytes? {
        guard uri.lowercased().hasPrefix("data:"), let comma = uri.firstIndex(of: ",")
        else { return nil }
        let header = uri[uri.index(uri.startIndex, offsetBy: "data:".count)..<comma]
        let body = String(uri[uri.index(after: comma)...])
        let parameters = header.lowercased().split(separator: ";").map(String.init)

        let decoded: Data?
        if parameters.contains("base64") {
            // Markup wraps long attribute values, so the newlines in the
            // middle of the payload are expected rather than an error.
            decoded = Data(base64Encoded: body, options: .ignoreUnknownCharacters)
        } else {
            decoded = body.removingPercentEncoding.flatMap { $0.data(using: .utf8) }
        }
        guard let decoded, !decoded.isEmpty else { return nil }
        return ImageBytes(
            data: decoded, preferredExtension: parameters.first.flatMap(fileExtension(forMIMEType:))
        )
    }

    /// A web archive's subresource for a source. The markup usually refers to
    /// it by the same absolute URL the archive filed it under; where it does
    /// not — a relative source, a URL that picked up a fragment — the file
    /// name is what the two still have in common.
    private static func resource(for source: String, in resources: [String: Data]) -> Data? {
        if let exact = resources[source] { return exact }
        guard !resources.isEmpty else { return nil }
        let name = (source as NSString).lastPathComponent
        guard !name.isEmpty else { return nil }
        for (url, bytes) in resources where (url as NSString).lastPathComponent == name {
            return bytes
        }
        return nil
    }

    private static func pathExtension(of source: String) -> String? {
        let ext = URL(string: source).map { $0.pathExtension }
            ?? (source as NSString).pathExtension
        return ext.isEmpty ? nil : ext
    }

    private static func fileExtension(forMIMEType mime: String) -> String? {
        UTType(mimeType: mime)?.preferredFilenameExtension
    }

    /// The handful of entities a URL in an attribute can be written with.
    private static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        for (entity, character) in [
            ("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&lt;", "<"), ("&gt;", ">"),
        ] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result
    }

    // MARK: - Fetching

    /// A picture the page only pointed at. Synchronous on purpose: a paste is
    /// one undoable edit, and the bytes have to be in hand before the
    /// attachment is made. `URLSession` calls back on a queue of its own, so
    /// waiting here never deadlocks the main thread.
    static func download(_ url: URL) -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        var result: Data?
        let finished = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { finished.signal() }
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) { return }
            result = data
        }
        task.resume()
        guard finished.wait(timeout: .now() + timeout + 1) == .success else {
            task.cancel()
            return nil
        }
        return result
    }

    // MARK: - The text

    /// The markup as an attributed string, attachments and all. The importer
    /// is what turns `<p>`, `<br>` and `<div>` into the line breaks the words
    /// had on the page; Nota throws the styling away afterwards.
    @MainActor
    static func attributedString(from payload: Payload) -> NSAttributedString? {
        guard let data = payload.html.data(using: .utf8) else { return nil }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
            .timeout: timeout,
        ]
        return try? NSAttributedString(data: data, options: options, documentAttributes: nil)
    }

    /// The importer closes a block with a newline the copy never had, so a
    /// pasted paragraph would push the caret onto a line of its own.
    static func trimmingTrailingWhitespace(_ attributed: NSAttributedString) -> NSAttributedString {
        let text = attributed.string as NSString
        var end = text.length
        let whitespace = CharacterSet.whitespacesAndNewlines
        while end > 0, let scalar = Unicode.Scalar(text.character(at: end - 1)),
              whitespace.contains(scalar) {
            end -= 1
        }
        guard end < text.length else { return attributed }
        return attributed.attributedSubstring(from: NSRange(location: 0, length: end))
    }
}
