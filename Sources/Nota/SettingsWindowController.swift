import AppKit

/// Single-pane Settings window, in the shape macOS expects: fixed size,
/// centred the first time it appears, closes with ⌘W or Escape, and never
/// really goes away — it is hidden and reused.
///
/// Every control writes straight into `Preferences`, and the window listens
/// for `Preferences.didChange` so it also reflects changes made elsewhere
/// (⌘+ / ⌘- / ⌘0 move the size field while the window is open).
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
    private let sidebarSidePopUp = NSPopUpButton()
    private let plainTextImageStylePopUp = NSPopUpButton()
    private let readingModeCheckbox = NSButton(
        checkboxWithTitle: "Open Markdown files in reading mode", target: nil, action: nil
    )
    private let vimModeCheckbox = NSButton(checkboxWithTitle: "Vim mode", target: nil, action: nil)
    private let footerCheckboxes: [(TextStats.Segment, NSButton)] = [
        (.words, NSButton(checkboxWithTitle: "Words", target: nil, action: nil)),
        (.characters, NSButton(checkboxWithTitle: "Characters", target: nil, action: nil)),
        (.images, NSButton(checkboxWithTitle: "Images", target: nil, action: nil)),
        (.lines, NSButton(checkboxWithTitle: "Lines", target: nil, action: nil)),
    ]
    private let hotKeyField = ShortcutRecorderField()
    private let hotKeyWarning = NSTextField(labelWithString: "")
    private var hasCentered = false

    private var preferences: Preferences { .shared }

    private init() {
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        window.title = "Settings"
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

        fill(spacingPopUp, with: LineSpacingOption.allCases.map { ($0.title, $0.rawValue) },
             action: #selector(lineSpacingChanged))
        fill(paddingPopUp, with: EditorPaddingOption.allCases.map { ($0.title, $0.rawValue) },
             action: #selector(paddingChanged))
        fill(sidebarSidePopUp, with: SidebarSide.allCases.map { ($0.title, $0.rawValue) },
             action: #selector(sidebarSideChanged))
        fill(plainTextImageStylePopUp,
             with: PlainTextImageStyle.allCases.map { ($0.title, $0.rawValue) },
             action: #selector(plainTextImageStyleChanged))

        wordWrapCheckbox.target = self
        wordWrapCheckbox.action = #selector(wordWrapChanged)

        lineNumbersCheckbox.target = self
        lineNumbersCheckbox.action = #selector(lineNumbersChanged)

        gutterSeparatorCheckbox.target = self
        gutterSeparatorCheckbox.action = #selector(gutterSeparatorChanged)
        // Both gutter switches on one line, the separator second: it only
        // means anything while the numbers are there.
        let gutterRow = NSStackView(views: [lineNumbersCheckbox, gutterSeparatorCheckbox])
        gutterRow.orientation = .horizontal
        gutterRow.spacing = 10

        readingModeCheckbox.target = self
        readingModeCheckbox.action = #selector(readingModeChanged)

        vimModeCheckbox.target = self
        vimModeCheckbox.action = #selector(vimModeChanged)

        for (_, checkbox) in footerCheckboxes {
            checkbox.target = self
            checkbox.action = #selector(footerSegmentsChanged)
        }
        // Two by two rather than one long row, so the window keeps its width.
        let footerGrid = NSGridView(views: [
            [footerCheckboxes[0].1, footerCheckboxes[1].1],
            [footerCheckboxes[2].1, footerCheckboxes[3].1],
        ])
        footerGrid.rowSpacing = 2
        footerGrid.columnSpacing = 10
        footerGrid.column(at: 0).xPlacement = .leading
        footerGrid.column(at: 1).xPlacement = .leading

        hotKeyField.onRecord = { [weak self] shortcut in
            self?.preferences.hotKey = shortcut
        }
        let clearHotKey = NSButton(title: "Clear", target: self, action: #selector(clearHotKey))
        clearHotKey.bezelStyle = .rounded
        clearHotKey.controlSize = .small
        let hotKeyRow = NSStackView(views: [hotKeyField, clearHotKey])
        hotKeyRow.orientation = .horizontal
        hotKeyRow.spacing = 6
        hotKeyField.widthAnchor.constraint(equalToConstant: 118).isActive = true

        hotKeyWarning.font = .systemFont(ofSize: 11)
        hotKeyWarning.textColor = .systemRed
        hotKeyWarning.isHidden = true

        let grid = NSGridView(views: [
            [label("Font"), fontPopUp],
            [label("Size"), sizeRow],
            [label("Line spacing"), spacingPopUp],
            [label("Padding"), paddingPopUp],
            [label("Editor"), wordWrapCheckbox],
            [label("Gutter"), gutterRow],
            [label("Status bar"), footerGrid],
            [label("Image sidebar"), sidebarSidePopUp],
            [label("Copy images as"), plainTextImageStylePopUp],
            [label("Markdown"), readingModeCheckbox],
            [label("Vim mode"), vimModeCheckbox],
            [label("Summon"), hotKeyRow],
            [label(""), hotKeyWarning],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.rowAlignment = .none
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        for index in 0..<grid.numberOfRows {
            grid.row(at: index).yPlacement = .center
        }
        content.addSubview(grid)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            fontPopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 190),
            spacingPopUp.widthAnchor.constraint(equalTo: fontPopUp.widthAnchor),
            sidebarSidePopUp.widthAnchor.constraint(equalTo: fontPopUp.widthAnchor),
            plainTextImageStylePopUp.widthAnchor.constraint(equalTo: fontPopUp.widthAnchor),
            paddingPopUp.widthAnchor.constraint(equalTo: fontPopUp.widthAnchor),
        ])

        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        return field
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

    @objc private func preferencesChanged() { refresh() }

    private func refresh() {
        rebuildFontMenu()

        let size = "\(Int(preferences.fontSize))"
        if sizeField.stringValue != size { sizeField.stringValue = size }
        sizeStepper.doubleValue = Double(preferences.fontSize)

        select(spacingPopUp, raw: preferences.lineSpacing.rawValue)
        select(paddingPopUp, raw: preferences.padding.rawValue)
        select(sidebarSidePopUp, raw: preferences.sidebarSide.rawValue)
        select(plainTextImageStylePopUp, raw: preferences.plainTextImageStyle.rawValue)
        wordWrapCheckbox.state = preferences.wrapsLines ? .on : .off
        lineNumbersCheckbox.state = preferences.showsLineNumbers ? .on : .off
        gutterSeparatorCheckbox.state = preferences.showsGutterSeparator ? .on : .off
        gutterSeparatorCheckbox.isEnabled = preferences.showsLineNumbers
        let enabled = Set(preferences.footerSegments)
        for (segment, checkbox) in footerCheckboxes {
            checkbox.state = enabled.contains(segment) ? .on : .off
        }
        readingModeCheckbox.state = preferences.opensMarkdownInReadingMode ? .on : .off
        vimModeCheckbox.state = preferences.vimMode ? .on : .off
        hotKeyField.shortcut = preferences.hotKey

        let failed = (NSApp.delegate as? AppDelegate)?.hotKeyRegistrationFailed ?? false
        hotKeyWarning.stringValue = failed
            ? "Another app is using that shortcut."
            : ""
        hotKeyWarning.isHidden = !failed
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
        if preferences.fontFamily == .custom, let name = preferences.customFontName {
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
        if preferences.fontFamily == .custom {
            fontPopUp.selectItem(withTag: Tag.customFont)
        } else {
            select(fontPopUp, raw: preferences.fontFamily.rawValue)
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
            refresh()
        case Tag.customFont:
            break
        default:
            if let raw = item.representedObject as? String,
               let family = EditorFontFamily(rawValue: raw) {
                preferences.fontFamily = family
            }
        }
    }

    @objc private func sizeFieldChanged(_ sender: NSTextField) {
        preferences.fontSize = CGFloat(sender.doubleValue)
        refresh()
    }

    @objc private func sizeStepperChanged(_ sender: NSStepper) {
        preferences.fontSize = CGFloat(sender.doubleValue)
    }

    @objc private func lineSpacingChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let option = LineSpacingOption(rawValue: raw) else { return }
        preferences.lineSpacing = option
    }

    @objc private func sidebarSideChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let side = SidebarSide(rawValue: raw) else { return }
        preferences.sidebarSide = side
    }

    @objc private func readingModeChanged(_ sender: NSButton) {
        preferences.opensMarkdownInReadingMode = sender.state == .on
    }

    @objc private func plainTextImageStyleChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let style = PlainTextImageStyle(rawValue: raw) else { return }
        preferences.plainTextImageStyle = style
    }

    @objc private func clearHotKey() {
        preferences.hotKey = nil
        hotKeyField.shortcut = nil
    }

    @objc private func wordWrapChanged(_ sender: NSButton) {
        preferences.wrapsLines = sender.state == .on
    }

    @objc private func lineNumbersChanged(_ sender: NSButton) {
        preferences.showsLineNumbers = sender.state == .on
    }

    @objc private func gutterSeparatorChanged(_ sender: NSButton) {
        preferences.showsGutterSeparator = sender.state == .on
    }

    @objc private func footerSegmentsChanged(_ sender: NSButton) {
        for (segment, checkbox) in footerCheckboxes where checkbox === sender {
            let isOn = checkbox.state == .on
            switch segment {
            case .words: preferences.footerShowsWords = isOn
            case .characters: preferences.footerShowsCharacters = isOn
            case .images: preferences.footerShowsImages = isOn
            case .lines: preferences.footerShowsLines = isOn
            }
        }
    }

    @objc private func vimModeChanged(_ sender: NSButton) {
        preferences.vimMode = sender.state == .on
    }

    @objc private func paddingChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let option = EditorPaddingOption(rawValue: raw) else { return }
        preferences.padding = option
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
        preferences.selectCustomFont(familyName: family)
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
