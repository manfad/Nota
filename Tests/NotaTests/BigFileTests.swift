import AppKit
import XCTest
@testable import Nota

/// What has to hold for a `.log` or a `.csv` the size of a small library: the
/// note keeps its own line table current, the counts that used to walk the
/// whole file no longer do, and the token machinery leaves a text with no
/// tokens in it alone.
final class BigFileTests: XCTestCase {
    // MARK: - The note's line table

    func testNoteBuildsItsLineTable() {
        let note = makeNote("one\ntwo\nthree\n")
        XCTAssertEqual(note.lineIndex.lineCount, 4)
        XCTAssertEqual(note.lineIndex.lineCount, TextStats.lineCount(note.storage.string))
    }

    func testNoteFollowsEveryEdit() {
        let note = makeNote("one\ntwo\nthree")
        let storage = note.storage

        // Typing at the caret, splitting a line, deleting a line, and putting
        // a whole paragraph in at once.
        storage.replaceCharacters(in: NSRange(location: 3, length: 0), with: "!")
        XCTAssertEqual(note.lineIndex, LineIndex(storage.string as NSString))

        storage.replaceCharacters(in: NSRange(location: 2, length: 0), with: "\n")
        XCTAssertEqual(note.lineIndex.lineCount, 4)
        XCTAssertEqual(note.lineIndex, LineIndex(storage.string as NSString))

        storage.replaceCharacters(in: NSRange(location: 0, length: 3), with: "")
        XCTAssertEqual(note.lineIndex, LineIndex(storage.string as NSString))

        storage.replaceCharacters(
            in: NSRange(location: storage.length, length: 0), with: "\nfour\nfive\n"
        )
        XCTAssertEqual(note.lineIndex, LineIndex(storage.string as NSString))
        XCTAssertEqual(note.lineIndex.lineCount, TextStats.lineCount(storage.string))

        // Attributes alone move nothing, and must not disturb the table.
        let before = note.lineIndex
        storage.addAttribute(
            .foregroundColor, value: NSColor.red,
            range: NSRange(location: 0, length: storage.length)
        )
        XCTAssertEqual(note.lineIndex, before)
    }

