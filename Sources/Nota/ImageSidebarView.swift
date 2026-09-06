import AppKit

protocol ImageSidebarViewDelegate: AnyObject {
    func imageSidebar(_ sidebar: ImageSidebarView, didActivateItemAt index: Int)
}

/// The right-hand panel showing the current tab's images full width, in the
/// order they appear in the text. The inline chips stay small; this is where
/// the pictures are actually looked at.
///
/// The cards are `SidebarCardItemView`s, the same ones a PDF's pages stand on
/// in the same column: what the gallery adds is the store behind each picture,
/// the context menu and the double click that opens the file.
final class ImageSidebarView: NSView {
    static let width: CGFloat = 150
    private static let margin: CGFloat = 8

    weak var delegate: ImageSidebarViewDelegate?
    var assets: AssetStore?

    private let scrollView = NSScrollView()
    private let container = FlippedView()
    private let stack = NSStackView()
    private let header = SidebarSectionHeader(title: L10n.text("Images"))
    private let emptyLabel = NSTextField(labelWithString: "No images")
    private var itemViews: [SidebarImageItemView] = []

    /// What is currently on show, in document order. Duplicates are kept:
    /// the same picture used twice gets two rows, matching the two chips.
    private(set) var assetIDs: [String] = []

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
        stack.spacing = SidebarCard.gap
        container.addSubview(stack)

        // Above the scroll view rather than inside it: the column says what
        // it is listing however far the list has been scrolled.
        addSubview(header)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: topInset),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Only the width is tied to the clip view, so the container is
            // free to grow taller than it and scroll.
            container.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            stack.topAnchor.constraint(
                equalTo: container.topAnchor, constant: SidebarCard.gap / 2
            ),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.margin),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Content

    /// Rebuilds only when the sequence of asset ids actually changed, so
    /// typing next to an image does not make the sidebar flicker.
    func setAssetIDs(_ ids: [String], force: Bool = false) {
        header.title = L10n.text("Images")
        header.count = ids.count
        guard force || ids != assetIDs else { return }
        assetIDs = ids

        for view in itemViews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        itemViews = ids.enumerated().map { index, assetID in
            let item = SidebarImageItemView(index: index, assetID: assetID, assets: assets)
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

    // MARK: - Tests

    /// The title standing over the column, which a note's column always has:
    /// it says what the column is for, empty or not.
    var headerTitle: String { header.title }
    var headerCount: Int? { header.count }
}

/// Document views are bottom-up by default; images should stack downwards.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - One image

/// A gallery card: the shared thumbnail card, with an `Image N` caption and
/// the three things only a picture out of the store can offer — copy, save a
/// copy, and reveal the file behind it.
private final class SidebarImageItemView: SidebarCardItemView {
    let index: Int
    let assetID: String

    private let assets: AssetStore?

    init(index: Int, assetID: String, assets: AssetStore?) {
        self.index = index
        self.assetID = assetID
        self.assets = assets
        super.init(
            caption: "\(L10n.text("Image")) \(index + 1)",
            image: assets?.image(for: assetID),
            placeholderGlyph: "\u{1F5BC}"
        )
        toolTip = assetID
        menu = buildMenu()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

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
