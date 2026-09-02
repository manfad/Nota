import AppKit

protocol ImageSidebarViewDelegate: AnyObject {
    func imageSidebar(_ sidebar: ImageSidebarView, didActivateItemAt index: Int)
}

/// The right-hand panel showing the current tab's images full width, in the
/// order they appear in the text. The inline chips stay small; this is where
/// the pictures are actually looked at.
final class ImageSidebarView: NSView {
    static let width: CGFloat = 150
    /// The picture square (104) plus 6pt of selection wash on each side.
    static let cellSize: CGFloat = 116
    private static let margin: CGFloat = 8
    private static let gap: CGFloat = 12
    /// The bottom utility strip: room for a comfortable hit target without
    /// stealing height from the pictures.
    static let utilityRowHeight: CGFloat = 28
    private static let utilityInset: CGFloat = 8
    private static let gearSize: CGFloat = 22

    weak var delegate: ImageSidebarViewDelegate?
    var assets: AssetStore?

    private let scrollView = NSScrollView()
    /// Bottom-pinned strip for the sidebar's small utilities — the Settings
    /// gear for now — sitting under a hairline of its own.
    private let utilityRow = NSView()
    private let utilitySeparator = NSBox()
    private let settingsButton = NSButton()
    private let container = FlippedView()
    private let stack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "No images")
    private var itemViews: [SidebarImageItemView] = []

    /// What is currently on show, in document order. Duplicates are kept:
    /// the same picture used twice gets two rows, matching the two chips.
    private(set) var assetIDs: [String] = []

    /// Run when the gear is clicked. The window controller opens Settings,
    /// the same window ⌘, does.
    var onSettings: (() -> Void)?

    init(topInset: CGFloat) {
        super.init(frame: .zero)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = container
        addSubview(scrollView)

        container.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Self.gap
        container.addSubview(stack)

        utilityRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(utilityRow)

        utilitySeparator.boxType = .separator
        utilitySeparator.translatesAutoresizingMaskIntoConstraints = false
        utilityRow.addSubview(utilitySeparator)

        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.image = NSImage(
            systemSymbolName: "gear", accessibilityDescription: "Settings"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        )
        settingsButton.image?.isTemplate = true
        settingsButton.isBordered = false
        settingsButton.bezelStyle = .inline
        settingsButton.imagePosition = .imageOnly
        settingsButton.contentTintColor = .secondaryLabelColor
        settingsButton.toolTip = "Settings"
        settingsButton.setAccessibilityLabel("Settings")
        settingsButton.target = self
        settingsButton.action = #selector(settingsClicked)
        utilityRow.addSubview(settingsButton)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: utilityRow.topAnchor),

            utilityRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            utilityRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            utilityRow.bottomAnchor.constraint(equalTo: bottomAnchor),
            utilityRow.heightAnchor.constraint(equalToConstant: Self.utilityRowHeight),

            utilitySeparator.topAnchor.constraint(equalTo: utilityRow.topAnchor),
            utilitySeparator.leadingAnchor.constraint(equalTo: utilityRow.leadingAnchor),
            utilitySeparator.trailingAnchor.constraint(equalTo: utilityRow.trailingAnchor),

            settingsButton.leadingAnchor.constraint(
                equalTo: utilityRow.leadingAnchor, constant: Self.utilityInset
            ),
            settingsButton.centerYAnchor.constraint(equalTo: utilityRow.centerYAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: Self.gearSize),
            settingsButton.heightAnchor.constraint(equalToConstant: Self.gearSize),

            // Only the width is tied to the clip view, so the container is
            // free to grow taller than it and scroll.
            container.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: topInset),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.margin),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.margin),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.margin),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func settingsClicked() { onSettings?() }

    /// The utility strip, for the layout test: the row, the gear inside it,
    /// and the thumbnail list that has to sit clear of both.
    var utilityRowViews: (row: NSView, gear: NSButton, list: NSScrollView) {
        (utilityRow, settingsButton, scrollView)
    }

    // MARK: - Content

    /// Rebuilds only when the sequence of asset ids actually changed, so
    /// typing next to an image does not make the sidebar flicker.
    func setAssetIDs(_ ids: [String], force: Bool = false) {
        guard force || ids != assetIDs else { return }
        assetIDs = ids

        for view in itemViews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        itemViews = ids.enumerated().map { index, assetID in
            let item = SidebarImageItemView(
                index: index,
                assetID: assetID,
                assets: assets,
                width: Self.cellSize
            )
            item.onActivate = { [weak self] in
                guard let self else { return }
                self.delegate?.imageSidebar(self, didActivateItemAt: index)
            }
            item.onOpen = { [weak self] in
                guard let url = self?.assets?.url(for: assetID),
                      FileManager.default.fileExists(atPath: url.path) else { return }
                NSWorkspace.shared.open(url)
            }
            stack.addArrangedSubview(item)
            return item
        }

        emptyLabel.isHidden = !ids.isEmpty
        scrollView.isHidden = ids.isEmpty
    }

    /// The selection wash is accent-coloured only while the window is key.
    func redrawItems() {
        for item in itemViews { item.redraw() }
    }

    func setHighlighted(_ indices: Set<Int>) {
        for (index, item) in itemViews.enumerated() {
            item.isHighlighted = indices.contains(index)
        }
    }

    func scrollItemToVisible(_ index: Int) {
        guard itemViews.indices.contains(index) else { return }
        let item = itemViews[index]
        item.scrollToVisible(item.bounds)
    }
}