    func testEachNoteKeepsItsOwnTable() {
        let first = makeNote("a\nb\nc")
        let second = makeNote("only one line")
        first.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "\n\n")
        XCTAssertEqual(first.lineIndex.lineCount, 5)
        XCTAssertEqual(second.lineIndex.lineCount, 1, "the other note heard nothing")
    }

    // MARK: - Counting pictures

    func testImageCountReadsTheAttachments() throws {
        let directory = try temporaryDirectory()
        let assets = AssetStore(directory: directory)
        let first = try XCTUnwrap(assets.importImageData(pngData(), preferredExtension: "png"))
        let second = try XCTUnwrap(assets.importImageData(pngData(), preferredExtension: "png"))

        let plain = "before \(NoteText.token(for: first))\nafter \(NoteText.token(for: second))"
        let note = Note(
            fileURL: nil, untitledName: "Untitled", text: plain,
            attributes: [.font: NSFont.systemFont(ofSize: 13)], assets: assets
        )
        XCTAssertEqual(note.imageCount, 2)
        XCTAssertEqual(note.imageCount, NoteText.assetIDs(in: note.text).count)

        XCTAssertEqual(makeNote("no pictures here").imageCount, 0)
    }

    /// The claim the footer's picture count rests on: asking a big storage
    /// for its attachments is a walk over its attribute runs, not over its
    /// characters, so a log with nothing in it costs nothing.
    func testCountingPicturesInABigNoteIsCheap() {
        let note = makeNote(String(repeating: "log line with some words in it\n", count: 200_000))
        XCTAssertTrue(BigFile.isBig(length: note.storage.length))
        // The first question a text storage is asked makes it fix its
        // attributes, once, over everything it holds. That is the price of
        // opening the file; what matters is every ask after it.
        XCTAssertEqual(note.imageCount, 0)

        let started = Date()
        var counted = 0
        for _ in 0..<200 { counted += note.imageCount }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(counted, 0)
        // Two hundred of them — one per keystroke in a long typing session —
        // over in a blink, because the walk is over the attribute runs and a
        // log is one run. `enumerateAttribute` asks the same question by
        // walking the characters instead and takes some 6 ms *each* on this
        // note, which is why nothing here uses it.
        XCTAssertLessThan(elapsed, 0.05, "two hundred picture counts took \(elapsed)s")
    }

    // MARK: - The token fast paths

    func testFastPathsMatchTheSlowOnes() throws {
        let directory = try temporaryDirectory()
        let assets = AssetStore(directory: directory)
        let assetID = try XCTUnwrap(assets.importImageData(pngData(), preferredExtension: "png"))
        let token = NoteText.token(for: assetID)

        // Two texts that go down opposite sides of the substring check, and
        // one that gets as far as the check but is not a token after all.
        let withToken = "before \(token) after"
        let withoutToken = "before after — no pictures at all"
        let nearMiss = "a link: [](nota://) and ![](https://example.com/a.png)"

        XCTAssertEqual(NoteText.assetIDs(in: withToken), [assetID])
        XCTAssertEqual(NoteText.assetIDs(in: withoutToken), [])
        XCTAssertEqual(NoteText.assetIDs(in: nearMiss), [])

        XCTAssertEqual(NoteText.strippingTokens(withToken), "before  after")
        XCTAssertEqual(NoteText.strippingTokens(withoutToken), withoutToken)
        XCTAssertEqual(NoteText.strippingTokens(nearMiss), nearMiss)

        XCTAssertEqual(NoteText.placeholdingTokens(withToken), "before \u{FFFC} after")
        XCTAssertEqual(NoteText.placeholdingTokens(withoutToken), withoutToken)

        XCTAssertEqual(
            NoteText.pathTokens(withToken, assets: assets),
            "before ![Image 1](\(assets.url(for: assetID).path)) after"
        )
        XCTAssertEqual(NoteText.pathTokens(withoutToken, assets: assets), withoutToken)

        // Rendering a text with no token in it gives the same attributed
        // string the token-by-token walk gave.
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13)]
        let rendered = NoteText.render(withoutToken, attributes: attributes, assets: assets)
        XCTAssertEqual(rendered.string, withoutToken)
        XCTAssertEqual(
            rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
            NSFont.systemFont(ofSize: 13)
        )
        XCTAssertEqual(NoteText.render("", attributes: attributes, assets: assets).length, 0)

        // And round trips still hold, in both directions.
        for plain in [withToken, withoutToken, nearMiss, ""] {
            let storage = NSTextStorage(attributedString: NoteText.render(
                plain, attributes: attributes, assets: assets
            ))
            XCTAssertEqual(NoteText.serialize(storage), plain)
        }
    }

    /// `serialize` hands back the storage's own string when nothing is
    /// attached; what comes back has to be a snapshot of it rather than a
    /// window onto it, or a note would rewrite its file as it is typed.
    func testSerializedTextIsASnapshot() {
        let note = makeNote(String(repeating: "a line of text\n", count: 100))
        let text = note.text
        note.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "CHANGED\n")
        XCTAssertFalse(text.hasPrefix("CHANGED"), "the text taken before the edit is unchanged")
        XCTAssertTrue(note.text.hasPrefix("CHANGED"), "and asking again sees the edit")
    }

    // MARK: - The footer on a big file

    /// Opening a big file: the lines and the caret are right at once, because
    /// both come from the line table, and the words and characters arrive a
    /// moment later off the main thread.
    @MainActor
    func testABigFilesCountsArriveWithoutBlockingTheOpen() throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        let line = "one two three four five six seven eight nine tenx\n"
        let lines = 25_000
        let url = directory.appendingPathComponent("big.log")
        try String(repeating: line, count: lines).write(to: url, atomically: true, encoding: .utf8)

        let controller = MainWindowController(store: SessionStore(directory: directory))
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 900, height: 560))
        window.layoutIfNeeded()

        controller.open(url: url)

        XCTAssertTrue(BigFile.isBig(length: lines * line.count), "the file is a big one")
        XCTAssertEqual(controller.footerRegions.cursor.stringValue, "Ln 1, Col 1")

        // The words are counted off the main thread, so the footer says what
        // it is going to say only once that has landed.
        let expected = "\(lines * 10) words · \(lines * line.count) characters"
        let counted = expectation(description: "the counts land")
        var waited = 0.0
        func poll() {
            if controller.footerRegions.counts.stringValue == expected { return counted.fulfill() }
            waited += 0.05
            guard waited < 10 else { return counted.fulfill() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
        }
        poll()
        wait(for: [counted], timeout: 12)
        XCTAssertEqual(controller.footerRegions.counts.stringValue, expected)
    }

    /// What the window does on every keystroke and every caret move, on a
    /// note far past the threshold: none of it may be a walk over the text.
    ///
    /// Measured through the delegate rather than through typing, deliberately
    /// — what a text storage costs to edit is TextKit's business, and it is
    /// being seen to elsewhere. This is the window's own share.
    @MainActor
    func testTypingInABigNoteDoesNotTouchTheWholeText() throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("big.log")
        let text = String(repeating: "one two three four five six seven eight nine tenx\n",
                          count: 25_000)
        try text.write(to: url, atomically: true, encoding: .utf8)

        let controller = MainWindowController(store: SessionStore(directory: directory))
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 900, height: 560))
        window.layoutIfNeeded()
        controller.open(url: url)

        let content = try XCTUnwrap(window.contentView)
        let textView = try XCTUnwrap(descendant(of: content, ofType: NotaTextView.self))
        XCTAssertTrue(BigFile.isBig(length: textView.textStorage?.length ?? 0))

        let edited = Notification(name: NSText.didChangeNotification, object: textView)
        let typed = Date()
        for _ in 0..<50 { controller.textDidChange(edited) }
        let perKeystroke = Date().timeIntervalSince(typed) / 50

        let selected = Notification(name: NSTextView.didChangeSelectionNotification,
                                    object: textView)
        let moved = Date()
        for index in 0..<50 {
            textView.setSelectedRange(NSRange(location: 600_000 + index, length: 0))
            controller.textViewDidChangeSelection(selected)
        }
        let perMove = Date().timeIntervalSince(moved) / 50

        // Both are tens of microseconds with the line table in place; a single
        // walk over this note is milliseconds, and the whole of what used to
        // be here was several of them.
        XCTAssertLessThan(perKeystroke, 0.002, "a keystroke cost \(perKeystroke)s")
        XCTAssertLessThan(perMove, 0.002, "a caret move cost \(perMove)s")
    }

    private func descendant<T: NSView>(of view: NSView, ofType type: T.Type) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = descendant(of: child, ofType: type) { return match }
        }
        return nil
    }

    // MARK: - Helpers

    private func makeNote(_ text: String) -> Note {
        Note(
            fileURL: nil, untitledName: "Untitled", text: text,
            attributes: [.font: NSFont.systemFont(ofSize: 13)], assets: nil
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nota-bigfile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func pngData() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
