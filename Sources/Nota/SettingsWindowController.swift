import AppKit

/// Single-pane Settings window, in the shape macOS expects: fixed size,
/// centred the first time it appears, closes with ⌘W or Escape, and never
/// really goes away — it is hidden and reused.
///
/// Controls stage a draft. Save applies that snapshot together, then rebuilds
/// the dialog so a language change is visible without closing the window.
final class SettingsWindowController: NSWindowController, NSFontChanging {
    static let shared = SettingsWindowController()

    private enum Tag {
        static let customFont = 100
        static let otherFont = 200
    }

    private let fontPopUp = NSPopUpButton()
    private let sizeField = NSTextField()
    private let sizeStepper = NSStepper()
    private let spacingPopUp = NSPopUpButton()
    private let paddingPopUp = NSPopUpButton()
    private let lineNumbersCheckbox = NSButton(checkboxWithTitle: "Line numbers", target: nil, action: nil)
    private let gutterSeparatorCheckbox = NSButton(
        checkboxWithTitle: "Gutter separator", target: nil, action: nil
    )
    private let wordWrapCheckbox = NSButton(checkboxWithTitle: "Word wrap", target: nil, action: nil)
    private let previewModeCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let vimModeCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let footerCheckboxes: [(TextStats.Segment, NSButton)] = [
        (.words, NSButton(checkboxWithTitle: "", target: nil, action: nil)),
        (.characters, NSButton(checkboxWithTitle: "", target: nil, action: nil)),
        (.images, NSButton(checkboxWithTitle: "", target: nil, action: nil)),
        (.lines, NSButton(checkboxWithTitle: "", target: nil, action: nil)),
    ]
    private let footerEncodingCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let footerLineEndingsCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let footerCursorCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let statusBarCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let languagePopUp = NSPopUpButton()
    private let themePopUp = NSPopUpButton()
    private let hotKeyField = ShortcutRecorderField()
    private let hotKeyWarning = NSTextField(labelWithString: "")
    private let clearHotKeyButton = NSButton()
    private let saveButton = NSButton()
    private var localizedLabels: [(field: NSTextField, key: String)] = []
    private var sectionTitles: [(field: NSTextField, key: String)] = []
    private var hasCentered = false
    private var isDirty = false
    private var isApplying = false
    private var pendingHotKey: GlobalHotKey.Shortcut?
    private var pendingFontFamily: EditorFontFamily = .system
    private var pendingCustomFontName: String?

    private var preferences: Preferences { .shared }

