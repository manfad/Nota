import AppKit

/// The attachment Nota puts in a text storage for `![](nota://<id>)`.
///
/// It draws as a text chip reading `Image 1`, not a thumbnail: the point is
/// that a note stays prose you can read, with the pictures themselves off in
/// the sidebar. The number is the image's position in the note and is
/// renumbered live as images are added, pasted or deleted.
final class NotaImageAttachment: NSTextAttachment {
    private static let cornerRadius: CGFloat = 4
    private static let horizontalPadding: CGFloat = 4

    let assetID: String
    /// The asset file is gone; the chip says so instead of pretending.
    let isMissing: Bool

    private(set) var displayIndex: Int
    private var chipSize: NSSize = .zero
    private var baselineOffset: CGFloat = 0
    private var renderedFont: NSFont
    private var renderedLabel = ""

    init(assetID: String, isMissing: Bool, font: NSFont, index: Int) {
        self.assetID = assetID
        self.isMissing = isMissing
        self.displayIndex = index
        self.renderedFont = font
        super.init(data: nil, ofType: nil)
        _ = updateChip(font: font, index: index)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var label: String {
        let title = "\(L10n.text("Image")) \(displayIndex)"
        return isMissing ? "\(title) — \(L10n.text("missing"))" : title
    }

    /// Re-measures and redraws for a new font or a new position.
    /// Returns whether the geometry changed, so the caller only invalidates
    /// layout for the chips that actually moved.
    @discardableResult
    func updateChip(font: NSFont, index: Int) -> Bool {
        let unchanged = index == displayIndex
            && font.pointSize == renderedFont.pointSize
            && font.fontName == renderedFont.fontName
            && label == renderedLabel
            && chipSize != .zero
        guard !unchanged else { return false }

        displayIndex = index
        renderedFont = font

        let text = label
        renderedLabel = text
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)

        let previous = chipSize
        chipSize = NSSize(
            width: ceil(textSize.width) + Self.horizontalPadding * 2,
            height: lineHeight
        )
        // Sits on the baseline the way a word does.
        baselineOffset = font.descender.rounded()
        image = Self.makeChip(size: chipSize, text: text, font: font)
        return previous != chipSize
    }

    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        CGRect(origin: CGPoint(x: 0, y: baselineOffset), size: chipSize)
    }

    /// Drawn through a handler so the label and fill colours resolve at draw
    /// time and follow light and dark mode without re-rendering.
    private static func makeChip(size: NSSize, text: String, font: NSFont) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            NSBezierPath(
                roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius
            ).fill()

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let textSize = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(
                at: NSPoint(
                    x: rect.midX - textSize.width / 2,
                    y: rect.midY - textSize.height / 2
                ),
                withAttributes: attributes
            )
            return true
        }
    }
}

/// Fitting a picture inside a box without cropping it.
enum ImageFitting {
    static func aspectFit(_ size: NSSize, in rect: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let fitted = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(
            x: rect.midX - fitted.width / 2,
            y: rect.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }
}

/// Sidecar image files at `<supportDir>/assets/<uuid>.<ext>`.
///
/// Assets are never deleted automatically: a note saved anywhere on disk can
/// still reference one, and Nota has no way to know about those files.
final class AssetStore {
    /// Formats kept byte-for-byte. Anything else is normalised to PNG.
    private static let passThroughExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp",
    ]

    let directory: URL
    private var imageCache: [String: NSImage] = [:]

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Reading

    func url(for assetID: String) -> URL {
        directory.appendingPathComponent(assetID)
    }

    func data(for assetID: String) -> Data? {
        try? Data(contentsOf: url(for: assetID))
    }

