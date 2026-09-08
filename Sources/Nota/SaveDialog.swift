import AppKit

/// Nota's own Save dialog, in place of `NSSavePanel`.
///
/// The system panel gives an app one accessory view and centres it under a
/// file browser nobody asked for, so the Format row could only ever be
/// bolted on below "Where:", lined up with the system's own form by measured
/// offsets from the panel's centre (SPEC Done 51, which replaces all of it).
/// Nota already knows where a file is going: the
/// note's own folder, or the last one saved into. So the dialog is a small
/// sheet in the shape of the macOS save form and nothing more — two rows
/// over two buttons:
///
///     Save As:  [ Nota — todo        ] [ md  ⌄ ]
///    Location:  [ 📁 Examples         ] [Choose…]
///
/// The labels are right-aligned into one column and the fields start in
/// another (`NSGridView` holds both), the way the system form stands. The
/// location is read only — `Choose…` opens the system's folder picker as a
/// sheet on this one, which is the one thing a hand-built form has no
/// business reimplementing.
///
/// It is run synchronously: `runSheet(on:)` puts it up with `beginSheet` and
/// pumps `NSApp.runModal(for:)` until Save or Cancel stops it, so
/// `MainWindowController.presentSavePanel(for:)` still hands back a `URL?`
/// and every caller of `save(note:forcePanel:)` is untouched.
///
/// The name field carries the base name only; the extension lives in the
/// Format popup, and `SaveNameComposer` — unchanged, still the pure logic —
/// puts the two back together, a name that spells its own extension winning
/// over the popup.
///
/// Nothing here paints a colour of its own, so the sheet follows the app's
/// appearance; every string goes through `L10n`, and `Preferences.didChange`
/// relabels the dialog where it stands, so a language changed while it is
/// open takes effect at once.
@MainActor
final class SaveDialog: NSObject, NSTextFieldDelegate {
    // MARK: - Metrics

    private static let contentWidth: CGFloat = 460
    private static let inset: CGFloat = 20
    private static let rowSpacing: CGFloat = 12
    private static let formatWidth: CGFloat = 96

    // MARK: - Chrome

    let panel: NSPanel
    let headingLabel = NSTextField(labelWithString: "")
    let saveAsLabel = NSTextField(labelWithString: "")
    let locationLabel = NSTextField(labelWithString: "")
    let nameField = NSTextField()
    let formatPopUp = NSPopUpButton()
    /// The extension typed by hand once the popup is on `Other…` — the one
    /// way to a format the list does not carry, or a `.txt` spelled some other
    /// way. Hidden until then, and hidden again when a listed one is picked.
    let otherExtensionField = NSTextField()
    /// The `Location:` row, shared with the Export sheet (`LocationRow`).
    private let location: LocationRow
    var locationField: NSTextField { location.field }
    var chooseButton: NSButton { location.chooseButton }
    let cancelButton = NSButton()
    let saveButton = NSButton()
    private let grid: NSGridView

    // MARK: - State

    /// The folder the composed name is written into. `Choose…` replaces it.
    var locationURL: URL { location.url }

    /// The file this note already has, if it has one: saving over yourself is
    /// not a replacement and asks nothing.
    private let existingFileURL: URL?

    /// Nota's own "already exists, replace?" alert, handed in by the window so
    /// the dialog puts no alert up itself (and a test can answer it).
    var confirmReplace: ((URL) -> Bool)?

    private var result: URL?
    private var isObserving = false

    /// What Save would write: the name field and the Format popup composed
    /// into the location. The name field's own extension wins over the popup.
    var composedURL: URL {
        SaveNameComposer.composedURL(
            directory: locationURL,
            name: nameField.stringValue,
            extension: chosenExtension
        )
    }

    /// The popup's two items that are not extensions, told apart by tag so
    /// that neither the language nor the list's contents matter: `None`
    /// saves the name bare, `Other…` reads the extension off the field.
    static let noneTag = 1
    static let otherTag = 2

    /// What the popup and, behind `Other…`, the field say the extension is.
    var chosenExtension: String {
        switch formatPopUp.selectedItem?.tag {
        case Self.noneTag: return ""
        case Self.otherTag: return otherExtensionField.stringValue
        default: return formatPopUp.titleOfSelectedItem ?? ""
        }
    }

