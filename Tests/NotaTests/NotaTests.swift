import AppKit
import Foundation
import XCTest
@testable import Nota

final class NotaTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    func testNextUntitledNamePicksLowestFreeNumber() {
        XCTAssertEqual(UntitledNaming.nextName(existing: []), "Untitled")
        XCTAssertEqual(UntitledNaming.nextName(existing: ["Untitled"]), "Untitled 2")
        XCTAssertEqual(
            UntitledNaming.nextName(existing: ["Untitled", "Untitled 2", "Untitled 3"]),
            "Untitled 4"
        )
        // Gaps are reused, and saved notes never block a number.
        XCTAssertEqual(
            UntitledNaming.nextName(existing: ["Untitled", "Untitled 3", "shopping"]),
            "Untitled 2"
        )
    }

    func testWordAndCharacterCounts() {
        XCTAssertEqual(TextStats.wordCount(""), 0)
        XCTAssertEqual(TextStats.characterCount(""), 0)
        XCTAssertEqual(TextStats.wordCount("  hello   world \n\n again  "), 3)
        XCTAssertEqual(TextStats.characterCount("héllo"), 5)
        XCTAssertEqual(TextStats.counts("one two"), "2 words · 7 characters")
        XCTAssertEqual(TextStats.counts("a"), "1 word · 1 character")
        XCTAssertEqual(TextStats.pointSize(13), "13 pt")
    }

    func testSuggestedFileNameFromFirstLine() {
        XCTAssertEqual(SuggestedName.from(text: ""), "Untitled")
        XCTAssertEqual(SuggestedName.from(text: "\n\n"), "Untitled")
        XCTAssertEqual(SuggestedName.from(text: "  Grocery list  \nmilk"), "Grocery list")
        XCTAssertEqual(SuggestedName.from(text: "a/b:c"), "a-b-c")
        XCTAssertEqual(SuggestedName.from(text: String(repeating: "x", count: 100)).count, 40)
    }

    func testSessionRoundTripsThroughDisk() throws {
        let directory = try makeTemporaryDirectory()
        let first = UUID()
        let second = UUID()

        let state = SessionState(
            tabs: [
                SessionTab(id: first, path: "/tmp/notes.txt", untitledName: nil,
                           isDirty: true, selection: 12),
                SessionTab(id: second, path: nil, untitledName: "Untitled 2",
                           isDirty: false, selection: 0),
            ],
            selectedTabID: second,
            fontSize: 16
        )

        do {
            let store = SessionStore(directory: directory)
            store.save(state)
            store.writeText("hello", for: first)
            store.writeText("", for: second)
        }

        let reopened = SessionStore(directory: directory)
        XCTAssertEqual(reopened.load(), state)
        XCTAssertEqual(reopened.readText(for: first), "hello")
        XCTAssertEqual(reopened.readText(for: second), "")

        // Cache files for tabs that went away are cleaned up.
        reopened.pruneCache(keeping: [first])
        XCTAssertEqual(reopened.readText(for: first), "hello")
        XCTAssertNil(reopened.readText(for: second))
    }

    func testPreferencesDefaultsAndDerivedValues() throws {
        let suite = "NotaTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)

        XCTAssertEqual(preferences.fontFamily, .system)
        XCTAssertEqual(preferences.fontSize, 13)
        XCTAssertEqual(preferences.lineSpacing, .normal)
        XCTAssertEqual(preferences.padding, .normal)
        XCTAssertEqual(preferences.fontDisplayName, "System")
        // Line numbers are on unless explicitly turned off.
        XCTAssertTrue(preferences.showsLineNumbers)
        preferences.showsLineNumbers = false
        XCTAssertFalse(preferences.showsLineNumbers)
        XCTAssertFalse(Preferences(defaults: defaults).showsLineNumbers)
        preferences.showsLineNumbers = true
        XCTAssertTrue(preferences.showsLineNumbers)

        // Long lines fold until you say otherwise.
        XCTAssertTrue(preferences.wrapsLines)
        preferences.wrapsLines = false
        XCTAssertFalse(preferences.wrapsLines)
        XCTAssertFalse(Preferences(defaults: defaults).wrapsLines)
        preferences.wrapsLines = true
        XCTAssertTrue(Preferences(defaults: defaults).wrapsLines)

        // The summon shortcut defaults to ⌥Space, is recordable, and can be
        // cleared to nothing without falling back to the default again.
        XCTAssertEqual(preferences.hotKey, .optionSpace)
        XCTAssertEqual(GlobalHotKey.Shortcut.optionSpace.displayName, "⌥Space")
        preferences.hotKey = GlobalHotKey.Shortcut(
            keyCode: 0x0B, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue
        )
        XCTAssertEqual(preferences.hotKey?.displayName, "⇧⌘B")
        XCTAssertEqual(Preferences(defaults: defaults).hotKey?.keyCode, 0x0B)
        preferences.hotKey = nil
        XCTAssertNil(preferences.hotKey)
        XCTAssertNil(Preferences(defaults: defaults).hotKey)

        // The sidebar sits on the right until told otherwise.
        XCTAssertEqual(preferences.sidebarSide, .right)
        XCTAssertEqual(SidebarSide.left.title, "Left")
        preferences.sidebarSide = .left
        XCTAssertEqual(Preferences(defaults: defaults).sidebarSide, .left)

        // The save panel remembers where you last saved.
        XCTAssertNil(preferences.lastSaveDirectory)
        preferences.lastSaveDirectory = URL(fileURLWithPath: "/tmp/notes", isDirectory: true)
        XCTAssertEqual(Preferences(defaults: defaults).lastSaveDirectory?.path, "/tmp/notes")

        XCTAssertEqual(LineSpacingOption.tight.multiple, 1.15)
        XCTAssertEqual(LineSpacingOption.relaxed.multiple, 1.5)
        XCTAssertEqual(EditorPaddingOption.compact.inset, 12)
        XCTAssertEqual(EditorPaddingOption.wide.inset, 40)

        // Sizes are clamped and rounded on the way in.
        preferences.fontSize = 200
        XCTAssertEqual(preferences.fontSize, 48)
        preferences.fontSize = 1
        XCTAssertEqual(preferences.fontSize, 9)
        preferences.fontSize = 17.4
        XCTAssertEqual(preferences.fontSize, 17)
        XCTAssertEqual(preferences.font().pointSize, 17)

        preferences.lineSpacing = .relaxed
        XCTAssertEqual(preferences.paragraphStyle().lineHeightMultiple, 1.5)

        // Picking a font switches family and name together.
        preferences.selectCustomFont(familyName: "Helvetica")
        XCTAssertEqual(preferences.fontFamily, .custom)
        XCTAssertEqual(preferences.fontDisplayName, "Helvetica")
        XCTAssertEqual(preferences.font().familyName, "Helvetica")

        // Settings survive a fresh reader over the same defaults.
        XCTAssertEqual(Preferences(defaults: defaults).fontSize, 17)
    }

    @MainActor
    func testSettingsWindowBuildsItsControls() {
        _ = NSApplication.shared
        let controller = SettingsWindowController.shared
        let window = controller.window
        defer { controller.selectPage(at: 0) }

        XCTAssertEqual(window?.title, "Settings")
        XCTAssertFalse(window?.isReleasedWhenClosed ?? true)
        // The sidebar runs to the top of the window with the traffic lights
        // over it, so the titlebar is glass and the title is not drawn there.
        XCTAssertTrue(window?.styleMask.contains(.fullSizeContentView) ?? false)
        XCTAssertTrue(window?.titlebarAppearsTransparent ?? false)
        XCTAssertEqual(window?.titleVisibility, .hidden)

        XCTAssertEqual(
            controller.pageTitles,
            ["General", "Appearance", "Editor", "Preview", "Tab bar", "Status bar",
             "Shortcuts", "About"]
        )

        func allViews(in root: NSView) -> [NSView] {
            [root] + root.subviews.flatMap(allViews)
        }
        func views() -> [NSView] { window?.contentView.map(allViews) ?? [] }

        // Every on/off row is a label beside an NSSwitch now, so the row's own
        // label is what names it.
        func titles(on page: Int) -> [String] {
            controller.rows(on: page).map(\.title)
        }
        XCTAssertEqual(titles(on: 0), ["Language", "Theme"])
        XCTAssertEqual(titles(on: 1), ["Font", "Size", "Line spacing", "Padding"])
        XCTAssertEqual(titles(on: 2), ["Word wrap", "Line numbers", "Gutter separator", "Vim mode"])
        XCTAssertEqual(titles(on: 3), ["Start supported files in preview mode"])
        XCTAssertEqual(titles(on: 4), ["Show tab bar", "Auto-hide tab bar", "Traffic lights",
                                       "Bookmark button", "Settings button"])
        XCTAssertEqual(titles(on: 5), ["Show status bar", "Words", "Characters", "Images", "Lines",
                                       "Text encoding", "Line endings", "Cursor position"])
        for page in [2, 3, 4, 5] {
            for row in controller.rows(on: page) {
                XCTAssertTrue(row.control is NSSwitch, "\(row.title) is not a switch")
            }
        }

        // Every page lays out on its own: nothing ambiguous, and the rows
        // inside a group have real height.
        for page in 0..<controller.pageTitles.count {
            controller.selectPage(at: page)
            let root = window?.contentView
            root?.layoutSubtreeIfNeeded()
            XCTAssertFalse(root?.hasAmbiguousLayout ?? true, "page \(page) is ambiguous")
            for row in controller.rows(on: page) {
                XCTAssertGreaterThan(row.control.superview?.frame.height ?? 0, 0,
                                     "\(row.title) has no row")
            }
        }

        // Font popup offers the four designs plus "Other…".
        controller.selectPage(at: 1)
        let fontPopUp = views().compactMap { $0 as? NSPopUpButton }.first {
            $0.itemTitles.contains("Other…")
        }
        XCTAssertEqual(
            fontPopUp?.itemTitles.filter { !$0.isEmpty },
            ["System", "Serif", "Rounded", "Monospaced", "Other…"]
        )

        controller.selectPage(at: 0)
        XCTAssertTrue(
            views().compactMap { ($0 as? NSButton)?.title }.contains("Save"),
            "Save is outside the pages, shared by all of them"
        )

        let language = views().compactMap { $0 as? NSPopUpButton }.first {
            $0.itemTitles.contains("简体中文")
        }
        XCTAssertEqual(language?.itemTitles, ["System Default", "English", "简体中文"])

        let theme = views().compactMap { $0 as? NSPopUpButton }.first {
            $0.itemTitles.contains("Dark")
        }
        XCTAssertEqual(theme?.itemTitles, ["System Default", "Light", "Dark"])
    }

    /// The five window-chrome switches are draft like everything else: nothing
    /// is written until Save, and then all five go together.
    @MainActor
    func testSavingAWindowChromeDraftWritesEveryToggle() throws {
        _ = NSApplication.shared
        let preferences = Preferences.shared
        let original = (preferences.hidesTabBar, preferences.hidesTrafficLights,
                        preferences.hidesBookmarkButton, preferences.hidesSettingsButton,
                        preferences.autoHidesTabBar)
        defer {
            preferences.hidesTabBar = original.0
            preferences.hidesTrafficLights = original.1
            preferences.hidesBookmarkButton = original.2
            preferences.hidesSettingsButton = original.3
            preferences.autoHidesTabBar = original.4
        }
        preferences.hidesTabBar = false
        preferences.hidesTrafficLights = false
        preferences.hidesBookmarkButton = false
        preferences.hidesSettingsButton = false
        preferences.autoHidesTabBar = false

        let controller = SettingsWindowController.shared
        defer { controller.selectPage(at: 0) }
        XCTAssertTrue(controller.selectPage(titled: "Tab bar"))
        let root = try XCTUnwrap(controller.window?.contentView)
        func allViews(in view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(allViews)
        }
        let save = try XCTUnwrap(allViews(in: root).compactMap { $0 as? NSButton }
            .first { $0.title == "Save" })
        XCTAssertFalse(save.isEnabled, "a fresh draft has nothing to save")

        // Auto-hide first: switching "Show tab bar" off greys its row, and a
        // row that is greyed is one the reader cannot reach either. The other
        // three switches wear positive labels now, so turning them off is
        // what hides the piece of chrome they name.
        let chrome: [(title: String, state: NSControl.StateValue)] = [
            ("Auto-hide tab bar", .on),
            ("Show tab bar", .off),
            ("Traffic lights", .off),
            ("Bookmark button", .off),
            ("Settings button", .off),
        ]
        for (title, state) in chrome {
            let control = try XCTUnwrap(
                controller.rows(on: 4).first { $0.title == title }?.control as? NSSwitch
            )
            control.state = state
            _ = NSApp.sendAction(try XCTUnwrap(control.action), to: control.target, from: control)
        }
        XCTAssertTrue(save.isEnabled)
        XCTAssertFalse(preferences.hidesTabBar, "nothing is written until Save")

        save.performClick(nil)
        XCTAssertTrue(preferences.hidesTabBar)
        XCTAssertTrue(preferences.autoHidesTabBar)
        XCTAssertTrue(preferences.hidesTrafficLights)
        XCTAssertTrue(preferences.hidesBookmarkButton)
        XCTAssertTrue(preferences.hidesSettingsButton)
        XCTAssertFalse(save.isEnabled, "the draft is spent")
    }

    /// The Tab bar page's rows, in the order the strip itself reads them:
    /// "Show tab bar" and "Auto-hide tab bar" first, then the three parts the
    /// strip can carry. Turning "Show tab bar" off greys "Auto-hide tab bar"
    /// and "Traffic lights" — a strip that is gone for good has nothing to
    /// slide back in, and the lights are already gone the way zen takes them
    /// — but leaves "Bookmark button" and "Settings button" reachable.
    @MainActor
    func testTabBarPageRowsAndShowTabBarGreying() throws {
        _ = NSApplication.shared
        let preferences = Preferences.shared
        let original = preferences.hidesTabBar
        defer { preferences.hidesTabBar = original }
        preferences.hidesTabBar = false

        let controller = SettingsWindowController.shared
        defer { controller.selectPage(at: 0) }
        XCTAssertTrue(controller.selectPage(titled: "Tab bar"))

        let rows = controller.rows(on: 4)
        XCTAssertEqual(rows.map(\.title), [
            "Show tab bar", "Auto-hide tab bar", "Traffic lights",
            "Bookmark button", "Settings button",
        ])

        func isEnabled(_ title: String) -> Bool {
            rows.first { $0.title == title }?.control.isEnabled ?? false
        }
        XCTAssertTrue(isEnabled("Auto-hide tab bar"))
        XCTAssertTrue(isEnabled("Traffic lights"))

        let showTabBar = try XCTUnwrap(
            rows.first { $0.title == "Show tab bar" }?.control as? NSSwitch
        )
        showTabBar.state = .off
        _ = NSApp.sendAction(try XCTUnwrap(showTabBar.action), to: showTabBar.target, from: showTabBar)

        XCTAssertFalse(isEnabled("Auto-hide tab bar"))
        XCTAssertFalse(isEnabled("Traffic lights"))
        XCTAssertTrue(isEnabled("Bookmark button"), "only auto-hide and traffic lights grey")
        XCTAssertTrue(isEnabled("Settings button"))
    }

    /// The last page is a plain about box: the icon, the name, and the version
    /// the bundle carries.
    @MainActor
    func testAboutPageShowsTheVersion() throws {
        _ = NSApplication.shared
        let controller = SettingsWindowController.shared
        defer { controller.selectPage(at: 0) }
        XCTAssertTrue(controller.selectPage(titled: "About"))

        let root = try XCTUnwrap(controller.window?.contentView)
        func allViews(in view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(allViews)
        }
        let strings = allViews(in: root).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(strings.contains("Nota"))
        XCTAssertTrue(strings.contains("Version \(AppVersion.current)"),
                      "no version line, only \(strings)")
        XCTAssertTrue(strings.contains("A plain-text notebook."))
    }

    /// Theme is General's second row: Save puts it on the app as a whole,
    /// and System Default hands the choice back to the Mac.
    @MainActor
    func testSavingAThemeDraftSetsTheAppsAppearance() throws {
        _ = NSApplication.shared
        let original = Preferences.shared.theme
        defer {
            Preferences.shared.theme = original
            NSApp.appearance = original.appearance
        }
        Preferences.shared.theme = .system
        NSApp.appearance = nil

        let controller = SettingsWindowController.shared
        let root = try XCTUnwrap(controller.window?.contentView)
        controller.selectPage(at: 0)
        func allViews(in view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(allViews)
        }
        let views = allViews(in: root)
        let theme = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first {
            $0.itemTitles.contains("Dark")
        })
        let save = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "Save" })

        theme.selectItem(at: 2)
        _ = NSApp.sendAction(try XCTUnwrap(theme.action), to: theme.target, from: theme)
        XCTAssertTrue(save.isEnabled)
        save.performClick(nil)
        XCTAssertEqual(Preferences.shared.theme, .dark)
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)

        theme.selectItem(at: 0)
        _ = NSApp.sendAction(try XCTUnwrap(theme.action), to: theme.target, from: theme)
        save.performClick(nil)
        XCTAssertEqual(Preferences.shared.theme, .system)
        XCTAssertNil(NSApp.appearance, "System Default lets the Mac decide")
    }

    @MainActor
    func testSavingAChineseLanguageDraftRerendersSettings() throws {
        _ = NSApplication.shared
        let original = Preferences.shared.language
        defer { Preferences.shared.language = original }
        Preferences.shared.language = .english

        let controller = SettingsWindowController.shared
        let root = try XCTUnwrap(controller.window?.contentView)
        controller.selectPage(at: 0)
        func allViews(in view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(allViews)
        }
        let views = allViews(in: root)
        let language = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first {
            $0.itemTitles.contains("简体中文")
        })
        let save = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "Save" })

        language.selectItem(at: 2)
        _ = NSApp.sendAction(try XCTUnwrap(language.action), to: language.target, from: language)
        XCTAssertTrue(save.isEnabled)
        save.performClick(nil)

        XCTAssertEqual(controller.window?.title, "设置")
        XCTAssertEqual(save.title, "保存")
        // The sidebar and the rows are relabelled in place, not rebuilt.
        XCTAssertEqual(controller.pageTitles.first, "通用")
        XCTAssertEqual(controller.rows(on: 0).map(\.title), ["语言", "主题"])

        // Footnotes are translated too.
        let translated = allViews(in: root).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(translated.contains("“跟随系统”由 Mac 决定。"),
                      "the Theme footnote is still English: \(translated)")
    }

    @MainActor
    func testStatusBarPreferenceHidesEveryFooterRegion() throws {
        _ = NSApplication.shared
        let original = Preferences.shared.showsStatusBar
        defer { Preferences.shared.showsStatusBar = original }
        let directory = try makeTemporaryDirectory()
        let controller = MainWindowController(store: SessionStore(directory: directory))

        Preferences.shared.showsStatusBar = false
        let footer = controller.footerRegions
        XCTAssertTrue(footer.badge.isHidden)
        XCTAssertTrue(footer.pendingKeys.isHidden)
        XCTAssertTrue(footer.counts.isHidden)
        XCTAssertTrue(footer.cursor.isHidden)
        XCTAssertTrue(footer.encoding.isHidden)
        XCTAssertTrue(footer.lineEnding.isHidden)
    }

    // MARK: - Images

    func testTokenRoundTripAndEdgeCases() throws {
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let a = "aaaaaaaa-0000-0000-0000-000000000001.png"
        let b = "bbbbbbbb-0000-0000-0000-000000000002.jpg"

        // Round trip: render then serialize gives back the exact same text.
        for plain in [
            "",
            "just words",
            NoteText.token(for: a),                                   // whole note
            NoteText.token(for: a) + "after",                         // at the start
            "before" + NoteText.token(for: a),                        // at the end
            NoteText.token(for: a) + NoteText.token(for: b),          // adjacent
            "one" + NoteText.token(for: a) + "two" + NoteText.token(for: b) + "three",
            "line\n" + NoteText.token(for: a) + "\nline",
        ] {
            let rendered = NoteText.render(plain, attributes: [:], assets: assets)
            XCTAssertEqual(NoteText.serialize(rendered), plain, "round trip failed for \(plain)")
        }

        // Two adjacent tokens really are two separate attachments.
        let adjacent = NoteText.render(
            NoteText.token(for: a) + NoteText.token(for: b), attributes: [:], assets: assets
        )
        XCTAssertEqual(adjacent.length, 2)
        XCTAssertEqual(attachmentIDs(in: adjacent), [a, b])

        // Malformed tokens are ordinary text and survive untouched.
        for malformed in [
            "![](nota://",
            "![](nota://)",
            "![](nota://noextension)",
            "![](http://example.com/x.png)",
            "![alt](nota://\(a))",
            "(nota://\(a))",
        ] {
            let rendered = NoteText.render(malformed, attributes: [:], assets: assets)
            XCTAssertTrue(attachmentIDs(in: rendered).isEmpty, "should not match: \(malformed)")
            XCTAssertEqual(NoteText.serialize(rendered), malformed)
        }

        XCTAssertEqual(NoteText.assetIDs(in: "x\(NoteText.token(for: a))y"), [a])
    }

    func testSerializeMixedStorageAndCountsExcludeImages() throws {
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let id = "cccccccc-0000-0000-0000-000000000003.png"
        let plain = "hello \(NoteText.token(for: id)) world"

        // A storage built the way a Note builds one.
        let storage = NSTextStorage(
            attributedString: NoteText.render(
                plain, attributes: [.font: NSFont.systemFont(ofSize: 13)], assets: assets
            )
        )
        // One image plus the surrounding text: "hello " + U+FFFC + " world".
        XCTAssertEqual(storage.length, 13)
        XCTAssertEqual(NoteText.serialize(storage), plain)

        // Editing around the image keeps the token intact.
        storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "HI")
        XCTAssertEqual(NoteText.serialize(storage), "HI \(NoteText.token(for: id)) world")

        // Counts see through to the text only — an image is worth nothing.
        XCTAssertEqual(NoteText.strippingTokens(plain), "hello  world")
        XCTAssertEqual(TextStats.counts(NoteText.strippingTokens(plain)), "2 words · 12 characters")
        XCTAssertEqual(
            TextStats.counts(NoteText.strippingTokens(NoteText.token(for: id))),
            "0 words · 0 characters"
        )
    }

    func testPlaceholdingTokensLeavesAnObjectReplacementCharacterPerImage() throws {
        let a = "aaaaaaaa-0000-0000-0000-000000000001.png"
        let b = "bbbbbbbb-0000-0000-0000-000000000002.png"
        let plain = "before \(NoteText.token(for: a)) middle \(NoteText.token(for: b)) after"

        XCTAssertEqual(
            NoteText.placeholdingTokens(plain),
            "before \u{FFFC} middle \u{FFFC} after"
        )
    }

    func testPathTokensWritesMarkdownImagesPointingAtTheAssetFiles() throws {
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let a = try XCTUnwrap(assets.importImageData(makePNGData(), preferredExtension: "png"))
        let b = try XCTUnwrap(assets.importImageData(makePNGData(), preferredExtension: "png"))
        let missing = "aaaaaaaa-0000-0000-0000-000000000009.png"
        let plain = "before \(NoteText.token(for: a)) middle "
            + "\(NoteText.token(for: b)) middle2 \(NoteText.token(for: missing)) after"

        XCTAssertEqual(
            NoteText.pathTokens(plain, assets: assets),
            "before ![Image 1](\(assets.url(for: a).path)) middle "
                + "![Image 2](\(assets.url(for: b).path)) middle2 \u{FFFC} after"
        )

        // No store at all: every image falls back to the marker.
        let a2 = "aaaaaaaa-0000-0000-0000-000000000001.png"
        let onlyToken = NoteText.token(for: a2)
        XCTAssertEqual(NoteText.pathTokens(onlyToken, assets: nil), "\u{FFFC}")
    }

    func testPasteImageThenCopyOffersEveryFlavour() throws {
        let previousStyle = Preferences.shared.plainTextImageStyle
        Preferences.shared.plainTextImageStyle = .marker
        defer { Preferences.shared.plainTextImageStyle = previousStyle }

        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let view = makeTextView(assets: assets)

        // A screenshot-style paste: raw PNG bytes on the pasteboard.
        let board = makePasteboard()
        board.clearContents()
        board.setData(makePNGData(), forType: .png)

        let chosen = view.preferredPasteboardType(
            from: board.types ?? [], restrictedToTypesFrom: view.readablePasteboardTypes
        )
        XCTAssertEqual(chosen, .png)
        XCTAssertTrue(view.readSelection(from: board, type: try XCTUnwrap(chosen)))

        // One attachment in the storage, one file in the assets dir.
        let storage = try XCTUnwrap(view.textStorage)
        let ids = attachmentIDs(in: storage)
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(storage.length, 1)
        XCTAssertEqual(try assetFileCount(assets), 1)
        XCTAssertTrue(ids[0].hasSuffix(".png"))

        // Copying it out offers Nota's own flavour, RTFD, the bare picture and
        // plain text — in that order, so Nota and rich-text apps take the
        // flavour that keeps the words around the image.
        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        let types = view.writablePasteboardTypes
        XCTAssertEqual(types, [.notaNote, .rtfd, .png, .tiff, .string])

        let out = makePasteboard()
        out.clearContents()
        out.declareTypes(types, owner: nil)
        for type in types {
            XCTAssertTrue(view.writeSelection(to: out, type: type), "failed to write \(type)")
        }
        // AppKit also puts legacy aliases (NSStringPboardType, NeXT RTFD) on the
        // board, so check ours are present rather than that they are all there is.
        XCTAssertTrue(Set(types).isSubset(of: Set(out.types ?? [])))
        XCTAssertEqual(out.string(forType: .notaNote), NoteText.token(for: ids[0]))
        XCTAssertEqual(out.string(forType: .string), "\u{FFFC}")

        // The RTFD really carries the bytes, so other apps see an image.
        let rtfd = try XCTUnwrap(out.data(forType: .rtfd))
        let restored = try XCTUnwrap(NSAttributedString(rtfd: rtfd, documentAttributes: nil))
        var foreignAttachments = 0
        restored.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: restored.length)
        ) { value, _, _ in
            if let attachment = value as? NSTextAttachment,
               attachment.fileWrapper?.regularFileContents != nil {
                foreignAttachments += 1
            }
        }
        XCTAssertEqual(foreignAttachments, 1)

        // Nota -> Nota re-uses the asset instead of importing a second copy.
        let second = makeTextView(assets: assets)
        XCTAssertTrue(second.readSelection(from: out, type: .notaNote))
        XCTAssertEqual(attachmentIDs(in: try XCTUnwrap(second.textStorage)), ids)
        XCTAssertEqual(try assetFileCount(assets), 1)
    }

    /// The default plain-text flavour: a Markdown image pointing at the
    /// asset's real path on disk, so pasting into a terminal agent leaves
    /// something it can actually open.
    @MainActor
    func testCopyingWithDefaultPlainTextStyleWritesTheAssetPath() throws {
        _ = NSApplication.shared
        XCTAssertEqual(Preferences.shared.plainTextImageStyle, .path)

        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let view = makeTextView(assets: assets)
        let id = try XCTUnwrap(assets.importImageData(makePNGData(), preferredExtension: "png"))
        let token = NoteText.token(for: id)
        try XCTUnwrap(view.textStorage).setAttributedString(NoteText.render(
            "hello \(token) world", attributes: [.font: NSFont.systemFont(ofSize: 13)],
            assets: assets
        ))
        view.setSelectedRange(NSRange(location: 0, length: view.textStorage?.length ?? 0))

        let board = makePasteboard()
        board.clearContents()
        board.declareTypes([.string], owner: nil)
        XCTAssertTrue(view.writeSelection(to: board, type: .string))
        XCTAssertEqual(
            board.string(forType: .string),
            "hello ![Image 1](\(assets.url(for: id).path)) world"
        )
    }

    /// Copying text and a picture off a web page: a browser offers no RTF, so
    /// `public.html` is the only flavour the picture is in at all.
    @MainActor
    func testPastingHTMLWithAnInlineImageKeepsTheWordsAndThePicture() throws {
        _ = NSApplication.shared
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let view = makeTextView(assets: assets)
        let png = makePNGData()
        let html = """
        <html><body><p>before \
        <img src="data:image/png;base64,\(png.base64EncodedString())"> after</p></body></html>
        """

        try withGeneralPasteboard { board in
            board.clearContents()
            board.declareTypes([.html, .string], owner: nil)
            board.setData(Data(html.utf8), forType: .html)
            board.setString("before  after", forType: .string)

            let chosen = view.preferredPasteboardType(
                from: board.types ?? [], restrictedToTypesFrom: view.readablePasteboardTypes
            )
            XCTAssertEqual(chosen, .html)
            XCTAssertTrue(view.readSelection(from: board, type: try XCTUnwrap(chosen)))
        }

        // The words survive, and the picture is a chip backed by a real file.
        let storage = try XCTUnwrap(view.textStorage)
        let ids = attachmentIDs(in: storage)
        XCTAssertEqual(ids.count, 1)
        XCTAssertTrue(assets.exists(ids[0]))
        XCTAssertEqual(try assetFileCount(assets), 1)
        XCTAssertTrue(storage.string.contains("before"))
        XCTAssertTrue(storage.string.contains("after"))
        // The importer closes the paragraph with a newline the copy never had.
        XCTAssertFalse(storage.string.hasSuffix("\n"))
    }

    /// A text-only copy from a browser is left exactly as it was: the HTML
    /// flavour has nothing to add, and going through the importer would cost
    /// the copy its lists and its whitespace for nothing.
    @MainActor
    func testPastingHTMLWithoutAPictureStaysPlainText() throws {
        _ = NSApplication.shared
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let view = makeTextView(assets: assets)
        let html = "<html><body><ul><li>one</li><li>two</li></ul></body></html>"
        let plain = "- one\n- two"

        try withGeneralPasteboard { board in
            board.clearContents()
            board.declareTypes([.html, .string], owner: nil)
            board.setData(Data(html.utf8), forType: .html)
            board.setString(plain, forType: .string)

            let chosen = view.preferredPasteboardType(
                from: board.types ?? [], restrictedToTypesFrom: view.readablePasteboardTypes
            )
            XCTAssertEqual(chosen, .string)
            XCTAssertTrue(view.readSelection(from: board, type: try XCTUnwrap(chosen)))
        }

        XCTAssertEqual(view.textStorage?.string, plain)
        XCTAssertEqual(try assetFileCount(assets), 0)
    }

    /// The path that matters: a picture the importer would not load — here a
    /// source relative to a page that is not on this machine — filled in from
    /// the web archive's own subresources rather than dropped.
    @MainActor
    func testPastingAWebArchiveFillsInThePicturesTheImporterLeftEmpty() throws {
        _ = NSApplication.shared
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let view = makeTextView(assets: assets)
        let png = makePNGData()
        // The second picture is one nothing can resolve: the importer would
        // put its broken-picture icon there, and a chip pointing at that icon
        // would be worse than no chip at all.
        let html = """
        <html><body><p>look <img src="a.png"> here \
        <img src="notes://elsewhere/gone.png"></p></body></html>
        """
        let archive: [String: Any] = [
            "WebMainResource": [
                "WebResourceData": Data(html.utf8),
                "WebResourceURL": "https://example.com/",
                "WebResourceMIMEType": "text/html",
                "WebResourceTextEncodingName": "UTF-8",
            ],
            "WebSubresources": [[
                "WebResourceData": png,
                "WebResourceURL": "https://example.com/a.png",
                "WebResourceMIMEType": "image/png",
            ]],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: archive, format: .binary, options: 0
        )

        try withGeneralPasteboard { board in
            board.clearContents()
            board.declareTypes([.webArchive, .string], owner: nil)
            board.setData(data, forType: .webArchive)
            board.setString("look  here", forType: .string)

            let chosen = view.preferredPasteboardType(
                from: board.types ?? [], restrictedToTypesFrom: view.readablePasteboardTypes
            )
            XCTAssertEqual(chosen, .webArchive)
            XCTAssertTrue(view.readSelection(from: board, type: try XCTUnwrap(chosen)))
        }

        let storage = try XCTUnwrap(view.textStorage)
        let ids = attachmentIDs(in: storage)
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(assets.data(for: ids[0]), png)
        XCTAssertEqual(try assetFileCount(assets), 1)
        XCTAssertTrue(storage.string.contains("look"))
        XCTAssertTrue(storage.string.contains("here"))
    }

    /// The source list and what each source resolves to, without a view or a
    /// pasteboard in the way. Nothing here goes near the network.
    func testHTMLClipboardResolvesInlinePicturesAndDropsWhatItCannot() throws {
        let png = makePNGData()
        let html = """
        <p>one <img src='data:image/png;base64,\(png.base64EncodedString())'> \
        two <img src="notes://elsewhere/picture.png"> \
        three <img src="page.png"></p>
        """
        let payload = HTMLClipboard.Payload(html: html)

        XCTAssertTrue(HTMLClipboard.containsImage(html))
        XCTAssertFalse(HTMLClipboard.containsImage("<p>no pictures here</p>"))

        let sources = HTMLClipboard.imageSources(in: html)
        XCTAssertEqual(sources.count, 3)
        XCTAssertEqual(sources[1], "notes://elsewhere/picture.png")
        XCTAssertEqual(sources[2], "page.png")

        // A data URI is the picture itself, byte for byte, and says what it is.
        let inline = try XCTUnwrap(HTMLClipboard.imageBytes(
            forSource: sources[0], in: payload, fetch: { _ in nil }
        ))
        XCTAssertEqual(inline.data, png)
        XCTAssertEqual(inline.preferredExtension, "png")

        // A scheme that is not the web's, and a relative source with no page
        // behind it, have nowhere to go — that one picture is dropped.
        XCTAssertNil(HTMLClipboard.imageBytes(
            forSource: sources[1], in: payload, fetch: { _ in nil }
        ))
        XCTAssertNil(HTMLClipboard.imageBytes(
            forSource: sources[2], in: payload, fetch: { _ in nil }
        ))

        // An http source is fetched, and nothing else is.
        var fetched: [URL] = []
        let remote = try XCTUnwrap(HTMLClipboard.imageBytes(
            forSource: "https://example.com/a.jpg", in: payload,
            fetch: { url in
                fetched.append(url)
                return png
            }
        ))
        XCTAssertEqual(fetched.map(\.absoluteString), ["https://example.com/a.jpg"])
        XCTAssertEqual(remote.preferredExtension, "jpg")
    }

    /// Safari's flavour: the markup and the pictures in one property list, so
    /// the bytes are already in hand and nothing has to be fetched.
    func testWebArchiveCarriesTheMarkupAndItsPictures() throws {
        let png = makePNGData()
        let html = "<p>hi <img src=\"https://example.com/a.png\"></p>"
        let archive: [String: Any] = [
            "WebMainResource": [
                "WebResourceData": Data(html.utf8),
                "WebResourceURL": "https://example.com/",
                "WebResourceMIMEType": "text/html",
                "WebResourceTextEncodingName": "UTF-8",
            ],
            "WebSubresources": [[
                "WebResourceData": png,
                "WebResourceURL": "https://example.com/a.png",
                "WebResourceMIMEType": "image/png",
            ]],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: archive, format: .binary, options: 0
        )

        let payload = try XCTUnwrap(HTMLClipboard.payload(from: data, type: .webArchive))
        XCTAssertEqual(payload.html, html)

        let source = try XCTUnwrap(HTMLClipboard.imageSources(in: payload.html).first)
        let bytes = try XCTUnwrap(HTMLClipboard.imageBytes(
            forSource: source, in: payload, fetch: { _ in nil }
        ))
        XCTAssertEqual(bytes.data, png)

        // A relative source still finds the subresource it names.
        let relative = try XCTUnwrap(HTMLClipboard.imageBytes(
            forSource: "a.png", in: payload, fetch: { _ in nil }
        ))
        XCTAssertEqual(relative.data, png)
    }

    /// The bug: a click dropped a caret *beside* the chip, so the picture
    /// looked selected and ⌘C copied nothing — `writeSelection` bails on a
    /// zero-length range. A click now selects the chip character itself.
    @MainActor
    func testClickingAChipSelectsItSoCopyCarriesTheImage() throws {
        _ = NSApplication.shared
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let view = makeTextView(assets: assets)
        let id = try XCTUnwrap(assets.importImageData(makePNGData(), preferredExtension: "png"))
        try XCTUnwrap(view.textStorage).setAttributedString(NoteText.render(
            "hello \(NoteText.token(for: id)) world",
            attributes: [.font: NSFont.systemFont(ofSize: 13)], assets: assets
        ))

        var clicked: Int?
        view.onChipClick = { clicked = $0 }
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.selectClickedChip(at: 6)

        XCTAssertEqual(view.selectedRange(), NSRange(location: 6, length: 1))
        XCTAssertEqual(clicked, 6)
        // The sidebar still rings exactly one thumbnail for that one chip.
        XCTAssertEqual(
            ChipHighlight.resolve(
                clickedChipLocation: nil, selection: view.selectedRange(), chipLocations: [6]
            ),
            [0]
        )

        // ⌘C, the real action, now has a range to write.
        withGeneralPasteboard { board in
            board.clearContents()
            view.copy(nil as Any?)
            XCTAssertTrue(Set<NSPasteboard.PasteboardType>([.notaNote, .rtfd, .string])
                .isSubset(of: Set(board.types ?? [])))
            XCTAssertEqual(board.string(forType: .notaNote), NoteText.token(for: id))
        }

        // A drag or a ⇧-click has already said what is meant; leave it be.
        view.setSelectedRange(NSRange(location: 0, length: 13))
        view.selectClickedChip(at: 6)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 13))

        // Vim's block caret sits *on* the chip instead, where the block draws.
        view.vimCursorStyle = .block
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.selectClickedChip(at: 6)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 6, length: 0))
    }

    /// A whole line copied the way ⌘C and Edit ▸ Copy take it — through
    /// `copy(_:)` and the general pasteboard, not `writeSelection` by hand.
    @MainActor
    func testCopyingALineWithAChipPastesTheImageBackAndCarriesItsBytes() throws {
        _ = NSApplication.shared
        let previousStyle = Preferences.shared.plainTextImageStyle
        Preferences.shared.plainTextImageStyle = .marker
        defer { Preferences.shared.plainTextImageStyle = previousStyle }

        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let view = makeTextView(assets: assets)
        let png = makePNGData()
        let id = try XCTUnwrap(assets.importImageData(png, preferredExtension: "png"))
        let token = NoteText.token(for: id)
        try XCTUnwrap(view.textStorage).setAttributedString(NoteText.render(
            "hello \(token) world\nsecond line",
            attributes: [.font: NSFont.systemFont(ofSize: 13)], assets: assets
        ))

        // "hello " + chip + " world" + newline: the first line, as a triple
        // click takes it.
        view.setSelectedRange(NSRange(location: 0, length: 14))

        try withGeneralPasteboard { board in
            board.clearContents()
            view.copy(nil as Any?)

            XCTAssertTrue(Set<NSPasteboard.PasteboardType>([.notaNote, .rtfd, .string])
                .isSubset(of: Set(board.types ?? [])))
            XCTAssertEqual(board.string(forType: .notaNote), "hello \(token) world\n")
            XCTAssertEqual(board.string(forType: .string), "hello \u{FFFC} world\n")

            // Nota -> Nota: the chip comes back, still pointing at the one asset.
            let second = makeTextView(assets: assets)
            let chosen = second.preferredPasteboardType(
                from: board.types ?? [], restrictedToTypesFrom: second.readablePasteboardTypes
            )
            XCTAssertEqual(chosen, .notaNote)
            XCTAssertTrue(second.readSelection(from: board, type: try XCTUnwrap(chosen)))
            XCTAssertEqual(attachmentIDs(in: try XCTUnwrap(second.textStorage)), [id])
            XCTAssertEqual(try assetFileCount(assets), 1)

            // And the RTFD other apps take really carries the picture.
            let rtfd = try XCTUnwrap(board.data(forType: .rtfd))
            let restored = try XCTUnwrap(NSAttributedString(rtfd: rtfd, documentAttributes: nil))
            var carried: [Data] = []
            restored.enumerateAttribute(
                .attachment, in: NSRange(location: 0, length: restored.length)
            ) { value, _, _ in
                if let contents = (value as? NSTextAttachment)?.fileWrapper?.regularFileContents {
                    carried.append(contents)
                }
            }
            XCTAssertEqual(carried, [png])
        }
    }

    /// The bug: a copied chip pasted into Nota and Notes but nowhere else —
    /// a terminal, a browser and Slack read `public.png` and nothing Nota was
    /// offering. The picture now rides along whether the chip is copied on
    /// its own or inside a line of prose.
    @MainActor
    func testACopiedChipIsAlsoAPNGAndTIFFOnTheClipboard() throws {
        _ = NSApplication.shared
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let view = makeTextView(assets: assets)
        let png = makePNGData()
        let id = try XCTUnwrap(assets.importImageData(png, preferredExtension: "png"))
        let source = try XCTUnwrap(NSBitmapImageRep(data: png))
        try XCTUnwrap(view.textStorage).setAttributedString(NoteText.render(
            "asd \(NoteText.token(for: id)) asdasd",
            attributes: [.font: NSFont.systemFont(ofSize: 13)], assets: assets
        ))

        // The chip alone, as a click on it selects it.
        view.setSelectedRange(NSRange(location: 4, length: 1))
        XCTAssertEqual(view.writablePasteboardTypes, [.notaNote, .rtfd, .png, .tiff, .string])

        // And the whole line around it, as a triple click takes it.
        for range in [NSRange(location: 4, length: 1), NSRange(location: 0, length: 12)] {
            view.setSelectedRange(range)
            let board = makePasteboard()
            board.clearContents()
            let types = view.writablePasteboardTypes
            board.declareTypes(types, owner: nil)
            for type in types {
                XCTAssertTrue(view.writeSelection(to: board, type: type), "failed \(type)")
            }

            // Already a PNG on disk, so the very bytes go out — no re-encode.
            XCTAssertEqual(board.data(forType: .png), png)
            let tiff = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(board.data(forType: .tiff))))
            XCTAssertEqual(tiff.pixelsWide, source.pixelsWide)
            XCTAssertEqual(tiff.pixelsHigh, source.pixelsHigh)

            // Nota -> Nota still takes its own flavour first, so the asset is
            // re-linked rather than imported a second time.
            let second = makeTextView(assets: assets)
            XCTAssertEqual(
                second.preferredPasteboardType(
                    from: board.types ?? [], restrictedToTypesFrom: second.readablePasteboardTypes
                ),
                .notaNote
            )
            XCTAssertTrue(second.readSelection(from: board, type: .notaNote))
            XCTAssertEqual(attachmentIDs(in: try XCTUnwrap(second.textStorage)), [id])
            XCTAssertEqual(try assetFileCount(assets), 1)
        }
    }

    /// One `public.png` cannot say which of two pictures is meant, so a
    /// selection holding both goes out as text and RTFD only.
    @MainActor
    func testASelectionWithTwoChipsOffersNoPictureFlavour() throws {
        _ = NSApplication.shared
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let view = makeTextView(assets: assets)
        let first = try XCTUnwrap(assets.importImageData(makePNGData(), preferredExtension: "png"))
        let second = try XCTUnwrap(assets.importImageData(makePNGData(), preferredExtension: "png"))
        let storage = try XCTUnwrap(view.textStorage)
        storage.setAttributedString(NoteText.render(
            "\(NoteText.token(for: first)) and \(NoteText.token(for: second))",
            attributes: [.font: NSFont.systemFont(ofSize: 13)], assets: assets
        ))

        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        XCTAssertEqual(view.writablePasteboardTypes, [.notaNote, .rtfd, .string])

        // Either one on its own is unambiguous again.
        view.setSelectedRange(NSRange(location: 0, length: 1))
        XCTAssertEqual(view.writablePasteboardTypes, [.notaNote, .rtfd, .png, .tiff, .string])
    }

    /// Copying prose stays prose: no image flavours, and still no RTFD.
    @MainActor
    func testAPlainTextSelectionOffersNoImageFlavours() throws {
        _ = NSApplication.shared
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let view = makeTextView(assets: assets)
        let storage = try XCTUnwrap(view.textStorage)
        storage.setAttributedString(NSAttributedString(
            string: "just words", attributes: [.font: NSFont.systemFont(ofSize: 13)]
        ))

        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        XCTAssertEqual(view.writablePasteboardTypes, [.notaNote, .string])
        XCTAssertFalse(view.writeSelection(to: makePasteboard(), type: .png))
    }

    func testMissingAssetKeepsItsTokenThroughARoundTrip() throws {
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let plain = "before \(NoteText.token(for: "missing-0000.png")) after"
        let rendered = NoteText.render(plain, attributes: [:], assets: assets)

        // Rendered as a placeholder, but still an attachment that serializes back.
        XCTAssertEqual(attachmentIDs(in: rendered), ["missing-0000.png"])
        XCTAssertEqual(NoteText.serialize(rendered), plain)
        XCTAssertEqual(try assetFileCount(assets), 0)
    }

    // MARK: - Search across tabs

    func testSearchFindsMatchesInTabOrderWithUsableRanges() {
        let notes = [
            (title: "One", text: "alpha beta\nGAMMA delta\n"),
            (title: "Two", text: "nothing here"),
            (title: "Three", text: "beta again\nand Beta once more"),
        ]

        let results = NoteSearch.matches(query: "beta", in: notes)
        XCTAssertEqual(results.map(\.tabIndex), [0, 2, 2])
        XCTAssertEqual(results.map(\.tabTitle), ["One", "Three", "Three"])

        // Every range addresses the text it came from, and the snippet range
        // covers the same characters — that is what the bolding and the
        // text-view selection both rely on.
        for match in results {
            let source = notes[match.tabIndex].text as NSString
            XCTAssertEqual(
                source.substring(with: match.rangeInText).lowercased(), "beta"
            )
            XCTAssertEqual(
                (match.snippet as NSString).substring(with: match.rangeInSnippet).lowercased(),
                "beta"
            )
        }

        // The snippet is the whole line the match sits on.
        XCTAssertEqual(results[0].snippet, "alpha beta")
        XCTAssertEqual(results[1].snippet, "beta again")
        XCTAssertEqual(results[2].snippet, "and Beta once more")
        XCTAssertEqual(results[0].rangeInText, NSRange(location: 6, length: 4))
    }

    func testSearchIsCaseInsensitiveAndIgnoresEmptyQueries() {
        let notes = [(title: "N", text: "Needle needle NEEDLE")]

        XCTAssertEqual(NoteSearch.matches(query: "needle", in: notes).count, 3)
        XCTAssertEqual(NoteSearch.matches(query: "NEEDLE", in: notes).count, 3)
        XCTAssertEqual(NoteSearch.matches(query: "NeEdLe", in: notes).count, 3)

        XCTAssertTrue(NoteSearch.matches(query: "", in: notes).isEmpty)
        XCTAssertTrue(NoteSearch.matches(query: "   ", in: notes).isEmpty)
        XCTAssertTrue(NoteSearch.matches(query: "\n", in: notes).isEmpty)
        XCTAssertTrue(NoteSearch.matches(query: "absent", in: notes).isEmpty)
        XCTAssertTrue(NoteSearch.matches(query: "x", in: []).isEmpty)

        // An image is a single object-replacement character, so a query can
        // never match "inside" a picture.
        let withImage = [(title: "N", text: "a\u{FFFC}b")]
        XCTAssertTrue(NoteSearch.matches(query: "nota", in: withImage).isEmpty)
        XCTAssertEqual(NoteSearch.matches(query: "b", in: withImage).first?.rangeInText,
                       NSRange(location: 2, length: 1))
    }

    func testSearchCapsResultsAndWindowsLongLines() {
        let many = (title: "Many", text: String(repeating: "hit ", count: 300))
        let capped = NoteSearch.matches(query: "hit", in: [many])
        XCTAssertEqual(capped.count, NoteSearch.resultLimit)
        XCTAssertEqual(capped.count, 200)

        // The cap is across all tabs, not per tab.
        let acrossTabs = NoteSearch.matches(query: "hit", in: [many, many])
        XCTAssertEqual(acrossTabs.count, 200)

        // A match far along a line is windowed so it stays visible.
        let long = (title: "Long", text: String(repeating: "x", count: 300) + "needle tail")
        let match = try? XCTUnwrap(NoteSearch.matches(query: "needle", in: [long]).first)
        let found = try? XCTUnwrap(match)
        XCTAssertTrue(found?.snippet.hasPrefix("…") ?? false)
        XCTAssertLessThan((found?.snippet as NSString?)?.length ?? .max, 160)
        XCTAssertEqual(
            ((found?.snippet ?? "") as NSString).substring(with: found?.rangeInSnippet ?? NSRange()),
            "needle"
        )
        // The text range still points at the real offset in the note.
        XCTAssertEqual(found?.rangeInText, NSRange(location: 300, length: 6))
    }

    // MARK: - Chips and sidebar

    func testSidebarOrderingFollowsDocumentOrderIncludingDuplicates() {
        let a = "aaaaaaaa-1111.png"
        let b = "bbbbbbbb-2222.jpg"
        let text = "x\(NoteText.token(for: a))y\(NoteText.token(for: b))z\(NoteText.token(for: a))"

        // The same picture used twice gets two sidebar rows, in text order.
        XCTAssertEqual(NoteText.assetIDs(in: text), [a, b, a])

        // And that list matches the chips actually rendered into the storage,
        // which is what makes "sidebar item N" mean "chip N".
        let rendered = NoteText.render(text, attributes: [:], assets: nil)
        XCTAssertEqual(attachmentIDs(in: rendered), [a, b, a])

        XCTAssertEqual(NoteText.assetIDs(in: ""), [])
        XCTAssertEqual(NoteText.assetIDs(in: "no tokens here"), [])
        XCTAssertEqual(NoteText.assetIDs(in: "![](nota://malformed"), [])
    }

    func testChipIsTextSizedAndRenumbersLive() {
        let font = NSFont.systemFont(ofSize: 13)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)

        func bounds(_ chip: NotaImageAttachment, width: CGFloat = 2000) -> CGRect {
            chip.attachmentBounds(
                for: nil,
                proposedLineFragment: CGRect(x: 0, y: 0, width: width, height: 20),
                glyphPosition: .zero,
                characterIndex: 0
            )
        }

        let first = NotaImageAttachment(assetID: "a.png", isMissing: false, font: font, index: 1)
        let tenth = NotaImageAttachment(assetID: "b.png", isMissing: false, font: font, index: 10)
        let gone = NotaImageAttachment(assetID: "c.png", isMissing: true, font: font, index: 1)

        XCTAssertEqual(first.label, "Image 1")
        XCTAssertEqual(tenth.label, "Image 10")
        XCTAssertEqual(gone.label, "Image 1 — missing")

        // Height is the line height for every chip, whatever it says.
        XCTAssertEqual(bounds(first).height, lineHeight)
        XCTAssertEqual(bounds(tenth).height, lineHeight)
        XCTAssertEqual(bounds(gone).height, lineHeight)

        // Width follows the label, so a longer number is a wider chip.
        XCTAssertGreaterThan(bounds(tenth).width, bounds(first).width)
        XCTAssertGreaterThan(bounds(gone).width, bounds(first).width)

        // Nothing depends on the line fragment: chips never go full width.
        XCTAssertEqual(bounds(first, width: 10).width, bounds(first).width)

        // Baseline-aligned like text, and taller type gives a taller chip.
        XCTAssertEqual(bounds(first).origin.y, font.descender.rounded())
        XCTAssertLessThan(bounds(first).origin.y, 0)
        let big = NotaImageAttachment(
            assetID: "a.png", isMissing: false, font: .systemFont(ofSize: 24), index: 1
        )
        XCTAssertGreaterThan(bounds(big).height, lineHeight)

        // Renumbering resizes in place, and reports whether anything moved.
        let widthAsOne = bounds(first).width
        XCTAssertTrue(first.updateChip(font: font, index: 10))
        XCTAssertEqual(first.label, "Image 10")
        XCTAssertGreaterThan(bounds(first).width, widthAsOne)
        XCTAssertFalse(first.updateChip(font: font, index: 10))
    }

    func testRenderNumbersChipsInDocumentOrder() {
        let a = "aaaaaaaa-1111.png"
        let b = "bbbbbbbb-2222.jpg"
        let text = "x\(NoteText.token(for: a))y\(NoteText.token(for: b))z\(NoteText.token(for: a))"
        let rendered = NoteText.render(text, attributes: [:], assets: nil)

        var labels: [String] = []
        rendered.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: rendered.length)
        ) { value, _, _ in
            if let chip = value as? NotaImageAttachment { labels.append(chip.label) }
        }
        // A repeated picture still gets its own number, by position.
        XCTAssertEqual(
            labels,
            ["Image 1 — missing", "Image 2 — missing", "Image 3 — missing"]
        )
        // Numbering is display only — it never reaches the file.
        XCTAssertEqual(NoteText.serialize(rendered), text)
    }

    func testABlockCaretLightsTheChipItSitsOn() {
        let chips = [4, 5, 9]
        func resolve(_ location: Int, block: Bool) -> Set<Int> {
            ChipHighlight.resolve(
                clickedChipLocation: nil, selection: NSRange(location: location, length: 0),
                chipLocations: chips, caretIsBlock: block
            )
        }
        // Normal mode: the block on the chip is the chip.
        XCTAssertEqual(resolve(4, block: true), [0])
        XCTAssertEqual(resolve(5, block: true), [1])
        XCTAssertEqual(resolve(9, block: true), [2])
        // Just past a chip is not on it any more.
        XCTAssertEqual(resolve(6, block: true), [])
        XCTAssertEqual(resolve(10, block: true), [])
        // Insert mode is unchanged: the chip before the bar.
        XCTAssertEqual(resolve(5, block: false), [0])
        XCTAssertEqual(resolve(4, block: false), [])
    }

    func testAdjacentChipsLightOnlyOneThumbnail() {
        // Two chips side by side at 4 and 5, a third further along.
        let chips = [4, 5, 9]
        func resolve(clicked: Int? = nil, _ selection: NSRange) -> Set<Int> {
            ChipHighlight.resolve(
                clickedChipLocation: clicked, selection: selection, chipLocations: chips
            )
        }

        // The caret between the two adjacent chips belongs to the one before
        // it — this is the case that used to light both.
        XCTAssertEqual(resolve(NSRange(location: 5, length: 0)), [0])
        XCTAssertEqual(resolve(NSRange(location: 6, length: 0)), [1])
        // Sitting in front of a chip highlights nothing.
        XCTAssertEqual(resolve(NSRange(location: 4, length: 0)), [])
        XCTAssertEqual(resolve(NSRange(location: 0, length: 0)), [])

        // A click is explicit, so it wins over where the caret landed.
        XCTAssertEqual(resolve(clicked: 5, NSRange(location: 5, length: 0)), [1])
        XCTAssertEqual(resolve(clicked: 9, NSRange(location: 6, length: 0)), [2])
        // A remembered click on a chip that has since gone falls back to the
        // caret rather than highlighting nothing.
        XCTAssertEqual(resolve(clicked: 99, NSRange(location: 5, length: 0)), [0])

        // A real selection lights every chip it covers, adjacency included.
        XCTAssertEqual(resolve(NSRange(location: 4, length: 6)), [0, 1, 2])
        XCTAssertEqual(resolve(NSRange(location: 4, length: 2)), [0, 1])
        XCTAssertEqual(resolve(NSRange(location: 0, length: 5)), [0])
        XCTAssertEqual(resolve(NSRange(location: 0, length: 4)), [])

        // A note with no images never highlights anything.
        XCTAssertEqual(
            ChipHighlight.resolve(
                clickedChipLocation: nil,
                selection: NSRange(location: 3, length: 2),
                chipLocations: []
            ),
            []
        )
    }

    // MARK: - Fuzzy tab picker

    func testFuzzyMatchIsSubsequenceBasedAndRanksSensibly() {
        // Characters must appear in order, but need not be adjacent.
        XCTAssertNotNil(FuzzyMatch.match(query: "ai", in: "AI prompts"))
        XCTAssertNotNil(FuzzyMatch.match(query: "aip", in: "AI prompts"))
        XCTAssertNotNil(FuzzyMatch.match(query: "APP", in: "AI prompts"))
        XCTAssertNil(FuzzyMatch.match(query: "pa", in: "AI prompts"))
        XCTAssertNil(FuzzyMatch.match(query: "zzz", in: "AI prompts"))
        XCTAssertNil(FuzzyMatch.match(query: "toolong", in: "abc"))

        // An empty query matches everything, so ⌘P opens on the full list.
        XCTAssertEqual(FuzzyMatch.match(query: "", in: "anything")?.matchedIndices, [])

        // Matched positions come back for highlighting.
        // Greedy leftmost match, case-insensitive: the T of Think, the p of patterns.
        XCTAssertEqual(FuzzyMatch.match(query: "tp", in: "Think patterns")?.matchedIndices, [0, 6])

        let titles = ["Think different", "AI prompts", "Thoughts", "Untitled"]
        let ranked = FuzzyMatch.rank(query: "th", titles: titles)
        XCTAssertEqual(Set(ranked.map(\.index)), [0, 2])
        // "Thoughts" is shorter and starts with the query, so it wins.
        XCTAssertEqual(ranked.first?.index, 2)

        // Nothing matches -> empty list, not a crash.
        XCTAssertTrue(FuzzyMatch.rank(query: "qqqq", titles: titles).isEmpty)
        // Word-boundary initials beat a scattered match.
        let initials = FuzzyMatch.rank(query: "td", titles: ["Think different", "toad"])
        XCTAssertEqual(initials.first?.index, 0)
    }

    // MARK: - Footer

    func testFooterCountVariantsShedSegmentsFromTheRight() {
        let all = TextStats.Segment.allCases

        // Longest first: everything enabled, then a segment given up at a
        // time from the right, then the bare numbers.
        XCTAssertEqual(
            TextStats.countVariants(
                words: 2, characters: 7, images: 3, lines: 12, segments: all
            ),
            [
                "2 words · 7 characters · 3 images · 12 lines",
                "2 words · 7 characters · 3 images",
                "2 words · 7 characters",
                "2 words",
                "2 · 7 · 3 · 12",
            ]
        )

        // Singulars, and an empty note.
        XCTAssertEqual(
            TextStats.countVariants(
                words: 1, characters: 1, images: 1, lines: 1, segments: all
            ).first,
            "1 word · 1 character · 1 image · 1 line"
        )
        XCTAssertEqual(
            TextStats.countVariants(
                words: 0, characters: 0, images: 0, lines: 1, segments: all
            ).first,
            "0 words · 0 characters · 0 images · 1 line"
        )

        // Only the enabled segments appear.
        XCTAssertEqual(
            TextStats.countVariants(
                words: 2, characters: 7, images: 3, lines: 12, segments: [.words, .characters]
            ),
            ["2 words · 7 characters", "2 words", "2 · 7"]
        )
        XCTAssertEqual(
            TextStats.countVariants(
                words: 2, characters: 7, images: 3, lines: 12, segments: [.lines]
            ),
            ["12 lines", "12"]
        )
        // Nothing enabled means nothing to show, which is what hides the label.
        XCTAssertTrue(
            TextStats.countVariants(
                words: 2, characters: 7, images: 3, lines: 12, segments: []
            ).isEmpty
        )

        // Hard lines: one per newline plus the last, empty note included.
        XCTAssertEqual(TextStats.lineCount(""), 1)
        XCTAssertEqual(TextStats.lineCount("one line"), 1)
        XCTAssertEqual(TextStats.lineCount("one\ntwo"), 2)
        // A trailing newline opens a line of its own, as the gutter shows it.
        XCTAssertEqual(TextStats.lineCount("one\n"), 2)
        XCTAssertEqual(TextStats.lineCount("\n\n"), 3)
    }

    func testFooterPicksTheLongestCountsThatFit() {
        let variants = TextStats.countVariants(
            words: 2, characters: 7, images: 3, lines: 12,
            segments: TextStats.Segment.allCases
        )
        // A stand-in for the type: every character is 10pt wide.
        func fitting(_ width: CGFloat) -> String {
            TextStats.variantFitting(variants, within: width) { candidate in
                CGFloat(candidate.count) * 10
            }
        }

        // Room for everything.
        XCTAssertEqual(fitting(10_000), "2 words · 7 characters · 3 images · 12 lines")
        // 44 characters in the full form, 33 in the next one down.
        XCTAssertEqual(fitting(440), "2 words · 7 characters · 3 images · 12 lines")
        XCTAssertEqual(fitting(439), "2 words · 7 characters · 3 images")
        XCTAssertEqual(fitting(330), "2 words · 7 characters · 3 images")
        XCTAssertEqual(fitting(329), "2 words · 7 characters")
        XCTAssertEqual(fitting(219), "2 words")
        XCTAssertEqual(fitting(70), "2 words")
        // Below one whole segment there is nothing left but the bare
        // numbers, which are kept even when they do not fit either — a
        // clipped number beats a phrase cut off mid-word.
        XCTAssertEqual(fitting(69), "2 · 7 · 3 · 12")
        XCTAssertEqual(fitting(0), "2 · 7 · 3 · 12")

        // With the default two segments the numbers really are the shortest
        // form, so they take over before anything is given up entirely.
        let two = TextStats.countVariants(
            words: 2, characters: 7, images: 3, lines: 12, segments: [.words, .characters]
        )
        func fittingTwo(_ width: CGFloat) -> String {
            TextStats.variantFitting(two, within: width) { CGFloat($0.count) * 10 }
        }
        XCTAssertEqual(fittingTwo(220), "2 words · 7 characters")
        XCTAssertEqual(fittingTwo(219), "2 words")
        XCTAssertEqual(fittingTwo(69), "2 · 7")

        // Nothing enabled has nothing to fit.
        XCTAssertEqual(TextStats.variantFitting([], within: 100) { _ in 0 }, "")
    }

    func testCursorPositionIsOneBasedAndCountsAnImageAsOneColumn() throws {
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let id = "dddddddd-0000-0000-0000-000000000004.png"

        let plain = "one\ntwo\nthree"
        let text = plain as NSString
        XCTAssertEqual(TextStats.position(in: text, at: 0), "Ln 1, Col 1")
        XCTAssertEqual(TextStats.position(in: text, at: 3), "Ln 1, Col 4")
        // Just past the newline is the start of the next line.
        XCTAssertEqual(TextStats.position(in: text, at: 4), "Ln 2, Col 1")
        XCTAssertEqual(TextStats.position(in: text, at: 7), "Ln 2, Col 4")
        XCTAssertEqual(TextStats.position(in: text, at: 8), "Ln 3, Col 1")
        // Out-of-range locations clamp rather than trap.
        XCTAssertEqual(TextStats.position(in: text, at: 9_999), "Ln 3, Col 6")
        XCTAssertEqual(TextStats.position(in: text, at: -4), "Ln 1, Col 1")
        XCTAssertEqual(TextStats.position(in: "" as NSString, at: 0), "Ln 1, Col 1")

        // A composed character is one column, not two UTF-16 units.
        let emoji = "a👋b" as NSString
        XCTAssertEqual(TextStats.position(in: emoji, at: emoji.length), "Ln 1, Col 4")

        // And an inline image is a single glyph, so the caret after
        // "hi <image>" sits in column 5.
        let withImage = NoteText.render(
            "line\nhi \(NoteText.token(for: id))x",
            attributes: [.font: NSFont.systemFont(ofSize: 13)],
            assets: assets
        )
        let storage = NSTextStorage(attributedString: withImage).string as NSString
        XCTAssertEqual(storage.length, 10)   // "line\nhi " + U+FFFC + "x"
        XCTAssertEqual(TextStats.position(in: storage, at: 8), "Ln 2, Col 4")
        XCTAssertEqual(TextStats.position(in: storage, at: 9), "Ln 2, Col 5")
        XCTAssertEqual(TextStats.position(in: storage, at: 10), "Ln 2, Col 6")
    }

    func testVimModePreferenceIsOffUntilAskedFor() throws {
        let suite = "NotaTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)

        // The footer counts words and characters until told otherwise.
        XCTAssertEqual(preferences.footerSegments, [.words, .characters])
        XCTAssertTrue(preferences.footerShowsWords)
        XCTAssertTrue(preferences.footerShowsCharacters)
        XCTAssertFalse(preferences.footerShowsImages)
        XCTAssertFalse(preferences.footerShowsLines)
        XCTAssertTrue(preferences.footerShowsEncoding)
        XCTAssertTrue(preferences.footerShowsLineEndings)
        XCTAssertTrue(preferences.footerShowsCursorPosition)
        XCTAssertTrue(preferences.showsStatusBar)
        XCTAssertEqual(preferences.language, .system)
        preferences.footerShowsLines = true
        preferences.footerShowsWords = false
        preferences.footerShowsEncoding = false
        preferences.footerShowsCursorPosition = false
        preferences.showsStatusBar = false
        XCTAssertEqual(preferences.footerSegments, [.characters, .lines])
        XCTAssertEqual(Preferences(defaults: defaults).footerSegments, [.characters, .lines])
        XCTAssertFalse(Preferences(defaults: defaults).footerShowsEncoding)
        XCTAssertFalse(Preferences(defaults: defaults).footerShowsCursorPosition)
        XCTAssertFalse(Preferences(defaults: defaults).showsStatusBar)
        preferences.language = .simplifiedChinese
        XCTAssertEqual(Preferences(defaults: defaults).language, .simplifiedChinese)

        XCTAssertFalse(preferences.vimMode)
        preferences.vimMode = true
        XCTAssertTrue(Preferences(defaults: defaults).vimMode)
        preferences.vimMode = false
        XCTAssertFalse(Preferences(defaults: defaults).vimMode)

        // The badge is monochrome and typographic: sentence-case names, and
        // one capsule everywhere but insert, which shows the bare word.
        XCTAssertEqual(VimMode.normal.badgeTitle, "Normal")
        XCTAssertEqual(VimMode.operatorPending.badgeTitle, "Normal")
        XCTAssertEqual(VimMode.insert.badgeTitle, "Insert")
        XCTAssertEqual(VimMode.visual.badgeTitle, "Visual")
        XCTAssertEqual(VimMode.visualLine.badgeTitle, "Visual")
        XCTAssertEqual(VimMode.replace.badgeTitle, "Replace")
        XCTAssertTrue(VimMode.insert.showsCapsule)
        for mode in [VimMode.normal, .operatorPending, .visual, .visualLine,
                     .replace, .commandLine] {
            XCTAssertTrue(mode.showsCapsule, "\(mode) should wear the capsule")
        }
    }

    @MainActor
    func testFooterLaysOutLeftCentreRightWithoutOverlapping() throws {
        _ = NSApplication.shared
        let previous = Preferences.shared.vimMode
        defer { Preferences.shared.vimMode = previous }
        Preferences.shared.vimMode = true

        let directory = try makeTemporaryDirectory()
        let controller = MainWindowController(store: SessionStore(directory: directory))
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 820, height: 560))
        window.layoutIfNeeded()

        let footer = controller.footerRegions
        // The caret label lives inside the footer's trailing stack, so its
        // frame is the stack's; the counts and the badge stand in the
        // workspace itself. One coordinate space for every comparison.
        func inWorkspace(_ view: NSView) -> NSRect {
            view.superview?.convert(view.frame, to: footer.counts.superview) ?? view.frame
        }
        XCTAssertFalse(footer.badge.isHidden, "the badge shows while vim mode is on")
        XCTAssertFalse(footer.cursor.isHidden, "the caret position is always shown")
        // Nothing has been typed, so the pending keys stay away.
        XCTAssertTrue(footer.pendingKeys.isHidden)

        // An empty note: no words, no images, one line, caret at the top.
        XCTAssertEqual(footer.counts.stringValue, "0 words · 0 characters")
        XCTAssertEqual(footer.cursor.stringValue, "Ln 1, Col 1")

        // Left, centre, right — in that order, with real gaps between them.
        XCTAssertEqual(footer.badge.frame.height, 18)
        XCTAssertLessThan(footer.badge.frame.maxX, footer.counts.frame.minX)
        XCTAssertLessThan(footer.counts.frame.maxX, inWorkspace(footer.cursor).minX)
        // The counts sit centred in the window.
        let content = try XCTUnwrap(window.contentView)
        let centre = footer.counts.superview.map {
            $0.convert(NSPoint(x: footer.counts.frame.midX, y: 0), to: content).x
        } ?? 0
        XCTAssertEqual(centre, content.bounds.midX, accuracy: 1)

        // All three sit on one line, inside the footer strip.
        XCTAssertEqual(footer.counts.frame.midY, footer.badge.frame.midY, accuracy: 1)
        XCTAssertEqual(inWorkspace(footer.cursor).midY, footer.badge.frame.midY, accuracy: 1)

        // Zen fades the whole footer out with the rest of the chrome, and
        // giving it back respects the vim setting rather than showing
        // everything.
        controller.toggleZenMode()
        let faded = expectation(description: "chrome finished fading out")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { faded.fulfill() }
        wait(for: [faded], timeout: 2)
        XCTAssertTrue(footer.badge.isHidden)
        XCTAssertTrue(footer.counts.isHidden)
        XCTAssertTrue(footer.cursor.isHidden)

        controller.toggleZenMode()
        XCTAssertFalse(footer.badge.isHidden)
        XCTAssertFalse(footer.cursor.isHidden)
        XCTAssertTrue(footer.pendingKeys.isHidden)

        // With vim mode off the badge goes; the counts and caret stay.
        Preferences.shared.vimMode = false
        window.layoutIfNeeded()
        XCTAssertTrue(footer.badge.isHidden)
        XCTAssertFalse(footer.counts.isHidden)
        XCTAssertFalse(footer.cursor.isHidden)

        // Turning every segment on and squeezing the window sheds segments
        // instead of truncating one, and never runs into the caret.
        let previousImages = Preferences.shared.footerShowsImages
        let previousLines = Preferences.shared.footerShowsLines
        defer {
            Preferences.shared.footerShowsImages = previousImages
            Preferences.shared.footerShowsLines = previousLines
        }
        Preferences.shared.footerShowsImages = true
        Preferences.shared.footerShowsLines = true
        window.layoutIfNeeded()
        XCTAssertEqual(footer.counts.stringValue,
                       "0 words · 0 characters · 0 images · 1 line")

        let variants = TextStats.countVariants(
            words: 0, characters: 0, images: 0, lines: 1,
            segments: TextStats.Segment.allCases
        )

        // Which variant gets picked for a given width is covered on its own
        // in `testFooterPicksTheLongestCountsThatFit`; what matters here is
        // that whatever the footer ends up showing is a whole variant, laid
        // out at its full width — never a phrase cut off mid-word.
        for (width, pending) in [(820.0, ""), (600.0, "recording @a"), (900.0, "\"a2d")] {
            Preferences.shared.vimMode = !pending.isEmpty
            controller.setVimPendingKeys(pending)
            window.setContentSize(NSSize(width: width, height: 560))
            // Twice: choosing the text inside a layout pass invalidates the
            // label's intrinsic size, which the next pass acts on.
            window.layoutIfNeeded()
            window.layoutIfNeeded()

            let shown = footer.counts.stringValue
            XCTAssertTrue(variants.contains(shown),
                          "\(width)pt showed \(shown), which is not a whole variant")
            let font = try XCTUnwrap(footer.counts.font)
            let textWidth = (shown as NSString).size(withAttributes: [.font: font]).width
            XCTAssertEqual(footer.counts.frame.width, footer.counts.fittingSize.width,
                           accuracy: 1,
                           "the label must be laid out at its full width, not squeezed")
            XCTAssertGreaterThanOrEqual(footer.counts.frame.width, textWidth)
            XCTAssertLessThanOrEqual(footer.counts.frame.maxX, inWorkspace(footer.cursor).minX)
            if !pending.isEmpty {
                XCTAssertGreaterThanOrEqual(
                    footer.counts.frame.minX, footer.pendingKeys.frame.maxX
                )
            }
        }

        controller.setVimPendingKeys("")
        Preferences.shared.vimMode = false
        window.setContentSize(NSSize(width: 820, height: 560))
        window.layoutIfNeeded()
        XCTAssertEqual(footer.counts.stringValue, variants[0])

        // Nothing counted at all hides the middle label outright.
        let previousWords = Preferences.shared.footerShowsWords
        let previousCharacters = Preferences.shared.footerShowsCharacters
        defer {
            Preferences.shared.footerShowsWords = previousWords
            Preferences.shared.footerShowsCharacters = previousCharacters
        }
        Preferences.shared.footerShowsWords = false
        Preferences.shared.footerShowsCharacters = false
        Preferences.shared.footerShowsImages = false
        Preferences.shared.footerShowsLines = false
        window.layoutIfNeeded()
        XCTAssertTrue(footer.counts.isHidden)
        XCTAssertEqual(footer.counts.stringValue, "")
        // The caret position is not part of the deal — it stays.
        XCTAssertFalse(footer.cursor.isHidden)
    }

    // MARK: - Encoding and line endings in the footer (Todo 2)

    /// A file's own shape, read straight back off the tab that opened it:
    /// `Windows-1252 · CRLF` for a file that was that all along.
    @MainActor
    func testTheFooterShowsAFilesEncodingAndLineEndings() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeFooterFormatController(in: directory)
        let url = directory.appendingPathComponent("windows.txt")
        // "café\r\nbar" in Windows-1252: 0xE9 is é there.
        try Data([0x63, 0x61, 0x66, 0xE9, 0x0D, 0x0A, 0x62, 0x61, 0x72]).write(to: url)

        controller.open(url: url)

        XCTAssertEqual(controller.footerRegions.encoding.stringValue, "Windows-1252")
        XCTAssertEqual(controller.footerRegions.lineEnding.stringValue, "CRLF")
    }

    /// Picking another shape from either menu converts the note, marks the
    /// tab dirty, and ⌘S writes the bytes back in the new shape rather than
    /// the one the file was opened in.
    @MainActor
    func testConvertingEncodingAndLineEndingMarksDirtyAndSavesTheNewShape() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeFooterFormatController(in: directory)
        let url = directory.appendingPathComponent("windows.txt")
        try Data([0x63, 0x61, 0x66, 0xE9, 0x0D, 0x0A, 0x62, 0x61, 0x72]).write(to: url)
        controller.open(url: url)
        XCTAssertFalse(controller.currentTabState.isDirty)

        // The current one is ticked before anything is touched.
        let encodingMenu = try XCTUnwrap(controller.encodingMenu())
        let current = try XCTUnwrap(encodingMenu.items.first { $0.title == "Windows-1252" })
        XCTAssertEqual(current.state, .on)

        controller.convertEncoding(to: .utf8)
        XCTAssertTrue(controller.currentTabState.isDirty)
        XCTAssertEqual(controller.openNotes.last?.format.encoding, .utf8)
        XCTAssertEqual(controller.footerRegions.encoding.stringValue, "UTF-8")

        controller.convertLineEnding(to: .lf)
        XCTAssertEqual(controller.openNotes.last?.format.lineEnding, .lf)
        XCTAssertEqual(controller.footerRegions.lineEnding.stringValue, "LF")

        controller.saveCurrent(forcePanel: false)
        XCTAssertFalse(controller.currentTabState.isDirty, "the save just made caught up with it")
        let written = try Data(contentsOf: url)
        XCTAssertEqual(written, Data("café\nbar".utf8))
    }

    /// Picking the note's own shape again — or the same encoding under
    /// another name, UTF-16 while it is already UTF-16 the other way round —
    /// is a no-op, not a dirtying no-change.
    @MainActor
    func testPickingTheSameShapeAgainDoesNothing() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeFooterFormatController(in: directory)
        let url = directory.appendingPathComponent("big-endian.txt")
        try (Data([0xFE, 0xFF]) + "hi".data(using: .utf16BigEndian)!).write(to: url)
        controller.open(url: url)

        controller.convertEncoding(to: .utf16LittleEndian)
        XCTAssertEqual(controller.openNotes.last?.format.encoding, .utf16BigEndian,
                       "UTF-16 is one menu item either way round")
        XCTAssertFalse(controller.currentTabState.isDirty)

        controller.convertLineEnding(to: .lf)
        XCTAssertFalse(controller.currentTabState.isDirty, "the file had no CRLF to begin with")
    }

    /// An encoding the note's text cannot survive — an emoji into Latin-1 —
    /// keeps the old encoding and is not even offered.
    @MainActor
    func testAnEncodingTheTextCannotHoldIsRefusedAndTheMenuItemIsDisabled() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeFooterFormatController(in: directory)
        controller.newTab()
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        let textView = try XCTUnwrap(descendant(of: content, ofType: NotaTextView.self))
        textView.string = "rocket 🚀"

        let menu = try XCTUnwrap(controller.encodingMenu())
        let latin1 = try XCTUnwrap(menu.items.first { $0.title == "Latin-1" })
        XCTAssertFalse(latin1.isEnabled, "an emoji cannot survive Latin-1")
        XCTAssertNotNil(latin1.toolTip, "the quiet way of saying why")
        let utf16 = try XCTUnwrap(menu.items.first { $0.title == "UTF-16" })
        XCTAssertTrue(utf16.isEnabled, "UTF-16 holds anything Unicode does")

        controller.convertEncoding(to: .isoLatin1)
        XCTAssertEqual(controller.openNotes.last?.format.encoding, .utf8, "refused, not widened")
        XCTAssertFalse(controller.currentTabState.isDirty, "nothing changed, so nothing to save")
    }

    // MARK: - The command pane

    @MainActor
    func testTheCommandPaneOverlaysTheEditorWithoutMovingIt() throws {
        _ = NSApplication.shared
        let directory = try makeTemporaryDirectory()
        let controller = MainWindowController(store: SessionStore(directory: directory))
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()

        let scrollView = try XCTUnwrap(descendant(of: content, ofType: NSScrollView.self))
        let pane = try XCTUnwrap(descendant(of: content, ofType: VimCommandPane.self))
        XCTAssertTrue(pane.isHidden, "nothing to show at rest")
        let editorFrame = scrollView.frame

        controller.vim.beginPrompt(":")
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.commandPaneState.isVisible)
        XCTAssertEqual(controller.commandPaneState.text, ":\u{258F}", "the prefix and a caret")
        XCTAssertEqual(scrollView.frame, editorFrame, "the editor does not move for it")

        // It lies over the bottom of the editor, under the footer.
        let paneFrame = pane.convert(pane.bounds, to: content)
        let editor = scrollView.convert(scrollView.bounds, to: content)
        XCTAssertGreaterThanOrEqual(paneFrame.minY, editor.minY)
        XCTAssertLessThanOrEqual(paneFrame.maxY, editor.maxY)
        XCTAssertEqual(paneFrame.height, VimCommandPane.height)

        controller.vim.cancelPrompt()
        XCTAssertFalse(controller.commandPaneState.isVisible, "Escape collapses it")

        // Zen takes the footer away; the pane goes to the window's own edge
        // rather than with it.
        controller.vim.beginPrompt(":")
        controller.toggleZenMode()
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.commandPaneState.isVisible, "`:` still works in zen mode")
        XCTAssertEqual(pane.convert(pane.bounds, to: content).minY, 0, accuracy: 0.5)
    }

    @MainActor
    func testTheCommandPaneDrawsPromptsAndMessagesDifferently() throws {
        let pane = VimCommandPane(inset: 16)
        XCTAssertTrue(pane.isHidden)

        pane.showPrompt(":wq")
        XCTAssertFalse(pane.isHidden)
        XCTAssertEqual(pane.text, ":wq\u{258F}")
        XCTAssertFalse(pane.isShowingMessage)

        // The prompt's character is quieter than what was typed after it.
        let label = try XCTUnwrap(descendant(of: pane, ofType: NSTextField.self))
        let line = label.attributedStringValue
        XCTAssertEqual(
            line.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
            .secondaryLabelColor
        )
        XCTAssertEqual(
            line.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor,
            .labelColor
        )

        pane.showMessage("E486: Pattern not found: x")
        XCTAssertTrue(pane.isShowingMessage)
        XCTAssertEqual(pane.text, "E486: Pattern not found: x")
        XCTAssertEqual(
            label.attributedStringValue
                .attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
            .secondaryLabelColor,
            "a message is quiet all through"
        )

        pane.clear()
        XCTAssertTrue(pane.isHidden)
        XCTAssertFalse(pane.isShowingMessage)
    }

    // MARK: - The find bar

    /// ⌘F opens Nota's own pill in the top-trailing corner, with the keyboard
    /// in its field. AppKit's focus ring on a search field is a thick
    /// light-blue slab across the whole of it — the ⌘P picker already turns
    /// that off on its own field, and so does this one.
    ///
    /// The field gets a field editor of Nota's own, which is what keeps ⌘G
    /// working while the reader is typing in the bar: a nil-targeted
    /// `performTextFinderAction:` goes to the first responder, and while the
    /// pill is up that is the field editor rather than the note.
    @MainActor
    func testCommandFOpensTheFindBarWithNoFocusRingOnItsField() throws {
        let (_, textView, bar) = try makeFindBarController(text: "alpha beta alpha")
        XCTAssertFalse(bar.isShown, "nothing floats over the text at rest")
        XCTAssertEqual(bar.field.focusRingType, .none)
        XCTAssertEqual(bar.field.placeholderString, "Find in note")

        perform(.showFindInterface, on: textView)
        XCTAssertTrue(bar.isShown)

        let editor = try XCTUnwrap(
            bar.field.currentEditor() as? PillFieldEditor,
            "⌘G typed in the field has to reach the bar, not AppKit's own finder"
        )
        let next = NSMenuItem()
        next.tag = NSTextFinder.Action.nextMatch.rawValue
        XCTAssertTrue(editor.validateUserInterfaceItem(next), "and stay enabled there")
    }

    /// Typing lights every match at once and takes the first one at or after
    /// the caret — not the first in the note, and not one further down with
    /// every letter added.
    @MainActor
    func testTypingInTheFindBarLightsEveryMatchAndTakesTheOneAfterTheCaret() throws {
        let (_, textView, bar) = try makeFindBarController(
            text: "alpha beta alpha gamma alpha"
        )
        // Just past the first `alpha`.
        textView.setSelectedRange(NSRange(location: 7, length: 0))
        perform(.showFindInterface, on: textView)
        type("alpha", into: bar)

        XCTAssertEqual(textView.highlightedRanges, [
            NSRange(location: 0, length: 5),
            NSRange(location: 11, length: 5),
            NSRange(location: 23, length: 5),
        ])
        XCTAssertEqual(
            textView.findSession?.currentMatch, NSRange(location: 11, length: 5),
            "the first match at or after the caret is the one stood on"
        )
        XCTAssertEqual(
            textView.selectedRange(), NSRange(location: 11, length: 0),
            "a caret, not a selection — a selection would draw grey over the band"
        )
        XCTAssertEqual(bar.status, "2 of 3")

        // Temporary attributes: the layout manager has the bands, the storage
        // — and so the cache, and so the file — never does.
        let storage = try XCTUnwrap(textView.textStorage)
        XCTAssertNil(storage.attribute(.backgroundColor, at: 0, effectiveRange: nil))
        XCTAssertNotNil(textView.layoutManager?.temporaryAttribute(
            .backgroundColor, atCharacterIndex: 0, effectiveRange: nil
        ))

        // An empty field puts them all out again and says nothing.
        type("", into: bar)
        XCTAssertTrue(textView.highlightedRanges.isEmpty)
        XCTAssertNil(bar.status)
    }

    /// ⌘G and ⇧⌘G walk the matches and wrap round the ends, sent through the
    /// bar's own field editor — which is where they land while the reader is
    /// still typing the query.
    @MainActor
    func testFindNextAndPreviousWalkTheMatchesAndWrap() throws {
        let (_, textView, bar) = try makeFindBarController(
            text: "alpha beta alpha gamma alpha"
        )
        perform(.showFindInterface, on: textView)
        type("alpha", into: bar)
        XCTAssertEqual(textView.findSession?.currentMatch, NSRange(location: 0, length: 5))

        let editor = try XCTUnwrap(bar.field.currentEditor() as? PillFieldEditor)
        perform(.nextMatch, on: editor)
        XCTAssertEqual(textView.findSession?.currentMatch, NSRange(location: 11, length: 5))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 11, length: 0))
        XCTAssertEqual(bar.status, "2 of 3")
        perform(.nextMatch, on: editor)
        XCTAssertEqual(textView.findSession?.currentMatch, NSRange(location: 23, length: 5))
        perform(.nextMatch, on: editor)
        XCTAssertEqual(
            textView.findSession?.currentMatch, NSRange(location: 0, length: 5), "round the end"
        )
        XCTAssertEqual(bar.status, "1 of 3")
        perform(.previousMatch, on: editor)
        XCTAssertEqual(
            textView.findSession?.currentMatch, NSRange(location: 23, length: 5),
            "and round the top"
        )
    }

    /// `cafe` finds `Café`: the search reads case and accents the way the
    /// native bar did.
    @MainActor
    func testTheFindBarIgnoresCaseAndAccents() throws {
        let (_, textView, bar) = try makeFindBarController(text: "Café cafe CAFÉ")
        perform(.showFindInterface, on: textView)
        type("cafe", into: bar)
        XCTAssertEqual(textView.highlightedRanges.count, 3)
        XCTAssertEqual(bar.status, "1 of 3")
    }

    /// Escape closes the bar, leaves the match you were on selected, puts the
    /// keyboard back in the note — and hands the bands back to vim, whose own
    /// search draws with the same mechanism and had them first.
    @MainActor
    func testEscapeClosesTheFindBarAndHandsVimBackItsHighlights() throws {
        let previous = Preferences.shared.vimMode
        defer { Preferences.shared.vimMode = previous }
        Preferences.shared.vimMode = true

        let (controller, textView, bar) = try makeFindBarController(text: "alpha beta alpha")
        let window = try XCTUnwrap(controller.window)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        // `*`: vim lights both `alpha`s and remembers the pattern.
        controller.vim.searchWordUnderCaret(forward: true)
        let vimRanges = textView.highlightedRanges
        XCTAssertEqual(vimRanges.count, 2, "vim's own search lit both")

        perform(.showFindInterface, on: textView)
        type("beta", into: bar)
        XCTAssertEqual(
            textView.highlightedRanges, [NSRange(location: 6, length: 4)],
            "⌘F owns the bands for as long as it is up"
        )

        try escape(bar)
        XCTAssertFalse(bar.isShown)
        XCTAssertEqual(
            textView.selectedRange(), NSRange(location: 6, length: 4),
            "the match you were on stays selected"
        )
        XCTAssertEqual(textView.highlightedRanges, vimRanges, "and vim gets its own back")
        XCTAssertTrue(window.firstResponder === textView, "the keyboard goes back to the note")
    }

    /// ⌘E takes the query from the selection without opening anything, and
    /// puts it on the find pasteboard, so ⌘G walks from there with the bar
    /// still closed.
    @MainActor
    func testUseSelectionForFindTakesTheQueryFromTheSelection() throws {
        let board = NSPasteboard(name: .find)
        let previous = board.string(forType: .string)
        defer {
            board.clearContents()
            if let previous { board.setString(previous, forType: .string) }
        }

        let (_, textView, bar) = try makeFindBarController(text: "alpha beta alpha")
        textView.setSelectedRange(NSRange(location: 6, length: 4))
        perform(.setSearchString, on: textView)

        XCTAssertFalse(bar.isShown, "⌘E seeds the query; it does not open the bar")
        XCTAssertEqual(bar.query, "beta")
        XCTAssertEqual(board.string(forType: .string), "beta")

        perform(.nextMatch, on: textView)
        XCTAssertEqual(
            textView.selectedRange(), NSRange(location: 6, length: 4),
            "the only match, come round the end again"
        )
    }

    /// The bar was searching the tab you are leaving, and its bands are laid
    /// on the storage that goes with it.
    @MainActor
    func testSwitchingTabsClosesTheFindBar() throws {
        let (controller, textView, bar) = try makeFindBarController(text: "alpha beta alpha")
        perform(.showFindInterface, on: textView)
        type("alpha", into: bar)
        XCTAssertFalse(textView.highlightedRanges.isEmpty)

        controller.newTab()
        XCTAssertFalse(bar.isShown)
        XCTAssertTrue(textView.highlightedRanges.isEmpty)
    }

    /// A single letter typed into the bar over a megabyte of text must not
    /// lay a hundred thousand bands on the main thread between one keystroke
    /// and the next. The scan stops at the cap, and the count says so rather
    /// than reporting a total it never counted.
    @MainActor
    func testTheFindBarCapsItsBandsOnABigNote() throws {
        let (_, textView, bar) = try makeFindBarController(
            text: String(repeating: "alpha beta gamma\n", count: 60_000)
        )
        perform(.showFindInterface, on: textView)

        let started = Date()
        type("a", into: bar)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(textView.highlightedRanges.count, TextFindSession.highlightLimit)
        XCTAssertEqual(bar.status, "1 of \(TextFindSession.highlightLimit)+")
        XCTAssertLessThan(elapsed, 1, "the scan stops at the cap rather than walking the note")
    }

    /// The match you are standing on wears a band of its own. The selection
    /// alone will not do it: the keyboard is in the find field, so the
    /// selection draws in the inactive grey, which is very nearly the quiet
    /// band the other matches wear.
    @MainActor
    func testTheCurrentMatchWearsTheFindHighlightAndTheOthersDoNot() throws {
        let (_, textView, bar) = try makeFindBarController(
            text: "alpha beta alpha gamma alpha"
        )
        perform(.showFindInterface, on: textView)
        type("alpha", into: bar)

        let quiet = NSTextView.quietFindBand(alpha: 0.12)
        XCTAssertEqual(background(of: textView, at: 0), .findHighlightColor)
        XCTAssertEqual(
            foreground(of: textView, at: 0), .black, "black text on AppKit's find yellow"
        )
        XCTAssertEqual(background(of: textView, at: 11), quiet)
        XCTAssertEqual(background(of: textView, at: 23), quiet)
        XCTAssertNil(foreground(of: textView, at: 11), "only the current match is spelled out")

        // ⌘G moves the band with the reader.
        let editor = try XCTUnwrap(bar.field.currentEditor() as? PillFieldEditor)
        perform(.nextMatch, on: editor)
        XCTAssertEqual(textView.findSession?.currentMatch, NSRange(location: 11, length: 5))
        XCTAssertEqual(background(of: textView, at: 11), .findHighlightColor)
        XCTAssertEqual(foreground(of: textView, at: 11), .black)
        XCTAssertEqual(background(of: textView, at: 0), quiet, "and leaves the one it came from")
        XCTAssertNil(foreground(of: textView, at: 0))

        // The quiet band is the faint label wash in light mode, and a dimmed
        // find yellow in dark mode, where the wash was invisible.
        func resolved(in appearance: NSAppearance.Name) -> NSColor? {
            var colour: NSColor?
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                colour = quiet.usingColorSpace(.sRGB)
            }
            return colour
        }
        let light = try XCTUnwrap(resolved(in: .aqua))
        let dark = try XCTUnwrap(resolved(in: .darkAqua))
        XCTAssertEqual(light.alphaComponent, 0.12, accuracy: 0.001)
        XCTAssertEqual(dark.alphaComponent, 0.3, accuracy: 0.001)
        XCTAssertGreaterThan(dark.redComponent + dark.greenComponent, dark.blueComponent * 2,
                             "yellow, not a grey wash")

        // Closing puts all of it down, the black text with it.
        try escape(bar)
        XCTAssertNil(background(of: textView, at: 0))
        XCTAssertNil(background(of: textView, at: 11))
        XCTAssertNil(foreground(of: textView, at: 11))
        XCTAssertTrue(textView.highlightedRanges.isEmpty)
    }

    @MainActor
    private func background(of textView: NSTextView, at index: Int) -> NSColor? {
        textView.layoutManager?.temporaryAttribute(
            .backgroundColor, atCharacterIndex: index, effectiveRange: nil
        ) as? NSColor
    }

    @MainActor
    private func foreground(of textView: NSTextView, at index: Int) -> NSColor? {
        textView.layoutManager?.temporaryAttribute(
            .foregroundColor, atCharacterIndex: index, effectiveRange: nil
        ) as? NSColor
    }

    /// Nothing in the note is selected while the bar is open. The keyboard is
    /// in the find field, so a selection would draw unemphasized — a flat
    /// grey, laid over the top of the yellow band and hiding the one thing
    /// that says where the reader is. The caret sits at the match's start and
    /// the band does the talking; closing hands the match over for real.
    @MainActor
    func testTheFindBarLeavesTheCurrentMatchUnselectedWhileItIsOpen() throws {
        let (_, textView, bar) = try makeFindBarController(text: "alpha beta alpha")
        perform(.showFindInterface, on: textView)
        type("alpha", into: bar)

        XCTAssertEqual(
            textView.selectedRange(), NSRange(location: 0, length: 0), "a caret, not a selection"
        )
        XCTAssertEqual(textView.findSession?.currentMatch, NSRange(location: 0, length: 5))
        XCTAssertEqual(background(of: textView, at: 0), .findHighlightColor)

        let editor = try XCTUnwrap(bar.field.currentEditor() as? PillFieldEditor)
        perform(.nextMatch, on: editor)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 11, length: 0))
        XCTAssertEqual(textView.findSession?.currentMatch, NSRange(location: 11, length: 5))
        XCTAssertEqual(background(of: textView, at: 11), .findHighlightColor)

        // A click somewhere else in the note is a new place to walk from.
        textView.setSelectedRange(NSRange(location: 6, length: 0))
        perform(.nextMatch, on: editor)
        XCTAssertEqual(
            textView.findSession?.currentMatch, NSRange(location: 11, length: 5),
            "the first match after where the reader put the caret"
        )

        try escape(bar)
        XCTAssertEqual(
            textView.selectedRange(), NSRange(location: 11, length: 5),
            "and closing hands it over as a real selection"
        )
    }

    /// An edit under an open bar moves the matches. The native bar re-ran its
    /// search on every change; this one waits for the keystrokes to stop, the
    /// same 150 ms the render waits, and a note past `BigFile.threshold` is
    /// left alone entirely.
    @MainActor
    func testEditingUnderTheFindBarRescansOnceTheKeystrokesStop() throws {
        let (_, textView, bar) = try makeFindBarController(text: "alpha beta")
        perform(.showFindInterface, on: textView)
        type("alpha", into: bar)
        XCTAssertEqual(bar.status, "1 of 1")
        XCTAssertEqual(textView.highlightedRanges.count, 1)

        // Typed at the end, the way a reader would, so the editor hears it.
        textView.setSelectedRange(NSRange(location: 10, length: 0))
        textView.insertText(" alpha", replacementRange: textView.selectedRange())
        XCTAssertEqual(
            textView.highlightedRanges.count, 1,
            "nothing re-scans while the keys are still coming"
        )

        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(textView.highlightedRanges, [
            NSRange(location: 0, length: 5),
            NSRange(location: 11, length: 5),
        ], "and the new match is lit once they stop")
        XCTAssertEqual(
            bar.status, "2 matches",
            "the caret is not on a match any more, so there is nothing to count from"
        )
    }

    // MARK: - The find bar: replacing

    /// ⌥⌘F opens the same pill with its second row out, and Return in the
    /// replace field changes the match being stood on and walks to the next.
    /// The edit goes in as an ordinary edit: one undo puts it back.
    @MainActor
    func testReplaceChangesOnlyTheMatchYouAreOnAndLandsOnTheNext() throws {
        let (_, textView, bar) = try makeFindBarController(
            text: "alpha beta alpha gamma alpha"
        )
        perform(.showReplaceInterface, on: textView)
        XCTAssertTrue(bar.isShown)
        XCTAssertTrue(bar.isExpanded, "⌥⌘F brings the second pill out with it")
        XCTAssertTrue(bar.replacePill.isShown)
        XCTAssertEqual(bar.stackHeight, PillView.height + PillView.gap + PillView.height)

        type("alpha", into: bar)
        bar.replaceField.stringValue = "delta"
        bar.focusReplaceField()
        XCTAssertEqual(textView.findSession?.currentMatch, NSRange(location: 0, length: 5))

        try returnInReplaceField(bar)
        XCTAssertEqual(
            textView.string, "delta beta alpha gamma alpha", "only the one being stood on"
        )
        XCTAssertEqual(
            textView.findSession?.currentMatch, NSRange(location: 11, length: 5),
            "and it lands on the next"
        )
        XCTAssertEqual(bar.status, "1 of 2")

        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "alpha beta alpha gamma alpha")
    }

    /// A reader who has clicked away from the match is walked to the next one
    /// rather than having whatever the caret landed in replaced under them.
    @MainActor
    func testReplaceWalksOnWhenTheReaderHasMovedOffTheMatch() throws {
        let (_, textView, bar) = try makeFindBarController(text: "alpha beta alpha")
        perform(.showReplaceInterface, on: textView)
        type("alpha", into: bar)
        bar.replaceField.stringValue = "x"
        bar.focusReplaceField()

        textView.setSelectedRange(NSRange(location: 7, length: 0))
        try returnInReplaceField(bar)
        XCTAssertEqual(textView.string, "alpha beta alpha", "nothing was replaced")
        XCTAssertEqual(
            textView.findSession?.currentMatch, NSRange(location: 11, length: 5),
            "it stepped to the next match instead"
        )
    }

    /// ⌥Return replaces every match in the note, in one edit — one undo, not
    /// one per match — and leaves the reader where they were.
    @MainActor
    func testReplaceAllChangesEveryMatchInOneUndo() throws {
        let (_, textView, bar) = try makeFindBarController(
            text: "alpha beta alpha gamma alpha"
        )
        perform(.showReplaceInterface, on: textView)
        type("alpha", into: bar)
        bar.replaceField.stringValue = "x"
        bar.focusReplaceField()

        try returnInReplaceField(bar, all: true)
        XCTAssertEqual(textView.string, "x beta x gamma x")
        XCTAssertEqual(bar.status, "No matches")
        XCTAssertTrue(textView.highlightedRanges.isEmpty)

        textView.undoManager?.undo()
        XCTAssertEqual(
            textView.string, "alpha beta alpha gamma alpha", "one undo, not three"
        )
    }

    /// Escape closes the bar from the replace field too, and the row it was
    /// showing is remembered for the next time ⌘F opens in this column.
    @MainActor
    func testEscapeInTheReplaceFieldClosesTheFindBar() throws {
        let (_, textView, bar) = try makeFindBarController(text: "alpha beta")
        perform(.showReplaceInterface, on: textView)
        type("alpha", into: bar)
        bar.focusReplaceField()

        let editor = try XCTUnwrap(bar.replaceField.currentEditor() as? NSTextView)
        _ = bar.replacePill.control(
            bar.replaceField, textView: editor,
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        )
        XCTAssertFalse(bar.isShown)
        XCTAssertTrue(bar.isExpanded, "the row is remembered for next time")
    }

    /// Return, or ⌥Return, in the pill's replace field — as AppKit hands it
    /// to the delegate.
    @MainActor
    private func returnInReplaceField(_ bar: FindBarView, all: Bool = false) throws {
        let editor = try XCTUnwrap(bar.replaceField.currentEditor() as? NSTextView)
        _ = bar.replacePill.control(
            bar.replaceField, textView: editor,
            doCommandBy: all
                ? #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
                : #selector(NSResponder.insertNewline(_:))
        )
    }

    // MARK: - Go to line

    /// ⌘L opens its own pill in the same corner, saying how many lines there
    /// are to aim inside.
    @MainActor
    func testCommandLOpensTheGoToLinePillWithTheLineTotal() throws {
        let (controller, textView, pill) = try makeGoToLineController()
        XCTAssertFalse(pill.isShown)
        XCTAssertTrue(controller.canGoToLine)

        controller.showGoToLine()
        XCTAssertTrue(pill.isShown)
        XCTAssertEqual(pill.status, "200 lines")
        XCTAssertEqual(pill.field.focusRingType, .none)
        XCTAssertEqual(pill.field.placeholderString, "Go to line")
        XCTAssertTrue(
            pill.field.currentEditor() is PillFieldEditor, "the pill's own field editor"
        )
        _ = textView
    }

    /// Typing moves as you go: the caret lands on the first thing on the line
    /// that is not a space, and the line is brought into view.
    @MainActor
    func testTypingInTheGoToLinePillMovesTheCaretAndScrolls() throws {
        let (controller, textView, pill) = try makeGoToLineController()
        let scrollView = try XCTUnwrap(textView.enclosingScrollView)
        controller.showGoToLine()
        let restingScroll = scrollView.contentView.bounds.origin

        let index = LineIndex(textView.string as NSString)
        type("12", into: pill)
        XCTAssertEqual(
            textView.selectedRange(),
            NSRange(location: index.range(ofLine: 12).location + 4, length: 0),
            "past the indent, on the first thing that is not a space"
        )

        type("150", into: pill)
        XCTAssertEqual(
            textView.selectedRange().location, index.range(ofLine: 150).location + 4
        )
        XCTAssertGreaterThan(
            scrollView.contentView.bounds.origin.y, restingScroll.y, "and the view followed"
        )
    }

    /// `N:M` lands on the column, 1-based and clamped to the line's own end.
    @MainActor
    func testGoToLineTakesALineAndColumn() throws {
        let (controller, textView, pill) = try makeGoToLineController()
        controller.showGoToLine()
        let index = LineIndex(textView.string as NSString)

        type("12:3", into: pill)
        XCTAssertEqual(
            textView.selectedRange().location, index.range(ofLine: 12).location + 2
        )

        // Past the end of the line is the end of the line, never the next one.
        type("12:999", into: pill)
        let line = index.range(ofLine: 12)
        XCTAssertEqual(
            textView.selectedRange().location, line.location + line.length - 1,
            "clamped to the line, in front of its newline"
        )
    }

    /// A number past the end lands on the last line rather than refusing; a
    /// word is not a line at all, and the caret is left where it was.
    @MainActor
    func testGoToLineClampsPastTheEndAndRefusesJunk() throws {
        let (controller, textView, pill) = try makeGoToLineController()
        controller.showGoToLine()
        let index = LineIndex(textView.string as NSString)

        type("9999", into: pill)
        XCTAssertEqual(
            textView.selectedRange().location, index.range(ofLine: 200).location + 4
        )
        XCTAssertEqual(pill.status, "200 lines")

        let landed = textView.selectedRange()
        type("banana", into: pill)
        XCTAssertEqual(pill.status, "Not a line")
        XCTAssertEqual(textView.selectedRange(), landed, "junk moves nothing")
    }

    /// Escape puts the caret and the view back where the pill found them;
    /// Return leaves the place the number found.
    @MainActor
    func testGoToLineEscapeRestoresAndReturnKeepsThePlace() throws {
        let (controller, textView, pill) = try makeGoToLineController()
        let scrollView = try XCTUnwrap(textView.enclosingScrollView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        controller.showGoToLine()
        let restingScroll = scrollView.contentView.bounds.origin

        type("150", into: pill)
        XCTAssertGreaterThan(textView.selectedRange().location, 0)
        try key(#selector(NSResponder.cancelOperation(_:)), in: pill)

        XCTAssertFalse(pill.isShown)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, restingScroll.y, accuracy: 0.5)
        XCTAssertTrue(
            controller.window?.firstResponder === textView, "the keyboard goes back to the text"
        )

        controller.showGoToLine()
        type("150", into: pill)
        let landed = textView.selectedRange()
        try key(#selector(NSResponder.insertNewline(_:)), in: pill)
        XCTAssertFalse(pill.isShown)
        XCTAssertEqual(textView.selectedRange(), landed, "Return keeps the place")
    }

    /// One corner, one pill: opening either sends the other away.
    @MainActor
    func testTheFindBarAndTheGoToLinePillShareTheCorner() throws {
        let (controller, textView, pill) = try makeGoToLineController()
        let column = try XCTUnwrap(textView.enclosingScrollView?.superview)
        let bar = try XCTUnwrap(descendant(of: column, ofType: FindBarView.self))

        controller.showGoToLine()
        XCTAssertTrue(pill.isShown)

        perform(.showFindInterface, on: textView)
        XCTAssertTrue(bar.isShown)
        XCTAssertFalse(pill.isShown, "⌘F takes the corner")

        controller.showGoToLine()
        XCTAssertTrue(pill.isShown)
        XCTAssertFalse(bar.isShown, "and ⌘L takes it back")
    }

    /// A window with a note of 200 lines in it and ⌘L's pill to hand. Line 12
    /// and every other line is indented, so "the first thing that is not a
    /// space" has something to mean.
    @MainActor
    private func makeGoToLineController() throws
        -> (MainWindowController, NotaTextView, GoToLinePill) {
        let text = (1...200).map { "    line \($0)" }.joined(separator: "\n")
        let (controller, textView, _) = try makeFindBarController(text: text)
        let column = try XCTUnwrap(textView.enclosingScrollView?.superview)
        let pill = try XCTUnwrap(descendant(of: column, ofType: GoToLinePill.self))
        return (controller, textView, pill)
    }

    /// A number typed into ⌘L's field, as AppKit reports it.
    @MainActor
    private func type(_ number: String, into pill: GoToLinePill) {
        pill.query = number
        pill.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: pill.field)
        )
    }

    /// Return or Escape in ⌘L's field, as AppKit hands it to the delegate.
    @MainActor
    private func key(_ selector: Selector, in pill: GoToLinePill) throws {
        let editor = try XCTUnwrap(pill.field.currentEditor() as? NSTextView)
        _ = pill.control(pill.field, textView: editor, doCommandBy: selector)
    }

    /// A window with a note in it and the editor's own find bar to hand. The
    /// render has one of its own, so the bar is looked for inside the editor
    /// column rather than anywhere in the window.
    @MainActor
    private func makeFindBarController(
        text: String
    ) throws -> (MainWindowController, NotaTextView, FindBarView) {
        _ = NSApplication.shared
        let directory = try makeTemporaryDirectory()
        let controller = MainWindowController(store: SessionStore(directory: directory))
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 820, height: 560))
        window.makeKeyAndOrderFrontOffscreen()
        window.layoutIfNeeded()

        let content = try XCTUnwrap(window.contentView)
        let textView = try XCTUnwrap(descendant(of: content, ofType: NotaTextView.self))
        textView.string = text
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        let column = try XCTUnwrap(textView.enclosingScrollView?.superview)
        let bar = try XCTUnwrap(descendant(of: column, ofType: FindBarView.self))
        return (controller, textView, bar)
    }

    /// The route the Find menu takes: a nil-targeted item tagged with the
    /// finder action, sent to whatever text view has the keyboard.
    @MainActor
    private func perform(_ action: NSTextFinder.Action, on textView: NSTextView) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        textView.performTextFinderAction(item)
    }

    /// A query typed into the field, as AppKit reports it.
    @MainActor
    private func type(_ query: String, into bar: FindBarView) {
        bar.query = query
        bar.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: bar.field)
        )
    }

    /// Escape in the field, as AppKit hands it to the delegate.
    @MainActor
    private func escape(_ bar: FindBarView) throws {
        let editor = try XCTUnwrap(bar.field.currentEditor() as? NSTextView)
        _ = bar.control(
            bar.field, textView: editor,
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        )
    }

    /// The first view of a kind anywhere under another.
    @MainActor
    private func descendant<T: NSView>(of view: NSView, ofType type: T.Type) -> T? {
        for subview in view.subviews {
            if let match = subview as? T { return match }
            if let match = descendant(of: subview, ofType: type) { return match }
        }
        return nil
    }

    // MARK: - Word wrap

    /// Settings → "Word wrap". On, a long line folds and the content is
    /// exactly as wide as the column. Off, the line runs on and the editor
    /// scrolls sideways to follow it.
    @MainActor
    func testWordWrapTogglesHorizontalScrolling() throws {
        _ = NSApplication.shared
        let previous = Preferences.shared.wrapsLines
        defer { Preferences.shared.wrapsLines = previous }
        Preferences.shared.wrapsLines = true

        let directory = try makeTemporaryDirectory()
        let controller = MainWindowController(store: SessionStore(directory: directory))
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 820, height: 560))
        window.layoutIfNeeded()

        let editor = controller.editorScrolling
        let container = try XCTUnwrap(editor.container)
        let long = String(repeating: "the quick brown fox ", count: 60)
        editor.textView.insertText(long, replacementRange: editor.textView.selectedRange())
        window.layoutIfNeeded()

        // Wrapping: the container is welded to the text view, no sideways
        // scroller, and the content is no wider than what is on screen.
        XCTAssertTrue(container.widthTracksTextView)
        XCTAssertFalse(editor.scrollView.hasHorizontalScroller)
        XCTAssertEqual(
            editor.textView.frame.width, controller.editorScrolling.visibleWidth, accuracy: 1
        )

        Preferences.shared.wrapsLines = false
        window.layoutIfNeeded()

        // Not wrapping: the container is unbounded, the scroller is there, and
        // the one long line is wider than the column showing it.
        XCTAssertFalse(container.widthTracksTextView)
        XCTAssertTrue(editor.scrollView.hasHorizontalScroller)
        XCTAssertGreaterThan(
            editor.textView.frame.width, controller.editorScrolling.visibleWidth + 1
        )
        // The gutter is a ruler, so it keeps its own strip at the left edge
        // whatever the text does.
        XCTAssertTrue(editor.scrollView.rulersVisible)

        Preferences.shared.wrapsLines = true
        window.layoutIfNeeded()

        // And back: tracking restored, scroller gone, content back in the column.
        XCTAssertTrue(container.widthTracksTextView)
        XCTAssertFalse(editor.scrollView.hasHorizontalScroller)
        XCTAssertEqual(
            editor.textView.frame.width, controller.editorScrolling.visibleWidth, accuracy: 1
        )
    }

    /// With wrap off the text view is sized to its own text rather than
    /// stretched to the column, so a short note has to keep filling the column
    /// as the window grows — otherwise a click to the right of the text lands
    /// nowhere. Being the scroll view's document view is what carries that
    /// floor; this pins the behaviour down.
    @MainActor
    func testWordWrapKeepsAShortNoteFillingAWidenedColumn() throws {
        _ = NSApplication.shared
        let previous = Preferences.shared.wrapsLines
        defer { Preferences.shared.wrapsLines = previous }
        Preferences.shared.wrapsLines = false

        let directory = try makeTemporaryDirectory()
        let controller = MainWindowController(store: SessionStore(directory: directory))
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 600, height: 400))
        window.layoutIfNeeded()

        let editor = controller.editorScrolling
        editor.textView.insertText("short", replacementRange: editor.textView.selectedRange())
        window.layoutIfNeeded()
        XCTAssertGreaterThanOrEqual(
            editor.textView.frame.width, controller.editorScrolling.visibleWidth - 1
        )

        window.setContentSize(NSSize(width: 1000, height: 400))
        window.layoutIfNeeded()

        let widened = controller.editorScrolling.visibleWidth
        XCTAssertGreaterThan(widened, 600, "the column really did grow")
        XCTAssertGreaterThanOrEqual(editor.textView.frame.width, widened - 1)
    }

    // MARK: - Zen mode

    @MainActor
    func testZenModeTogglesAndRestores() throws {
        _ = NSApplication.shared
        // The chrome must be up to begin with, whatever an interrupted run
        // left in the test defaults.
        let prefs = Preferences.shared
        let originals = (prefs.hidesTabBar, prefs.autoHidesTabBar, prefs.hidesTrafficLights)
        defer {
            prefs.hidesTabBar = originals.0
            prefs.autoHidesTabBar = originals.1
            prefs.hidesTrafficLights = originals.2
        }
        prefs.hidesTabBar = false
        prefs.autoHidesTabBar = false
        prefs.hidesTrafficLights = false
        let directory = try makeTemporaryDirectory()
        let controller = MainWindowController(store: SessionStore(directory: directory))
        let window = try XCTUnwrap(controller.window)

        // Chrome is up, traffic lights visible, and zen is off on launch.
        XCTAssertFalse(controller.isZenMode)
        XCTAssertFalse(window.standardWindowButton(.closeButton)?.isHidden ?? true)

        controller.toggleZenMode()
        XCTAssertTrue(controller.isZenMode)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertTrue(
                window.standardWindowButton(button)?.isHidden ?? false,
                "\(button) should be hidden in zen"
            )
        }

        controller.toggleZenMode()
        XCTAssertFalse(controller.isZenMode)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertFalse(
                window.standardWindowButton(button)?.isHidden ?? true,
                "\(button) should come back"
            )
        }

        // The outer split survives the round trip intact: the document
        // workspace and the image sidebar. The preview is nested inside the
        // workspace so its divider starts below the shared tabs.
        XCTAssertEqual(
            (window.contentViewController as? NSSplitViewController)?.splitViewItems.count, 2
        )
    }

    // MARK: - Gutter separator

    func testTheSidebarNeverResizesTheWindow() throws {
        _ = NSApplication.shared
        let directory = try makeTemporaryDirectory()
        let controller = MainWindowController(store: SessionStore(directory: directory))
        let window = try XCTUnwrap(controller.window)
        let split = try XCTUnwrap(window.contentViewController as? NSSplitViewController)
        // The thumbnails are the one thing left that collapses, and they
        // make their sibling give up room rather than changing the window
        // frame. The document's own two columns never collapse at all — a
        // preview mode is a divider position, and a divider asks the window
        // for nothing.
        let documentSplit = try XCTUnwrap(
            split.children.lazy
                .flatMap(\.children)
                .compactMap { $0 as? NSSplitViewController }
                .first
        )
        let collapsible = (split.splitViewItems + documentSplit.splitViewItems)
            .filter(\.canCollapse)
        XCTAssertEqual(collapsible.count, 1)
        for item in collapsible {
            XCTAssertEqual(item.collapseBehavior, .preferResizingSiblingsWithFixedSplitView)
        }
        XCTAssertTrue(
            documentSplit.splitViewItems.allSatisfy { !$0.canCollapse },
            "neither document column collapses for a mode"
        )
    }

    func testTextSitsCloserToTheGutterWhileTheRightMarginKeepsTheSetting() throws {
        _ = NSApplication.shared
        let previousNumbers = Preferences.shared.showsLineNumbers
        let previousPadding = Preferences.shared.padding
        defer {
            Preferences.shared.showsLineNumbers = previousNumbers
            Preferences.shared.padding = previousPadding
        }
        Preferences.shared.padding = .normal
        Preferences.shared.showsLineNumbers = true

        let directory = try makeTemporaryDirectory()
        let controller = MainWindowController(store: SessionStore(directory: directory))
        _ = controller.window

        // Gutter on: 8pt off the numbers on the left, the setting on the right.
        XCTAssertTrue(controller.isGutterVisible)
        XCTAssertEqual(controller.horizontalTextInset, MainWindowController.gutterTextGap)
        XCTAssertEqual(
            controller.trailingTextInsetExtra,
            EditorPaddingOption.normal.inset - MainWindowController.gutterTextGap
        )
        XCTAssertEqual(
            controller.editorParagraphStyle?.tailIndent,
            -(EditorPaddingOption.normal.inset - MainWindowController.gutterTextGap)
        )

        // Gutter off: the plain symmetric padding, and no tail indent at all.
        Preferences.shared.showsLineNumbers = false
        XCTAssertFalse(controller.isGutterVisible)
        XCTAssertEqual(controller.horizontalTextInset, EditorPaddingOption.normal.inset)
        XCTAssertEqual(controller.trailingTextInsetExtra, 0)
        XCTAssertEqual(controller.editorParagraphStyle?.tailIndent, 0)
    }

    func testGutterSeparatorPreferenceRoundTrips() throws {
        let suite = "NotaTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)

        // Off until asked for, and it survives a fresh reader either way.
        XCTAssertFalse(preferences.showsGutterSeparator)
        preferences.showsGutterSeparator = true
        XCTAssertTrue(Preferences(defaults: defaults).showsGutterSeparator)
        preferences.showsGutterSeparator = false
        XCTAssertFalse(Preferences(defaults: defaults).showsGutterSeparator)
    }

    @MainActor
    func testGutterSeparatorHairlineHugsTheInnerEdge() throws {
        _ = NSApplication.shared
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let textView = makeTextView(assets: assets)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.documentView = textView
        let ruler = LineNumberRulerView(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.tile()

        // Off is the default, and off draws nothing at all.
        XCTAssertFalse(ruler.showsSeparator)
        XCTAssertNil(ruler.separatorRect)

        ruler.showsSeparator = true
        let hairline = try XCTUnwrap(ruler.separatorRect)
        // One device pixel wide, hard against the text, full height.
        XCTAssertEqual(hairline.width, 1 / (ruler.window?.backingScaleFactor ?? 1))
        XCTAssertGreaterThan(hairline.width, 0)
        XCTAssertLessThanOrEqual(hairline.width, 1)
        XCTAssertEqual(hairline.maxX, ruler.bounds.maxX)
        XCTAssertEqual(hairline.minY, ruler.bounds.minY)
        XCTAssertEqual(hairline.height, ruler.bounds.height)
        XCTAssertGreaterThan(hairline.height, 0)
    }

    // MARK: - Tab bar

    /// Every tab shows a leading file icon, whatever its kind
    /// (`FileKindIconTests` covers which symbol each kind gets).
    @MainActor
    func testEveryTabShowsALeadingFileIcon() throws {
        _ = NSApplication.shared
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 600, height: TabBarView.height))
        bar.setItems(
            (0..<3).map { TabBarItem(title: "Note \($0)", isDirty: false) },
            selectedIndex: 0
        )
        bar.layoutSubtreeIfNeeded()

        for index in 0..<3 {
            XCTAssertTrue(bar.hasFileIconForTesting(at: index))
        }
    }

    /// The strip sits in the title-bar region. If it tells AppKit that a
    /// press may move the window, the window drags *together with* the tab
    /// being reordered (the tab's own refusal was not honoured), which is
    /// what made every first drag move the window. The strip refuses and
    /// starts the empty-area window drag itself; a press on the icon must
    /// land on the tab, not on the image view.
    @MainActor
    func testStripNeverLetsAppKitMoveTheWindowAndIconPressesReachTheTab() throws {
        _ = NSApplication.shared
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 600, height: TabBarView.height))
        bar.setItems([TabBarItem(title: "Note", isDirty: false)], selectedIndex: 0)
        bar.layoutSubtreeIfNeeded()
        XCTAssertFalse(bar.mouseDownCanMoveWindow)

        let tab = try XCTUnwrap(bar.tabViewForTesting(at: 0))
        XCTAssertFalse(tab.mouseDownCanMoveWindow)
        // 14pt in from the tab's leading edge is inside the 16pt icon box.
        let onIcon = NSPoint(x: tab.frame.minX + 14, y: tab.frame.midY)
        XCTAssertTrue(bar.hitTest(onIcon) === tab, "a press on the icon is a press on the tab")
    }

    /// The strip does not scroll: every tab shares one width that shrinks as
    /// tabs are added, and they all stay on screen.
    @MainActor
    func testTabsShareOneWidthAndNoneAreHiddenUntilTheFloor() throws {
        _ = NSApplication.shared
        // 1000pt of tabs, plus whatever the trailing controls take past the +.
        let width = 1000 - 68 + TabStripLayout.trailingControls
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: width, height: TabBarView.height))
        bar.setItems(
            (0..<14).map { TabBarItem(title: "Note \($0)", isDirty: false) },
            selectedIndex: 0
        )
        bar.layoutSubtreeIfNeeded()

        let frames = bar.tabFramesForTesting
        XCTAssertEqual(frames.count, 14)
        XCTAssertEqual(bar.hiddenTabsForTesting, Array(repeating: false, count: 14),
                       "14 tabs still fit at 1000pt, so none is hidden")

        // Wide enough that even the selected tab is above its floor, so
        // every tab — selected included — shares one width.
        for frame in frames.dropFirst() {
            XCTAssertEqual(frame.width, frames[0].width, accuracy: 0.01)
        }
        for (index, frame) in frames.enumerated().dropFirst() {
            XCTAssertEqual(frame.minX, frames[index - 1].maxX + 4, accuracy: 0.01,
                           "tabs sit shoulder to shoulder with one gap")
        }
        XCTAssertTrue(bar.isSelectedTabFullyVisible())
    }

    /// Below the active width there is no trailing slot: no ✕ to hover, and
    /// the unsaved dot rides on the icon instead. Drawing the whole strip
    /// here also runs the separators, the clipped title and its fade.
    @MainActor
    func testANarrowTabDropsItsTrailingSlotAndTheStripStillDraws() throws {
        _ = NSApplication.shared
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 300, height: TabBarView.height))
        bar.setItems(
            (0..<6).map { TabBarItem(title: "A rather long note title \($0)", isDirty: true) },
            selectedIndex: 0
        )
        bar.layoutSubtreeIfNeeded()

        let narrow = try XCTUnwrap(bar.tabViewForTesting(at: 1))
        narrow.layoutSubtreeIfNeeded()
        XCTAssertLessThan(narrow.frame.width, 60, "six tabs at 300pt are past the slot's floor")
        XCTAssertTrue(
            narrow.subviews.compactMap { $0 as? NSButton }.allSatisfy(\.isHidden),
            "there is no ✕ to hover at this width"
        )

        let selected = try XCTUnwrap(bar.tabViewForTesting(at: 0))
        selected.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(selected.frame.width, 60)
        XCTAssertTrue(
            selected.subviews.contains { $0 is NSButton && !$0.isHidden },
            "the selected tab is held wide enough to keep its ✕"
        )

        // Draws the strip offscreen: separators, the clipped title, its fade
        // and the dot on the icon all run, and none of them may blow up.
        let rep = try XCTUnwrap(bar.bitmapImageRepForCachingDisplay(in: bar.bounds))
        bar.cacheDisplay(in: bar.bounds, to: rep)

        // The same drawing with room to spare, where the title is long
        // enough to be clipped and faded rather than fitted.
        let wide = TabBarView(frame: NSRect(x: 0, y: 0, width: 600, height: TabBarView.height))
        wide.setItems(
            [TabBarItem(title: String(repeating: "long title ", count: 8), isDirty: false)],
            selectedIndex: 0
        )
        wide.layoutSubtreeIfNeeded()
        let wideRep = try XCTUnwrap(wide.bitmapImageRepForCachingDisplay(in: wide.bounds))
        wide.cacheDisplay(in: wide.bounds, to: wideRep)
    }

    /// The + rides after the last tab and only pins at the trailing edge
    /// once the strip is full.
    @MainActor
    func testThePlusFollowsTheLastTabAndPinsOnceTheStripIsFull() throws {
        _ = NSApplication.shared
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 600, height: TabBarView.height))
        bar.setItems(
            (0..<3).map { TabBarItem(title: "Note \($0)", isDirty: false) },
            selectedIndex: 0
        )
        bar.layoutSubtreeIfNeeded()

        let lastTab = try XCTUnwrap(bar.tabFramesForTesting.last)
        XCTAssertEqual(bar.newTabButtonFrameForTesting.minX, lastTab.maxX + 4, accuracy: 0.01)
        XCTAssertLessThan(bar.newTabButtonFrameForTesting.maxX, bar.bounds.maxX,
                          "a half-empty strip does not park the + at the edge")

        // Twelve tabs at their floors (one at 60, eleven at 40, eleven gaps)
        // plus the +, its gap, and the trailing controls — the bookmark
        // button, the gear, their gaps and the reserve past them: exactly full.
        let tabsAtTheirFloors: CGFloat = 60 + 11 * 40 + 11 * 4
        let plusAndGap: CGFloat = 24 + 4
        bar.frame.size.width = tabsAtTheirFloors + plusAndGap + TabStripLayout.trailingControls
        bar.setItems(
            (0..<12).map { TabBarItem(title: "Note \($0)", isDirty: false) },
            selectedIndex: 0
        )
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.newTabButtonFrameForTesting.maxX,
                       bar.bounds.maxX - TabStripLayout.trailingControls, accuracy: 0.01,
                       "a full strip pins the + short of the bookmark button and the reserve")
        XCTAssertEqual(bar.hiddenTabsForTesting, Array(repeating: false, count: 12))

        // Past that the strip is a window, and the + still follows whatever
        // the window's last tab is.
        bar.setItems(
            (0..<30).map { TabBarItem(title: "Note \($0)", isDirty: false) },
            selectedIndex: 0
        )
        bar.layoutSubtreeIfNeeded()
        let lastVisible = try XCTUnwrap(
            zip(bar.tabFramesForTesting, bar.hiddenTabsForTesting)
                .filter { !$0.1 }.map(\.0).last
        )
        XCTAssertEqual(bar.newTabButtonFrameForTesting.minX, lastVisible.maxX + 4, accuracy: 0.01)
        XCTAssertLessThanOrEqual(bar.newTabButtonFrameForTesting.maxX,
                                 bar.bounds.maxX - TabStripLayout.trailingControls + 0.01,
                                 "the + never enters the bookmark button's slot or the reserve")
    }

    /// Whatever the strip does, the tab in front is on screen and fully
    /// inside it — through a resize, a selection change, and a strip so
    /// crowded that it has gone to a sliding window.
    @MainActor
    func testSelectedTabStaysInViewAcrossResizeAndSelection() throws {
        _ = NSApplication.shared
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 600, height: TabBarView.height))
        let tabs = (0..<4).map { TabBarItem(title: "Note \($0)", isDirty: false) }

        bar.setItems(tabs, selectedIndex: 3)
        bar.layoutSubtreeIfNeeded()
        XCTAssertTrue(bar.isSelectedTabFullyVisible(), "last tab selected at full width")

        bar.frame = NSRect(x: 0, y: 0, width: 300, height: TabBarView.height)
        bar.layoutSubtreeIfNeeded()
        XCTAssertTrue(bar.isSelectedTabFullyVisible(), "a resize alone keeps it in view")

        // Past the floor the strip is a window over the tabs, and the
        // selected one is what the window is anchored on.
        let crowd = (0..<30).map { TabBarItem(title: "Note \($0)", isDirty: false) }
        bar.frame = NSRect(x: 0, y: 0, width: 400, height: TabBarView.height)
        bar.setItems(crowd, selectedIndex: 29)
        bar.layoutSubtreeIfNeeded()
        XCTAssertTrue(bar.hiddenTabsForTesting.contains(true), "30 tabs at 400pt cannot all fit")
        XCTAssertTrue(bar.isSelectedTabFullyVisible(), "the last tab is what the window shows")

        bar.setItems(crowd, selectedIndex: 0)
        bar.layoutSubtreeIfNeeded()
        XCTAssertTrue(bar.isSelectedTabFullyVisible(), "the window slid back to the first tab")
    }

    /// Chromium's `in_tab_close_`: closing with the ✕ holds the remaining
    /// tabs at the width they had, so a run of closes leaves each next ✕
    /// under the pointer. The widths settle once the pointer leaves.
    @MainActor
    func testClosingATabWithItsCloseButtonFreezesWidthsUntilThePointerLeaves() throws {
        _ = NSApplication.shared
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 600, height: TabBarView.height))
        var tabs = (0..<4).map { TabBarItem(title: "Note \($0)", isDirty: false) }

        final class ClosingDelegate: TabBarViewDelegate {
            var tabs: [TabBarItem]
            init(tabs: [TabBarItem]) { self.tabs = tabs }
            func tabBar(_ bar: TabBarView, didSelect index: Int) {}
            func tabBarDidRequestNewTab(_ bar: TabBarView) {}
            func tabBar(_ bar: TabBarView, didMove index: Int, to newIndex: Int) {}
            func tabBar(_ bar: TabBarView, didRequestCloseAt index: Int) {
                tabs.remove(at: index)
                MainActor.assumeIsolated {
                    bar.setItems(tabs, selectedIndex: 0)
                    bar.layoutSubtreeIfNeeded()
                }
            }
        }
        let closer = ClosingDelegate(tabs: tabs)
        bar.delegate = closer

        bar.setItems(tabs, selectedIndex: 0)
        bar.layoutSubtreeIfNeeded()
        let widthOfFour = try XCTUnwrap(bar.tabFramesForTesting.first).width
        let plusOfFour = bar.newTabButtonFrameForTesting

        bar.closeViaButtonForTesting(at: 1)
        tabs = closer.tabs
        XCTAssertEqual(bar.titlesForTesting, ["Note 0", "Note 2", "Note 3"])
        XCTAssertTrue(bar.isFrozenAfterCloseForTesting)
        for frame in bar.tabFramesForTesting {
            XCTAssertEqual(frame.width, widthOfFour, accuracy: 0.01,
                           "the tabs that remain keep the width they had")
        }
        XCTAssertEqual(bar.newTabButtonFrameForTesting, plusOfFour, "the + stays put too")

        // A second ✕ in the same run behaves the same way.
        bar.closeViaButtonForTesting(at: 1)
        XCTAssertEqual(bar.titlesForTesting, ["Note 0", "Note 3"])
        for frame in bar.tabFramesForTesting {
            XCTAssertEqual(frame.width, widthOfFour, accuracy: 0.01)
        }

        // The pointer leaving the strip is what lets them settle.
        bar.mouseExited(with: try exitEvent(for: bar))
        bar.layoutSubtreeIfNeeded()
        XCTAssertFalse(bar.isFrozenAfterCloseForTesting)
        for frame in bar.tabFramesForTesting {
            XCTAssertGreaterThan(frame.width, widthOfFour, "two tabs share the strip again")
        }
    }

    private func exitEvent(for view: NSView) throws -> NSEvent {
        try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseExited, location: NSPoint(x: -10, y: -10), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil
        ))
    }

    /// A completed drag reports `(from, to)` through the delegate; applying
    /// that move the way `MainWindowController.moveTab` does and pushing it
    /// back through `setItems` is what the strip then displays.
    @MainActor
    func testTabBarReportsAMoveAndReflectsTheNewOrderOnceApplied() throws {
        _ = NSApplication.shared
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 600, height: TabBarView.height))
        var tabs = (0..<4).map { TabBarItem(title: "Note \($0)", isDirty: false) }
        bar.setItems(tabs, selectedIndex: 0)
        bar.layoutSubtreeIfNeeded()

        final class RecordingDelegate: TabBarViewDelegate {
            var moved: (from: Int, to: Int)?
            func tabBar(_ bar: TabBarView, didSelect index: Int) {}
            func tabBar(_ bar: TabBarView, didRequestCloseAt index: Int) {}
            func tabBarDidRequestNewTab(_ bar: TabBarView) {}
            func tabBar(_ bar: TabBarView, didMove index: Int, to newIndex: Int) {
                moved = (index, newIndex)
            }
        }
        let recorder = RecordingDelegate()
        bar.delegate = recorder

        bar.moveTabForTesting(from: 0, to: 2)
        let moved = try XCTUnwrap(recorder.moved)
        XCTAssertEqual(moved.from, 0)
        XCTAssertEqual(moved.to, 2)

        // A no-op move reports nothing.
        recorder.moved = nil
        bar.moveTabForTesting(from: 1, to: 1)
        XCTAssertNil(recorder.moved)

        // Applying the reported move the way the delegate does, and pushing
        // it back in, is what the strip is expected to show.
        tabs.insert(tabs.remove(at: moved.from), at: moved.to)
        bar.setItems(tabs, selectedIndex: moved.to)
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.titlesForTesting, ["Note 1", "Note 2", "Note 0", "Note 3"])
        XCTAssertTrue(bar.isSelectedTabFullyVisible(), "the moved, still-selected tab stays in view")
    }

    /// A layout arriving mid-drag (a resize here) must not reset the dragged
    /// tab's frame back to its plain-order slot — that would yank it out
    /// from under the pointer. A tab count change mid-drag (⌘W closing a
    /// tab) cancels the drag instead, since the session's slots would
    /// otherwise be stale.
    @MainActor
    func testLayoutMidDragLeavesTheDraggedTabInPlaceAndACountChangeCancelsIt() throws {
        _ = NSApplication.shared
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 600, height: TabBarView.height))
        let tabs = (0..<4).map { TabBarItem(title: "Note \($0)", isDirty: false) }
        bar.setItems(tabs, selectedIndex: 0)
        bar.layoutSubtreeIfNeeded()

        bar.beginDragForTesting(index: 1)
        let xBeforeResize = try XCTUnwrap(bar.draggedTabXForTesting)

        bar.frame = NSRect(x: 0, y: 0, width: 300, height: TabBarView.height)
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.draggedTabXForTesting, xBeforeResize,
                       "a resize mid-drag must not move the dragged tab")

        // A dirty-dot refresh with the same count is safe and must not move
        // it either.
        bar.setItems(tabs.map { TabBarItem(title: $0.title, isDirty: true) }, selectedIndex: 0)
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.draggedTabXForTesting, xBeforeResize,
                       "a same-count refresh mid-drag must not move it either")

        // ⌘W while dragging pushes a shorter item list — the drag can no
        // longer trust its slots, so it is dropped rather than crashing.
        bar.setItems(Array(tabs.dropLast()), selectedIndex: 0)
        XCTAssertNil(bar.draggedTabXForTesting, "the count change cancelled the drag")
    }

    /// Reordering should respond once the dragged tab reaches the boundary
    /// between adjacent resting slots. Requiring it to reach the next slot's
    /// centre makes the gesture feel as though it has not started.
    @MainActor
    func testDragChangesSlotAfterHalfATabOfTravel() throws {
        _ = NSApplication.shared
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 700, height: TabBarView.height))
        let tabs = (0..<3).map { TabBarItem(title: "Note \($0)", isDirty: false) }
        bar.setItems(tabs, selectedIndex: 0)
        bar.layoutSubtreeIfNeeded()

        // Three tabs in a 700pt strip sit at the comfortable 180pt.
        let width = try XCTUnwrap(bar.tabFramesForTesting.first).width
        XCTAssertEqual(width, 180, accuracy: 0.01)

        bar.beginDragForTesting(index: 0)
        let startX = try XCTUnwrap(bar.draggedTabXForTesting)
        // The grab point is the tab's centre. Travelling just over half a
        // tab takes its trailing edge past the next tab's centre.
        bar.updateDragForTesting(pointerX: startX + width / 2 + 100)

        XCTAssertEqual(try XCTUnwrap(bar.draggedTabXForTesting), startX + 100,
                       accuracy: 0.5, "the tab stays attached to its grab point")
        XCTAssertEqual(bar.draggedTabSlotForTesting, 1)

        // Crossing the same boundary in reverse restores the original slot,
        // without a wide dead zone or oscillation around the midpoint.
        bar.updateDragForTesting(pointerX: startX + width / 2 + 80)
        XCTAssertEqual(bar.draggedTabSlotForTesting, 0)

        // End the synthetic drag by changing the item count, the same safe
        // cancellation route covered by the lifecycle test above.
        bar.setItems(Array(tabs.dropLast()), selectedIndex: 0)
    }

    /// One press-and-drag on a background tab must both select and move it.
    /// The press selects, as it does in every browser; the same press keeps
    /// dragging even though selection has meanwhile rebuilt the strip.
    @MainActor
    func testBackgroundTabSelectsAndReordersInOneGesture() throws {
        _ = NSApplication.shared
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 600, height: TabBarView.height))
        let tabs = (0..<3).map { TabBarItem(title: "Note \($0)", isDirty: false) }
        bar.setItems(tabs, selectedIndex: 0)
        bar.layoutSubtreeIfNeeded()

        final class RecordingDelegate: TabBarViewDelegate {
            let tabs: [TabBarItem]
            var selections: [Int] = []
            var moved: (from: Int, to: Int)?

            init(tabs: [TabBarItem]) { self.tabs = tabs }

            func tabBar(_ bar: TabBarView, didSelect index: Int) {
                selections.append(index)
                // Match MainWindowController: selection pushes refreshed tab
                // state back into the bar during the same gesture.
                MainActor.assumeIsolated {
                    bar.setItems(tabs, selectedIndex: index)
                }
            }
            func tabBar(_ bar: TabBarView, didRequestCloseAt index: Int) {}
            func tabBarDidRequestNewTab(_ bar: TabBarView) {}
            func tabBar(_ bar: TabBarView, didMove index: Int, to newIndex: Int) {
                moved = (index, newIndex)
            }
        }

        let recorder = RecordingDelegate(tabs: tabs)
        bar.delegate = recorder

        let downPoint = NSPoint(x: 250, y: TabBarView.height / 2)
        let draggedPoint = NSPoint(x: 45, y: downPoint.y)
        let tab = try XCTUnwrap(bar.hitTest(downPoint))

        func event(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: bar.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
        }

        tab.mouseDown(with: try event(.leftMouseDown, at: downPoint))
        XCTAssertEqual(recorder.selections, [1], "the press selects straight away")

        tab.mouseDragged(with: try event(.leftMouseDragged, at: draggedPoint))
        XCTAssertEqual(recorder.selections, [1], "dragging must not re-select")
        XCTAssertEqual(bar.draggedTabSlotForTesting, 0,
                       "the drag is underway even though selection rebuilt the strip")

        tab.mouseUp(with: try event(.leftMouseUp, at: draggedPoint))
        // The move is reported when the settle animation lands. How long that
        // takes depends on how busy the process is — with the whole suite's
        // windows still alive it can run past a fixed wait — so wait for the
        // report itself, up to a generous deadline.
        let deadline = Date().addingTimeInterval(3)
        while recorder.moved == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(recorder.moved?.from, 1)
        XCTAssertEqual(recorder.moved?.to, 0)
    }

    /// The gesture above, driven through the real event queue. `mouseDown`
    /// must enter its tracking loop and dequeue the drag and the mouse-up
    /// itself — the routing AppKit would otherwise use does not survive the
    /// hierarchy rebuild that selecting a background tab causes.
    @MainActor
    func testTrackingLoopCarriesTheDragThroughSelection() throws {
        let harness = try TabDragLoopHarness()

        NSApp.postEvent(try harness.mouseEvent(.leftMouseDragged, at: harness.draggedPoint), atStart: false)
        NSApp.postEvent(try harness.mouseEvent(.leftMouseUp, at: harness.draggedPoint), atStart: false)

        harness.tab.mouseDown(with: try harness.mouseEvent(.leftMouseDown, at: harness.downPoint))

        XCTAssertEqual(harness.recorder.selections, [1], "the press selected before the loop ran")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(harness.recorder.moved?.from, 1)
        XCTAssertEqual(harness.recorder.moved?.to, 0)
    }

    /// The strip lives in the title-bar region. A press on a tab while the
    /// window is not key must reach the tab, not the frame view — otherwise
    /// it activates the window and a drag moves the window, and the user
    /// has to press a second time to drag the tab.
    @MainActor
    func testTabAcceptsTheActivatingFirstClick() throws {
        let harness = try TabDragLoopHarness()
        let event = try harness.mouseEvent(.leftMouseDown, at: harness.downPoint)
        XCTAssertTrue(harness.tab.acceptsFirstMouse(for: event))
    }

    /// Esc during a real drag abandons it. Local key monitors are never
    /// called inside a nested tracking loop, so the loop has to notice the
    /// key itself; the tab stays selected and nothing is reordered.
    @MainActor
    func testTrackingLoopEscapeCancelsTheDrag() throws {
        let harness = try TabDragLoopHarness()

        NSApp.postEvent(try harness.mouseEvent(.leftMouseDragged, at: harness.draggedPoint), atStart: false)
        NSApp.postEvent(try harness.escapeEvent(), atStart: false)
        NSApp.postEvent(try harness.mouseEvent(.leftMouseUp, at: harness.draggedPoint), atStart: false)

        harness.tab.mouseDown(with: try harness.mouseEvent(.leftMouseDown, at: harness.downPoint))

        XCTAssertEqual(harness.recorder.selections, [1], "Esc cancels the move, not the selection")
        XCTAssertNil(harness.bar.draggedTabXForTesting, "the drag session is gone")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNil(harness.recorder.moved, "nothing was reordered")
    }

    // MARK: - Tearing a tab out of the strip

    /// Chromium's rule: the tab follows the pointer along the strip, and
    /// once the pointer is far enough out of it the tab stops being this
    /// window's altogether. The strip says so once and then only carries the
    /// rest of the gesture — including the release — to its delegate.
    @MainActor
    func testDraggingWellBelowTheStripTearsTheTabOff() throws {
        _ = NSApplication.shared
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 700, height: TabBarView.height))
        let tabs = (0..<3).map { TabBarItem(title: "Note \($0)", isDirty: false) }
        bar.setItems(tabs, selectedIndex: 0)
        bar.layoutSubtreeIfNeeded()
        let recorder = TearOffRecorder()
        bar.delegate = recorder
        let width = try XCTUnwrap(bar.tabFramesForTesting.first).width

        bar.beginDragForTesting(index: 1)
        bar.updateDragForTesting(pointerX: 250, pointerY: -39, screenPoint: NSPoint(x: 300, y: 900))
        XCTAssertNil(recorder.tornOff, "just under the strip is still a reorder")
        XCTAssertNotNil(bar.draggedTabXForTesting)

        bar.updateDragForTesting(pointerX: 250, pointerY: -41, screenPoint: NSPoint(x: 300, y: 890))
        let torn = try XCTUnwrap(recorder.tornOff)
        XCTAssertEqual(torn.index, 1, "the tab that was being dragged, not the one under the pointer")
        XCTAssertEqual(torn.grabOffset.x, width / 2, accuracy: 0.5,
                       "the drag began at the tab's centre, and the grab point rides with it")
        XCTAssertEqual(torn.screenPoint, NSPoint(x: 300, y: 890))
        XCTAssertNil(bar.draggedTabXForTesting, "the strip has stopped reordering")
        XCTAssertTrue(bar.isTornOffForTesting)

        bar.updateDragForTesting(pointerX: 250, pointerY: -60, screenPoint: NSPoint(x: 310, y: 870))
        XCTAssertEqual(recorder.tearOffCount, 1, "a tab is torn off once, not on every drag")
        XCTAssertEqual(recorder.dragMoves, [NSPoint(x: 310, y: 870)])

        // Coming back over the strip does not put the tab back — the window
        // simply follows the pointer, which is what Chromium does too.
        bar.updateDragForTesting(pointerX: 250, pointerY: 17, screenPoint: NSPoint(x: 320, y: 880))
        XCTAssertTrue(bar.isTornOffForTesting)
        XCTAssertEqual(recorder.dragMoves.count, 2)

        bar.endDragForTesting(committed: true, at: NSPoint(x: 320, y: 880))
        XCTAssertEqual(recorder.ended?.committed, true)
        XCTAssertEqual(recorder.ended?.screenPoint, NSPoint(x: 320, y: 880))
        XCTAssertFalse(bar.isTornOffForTesting, "the gesture is over")
    }

    /// Esc mid-tear-off reaches the delegate as a drag that was not
    /// committed, so the window it made can put the tab back.
    @MainActor
    func testEscapeAfterATearOffEndsTheDragUncommitted() throws {
        _ = NSApplication.shared
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 700, height: TabBarView.height))
        bar.setItems((0..<2).map { TabBarItem(title: "Note \($0)", isDirty: false) }, selectedIndex: 0)
        bar.layoutSubtreeIfNeeded()
        let recorder = TearOffRecorder()
        bar.delegate = recorder

        bar.beginDragForTesting(index: 0)
        bar.updateDragForTesting(pointerX: 100, pointerY: TabBarView.height + 41,
                                 screenPoint: NSPoint(x: 200, y: 950))
        XCTAssertEqual(recorder.tornOff?.index, 0, "above the strip tears off just as below does")

        bar.endDragForTesting(committed: false, at: NSPoint(x: 200, y: 950))
        XCTAssertEqual(recorder.ended?.committed, false)
        XCTAssertFalse(bar.isTornOffForTesting)
    }

    /// Sideways out of the window counts as leaving too: a tab dragged past
    /// either edge is on its way to a window of its own, not to the far end
    /// of a strip it has already run out of.
    @MainActor
    func testDraggingOffTheSideOfTheWindowTearsTheTabOff() throws {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 600, height: TabBarView.height)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let bar = TabBarView(frame: frame)
        window.contentView = bar
        bar.setItems((0..<3).map { TabBarItem(title: "Note \($0)", isDirty: false) }, selectedIndex: 0)
        bar.layoutSubtreeIfNeeded()
        let recorder = TearOffRecorder()
        bar.delegate = recorder

        bar.beginDragForTesting(index: 2)
        bar.updateDragForTesting(pointerX: 620, pointerY: TabBarView.height / 2,
                                 screenPoint: NSPoint(x: 620, y: 400))
        XCTAssertEqual(recorder.tornOff?.index, 2)
    }

    /// The insertion caret the strip under a torn-off tab shows: the visible
    /// tabs' midpoints are the boundaries, and nil takes it away again.
    @MainActor
    func testTheDropCaretFollowsTheTabMidpointsAndClears() throws {
        _ = NSApplication.shared
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 700, height: TabBarView.height))
        bar.setItems((0..<3).map { TabBarItem(title: "Note \($0)", isDirty: false) }, selectedIndex: 0)
        bar.layoutSubtreeIfNeeded()
        let frames = bar.tabFramesForTesting

        XCTAssertEqual(bar.dropSlot(at: NSPoint(x: frames[0].midX - 1, y: 17)), 0)
        XCTAssertEqual(bar.dropSlot(at: NSPoint(x: frames[0].midX + 1, y: 17)), 1)
        XCTAssertEqual(bar.dropSlot(at: NSPoint(x: frames[2].maxX, y: 17)), 3)

        bar.showDropCaret(at: 1)
        XCTAssertEqual(bar.dropCaretSlotForTesting, 1)
        bar.showDropCaret(at: nil)
        XCTAssertNil(bar.dropCaretSlotForTesting)
    }

    /// The tab a window's *last* tab is dragged out of loses its view the
    /// moment the delegate takes the note away — the strip rebuilds with
    /// nothing in it. The gesture has to carry on regardless: the tracking
    /// loop is on that view, and it still owes the delegate every move and
    /// the release. Driven through the real event queue, tab view and all.
    @MainActor
    func testTheGestureSurvivesTheTabLeavingTheStrip() throws {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 600, height: TabBarView.height)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let bar = TabBarView(frame: frame)
        window.contentView = bar
        bar.setItems([TabBarItem(title: "Only", isDirty: false)], selectedIndex: 0)
        bar.layoutSubtreeIfNeeded()

        // What the window controller does with the note: it takes it, and
        // the strip is left with no tabs at all.
        let recorder = TearOffRecorder()
        recorder.onTearOff = { MainActor.assumeIsolated { bar.setItems([], selectedIndex: 0) } }
        bar.delegate = recorder

        let down = NSPoint(x: 100, y: TabBarView.height / 2)
        let tab = try XCTUnwrap(bar.hitTest(down))
        func event(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: bar.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
            ))
        }

        NSApp.postEvent(try event(.leftMouseDragged, at: NSPoint(x: 100, y: -60)), atStart: false)
        NSApp.postEvent(try event(.leftMouseDragged, at: NSPoint(x: 140, y: -90)), atStart: false)
        NSApp.postEvent(try event(.leftMouseUp, at: NSPoint(x: 140, y: -90)), atStart: false)
        tab.mouseDown(with: try event(.leftMouseDown, at: down))

        XCTAssertEqual(recorder.tearOffCount, 1)
        XCTAssertEqual(bar.titlesForTesting, [], "the strip really did give the tab up")
        XCTAssertEqual(recorder.dragMoves.count, 1,
                       "the drag after the tab left the strip still reached the delegate")
        XCTAssertEqual(recorder.ended?.committed, true, "and so did the release")
    }

    // MARK: - Carried over from Jot

    /// Notes written before the rename hold `jot://` tokens. They still find
    /// their picture, and the next save quietly writes the new scheme.
    func testALegacyJotTokenStillRendersAndIsRewrittenOnTheWayOut() throws {
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let id = try XCTUnwrap(assets.importImageData(makePNGData(), preferredExtension: "png"))

        let legacy = "before ![](jot://\(id)) after"
        XCTAssertEqual(NoteText.assetIDs(in: legacy), [id])

        let rendered = NoteText.render(legacy, attributes: [:], assets: assets)
        XCTAssertEqual(attachmentIDs(in: rendered), [id])

        // Serializing writes the new scheme, so a round trip brings the file
        // up to date rather than preserving the old spelling.
        XCTAssertEqual(NoteText.serialize(rendered), "before ![](nota://\(id)) after")
        XCTAssertEqual(NoteText.token(for: id), "![](nota://\(id))")

        // The old scheme is just as strict as the new one.
        for malformed in ["![](jot://", "![](jot://)", "![](jot://noextension)"] {
            let rendered = NoteText.render(malformed, attributes: [:], assets: assets)
            XCTAssertTrue(attachmentIDs(in: rendered).isEmpty, "should not match: \(malformed)")
            XCTAssertEqual(NoteText.serialize(rendered), malformed)
        }

        XCTAssertEqual(NoteText.assetID(fromTokenURL: "jot://\(id)"), id)
        XCTAssertEqual(NoteText.assetID(fromTokenURL: "nota://\(id)"), id)
        XCTAssertNil(NoteText.assetID(fromTokenURL: "https://example.com/x.png"))
        XCTAssertNil(NoteText.assetID(fromTokenURL: "nota://"))
    }

    /// The first launch under the new name moves the whole support directory
    /// across, so the notes are exactly where they were.
    func testTheSupportDirectoryMovesOverFromTheOldName() throws {
        let manager = FileManager.default
        let root = try makeTemporaryDirectory()
        let legacy = root.appendingPathComponent("Jot", isDirectory: true)
        try manager.createDirectory(
            at: legacy.appendingPathComponent("assets", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: legacy.appendingPathComponent("session.json"))

        let resolved = SessionStore.supportDirectory(in: root)
        XCTAssertEqual(resolved.lastPathComponent, "Nota")
        XCTAssertFalse(manager.fileExists(atPath: legacy.path), "the old directory is gone")
        XCTAssertTrue(manager.fileExists(
            atPath: resolved.appendingPathComponent("session.json").path
        ))
        XCTAssertTrue(manager.fileExists(
            atPath: resolved.appendingPathComponent("assets").path
        ))

        // And a store pointed at that root reads the carried-over session.
        let store = SessionStore(applicationSupport: root)
        XCTAssertEqual(store.directory, resolved)
    }

    /// The move happens once. A directory already under the new name is left
    /// alone even when an old one is somehow still sitting beside it, so no
    /// note written since the rename can be overwritten.
    func testTheSupportDirectoryIsNeverMovedTwiceAndIsMadeFreshOtherwise() throws {
        let manager = FileManager.default
        let root = try makeTemporaryDirectory()
        let legacy = root.appendingPathComponent("Jot", isDirectory: true)
        let current = root.appendingPathComponent("Nota", isDirectory: true)
        try manager.createDirectory(at: legacy, withIntermediateDirectories: true)
        try manager.createDirectory(at: current, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: current.appendingPathComponent("session.json"))
        try Data("old".utf8).write(to: legacy.appendingPathComponent("session.json"))

        XCTAssertEqual(SessionStore.supportDirectory(in: root), current)
        XCTAssertEqual(
            try String(contentsOf: current.appendingPathComponent("session.json"), encoding: .utf8),
            "new"
        )
        XCTAssertTrue(manager.fileExists(atPath: legacy.path), "the old one is left where it is")

        // A machine that never ran the old app just gets the new directory.
        let clean = try makeTemporaryDirectory()
        XCTAssertEqual(
            SessionStore.supportDirectory(in: clean).lastPathComponent, "Nota"
        )
    }

    /// The bundle identifier changed with the name, which moves `UserDefaults`
    /// to a domain of its own. Every setting is copied across on first launch.
    func testSettingsAreCarriedOverFromTheOldDefaultsDomain() throws {
        let suite = "NotaTests-\(UUID().uuidString)"
        let legacyDomain = "NotaTests-legacy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            defaults.removePersistentDomain(forName: legacyDomain)
        }

        // What the old build left behind.
        let old = try XCTUnwrap(UserDefaults(suiteName: legacyDomain))
        let preferences = Preferences(defaults: old)
        preferences.fontFamily = .serif
        preferences.showsLineNumbers = false
        preferences.fontSize = 21
        XCTAssertTrue(old.synchronize())

        // Before the migration the new domain knows nothing.
        XCTAssertEqual(Preferences(defaults: defaults).fontFamily, .system)

        XCTAssertTrue(Preferences.migrateFromJotIfNeeded(
            defaults: defaults, legacyDomain: legacyDomain
        ))
        let carried = Preferences(defaults: defaults)
        XCTAssertEqual(carried.fontFamily, .serif)
        XCTAssertFalse(carried.showsLineNumbers)
        XCTAssertEqual(carried.fontSize, 21)

        // It runs once: a setting changed since is not overwritten by the
        // old value on the next launch.
        carried.fontFamily = .rounded
        XCTAssertFalse(Preferences.migrateFromJotIfNeeded(
            defaults: defaults, legacyDomain: legacyDomain
        ))
        XCTAssertEqual(Preferences(defaults: defaults).fontFamily, .rounded)
    }

    /// A fresh install has nothing to carry over, and must not be left
    /// probing the old domain on every launch.
    func testAFreshInstallCarriesNothingOverButStillMarksItselfDone() throws {
        let suite = "NotaTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(Preferences.migrateFromJotIfNeeded(
            defaults: defaults, legacyDomain: "NotaTests-absent-\(UUID().uuidString)"
        ))
        XCTAssertEqual(Preferences(defaults: defaults).fontFamily, .system)
        XCTAssertEqual(defaults.object(forKey: "migratedFromJot") as? Bool, true)
    }

    /// A copy taken from a build from before the rename is still on the
    /// pasteboard under the old flavour, and still pastes as an image.
    @MainActor
    func testACopyUnderTheOldPasteboardFlavourIsStillRead() throws {
        _ = NSApplication.shared
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let id = try XCTUnwrap(assets.importImageData(makePNGData(), preferredExtension: "png"))
        let view = makeTextView(assets: assets)

        let board = makePasteboard()
        board.clearContents()
        board.declareTypes([.legacyJotNote], owner: nil)
        board.setString("![](jot://\(id))", forType: .legacyJotNote)

        // It is preferred over plain text, just as the new flavour is.
        XCTAssertEqual(
            view.preferredPasteboardType(
                from: board.types ?? [], restrictedToTypesFrom: view.readablePasteboardTypes
            ),
            .legacyJotNote
        )
        XCTAssertTrue(view.readSelection(from: board, type: .legacyJotNote))
        XCTAssertEqual(attachmentIDs(in: try XCTUnwrap(view.textStorage)), [id])
        // Relinked, not imported a second time.
        XCTAssertEqual(try assetFileCount(assets), 1)

        // The new flavour still wins when both are on the board.
        XCTAssertEqual(view.writablePasteboardTypes.first, .notaNote)
    }

    // MARK: - Hovering the tab picker with the mouse

    /// Moving the pointer onto a row selects it, the same path ↓/↑ use — so
    /// choosing right after picks whatever the pointer last landed on.
    @MainActor
    func testHoverMovesSelectionDownTheList() throws {
        let (picker, _, delegate) = try makeHoverTestPicker(titles: ["Alpha", "Beta", "Gamma"])
        defer { picker.hide() }

        picker.simulateHover(atRow: 1)
        picker.simulateHover(atRow: 2)
        picker.chooseSelection()

        XCTAssertEqual(delegate.chosenTabIndex, 2, "the selection followed the pointer down")
    }

    /// Hovering the fixed row above the field takes the selection there,
    /// exactly as ↑ from the top of the list does — deselecting the list.
    @MainActor
    func testHoverOnTheTopRowSelectsItAndDeselectsTheList() throws {
        let (picker, _, delegate) = try makeHoverTestPicker(titles: ["Alpha", "Beta"])
        defer { picker.hide() }

        picker.moveSelectionDown()
        XCTAssertFalse(picker.isTopRowSelected, "the list holds the selection to begin with")

        picker.simulateHoverOverTopRow()
        XCTAssertTrue(picker.isTopRowSelected)

        picker.chooseSelection()
        XCTAssertTrue(delegate.requestedNewTab, "the top row's own action fired")
        XCTAssertNil(delegate.chosenTabIndex, "not a row from the list")
    }

    /// A second "move" that lands at the exact point the last one did is the
    /// synthetic repeat a still pointer can produce — a no-op, not a second
    /// hover.
    @MainActor
    func testARepeatedMoveAtTheIdenticalLocationDoesNothing() throws {
        let (picker, _, delegate) = try makeHoverTestPicker(titles: ["Alpha", "Beta", "Gamma"])
        defer { picker.hide() }

        picker.simulateHover(atRow: 1)
        // A real key press, unrelated to the pointer, moves the selection on.
        picker.moveSelectionDown()
        // The identical point as the first hover: nothing about it moved.
        picker.simulateHover(atRow: 1)

        picker.chooseSelection()
        XCTAssertEqual(delegate.chosenTabIndex, 2, "the repeat did not pull the selection back")
    }

    /// Return after a hover chooses whatever row the pointer is resting on.
    @MainActor
    func testReturnAfterAHoverChoosesTheHoveredItem() throws {
        let (picker, _, delegate) = try makeHoverTestPicker(titles: ["Alpha", "Beta", "Gamma"])
        defer { picker.hide() }

        picker.simulateHover(atRow: 2)
        picker.chooseSelection()

        XCTAssertEqual(delegate.chosenTabIndex, 2)
    }

    // MARK: - Helpers

    private func solidImage(_ width: Int, _ height: Int) -> NSImage {
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemGreen.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }


    private func attachmentIDs(in attributed: NSAttributedString) -> [String] {
        var ids: [String] = []
        attributed.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: attributed.length)
        ) { value, _, _ in
            if let attachment = value as? NotaImageAttachment { ids.append(attachment.assetID) }
        }
        return ids
    }

    private func assetFileCount(_ assets: AssetStore) throws -> Int {
        try FileManager.default
            .contentsOfDirectory(atPath: assets.directory.path)
            .filter { !$0.hasPrefix(".") }
            .count
    }

    /// A private pasteboard, so running the tests never disturbs whatever the
    /// person at the keyboard has on their real clipboard.
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("NotaTests-\(UUID().uuidString)"))
    }

    /// Lends the real clipboard out and puts back what was on it. `copy(_:)`
    /// writes to `NSPasteboard.general` and nowhere else, so testing the
    /// action itself means borrowing it rather than using a private board.
    private func withGeneralPasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        defer {
            board.clearContents()
            if !saved.isEmpty { board.writeObjects(saved) }
        }
        try body(board)
    }

    private func makePNGData() -> Data {
        let size = NSSize(width: 6, height: 4)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }

    private func makeTextView(assets: AssetStore) -> NotaTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        let view = NotaTextView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container
        )
        view.isRichText = false
        view.isEditable = true
        view.assets = assets
        view.attributesProvider = { [.font: NSFont.systemFont(ofSize: 13)] }
        return view
    }


    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    @MainActor
    private func makeFooterFormatController(in directory: URL) throws -> MainWindowController {
        _ = NSApplication.shared
        let controller = MainWindowController(store: SessionStore(directory: directory))
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1000, height: 560))
        window.layoutIfNeeded()
        return controller
    }

    /// A bare `TabPickerPanel` over an offscreen window, wired to a delegate
    /// that just records what it was told — for the hover tests, which only
    /// need to know which row `chooseSelection()` landed on.
    @MainActor
    private func makeHoverTestPicker(titles: [String], selectedIndex: Int = 0) throws
        -> (picker: TabPickerPanel, window: NSWindow, delegate: RecordingHoverDelegate) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.makeKeyAndOrderFrontOffscreen()
        let picker = TabPickerPanel()
        let delegate = RecordingHoverDelegate()
        picker.delegate = delegate
        picker.show(titles: titles, selectedIndex: selectedIndex, loadHeadings: { _ in }, over: window)
        return (picker, window, delegate)
    }
}

