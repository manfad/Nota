import AppKit
import PDFKit
import XCTest
@testable import Nota

/// File › Export…: what each tab offers, what the sheet asks, what lands in
/// the PDF, and the tab the written file opens in. See SPEC.md "## Export".
///
/// Every PDF here is read back with PDFKit rather than looked at: a page
/// count and the words on a page are the whole of what the export promises.
final class ExportTests: AppKitTestCase {
    private var temporaryDirectories: [URL] = []
    private var placement: ExportImagePlacement = .inline
    private var gutter = true

    override func setUpWithError() throws {
        try super.setUpWithError()
        // The export writes both of these; the suite must not leave the
        // reader's own settings changed behind it.
        placement = Preferences.shared.exportEditorImages
        gutter = Preferences.shared.showsLineNumbers
    }

    override func tearDownWithError() throws {
        Preferences.shared.exportEditorImages = placement
        Preferences.shared.showsLineNumbers = gutter
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    // MARK: - What a tab offers

    /// The list, and its order: what the reader is looking at first, the
    /// source after it, and the tab's own speciality last — and only where
    /// somebody has plugged that speciality in.
    @MainActor
    func testEachKindOffersItsOwnTargetsInOrder() throws {
        let directory = try makeTemporaryDirectory()
        let markdown = try makeNote(named: "notes.md", text: "# Title", in: directory)
        let plain = try makeNote(named: "log.txt", text: "just words", in: directory)
        let tex = try makeNote(named: "paper.tex", text: "\\section{One}", in: directory)
        let dump = try makeNote(named: "shop.sql", text: "SELECT 1;", in: directory)

        XCTAssertEqual(Exporter.targets(for: markdown), [.previewPDF, .editorPDF])
        XCTAssertEqual(Exporter.targets(for: plain), [.previewPDF, .editorPDF],
                       "a tab with no render still has the source to list")
        XCTAssertEqual(Exporter.targets(for: tex), [.previewPDF, .editorPDF],
                       "no TeX engine plugged in, so no TeX target offered")
        XCTAssertEqual(Exporter.targets(for: dump), [.previewPDF, .editorPDF])

        let picture = Note(id: UUID(), fileURL: exampleURL("Picture.png"), untitledName: nil,
                           text: "", attributes: [:], assets: nil, kind: .image)
        let rich = Note(id: UUID(), fileURL: exampleURL("Rich.rtf"), untitledName: nil,
                        text: "", attributes: [:], assets: nil, kind: .rtf)
        let document = Note(id: UUID(), fileURL: exampleURL("Demo.pdf"), untitledName: nil,
                            text: "", attributes: [:], assets: nil, kind: .pdf)
        let book = Note(id: UUID(), fileURL: exampleURL("Book.epub"), untitledName: nil,
                        text: "", attributes: [:], assets: nil, kind: .epub)

        XCTAssertEqual(Exporter.targets(for: picture), [.previewPDF])
        XCTAssertEqual(Exporter.targets(for: rich), [.previewPDF])
        XCTAssertEqual(Exporter.targets(for: document), [],
                       "a document exports as a book, and that exporter is not in yet")
        XCTAssertEqual(Exporter.targets(for: book), [])
    }

    /// A target whose exporter is plugged in is listed; the same target is
    /// gone again when it is taken out.
    @MainActor
    func testATargetIsOfferedOnlyWhileItsExporterIsPluggedIn() throws {
        let directory = try makeTemporaryDirectory()
        let tex = try makeNote(named: "paper.tex", text: "\\section{One}", in: directory)
        let dump = try makeNote(named: "shop.sql", text: "SELECT 1;", in: directory)
        let book = Note(id: UUID(), fileURL: exampleURL("Book.epub"), untitledName: nil,
                        text: "", attributes: [:], assets: nil, kind: .epub)

        Exporter.texPDF = { _, _, _ in }
        Exporter.csv = { _, _, _ in }
        Exporter.bookPDF = { _, _, _ in }
        defer {
            Exporter.texPDF = nil
            Exporter.csv = nil
            Exporter.bookPDF = nil
        }

        XCTAssertEqual(Exporter.targets(for: tex), [.previewPDF, .editorPDF, .texPDF])
        XCTAssertEqual(Exporter.targets(for: dump), [.previewPDF, .editorPDF, .csv])
        XCTAssertEqual(Exporter.targets(for: book), [.bookPDF])
    }

    // MARK: - The render on pages

    @MainActor
    func testAMarkdownNotePrintsItsHeadingOntoTheFirstPage() throws {
        let directory = try makeTemporaryDirectory()
        let note = try makeNote(
            named: "notes.md",
            text: "# Chapter One\n\nSome prose under the heading.\n",
            in: directory
        )
        let destination = directory.appendingPathComponent("notes.pdf")

        try Exporter.export(note, to: .previewPDF, at: destination, context: context())

        let pdf = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertGreaterThanOrEqual(pdf.pageCount, 1)
        XCTAssertTrue(try text(ofPage: 0, in: pdf).contains("Chapter One"),
                      "the render's own first heading is on the page")
    }

    @MainActor
    func testALongNoteRunsOverMoreThanOnePage() throws {
        let directory = try makeTemporaryDirectory()
        let lines = (1...400).map { "Paragraph \($0) of a note long enough to need paper." }
        let note = try makeNote(
            named: "long.md", text: lines.joined(separator: "\n\n"), in: directory
        )
        let destination = directory.appendingPathComponent("long.pdf")

        try Exporter.export(note, to: .previewPDF, at: destination, context: context())

        let pdf = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertGreaterThan(pdf.pageCount, 1, "the text is paginated, not clipped")
    }

    @MainActor
    func testARichTextDocumentExportsAsWhatTheViewerShows() throws {
        let directory = try makeTemporaryDirectory()
        let note = Note(id: UUID(), fileURL: exampleURL("Rich.rtf"), untitledName: nil,
                        text: "", attributes: [:], assets: nil, kind: .rtf)
        let destination = directory.appendingPathComponent("rich.pdf")

        try Exporter.export(note, to: .previewPDF, at: destination, context: context())

        let pdf = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertGreaterThanOrEqual(pdf.pageCount, 1)
        XCTAssertFalse((pdf.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "the document's own words are on the page")
    }

    @MainActor
    func testAPictureIsOnePageAndNothingElse() throws {
        let directory = try makeTemporaryDirectory()
        let note = Note(id: UUID(), fileURL: exampleURL("Picture.png"), untitledName: nil,
                        text: "", attributes: [:], assets: nil, kind: .image)
        let destination = directory.appendingPathComponent("picture.pdf")

        try Exporter.export(note, to: .previewPDF, at: destination, context: context())

        let pdf = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertEqual(pdf.pageCount, 1, "the picture, on one page, fitted to the margins")
    }

    // MARK: - The source listing

    /// The gutter is the editor's, and so is its absence: the listing wears
    /// line numbers exactly while the editor does.
    @MainActor
    func testTheListingCarriesLineNumbersOnlyWhileTheGutterIsOn() throws {
        let directory = try makeTemporaryDirectory()
        let lines = (1...30).map { _ in "a plain line of prose with no digits in it" }
        let note = try makeNote(
            named: "log.txt", text: lines.joined(separator: "\n"), in: directory
        )

        let numbered = directory.appendingPathComponent("numbered.pdf")
        try Exporter.export(
            note, to: .editorPDF, at: numbered, context: context(showsLineNumbers: true)
        )
        let bare = directory.appendingPathComponent("bare.pdf")
        try Exporter.export(
            note, to: .editorPDF, at: bare, context: context(showsLineNumbers: false)
        )

        let withGutter = try XCTUnwrap(PDFDocument(url: numbered)?.string)
        let withoutGutter = try XCTUnwrap(PDFDocument(url: bare)?.string)
        XCTAssertTrue(withGutter.contains("17"), "line 17 is numbered in the gutter")
        XCTAssertTrue(withGutter.contains("30"))
        XCTAssertFalse(withoutGutter.contains("17"),
                       "with the gutter off the listing is the text alone")
    }

    /// The two answers the sheet's Images row gives. Plates: the pictures
    /// come after the last page of text, one to a page, each with the line
    /// saying which figure it is. Inline: they are in the text and there are
    /// no plates at all.
    @MainActor
    func testPlatesFollowTheTextAndInlineLeavesNone() throws {
        let directory = try makeTemporaryDirectory()
        let assets = AssetStore(directory: directory.appendingPathComponent("assets"))
        let first = try XCTUnwrap(assets.importFile(at: exampleURL("Picture.png")))
        let second = try XCTUnwrap(assets.importFile(at: exampleURL("Picture.png")))
        let source = """
        The first picture is next.
        \(NoteText.token(for: first))
        And the second one follows it.
        \(NoteText.token(for: second))
        The end.
        """
        let note = try makeNote(named: "pictures.md", text: source, in: directory, assets: assets)

        let plated = directory.appendingPathComponent("plates.pdf")
        try Exporter.export(
            note, to: .editorPDF, at: plated,
            context: context(assets: assets, images: .plates)
        )
        let inline = directory.appendingPathComponent("inline.pdf")
        try Exporter.export(
            note, to: .editorPDF, at: inline,
            context: context(assets: assets, images: .inline)
        )

        let plates = try XCTUnwrap(PDFDocument(url: plated))
        XCTAssertGreaterThanOrEqual(plates.pageCount, 3,
                                    "at least one page of text and the two plates")
        let lastTwo = plates.pageCount - 2
        XCTAssertTrue(try text(ofPage: lastTwo, in: plates).contains("Figure 1"))
        XCTAssertTrue(try text(ofPage: lastTwo + 1, in: plates).contains("Figure 2"))
        XCTAssertFalse(try text(ofPage: lastTwo - 1, in: plates).contains("Figure "),
                       "the pages before the plates are the text")

        let flowing = try XCTUnwrap(PDFDocument(url: inline))
        XCTAssertFalse((flowing.string ?? "").contains("Figure "),
                       "inline pictures leave no plates behind them")
        XCTAssertEqual(flowing.pageCount, plates.pageCount - 2,
                       "the same text, without the two plate pages after it")
    }

    /// A note with no pictures has no plates, whichever way the sheet is
    /// answered.
    @MainActor
    func testANoteWithNoPicturesHasNoPlates() throws {
        let directory = try makeTemporaryDirectory()
        let note = try makeNote(named: "bare.md", text: "# Nothing to see", in: directory)
        let destination = directory.appendingPathComponent("bare.pdf")

        try Exporter.export(
            note, to: .editorPDF, at: destination, context: context(images: .plates)
        )

        let pdf = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertFalse((pdf.string ?? "").contains("Figure "))
    }

    // MARK: - The sheet

    /// One row for every tab, and a second one only for the listing: a render
    /// puts its pictures where the render puts them.
    @MainActor
    func testTheSheetShowsTheImagesRowOnlyForTheListing() {
        let dialog = ExportDialog(targets: [.previewPDF, .editorPDF], images: .inline)

        XCTAssertEqual(dialog.targetPopUp.itemTitles,
                       [ExportTarget.previewPDF.title, ExportTarget.editorPDF.title])
        XCTAssertEqual(dialog.chosenTarget, .previewPDF, "the first target is the one selected")
        XCTAssertFalse(dialog.isImagesRowShown)

        dialog.choose(.editorPDF)
        XCTAssertTrue(dialog.isImagesRowShown)
        XCTAssertEqual(dialog.imagesPopUp.itemTitles,
                       [ExportImagePlacement.inline.title, ExportImagePlacement.plates.title])

        dialog.choose(.previewPDF)
        XCTAssertFalse(dialog.isImagesRowShown)
    }

    /// The sheet opens on the remembered answer and hands back what was
    /// chosen.
    @MainActor
    func testTheSheetOpensOnTheRememberedPlacementAndHandsBackTheChoice() {
        let dialog = ExportDialog(targets: [.previewPDF, .editorPDF], images: .plates)
        dialog.choose(.editorPDF)

        XCTAssertEqual(dialog.chosenImages, .plates)
        XCTAssertEqual(dialog.export(), ExportChoice(target: .editorPDF, images: .plates))
    }

    // MARK: - The window

    /// The whole path, sheet and save dialog answered through their seams:
    /// the file is written and opens in a tab of its own beside the note,
    /// selected.
    @MainActor
    func testExportingOpensTheWrittenPDFInATab() throws {
        let directory = try makeTemporaryDirectory()
        let source = directory.appendingPathComponent("notes.md")
        try "# Exported\n\nA note with something in it.\n".write(
            to: source, atomically: true, encoding: .utf8
        )
        let controller = try makeController()
        controller.open(url: source)

        let destination = directory.appendingPathComponent("notes.pdf")
        var asked: [ExportTarget] = []
        controller.exportSheetProvider = { _, targets in
            asked = targets
            return ExportChoice(target: .previewPDF, images: .inline)
        }
        controller.savePanelProvider = { _ in destination }

        XCTAssertTrue(controller.canExportCurrentTab)
        controller.exportCurrentTab()

        XCTAssertEqual(asked, [.previewPDF, .editorPDF], "the sheet was asked about this tab")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(controller.openNotes.last?.title, "notes.pdf")
        XCTAssertEqual(controller.currentTabState.kind, .pdf,
                       "the export is in front, as a document tab")
        XCTAssertEqual(Preferences.shared.exportEditorImages, .inline,
                       "the sheet's answer is remembered")
    }

    /// Cancelling the sheet writes nothing and opens nothing.
    @MainActor
    func testCancellingTheSheetWritesNothing() throws {
        let directory = try makeTemporaryDirectory()
        let source = directory.appendingPathComponent("notes.md")
        try "# Nothing doing\n".write(to: source, atomically: true, encoding: .utf8)
        let controller = try makeController()
        controller.open(url: source)
        let tabs = controller.openNotes.count

        controller.exportSheetProvider = { _, _ in nil }
        controller.savePanelProvider = { _ in
            XCTFail("the save dialog must not be reached from a cancelled sheet")
            return nil
        }
        controller.exportCurrentTab()

        XCTAssertEqual(controller.openNotes.count, tabs)
    }

    // MARK: - Helpers

    @MainActor
    private func makeController() throws -> MainWindowController {
        _ = NSApplication.shared
        let controller = MainWindowController(
            store: SessionStore(directory: try makeTemporaryDirectory())
        )
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1000, height: 560))
        window.layoutIfNeeded()
        return controller
    }

    /// A note as a tab holds one: written to disk, so its name says what it
    /// renders as and its pictures come back as chips.
    @MainActor
    private func makeNote(
        named name: String, text: String, in directory: URL, assets: AssetStore? = nil
    ) throws -> Note {
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return Note(
            id: UUID(), fileURL: url, untitledName: nil, text: text,
            attributes: [.font: font, .foregroundColor: NSColor.textColor],
            assets: assets
        )
    }

    private var font: NSFont { .monospacedSystemFont(ofSize: 11, weight: .regular) }

    private func context(
        assets: AssetStore? = nil,
        images: ExportImagePlacement = .inline,
        showsLineNumbers: Bool = false
    ) -> Exporter.Context {
        Exporter.Context(
            font: font,
            paragraphStyle: NSParagraphStyle.default,
            assets: assets,
            showsLineNumbers: showsLineNumbers,
            images: images
        )
    }

    private func text(ofPage index: Int, in pdf: PDFDocument) throws -> String {
        try XCTUnwrap(XCTUnwrap(pdf.page(at: index)).string)
    }

    private func exampleURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/\(name)")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotaExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