    /// Whether the popup stands on `Other…`, with the field beside it.
    var isOtherExtensionChosen: Bool {
        formatPopUp.selectedItem?.tag == Self.otherTag
    }

    /// Puts the popup on `Other…` with `ext` in the field, as a pick of that
    /// item and typing would. `None` is `selectNoExtension()`.
    func chooseOtherExtension(_ ext: String) {
        formatPopUp.selectItem(withTag: Self.otherTag)
        otherExtensionField.stringValue = ext
        formatChanged()
    }

    func selectNoExtension() {
        formatPopUp.selectItem(withTag: Self.noneTag)
        formatChanged()
    }

    // MARK: - Building

    /// - Parameters:
    ///   - suggestedName: the whole name as `SuggestedName.panelName` proposes
    ///     it, extension and all; it is split into the two fields here.
    ///   - existingFileURL: the note's own file, whose folder and extension
    ///     the dialog opens on.
    ///   - lastDirectory: `Preferences.lastSaveDirectory`, where a note with
    ///     no file of its own opens.
    ///   - preferredExtension: the footer's format badge, `Note.formatOverride`,
    ///     which wins over both of the others when it is set
    ///   - lastExtension: `Preferences.lastSaveExtension`, the format a note
    ///     with none of its own opens on.
    init(
        suggestedName: String,
        existingFileURL: URL?,
        lastDirectory: URL?,
        lastExtension: String,
        preferredExtension: String? = nil
    ) {
        self.existingFileURL = existingFileURL
        let base = SaveNameComposer.split(name: suggestedName).base
        // A named file saves where it lives; a new one where the last save
        // landed, and failing that in Documents.
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

        nameField.stringValue = base
        // A named file keeps its own extension; a new note is offered
        // whatever was chosen last, listed even if it is none of ours. The
        // extension is read off the *file*, never off the suggested name —
        // `SuggestedName.panelName` proposes `.md` for a note that has no
        // file at all, and that would leave the remembered one unreachable.
        let chosen = Self.openingExtension(
            existingFileURL: existingFileURL, lastExtension: lastExtension,
            preferredExtension: preferredExtension
        )
        formatPopUp.addItems(withTitles: SaveNameComposer.formatOptions(including: chosen))
        formatPopUp.menu?.addItem(.separator())
        let none = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        none.tag = Self.noneTag
        let other = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        other.tag = Self.otherTag
        formatPopUp.menu?.addItem(none)
        formatPopUp.menu?.addItem(other)
        if let match = formatPopUp.itemTitles.first(where: {
            $0.caseInsensitiveCompare(chosen) == .orderedSame
        }) {
            formatPopUp.selectItem(withTitle: match)
        }
        otherExtensionField.isHidden = true
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

        nameField.isEditable = true
        nameField.isBezeled = true
        nameField.bezelStyle = .roundedBezel
        nameField.delegate = self
        nameField.usesSingleLineMode = true
        nameField.cell?.wraps = false
        nameField.cell?.isScrollable = true

        formatPopUp.pullsDown = false
        formatPopUp.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        formatPopUp.target = self
        formatPopUp.action = #selector(formatPicked)

        otherExtensionField.isEditable = true
        otherExtensionField.isBezeled = true
        otherExtensionField.bezelStyle = .roundedBezel
        otherExtensionField.delegate = self
        otherExtensionField.usesSingleLineMode = true
        otherExtensionField.cell?.wraps = false
        otherExtensionField.cell?.isScrollable = true
        otherExtensionField.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.keyEquivalent = "\u{1b}"

        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        saveButton.keyEquivalent = "\r"

        // The name and its format are one thing — the file's name — so they
        // share the row: the field takes the width, the popup sits at its
        // end, and the extension reads as the tail of the name it is.
        let nameRow = NSStackView(views: [nameField, otherExtensionField, formatPopUp])
        nameRow.orientation = .horizontal
        nameRow.spacing = 8
        nameRow.distribution = .fill
        formatPopUp.widthAnchor.constraint(equalToConstant: Self.formatWidth).isActive = true
        otherExtensionField.widthAnchor.constraint(equalToConstant: Self.formatWidth).isActive = true
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

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
            // The fields, not the grid, reach the trailing inset: a grid
            // pinned on both sides hands its spare width to both columns
            // alike, and the label column would grow with it.
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

        content.layoutSubtreeIfNeeded()
        panel.setContentSize(content.fittingSize)
    }