/// Records what the picker was told to do, for the hover tests.
private final class RecordingHoverDelegate: TabPickerPanelDelegate {
    var chosenTabIndex: Int?
    var requestedNewTab = false

    func tabPicker(_ picker: TabPickerPanel, didChoose tabIndex: Int) {
        chosenTabIndex = tabIndex
    }
    func tabPicker(_ picker: TabPickerPanel, didChooseHeading heading: MarkdownHeadings.Heading) {}
    func tabPickerDidRequestNewTab(_ picker: TabPickerPanel) { requestedNewTab = true }
    func tabPickerDidRequestBookmarkCurrentTab(_ picker: TabPickerPanel) {}
    func tabPicker(_ picker: TabPickerPanel, didChooseBookmark path: String) {}
    func tabPicker(_ picker: TabPickerPanel, didRemoveBookmark path: String) {}
    func tabPicker(
        _ picker: TabPickerPanel, didChooseSearchMatch match: NoteSearchMatch, query: String
    ) {}
}

/// Sets up a real `NSWindow` around a tab strip so `TabItemView.mouseDown`
/// finds an event queue to track. The window is never ordered front; it only
/// has to exist and have a window number the posted events can carry.
@MainActor
private final class TabDragLoopHarness {
    /// Mimics `MainWindowController`: selecting pushes refreshed tab state
    /// back into the bar, rebuilding the strip in the middle of the gesture.
    final class RecordingDelegate: TabBarViewDelegate {
        let tabs: [TabBarItem]
        var selections: [Int] = []
        var moved: (from: Int, to: Int)?

