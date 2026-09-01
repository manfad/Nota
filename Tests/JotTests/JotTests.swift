import AppKit
import Foundation
import XCTest
@testable import Jot

final class JotTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    func testNextUntitledNamePicksLowestFreeNumber() {
        XCTAssertEqual(UntitledNaming.nextName(existing: []), "Untitled")
        XCTAssertEqual(UntitledNaming.nextName(existing: ["Untitled"]), "Untitled 2")
        XCTAssertEqual(
            UntitledNaming.nextName(existing: ["Untitled", "Untitled 2", "Untitled 3"]),
            "Untitled 4"
        )
        // Gaps are reused, and saved notes never block a number.
        XCTAssertEqual(
            UntitledNaming.nextName(existing: ["Untitled", "Untitled 3", "shopping"]),
            "Untitled 2"
        )
    }

    func testWordAndCharacterCounts() {
        XCTAssertEqual(TextStats.wordCount(""), 0)
        XCTAssertEqual(TextStats.characterCount(""), 0)
        XCTAssertEqual(TextStats.wordCount("  hello   world \n\n again  "), 3)
        XCTAssertEqual(TextStats.characterCount("héllo"), 5)
        XCTAssertEqual(TextStats.counts("one two"), "2 words · 7 characters")
        XCTAssertEqual(TextStats.counts("a"), "1 word · 1 character")
        XCTAssertEqual(TextStats.pointSize(13), "13 pt")
    }

    func testSuggestedFileNameFromFirstLine() {
        XCTAssertEqual(SuggestedName.from(text: ""), "Untitled")
        XCTAssertEqual(SuggestedName.from(text: "\n\n"), "Untitled")
        XCTAssertEqual(SuggestedName.from(text: "  Grocery list  \nmilk"), "Grocery list")
        XCTAssertEqual(SuggestedName.from(text: "a/b:c"), "a-b-c")
        XCTAssertEqual(SuggestedName.from(text: String(repeating: "x", count: 100)).count, 40)
    }

    func testSessionRoundTripsThroughDisk() throws {
        let directory = try makeTemporaryDirectory()
        let first = UUID()
        let second = UUID()

        let state = SessionState(
            tabs: [
                SessionTab(id: first, path: "/tmp/notes.txt", untitledName: nil,
                           isDirty: true, selection: 12),
                SessionTab(id: second, path: nil, untitledName: "Untitled 2",
                           isDirty: false, selection: 0),
            ],
            selectedTabID: second,
            fontSize: 16
        )

        do {
            let store = SessionStore(directory: directory)
            store.save(state)
            store.writeText("hello", for: first)
            store.writeText("", for: second)
        }

        let reopened = SessionStore(directory: directory)
        XCTAssertEqual(reopened.load(), state)
        XCTAssertEqual(reopened.readText(for: first), "hello")
        XCTAssertEqual(reopened.readText(for: second), "")

        // Cache files for tabs that went away are cleaned up.
        reopened.pruneCache(keeping: [first])
        XCTAssertEqual(reopened.readText(for: first), "hello")
        XCTAssertNil(reopened.readText(for: second))
    }

    func testPreferencesDefaultsAndDerivedValues() throws {
        let suite = "JotTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)

        XCTAssertEqual(preferences.fontFamily, .system)
        XCTAssertEqual(preferences.fontSize, 13)
        XCTAssertEqual(preferences.lineSpacing, .normal)
        XCTAssertEqual(preferences.padding, .normal)
        XCTAssertEqual(preferences.fontDisplayName, "System")
        // Line numbers are on unless explicitly turned off.
        XCTAssertTrue(preferences.showsLineNumbers)
        preferences.showsLineNumbers = false
        XCTAssertFalse(preferences.showsLineNumbers)
        XCTAssertFalse(Preferences(defaults: defaults).showsLineNumbers)
        preferences.showsLineNumbers = true
        XCTAssertTrue(preferences.showsLineNumbers)

        // The summon shortcut defaults to ⌥Space, is recordable, and can be
        // cleared to nothing without falling back to the default again.
        XCTAssertEqual(preferences.hotKey, .optionSpace)
        XCTAssertEqual(GlobalHotKey.Shortcut.optionSpace.displayName, "⌥Space")
        preferences.hotKey = GlobalHotKey.Shortcut(
            keyCode: 0x0B, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue
        )
        XCTAssertEqual(preferences.hotKey?.displayName, "⇧⌘B")
        XCTAssertEqual(Preferences(defaults: defaults).hotKey?.keyCode, 0x0B)
        preferences.hotKey = nil
        XCTAssertNil(preferences.hotKey)
        XCTAssertNil(Preferences(defaults: defaults).hotKey)

        // The sidebar sits on the right until told otherwise.
        XCTAssertEqual(preferences.sidebarSide, .right)
        XCTAssertEqual(SidebarSide.left.title, "Left")
        preferences.sidebarSide = .left
        XCTAssertEqual(Preferences(defaults: defaults).sidebarSide, .left)

        // The save panel remembers where you last saved.
        XCTAssertNil(preferences.lastSaveDirectory)
        preferences.lastSaveDirectory = URL(fileURLWithPath: "/tmp/notes", isDirectory: true)
        XCTAssertEqual(Preferences(defaults: defaults).lastSaveDirectory?.path, "/tmp/notes")

        XCTAssertEqual(LineSpacingOption.tight.multiple, 1.15)
        XCTAssertEqual(LineSpacingOption.relaxed.multiple, 1.5)
        XCTAssertEqual(EditorPaddingOption.compact.inset, 12)
        XCTAssertEqual(EditorPaddingOption.wide.inset, 40)

        // Sizes are clamped and rounded on the way in.
        preferences.fontSize = 200
        XCTAssertEqual(preferences.fontSize, 48)
        preferences.fontSize = 1
        XCTAssertEqual(preferences.fontSize, 9)
        preferences.fontSize = 17.4
        XCTAssertEqual(preferences.fontSize, 17)
        XCTAssertEqual(preferences.font().pointSize, 17)

        preferences.lineSpacing = .relaxed
        XCTAssertEqual(preferences.paragraphStyle().lineHeightMultiple, 1.5)

        // Picking a font switches family and name together.
        preferences.selectCustomFont(familyName: "Helvetica")
        XCTAssertEqual(preferences.fontFamily, .custom)
        XCTAssertEqual(preferences.fontDisplayName, "Helvetica")
        XCTAssertEqual(preferences.font().familyName, "Helvetica")

        // Settings survive a fresh reader over the same defaults.
        XCTAssertEqual(Preferences(defaults: defaults).fontSize, 17)
    }

    @MainActor
    func testSettingsWindowBuildsItsControls() {
        _ = NSApplication.shared
        let controller = SettingsWindowController.shared
        let window = controller.window

        XCTAssertEqual(window?.title, "Settings")
        XCTAssertFalse(window?.styleMask.contains(.resizable) ?? true)
        XCTAssertFalse(window?.isReleasedWhenClosed ?? true)

        // Four label/control rows, laid out in one grid.
        let grid = window?.contentView?.subviews.compactMap { $0 as? NSGridView }.first
        XCTAssertEqual(grid?.numberOfRows, 9)
        XCTAssertEqual(grid?.numberOfColumns, 2)

        // Font popup offers the four designs plus "Other…".
        let fontPopUp = grid?.cell(atColumnIndex: 1, rowIndex: 0).contentView as? NSPopUpButton
        XCTAssertEqual(
            fontPopUp?.itemTitles.filter { !$0.isEmpty },
            ["System", "Serif", "Rounded", "Monospaced", "Other…"]
        )

        // Row labels, right-aligned in the first column.
        let labels = (0..<8).compactMap {
            (grid?.cell(atColumnIndex: 0, rowIndex: $0).contentView as? NSTextField)?.stringValue
        }
        XCTAssertEqual(
            labels,
            ["Font", "Size", "Line spacing", "Padding", "Gutter", "Image sidebar",
             "Vim mode", "Summon"]
        )
    }

    // MARK: - Images

    func testTokenRoundTripAndEdgeCases() throws {
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let a = "aaaaaaaa-0000-0000-0000-000000000001.png"
        let b = "bbbbbbbb-0000-0000-0000-000000000002.jpg"

        // Round trip: render then serialize gives back the exact same text.
        for plain in [
            "",
            "just words",
            NoteText.token(for: a),                                   // whole note
            NoteText.token(for: a) + "after",                         // at the start
            "before" + NoteText.token(for: a),                        // at the end
            NoteText.token(for: a) + NoteText.token(for: b),          // adjacent
            "one" + NoteText.token(for: a) + "two" + NoteText.token(for: b) + "three",
            "line\n" + NoteText.token(for: a) + "\nline",
        ] {
            let rendered = NoteText.render(plain, attributes: [:], assets: assets)
            XCTAssertEqual(NoteText.serialize(rendered), plain, "round trip failed for \(plain)")
        }

        // Two adjacent tokens really are two separate attachments.
        let adjacent = NoteText.render(
            NoteText.token(for: a) + NoteText.token(for: b), attributes: [:], assets: assets
        )
        XCTAssertEqual(adjacent.length, 2)
        XCTAssertEqual(attachmentIDs(in: adjacent), [a, b])

        // Malformed tokens are ordinary text and survive untouched.
        for malformed in [
            "![](jot://",
            "![](jot://)",
            "![](jot://noextension)",
            "![](http://example.com/x.png)",
            "![alt](jot://\(a))",
            "(jot://\(a))",
        ] {
            let rendered = NoteText.render(malformed, attributes: [:], assets: assets)
            XCTAssertTrue(attachmentIDs(in: rendered).isEmpty, "should not match: \(malformed)")
            XCTAssertEqual(NoteText.serialize(rendered), malformed)
        }

        XCTAssertEqual(NoteText.assetIDs(in: "x\(NoteText.token(for: a))y"), [a])
    }

    func testSerializeMixedStorageAndCountsExcludeImages() throws {
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let id = "cccccccc-0000-0000-0000-000000000003.png"
        let plain = "hello \(NoteText.token(for: id)) world"

        // A storage built the way a Note builds one.
        let storage = NSTextStorage(
            attributedString: NoteText.render(
                plain, attributes: [.font: NSFont.systemFont(ofSize: 13)], assets: assets
            )
        )
        // One image plus the surrounding text: "hello " + U+FFFC + " world".
        XCTAssertEqual(storage.length, 13)
        XCTAssertEqual(NoteText.serialize(storage), plain)

        // Editing around the image keeps the token intact.
        storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "HI")
        XCTAssertEqual(NoteText.serialize(storage), "HI \(NoteText.token(for: id)) world")

        // Counts see through to the text only — an image is worth nothing.
        XCTAssertEqual(NoteText.strippingTokens(plain), "hello  world")
        XCTAssertEqual(TextStats.counts(NoteText.strippingTokens(plain)), "2 words · 12 characters")
        XCTAssertEqual(
            TextStats.counts(NoteText.strippingTokens(NoteText.token(for: id))),
            "0 words · 0 characters"
        )
    }

    func testPasteImageThenCopyOffersAllThreeFlavours() throws {
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let view = makeTextView(assets: assets)

        // A screenshot-style paste: raw PNG bytes on the pasteboard.
        let board = makePasteboard()
        board.clearContents()
        board.setData(makePNGData(), forType: .png)

        let chosen = view.preferredPasteboardType(
            from: board.types ?? [], restrictedToTypesFrom: view.readablePasteboardTypes
        )
        XCTAssertEqual(chosen, .png)
        XCTAssertTrue(view.readSelection(from: board, type: try XCTUnwrap(chosen)))

        // One attachment in the storage, one file in the assets dir.
        let storage = try XCTUnwrap(view.textStorage)
        let ids = attachmentIDs(in: storage)
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(storage.length, 1)
        XCTAssertEqual(try assetFileCount(assets), 1)
        XCTAssertTrue(ids[0].hasSuffix(".png"))

        // Copying it out offers Jot's own flavour, RTFD, and plain text.
        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        let types = view.writablePasteboardTypes
        XCTAssertEqual(Set(types), Set([.jotNote, .rtfd, .string]))

        let out = makePasteboard()
        out.clearContents()
        out.declareTypes(types, owner: nil)
        for type in types {
            XCTAssertTrue(view.writeSelection(to: out, type: type), "failed to write \(type)")
        }
        // AppKit also puts legacy aliases (NSStringPboardType, NeXT RTFD) on the
        // board, so check ours are present rather than that they are all there is.
        XCTAssertTrue(Set(types).isSubset(of: Set(out.types ?? [])))
        XCTAssertEqual(out.string(forType: .jotNote), NoteText.token(for: ids[0]))
        XCTAssertEqual(out.string(forType: .string), "")

        // The RTFD really carries the bytes, so other apps see an image.
        let rtfd = try XCTUnwrap(out.data(forType: .rtfd))
        let restored = try XCTUnwrap(NSAttributedString(rtfd: rtfd, documentAttributes: nil))
        var foreignAttachments = 0
        restored.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: restored.length)
        ) { value, _, _ in
            if let attachment = value as? NSTextAttachment,
               attachment.fileWrapper?.regularFileContents != nil {
                foreignAttachments += 1
            }
        }
        XCTAssertEqual(foreignAttachments, 1)

        // Jot -> Jot re-uses the asset instead of importing a second copy.
        let second = makeTextView(assets: assets)
        XCTAssertTrue(second.readSelection(from: out, type: .jotNote))
        XCTAssertEqual(attachmentIDs(in: try XCTUnwrap(second.textStorage)), ids)
        XCTAssertEqual(try assetFileCount(assets), 1)
    }

    func testMissingAssetKeepsItsTokenThroughARoundTrip() throws {
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let plain = "before \(NoteText.token(for: "missing-0000.png")) after"
        let rendered = NoteText.render(plain, attributes: [:], assets: assets)

        // Rendered as a placeholder, but still an attachment that serializes back.
        XCTAssertEqual(attachmentIDs(in: rendered), ["missing-0000.png"])
        XCTAssertEqual(NoteText.serialize(rendered), plain)
        XCTAssertEqual(try assetFileCount(assets), 0)
    }

    // MARK: - Search across tabs

    func testSearchFindsMatchesInTabOrderWithUsableRanges() {
        let notes = [
            (title: "One", text: "alpha beta\nGAMMA delta\n"),
            (title: "Two", text: "nothing here"),
            (title: "Three", text: "beta again\nand Beta once more"),
        ]

        let results = NoteSearch.matches(query: "beta", in: notes)
        XCTAssertEqual(results.map(\.tabIndex), [0, 2, 2])
        XCTAssertEqual(results.map(\.tabTitle), ["One", "Three", "Three"])

        // Every range addresses the text it came from, and the snippet range
        // covers the same characters — that is what the bolding and the
        // text-view selection both rely on.
        for match in results {
            let source = notes[match.tabIndex].text as NSString
            XCTAssertEqual(
                source.substring(with: match.rangeInText).lowercased(), "beta"
            )
            XCTAssertEqual(
                (match.snippet as NSString).substring(with: match.rangeInSnippet).lowercased(),
                "beta"
            )
        }

        // The snippet is the whole line the match sits on.
        XCTAssertEqual(results[0].snippet, "alpha beta")
        XCTAssertEqual(results[1].snippet, "beta again")
        XCTAssertEqual(results[2].snippet, "and Beta once more")
        XCTAssertEqual(results[0].rangeInText, NSRange(location: 6, length: 4))
    }

    func testSearchIsCaseInsensitiveAndIgnoresEmptyQueries() {
        let notes = [(title: "N", text: "Needle needle NEEDLE")]

        XCTAssertEqual(NoteSearch.matches(query: "needle", in: notes).count, 3)
        XCTAssertEqual(NoteSearch.matches(query: "NEEDLE", in: notes).count, 3)
        XCTAssertEqual(NoteSearch.matches(query: "NeEdLe", in: notes).count, 3)

        XCTAssertTrue(NoteSearch.matches(query: "", in: notes).isEmpty)
        XCTAssertTrue(NoteSearch.matches(query: "   ", in: notes).isEmpty)
        XCTAssertTrue(NoteSearch.matches(query: "\n", in: notes).isEmpty)
        XCTAssertTrue(NoteSearch.matches(query: "absent", in: notes).isEmpty)
        XCTAssertTrue(NoteSearch.matches(query: "x", in: []).isEmpty)

        // An image is a single object-replacement character, so a query can
        // never match "inside" a picture.
        let withImage = [(title: "N", text: "a\u{FFFC}b")]
        XCTAssertTrue(NoteSearch.matches(query: "jot", in: withImage).isEmpty)
        XCTAssertEqual(NoteSearch.matches(query: "b", in: withImage).first?.rangeInText,
                       NSRange(location: 2, length: 1))
    }

    func testSearchCapsResultsAndWindowsLongLines() {
        let many = (title: "Many", text: String(repeating: "hit ", count: 300))
        let capped = NoteSearch.matches(query: "hit", in: [many])
        XCTAssertEqual(capped.count, NoteSearch.resultLimit)
        XCTAssertEqual(capped.count, 200)

        // The cap is across all tabs, not per tab.
        let acrossTabs = NoteSearch.matches(query: "hit", in: [many, many])
        XCTAssertEqual(acrossTabs.count, 200)

        // A match far along a line is windowed so it stays visible.
        let long = (title: "Long", text: String(repeating: "x", count: 300) + "needle tail")
        let match = try? XCTUnwrap(NoteSearch.matches(query: "needle", in: [long]).first)
        let found = try? XCTUnwrap(match)
        XCTAssertTrue(found?.snippet.hasPrefix("…") ?? false)
        XCTAssertLessThan((found?.snippet as NSString?)?.length ?? .max, 160)
        XCTAssertEqual(
            ((found?.snippet ?? "") as NSString).substring(with: found?.rangeInSnippet ?? NSRange()),
            "needle"
        )
        // The text range still points at the real offset in the note.
        XCTAssertEqual(found?.rangeInText, NSRange(location: 300, length: 6))
    }

    // MARK: - Chips and sidebar

    func testSidebarOrderingFollowsDocumentOrderIncludingDuplicates() {
        let a = "aaaaaaaa-1111.png"
        let b = "bbbbbbbb-2222.jpg"
        let text = "x\(NoteText.token(for: a))y\(NoteText.token(for: b))z\(NoteText.token(for: a))"

        // The same picture used twice gets two sidebar rows, in text order.
        XCTAssertEqual(NoteText.assetIDs(in: text), [a, b, a])

        // And that list matches the chips actually rendered into the storage,
        // which is what makes "sidebar item N" mean "chip N".
        let rendered = NoteText.render(text, attributes: [:], assets: nil)
        XCTAssertEqual(attachmentIDs(in: rendered), [a, b, a])

        XCTAssertEqual(NoteText.assetIDs(in: ""), [])
        XCTAssertEqual(NoteText.assetIDs(in: "no tokens here"), [])
        XCTAssertEqual(NoteText.assetIDs(in: "![](jot://malformed"), [])
    }

    func testChipIsTextSizedAndRenumbersLive() {
        let font = NSFont.systemFont(ofSize: 13)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)

        func bounds(_ chip: JotImageAttachment, width: CGFloat = 2000) -> CGRect {
            chip.attachmentBounds(
                for: nil,
                proposedLineFragment: CGRect(x: 0, y: 0, width: width, height: 20),
                glyphPosition: .zero,
                characterIndex: 0
            )
        }

        let first = JotImageAttachment(assetID: "a.png", isMissing: false, font: font, index: 1)
        let tenth = JotImageAttachment(assetID: "b.png", isMissing: false, font: font, index: 10)
        let gone = JotImageAttachment(assetID: "c.png", isMissing: true, font: font, index: 1)

        XCTAssertEqual(first.label, "Image 1")
        XCTAssertEqual(tenth.label, "Image 10")
        XCTAssertEqual(gone.label, "Image 1 — missing")

        // Height is the line height for every chip, whatever it says.
        XCTAssertEqual(bounds(first).height, lineHeight)
        XCTAssertEqual(bounds(tenth).height, lineHeight)
        XCTAssertEqual(bounds(gone).height, lineHeight)

        // Width follows the label, so a longer number is a wider chip.
        XCTAssertGreaterThan(bounds(tenth).width, bounds(first).width)
        XCTAssertGreaterThan(bounds(gone).width, bounds(first).width)

        // Nothing depends on the line fragment: chips never go full width.
        XCTAssertEqual(bounds(first, width: 10).width, bounds(first).width)

        // Baseline-aligned like text, and taller type gives a taller chip.
        XCTAssertEqual(bounds(first).origin.y, font.descender.rounded())
        XCTAssertLessThan(bounds(first).origin.y, 0)
        let big = JotImageAttachment(
            assetID: "a.png", isMissing: false, font: .systemFont(ofSize: 24), index: 1
        )
        XCTAssertGreaterThan(bounds(big).height, lineHeight)

        // Renumbering resizes in place, and reports whether anything moved.
        let widthAsOne = bounds(first).width
        XCTAssertTrue(first.updateChip(font: font, index: 10))
        XCTAssertEqual(first.label, "Image 10")
        XCTAssertGreaterThan(bounds(first).width, widthAsOne)
        XCTAssertFalse(first.updateChip(font: font, index: 10))
    }

    func testRenderNumbersChipsInDocumentOrder() {
        let a = "aaaaaaaa-1111.png"
        let b = "bbbbbbbb-2222.jpg"
        let text = "x\(NoteText.token(for: a))y\(NoteText.token(for: b))z\(NoteText.token(for: a))"
        let rendered = NoteText.render(text, attributes: [:], assets: nil)

        var labels: [String] = []
        rendered.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: rendered.length)
        ) { value, _, _ in
            if let chip = value as? JotImageAttachment { labels.append(chip.label) }
        }
        // A repeated picture still gets its own number, by position.
        XCTAssertEqual(
            labels,
            ["Image 1 — missing", "Image 2 — missing", "Image 3 — missing"]
        )
        // Numbering is display only — it never reaches the file.
        XCTAssertEqual(NoteText.serialize(rendered), text)
    }

    func testAdjacentChipsLightOnlyOneThumbnail() {
        // Two chips side by side at 4 and 5, a third further along.
        let chips = [4, 5, 9]
        func resolve(clicked: Int? = nil, _ selection: NSRange) -> Set<Int> {
            ChipHighlight.resolve(
                clickedChipLocation: clicked, selection: selection, chipLocations: chips
            )
        }

        // The caret between the two adjacent chips belongs to the one before
        // it — this is the case that used to light both.
        XCTAssertEqual(resolve(NSRange(location: 5, length: 0)), [0])
        XCTAssertEqual(resolve(NSRange(location: 6, length: 0)), [1])
        // Sitting in front of a chip highlights nothing.
        XCTAssertEqual(resolve(NSRange(location: 4, length: 0)), [])
        XCTAssertEqual(resolve(NSRange(location: 0, length: 0)), [])

        // A click is explicit, so it wins over where the caret landed.
        XCTAssertEqual(resolve(clicked: 5, NSRange(location: 5, length: 0)), [1])
        XCTAssertEqual(resolve(clicked: 9, NSRange(location: 6, length: 0)), [2])
        // A remembered click on a chip that has since gone falls back to the
        // caret rather than highlighting nothing.
        XCTAssertEqual(resolve(clicked: 99, NSRange(location: 5, length: 0)), [0])

        // A real selection lights every chip it covers, adjacency included.
        XCTAssertEqual(resolve(NSRange(location: 4, length: 6)), [0, 1, 2])
        XCTAssertEqual(resolve(NSRange(location: 4, length: 2)), [0, 1])
        XCTAssertEqual(resolve(NSRange(location: 0, length: 5)), [0])
        XCTAssertEqual(resolve(NSRange(location: 0, length: 4)), [])

        // A note with no images never highlights anything.
        XCTAssertEqual(
            ChipHighlight.resolve(
                clickedChipLocation: nil,
                selection: NSRange(location: 3, length: 2),
                chipLocations: []
            ),
            []
        )
    }

    // MARK: - Fuzzy tab picker

    func testFuzzyMatchIsSubsequenceBasedAndRanksSensibly() {
        // Characters must appear in order, but need not be adjacent.
        XCTAssertNotNil(FuzzyMatch.match(query: "ai", in: "AI prompts"))
        XCTAssertNotNil(FuzzyMatch.match(query: "aip", in: "AI prompts"))
        XCTAssertNotNil(FuzzyMatch.match(query: "APP", in: "AI prompts"))
        XCTAssertNil(FuzzyMatch.match(query: "pa", in: "AI prompts"))
        XCTAssertNil(FuzzyMatch.match(query: "zzz", in: "AI prompts"))
        XCTAssertNil(FuzzyMatch.match(query: "toolong", in: "abc"))

        // An empty query matches everything, so ⌘P opens on the full list.
        XCTAssertEqual(FuzzyMatch.match(query: "", in: "anything")?.matchedIndices, [])

        // Matched positions come back for highlighting.
        // Greedy leftmost match, case-insensitive: the T of Think, the p of patterns.
        XCTAssertEqual(FuzzyMatch.match(query: "tp", in: "Think patterns")?.matchedIndices, [0, 6])

        let titles = ["Think different", "AI prompts", "Thoughts", "Untitled"]
        let ranked = FuzzyMatch.rank(query: "th", titles: titles)
        XCTAssertEqual(Set(ranked.map(\.index)), [0, 2])
        // "Thoughts" is shorter and starts with the query, so it wins.
        XCTAssertEqual(ranked.first?.index, 2)

        // Nothing matches -> empty list, not a crash.
        XCTAssertTrue(FuzzyMatch.rank(query: "qqqq", titles: titles).isEmpty)
        // Word-boundary initials beat a scattered match.
        let initials = FuzzyMatch.rank(query: "td", titles: ["Think different", "toad"])
        XCTAssertEqual(initials.first?.index, 0)
    }

    // MARK: - Footer

    func testFooterCountsIncludeImagesAndLines() {
        XCTAssertEqual(
            TextStats.counts("", images: 0, lines: 1),
            "0 words · 0 characters · 0 images · 1 line"
        )
        XCTAssertEqual(
            TextStats.counts("a", images: 1, lines: 1),
            "1 word · 1 character · 1 image · 1 line"
        )
        XCTAssertEqual(
            TextStats.counts("one two", images: 3, lines: 12),
            "2 words · 7 characters · 3 images · 12 lines"
        )

        // Hard lines: one per newline plus the last, empty note included.
        XCTAssertEqual(TextStats.lineCount(""), 1)
        XCTAssertEqual(TextStats.lineCount("one line"), 1)
        XCTAssertEqual(TextStats.lineCount("one\ntwo"), 2)
        // A trailing newline opens a line of its own, as the gutter shows it.
        XCTAssertEqual(TextStats.lineCount("one\n"), 2)
        XCTAssertEqual(TextStats.lineCount("\n\n"), 3)
    }

    func testCursorPositionIsOneBasedAndCountsAnImageAsOneColumn() throws {
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let id = "dddddddd-0000-0000-0000-000000000004.png"

        let plain = "one\ntwo\nthree"
        let text = plain as NSString
        XCTAssertEqual(TextStats.position(in: text, at: 0), "1:1")
        XCTAssertEqual(TextStats.position(in: text, at: 3), "1:4")
        // Just past the newline is the start of the next line.
        XCTAssertEqual(TextStats.position(in: text, at: 4), "2:1")
        XCTAssertEqual(TextStats.position(in: text, at: 7), "2:4")
        XCTAssertEqual(TextStats.position(in: text, at: 8), "3:1")
        // Out-of-range locations clamp rather than trap.
        XCTAssertEqual(TextStats.position(in: text, at: 9_999), "3:6")
        XCTAssertEqual(TextStats.position(in: text, at: -4), "1:1")
        XCTAssertEqual(TextStats.position(in: "" as NSString, at: 0), "1:1")

        // A composed character is one column, not two UTF-16 units.
        let emoji = "a👋b" as NSString
        XCTAssertEqual(TextStats.position(in: emoji, at: emoji.length), "1:4")

        // And an inline image is a single glyph, so the caret after
        // "hi <image>" sits in column 5.
        let withImage = NoteText.render(
            "line\nhi \(NoteText.token(for: id))x",
            attributes: [.font: NSFont.systemFont(ofSize: 13)],
            assets: assets
        )
        let storage = NSTextStorage(attributedString: withImage).string as NSString
        XCTAssertEqual(storage.length, 10)   // "line\nhi " + U+FFFC + "x"
        XCTAssertEqual(TextStats.position(in: storage, at: 8), "2:4")
        XCTAssertEqual(TextStats.position(in: storage, at: 9), "2:5")
        XCTAssertEqual(TextStats.position(in: storage, at: 10), "2:6")
    }

    func testVimModePreferenceIsOffUntilAskedFor() throws {
        let suite = "JotTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)

        XCTAssertFalse(preferences.vimMode)
        preferences.vimMode = true
        XCTAssertTrue(Preferences(defaults: defaults).vimMode)
        preferences.vimMode = false
        XCTAssertFalse(Preferences(defaults: defaults).vimMode)

        // The badge is monochrome and typographic: sentence-case names, and
        // one capsule everywhere but insert, which shows the bare word.
        XCTAssertEqual(VimMode.normal.badgeTitle, "Normal")
        XCTAssertEqual(VimMode.operatorPending.badgeTitle, "Normal")
        XCTAssertEqual(VimMode.insert.badgeTitle, "Insert")
        XCTAssertEqual(VimMode.visual.badgeTitle, "Visual")
        XCTAssertEqual(VimMode.visualLine.badgeTitle, "Visual Line")
        XCTAssertEqual(VimMode.replace.badgeTitle, "Replace")
        XCTAssertFalse(VimMode.insert.showsCapsule)
        for mode in [VimMode.normal, .operatorPending, .visual, .visualLine,
                     .replace, .commandLine] {
            XCTAssertTrue(mode.showsCapsule, "\(mode) should wear the capsule")
        }
    }

    @MainActor
    func testFooterLaysOutLeftCentreRightWithoutOverlapping() throws {
        _ = NSApplication.shared
        let previous = Preferences.shared.vimMode
        defer { Preferences.shared.vimMode = previous }
        Preferences.shared.vimMode = true

        let directory = try makeTemporaryDirectory()
        let controller = MainWindowController(store: SessionStore(directory: directory))
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 820, height: 560))
        window.layoutIfNeeded()

        let footer = controller.footerRegions
        XCTAssertFalse(footer.badge.isHidden, "the badge shows while vim mode is on")
        XCTAssertFalse(footer.cursor.isHidden, "the caret position is always shown")
        // Nothing has been typed, so the pending keys stay away.
        XCTAssertTrue(footer.pendingKeys.isHidden)

        // An empty note: no words, no images, one line, caret at the top.
        XCTAssertEqual(footer.counts.stringValue,
                       "0 words · 0 characters · 0 images · 1 line")
        XCTAssertEqual(footer.cursor.stringValue, "1:1")

        // Left, centre, right — in that order, with real gaps between them.
        XCTAssertEqual(footer.badge.frame.height, 18)
        XCTAssertLessThan(footer.badge.frame.maxX, footer.counts.frame.minX)
        XCTAssertLessThan(footer.counts.frame.maxX, footer.cursor.frame.minX)
        // The counts sit centred in the window.
        let content = try XCTUnwrap(window.contentView)
        let centre = footer.counts.superview.map {
            $0.convert(NSPoint(x: footer.counts.frame.midX, y: 0), to: content).x
        } ?? 0
        XCTAssertEqual(centre, content.bounds.midX, accuracy: 1)

        // All three sit on one line, inside the footer strip.
        XCTAssertEqual(footer.counts.frame.midY, footer.badge.frame.midY, accuracy: 1)
        XCTAssertEqual(footer.cursor.frame.midY, footer.badge.frame.midY, accuracy: 1)

        // Zen fades the whole footer out with the rest of the chrome, and
        // giving it back respects the vim setting rather than showing
        // everything.
        controller.toggleZenMode()
        let faded = expectation(description: "chrome finished fading out")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { faded.fulfill() }
        wait(for: [faded], timeout: 2)
        XCTAssertTrue(footer.badge.isHidden)
        XCTAssertTrue(footer.counts.isHidden)
        XCTAssertTrue(footer.cursor.isHidden)

        controller.toggleZenMode()
        XCTAssertFalse(footer.badge.isHidden)
        XCTAssertFalse(footer.cursor.isHidden)
        XCTAssertTrue(footer.pendingKeys.isHidden)

        // With vim mode off the badge goes; the counts and caret stay.
        Preferences.shared.vimMode = false
        window.layoutIfNeeded()
        XCTAssertTrue(footer.badge.isHidden)
        XCTAssertFalse(footer.counts.isHidden)
        XCTAssertFalse(footer.cursor.isHidden)
    }

    // MARK: - Zen mode

    @MainActor
    func testZenModeTogglesAndRestores() throws {
        _ = NSApplication.shared
        let directory = try makeTemporaryDirectory()
        let controller = MainWindowController(store: SessionStore(directory: directory))
        let window = try XCTUnwrap(controller.window)

        // Chrome is up, traffic lights visible, and zen is off on launch.
        XCTAssertFalse(controller.isZenMode)
        XCTAssertFalse(window.standardWindowButton(.closeButton)?.isHidden ?? true)

        controller.toggleZenMode()
        XCTAssertTrue(controller.isZenMode)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertTrue(
                window.standardWindowButton(button)?.isHidden ?? false,
                "\(button) should be hidden in zen"
            )
        }

        controller.toggleZenMode()
        XCTAssertFalse(controller.isZenMode)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertFalse(
                window.standardWindowButton(button)?.isHidden ?? true,
                "\(button) should come back"
            )
        }

        // The split view survives the round trip intact.
        XCTAssertEqual(
            (window.contentViewController as? NSSplitViewController)?.splitViewItems.count, 2
        )
    }

    // MARK: - Helpers

    private func solidImage(_ width: Int, _ height: Int) -> NSImage {
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemGreen.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }


    private func attachmentIDs(in attributed: NSAttributedString) -> [String] {
        var ids: [String] = []
        attributed.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: attributed.length)
        ) { value, _, _ in
            if let attachment = value as? JotImageAttachment { ids.append(attachment.assetID) }
        }
        return ids
    }

    private func assetFileCount(_ assets: AssetStore) throws -> Int {
        try FileManager.default
            .contentsOfDirectory(atPath: assets.directory.path)
            .filter { !$0.hasPrefix(".") }
            .count
    }

    /// A private pasteboard, so running the tests never disturbs whatever the
    /// person at the keyboard has on their real clipboard.
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("JotTests-\(UUID().uuidString)"))
    }

    private func makePNGData() -> Data {
        let size = NSSize(width: 6, height: 4)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }

    private func makeTextView(assets: AssetStore) -> JotTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        let view = JotTextView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container
        )
        view.isRichText = false
        view.isEditable = true
        view.assets = assets
        view.attributesProvider = { [.font: NSFont.systemFont(ofSize: 13)] }
        return view
    }


    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
