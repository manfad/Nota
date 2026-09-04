import AppKit
import XCTest
@testable import Nota

/// The line table: it has to agree with the walk it replaces, on any text and
/// after any edit, and it has to build fast enough that a 100 MB log opens.
final class LineIndexTests: XCTestCase {
    private let samples = [
        "",
        "one line",
        "two\nlines",
        "trailing\n",
        "\n",
        "\n\n\n",
        "windows\r\nlines\r\n",
        "emoji 👋 and a line\nand another 🎉\n",
        "a\nb\nc\nd\ne",
    ]

    // MARK: Building

    func testLineCountMatchesTextStats() {
        for sample in samples {
            let index = LineIndex(sample as NSString)
            XCTAssertEqual(
                index.lineCount, TextStats.lineCount(sample),
                "line count of \(sample.debugDescription)"
            )
        }
    }

    func testCursorPositionMatchesTheWalk() {
        for sample in samples {
            let text = sample as NSString
            let index = LineIndex(text)
            // Every caret the text has, and one past each end for good measure.
            for location in -1...(text.length + 1) {
                let walked = TextStats.cursorPosition(in: text, at: location)
                let looked = TextStats.cursorPosition(in: text, at: location, using: index)
                XCTAssertEqual(
                    looked.line, walked.line,
                    "line at \(location) of \(sample.debugDescription)"
                )
                XCTAssertEqual(
                    looked.column, walked.column,
                    "column at \(location) of \(sample.debugDescription)"
                )
            }
        }
    }

    func testLineStartsAndRanges() {
        let text = "one\ntwo\n\nfour" as NSString
        let index = LineIndex(text)
        XCTAssertEqual(index.lineCount, 4)
        XCTAssertEqual(index.starts, [0, 4, 8, 9])
        XCTAssertEqual(index.lineStart(ofLine: 1), 0)
        XCTAssertEqual(index.lineStart(ofLine: 4), 9)
        // Out of range either way names the nearest line rather than trapping.
        XCTAssertEqual(index.lineStart(ofLine: 0), 0)
        XCTAssertEqual(index.lineStart(ofLine: 99), 9)

        for line in 1...4 {
            XCTAssertEqual(
                index.range(ofLine: line),
                text.lineRange(for: NSRange(location: index.lineStart(ofLine: line), length: 0)),
                "range of line \(line)"
            )
        }
    }

    func testEmptyTextIsOneLine() {
        let index = LineIndex()
        XCTAssertEqual(index.lineCount, 1)
        XCTAssertEqual(index.lineNumber(at: 0), 1)
        XCTAssertEqual(index.range(ofLine: 1), NSRange(location: 0, length: 0))
        XCTAssertEqual(index, LineIndex("" as NSString))
    }

    // MARK: Keeping up with edits

    func testSingleEditsAgreeWithARebuild() {
        // Insert, delete and replace, at the top, in the middle and at the end.
        let edits: [(String, NSRange, String)] = [
            ("one\ntwo\nthree", NSRange(location: 0, length: 0), "zero\n"),
            ("one\ntwo\nthree", NSRange(location: 4, length: 0), "1.5\n"),
            ("one\ntwo\nthree", NSRange(location: 13, length: 0), "\nfour"),
            ("one\ntwo\nthree", NSRange(location: 3, length: 1), ""),
            ("one\ntwo\nthree", NSRange(location: 0, length: 8), ""),
            ("one\ntwo\nthree", NSRange(location: 0, length: 13), "a\nb\nc\nd\n"),
            ("one\ntwo\nthree", NSRange(location: 4, length: 3), "TWO\nAND\nA HALF"),
            ("one\ntwo\nthree", NSRange(location: 8, length: 5), ""),
            ("", NSRange(location: 0, length: 0), "\n\n\n"),
            ("\n\n\n", NSRange(location: 0, length: 3), ""),
        ]
        for (before, range, replacement) in edits {
            let after = NSMutableString(string: before)
            after.replaceCharacters(in: range, with: replacement)
            // The same three facts a text storage hands out while it is
            // processing the edit: the range the new text now occupies, how
            // much longer everything got, and the text as it now stands.
            let inserted = (replacement as NSString).length
            var index = LineIndex(before as NSString)
            index.apply(
                editedRange: NSRange(location: range.location, length: inserted),
                changeInLength: inserted - range.length,
                in: after
            )
            XCTAssertEqual(
                index, LineIndex(after),
                "\(before.debugDescription) \(range) -> \(replacement.debugDescription)"
            )
        }
    }

