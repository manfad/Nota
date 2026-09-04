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
    /// What the scroll view scrolls: the room the picture is looked at in,
    /// which is the column's own until a zoom makes the picture bigger than
    /// it. The picture sits centred inside it, so the two frames are one
    /// calculation rather than the image view standing in for both.
    private let canvas = NSView()
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

        // Up as well as down, since a zoom is allowed to draw the picture
        // past its own pixels — the frame it is given is always exactly the
        // size it should be drawn at, so nothing here fills or distorts.
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        // `animates` is what makes a GIF a moving picture rather than its
        // first frame.
        imageView.animates = true
        imageView.isEditable = false
        canvas.addSubview(imageView)
        scrollView.documentView = canvas

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

    /// The picture is drawn at its own size when the column is big enough to
    /// hold it and shrunk until it fits when it is not, centred either way, so
    /// the whole picture is on screen — a picture is looked at whole, unlike a
    /// document, which is read a page at a time. A zoom multiplies that, and
    /// past the column's room the canvas grows and the picture is scrolled
    /// around instead.
    private func layoutImage() {
        let room = scrollView.contentSize
        guard room.width > 1, room.height > 1 else { return }
        guard let size = imageView.image?.size, size.width > 1, size.height > 1 else {
            canvas.frame = NSRect(origin: .zero, size: room)
            imageView.frame = canvas.bounds
            return
        }
        let drawn = NSSize(width: (size.width * fittedScale(in: room) * zoomStorage).rounded(),
                           height: (size.height * fittedScale(in: room) * zoomStorage).rounded())
        canvas.frame = NSRect(
            origin: .zero,
            size: NSSize(width: max(room.width, drawn.width),
                         height: max(room.height, drawn.height))
        )
        imageView.frame = NSRect(
            x: ((canvas.frame.width - drawn.width) / 2).rounded(),
            y: ((canvas.frame.height - drawn.height) / 2).rounded(),
            width: drawn.width, height: drawn.height
        )
    }

    /// What a zoom of 1 means: the picture at its own size, or shrunk to fit
    /// the column when it is bigger than that. Never blown up — a small icon
    /// is a small icon, and stretching it across the column would be showing
    /// you something the file does not say.
    private func fittedScale(in room: NSSize) -> CGFloat {
        guard let size = imageView.image?.size, size.width > 1, size.height > 1 else { return 1 }
        return min(1, min(room.width / size.width, room.height / size.height))
    }

    // MARK: - Zoom

    private var zoomStorage: CGFloat = 1

    /// A picture zooms rather than changing a font: it is the only thing on
    /// screen in its tab, and its size has nothing to do with the editor's.
    var canZoom: Bool { imageView.image != nil }

    private static let zoomRange: ClosedRange<CGFloat> = 0.25 ... 8

    /// How much bigger than the fitted picture it is drawn. 1 is the fit
    /// itself, which is what "Actual Size" goes back to.
    var zoom: CGFloat {
        get { zoomStorage }
        set {
            let clamped = min(max(newValue, Self.zoomRange.lowerBound),
                              Self.zoomRange.upperBound)
            guard clamped != zoomStorage else { return }
            zoomStorage = clamped
            layoutImage()
        }
    }

    /// The size the picture is actually drawn at, for the tests.
    var drawnSize: NSSize { imageView.frame.size }

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