        init(tabs: [TabBarItem]) { self.tabs = tabs }

        func tabBar(_ bar: TabBarView, didSelect index: Int) {
            selections.append(index)
            MainActor.assumeIsolated {
                bar.setItems(tabs, selectedIndex: index)
            }
        }
        func tabBar(_ bar: TabBarView, didRequestCloseAt index: Int) {}
        func tabBarDidRequestNewTab(_ bar: TabBarView) {}
        func tabBar(_ bar: TabBarView, didMove index: Int, to newIndex: Int) {
            moved = (index, newIndex)
        }
    }

    let window: NSWindow
    let bar: TabBarView
    let recorder: RecordingDelegate
    let tab: NSView
    /// Inside the second tab (three tabs in a 600pt strip are 180pt each),
    /// and far enough left of it to land on slot 0.
    let downPoint = NSPoint(x: 250, y: TabBarView.height / 2)
    let draggedPoint = NSPoint(x: 45, y: TabBarView.height / 2)

    init() throws {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 600, height: TabBarView.height)
        window = NSWindow(contentRect: frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
        bar = TabBarView(frame: frame)
        window.contentView = bar

        let tabs = (0..<3).map { TabBarItem(title: "Note \($0)", isDirty: false) }
        bar.setItems(tabs, selectedIndex: 0)
        bar.layoutSubtreeIfNeeded()

        recorder = RecordingDelegate(tabs: tabs)
        bar.delegate = recorder
        tab = try XCTUnwrap(bar.hitTest(downPoint))
    }

