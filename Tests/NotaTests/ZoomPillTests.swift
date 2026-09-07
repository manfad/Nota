import AppKit
import CoreText
import Foundation
import XCTest
@testable import Nota

/// The zoom pill in the preview column's bottom-leading corner: `−  100%  +`,
/// the corner slot's twin at the other end of the diagonal.
///
/// It says what the content in front is drawn at, as a percentage of that
/// content's own actual size, and it is only there when it is wanted — for a
/// second and a half after a zoom, and while the pointer is in the band along
/// the bottom of the column. A tab with no zoom to report has no pill at all.
final class ZoomPillTests: AppKitTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    // MARK: - What it says

    @MainActor
    func testAPDFTabReadsAHundredPercentAndThePillIsNotOnScreen() throws {
        let controller = try makeController()
        controller.open(url: try makePDF(named: "paper.pdf"))
        let pill = controller.zoomPill

        XCTAssertEqual(pill.percent, 100, "the fitted page is what 100% means")
        XCTAssertFalse(pill.isHidden, "a document has a zoom to report")
        XCTAssertFalse(pill.isRevealed, "but nobody has asked for it yet")
    }

    @MainActor
    func testZoomingShowsThePillAndActualSizePutsItBackToAHundred() throws {
        let controller = try makeController()
        controller.open(url: try makePDF(named: "paper.pdf"))
        let pill = controller.zoomPill

        controller.zoomIn()
        XCTAssertTrue(pill.isRevealed, "a zoom is the pill's own reason to be there")
        XCTAssertEqual(pill.percent, 125)

        controller.zoomIn()
        XCTAssertEqual(pill.percent, 156, "a quarter more again, rounded to a percent")

        controller.actualSize()
        XCTAssertEqual(pill.percent, 100)
        XCTAssertTrue(pill.isRevealed)
    }

    // MARK: - When it is on screen

    @MainActor
    func testThePillTakesItselfAwayWhenTheHoldRunsOut() throws {
        let controller = try makeController()
        controller.open(url: try makePDF(named: "paper.pdf"))
        let pill = controller.zoomPill

        controller.zoomIn()
        XCTAssertTrue(pill.isRevealed)

        pill.fireHoldTimerForTesting()
        XCTAssertFalse(pill.isRevealed, "a second and a half after the last zoom")
        XCTAssertEqual(pill.percent, 125, "and it still knows the number for next time")
    }

    @MainActor
    func testTheHoldStartsAgainFromTheLastZoom() throws {
        let controller = try makeController()
        controller.open(url: try makePDF(named: "paper.pdf"))
        let pill = controller.zoomPill

        controller.zoomIn()
        controller.zoomIn()
        pill.fireHoldTimerForTesting()
        XCTAssertFalse(pill.isRevealed, "one clock, restarted by the second press")
    }

    @MainActor
    func testThePointerInTheBandShowsThePillAndKeepsIt() throws {
        let controller = try makeController()
        controller.open(url: try makePDF(named: "paper.pdf"))
        let pill = controller.zoomPill

        pill.setHovering(true)
        XCTAssertTrue(pill.isRevealed, "reaching for it is enough")

        // The clock running out while the pointer is still there changes
        // nothing: either reason on its own keeps the pill up.
        controller.zoomIn()
        pill.fireHoldTimerForTesting()
        XCTAssertTrue(pill.isRevealed)

        pill.setHovering(false)
        XCTAssertFalse(pill.isRevealed, "and leaving takes it away")
    }

    /// Hovering a column whose content has no zoom brings back nothing — the
    /// overlay is away whole, so the band takes no clicks either.
    @MainActor
    func testHoveringATabWithNoZoomShowsNothing() throws {
        let controller = try makeController()
        controller.open(url: try writeFile(named: "notes.md", text: "# Heading\n"))
        controller.setPreviewMode(.reading)
        try XCTUnwrap(controller.window).layoutIfNeeded()
        let pill = controller.zoomPill

        pill.setHovering(true)
        XCTAssertFalse(pill.isRevealed)
        XCTAssertTrue(pill.isHidden)
    }

    // MARK: - Pressing it

    @MainActor
    func testPressingThePillIsTheSameAsPressingTheKeys() throws {
        let controller = try makeController()
        controller.open(url: try makePDF(named: "paper.pdf"))
        let pill = controller.zoomPill
        let pane = controller.previewPanes.pdf

        press(pill, segment: 2)
        XCTAssertEqual(pane.zoom, 1.25, accuracy: 0.001, "`+` is ⌘+")
        XCTAssertEqual(pill.percent, 125)
        XCTAssertTrue(pill.isRevealed, "and the pill's own press restarts its clock")

        press(pill, segment: 0)
        XCTAssertEqual(pane.zoom, 1, accuracy: 0.001, "`−` is ⌘-")

        press(pill, segment: 2)
        press(pill, segment: 1)
        XCTAssertEqual(pane.zoom, 1, accuracy: 0.001, "and the percentage is Actual Size")
        XCTAssertEqual(pill.percent, 100)
    }

    // MARK: - Which tabs carry one

    @MainActor
    func testAPictureCarriesThePill() throws {
        let controller = try makeController()
        controller.open(url: try writePNG(width: 200, height: 150, named: "photo.png"))

        XCTAssertEqual(controller.zoomPill.percent, 100)
        controller.zoomIn()
        XCTAssertEqual(controller.zoomPill.percent, 125)
    }

    @MainActor
    func testAPageInReadingCarriesThePillAndBesideTheEditorDoesNot() throws {
        let controller = try makeController()
        let file = try writeFile(named: "page.html", text: "<!doctype html><p>Hello.</p>")
        controller.open(url: file)
        controller.setPreviewMode(.reading)
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()

        XCTAssertEqual(controller.zoomPill.percent, 100)
        controller.zoomIn()
        XCTAssertEqual(controller.zoomPill.percent, 125)

        // In split the keys are the editor's font again, so the pill has
        // nothing to offer and goes.
        controller.setPreviewMode(.split)
        window.layoutIfNeeded()
        XCTAssertNil(controller.zoomPill.percent)
        XCTAssertTrue(controller.zoomPill.isHidden)
    }

    @MainActor
    func testARenderAndAGridHaveNoPill() throws {
        let controller = try makeController()
        controller.open(url: try writeFile(named: "notes.md", text: "# Heading\n"))
        controller.setPreviewMode(.reading)
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        XCTAssertNil(controller.zoomPill.percent, "the font already is the zoom in a render")

        controller.open(url: try writeFile(named: "shop.sql", text: "CREATE TABLE t (a);"))
        controller.setPreviewMode(.reading)
        window.layoutIfNeeded()
        XCTAssertNil(controller.zoomPill.percent, "and a grid is not a thing that zooms")
        XCTAssertTrue(controller.zoomPill.isHidden)
    }

    @MainActor
    func testSwitchingFromADocumentToANoteTakesThePillAwayAtOnce() throws {
        let controller = try makeController()
        controller.open(url: try makePDF(named: "paper.pdf"))
        let document = controller.selectedTabIndex
        controller.zoomIn()
        XCTAssertTrue(controller.zoomPill.isRevealed)

        controller.open(url: try writeFile(named: "notes.md", text: "# Heading\n"))
        try XCTUnwrap(controller.window).layoutIfNeeded()
        XCTAssertFalse(controller.zoomPill.isRevealed, "no fade: the number was the PDF's")
        XCTAssertNil(controller.zoomPill.percent)

        controller.selectTab(at: document)
        try XCTUnwrap(controller.window).layoutIfNeeded()
        XCTAssertEqual(controller.zoomPill.percent, 125, "and the document is as it was left")
        XCTAssertFalse(controller.zoomPill.isRevealed, "shown again only when it is asked for")
    }

    // MARK: - Light and dark

    @MainActor
    func testTheAppearanceSwapRedrawsTheSymbols() throws {
        let controller = try makeController()
        controller.open(url: try makePDF(named: "paper.pdf"))
        let window = try XCTUnwrap(controller.window)
        let pill = controller.zoomPill

        window.appearance = NSAppearance(named: .darkAqua)
        window.layoutIfNeeded()
        pill.applySegmentTints()
        XCTAssertNotNil(pill.control.image(forSegment: 0))
        XCTAssertNotNil(pill.control.image(forSegment: 2))

        window.appearance = NSAppearance(named: .aqua)
        window.layoutIfNeeded()
        pill.applySegmentTints()
        XCTAssertNotNil(pill.control.image(forSegment: 0))
        XCTAssertEqual(pill.percent, 100)
    }

    // MARK: - Helpers

    /// A press on one of the three segments. The control is momentary, so
    /// there is no selection for a test to set: the index is what a click
    /// would have handed the pill.
    @MainActor
    private func press(_ pill: ZoomPillOverlay, segment: Int) {
        pill.pressSegment(segment)
    }

    @MainActor
    private func makeController() throws -> MainWindowController {
        _ = NSApplication.shared
        let store = try SessionStore(directory: makeTemporaryDirectory())
        let controller = MainWindowController(store: store)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1000, height: 560))
        window.makeKeyAndOrderFrontOffscreen()
        window.layoutIfNeeded()
        return controller
    }

    /// A real PDF of one page with text on it, the same fixture the zoom
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

    private func writeFile(named name: String, text: String) throws -> URL {
        let url = try makeTemporaryDirectory().appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotaZoomPillTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
