import AppKit
import XCTest
@testable import Nota

/// The per-kind leading icon a tab shows, in the strip and in ⌘P (SPEC
/// Todo 15).
final class FileKindIconTests: AppKitTestCase {

    /// The name decides the icon, and every name gets one: the set has a
    /// badge for each extension it knows, an empty one for a note with no
    /// name yet and a `?` for a kind nobody drew, so nothing falls through
    /// to an SF Symbol any more.
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
            FileKindIcon.symbolName(forTitle: "run.log"), "filetype-log",
            "a kind the old set had nothing for has its own badge now"
        )
        XCTAssertEqual(
            FileKindIcon.symbolName(forTitle: "shot.webp"), "filetype-webp",
            "so does every picture format"
        )
        XCTAssertEqual(
            FileKindIcon.symbolName(forTitle: "thing.wat"), "filetype-unknown",
            "a kind nobody drew gets the ? badge rather than a generic page"
        )
    }

    /// A spelling the set did not draw twice folds onto the one it did.
    func testAnAliasFoldsOntoTheSpellingThatWasDrawn() {
        XCTAssertEqual(FileKindIcon.symbolName(forTitle: "app.mjs"), "filetype-js")
        XCTAssertEqual(FileKindIcon.symbolName(forTitle: "paper.latex"), "filetype-tex")
        XCTAssertEqual(FileKindIcon.symbolName(forTitle: "setup.zsh"), "filetype-sh")
        XCTAssertEqual(FileKindIcon.symbolName(forTitle: "notes.mkd"), "filetype-md")
        XCTAssertEqual(FileKindIcon.symbolName(forTitle: "scan.tif"), "filetype-tiff")
        XCTAssertEqual(FileKindIcon.symbolName(forTitle: "main.cxx"), "filetype-cpp")
        XCTAssertEqual(
            FileKindIcon.symbolName(forTitle: "PAPER.TEX"), "filetype-tex",
            "the extension is read in any case"
        )
    }

    /// A note with no file has no name to go on, so it is the empty badge —
    /// which is what tells it apart from a saved file with no extension.
    func testAnUntitledNoteIsTheEmptyBadge() {
        XCTAssertEqual(FileKindIcon.untitledSymbolName, "filetype-untitled")
        XCTAssertEqual(FileKindIcon.symbolName(for: nil), "filetype-untitled")
        XCTAssertEqual(
            FileKindIcon.symbolName(for: URL(fileURLWithPath: "/tmp/notes.txt")), "filetype-txt"
        )
        XCTAssertNotEqual(
            FileKindIcon.untitledSymbolName, FileKindIcon.symbolName(forTitle: "README"),
            "nothing yet and a file with no extension are not the same icon"
        )
    }

    /// Every icon name handed back can actually be drawn: the art exists for
    /// it in both halves of the set and comes back a template image, three
    /// units wide to two high, at the size asked for.
    func testEveryIconExistsInBothHalvesOfTheSet() {
        let names = ["notes.md", "notes.txt", "README", "shot.png", "index.html", "main.swift",
                     "data.json", "rows.csv", "run.log", "db.sql", "paper.tex", "book.pdf",
                     "novel.epub", "thing.wat", "shot.webp"]
        let pointSize: CGFloat = 11
        for name in names + [""] {
            let symbol = FileKindIcon.symbolName(forTitle: name)
            XCTAssertTrue(FileKindIcon.isCustomArt(symbol), "\(name) should draw this app's art")
            for filled in [false, true] {
                let image = FileKindIcon.image(
                    named: symbol, pointSize: pointSize, filled: filled
                )
                XCTAssertNotNil(image, "\(symbol) has no \(filled ? "filled" : "outline") drawing")
                XCTAssertEqual(image?.isTemplate, true, "\(symbol) should tint like an SF Symbol")
                XCTAssertEqual(image?.size.height, 15, "11pt asks for a 15pt-high badge")
                XCTAssertEqual(image?.size.width, 23, "and the art is three units wide to two")
            }
        }
        XCTAssertNotNil(
            FileKindIcon.image(named: FileKindIcon.untitledSymbolName, pointSize: pointSize)
        )
        XCTAssertNotNil(
            FileKindIcon.image(named: FileKindIcon.unknownSymbolName, pointSize: pointSize)
        )
    }

    /// The two halves are different drawings, not the same one twice.
    func testTheFilledArtIsNotTheOutlinedArt() {
        for stem in ["md", "csv", "untitled", "unknown"] {
            XCTAssertNotEqual(
                FileKindArt.outline[stem], FileKindArt.filled[stem],
                "\(stem) should be drawn twice"
            )
        }
        XCTAssertEqual(
            Set(FileKindArt.outline.keys), Set(FileKindArt.filled.keys),
            "every stem is drawn both ways"
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
        XCTAssertEqual(
            bar.iconImagesForTesting[0]?.isTemplate, true,
            "notes.md draws this app's own art, not an SF Symbol"
        )
        XCTAssertEqual(bar.filledIconsForTesting, [false, false, false])
    }

    /// A bookmarked tab draws the same kind of icon solid — the whole mark,
    /// with nothing added to the corner.
    @MainActor
    func testABookmarkedTabDrawsTheSameKindFilled() throws {
        _ = NSApplication.shared
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 600, height: TabBarView.height))
        let items = ["notes.md", "other.md"].enumerated().map { index, title in
            TabBarItem(
                title: title, isDirty: false,
                symbolName: FileKindIcon.symbolName(forTitle: title),
                isBookmarked: index == 1
            )
        }
        bar.setItems(items, selectedIndex: 0)
        bar.layoutSubtreeIfNeeded()

        XCTAssertEqual(bar.filledIconsForTesting, [false, true])
        XCTAssertEqual(
            bar.iconSymbolNamesForTesting, ["filetype-md", "filetype-md"],
            "the kind does not change; only the drawing of it does"
        )
        XCTAssertNotEqual(
            bar.iconImagesForTesting[0], bar.iconImagesForTesting[1],
            "and the two tabs are not handed the same image"
        )
    }

    /// An untitled tab draws the empty badge, not a lettered one.
    @MainActor
    func testAnUntitledTabDrawsTheEmptyBadge() throws {
        _ = NSApplication.shared
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 600, height: TabBarView.height))
        bar.setItems(
            [TabBarItem(title: "Untitled", isDirty: false, symbolName: FileKindIcon.untitledSymbolName)],
            selectedIndex: 0
        )
        bar.layoutSubtreeIfNeeded()

        XCTAssertEqual(bar.iconSymbolNamesForTesting, ["filetype-untitled"])
        XCTAssertTrue(bar.hasFileIconForTesting(at: 0))
    }
}
