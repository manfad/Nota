import AppKit

/// The list Settings › Shortcuts and Settings › File types are both made of:
/// tick boxes on indented rows under group rows that fold away, the shape
/// System Settings gives its own keyboard shortcuts.
///
/// One thing here is deliberate and unusual. A row's controls belong to the
/// item rather than to the cell the outline lends it, and every cell is built
/// when the page is, not when the row first scrolls into view. A page can then
/// write a row's state without asking whether it is on screen, and a test can
/// reach the twenty-eighth extension without scrolling to it — which is the
/// whole reason the two pages could leave their stacks of rows behind.

/// One row: a tick box, a title, and something at the trailing edge — the app
/// that opens a kind of file.
final class SettingsOutlineItem: NSObject {
    /// The `L10n` key the title is looked up under. A literal no table holds
    /// — ".md" — comes back unchanged, which is what a file-type row wants.
    let titleKey: String

    /// The rows folded under this one. Empty makes it a child row.
    let children: [SettingsOutlineItem]

    var isGroup: Bool { !children.isEmpty }

    /// The tick box, owned here so a page can read and write it whether or
    /// not the row has ever been drawn.
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    /// The `?` after the title, where the row has one. The page makes it, so
    /// the single popover every `?` in Settings shares still serves this one.
    let accessory: NSButton?

    let titleField: SettingsOutlineLabel
    let trailingField: SettingsOutlineLabel

    /// The cell the outline hands back for this row, every time.
    private(set) var cell: SettingsOutlineCellView!

    /// The tick was clicked; true where the row is now on. The model decides
    /// what a click means, so a group's mixed box reads as "turn it all on".
    var onToggle: ((Bool) -> Void)?

    var state: NSControl.StateValue = .off
    var isEnabled = true
    var trailingText = ""
    var trailingColor: NSColor = .labelColor

    init(
        titleKey: String,
        accessory: NSButton? = nil,
        children: [SettingsOutlineItem] = []
    ) {
        self.titleKey = titleKey
        self.children = children
        self.accessory = accessory
        let isGroup = !children.isEmpty
        titleField = SettingsOutlineLabel(
            text: "",
            font: .systemFont(ofSize: 13, weight: isGroup ? .semibold : .regular)
        )
        trailingField = SettingsOutlineLabel(text: "", font: .systemFont(ofSize: 13))
        super.init()

        checkbox.allowsMixedState = isGroup
        checkbox.target = self
        checkbox.action = #selector(checkboxClicked(_:))
        cell = SettingsOutlineCellView(item: self)
        apply()
    }

    /// Draws the row from the model. Called whenever a page has written
    /// something, and on a language change.
    func apply() {
        titleField.stringValue = L10n.text(titleKey)
        checkbox.state = state
        checkbox.isEnabled = isEnabled
        checkbox.setAccessibilityLabel(titleField.stringValue)
        titleField.textColor = isEnabled ? .labelColor : .tertiaryLabelColor
        // A group row has no key and no app of its own, so its trailing
        // column is simply empty rather than saying "None" about nothing.
        trailingField.stringValue = trailingText
        trailingField.textColor = trailingColor
    }

    /// The state a group row wears, read off the rows folded under it.
    func groupState() -> NSControl.StateValue {
        guard isGroup else { return state }
        let on = children.filter { $0.state == .on }.count
        if on == 0 { return .off }
        if on == children.count { return .on }
        return .mixed
    }

    @objc private func checkboxClicked(_ sender: NSButton) {
        // A three-state box cycles through mixed on its own, and mixed is not
        // something a reader can mean by a click. What they mean is the
        // opposite of where the row stood, so the model decides and the
        // button is told.
        let turningOn = state != .on
        state = turningOn ? .on : .off
        sender.state = state
        onToggle?(turningOn)
    }
}

/// A plain label with the one init the rows want.
final class SettingsOutlineLabel: NSTextField {
    init(text: String, font: NSFont) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        self.font = font
        stringValue = text
        lineBreakMode = .byTruncatingTail
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// One row's view: the tick box at the leading edge, the title after it, and
/// the trailing label at the far end.
///
/// The cell is frame-positioned by the outline, the way a table cell is, so it
/// is given a row's height at birth. That is what lets a page ask a row it has
/// never drawn how tall it is.
final class SettingsOutlineCellView: NSTableCellView {
    init(item: SettingsOutlineItem) {
        var content: [NSView] = [item.titleField]
        if let accessory = item.accessory { content.append(accessory) }
        let contentStack = NSStackView(views: content)
        contentStack.orientation = .horizontal
        contentStack.spacing = 7
        contentStack.alignment = .centerY

        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: SettingsOutlineView.rowHeight))