    // MARK: - Language

    @objc private func preferencesChanged() { relabel() }

    /// Every word the dialog wears, asked again. Called on `Preferences`
    /// changing, so switching language while it is open takes effect where it
    /// stands rather than on the next save.
    private func relabel() {
        let title = L10n.text("Save")
        panel.title = title
        headingLabel.stringValue = title
        saveAsLabel.stringValue = L10n.text("Save As", chinese: "另存为") + ":"
        locationLabel.stringValue = L10n.text("Location", chinese: "位置") + ":"
        location.relabel()
        cancelButton.title = L10n.text("Cancel", chinese: "取消")
        saveButton.title = title
        formatPopUp.menu?.item(withTag: Self.noneTag)?.title = L10n.text("None", chinese: "无")
        formatPopUp.menu?.item(withTag: Self.otherTag)?.title = L10n.text("Other…", chinese: "其他…")
        otherExtensionField.placeholderString = L10n.text("Extension", chinese: "扩展名")
        otherExtensionField.toolTip = L10n.text(
            "The file's extension, typed by hand", chinese: "手动输入的文件扩展名"
        )
        // The label column is exactly as wide as its widest word: a column
        // left to size itself is handed a share of the grid's spare width
        // too, and the fields would lose it.
        grid.column(at: 0).width = [saveAsLabel, locationLabel]
            .map { $0.fittingSize.width }.max() ?? 0
        grid.layoutSubtreeIfNeeded()
    }

    // MARK: - Running

    /// Puts the dialog up as a sheet on `parent` and stays there until Save
    /// or Cancel: the URL Save composed, or `nil`.
    @discardableResult
    /// The extension the Format popup opens on: the footer's format badge
    /// where the reader has set one — their own word on what the tab is —
    /// else the file's own, else the one remembered from the last save.
    /// The one rule, so `MainWindowController.currentSaveExtension` can
    /// answer for the tests without a dialog ever being built.
    static func openingExtension(
        existingFileURL: URL?, lastExtension: String, preferredExtension: String?
    ) -> String {
        let ownExtension = existingFileURL
            .flatMap { SaveNameComposer.split(name: $0.lastPathComponent).extension }
        return preferredExtension ?? ownExtension ?? lastExtension
    }

    func runSheet(on parent: NSWindow) -> URL? {
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

    /// Save with nothing typed would write a file called `.md`; the button is
    /// simply not available until there is a name. `Other…` with nothing in
    /// its field is the same wait: the reader asked for an extension and has
    /// not said which yet.
    private func updateSaveEnabled() {
        let hasName = !nameField.stringValue
            .trimmingCharacters(in: .whitespaces).isEmpty
        let hasExtension = !isOtherExtensionChosen
            || !chosenExtension
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".")).isEmpty
        saveButton.isEnabled = hasName && hasExtension
    }

    @objc private func formatPicked() { formatChanged() }

    /// The field steps in beside the popup on `Other…`, takes the keyboard so
    /// the extension can be typed at once, and steps out on anything else.
    private func formatChanged() {
        let other = isOtherExtensionChosen
        otherExtensionField.isHidden = !other
        if other, panel.isVisible {
            panel.makeFirstResponder(otherExtensionField)
        }
        updateSaveEnabled()
    }

    func controlTextDidChange(_ notification: Notification) {
        updateSaveEnabled()
    }

    /// The Save the button and Return both mean, exposed so a test can take
    /// it without a modal session: the composed URL unless it would replace
    /// somebody else's file and the alert says no, in which case the dialog
    /// stays where it is.
    @discardableResult
    func save() -> Bool {
        guard saveButton.isEnabled else { return false }
        let url = composedURL
        if url.path != existingFileURL?.path,
           FileManager.default.fileExists(atPath: url.path),
           confirmReplace?(url) != true {
            return false
        }
        result = url
        finish()
        return true
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
