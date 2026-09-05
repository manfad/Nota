import XCTest
@testable import Nota

final class SaveNameComposerTests: XCTestCase {
    // MARK: - Splitting

    func testSplittingSeparatesAKnownExtension() {
        let split = SaveNameComposer.split(name: "notes.md")
        XCTAssertEqual(split.base, "notes")
        XCTAssertEqual(split.extension, "md")
    }

    func testSplittingLeavesANameWithoutADotAlone() {
        let split = SaveNameComposer.split(name: "Untitled")
        XCTAssertEqual(split.base, "Untitled")
        XCTAssertNil(split.extension)
    }

    func testSplittingTreatsADotfileAsHavingNoExtension() {
        let split = SaveNameComposer.split(name: ".gitignore")
        XCTAssertEqual(split.base, ".gitignore")
        XCTAssertNil(split.extension)
    }

    // MARK: - Composing

    func testAPlainNameTakesTheComboExtension() {
        XCTAssertEqual(SaveNameComposer.composedName(name: "notes", extension: "md"), "notes.md")
    }

    func testANameThatAlreadyHasAnExtensionIgnoresTheCombo() {
        // The name field's own extension wins — Save must never produce
        // "notes.md.txt".
        XCTAssertEqual(SaveNameComposer.composedName(name: "notes.md", extension: "txt"), "notes.md")
    }

    func testALeadingDotTypedIntoTheComboIsTrimmed() {
        XCTAssertEqual(SaveNameComposer.composedName(name: "notes", extension: ".toml"), "notes.toml")
    }

    func testAnEmptyComboLeavesTheNameBare() {
        XCTAssertEqual(SaveNameComposer.composedName(name: "notes", extension: ""), "notes")
    }

    func testASingleDotNameCountsAsAlreadyHavingAnExtension() {
        // "a.b" already has an extension by NSSavePanel's own rule, however
        // short, so the combo is ignored just like the "notes.md" case.
        XCTAssertEqual(SaveNameComposer.composedName(name: "a.b", extension: "md"), "a.b")
    }

    func testWhitespaceAroundBothFieldsIsTrimmed() {
        XCTAssertEqual(SaveNameComposer.composedName(name: "  notes  ", extension: "  md  "), "notes.md")
    }

    // MARK: - Composed URL

    func testComposedURLJoinsTheDirectoryToTheComposedName() {
        let directory = URL(fileURLWithPath: "/tmp/notes", isDirectory: true)
        let url = SaveNameComposer.composedURL(directory: directory, name: "notes", extension: "md")
        XCTAssertEqual(url, directory.appendingPathComponent("notes.md"))
    }

    func testComposedURLAlsoRespectsANameThatAlreadyHasAnExtension() {
        let directory = URL(fileURLWithPath: "/tmp/notes", isDirectory: true)
        let url = SaveNameComposer.composedURL(directory: directory, name: "notes.md", extension: "txt")
        XCTAssertEqual(url, directory.appendingPathComponent("notes.md"))
    }

    // MARK: - Known extensions

    func testKnownExtensionsLeadsWithMarkdownAndHasNoDuplicates() {
        let extensions = SaveNameComposer.knownExtensions()
        XCTAssertEqual(extensions.first, "md")
        XCTAssertEqual(extensions.count, Set(extensions.map { $0.lowercased() }).count)
        XCTAssertTrue(extensions.contains("toml"))
        XCTAssertTrue(extensions.contains("ts"))
    }

    // MARK: - Preferences round trip

    func testTheLastChosenExtensionRoundTripsThroughPreferences() {
        let suite = "NotaTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let preferences = Preferences(defaults: defaults)

        XCTAssertEqual(preferences.lastSaveExtension, "md", "md until a save says otherwise")
        preferences.lastSaveExtension = "toml"
        XCTAssertEqual(preferences.lastSaveExtension, "toml")

        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.lastSaveExtension, "toml")
    }
}
