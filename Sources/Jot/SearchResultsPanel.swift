import AppKit

protocol SearchResultsPanelDelegate: AnyObject {
    func searchResultsPanel(_ panel: SearchResultsPanel, didChoose match: NoteSearchMatch)
}

/// The drop-down under the search field.
///
/// It lives in a non-activating borderless panel attached to the main window,
/// so it can be clicked without ever taking key status away from the search
/// field the person is still typing in.
final class SearchResultsPanel: NSObject {
    weak var delegate: SearchResultsPanelDelegate?

    private static let rowHeight: CGFloat = 40
    private static let maximumVisibleRows = 10
    private static let width: CGFloat = 420

    private let panel: NSPanel
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var matches: [NoteSearchMatch] = []
    private var isAttached = false

    var isVisible: Bool { panel.isVisible }

    var selectedMatch: NoteSearchMatch? {
        let row = tableView.selectedRow
        guard matches.indices.contains(row) else { return nil }
        return matches[row]
    }

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.rowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false

        let background = NSVisualEffectView()
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.masksToBounds = true
        panel.contentView = background

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        background.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: background.topAnchor, constant: 2),
            scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -2),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
        ])
    }

    // MARK: - Showing

    func show(matches: [NoteSearchMatch], below anchor: NSView, in window: NSWindow) {
        self.matches = matches
        tableView.reloadData()
        if !matches.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }

        if !isAttached {
            window.addChildWindow(panel, ordered: .above)
            isAttached = true
        }
        position(below: anchor, in: window)
        panel.orderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
        matches = []
        tableView.reloadData()
    }

    /// Keeps the panel glued to the field as the window moves or resizes.
    func position(below anchor: NSView, in window: NSWindow) {
        let rows = max(1, min(matches.isEmpty ? 1 : matches.count, Self.maximumVisibleRows))
        let height = CGFloat(rows) * Self.rowHeight + 4

        let inWindow = anchor.convert(anchor.bounds, to: nil)
        let onScreen = window.convertToScreen(inWindow)
        panel.setFrame(
            NSRect(x: onScreen.maxX - Self.width, y: onScreen.minY - 4 - height,
                   width: Self.width, height: height),
            display: true
        )
    }

    // MARK: - Keyboard

    func moveSelection(by delta: Int) {
        guard !matches.isEmpty else { return }
        let current = tableView.selectedRow
        let next = max(0, min(matches.count - 1, (current < 0 ? 0 : current) + delta))
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    @objc private func rowClicked() {
        guard let match = selectedMatch else { return }
        delegate?.searchResultsPanel(self, didChoose: match)
    }
}

// MARK: - Table

extension SearchResultsPanel: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        matches.isEmpty ? 1 : matches.count
    }

    /// With no matches the table still shows one row, saying so.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !matches.isEmpty
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        let cell = tableView.makeView(withIdentifier: SearchResultCell.identifier, owner: self)
            as? SearchResultCell ?? SearchResultCell()
        cell.identifier = SearchResultCell.identifier

        if matches.isEmpty {
            cell.configureEmpty()
        } else {
            let match = matches[row]
            cell.configure(
                title: match.tabTitle,
                snippet: match.snippet,
                matchRange: match.rangeInSnippet
            )
        }
        return cell
    }
}

// MARK: - Row

private final class SearchResultCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SearchResultCell")

    private let titleLabel = NSTextField(labelWithString: "")
    private let snippetLabel = NSTextField(labelWithString: "")
    private var snippetText = ""
    private var matchRange = NSRange(location: 0, length: 0)
    private var isEmptyRow = false

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { restyle() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleLabel.font = .systemFont(ofSize: 11)
        snippetLabel.font = .systemFont(ofSize: 12)
        for label in [titleLabel, snippetLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.cell?.truncatesLastVisibleLine = true
            addSubview(label)
        }

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            snippetLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            snippetLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            snippetLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(title: String, snippet: String, matchRange: NSRange) {
        isEmptyRow = false
        titleLabel.stringValue = title
        // An image is one object-replacement character; show it as a space
        // rather than a hollow box, which keeps the match range valid.
        snippetText = snippet.replacingOccurrences(of: "\u{FFFC}", with: " ")
        self.matchRange = matchRange
        restyle()
    }

    func configureEmpty() {
        isEmptyRow = true
        titleLabel.stringValue = ""
        snippetText = "No results"
        matchRange = NSRange(location: 0, length: 0)
        restyle()
    }

    private func restyle() {
        let emphasized = backgroundStyle == .emphasized
        titleLabel.textColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor

        let color: NSColor = isEmptyRow
            ? .secondaryLabelColor
            : (emphasized ? .alternateSelectedControlTextColor : .labelColor)
        let attributed = NSMutableAttributedString(
            string: snippetText,
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: color]
        )
        if matchRange.length > 0, NSMaxRange(matchRange) <= attributed.length {
            attributed.addAttribute(
                .font, value: NSFont.boldSystemFont(ofSize: 12), range: matchRange
            )
        }
        snippetLabel.attributedStringValue = attributed
    }
}
