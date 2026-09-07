import AppKit
import Foundation
import PDFKit
import XCTest
@testable import Nota

/// Content-first file detection: what a file *is* comes from its bytes, and
/// its name is only asked when the bytes cannot say. A `report` with no
/// extension, a PDF named `notes`, and a `.pdf` that is really a log all
/// have to land the way their content says, not the way their name guesses.
final class FileSniffTests: AppKitTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    // MARK: - Classifying

    func testARealPDFIsKnownByItsMagicBytesWhateverItIsNamed() throws {
        let directory = try makeTemporaryDirectory()
        let url = try makePDF(pages: 1, named: "report", in: directory)
        XCTAssertEqual(FileSniff.classify(at: url), .pdf)
    }

    func testUTF8TextWithNoExtensionIsText() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("report")
        try Data("just some notes".utf8).write(to: url)
        XCTAssertEqual(FileSniff.classify(at: url), .text)
    }

    func testLatin1TextNamedNotesIsText() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("notes")
        // 0xE9 is `é` in Latin-1 and invalid on its own as UTF-8.
        try Data([0x63, 0x61, 0x66, 0xE9]).write(to: url)
        XCTAssertEqual(FileSniff.classify(at: url), .text)
    }

    /// A book is a zip, and what tells it from every other zip is the entry
    /// at the front of the file: a stored `mimetype` reading
    /// `application/epub+zip` (SPEC Todo 3).
    func testABookIsKnownByItsFirstEntryAndAPlainZipIsNot() throws {
        let directory = try makeTemporaryDirectory()
        let staging = try makeTemporaryDirectory()
        try Data("just some notes".utf8).write(to: staging.appendingPathComponent("notes.txt"))

        let book = directory.appendingPathComponent("novel.epub")
        try Data("application/epub+zip".utf8)
            .write(to: staging.appendingPathComponent("mimetype"))
        try zip(["-X", "-0", book.path, "mimetype"], in: staging)
        try zip(["-X", "-r", book.path, "notes.txt"], in: staging)

        let archive = directory.appendingPathComponent("bundle.zip")
        try zip(["-X", "-r", archive.path, "notes.txt"], in: staging)

        XCTAssertEqual(FileSniff.classify(at: book), .epub)
        XCTAssertNotEqual(FileSniff.classify(at: archive), .epub,
                          "an archive with no mimetype entry is only an archive")
        XCTAssertTrue(Note.isOpenable(book))
        XCTAssertFalse(Note.isOpenable(archive))
    }

    private func zip(_ arguments: [String], in directory: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        task.arguments = arguments
        task.currentDirectoryURL = directory
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)
    }

    func testBytesWithANULAreBinary() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("blob")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: url)
        XCTAssertEqual(FileSniff.classify(at: url), .binary)
    }

    func testADirectoryIsUnreadable() throws {
        let directory = try makeTemporaryDirectory()
        XCTAssertEqual(FileSniff.classify(at: directory), .unreadable)
    }

    func testAMissingFileIsUnreadable() throws {
        let directory = try makeTemporaryDirectory()
        XCTAssertEqual(
            FileSniff.classify(at: directory.appendingPathComponent("nope")), .unreadable
        )
    }

    // MARK: - Through the window

    @MainActor
    func testAPDFNamedReportOpensAsAPDFTab() throws {
        let controller = try makeController(store: try makeStore())
        let pdf = try makePDF(pages: 2, named: "report", in: try makeTemporaryDirectory())

        controller.open(url: pdf)

        XCTAssertEqual(controller.currentTabState.kind, .pdf)
        XCTAssertEqual(controller.previewState.mode, .reading)
        XCTAssertTrue(controller.previewPanes.showsPDF)
        XCTAssertEqual(controller.previewPanes.pdf.pageCount, 2)
    }

    @MainActor
    func testATextFileNamedREADMEOpensAsATextTab() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("README")
        try Data("what this is about".utf8).write(to: url)
        let controller = try makeController(store: try makeStore())

        controller.open(url: url)

        XCTAssertEqual(controller.currentTabState.kind, .text)
        let opened = try XCTUnwrap(controller.openNotes.first { $0.fileURL == url })
        XCTAssertEqual(opened.text, "what this is about")
    }

    @MainActor
    func testATextFileNamedFakeDotPDFOpensAsATextTab() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("fake.pdf")
        try Data("this is not really a PDF".utf8).write(to: url)
        let controller = try makeController(store: try makeStore())

        controller.open(url: url)

        XCTAssertEqual(controller.currentTabState.kind, .text)
        XCTAssertFalse(controller.previewPanes.showsPDF)
        let opened = try XCTUnwrap(controller.openNotes.first { $0.fileURL == url })
        XCTAssertEqual(opened.text, "this is not really a PDF")
    }

    // `presentFailure` runs `NSAlert.runModal`, which hangs a test, so a
    // NUL-bearing file's refusal is tested at the classifier level only —
    // the same way the existing "not a text file" tests do.
    func testANULBearingFileIsNotSomethingTheWindowWouldOpenAsText() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("blob.txt")
        try Data([0x00, 0x01, 0x02]).write(to: url)
        XCTAssertEqual(FileSniff.classify(at: url), .binary)
        XCTAssertFalse(Note.isPDFFile(url), "nothing about the name says PDF either")
    }

    // MARK: - Drop filter

    /// `.ts` is a TypeScript module to a programmer and an MPEG-2 transport
    /// stream to the system. The bytes settle it: text opens, however the
    /// name is filed.
    func testATypeScriptModuleOpensDespiteTheSystemCallingItVideo() throws {
        let directory = try makeTemporaryDirectory()
        for name in ["index.ts", "vite.config.ts", "worker.mts", "types.cts"] {
            let url = directory.appendingPathComponent(name)
            try "export const answer: number = 42\n".write(to: url, atomically: true, encoding: .utf8)
            XCTAssertTrue(Note.isOpenable(url), "\(name) is text, whatever its extension claims")
            XCTAssertFalse(TextFile.isDeliberatelyExcluded(url), name)
        }
        // A `.ts` that is not there to be read keeps the system's word for it.
        XCTAssertFalse(Note.isOpenable(directory.appendingPathComponent("missing.ts")))
    }

    func testAPDFNamedReportAndATextFileNamedConfigAreBothOpenable() throws {
        let directory = try makeTemporaryDirectory()
        let pdf = try makePDF(pages: 1, named: "report", in: directory)
        let config = directory.appendingPathComponent("config")
        try Data("key = value".utf8).write(to: config)
        let image = directory.appendingPathComponent("photo.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00]).write(to: image)

        let pasteboard = NSPasteboard(name: .init("NotaFileSniffTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([pdf, config, image].map { $0 as NSURL })

        XCTAssertEqual(
            NotaTextView.openableFiles(on: pasteboard).map(\.lastPathComponent),
            ["report", "config"]
        )
    }

    /// The drop filter is not `Note.isOpenable`, and a picture is where the
    /// two part company: it opens in a tab of its own through Open…, the
    /// Finder and the command line, and it lands in the note as a chip when
    /// it is dropped into the text. The target decides, not the file.
    func testAPictureOpensAsATabButIsStillTheStoresWhenDroppedInTheText() throws {
        let directory = try makeTemporaryDirectory()
        let pdf = try makePDF(pages: 1, named: "report", in: directory)
        let config = directory.appendingPathComponent("config")
        try Data("key = value".utf8).write(to: config)
        let image = directory.appendingPathComponent("photo.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00]).write(to: image)

        XCTAssertTrue(Note.isOpenable(pdf))
        XCTAssertTrue(Note.isOpenable(config))
        XCTAssertTrue(Note.isOpenable(image))

        let pasteboard = NSPasteboard(name: .init("NotaSniffTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([pdf, config, image].map { $0 as NSURL })
        XCTAssertEqual(
            NotaTextView.openableFiles(on: pasteboard).map(\.lastPathComponent),
            ["report", "config"]
        )
    }

    // MARK: - Restoring a session

    @MainActor
    func testASessionTabNamedReportThatIsAPDFComesBackAsAPDFTab() throws {
        let directory = try makeTemporaryDirectory()
        let store = try makeStore()
        let pdf = try makePDF(pages: 3, named: "report", in: directory)

        let opened = try makeController(store: store)
        opened.open(url: pdf)
        opened.flushAll()

        let relaunched = try makeController(store: SessionStore(directory: store.directory))
        let index = try XCTUnwrap(relaunched.openNotes.firstIndex {
            $0.fileURL?.standardizedFileURL == pdf.standardizedFileURL
        })
        relaunched.selectTab(at: index)

        XCTAssertEqual(relaunched.currentTabState.kind, .pdf)
        XCTAssertEqual(relaunched.previewPanes.pdf.pageCount, 3)
    }

    // MARK: - Helpers

    @MainActor
    private func makeController(store: SessionStore) throws -> MainWindowController {
        _ = NSApplication.shared
        let controller = MainWindowController(store: store)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1000, height: 560))
        window.layoutIfNeeded()
        return controller
    }

    private func makeStore() throws -> SessionStore {
        SessionStore(directory: try makeTemporaryDirectory())
    }

    /// A real PDF, made by PDFKit rather than checked in: a few blank pages
    /// of a believable size, written to a file the way any other one is.
    private func makePDF(pages: Int, named name: String, in directory: URL) throws -> URL {
        let document = PDFDocument()
        for index in 0 ..< pages {
            let page = PDFPage()
            page.setBounds(NSRect(x: 0, y: 0, width: 300, height: 400), for: .mediaBox)
            document.insert(page, at: index)
        }
        let url = directory.appendingPathComponent(name)
        XCTAssertTrue(document.write(to: url), "the fixture has to be a real PDF")
        return url
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotaFileSniffTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