    private init() {
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        window.title = L10n.text("Settings")
        window.isReleasedWhenClosed = false

        buildUI()
        refresh()

        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: Preferences.didChange, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    func show() {
        guard let window else { return }
        if !hasCentered {
            window.center()
            hasCentered = true
        }
        isDirty = false
        refresh()
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Layout

    private func buildUI() {
        guard let window, let content = window.contentView else { return }

        fontPopUp.target = self
        fontPopUp.action = #selector(fontFamilyChanged)

        sizeField.alignment = .right
        sizeField.target = self
        sizeField.action = #selector(sizeFieldChanged)
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = NSNumber(value: Double(Preferences.minimumFontSize))
        formatter.maximum = NSNumber(value: Double(Preferences.maximumFontSize))
        sizeField.formatter = formatter

        sizeStepper.minValue = Double(Preferences.minimumFontSize)
        sizeStepper.maxValue = Double(Preferences.maximumFontSize)
        sizeStepper.increment = 1
        sizeStepper.valueWraps = false
        sizeStepper.target = self
        sizeStepper.action = #selector(sizeStepperChanged)

        let sizeRow = NSStackView(views: [sizeField, sizeStepper])
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 6
        sizeField.widthAnchor.constraint(equalToConstant: 52).isActive = true

        wordWrapCheckbox.target = self
        wordWrapCheckbox.action = #selector(draftChanged)

        lineNumbersCheckbox.target = self
        lineNumbersCheckbox.action = #selector(lineNumbersDraftChanged)

        gutterSeparatorCheckbox.target = self
        gutterSeparatorCheckbox.action = #selector(draftChanged)
        // Both gutter switches on one line, the separator second: it only
        // means anything while the numbers are there.
        let gutterRow = NSStackView(views: [lineNumbersCheckbox, gutterSeparatorCheckbox])
        gutterRow.orientation = .horizontal
        gutterRow.spacing = 10

        previewModeCheckbox.target = self
        previewModeCheckbox.action = #selector(draftChanged)

        vimModeCheckbox.target = self
        vimModeCheckbox.action = #selector(draftChanged)

        for (_, checkbox) in footerCheckboxes {
            checkbox.target = self
            checkbox.action = #selector(draftChanged)
        }
        for checkbox in [footerEncodingCheckbox, footerLineEndingsCheckbox, footerCursorCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(draftChanged)
        }
        statusBarCheckbox.target = self
        statusBarCheckbox.action = #selector(statusBarDraftChanged)
        // The visible status items mirror their order in the actual bar.
        let footerGrid = NSGridView(views: [
            [footerCheckboxes[0].1, footerCheckboxes[1].1],
            [footerCheckboxes[2].1, footerCheckboxes[3].1],
            [footerEncodingCheckbox, footerLineEndingsCheckbox],
            [footerCursorCheckbox, NSView()],
        ])
        footerGrid.rowSpacing = 5
        footerGrid.columnSpacing = 16
        footerGrid.column(at: 0).xPlacement = .leading
        footerGrid.column(at: 1).xPlacement = .leading

        hotKeyField.onRecord = { [weak self] shortcut in
            self?.pendingHotKey = shortcut
            self?.markDirty()
        }
        clearHotKeyButton.target = self
        clearHotKeyButton.action = #selector(clearHotKey)
        clearHotKeyButton.bezelStyle = .rounded
        clearHotKeyButton.controlSize = .small
        let hotKeyRow = NSStackView(views: [hotKeyField, clearHotKeyButton])
        hotKeyRow.orientation = .horizontal
        hotKeyRow.spacing = 6
        hotKeyField.widthAnchor.constraint(equalToConstant: 118).isActive = true

        hotKeyWarning.font = .systemFont(ofSize: 11)
        hotKeyWarning.textColor = .systemRed
        hotKeyWarning.isHidden = true

        saveButton.target = self
        saveButton.action = #selector(saveChanges)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let actionSpacer = NSView()
        let actionRow = NSStackView(views: [actionSpacer, saveButton])
        actionRow.orientation = .horizontal
        actionRow.spacing = 12

        let general = section("General", rows: [
            [label("Language"), languagePopUp],
            [label("Theme"), themePopUp],
            [label("Summon"), hotKeyRow],
            [label(""), hotKeyWarning],
        ])
        let appearance = section("Appearance", rows: [
            [label("Font"), fontPopUp],
            [label("Size"), sizeRow],
            [label("Line spacing"), spacingPopUp],
            [label("Padding"), paddingPopUp],
        ])
        let editor = section("Editor", rows: [
            [label(""), wordWrapCheckbox],
            [label(""), gutterRow],
        ])
        let preview = section("Preview", rows: [
            [label(""), previewModeCheckbox],
        ])
        let status = section("Status bar", rows: [
            [label(""), statusBarCheckbox],
            [label(""), footerGrid],
            [label(""), vimModeCheckbox],
        ])

        let stack = NSStackView(views: [general, appearance, editor, preview, status, actionRow])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            fontPopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            spacingPopUp.widthAnchor.constraint(equalTo: fontPopUp.widthAnchor),
            paddingPopUp.widthAnchor.constraint(equalTo: fontPopUp.widthAnchor),
            languagePopUp.widthAnchor.constraint(equalTo: fontPopUp.widthAnchor),
            themePopUp.widthAnchor.constraint(equalTo: fontPopUp.widthAnchor),
            actionRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
    }

    private func label(_ key: String) -> NSTextField {
        let field = NSTextField(labelWithString: L10n.text(key))
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: 112).isActive = true
        localizedLabels.append((field, key))
        return field
    }

    private func section(_ title: String, rows: [[NSView]]) -> NSStackView {
        let heading = NSTextField(labelWithString: L10n.text(title))
        heading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        sectionTitles.append((heading, title))

        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        for index in 0..<grid.numberOfRows { grid.row(at: index).yPlacement = .center }

        let section = NSStackView(views: [heading, grid])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        return section
    }

    private func fill(_ popUp: NSPopUpButton, with entries: [(String, String)], action: Selector) {
        popUp.removeAllItems()
        let menu = NSMenu()
        for (title, raw) in entries {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = raw
            menu.addItem(item)
        }
        popUp.menu = menu
        popUp.target = self
        popUp.action = action
    }

    // MARK: - Syncing controls

    @objc private func preferencesChanged() {
        if !isApplying && !isDirty { refresh() }
    }

    private func refresh() {
        pendingHotKey = preferences.hotKey
        pendingFontFamily = preferences.fontFamily
        pendingCustomFontName = preferences.customFontName
        window?.title = L10n.text("Settings")
        for (field, key) in localizedLabels { field.stringValue = L10n.text(key) }
        for (field, key) in sectionTitles { field.stringValue = L10n.text(key) }

        wordWrapCheckbox.title = L10n.text("Word wrap")
        lineNumbersCheckbox.title = L10n.text("Line numbers")
        gutterSeparatorCheckbox.title = L10n.text("Gutter separator")
        previewModeCheckbox.title = L10n.text("Start supported files in preview mode")
        vimModeCheckbox.title = L10n.text("Vim mode")
        statusBarCheckbox.title = L10n.text("Show status bar")
        let countTitles = ["Words", "Characters", "Images", "Lines"]
        for (entry, title) in zip(footerCheckboxes, countTitles) {
            entry.1.title = L10n.text(title)
        }
        footerEncodingCheckbox.title = L10n.text("Text encoding")
        footerLineEndingsCheckbox.title = L10n.text("Line endings")
        footerCursorCheckbox.title = L10n.text("Cursor position")
        clearHotKeyButton.title = L10n.text("Clear")
        saveButton.title = L10n.text("Save")
        fontPopUp.setAccessibilityLabel(L10n.text("Font"))
        sizeField.setAccessibilityLabel(L10n.text("Size"))
        sizeStepper.setAccessibilityLabel(L10n.text("Size"))
        spacingPopUp.setAccessibilityLabel(L10n.text("Line spacing"))
        paddingPopUp.setAccessibilityLabel(L10n.text("Padding"))
        languagePopUp.setAccessibilityLabel(L10n.text("Language"))
        themePopUp.setAccessibilityLabel(L10n.text("Theme"))
        hotKeyField.setAccessibilityLabel(L10n.text("Summon"))

        fill(spacingPopUp, with: LineSpacingOption.allCases.map { ($0.title, $0.rawValue) },
             action: #selector(lineSpacingChanged))
        fill(paddingPopUp, with: EditorPaddingOption.allCases.map { ($0.title, $0.rawValue) },
             action: #selector(paddingChanged))
        fill(languagePopUp, with: AppLanguage.allCases.map { ($0.title, $0.rawValue) },
             action: #selector(languageChanged))
        fill(themePopUp, with: AppTheme.allCases.map { ($0.title, $0.rawValue) },
             action: #selector(themeChanged))

        rebuildFontMenu()

        let size = "\(Int(preferences.fontSize))"
        if sizeField.stringValue != size { sizeField.stringValue = size }
        sizeStepper.doubleValue = Double(preferences.fontSize)

        select(spacingPopUp, raw: preferences.lineSpacing.rawValue)
        select(paddingPopUp, raw: preferences.padding.rawValue)
        select(languagePopUp, raw: preferences.language.rawValue)
        select(themePopUp, raw: preferences.theme.rawValue)
        wordWrapCheckbox.state = preferences.wrapsLines ? .on : .off
        lineNumbersCheckbox.state = preferences.showsLineNumbers ? .on : .off
        gutterSeparatorCheckbox.state = preferences.showsGutterSeparator ? .on : .off
        gutterSeparatorCheckbox.isEnabled = preferences.showsLineNumbers
        let enabled = Set(preferences.footerSegments)
        for (segment, checkbox) in footerCheckboxes {
            checkbox.state = enabled.contains(segment) ? .on : .off
        }
        footerEncodingCheckbox.state = preferences.footerShowsEncoding ? .on : .off
        footerLineEndingsCheckbox.state = preferences.footerShowsLineEndings ? .on : .off
        footerCursorCheckbox.state = preferences.footerShowsCursorPosition ? .on : .off
        statusBarCheckbox.state = preferences.showsStatusBar ? .on : .off
        setStatusDetailsEnabled(preferences.showsStatusBar)
        previewModeCheckbox.state = preferences.opensMarkdownInReadingMode ? .on : .off
        vimModeCheckbox.state = preferences.vimMode ? .on : .off
        hotKeyField.shortcut = pendingHotKey

        let failed = (NSApp.delegate as? AppDelegate)?.hotKeyRegistrationFailed ?? false
        hotKeyWarning.stringValue = failed
            ? L10n.text("Another app is using that shortcut.")
            : ""
        hotKeyWarning.isHidden = !failed
        isDirty = false
        saveButton.isEnabled = false
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
    }

    /// The custom family gets its own item so the popup can show the real
    /// font name rather than a generic "Other".
    private func rebuildFontMenu() {
        let menu = NSMenu()
        for family in EditorFontFamily.allCases where family != .custom {
            let item = NSMenuItem(title: family.title, action: nil, keyEquivalent: "")
            item.representedObject = family.rawValue
            menu.addItem(item)
        }
        if pendingFontFamily == .custom, let name = pendingCustomFontName {
            menu.addItem(.separator())
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            item.tag = Tag.customFont
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let other = NSMenuItem(title: EditorFontFamily.custom.title, action: nil, keyEquivalent: "")
        other.tag = Tag.otherFont
        menu.addItem(other)

        fontPopUp.menu = menu
        if pendingFontFamily == .custom {
            fontPopUp.selectItem(withTag: Tag.customFont)
        } else {
            select(fontPopUp, raw: pendingFontFamily.rawValue)
        }
    }

    private func select(_ popUp: NSPopUpButton, raw: String) {
        let match = popUp.itemArray.first { ($0.representedObject as? String) == raw }
        if let match { popUp.select(match) }
    }

    // MARK: - Actions

    @objc private func fontFamilyChanged(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem else { return }
        switch item.tag {
        case Tag.otherFont:
            presentFontPanel()
        case Tag.customFont:
            break
        default:
            if let raw = item.representedObject as? String,
               let family = EditorFontFamily(rawValue: raw) {
                pendingFontFamily = family
                markDirty()
            }
        }
    }

    @objc private func sizeFieldChanged(_ sender: NSTextField) {
        let size = Preferences.clampFontSize(CGFloat(sender.doubleValue))
        sender.stringValue = "\(Int(size))"
        sizeStepper.doubleValue = Double(size)
        markDirty()
    }

    @objc private func sizeStepperChanged(_ sender: NSStepper) {
        sizeField.stringValue = "\(Int(sender.doubleValue))"
        markDirty()
    }

    @objc private func lineSpacingChanged(_ sender: NSPopUpButton) { markDirty() }
    @objc private func paddingChanged(_ sender: NSPopUpButton) { markDirty() }
    @objc private func languageChanged(_ sender: NSPopUpButton) { markDirty() }
    @objc private func themeChanged(_ sender: NSPopUpButton) { markDirty() }
    @objc private func draftChanged(_ sender: Any?) { markDirty() }

    @objc private func clearHotKey() {
        pendingHotKey = nil
        hotKeyField.shortcut = nil
        markDirty()
    }

    @objc private func lineNumbersDraftChanged(_ sender: NSButton) {
        gutterSeparatorCheckbox.isEnabled = sender.state == .on
        markDirty()
    }

    @objc private func statusBarDraftChanged(_ sender: NSButton) {
        setStatusDetailsEnabled(sender.state == .on)
        markDirty()
    }

    private func setStatusDetailsEnabled(_ enabled: Bool) {
        for (_, checkbox) in footerCheckboxes { checkbox.isEnabled = enabled }
        footerEncodingCheckbox.isEnabled = enabled
        footerLineEndingsCheckbox.isEnabled = enabled
        footerCursorCheckbox.isEnabled = enabled
    }

    private func markDirty() {
        isDirty = true
        saveButton.isEnabled = true
    }

    private func rawValue<T: RawRepresentable>(of popUp: NSPopUpButton, as type: T.Type) -> T?
    where T.RawValue == String {
        guard let raw = popUp.selectedItem?.representedObject as? String else { return nil }
        return T(rawValue: raw)
    }

    @objc private func saveChanges() {
        guard let spacing = rawValue(of: spacingPopUp, as: LineSpacingOption.self),
              let padding = rawValue(of: paddingPopUp, as: EditorPaddingOption.self),
              let language = rawValue(of: languagePopUp, as: AppLanguage.self),
              let theme = rawValue(of: themePopUp, as: AppTheme.self)
        else { return }

        let fontFamily = pendingFontFamily
        let customFontName = pendingCustomFontName
        let fontSize = Preferences.clampFontSize(CGFloat(sizeField.doubleValue))
        let hotKey = pendingHotKey
        let segmentStates = Dictionary(uniqueKeysWithValues: footerCheckboxes.map {
            ($0.0, $0.1.state == .on)
        })

        isApplying = true
        preferences.customFontName = customFontName
        preferences.fontFamily = fontFamily
        preferences.fontSize = fontSize
        preferences.lineSpacing = spacing
        preferences.padding = padding
        preferences.wrapsLines = wordWrapCheckbox.state == .on
        preferences.showsLineNumbers = lineNumbersCheckbox.state == .on
        preferences.showsGutterSeparator = gutterSeparatorCheckbox.state == .on
        preferences.opensMarkdownInReadingMode = previewModeCheckbox.state == .on
        preferences.showsStatusBar = statusBarCheckbox.state == .on
        preferences.footerShowsWords = segmentStates[.words] ?? false
        preferences.footerShowsCharacters = segmentStates[.characters] ?? false
        preferences.footerShowsImages = segmentStates[.images] ?? false
        preferences.footerShowsLines = segmentStates[.lines] ?? false
        preferences.footerShowsEncoding = footerEncodingCheckbox.state == .on
        preferences.footerShowsLineEndings = footerLineEndingsCheckbox.state == .on
        preferences.footerShowsCursorPosition = footerCursorCheckbox.state == .on
        preferences.vimMode = vimModeCheckbox.state == .on
        preferences.hotKey = hotKey
        preferences.language = language
        preferences.theme = theme
        isApplying = false
        isDirty = false
        refresh()
    }

    // MARK: - Font panel

    private func presentFontPanel() {
        let manager = NSFontManager.shared
        manager.target = self
        manager.setSelectedFont(preferences.font(), isMultiple: false)
        manager.orderFrontFontPanel(self)
    }

    func changeFont(_ sender: NSFontManager?) {
        guard let sender else { return }
        let chosen = sender.convert(preferences.font())
        guard let family = chosen.familyName else { return }
        pendingFontFamily = .custom
        pendingCustomFontName = family
        rebuildFontMenu()
        markDirty()
    }

    /// Size lives in the Settings window, so the panel only offers the family.
    func validModesForFontPanel(_ fontPanel: NSFontPanel) -> NSFontPanel.ModeMask {
        [.collection, .face]
    }
}

/// Escape closes the window, the way a Preferences window normally does.
final class SettingsWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}