/// Document views are bottom-up by default; images should stack downwards.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - One image

/// A thumbnail in the shape Preview.app uses for pages: the picture on a
/// white card with a soft drop shadow, an `Image N` caption underneath, and —
/// when it is the one the caret is on — a rounded selection wash behind it.
private final class SidebarImageItemView: NSView {
    private static let captionGap: CGFloat = 4
    private static let captionHeight: CGFloat = 15

    let index: Int
    let assetID: String

    var onActivate: (() -> Void)?
    var onOpen: (() -> Void)?

    var isHighlighted: Bool {
        get { thumbnail.isHighlighted }
        set { thumbnail.isHighlighted = newValue }
    }

    private let assets: AssetStore?
    private let thumbnail: ThumbnailView
    private let caption = NSTextField(labelWithString: "")

    init(index: Int, assetID: String, assets: AssetStore?, width: CGFloat) {
        self.index = index
        self.assetID = assetID
        self.assets = assets
        self.thumbnail = ThumbnailView(image: assets?.image(for: assetID))
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        toolTip = assetID

        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        addSubview(thumbnail)

        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.stringValue = "Image \(index + 1)"
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingTail
        caption.maximumNumberOfLines = 1
        addSubview(caption)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(
                equalToConstant: width + Self.captionGap + Self.captionHeight
            ),

            thumbnail.topAnchor.constraint(equalTo: topAnchor),
            thumbnail.leadingAnchor.constraint(equalTo: leadingAnchor),
            thumbnail.trailingAnchor.constraint(equalTo: trailingAnchor),
            thumbnail.heightAnchor.constraint(equalToConstant: width),

            caption.topAnchor.constraint(
                equalTo: thumbnail.bottomAnchor, constant: Self.captionGap
            ),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        menu = buildMenu()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func redraw() { thumbnail.needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onOpen?()
        } else {
            onActivate?()
        }
    }

    // MARK: Context menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [
            ("Copy Image", #selector(copyImage)),
            ("Save Image As…", #selector(saveImageAs)),
            ("Reveal in Finder", #selector(revealInFinder)),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    private var assetURL: URL? { assets?.url(for: assetID) }

    @objc private func copyImage() {
        guard let png = assets?.pngData(for: assetID) else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(png, forType: .png)
    }

    @objc private func saveImageAs() {
        guard let data = assets?.data(for: assetID) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = assetID
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }

    @objc private func revealInFinder() {
        guard let assetURL, FileManager.default.fileExists(atPath: assetURL.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([assetURL])
    }
}

/// The picture itself: a white card sized to the image's aspect, shadowed,
/// with the selection wash sitting behind it.
private final class ThumbnailView: NSView {
    /// The square the picture is fitted into; the wash extends past it.
    static let squareSize: CGFloat = 104
    private static let selectionPadding: CGFloat = 6
    private static let selectionRadius: CGFloat = 8
    private static let cardRadius: CGFloat = 2

    private let image: NSImage?
    var isHighlighted = false {
        didSet { if isHighlighted != oldValue { needsDisplay = true } }
    }

    init(image: NSImage?) {
        self.image = image
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Clicks belong to the item, so it can tell single from double.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let square = NSRect(
            x: bounds.midX - Self.squareSize / 2,
            y: bounds.midY - Self.squareSize / 2,
            width: Self.squareSize,
            height: Self.squareSize
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
        } else {
            let glyph = "\u{1F5BC}" as NSString
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
