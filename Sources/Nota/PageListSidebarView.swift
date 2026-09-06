import AppKit

protocol PageListSidebarViewDelegate: AnyObject {
    func pageListSidebar(_ sidebar: PageListSidebarView, didChoosePage page: Int)
}

/// A document's pages, drawn small, in the sidebar column a note's pictures are
/// shown in: one card per page, in order, the page in front washed, and a click
/// taking the reader there.
///
/// The third sibling in that column, beside `ImageSidebarView` and
/// `ContentsSidebarView`. It shares the gallery's card — the same white page
/// with the same shadow, the same wash and the same caption underneath — since
/// a picture and a page are looked at in the same way and drifting apart would
/// only be an accident. What it does not share is where the picture comes
/// from: a gallery card has its bytes in hand, and a page card is a blank one
/// until the document has been asked to draw it.
///
/// Nothing here knows what a page is. The list arrives as a `PageListSource` —
/// how many pages, which is in front, go to one, draw one — and the content
/// view behind it is the only thing that knows what any of that means.
final class PageListSidebarView: NSView {
    private static let margin: CGFloat = 8
    /// How many pages are drawn before the column has been laid out and can
    /// say which of them are actually being looked at.
    private static let firstScreenful = 12

    weak var delegate: PageListSidebarViewDelegate?

    private let scrollView = NSScrollView()
    private let container = FlippedPageListView()
    private let stack = NSStackView()
    private let header = SidebarSectionHeader(title: L10n.text("Pages"))
    private var cards: [SidebarCardItemView] = []

    /// The pages on show, which document they came from, and which of them is
    /// in front.
    private(set) weak var pages: PageListSource?
    private var pagesIdentity: AnyHashable?
    private(set) var selectedPageIndex: Int?

    init(topInset: CGFloat) {
        super.init(frame: .zero)

        // Above the scroll view rather than inside it, so the column goes on
        // saying what it is listing however far the list has been scrolled.
        addSubview(header)

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

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: topInset),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Only the width is tied to the clip view, so the list is free to
            // grow taller than it and scroll.
            container.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            stack.topAnchor.constraint(
                equalTo: container.topAnchor, constant: SidebarCard.gap / 2
            ),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.margin),
        ])

        // Thumbnails are drawn for the cards actually being looked at, so a
        // five-hundred-page document costs a screenful rather than five
        // hundred renders.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(visibleAreaChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Content

    /// The document's pages, one card each. Rebuilt only when the document
    /// behind them changed — coming back to a tab keeps the cards, and the
    /// thumbnails already drawn on them.
    func setPages(_ source: PageListSource?, force: Bool = false) {
        header.title = L10n.text("Pages")
        let count = source?.pageCount ?? 0
        let identity = source?.pageListIdentity
        let sameList = identity != nil && identity == pagesIdentity && count == cards.count
        pages = source
        pagesIdentity = identity
        guard force || !sameList else {
            requestVisibleThumbnails()
            return
        }

        for card in cards {
            stack.removeArrangedSubview(card)
            card.removeFromSuperview()
        }
        cards = (0 ..< count).map { index in
            let card = SidebarCardItemView(
                caption: "\(L10n.text("Page")) \(index + 1)", image: nil, placeholderGlyph: nil
            )
            card.onActivate = { [weak self] in
                guard let self else { return }
                self.delegate?.pageListSidebar(self, didChoosePage: index)
            }
            stack.addArrangedSubview(card)
            return card
        }

        applySelection()
        requestVisibleThumbnails()
    }

    /// Rings the card for the page in front and keeps it in view, so scrolling
    /// or paging through the document walks the column too.
    func setSelectedPage(_ index: Int?) {
        selectedPageIndex = index
        applySelection()
        guard let index, cards.indices.contains(index) else { return }
        cards[index].scrollToVisible(cards[index].bounds)
    }

    private func applySelection() {
        for (index, card) in cards.enumerated() {
            card.isHighlighted = index == selectedPageIndex
        }
    }

    /// The selection wash is accent-coloured only while the window is key.
    func redrawItems() {
        for card in cards { card.redraw() }
    }

    // MARK: - Drawing the pages

    @objc private func visibleAreaChanged() { requestVisibleThumbnails() }

    override func layout() {
        super.layout()
        requestVisibleThumbnails()
    }

    /// Asks for the thumbnails of the cards on screen, and of a screenful
    /// either side of them so scrolling lands on pages already drawn.
    ///
    /// Nothing is queued for a card nobody has looked at yet: a long document
    /// would otherwise spend its first seconds drawing pages hundreds of
    /// scrolls away. Before the column has been laid out there is no visible
    /// rectangle to go by, so the first screenful stands in — which is also
    /// what the tests see.
    private func requestVisibleThumbnails() {
        guard let pages, !cards.isEmpty else { return }
        let visible = scrollView.contentView.bounds
        let wanted: Range<Int>
        if visible.height > 1, container.frame.height > 1 {
            let area = visible.insetBy(dx: 0, dy: -visible.height)
            var first = cards.count
            var last = -1
            for (index, card) in cards.enumerated() {
                guard card.convert(card.bounds, to: container).intersects(area) else { continue }
                first = min(first, index)
                last = max(last, index)
            }
            wanted = last >= first ? first ..< (last + 1) : 0 ..< 0
        } else {
            wanted = 0 ..< min(cards.count, Self.firstScreenful)
        }
        for index in wanted where cards[index].image == nil {
            pages.thumbnail(forPage: index) { [weak self] image in
                guard let self, self.pages === pages,
                      self.cards.indices.contains(index) else { return }
                self.cards[index].image = image
            }
        }
    }

    // MARK: - Tests

    /// The caption under each card, the picture on one of them, and how many
    /// have got one — the tests have no other way to read a stack of views.
    var pageCaptions: [String] { cards.map(\.captionText) }
    var drawnPageThumbnails: Int { cards.filter { $0.image != nil }.count }

    func pageThumbnail(_ index: Int) -> NSImage? {
        cards.indices.contains(index) ? cards[index].image : nil
    }

    /// The title standing over the column, which it always has: it says what
    /// the column is for, empty or not.
    var headerTitle: String { header.title }

    /// As if a card had been clicked — the tests have no window server to
    /// move a pointer through.
    func choosePage(_ index: Int) {
        guard cards.indices.contains(index) else { return }
        cards[index].activateForTesting()
    }
}

/// Document views are bottom-up by default; pages should stack downwards.
private final class FlippedPageListView: NSView {
    override var isFlipped: Bool { true }
}
