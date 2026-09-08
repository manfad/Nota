import AppKit

/// What the reader chose in the export sheet: the shape, where the listing's
/// pictures go, and the file it is all going into.
struct ExportChoice: Equatable {
    let target: ExportTarget
    let images: ExportImagePlacement
    let destination: URL
}

/// Which half of the tab an export is taken from — the second of the two
/// questions the sheet asks about shape.
///
/// The first is what *file* comes out: PDF, PNG, EPUB. This one is what goes
/// into it: the source as the editor has it, the render as the preview shows
/// it, or — for a `.tex` — the page a real TeX engine sets. Together the two
/// answers name exactly one `ExportTarget`, which is why neither is a target
/// itself.
enum ExportViewChoice: String, CaseIterable {
    case editor, preview, tex

    /// The word the segment wears — also the `L10n` key it is looked up
    /// under, so the sheet and the tables can never drift apart.
    var titleKey: String {
        switch self {
        case .editor: "Editor"
        case .preview: "Preview"
        case .tex: "TeX"
        }
    }

    var title: String { L10n.text(titleKey) }

    /// The half of the tab a target is taken from. A book on pages and a
    /// document taken apart into a book are both the reader's own view of the
    /// tab, the same as a render is — and both are the only thing their tab
    /// offers, so neither is ever a segment anybody has to read.
    static func of(_ target: ExportTarget) -> ExportViewChoice {
        switch target {
        case .editorPDF, .editorPNG: .editor
        case .previewPDF, .bookPDF, .epub, .previewPNG: .preview
        case .texPDF: .tex
        }
    }
}

/// Nota's own Export sheet — the whole question, asked once (SPEC Done 62).
///
/// The same small form `SaveDialog` is (SPEC Done 51): labels right-aligned
/// into one column, controls in another, two buttons under them, run
/// synchronously so the window's export reads as one straight line of code.
/// It asks five things, and often three:
///
///     Export as  [ PDF | PNG ]
///     View       [ Editor | Preview ]
///     Image      ( ) Inline  ( ) End
///     Save As:   [ notes             ] .pdf
///     Location:  [ 📁 Examples       ] [Choose…]
///
/// The shape is two questions rather than one popup of seven answers. The
/// first is the *file*: the distinct extensions this tab's targets write, in
/// `Exporter.targets(for:)`'s order, each segment wearing its own extension
/// in capitals. The second is which half of the tab it is taken from —
/// Editor, Preview, or, for a `.tex`, the page TeX itself sets. The two
/// together resolve to one `ExportTarget`, and where they cannot ask anything
/// worth asking the second row goes quiet: a PNG is always the source Nota
/// can lay out (the editor's, where the tab offers one), and an extension
/// with a single view — EPUB, a book's pages, a picture, a rich-text document
/// — has nothing to choose between. Changing the file keeps the view where
/// the new file still offers it.
///
/// There is no Format popup: the target *is* the format, so the extension
/// after the name field is a label the reader reads rather than a control
/// they answer. It follows the target — `.pdf`, `.epub` — and so does the
/// name, which opens on the target's own default (`notes.pdf` for a Markdown
/// note, `Demo.epub` for a document taken apart into a book) and keeps
/// following it until the reader types something of their own.
///
/// The Image row is for the two exports that lay a note's own pictures out
/// themselves: the source listing, always, and the render, when the note has
/// chips for it to place. Inline is where they were written; End gathers them
/// onto plates after the text with a `[n] name` tag left behind on the line.
/// The choice is remembered in `Preferences.exportEditorImages`, so the next
/// export opens on whichever way the reader liked last.
///
/// The panel is sized once, when it is built, and never again: a row that has
/// nothing to ask hides its controls but keeps its place, so the sheet is the
/// same sheet whichever way the reader turns it.
///
/// The `Location:` row is `SaveDialog`'s own, shared as `LocationRow`, and the
/// "already exists, replace?" question is the window's `confirmReplace` — the
/// dialog puts no alert up itself, and a "no" leaves it standing.
///
/// Nothing here paints a colour of its own, so the sheet follows the app's
/// appearance; every string goes through `L10n`, and `Preferences.didChange`
/// relabels it where it stands.
@MainActor
final class ExportDialog: NSObject, NSTextFieldDelegate {
    // MARK: - Metrics

