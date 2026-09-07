import AppKit

/// Settings, in the shape macOS System Settings uses: a source list of pages
/// down the left, under the traffic lights, and one page at a time on the
/// right with its controls in inset rounded groups.
///
/// Nothing is staged and there is no Save button: every control writes its own
/// preference the moment it changes, and the app follows at once. A change that
/// re-words the dialog itself — language, theme — rebuilds it afterwards, so
/// the new wording is visible without closing the window.
///
/// The one refusal is a shortcut clash: a combination already spoken for is
/// not written at all. The field snaps back to the stored key and the page says
/// why, since a key applied live would leave one of two commands unreachable.
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
    private let highlightCurrentLineSwitch = NSSwitch()
    private let vimModeSwitch = NSSwitch()
    private let previewModeSwitch = NSSwitch()
    private let statusBarSwitch = NSSwitch()
    private let showTabBarSwitch = NSSwitch()
    private let autoHideTabBarSwitch = NSSwitch()
    private let trafficLightsSwitch = NSSwitch()
    private let bookmarkToggleButtonSwitch = NSSwitch()
    private let bookmarkButtonSwitch = NSSwitch()
    private let settingsButtonSwitch = NSSwitch()
    private let footerSwitches: [(TextStats.Segment, NSSwitch)] = [
        (.words, NSSwitch()),
        (.characters, NSSwitch()),
        (.images, NSSwitch()),
        (.lines, NSSwitch()),
    ]
    private let footerFormatSwitch = NSSwitch()
    private let footerEncodingSwitch = NSSwitch()
    private let footerLineEndingsSwitch = NSSwitch()
    private let footerCursorSwitch = NSSwitch()
    private let hotKeyField = ShortcutRecorderField()
    private let hotKeyWarning = WrappingLabel(text: "")
    private let clearHotKeyButton = NSButton()
    private let resetShortcutsButton = NSButton()
    private let shortcutWarning = WrappingLabel(text: "")
    private let versionLabel = WrappingLabel(text: "")
    private let checkUpdatesButton = NSButton()
    // Not a `WrappingLabel`: the About page centres its blocks rather than
    // stretching them, so a label that takes whatever width it is given is
    // given none and folds to a word a line. This one wraps at a width of
    // its own and hugs the result.
    private let updateStatusLabel = NSTextField(wrappingLabelWithString: "")
    /// The `?` buttons and the sentence each one explains; one popover serves them all.
    private var helpTexts: [ObjectIdentifier: String] = [:]
    private let helpPopover = NSPopover()
    private weak var summonHelpButton: NSButton?
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
    /// True while a control is writing its own preference, so the change
    /// notification that comes straight back does not rebuild the dialog
    /// underneath the control the user is still holding.
    private var isApplying = false

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
    var summonHelpForTesting: (button: NSButton?, popover: NSPopover) {
        (summonHelpButton, helpPopover)
    }

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
            // Nothing under the pages any more, so the page area runs to the
            // bottom edge with the air a group would have had below it.
            scroll.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -18),

            pageHost.topAnchor.constraint(equalTo: clip.topAnchor),
            pageHost.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            pageHost.widthAnchor.constraint(equalTo: clip.widthAnchor),
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

        for control in [wordWrapSwitch, gutterSeparatorSwitch, highlightCurrentLineSwitch,
                        vimModeSwitch] {
            control.target = self
            control.action = #selector(editorSwitchChanged)
        }
        previewModeSwitch.target = self
        previewModeSwitch.action = #selector(previewSwitchChanged)
        for control in [autoHideTabBarSwitch, trafficLightsSwitch,
                        bookmarkToggleButtonSwitch, bookmarkButtonSwitch,
                        settingsButtonSwitch] {
            control.target = self
            control.action = #selector(tabBarSwitchChanged)
        }
        for (_, control) in footerSwitches {
            control.target = self
            control.action = #selector(footerSwitchChanged)
        }
        for control in [footerFormatSwitch, footerEncodingSwitch,
                        footerLineEndingsSwitch, footerCursorSwitch] {
            control.target = self
            control.action = #selector(footerSwitchChanged)
        }
        lineNumbersSwitch.target = self
        lineNumbersSwitch.action = #selector(lineNumbersChanged)
        showTabBarSwitch.target = self
        showTabBarSwitch.action = #selector(showTabBarChanged)
        statusBarSwitch.target = self
        statusBarSwitch.action = #selector(statusBarChanged)

        hotKeyField.onRecord = { [weak self] shortcut in
            self?.applyHotKey(shortcut)
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
            blocks: [groupBox(rows)],
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
            row("Highlight current line", control: highlightCurrentLineSwitch),
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
            row("Bookmark button", control: bookmarkToggleButtonSwitch),
            row("Bookmark dialog button", control: bookmarkButtonSwitch),
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
        regions.append(row("Format", control: footerFormatSwitch))
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

        let summon = row("Summon", control: hotKeyField, trailing: hotKeyStack,
                         help: "Summon brings Nota to the front from any app, even while it is hidden.")
        summonHelpButton = summon.accessory as? NSButton
        // Settings… shares the top group with Summon: a group of its own
        // would be headed "Nota", which reads as nothing on a Nota page.
        let settings = row(ShortcutAction.settings.titleKey, control: recorder(for: .settings))
        var blocks: [NSView] = [
            groupBox([summon, settings]),
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

        updateStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        updateStatusLabel.isSelectable = false
        updateStatusLabel.font = .systemFont(ofSize: 12)
        updateStatusLabel.textColor = .secondaryLabelColor
        updateStatusLabel.alignment = .center
        updateStatusLabel.preferredMaxLayoutWidth = 360
        brewCommandField.alignment = .center

        let about = page(
            "About",
            blocks: [icon, name, versionLabel,
                     checkUpdatesButton, updateStatusLabel, brewCommandField,
                     downloadUpdateButton],
            rows: [], centered: true
        )
        // The button starts a block of its own under the version.
        (about.content as? NSStackView)?.setCustomSpacing(20, after: versionLabel)
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

    /// `help` is a sentence the row would otherwise carry as a footnote; it
    /// goes behind a `?` after the label instead, shown in a popover on a click.
    private func row(
        _ key: String, control: NSControl, trailing: NSView? = nil, help: String? = nil
    ) -> SettingsRowView {
        SettingsRowView(label: label(key), control: control, trailing: trailing ?? control,
                        accessory: help.map { helpButton(explaining: $0) })
    }

    private func helpButton(explaining key: String) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(showHelp(_:)))
        button.bezelStyle = .helpButton
        button.controlSize = .small
        button.toolTip = nil
        button.setAccessibilityLabel(L10n.text(key))
        helpTexts[ObjectIdentifier(button)] = key
        return button
    }

    /// One popover for every `?`, transient, so a click anywhere else closes it.
    @objc private func showHelp(_ sender: NSButton) {
        guard let key = helpTexts[ObjectIdentifier(sender)] else { return }
        if helpPopover.isShown { helpPopover.performClose(nil) }
        // Measured by hand and handed to the popover as a fixed size: a
        // wrapping label left to Auto Layout inside a popover gets no width
        // and folds to nothing, as it did the first evening.
        let text = NSTextField(wrappingLabelWithString: L10n.text(key))
        text.isSelectable = false
        text.font = .systemFont(ofSize: 12)
        text.textColor = .labelColor
        text.preferredMaxLayoutWidth = 280
        let inset = NSSize(width: 14, height: 12)
        let measured = text.sizeThatFits(NSSize(width: 280, height: CGFloat.greatestFiniteMagnitude))
        let size = NSSize(width: ceil(measured.width), height: ceil(measured.height))
        text.frame = NSRect(origin: NSPoint(x: inset.width, y: inset.height), size: size)
        let content = NSView(frame: NSRect(
            x: 0, y: 0, width: size.width + inset.width * 2, height: size.height + inset.height * 2
        ))
        content.addSubview(text)
        let controller = NSViewController()
        controller.view = content
        controller.preferredContentSize = content.frame.size
        helpPopover.contentViewController = controller
        helpPopover.behavior = .transient
        helpPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
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
        if !isApplying { refresh() }
    }

    private func refresh() {
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
        highlightCurrentLineSwitch.state = preferences.highlightsCurrentLine ? .on : .off
        let enabled = Set(preferences.footerSegments)
        for (segment, control) in footerSwitches {
            control.state = enabled.contains(segment) ? .on : .off
        }
        footerFormatSwitch.state = preferences.footerShowsFormat ? .on : .off
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
        bookmarkToggleButtonSwitch.state = preferences.hidesBookmarkToggleButton ? .off : .on
        bookmarkButtonSwitch.state = preferences.hidesBookmarkButton ? .off : .on
        settingsButtonSwitch.state = preferences.hidesSettingsButton ? .off : .on
        hotKeyField.shortcut = preferences.hotKey

        let failed = (NSApp.delegate as? AppDelegate)?.hotKeyRegistrationFailed ?? false
        hotKeyWarning.stringValue = failed
            ? L10n.text("Another app is using that shortcut.")
            : ""
        hotKeyWarning.isHidden = !failed
        refreshShortcutFields()
        // What is stored never clashes — a clash is refused rather than
        // written — so the fields the refresh just filled have nothing to warn
        // about.
        clearShortcutWarning()
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

    /// Writes preferences without the change notification turning round and
    /// rebuilding the dialog under the control that is still being held.
    private func apply(_ changes: () -> Void) {
        isApplying = true
        changes()
        isApplying = false
    }

    @objc private func fontFamilyChanged(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem else { return }
        switch item.tag {
        case Tag.otherFont:
            presentFontPanel()
        case Tag.customFont:
            apply { preferences.fontFamily = .custom }
        default:
            if let raw = item.representedObject as? String,
               let family = EditorFontFamily(rawValue: raw) {
                apply { preferences.fontFamily = family }
            }
        }
    }

    /// Return in the field, or the focus leaving it, is the size the user
    /// meant — clamped to what the editor will take.
    @objc private func sizeFieldChanged(_ sender: NSTextField) {
        let size = Preferences.clampFontSize(CGFloat(sender.doubleValue))
        sender.stringValue = "\(Int(size))"
        sizeStepper.doubleValue = Double(size)
        apply { preferences.fontSize = size }
    }

    @objc private func sizeStepperChanged(_ sender: NSStepper) {
        let size = Preferences.clampFontSize(CGFloat(sender.doubleValue))
        sizeField.stringValue = "\(Int(size))"
        apply { preferences.fontSize = size }
    }

    @objc private func lineSpacingChanged(_ sender: NSPopUpButton) {
        guard let spacing = rawValue(of: sender, as: LineSpacingOption.self) else { return }
        apply { preferences.lineSpacing = spacing }
    }

    @objc private func paddingChanged(_ sender: NSPopUpButton) {
        guard let padding = rawValue(of: sender, as: EditorPaddingOption.self) else { return }
        apply { preferences.padding = padding }
    }

    /// Language and theme are the two that re-word the dialog itself, so both
    /// rebuild it once the preference is written.
    @objc private func languageChanged(_ sender: NSPopUpButton) {
        guard let language = rawValue(of: sender, as: AppLanguage.self) else { return }
        apply { preferences.language = language }
        refresh()
    }

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        guard let theme = rawValue(of: sender, as: AppTheme.self) else { return }
        apply { preferences.theme = theme }
        refresh()
    }

    @objc private func sidebarSideChanged(_ sender: NSPopUpButton) {
        guard let side = rawValue(of: sender, as: SidebarSide.self) else { return }
        apply { preferences.sidebarSide = side }
    }

    @objc private func editorSwitchChanged(_ sender: Any?) {
        apply {
            preferences.wrapsLines = wordWrapSwitch.state == .on
            preferences.showsLineNumbers = lineNumbersSwitch.state == .on
            preferences.showsGutterSeparator = gutterSeparatorSwitch.state == .on
            preferences.highlightsCurrentLine = highlightCurrentLineSwitch.state == .on
            preferences.vimMode = vimModeSwitch.state == .on
        }
    }

    @objc private func previewSwitchChanged(_ sender: Any?) {
        apply { preferences.opensMarkdownInReadingMode = previewModeSwitch.state == .on }
    }

    /// The four positive labels: off is what hides the piece of chrome each
    /// one names.
    @objc private func tabBarSwitchChanged(_ sender: Any?) {
        apply {
            preferences.hidesTabBar = showTabBarSwitch.state == .off
            preferences.autoHidesTabBar = autoHideTabBarSwitch.state == .on
            preferences.hidesTrafficLights = trafficLightsSwitch.state == .off
            preferences.hidesBookmarkToggleButton = bookmarkToggleButtonSwitch.state == .off
            preferences.hidesBookmarkButton = bookmarkButtonSwitch.state == .off
            preferences.hidesSettingsButton = settingsButtonSwitch.state == .off
        }
    }

    /// The status bar's regions go together: which counts it shows, and the
    /// three readings at its trailing edge.
    @objc private func footerSwitchChanged(_ sender: Any?) {
        apply {
            let states = Dictionary(uniqueKeysWithValues: footerSwitches.map {
                ($0.0, $0.1.state == .on)
            })
            preferences.showsStatusBar = statusBarSwitch.state == .on
            preferences.footerShowsWords = states[.words] ?? false
            preferences.footerShowsCharacters = states[.characters] ?? false
            preferences.footerShowsImages = states[.images] ?? false
            preferences.footerShowsLines = states[.lines] ?? false
            preferences.footerShowsFormat = footerFormatSwitch.state == .on
            preferences.footerShowsEncoding = footerEncodingSwitch.state == .on
            preferences.footerShowsLineEndings = footerLineEndingsSwitch.state == .on
            preferences.footerShowsCursorPosition = footerCursorSwitch.state == .on
        }
    }

    /// Recorded and registered at once; the rebuild afterwards is what puts up
    /// the warning if the Mac would not give Nota the combination.
    private func applyHotKey(_ shortcut: GlobalHotKey.Shortcut?) {
        apply { preferences.hotKey = shortcut }
        refresh()
    }

    @objc private func clearHotKey() {
        hotKeyField.shortcut = nil
        applyHotKey(nil)
    }

    /// A row put back to the key it ships with is not an override at all, so
    /// it comes out of the table rather than going into it.
    ///
    /// A combination already spoken for is refused: nothing is written, the
    /// field goes back to the key that is stored, and the page says which two
    /// commands would have shared it. Live apply is why — a clash written
    /// through would leave one of the two unreachable in the menu.
    private func record(_ combo: KeyCombo, for action: ShortcutAction) {
        var table = preferences.shortcuts
        table[action] = combo == action.defaultCombo ? nil : combo
        if let clash = shortcutConflict(in: table) {
            shortcutWarning.stringValue = clash
            shortcutWarning.isHidden = false
            shortcutFields[action]?.combo = preferences.combo(for: action)
            return
        }
        apply { preferences.shortcuts = table }
        clearShortcutWarning()
    }

    @objc private func resetShortcuts() {
        apply { preferences.shortcuts = [:] }
        refreshShortcutFields()
        clearShortcutWarning()
    }

    // MARK: - Check for Updates

    /// The About page's one button. The check is not a setting, so nothing
    /// here is written and nothing on the page is rebuilt but its own lines.
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

    private func refreshShortcutFields() {
        for (action, field) in shortcutFields {
            field.setAccessibilityLabel(action.title)
            field.combo = preferences.combo(for: action)
        }
    }

    /// The first clash in a table: two commands on one combination, or one
    /// sitting on a key the Mac has already spoken for. Nil when the table is
    /// fit to write.
    private func shortcutConflict(in table: [ShortcutAction: KeyCombo]) -> String? {
        var owners: [KeyCombo: ShortcutAction] = [:]
        for action in ShortcutAction.allCases {
            let combo = table[action] ?? action.defaultCombo
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

    /// Takes the clash line away: the next key that lands somewhere free ends
    /// the refusal, whichever row recorded it.
    private func clearShortcutWarning() {
        shortcutWarning.stringValue = ""
        shortcutWarning.isHidden = true
    }

    @objc private func lineNumbersChanged(_ sender: NSSwitch) {
        gutterSeparatorRow?.isEnabled = sender.state == .on
        editorSwitchChanged(sender)
    }

    /// Turning the strip off outright takes auto-hide, and the traffic
    /// lights, with it: there is nothing left for the top edge to slide in,
    /// and the lights are already gone the way zen takes them.
    @objc private func showTabBarChanged(_ sender: NSSwitch) {
        autoHideTabBarRow?.isEnabled = sender.state == .on
        trafficLightsRow?.isEnabled = sender.state == .on
        tabBarSwitchChanged(sender)
    }

    @objc private func statusBarChanged(_ sender: NSSwitch) {
        setStatusDetailsEnabled(sender.state == .on)
        footerSwitchChanged(sender)
    }

    private func setStatusDetailsEnabled(_ enabled: Bool) {
        for row in statusDetailRows { row.isEnabled = enabled }
    }

    private func rawValue<T: RawRepresentable>(of popUp: NSPopUpButton, as type: T.Type) -> T?
    where T.RawValue == String {
        guard let raw = popUp.selectedItem?.representedObject as? String else { return nil }
        return T(rawValue: raw)
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
        // Family and name are one edit, so the panel's pick lands as one
        // change; the popup then names the font it just took.
        apply { preferences.selectCustomFont(familyName: family) }
        rebuildFontMenu()
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
    /// What follows the label, if anything — the `?` a row's help sits behind.
    let accessory: NSView?

    /// Greys the label with the control, so a row switched off by another row
    /// reads as off rather than merely unresponsive.
    var isEnabled = true {
        didSet {
            control.isEnabled = isEnabled
            label.textColor = isEnabled ? .labelColor : .tertiaryLabelColor
        }
    }

    init(label: NSTextField, control: NSControl, trailing: NSView, accessory: NSView? = nil) {
        self.label = label
        self.control = control
        self.accessory = accessory
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        trailing.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(trailing)
        let afterLabel: NSView
        if let accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            addSubview(accessory)
            accessory.setContentHuggingPriority(.required, for: .horizontal)
            accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            NSLayoutConstraint.activate([
                accessory.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
                accessory.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            afterLabel = accessory
        } else {
            afterLabel = label
        }

        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailing.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.leadingAnchor.constraint(
                greaterThanOrEqualTo: afterLabel.trailingAnchor, constant: 12
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
