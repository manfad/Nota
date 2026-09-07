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
    private static let folderIconSize: CGFloat = 16

    // MARK: - Chrome

    let panel: NSPanel
    let headingLabel = NSTextField(labelWithString: "")
    let saveAsLabel = NSTextField(labelWithString: "")
    let locationLabel = NSTextField(labelWithString: "")
    let nameField = NSTextField()
    let formatPopUp = NSPopUpButton()
    let locationField = NSTextField(labelWithString: "")
    let chooseButton = NSButton()
    let cancelButton = NSButton()
    let saveButton = NSButton()
    private let grid: NSGridView

    // MARK: - State

    /// The folder the composed name is written into. `Choose…` replaces it.
    private(set) var locationURL: URL

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
            extension: formatPopUp.titleOfSelectedItem ?? ""
        )
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
        // landed, and failing that in Documents, which is where a save panel
        // with nothing to go on opens too.
        locationURL = existingFileURL?.deletingLastPathComponent()
            ?? lastDirectory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)

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
        if let match = formatPopUp.itemTitles.first(where: {
            $0.caseInsensitiveCompare(chosen) == .orderedSame
        }) {
            formatPopUp.selectItem(withTitle: match)
        }
        showLocation()
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

        // Read only: the folder is picked through `Choose…`, never typed, so
        // the field is here to be read — the folder's own icon, its name, and
        // the whole path behind a tooltip.
        locationField.isBezeled = true
        locationField.bezelStyle = .roundedBezel
        locationField.isEditable = false
        locationField.isSelectable = false
        locationField.lineBreakMode = .byTruncatingMiddle
        locationField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        locationField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        chooseButton.bezelStyle = .rounded
        chooseButton.target = self
        chooseButton.action = #selector(chooseLocation)

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
        let nameRow = NSStackView(views: [nameField, formatPopUp])
        nameRow.orientation = .horizontal
        nameRow.spacing = 8
        nameRow.distribution = .fill
        formatPopUp.widthAnchor.constraint(equalToConstant: Self.formatWidth).isActive = true
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let locationRow = NSStackView(views: [locationField, chooseButton])
        locationRow.orientation = .horizontal
        locationRow.spacing = 8
        // `.fill`, not gravity areas: the field takes the width up to the
        // button instead of hugging its folder's name.
        locationRow.distribution = .fill

        grid.addRow(with: [saveAsLabel, nameRow])
        grid.addRow(with: [locationLabel, locationRow])
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
            locationRow.trailingAnchor.constraint(
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
        chooseButton.title = L10n.text("Choose…", chinese: "选择…")
        cancelButton.title = L10n.text("Cancel", chinese: "取消")
        saveButton.title = title
        // The label column is exactly as wide as its widest word: a column
        // left to size itself is handed a share of the grid's spare width
        // too, and the fields would lose it.
        grid.column(at: 0).width = [saveAsLabel, locationLabel]
            .map { $0.fittingSize.width }.max() ?? 0
        grid.layoutSubtreeIfNeeded()
    }

    // MARK: - Location

    /// The folder as the row shows it: its own Finder icon, then its name,
    /// with the whole path behind the tooltip.
    private func showLocation() {
        let icon = NSWorkspace.shared.icon(forFile: locationURL.path)
        icon.size = NSSize(width: Self.folderIconSize, height: Self.folderIconSize)
        let attachment = NSTextAttachment()
        let cell = NSTextAttachmentCell(imageCell: icon)
        attachment.attachmentCell = cell
        let line = NSMutableAttributedString(attachment: attachment)
        line.append(NSAttributedString(
            string: " " + locationURL.lastPathComponent,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.labelColor,
            ]
        ))
        locationField.attributedStringValue = line
        locationField.toolTip = locationURL.path
    }

    /// The one part the system still owns: picking a folder. Run modally
    /// inside the dialog's own modal session — a nested `runModal` is what
    /// AppKit documents for a panel opened from a modal window, and a sheet
    /// on a sheet is not a Mac shape anyway.
    @objc private func chooseLocation() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.canCreateDirectories = true
        picker.allowsMultipleSelection = false
        picker.directoryURL = locationURL
        picker.prompt = L10n.text("Choose", chinese: "选择")
        guard picker.runModal() == .OK, let chosen = picker.url else { return }
        locationURL = chosen
        showLocation()
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
    /// simply not available until there is a name.
    private func updateSaveEnabled() {
        saveButton.isEnabled = !nameField.stringValue
            .trimmingCharacters(in: .whitespaces).isEmpty
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
