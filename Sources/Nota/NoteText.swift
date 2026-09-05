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

    /// Any Markdown image at all — alt text and a target — for the one job
    /// the strict token pattern cannot do: reading a file's own relative
    /// links back as chips. A target holding `)` or a quote is not a plain
    /// path and is left alone, which is also what keeps `![](a.png "title")`
    /// out of it.
    private static let linkPattern = "!\\[([^\\]\\n]*)\\]\\(([^)\"\\n]*)\\)"

    private static let linkRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: linkPattern)
    }()

    /// What an ordinary relative image link in a file turns into, decided by
    /// whoever owns the disk — `Sidecar.importer(forFileAt:assets:)`. Handed
    /// in as a closure so this file stays pure and testable: it takes the
    /// link target as the file spelled it and answers with the asset the
    /// picture was imported as, plus the path that actually resolved, which
    /// the note remembers so its next save writes the same link back.
    typealias RelativeImporter = (_ linkTarget: String) -> (id: String, path: String)?

    /// What one file's text became: the editor's attributed string, and the
    /// relative path behind each chip that came from an ordinary link.
    struct Rendered {
        let text: NSAttributedString
        /// Asset id → the relative path the file named it with.
        let relativePaths: [String: String]
    }

    /// One picture found in the text: where it is, and which asset it is.
    private struct ImageSpot {
        let range: NSRange
        let assetID: String
    }

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
        render(plain, attributes: attributes, assets: assets, importing: nil).text
    }

    /// The same, for text that came out of a file the reader named.
    ///
    /// With an importer in hand, an ordinary relative Markdown link —
    /// `![](pics/a.png)`, with any alt text or none — that resolves to a real
    /// picture beside the file becomes a chip too, and the path it was
    /// spelled with comes back in `relativePaths`. That is what makes a
    /// Markdown file written anywhere else show its pictures here, and what
    /// keeps them where their author put them on the way back out.
    ///
    /// Without one — an untitled note, the cache, a paste — nothing changes:
    /// only `nota://` tokens are chips, exactly as before.
    static func render(
        _ plain: String,
        attributes: [NSAttributedString.Key: Any],
        assets: AssetStore?,
        importing: RelativeImporter?
    ) -> Rendered {
        let plainResult = { Rendered(
            text: NSAttributedString(string: plain, attributes: attributes),
            relativePaths: [:]
        ) }
        guard mayHoldToken(plain) || (importing != nil && mayHoldLink(plain)) else {
            return plainResult()
        }
        let (spots, relativePaths) = imageSpots(in: plain, importing: importing)
        guard !spots.isEmpty else { return plainResult() }

        let result = NSMutableAttributedString()
        let source = plain as NSString
        let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: 13)
        var cursor = 0
        var imageNumber = 1

        for spot in spots {
            if spot.range.location > cursor {
                let range = NSRange(location: cursor, length: spot.range.location - cursor)
                result.append(NSAttributedString(
                    string: source.substring(with: range), attributes: attributes
                ))
            }
            let attachment = NotaImageAttachment(
                assetID: spot.assetID,
                isMissing: !(assets?.exists(spot.assetID) ?? false),
                font: font,
                index: imageNumber
            )
            imageNumber += 1
            let piece = NSMutableAttributedString(attachment: attachment)
            // Keep the paragraph style so line spacing applies to image lines too.
            piece.addAttributes(attributes, range: NSRange(location: 0, length: piece.length))
            result.append(piece)
            cursor = spot.range.location + spot.range.length
        }

        if cursor < source.length {
            let range = NSRange(location: cursor, length: source.length - cursor)
            result.append(NSAttributedString(
                string: source.substring(with: range), attributes: attributes
            ))
        }
        return Rendered(text: result, relativePaths: relativePaths)
    }

    /// Every picture in the text, in document order.
    ///
    /// With no importer this is just the strict token matches, so the whole
    /// of the old behaviour is the same code path it always was. With one,
    /// the general image pattern is run instead and each match classified: an
    /// empty alt over a `nota://` address is a token exactly as the strict
    /// pattern reads it, an ordinary relative link is whatever the importer
    /// makes of it, and everything else — a remote URL, a missing file — is
    /// left as the text it is.
    private static func imageSpots(
        in plain: String, importing: RelativeImporter?
    ) -> (spots: [ImageSpot], relativePaths: [String: String]) {
        let source = plain as NSString
        guard let importing, let linkRegex, mayHoldLink(plain) else {
            return (matches(in: plain).map {
                ImageSpot(range: $0.range, assetID: source.substring(with: $0.range(at: 1)))
            }, [:])
        }
        var spots: [ImageSpot] = []
        var relativePaths: [String: String] = [:]
        let whole = NSRange(location: 0, length: source.length)

        for match in linkRegex.matches(in: plain, range: whole) {
            let alt = source.substring(with: match.range(at: 1))
            let target = source.substring(with: match.range(at: 2))
            if alt.isEmpty, let assetID = tokenAssetID(target) {
                spots.append(ImageSpot(range: match.range, assetID: assetID))
                continue
            }
            guard let found = importing(target) else { continue }
            relativePaths[found.id] = found.path
            spots.append(ImageSpot(range: match.range, assetID: found.id))
        }
        return (spots, relativePaths)
    }

    /// A link target that is a token's address and nothing else, read as
    /// strictly as `pattern` reads the whole token.
    private static func tokenAssetID(_ target: String) -> String? {
        guard let id = assetID(fromTokenURL: target),
              let assetIDRegex,
              assetIDRegex.firstMatch(
                  in: id, range: NSRange(location: 0, length: (id as NSString).length)
              ) != nil
        else { return nil }
        return id
    }

    private static let assetIDRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "^[A-Za-z0-9-]+\\.[A-Za-z0-9]+$")
    }()

    /// The cheap sweep `mayHoldToken` is, for the general pattern: no `![`
    /// anywhere means no image link anywhere.
    private static func mayHoldLink(_ plain: String) -> Bool {
        plain.range(of: "![") != nil
    }

    // MARK: Attributed -> plain text

    /// Attachments become tokens again; everything else is taken verbatim.
    /// An attachment Nota does not recognise is dropped rather than leaving a
    /// stray U+FFFC in the file.
    static func serialize(_ attributed: NSAttributedString) -> String {
        serialize(attributed, sidecar: nil)
    }

    /// One chip's fate on the way into a named file: the link target to write
    /// for it, or `nil` to leave the `nota://` token as it stands. Handed in
    /// as a closure — `Sidecar.Writer.link(forAssetID:)` — so this file still
    /// touches no disk.
    typealias SidecarResolver = (_ assetID: String) -> String?

    /// The same, for a note going into a file the reader named: each chip
    /// becomes the ordinary relative link the resolver gives it, and the
    /// resolver has put the picture there on the way past. An untitled note
    /// and the cache pass no resolver and keep writing tokens, which is what
    /// makes the store the truth until ⌘S.
    static func serialize(_ attributed: NSAttributedString, sidecar: SidecarResolver?) -> String {
        // Nothing attached anywhere means the text *is* the file, so hand it
        // over rather than copying it out run by run. Bridging a text
        // storage's string takes a snapshot of it, so what comes back is not
        // a window onto the storage.
        guard hasAttachment(attributed) else { return attributed.string }
        var result = ""
        let source = attributed.string as NSString

        attributed.forEachAttachmentRun { value, range, _ in
            if let attachment = value as? NotaImageAttachment {
                if let link = sidecar?(attachment.assetID) {
                    result += "![](\(link))"
                } else {
                    result += token(for: attachment.assetID)
                }
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
