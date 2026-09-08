import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Nota

/// Settings › File types: the page that makes Nota the app the Mac opens a
/// kind of file in.
///
/// Every test here runs against `FakeDefaultAppRegistry`. Nothing in this file
/// ever reaches Launch Services: a default app is the reader's own machine, so
/// a suite that rewrote one would be doing the clipboard's old sin one shelf
/// up. `SystemDefaultAppRegistry` refuses to set anything under XCTest at all,
/// which is the second lock on the same door.
final class FileTypesTests: AppKitTestCase {
    private let notaBundle = DefaultAppBundle(
        url: URL(fileURLWithPath: "/Applications/Nota.app"),
        name: "Nota",
        identifier: "com.manfad.nota"
    )

    /// A Launch Services that lives in a dictionary. Keyed by type identifier,
    /// the way the real one is: `.md` and `.markdown` are one entry.
    private final class FakeDefaultAppRegistry: DefaultAppRegistry {
        var nota: DefaultAppBundle?
        private var defaults: [String: DefaultAppBundle] = [:]
        var known: [String: DefaultAppBundle] = [:]
        /// Every set, in order: which type, and which app it went to.
        private(set) var sets: [(type: String, app: DefaultAppBundle)] = []
        var failure: Error?

        init(nota: DefaultAppBundle?) {
            self.nota = nota
            if let nota { known[nota.identifier] = nota }
        }

        func setDefault(_ app: DefaultAppBundle, forExtension ext: String) {
            guard let type = DefaultAppTypes.type(forExtension: ext) else { return }
            defaults[type.identifier] = app
            known[app.identifier] = app
        }

        func defaultApplication(toOpen type: UTType) -> DefaultAppBundle? {
            defaults[type.identifier]
        }

        func application(forIdentifier identifier: String) -> DefaultAppBundle? {
            known[identifier]
        }

        func setDefaultApplication(
            at applicationURL: URL, toOpen type: UTType, completion: @escaping (Error?) -> Void
        ) {
            let app = known.values.first { $0.url == applicationURL }
                ?? DefaultAppBundle(url: applicationURL,
                                    name: applicationURL.deletingPathExtension().lastPathComponent,
                                    identifier: applicationURL.path)
            sets.append((type.identifier, app))
            if failure == nil { defaults[type.identifier] = app }
            completion(failure)
        }
    }

