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

    // MARK: - What the Format popup lists

    /// The popup cannot be typed into, so whatever the dialog opens on has to
    /// be in the list — and a known extension is never listed twice.
    func testFormatOptionsCarryAnExtensionTheListDoesNotKnow() {
        let options = SaveNameComposer.formatOptions(including: "mdx")
        XCTAssertEqual(options.first, "mdx")
        XCTAssertEqual(options.dropFirst().map { $0 }, SaveNameComposer.knownExtensions())
    }

    func testFormatOptionsLeaveAKnownExtensionWhereItIs() {
        XCTAssertEqual(SaveNameComposer.formatOptions(including: "md"),
                       SaveNameComposer.knownExtensions())
        XCTAssertEqual(SaveNameComposer.formatOptions(including: "MD"),
                       SaveNameComposer.knownExtensions(),
                       "the list is matched case-insensitively, as it is deduped")
    }

    func testFormatOptionsTrimAndIgnoreAnEmptyExtension() {
        XCTAssertEqual(SaveNameComposer.formatOptions(including: " .mdx ").first, "mdx")
        XCTAssertEqual(SaveNameComposer.formatOptions(including: "  "),
                       SaveNameComposer.knownExtensions())
    }

    // MARK: - A pinned extension

    /// The Export sheet's rule: the target is the format, so the extension is
    /// never talked out of. A name that already spells it keeps it once; a
    /// name with some other dot in it gets it anyway.
    func testAPinnedExtensionIsAlwaysTheOneTheFileLandsOn() {
        XCTAssertEqual(
            SaveNameComposer.composedName(name: "notes", pinnedExtension: "pdf"), "notes.pdf"
        )
        XCTAssertEqual(
            SaveNameComposer.composedName(name: "notes.pdf", pinnedExtension: "pdf"),
            "notes.pdf", "the extension is not doubled"
        )
        XCTAssertEqual(
            SaveNameComposer.composedName(name: "notes.PDF", pinnedExtension: "pdf"),
            "notes.PDF", "and it is matched case-insensitively"
        )
        XCTAssertEqual(
            SaveNameComposer.composedName(name: "report.v2", pinnedExtension: "pdf"),
            "report.v2.pdf",
            "a dot in the name is not an extension the reader chose instead"
        )
        XCTAssertEqual(
            SaveNameComposer.composedName(name: "  rows  ", pinnedExtension: " .csv "),
            "rows.csv"
        )
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

    /// The export's own folder is a second key, so neither memory moves the
    /// other (SPEC "## Export").
    func testTheExportFolderIsRememberedApartFromTheSaveFolder() {
        let suite = "NotaTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let preferences = Preferences(defaults: defaults)

        XCTAssertNil(preferences.lastExportDirectory)
        let folder = URL(fileURLWithPath: "/tmp/exports", isDirectory: true)
        preferences.lastExportDirectory = folder
        XCTAssertEqual(preferences.lastExportDirectory?.path, folder.path)
        XCTAssertNil(preferences.lastSaveDirectory, "and the save folder is untouched")

        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.lastExportDirectory?.path, folder.path)
    }
}
