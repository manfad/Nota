import AppKit
import Foundation
import XCTest
@testable import Nota

final class NotaTests: XCTestCase {
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
        let suite = "NotaTests-\(UUID().uuidString)"
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

        // Long lines fold until you say otherwise.
        XCTAssertTrue(preferences.wrapsLines)
        preferences.wrapsLines = false
        XCTAssertFalse(preferences.wrapsLines)
        XCTAssertFalse(Preferences(defaults: defaults).wrapsLines)
        preferences.wrapsLines = true
        XCTAssertTrue(Preferences(defaults: defaults).wrapsLines)

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
        XCTAssertEqual(grid?.numberOfRows, 13)
        XCTAssertEqual(grid?.numberOfColumns, 2)

        // Font popup offers the four designs plus "Other…".
        let fontPopUp = grid?.cell(atColumnIndex: 1, rowIndex: 0).contentView as? NSPopUpButton
        XCTAssertEqual(
            fontPopUp?.itemTitles.filter { !$0.isEmpty },
            ["System", "Serif", "Rounded", "Monospaced", "Other…"]
        )

        // Word wrap is a plain checkbox on the "Editor" row.
        let wordWrap = grid?.cell(atColumnIndex: 1, rowIndex: 4).contentView as? NSButton
        XCTAssertEqual(wordWrap?.title, "Word wrap")

        // The gutter row carries both switches, numbers first.
        let gutterRow = grid?.cell(atColumnIndex: 1, rowIndex: 5).contentView as? NSStackView
        XCTAssertEqual(
            gutterRow?.views.compactMap { ($0 as? NSButton)?.title },
            ["Line numbers", "Gutter separator"]
        )

        // Row labels, right-aligned in the first column.
        let labels = (0..<12).compactMap {
            (grid?.cell(atColumnIndex: 0, rowIndex: $0).contentView as? NSTextField)?.stringValue
        }
        XCTAssertEqual(
            labels,
            ["Font", "Size", "Line spacing", "Padding", "Editor", "Gutter", "Status bar",
             "Image sidebar", "Copy images as", "Markdown", "Vim mode", "Summon"]
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
            "![](nota://",
            "![](nota://)",
            "![](nota://noextension)",
            "![](http://example.com/x.png)",
            "![alt](nota://\(a))",
            "(nota://\(a))",
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

    func testPlaceholdingTokensLeavesAnObjectReplacementCharacterPerImage() throws {
        let a = "aaaaaaaa-0000-0000-0000-000000000001.png"
        let b = "bbbbbbbb-0000-0000-0000-000000000002.png"
        let plain = "before \(NoteText.token(for: a)) middle \(NoteText.token(for: b)) after"

        XCTAssertEqual(
            NoteText.placeholdingTokens(plain),
            "before \u{FFFC} middle \u{FFFC} after"
        )
    }

    func testPathTokensWritesMarkdownImagesPointingAtTheAssetFiles() throws {
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let a = try XCTUnwrap(assets.importImageData(makePNGData(), preferredExtension: "png"))
        let b = try XCTUnwrap(assets.importImageData(makePNGData(), preferredExtension: "png"))
        let missing = "aaaaaaaa-0000-0000-0000-000000000009.png"
        let plain = "before \(NoteText.token(for: a)) middle "
            + "\(NoteText.token(for: b)) middle2 \(NoteText.token(for: missing)) after"

        XCTAssertEqual(
            NoteText.pathTokens(plain, assets: assets),
            "before ![Image 1](\(assets.url(for: a).path)) middle "
                + "![Image 2](\(assets.url(for: b).path)) middle2 \u{FFFC} after"
        )

        // No store at all: every image falls back to the marker.
        let a2 = "aaaaaaaa-0000-0000-0000-000000000001.png"
        let onlyToken = NoteText.token(for: a2)
        XCTAssertEqual(NoteText.pathTokens(onlyToken, assets: nil), "\u{FFFC}")
    }

    func testPasteImageThenCopyOffersEveryFlavour() throws {
        let previousStyle = Preferences.shared.plainTextImageStyle
        Preferences.shared.plainTextImageStyle = .marker
        defer { Preferences.shared.plainTextImageStyle = previousStyle }

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

        // Copying it out offers Nota's own flavour, RTFD, the bare picture and
        // plain text — in that order, so Nota and rich-text apps take the
        // flavour that keeps the words around the image.
        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        let types = view.writablePasteboardTypes
        XCTAssertEqual(types, [.notaNote, .rtfd, .png, .tiff, .string])

        let out = makePasteboard()
        out.clearContents()
        out.declareTypes(types, owner: nil)
        for type in types {
            XCTAssertTrue(view.writeSelection(to: out, type: type), "failed to write \(type)")
        }
        // AppKit also puts legacy aliases (NSStringPboardType, NeXT RTFD) on the
        // board, so check ours are present rather than that they are all there is.
        XCTAssertTrue(Set(types).isSubset(of: Set(out.types ?? [])))
        XCTAssertEqual(out.string(forType: .notaNote), NoteText.token(for: ids[0]))
        XCTAssertEqual(out.string(forType: .string), "\u{FFFC}")

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

        // Nota -> Nota re-uses the asset instead of importing a second copy.
        let second = makeTextView(assets: assets)
        XCTAssertTrue(second.readSelection(from: out, type: .notaNote))
        XCTAssertEqual(attachmentIDs(in: try XCTUnwrap(second.textStorage)), ids)
        XCTAssertEqual(try assetFileCount(assets), 1)
    }

    /// The default plain-text flavour: a Markdown image pointing at the
    /// asset's real path on disk, so pasting into a terminal agent leaves
    /// something it can actually open.
    @MainActor
    func testCopyingWithDefaultPlainTextStyleWritesTheAssetPath() throws {
        _ = NSApplication.shared
        XCTAssertEqual(Preferences.shared.plainTextImageStyle, .path)

        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let view = makeTextView(assets: assets)
        let id = try XCTUnwrap(assets.importImageData(makePNGData(), preferredExtension: "png"))
        let token = NoteText.token(for: id)
        try XCTUnwrap(view.textStorage).setAttributedString(NoteText.render(
            "hello \(token) world", attributes: [.font: NSFont.systemFont(ofSize: 13)],
            assets: assets
        ))
        view.setSelectedRange(NSRange(location: 0, length: view.textStorage?.length ?? 0))

        let board = makePasteboard()
        board.clearContents()
        board.declareTypes([.string], owner: nil)
        XCTAssertTrue(view.writeSelection(to: board, type: .string))
        XCTAssertEqual(
            board.string(forType: .string),
            "hello ![Image 1](\(assets.url(for: id).path)) world"
        )
    }

    /// Copying text and a picture off a web page: a browser offers no RTF, so
    /// `public.html` is the only flavour the picture is in at all.
    @MainActor
    func testPastingHTMLWithAnInlineImageKeepsTheWordsAndThePicture() throws {
        _ = NSApplication.shared
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let view = makeTextView(assets: assets)
        let png = makePNGData()
        let html = """
        <html><body><p>before \
        <img src="data:image/png;base64,\(png.base64EncodedString())"> after</p></body></html>
        """

        try withGeneralPasteboard { board in
            board.clearContents()
            board.declareTypes([.html, .string], owner: nil)
            board.setData(Data(html.utf8), forType: .html)
            board.setString("before  after", forType: .string)

            let chosen = view.preferredPasteboardType(
                from: board.types ?? [], restrictedToTypesFrom: view.readablePasteboardTypes
            )
            XCTAssertEqual(chosen, .html)
            XCTAssertTrue(view.readSelection(from: board, type: try XCTUnwrap(chosen)))
        }

        // The words survive, and the picture is a chip backed by a real file.
        let storage = try XCTUnwrap(view.textStorage)
        let ids = attachmentIDs(in: storage)
        XCTAssertEqual(ids.count, 1)
        XCTAssertTrue(assets.exists(ids[0]))
        XCTAssertEqual(try assetFileCount(assets), 1)
        XCTAssertTrue(storage.string.contains("before"))
        XCTAssertTrue(storage.string.contains("after"))
        // The importer closes the paragraph with a newline the copy never had.
        XCTAssertFalse(storage.string.hasSuffix("\n"))
    }

    /// A text-only copy from a browser is left exactly as it was: the HTML
    /// flavour has nothing to add, and going through the importer would cost
    /// the copy its lists and its whitespace for nothing.
    @MainActor
    func testPastingHTMLWithoutAPictureStaysPlainText() throws {
        _ = NSApplication.shared
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let view = makeTextView(assets: assets)
        let html = "<html><body><ul><li>one</li><li>two</li></ul></body></html>"
        let plain = "- one\n- two"

        try withGeneralPasteboard { board in
            board.clearContents()
            board.declareTypes([.html, .string], owner: nil)
            board.setData(Data(html.utf8), forType: .html)
            board.setString(plain, forType: .string)

            let chosen = view.preferredPasteboardType(
                from: board.types ?? [], restrictedToTypesFrom: view.readablePasteboardTypes
            )
            XCTAssertEqual(chosen, .string)
            XCTAssertTrue(view.readSelection(from: board, type: try XCTUnwrap(chosen)))
        }

        XCTAssertEqual(view.textStorage?.string, plain)
        XCTAssertEqual(try assetFileCount(assets), 0)
    }

    /// The path that matters: a picture the importer would not load — here a
    /// source relative to a page that is not on this machine — filled in from
    /// the web archive's own subresources rather than dropped.
    @MainActor
    func testPastingAWebArchiveFillsInThePicturesTheImporterLeftEmpty() throws {
        _ = NSApplication.shared
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let view = makeTextView(assets: assets)
        let png = makePNGData()
        // The second picture is one nothing can resolve: the importer would
        // put its broken-picture icon there, and a chip pointing at that icon
        // would be worse than no chip at all.
        let html = """
        <html><body><p>look <img src="a.png"> here \
        <img src="notes://elsewhere/gone.png"></p></body></html>
        """
        let archive: [String: Any] = [
            "WebMainResource": [
                "WebResourceData": Data(html.utf8),
                "WebResourceURL": "https://example.com/",
                "WebResourceMIMEType": "text/html",
                "WebResourceTextEncodingName": "UTF-8",
            ],
            "WebSubresources": [[
                "WebResourceData": png,
                "WebResourceURL": "https://example.com/a.png",
                "WebResourceMIMEType": "image/png",
            ]],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: archive, format: .binary, options: 0
        )

        try withGeneralPasteboard { board in
            board.clearContents()
            board.declareTypes([.webArchive, .string], owner: nil)
            board.setData(data, forType: .webArchive)
            board.setString("look  here", forType: .string)

            let chosen = view.preferredPasteboardType(
                from: board.types ?? [], restrictedToTypesFrom: view.readablePasteboardTypes
            )
            XCTAssertEqual(chosen, .webArchive)
            XCTAssertTrue(view.readSelection(from: board, type: try XCTUnwrap(chosen)))
        }

        let storage = try XCTUnwrap(view.textStorage)
        let ids = attachmentIDs(in: storage)
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(assets.data(for: ids[0]), png)
        XCTAssertEqual(try assetFileCount(assets), 1)
        XCTAssertTrue(storage.string.contains("look"))
        XCTAssertTrue(storage.string.contains("here"))
    }

    /// The source list and what each source resolves to, without a view or a
    /// pasteboard in the way. Nothing here goes near the network.
    func testHTMLClipboardResolvesInlinePicturesAndDropsWhatItCannot() throws {
        let png = makePNGData()
        let html = """
        <p>one <img src='data:image/png;base64,\(png.base64EncodedString())'> \
        two <img src="notes://elsewhere/picture.png"> \
        three <img src="page.png"></p>
        """
        let payload = HTMLClipboard.Payload(html: html)

        XCTAssertTrue(HTMLClipboard.containsImage(html))
        XCTAssertFalse(HTMLClipboard.containsImage("<p>no pictures here</p>"))

        let sources = HTMLClipboard.imageSources(in: html)
        XCTAssertEqual(sources.count, 3)
        XCTAssertEqual(sources[1], "notes://elsewhere/picture.png")
        XCTAssertEqual(sources[2], "page.png")

        // A data URI is the picture itself, byte for byte, and says what it is.
        let inline = try XCTUnwrap(HTMLClipboard.imageBytes(
            forSource: sources[0], in: payload, fetch: { _ in nil }
        ))
        XCTAssertEqual(inline.data, png)
        XCTAssertEqual(inline.preferredExtension, "png")

        // A scheme that is not the web's, and a relative source with no page
        // behind it, have nowhere to go — that one picture is dropped.
        XCTAssertNil(HTMLClipboard.imageBytes(
            forSource: sources[1], in: payload, fetch: { _ in nil }
        ))
        XCTAssertNil(HTMLClipboard.imageBytes(
            forSource: sources[2], in: payload, fetch: { _ in nil }
        ))

        // An http source is fetched, and nothing else is.
        var fetched: [URL] = []
        let remote = try XCTUnwrap(HTMLClipboard.imageBytes(
            forSource: "https://example.com/a.jpg", in: payload,
            fetch: { url in
                fetched.append(url)
                return png
            }
        ))
        XCTAssertEqual(fetched.map(\.absoluteString), ["https://example.com/a.jpg"])
        XCTAssertEqual(remote.preferredExtension, "jpg")
    }

    /// Safari's flavour: the markup and the pictures in one property list, so
    /// the bytes are already in hand and nothing has to be fetched.
    func testWebArchiveCarriesTheMarkupAndItsPictures() throws {
        let png = makePNGData()
        let html = "<p>hi <img src=\"https://example.com/a.png\"></p>"
        let archive: [String: Any] = [
            "WebMainResource": [
                "WebResourceData": Data(html.utf8),
                "WebResourceURL": "https://example.com/",
                "WebResourceMIMEType": "text/html",
                "WebResourceTextEncodingName": "UTF-8",
            ],
            "WebSubresources": [[
                "WebResourceData": png,
                "WebResourceURL": "https://example.com/a.png",
                "WebResourceMIMEType": "image/png",
            ]],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: archive, format: .binary, options: 0
        )

        let payload = try XCTUnwrap(HTMLClipboard.payload(from: data, type: .webArchive))
        XCTAssertEqual(payload.html, html)

        let source = try XCTUnwrap(HTMLClipboard.imageSources(in: payload.html).first)
        let bytes = try XCTUnwrap(HTMLClipboard.imageBytes(
            forSource: source, in: payload, fetch: { _ in nil }
        ))
        XCTAssertEqual(bytes.data, png)

        // A relative source still finds the subresource it names.
        let relative = try XCTUnwrap(HTMLClipboard.imageBytes(
            forSource: "a.png", in: payload, fetch: { _ in nil }
        ))
        XCTAssertEqual(relative.data, png)
    }

    /// The bug: a click dropped a caret *beside* the chip, so the picture
    /// looked selected and ⌘C copied nothing — `writeSelection` bails on a
    /// zero-length range. A click now selects the chip character itself.
    @MainActor
    func testClickingAChipSelectsItSoCopyCarriesTheImage() throws {
        _ = NSApplication.shared
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let view = makeTextView(assets: assets)
        let id = try XCTUnwrap(assets.importImageData(makePNGData(), preferredExtension: "png"))
        try XCTUnwrap(view.textStorage).setAttributedString(NoteText.render(
            "hello \(NoteText.token(for: id)) world",
            attributes: [.font: NSFont.systemFont(ofSize: 13)], assets: assets
        ))

        var clicked: Int?
        view.onChipClick = { clicked = $0 }
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.selectClickedChip(at: 6)

        XCTAssertEqual(view.selectedRange(), NSRange(location: 6, length: 1))
        XCTAssertEqual(clicked, 6)
        // The sidebar still rings exactly one thumbnail for that one chip.
        XCTAssertEqual(
            ChipHighlight.resolve(
                clickedChipLocation: nil, selection: view.selectedRange(), chipLocations: [6]
            ),
            [0]
        )

        // ⌘C, the real action, now has a range to write.
        withGeneralPasteboard { board in
            board.clearContents()
            view.copy(nil as Any?)
            XCTAssertTrue(Set<NSPasteboard.PasteboardType>([.notaNote, .rtfd, .string])
                .isSubset(of: Set(board.types ?? [])))
            XCTAssertEqual(board.string(forType: .notaNote), NoteText.token(for: id))
        }

        // A drag or a ⇧-click has already said what is meant; leave it be.
        view.setSelectedRange(NSRange(location: 0, length: 13))
        view.selectClickedChip(at: 6)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 13))

