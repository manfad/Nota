import AppKit
import XCTest
@testable import Nota

/// Where a dropped file lands is the drop target's business, not the file's.
/// The text is the chip target: a picture let go in it becomes part of the
/// note. The tab strip and the band across the top of the window are tab
/// targets: everything let go on them opens as a tab, pictures included, the
/// same as ⌘O and the Dock icon do it.
final class DropOnStripTests: XCTestCase {
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

    // MARK: - The strip

    /// The one case the editor would have handled differently: a picture in
    /// the text is a chip, a picture on the strip is a tab of its own — and
    /// the note that was in front is left exactly as it was.
    @MainActor
    func testAPictureDroppedOnTheStripOpensAnImageTabRatherThanAChip() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeController(in: directory)
        let picture = try write(pngData(width: 20, height: 10), named: "photo.png",
                                in: directory)
        let tabsBefore = controller.openNotes.count

        XCTAssertTrue(controller.tabStrip.performDragOperation(dragOf([picture])))

        XCTAssertEqual(controller.openNotes.count, tabsBefore + 1)
        XCTAssertEqual(controller.openNotes.last?.title, "photo.png")
        XCTAssertEqual(controller.currentTabState.kind, .image)
        XCTAssertTrue(controller.openNotes.allSatisfy { $0.text.isEmpty },
                      "no chip landed in the note that was in front")
    }

    @MainActor
    func testATextFileDroppedOnTheStripOpensATextTab() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeController(in: directory)
        let note = directory.appendingPathComponent("notes.md")
        try Data("# hi".utf8).write(to: note)

        XCTAssertTrue(controller.tabStrip.performDragOperation(dragOf([note])))

        XCTAssertEqual(controller.openNotes.last?.title, "notes.md")
        XCTAssertEqual(controller.openNotes.last?.text, "# hi")
        XCTAssertEqual(controller.currentTabState.kind, .text)
    }

    /// A drag carrying no file at all is not the strip's to take, so the
    /// window under it is free to answer instead.
    @MainActor
    func testTheStripRefusesADragThatCarriesNoFile() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeController(in: directory)

        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.writeObjects(["just some words" as NSString])

        XCTAssertEqual(
            controller.tabStrip.draggingEntered(FakeDraggingInfo(pasteboard: pasteboard)), []
        )
        XCTAssertFalse(
            controller.tabStrip.performDragOperation(FakeDraggingInfo(pasteboard: pasteboard))
        )
    }

    // MARK: - The band a hidden strip leaves behind

    /// With the strip switched off there is nothing at the top but the band
    /// the window is dragged by — and that takes the drop, so the target is
    /// in the same place whether or not the strip is on screen.
    @MainActor
    func testAFileDroppedOnTheTopBandOpensATabWhileTheStripIsHidden() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeController(in: directory)
        Preferences.shared.hidesTabBar = true
        controller.window?.layoutIfNeeded()

        let band = controller.topDragBandForTesting
        XCTAssertFalse(band.isHidden, "the band is what is left of the top")

        let note = directory.appendingPathComponent("band.md")
        try Data("dropped".utf8).write(to: note)
        XCTAssertTrue(band.performDragOperation(dragOf([note])))

        XCTAssertEqual(controller.openNotes.last?.title, "band.md")
        XCTAssertEqual(controller.currentTabState.kind, .text)
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

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("DropOnStripTests-\(UUID().uuidString)"))
    }

    /// A Finder drag carrying these files, as far as a drop target can tell.
    private func dragOf(_ urls: [URL]) -> FakeDraggingInfo {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        return FakeDraggingInfo(pasteboard: pasteboard)
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
            .appendingPathComponent("DropOnStripTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}

/// A drag the window server never made. Only the pasteboard matters to a
/// target that reads file URLs off it; the rest is there because the
/// protocol asks for it.
private final class FakeDraggingInfo: NSObject, NSDraggingInfo {
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
