import AppKit
import XCTest
@testable import Nota

/// The interface vocabulary: the tables are complete against each other, the
/// Mac's own language picks the right one, and switching takes effect at once.
final class LocalizationTests: AppKitTestCase {
    /// Every table is keyed by the same English strings, so a call site that
    /// reads in one language reads in all of them.
    func testEveryTableCoversTheSameKeys() {
        let english = Set(L10n.simplifiedChinese.keys)
        for language in [AppLanguage.traditionalChinese, .malay] {
            let table = L10n.table(for: language)!
            let keys = Set(table.keys)
            XCTAssertTrue(english.subtracting(keys).isEmpty,
                          "\(language) is missing \(english.subtracting(keys).sorted())")
            XCTAssertTrue(keys.subtracting(english).isEmpty,
                          "\(language) has keys nothing else has: \(keys.subtracting(english).sorted())")
        }
    }

    /// An empty string would draw an empty menu item; a string still equal to
    /// its English key is an untranslated entry — except the handful of words
    /// Malay actually spells the English way.
    func testNoTableEntryIsEmptyOrStillEnglish() {
        for language in [AppLanguage.simplifiedChinese, .traditionalChinese, .malay] {
            let table = L10n.table(for: language)!
            let shared = L10n.sharedWithEnglish[language] ?? []
            for (english, translated) in table {
                XCTAssertFalse(translated.isEmpty, "\(language): “\(english)” is empty")
                if shared.contains(english) { continue }
                XCTAssertNotEqual(translated, english,
                                  "\(language): “\(english)” is not translated")
            }
        }
    }

    /// The two Chinese tables are separate vocabularies, not one converted
    /// character by character: Taiwan says 檔案, 視窗, 儲存, 拷貝.
    func testTraditionalChineseUsesItsOwnVocabulary() {
        XCTAssertEqual(L10n.traditionalChinese["File"], "檔案")
        XCTAssertEqual(L10n.traditionalChinese["Window"], "視窗")
        XCTAssertEqual(L10n.traditionalChinese["Save"], "儲存")
        XCTAssertEqual(L10n.traditionalChinese["Copy"], "拷貝")
        XCTAssertEqual(L10n.traditionalChinese["Settings"], "設定")
        XCTAssertEqual(L10n.malay["Settings"], "Tetapan")
        XCTAssertEqual(L10n.malay["Language"], "Bahasa")
    }

    /// The inline `chinese:` overrides a few call sites pass are in every
    /// table too, so those strings are translated rather than left English.
    func testInlineChineseOverridesExistInEveryTable() {
        for key in ["Replace", "Cancel", "Format", "System Default"] {
            XCTAssertNotNil(L10n.simplifiedChinese[key], key)
            XCTAssertNotNil(L10n.traditionalChinese[key], key)
            XCTAssertNotNil(L10n.malay[key], key)
        }
    }

    func testSystemResolvesTheMacsPreferredLanguage() {
        func resolved(_ identifier: String?) -> AppLanguage {
            AppLanguage.resolving(preferredLanguage: identifier)
        }
        XCTAssertEqual(resolved("zh-Hant"), .traditionalChinese)
        XCTAssertEqual(resolved("zh-Hant-TW"), .traditionalChinese)
        XCTAssertEqual(resolved("zh-TW"), .traditionalChinese)
        XCTAssertEqual(resolved("zh-HK"), .traditionalChinese)
        XCTAssertEqual(resolved("zh-Hans"), .simplifiedChinese)
        XCTAssertEqual(resolved("zh-Hans-CN"), .simplifiedChinese)
        XCTAssertEqual(resolved("zh-CN"), .simplifiedChinese)
        XCTAssertEqual(resolved("zh"), .simplifiedChinese)
        XCTAssertEqual(resolved("ms"), .malay)
        XCTAssertEqual(resolved("ms-MY"), .malay)
        XCTAssertEqual(resolved("ja"), .english, "Japanese is not one of ours")
        XCTAssertEqual(resolved("en-GB"), .english)
        XCTAssertEqual(resolved("fr-FR"), .english)
        XCTAssertEqual(resolved(nil), .english)
    }

    /// A chosen language resolves to itself; only `.system` asks the Mac.
    func testAChosenLanguageResolvesToItself() {
        for language in [AppLanguage.english, .simplifiedChinese, .traditionalChinese, .malay] {
            XCTAssertEqual(language.resolved, language)
        }
        XCTAssertNotEqual(AppLanguage.system.resolved, .system)
    }

    func testEachLanguageNamesItselfInItsOwnScript() {
        XCTAssertEqual(AppLanguage.english.title, "English")
        XCTAssertEqual(AppLanguage.simplifiedChinese.title, "简体中文")
        XCTAssertEqual(AppLanguage.traditionalChinese.title, "繁體中文")
        XCTAssertEqual(AppLanguage.malay.title, "Bahasa Melayu")
    }

