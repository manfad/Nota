import AppKit
import PDFKit
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

    // MARK: - The text

    /// The editor is the chip target, and a drawing is not a picture: an
    /// `.svg` is text that opens in a tab with the drawing beside it, the
    /// same arrangement a `.html` has. The system files it under images all
    /// the same, which is what used to claim it as a chip and then lose it —
    /// the store cannot read a drawing's bytes as a picture.
    @MainActor
    func testADrawingDroppedOnTheTextOpensATabRatherThanBecomingAChip() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeController(in: directory)
        let drawing = try write(
            Data("<svg xmlns=\"http://www.w3.org/2000/svg\"><rect/></svg>".utf8),
            named: "logo.svg", in: directory
        )
        let editor = try XCTUnwrap(controller.editorScrolling.textView as? NotaTextView)
        let tabsBefore = controller.openNotes.count

        XCTAssertFalse(AssetStore.isImageFile(drawing), "the store refuses a drawing")
        XCTAssertTrue(editor.performDragOperation(dragOf([drawing])))

        XCTAssertEqual(controller.openNotes.count, tabsBefore + 1)
        XCTAssertEqual(controller.openNotes.last?.title, "logo.svg")
        XCTAssertEqual(controller.openNotes.last?.fileURL.flatMap(Note.previewKind), .svg,
                       "and it is read as the drawing it is")
        XCTAssertTrue(controller.openNotes.allSatisfy { !$0.text.contains("nota://") },
                      "and no chip landed in the note it was let go on")
    }

    /// The other half of the same rule: a real picture in the text is still
    /// a chip in that note, and no tab of its own.
    @MainActor
    func testAPictureDroppedOnTheTextIsStillAChipAndNoTab() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeController(in: directory)
        let picture = try write(pngData(width: 20, height: 10), named: "photo.png",
                                in: directory)
        let editor = try XCTUnwrap(controller.editorScrolling.textView as? NotaTextView)
        let tabsBefore = controller.openNotes.count

        XCTAssertTrue(editor.performDragOperation(dragOf([picture])))

        XCTAssertEqual(controller.openNotes.count, tabsBefore, "no tab opened")
        XCTAssertTrue(controller.openNotes.contains { $0.text.contains("nota://") },
                      "the picture is in the note as a chip")
    }

    // MARK: - The render column

    /// Reading a render, the column is all there is on screen — and it is a
    /// tab target like the strip, so a file let go anywhere over it opens as
    /// a tab and the note being read is left as it was.
    @MainActor
    func testAFileDroppedOnTheRenderOpensATab() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeController(in: directory)
        let note = try write(Data("# hi".utf8), named: "notes.md", in: directory)
        controller.open(url: note)
        controller.setPreviewMode(.reading)
        controller.window?.layoutIfNeeded()
        XCTAssertEqual(controller.previewPanes.kind, .markdown)

        let dropped = try write(Data("dropped".utf8), named: "dropped.md", in: directory)
        let target = dropTarget(in: controller.previewPanes.markdown)
        XCTAssertTrue(target.performDragOperation(dragOf([dropped])))

        XCTAssertEqual(controller.openNotes.last?.title, "dropped.md")
        XCTAssertEqual(controller.currentTabState.kind, .text)
        XCTAssertEqual(controller.openNotes.first(where: { $0.title == "notes.md" })?.text,
                       "# hi", "the note that was being read is untouched")
    }

    /// WebKit takes a dropped file itself, by loading it — which would throw
    /// away the page being read with no way back. It never sees the drag.
    @MainActor
    func testAFileDroppedOnAPageOpensATabAndLeavesThePageWhereItWas() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeController(in: directory)
        let page = try write(Data("<!doctype html><p>hi</p>".utf8), named: "page.html",
                             in: directory)
        controller.open(url: page)
        controller.setPreviewMode(.reading)
        controller.window?.layoutIfNeeded()
        XCTAssertEqual(controller.previewPanes.kind, .html)

        let pane = controller.previewPanes.html
        let webView = try XCTUnwrap(pane.webView, "the page is on screen")
        let dropped = try write(Data("dropped".utf8), named: "dropped.md", in: directory)
        let target = dropTarget(in: pane)
        XCTAssertTrue(target.performDragOperation(dragOf([dropped])))

        XCTAssertEqual(controller.openNotes.last?.title, "dropped.md")
        XCTAssertEqual(controller.currentTabState.kind, .text)
        XCTAssertEqual(pane.shownBaseURL, PageFiles.pageURL(page),
                       "the page is still the page it was")
        XCTAssertNotEqual(webView.url, dropped)
        XCTAssertNotEqual(webView.url.map(PageFiles.linkDestination), dropped,
                          "and WebKit never navigated to the file let go on it")
    }

    /// PDFKit does the same thing with a dropped file — opens it in place —
    /// and is kept out of the drag the same way.
    @MainActor
    func testAFileDroppedOnADocumentOpensATab() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeController(in: directory)
        let paper = try makePDF(named: "paper.pdf", in: directory)
        controller.open(url: paper)
        controller.window?.layoutIfNeeded()
        XCTAssertEqual(controller.previewPanes.kind, .pdf)

        let pane = controller.previewPanes.pdf
        let dropped = try write(Data("dropped".utf8), named: "dropped.md", in: directory)
        let target = dropTarget(in: pane)
        XCTAssertTrue(target.performDragOperation(dragOf([dropped])))

        XCTAssertEqual(controller.openNotes.last?.title, "dropped.md")
        XCTAssertEqual(controller.currentTabState.kind, .text)
        XCTAssertEqual(
            controller.openNotes.first(where: { $0.title == "paper.pdf" })?.fileURL?
                .standardizedFileURL,
            paper.standardizedFileURL,
            "the document tab is still the document it was"
        )
    }

    /// A picture tab has no text to put a chip in, so a picture let go on one
    /// is a picture tab of its own — the strip's answer, not the editor's.
    @MainActor
    func testAFileDroppedOnAPictureOpensATab() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeController(in: directory)
        let picture = try write(pngData(width: 20, height: 10), named: "photo.png",
                                in: directory)
        controller.open(url: picture)
        controller.window?.layoutIfNeeded()
        XCTAssertEqual(controller.previewPanes.kind, .image)

        let other = try write(pngData(width: 8, height: 8), named: "other.png", in: directory)
        let target = dropTarget(in: controller.previewPanes.image)
        XCTAssertTrue(target.performDragOperation(dragOf([other])))

        XCTAssertEqual(controller.openNotes.last?.title, "other.png")
        XCTAssertEqual(controller.currentTabState.kind, .image)
    }

    /// A chapter is a page like any other, and the book behind it is left on
    /// the chapter it was open at.
    @MainActor
    func testAFileDroppedOnAChapterOpensATab() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeController(in: directory)
        controller.open(url: exampleURL("Book.epub"))
        controller.window?.layoutIfNeeded()
        XCTAssertEqual(controller.previewPanes.kind, .epub)
        let chapterBefore = controller.previewPanes.epub.chapterIndex

        let dropped = try write(Data("dropped".utf8), named: "dropped.md", in: directory)
        let target = dropTarget(in: controller.previewPanes.epub)
        XCTAssertTrue(target.performDragOperation(dragOf([dropped])))

        XCTAssertEqual(controller.openNotes.last?.title, "dropped.md")
        XCTAssertEqual(controller.currentTabState.kind, .text)
        XCTAssertEqual(controller.previewPanes.epub.chapterIndex, chapterBefore,
                       "the book is still where it was being read")
    }

    // MARK: - Helpers

    /// The fixtures the repo keeps beside the sources.
    private func exampleURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/\(name)")
            .standardizedFileURL
    }

    /// The view a Finder drag actually lands on. AppKit hands it to the
    /// deepest view under the pointer that is registered for the type, so a
    /// test that dropped on the wrapper would prove nothing about the page or
    /// the document inside it.
    @MainActor
    private func dropTarget(in view: NSView) -> NSView {
        var best = view
        var bestDepth = -1
        var stack: [(view: NSView, depth: Int)] = [(view, 0)]
        while let (candidate, depth) = stack.popLast() {
            if candidate.registeredDraggedTypes.contains(.fileURL), depth > bestDepth {
                best = candidate
                bestDepth = depth
            }
            stack.append(contentsOf: candidate.subviews.map { ($0, depth + 1) })
        }
        return best
    }

    private func makePDF(named name: String, in directory: URL) throws -> URL {
        let document = PDFDocument()
        let page = PDFPage()
        page.setBounds(NSRect(x: 0, y: 0, width: 300, height: 400), for: .mediaBox)
        document.insert(page, at: 0)
        let url = directory.appendingPathComponent(name)
        XCTAssertTrue(document.write(to: url), "the fixture has to be a real PDF")
        return url
    }

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
