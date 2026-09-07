import AppKit
import XCTest
@testable import Nota

/// Nota's own Save dialog (SPEC Done 42): what its three rows open on, what
/// Save composes out of them, when Save is available at all, and that it
/// wears whatever language is set while it stands.
///
/// Nothing here runs a modal session — the dialog is built, read and its
/// buttons taken directly, so no sheet ever goes up and no alert ever waits
/// for a person.
final class SaveDialogTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    // MARK: - What it opens on

    /// A named file keeps its own name, its own extension and its own folder.
    @MainActor
    func testANamedFileOpensOnItsOwnNameFormatAndFolder() throws {
        let folder = try makeTemporaryDirectory()
        let file = folder.appendingPathComponent("app.js")
        let dialog = SaveDialog(
            suggestedName: "app.js", existingFileURL: file,
            lastDirectory: try makeTemporaryDirectory(), lastExtension: "md"
        )

        XCTAssertEqual(dialog.nameField.stringValue, "app",
                       "the name field carries the base name, never the extension")
        XCTAssertEqual(dialog.formatPopUp.titleOfSelectedItem, "js")
        XCTAssertEqual(dialog.locationURL.standardizedFileURL, folder.standardizedFileURL,
                       "a named file saves where it already lives, not where the last save went")
        XCTAssertEqual(dialog.locationField.toolTip, dialog.locationURL.path)
        XCTAssertTrue(dialog.locationField.attributedStringValue.string
            .hasSuffix(folder.lastPathComponent))
    }

    /// An untitled note has neither: the format is whatever was chosen last
    /// and the folder is where the last save landed.
    @MainActor
    func testAnUntitledNoteOpensOnTheRememberedFormatAndFolder() throws {
        let remembered = try makeTemporaryDirectory()
        let dialog = SaveDialog(
            suggestedName: "Shopping list.md", existingFileURL: nil,
            lastDirectory: remembered, lastExtension: "txt"
        )

        XCTAssertEqual(dialog.nameField.stringValue, "Shopping list")
        XCTAssertEqual(dialog.formatPopUp.titleOfSelectedItem, "txt")
        XCTAssertEqual(dialog.locationURL.standardizedFileURL, remembered.standardizedFileURL)
    }

    /// Nothing remembered and no file of its own: Documents, the way a save
    /// panel with nothing to go on opens.
    @MainActor
    func testWithNothingRememberedItOpensInDocuments() {
        let dialog = SaveDialog(
            suggestedName: "Untitled.md", existingFileURL: nil,
            lastDirectory: nil, lastExtension: "md"
        )
        let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first
        XCTAssertEqual(dialog.locationURL.standardizedFileURL, documents?.standardizedFileURL)
    }

    /// The popup cannot be typed into, so an extension it does not know —
    /// remembered from a file saved as `.mdx` — is listed rather than lost.
    @MainActor
    func testARememberedExtensionOutsideTheKnownListIsStillOffered() throws {
        XCTAssertFalse(SaveNameComposer.knownExtensions().contains("mdx"))
        let dialog = SaveDialog(
            suggestedName: "Untitled.md", existingFileURL: nil,
            lastDirectory: try makeTemporaryDirectory(), lastExtension: "mdx"
        )
        XCTAssertTrue(dialog.formatPopUp.itemTitles.contains("mdx"))
        XCTAssertEqual(dialog.formatPopUp.titleOfSelectedItem, "mdx")
        XCTAssertTrue(dialog.formatPopUp.itemTitles.contains("md"),
                      "the known list is still all there behind it")
    }

    // MARK: - What Save composes

    @MainActor
    func testTheComposedURLIsTheNameAndThePopUpInTheLocation() throws {
        let folder = try makeTemporaryDirectory()
        let dialog = SaveDialog(
            suggestedName: "Untitled.md", existingFileURL: nil,
            lastDirectory: folder, lastExtension: "md"
        )
        dialog.nameField.stringValue = "notes"
        dialog.formatPopUp.selectItem(withTitle: "txt")

        XCTAssertEqual(dialog.composedURL.standardizedFileURL,
                       folder.appendingPathComponent("notes.txt").standardizedFileURL)
    }

    /// A name typed with its own extension wins over the popup — Save must
    /// never write `notes.txt.md`.
    @MainActor
    func testANameTypedWithItsOwnExtensionWinsOverThePopUp() throws {
        let folder = try makeTemporaryDirectory()
        let dialog = SaveDialog(
            suggestedName: "Untitled.md", existingFileURL: nil,
            lastDirectory: folder, lastExtension: "md"
        )
        dialog.nameField.stringValue = "notes.txt"

        XCTAssertEqual(dialog.formatPopUp.titleOfSelectedItem, "md")
        XCTAssertEqual(dialog.composedURL.standardizedFileURL,
                       folder.appendingPathComponent("notes.txt").standardizedFileURL)
    }

    // MARK: - Save itself

    @MainActor
    func testSaveIsUnavailableWhileTheNameIsBlank() throws {
        let dialog = SaveDialog(
            suggestedName: "Untitled.md", existingFileURL: nil,
            lastDirectory: try makeTemporaryDirectory(), lastExtension: "md"
        )
        XCTAssertTrue(dialog.saveButton.isEnabled)

        dialog.nameField.stringValue = "   "
        dialog.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertFalse(dialog.saveButton.isEnabled, "a blank name would write a file called .md")
        XCTAssertFalse(dialog.save(), "and Save does nothing even if it is asked directly")

        dialog.nameField.stringValue = "notes"
        dialog.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertTrue(dialog.saveButton.isEnabled)
    }

    /// An existing file that is not the note's own is a replacement, and the
    /// dialog stays put when the alert says no.
    @MainActor
    func testReplacingSomebodyElsesFileIsAsked() throws {
        let folder = try makeTemporaryDirectory()
        let existing = folder.appendingPathComponent("notes.md")
        try "already here".write(to: existing, atomically: true, encoding: .utf8)

        let dialog = SaveDialog(
            suggestedName: "Untitled.md", existingFileURL: nil,
            lastDirectory: folder, lastExtension: "md"
        )
        dialog.nameField.stringValue = "notes"

        var asked: [URL] = []
        dialog.confirmReplace = { url in
            asked.append(url)
            return false
        }
        XCTAssertFalse(dialog.save(), "refused: the dialog is still standing")
        XCTAssertEqual(asked.map(\.lastPathComponent), ["notes.md"])

        dialog.confirmReplace = { _ in true }
        XCTAssertTrue(dialog.save())
    }

    /// Saving a named file over itself is not a replacement and asks nothing.
    @MainActor
    func testSavingOverTheNotesOwnFileAsksNothing() throws {
        let folder = try makeTemporaryDirectory()
        let file = folder.appendingPathComponent("notes.md")
        try "mine".write(to: file, atomically: true, encoding: .utf8)

        let dialog = SaveDialog(
            suggestedName: "notes.md", existingFileURL: file,
            lastDirectory: nil, lastExtension: "md"
        )
        dialog.confirmReplace = { _ in
            XCTFail("saving over yourself is not a replacement")
            return false
        }
        XCTAssertTrue(dialog.save())
    }

    // MARK: - Language

    /// The dialog is relabelled where it stands, so a language changed while
    /// it is open takes effect at once rather than on the next save.
    @MainActor
    func testChangingTheLanguageRelabelsTheDialogInPlace() throws {
        let original = Preferences.shared.language
        defer { Preferences.shared.language = original }
        Preferences.shared.language = .english

        let dialog = SaveDialog(
            suggestedName: "Untitled.md", existingFileURL: nil,
            lastDirectory: try makeTemporaryDirectory(), lastExtension: "md"
        )
        XCTAssertEqual(dialog.headingLabel.stringValue, "Save")
        XCTAssertEqual(dialog.saveAsLabel.stringValue, "Save As:")
        XCTAssertEqual(dialog.locationLabel.stringValue, "Location:")
        XCTAssertEqual(dialog.chooseButton.title, "Choose…")
        XCTAssertEqual(dialog.saveButton.title, "Save")
        XCTAssertEqual(dialog.cancelButton.title, "Cancel")

        Preferences.shared.language = .traditionalChinese
        XCTAssertEqual(dialog.panel.title, "儲存")
        XCTAssertEqual(dialog.headingLabel.stringValue, "儲存")
        XCTAssertEqual(dialog.saveAsLabel.stringValue, "另存新檔:")
        XCTAssertEqual(dialog.locationLabel.stringValue, "位置:")
        XCTAssertEqual(dialog.chooseButton.title, "選擇…")
        XCTAssertEqual(dialog.saveButton.title, "儲存")
        XCTAssertEqual(dialog.cancelButton.title, "取消")

        Preferences.shared.language = .malay
        XCTAssertEqual(dialog.saveAsLabel.stringValue, "Simpan Sebagai:")
        XCTAssertEqual(dialog.locationLabel.stringValue, "Lokasi:")
        XCTAssertEqual(dialog.chooseButton.title, "Pilih…")
        XCTAssertEqual(dialog.saveButton.title, "Simpan")
    }

    /// The list is not the end of it: `Other…` opens a field for an extension
    /// the popup does not carry, and `None` writes the name bare.
    @MainActor
    func testOtherAndNoneReachPastTheList() throws {
        let folder = try makeTemporaryDirectory()
        let dialog = SaveDialog(
            suggestedName: "notes.md", existingFileURL: nil,
            lastDirectory: folder, lastExtension: "md"
        )
        XCTAssertTrue(dialog.otherExtensionField.isHidden, "the field waits behind Other…")
        XCTAssertNotNil(dialog.formatPopUp.menu?.item(withTag: SaveDialog.noneTag))
        XCTAssertNotNil(dialog.formatPopUp.menu?.item(withTag: SaveDialog.otherTag))

        dialog.chooseOtherExtension("")
        XCTAssertFalse(dialog.otherExtensionField.isHidden, "Other… brings the field out")
        XCTAssertFalse(dialog.saveButton.isEnabled, "and Save waits for the extension")

        dialog.otherExtensionField.stringValue = "mdx"
        dialog.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertTrue(dialog.saveButton.isEnabled)
        XCTAssertEqual(dialog.composedURL.lastPathComponent, "notes.mdx")

        dialog.chooseOtherExtension(".TeXt ")
        XCTAssertEqual(dialog.composedURL.lastPathComponent, "notes.TeXt",
                       "a leading dot and stray whitespace are trimmed, the case is the reader's")

        dialog.selectNoExtension()
        XCTAssertTrue(dialog.otherExtensionField.isHidden, "a listed pick puts the field away")
        XCTAssertTrue(dialog.saveButton.isEnabled)
        XCTAssertEqual(dialog.composedURL.lastPathComponent, "notes", "None writes the name bare")

        dialog.formatPopUp.selectItem(withTitle: "txt")
        XCTAssertEqual(dialog.composedURL.lastPathComponent, "notes.txt")
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SaveDialogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }
}
