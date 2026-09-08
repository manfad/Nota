import AppKit

/// What the reader chose in the CSV export dialog: which of the grid's
/// columns are going out, and the file they are going into.
struct CSVExportChoice: Equatable {
    let url: URL
    /// The ticked columns as indices into the grid's own header, in grid
    /// order. Never empty — Save is not available with nothing ticked.
    let columns: [Int]
}

/// Nota's own Export CSV sheet — the one the `Export CSV` button on a `.sql`
/// or `.csv` grid puts up.
///
/// It is its own dialog rather than `SaveDialog` because of the one row a
/// save has no place for: the list of the grid's columns, ticked or not. A
/// save writes the document it is given; this writes a table the reader is
/// choosing the shape of on the way out, and that question belongs above the
/// name rather than bolted beside it:
///
///     Export with
///     ┌──────────────────────────────┐
///     │ ☑ id                 INTEGER │
///     │ ☑ name                  TEXT │
///     │ ☑ city                  TEXT │
///     └──────────────────────────────┘
///      Save As:  [ customers    ] [ csv ⌄ ]
///     Location:  [ 📁 Examples  ] [Choose…]
///
/// Everything below the list is the shape `SaveDialog` (SPEC Done 51) and
/// `ExportDialog` (Done 62) already stand in — labels right-aligned into one
/// column, controls in another, Cancel and a default Save under them, run
/// synchronously through `runSheet(on:)` so the pane's export reads as one
/// straight line of code. The Format popup carries the one word `csv` and is
/// not a control: a grid's Export button writes a CSV and nothing else, but
/// the row reads like every other save row in Nota rather than losing its
/// second half.
///
/// The list is drawn in the Settings › File types shape — the same card fill,
/// the same banding, the same 34pt rows (`SettingsPalette`,
/// `SettingsOutlineView.rowHeight`) — and every row's tick box belongs to the
/// dialog rather than to the cell the table lends it, so a column that has
/// never been scrolled into view can still be read and written. Past eight
/// rows the list scrolls instead of growing: a forty-column table must not
/// make a sheet taller than the screen.
///
/// The `Location:` row is the shared `LocationRow`, opening on the note's own
/// folder and falling back to `Preferences.lastExportDirectory` — an export
/// is not a save, and neither one may move the other. The "already exists,
/// replace?" question is the window's `confirmReplace`, so the sheet puts no
/// alert up itself and a "no" leaves it standing.
///
/// Nothing here paints a colour of its own, so the sheet follows the app's
/// appearance; every string goes through `L10n`, and `Preferences.didChange`
/// relabels it where it stands.
@MainActor
final class CSVExportDialog: NSObject, NSTextFieldDelegate {
    // MARK: - Metrics

    private static let contentWidth: CGFloat = 460
    private static let inset: CGFloat = 20
    private static let rowSpacing: CGFloat = 12

    /// How much of the list is on screen at once. A table of forty columns
    /// scrolls; one of three is exactly three rows tall.
    static let maximumVisibleColumns = 8

    // MARK: - Chrome

    let panel: NSPanel
    let headingLabel = NSTextField(labelWithString: "")
    /// The caption over the list, the way a Settings card is captioned.
    let columnsCaption = NSTextField(labelWithString: "")
    let columnList: CSVExportColumnListView
    let saveAsLabel = NSTextField(labelWithString: "")
    let locationLabel = NSTextField(labelWithString: "")
    let nameField = NSTextField()
    /// The extension the file will land on, after the name field: `.csv`,
    /// a muted label the reader reads rather than a control they answer,
    /// the same as the Export sheet's.
    let extensionLabel = NSTextField(labelWithString: ".csv")
    /// The `Location:` row, shared with the Save dialog and the Export sheet.
    private let location: LocationRow
    var locationField: NSTextField { location.field }
    var chooseButton: NSButton { location.chooseButton }
    let cancelButton = NSButton()
    let saveButton = NSButton()
    private let grid: NSGridView

    // MARK: - State

    /// The grid's header as it was handed in, in grid order.
    let columns: [(name: String, type: String?)]

    /// The folder the file is going into. `Choose…` replaces it.
    var locationURL: URL { location.url }

    /// Nota's own "already exists, replace?" alert, handed in by the window so
    /// the sheet puts no alert up itself (and a test can answer it).
    var confirmReplace: ((URL) -> Bool)?

    private var result: CSVExportChoice?
    private var isObserving = false

    /// Which columns are ticked, in grid order.
    var chosenColumns: [Int] { columnList.tickedColumns }