    /// Cheap existence check — the chip only needs to know if the file is
    /// there, and decoding the picture just to find out would be wasteful.
    func exists(_ assetID: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: assetID).path)
    }

    func image(for assetID: String) -> NSImage? {
        if let cached = imageCache[assetID] { return cached }
        guard let image = NSImage(contentsOf: url(for: assetID)) else { return nil }
        imageCache[assetID] = image
        return image
    }

    // MARK: Copying out

    /// Nota's chips travel as tokens, and its own flavours mean nothing to a
    /// terminal, a browser or Slack: those read `public.png` and `public.tiff`
    /// and nothing else. Every copy that leaves Nota — the sidebar's Copy
    /// Image, ⌘C over a chip — puts a real picture on the board through here.
    func pngData(for assetID: String) -> Data? {
        data(for: assetID).flatMap(Self.pngData(from:))
    }

    func tiffData(for assetID: String) -> Data? {
        data(for: assetID).flatMap(Self.tiffData(from:))
    }

    /// Bytes that already are a PNG are handed back untouched — the magic
    /// number says so — rather than decoded and re-encoded.
    static func pngData(from data: Data) -> Data? {
        if data.starts(with: pngMagic) { return data }
        return bitmap(from: data)?.representation(using: .png, properties: [:])
    }

    static func tiffData(from data: Data) -> Data? {
        NSImage(data: data)?.tiffRepresentation
    }

    private static let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// `NSBitmapImageRep` reads the common formats straight; the ones it will
    /// not (a multi-representation icon, say) still go through `NSImage`.
    private static func bitmap(from data: Data) -> NSBitmapImageRep? {
        if let rep = NSBitmapImageRep(data: data) { return rep }
        guard let tiff = NSImage(data: data)?.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    // MARK: Importing

    /// Screenshots arrive as TIFF and become PNG; a real jpg/png/gif keeps its
    /// original bytes so nothing is re-encoded.
    func importImageData(_ data: Data, preferredExtension: String?) -> String? {
        if let ext = preferredExtension?.lowercased(),
           Self.passThroughExtensions.contains(ext) {
            return store(data, extension: ext)
        }
        guard let rep = NSBitmapImageRep(data: data),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        return store(png, extension: "png")
    }

    func importFile(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return importImageData(data, preferredExtension: url.pathExtension)
    }

    /// Takes in a picture that already lives beside a note's file — a
    /// sidecar's, or any other relative link the file draws — reusing an
    /// asset that already holds exactly these bytes.
    ///
    /// Those pictures are read again every time the file naming them is
    /// opened, and assets are never deleted, so without this the store would
    /// grow another copy of every one of them on every open. Bytes decide,
    /// not names: two files with the same content are the same picture.
    func importFileDeduplicating(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let existing = existingAsset(matching: data) { return existing }
        return importImageData(data, preferredExtension: url.pathExtension)
    }

    /// The id of an asset holding exactly these bytes, if the store has one.
    /// Only files of the same length are read at all, so the usual answer
    /// costs one directory listing and nothing else.
    func existingAsset(matching data: Data) -> String? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for candidate in contents {
            guard (try? candidate.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                    == data.count,
                  let bytes = try? Data(contentsOf: candidate), bytes == data
            else { continue }
            return candidate.lastPathComponent
        }
        return nil
    }

    /// Pulls the bytes out of an attachment that came from another app.
    func importForeignAttachment(_ attachment: NSTextAttachment) -> String? {
        if let wrapper = attachment.fileWrapper, let data = wrapper.regularFileContents {
            let ext = wrapper.preferredFilename.map { ($0 as NSString).pathExtension }
            return importImageData(data, preferredExtension: ext)
        }
        guard let image = attachment.image,
              let tiff = image.tiffRepresentation
        else { return nil }
        return importImageData(tiff, preferredExtension: nil)
    }

    private func store(_ data: Data, extension ext: String) -> String? {
        let assetID = "\(UUID().uuidString.lowercased()).\(ext)"
        do {
            try data.write(to: url(for: assetID), options: .atomic)
        } catch {
            return nil
        }
        return assetID
    }

    // MARK: Helpers

    /// Whether a file is a picture the store would take in — which is the
    /// same question `Note.isImageFile` asks of a tab, and deliberately the
    /// same answer.
    ///
    /// The two must agree, because between them they decide what a file let
    /// go on the editor becomes: a picture is a chip in the text, and
    /// everything else opens as a tab beside it. A file both refused would
    /// land nowhere. That is what an `.svg` used to be — the system files it
    /// under images, so it was claimed here as a chip, and then the store
    /// could not read a drawing's bytes as a picture and it vanished. It is
    /// text that opens in a tab, and it is refused here for that reason.
    static func isImageFile(_ url: URL) -> Bool {
        Note.isImageFile(url)
    }
}
