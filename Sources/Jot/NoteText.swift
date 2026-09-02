import AppKit

/// The bridge between what a note *is* on disk — plain text with
/// `![](jot://<uuid>.<ext>)` tokens — and what it looks like in the editor,
/// where those tokens are image attachments.
///
/// Everything that touches a file goes through `serialize`; everything that
/// fills a text storage goes through `render`. Files therefore stay plain
/// text and stay readable in any other editor.
enum NoteText {
    static let scheme = "jot://"

    /// Deliberately strict: an id must look like `name.ext`, so a stray
    /// `![](jot://` in prose is left alone as ordinary text.
    private static let pattern = "!\\[\\]\\(jot://([A-Za-z0-9-]+\\.[A-Za-z0-9]+)\\)"

    private static let regex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: pattern)
    }()

    static func token(for assetID: String) -> String {
        "![](\(scheme)\(assetID))"
    }

    /// Asset ids referenced by a piece of plain text, in order.
    static func assetIDs(in plain: String) -> [String] {
        matches(in: plain).compactMap { match in
            Range(match.range(at: 1), in: plain).map { String(plain[$0]) }
        }
    }

    private static func matches(in plain: String) -> [NSTextCheckingResult] {
        guard let regex else { return [] }
        return regex.matches(
            in: plain, range: NSRange(location: 0, length: (plain as NSString).length)
        )
    }

    // MARK: Plain text -> attributed

    /// Tokens become `JotImageAttachment`s; a missing asset still gets a chip
    /// (showing a picture glyph) rather than vanishing, so the token survives
    /// a round trip untouched.
    static func render(
        _ plain: String,
        attributes: [NSAttributedString.Key: Any],
        assets: AssetStore?
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let source = plain as NSString
        let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: 13)
        var cursor = 0
        var imageNumber = 1

        for match in matches(in: plain) {
            if match.range.location > cursor {
                let range = NSRange(location: cursor, length: match.range.location - cursor)
                result.append(NSAttributedString(
                    string: source.substring(with: range), attributes: attributes
                ))
            }
            let assetID = source.substring(with: match.range(at: 1))
            let attachment = JotImageAttachment(
                assetID: assetID,
                isMissing: !(assets?.exists(assetID) ?? false),
                font: font,
                index: imageNumber
            )
            imageNumber += 1
            let piece = NSMutableAttributedString(attachment: attachment)
            // Keep the paragraph style so line spacing applies to image lines too.
            piece.addAttributes(attributes, range: NSRange(location: 0, length: piece.length))
            result.append(piece)
            cursor = match.range.location + match.range.length
        }

        if cursor < source.length {
            let range = NSRange(location: cursor, length: source.length - cursor)
            result.append(NSAttributedString(
                string: source.substring(with: range), attributes: attributes
            ))
        }
        return result
    }

    // MARK: Attributed -> plain text

    /// Attachments become tokens again; everything else is taken verbatim.
    /// An attachment Jot does not recognise is dropped rather than leaving a
    /// stray U+FFFC in the file.
    static func serialize(_ attributed: NSAttributedString) -> String {
        var result = ""
        let source = attributed.string as NSString
        let full = NSRange(location: 0, length: attributed.length)

        attributed.enumerateAttribute(.attachment, in: full) { value, range, _ in
            if let attachment = value as? JotImageAttachment {
                result += token(for: attachment.assetID)
            } else if value == nil {
                result += source.substring(with: range)
            }
        }
        return result
    }

    /// Text with the image tokens removed — what the word and character
    /// counts are taken from, so an image counts as nothing.
    static func strippingTokens(_ plain: String) -> String {
        guard let regex else { return plain }
        return regex.stringByReplacingMatches(
            in: plain,
            range: NSRange(location: 0, length: (plain as NSString).length),
            withTemplate: ""
        )
    }

    /// Text with each image token replaced by U+FFFC OBJECT REPLACEMENT
    /// CHARACTER — what the plain-text pasteboard flavor uses, so an image
    /// pasted into a terminal or chat leaves the same marker a stock text
    /// view would.
    static func placeholdingTokens(_ plain: String) -> String {
        guard let regex else { return plain }
        return regex.stringByReplacingMatches(
            in: plain,
            range: NSRange(location: 0, length: (plain as NSString).length),
            withTemplate: "\u{FFFC}"
        )
    }

    /// Text with each image token replaced by a Markdown image pointing at
    /// the asset's absolute path on disk — the default for the plain-text
    /// pasteboard flavor, so an agent reading pasted text in a terminal can
    /// still find the picture. Numbered 1-based in order of appearance. An
    /// asset that is missing, or with no store to resolve it against, falls
    /// back to the U+FFFC marker for that one image.
    static func pathTokens(_ plain: String, assets: AssetStore?) -> String {
        guard regex != nil else { return plain }
        let source = plain as NSString
        var result = ""
        var cursor = 0
        var imageNumber = 1

        for match in matches(in: plain) {
            if match.range.location > cursor {
                result += source.substring(
                    with: NSRange(location: cursor, length: match.range.location - cursor)
                )
            }
            let assetID = source.substring(with: match.range(at: 1))
            if let assets, assets.exists(assetID) {
                result += "![Image \(imageNumber)](\(assets.url(for: assetID).path))"
            } else {
                result += "\u{FFFC}"
            }
            imageNumber += 1
            cursor = match.range.location + match.range.length
        }

        if cursor < source.length {
            result += source.substring(
                with: NSRange(location: cursor, length: source.length - cursor)
            )
        }
        return result
    }
}