    private static let contentWidth: CGFloat = 460
    private static let inset: CGFloat = 20
    private static let rowSpacing: CGFloat = 12
    /// The two rows that come and go, by their place in the grid.
    private static let viewRow = 1
    private static let imagesRow = 2

    // MARK: - Chrome

    let panel: NSPanel
    let headingLabel = NSTextField(labelWithString: "")
    let exportLabel = NSTextField(labelWithString: "")
    let viewLabel = NSTextField(labelWithString: "")
    let imagesLabel = NSTextField(labelWithString: "")
    let saveAsLabel = NSTextField(labelWithString: "")
    let locationLabel = NSTextField(labelWithString: "")
    /// What file comes out: one segment per extension the tab can write.
    let formatSegments = NSSegmentedControl()
    /// Which half of the tab it is taken from, under the chosen extension.
    let viewSegments = NSSegmentedControl()
    /// The Image row's two radios — one group, so answering one unanswers
    /// the other.
    let inlineButton = NSButton()
    let platesButton = NSButton()
    let nameField = NSTextField()
    /// The extension the file will land on, after the name field. A label,
    /// not a control: the target already said what this file is.
    let extensionLabel = NSTextField(labelWithString: "")
    /// The `Location:` row, shared with the Save dialog (`LocationRow`).
    private let location: LocationRow
    var locationField: NSTextField { location.field }
    var chooseButton: NSButton { location.chooseButton }
    let cancelButton = NSButton()
    let exportButton = NSButton()
    private let grid: NSGridView
    /// The two hideable rows' contents live in stacks that keep their size
    /// while their controls are hidden, so an empty row is still a row and
    /// the panel never has to grow or shrink around it.
    private let viewBox = NSStackView()
    private let imagesBox = NSStackView()

    // MARK: - State

    /// The targets the tab offers, in `Exporter.targets(for:)`'s order — the
    /// order the segments are derived in, first one selected.
    let targets: [ExportTarget]

    /// Whether the note has pictures of its own. The render only asks where
    /// its pictures go when it has some to place; the listing always does,
    /// since a listing with no chips has no Image row's worth of difference
    /// either way and the row is the listing's own.
    private let hasImageChips: Bool

    /// The distinct extensions the targets write, in first-seen order — the
    /// `Export as` segments, in capitals.
    private let extensions: [String]

    /// The view the reader last asked for, kept across a change of file so
    /// `PDF Editor` → `PNG` → `PDF` comes back to the editor.
    private var selectedView: ExportViewChoice

    /// What each target would call the file, as the window composes it
    /// (`MainWindowController.exportName(for:target:)`): the tab's own title
    /// under the target's extension, except a grid's CSV, which is the pane's
    /// own default. The base alone is put in the field.
    private let suggestedNames: [ExportTarget: String]

    /// True once the reader has typed in the name field: the name follows the
    /// target's default until then, and stands still afterwards.
    private var hasTypedName = false

    /// The folder the file is going into. `Choose…` replaces it.
    var locationURL: URL { location.url }

    /// Nota's own "already exists, replace?" alert, handed in by the window so
    /// the sheet puts no alert up itself (and a test can answer it).
    var confirmReplace: ((URL) -> Bool)?

    private var result: ExportChoice?
    private var isObserving = false

    // MARK: - What the two rows add up to

    /// The extension the `Export as` row stands on.
    private var selectedExtension: String {
        extensions.indices.contains(formatSegments.selectedSegment)
            ? extensions[formatSegments.selectedSegment]
            : extensions[0]
    }

    /// The targets written under `fileExtension`, in the tab's own order.
    private func offeredTargets(writing fileExtension: String) -> [ExportTarget] {
        targets.filter { $0.fileExtension == fileExtension }
    }

    /// The views offered under `fileExtension`, always Editor, Preview, TeX.
    private func views(under fileExtension: String) -> [ExportViewChoice] {
        let offered = offeredTargets(writing: fileExtension).map(ExportViewChoice.of)
        return ExportViewChoice.allCases.filter(offered.contains)
    }

