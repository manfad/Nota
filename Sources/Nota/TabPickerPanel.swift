import AppKit

protocol TabPickerPanelDelegate: AnyObject {
    func tabPicker(_ picker: TabPickerPanel, didChoose tabIndex: Int)
}

/// ⌘P: a small centred panel in the shape of Xcode's Open Quickly — a search
/// field over a list, fuzzy-matched on tab title.
final class TabPickerPanel: NSObject {
    private static let panelWidth: CGFloat = 420
    private static let rowHeight: CGFloat = 26
    private static let maximumVisibleRows = 10

    weak var delegate: TabPickerPanelDelegate?

    private let panel: NSPanel
    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var titles: [String] = []
    private var ranked: [(index: Int, result: FuzzyMatch.Result)] = []

    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 200),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating

        let background = NSVisualEffectView()
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        panel.contentView = background

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Go to tab"
        searchField.font = .systemFont(ofSize: 15)
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.delegate = self
        background.addSubview(searchField)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(divider)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tab"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.backgroundColor = .clear
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
            searchField.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),

            divider.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            divider.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: background.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
    }

    // MARK: - Showing

    func show(titles: [String], selectedIndex: Int, over window: NSWindow) {
        self.titles = titles
        searchField.stringValue = ""
        reload(preferring: selectedIndex)

        panel.setContentSize(NSSize(width: Self.panelWidth, height: panelHeight))
        if let frame = window.screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - Self.panelWidth / 2,
                y: frame.midY - panelHeight / 2 + frame.height * 0.12
            ))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    func hide() {
        panel.orderOut(nil)
    }

    private var panelHeight: CGFloat {
        let rows = max(1, min(ranked.isEmpty ? 1 : ranked.count, Self.maximumVisibleRows))
        return CGFloat(rows) * Self.rowHeight + 52
    }

    private func reload(preferring selectedIndex: Int = -1) {
        let query = searchField.stringValue
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            ranked = titles.indices.map {
                (index: $0, result: FuzzyMatch.Result(score: 0, matchedIndices: []))
            }
        } else {
            ranked = FuzzyMatch.rank(query: query, titles: titles)
        }
        tableView.reloadData()

        let row = ranked.firstIndex { $0.index == selectedIndex } ?? 0
        if !ranked.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }
        panel.setContentSize(NSSize(width: Self.panelWidth, height: panelHeight))
    }

    private func moveSelection(by delta: Int) {
        guard !ranked.isEmpty else { return }
        let current = max(0, tableView.selectedRow)
        let next = max(0, min(ranked.count - 1, current + delta))
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    private func commit() {
        let row = tableView.selectedRow
        guard ranked.indices.contains(row) else { return }
        let tabIndex = ranked[row].index
        hide()
        delegate?.tabPicker(self, didChoose: tabIndex)
    }

    @objc private func rowClicked() { commit() }
}

// MARK: - Field

extension TabPickerPanel: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        reload()
    }

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            commit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
            return true
        default:
            return false
        }
    }
}

// MARK: - List

extension TabPickerPanel: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        ranked.isEmpty ? 1 : ranked.count
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !ranked.isEmpty
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("TabPickerCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? {
                let view = NSTableCellView()
                let field = NSTextField(labelWithString: "")
                field.translatesAutoresizingMaskIntoConstraints = false
                field.lineBreakMode = .byTruncatingTail
                view.addSubview(field)
                view.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
                    field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
                    field.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                ])
                view.identifier = identifier
                return view
            }()

        guard !ranked.isEmpty else {
            cell.textField?.attributedStringValue = NSAttributedString(
                string: "No tabs",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
            return cell
        }

        let entry = ranked[row]
        let title = titles[entry.index]
        let attributed = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        // Bold the characters the query actually matched.
        for index in entry.result.matchedIndices where index < title.count {
            attributed.addAttribute(
                .font, value: NSFont.boldSystemFont(ofSize: 13),
                range: NSRange(location: index, length: 1)
            )
        }
        cell.textField?.attributedStringValue = attributed
        return cell
    }
}