    func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: bar.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        ))
    }

    func escapeEvent() throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53
        ))
    }
}

/// Records the three calls a tear-off makes on the strip's delegate. Every
/// other delegate method is the protocol's own no-op.
private final class TearOffRecorder: TabBarViewDelegate {
    var tornOff: (index: Int, grabOffset: NSPoint, screenPoint: NSPoint)?
    var tearOffCount = 0
    /// What a real delegate does on a tear-off: take the note away, which
    /// can leave the strip with no tab views at all.
    var onTearOff: (() -> Void)?
    var dragMoves: [NSPoint] = []
    var ended: (committed: Bool, screenPoint: NSPoint)?

    func tabBar(_ bar: TabBarView, didSelect index: Int) {}
    func tabBar(_ bar: TabBarView, didRequestCloseAt index: Int) {}
    func tabBarDidRequestNewTab(_ bar: TabBarView) {}
    func tabBar(_ bar: TabBarView, didMove index: Int, to newIndex: Int) {}

    func tabBar(_ bar: TabBarView, tearOff index: Int, grabOffset: NSPoint, screenPoint: NSPoint) {
        tornOff = (index, grabOffset, screenPoint)
        tearOffCount += 1
        onTearOff?()
    }
    func tabBarDragMoved(_ bar: TabBarView, to screenPoint: NSPoint) {
        dragMoves.append(screenPoint)
    }
    func tabBarDragEnded(_ bar: TabBarView, committed: Bool, at screenPoint: NSPoint) {
        ended = (committed, screenPoint)
    }
}
