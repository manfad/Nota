import AppKit

/// What the reader chose in the export sheet.
struct ExportChoice: Equatable {
    let target: ExportTarget
    let images: ExportImagePlacement
}

/// Nota's own Export sheet — the question before the Save dialog.
///
/// The same small form `SaveDialog` is (SPEC Done 51): labels right-aligned
/// into one column, controls in another, two buttons under them, run
/// synchronously so the window's export reads as one straight line of code.
/// What it asks is one thing, and sometimes two:
///
///     Export:  [ Preview as PDF  ⌄ ]
///     Images:  [ Plates at the end ⌄ ]
///
/// The Images row belongs to the listing alone — a render puts its pictures
/// where the render puts them — so it is in the form only while `Editor as
/// PDF` is selected, and the sheet grows and shrinks around it. The choice is
/// remembered in `Preferences.exportEditorImages`, so the next export opens on
/// whichever way the reader liked last.
///
/// Nothing here paints a colour of its own, so the sheet follows the app's
/// appearance; every string goes through `L10n`, and `Preferences.didChange`
/// relabels it where it stands.
@MainActor
final class ExportDialog: NSObject {
    // MARK: - Metrics

    private static let contentWidth: CGFloat = 380
    private static let inset: CGFloat = 20
    private static let rowSpacing: CGFloat = 12

    // MARK: - Chrome

    let panel: NSPanel
    let headingLabel = NSTextField(labelWithString: "")
    let exportLabel = NSTextField(labelWithString: "")
    let imagesLabel = NSTextField(labelWithString: "")
    let targetPopUp = NSPopUpButton()
    let imagesPopUp = NSPopUpButton()
    let cancelButton = NSButton()
    let exportButton = NSButton()
    private let grid: NSGridView

    // MARK: - State

    /// The targets the tab offers, in the order the popup lists them —
    /// `Exporter.targets(for:)`'s order, first one selected.
    let targets: [ExportTarget]
    private var result: ExportChoice?
    private var isObserving = false

    var chosenTarget: ExportTarget {
        targets.indices.contains(targetPopUp.indexOfSelectedItem)
            ? targets[targetPopUp.indexOfSelectedItem]
            : targets[0]
    }

    var chosenImages: ExportImagePlacement {
        ExportImagePlacement.allCases.indices.contains(imagesPopUp.indexOfSelectedItem)
            ? ExportImagePlacement.allCases[imagesPopUp.indexOfSelectedItem]
            : .inline
    }

    /// Whether the Images row is in the form — for the tests, and for the
    /// layout, which is the same question.
    var isImagesRowShown: Bool { !imagesPopUp.isHidden }

    /// Picking a target, as a click on the popup would. Exposed so a test
    /// can walk the sheet without a mouse.
    func choose(_ target: ExportTarget) {
        guard let index = targets.firstIndex(of: target) else { return }
        targetPopUp.selectItem(at: index)
        targetChanged()
    }

    func choose(_ images: ExportImagePlacement) {
        guard let index = ExportImagePlacement.allCases.firstIndex(of: images) else { return }
        imagesPopUp.selectItem(at: index)
    }

    // MARK: - Building

    init(targets: [ExportTarget], images: ExportImagePlacement) {
        self.targets = targets.isEmpty ? [.editorPDF] : targets

        grid = NSGridView(numberOfColumns: 2, rows: 0)
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 160),
            styleMask: [.titled, .docModalWindow],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        buildUI()

        targetPopUp.addItems(withTitles: self.targets.map(\.title))
        targetPopUp.selectItem(at: 0)
        imagesPopUp.addItems(withTitles: ExportImagePlacement.allCases.map(\.title))
        choose(images)
        targetChanged()
        relabel()

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

        for popUp in [targetPopUp, imagesPopUp] {
            popUp.pullsDown = false
            popUp.target = self
        }
        targetPopUp.action = #selector(targetPicked)

        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.keyEquivalent = "\u{1b}"

        exportButton.bezelStyle = .rounded
        exportButton.target = self
        exportButton.action = #selector(exportClicked)
        exportButton.keyEquivalent = "\r"

        grid.addRow(with: [exportLabel, targetPopUp])
        grid.addRow(with: [imagesLabel, imagesPopUp])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.rowSpacing = Self.rowSpacing
        grid.columnSpacing = 8
        for index in 0..<grid.numberOfRows { grid.row(at: index).yPlacement = .center }

        let buttons = NSStackView(views: [cancelButton, exportButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false

        headingLabel.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(headingLabel)
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

            grid.topAnchor.constraint(equalTo: headingLabel.bottomAnchor, constant: 18),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.inset),
            // The controls, not the grid, reach the trailing inset: a grid
            // pinned on both sides hands its spare width to both columns
            // alike, and the label column would grow with it.
            grid.trailingAnchor.constraint(
                lessThanOrEqualTo: content.trailingAnchor, constant: -Self.inset
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

    private func relabel() {
        let title = L10n.text("Export", chinese: "导出")
        panel.title = title
        headingLabel.stringValue = title
        exportLabel.stringValue = title + ":"
        imagesLabel.stringValue = L10n.text("Images") + ":"
        cancelButton.title = L10n.text("Cancel", chinese: "取消")
        exportButton.title = title
        for (index, target) in targets.enumerated() {
            targetPopUp.item(at: index)?.title = target.title
        }
        for (index, placement) in ExportImagePlacement.allCases.enumerated() {
            imagesPopUp.item(at: index)?.title = placement.title
        }
        // The label column is exactly as wide as its widest word: a column
        // left to size itself is handed a share of the grid's spare width
        // too, and the controls would lose it.
        grid.column(at: 0).width = [exportLabel, imagesLabel]
            .map { $0.fittingSize.width }.max() ?? 0
        fit()
    }

    // MARK: - The Images row

    @objc private func targetPicked() { targetChanged() }

    /// The listing is the only export the pictures are a question for.
    private func targetChanged() {
        let listing = chosenTarget == .editorPDF
        imagesLabel.isHidden = !listing
        imagesPopUp.isHidden = !listing
        grid.row(at: 1).isHidden = !listing
        fit()
    }

    private func fit() {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        panel.setContentSize(content.fittingSize)
    }

    // MARK: - Running

    /// Puts the sheet up on `parent` and stays there until Export or Cancel:
    /// what was chosen, or `nil`.
    @discardableResult
    func runSheet(on parent: NSWindow) -> ExportChoice? {
        result = nil
        parent.beginSheet(panel) { _ in }
        panel.makeFirstResponder(targetPopUp)
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

    /// The Export the button and Return both mean, exposed so a test can take
    /// it without a modal session.
    @discardableResult
    func export() -> ExportChoice {
        let choice = ExportChoice(target: chosenTarget, images: chosenImages)
        result = choice
        finish()
        return choice
    }

    func cancel() {
        result = nil
        finish()
    }

    @objc private func exportClicked() { export() }

    @objc private func cancelClicked() { cancel() }

    private func finish() {
        guard NSApp.modalWindow === panel else { return }
        NSApp.stopModal()
    }
}