    /// What Save would write: the name field under the pinned `csv`, in the
    /// folder the Location row stands on.
    var composedURL: URL {
        location.url.appendingPathComponent(SaveNameComposer.composedName(
            name: nameField.stringValue, pinnedExtension: "csv"
        ))
    }

    /// Ticking one column, as a click on its box would. Exposed so a test can
    /// walk the sheet without a mouse.
    func setColumn(_ index: Int, ticked: Bool) {
        columnList.setColumn(index, ticked: ticked)
        updateSaveEnabled()
    }

    /// Sending the sheet to another folder, as `Choose…` would.
    func choose(_ folder: URL) { location.choose(folder) }

    /// Typing in the name field, as the reader would.
    func type(name: String) {
        nameField.stringValue = name
        updateSaveEnabled()
    }

    // MARK: - Building

    /// - Parameters:
    ///   - columns: the grid's own header, in grid order — a name each, and
    ///     the declared type where the column has one (a `.csv`'s columns and
    ///     a query's expressions have none).
    ///   - suggestedName: what the pane would call the file, extension and
    ///     all; the base alone goes in the field.
    ///   - existingFileURL: the note's own file, whose folder the sheet opens
    ///     in when it has one.
    ///   - lastDirectory: `Preferences.lastExportDirectory`, where a note with
    ///     no file of its own opens. Never the *save* directory.
    init(
        columns: [(name: String, type: String?)],
        suggestedName: String,
        existingFileURL: URL?,
        lastDirectory: URL?
    ) {
        self.columns = columns
        columnList = CSVExportColumnListView(columns: columns)
        location = LocationRow(url: LocationRow.openingURL(
            existingFileURL: existingFileURL, lastDirectory: lastDirectory
        ))

        grid = NSGridView(numberOfColumns: 2, rows: 0)
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 260),
            styleMask: [.titled, .docModalWindow],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        buildUI()

