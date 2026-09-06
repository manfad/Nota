import AppKit

/// Settings, in the shape macOS System Settings uses: a source list of pages
/// down the left, under the traffic lights, and one page at a time on the
/// right with its controls in inset rounded groups.
///
/// Seven pages over one shared Save button. The button lives outside the pages
/// on purpose: the draft is one draft, and Save applies every page's worth of
/// it together.
///
/// Controls stage a draft. Save applies that snapshot together, then rebuilds
/// the dialog so a language change is visible without closing the window.
final class SettingsWindowController: NSWindowController, NSFontChanging {
    static let shared = SettingsWindowController()

    private enum Tag {
        static let customFont = 100
        static let otherFont = 200
    }

    /// The pages, in sidebar order, each with the symbol its row wears.
    private static let pageSymbols: [(key: String, symbol: String)] = [
        ("General", "gearshape"),
        ("Appearance", "paintbrush"),
        ("Editor", "square.and.pencil"),
        ("Preview", "doc.richtext"),
        ("Tab bar", "rectangle.topthird.inset.filled"),
        ("Status bar", "rectangle.bottomthird.inset.filled"),
        ("Shortcuts", "keyboard"),
        ("About", "info.circle"),
    ]

    private struct Page {
        let key: String
        let content: NSView
        let rows: [SettingsRowView]
    }

    private let fontPopUp = NSPopUpButton()
    private let sizeField = NSTextField()
    private let sizeStepper = NSStepper()
    private let spacingPopUp = NSPopUpButton()
    private let paddingPopUp = NSPopUpButton()
    private let languagePopUp = NSPopUpButton()
    private let themePopUp = NSPopUpButton()
    private let sidebarSidePopUp = NSPopUpButton()
    private let wordWrapSwitch = NSSwitch()
    private let lineNumbersSwitch = NSSwitch()
    private let gutterSeparatorSwitch = NSSwitch()
    private let vimModeSwitch = NSSwitch()
    private let previewModeSwitch = NSSwitch()
    private let statusBarSwitch = NSSwitch()
    private let showTabBarSwitch = NSSwitch()
    private let autoHideTabBarSwitch = NSSwitch()
    private let trafficLightsSwitch = NSSwitch()
    private let bookmarkButtonSwitch = NSSwitch()
    private let settingsButtonSwitch = NSSwitch()
    private let footerSwitches: [(TextStats.Segment, NSSwitch)] = [
        (.words, NSSwitch()),
        (.characters, NSSwitch()),
        (.images, NSSwitch()),
        (.lines, NSSwitch()),
    ]
    private let footerEncodingSwitch = NSSwitch()
    private let footerLineEndingsSwitch = NSSwitch()
    private let footerCursorSwitch = NSSwitch()
    private let hotKeyField = ShortcutRecorderField()
    private let hotKeyWarning = WrappingLabel(text: "")
    private let clearHotKeyButton = NSButton()
    private let saveButton = NSButton()
    private let resetShortcutsButton = NSButton()
    private let shortcutWarning = WrappingLabel(text: "")
    private let versionLabel = WrappingLabel(text: "")
    private let checkUpdatesButton = NSButton()
    private let updateStatusLabel = WrappingLabel(text: "")
    private let downloadUpdateButton = NSButton()
    private let brewCommandField = NSTextField(labelWithString: UpdateCheck.homebrewUpgradeCommand)
    /// Where the About page's update check has got to. Manual, and forgotten
    /// the moment the window is rebuilt: nothing about it is stored.
    private enum UpdateState {
        case idle
        case checking
        case done(UpdateCheck.Result)
    }
    private var updateState: UpdateState = .idle
    private var updateURL: String?

    private let pageTitleLabel = NSTextField(labelWithString: "")
    private let pageHost = FlippedView()
    private var pages: [Page] = []
    private var sidebarRows: [SettingsSidebarRow] = []
    private var selectedPage = 0

    /// The row whose switch only means anything while line numbers are on.
    private var gutterSeparatorRow: SettingsRowView?
    /// Greyed while "Show tab bar" is off: a strip that is gone for good has
    /// nothing to slide in.
    private var autoHideTabBarRow: SettingsRowView?
    /// Greyed while "Show tab bar" is off: it already takes the lights with
    /// it, the way zen does, so there is nothing left for this row to do.
    private var trafficLightsRow: SettingsRowView?
    /// The region rows the status-bar switch turns off as a block.
    private var statusDetailRows: [SettingsRowView] = []

    private var shortcutFields: [ShortcutAction: ShortcutRecorderField] = [:]
    private var localizedLabels: [(field: NSTextField, key: String)] = []
    private var sectionTitles: [(field: NSTextField, key: String)] = []
    private var hasCentered = false
    private var isDirty = false
    private var isApplying = false
    private var pendingHotKey: GlobalHotKey.Shortcut?
    private var pendingShortcuts: [ShortcutAction: KeyCombo] = [:]
    private var pendingFontFamily: EditorFontFamily = .system
    private var pendingCustomFontName: String?

