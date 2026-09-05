import AppKit

protocol ContentsSidebarViewDelegate: AnyObject {
    func contentsSidebar(_ sidebar: ContentsSidebarView, didChooseLine line: Int)
}

/// A read-only tab's own table of contents, in the sidebar column a note's
/// pictures are shown in: a book's chapters, a PDF's outline.
///
/// A sibling of `ImageSidebarView` rather than a second mode inside it: the
/// two share a column and nothing else. One is a stack of picture cards with
/// an asset store, a caption and a context menu behind each; this is a list of
/// lines of text with a nesting level. Folding them together would be one
/// class with two of everything, so the split item holds both and shows
/// whichever the tab in front has something to say through.
///
/// Nothing here knows what it is listing. The lines arrive as `ContentsEntry`
/// values — a title, a nesting level and the entry's own place in the list —
/// and the content view they came from is what turns a chosen line into a
/// chapter or a page. That is what lets one column serve both kinds.
final class ContentsSidebarView: NSView {
    /// A line is a label, not a paragraph: one row, one line of text.
    static let rowHeight: CGFloat = 24
    /// How far one level of nesting moves a line to the right.
    static let indentUnit: CGFloat = 12
    private static let margin: CGFloat = 4

    weak var delegate: ContentsSidebarViewDelegate?

    private let scrollView = NSScrollView()
    private let container = FlippedContentsView()
    private let stack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: L10n.text("No contents"))
    private var rowViews: [ContentsRowView] = []

    /// The lines on show, in the document's own order.
    private(set) var entries: [ContentsEntry] = []

    /// Which line names what is on screen, or none while the contents say
    /// nothing about it.
    private(set) var selectedLine: Int?

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
        stack.alignment = .leading
        stack.spacing = 0
        container.addSubview(stack)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Only the width is tied to the clip view, so the list is free to
            // grow taller than it and scroll.
            container.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: topInset),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.margin),
            stack.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -Self.margin
            ),
            stack.bottomAnchor.constraint(
                equalTo: container.bottomAnchor, constant: -Self.margin
            ),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Content

    /// Rebuilt only when the lines actually changed, so coming back to a tab
    /// does not throw the list away and lay it out again.
    func setEntries(_ newEntries: [ContentsEntry], force: Bool = false) {
        guard force || newEntries != entries else { return }
        entries = newEntries

        for view in rowViews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rowViews = newEntries.map { entry in
            let row = ContentsRowView(title: entry.title, level: entry.level)
            row.onActivate = { [weak self] in
                guard let self else { return }
                self.delegate?.contentsSidebar(self, didChooseLine: entry.line)
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            return row
        }

        emptyLabel.isHidden = !newEntries.isEmpty
        scrollView.isHidden = newEntries.isEmpty
        applySelection()
    }

    /// Rings the line naming what is on screen and keeps it in view — a
    /// chapter turned with `→`, a page scrolled past — the same way a click
    /// on the list moves it.
    func setSelectedLine(_ line: Int?) {
        selectedLine = line
        applySelection()
        guard let line, let row = rowIndex(ofLine: line),
              rowViews.indices.contains(row) else { return }
        rowViews[row].scrollToVisible(rowViews[row].bounds)
    }

    private func applySelection() {
        let selectedRow = selectedLine.flatMap { rowIndex(ofLine: $0) }
        for (index, row) in rowViews.enumerated() {
            row.isSelected = index == selectedRow
        }
    }

    private func rowIndex(ofLine line: Int) -> Int? {
        entries.firstIndex { $0.line == line }
    }

    // MARK: - Tests

    /// What the column is listing, and how deep each line sits — the tests
    /// have no other way to read a stack of views.
    var rowTitles: [String] { entries.map(\.title) }
    /// Whether the quiet "No contents" hint is what the column is showing —
    /// a document with no outline, pinned open with ⌘B.
    var showsEmptyHint: Bool { !emptyLabel.isHidden }
    var rowIndents: [CGFloat] { rowViews.map(\.indent) }
    var selectedRowTitle: String? {
        rowViews.first(where: \.isSelected)?.title
    }

    /// As if a line had been clicked — the tests have no window server to
    /// move a pointer through.
    func chooseRow(_ index: Int) {
        guard rowViews.indices.contains(index) else { return }
        rowViews[index].activateForTesting()
    }
}

/// Document views are bottom-up by default; a list of contents reads down.
private final class FlippedContentsView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - One line

/// One line of the contents: the title, indented by its nesting, on a rounded
/// wash while it names what is on screen or is the line under the pointer.
///
/// The wash is grey rather than the accent colour — the ⌘P switcher's own
/// rows, not a document selection. Nothing here is being edited, so a blue
/// bar would be claiming something the list cannot do.
private final class ContentsRowView: NSView {
    private static let radius: CGFloat = 5
    private static let leadingMargin: CGFloat = 6

    let title: String
    let indent: CGFloat

    var onActivate: (() -> Void)?

    var isSelected = false {
        didSet { if isSelected != oldValue { needsDisplay = true } }
    }
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    private let label = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?

    init(title: String, level: Int) {
        self.title = title
        self.indent = CGFloat(max(0, level - 1)) * ContentsSidebarView.indentUnit
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        toolTip = title

        label.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = title
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: ContentsSidebarView.rowHeight),
            label.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: Self.leadingMargin + indent
            ),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.leadingMargin),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }

    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) { onActivate?() }

    func activateForTesting() { onActivate?() }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected || isHovered else { return }
        let wash = isSelected
            ? NSColor.unemphasizedSelectedContentBackgroundColor
            : NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.5)
        wash.setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 2, dy: 1),
            xRadius: Self.radius, yRadius: Self.radius
        ).fill()
    }
}