    /// The raw values are what `UserDefaults` holds, so a preference saved by
    /// an older build still decodes.
    func testStoredRawValuesAreStable() {
        XCTAssertEqual(AppLanguage(rawValue: "system"), .system)
        XCTAssertEqual(AppLanguage(rawValue: "english"), .english)
        XCTAssertEqual(AppLanguage(rawValue: "simplifiedChinese"), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.traditionalChinese.rawValue, "traditionalChinese")
        XCTAssertEqual(AppLanguage.malay.rawValue, "malay")
    }

    /// The footer's counts and a new tab's name speak the language: one
    /// word for one and for many where the language has no plural, and
    /// Malay keeps "Untitled" as its own word.
    func testCountsAndUntitledSpeakTheLanguage() {
        let original = Preferences.shared.language
        defer { Preferences.shared.language = original }

        Preferences.shared.language = .english
        XCTAssertEqual(TextStats.counts("one two"), "2 words · 7 characters")
        XCTAssertEqual(UntitledNaming.nextName(existing: ["Untitled"]), "Untitled 2")

        Preferences.shared.language = .simplifiedChinese
        XCTAssertEqual(TextStats.counts("one two"), "2 字 · 7 字符")
        XCTAssertEqual(TextStats.counts("a"), "1 字 · 1 字符")
        XCTAssertEqual(TextStats.phrase(.lines, 40), "40 行")
        XCTAssertEqual(UntitledNaming.base, "无标题")
        XCTAssertEqual(UntitledNaming.nextName(existing: ["无标题"]), "无标题 2")

        Preferences.shared.language = .traditionalChinese
        XCTAssertEqual(TextStats.counts("one two"), "2 字 · 7 字元")
        XCTAssertEqual(TextStats.phrase(.images, 3), "3 圖片")
        XCTAssertEqual(UntitledNaming.base, "未命名")

        Preferences.shared.language = .malay
        XCTAssertEqual(TextStats.counts("one two"), "2 perkataan · 7 aksara")
        XCTAssertEqual(UntitledNaming.base, "Untitled")
    }

    func testTextSwitchesTableWithTheSetting() {
        let original = Preferences.shared.language
        defer { Preferences.shared.language = original }

        Preferences.shared.language = .english
        XCTAssertEqual(L10n.text("Settings"), "Settings")
        XCTAssertEqual(L10n.text("Replace", chinese: "替换"), "Replace")

        Preferences.shared.language = .simplifiedChinese
        XCTAssertEqual(L10n.text("Settings"), "设置")
        XCTAssertEqual(L10n.text("Window"), "窗口")
        // The inline override still wins for Simplified Chinese callers.
        XCTAssertEqual(L10n.text("Replace", chinese: "替换"), "替换")

        Preferences.shared.language = .traditionalChinese
        XCTAssertEqual(L10n.text("Settings"), "設定")
        XCTAssertEqual(L10n.text("Window"), "視窗")
        // A Simplified override does not leak into the other tables.
        XCTAssertEqual(L10n.text("Replace", chinese: "替换"), "取代")

        Preferences.shared.language = .malay
        XCTAssertEqual(L10n.text("Settings"), "Tetapan")
        XCTAssertEqual(L10n.text("Window"), "Tetingkap")
        XCTAssertEqual(L10n.text("Replace", chinese: "替换"), "Ganti")

        // A string no table knows falls back to the English it was written in.
        XCTAssertEqual(L10n.text("Not a key in any table"), "Not a key in any table")
    }

    /// The Settings popup lists all five, System first, and choosing one
    /// relabels the window without closing it.
    @MainActor
    func testLanguagePopUpListsEveryLanguage() throws {
        _ = NSApplication.shared
        let original = Preferences.shared.language
        defer { Preferences.shared.language = original }
        Preferences.shared.language = .english

        let controller = SettingsWindowController.shared
        let root = try XCTUnwrap(controller.window?.contentView)
        controller.selectPage(at: 0)
        func allViews(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
        let popUp = try XCTUnwrap(allViews(in: root).compactMap { $0 as? NSPopUpButton }.first {
            $0.itemTitles.contains("Bahasa Melayu")
        })
        XCTAssertEqual(popUp.itemTitles,
                       ["System Default", "English", "简体中文", "繁體中文", "Bahasa Melayu"])

        popUp.selectItem(at: 3)
        _ = NSApp.sendAction(try XCTUnwrap(popUp.action), to: popUp.target, from: popUp)
        XCTAssertEqual(Preferences.shared.language, .traditionalChinese)
        XCTAssertEqual(controller.window?.title, "設定")
        XCTAssertEqual(controller.rows(on: 0).map(\.title), ["語言", "主題"])

        popUp.selectItem(at: 4)
        _ = NSApp.sendAction(try XCTUnwrap(popUp.action), to: popUp.target, from: popUp)
        XCTAssertEqual(Preferences.shared.language, .malay)
        XCTAssertEqual(controller.window?.title, "Tetapan")
        XCTAssertEqual(controller.rows(on: 0).map(\.title), ["Bahasa", "Tema"])
    }
}