    /// Whether the View row is a question at all. A picture is always taken
    /// of the source Nota can lay out — the reader asked for the note, not
    /// for a photograph of a view they are not looking at — and an extension
    /// with one view has nothing to choose between.
    private var isViewRowShown: Bool {
        selectedExtension != "png" && views(under: selectedExtension).count > 1
    }

    /// The one target the two rows resolve to.
    var chosenTarget: ExportTarget {
        let candidates = offeredTargets(writing: selectedExtension)
        guard let first = candidates.first else { return targets[0] }
        // A PNG always sources: the editor's own text where the tab lists
        // one, and the render only where there is nothing else to photograph.
        if selectedExtension == "png" {
            return candidates.contains(.editorPNG) ? .editorPNG : first
        }
        return candidates.first { ExportViewChoice.of($0) == selectedView } ?? first
    }

    var chosenImages: ExportImagePlacement {
        inlineButton.state == .on ? .inline : .plates
    }

    /// What Export would write: the name field under the target's own
    /// extension, in the folder the Location row stands on.
    var composedURL: URL {
        location.url.appendingPathComponent(SaveNameComposer.composedName(
            name: nameField.stringValue, pinnedExtension: chosenTarget.fileExtension
        ))
    }

    /// Whether the Image row is in the form — for the tests, and for the
    /// layout, which is the same question.
    var isImagesRowShown: Bool { !inlineButton.isHidden }

    /// Whether the pictures are a question for what is being written: the
    /// listing lays them out itself, and so does the render when the note
    /// has any.
    private var imagesRowApplies: Bool {
        switch chosenTarget {
        case .editorPDF: true
        case .previewPDF: hasImageChips
        default: false
        }
    }

    /// Picking a target, as two clicks on the segments would: the file first,
    /// then the half of the tab it comes from. A target the two rows cannot
    /// resolve to — `.previewPNG` on a tab that also lists an editor — lands
    /// on its extension and takes that row's own answer, which is what a
    /// reader clicking the same segments would get.
    func choose(_ target: ExportTarget) {
        guard targets.contains(target),
              let index = extensions.firstIndex(of: target.fileExtension) else { return }
        formatSegments.selectedSegment = index
        let offered = views(under: target.fileExtension)
        let view = ExportViewChoice.of(target)
        if offered.contains(view) {
            selectedView = view
        } else if let first = offered.first {
            selectedView = first
        }
        selectionChanged()
    }

    func choose(_ images: ExportImagePlacement) {
        inlineButton.state = images == .inline ? .on : .off
        platesButton.state = images == .plates ? .on : .off
    }

    /// Sending the sheet to another folder, as `Choose…` would.
    func choose(_ folder: URL) { location.choose(folder) }

    /// Typing in the name field, as the reader would: the name stops
    /// following the target from here on.
    func type(name: String) {
        nameField.stringValue = name
        nameTyped()
    }

    // MARK: - Building

    /// - Parameters:
    ///   - targets: what the tab offers, in `Exporter.targets(for:)`'s order.
    ///   - images: `Preferences.exportEditorImages`, the way the last listing
    ///     put its pictures.
    ///   - suggestedNames: what each target would call the file.
    ///   - existingFileURL: the note's own file, whose folder the sheet opens
    ///     in when it has one.
    ///   - lastDirectory: `Preferences.lastExportDirectory`, where a note with
    ///     no file of its own opens. Never the *save* directory: an export is
    ///     not a save, and neither one may move the other.
    ///   - hasImageChips: whether the note has pictures in it, which is the
    ///     one thing that makes the Image row worth asking for a render.
    init(
        targets: [ExportTarget],
        images: ExportImagePlacement,
        suggestedNames: [ExportTarget: String] = [:],
        existingFileURL: URL? = nil,
        lastDirectory: URL? = nil,
        hasImageChips: Bool = false
    ) {
        let offered = targets.isEmpty ? [.editorPDF] : targets
        self.targets = offered
        self.hasImageChips = hasImageChips
        self.suggestedNames = suggestedNames
        var seen: [String] = []
        for target in offered where !seen.contains(target.fileExtension) {
            seen.append(target.fileExtension)
        }
        extensions = seen
        selectedView = ExportViewChoice.of(offered[0])
        location = LocationRow(url: LocationRow.openingURL(
            existingFileURL: existingFileURL, lastDirectory: lastDirectory
        ))

        grid = NSGridView(numberOfColumns: 2, rows: 0)
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 200),
            styleMask: [.titled, .docModalWindow],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        buildUI()