        for view in [item.checkbox, contentStack, item.trailingField] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        contentStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        item.titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        item.trailingField.setContentHuggingPriority(.required, for: .horizontal)
        item.trailingField.setContentCompressionResistancePriority(.required, for: .horizontal)
        item.checkbox.setContentHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            item.checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            item.checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            contentStack.leadingAnchor.constraint(
                equalTo: item.checkbox.trailingAnchor, constant: 6
            ),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            item.trailingField.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -12
            ),
            item.trailingField.centerYAnchor.constraint(equalTo: centerYAnchor),
            item.trailingField.leadingAnchor.constraint(
                greaterThanOrEqualTo: contentStack.trailingAnchor, constant: 12
            ),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// The stripe behind a row. Even rows take the group's own fill, odd rows a
/// touch more of it, which is the quiet banding the reference draws.
final class SettingsOutlineRowView: NSTableRowView {
    private var isAlternate = false

    func setAlternate(_ alternate: Bool) {
        guard alternate != isAlternate else { return }
        isAlternate = alternate
        needsDisplay = true
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard isAlternate else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            SettingsPalette.rowAlternateFill.setFill()
            dirtyRect.fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The rounded card the rows sit in, and the outline inside it.
final class SettingsOutlineView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    static let rowHeight: CGFloat = 34

    let groups: [SettingsOutlineItem]
    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private var heightConstraint: NSLayoutConstraint!

    /// Every child row, in the order the page lists them.
    var items: [SettingsOutlineItem] { groups.flatMap(\.children) }

    init(groups: [SettingsOutlineItem], expandFirstGroup: Bool = true) {
        self.groups = groups
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("settings"))
        column.minWidth = 80
        column.maxWidth = 10_000
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = Self.rowHeight
        outline.indentationPerLevel = 14
        outline.selectionHighlightStyle = .none
        outline.allowsEmptySelection = true
        outline.backgroundColor = .clear
        outline.gridStyleMask = []
        outline.style = .plain
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.autoresizesOutlineColumn = false
        outline.usesAlternatingRowBackgroundColors = false
        outline.dataSource = self
        outline.delegate = self

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = outline
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false
        addSubview(scroll)

        heightConstraint = heightAnchor.constraint(equalToConstant: Self.rowHeight)
        heightConstraint.priority = .required
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightConstraint,
        ])

        outline.reloadData()
        if expandFirstGroup, let first = groups.first { outline.expandItem(first) }
        updateHeight()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Opens every group — what a screenshot wants, and what a test that
    /// reads the rows on screen wants.
    func expandAllGroups() {
        for group in groups { outline.expandItem(group) }
        updateHeight()
    }

    /// Redraws every row from its model: a language change, or a page that
    /// has just written a whole column.
    func applyAll() {
        for group in groups {
            group.state = group.groupState()
            group.apply()
            for child in group.children { child.apply() }
        }
    }

    /// Reads each group's tick off the rows folded under it.
    func refreshGroupStates() {
        for group in groups {
            group.state = group.groupState()
            group.apply()
        }
    }

    override func layout() {
        super.layout()
        if let column = outline.tableColumns.first, abs(column.width - bounds.width) > 0.5 {
            column.width = bounds.width
        }
    }

    private func updateHeight() {
        let height = max(Self.rowHeight, CGFloat(outline.numberOfRows) * Self.rowHeight)
        if abs(heightConstraint.constant - height) > 0.5 {
            heightConstraint.constant = height
        }
        outline.enumerateAvailableRowViews { view, row in
            (view as? SettingsOutlineRowView)?.setAlternate(row % 2 == 1)
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = SettingsPalette.groupFill.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return groups.count }
        return (item as? SettingsOutlineItem)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else { return groups[index] }
        return (item as! SettingsOutlineItem).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SettingsOutlineItem)?.isGroup ?? false
    }

    // MARK: - Delegate

    func outlineView(
        _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
    ) -> NSView? {
        (item as? SettingsOutlineItem)?.cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        SettingsOutlineRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
        (rowView as? SettingsOutlineRowView)?.setAlternate(row % 2 == 1)
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { false }

    func outlineViewItemDidExpand(_ notification: Notification) { updateHeight() }

    func outlineViewItemDidCollapse(_ notification: Notification) { updateHeight() }
}