        nameField.stringValue = SaveNameComposer.split(name: suggestedName).base
        columnList.onToggle = { [weak self] in self?.updateSaveEnabled() }
        relabel()
        updateSaveEnabled()

        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: Preferences.didChange, object: nil
        )
        isObserving = true
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func buildUI() {
        headingLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        headingLabel.alignment = .center

        columnsCaption.font = .systemFont(ofSize: 12, weight: .semibold)
        columnsCaption.textColor = .secondaryLabelColor

        nameField.isEditable = true
        nameField.isBezeled = true
        nameField.bezelStyle = .roundedBezel
        nameField.delegate = self
        nameField.usesSingleLineMode = true
        nameField.cell?.wraps = false
        nameField.cell?.isScrollable = true
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        extensionLabel.textColor = .secondaryLabelColor
        extensionLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        extensionLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.keyEquivalent = "\u{1b}"

        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        saveButton.keyEquivalent = "\r"

        // The name and its extension are one thing — the file's name — so
        // they share the row, the way the Export sheet's do.
        let nameRow = NSStackView(views: [nameField, extensionLabel])
        nameRow.orientation = .horizontal
        nameRow.spacing = 6
        nameRow.distribution = .fill

        grid.addRow(with: [saveAsLabel, nameRow])
        grid.addRow(with: [locationLabel, location.view])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.rowSpacing = Self.rowSpacing
        grid.columnSpacing = 8
        for index in 0..<grid.numberOfRows { grid.row(at: index).yPlacement = .center }

        let buttons = NSStackView(views: [cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false

        headingLabel.translatesAutoresizingMaskIntoConstraints = false
        columnsCaption.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(headingLabel)
        content.addSubview(columnsCaption)
        content.addSubview(columnList)
        content.addSubview(grid)
        content.addSubview(buttons)
        panel.contentView = content

        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: Self.contentWidth),

            headingLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.inset),
            headingLabel.leadingAnchor.constraint(
                equalTo: content.leadingAnchor, constant: Self.inset
            ),
            headingLabel.trailingAnchor.constraint(
                equalTo: content.trailingAnchor, constant: -Self.inset
            ),

            columnsCaption.topAnchor.constraint(
                equalTo: headingLabel.bottomAnchor, constant: 18
            ),
            columnsCaption.leadingAnchor.constraint(
                equalTo: content.leadingAnchor, constant: Self.inset
            ),
            columnsCaption.trailingAnchor.constraint(
                equalTo: content.trailingAnchor, constant: -Self.inset
            ),

            columnList.topAnchor.constraint(
                equalTo: columnsCaption.bottomAnchor, constant: 8
            ),
            columnList.leadingAnchor.constraint(
                equalTo: content.leadingAnchor, constant: Self.inset
            ),
            columnList.trailingAnchor.constraint(
                equalTo: content.trailingAnchor, constant: -Self.inset
            ),

            grid.topAnchor.constraint(equalTo: columnList.bottomAnchor, constant: 18),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.inset),
            // The controls, not the grid, reach the trailing inset: a grid
            // pinned on both sides hands its spare width to both columns
            // alike, and the label column would grow with it.
            grid.trailingAnchor.constraint(
                lessThanOrEqualTo: content.trailingAnchor, constant: -Self.inset
            ),
            nameRow.trailingAnchor.constraint(
                equalTo: content.trailingAnchor, constant: -Self.inset
            ),
            location.view.trailingAnchor.constraint(
                equalTo: content.trailingAnchor, constant: -Self.inset
            ),

            buttons.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 20),
            buttons.trailingAnchor.constraint(
                equalTo: content.trailingAnchor, constant: -Self.inset
            ),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.inset),
        ])
    }

    // MARK: - Language

    @objc private func preferencesChanged() { relabel() }

    /// Every word the sheet wears, asked again. Called on `Preferences`
    /// changing, so a language switched while it is open takes effect where
    /// it stands. The column names are the table's own and are never looked
    /// up: a column called `Save` is a column called `Save` in every
    /// language.
    private func relabel() {
        let title = L10n.text("Export CSV")
        panel.title = title
        headingLabel.stringValue = title
        columnsCaption.stringValue = L10n.text("Export with")
        saveAsLabel.stringValue = L10n.text("Save As", chinese: "另存为") + ":"
        locationLabel.stringValue = L10n.text("Location", chinese: "位置") + ":"
        location.relabel()
        cancelButton.title = L10n.text("Cancel", chinese: "取消")
        saveButton.title = L10n.text("Save")
        // The label column is exactly as wide as its widest word: a column
        // left to size itself is handed a share of the grid's spare width
        // too, and the controls would lose it.
        grid.column(at: 0).width = [saveAsLabel, locationLabel]
            .map { $0.fittingSize.width }.max() ?? 0
        fit()
    }

    private func fit() {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        panel.setContentSize(content.fittingSize)
    }

    // MARK: - Running

    /// Puts the sheet up on `parent` and stays there until Save or Cancel:
    /// what was chosen, or `nil`.
    @discardableResult
    func runSheet(on parent: NSWindow) -> CSVExportChoice? {
        result = nil
        parent.beginSheet(panel) { _ in }
        panel.makeFirstResponder(nameField)
        // The base name, whole and selected, so typing replaces it.
        nameField.selectText(nil)
        NSApp.runModal(for: panel)
        parent.endSheet(panel)
        panel.orderOut(nil)
        stopObserving()
        return result
    }

    private func stopObserving() {
        guard isObserving else { return }
        NotificationCenter.default.removeObserver(self, name: Preferences.didChange, object: nil)
        isObserving = false
    }

    // MARK: - Buttons

    func controlTextDidChange(_ notification: Notification) { updateSaveEnabled() }

    /// Save with nothing typed would write a file called `.csv`, and Save
    /// with nothing ticked would write a file of nothing at all. The button
    /// is simply not available until there is both a name and a column.
    private func updateSaveEnabled() {
        let hasName = !nameField.stringValue
            .trimmingCharacters(in: .whitespaces).isEmpty
        saveButton.isEnabled = hasName && !chosenColumns.isEmpty
    }

    /// The Save the button and Return both mean, exposed so a test can take
    /// it without a modal session: the ticked columns and where they are
    /// going, unless the file is already there and the window's own alert
    /// says no, in which case the sheet stays where it is and answers `nil`.
    ///
    /// An export always asks, even where the destination is the note's own
    /// file: unlike a save, this one may be writing three of the file's five
    /// columns back over it.
    @discardableResult
    func save() -> CSVExportChoice? {
        guard saveButton.isEnabled else { return nil }
        let url = composedURL
        if FileManager.default.fileExists(atPath: url.path),
           confirmReplace?(url) != true {
            return nil
        }
        let choice = CSVExportChoice(url: url, columns: chosenColumns)
        result = choice
        finish()
        return choice
    }

    func cancel() {
        result = nil
        finish()
    }

    @objc private func saveClicked() { save() }

    @objc private func cancelClicked() { cancel() }

    private func finish() {
        guard NSApp.modalWindow === panel else { return }
        NSApp.stopModal()
    }
}

