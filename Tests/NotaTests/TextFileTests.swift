import AppKit
import Foundation
import XCTest
@testable import Nota

/// Opening and saving text of any kind: the encoding and line endings a file
/// arrives in, the shape it goes back in, and what counts as text at all.
final class TextFileTests: AppKitTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    // MARK: - Encoding detection

    func testPlainUTF8IsReadAsUTF8WithNoMark() throws {
        let decoded = try XCTUnwrap(TextFile.decode(Data("héllo wörld".utf8)))
        XCTAssertEqual(decoded.text, "héllo wörld")
        XCTAssertEqual(decoded.format.encoding, .utf8)
        XCTAssertFalse(decoded.format.hadBOM)
        XCTAssertEqual(decoded.format.lineEnding, .lf)
    }

    func testUTF8ByteOrderMarkIsRememberedAndStrippedFromTheText() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("notes".utf8)
        let decoded = try XCTUnwrap(TextFile.decode(data))
        // The mark is a property of the file, not a character in the note.
        XCTAssertEqual(decoded.text, "notes")
        XCTAssertEqual(decoded.format.encoding, .utf8)
        XCTAssertTrue(decoded.format.hadBOM)
    }

    func testUTF16LittleEndianIsFoundByItsMark() throws {
        let data = Data([0xFF, 0xFE]) + "hi\nthere".data(using: .utf16LittleEndian)!
        let decoded = try XCTUnwrap(TextFile.decode(data))
        XCTAssertEqual(decoded.text, "hi\nthere")
        XCTAssertEqual(decoded.format.encoding, .utf16LittleEndian)
        XCTAssertTrue(decoded.format.hadBOM)
    }

    func testUTF16BigEndianIsFoundByItsMark() throws {
        let data = Data([0xFE, 0xFF]) + "hi\nthere".data(using: .utf16BigEndian)!
        let decoded = try XCTUnwrap(TextFile.decode(data))
        XCTAssertEqual(decoded.text, "hi\nthere")
        XCTAssertEqual(decoded.format.encoding, .utf16BigEndian)
        XCTAssertTrue(decoded.format.hadBOM)
    }

    func testHighBytesThatAreNotUTF8FallBackToAnEightBitEncoding() throws {
        // `café` written by a Windows editor: 0xE9 is é there and invalid
        // UTF-8 here, so the fallback is what reads it.
        let data = Data([0x63, 0x61, 0x66, 0xE9])
        let decoded = try XCTUnwrap(TextFile.decode(data))
        XCTAssertEqual(decoded.text, "café")
        XCTAssertNotEqual(decoded.format.encoding, .utf8)
        // Whatever the fallback settled on has to write the same bytes back.
        XCTAssertEqual(TextFile.encode(decoded.text, format: decoded.format).data, data)
    }

    func testEveryByteIsReadableByOneOfTheFallbacks() {
        // Latin-1 can never fail, so no run of NUL-free bytes is ever refused.
        let data = Data((1...255).map { UInt8($0) })
        XCTAssertNotNil(TextFile.decode(data))
    }

    func testAnEmptyFileIsTextAndOpensAsAnEmptyNote() throws {
        let decoded = try XCTUnwrap(TextFile.decode(Data()))
        XCTAssertEqual(decoded.text, "")
        XCTAssertEqual(decoded.format, .default)
    }

    // MARK: - Binaries

    func testNulBytesMeanBinaryAndAreRefused() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x00, 0x00, 0x01])
        XCTAssertTrue(TextFile.isBinary(png))
        XCTAssertNil(TextFile.decode(png))
    }

    func testOnlyTheFirstEightKilobytesDecideBinary() {
        // A log with a stray NUL a long way in is still a log.
        let late = Data(repeating: 0x41, count: TextFile.sniffLength + 16) + Data([0x00])
        XCTAssertFalse(TextFile.isBinary(late))
        XCTAssertNotNil(TextFile.decode(late))
    }

    func testUTF16IsNotMistakenForBinaryDespiteItsNulBytes() {
        let data = Data([0xFF, 0xFE]) + "abc".data(using: .utf16LittleEndian)!
        XCTAssertTrue(TextFile.isBinary(data), "the bytes really do contain NULs")
        XCTAssertNotNil(TextFile.decode(data), "but the mark is asked first")
    }

    // MARK: - Line endings

    func testLineEndingIsDecidedByMajority() {
        XCTAssertEqual(TextFile.lineEnding(of: "a\r\nb\r\nc\nd"), .crlf)
        XCTAssertEqual(TextFile.lineEnding(of: "a\nb\nc\r\nd"), .lf)
        XCTAssertEqual(TextFile.lineEnding(of: "a\r\nb"), .crlf)
        // No breaks at all is LF, the same as a brand new note.
        XCTAssertEqual(TextFile.lineEnding(of: "one line"), .lf)
        XCTAssertEqual(TextFile.lineEnding(of: ""), .lf)
    }

    func testTheStorageOnlyEverHoldsLineFeeds() throws {
        let decoded = try XCTUnwrap(TextFile.decode(Data("a\r\nb\r\nc".utf8)))
        XCTAssertEqual(decoded.text, "a\nb\nc")
        XCTAssertEqual(decoded.format.lineEnding, .crlf)
        // A lone CR is a line break too, not a character left in the text.
        XCTAssertEqual(TextFile.normalized("a\rb\r\nc"), "a\nb\nc")
        XCTAssertEqual(TextFile.normalized("nothing to do"), "nothing to do")
    }

    // MARK: - Writing

    func testCRLFIsPutBackOnSave() {
        let format = TextFileFormat(encoding: .utf8, hadBOM: false, lineEnding: .crlf)
        let written = TextFile.encode("a\nb\nc", format: format)
        XCTAssertEqual(String(data: written.data, encoding: .utf8), "a\r\nb\r\nc")
        XCTAssertEqual(written.format, format)
    }

    func testLineFeedsAreLeftAloneForAnLFFile() {
        let written = TextFile.encode("a\nb", format: .default)
        XCTAssertEqual(written.data, Data("a\nb".utf8))
    }

    func testTheByteOrderMarkComesBack() {
        let utf8 = TextFileFormat(encoding: .utf8, hadBOM: true, lineEnding: .lf)
        XCTAssertEqual(TextFile.encode("x", format: utf8).data, Data([0xEF, 0xBB, 0xBF, 0x78]))

        let utf16 = TextFileFormat(encoding: .utf16LittleEndian, hadBOM: true, lineEnding: .lf)
        XCTAssertEqual(
            TextFile.encode("x", format: utf16).data,
            Data([0xFF, 0xFE]) + "x".data(using: .utf16LittleEndian)!
        )
    }

    func testAFileWithNoMarkNeverGrowsOne() {
        let format = TextFileFormat(encoding: .utf8, hadBOM: false, lineEnding: .lf)
        XCTAssertEqual(TextFile.encode("x", format: format).data, Data("x".utf8))
    }

    func testTextThatOutgrowsItsEncodingIsWidenedToUTF8RatherThanLost() {
        let latin1 = TextFileFormat(encoding: .isoLatin1, hadBOM: false, lineEnding: .crlf)
        let written = TextFile.encode("rocket 🚀\nhere", format: latin1)
        XCTAssertEqual(written.format.encoding, .utf8)
        XCTAssertFalse(written.format.hadBOM)
        // The line endings are still the file's own; only the encoding moved.
        XCTAssertEqual(written.format.lineEnding, .crlf)
        XCTAssertEqual(String(data: written.data, encoding: .utf8), "rocket 🚀\r\nhere")
    }

    func testAFileGoesBackToDiskExactlyAsItCame() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("windows.txt")
        // Latin-1 text with CRLF endings, byte for byte.
        let original = Data([0x63, 0x61, 0x66, 0xE9, 0x0D, 0x0A, 0x62, 0x61, 0x72])
        try original.write(to: url)

        let opened = try XCTUnwrap(TextFile.read(at: url))
        XCTAssertEqual(opened.text, "café\nbar")
        XCTAssertEqual(opened.format.lineEnding, .crlf)
        XCTAssertEqual(TextFile.encode(opened.text, format: opened.format).data, original)
    }

    func testReadingSomethingThatIsNotThereIsNil() throws {
        let directory = try makeTemporaryDirectory()
        XCTAssertNil(TextFile.read(at: directory.appendingPathComponent("nope.txt")))
    }

    // MARK: - The footer's menu (Todo 2)

    func testTheFooterCallsEachEncodingWhatTodo2CallsIt() {
        XCTAssertEqual(TextFileFormat.displayName(for: .utf8), "UTF-8")
        XCTAssertEqual(TextFileFormat.displayName(for: .utf16LittleEndian), "UTF-16")
        XCTAssertEqual(TextFileFormat.displayName(for: .utf16BigEndian), "UTF-16",
                       "one menu item for either byte order")
        XCTAssertEqual(TextFileFormat.displayName(for: .isoLatin1), "Latin-1")
        XCTAssertEqual(TextFileFormat.displayName(for: .windowsCP1252), "Windows-1252")
        XCTAssertEqual(TextFileFormat.selectableEncodings.map(TextFileFormat.displayName),
                       ["UTF-8", "UTF-16", "Latin-1", "Windows-1252"])
    }

    func testCanRepresentRefusesWhatAnEncodingCannotHold() {
        // An é is Latin-1 and Windows-1252 both; an emoji is neither.
        XCTAssertTrue(TextFile.canRepresent("café", in: .isoLatin1))
        XCTAssertTrue(TextFile.canRepresent("café", in: .windowsCP1252))
        XCTAssertFalse(TextFile.canRepresent("rocket 🚀", in: .isoLatin1))
        XCTAssertFalse(TextFile.canRepresent("rocket 🚀", in: .windowsCP1252))
        // UTF-8 and UTF-16 hold anything Unicode does.
        XCTAssertTrue(TextFile.canRepresent("rocket 🚀", in: .utf8))
        XCTAssertTrue(TextFile.canRepresent("rocket 🚀", in: .utf16LittleEndian))
    }

    func testLineEndingDisplayNames() {
        XCTAssertEqual(LineEnding.lf.displayName, "LF")
        XCTAssertEqual(LineEnding.crlf.displayName, "CRLF")
    }

    // MARK: - What counts as text

    func testTypesTheSystemKnowsAnswerForThemselves() throws {
        let directory = try makeTemporaryDirectory()
        for name in ["notes.md", "app.swift", "page.html", "data.json", "styles.css"] {
            let url = directory.appendingPathComponent(name)
            try Data("x = 1".utf8).write(to: url)
            XCTAssertTrue(TextFile.isTextFile(at: url), "\(name) is text")
        }
    }

    func testTypesWithNoUTIAtAllAreDecidedByTheirBytes() throws {
        let directory = try makeTemporaryDirectory()
        for name in ["Cargo.toml", ".env", "app.properties", "README"] {
            let url = directory.appendingPathComponent(name)
            try Data("key = value\n".utf8).write(to: url)
            XCTAssertTrue(TextFile.isTextFile(at: url), "\(name) is text")
        }
    }

    func testBinariesAndImagesAreNotOpenedAsNotes() throws {
        let directory = try makeTemporaryDirectory()
        let image = directory.appendingPathComponent("photo.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00]).write(to: image)
        XCTAssertFalse(TextFile.isTextFile(at: image))

        // No extension to go on, so the bytes are what refuse it.
        let blob = directory.appendingPathComponent("payload")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: blob)
        XCTAssertFalse(TextFile.isTextFile(at: blob))

        // SPEC rules rich text out even though it is technically characters.
        let rich = directory.appendingPathComponent("letter.rtf")
        try Data("{\\rtf1}".utf8).write(to: rich)
        XCTAssertFalse(TextFile.isTextFile(at: rich))

        XCTAssertFalse(TextFile.isTextFile(at: directory), "a folder is not a note")
    }

    func testTheSavePanelOffersMarkdownFirstAndPlainTextAmongTheRest() {
        let types = TextFile.contentTypes
        XCTAssertEqual(types.first?.preferredFilenameExtension, "md")
        XCTAssertTrue(types.contains(.plainText))
        XCTAssertTrue(types.contains(.sourceCode))
    }

    // MARK: - Names

    func testTheSavePanelKeepsANamedFilesOwnExtension() {
        let script = URL(fileURLWithPath: "/tmp/build/app.js")
        XCTAssertEqual(SuggestedName.panelName(for: script, text: "console.log(1)"), "app.js")
        let dotted = URL(fileURLWithPath: "/tmp/site/.gitignore")
        XCTAssertEqual(SuggestedName.panelName(for: dotted, text: "build/"), ".gitignore")
    }

    func testANewNoteIsProposedAsMarkdown() {
        XCTAssertEqual(SuggestedName.panelName(for: nil, text: "Grocery list\nmilk"),
                       "Grocery list.md")
        XCTAssertEqual(SuggestedName.panelName(for: nil, text: ""), "Untitled.md")
    }

    func testATabIsNamedAfterTheWholeFileName() {
        let note = Note(
            fileURL: URL(fileURLWithPath: "/tmp/app.js"), untitledName: nil, text: "",
            attributes: [:], assets: nil
        )
        XCTAssertEqual(note.title, "app.js")
        let untitled = Note(fileURL: nil, untitledName: "Untitled 2", text: "",
                            attributes: [:], assets: nil)
        XCTAssertEqual(untitled.title, "Untitled 2")
    }

    // MARK: - Persistence

    func testTheFileFormatSurvivesARelaunch() throws {
        let directory = try makeTemporaryDirectory()
        let format = TextFileFormat(
            encoding: .windowsCP1252, hadBOM: false, lineEnding: .crlf
        )
        let state = SessionState(
            tabs: [SessionTab(id: UUID(), path: "/tmp/windows.txt", untitledName: nil,
                              isDirty: false, selection: 0, format: format)],
            selectedTabID: nil,
            fontSize: 13
        )
        let store = SessionStore(directory: directory)
        store.save(state)
        XCTAssertEqual(SessionStore(directory: directory).load(), state)
    }

    func testAnUntitledNoteKeepsNoFormatOfItsOwn() {
        let untitled = Note(fileURL: nil, untitledName: "Untitled", text: "",
                            attributes: [:], assets: nil)
        untitled.format = TextFileFormat(encoding: .isoLatin1, hadBOM: true, lineEnding: .crlf)
        XCTAssertNil(untitled.sessionTab().format)

        let named = Note(fileURL: URL(fileURLWithPath: "/tmp/a.txt"), untitledName: nil,
                         text: "", attributes: [:], assets: nil)
        named.format = TextFileFormat(encoding: .isoLatin1, hadBOM: true, lineEnding: .crlf)
        XCTAssertEqual(named.sessionTab().format, named.format)
    }

    func testASessionWrittenBeforeNotaKnewAboutFormatsStillLoads() throws {
        let json = """
        {"fontSize":13,"tabs":[{"id":"\(UUID().uuidString)","isDirty":false,\
        "path":"/tmp/old.txt","selection":0}]}
        """
        let state = try JSONDecoder().decode(SessionState.self, from: Data(json.utf8))
        XCTAssertNil(state.tabs[0].format)
    }

    // MARK: - Document types

    func testInfoPlistRegistersNotaAsAnEditorForTextAndSource() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // NotaTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // the project
            .appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: plist)
        let root = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )
        // The bundle identity the defaults migration keys off.
        XCTAssertEqual(root["CFBundleName"] as? String, "Nota")
        XCTAssertEqual(root["CFBundleDisplayName"] as? String, "Nota")
        XCTAssertEqual(root["CFBundleExecutable"] as? String, "Nota")
        XCTAssertEqual(root["CFBundleIconFile"] as? String, "Nota")
        XCTAssertEqual(root["CFBundleIdentifier"] as? String, "com.manfad.nota")
        XCTAssertNotEqual(
            root["CFBundleIdentifier"] as? String, Preferences.legacyDefaultsDomain
        )

        let types = try XCTUnwrap(root["CFBundleDocumentTypes"] as? [[String: Any]])

        let identifiers = types.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
        for uti in ["public.plain-text", "public.text", "public.source-code",
                    "net.daringfireball.markdown", "public.json", "public.xml"] {
            XCTAssertTrue(identifiers.contains(uti), "\(uti) should be declared")
        }

        // The types the system has no UTI for can only be named by extension.
        let extensions = types.flatMap { $0["CFBundleTypeExtensions"] as? [String] ?? [] }
        for name in ["toml", "env", "tsx", "gitignore"] {
            XCTAssertTrue(extensions.contains(name), "\(name) should be declared")
        }

        // The one binary, and it is declared for what it is: Nota views a
        // PDF, it never edits one.
        let pdfType = try XCTUnwrap(types.first {
            ($0["LSItemContentTypes"] as? [String])?.contains("com.adobe.pdf") == true
        })
        XCTAssertEqual(pdfType["CFBundleTypeRole"] as? String, "Viewer")

        // An editor for text, a viewer for the PDF, and never the default one
        // for anybody else's file type.
        for type in types {
            let isPDF = (type["LSItemContentTypes"] as? [String])?
                .contains("com.adobe.pdf") == true
            XCTAssertEqual(type["CFBundleTypeRole"] as? String,
                           isPDF ? "Viewer" : "Editor")
            XCTAssertEqual(type["LSHandlerRank"] as? String, "Alternate")
        }
    }

    // MARK: - Drops

    func testOnlyTextFilesInADropAreOpenedAsTabs() throws {
        let directory = try makeTemporaryDirectory()
        let note = directory.appendingPathComponent("notes.md")
        let config = directory.appendingPathComponent("Cargo.toml")
        let image = directory.appendingPathComponent("photo.png")
        let blob = directory.appendingPathComponent("blob.bin")
        try Data("# hi".utf8).write(to: note)
        try Data("[package]".utf8).write(to: config)
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00]).write(to: image)
        try Data([0x00, 0x01]).write(to: blob)

        let pasteboard = NSPasteboard(name: .init("NotaTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([note, config, image, blob].map { $0 as NSURL })

        // Several files at once means several tabs; the image stays the
        // asset store's business and the binary is nobody's.
        XCTAssertEqual(
            NotaTextView.openableFiles(on: pasteboard).map(\.lastPathComponent),
            ["notes.md", "Cargo.toml"]
        )
    }

    func testADropWithNoFilesInItOpensNothing() {
        let pasteboard = NSPasteboard(name: .init("NotaTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("just some text", forType: .string)
        XCTAssertTrue(NotaTextView.openableFiles(on: pasteboard).isEmpty)
    }

    // MARK: - Through the window

    @MainActor
    func testOpeningAWindowsFileKeepsItsNameEncodingAndLineEndings() throws {
        _ = NSApplication.shared
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("readme.rst")
        let original = Data([0x63, 0x61, 0x66, 0xE9, 0x0D, 0x0A, 0x62, 0x61, 0x72])
        try original.write(to: url)

        let controller = MainWindowController(store: SessionStore(directory: try makeTemporaryDirectory()))
        controller.open(url: url)

        let opened = try XCTUnwrap(controller.openNotes.first { $0.fileURL == url })
        XCTAssertEqual(opened.title, "readme.rst", "the extension belongs in the tab")
        XCTAssertEqual(opened.text, "café\nbar", "the storage only holds LF")
        XCTAssertEqual(opened.format.lineEnding, .crlf)
        XCTAssertNotEqual(opened.format.encoding, .utf8)
    }

    @MainActor
    func testSavingAnOpenedFileWritesTheSameBytesBack() throws {
        _ = NSApplication.shared
        let previous = Preferences.shared.lastSaveDirectory
        defer { Preferences.shared.lastSaveDirectory = previous }

        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("script.js")
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("let a = 1;\r\nlet b = 2;".utf8)
        try original.write(to: url)

        let controller = MainWindowController(store: SessionStore(directory: try makeTemporaryDirectory()))
        controller.open(url: url)
        controller.saveCurrent(forcePanel: false)

        // Mark, encoding and CRLF all still there, and the name untouched.
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(controller.openNotes.last?.title, "script.js")
    }

    @MainActor
    func testVimWriteKeepsWhateverExtensionWasTyped() throws {
        _ = NSApplication.shared
        let previous = Preferences.shared.lastSaveDirectory
        defer { Preferences.shared.lastSaveDirectory = previous }

        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("app.js")
        try Data("let a = 1;\n".utf8).write(to: url)

        let controller = MainWindowController(store: SessionStore(directory: try makeTemporaryDirectory()))
        controller.open(url: url)
        // Saving once teaches the panel — and `:w name` — where we are.
        controller.saveCurrent(forcePanel: false)
        XCTAssertTrue(controller.vimSave(name: "app.jsx"))

        let renamed = directory.appendingPathComponent("app.jsx")
        XCTAssertEqual(try Data(contentsOf: renamed), Data("let a = 1;\n".utf8))
        XCTAssertEqual(controller.openNotes.last?.title, "app.jsx",
                       ":w name never appends .md to it")
    }

    @MainActor
    func testAFileThatIsNotTextIsNeverOpenedInATab() throws {
        _ = NSApplication.shared
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("archive.bin")
        try Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00]).write(to: url)

        // The refusal itself is an alert, so what is checked here is the
        // decision behind it: nothing about this file can be opened.
        XCTAssertNil(TextFile.read(at: url))
        XCTAssertFalse(TextFile.isTextFile(at: url))
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
