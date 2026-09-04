import AppKit
import XCTest
@testable import Nota

/// The per-kind leading icon a tab shows, in the strip and in ⌘P (SPEC
/// Todo 15).
final class FileKindIconTests: XCTestCase {

    /// The name decides the icon. Most kinds draw this app's own art, named
    /// `"filetype-<stem>"`; a kind the set has no art for still falls back
    /// to an SF Symbol, and a couple of those name an older spelling behind
    /// their preferred symbol, so those are asserted as either.
    func testTheExtensionPicksTheIcon() {
        XCTAssertEqual(FileKindIcon.symbolName(forTitle: "notes.md"), "filetype-md")
        XCTAssertEqual(FileKindIcon.symbolName(forTitle: "notes.txt"), "filetype-txt")
        XCTAssertEqual(
            FileKindIcon.symbolName(forTitle: "README"), "filetype-txt",
            "no extension reads as plain text"
        )
        XCTAssertEqual(FileKindIcon.symbolName(forTitle: "shot.png"), "filetype-png")
        XCTAssertEqual(FileKindIcon.symbolName(forTitle: "index.html"), "filetype-html")
        XCTAssertEqual(FileKindIcon.symbolName(forTitle: "main.swift"), "filetype-swift")
        XCTAssertEqual(FileKindIcon.symbolName(forTitle: "data.json"), "filetype-json")
        XCTAssertEqual(FileKindIcon.symbolName(forTitle: "rows.csv"), "filetype-csv")
        XCTAssertEqual(FileKindIcon.symbolName(forTitle: "db.sql"), "filetype-sql")
        XCTAssertEqual(FileKindIcon.symbolName(forTitle: "paper.tex"), "filetype-tex")
        XCTAssertEqual(FileKindIcon.symbolName(forTitle: "book.pdf"), "filetype-pdf")
        XCTAssertEqual(
            FileKindIcon.symbolName(forTitle: "novel.epub"), "filetype-epub",
            "a book, the third kind Nota views rather than edits"
        )
        XCTAssertEqual(
            FileKindIcon.symbolName(forTitle: "run.log"), "list.bullet.rectangle",
            "a kind the art set has nothing for keeps its SF Symbol"
        )
        XCTAssertTrue(
            ["text.page", "doc"].contains(FileKindIcon.symbolName(forTitle: "thing.wat")),
            "a kind nobody named keeps the old generic page"
        )
        XCTAssertEqual(
            FileKindIcon.symbolName(forTitle: "shot.webp"), "photo",
            "a photo format the art set has no drawing for keeps its SF Symbol"
        )
    }

    /// A note with no file has no name to go on, so it is the plain `doc` —
    /// which is what tells it apart from a saved file with no extension.
    func testAnUntitledNoteIsAPlainDoc() {
        XCTAssertEqual(FileKindIcon.untitledSymbolName, "doc")
        XCTAssertEqual(FileKindIcon.symbolName(for: nil), "doc")
        XCTAssertEqual(
            FileKindIcon.symbolName(for: URL(fileURLWithPath: "/tmp/notes.txt")), "filetype-txt"
        )
    }

    /// Every icon name handed back can actually be drawn: the custom art
    /// exists for every `"filetype-*"` name and comes back a template image
    /// at the requested size, and every SF Symbol fallback is one this
    /// system actually has — the point of the fallback chains, since a
    /// missing symbol draws nothing.
    func testEveryIconExistsOnThisSystem() {
        let names = ["notes.md", "notes.txt", "README", "shot.png", "index.html", "main.swift",
                     "data.json", "rows.csv", "run.log", "db.sql", "paper.tex", "book.pdf",
                     "novel.epub", "thing.wat"]
        let pointSize: CGFloat = 16
        for name in names + [""] {
            let symbol = FileKindIcon.symbolName(forTitle: name)
            let image = FileKindIcon.image(named: symbol, pointSize: pointSize)
            XCTAssertNotNil(
                image, "\(name) asked for \(symbol), which this system does not have"
            )
            if symbol.hasPrefix("filetype-") {
                XCTAssertEqual(image?.isTemplate, true, "\(symbol) should tint like an SF Symbol")
                XCTAssertEqual(image?.size.width, image?.size.height, "square, whatever the size")
            }
        }
        XCTAssertNotNil(
            FileKindIcon.image(named: FileKindIcon.untitledSymbolName, pointSize: pointSize)
        )
    }

    /// The strip draws whatever kind each tab says it is, not one symbol for
    /// all of them, and a kind with custom art draws that art rather than an
    /// SF Symbol.
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
        XCTAssertEqual(
            bar.iconImagesForTesting[0]?.isTemplate, true,
            "notes.md draws this app's own art, not an SF Symbol"
        )
    }

    /// An untitled tab still draws the plain `doc` SF Symbol, not custom art.
    @MainActor
    func testAnUntitledTabStillDrawsThePlainDocSymbol() throws {
        _ = NSApplication.shared
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 600, height: TabBarView.height))
        bar.setItems(
            [TabBarItem(title: "Untitled", isDirty: false, symbolName: FileKindIcon.untitledSymbolName)],
            selectedIndex: 0
        )
        bar.layoutSubtreeIfNeeded()

        XCTAssertEqual(bar.iconSymbolNamesForTesting, ["doc"])
        XCTAssertTrue(bar.hasFileIconForTesting(at: 0))
    }
}
