import AppKit
import XCTest
@testable import Nota

/// A note with pictures in it should be readable by anything, not only by
/// Nota. Saving one under a name writes its pictures into `<basename>.assets/`
/// beside the file and spells them as ordinary relative Markdown links;
/// opening a file reads relative links back as chips, remembering where their
/// author put them so the next save leaves them there.
final class SidecarTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func setUp() {
        super.setUp()
        Preferences.shared.hidesTabBar = false
    }

    override func tearDownWithError() throws {
        Preferences.shared.hidesTabBar = false
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    // MARK: - Saving

    @MainActor
    func testSavingANoteWithChipsWritesTheirPicturesBesideTheFile() throws {
        let notes = try makeTemporaryDirectory()
        let controller = try makeController()
        let first = try write(pngData(width: 20, height: 10), named: "one.png", in: notes)
        let second = try write(pngData(width: 8, height: 30), named: "two.png", in: notes)
        try drop([first, second], on: controller)

        let destination = notes.appendingPathComponent("notes.md")
        controller.savePanelProvider = { _ in destination }
        controller.saveCurrent(forcePanel: false)

        let text = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertFalse(text.contains("nota://"), "the file carries no scheme of Nota's own")
        XCTAssertEqual(occurrences(of: "](notes.assets/", in: text), 2)

        let folder = notes.appendingPathComponent("notes.assets")
        let written = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(written.count, 2)
        // Byte for byte what was dropped: a PNG is kept as it came in.
        let bytes = Set(try written.map { try Data(contentsOf: folder.appendingPathComponent($0)) })
        XCTAssertEqual(bytes, Set([try Data(contentsOf: first), try Data(contentsOf: second)]))
    }

    /// The folder name goes through the link as a path, so a note whose name
    /// has a space in it is still linked in a way every reader can follow.
    @MainActor
    func testAFolderNameWithASpaceIsPercentEncodedInTheLink() throws {
        let notes = try makeTemporaryDirectory()
        let controller = try makeController()
        try drop([try write(pngData(width: 6, height: 6), named: "p.png", in: notes)],
                 on: controller)

        let destination = notes.appendingPathComponent("my notes.md")
        controller.savePanelProvider = { _ in destination }
        controller.saveCurrent(forcePanel: false)

        let text = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(text.contains("](my%20notes.assets/"), text)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: notes.appendingPathComponent("my notes.assets").path
        ))
    }

    /// An untitled note has nowhere to put a sidecar: it keeps writing tokens
    /// into the cache, which stays the truth until ⌘S.
    @MainActor
    func testAnUntitledNoteStillWritesTokensToTheCache() throws {
        let notes = try makeTemporaryDirectory()
        let support = try makeTemporaryDirectory()
        let controller = try makeController(support: support)
        try drop([try write(pngData(width: 12, height: 12), named: "p.png", in: notes)],
                 on: controller)
        controller.flushAll()

        let cache = support.appendingPathComponent("cache")
        let cached = try FileManager.default.contentsOfDirectory(at: cache,
                                                                 includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "txt" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
        XCTAssertTrue(cached.contains { $0.contains("nota://") },
                      "the cache keeps Nota's own tokens")
        XCTAssertTrue(cached.allSatisfy { !$0.contains(".assets/") })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: notes.appendingPathComponent("Untitled.assets").path
        ))
    }

    /// A file written by an older version says `nota://`; it reads as it
    /// always did, and the next save brings it up to date.
    @MainActor
    func testALegacyTokenInANamedFileBecomesASidecarLinkOnSave() throws {
        let notes = try makeTemporaryDirectory()
        let support = try makeTemporaryDirectory()
        let store = SessionStore(directory: support)
        let assetID = try XCTUnwrap(
            store.assets.importImageData(try pngData(width: 9, height: 9),
                                         preferredExtension: "png")
        )
        let file = notes.appendingPathComponent("legacy.md")
        try Data("before ![](nota://\(assetID)) after".utf8).write(to: file)

        let controller = try makeController(store: store)
        controller.open(url: file)
        controller.saveCurrent(forcePanel: false)

        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(text, "before ![](legacy.assets/\(assetID)) after")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: notes.appendingPathComponent("legacy.assets/\(assetID)").path
        ))
    }

    // MARK: - Opening

    @MainActor
    func testReopeningASavedNoteBringsTheChipsBackAndSavesTheSameLinks() throws {
        let notes = try makeTemporaryDirectory()
        let destination = notes.appendingPathComponent("notes.md")
        let saver = try makeController()
        try drop([try write(pngData(width: 20, height: 10), named: "one.png", in: notes),
                  try write(pngData(width: 8, height: 30), named: "two.png", in: notes)],
                 on: saver)
        saver.savePanelProvider = { _ in destination }
        saver.saveCurrent(forcePanel: false)
        let saved = try String(contentsOf: destination, encoding: .utf8)

        // A fresh window with a store of its own: the pictures come in from
        // the sidecar rather than from any asset the first window made.
        let reader = try makeController()
        reader.open(url: destination)
        let opened = try XCTUnwrap(reader.openNotes.first { $0.fileURL == destination })
        XCTAssertEqual(occurrences(of: "nota://", in: opened.text), 2,
                       "both relative links came back as chips")
        XCTAssertFalse(opened.text.contains("notes.assets/"))

        reader.saveCurrent(forcePanel: false)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), saved,
                       "the same links go back, unmoved")
        let folder = notes.appendingPathComponent("notes.assets")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2,
            "and no second copy of either picture"
        )
    }

    /// Any relative folder, not only the sidecar: a Markdown file written
    /// somewhere else shows its pictures here for the first time, and they
    /// stay where their author put them.
    @MainActor
    func testAnOrdinaryRelativeLinkOpensAsAChipAndIsWrittenBackUnchanged() throws {
        let notes = try makeTemporaryDirectory()
        let pictures = notes.appendingPathComponent("pics")
        try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        _ = try write(pngData(width: 14, height: 7), named: "a.png", in: pictures)
        let file = notes.appendingPathComponent("doc.md")
        try Data("# title\n\n![](pics/a.png)\n\nend\n".utf8).write(to: file)

        let controller = try makeController()
        controller.open(url: file)
        let opened = try XCTUnwrap(controller.openNotes.first { $0.fileURL == file })
        XCTAssertEqual(occurrences(of: "nota://", in: opened.text), 1)

        controller.saveCurrent(forcePanel: false)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8),
                       "# title\n\n![](pics/a.png)\n\nend\n")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: notes.appendingPathComponent("doc.assets").path),
            "nothing was moved into a sidecar"
        )
    }

    /// Alt text changes nothing about which links are pictures.
    @MainActor
    func testALinkWithAltTextIsAChipToo() throws {
        let notes = try makeTemporaryDirectory()
        _ = try write(pngData(width: 5, height: 5), named: "a.png", in: notes)
        let file = notes.appendingPathComponent("doc.md")
        try Data("![a picture](a.png)".utf8).write(to: file)

        let controller = try makeController()
        controller.open(url: file)
        let opened = try XCTUnwrap(controller.openNotes.first { $0.fileURL == file })
        XCTAssertEqual(occurrences(of: "nota://", in: opened.text), 1)
    }

    @MainActor
    func testALinkToAFileThatIsNotThereStaysTheTextItIs() throws {
        let notes = try makeTemporaryDirectory()
        let file = notes.appendingPathComponent("doc.md")
        let source = "![](pics/gone.png) and ![](http://example.com/x.png)\n"
        try Data(source.utf8).write(to: file)

        let controller = try makeController()
        controller.open(url: file)
        let opened = try XCTUnwrap(controller.openNotes.first { $0.fileURL == file })
        XCTAssertEqual(opened.text, source)

        controller.saveCurrent(forcePanel: false)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source)
    }

    // MARK: - Save As

    @MainActor
    func testSaveAsWritesANewSidecarAndLeavesTheOldOneAlone() throws {
        let notes = try makeTemporaryDirectory()
        let controller = try makeController()
        try drop([try write(pngData(width: 20, height: 10), named: "one.png", in: notes),
                  try write(pngData(width: 8, height: 30), named: "two.png", in: notes)],
                 on: controller)

        let first = notes.appendingPathComponent("notes.md")
        controller.savePanelProvider = { _ in first }
        controller.saveCurrent(forcePanel: false)

        let second = notes.appendingPathComponent("copy.md")
        controller.savePanelProvider = { _ in second }
        controller.saveCurrent(forcePanel: true)

        let text = try String(contentsOf: second, encoding: .utf8)
        XCTAssertEqual(occurrences(of: "](copy.assets/", in: text), 2)
        XCTAssertFalse(text.contains("notes.assets/"), "the copy is not tied to the original")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: notes.appendingPathComponent("copy.assets").path
        ).count, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: notes.appendingPathComponent("notes.assets").path
        ).count, 2, "the first note's folder is left exactly as it was")
    }

    // MARK: - The pieces on their own

    func testFolderNamesAndLinkSpelling() throws {
        let file = URL(fileURLWithPath: "/tmp/dir/notes.md")
        XCTAssertEqual(Sidecar.folderName(for: file), "notes.assets")
        XCTAssertEqual(Sidecar.folderURL(for: file).path, "/tmp/dir/notes.assets")
        XCTAssertEqual(Sidecar.folderName(for: URL(fileURLWithPath: "/tmp/README")),
                       "README.assets")

        XCTAssertEqual(Sidecar.link(forRelativePath: "my notes.assets/a.png"),
                       "my%20notes.assets/a.png")
        XCTAssertEqual(Sidecar.link(forRelativePath: "pics/a(1).png"), "pics/a%281%29.png")
        XCTAssertEqual(Sidecar.link(forRelativePath: "pics/a.png"), "pics/a.png")
    }

    func testWhichLinkTargetsAreRelativePaths() throws {
        XCTAssertEqual(Sidecar.candidatePaths(fromLinkTarget: "pics/a.png"), ["pics/a.png"])
        XCTAssertEqual(Sidecar.candidatePaths(fromLinkTarget: "my%20pics/a.png"),
                       ["my pics/a.png", "my%20pics/a.png"])
        for refused in ["/abs/a.png", "~/a.png", "http://x/a.png", "nota://a.png",
                        "//host/a.png", "#anchor", "../a.png", "  "] {
            XCTAssertTrue(Sidecar.candidatePaths(fromLinkTarget: refused).isEmpty,
                          "should not resolve: \(refused)")
        }
    }

    /// Save As must not go on pointing at the note it was copied from, but a
    /// folder the author chose is theirs and is left alone.
    func testWhichRememberedPathsSurviveARename() {
        XCTAssertTrue(Sidecar.isPortable("pics/a.png", ownFolderName: "copy.assets"))
        XCTAssertTrue(Sidecar.isPortable("copy.assets/a.png", ownFolderName: "copy.assets"))
        XCTAssertFalse(Sidecar.isPortable("notes.assets/a.png", ownFolderName: "copy.assets"))
    }

    /// The pictures beside a file are read again on every open of it, so the
    /// store must recognise bytes it already holds instead of growing a copy.
    func testImportingTheSameBytesTwiceReusesTheAsset() throws {
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let directory = try makeTemporaryDirectory()
        let picture = try write(pngData(width: 11, height: 4), named: "a.png", in: directory)

        let first = try XCTUnwrap(assets.importFileDeduplicating(at: picture))
        let second = try XCTUnwrap(assets.importFileDeduplicating(at: picture))
        XCTAssertEqual(first, second)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: assets.directory.path).count, 1
        )

        let other = try write(pngData(width: 3, height: 3), named: "b.png", in: directory)
        XCTAssertNotEqual(try XCTUnwrap(assets.importFileDeduplicating(at: other)), first)
    }

    /// Nothing about serialising changes until a resolver is handed in.
    func testSerializeWithoutAResolverStillWritesTokens() throws {
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let id = try XCTUnwrap(
            assets.importImageData(try pngData(width: 4, height: 4), preferredExtension: "png")
        )
        let plain = "a \(NoteText.token(for: id)) b"
        let rendered = NoteText.render(plain, attributes: [:], assets: assets)
        XCTAssertEqual(NoteText.serialize(rendered, sidecar: nil), plain)
        XCTAssertEqual(
            NoteText.serialize(rendered, sidecar: { _ in "pics/a.png" }),
            "a ![](pics/a.png) b"
        )
        // A resolver that has nothing to offer leaves the token as it was.
        XCTAssertEqual(NoteText.serialize(rendered, sidecar: { _ in nil }), plain)
    }

    // MARK: - Helpers

    private func occurrences(of needle: String, in text: String) -> Int {
        var count = 0
        var range = text.startIndex..<text.endIndex
        while let found = text.range(of: needle, range: range) {
            count += 1
            range = found.upperBound..<text.endIndex
        }
        return count
    }

    @MainActor
    private func drop(_ pictures: [URL], on controller: MainWindowController) throws {
        let editor = try XCTUnwrap(controller.editorScrolling.textView as? NotaTextView)
        for picture in pictures {
            XCTAssertTrue(editor.performDragOperation(dragOf([picture])))
        }
    }

    private func dragOf(_ urls: [URL]) -> FakeSidecarDrag {
        let pasteboard = NSPasteboard(name: .init("SidecarTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        return FakeSidecarDrag(pasteboard: pasteboard)
    }

    @MainActor
    private func makeController(
        support: URL? = nil, store: SessionStore? = nil
    ) throws -> MainWindowController {
        _ = NSApplication.shared
        let resolved = try store ?? SessionStore(directory: support ?? makeTemporaryDirectory())
        let controller = MainWindowController(store: resolved)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1000, height: 560))
        window.makeKeyAndOrderFrontOffscreen()
        window.layoutIfNeeded()
        return controller
    }

    private func write(_ data: Data, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func pngData(width: Int, height: Int) throws -> Data {
        let representation = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        NSColor.orange.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidecarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory.standardizedFileURL
    }
}

/// A drag the window server never made: only the pasteboard matters to a
/// target that reads file URLs off it.
private final class FakeSidecarDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard

    init(pasteboard: NSPasteboard) {
        self.draggingPasteboard = pasteboard
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    var numberOfValidItemsForDrop: Int = 0
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination: Bool = false
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