    /// The sidebar's width, and the height its first row starts at — far
    /// enough down that the traffic lights sitting over it have their own air.
    private static let sidebarWidth: CGFloat = 180
    private static let sidebarTopInset: CGFloat = 46
    /// Padding between the page's edge and its groups.
    private static let pageInset: CGFloat = 24

    private var preferences: Preferences { .shared }

    private init() {
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 500),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        window.title = L10n.text("Settings")
        window.isReleasedWhenClosed = false
        // The sidebar runs the full height with the traffic lights over it, so
        // the titlebar is glass and the title itself lives on the page.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Small enough to shrink well below the opening size — the pages are
        // narrow — but never so small that a group's control and its label
        // would have to fight for the same points.
        window.contentMinSize = NSSize(width: 560, height: 400)

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

    // MARK: - Testing hooks

    /// The page titles, in the order the sidebar lists them.
    var pageTitles: [String] { pages.map { L10n.text($0.key) } }

    /// Stands in for the network on the About page: given the closure the
    /// real check would call, answer it. Set, no request is ever made.
    var updateCheckForTesting: (((@escaping (UpdateCheck.Result) -> Void)) -> Void)?

    /// Answers "did this copy come from Homebrew?" without a disk to look at.
    var homebrewOverrideForTesting: Bool?

    /// What the About page's update block is showing.
    var updateControlsForTesting:
        (check: NSButton, status: NSTextField, download: NSButton, brewCommand: NSTextField)
    {
        (checkUpdatesButton, updateStatusLabel, downloadUpdateButton, brewCommandField)
    }

    /// Puts the About page back the way it opens, so one test's answer is
    /// not still on screen for the next.
    func resetUpdateStateForTesting() {
        updateCheckForTesting = nil
        homebrewOverrideForTesting = nil
        updateState = .idle
        applyUpdateState()
    }