        formatSegments.segmentCount = extensions.count
        for (index, fileExtension) in extensions.enumerated() {
            formatSegments.setLabel(fileExtension.uppercased(), forSegment: index)
        }
        formatSegments.selectedSegment = 0
        choose(images)
        relabel()
        pinRowHeights()
        selectionChanged()
        // Once, and only once: the sheet the reader opens is the sheet they
        // close, whichever rows it turns out to need.
        fit()

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

        for segments in [formatSegments, viewSegments] {
            segments.trackingMode = .selectOne
            segments.segmentDistribution = .fillEqually
            segments.target = self
            segments.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        formatSegments.action = #selector(formatPicked)
        viewSegments.action = #selector(viewPicked)
        // A segmented control has to hold at least one segment to have a
        // height to measure; the labels come with the selection.
        viewSegments.segmentCount = 1

        // Two radios in one view sharing one action are one group: answering
        // either unanswers the other, without a box around them.
        for radio in [inlineButton, platesButton] {
            radio.setButtonType(.radio)
            radio.target = self
            radio.action = #selector(imagesPicked)
        }

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

        exportButton.bezelStyle = .rounded
        exportButton.target = self
        exportButton.action = #selector(exportClicked)
        exportButton.keyEquivalent = "\r"

        // The two rows that come and go keep their own boxes, and the boxes
        // keep their hidden contents' place: a stack that let go of them
        // would collapse, and a grid row with nothing visible in it collapses
        // with it.
        for box in [viewBox, imagesBox] {
            box.orientation = .horizontal
            box.detachesHiddenViews = false
        }
        viewBox.addArrangedSubview(viewSegments)
        viewBox.spacing = 0
        // `.fill`, so the segments take the whole control column rather than
        // hugging their own words.
        viewBox.distribution = .fill
        imagesBox.addArrangedSubview(inlineButton)
        imagesBox.addArrangedSubview(platesButton)
        imagesBox.spacing = 16

        // The name and its extension are one thing — the file's name — so
        // they share the row, the way the Save dialog's name and its Format
        // popup do.
        let nameRow = NSStackView(views: [nameField, extensionLabel])
        nameRow.orientation = .horizontal
        nameRow.spacing = 6
        nameRow.distribution = .fill

        grid.addRow(with: [exportLabel, formatSegments])
        grid.addRow(with: [viewLabel, viewBox])
        grid.addRow(with: [imagesLabel, imagesBox])
        grid.addRow(with: [saveAsLabel, nameRow])
        grid.addRow(with: [locationLabel, location.view])
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
            formatSegments.trailingAnchor.constraint(
                equalTo: content.trailingAnchor, constant: -Self.inset
            ),
            viewBox.trailingAnchor.constraint(
                equalTo: content.trailingAnchor, constant: -Self.inset
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

    /// The two rows that come and go are nailed to the height they have while
    /// they are being asked, so hiding their controls empties them without
    /// taking their place away — and the panel, sized once, still fits.
    private func pinRowHeights() {
        grid.row(at: Self.viewRow).height = viewSegments.fittingSize.height
        grid.row(at: Self.imagesRow).height = max(
            inlineButton.fittingSize.height, platesButton.fittingSize.height
        )
    }

    // MARK: - Language

    @objc private func preferencesChanged() { relabel() }

    private func relabel() {
        let title = L10n.text("Export", chinese: "导出")
        panel.title = title
        headingLabel.stringValue = title
        exportLabel.stringValue = L10n.text("Export as")
        viewLabel.stringValue = L10n.text("View")
        imagesLabel.stringValue = L10n.text("Image")
        saveAsLabel.stringValue = L10n.text("Save As", chinese: "另存为") + ":"
        locationLabel.stringValue = L10n.text("Location", chinese: "位置") + ":"
        location.relabel()
        cancelButton.title = L10n.text("Cancel", chinese: "取消")
        exportButton.title = title
        inlineButton.title = ExportImagePlacement.inline.title
        platesButton.title = ExportImagePlacement.plates.title
        applyViewSegments()
        // The label column is exactly as wide as its widest word: a column
        // left to size itself is handed a share of the grid's spare width
        // too, and the controls would lose it.
        grid.column(at: 0).width = [
            exportLabel, viewLabel, imagesLabel, saveAsLabel, locationLabel,
        ].map { $0.fittingSize.width }.max() ?? 0
    }

    /// The View row's segments for whatever `Export as` stands on, with the
    /// reader's own view still selected where the new file offers it.
    private func applyViewSegments() {
        let offered = views(under: selectedExtension)
        guard !offered.isEmpty else { return }
        viewSegments.segmentCount = offered.count
        for (index, view) in offered.enumerated() {
            viewSegments.setLabel(view.title, forSegment: index)
        }
        viewSegments.selectedSegment = offered.firstIndex(of: selectedView) ?? 0
    }

    // MARK: - The two rows of shape

    /// A new file to write. The view stays where the reader put it wherever
    /// the new file still offers it, and falls to the first one where it
    /// does not.
    @objc private func formatPicked() {
        let offered = views(under: selectedExtension)
        if !offered.contains(selectedView), let first = offered.first {
            selectedView = first
        }
        selectionChanged()
    }

    @objc private func viewPicked() {
        let offered = views(under: selectedExtension)
        if offered.indices.contains(viewSegments.selectedSegment) {
            selectedView = offered[viewSegments.selectedSegment]
        }
        selectionChanged()
    }

    @objc private func imagesPicked() {}

    /// Everything that follows the shape: which of the two questions are
    /// still worth asking, the extension after the name, and the name itself
    /// until the reader has typed one.
    private func selectionChanged() {
        applyViewSegments()

        let showsView = isViewRowShown
        viewLabel.isHidden = !showsView
        viewSegments.isHidden = !showsView

        let showsImages = imagesRowApplies
        imagesLabel.isHidden = !showsImages
        inlineButton.isHidden = !showsImages
        platesButton.isHidden = !showsImages

        extensionLabel.stringValue = "." + chosenTarget.fileExtension
        if !hasTypedName { nameField.stringValue = defaultBaseName(for: chosenTarget) }
        updateExportEnabled()
    }

    /// The base of what the window would call this file, or the tab's own
    /// name where nothing was handed in.
    private func defaultBaseName(for target: ExportTarget) -> String {
        guard let name = suggestedNames[target] else { return "" }
        return SaveNameComposer.split(name: name).base
    }

    private func fit() {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        panel.setContentSize(content.fittingSize)
    }

    // MARK: - The name

    func controlTextDidChange(_ notification: Notification) { nameTyped() }

    private func nameTyped() {
        hasTypedName = true
        updateExportEnabled()
    }

    /// Export with nothing typed would write a file called `.pdf`; the button
    /// is simply not available until there is a name.
    private func updateExportEnabled() {
        exportButton.isEnabled = !nameField.stringValue
            .trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Running

    /// Puts the sheet up on `parent` and stays there until Export or Cancel:
    /// what was chosen, or `nil`.
    @discardableResult
    func runSheet(on parent: NSWindow) -> ExportChoice? {
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

    /// The Export the button and Return both mean, exposed so a test can take
    /// it without a modal session: what was chosen and where it is going,
    /// unless the file is already there and the window's own alert says no,
    /// in which case the sheet stays where it is and answers `nil`.
    @discardableResult
    func export() -> ExportChoice? {
        guard exportButton.isEnabled else { return nil }
        let url = composedURL
        if FileManager.default.fileExists(atPath: url.path),
           confirmReplace?(url) != true {
            return nil
        }
        let choice = ExportChoice(
            target: chosenTarget, images: chosenImages, destination: url
        )
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