/// The banded list of columns inside its rounded card — Settings › File
/// types' own shape (`SettingsPalette.groupFill`, `SettingsOutlineRowView`,
/// `SettingsOutlineView.rowHeight`) with the folding taken out, since a
/// column list has no groups to fold.
///
/// Every row's tick box and its two labels are built with the list rather
/// than with the cell, so a column forty rows down can be read and written
/// without ever having been scrolled to — the same reason the Settings
/// outline builds its cells up front.
final class CSVExportColumnListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    /// One row: the tick box, the column's name, and its declared type at the
    /// trailing edge where it has one.
    final class Row: NSObject {
        let name: String
        let type: String?
        let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        let nameField: SettingsOutlineLabel
        let typeField: SettingsOutlineLabel
        private(set) var cell: NSTableCellView!

        /// The box was clicked. The list hears it, so the dialog can grey Save
        /// out the moment the last column is unticked.
        var onToggle: (() -> Void)?

        init(name: String, type: String?) {
            self.name = name
            self.type = type
            nameField = SettingsOutlineLabel(text: name, font: .systemFont(ofSize: 13))
            typeField = SettingsOutlineLabel(
                text: type ?? "", font: .systemFont(ofSize: 13)
            )
            super.init()
            typeField.textColor = .secondaryLabelColor
            checkbox.state = .on
            checkbox.setAccessibilityLabel(name)
            checkbox.target = self
            checkbox.action = #selector(checkboxClicked)
            cell = buildCell()
        }

        var isTicked: Bool { checkbox.state == .on }

        @objc private func checkboxClicked() { onToggle?() }

        private func buildCell() -> NSTableCellView {
            let cell = NSTableCellView(frame: NSRect(
                x: 0, y: 0, width: 420, height: SettingsOutlineView.rowHeight
            ))
            for view in [checkbox, nameField, typeField] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(view)
            }
            checkbox.setContentHuggingPriority(.required, for: .horizontal)
            nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            typeField.setContentHuggingPriority(.required, for: .horizontal)
            typeField.setContentCompressionResistancePriority(.required, for: .horizontal)

            NSLayoutConstraint.activate([
                checkbox.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                checkbox.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                nameField.leadingAnchor.constraint(
                    equalTo: checkbox.trailingAnchor, constant: 6
                ),
                nameField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                typeField.trailingAnchor.constraint(
                    equalTo: cell.trailingAnchor, constant: -12
                ),
                typeField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                typeField.leadingAnchor.constraint(
                    greaterThanOrEqualTo: nameField.trailingAnchor, constant: 12
                ),
            ])
            return cell
        }
    }

    let rows: [Row]
    private let table = NSTableView()
    private let scroll = NSScrollView()

    /// A box was clicked, whichever one.
    var onToggle: (() -> Void)?

    /// The ticked columns, in the order they were handed in.
    var tickedColumns: [Int] {
        rows.enumerated().compactMap { $1.isTicked ? $0 : nil }
    }

    init(columns: [(name: String, type: String?)]) {
        rows = columns.map { Row(name: $0.name, type: $0.type) }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        for row in rows {
            row.onToggle = { [weak self] in self?.onToggle?() }
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("column"))
        column.minWidth = 80
        column.maxWidth = 10_000
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = SettingsOutlineView.rowHeight
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.usesAlternatingRowBackgroundColors = false
        table.dataSource = self
        table.delegate = self

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = table
        // Past the eighth row the list scrolls rather than growing, so a
        // forty-column table cannot make the sheet taller than the screen.
        scroll.hasVerticalScroller = rows.count > CSVExportDialog.maximumVisibleColumns
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.horizontalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false
        addSubview(scroll)

        let visible = min(max(rows.count, 1), CSVExportDialog.maximumVisibleColumns)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(
                equalToConstant: CGFloat(visible) * SettingsOutlineView.rowHeight
            ),
        ])

        table.reloadData()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Ticking one row from outside, as a click on its box would.
    func setColumn(_ index: Int, ticked: Bool) {
        guard rows.indices.contains(index) else { return }
        rows[index].checkbox.state = ticked ? .on : .off
    }

    override func layout() {
        super.layout()
        if let column = table.tableColumns.first, abs(column.width - bounds.width) > 0.5 {
            column.width = bounds.width
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

    // MARK: - Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        rows[row].cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SettingsOutlineRowView()
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        (rowView as? SettingsOutlineRowView)?.setAlternate(row % 2 == 1)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}