    /// Only the selected page's controls are in the view hierarchy, the way
    /// System Settings works, so a test looking for a row has to bring that
    /// page forward first.
    func selectPage(at index: Int) {
        guard pages.indices.contains(index) else { return }
        selectedPage = index
        for (position, row) in sidebarRows.enumerated() { row.isSelected = position == index }
        pageTitleLabel.stringValue = L10n.text(pages[index].key)

        for view in pageHost.subviews { view.removeFromSuperview() }
        let content = pages[index].content
        pageHost.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: pageHost.topAnchor, constant: 8),
            content.leadingAnchor.constraint(
                equalTo: pageHost.leadingAnchor, constant: Self.pageInset
            ),
            content.trailingAnchor.constraint(
                equalTo: pageHost.trailingAnchor, constant: -Self.pageInset
            ),
            content.bottomAnchor.constraint(equalTo: pageHost.bottomAnchor, constant: -20),
        ])
        pageHost.layoutSubtreeIfNeeded()
    }

    /// Selects the page with this title, English key or translation. False if
    /// there is no such page.
    @discardableResult
    func selectPage(titled title: String) -> Bool {
        guard let index = pages.firstIndex(where: { $0.key == title || L10n.text($0.key) == title })
        else { return false }
        selectPage(at: index)
        return true
    }

    /// A page's rows as the user reads them: the label on the left and the
    /// control on the right. Switches carry no title of their own, so this is
    /// how a test names one.
    func rows(on page: Int) -> [(title: String, control: NSControl)] {
        guard pages.indices.contains(page) else { return [] }
        return pages[page].rows.map { ($0.label.stringValue, $0.control) }
    }

    // MARK: - Layout

    private func buildUI() {
        guard let window, let content = window.contentView else { return }
        configureControls()
        buildPages()

        let sidebar = NSVisualEffectView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .followsWindowActiveState

        let rowStack = NSStackView(views: [])
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 2
        for (index, entry) in Self.pageSymbols.enumerated() {
            let row = SettingsSidebarRow(symbol: entry.symbol)
            row.onSelect = { [weak self] in self?.selectPage(at: index) }
            sidebarRows.append(row)
            rowStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }
        sidebar.addSubview(rowStack)

        let pane = NSView()
        pane.translatesAutoresizingMaskIntoConstraints = false

        pageTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        pageTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        pageTitleLabel.alignment = .center
        pane.addSubview(pageTitleLabel)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = pageHost
        pane.addSubview(scroll)

        let saveSpacer = NSView()
        let saveRow = NSStackView(views: [saveSpacer, saveButton])
        saveRow.translatesAutoresizingMaskIntoConstraints = false
        saveRow.orientation = .horizontal
        saveRow.spacing = 12
        pane.addSubview(saveRow)

        content.addSubview(sidebar)
        content.addSubview(pane)

        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),

            rowStack.topAnchor.constraint(
                equalTo: sidebar.topAnchor, constant: Self.sidebarTopInset
            ),
            rowStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            rowStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),

            pane.topAnchor.constraint(equalTo: content.topAnchor),
            pane.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            pane.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pane.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            pageTitleLabel.topAnchor.constraint(equalTo: pane.topAnchor, constant: 18),
            pageTitleLabel.centerXAnchor.constraint(equalTo: pane.centerXAnchor),
            pageTitleLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: pane.leadingAnchor, constant: 20
            ),

            scroll.topAnchor.constraint(equalTo: pageTitleLabel.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: saveRow.topAnchor, constant: -12),

            pageHost.topAnchor.constraint(equalTo: clip.topAnchor),
            pageHost.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            pageHost.widthAnchor.constraint(equalTo: clip.widthAnchor),

            saveRow.leadingAnchor.constraint(
                equalTo: pane.leadingAnchor, constant: Self.pageInset
            ),
            saveRow.trailingAnchor.constraint(
                equalTo: pane.trailingAnchor, constant: -Self.pageInset
            ),
            saveRow.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -18),
        ])

        selectPage(at: 0)
    }

    private func configureControls() {
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

        for control in [wordWrapSwitch, gutterSeparatorSwitch, vimModeSwitch, previewModeSwitch,
                        autoHideTabBarSwitch, trafficLightsSwitch, bookmarkButtonSwitch,
                        settingsButtonSwitch] {
            control.target = self
            control.action = #selector(draftChanged)
        }
        for (_, control) in footerSwitches {
            control.target = self
            control.action = #selector(draftChanged)
        }
        for control in [footerEncodingSwitch, footerLineEndingsSwitch, footerCursorSwitch] {
            control.target = self
            control.action = #selector(draftChanged)
        }
        lineNumbersSwitch.target = self
        lineNumbersSwitch.action = #selector(lineNumbersDraftChanged)
        showTabBarSwitch.target = self
        showTabBarSwitch.action = #selector(showTabBarDraftChanged)
        statusBarSwitch.target = self
        statusBarSwitch.action = #selector(statusBarDraftChanged)

        hotKeyField.onRecord = { [weak self] shortcut in
            self?.pendingHotKey = shortcut
            self?.markDirty()
        }
        clearHotKeyButton.target = self
        clearHotKeyButton.action = #selector(clearHotKey)
        clearHotKeyButton.bezelStyle = .rounded
        clearHotKeyButton.controlSize = .small

        hotKeyWarning.textColor = .systemRed
        hotKeyWarning.isHidden = true
        hotKeyWarning.setAccessibilityIdentifier("summon-warning")

        shortcutWarning.textColor = .systemRed
        shortcutWarning.isHidden = true
        shortcutWarning.setAccessibilityIdentifier("shortcut-conflict")

        checkUpdatesButton.target = self
        checkUpdatesButton.action = #selector(checkForUpdates)
        checkUpdatesButton.bezelStyle = .rounded
        checkUpdatesButton.controlSize = .regular
        checkUpdatesButton.setAccessibilityIdentifier("check-for-updates")

        downloadUpdateButton.target = self
        downloadUpdateButton.action = #selector(openDownloadPage)
        downloadUpdateButton.bezelStyle = .rounded
        downloadUpdateButton.controlSize = .regular
        downloadUpdateButton.setAccessibilityIdentifier("download-update")

        // The Homebrew command is read and copied by hand — selectable text,
        // in the font a terminal would print it in. Nota touches no clipboard.
        brewCommandField.isSelectable = true
        brewCommandField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        brewCommandField.setAccessibilityIdentifier("brew-upgrade-command")

        resetShortcutsButton.target = self
        resetShortcutsButton.action = #selector(resetShortcuts)
        resetShortcutsButton.bezelStyle = .rounded
        resetShortcutsButton.controlSize = .small

        saveButton.target = self
        saveButton.action = #selector(saveChanges)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        for popUp in [fontPopUp, spacingPopUp, paddingPopUp, languagePopUp, themePopUp,
                      sidebarSidePopUp] {
            popUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        }
        sizeField.widthAnchor.constraint(equalToConstant: 52).isActive = true
        hotKeyField.widthAnchor.constraint(equalToConstant: 118).isActive = true
    }

    // MARK: - The pages

    private func buildPages() {
        pages = [
            generalPage(), appearancePage(), editorPage(), previewPage(),
            tabBarPage(), statusBarPage(), shortcutsPage(), aboutPage(),
        ]
    }

    private func generalPage() -> Page {
        let rows = [row("Language", control: languagePopUp), row("Theme", control: themePopUp)]
        return page(
            "General",
            blocks: [groupBox(rows), footnote("System Default follows the Mac.")],
            rows: rows
        )
    }

    private func appearancePage() -> Page {
        let sizeStack = NSStackView(views: [sizeField, sizeStepper])
        sizeStack.orientation = .horizontal
        sizeStack.spacing = 6

        let text = [
            row("Font", control: fontPopUp),
            row("Size", control: sizeField, trailing: sizeStack),
            row("Line spacing", control: spacingPopUp),
            row("Padding", control: paddingPopUp),
            row("Sidebar side", control: sidebarSidePopUp),
        ]
        return page("Appearance", blocks: [groupBox(text)], rows: text)
    }

    private func editorPage() -> Page {
        let separator = row("Gutter separator", control: gutterSeparatorSwitch)
        gutterSeparatorRow = separator
        let rows = [
            row("Word wrap", control: wordWrapSwitch),
            row("Line numbers", control: lineNumbersSwitch),
            separator,
            row("Vim mode", control: vimModeSwitch),
        ]
        return page("Editor", blocks: [groupBox(rows)], rows: rows)
    }

    private func previewPage() -> Page {
        let rows = [
            row("Start supported files in preview mode", control: previewModeSwitch),
        ]
        return page("Preview", blocks: [groupBox(rows)], rows: rows)
    }

    private func tabBarPage() -> Page {
        let showTabBar = row("Show tab bar", control: showTabBarSwitch)
        // Auto-hide has nothing to slide in once the strip is gone for good.
        let autoHide = row("Auto-hide tab bar", control: autoHideTabBarSwitch)
        autoHideTabBarRow = autoHide
        let master = [showTabBar, autoHide]

        // What the strip shows: each of these takes a piece of chrome away,
        // and every one of them has a key that still works without it.
        let trafficLights = row("Traffic lights", control: trafficLightsSwitch)
        trafficLightsRow = trafficLights
        let parts = [
            trafficLights,
            row("Bookmark button", control: bookmarkButtonSwitch),
            row("Settings button", control: settingsButtonSwitch),
        ]

        return page(
            "Tab bar",
            blocks: [
                groupBox(master),
                groupBox(parts),
            ],
            rows: master + parts
        )
    }

    private func statusBarPage() -> Page {
        let toggle = row("Show status bar", control: statusBarSwitch)
        // The regions read in the order the actual bar draws them.
        let titles = ["Words", "Characters", "Images", "Lines"]
        var regions = zip(titles, footerSwitches).map { row($0.0, control: $0.1.1) }
        regions.append(row("Text encoding", control: footerEncodingSwitch))
        regions.append(row("Line endings", control: footerLineEndingsSwitch))
        regions.append(row("Cursor position", control: footerCursorSwitch))
        statusDetailRows = regions

        return page(
            "Status bar",
            blocks: [groupBox([toggle]), groupBox(regions)],
            rows: [toggle] + regions
        )
    }

    /// Summon first — it is the one shortcut that works while Nota is not in
    /// front — then the menu commands, grouped under the menu each lives in.
    private func shortcutsPage() -> Page {
        let hotKeyStack = NSStackView(views: [hotKeyField, clearHotKeyButton])
        hotKeyStack.orientation = .horizontal
        hotKeyStack.spacing = 6

        let summon = row("Summon", control: hotKeyField, trailing: hotKeyStack)
        // Settings… shares the top group with Summon: a group of its own
        // would be headed "Nota", which reads as nothing on a Nota page.
        let settings = row(ShortcutAction.settings.titleKey, control: recorder(for: .settings))
        var blocks: [NSView] = [
            groupBox([summon, settings]),
            footnote("Summon brings Nota to the front from any app, even while it is hidden."),
            hotKeyWarning,
        ]
        var rows = [summon, settings]
        for group in ShortcutAction.Group.allCases where group != .nota {
            let commands = group.actions.map { action in
                row(action.titleKey, control: recorder(for: action))
            }
            blocks.append(sectionHeading(group.rawValue))
            blocks.append(groupBox(commands))
            rows.append(contentsOf: commands)
        }

        let resetSpacer = NSView()
        let resetRow = NSStackView(views: [resetSpacer, resetShortcutsButton])
        resetRow.orientation = .horizontal
        resetRow.spacing = 12

        blocks.append(shortcutWarning)
        blocks.append(footnote(
            "Two commands cannot share a combination, and the Mac's own keys are off limits."
        ))
        blocks.append(resetRow)
        return page("Shortcuts", blocks: blocks, rows: rows)
    }

    private func aboutPage() -> Page {
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),
        ])

        let name = NSTextField(labelWithString: "Nota")
        name.font = .systemFont(ofSize: 24, weight: .semibold)
        name.alignment = .center

        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center

        let tagline = footnote("A plain-text notebook.")
        tagline.alignment = .center

        updateStatusLabel.alignment = .center
        updateStatusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
        brewCommandField.alignment = .center

        let about = page(
            "About",
            blocks: [icon, name, versionLabel, tagline,
                     checkUpdatesButton, updateStatusLabel, brewCommandField,
                     downloadUpdateButton],
            rows: [], centered: true
        )
        // The button starts a block of its own under the line about Nota.
        (about.content as? NSStackView)?.setCustomSpacing(20, after: tagline)
        applyUpdateState()
        return about
    }

    // MARK: - Building blocks

    private func page(
        _ key: String, blocks: [NSView], rows: [SettingsRowView], centered: Bool = false
    ) -> Page {
        let stack = NSStackView(views: blocks)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = centered ? .centerX : .leading
        stack.spacing = centered ? 8 : 18
        // A footnote belongs to the group above it, and a heading to the group
        // below, so both sit closer than one group does to the next.
        for (index, block) in blocks.enumerated() {
            if block is SectionHeadingLabel {
                stack.setCustomSpacing(6, after: block)
            } else if index + 1 < blocks.count, blocks[index + 1] is WrappingLabel {
                stack.setCustomSpacing(6, after: block)
            }
            if !centered {
                block.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        if centered, let first = blocks.first {
            stack.setCustomSpacing(16, after: first)
        }
        return Page(key: key, content: stack, rows: rows)
    }

    private func groupBox(_ rows: [SettingsRowView]) -> NSView { GroupBoxView(rows: rows) }

    private func row(
        _ key: String, control: NSControl, trailing: NSView? = nil
    ) -> SettingsRowView {
        SettingsRowView(label: label(key), control: control, trailing: trailing ?? control)
    }

    private func recorder(for action: ShortcutAction) -> ShortcutRecorderField {
        let field = ShortcutRecorderField(kind: .appShortcut)
        field.widthAnchor.constraint(equalToConstant: 118).isActive = true
        field.defaultCombo = action.defaultCombo
        field.onRecordCombo = { [weak self] combo in self?.record(combo, for: action) }
        shortcutFields[action] = field
        return field
    }

    private func label(_ key: String) -> NSTextField {
        let field = NSTextField(labelWithString: L10n.text(key))
        field.lineBreakMode = .byTruncatingTail
        localizedLabels.append((field, key))
        return field
    }

    private func footnote(_ key: String) -> WrappingLabel {
        let field = WrappingLabel(text: L10n.text(key))
        field.font = .systemFont(ofSize: 12)
        field.textColor = .secondaryLabelColor
        localizedLabels.append((field, key))
        return field
    }

    private func sectionHeading(_ key: String) -> SectionHeadingLabel {
        let field = SectionHeadingLabel(text: L10n.text(key))
        sectionTitles.append((field, key))
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

    @objc private func preferencesChanged() {
        if !isApplying && !isDirty { refresh() }
    }

    private func refresh() {
        pendingHotKey = preferences.hotKey
        pendingShortcuts = preferences.shortcuts
        pendingFontFamily = preferences.fontFamily
        pendingCustomFontName = preferences.customFontName
        window?.title = L10n.text("Settings")
        for (field, key) in localizedLabels { field.stringValue = L10n.text(key) }
        for (field, key) in sectionTitles { field.stringValue = L10n.text(key) }
        for (index, row) in sidebarRows.enumerated() {
            let key = Self.pageSymbols[index].key
            row.title = L10n.text(key)
        }
        if pages.indices.contains(selectedPage) {
            pageTitleLabel.stringValue = L10n.text(pages[selectedPage].key)
        }
        versionLabel.stringValue = String(
            format: L10n.text("Version %@"), AppVersion.current
        )
        applyUpdateState()

        clearHotKeyButton.title = L10n.text("Clear")
        resetShortcutsButton.title = L10n.text("Reset to Defaults")
        saveButton.title = L10n.text("Save")
        // A switch has no title of its own, so its row's label is its name —
        // for VoiceOver and for the tests alike.
        for page in pages {
            for row in page.rows { row.control.setAccessibilityLabel(row.label.stringValue) }
        }
        sizeStepper.setAccessibilityLabel(L10n.text("Size"))

        fill(spacingPopUp, with: LineSpacingOption.allCases.map { ($0.title, $0.rawValue) },
             action: #selector(lineSpacingChanged))
        fill(paddingPopUp, with: EditorPaddingOption.allCases.map { ($0.title, $0.rawValue) },
             action: #selector(paddingChanged))
        fill(languagePopUp, with: AppLanguage.allCases.map { ($0.title, $0.rawValue) },
             action: #selector(languageChanged))
        fill(themePopUp, with: AppTheme.allCases.map { ($0.title, $0.rawValue) },
             action: #selector(themeChanged))
        fill(sidebarSidePopUp, with: SidebarSide.allCases.map { ($0.title, $0.rawValue) },
             action: #selector(sidebarSideChanged))

        rebuildFontMenu()

        let size = "\(Int(preferences.fontSize))"
        if sizeField.stringValue != size { sizeField.stringValue = size }
        sizeStepper.doubleValue = Double(preferences.fontSize)

        select(spacingPopUp, raw: preferences.lineSpacing.rawValue)
        select(paddingPopUp, raw: preferences.padding.rawValue)
        select(languagePopUp, raw: preferences.language.rawValue)
        select(themePopUp, raw: preferences.theme.rawValue)
        select(sidebarSidePopUp, raw: preferences.sidebarSide.rawValue)
        wordWrapSwitch.state = preferences.wrapsLines ? .on : .off
        lineNumbersSwitch.state = preferences.showsLineNumbers ? .on : .off
        gutterSeparatorSwitch.state = preferences.showsGutterSeparator ? .on : .off
        gutterSeparatorRow?.isEnabled = preferences.showsLineNumbers
        let enabled = Set(preferences.footerSegments)
        for (segment, control) in footerSwitches {
            control.state = enabled.contains(segment) ? .on : .off
        }
        footerEncodingSwitch.state = preferences.footerShowsEncoding ? .on : .off
        footerLineEndingsSwitch.state = preferences.footerShowsLineEndings ? .on : .off
        footerCursorSwitch.state = preferences.footerShowsCursorPosition ? .on : .off
        statusBarSwitch.state = preferences.showsStatusBar ? .on : .off
        setStatusDetailsEnabled(preferences.showsStatusBar)
        previewModeSwitch.state = preferences.opensMarkdownInReadingMode ? .on : .off
        vimModeSwitch.state = preferences.vimMode ? .on : .off
        showTabBarSwitch.state = preferences.hidesTabBar ? .off : .on
        autoHideTabBarSwitch.state = preferences.autoHidesTabBar ? .on : .off
        autoHideTabBarRow?.isEnabled = !preferences.hidesTabBar
        trafficLightsRow?.isEnabled = !preferences.hidesTabBar
        trafficLightsSwitch.state = preferences.hidesTrafficLights ? .off : .on
        bookmarkButtonSwitch.state = preferences.hidesBookmarkButton ? .off : .on
        settingsButtonSwitch.state = preferences.hidesSettingsButton ? .off : .on
        hotKeyField.shortcut = pendingHotKey

        let failed = (NSApp.delegate as? AppDelegate)?.hotKeyRegistrationFailed ?? false
        hotKeyWarning.stringValue = failed
            ? L10n.text("Another app is using that shortcut.")
            : ""
        hotKeyWarning.isHidden = !failed
        refreshShortcutFields()
        showShortcutConflict()
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
    @objc private func sidebarSideChanged(_ sender: NSPopUpButton) { markDirty() }
    @objc private func draftChanged(_ sender: Any?) { markDirty() }

    @objc private func clearHotKey() {
        pendingHotKey = nil
        hotKeyField.shortcut = nil
        markDirty()
    }

    /// A row that has been put back to the key it ships with is not an
    /// override at all, so it comes out of the draft rather than going in.
    private func record(_ combo: KeyCombo, for action: ShortcutAction) {
        pendingShortcuts[action] = combo == action.defaultCombo ? nil : combo
        markDirty()
    }

    @objc private func resetShortcuts() {
        pendingShortcuts = [:]
        refreshShortcutFields()
        markDirty()
    }

    // MARK: - Check for Updates

    /// The About page's one button. Nothing here is a draft — the check is
    /// not a setting, so it neither dirties the window nor waits for Save.
    @objc func checkForUpdates() {
        if case .checking = updateState { return }
        updateState = .checking
        applyUpdateState()
        let finish: (UpdateCheck.Result) -> Void = { [weak self] result in
            guard let self else { return }
            self.updateState = .done(result)
            self.applyUpdateState()
        }
        if let stub = updateCheckForTesting {
            stub(finish)
        } else {
            UpdateCheck.check(completion: finish)
        }
    }

    @objc private func openDownloadPage() {
        guard let updateURL, let url = URL(string: updateURL) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Draws whichever of the four states the check is in. Called again on
    /// every refresh so a language change re-words what is on screen.
    private func applyUpdateState() {
        checkUpdatesButton.title = L10n.text("Check for Updates")
        downloadUpdateButton.title = L10n.text("Download")
        brewCommandField.stringValue = UpdateCheck.homebrewUpgradeCommand
        checkUpdatesButton.isEnabled = true
        updateStatusLabel.isHidden = false
        downloadUpdateButton.isHidden = true
        brewCommandField.isHidden = true
        updateURL = nil

        switch updateState {
        case .idle:
            updateStatusLabel.stringValue = ""
            updateStatusLabel.isHidden = true
        case .checking:
            checkUpdatesButton.isEnabled = false
            updateStatusLabel.stringValue = L10n.text("Checking…")
        case let .done(result):
            switch result {
            case .upToDate:
                updateStatusLabel.stringValue = L10n.text("Nota is up to date.")
            case let .available(version, url):
                updateURL = url
                if isHomebrewCopy {
                    updateStatusLabel.stringValue = String(
                        format: L10n.text("Nota %@ is available. Update with:"), version
                    )
                    brewCommandField.isHidden = false
                } else {
                    updateStatusLabel.stringValue = String(
                        format: L10n.text("Nota %@ is available."), version
                    )
                    downloadUpdateButton.isHidden = url.isEmpty
                }
            case let .failed(reason):
                updateStatusLabel.stringValue = String(
                    format: L10n.text("Couldn't check for updates: %@"), reason.message
                )
            }
        }
    }

    private var isHomebrewCopy: Bool {
        homebrewOverrideForTesting ?? UpdateCheck.installedWithHomebrew
    }

    private func draftCombo(for action: ShortcutAction) -> KeyCombo {
        pendingShortcuts[action] ?? action.defaultCombo
    }

    private func refreshShortcutFields() {
        for (action, field) in shortcutFields {
            field.setAccessibilityLabel(action.title)
            field.combo = draftCombo(for: action)
        }
    }

    /// The first clash in the draft: two commands on one combination, or one
    /// sitting on a key the Mac has already spoken for. Nil when the draft is
    /// fit to save.
    private func shortcutConflict() -> String? {
        var owners: [KeyCombo: ShortcutAction] = [:]
        for action in ShortcutAction.allCases {
            let combo = draftCombo(for: action)
            if let reserved = ShortcutAction.reservedCombos.first(where: { $0.combo == combo }) {
                return String(
                    format: L10n.text("%1$@ is reserved for %2$@."),
                    combo.displayName, L10n.text(reserved.titleKey)
                )
            }
            if let owner = owners[combo] {
                return String(
                    format: L10n.text("%1$@ and %2$@ both use %3$@."),
                    owner.title, action.title, combo.displayName
                )
            }
            owners[combo] = action
        }
        return nil
    }

    /// Shows the clash, if there is one, and says whether Save has to wait.
    @discardableResult
    private func showShortcutConflict() -> Bool {
        let message = shortcutConflict()
        shortcutWarning.stringValue = message ?? ""
        shortcutWarning.isHidden = message == nil
        return message != nil
    }

    @objc private func lineNumbersDraftChanged(_ sender: NSSwitch) {
        gutterSeparatorRow?.isEnabled = sender.state == .on
        markDirty()
    }

    /// Turning the strip off outright takes auto-hide, and the traffic
    /// lights, with it: there is nothing left for the top edge to slide in,
    /// and the lights are already gone the way zen takes them.
    @objc private func showTabBarDraftChanged(_ sender: NSSwitch) {
        autoHideTabBarRow?.isEnabled = sender.state == .on
        trafficLightsRow?.isEnabled = sender.state == .on
        markDirty()
    }

    @objc private func statusBarDraftChanged(_ sender: NSSwitch) {
        setStatusDetailsEnabled(sender.state == .on)
        markDirty()
    }

    private func setStatusDetailsEnabled(_ enabled: Bool) {
        for row in statusDetailRows { row.isEnabled = enabled }
    }

    private func markDirty() {
        isDirty = true
        // Two commands on one key would leave one of them unreachable, so the
        // draft cannot be saved until the user picks a side.
        saveButton.isEnabled = !showShortcutConflict()
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
              let theme = rawValue(of: themePopUp, as: AppTheme.self),
              let sidebarSide = rawValue(of: sidebarSidePopUp, as: SidebarSide.self)
        else { return }

        let fontFamily = pendingFontFamily
        let customFontName = pendingCustomFontName
        let fontSize = Preferences.clampFontSize(CGFloat(sizeField.doubleValue))
        guard shortcutConflict() == nil else { return }
        let hotKey = pendingHotKey
        let segmentStates = Dictionary(uniqueKeysWithValues: footerSwitches.map {
            ($0.0, $0.1.state == .on)
        })

        isApplying = true
        preferences.customFontName = customFontName
        preferences.fontFamily = fontFamily
        preferences.fontSize = fontSize
        preferences.lineSpacing = spacing
        preferences.padding = padding
        preferences.wrapsLines = wordWrapSwitch.state == .on
        preferences.showsLineNumbers = lineNumbersSwitch.state == .on
        preferences.showsGutterSeparator = gutterSeparatorSwitch.state == .on
        preferences.opensMarkdownInReadingMode = previewModeSwitch.state == .on
        preferences.showsStatusBar = statusBarSwitch.state == .on
        preferences.footerShowsWords = segmentStates[.words] ?? false
        preferences.footerShowsCharacters = segmentStates[.characters] ?? false
        preferences.footerShowsImages = segmentStates[.images] ?? false
        preferences.footerShowsLines = segmentStates[.lines] ?? false
        preferences.footerShowsEncoding = footerEncodingSwitch.state == .on
        preferences.footerShowsLineEndings = footerLineEndingsSwitch.state == .on
        preferences.footerShowsCursorPosition = footerCursorSwitch.state == .on
        preferences.vimMode = vimModeSwitch.state == .on
        preferences.hidesTabBar = showTabBarSwitch.state == .off
        preferences.autoHidesTabBar = autoHideTabBarSwitch.state == .on
        preferences.hidesTrafficLights = trafficLightsSwitch.state == .off
        preferences.hidesBookmarkButton = bookmarkButtonSwitch.state == .off
        preferences.hidesSettingsButton = settingsButtonSwitch.state == .off
        preferences.hotKey = hotKey
        preferences.shortcuts = pendingShortcuts
        preferences.language = language
        preferences.theme = theme
        preferences.sidebarSide = sidebarSide
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

// MARK: - The pieces the pages are made of

/// The document view of the page's scroller. Flipped so a short page sits at
/// the top of the scroller rather than the bottom.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// One row of a group: a label on the left, its control on the right edge.
private final class SettingsRowView: NSView {
    let label: NSTextField
    let control: NSControl

    /// Greys the label with the control, so a row switched off by another row
    /// reads as off rather than merely unresponsive.
    var isEnabled = true {
        didSet {
            control.isEnabled = isEnabled
            label.textColor = isEnabled ? .labelColor : .tertiaryLabelColor
        }
    }

    init(label: NSTextField, control: NSControl, trailing: NSView) {
        self.label = label
        self.control = control
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        trailing.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(trailing)

        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailing.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.leadingAnchor.constraint(
                greaterThanOrEqualTo: label.trailingAnchor, constant: 12
            ),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// The inset group System Settings puts its rows in: a rounded card with a
/// hairline between one row and the next.
private final class GroupBoxView: NSView {
    init(rows: [SettingsRowView]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        var previous: NSView?
        for row in rows {
            addSubview(row)
            if let previous {
                let line = HairlineView()
                addSubview(line)
                NSLayoutConstraint.activate([
                    line.topAnchor.constraint(equalTo: previous.bottomAnchor),
                    line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                    line.trailingAnchor.constraint(equalTo: trailingAnchor),
                    line.heightAnchor.constraint(equalToConstant: 1),
                    row.topAnchor.constraint(equalTo: line.bottomAnchor),
                ])
            } else {
                row.topAnchor.constraint(equalTo: topAnchor).isActive = true
            }
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: leadingAnchor),
                row.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            previous = row
        }
        previous?.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

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
}

/// The line between two rows of a group.
private final class HairlineView: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// One row of the source list: an accent-coloured symbol and a title, filled
/// with the accent colour when it is the page on screen.
private final class SettingsSidebarRow: NSView {
    private let symbolView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    var onSelect: (() -> Void)?

    var title: String {
        get { titleField.stringValue }
        set {
            titleField.stringValue = newValue
            setAccessibilityLabel(newValue)
        }
    }

    var isSelected = false {
        didSet {
            applyTint()
            needsDisplay = true
        }
    }

    init(symbol: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous

        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        symbolView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 13, weight: .medium
        )
        symbolView.imageScaling = .scaleProportionallyDown
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 13)
        titleField.lineBreakMode = .byTruncatingTail
        addSubview(symbolView)
        addSubview(titleField)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            symbolView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 18),
            titleField.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: 7),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityRole(.button)
        applyTint()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func applyTint() {
        symbolView.contentTintColor = isSelected ? .white : .controlAccentColor
        titleField.textColor = isSelected ? .white : .labelColor
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isSelected
                ? NSColor.controlAccentColor.cgColor
                : NSColor.clear.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// A label that wraps to whatever width it is given — the explanatory lines
/// under a group, and the red warnings.
private class WrappingLabel: NSTextField {
    init(text: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = .systemFont(ofSize: 12)
        textColor = .secondaryLabelColor
        lineBreakMode = .byWordWrapping
        maximumNumberOfLines = 0
        stringValue = text
        // A footnote takes the width it is given and wraps to it. Left at the
        // default priority, one long line would hold the whole window open at
        // the width of its single line instead.
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        if preferredMaxLayoutWidth != bounds.width {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
        super.layout()
    }
}

/// The small caption over a group of shortcut rows.
private final class SectionHeadingLabel: WrappingLabel {
    override init(text: String) {
        super.init(text: text)
        font = .systemFont(ofSize: 12, weight: .semibold)
        textColor = .secondaryLabelColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// The one colour the redesign adds: the fill of an inset group. Light mode
/// gets the card white that sits over the window's grey; dark mode gets a
/// touch of white over the window instead, because the control background
/// there is darker than the window and would read as a hole.
private enum SettingsPalette {
    static let groupFill = NSColor(name: "notaSettingsGroupFill") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.06)
            : .controlBackgroundColor
    }
}
