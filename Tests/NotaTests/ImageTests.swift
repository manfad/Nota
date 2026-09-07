import AppKit
import Foundation
import XCTest
@testable import Nota

/// The other thing Nota opens rather than edits. A picture is a tab like a
/// PDF is — in the strip, ⌘W closes it, the session brings it back — and like
/// a PDF it is looked at rather than written to: locked in reading, never
/// dirty, never cached.
///
/// The one thing a picture is not is an asset. Dropped into the text of a
/// note it is still a picture in that note; opened as a file it is a tab of
/// its own. Which of the two happens is settled by where it was dropped.
final class ImageTests: AppKitTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    // MARK: - What counts as a picture

    func testAPictureIsKnownByItsBytesWhateverItIsNamed() throws {
        let directory = try makeTemporaryDirectory()
        let png = try write(pngData(width: 20, height: 10), named: "report", in: directory)
        let jpeg = try write(jpegData(width: 20, height: 10), named: "notes.txt", in: directory)
        let gif = try write(gifData(width: 8, height: 8), named: "photo", in: directory)

        XCTAssertEqual(FileSniff.classify(at: png), .image, "a PNG named report is a picture")
        XCTAssertEqual(FileSniff.classify(at: jpeg), .image)
        XCTAssertEqual(FileSniff.classify(at: gif), .image)
    }

    func testAFileNamedForAPictureWhoseBytesAreTextIsText() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("screenshot.png")
        try Data("2026-09-04 08:00 started\n2026-09-04 08:01 finished\n".utf8).write(to: url)
        XCTAssertEqual(FileSniff.classify(at: url), .text,
                       "the bytes decide, the same as for a .pdf that is really a log")
    }

    func testTheNameIsAskedOnlyWhenTheBytesCannotSpeak() throws {
        let missing = try makeTemporaryDirectory()
        XCTAssertEqual(Note.viewerKind(missing.appendingPathComponent("photo.png")), .image)
        XCTAssertEqual(Note.viewerKind(missing.appendingPathComponent("SHOT.JPEG")), .image)
        XCTAssertEqual(Note.viewerKind(missing.appendingPathComponent("paper.pdf")), .pdf)
        XCTAssertNil(Note.viewerKind(missing.appendingPathComponent("notes.txt")))
        XCTAssertNil(
            Note.viewerKind(missing.appendingPathComponent("drawing.svg")),
            "an SVG is text with a drawing beside it, not a picture Nota views"
        )
    }

    // MARK: - Where a picture lands

    /// The split is the drop target, not the file. The same `.png` opens as a
    /// tab through Open…, the Finder and the command line, and lands in the
    /// note as a chip when it is dropped into the text.
    func testAPictureOpensAsATabButDropsIntoTheTextAsAChip() throws {
        let directory = try makeTemporaryDirectory()
        let picture = try write(pngData(width: 20, height: 10), named: "photo.png",
                                in: directory)
        let text = directory.appendingPathComponent("notes.md")
        try Data("# hi".utf8).write(to: text)

        XCTAssertTrue(Note.isOpenable(picture), "Open… and the Finder open it as a tab")

        let pasteboard = NSPasteboard(name: .init("NotaImageTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([picture, text].map { $0 as NSURL })
        XCTAssertEqual(
            NotaTextView.openableFiles(on: pasteboard).map(\.lastPathComponent),
            ["notes.md"],
            "dropped into the text, the picture is the note's own, not a tab beside it"
        )
        XCTAssertTrue(AssetStore.isImageFile(picture), "which is what the store takes it as")
    }

    // MARK: - Opening one

    @MainActor
    func testOpeningAPictureAddsAReadingTabShowingIt() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeController(in: directory)
        let picture = try write(pngData(width: 200, height: 150), named: "photo.png",
                                in: directory)

        controller.open(url: picture)

        XCTAssertEqual(controller.openNotes.last?.title, "photo.png")
        XCTAssertEqual(controller.currentTabState.kind, .image)
        XCTAssertEqual(controller.previewMode, .reading, "a picture is the page and nothing else")
        XCTAssertTrue(controller.previewState.isVisible)
        XCTAssertEqual(controller.previewPanes.kind, .image, "the picture, not a render")
        XCTAssertEqual(controller.previewPanes.image.image?.size.width, 200)
    }

    @MainActor
    func testAPictureTabIsReadNeverEdited() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeController(in: directory)
        let picture = try write(gifData(width: 8, height: 8), named: "loop.gif", in: directory)
        controller.open(url: picture)

        XCTAssertFalse(controller.currentTabState.isDirty)
        XCTAssertFalse(controller.currentTabIsSavable, "there is nothing in it to save")

        let note = makeNote(of: picture)
        XCTAssertFalse(note.isEditable)
        XCTAssertFalse(note.writesToCache, "and nothing to write to the cache")
        XCTAssertFalse(controller.canShowRenderedPreview, "and no mode control to offer")

        // Locked in reading: asking for another mode is asking for nothing.
        controller.setPreviewMode(.off)
        XCTAssertEqual(controller.previewMode, .reading)
        controller.toggleMarkdownPreview()
        XCTAssertEqual(controller.previewMode, .reading)
    }

    @MainActor
    func testAPictureThatHasGoneSaysSoInThePane() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeController(in: directory)
        let picture = try write(pngData(width: 20, height: 10), named: "gone.png",
                                in: directory)
        controller.open(url: picture)
        try FileManager.default.removeItem(at: picture)

        // A fresh pane, since the one on screen is holding the picture it
        // already read — the same as a PDF whose file goes.
        let pane = ImagePreviewView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        pane.show(makeNote(of: picture), in: PreviewContext(
            font: .systemFont(ofSize: 13), assets: nil, isVisible: true
        ))
        XCTAssertNil(pane.image)
        XCTAssertEqual(pane.missingMessage, "Couldn’t open “gone.png”.")
    }

    // MARK: - The footer

    func testAPictureIsMeasuredInPixelsAndHasNowhereToBe() throws {
        XCTAssertEqual(TextStats.pixelSize(of: NSSize(width: 1200, height: 800)), "1200 × 800")

        let directory = try makeTemporaryDirectory()
        let picture = try write(pngData(width: 200, height: 150), named: "photo.png",
                                in: directory)
        let note = makeNote(of: picture)
        let pane = ImagePreviewView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        pane.show(note, in: PreviewContext(font: .systemFont(ofSize: 13),
                                           assets: nil, isVisible: true))

        let status = try XCTUnwrap(pane.footerStatus)
        XCTAssertEqual(status.summary, "200 × 150")
        XCTAssertNil(status.position, "there is nowhere in a picture to be")
    }

    /// A picture has no encoding or line endings either — Todo 2's field is
    /// empty over it, same as a PDF.
    @MainActor
    func testTheEncodingAndLineEndingFieldIsEmptyOverAPictureTab() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeController(in: directory)
        let picture = try write(pngData(width: 20, height: 10), named: "photo.png",
                                in: directory)
        controller.open(url: picture)

        XCTAssertEqual(controller.footerRegions.encoding.stringValue, "")
        XCTAssertEqual(controller.footerRegions.lineEnding.stringValue, "")
    }

    // MARK: - The session

    @MainActor
    func testAPictureTabComesBackFromTheSession() throws {
        let directory = try makeTemporaryDirectory()
        let picture = try write(pngData(width: 200, height: 150), named: "photo.png",
                                in: directory)
        do {
            let controller = try makeController(in: directory)
            controller.open(url: picture)
            controller.flushAll()
        }
        let relaunched = try makeController(in: directory)
        let index = try XCTUnwrap(
            relaunched.openNotes.firstIndex { $0.fileURL?.standardizedFileURL
                == picture.standardizedFileURL },
            "photo.png is not open"
        )
        relaunched.selectTab(at: index)

        XCTAssertEqual(relaunched.currentTabState.kind, .image)
        XCTAssertFalse(relaunched.currentTabState.isDirty,
                       "a picture read as text is what used to come back as an empty dirty tab")
        XCTAssertEqual(relaunched.previewMode, .reading)
        XCTAssertEqual(relaunched.previewPanes.kind, .image)
    }

    // MARK: - Helpers

    @MainActor
    private func makeController(in directory: URL) throws -> MainWindowController {
        _ = NSApplication.shared
        let controller = MainWindowController(store: SessionStore(directory: directory))
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1000, height: 560))
        window.layoutIfNeeded()
        return controller
    }

    /// The tab a picture opens in, on its own — the window's own notes are
    /// not reachable from a test, and nothing here needs a window.
    private func makeNote(of url: URL) -> Note {
        Note(fileURL: url, untitledName: nil, text: "", attributes: [:],
             assets: nil, kind: .image)
    }

    private func write(_ data: Data, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func bitmap(width: Int, height: Int) throws -> NSBitmapImageRep {
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
        return representation
    }

    private func pngData(width: Int, height: Int) throws -> Data {
        try XCTUnwrap(bitmap(width: width, height: height).representation(
            using: .png, properties: [:]
        ))
    }

    private func jpegData(width: Int, height: Int) throws -> Data {
        try XCTUnwrap(bitmap(width: width, height: height).representation(
            using: .jpeg, properties: [:]
        ))
    }

    private func gifData(width: Int, height: Int) throws -> Data {
        try XCTUnwrap(bitmap(width: width, height: height).representation(
            using: .gif, properties: [:]
        ))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotaImageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