    private var controller: SettingsWindowController { .shared }
    private var registry: FakeDefaultAppRegistry!
    private var originalRemembered: [String: String]!
    private var originalLanguage: AppLanguage!

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
        originalRemembered = Preferences.shared.previousDefaultApps
        originalLanguage = Preferences.shared.language
        Preferences.shared.previousDefaultApps = [:]
        registry = FakeDefaultAppRegistry(nota: notaBundle)
        controller.defaultAppRegistry = registry
    }

    override func tearDown() {
        Preferences.shared.language = originalLanguage
        Preferences.shared.previousDefaultApps = originalRemembered
        controller.defaultAppRegistry = SystemDefaultAppRegistry()
        controller.selectPage(at: 0)
        super.tearDown()
    }

    /// An app that is not Nota, known to the registry by identifier.
    @discardableResult
    private func app(_ name: String, opening ext: String? = nil) -> DefaultAppBundle {
        let bundle = DefaultAppBundle(
            url: URL(fileURLWithPath: "/Applications/\(name).app"),
            name: name,
            identifier: "com.example.\(name.lowercased())"
        )
        registry.known[bundle.identifier] = bundle
        if let ext { registry.setDefault(bundle, forExtension: ext) }
        return bundle
    }

    private func typeIdentifier(_ ext: String) throws -> String {
        try XCTUnwrap(DefaultAppTypes.type(forExtension: ext)).identifier
    }

    /// Brings the page forward, which is also what makes it read the registry.
    @discardableResult
    private func openPage() -> Int {
        let index = controller.pageTitles.firstIndex(of: L10n.text("File types")) ?? 0
        controller.selectPage(at: index)
        return index
    }

    private func row(_ ext: String) throws -> (
        ext: String, app: String, ticked: Bool, enabled: Bool
    ) {
        openPage()
        return try XCTUnwrap(controller.fileTypeRowsForTesting.first { $0.ext == ext })
    }

    private func checkbox(_ ext: String) throws -> NSButton {
        let index = try XCTUnwrap(DefaultAppTypes.allExtensions.firstIndex(of: ext))
        let page = openPage()
        return try XCTUnwrap(controller.rows(on: page)[index].control as? NSButton)
    }

    private func click(_ button: NSButton) throws {
        _ = NSApp.sendAction(try XCTUnwrap(button.action), to: button.target, from: button)
    }

    /// Flips a checkbox the way a click does — the state first, then the
    /// action — since `performClick:` would want a live event.
    private func toggle(_ ext: String) throws {
        let box = try checkbox(ext)
        box.state = box.state == .on ? .off : .on
        try click(box)
    }

    // MARK: - The page

    /// It sits between Shortcuts and About, and its sidebar row has a symbol
    /// this macOS actually draws.
    func testFileTypesPageIsBetweenShortcutsAndAbout() {
        XCTAssertEqual(
            controller.pageTitles,
            ["General", "Appearance", "Editor", "Preview", "Tab bar", "Status bar",
             "Shortcuts", "File types", "About"]
        )
        XCTAssertNotNil(NSImage(systemSymbolName: "doc.badge.gearshape",
                                accessibilityDescription: nil))
    }

    /// The rows are the table's extensions, in the table's order, under the
    /// four group titles.
    func testRowsAreTheTableInOrderUnderTheirGroupTitles() throws {
        let page = openPage()
        XCTAssertEqual(controller.rows(on: page).map(\.title),
                       DefaultAppTypes.allExtensions.map { "." + $0 })
        XCTAssertEqual(DefaultAppTypes.groups.map(\.titleKey),
                       ["Text", "Data", "Code", "Documents and pictures"])

        let root = try XCTUnwrap(controller.window?.contentView)
        func allViews(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
        let labels = allViews(in: root).compactMap { ($0 as? NSTextField)?.stringValue }
        for title in ["Text", "Data", "Code", "Documents and pictures"] {
            XCTAssertTrue(labels.contains(title), "no group title \(title)")
        }
        root.layoutSubtreeIfNeeded()
        XCTAssertFalse(root.hasAmbiguousLayout)
    }

    /// A row is ticked when the registry says Nota opens that type, and the
    /// name beside it is whatever app the registry named.
    func testARowIsTickedWhenNotaIsTheDefaultAndNamesTheAppBesideIt() throws {
        registry.setDefault(notaBundle, forExtension: "md")
        app("Xcode", opening: "json")
        Preferences.shared.previousDefaultApps = ["md": "com.example.xcode"]

        XCTAssertTrue(try row("md").ticked)
        XCTAssertEqual(try row("md").app, "Nota")
        XCTAssertFalse(try row("json").ticked)
        XCTAssertEqual(try row("json").app, "Xcode")
        // Nothing claims it at all.
        XCTAssertFalse(try row("toml").ticked)
        XCTAssertEqual(try row("toml").app, "None")
    }

    // MARK: - Ticking and unticking

    /// Ticking asks the registry for that type and writes down who had it.
    func testTickingSetsNotaAndRemembersThePreviousApp() throws {
        let sublime = app("Sublime", opening: "txt")
        openPage()

        try toggle("txt")

        XCTAssertEqual(registry.sets.count, 1)
        XCTAssertEqual(registry.sets.first?.type, try typeIdentifier("txt"))
        XCTAssertEqual(registry.sets.first?.app.identifier, "com.manfad.nota")
        XCTAssertEqual(Preferences.shared.previousDefaultApps["txt"], sublime.identifier)
        XCTAssertTrue(try row("txt").ticked)
        XCTAssertEqual(try row("txt").app, "Nota")
        XCTAssertTrue(try row("txt").enabled, "there is something to hand it back to")
    }

    /// Unticking hands the type back to the remembered app and forgets it.
    func testUntickingPutsThePreviousAppBackAndForgetsIt() throws {
        let sublime = app("Sublime", opening: "txt")
        openPage()
        try toggle("txt")

        try toggle("txt")

        XCTAssertEqual(registry.sets.count, 2)
        XCTAssertEqual(registry.sets.last?.app.identifier, sublime.identifier)
        XCTAssertNil(Preferences.shared.previousDefaultApps["txt"])
        XCTAssertFalse(try row("txt").ticked)
        XCTAssertEqual(try row("txt").app, "Sublime")
    }

    /// Launch Services keeps one default per type, so the two rows that name
    /// the same type move together and are remembered together.
    func testTwoRowsNamingOneTypeMoveTogether() throws {
        app("Sublime", opening: "md")
        openPage()

        try toggle("md")

        XCTAssertTrue(try row("md").ticked)
        XCTAssertTrue(try row("markdown").ticked, ".markdown names the same type")
        XCTAssertTrue(try row("markdown").enabled, "and remembers the same app")
        XCTAssertEqual(Preferences.shared.previousDefaultApps["markdown"], "com.example.sublime")

        try toggle("markdown")
        XCTAssertFalse(try row("md").ticked)
        XCTAssertTrue(Preferences.shared.previousDefaultApps.isEmpty)
    }

    /// Nota was already the default when the page opened, so there is nothing
    /// to put back: the tick stays and the checkbox goes dead.
    func testARowNotaAlreadyOwnedIsTickedAndDisabled() throws {
        registry.setDefault(notaBundle, forExtension: "sql")
        openPage()

        XCTAssertTrue(try row("sql").ticked)
        XCTAssertFalse(try row("sql").enabled)
        let box = try checkbox("sql")
        XCTAssertFalse(box.isEnabled)
        XCTAssertNotNil(box.toolTip, "the row says where to change it instead")
        XCTAssertTrue(registry.sets.isEmpty, "opening the page sets nothing")
    }

    /// A refusal from Launch Services is not swallowed: the tick goes back to
    /// what the Mac actually says, and the row wears the reason.
    func testARefusedSetSaysWhyOnTheRow() throws {
        struct Refused: LocalizedError {
            var errorDescription: String? { "Sorry, no." }
        }
        app("Safari", opening: "html")
        registry.failure = Refused()
        openPage()

        try toggle("html")

        XCTAssertFalse(try row("html").ticked, "the Mac still says Safari")
        XCTAssertEqual(try row("html").app, "Sorry, no.")
        let box = try XCTUnwrap(controller.fileTypeCheckboxForTesting("html"))
        XCTAssertEqual(box.toolTip?.contains("Sorry, no."), true)
        XCTAssertEqual(box.toolTip?.contains("⌘I"), true, "and where to go instead")
        // The twin row names the same type, so it carries the same news.
        XCTAssertEqual(try row("htm").app, "Sorry, no.")

        // Trying again clears the old reason before it asks.
        registry.failure = nil
        try toggle("html")
        XCTAssertTrue(try row("html").ticked)
        XCTAssertEqual(try row("html").app, "Nota")
        XCTAssertNil(try XCTUnwrap(controller.fileTypeCheckboxForTesting("html")).toolTip)
    }

    /// `permErr` is what Launch Services answers for a type it will not give
    /// away at all, and its own words explain nothing.
    func testLaunchServicesPermErrIsWordedForTheReader() throws {
        let permErr = NSError(
            domain: NSCocoaErrorDomain, code: 256,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -54)]
        )
        app("Safari", opening: "html")
        registry.failure = permErr
        openPage()

        try toggle("html")

        XCTAssertEqual(try row("html").app, "Not allowed by macOS")
        XCTAssertNotEqual(try row("html").app, permErr.localizedDescription)
    }

    // MARK: - The all button

    /// The button claims Text, Data and Code, and leaves the fourth group be.
    func testAllButtonClaimsOnlyTheFirstThreeGroups() throws {
        openPage()
        try click(controller.useNotaForAllButtonForTesting)

        let claimed = Set(registry.sets.map(\.type))
        for ext in DefaultAppTypes.textLikeExtensions {
            XCTAssertTrue(claimed.contains(try typeIdentifier(ext)), ".\(ext) was not claimed")
            XCTAssertTrue(try row(ext).ticked, ".\(ext) should be ticked")
        }
        let pictures = try XCTUnwrap(DefaultAppTypes.groups.last)
        XCTAssertEqual(pictures.titleKey, "Documents and pictures")
        for ext in pictures.extensions {
            XCTAssertFalse(claimed.contains(try typeIdentifier(ext)), ".\(ext) was claimed")
            XCTAssertFalse(try row(ext).ticked, ".\(ext) should be left alone")
            XCTAssertEqual(try row(ext).app, "None")
        }
    }

    // MARK: - The restore button

    /// It hands back every type this page took and leaves alone the one Nota
    /// already owned, which has nothing written down to hand back to.
    func testRestoreButtonPutsBackWhatWasRememberedAndSkipsTheRest() throws {
        let sublime = app("Sublime", opening: "txt")
        let numbers = app("Numbers", opening: "csv")
        registry.setDefault(notaBundle, forExtension: "sql")
        openPage()
        try toggle("txt")
        try toggle("csv")
        XCTAssertEqual(Preferences.shared.previousDefaultApps.count, 2)

        let before = registry.sets.count
        try click(controller.restorePreviousAppsButtonForTesting)

        XCTAssertEqual(registry.sets.count, before + 2, "one set each, not one per row")
        XCTAssertEqual(Set(registry.sets.suffix(2).map(\.app.identifier)),
                       [sublime.identifier, numbers.identifier])
        XCTAssertTrue(Preferences.shared.previousDefaultApps.isEmpty)
        XCTAssertFalse(try row("txt").ticked)
        XCTAssertEqual(try row("txt").app, "Sublime")
        XCTAssertFalse(try row("csv").ticked)
        XCTAssertEqual(try row("csv").app, "Numbers")
        // The row Nota already owned is untouched, and still cannot be untied.
        XCTAssertTrue(try row("sql").ticked)
        XCTAssertFalse(try row("sql").enabled)
    }

    /// Twins naming one type are one release, not two.
    func testRestoreButtonAsksOncePerTypeNotOncePerRow() throws {
        app("Sublime", opening: "md")
        openPage()
        try toggle("md")
        XCTAssertEqual(Preferences.shared.previousDefaultApps.count, 2, "md and markdown")

        let before = registry.sets.count
        try click(controller.restorePreviousAppsButtonForTesting)

        XCTAssertEqual(registry.sets.count, before + 1)
        XCTAssertFalse(try row("markdown").ticked)
    }

    /// Nothing written down, nothing to put back.
    func testRestoreButtonIsDisabledWithNothingRemembered() throws {
        openPage()
        XCTAssertFalse(controller.restorePreviousAppsButtonForTesting.isEnabled)

        app("Sublime", opening: "txt")
        openPage()
        try toggle("txt")
        XCTAssertTrue(controller.restorePreviousAppsButtonForTesting.isEnabled)

        try click(controller.restorePreviousAppsButtonForTesting)
        XCTAssertFalse(controller.restorePreviousAppsButtonForTesting.isEnabled)
    }

    // MARK: - The table and the words

    /// One place to add an extension, and no extension listed twice.
    func testTheTableIsOnePlaceWithNoDuplicates() {
        let all = DefaultAppTypes.allExtensions
        XCTAssertEqual(Set(all).count, all.count)
        XCTAssertEqual(DefaultAppTypes.textLikeExtensions.count, all.count - 10)
        XCTAssertEqual(DefaultAppTypes.notaBundleIdentifier, "com.manfad.nota")
        // Every row can name a type, dynamic ones included.
        for ext in all { XCTAssertNotNil(DefaultAppTypes.type(forExtension: ext), ext) }
        XCTAssertEqual(DefaultAppTypes.extensions(sharingTypeWith: "yml"), ["yaml", "yml"])
        XCTAssertEqual(DefaultAppTypes.extensions(sharingTypeWith: "css"), ["css"])
    }

    /// Every word on the page is in all three tables — the sentences included,
    /// which is what catches a key the page spells one way and the table another.
    func testEveryStringOnThePageIsTranslated() throws {
        for key in ["File types", "Use Nota for all text types", "Text", "Data", "Code",
                    "Documents and pictures", "None", "Not allowed by macOS",
                    "Nota could not take .%@ over: %@", "Restore previous apps"] {
            XCTAssertNotNil(L10n.simplifiedChinese[key], key)
            XCTAssertNotNil(L10n.traditionalChinese[key], key)
            XCTAssertNotNil(L10n.malay[key], key)
        }

        Preferences.shared.language = .simplifiedChinese
        let page = openPage()
        XCTAssertEqual(controller.pageTitles[page], "文件类型")
        XCTAssertNotEqual(controller.useNotaForAllButtonForTesting.title,
                          "Use Nota for all text types")

        let content = try XCTUnwrap(controller.window?.contentView)
        func allViews(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
        let english = allViews(in: content)
            .compactMap { ($0 as? NSTextField)?.stringValue }
            .filter { $0.hasPrefix("A ticked row") }
        XCTAssertTrue(english.isEmpty, "the page's own sentence is not in the tables")
    }
}
