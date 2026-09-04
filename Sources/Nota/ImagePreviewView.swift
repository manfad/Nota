import AppKit

/// The preview column holding a picture: a `.png`, `.jpg`, `.gif` or any of
/// the other formats the system draws, where a Markdown tab would have its
/// render.
///
/// A picture tab has no editor behind it — there is nothing to edit — so this
/// is never a pane beside anything. It is the whole column, in reading mode,
/// the same arrangement a PDF gets and for the same reason: Nota opens the
/// file to be looked at, not to be written to.
///
/// The picture is drawn at its own size when the column is big enough to hold
/// it, and shrunk to fit when it is not. It is never blown up past its own
/// pixels: a small icon is a small icon, and stretching it across the column
/// would be showing you something the file does not say.
final class ImagePreviewView: NSView, PreviewContent {

    private let scrollView = NSScrollView()
    private let imageView = NSImageView()
    /// Shown instead of the picture when the file has gone — deleted while
    /// the tab was open, or missing by the time the session comes back.
    private let missingLabel = NSTextField(labelWithString: "")

    /// The file the picture on screen came from. A show that would draw the
    /// same file again does nothing: showing is asked on every resize, and
    /// reading the bytes again would be reading them for nothing.
    private var shownPath: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        // Pinned edge to edge, unlike the Markdown render's own margins. The
        // picture already has whatever margin its author drew into it, and a
        // second one outside that is the column shrinking the picture to pay
        // for space nobody asked for.
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        addSubview(scrollView)

        // `animates` is what makes a GIF a moving picture rather than its
        // first frame.
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        imageView.animates = true
        imageView.isEditable = false
        scrollView.documentView = imageView

        // The same quiet voice the rest of the app uses for something that is
        // not there: the editor's own font family, secondary colour, centred
        // in the column with nothing else in it.
        missingLabel.translatesAutoresizingMaskIntoConstraints = false
        missingLabel.alignment = .center
        missingLabel.textColor = .secondaryLabelColor
        missingLabel.isHidden = true
        addSubview(missingLabel)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            missingLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            missingLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            missingLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor, constant: 20
            ),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Content

    /// Puts the tab's picture in the pane. Nothing here asks whether the
    /// column is on screen: a picture already read costs nothing to hold, and
    /// the pane has to be right the moment it comes forward.
    func show(_ note: Note, in context: PreviewContext) {
        let path = note.fileURL?.path
        // Only on a real change. A resize and a tab switch both ask again,
        // and handing the view the same picture would start a GIF over from
        // its first frame.
        if path != shownPath {
            shownPath = path
            let image = note.image
            show(image, missingName: image == nil ? note.title : nil)
            missingLabel.font = Preferences.shared.font()
        }
        layoutImage()
    }

    private func show(_ image: NSImage?, missingName: String?) {
        imageView.image = image
        scrollView.isHidden = image == nil
        missingLabel.isHidden = image != nil
        guard image == nil else { return }
        missingLabel.stringValue = missingName.map { "Couldn’t open “\($0)”." } ?? ""
    }

    /// The picture takes the column's whole room, and `scaleProportionallyDown`
    /// draws it inside that: at its own size when it is smaller, shrunk until
    /// it fits when it is bigger, centred either way. So the whole picture is
    /// always on screen — a picture is looked at whole, unlike a document,
    /// which is read a page at a time.
    private func layoutImage() {
        let room = scrollView.contentSize
        guard room.width > 1, room.height > 1 else { return }
        imageView.frame = NSRect(origin: .zero, size: room)
    }

    override func layout() {
        super.layout()
        layoutImage()
    }

    /// The picture on screen, and the message standing in for one that could
    /// not be opened — for the tests.
    var image: NSImage? { imageView.image }

    var missingMessage: String? {
        missingLabel.isHidden ? nil : missingLabel.stringValue
    }

    /// A picture has no words or characters to count, and no pages either.
    /// How big it is, is how big it is — and there is nowhere in it to be, so
    /// the right of the footer stays empty.
    var footerStatus: PreviewFooterStatus? {
        guard let image = imageView.image else { return nil }
        return PreviewFooterStatus(
            summary: TextStats.pixelSize(of: pixelSize(of: image)), position: nil
        )
    }

    /// The picture's real size in pixels, which is what a picture is measured
    /// in. `NSImage.size` is in points, and a photograph taken on a modern
    /// camera or a screenshot from a Retina display has two pixels to each of
    /// them; the representation is the one that knows.
    private func pixelSize(of image: NSImage) -> NSSize {
        guard let representation = image.representations.first else { return image.size }
        return NSSize(width: representation.pixelsWide, height: representation.pixelsHigh)
    }

    /// Puts the keyboard in the picture — reading mode's answer to
    /// `focusEditor`, so the arrow and page keys scroll a picture too big for
    /// the column.
    @discardableResult
    func focus(in window: NSWindow?) -> Bool {
        window?.makeFirstResponder(scrollView) ?? false
    }

    // MARK: - Background

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // The scroll view keeps the colour it was handed rather than resolving
        // it again, so light and dark are swapped by handing it over afresh.
        scrollView.backgroundColor = .textBackgroundColor
        needsDisplay = true
    }
}
