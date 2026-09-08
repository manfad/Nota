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
    private var exportDirectory: URL?
    private var saveDirectory: URL?
    private var saveExtension = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        // The export writes these; the suite must not leave the reader's own
        // settings changed behind it.
        placement = Preferences.shared.exportEditorImages
        gutter = Preferences.shared.showsLineNumbers
        exportDirectory = Preferences.shared.lastExportDirectory
        saveDirectory = Preferences.shared.lastSaveDirectory
        saveExtension = Preferences.shared.lastSaveExtension
        // The same call the app makes at launch: without it a tab offers the
        // two PDFs Nota writes itself and nothing else.
        Exporter.installDefaultHooks()
    }

    override func tearDownWithError() throws {
        Preferences.shared.exportEditorImages = placement
        Preferences.shared.showsLineNumbers = gutter
        Preferences.shared.lastExportDirectory = exportDirectory
        Preferences.shared.lastSaveDirectory = saveDirectory
        Preferences.shared.lastSaveExtension = saveExtension
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    // MARK: - What a tab offers

    /// The list, and its order: what the reader is looking at first, the
    /// source after it, and the tab's own speciality last.
    @MainActor
    func testEachKindOffersItsOwnTargetsInOrder() throws {
        let directory = try makeTemporaryDirectory()
        let markdown = try makeNote(named: "notes.md", text: "# Title", in: directory)
        let plain = try makeNote(named: "log.txt", text: "just words", in: directory)
        let tex = try makeNote(named: "paper.tex", text: "\\section{One}", in: directory)
        let dump = try makeNote(named: "shop.sql", text: "SELECT 1;", in: directory)
        let table = try makeNote(named: "rows.csv", text: "a,b\n1,2\n", in: directory)

        XCTAssertEqual(Exporter.targets(for: markdown),
                       [.previewPDF, .editorPDF, .previewPNG, .editorPNG])
        XCTAssertEqual(Exporter.targets(for: plain),
                       [.previewPDF, .editorPDF, .editorPNG],
                       "a tab with no render still has the source to list")
        XCTAssertEqual(Exporter.targets(for: tex),
                       [.previewPDF, .editorPDF, .previewPNG, .editorPNG, .texPDF])
        XCTAssertEqual(Exporter.targets(for: dump),
                       [.previewPDF, .editorPDF, .editorPNG],
                       "a grid's rows are the pane's own Export CSV button, not a target")
        XCTAssertEqual(Exporter.targets(for: table),
                       [.previewPDF, .editorPDF, .editorPNG])

        let picture = Note(id: UUID(), fileURL: exampleURL("Picture.png"), untitledName: nil,
                           text: "", attributes: [:], assets: nil, kind: .image)
        let rich = Note(id: UUID(), fileURL: exampleURL("Rich.rtf"), untitledName: nil,
                        text: "", attributes: [:], assets: nil, kind: .rtf)
        let document = Note(id: UUID(), fileURL: exampleURL("Demo.pdf"), untitledName: nil,
                            text: "", attributes: [:], assets: nil, kind: .pdf)
        let book = Note(id: UUID(), fileURL: exampleURL("Book.epub"), untitledName: nil,
                        text: "", attributes: [:], assets: nil, kind: .epub)

        XCTAssertEqual(Exporter.targets(for: picture), [.previewPDF])
        XCTAssertEqual(Exporter.targets(for: rich), [.previewPDF, .previewPNG])
        XCTAssertEqual(Exporter.targets(for: document), [.epub],
                       "the one export that is not a PDF: a document is one already")
        XCTAssertEqual(Exporter.targets(for: book), [.bookPDF])
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

        Exporter.texPDF = nil
        Exporter.bookPDF = nil
        defer { Exporter.installDefaultHooks() }

        XCTAssertEqual(Exporter.targets(for: tex),
                       [.previewPDF, .editorPDF, .previewPNG, .editorPNG])
        XCTAssertEqual(Exporter.targets(for: dump),
                       [.previewPDF, .editorPDF, .editorPNG])
        XCTAssertEqual(Exporter.targets(for: book), [])

        Exporter.installDefaultHooks()
        XCTAssertEqual(Exporter.targets(for: tex),
                       [.previewPDF, .editorPDF, .previewPNG, .editorPNG, .texPDF])
        XCTAssertEqual(Exporter.targets(for: dump),
                       [.previewPDF, .editorPDF, .editorPNG])
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

        try exportAndWait(note, to: .previewPDF, at: destination, context: context())

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

        try exportAndWait(note, to: .previewPDF, at: destination, context: context())

        let pdf = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertGreaterThan(pdf.pageCount, 1, "the text is paginated, not clipped")
    }

    @MainActor
    func testARichTextDocumentExportsAsWhatTheViewerShows() throws {
        let directory = try makeTemporaryDirectory()
        let note = Note(id: UUID(), fileURL: exampleURL("Rich.rtf"), untitledName: nil,
                        text: "", attributes: [:], assets: nil, kind: .rtf)
        let destination = directory.appendingPathComponent("rich.pdf")

        try exportAndWait(note, to: .previewPDF, at: destination, context: context())

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

        try exportAndWait(note, to: .previewPDF, at: destination, context: context())

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
        try exportAndWait(
            note, to: .editorPDF, at: numbered, context: context(showsLineNumbers: true)
        )
        let bare = directory.appendingPathComponent("bare.pdf")
        try exportAndWait(
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
        try exportAndWait(
            note, to: .editorPDF, at: plated,
            context: context(assets: assets, images: .plates)
        )
        let inline = directory.appendingPathComponent("inline.pdf")
        try exportAndWait(
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

        try exportAndWait(
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

        XCTAssertEqual(labels(of: dialog.formatSegments), ["PDF"],
                       "one file, so one segment")
        XCTAssertEqual(labels(of: dialog.viewSegments),
                       [ExportViewChoice.editor.title, ExportViewChoice.preview.title])
        XCTAssertEqual(dialog.chosenTarget, .previewPDF, "the first target is the one selected")
        XCTAssertFalse(dialog.isImagesRowShown)

        dialog.choose(.editorPDF)
        XCTAssertTrue(dialog.isImagesRowShown)
        XCTAssertEqual([dialog.inlineButton.title, dialog.platesButton.title],
                       [ExportImagePlacement.inline.title, ExportImagePlacement.plates.title])

        dialog.choose(.previewPDF)
        XCTAssertFalse(dialog.isImagesRowShown)
    }

    /// The sheet opens on the remembered answer and hands back what was
    /// chosen — the shape, the pictures and the file all three.
    @MainActor
    func testTheSheetOpensOnTheRememberedPlacementAndHandsBackTheChoice() throws {
        let folder = try makeTemporaryDirectory()
        let dialog = makeSheet(
            targets: [.previewPDF, .editorPDF], images: .plates,
            names: [.previewPDF: "notes.pdf", .editorPDF: "notes.pdf"], in: folder
        )
        dialog.choose(.editorPDF)

        XCTAssertEqual(dialog.chosenImages, .plates)
        XCTAssertEqual(dialog.export(), ExportChoice(
            target: .editorPDF, images: .plates,
            destination: folder.appendingPathComponent("notes.pdf")
        ))
    }

    /// The extension after the name is the target's own, and it changes with
    /// the popup: there is no format to pick, because the target is one.
    @MainActor
    func testTheExtensionLabelFollowsTheTarget() throws {
        let folder = try makeTemporaryDirectory()
        let dialog = makeSheet(
            targets: [.previewPDF, .editorPDF, .epub], images: .inline,
            names: [.previewPDF: "rows.pdf", .editorPDF: "rows.pdf", .epub: "rows.epub"],
            in: folder
        )

        XCTAssertEqual(dialog.extensionLabel.stringValue, ".pdf")
        dialog.choose(.epub)
        XCTAssertEqual(dialog.extensionLabel.stringValue, ".epub")
        XCTAssertEqual(dialog.composedURL, folder.appendingPathComponent("rows.epub"))

        let book = makeSheet(
            targets: [.epub], images: .inline, names: [.epub: "Demo.epub"], in: folder
        )
        XCTAssertEqual(book.extensionLabel.stringValue, ".epub")
    }

    /// The name follows the target's own default — each target names the file
    /// its own way — until the reader types one of their own, and then it
    /// stays where they put it.
    @MainActor
    func testTheNameFollowsTheTargetUntilTheReaderTypesOne() throws {
        let folder = try makeTemporaryDirectory()
        let dialog = makeSheet(
            targets: [.previewPDF, .editorPDF, .epub], images: .inline,
            names: [.previewPDF: "Shop.pdf", .editorPDF: "Shop.pdf",
                    .epub: "Shop-book.epub"],
            in: folder
        )

        XCTAssertEqual(dialog.nameField.stringValue, "Shop",
                       "the base alone; the extension is the label beside it")
        dialog.choose(.epub)
        XCTAssertEqual(dialog.nameField.stringValue, "Shop-book",
                       "the target the reader picked names the file")

        dialog.type(name: "for the accountant")
        dialog.choose(.previewPDF)
        XCTAssertEqual(dialog.nameField.stringValue, "for the accountant",
                       "a name the reader typed is not taken away by the popup")
        XCTAssertEqual(dialog.composedURL,
                       folder.appendingPathComponent("for the accountant.pdf"))
    }

    /// Export with nothing in the field would write a file called `.pdf`, so
    /// the button is simply not available until there is a name.
    @MainActor
    func testExportIsUnavailableWithoutAName() throws {
        let folder = try makeTemporaryDirectory()
        let dialog = makeSheet(
            targets: [.previewPDF], images: .inline, names: [.previewPDF: "notes.pdf"],
            in: folder
        )
        XCTAssertTrue(dialog.exportButton.isEnabled)

        dialog.type(name: "   ")
        XCTAssertFalse(dialog.exportButton.isEnabled)
        XCTAssertNil(dialog.export(), "and Return means nothing either")

        dialog.type(name: "notes")
        XCTAssertTrue(dialog.exportButton.isEnabled)
    }

    /// A name that is already a file on disk asks the window's own replace
    /// question. A "no" leaves the sheet standing and hands nothing back; a
    /// "yes" goes through to exactly that file.
    @MainActor
    func testAnExistingFileIsAskedAboutAndANoKeepsTheSheetUp() throws {
        let folder = try makeTemporaryDirectory()
        let taken = folder.appendingPathComponent("notes.pdf")
        try "already here".write(to: taken, atomically: true, encoding: .utf8)

        let dialog = makeSheet(
            targets: [.previewPDF], images: .inline, names: [.previewPDF: "notes.pdf"],
            in: folder
        )
        var asked: [URL] = []
        var answer = false
        dialog.confirmReplace = { url in
            asked.append(url)
            return answer
        }

        XCTAssertNil(dialog.export(), "a refused replacement is not a choice")
        XCTAssertEqual(asked, [taken])
        XCTAssertEqual(try String(contentsOf: taken, encoding: .utf8), "already here",
                       "and nothing was written over it")

        answer = true
        XCTAssertEqual(dialog.export()?.destination, taken)
        XCTAssertEqual(asked.count, 2)
    }

    /// A name nobody else has is written without a word.
    @MainActor
    func testAFreeNameAsksNothing() throws {
        let folder = try makeTemporaryDirectory()
        let dialog = makeSheet(
            targets: [.previewPDF], images: .inline, names: [.previewPDF: "notes.pdf"],
            in: folder
        )
        dialog.confirmReplace = { _ in
            XCTFail("nothing is there to replace")
            return false
        }
        XCTAssertEqual(dialog.export()?.destination,
                       folder.appendingPathComponent("notes.pdf"))
    }

    /// Where the sheet opens: the note's own folder when it has a file, else
    /// the folder the last export landed in, and `Choose…` moves it.
    @MainActor
    func testTheSheetOpensInTheNotesOwnFolderThenTheLastExportFolder() throws {
        let beside = try makeTemporaryDirectory()
        let remembered = try makeTemporaryDirectory()
        let named = ExportDialog(
            targets: [.previewPDF], images: .inline,
            suggestedNames: [.previewPDF: "notes.pdf"],
            existingFileURL: beside.appendingPathComponent("notes.md"),
            lastDirectory: remembered
        )
        XCTAssertEqual(named.locationURL.standardizedFileURL, beside.standardizedFileURL,
                       "a note exports beside itself, not where the last export went")

        let untitled = ExportDialog(
            targets: [.previewPDF], images: .inline,
            suggestedNames: [.previewPDF: "Untitled.pdf"],
            existingFileURL: nil, lastDirectory: remembered
        )
        XCTAssertEqual(untitled.locationURL.standardizedFileURL,
                       remembered.standardizedFileURL)

        let elsewhere = try makeTemporaryDirectory()
        untitled.choose(elsewhere)
        XCTAssertEqual(untitled.composedURL,
                       elsewhere.appendingPathComponent("Untitled.pdf"))
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
            return ExportChoice(
                target: .previewPDF, images: .inline, destination: destination
            )
        }
        controller.exportPanelProvider = { _, _ in
            XCTFail("File › Export… asks in its own sheet; there is no second dialog")
            return nil
        }

        XCTAssertTrue(controller.canExportCurrentTab)
        controller.exportCurrentTab()

        XCTAssertEqual(asked, [.previewPDF, .editorPDF, .previewPNG, .editorPNG],
                       "the sheet was asked about this tab")
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
        controller.exportCurrentTab()

        XCTAssertEqual(controller.openNotes.count, tabs)
    }

    /// An export remembers its own folder and leaves the save dialog's
    /// memory alone: exporting as PDF must not offer `pdf`, or that folder,
    /// the next time ⌘S asks about the note itself.
    @MainActor
    func testAnExportRemembersItsFolderAndLeavesTheSaveDialogAlone() throws {
        let directory = try makeTemporaryDirectory()
        let source = directory.appendingPathComponent("notes.md")
        try "# Exported\n".write(to: source, atomically: true, encoding: .utf8)
        let controller = try makeController()
        controller.open(url: source)

        let elsewhere = try makeTemporaryDirectory()
        Preferences.shared.lastSaveDirectory = directory
        Preferences.shared.lastSaveExtension = "md"

        let destination = elsewhere.appendingPathComponent("notes.pdf")
        controller.exportSheetProvider = { _, _ in
            ExportChoice(target: .previewPDF, images: .inline, destination: destination)
        }
        controller.exportCurrentTab()

        XCTAssertEqual(Preferences.shared.lastExportDirectory?.standardizedFileURL,
                       elsewhere.standardizedFileURL,
                       "the next export opens where this one landed")
        XCTAssertEqual(Preferences.shared.lastSaveDirectory?.standardizedFileURL,
                       directory.standardizedFileURL,
                       "and ⌘S still offers the folder the note was saved in")
        XCTAssertEqual(Preferences.shared.lastSaveExtension, "md")
    }

    // MARK: - Every hook, end to end

    /// A book onto pages, through `EPUBToPDF` and WebKit. Slow — every
    /// chapter is a page load and a print — so one small book is the whole
    /// of what is asserted: pages came out, with words on them.
    @MainActor
    func testABookExportsOntoPages() throws {
        let directory = try makeTemporaryDirectory()
        let book = Note(id: UUID(), fileURL: exampleURL("Book.epub"), untitledName: nil,
                        text: "", attributes: [:], assets: nil, kind: .epub)
        let destination = directory.appendingPathComponent("book.pdf")

        try exportAndWait(book, to: .bookPDF, at: destination, context: context())

        let pdf = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertGreaterThanOrEqual(pdf.pageCount, 1)
        XCTAssertFalse((pdf.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "the book's own words are on the pages")
    }

    /// A document taken apart into a book, through `PDFToEPUB` — the one
    /// export that is not a PDF.
    @MainActor
    func testADocumentExportsAsABook() throws {
        let directory = try makeTemporaryDirectory()
        let document = Note(id: UUID(), fileURL: exampleURL("Demo.pdf"), untitledName: nil,
                            text: "", attributes: [:], assets: nil, kind: .pdf)
        let destination = directory.appendingPathComponent("demo.epub")

        try exportAndWait(document, to: .epub, at: destination, context: context())

        let written = try XCTUnwrap(EPUBBook.open(destination))
        XCTAssertFalse(written.chapters.isEmpty, "the document came apart into chapters")
    }

    /// An `.html` tab, through WebKit's own print — the page as it is drawn,
    /// not the source listing.
    @MainActor
    func testAPageExportsAsWebKitDrawsIt() throws {
        let directory = try makeTemporaryDirectory()
        let page = exampleURL("HTML.html")
        let note = Note(id: UUID(), fileURL: page, untitledName: nil,
                        text: try String(contentsOf: page, encoding: .utf8),
                        attributes: [:], assets: nil)
        let destination = directory.appendingPathComponent("page.pdf")

        try exportAndWait(note, to: .previewPDF, at: destination, context: context())

        let pdf = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertGreaterThanOrEqual(pdf.pageCount, 1)
        XCTAssertFalse((pdf.string ?? "").contains("<html"),
                       "the page as WebKit draws it, not the tags the editor shows")
    }

    /// A `.tex` with no engine on the Mac and a reader who answers "use
    /// Nota's render": what lands at TeX's own destination is the native
    /// render, and the export answers success rather than a refusal.
    @MainActor
    func testATeXFallsBackToTheNativeRenderWhenTheReaderAsksForIt() throws {
        let directory = try makeTemporaryDirectory()
        let note = try makeNote(
            named: "paper.tex",
            text: "\\section{Fallback}\n\nA paragraph under the section.\n",
            in: directory
        )
        let destination = directory.appendingPathComponent("paper.pdf")

        let presenter = FakeTeXPrompt(answer: .useNativeRender)
        Exporter.texInstallPresenter = { _ in presenter }
        Exporter.texSeams.findEngine = { nil }
        defer {
            Exporter.texInstallPresenter = { TeXInstallAlert(window: $0) }
            Exporter.texSeams = TeXExport.Seams()
        }

        try exportAndWait(note, to: .texPDF, at: destination, context: context())

        XCTAssertEqual(presenter.asked, 1, "the reader was asked once")
        let pdf = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertTrue((pdf.string ?? "").contains("Fallback"),
                      "Nota's own render of the document, at TeX's destination")
    }

    /// Cancelling the same question writes nothing and comes back as the one
    /// error the window stays silent about.
    @MainActor
    func testCancellingTheTeXQuestionWritesNothing() throws {
        let directory = try makeTemporaryDirectory()
        let note = try makeNote(named: "paper.tex", text: "\\section{Nope}", in: directory)
        let destination = directory.appendingPathComponent("paper.pdf")

        let presenter = FakeTeXPrompt(answer: .cancel)
        Exporter.texInstallPresenter = { _ in presenter }
        Exporter.texSeams.findEngine = { nil }
        defer {
            Exporter.texInstallPresenter = { TeXInstallAlert(window: $0) }
            Exporter.texSeams = TeXExport.Seams()
        }

        XCTAssertThrowsError(
            try exportAndWait(note, to: .texPDF, at: destination, context: context())
        ) { error in
            XCTAssertEqual(error as? TeXExportError, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Print

    /// Every kind that has a PDF in it prints; the two that only make a file
    /// rather than a page do not, and neither does an empty window.
    @MainActor
    func testPrintIsEnabledExactlyWhereTheTabMakesAPDF() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeController()
        XCTAssertTrue(controller.canPrintCurrentTab,
                      "an untitled tab prints its own listing, the way it exports one")

        let markdown = directory.appendingPathComponent("notes.md")
        try "# Printable\n".write(to: markdown, atomically: true, encoding: .utf8)
        controller.open(url: markdown)
        XCTAssertTrue(controller.canPrintCurrentTab)

        controller.open(url: exampleURL("Demo.pdf"))
        XCTAssertTrue(controller.canPrintCurrentTab, "a document prints itself")

        controller.open(url: exampleURL("Book.epub"))
        XCTAssertTrue(controller.canPrintCurrentTab, "a book prints its pages")

        let rows = directory.appendingPathComponent("rows.csv")
        try "a,b\n1,2\n".write(to: rows, atomically: true, encoding: .utf8)
        controller.open(url: rows)
        XCTAssertTrue(controller.canPrintCurrentTab,
                      "a grid's first target is still its render")
    }

    /// ⌥⌘P on a note: the PDF the tab's first export target would make, and
    /// the system dialog built over exactly those pages. The operation is
    /// taken at the seam, so no panel is ever raised.
    @MainActor
    func testPrintingANoteBuildsTheOperationOverTheRenderedPages() throws {
        let directory = try makeTemporaryDirectory()
        let source = directory.appendingPathComponent("long.md")
        let lines = (1...400).map { "Paragraph \($0) of a note long enough to need paper." }
        try lines.joined(separator: "\n\n").write(to: source, atomically: true, encoding: .utf8)

        let controller = try makeController()
        controller.open(url: source)

        // The same render, exported, to compare the print against.
        let expected = directory.appendingPathComponent("expected.pdf")
        let note = Note(id: UUID(), fileURL: source, untitledName: nil,
                        text: try String(contentsOf: source, encoding: .utf8),
                        attributes: [:], assets: nil)
        try exportAndWait(
            note, to: .previewPDF, at: expected,
            context: Exporter.Context(
                font: Preferences.shared.font(),
                paragraphStyle: Preferences.shared.paragraphStyle(),
                assets: nil,
                showsLineNumbers: Preferences.shared.showsLineNumbers,
                images: Preferences.shared.exportEditorImages
            )
        )
        let pages = try XCTUnwrap(PDFDocument(url: expected)).pageCount
        XCTAssertGreaterThan(pages, 1)

        var printed: PDFDocument?
        var operations = 0
        controller.printOperationRunner = { _, document in
            operations += 1
            printed = document
        }
        controller.printCurrentTab()

        XCTAssertEqual(operations, 1, "one dialog, and no panel of Nota's in front of it")
        XCTAssertEqual(printed?.pageCount, pages,
                       "the dialog is over the pages the export would have written")
    }

    /// A document tab prints its own pages — no temp file, no render.
    @MainActor
    func testPrintingADocumentPrintsTheDocumentItself() throws {
        let controller = try makeController()
        controller.open(url: exampleURL("Demo.pdf"))

        var printed: PDFDocument?
        controller.printOperationRunner = { _, document in printed = document }
        controller.printCurrentTab()

        let onDisk = try XCTUnwrap(PDFDocument(url: exampleURL("Demo.pdf")))
        XCTAssertEqual(printed?.pageCount, onDisk.pageCount)
    }

    // MARK: - Helpers

    /// The words a segmented control is wearing, left to right.
    @MainActor
    private func labels(of segments: NSSegmentedControl) -> [String] {
        (0..<segments.segmentCount).map { segments.label(forSegment: $0) ?? "" }
    }

    /// The export sheet as the window builds it, pointed at a folder of this
    /// test's own so nothing is ever composed onto a real one.
    @MainActor
    private func makeSheet(
        targets: [ExportTarget],
        images: ExportImagePlacement,
        names: [ExportTarget: String],
        in folder: URL
    ) -> ExportDialog {
        ExportDialog(
            targets: targets, images: images, suggestedNames: names,
            existingFileURL: nil, lastDirectory: folder
        )
    }


    /// `Exporter.export` answers through a completion whatever it is writing,
    /// so every test goes through here: the run loop is pumped while the
    /// export works — which is what WebKit needs and a semaphore would take
    /// away — and a failure comes back as a `throw`, the way the tests that
    /// were written against the old synchronous seam read.
    @MainActor
    private func exportAndWait(
        _ note: Note, to target: ExportTarget, at url: URL,
        context: Exporter.Context, timeout: TimeInterval = 60
    ) throws {
        let finished = expectation(description: "export finished")
        var outcome: Result<Void, Error>?
        Exporter.export(note, to: target, at: url, context: context) { result in
            outcome = result
            finished.fulfill()
        }
        wait(for: [finished], timeout: timeout)
        try XCTUnwrap(outcome, "the export never answered").get()
    }

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

/// The install question, answered without an alert.
private final class FakeTeXPrompt: TeXInstallPrompting {
    private let answer: TeXInstallChoice
    private(set) var asked = 0

    init(answer: TeXInstallChoice) { self.answer = answer }

    func promptForTeXInstall() -> TeXInstallChoice {
        asked += 1
        return answer
    }
}
