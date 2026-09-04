import AppKit
import XCTest
@testable import Nota

/// The per-kind leading icon a tab shows, in the strip and in ⌘P (SPEC
/// Todo 15).
final class FileKindIconTests: XCTestCase {

    /// The name decides the symbol. A couple of kinds name an older spelling
    /// behind their preferred symbol, so those are asserted as either.
    func testTheExtensionPicksTheSymbol() {
        XCTAssertTrue(
            ["text.document", "doc.text"].contains(FileKindIcon.symbolName(forTitle: "notes.md")),
            "Markdown, however this system spells it"
        )
        XCTAssertEqual(FileKindIcon.symbolName(forTitle: "notes.txt"), "doc.plaintext")
        XCTAssertEqual(
            FileKindIcon.symbolName(forTitle: "README"), "doc.plaintext",
            "no extension reads as plain text"
        )
        XCTAssertEqual(FileKindIcon.symbolName(forTitle: "shot.png"), "photo")
        XCTAssertEqual(FileKindIcon.symbolName(forTitle: "index.html"), "globe")
        XCTAssertEqual(FileKindIcon.symbolName(forTitle: "main.swift"),
                       "chevron.left.forwardslash.chevron.right")
        XCTAssertEqual(FileKindIcon.symbolName(forTitle: "data.json"), "curlybraces")
        XCTAssertEqual(FileKindIcon.symbolName(forTitle: "rows.csv"), "tablecells")
        XCTAssertEqual(FileKindIcon.symbolName(forTitle: "run.log"), "list.bullet.rectangle")
        XCTAssertEqual(FileKindIcon.symbolName(forTitle: "db.sql"), "cylinder")
        XCTAssertTrue(
            ["function", "x.squareroot"].contains(FileKindIcon.symbolName(forTitle: "paper.tex"))
        )
        XCTAssertTrue(
            ["doc.richtext", "doc.fill"].contains(FileKindIcon.symbolName(forTitle: "book.pdf"))
        )
        XCTAssertTrue(
            ["text.page", "doc"].contains(FileKindIcon.symbolName(forTitle: "thing.wat")),
            "a kind nobody named keeps the old generic page"
        )
    }

    /// A note with no file has no name to go on, so it is the plain `doc` —
    /// which is what tells it apart from a saved file with no extension.
    func testAnUntitledNoteIsAPlainDoc() {
        XCTAssertEqual(FileKindIcon.untitledSymbolName, "doc")
        XCTAssertEqual(FileKindIcon.symbolName(for: nil), "doc")
        XCTAssertEqual(
            FileKindIcon.symbolName(for: URL(fileURLWithPath: "/tmp/notes.txt")), "doc.plaintext"
        )
    }

    /// Every symbol handed back is one this system can actually draw —
    /// the point of the fallbacks, since a missing symbol draws nothing.
    func testEverySymbolExistsOnThisSystem() {
        let names = ["notes.md", "notes.txt", "README", "shot.png", "index.html", "main.swift",
                     "data.json", "rows.csv", "run.log", "db.sql", "paper.tex", "book.pdf",
                     "thing.wat"]
        for name in names + [""] {
            let symbol = FileKindIcon.symbolName(forTitle: name)
            XCTAssertNotNil(
                NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
                "\(name) asked for \(symbol), which this system does not have"
            )
        }
        XCTAssertNotNil(
            NSImage(systemSymbolName: FileKindIcon.untitledSymbolName, accessibilityDescription: nil)
        )
    }

    /// The strip draws whatever kind each tab says it is, not one symbol for
    /// all of them.
    @MainActor
    func testTheStripDrawsEachTabsOwnKind() throws {
        _ = NSApplication.shared
        let titles = ["notes.md", "shot.png", "main.swift"]
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 600, height: TabBarView.height))
        bar.setItems(
            titles.map {
                TabBarItem(title: $0, isDirty: false,
                           symbolName: FileKindIcon.symbolName(forTitle: $0))
            },
            selectedIndex: 0
        )
        bar.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            bar.iconSymbolNamesForTesting,
            titles.map { FileKindIcon.symbolName(forTitle: $0) }
        )
        XCTAssertNotEqual(
            bar.iconSymbolNamesForTesting[0], bar.iconSymbolNamesForTesting[1],
            "a picture and a Markdown file no longer look the same"
        )
        for index in titles.indices {
            XCTAssertTrue(bar.hasFileIconForTesting(at: index))
        }
    }
}
