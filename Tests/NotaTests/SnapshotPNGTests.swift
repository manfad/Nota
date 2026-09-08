import AppKit
import XCTest
@testable import Nota

/// File › Export… → PNG of the preview / PNG of the editor: the whole
/// document as one tall picture of the screen. See SPEC.md "## Export",
/// Snapshots.
///
/// Every picture here is read back as pixels rather than looked at: how wide
/// it came out, how tall it grew, what colour the ground is, and where the
/// ink landed are the whole of what a snapshot promises.
final class SnapshotPNGTests: AppKitTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    // MARK: - What a tab offers

    /// The two pictures come after the two pages, preview first, and only a
    /// tab with a render of its own is offered a picture of its preview.
    @MainActor
    func testThePicturesAreListedAfterThePagesAndOnlyWhereTheyMeanSomething() throws {
        let directory = try makeTemporaryDirectory()
        let markdown = try makeNote(named: "notes.md", text: "# Title", in: directory)
        let plain = try makeNote(named: "log.txt", text: "just words", in: directory)
        let json = try makeNote(named: "data.json", text: "{\"a\": 1}", in: directory)

        XCTAssertEqual(
            Exporter.targets(for: markdown),
            [.previewPDF, .editorPDF, .previewPNG, .editorPNG]
        )
        XCTAssertEqual(
            Exporter.targets(for: plain), [.previewPDF, .editorPDF, .editorPNG],
            "a tab with no render of its own has no preview to photograph"
        )
        XCTAssertEqual(
            Exporter.targets(for: json), [.previewPDF, .editorPDF, .editorPNG],
            "a tree is drawn by a view, not laid out as text"
        )

        let rich = Note(id: UUID(), fileURL: exampleURL("Rich.rtf"), untitledName: nil,
                        text: "", attributes: [:], assets: nil, kind: .rtf)
        XCTAssertEqual(Exporter.targets(for: rich), [.previewPDF, .previewPNG],
                       "a document the viewer shows, with no source to list")

        let picture = Note(id: UUID(), fileURL: exampleURL("Picture.png"), untitledName: nil,
                           text: "", attributes: [:], assets: nil, kind: .image)
        let document = Note(id: UUID(), fileURL: exampleURL("Demo.pdf"), untitledName: nil,
                            text: "", attributes: [:], assets: nil, kind: .pdf)
        let book = Note(id: UUID(), fileURL: exampleURL("Book.epub"), untitledName: nil,
                        text: "", attributes: [:], assets: nil, kind: .epub)

        XCTAssertFalse(Exporter.targets(for: picture).contains(.previewPNG),
                       "a picture tab is a picture already")
        XCTAssertFalse(Exporter.targets(for: picture).contains(.editorPNG))
        XCTAssertFalse(Exporter.targets(for: document).contains(.previewPNG))
        XCTAssertFalse(Exporter.targets(for: document).contains(.editorPNG))
        XCTAssertFalse(Exporter.targets(for: book).contains(.previewPNG))
        XCTAssertFalse(Exporter.targets(for: book).contains(.editorPNG))
    }

    func testBothPicturesAreNamedPNG() {
        XCTAssertEqual(ExportTarget.previewPNG.fileExtension, "png")
        XCTAssertEqual(ExportTarget.editorPNG.fileExtension, "png")
    }

    /// The written file is a picture, so the tab it opens in beside the
    /// source is the picture viewer.
    @MainActor
    func testAWrittenPictureOpensAsAPictureTab() throws {
        let directory = try makeTemporaryDirectory()
        let note = try makeNote(named: "notes.md", text: "# Title\n", in: directory)
        let destination = directory.appendingPathComponent("notes.png")
        try export(note, to: .previewPNG, at: destination, context: context())
        XCTAssertTrue(Note.isImageFile(destination))
    }

    // MARK: - The picture itself

    /// As wide as it was asked for, times the scale it was drawn at, with the
    /// pane's own margin on each side.
    @MainActor
    func testThePictureIsTheMeasureItWasAskedForAtTheScaleItChose() throws {
        let directory = try makeTemporaryDirectory()
        let note = try makeNote(named: "notes.md", text: "# Title\n\nSome prose.\n", in: directory)
        let destination = directory.appendingPathComponent("notes.png")

        try export(note, to: .previewPNG, at: destination, context: context(width: 400))

        let bitmap = try read(destination)
        XCTAssertEqual(CGFloat(bitmap.pixelsWide), expectedWidth(400, scale: 2), accuracy: 1,
                       "a short note fits inside the ceiling, so it is drawn at 2x")
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
    }

    /// More paragraphs, a taller picture: the whole document is in it, not a
    /// page of it.
    @MainActor
    func testMoreParagraphsMakeATallerPicture() throws {
        let directory = try makeTemporaryDirectory()
        let short = try makeNote(
            named: "short.md", text: "One paragraph of prose.\n", in: directory
        )
        let long = try makeNote(
            named: "long.md",
            text: (1...40).map { "Paragraph \($0) of a note that keeps going.\n\n" }.joined(),
            in: directory
        )
        let first = directory.appendingPathComponent("short.png")
        let second = directory.appendingPathComponent("long.png")

        try export(short, to: .previewPNG, at: first, context: context(width: 400))
        try export(long, to: .previewPNG, at: second, context: context(width: 400))

        let shortImage = try read(first)
        let longImage = try read(second)
        XCTAssertEqual(shortImage.pixelsWide, longImage.pixelsWide, "the same measure")
        XCTAssertGreaterThan(longImage.pixelsHigh, shortImage.pixelsHigh * 4,
                             "forty paragraphs are far taller than one")
    }

    /// The picture is the screen, so the ground is the pane's own background
    /// in the appearance the reader is in — dark in a dark window, light in a
    /// light one. Read at a corner, which no text ever reaches.
    @MainActor
    func testTheGroundIsTheAppearanceTheReaderIsIn() throws {
        let directory = try makeTemporaryDirectory()
        let note = try makeNote(named: "notes.md", text: "# Title\n", in: directory)

        let light = directory.appendingPathComponent("light.png")
        let dark = directory.appendingPathComponent("dark.png")
        try export(note, to: .previewPNG, at: light,
                   context: context(width: 400, appearance: .aqua))
        try export(note, to: .previewPNG, at: dark,
                   context: context(width: 400, appearance: .darkAqua))

        let lightCorner = try XCTUnwrap(try read(light).colorAt(x: 1, y: 1)?
            .usingColorSpace(.sRGB))
        let darkCorner = try XCTUnwrap(try read(dark).colorAt(x: 1, y: 1)?
            .usingColorSpace(.sRGB))
        XCTAssertGreaterThan(lightCorner.brightnessComponent, 0.8, "a light pane's paper")
        XCTAssertLessThan(darkCorner.brightnessComponent, 0.3, "a dark pane's ground")
        XCTAssertGreaterThan(lightCorner.alphaComponent, 0.9, "the ground is painted, not empty")
        XCTAssertGreaterThan(darkCorner.alphaComponent, 0.9)
    }

    /// A formula is drawn at snapshot time under the picture's own
    /// appearance, so dark mode's maths is light ink rather than the black a
    /// page would have wanted.
    @MainActor
    func testAFormulaFollowsThePicturesAppearance() throws {
        let directory = try makeTemporaryDirectory()
        let note = try makeNote(named: "maths.md", text: "$$\\frac{1}{2}$$\n", in: directory)

        let light = directory.appendingPathComponent("light.png")
        let dark = directory.appendingPathComponent("dark.png")
        try export(note, to: .previewPNG, at: light,
                   context: context(width: 400, appearance: .aqua))
        try export(note, to: .previewPNG, at: dark,
                   context: context(width: 400, appearance: .darkAqua))

        XCTAssertLessThan(try darkestInk(in: read(light)), 0.25,
                          "a light picture's ink is nearly black")
        XCTAssertGreaterThan(try brightestInk(in: read(dark)), 0.6,
                             "a dark picture's ink is nearly white")
    }

    // MARK: - The editor's own listing

    /// The gutter is drawn as part of the listing rather than as a ruler
    /// beside it: a three-line note photographed with the numbers on carries
    /// three glyphs of ink nobody typed, and its text has moved right to make
    /// the column for them.
    @MainActor
    func testAPictureOfTheEditorDrawsItsGutterNumbers() throws {
        let directory = try makeTemporaryDirectory()
        let note = try makeNote(
            named: "log.txt", text: "alpha\nbeta\ngamma\n", in: directory
        )
        let numbered = directory.appendingPathComponent("numbered.png")
        let bare = directory.appendingPathComponent("bare.png")

        try export(note, to: .editorPNG, at: numbered,
                   context: context(width: 400, showsLineNumbers: true))
        try export(note, to: .editorPNG, at: bare,
                   context: context(width: 400, showsLineNumbers: false))

        let withGutter = try read(numbered)
        let without = try read(bare)
        XCTAssertGreaterThan(inkedPixels(in: withGutter), inkedPixels(in: without),
                             "three numbers is three glyphs of ink nobody typed")
        XCTAssertGreaterThan(
            try leftmostInkColumn(in: withGutter), try leftmostInkColumn(in: without),
            "the numbers hold a column of their own and the text starts past it"
        )
    }

    /// A picture has no pages, so there is nowhere to gather plates onto and
    /// nothing to turn to — which is why the sheet keeps its Images row for
    /// the listing on paper alone.
    @MainActor
    func testTheImagesRowIsNotOfferedForAPicture() {
        let dialog = ExportDialog(
            targets: [.previewPDF, .editorPDF, .previewPNG, .editorPNG], images: .plates
        )
        dialog.choose(.editorPDF)
        XCTAssertTrue(dialog.isImagesRowShown, "the listing on paper is asked")
        dialog.choose(.editorPNG)
        XCTAssertFalse(dialog.isImagesRowShown, "a picture is not")
        dialog.choose(.previewPNG)
        XCTAssertFalse(dialog.isImagesRowShown)
    }

    /// And the answer is ignored where it is not asked: the same note comes
    /// out the same height either way round.
    @MainActor
    func testPlatesAreNeverGatheredInAPicture() throws {
        let directory = try makeTemporaryDirectory()
        let note = try makeNote(named: "log.txt", text: "alpha\nbeta\n", in: directory)
        let inline = directory.appendingPathComponent("inline.png")
        let plates = directory.appendingPathComponent("plates.png")

        try export(note, to: .editorPNG, at: inline, context: context(width: 400))
        try export(note, to: .editorPNG, at: plates,
                   context: context(width: 400, images: .plates))

        XCTAssertEqual(try read(inline).pixelsHigh, try read(plates).pixelsHigh)
    }

    // MARK: - Too long

    /// Past the height a single picture may be, the export refuses rather
    /// than writing a file nothing can open.
    @MainActor
    func testANoteTallerThanAnyPictureIsRefused() throws {
        let directory = try makeTemporaryDirectory()
        let destination = directory.appendingPathComponent("tall.png")
        let tall = NSAttributedString(
            string: String(repeating: "A\n", count: 400),
            attributes: [.font: NSFont.systemFont(ofSize: 100)]
        )
        XCTAssertThrowsError(
            try SnapshotPNG.write(
                text: tall, width: 400, appearance: NSAppearance(named: .aqua),
                background: .white, to: destination
            )
        ) { error in
            XCTAssertEqual(error as? Exporter.Failure, .tooLongForAnImage)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                       "nothing is left behind by a refusal")
    }

    /// The scale is read off the long side: Retina while the picture still
    /// opens, one to one once 2x would pass the ceiling.
    func testTheScaleDropsToOneWhereRetinaWouldNotOpen() {
        XCTAssertEqual(SnapshotPNG.scale(for: NSSize(width: 400, height: 800)), 2)
        XCTAssertEqual(SnapshotPNG.scale(for: NSSize(width: 400, height: 8_191)), 2)
        XCTAssertEqual(SnapshotPNG.scale(for: NSSize(width: 400, height: 8_193)), 1)
    }

    // MARK: - Helpers

    @MainActor
    private func export(
        _ note: Note, to target: ExportTarget, at url: URL, context: Exporter.Context
    ) throws {
        var outcome: Result<Void, Error>?
        Exporter.export(note, to: target, at: url, context: context) { outcome = $0 }
        try XCTUnwrap(outcome, "the picture never answered").get()
    }

    private func read(_ url: URL) throws -> NSBitmapImageRep {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(NSBitmapImageRep(data: data), "not a readable PNG")
    }

    /// What the file should measure across: the text's own width plus the
    /// pane's margin on each side, in pixels.
    private func expectedWidth(_ width: CGFloat, scale: CGFloat) -> CGFloat {
        (width + SnapshotPNG.horizontalInset * 2) * scale
    }

    /// Every pixel that is not the ground: the ink, read against the corner
    /// the pane painted and nothing else.
    private func inkedPixels(in bitmap: NSBitmapImageRep) -> Int {
        var inked = 0
        forEachInkedPixel(in: bitmap) { _, _ in inked += 1 }
        return inked
    }

    /// The leftmost column any ink reached — where a line actually starts,
    /// gutter and all.
    private func leftmostInkColumn(in bitmap: NSBitmapImageRep) throws -> Int {
        var leftmost = bitmap.pixelsWide
        forEachInkedPixel(in: bitmap) { x, _ in leftmost = min(leftmost, x) }
        XCTAssertLessThan(leftmost, bitmap.pixelsWide, "the picture is blank")
        return leftmost
    }

    private func forEachInkedPixel(in bitmap: NSBitmapImageRep, _ body: (Int, Int) -> Void) {
        guard let ground = bitmap.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB) else { return }
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    continue
                }
                if abs(colour.brightnessComponent - ground.brightnessComponent) > 0.08 {
                    body(x, y)
                }
            }
        }
    }

    private func brightestInk(in bitmap: NSBitmapImageRep) -> CGFloat {
        var brightest: CGFloat = 0
        forEachPixel(in: bitmap) { brightest = max(brightest, $0.brightnessComponent) }
        return brightest
    }

    private func darkestInk(in bitmap: NSBitmapImageRep) -> CGFloat {
        var darkest: CGFloat = 1
        forEachPixel(in: bitmap) { darkest = min(darkest, $0.brightnessComponent) }
        return darkest
    }

    private func forEachPixel(in bitmap: NSBitmapImageRep, _ body: (NSColor) -> Void) {
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      colour.alphaComponent > 0.5 else { continue }
                body(colour)
            }
        }
    }

    @MainActor
    private func makeNote(
        named name: String, text: String, in directory: URL
    ) throws -> Note {
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return Note(
            id: UUID(), fileURL: url, untitledName: nil, text: text,
            attributes: [.font: font, .foregroundColor: NSColor.textColor],
            assets: nil
        )
    }

    private var font: NSFont { .monospacedSystemFont(ofSize: 11, weight: .regular) }

    /// The window is the appearance a picture resolves under, so the suite
    /// hands the export one rather than leaving it to whatever the test
    /// process happens to be in.
    private func context(
        width: CGFloat = 400,
        appearance: NSAppearance.Name = .aqua,
        images: ExportImagePlacement = .inline,
        showsLineNumbers: Bool = false
    ) -> Exporter.Context {
        var context = Exporter.Context(
            font: font,
            paragraphStyle: NSParagraphStyle.default,
            assets: nil,
            showsLineNumbers: showsLineNumbers,
            images: images,
            width: width
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.appearance = NSAppearance(named: appearance)
        context.window = window
        return context
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
            .appendingPathComponent("NotaSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
