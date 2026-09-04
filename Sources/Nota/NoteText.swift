import AppKit

/// The bridge between what a note *is* on disk — plain text with
/// `![](nota://<uuid>.<ext>)` tokens — and what it looks like in the editor,
/// where those tokens are image attachments.
///
/// Everything that touches a file goes through `serialize`; everything that
/// fills a text storage goes through `render`. Files therefore stay plain
/// text and stay readable in any other editor.
enum NoteText {
    static let scheme = "nota://"

    /// The scheme the app wrote when it was called Jot. Notes and caches on
    /// disk are full of these, so reading accepts either scheme forever;
    /// writing only ever uses `nota://`, which is how a file that goes
    /// through the editor is quietly brought up to date.
    static let legacyScheme = "jot://"

    /// Deliberately strict: an id must look like `name.ext`, so a stray
    /// `![](nota://` in prose is left alone as ordinary text.
    private static let pattern =
        "!\\[\\]\\((?:nota|jot)://([A-Za-z0-9-]+\\.[A-Za-z0-9]+)\\)"

    private static let regex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: pattern)
    }()

    static func token(for assetID: String) -> String {
        "![](\(scheme)\(assetID))"
    }

    /// The asset id a token's address points at, under either scheme.
    /// Anything else — a remote URL, a file path — is not ours.
    static func assetID(fromTokenURL text: String) -> String? {
        for candidate in [scheme, legacyScheme] where text.hasPrefix(candidate) {
            let id = String(text.dropFirst(candidate.count))
            return id.isEmpty ? nil : id
        }
        return nil
    }

    /// Asset ids referenced by a piece of plain text, in order.
    static func assetIDs(in plain: String) -> [String] {
        matches(in: plain).compactMap { match in
            Range(match.range(at: 1), in: plain).map { String(plain[$0]) }
        }
    }

    /// Whether it is worth running the regex at all.
    ///
    /// A token always spells its address the same way, so a plain substring
    /// search for that spelling settles it — and a search is a different
    /// thing from a match: a 100 MB log with no pictures in it is swept once
    /// at memory speed instead of being walked by the regex engine. Every
    /// entry point below asks this first; none of them means anything
    /// different because of it.
    private static func mayHoldToken(_ plain: String) -> Bool {
        for candidate in [scheme, legacyScheme] where plain.range(of: "](" + candidate) != nil {
            return true
        }
        return false
    }

    private static func matches(in plain: String) -> [NSTextCheckingResult] {
        guard let regex, mayHoldToken(plain) else { return [] }
        return regex.matches(
            in: plain, range: NSRange(location: 0, length: (plain as NSString).length)
        )
    }

    // MARK: Plain text -> attributed

    /// Tokens become `NotaImageAttachment`s; a missing asset still gets a chip
    /// (showing a picture glyph) rather than vanishing, so the token survives
    /// a round trip untouched.
    static func render(
        _ plain: String,
        attributes: [NSAttributedString.Key: Any],
        assets: AssetStore?
    ) -> NSAttributedString {
        guard mayHoldToken(plain) else {
            return NSAttributedString(string: plain, attributes: attributes)
        }
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
            let attachment = NotaImageAttachment(
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
    /// An attachment Nota does not recognise is dropped rather than leaving a
    /// stray U+FFFC in the file.
    static func serialize(_ attributed: NSAttributedString) -> String {
        // Nothing attached anywhere means the text *is* the file, so hand it
        // over rather than copying it out run by run. Bridging a text
        // storage's string takes a snapshot of it, so what comes back is not
        // a window onto the storage.
        guard hasAttachment(attributed) else { return attributed.string }
        var result = ""
        let source = attributed.string as NSString

        attributed.forEachAttachmentRun { value, range, _ in
            if let attachment = value as? NotaImageAttachment {
                result += token(for: attachment.assetID)
            } else if value == nil {
                result += source.substring(with: range)
            }
        }
        return result
    }

    /// Whether anything at all is attached — asked with the runs rather than
    /// the characters, and stopped at the first one, so a note full of
    /// pictures costs as little as a log with none.
    private static func hasAttachment(_ attributed: NSAttributedString) -> Bool {
        var found = false
        attributed.forEachAttachmentRun { value, _, stop in
            if value != nil {
                found = true
                stop = true
            }
        }
        return found
    }

    /// Text with the image tokens removed — what the word and character
    /// counts are taken from, so an image counts as nothing.
    static func strippingTokens(_ plain: String) -> String {
        guard let regex, mayHoldToken(plain) else { return plain }
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
        guard let regex, mayHoldToken(plain) else { return plain }
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
        guard regex != nil, mayHoldToken(plain) else { return plain }
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

extension NSAttributedString {
    /// Every run of the string, in order: what is attached there — `nil` for
    /// ordinary text — and the characters it covers.
    ///
    /// `enumerateAttribute` answers the same question, but it walks the text
    /// to do it: some 90 ms on a 100 MB log, on a note with nothing attached
    /// at all, every time the footer is written. Asking for the longest
    /// effective range instead is a single lookup per run, and a log is one
    /// run.
    func forEachAttachmentRun(_ body: (Any?, NSRange, inout Bool) -> Void) {
        var location = 0
        var stop = false
        while location < length, !stop {
            var effective = NSRange(location: location, length: 0)
            let value = attribute(
                .attachment, at: location, longestEffectiveRange: &effective,
                in: NSRange(location: location, length: length - location)
            )
            body(value, effective, &stop)
            // Never stand still, whatever the string says the run was.
            location = max(NSMaxRange(effective), location + 1)
        }
    }
}
