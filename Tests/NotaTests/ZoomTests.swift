import AppKit
import CoreText
import Foundation
import PDFKit
import XCTest
@testable import Nota

/// ⌘+, ⌘- and ⌘0 are one pair of hands doing two jobs.
///
/// With an editor on screen they are the editor's font size, and the Markdown
/// and LaTeX renders follow it — that is what the keys have always been. With
/// the content alone on screen and its size nothing to do with a font — a
/// document, a picture, an HTML page — they zoom the content instead. A
/// render in reading mode stays with the font, since the font already *is*
/// the zoom there.
final class ZoomTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    // MARK: - A document

    @MainActor
    func testZoomingAPDFTabScalesThePageAndActualSizeGoesBackToTheFit() throws {
        let controller = try makeController()
        controller.open(url: try makePDF(named: "paper.pdf"))
        let pane = controller.previewPanes.pdf
        XCTAssertTrue(controller.zoomsContent, "a document is the only thing on screen")
        let fitted = pane.scaleFactor
        XCTAssertGreaterThan(fitted, 0)

        controller.zoomIn()
        XCTAssertEqual(pane.scaleFactor, fitted * 1.25, accuracy: 0.001)
        XCTAssertEqual(pane.zoom, 1.25, accuracy: 0.001)
        controller.zoomIn()
        XCTAssertEqual(pane.scaleFactor, fitted * 1.25 * 1.25, accuracy: 0.001)

        controller.zoomOut()
        XCTAssertEqual(pane.scaleFactor, fitted * 1.25, accuracy: 0.001)

        controller.actualSize()
        XCTAssertEqual(pane.zoom, 1, accuracy: 0.001)
        XCTAssertEqual(pane.scaleFactor, fitted, accuracy: 0.001,
                       "back to the page fitted to the column, capped at 100%")
    }

    /// The zoom belongs to the tab, not to the pane every PDF is read
    /// through: two documents open at once are read at their own sizes.
    @MainActor
    func testTheZoomIsRememberedPerTab() throws {
        let controller = try makeController()
        controller.open(url: try makePDF(named: "first.pdf"))
        let first = controller.selectedTabIndex
        controller.zoomIn()
        controller.zoomIn()
        let pane = controller.previewPanes.pdf
        let zoomed = pane.zoom
        XCTAssertEqual(zoomed, 1.25 * 1.25, accuracy: 0.001)

        controller.open(url: try makePDF(named: "second.pdf"))
        XCTAssertEqual(pane.zoom, 1, accuracy: 0.001, "a fresh tab opens at its own size")

        controller.selectTab(at: first)
        XCTAssertEqual(pane.zoom, zoomed, accuracy: 0.001, "and the first is as it was left")

        // And none of it is in the session: how close you were reading is not
        // where you were reading.
        controller.flushAll()
        let reopened = try makeController(store: SessionStore(directory: storeDirectory))
        XCTAssertEqual(reopened.previewPanes.pdf.zoom, 1, accuracy: 0.001)
    }

    // MARK: - A picture

    @MainActor
    func testZoomingAPictureTabDrawsItBiggerAndActualSizeGoesBack() throws {
        let controller = try makeController()
        let picture = try writePNG(width: 200, height: 150, named: "photo.png")
        controller.open(url: picture)
        let pane = controller.previewPanes.image
        XCTAssertTrue(controller.zoomsContent)
        let fitted = pane.drawnSize
        XCTAssertGreaterThan(fitted.width, 0)

        controller.zoomIn()
        XCTAssertEqual(pane.drawnSize.width, (fitted.width * 1.25).rounded(), accuracy: 1)
        XCTAssertEqual(pane.drawnSize.height, (fitted.height * 1.25).rounded(), accuracy: 1)

        controller.zoomOut()
        controller.zoomOut()
        XCTAssertLessThan(pane.drawnSize.width, fitted.width, "and smaller than it opened")

        controller.actualSize()
        XCTAssertEqual(pane.drawnSize.width, fitted.width, accuracy: 1)
        XCTAssertEqual(pane.zoom, 1, accuracy: 0.001)
    }

    /// The clamp is real: pressing ⌘+ for ever does not run away.
    @MainActor
    func testAPicturesZoomIsClamped() throws {
        let controller = try makeController()
        controller.open(url: try writePNG(width: 200, height: 150, named: "photo.png"))
        for _ in 0 ..< 40 { controller.zoomIn() }
        XCTAssertEqual(controller.previewPanes.image.zoom, 8, accuracy: 0.001)
        for _ in 0 ..< 40 { controller.zoomOut() }
        XCTAssertEqual(controller.previewPanes.image.zoom, 0.25, accuracy: 0.001)
    }

    // MARK: - An HTML page

    /// In reading mode the page is the only thing on screen, so the keys are
    /// the page's zoom. In split the editor is right there and they are the
    /// font size they have always been.
    @MainActor
    func testAnHTMLTabZoomsThePageInReadingAndTheFontInSplit() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("page.html")
        try "<!doctype html><body><p>Hello.</p></body>".write(
            to: file, atomically: true, encoding: .utf8
        )
        let controller = try makeController()
        controller.open(url: file)
        controller.setPreviewMode(.reading)
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        let pane = controller.previewPanes.html
        XCTAssertTrue(controller.zoomsContent, "the page is the only thing on screen")

        let font = controller.currentFontSize
        controller.zoomIn()
        XCTAssertEqual(pane.zoom, 1.25, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(pane.webView).pageZoom, 1.25, accuracy: 0.001)
        XCTAssertEqual(controller.currentFontSize, font, "the font was left alone")

        controller.actualSize()
        XCTAssertEqual(pane.zoom, 1, accuracy: 0.001)

        // Beside the editor the keys are the editor's again.
        controller.setPreviewMode(.split)
        window.layoutIfNeeded()
        XCTAssertFalse(controller.zoomsContent)
        controller.zoomIn()
        XCTAssertEqual(controller.currentFontSize, font + 1)
        XCTAssertEqual(pane.zoom, 1, accuracy: 0.001, "and the page was left alone")
        controller.actualSize()
        XCTAssertEqual(controller.currentFontSize, 13)
    }

    // MARK: - A render

    /// A Markdown render in reading mode stays with the font: the font is
    /// what the render is made of, so changing it *is* zooming the page.
    @MainActor
    func testAMarkdownTabInReadingModeStillChangesTheFontSize() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("notes.md")
        try "# Heading\n\nA paragraph.".write(to: file, atomically: true, encoding: .utf8)
        let controller = try makeController()
        controller.open(url: file)
        controller.setPreviewMode(.reading)
        try XCTUnwrap(controller.window).layoutIfNeeded()

        XCTAssertFalse(controller.zoomsContent, "the font already is the zoom there")
        let font = controller.currentFontSize
        controller.zoomIn()
        XCTAssertEqual(controller.currentFontSize, font + 1)
        controller.actualSize()
        XCTAssertEqual(controller.currentFontSize, 13)
    }

    // MARK: - The View menu

    @MainActor
    func testTheViewMenuTitlesFollowTheTabInFront() throws {
        let controller = try makeController()
        XCTAssertEqual(controller.sizeMenuTitles.increase, "Increase Font Size",
                       "an untitled note is a note")
        XCTAssertEqual(controller.sizeMenuTitles.decrease, "Decrease Font Size")

        controller.open(url: try makePDF(named: "paper.pdf"))
        XCTAssertEqual(controller.sizeMenuTitles.increase, "Zoom In")
        XCTAssertEqual(controller.sizeMenuTitles.decrease, "Zoom Out")

        controller.newTab()
        XCTAssertEqual(controller.sizeMenuTitles.increase, "Increase Font Size",
                       "and back again on the next text tab")
    }

    // MARK: - Helpers

    private var storeDirectory: URL {
        temporaryDirectories.first ?? FileManager.default.temporaryDirectory
    }

    @MainActor
    private func makeController(store: SessionStore? = nil) throws -> MainWindowController {
        _ = NSApplication.shared
        let store = try store ?? SessionStore(directory: makeTemporaryDirectory())
        let controller = MainWindowController(store: store)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1000, height: 560))
        window.makeKeyAndOrderFrontOffscreen()
        window.layoutIfNeeded()
        return controller
    }

    /// A real PDF of one page with text on it, the same fixture the find
    /// tests use.
    private func makePDF(named name: String) throws -> URL {
        let url = try makeTemporaryDirectory().appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let attributed = NSAttributedString(
            string: "alpha beta",
            attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.black]
        )
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: box.insetBy(dx: 24, dy: 24), transform: nil)
        CTFrameDraw(
            CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil), context
        )
        context.endPDFPage()
        context.closePDF()
        return url
    }

    private func writePNG(width: Int, height: Int, named name: String) throws -> URL {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        let representation = try XCTUnwrap(
            NSBitmapImageRep(data: image.tiffRepresentation ?? Data())
        )
        let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        let url = try makeTemporaryDirectory().appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotaZoomTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
