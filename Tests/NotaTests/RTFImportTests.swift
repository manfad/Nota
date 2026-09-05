import AppKit
import XCTest
@testable import Nota

/// An `.rtf` (or an RTFD package) is not a document Nota edits, but its
/// plain text is worth keeping: `MainWindowController.open(url:)` imports it
/// into a brand-new untitled tab rather than binding a tab to the file, so
/// ⌘S can never overwrite the rich document with plain text. See SPEC.md
/// "## Model" and Note.isOpenable.
final class RTFImportTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    @MainActor
    func testOpeningAnRTFImportsItsPlainTextIntoANewUntitledDirtyTab() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeController(in: directory)
        let before = controller.openNotes
        XCTAssertEqual(before.count, 1, "a fresh window starts on one untitled tab")

        let rtf = try write(rtfData(for: "Hello **bold** world"), named: "notes.rtf", in: directory)
        controller.open(url: rtf)

        let after = controller.openNotes
        XCTAssertEqual(after.count, before.count + 1, "the rtf landed in a new tab, not the old one")
        let imported = try XCTUnwrap(after.last)
        XCTAssertEqual(imported.text, "Hello **bold** world")
        XCTAssertNil(imported.fileURL, "never bound to the rtf itself — ⌘S must ask for a new name")
        XCTAssertEqual(imported.title, "notes")
        XCTAssertTrue(controller.currentTabState.isDirty, "unsaved content from the moment it lands")

        // The tab that was in front before the import kept exactly what it had.
        XCTAssertEqual(after.first?.text, before.first?.text)
        XCTAssertEqual(after.first?.fileURL, before.first?.fileURL)
    }

    @MainActor
    func testOpeningAnRTFDPackageImportsItsPlainText() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeController(in: directory)

        let rtfd = try writeRTFD(for: "plain rtfd text", named: "doc.rtfd", in: directory)
        controller.open(url: rtfd)

        let imported = try XCTUnwrap(controller.openNotes.last)
        XCTAssertEqual(imported.text, "plain rtfd text")
        XCTAssertNil(imported.fileURL)
        XCTAssertTrue(controller.currentTabState.isDirty)
    }

    /// A `.rtf` whose bytes are not RTF at all is not imported — the bytes,
    /// not the extension, decide.
    func testAnRTFExtensionWithoutRealRTFBytesIsNotImported() throws {
        let directory = try makeTemporaryDirectory()
        let fakeRTF = try write(Data("just plain text, not rtf".utf8), named: "fake.rtf", in: directory)

        XCTAssertNil(TextFile.rtfPlainText(at: fakeRTF))
    }

    /// The drop path filters through `Note.isOpenable`; a real RTF must pass
    /// it now so a dropped `.rtf` reaches `open(url:)` and is imported rather
    /// than silently refused.
    @MainActor
    func testARealRTFDroppedOnTheStripIsAcceptedAndImported() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeController(in: directory)
        let rtf = try write(rtfData(for: "dropped rtf text"), named: "dropped.rtf", in: directory)

        XCTAssertTrue(Note.isOpenable(rtf), "a real RTF is openable — it imports rather than refuses")

        XCTAssertTrue(controller.tabStrip.performDragOperation(dragOf([rtf])))

        let imported = try XCTUnwrap(controller.openNotes.last)
        XCTAssertEqual(imported.text, "dropped rtf text")
        XCTAssertNil(imported.fileURL)
    }

    // MARK: - Helpers

    @MainActor
    private func makeController(in directory: URL) throws -> MainWindowController {
        _ = NSApplication.shared
        let controller = MainWindowController(store: SessionStore(directory: directory))
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1000, height: 560))
        window.makeKeyAndOrderFrontOffscreen()
        window.layoutIfNeeded()
        return controller
    }

    private func rtfData(for text: String) throws -> Data {
        let attributed = NSAttributedString(string: text)
        return try XCTUnwrap(attributed.rtf(
            from: NSRange(location: 0, length: attributed.length), documentAttributes: [:]
        ))
    }

    private func writeRTFD(for text: String, named name: String, in directory: URL) throws -> URL {
        let attributed = NSAttributedString(string: text)
        let wrapper = try XCTUnwrap(attributed.rtfdFileWrapper(
            from: NSRange(location: 0, length: attributed.length), documentAttributes: [:]
        ))
        let url = directory.appendingPathComponent(name)
        try wrapper.write(to: url, options: [], originalContentsURL: nil)
        return url
    }

    private func write(_ data: Data, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("RTFImportTests-\(UUID().uuidString)"))
    }

    private func dragOf(_ urls: [URL]) -> FakeRTFDraggingInfo {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        return FakeRTFDraggingInfo(pasteboard: pasteboard)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RTFImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}

/// A drag the window server never made — see `DropOnStripTests`'s own copy,
/// duplicated rather than shared since the two suites are not otherwise
/// linked and each keeps to its own file.
private final class FakeRTFDraggingInfo: NSObject, NSDraggingInfo {
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