    /// Typing: one character after another in the same place, which is the
    /// case the table keeps a shift on hand for. Nothing is settled between
    /// keystrokes, so this is the path a rebuild has to agree with most.
    func testTypingInOnePlaceAgreesWithARebuild() {
        let storage = NSTextStorage(attributedString: NSAttributedString(
            string: String(repeating: "a line of text\n", count: 200)
        ))
        var index = LineIndex(storage.mutableString)
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: storage, queue: nil
        ) { notification in
            guard let edited = notification.object as? NSTextStorage,
                  edited.editedMask.contains(.editedCharacters)
            else { return }
            index.apply(
                editedRange: edited.editedRange,
                changeInLength: edited.changeInLength,
                in: edited.mutableString
            )
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // Type a line in the middle, newline and all, then take half of it
        // back out the way backspace does.
        var caret = storage.length / 2
        for character in "hello\nthere\n" {
            storage.replaceCharacters(
                in: NSRange(location: caret, length: 0), with: String(character)
            )
            caret += 1
            XCTAssertEqual(index, LineIndex(storage.mutableString))
        }
        for _ in 0..<6 {
            storage.replaceCharacters(in: NSRange(location: caret - 1, length: 1), with: "")
            caret -= 1
            XCTAssertEqual(index, LineIndex(storage.mutableString))
        }
        XCTAssertEqual(index.lineCount, TextStats.lineCount(storage.string))
    }

    /// A few hundred random edits through a real text storage, checked against
    /// a rebuild after every one — the same three facts the note listens for,
    /// arriving the same way.
    func testFuzzedEditsAgreeWithARebuild() {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("ab \n\nc\td\n")
        func randomText(upTo limit: Int) -> String {
            String((0..<Int.random(in: 0...limit, using: &generator)).map { _ in
                alphabet.randomElement(using: &generator)!
            })
        }

        let storage = NSTextStorage(attributedString: NSAttributedString(
            string: randomText(upTo: 200)
        ))
        var index = LineIndex(storage.string as NSString)

        let observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: storage, queue: nil
        ) { notification in
            guard let edited = notification.object as? NSTextStorage,
                  edited.editedMask.contains(.editedCharacters)
            else { return }
            index.apply(
                editedRange: edited.editedRange,
                changeInLength: edited.changeInLength,
                in: edited.string as NSString
            )
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        for step in 0..<400 {
            let length = storage.length
            let location = Int.random(in: 0...length, using: &generator)
            let removed = Int.random(in: 0...(length - location), using: &generator)
            let inserted = randomText(upTo: 12)
            storage.replaceCharacters(
                in: NSRange(location: location, length: removed), with: inserted
            )
            XCTAssertEqual(
                index, LineIndex(storage.string as NSString),
                "step \(step): {\(location), \(removed)} -> \(inserted.debugDescription)"
            )
            XCTAssertEqual(index.lineCount, TextStats.lineCount(storage.string), "step \(step)")
            if index != LineIndex(storage.string as NSString) { return }
        }
    }

    // MARK: Speed

    /// The whole point: indexing a file the size of a log has to be a scan,
    /// not a walk. Roughly a million lines and 20 MB of text; the bound is
    /// generous — a machine under load still clears it, a `character(at:)`
    /// walk never would.
    func testIndexingAMillionLinesIsFast() {
        let line = String(repeating: "x", count: 19) + "\n"
        let text = String(repeating: line, count: 1_000_000) as NSString
        XCTAssertEqual(text.length, 20_000_000)

        let started = Date()
        let index = LineIndex(text)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(index.lineCount, 1_000_001)
        XCTAssertEqual(index.lineNumber(at: 10_000_000), 500_001)
        XCTAssertLessThan(elapsed, 2, "indexing 20 MB took \(elapsed)s")
    }
}
