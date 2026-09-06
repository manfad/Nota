import AppKit

/// The furniture the sidebar column's lists share: the title over a list, and
/// the card one entry of a picture list is drawn as.
///
/// A note's pictures and a PDF's pages are looked at the same way — a column
/// of small pages, clicked to go there — so they are drawn by the same card
/// rather than by two that drift apart. What differs stays with each list: a
/// gallery card has an asset store, a context menu and a double click that
/// opens the file behind it; a page card has a number and a thumbnail that
/// arrives later.
enum SidebarCard {
    /// The picture square plus 6pt of selection wash on each side.
    static let cellSize: CGFloat = 116
    /// The square a picture or a page is fitted into.
    static let squareSize: CGFloat = 104
    /// Between the card and the caption under it.
    static let captionGap: CGFloat = 4
    static let captionHeight: CGFloat = 15
    /// Between one card and the next.
    static let gap: CGFloat = 12
    /// How tall one card stands, caption and all.
    static let height: CGFloat = cellSize + captionGap + captionHeight
}

/// The title over a sidebar list, in the shape Finder gives its own sidebar
/// sections: 11pt semibold, secondary, at the list's leading margin, with air
/// above and below.
///
/// One word each — Images, Contents, Pages — and it stands at the top of the
/// column, outside the scroll view, so the column always says what it is
/// listing however far down the list has been scrolled.
final class SidebarSectionHeader: NSView {
    /// Where the title starts, measured from the column's own edge, so every
    /// column's title lines up with every other's.
    static let leadingInset: CGFloat = 10
    /// How much room the title takes at the top of a column, so the list
    /// below can start under it.
    static let height: CGFloat = 22
    private static let barHeight: CGFloat = height
    private static let bottomGap: CGFloat = 4

    private let label = NSTextField(labelWithString: "")

    /// What the list below is a list of.
    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    /// `topPadding` is the air above: none for the first title in the column,
    /// a gap for one that follows another list.
    init(title: String, topPadding: CGFloat = 0, leadingInset: CGFloat = leadingInset) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        label.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = title
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.barHeight + topPadding),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.bottomGap),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

// MARK: - One card

/// A thumbnail in the shape Preview.app uses for pages: the picture on a white
/// card with a soft drop shadow, a caption underneath, and — when it is the one
/// being pointed at — a rounded selection wash behind it.
///
/// The picture is settable rather than handed over once: a page's thumbnail is
/// drawn off the main thread and lands after the card is already standing.
class SidebarCardItemView: NSView {

    var onActivate: (() -> Void)?
    /// A double click, where the list has somewhere further to send it.
    var onOpen: (() -> Void)?

    var isHighlighted: Bool {
        get { card.isHighlighted }
        set { card.isHighlighted = newValue }
    }

    /// The picture on the card, or none while there is nothing to draw yet.
    var image: NSImage? {
        get { card.image }
        set { card.image = newValue }
    }

    let captionText: String

    private let card: SidebarCardView
    private let caption = NSTextField(labelWithString: "")

    /// `placeholderGlyph` is what stands on an empty card — a picture that
    /// would not load says so with a glyph; a page whose thumbnail has not
    /// been drawn yet stays blank, since it is coming.
    init(caption text: String, image: NSImage?, placeholderGlyph: String?) {
        self.captionText = text
        self.card = SidebarCardView(image: image, placeholderGlyph: placeholderGlyph)
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false

        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.stringValue = text
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingTail
        caption.maximumNumberOfLines = 1
        addSubview(caption)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: SidebarCard.cellSize),
            heightAnchor.constraint(equalToConstant: SidebarCard.height),

            card.topAnchor.constraint(equalTo: topAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.heightAnchor.constraint(equalToConstant: SidebarCard.cellSize),

            caption.topAnchor.constraint(
                equalTo: card.bottomAnchor, constant: SidebarCard.captionGap
            ),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The selection wash is accent-coloured only while the window is key, so
    /// it is drawn again when that changes.
    func redraw() { card.needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2, onOpen != nil {
            onOpen?()
        } else {
            onActivate?()
        }
    }

    /// As if the card had been clicked — the tests have no window server to
    /// move a pointer through.
    func activateForTesting() { onActivate?() }
}

/// The card itself: a white page sized to the picture's aspect, shadowed, with
/// the selection wash sitting behind it.
private final class SidebarCardView: NSView {
    private static let selectionPadding: CGFloat = 6
    private static let selectionRadius: CGFloat = 8
    private static let cardRadius: CGFloat = 2

    private let placeholderGlyph: String?

    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    var isHighlighted = false {
        didSet { if isHighlighted != oldValue { needsDisplay = true } }
    }

    init(image: NSImage?, placeholderGlyph: String?) {
        self.image = image
        self.placeholderGlyph = placeholderGlyph
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Clicks belong to the item, so it can tell single from double.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let square = NSRect(
            x: bounds.midX - SidebarCard.squareSize / 2,
            y: bounds.midY - SidebarCard.squareSize / 2,
            width: SidebarCard.squareSize,
            height: SidebarCard.squareSize
        )
        let card = image.map { ImageFitting.aspectFit($0.size, in: square) } ?? square

        if isHighlighted {
            let isKey = window?.isKeyWindow ?? false
            let wash = isKey
                ? NSColor.controlAccentColor.withAlphaComponent(0.25)
                : NSColor.unemphasizedSelectedContentBackgroundColor
            wash.setFill()
            NSBezierPath(
                roundedRect: card.insetBy(dx: -Self.selectionPadding, dy: -Self.selectionPadding),
                xRadius: Self.selectionRadius, yRadius: Self.selectionRadius
            ).fill()
        }

        let cardPath = NSBezierPath(
            roundedRect: card, xRadius: Self.cardRadius, yRadius: Self.cardRadius
        )

        // The card and its shadow, then the picture clipped onto it.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.set()
        NSColor.textBackgroundColor.setFill()
        cardPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        cardPath.addClip()
        if let image {
            image.draw(in: card, from: .zero, operation: .sourceOver, fraction: 1)
        } else if let placeholderGlyph {
            let glyph = placeholderGlyph as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 20),
            ]
            let size = glyph.size(withAttributes: attributes)
            glyph.draw(
                at: NSPoint(x: card.midX - size.width / 2, y: card.midY - size.height / 2),
                withAttributes: attributes
            )
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