        // Vim's block caret sits *on* the chip instead, where the block draws.
        view.vimCursorStyle = .block
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.selectClickedChip(at: 6)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 6, length: 0))
    }

    /// A whole line copied the way ⌘C and Edit ▸ Copy take it — through
    /// `copy(_:)` and the general pasteboard, not `writeSelection` by hand.
    @MainActor
    func testCopyingALineWithAChipPastesTheImageBackAndCarriesItsBytes() throws {
        _ = NSApplication.shared
        let previousStyle = Preferences.shared.plainTextImageStyle
        Preferences.shared.plainTextImageStyle = .marker
        defer { Preferences.shared.plainTextImageStyle = previousStyle }

        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let view = makeTextView(assets: assets)
        let png = makePNGData()
        let id = try XCTUnwrap(assets.importImageData(png, preferredExtension: "png"))
        let token = NoteText.token(for: id)
        try XCTUnwrap(view.textStorage).setAttributedString(NoteText.render(
            "hello \(token) world\nsecond line",
            attributes: [.font: NSFont.systemFont(ofSize: 13)], assets: assets
        ))

        // "hello " + chip + " world" + newline: the first line, as a triple
        // click takes it.
        view.setSelectedRange(NSRange(location: 0, length: 14))

        try withGeneralPasteboard { board in
            board.clearContents()
            view.copy(nil as Any?)

            XCTAssertTrue(Set<NSPasteboard.PasteboardType>([.notaNote, .rtfd, .string])
                .isSubset(of: Set(board.types ?? [])))
            XCTAssertEqual(board.string(forType: .notaNote), "hello \(token) world\n")
            XCTAssertEqual(board.string(forType: .string), "hello \u{FFFC} world\n")

            // Nota -> Nota: the chip comes back, still pointing at the one asset.
            let second = makeTextView(assets: assets)
            let chosen = second.preferredPasteboardType(
                from: board.types ?? [], restrictedToTypesFrom: second.readablePasteboardTypes
            )
            XCTAssertEqual(chosen, .notaNote)
            XCTAssertTrue(second.readSelection(from: board, type: try XCTUnwrap(chosen)))
            XCTAssertEqual(attachmentIDs(in: try XCTUnwrap(second.textStorage)), [id])
            XCTAssertEqual(try assetFileCount(assets), 1)

            // And the RTFD other apps take really carries the picture.
            let rtfd = try XCTUnwrap(board.data(forType: .rtfd))
            let restored = try XCTUnwrap(NSAttributedString(rtfd: rtfd, documentAttributes: nil))
            var carried: [Data] = []
            restored.enumerateAttribute(
                .attachment, in: NSRange(location: 0, length: restored.length)
            ) { value, _, _ in
                if let contents = (value as? NSTextAttachment)?.fileWrapper?.regularFileContents {
                    carried.append(contents)
                }
            }
            XCTAssertEqual(carried, [png])
        }
    }

    /// The bug: a copied chip pasted into Nota and Notes but nowhere else —
    /// a terminal, a browser and Slack read `public.png` and nothing Nota was
    /// offering. The picture now rides along whether the chip is copied on
    /// its own or inside a line of prose.
    @MainActor
    func testACopiedChipIsAlsoAPNGAndTIFFOnTheClipboard() throws {
        _ = NSApplication.shared
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let view = makeTextView(assets: assets)
        let png = makePNGData()
        let id = try XCTUnwrap(assets.importImageData(png, preferredExtension: "png"))
        let source = try XCTUnwrap(NSBitmapImageRep(data: png))
        try XCTUnwrap(view.textStorage).setAttributedString(NoteText.render(
            "asd \(NoteText.token(for: id)) asdasd",
            attributes: [.font: NSFont.systemFont(ofSize: 13)], assets: assets
        ))

        // The chip alone, as a click on it selects it.
        view.setSelectedRange(NSRange(location: 4, length: 1))
        XCTAssertEqual(view.writablePasteboardTypes, [.notaNote, .rtfd, .png, .tiff, .string])

        // And the whole line around it, as a triple click takes it.
        for range in [NSRange(location: 4, length: 1), NSRange(location: 0, length: 12)] {
            view.setSelectedRange(range)
            let board = makePasteboard()
            board.clearContents()
            let types = view.writablePasteboardTypes
            board.declareTypes(types, owner: nil)
            for type in types {
                XCTAssertTrue(view.writeSelection(to: board, type: type), "failed \(type)")
            }

            // Already a PNG on disk, so the very bytes go out — no re-encode.
            XCTAssertEqual(board.data(forType: .png), png)
            let tiff = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(board.data(forType: .tiff))))
            XCTAssertEqual(tiff.pixelsWide, source.pixelsWide)
            XCTAssertEqual(tiff.pixelsHigh, source.pixelsHigh)

            // Nota -> Nota still takes its own flavour first, so the asset is
            // re-linked rather than imported a second time.
            let second = makeTextView(assets: assets)
            XCTAssertEqual(
                second.preferredPasteboardType(
                    from: board.types ?? [], restrictedToTypesFrom: second.readablePasteboardTypes
                ),
                .notaNote
            )
            XCTAssertTrue(second.readSelection(from: board, type: .notaNote))
            XCTAssertEqual(attachmentIDs(in: try XCTUnwrap(second.textStorage)), [id])
            XCTAssertEqual(try assetFileCount(assets), 1)
        }
    }

    /// One `public.png` cannot say which of two pictures is meant, so a
    /// selection holding both goes out as text and RTFD only.
    @MainActor
    func testASelectionWithTwoChipsOffersNoPictureFlavour() throws {
        _ = NSApplication.shared
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let view = makeTextView(assets: assets)
        let first = try XCTUnwrap(assets.importImageData(makePNGData(), preferredExtension: "png"))
        let second = try XCTUnwrap(assets.importImageData(makePNGData(), preferredExtension: "png"))
        let storage = try XCTUnwrap(view.textStorage)
        storage.setAttributedString(NoteText.render(
            "\(NoteText.token(for: first)) and \(NoteText.token(for: second))",
            attributes: [.font: NSFont.systemFont(ofSize: 13)], assets: assets
        ))

        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        XCTAssertEqual(view.writablePasteboardTypes, [.notaNote, .rtfd, .string])

        // Either one on its own is unambiguous again.
        view.setSelectedRange(NSRange(location: 0, length: 1))
        XCTAssertEqual(view.writablePasteboardTypes, [.notaNote, .rtfd, .png, .tiff, .string])
    }

    /// Copying prose stays prose: no image flavours, and still no RTFD.
    @MainActor
    func testAPlainTextSelectionOffersNoImageFlavours() throws {
        _ = NSApplication.shared
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let view = makeTextView(assets: assets)
        let storage = try XCTUnwrap(view.textStorage)
        storage.setAttributedString(NSAttributedString(
            string: "just words", attributes: [.font: NSFont.systemFont(ofSize: 13)]
        ))

        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        XCTAssertEqual(view.writablePasteboardTypes, [.notaNote, .string])
        XCTAssertFalse(view.writeSelection(to: makePasteboard(), type: .png))
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
        XCTAssertTrue(NoteSearch.matches(query: "nota", in: withImage).isEmpty)
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
        XCTAssertEqual(NoteText.assetIDs(in: "![](nota://malformed"), [])
    }

    func testChipIsTextSizedAndRenumbersLive() {
        let font = NSFont.systemFont(ofSize: 13)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)

        func bounds(_ chip: NotaImageAttachment, width: CGFloat = 2000) -> CGRect {
            chip.attachmentBounds(
                for: nil,
                proposedLineFragment: CGRect(x: 0, y: 0, width: width, height: 20),
                glyphPosition: .zero,
                characterIndex: 0
            )
        }

        let first = NotaImageAttachment(assetID: "a.png", isMissing: false, font: font, index: 1)
        let tenth = NotaImageAttachment(assetID: "b.png", isMissing: false, font: font, index: 10)
        let gone = NotaImageAttachment(assetID: "c.png", isMissing: true, font: font, index: 1)

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
        let big = NotaImageAttachment(
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
            if let chip = value as? NotaImageAttachment { labels.append(chip.label) }
        }
        // A repeated picture still gets its own number, by position.
        XCTAssertEqual(
            labels,
            ["Image 1 — missing", "Image 2 — missing", "Image 3 — missing"]
        )
        // Numbering is display only — it never reaches the file.
        XCTAssertEqual(NoteText.serialize(rendered), text)
    }

    func testABlockCaretLightsTheChipItSitsOn() {
        let chips = [4, 5, 9]
        func resolve(_ location: Int, block: Bool) -> Set<Int> {
            ChipHighlight.resolve(
                clickedChipLocation: nil, selection: NSRange(location: location, length: 0),
                chipLocations: chips, caretIsBlock: block
            )
        }
        // Normal mode: the block on the chip is the chip.
        XCTAssertEqual(resolve(4, block: true), [0])
        XCTAssertEqual(resolve(5, block: true), [1])
        XCTAssertEqual(resolve(9, block: true), [2])
        // Just past a chip is not on it any more.
        XCTAssertEqual(resolve(6, block: true), [])
        XCTAssertEqual(resolve(10, block: true), [])
        // Insert mode is unchanged: the chip before the bar.
        XCTAssertEqual(resolve(5, block: false), [0])
        XCTAssertEqual(resolve(4, block: false), [])
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

    func testFooterCountVariantsShedSegmentsFromTheRight() {
        let all = TextStats.Segment.allCases

        // Longest first: everything enabled, then a segment given up at a
        // time from the right, then the bare numbers.
        XCTAssertEqual(
            TextStats.countVariants(
                words: 2, characters: 7, images: 3, lines: 12, segments: all
            ),
            [
                "2 words · 7 characters · 3 images · 12 lines",
                "2 words · 7 characters · 3 images",
                "2 words · 7 characters",
                "2 words",
                "2 · 7 · 3 · 12",
            ]
        )

        // Singulars, and an empty note.
        XCTAssertEqual(
            TextStats.countVariants(
                words: 1, characters: 1, images: 1, lines: 1, segments: all
            ).first,
            "1 word · 1 character · 1 image · 1 line"
        )
        XCTAssertEqual(
            TextStats.countVariants(
                words: 0, characters: 0, images: 0, lines: 1, segments: all
            ).first,
            "0 words · 0 characters · 0 images · 1 line"
        )

        // Only the enabled segments appear.
        XCTAssertEqual(
            TextStats.countVariants(
                words: 2, characters: 7, images: 3, lines: 12, segments: [.words, .characters]
            ),
            ["2 words · 7 characters", "2 words", "2 · 7"]
        )
        XCTAssertEqual(
            TextStats.countVariants(
                words: 2, characters: 7, images: 3, lines: 12, segments: [.lines]
            ),
            ["12 lines", "12"]
        )
        // Nothing enabled means nothing to show, which is what hides the label.
        XCTAssertTrue(
            TextStats.countVariants(
                words: 2, characters: 7, images: 3, lines: 12, segments: []
            ).isEmpty
        )

        // Hard lines: one per newline plus the last, empty note included.
        XCTAssertEqual(TextStats.lineCount(""), 1)
        XCTAssertEqual(TextStats.lineCount("one line"), 1)
        XCTAssertEqual(TextStats.lineCount("one\ntwo"), 2)
        // A trailing newline opens a line of its own, as the gutter shows it.
        XCTAssertEqual(TextStats.lineCount("one\n"), 2)
        XCTAssertEqual(TextStats.lineCount("\n\n"), 3)
    }

    func testFooterPicksTheLongestCountsThatFit() {
        let variants = TextStats.countVariants(
            words: 2, characters: 7, images: 3, lines: 12,
            segments: TextStats.Segment.allCases
        )
        // A stand-in for the type: every character is 10pt wide.
        func fitting(_ width: CGFloat) -> String {
            TextStats.variantFitting(variants, within: width) { candidate in
                CGFloat(candidate.count) * 10
            }
        }

        // Room for everything.
        XCTAssertEqual(fitting(10_000), "2 words · 7 characters · 3 images · 12 lines")
        // 44 characters in the full form, 33 in the next one down.
        XCTAssertEqual(fitting(440), "2 words · 7 characters · 3 images · 12 lines")
        XCTAssertEqual(fitting(439), "2 words · 7 characters · 3 images")
        XCTAssertEqual(fitting(330), "2 words · 7 characters · 3 images")
        XCTAssertEqual(fitting(329), "2 words · 7 characters")
        XCTAssertEqual(fitting(219), "2 words")
        XCTAssertEqual(fitting(70), "2 words")
        // Below one whole segment there is nothing left but the bare
        // numbers, which are kept even when they do not fit either — a
        // clipped number beats a phrase cut off mid-word.
        XCTAssertEqual(fitting(69), "2 · 7 · 3 · 12")
        XCTAssertEqual(fitting(0), "2 · 7 · 3 · 12")

        // With the default two segments the numbers really are the shortest
        // form, so they take over before anything is given up entirely.
        let two = TextStats.countVariants(
            words: 2, characters: 7, images: 3, lines: 12, segments: [.words, .characters]
        )
        func fittingTwo(_ width: CGFloat) -> String {
            TextStats.variantFitting(two, within: width) { CGFloat($0.count) * 10 }
        }
        XCTAssertEqual(fittingTwo(220), "2 words · 7 characters")
        XCTAssertEqual(fittingTwo(219), "2 words")
        XCTAssertEqual(fittingTwo(69), "2 · 7")

        // Nothing enabled has nothing to fit.
        XCTAssertEqual(TextStats.variantFitting([], within: 100) { _ in 0 }, "")
    }

    func testCursorPositionIsOneBasedAndCountsAnImageAsOneColumn() throws {
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let id = "dddddddd-0000-0000-0000-000000000004.png"

        let plain = "one\ntwo\nthree"
        let text = plain as NSString
        XCTAssertEqual(TextStats.position(in: text, at: 0), "Ln 1, Col 1")
        XCTAssertEqual(TextStats.position(in: text, at: 3), "Ln 1, Col 4")
        // Just past the newline is the start of the next line.
        XCTAssertEqual(TextStats.position(in: text, at: 4), "Ln 2, Col 1")
        XCTAssertEqual(TextStats.position(in: text, at: 7), "Ln 2, Col 4")
        XCTAssertEqual(TextStats.position(in: text, at: 8), "Ln 3, Col 1")
        // Out-of-range locations clamp rather than trap.
        XCTAssertEqual(TextStats.position(in: text, at: 9_999), "Ln 3, Col 6")
        XCTAssertEqual(TextStats.position(in: text, at: -4), "Ln 1, Col 1")
        XCTAssertEqual(TextStats.position(in: "" as NSString, at: 0), "Ln 1, Col 1")

        // A composed character is one column, not two UTF-16 units.
        let emoji = "a👋b" as NSString
        XCTAssertEqual(TextStats.position(in: emoji, at: emoji.length), "Ln 1, Col 4")

        // And an inline image is a single glyph, so the caret after
        // "hi <image>" sits in column 5.
        let withImage = NoteText.render(
            "line\nhi \(NoteText.token(for: id))x",
            attributes: [.font: NSFont.systemFont(ofSize: 13)],
            assets: assets
        )
        let storage = NSTextStorage(attributedString: withImage).string as NSString
        XCTAssertEqual(storage.length, 10)   // "line\nhi " + U+FFFC + "x"
        XCTAssertEqual(TextStats.position(in: storage, at: 8), "Ln 2, Col 4")
        XCTAssertEqual(TextStats.position(in: storage, at: 9), "Ln 2, Col 5")
        XCTAssertEqual(TextStats.position(in: storage, at: 10), "Ln 2, Col 6")
    }

    func testVimModePreferenceIsOffUntilAskedFor() throws {
        let suite = "NotaTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)

        // The footer counts words and characters until told otherwise.
        XCTAssertEqual(preferences.footerSegments, [.words, .characters])
        XCTAssertTrue(preferences.footerShowsWords)
        XCTAssertTrue(preferences.footerShowsCharacters)
        XCTAssertFalse(preferences.footerShowsImages)
        XCTAssertFalse(preferences.footerShowsLines)
        preferences.footerShowsLines = true
        preferences.footerShowsWords = false
        XCTAssertEqual(preferences.footerSegments, [.characters, .lines])
        XCTAssertEqual(Preferences(defaults: defaults).footerSegments, [.characters, .lines])

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
        XCTAssertEqual(VimMode.visualLine.badgeTitle, "Visual line")
        XCTAssertEqual(VimMode.replace.badgeTitle, "Replace")
        XCTAssertTrue(VimMode.insert.showsCapsule)
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
        XCTAssertEqual(footer.counts.stringValue, "0 words · 0 characters")
        XCTAssertEqual(footer.cursor.stringValue, "Ln 1, Col 1")

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

        // Turning every segment on and squeezing the window sheds segments
        // instead of truncating one, and never runs into the caret.
        let previousImages = Preferences.shared.footerShowsImages
        let previousLines = Preferences.shared.footerShowsLines
        defer {
            Preferences.shared.footerShowsImages = previousImages
            Preferences.shared.footerShowsLines = previousLines
        }
        Preferences.shared.footerShowsImages = true
        Preferences.shared.footerShowsLines = true
        window.layoutIfNeeded()
        XCTAssertEqual(footer.counts.stringValue,
                       "0 words · 0 characters · 0 images · 1 line")

        let variants = TextStats.countVariants(
            words: 0, characters: 0, images: 0, lines: 1,
            segments: TextStats.Segment.allCases
        )

        // Which variant gets picked for a given width is covered on its own
        // in `testFooterPicksTheLongestCountsThatFit`; what matters here is
        // that whatever the footer ends up showing is a whole variant, laid
        // out at its full width — never a phrase cut off mid-word.
        for (width, pending) in [(820.0, ""), (600.0, "recording @a"), (900.0, "\"a2d")] {
            Preferences.shared.vimMode = !pending.isEmpty
            controller.setVimPendingKeys(pending)
            window.setContentSize(NSSize(width: width, height: 560))
            // Twice: choosing the text inside a layout pass invalidates the
            // label's intrinsic size, which the next pass acts on.
            window.layoutIfNeeded()
            window.layoutIfNeeded()

            let shown = footer.counts.stringValue
            XCTAssertTrue(variants.contains(shown),
                          "\(width)pt showed \(shown), which is not a whole variant")
            let font = try XCTUnwrap(footer.counts.font)
            let textWidth = (shown as NSString).size(withAttributes: [.font: font]).width
            XCTAssertEqual(footer.counts.frame.width, footer.counts.fittingSize.width,
                           accuracy: 1,
                           "the label must be laid out at its full width, not squeezed")
            XCTAssertGreaterThanOrEqual(footer.counts.frame.width, textWidth)
            XCTAssertLessThanOrEqual(footer.counts.frame.maxX, footer.cursor.frame.minX)
            if !pending.isEmpty {
                XCTAssertGreaterThanOrEqual(
                    footer.counts.frame.minX, footer.pendingKeys.frame.maxX
                )
            }
        }

        controller.setVimPendingKeys("")
        Preferences.shared.vimMode = false
        window.setContentSize(NSSize(width: 820, height: 560))
        window.layoutIfNeeded()
        XCTAssertEqual(footer.counts.stringValue, variants[0])

        // Nothing counted at all hides the middle label outright.
        let previousWords = Preferences.shared.footerShowsWords
        let previousCharacters = Preferences.shared.footerShowsCharacters
        defer {
            Preferences.shared.footerShowsWords = previousWords
            Preferences.shared.footerShowsCharacters = previousCharacters
        }
        Preferences.shared.footerShowsWords = false
        Preferences.shared.footerShowsCharacters = false
        Preferences.shared.footerShowsImages = false
        Preferences.shared.footerShowsLines = false
        window.layoutIfNeeded()
        XCTAssertTrue(footer.counts.isHidden)
        XCTAssertEqual(footer.counts.stringValue, "")
        // The caret position is not part of the deal — it stays.
        XCTAssertFalse(footer.cursor.isHidden)
    }

    // MARK: - The command pane

    @MainActor
    func testTheCommandPaneOverlaysTheEditorWithoutMovingIt() throws {
        _ = NSApplication.shared
        let directory = try makeTemporaryDirectory()
        let controller = MainWindowController(store: SessionStore(directory: directory))
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()

        let scrollView = try XCTUnwrap(descendant(of: content, ofType: NSScrollView.self))
        let pane = try XCTUnwrap(descendant(of: content, ofType: VimCommandPane.self))
        XCTAssertTrue(pane.isHidden, "nothing to show at rest")
        let editorFrame = scrollView.frame

        controller.vim.beginPrompt(":")
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.commandPaneState.isVisible)
        XCTAssertEqual(controller.commandPaneState.text, ":\u{258F}", "the prefix and a caret")
        XCTAssertEqual(scrollView.frame, editorFrame, "the editor does not move for it")

        // It lies over the bottom of the editor, under the footer.
        let paneFrame = pane.convert(pane.bounds, to: content)
        let editor = scrollView.convert(scrollView.bounds, to: content)
        XCTAssertGreaterThanOrEqual(paneFrame.minY, editor.minY)
        XCTAssertLessThanOrEqual(paneFrame.maxY, editor.maxY)
        XCTAssertEqual(paneFrame.height, VimCommandPane.height)

        controller.vim.cancelPrompt()
        XCTAssertFalse(controller.commandPaneState.isVisible, "Escape collapses it")

        // Zen takes the footer away; the pane goes to the window's own edge
        // rather than with it.
        controller.vim.beginPrompt(":")
        controller.toggleZenMode()
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.commandPaneState.isVisible, "`:` still works in zen mode")
        XCTAssertEqual(pane.convert(pane.bounds, to: content).minY, 0, accuracy: 0.5)
    }

    @MainActor
    func testTheCommandPaneDrawsPromptsAndMessagesDifferently() throws {
        let pane = VimCommandPane(inset: 16)
        XCTAssertTrue(pane.isHidden)

        pane.showPrompt(":wq")
        XCTAssertFalse(pane.isHidden)
        XCTAssertEqual(pane.text, ":wq\u{258F}")
        XCTAssertFalse(pane.isShowingMessage)

        // The prompt's character is quieter than what was typed after it.
        let label = try XCTUnwrap(descendant(of: pane, ofType: NSTextField.self))
        let line = label.attributedStringValue
        XCTAssertEqual(
            line.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
            .secondaryLabelColor
        )
        XCTAssertEqual(
            line.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor,
            .labelColor
        )

        pane.showMessage("E486: Pattern not found: x")
        XCTAssertTrue(pane.isShowingMessage)
        XCTAssertEqual(pane.text, "E486: Pattern not found: x")
        XCTAssertEqual(
            label.attributedStringValue
                .attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
            .secondaryLabelColor,
            "a message is quiet all through"
        )

        pane.clear()
        XCTAssertTrue(pane.isHidden)
        XCTAssertFalse(pane.isShowingMessage)
    }

    // MARK: - The find bar

    /// AppKit's own focus ring on the find bar's search field is a thick
    /// light-blue slab across the whole width of the window — the ⌘P picker
    /// already turns this off on its own field, and the native find bar gets
    /// the same treatment.
    @MainActor
    func testTheFindBarShowsNoFocusRingOnItsFields() throws {
        _ = NSApplication.shared
        let directory = try makeTemporaryDirectory()
        let controller = MainWindowController(store: SessionStore(directory: directory))
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 820, height: 560))
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()

        let content = try XCTUnwrap(window.contentView)
        let scrollView = try XCTUnwrap(descendant(of: content, ofType: NSScrollView.self))
        let textView = try XCTUnwrap(descendant(of: content, ofType: NotaTextView.self))

        // Same route ⌘F takes: a menu item tagged with the finder action,
        // sent to the text view.
        let showFind = NSMenuItem()
        showFind.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(showFind)
        // A couple of the bar's own decorations are only realized once it
        // lays itself out.
        scrollView.needsLayout = true
        scrollView.layoutSubtreeIfNeeded()

        guard let findBarView = scrollView.findBarView else {
            throw XCTSkip("the native find bar did not install headlessly")
        }
        let fields = allTextFields(in: findBarView)
        XCTAssertFalse(fields.isEmpty, "expected at least the search field")
        for field in fields {
            XCTAssertEqual(field.focusRingType, .none)
        }
    }

    /// Every `NSTextField` (an `NSSearchField` included) anywhere under `view`.
    @MainActor
    private func allTextFields(in view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        if let field = view as? NSTextField { found.append(field) }
        for subview in view.subviews { found += allTextFields(in: subview) }
        return found
    }

    /// The first view of a kind anywhere under another.
    @MainActor
    private func descendant<T: NSView>(of view: NSView, ofType type: T.Type) -> T? {
        for subview in view.subviews {
            if let match = subview as? T { return match }
            if let match = descendant(of: subview, ofType: type) { return match }
        }
        return nil
    }

    // MARK: - Word wrap

    /// Settings → "Word wrap". On, a long line folds and the content is
    /// exactly as wide as the column. Off, the line runs on and the editor
    /// scrolls sideways to follow it.
    @MainActor
    func testWordWrapTogglesHorizontalScrolling() throws {
        _ = NSApplication.shared
        let previous = Preferences.shared.wrapsLines
        defer { Preferences.shared.wrapsLines = previous }
        Preferences.shared.wrapsLines = true

        let directory = try makeTemporaryDirectory()
        let controller = MainWindowController(store: SessionStore(directory: directory))
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 820, height: 560))
        window.layoutIfNeeded()

        let editor = controller.editorScrolling
        let container = try XCTUnwrap(editor.container)
        let long = String(repeating: "the quick brown fox ", count: 60)
        editor.textView.insertText(long, replacementRange: editor.textView.selectedRange())
        window.layoutIfNeeded()

        // Wrapping: the container is welded to the text view, no sideways
        // scroller, and the content is no wider than what is on screen.
        XCTAssertTrue(container.widthTracksTextView)
        XCTAssertFalse(editor.scrollView.hasHorizontalScroller)
        XCTAssertEqual(
            editor.textView.frame.width, controller.editorScrolling.visibleWidth, accuracy: 1
        )

        Preferences.shared.wrapsLines = false
        window.layoutIfNeeded()

        // Not wrapping: the container is unbounded, the scroller is there, and
        // the one long line is wider than the column showing it.
        XCTAssertFalse(container.widthTracksTextView)
        XCTAssertTrue(editor.scrollView.hasHorizontalScroller)
        XCTAssertGreaterThan(
            editor.textView.frame.width, controller.editorScrolling.visibleWidth + 1
        )
        // The gutter is a ruler, so it keeps its own strip at the left edge
        // whatever the text does.
        XCTAssertTrue(editor.scrollView.rulersVisible)

        Preferences.shared.wrapsLines = true
        window.layoutIfNeeded()

        // And back: tracking restored, scroller gone, content back in the column.
        XCTAssertTrue(container.widthTracksTextView)
        XCTAssertFalse(editor.scrollView.hasHorizontalScroller)
        XCTAssertEqual(
            editor.textView.frame.width, controller.editorScrolling.visibleWidth, accuracy: 1
        )
    }

    /// With wrap off the text view is sized to its own text rather than
    /// stretched to the column, so a short note has to keep filling the column
    /// as the window grows — otherwise a click to the right of the text lands
    /// nowhere. Being the scroll view's document view is what carries that
    /// floor; this pins the behaviour down.
    @MainActor
    func testWordWrapKeepsAShortNoteFillingAWidenedColumn() throws {
        _ = NSApplication.shared
        let previous = Preferences.shared.wrapsLines
        defer { Preferences.shared.wrapsLines = previous }
        Preferences.shared.wrapsLines = false

        let directory = try makeTemporaryDirectory()
        let controller = MainWindowController(store: SessionStore(directory: directory))
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 600, height: 400))
        window.layoutIfNeeded()

        let editor = controller.editorScrolling
        editor.textView.insertText("short", replacementRange: editor.textView.selectedRange())
        window.layoutIfNeeded()
        XCTAssertGreaterThanOrEqual(
            editor.textView.frame.width, controller.editorScrolling.visibleWidth - 1
        )

        window.setContentSize(NSSize(width: 1000, height: 400))
        window.layoutIfNeeded()

        let widened = controller.editorScrolling.visibleWidth
        XCTAssertGreaterThan(widened, 600, "the column really did grow")
        XCTAssertGreaterThanOrEqual(editor.textView.frame.width, widened - 1)
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

        // The outer split survives the round trip intact: the document
        // workspace and the image sidebar. The preview is nested inside the
        // workspace so its divider starts below the shared tabs.
        XCTAssertEqual(
            (window.contentViewController as? NSSplitViewController)?.splitViewItems.count, 2
        )
    }

    // MARK: - Sidebar utility row

    @MainActor
    func testSidebarUtilityRowSitsBelowTheThumbnails() throws {
        _ = NSApplication.shared
        let sidebar = ImageSidebarView(topInset: 8)
        sidebar.frame = NSRect(x: 0, y: 0, width: ImageSidebarView.width, height: 400)
        sidebar.layoutSubtreeIfNeeded()

        let (row, gear, list) = sidebar.utilityRowViews

        // Pinned to the bottom, full width, 28pt tall.
        XCTAssertEqual(row.frame.minY, 0)
        XCTAssertEqual(row.frame.height, ImageSidebarView.utilityRowHeight)
        XCTAssertEqual(row.frame.width, sidebar.bounds.width)

        // The gear sits inside the row, against its leading edge. AppKit pads
        // a button's frame out past the rect it lays out, so the alignment
        // rect is the one that has to land where it was asked to.
        XCTAssertEqual(gear.superview, row)
        let gearRect = gear.alignmentRect(forFrame: gear.frame)
        XCTAssertEqual(gearRect.minX, 8)
        XCTAssertTrue(row.bounds.contains(gearRect), "the gear must fit inside the row")
        XCTAssertEqual(gearRect.midY, row.bounds.midY, accuracy: 0.5)

        // The thumbnails stop where the row starts — nothing overlaps.
        XCTAssertEqual(list.frame.minY, row.frame.maxY)
        XCTAssertFalse(list.frame.intersects(row.frame))
        XCTAssertEqual(list.frame.maxY, sidebar.bounds.maxY)

        // Monochrome, labelled, and it opens Settings.
        XCTAssertEqual(gear.toolTip, "Settings")
        XCTAssertEqual(gear.accessibilityLabel(), "Settings")
        XCTAssertEqual(gear.contentTintColor, .secondaryLabelColor)
        XCTAssertFalse(gear.isBordered)
        XCTAssertTrue(gear.image?.isTemplate ?? false)

        var opened = 0
        sidebar.onSettings = { opened += 1 }
        gear.performClick(nil)
        XCTAssertEqual(opened, 1)
    }

    // MARK: - Gutter separator

    func testTheSidebarNeverResizesTheWindow() throws {
        _ = NSApplication.shared
        let directory = try makeTemporaryDirectory()
        let controller = MainWindowController(store: SessionStore(directory: directory))
        let window = try XCTUnwrap(controller.window)
        let split = try XCTUnwrap(window.contentViewController as? NSSplitViewController)
        // The thumbnails are the one thing left that collapses, and they
        // make their sibling give up room rather than changing the window
        // frame. The document's own two columns never collapse at all — a
        // preview mode is a divider position, and a divider asks the window
        // for nothing.
        let documentSplit = try XCTUnwrap(
            split.children.lazy
                .flatMap(\.children)
                .compactMap { $0 as? NSSplitViewController }
                .first
        )
        let collapsible = (split.splitViewItems + documentSplit.splitViewItems)
            .filter(\.canCollapse)
        XCTAssertEqual(collapsible.count, 1)
        for item in collapsible {
            XCTAssertEqual(item.collapseBehavior, .preferResizingSiblingsWithFixedSplitView)
        }
        XCTAssertTrue(
            documentSplit.splitViewItems.allSatisfy { !$0.canCollapse },
            "neither document column collapses for a mode"
        )
    }

    func testTextSitsCloserToTheGutterWhileTheRightMarginKeepsTheSetting() throws {
        _ = NSApplication.shared
        let previousNumbers = Preferences.shared.showsLineNumbers
        let previousPadding = Preferences.shared.padding
        defer {
            Preferences.shared.showsLineNumbers = previousNumbers
            Preferences.shared.padding = previousPadding
        }
        Preferences.shared.padding = .normal
        Preferences.shared.showsLineNumbers = true

        let directory = try makeTemporaryDirectory()
        let controller = MainWindowController(store: SessionStore(directory: directory))
        _ = controller.window

        // Gutter on: 8pt off the numbers on the left, the setting on the right.
        XCTAssertTrue(controller.isGutterVisible)
        XCTAssertEqual(controller.horizontalTextInset, MainWindowController.gutterTextGap)
        XCTAssertEqual(
            controller.trailingTextInsetExtra,
            EditorPaddingOption.normal.inset - MainWindowController.gutterTextGap
        )
        XCTAssertEqual(
            controller.editorParagraphStyle?.tailIndent,
            -(EditorPaddingOption.normal.inset - MainWindowController.gutterTextGap)
        )

        // Gutter off: the plain symmetric padding, and no tail indent at all.
        Preferences.shared.showsLineNumbers = false
        XCTAssertFalse(controller.isGutterVisible)
        XCTAssertEqual(controller.horizontalTextInset, EditorPaddingOption.normal.inset)
        XCTAssertEqual(controller.trailingTextInsetExtra, 0)
        XCTAssertEqual(controller.editorParagraphStyle?.tailIndent, 0)
    }

    func testGutterSeparatorPreferenceRoundTrips() throws {
        let suite = "NotaTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)

        // Off until asked for, and it survives a fresh reader either way.
        XCTAssertFalse(preferences.showsGutterSeparator)
        preferences.showsGutterSeparator = true
        XCTAssertTrue(Preferences(defaults: defaults).showsGutterSeparator)
        preferences.showsGutterSeparator = false
        XCTAssertFalse(Preferences(defaults: defaults).showsGutterSeparator)
    }

    @MainActor
    func testGutterSeparatorHairlineHugsTheInnerEdge() throws {
        _ = NSApplication.shared
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let textView = makeTextView(assets: assets)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.documentView = textView
        let ruler = LineNumberRulerView(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.tile()

        // Off is the default, and off draws nothing at all.
        XCTAssertFalse(ruler.showsSeparator)
        XCTAssertNil(ruler.separatorRect)

        ruler.showsSeparator = true
        let hairline = try XCTUnwrap(ruler.separatorRect)
        // One device pixel wide, hard against the text, full height.
        XCTAssertEqual(hairline.width, 1 / (ruler.window?.backingScaleFactor ?? 1))
        XCTAssertGreaterThan(hairline.width, 0)
        XCTAssertLessThanOrEqual(hairline.width, 1)
        XCTAssertEqual(hairline.maxX, ruler.bounds.maxX)
        XCTAssertEqual(hairline.minY, ruler.bounds.minY)
        XCTAssertEqual(hairline.height, ruler.bounds.height)
        XCTAssertGreaterThan(hairline.height, 0)
    }

    // MARK: - Tab bar

    /// A narrower window or a switch always scrolls the selected tab fully
    /// into view; only a manual trackpad scroll is allowed to move it out.
    @MainActor
    func testSelectedTabStaysInViewAcrossResizeAndSelection() throws {
        _ = NSApplication.shared
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 600, height: TabBarView.height))
        let tabs = (0..<4).map { TabBarItem(title: "Note \($0)", isDirty: false) }

        bar.setItems(tabs, selectedIndex: 3)
        bar.layoutSubtreeIfNeeded()
        XCTAssertTrue(bar.isSelectedTabFullyVisible(), "last tab selected at full width")

        // Narrowing the window past where the strip starts scrolling must
        // not leave the selected tab stranded off the trailing edge.
        bar.frame = NSRect(x: 0, y: 0, width: 300, height: TabBarView.height)
        bar.layoutSubtreeIfNeeded()
        XCTAssertTrue(bar.isSelectedTabFullyVisible(),
                      "resize alone must re-anchor the selected tab")

        // Selecting a different tab (e.g. the leading one) must scroll to it
        // too, without needing an extra layout pass.
        bar.setItems(tabs, selectedIndex: 0)
        bar.layoutSubtreeIfNeeded()
        XCTAssertTrue(bar.isSelectedTabFullyVisible(),
                      "switching selection must re-anchor synchronously")
    }

    /// A completed drag reports `(from, to)` through the delegate; applying
    /// that move the way `MainWindowController.moveTab` does and pushing it
    /// back through `setItems` is what the strip then displays.
    @MainActor
    func testTabBarReportsAMoveAndReflectsTheNewOrderOnceApplied() throws {
        _ = NSApplication.shared
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 600, height: TabBarView.height))
        var tabs = (0..<4).map { TabBarItem(title: "Note \($0)", isDirty: false) }
        bar.setItems(tabs, selectedIndex: 0)
        bar.layoutSubtreeIfNeeded()

        final class RecordingDelegate: TabBarViewDelegate {
            var moved: (from: Int, to: Int)?
            func tabBar(_ bar: TabBarView, didSelect index: Int) {}
            func tabBar(_ bar: TabBarView, didRequestCloseAt index: Int) {}
            func tabBarDidRequestNewTab(_ bar: TabBarView) {}
            func tabBar(_ bar: TabBarView, didMove index: Int, to newIndex: Int) {
                moved = (index, newIndex)
            }
        }
        let recorder = RecordingDelegate()
        bar.delegate = recorder

        bar.moveTabForTesting(from: 0, to: 2)
        let moved = try XCTUnwrap(recorder.moved)
        XCTAssertEqual(moved.from, 0)
        XCTAssertEqual(moved.to, 2)

        // A no-op move reports nothing.
        recorder.moved = nil
        bar.moveTabForTesting(from: 1, to: 1)
        XCTAssertNil(recorder.moved)

        // Applying the reported move the way the delegate does, and pushing
        // it back in, is what the strip is expected to show.
        tabs.insert(tabs.remove(at: moved.from), at: moved.to)
        bar.setItems(tabs, selectedIndex: moved.to)
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.titlesForTesting, ["Note 1", "Note 2", "Note 0", "Note 3"])
        XCTAssertTrue(bar.isSelectedTabFullyVisible(), "the moved, still-selected tab stays in view")
    }

    /// A layout arriving mid-drag (a resize here) must not reset the dragged
    /// tab's frame back to its plain-order slot — that would yank it out
    /// from under the pointer. A tab count change mid-drag (⌘W closing a
    /// tab) cancels the drag instead, since the session's slots would
    /// otherwise be stale.
    @MainActor
    func testLayoutMidDragLeavesTheDraggedTabInPlaceAndACountChangeCancelsIt() throws {
        _ = NSApplication.shared
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 600, height: TabBarView.height))
        let tabs = (0..<4).map { TabBarItem(title: "Note \($0)", isDirty: false) }
        bar.setItems(tabs, selectedIndex: 0)
        bar.layoutSubtreeIfNeeded()

        bar.beginDragForTesting(index: 1)
        let xBeforeResize = try XCTUnwrap(bar.draggedTabXForTesting)

        bar.frame = NSRect(x: 0, y: 0, width: 300, height: TabBarView.height)
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.draggedTabXForTesting, xBeforeResize,
                       "a resize mid-drag must not move the dragged tab")

        // ⌘W while dragging pushes a shorter item list — the drag can no
        // longer trust its slots, so it is dropped rather than crashing.
        bar.setItems(Array(tabs.dropLast()), selectedIndex: 0)
        XCTAssertNil(bar.draggedTabXForTesting, "the count change cancelled the drag")
    }

    /// Reordering should respond once the dragged tab reaches the boundary
    /// between adjacent resting slots. Requiring it to reach the next slot's
    /// centre makes the gesture feel as though it has not started.
    @MainActor
    func testDragChangesSlotAfterHalfATabOfTravel() throws {
        _ = NSApplication.shared
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 600, height: TabBarView.height))
        let tabs = (0..<3).map { TabBarItem(title: "Note \($0)", isDirty: false) }
        bar.setItems(tabs, selectedIndex: 0)
        bar.layoutSubtreeIfNeeded()

        bar.beginDragForTesting(index: 0)
        let startX = try XCTUnwrap(bar.draggedTabXForTesting)
        // Tabs have a 110 pt minimum width. Moving 60 pt is just over half a
        // tab, enough for its trailing edge to cross the next tab's centre.
        bar.updateDragForTesting(pointerX: startX + 55 + 60)

        XCTAssertEqual(try XCTUnwrap(bar.draggedTabXForTesting), startX + 60,
                       accuracy: 0.5, "the tab stays attached to its grab point")
        XCTAssertEqual(bar.draggedTabSlotForTesting, 1)

        // Crossing the same boundary in reverse restores the original slot,
        // without a wide dead zone or oscillation around the midpoint.
        bar.updateDragForTesting(pointerX: startX + 55 + 54)
        XCTAssertEqual(bar.draggedTabSlotForTesting, 0)

        // End the synthetic drag by changing the item count, the same safe
        // cancellation route covered by the lifecycle test above.
        bar.setItems(Array(tabs.dropLast()), selectedIndex: 0)
    }

    /// One press-and-drag on a background tab must both select and move it.
    /// The press selects, as it does in every browser; the same press keeps
    /// dragging even though selection has meanwhile rebuilt the strip.
    @MainActor
    func testBackgroundTabSelectsAndReordersInOneGesture() throws {
        _ = NSApplication.shared
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 600, height: TabBarView.height))
        let tabs = (0..<3).map { TabBarItem(title: "Note \($0)", isDirty: false) }
        bar.setItems(tabs, selectedIndex: 0)
        bar.layoutSubtreeIfNeeded()

        final class RecordingDelegate: TabBarViewDelegate {
            let tabs: [TabBarItem]
            var selections: [Int] = []
            var moved: (from: Int, to: Int)?

            init(tabs: [TabBarItem]) { self.tabs = tabs }

            func tabBar(_ bar: TabBarView, didSelect index: Int) {
                selections.append(index)
                // Match MainWindowController: selection pushes refreshed tab
                // state back into the bar during the same gesture.
                MainActor.assumeIsolated {
                    bar.setItems(tabs, selectedIndex: index)
                }
            }
            func tabBar(_ bar: TabBarView, didRequestCloseAt index: Int) {}
            func tabBarDidRequestNewTab(_ bar: TabBarView) {}
            func tabBar(_ bar: TabBarView, didMove index: Int, to newIndex: Int) {
                moved = (index, newIndex)
            }
        }

        let recorder = RecordingDelegate(tabs: tabs)
        bar.delegate = recorder

        let downPoint = NSPoint(x: 140, y: TabBarView.height / 2)
        let draggedPoint = NSPoint(x: 45, y: downPoint.y)
        let tab = try XCTUnwrap(bar.hitTest(downPoint))

        func event(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: bar.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
        }

        tab.mouseDown(with: try event(.leftMouseDown, at: downPoint))
        XCTAssertEqual(recorder.selections, [1], "the press selects straight away")

        tab.mouseDragged(with: try event(.leftMouseDragged, at: draggedPoint))
        XCTAssertEqual(recorder.selections, [1], "dragging must not re-select")
        XCTAssertEqual(bar.draggedTabSlotForTesting, 0,
                       "the drag is underway even though selection rebuilt the strip")

        tab.mouseUp(with: try event(.leftMouseUp, at: draggedPoint))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(recorder.moved?.from, 1)
        XCTAssertEqual(recorder.moved?.to, 0)
    }

    /// The gesture above, driven through the real event queue. `mouseDown`
    /// must enter its tracking loop and dequeue the drag and the mouse-up
    /// itself — the routing AppKit would otherwise use does not survive the
    /// hierarchy rebuild that selecting a background tab causes.
    @MainActor
    func testTrackingLoopCarriesTheDragThroughSelection() throws {
        let harness = try TabDragLoopHarness()

        NSApp.postEvent(try harness.mouseEvent(.leftMouseDragged, at: harness.draggedPoint), atStart: false)
        NSApp.postEvent(try harness.mouseEvent(.leftMouseUp, at: harness.draggedPoint), atStart: false)

        harness.tab.mouseDown(with: try harness.mouseEvent(.leftMouseDown, at: harness.downPoint))

        XCTAssertEqual(harness.recorder.selections, [1], "the press selected before the loop ran")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(harness.recorder.moved?.from, 1)
        XCTAssertEqual(harness.recorder.moved?.to, 0)
    }

    /// The strip lives in the title-bar region. A press on a tab while the
    /// window is not key must reach the tab, not the frame view — otherwise
    /// it activates the window and a drag moves the window, and the user
    /// has to press a second time to drag the tab.
    @MainActor
    func testTabAcceptsTheActivatingFirstClick() throws {
        let harness = try TabDragLoopHarness()
        let event = try harness.mouseEvent(.leftMouseDown, at: harness.downPoint)
        XCTAssertTrue(harness.tab.acceptsFirstMouse(for: event))
    }

    /// Esc during a real drag abandons it. Local key monitors are never
    /// called inside a nested tracking loop, so the loop has to notice the
    /// key itself; the tab stays selected and nothing is reordered.
    @MainActor
    func testTrackingLoopEscapeCancelsTheDrag() throws {
        let harness = try TabDragLoopHarness()

        NSApp.postEvent(try harness.mouseEvent(.leftMouseDragged, at: harness.draggedPoint), atStart: false)
        NSApp.postEvent(try harness.escapeEvent(), atStart: false)
        NSApp.postEvent(try harness.mouseEvent(.leftMouseUp, at: harness.draggedPoint), atStart: false)

        harness.tab.mouseDown(with: try harness.mouseEvent(.leftMouseDown, at: harness.downPoint))

        XCTAssertEqual(harness.recorder.selections, [1], "Esc cancels the move, not the selection")
        XCTAssertNil(harness.bar.draggedTabXForTesting, "the drag session is gone")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNil(harness.recorder.moved, "nothing was reordered")
    }

    // MARK: - Carried over from Jot

    /// Notes written before the rename hold `jot://` tokens. They still find
    /// their picture, and the next save quietly writes the new scheme.
    func testALegacyJotTokenStillRendersAndIsRewrittenOnTheWayOut() throws {
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let id = try XCTUnwrap(assets.importImageData(makePNGData(), preferredExtension: "png"))

        let legacy = "before ![](jot://\(id)) after"
        XCTAssertEqual(NoteText.assetIDs(in: legacy), [id])

        let rendered = NoteText.render(legacy, attributes: [:], assets: assets)
        XCTAssertEqual(attachmentIDs(in: rendered), [id])

        // Serializing writes the new scheme, so a round trip brings the file
        // up to date rather than preserving the old spelling.
        XCTAssertEqual(NoteText.serialize(rendered), "before ![](nota://\(id)) after")
        XCTAssertEqual(NoteText.token(for: id), "![](nota://\(id))")

        // The old scheme is just as strict as the new one.
        for malformed in ["![](jot://", "![](jot://)", "![](jot://noextension)"] {
            let rendered = NoteText.render(malformed, attributes: [:], assets: assets)
            XCTAssertTrue(attachmentIDs(in: rendered).isEmpty, "should not match: \(malformed)")
            XCTAssertEqual(NoteText.serialize(rendered), malformed)
        }

        XCTAssertEqual(NoteText.assetID(fromTokenURL: "jot://\(id)"), id)
        XCTAssertEqual(NoteText.assetID(fromTokenURL: "nota://\(id)"), id)
        XCTAssertNil(NoteText.assetID(fromTokenURL: "https://example.com/x.png"))
        XCTAssertNil(NoteText.assetID(fromTokenURL: "nota://"))
    }

    /// The first launch under the new name moves the whole support directory
    /// across, so the notes are exactly where they were.
    func testTheSupportDirectoryMovesOverFromTheOldName() throws {
        let manager = FileManager.default
        let root = try makeTemporaryDirectory()
        let legacy = root.appendingPathComponent("Jot", isDirectory: true)
        try manager.createDirectory(
            at: legacy.appendingPathComponent("assets", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: legacy.appendingPathComponent("session.json"))

        let resolved = SessionStore.supportDirectory(in: root)
        XCTAssertEqual(resolved.lastPathComponent, "Nota")
        XCTAssertFalse(manager.fileExists(atPath: legacy.path), "the old directory is gone")
        XCTAssertTrue(manager.fileExists(
            atPath: resolved.appendingPathComponent("session.json").path
        ))
        XCTAssertTrue(manager.fileExists(
            atPath: resolved.appendingPathComponent("assets").path
        ))

        // And a store pointed at that root reads the carried-over session.
        let store = SessionStore(applicationSupport: root)
        XCTAssertEqual(store.directory, resolved)
    }

    /// The move happens once. A directory already under the new name is left
    /// alone even when an old one is somehow still sitting beside it, so no
    /// note written since the rename can be overwritten.
    func testTheSupportDirectoryIsNeverMovedTwiceAndIsMadeFreshOtherwise() throws {
        let manager = FileManager.default
        let root = try makeTemporaryDirectory()
        let legacy = root.appendingPathComponent("Jot", isDirectory: true)
        let current = root.appendingPathComponent("Nota", isDirectory: true)
        try manager.createDirectory(at: legacy, withIntermediateDirectories: true)
        try manager.createDirectory(at: current, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: current.appendingPathComponent("session.json"))
        try Data("old".utf8).write(to: legacy.appendingPathComponent("session.json"))

        XCTAssertEqual(SessionStore.supportDirectory(in: root), current)
        XCTAssertEqual(
            try String(contentsOf: current.appendingPathComponent("session.json"), encoding: .utf8),
            "new"
        )
        XCTAssertTrue(manager.fileExists(atPath: legacy.path), "the old one is left where it is")

        // A machine that never ran the old app just gets the new directory.
        let clean = try makeTemporaryDirectory()
        XCTAssertEqual(
            SessionStore.supportDirectory(in: clean).lastPathComponent, "Nota"
        )
    }

    /// The bundle identifier changed with the name, which moves `UserDefaults`
    /// to a domain of its own. Every setting is copied across on first launch.
    func testSettingsAreCarriedOverFromTheOldDefaultsDomain() throws {
        let suite = "NotaTests-\(UUID().uuidString)"
        let legacyDomain = "NotaTests-legacy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            defaults.removePersistentDomain(forName: legacyDomain)
        }

        // What the old build left behind.
        let old = try XCTUnwrap(UserDefaults(suiteName: legacyDomain))
        let preferences = Preferences(defaults: old)
        preferences.fontFamily = .serif
        preferences.showsLineNumbers = false
        preferences.fontSize = 21
        XCTAssertTrue(old.synchronize())

        // Before the migration the new domain knows nothing.
        XCTAssertEqual(Preferences(defaults: defaults).fontFamily, .system)

        XCTAssertTrue(Preferences.migrateFromJotIfNeeded(
            defaults: defaults, legacyDomain: legacyDomain
        ))
        let carried = Preferences(defaults: defaults)
        XCTAssertEqual(carried.fontFamily, .serif)
        XCTAssertFalse(carried.showsLineNumbers)
        XCTAssertEqual(carried.fontSize, 21)

        // It runs once: a setting changed since is not overwritten by the
        // old value on the next launch.
        carried.fontFamily = .rounded
        XCTAssertFalse(Preferences.migrateFromJotIfNeeded(
            defaults: defaults, legacyDomain: legacyDomain
        ))
        XCTAssertEqual(Preferences(defaults: defaults).fontFamily, .rounded)
    }

    /// A fresh install has nothing to carry over, and must not be left
    /// probing the old domain on every launch.
    func testAFreshInstallCarriesNothingOverButStillMarksItselfDone() throws {
        let suite = "NotaTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(Preferences.migrateFromJotIfNeeded(
            defaults: defaults, legacyDomain: "NotaTests-absent-\(UUID().uuidString)"
        ))
        XCTAssertEqual(Preferences(defaults: defaults).fontFamily, .system)
        XCTAssertEqual(defaults.object(forKey: "migratedFromJot") as? Bool, true)
    }

    /// A copy taken from a build from before the rename is still on the
    /// pasteboard under the old flavour, and still pastes as an image.
    @MainActor
    func testACopyUnderTheOldPasteboardFlavourIsStillRead() throws {
        _ = NSApplication.shared
        let assets = AssetStore(directory: try makeTemporaryDirectory())
        let id = try XCTUnwrap(assets.importImageData(makePNGData(), preferredExtension: "png"))
        let view = makeTextView(assets: assets)

        let board = makePasteboard()
        board.clearContents()
        board.declareTypes([.legacyJotNote], owner: nil)
        board.setString("![](jot://\(id))", forType: .legacyJotNote)

        // It is preferred over plain text, just as the new flavour is.
        XCTAssertEqual(
            view.preferredPasteboardType(
                from: board.types ?? [], restrictedToTypesFrom: view.readablePasteboardTypes
            ),
            .legacyJotNote
        )
        XCTAssertTrue(view.readSelection(from: board, type: .legacyJotNote))
        XCTAssertEqual(attachmentIDs(in: try XCTUnwrap(view.textStorage)), [id])
        // Relinked, not imported a second time.
        XCTAssertEqual(try assetFileCount(assets), 1)

        // The new flavour still wins when both are on the board.
        XCTAssertEqual(view.writablePasteboardTypes.first, .notaNote)
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
            if let attachment = value as? NotaImageAttachment { ids.append(attachment.assetID) }
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
        NSPasteboard(name: NSPasteboard.Name("NotaTests-\(UUID().uuidString)"))
    }

    /// Lends the real clipboard out and puts back what was on it. `copy(_:)`
    /// writes to `NSPasteboard.general` and nowhere else, so testing the
    /// action itself means borrowing it rather than using a private board.
    private func withGeneralPasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        defer {
            board.clearContents()
            if !saved.isEmpty { board.writeObjects(saved) }
        }
        try body(board)
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

    private func makeTextView(assets: AssetStore) -> NotaTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        let view = NotaTextView(
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
            .appendingPathComponent("NotaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}

/// Sets up a real `NSWindow` around a tab strip so `TabItemView.mouseDown`
/// finds an event queue to track. The window is never ordered front; it only
/// has to exist and have a window number the posted events can carry.
@MainActor
private final class TabDragLoopHarness {
    /// Mimics `MainWindowController`: selecting pushes refreshed tab state
    /// back into the bar, rebuilding the strip in the middle of the gesture.
    final class RecordingDelegate: TabBarViewDelegate {
        let tabs: [TabBarItem]
        var selections: [Int] = []
        var moved: (from: Int, to: Int)?

        init(tabs: [TabBarItem]) { self.tabs = tabs }

        func tabBar(_ bar: TabBarView, didSelect index: Int) {
            selections.append(index)
            MainActor.assumeIsolated {
                bar.setItems(tabs, selectedIndex: index)
            }
        }
        func tabBar(_ bar: TabBarView, didRequestCloseAt index: Int) {}
        func tabBarDidRequestNewTab(_ bar: TabBarView) {}
        func tabBar(_ bar: TabBarView, didMove index: Int, to newIndex: Int) {
            moved = (index, newIndex)
        }
    }

    let window: NSWindow
    let bar: TabBarView
    let recorder: RecordingDelegate
    let tab: NSView
    /// Inside the second tab, and far enough left of it to land on slot 0.
    let downPoint = NSPoint(x: 140, y: TabBarView.height / 2)
    let draggedPoint = NSPoint(x: 45, y: TabBarView.height / 2)

    init() throws {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 600, height: TabBarView.height)
        window = NSWindow(contentRect: frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
        bar = TabBarView(frame: frame)
        window.contentView = bar

        let tabs = (0..<3).map { TabBarItem(title: "Note \($0)", isDirty: false) }
        bar.setItems(tabs, selectedIndex: 0)
        bar.layoutSubtreeIfNeeded()

        recorder = RecordingDelegate(tabs: tabs)
        bar.delegate = recorder
        tab = try XCTUnwrap(bar.hitTest(downPoint))
    }

    func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: bar.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        ))
    }

    func escapeEvent() throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53
        ))
    }
}
