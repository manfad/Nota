import AppKit
import Foundation
import WebKit
import XCTest
@testable import Nota

/// The one preview Nota does not draw itself. A `.html` tab is a tab like a
/// `.md` one — the same three modes, the same control, the same setting — and
/// unlike it the page beside the source is the author's own, drawn by WebKit
/// with its own stylesheets, colours and scripts.
final class HTMLPreviewTests: XCTestCase {
    private var temporaryDirectories: [URL] = []
    private var windows: [NSWindow] = []

    @MainActor
    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows = []
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
        super.tearDown()
    }

    // MARK: - What counts as HTML

    func testAPageIsKnownByItsSpellingWhateverCaseItIsIn() throws {
        for spelling in ["html", "htm", "HTML", "Htm"] {
            XCTAssertEqual(RenderedPreviewKind(fileExtension: spelling), .html,
                           "\(spelling) is a page")
        }
        for spelling in ["css", "js", "txt", "json", "xml"] {
            XCTAssertNil(RenderedPreviewKind(fileExtension: spelling),
                         "\(spelling) is source, and source has no preview")
        }
    }

    func testAPageIsAPreviewTabAndAnUntitledNoteIsNot() throws {
        let page = makeNote(named: "page.html", text: "<p>hi</p>")
        XCTAssertEqual(page.previewKind, .html)
        XCTAssertTrue(page.supportsRenderedPreview)
        XCTAssertTrue(page.hasPreviewContent)

        let stylesheet = makeNote(named: "page.css", text: "body {}")
        XCTAssertNil(stylesheet.previewKind, "a stylesheet is source beside the page")

        let untitled = Note(fileURL: nil, untitledName: "Untitled", text: "<p>hi</p>",
                            attributes: [:], assets: nil)
        XCTAssertNil(untitled.previewKind, "Save As to .html is what makes one")
        XCTAssertFalse(untitled.hasPreviewContent)
    }

    // MARK: - Which pane is in front

    @MainActor
    func testThePageIsTheColumnsThirdContent() throws {
        _ = NSApplication.shared
        XCTAssertEqual(PreviewContentKind(makeNote(named: "page.html", text: "")), .html)
        XCTAssertEqual(PreviewContentKind(makeNote(named: "notes.md", text: "")), .markdown)
        XCTAssertEqual(PreviewContentKind(makeNote(named: "paper.tex", text: "")), .latex)

        let column = PreviewPaneView(zenTopInset: 28)
        column.bringForward(makeNote(named: "page.html", text: ""))
        XCTAssertEqual(column.panes.kind, .html)
        XCTAssertFalse(column.panes.html.isHidden)
        XCTAssertTrue(column.panes.markdown.isHidden)
        XCTAssertTrue(column.panes.latex.isHidden)
        XCTAssertTrue(column.panes.pdf.isHidden)

        column.bringForward(makeNote(named: "notes.md", text: ""))
        XCTAssertEqual(column.panes.kind, .markdown)
        XCTAssertTrue(column.panes.html.isHidden, "and it waits behind the render again")
    }

    // MARK: - The page is the note's own text

    @MainActor
    func testThePaneShowsWhatTheEditorHoldsRatherThanWhatIsOnDisk() throws {
        let (pane, _) = try makePane()
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("page.html")
        try "<!doctype html><title>On disk</title><p>On disk</p>"
            .write(to: file, atomically: true, encoding: .utf8)

        let note = Note(fileURL: file, untitledName: nil,
                        text: "<!doctype html><title>Unsaved</title><p>Unsaved</p>",
                        attributes: [:], assets: nil)
        try show(note, in: pane)

        XCTAssertEqual(try string("document.title", in: pane), "Unsaved")
        XCTAssertEqual(try string("document.body.innerText.trim()", in: pane), "Unsaved")
        XCTAssertEqual(pane.shownBaseURL, PageFiles.pageURL(file),
                       "so a relative URL resolves beside the file")
        XCTAssertEqual(PageFiles.fileURL(try XCTUnwrap(pane.shownBaseURL)), file)
    }

    @MainActor
    func testAStylesheetBesideTheFileApplies() throws {
        let (pane, _) = try makePane()
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("page.html")
        try "body { background-color: rgb(1, 2, 3); }"
            .write(to: directory.appendingPathComponent("style.css"),
                   atomically: true, encoding: .utf8)
        try Data().write(to: file)

        let note = Note(
            fileURL: file, untitledName: nil,
            text: """
            <!doctype html>
            <link rel="stylesheet" href="style.css">
            <p>Styled</p>
            """,
            attributes: [:], assets: nil
        )
        try show(note, in: pane)

        XCTAssertEqual(
            try string("getComputedStyle(document.body).backgroundColor", in: pane),
            "rgb(1, 2, 3)",
            "the page brings its own CSS, from beside the file"
        )
    }

    /// The one test that would have caught the pane shipping unstyled.
    ///
    /// A page under a temporary folder loads its stylesheet whatever base URL
    /// it is given, because the process that draws it may read that folder
    /// anyway. Anywhere a reader actually keeps files, it may not. So this
    /// reads the example checked in beside the app, from the folder it really
    /// lives in.
    @MainActor
    func testAPageOutsideTheTemporaryFolderStillDrawsWhatIsBesideIt() throws {
        let (pane, _) = try makePane()
        let file = exampleURL("HTML.html")
        let note = Note(fileURL: file, untitledName: nil,
                        text: try String(contentsOf: file, encoding: .utf8),
                        attributes: [:], assets: nil)

        try show(note, in: pane)

        XCTAssertNotEqual(
            try string("getComputedStyle(document.body).backgroundColor", in: pane),
            "rgba(0, 0, 0, 0)",
            "HTML.css sits beside the page and paints its background"
        )
        XCTAssertGreaterThan(
            try number("document.images[0].naturalWidth", in: pane), 0,
            "and HTML.svg beside it is a picture, not a broken one"
        )
    }

    @MainActor
    func testTypingReloadsThePageAndShowingTheSameTextDoesNot() throws {
        let (pane, _) = try makePane()
        let file = try makeTemporaryDirectory().appendingPathComponent("page.html")
        try Data().write(to: file)
        let note = Note(fileURL: file, untitledName: nil, text: "<p>First</p>",
                        attributes: [:], assets: nil)

        try show(note, in: pane)
        XCTAssertEqual(pane.loadCount, 1)
        XCTAssertEqual(try string("document.body.innerText.trim()", in: pane), "First")

        // A resize, a tab switch and a settings change all ask again with the
        // text unmoved; a reload there would flash the page and lose the
        // scroll.
        pane.show(note, in: context())
        pane.show(note, in: context())
        XCTAssertEqual(pane.loadCount, 1, "nothing it is made from has moved")

        note.storage.replaceCharacters(
            in: NSRange(location: 0, length: note.storage.length), with: "<p>Second</p>"
        )
        try show(note, in: pane)
        XCTAssertEqual(pane.loadCount, 2)
        XCTAssertEqual(try string("document.body.innerText.trim()", in: pane), "Second")
    }

    @MainActor
    func testThePaneKeepsItsScrollAcrossAReload() throws {
        let (pane, _) = try makePane()
        let file = try makeTemporaryDirectory().appendingPathComponent("page.html")
        try Data().write(to: file)
        let note = Note(fileURL: file, untitledName: nil, text: tallPage(titled: "Line"),
                        attributes: [:], assets: nil)

        try show(note, in: pane)
        _ = try evaluate("window.scrollTo(0, 900);", in: pane)
        // The page reports where it has been scrolled to on its own frame, so
        // the pane has the number before the next load rather than after it.
        try waitForScrollReport(in: pane, of: note, toReach: 900)

        note.storage.replaceCharacters(
            in: NSRange(location: 0, length: note.storage.length),
            with: tallPage(titled: "Line", extra: "<p>And one more</p>")
        )
        try show(note, in: pane)

        XCTAssertEqual(try number("window.scrollY", in: pane), 900,
                       "an edit is not a reason to throw the reader back to the top")
    }

    /// The pane is one view every `.html` tab is read through, so the scroll
    /// it keeps has to be each tab's own.
    @MainActor
    func testEachTabKeepsItsOwnScrollThroughTheOnePane() throws {
        let (pane, _) = try makePane()
        let directory = try makeTemporaryDirectory()
        let first = directory.appendingPathComponent("first.html")
        let second = directory.appendingPathComponent("second.html")
        try Data().write(to: first)
        try Data().write(to: second)
        let one = Note(fileURL: first, untitledName: nil, text: tallPage(titled: "One"),
                       attributes: [:], assets: nil)
        let two = Note(fileURL: second, untitledName: nil, text: tallPage(titled: "Two"),
                       attributes: [:], assets: nil)

        try show(one, in: pane)
        _ = try evaluate("window.scrollTo(0, 2000);", in: pane)
        try waitForScrollReport(in: pane, of: one, toReach: 2000)

        try show(two, in: pane)
        XCTAssertEqual(try number("window.scrollY", in: pane), 0,
                       "a tab you have not read yet opens at the top of its page")
        XCTAssertEqual(pane.rememberedScroll(ofTab: one.id).y, 2000,
                       "and reading another tab does not overwrite where the first was left")

        try show(one, in: pane)
        XCTAssertEqual(try number("window.scrollY", in: pane), 2000,
                       "coming back lands where the tab was left")
    }

    // MARK: - What the pane costs

    /// Every window has one of these panes whether or not it ever opens a
    /// `.html` file, and a web view is a pair of processes rather than a view.
    @MainActor
    func testNoWebViewExistsUntilThereIsAPageToShow() throws {
        let (pane, _) = try makePane()
        XCTAssertNil(pane.webView, "a window of Markdown notes never starts WebKit")
        XCTAssertEqual(pane.loadCount, 0)
        XCTAssertFalse(pane.focus(in: pane.window), "and nothing there can take the keyboard")

        let file = try makeTemporaryDirectory().appendingPathComponent("page.html")
        try Data().write(to: file)
        try show(Note(fileURL: file, untitledName: nil, text: "<p>Here</p>",
                      attributes: [:], assets: nil), in: pane)
        XCTAssertNotNil(pane.webView)
    }

    /// In the editor mode the column is away, and a page loaded off screen on
    /// every keystroke is a page nobody is reading.
    @MainActor
    func testAPageIsNotLoadedWhileTheColumnIsAway() throws {
        let (pane, _) = try makePane()
        let file = try makeTemporaryDirectory().appendingPathComponent("page.html")
        try Data().write(to: file)
        let note = Note(fileURL: file, untitledName: nil, text: "<p>Waiting</p>",
                        attributes: [:], assets: nil)

        pane.show(note, in: context(isVisible: false))
        pane.show(note, in: context(isVisible: false))
        XCTAssertEqual(pane.loadCount, 0)
        XCTAssertNil(pane.webView)

        // And the mode that brings the column back loads it on the way in.
        try show(note, in: pane)
        XCTAssertEqual(pane.loadCount, 1)
        XCTAssertEqual(try string("document.body.innerText.trim()", in: pane), "Waiting")
    }

    // MARK: - Where a link goes

    func testALinkOutOfThePaneGoesBackToBeingAFile() throws {
        let file = URL(fileURLWithPath: "/tmp/site/style.css")
        let page = try XCTUnwrap(PageFiles.pageURL(file))
        XCTAssertEqual(page.scheme, "nota-file")
        XCTAssertEqual(page.path, "/tmp/site/style.css")
        XCTAssertEqual(PageFiles.linkDestination(of: page), file,
                       "the browser is handed a file, not a scheme only Nota knows")

        let elsewhere = try XCTUnwrap(URL(string: "https://example.com/a"))
        XCTAssertEqual(PageFiles.linkDestination(of: elsewhere), elsewhere)
    }

    func testAnInPageAnchorStaysAndEverythingElseGoesToTheBrowser() throws {
        let page = try XCTUnwrap(PageFiles.pageURL(URL(fileURLWithPath: "/tmp/site/page.html")))

        XCTAssertEqual(
            HTMLPreviewView.policy(for: URL(string: "#section", relativeTo: page)?.absoluteURL,
                                   navigationType: .linkActivated, currentURL: page),
            .stays
        )
        XCTAssertEqual(
            HTMLPreviewView.policy(for: URL(string: "https://example.com"),
                                   navigationType: .linkActivated, currentURL: page),
            .leaves
        )
        XCTAssertEqual(
            HTMLPreviewView.policy(for: PageFiles.pageURL(URL(fileURLWithPath: "/tmp/site/other.html")),
                                   navigationType: .linkActivated, currentURL: page),
            .leaves,
            "another file is somewhere else, and somewhere else is the browser's"
        )
        XCTAssertEqual(
            HTMLPreviewView.policy(for: URL(string: "mailto:someone@example.com"),
                                   navigationType: .linkActivated, currentURL: page),
            .leaves
        )
        // Not a link at all: the loads the pane itself asks for, and whatever
        // the page's own scripts are doing.
        XCTAssertEqual(
            HTMLPreviewView.policy(for: page, navigationType: .other, currentURL: nil),
            .stays
        )
    }

    @MainActor
    func testClickingAnExternalLinkHandsTheURLOverWithoutLeavingThePage() throws {
        let (pane, _) = try makePane()
        let file = try makeTemporaryDirectory().appendingPathComponent("page.html")
        try Data().write(to: file)
        let note = Note(
            fileURL: file, untitledName: nil,
            text: """
            <!doctype html>
            <p id="top">Top</p>
            <a id="away" href="https://example.com/somewhere">Away</a>
            """,
            attributes: [:], assets: nil
        )
        var handed: [URL] = []
        pane.openExternal = { handed.append($0) }
        try show(note, in: pane)

        _ = try evaluate("document.getElementById('away').click();", in: pane)
        let opened = expectation(description: "the link reached the browser")
        opened.assertForOverFulfill = false
        let poll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            if !handed.isEmpty { opened.fulfill() }
        }
        wait(for: [opened], timeout: 5)
        poll.invalidate()

        XCTAssertEqual(handed.map(\.absoluteString), ["https://example.com/somewhere"])
        XCTAssertEqual(pane.loadCount, 1, "and the page under it never moved")
        XCTAssertEqual(try string("document.getElementById('top').innerText", in: pane), "Top")
    }

    /// A link to another local file leaves the pane too, and leaves it as a
    /// file: the scheme the page is read under is this pane's business and
    /// means nothing to a browser.
    @MainActor
    func testClickingALinkToASiblingFileHandsOverAFileURL() throws {
        let (pane, _) = try makePane()
        let file = exampleURL("HTML.html")
        var handed: [URL] = []
        pane.openExternal = { handed.append($0) }
        try show(Note(fileURL: file, untitledName: nil,
                      text: try String(contentsOf: file, encoding: .utf8),
                      attributes: [:], assets: nil), in: pane)

        _ = try evaluate("document.querySelector('a[href=\"HTML.css\"]').click();", in: pane)
        let opened = expectation(description: "the link reached the browser")
        opened.assertForOverFulfill = false
        let poll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            if !handed.isEmpty { opened.fulfill() }
        }
        wait(for: [opened], timeout: 5)
        poll.invalidate()

        XCTAssertEqual(handed.first, exampleURL("HTML.css"))
    }

    // MARK: - The keyboard

    @MainActor
    func testThePageTakesTheKeyboardInReadingModeAndNowhereElse() throws {
        let (pane, window) = try makePane()
        let file = try makeTemporaryDirectory().appendingPathComponent("page.html")
        try Data().write(to: file)
        try show(Note(fileURL: file, untitledName: nil, text: "<p>Read me</p>",
                      attributes: [:], assets: nil), in: pane)

        // Split and the editor mode: the caret belongs to the text beside the
        // page, so the page refuses the keyboard outright.
        let webView = try page(of: pane)
        pane.takesKeyboard = false
        XCTAssertFalse(webView.acceptsFirstResponder)
        window.makeFirstResponder(webView)
        XCTAssertFalse(window.firstResponder === webView)

        pane.takesKeyboard = true
        XCTAssertTrue(webView.acceptsFirstResponder)
        XCTAssertTrue(pane.focus(in: window))
        XCTAssertTrue(window.firstResponder === webView)
    }

    @MainActor
    func testAClickInTheSplitPaneLeavesTheCaretInTheEditor() throws {
        _ = NSApplication.shared
        let directory = try makeTemporaryDirectory()
        let controller = try makeController(showing: "page.html",
                                            text: "<p>Beside the editor</p>", in: directory)
        controller.setPreviewMode(.split)
        controller.window?.layoutIfNeeded()
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFrontOffscreen()
        windows.append(window)
        let editor = try editorTextView(of: controller)
        XCTAssertTrue(window.makeFirstResponder(editor))

        click(in: try page(of: controller.previewPanes.html), of: window)

        XCTAssertTrue(window.firstResponder === editor,
                      "the page is read beside the note, not typed in")
    }

    // MARK: - A drawing is a page too

    /// An `.svg` is text you edit, with the drawing beside it — the same
    /// arrangement a `.html` has, drawn by the same pane.
    @MainActor
    func testADrawingIsReadThroughThePageAndNotAsAPicture() throws {
        _ = NSApplication.shared
        let drawing = makeNote(named: "logo.svg", text: "<svg/>")
        XCTAssertEqual(drawing.previewKind, .svg)
        XCTAssertEqual(PreviewContentKind(drawing), .html, "the same pane draws both")
        XCTAssertNil(Note.viewerKind(URL(fileURLWithPath: "/tmp/logo.svg")),
                     "and never a picture tab, whatever the system files it under")

        let column = PreviewPaneView(zenTopInset: 28)
        column.bringForward(drawing)
        XCTAssertEqual(column.panes.kind, .html)
    }

    /// Handed over as HTML, an `.svg` would be parsed by the HTML rules and
    /// the root `<svg>` would end up inside a `<body>` the file never had.
    @MainActor
    func testADrawingIsLoadedAsADrawingRatherThanAsAPage() throws {
        let (pane, _) = try makePane()
        let file = exampleURL("Drawing.svg")
        try show(Note(fileURL: file, untitledName: nil,
                      text: try String(contentsOf: file, encoding: .utf8),
                      attributes: [:], assets: nil), in: pane)

        XCTAssertEqual(try string("document.documentElement.tagName", in: pane), "svg",
                       "the drawing is the document, not a tag inside a page")
        XCTAssertEqual(try string("document.contentType", in: pane), "image/svg+xml")
        XCTAssertEqual(try string("document.querySelector('title').textContent", in: pane),
                       "SVG in Nota")
    }

    @MainActor
    func testEditingADrawingRedrawsIt() throws {
        let (pane, _) = try makePane()
        let file = try makeTemporaryDirectory().appendingPathComponent("logo.svg")
        try Data().write(to: file)
        let note = Note(
            fileURL: file, untitledName: nil,
            text: "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"20\"/>",
            attributes: [:], assets: nil
        )
        try show(note, in: pane)
        XCTAssertEqual(try string("document.documentElement.getAttribute('width')", in: pane), "40")

        note.storage.replaceCharacters(
            in: NSRange(location: 0, length: note.storage.length),
            with: "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"90\" height=\"20\"/>"
        )
        try show(note, in: pane)
        XCTAssertEqual(try string("document.documentElement.getAttribute('width')", in: pane), "90")
        XCTAssertEqual(pane.loadCount, 2)
    }

    func testTheViewItemIsCalledSVGPreviewOnADrawingTab() throws {
        XCTAssertEqual(RenderedPreviewKind.previewMenuTitle(.svg), "SVG Preview")
        XCTAssertEqual(RenderedPreviewKind(fileExtension: "svg"), .svg)
        XCTAssertEqual(RenderedPreviewKind(fileExtension: "SVG"), .svg)
    }

    @MainActor
    func testTheReadingModeSettingCoversDrawingsToo() throws {
        _ = NSApplication.shared
        let previous = Preferences.shared.opensMarkdownInReadingMode
        defer { Preferences.shared.opensMarkdownInReadingMode = previous }
        Preferences.shared.opensMarkdownInReadingMode = true

        let directory = try makeTemporaryDirectory()
        let controller = try makeController(showing: "start.html", text: "<p>hi</p>",
                                            in: directory)
        let drawing = directory.appendingPathComponent("logo.svg")
        try "<svg xmlns=\"http://www.w3.org/2000/svg\"/>"
            .write(to: drawing, atomically: true, encoding: .utf8)

        controller.open(url: drawing)
        XCTAssertEqual(controller.previewMode, .reading)
        XCTAssertEqual(controller.currentRenderedPreviewKind, .svg)
        XCTAssertEqual(controller.previewPanes.kind, .html)
        XCTAssertEqual(controller.currentTabState.kind, .text,
                       "it is text in the editor, whatever the drawing beside it looks like")
    }

    // MARK: - The tab around it

    @MainActor
    func testThePageHasTheSameThreeModesAsAMarkdownTab() throws {
        _ = NSApplication.shared
        let controller = try makeController(showing: "page.html", text: "<p>hi</p>",
                                            in: try makeTemporaryDirectory())
        XCTAssertTrue(controller.canShowRenderedPreview)
        XCTAssertEqual(controller.currentRenderedPreviewKind, .html)
        XCTAssertEqual(controller.previewMode, .off)

        controller.toggleMarkdownPreview()
        XCTAssertEqual(controller.previewMode, .split)
        XCTAssertTrue(controller.previewState.isVisible)
        XCTAssertEqual(controller.previewPanes.kind, .html)

        controller.toggleMarkdownPreview()
        XCTAssertEqual(controller.previewMode, .reading)
        controller.toggleReadingMode()
        XCTAssertEqual(controller.previewMode, .off)
    }

    @MainActor
    func testTheViewItemIsCalledHTMLPreviewOnAPageTab() throws {
        _ = NSApplication.shared
        let controller = try makeController(showing: "page.html", text: "<p>hi</p>",
                                            in: try makeTemporaryDirectory())
        XCTAssertEqual(controller.currentRenderedPreviewKind, .html)
        XCTAssertEqual(
            RenderedPreviewKind.previewMenuTitle(controller.currentRenderedPreviewKind),
            "HTML Preview"
        )
        XCTAssertEqual(RenderedPreviewKind.previewMenuTitle(.latex), "LaTeX Preview")
        XCTAssertEqual(RenderedPreviewKind.previewMenuTitle(.markdown), "Markdown Preview")
        XCTAssertEqual(RenderedPreviewKind.previewMenuTitle(nil), "Markdown Preview",
                       "a tab with no preview reads the plain name, greyed out")
    }

    @MainActor
    func testTheReadingModeSettingIsNamedForAllThree() throws {
        let controller = SettingsWindowController.shared
        _ = controller.window
        let checkbox = try XCTUnwrap(
            descendant(of: try XCTUnwrap(controller.window?.contentView), ofType: NSButton.self) {
                $0.title.hasPrefix("Open Markdown")
            }
        )
        XCTAssertEqual(checkbox.title, "Open Markdown, LaTeX and HTML files in reading mode")
    }

    @MainActor
    func testTheReadingModeSettingCoversHTMLFilesToo() throws {
        _ = NSApplication.shared
        let previous = Preferences.shared.opensMarkdownInReadingMode
        defer { Preferences.shared.opensMarkdownInReadingMode = previous }

        let directory = try makeTemporaryDirectory()
        let controller = try makeController(showing: "start.html", text: "<p>hi</p>",
                                            in: directory)
        let page = directory.appendingPathComponent("opened.html")
        try "<p>Opened</p>".write(to: page, atomically: true, encoding: .utf8)

        Preferences.shared.opensMarkdownInReadingMode = false
        controller.open(url: page)
        XCTAssertEqual(controller.previewMode, .off)

        Preferences.shared.opensMarkdownInReadingMode = true
        let second = directory.appendingPathComponent("again.htm")
        try "<p>Again</p>".write(to: second, atomically: true, encoding: .utf8)
        controller.open(url: second)
        XCTAssertEqual(controller.previewMode, .reading)
    }

    @MainActor
    func testAPageTabComesBackFromTheSessionInTheModeItWasLeftIn() throws {
        _ = NSApplication.shared
        let directory = try makeTemporaryDirectory()
        do {
            let controller = try makeController(showing: "page.html", text: "<p>hi</p>",
                                                in: directory)
            controller.setPreviewMode(.reading)
            controller.flushAll()
        }
        let relaunched = try makeController(showing: "page.html", text: "<p>hi</p>",
                                            in: directory)
        XCTAssertEqual(relaunched.previewMode, .reading)
        XCTAssertEqual(relaunched.previewPanes.kind, .html)
    }

    // MARK: - ⌘F over the page

    /// ⌘F in reading mode is the page's own pill, in the corner every column
    /// keeps its bars in. The editor's stays down: it is not on screen, and
    /// the page is what the reader is looking at.
    @MainActor
    func testCommandFOverThePageOpensThePagesOwnPill() throws {
        _ = NSApplication.shared
        let controller = try makeReadingController(
            text: "<p>alpha beta alpha</p>", in: try makeTemporaryDirectory()
        )
        let pane = controller.previewPanes.html
        let bar = try findBar(of: pane)
        XCTAssertEqual(bar.field.placeholderString, "Find in page")
        XCTAssertFalse(bar.isShown)
        XCTAssertFalse(bar.canReplace, "a preview is not a second place to edit the file")

        let view = try page(of: pane)
        XCTAssertTrue(view.validateUserInterfaceItem(finderItem(.showFindInterface)),
                      "the menu item has to stay enabled or ⌘F never arrives here")
        try find(.showFindInterface, in: pane)

        XCTAssertTrue(bar.isShown)
        XCTAssertTrue(pane.isFindBarVisible)
        let shown = allFindBars(in: controller).filter(\.isShown)
        XCTAssertEqual(shown.count, 1)
        XCTAssertTrue(shown.first === bar, "the editor's own bar stayed down")
    }

    /// Typing searches the page as you go: the count is exact, the match the
    /// reader is on wears the loud band and the quiet ones wear theirs.
    @MainActor
    func testTypingCountsTheMatchesInThePageAndBandsThem() throws {
        let (pane, _) = try makePane()
        try show(makeNote(named: "page.html", text: "<p>alpha beta</p><p>alpha</p><p>ALPHA</p>"),
                 in: pane)
        let bar = try findBar(of: pane)
        try find(.showFindInterface, in: pane)

        try type("alpha", into: bar, of: pane)

        XCTAssertEqual(bar.status, "1 of 3", "case makes no difference, as in every other bar")
        XCTAssertEqual(try number("CSS.highlights.get('nota-find').size", in: pane), 2,
                       "the two the reader is not on")
        XCTAssertEqual(try number("CSS.highlights.get('nota-find-current').size", in: pane), 1)
        XCTAssertEqual(
            try string("CSS.highlights.get('nota-find-current').values().next().value.toString()",
                       in: pane).lowercased(),
            "alpha",
            "and the loud band is over a match rather than anywhere"
        )
    }

    /// ⌘G walks the matches and wraps round the end of the page; ⇧⌘G walks
    /// them back. The count says exactly where the reader is, which is the
    /// whole reason the stepping is done in the page rather than by WebKit's
    /// own find.
    @MainActor
    func testCommandGStepsThroughThePageAndWraps() throws {
        let (pane, _) = try makePane()
        try show(makeNote(named: "page.html", text: "<p>alpha</p><p>alpha</p><p>alpha</p>"),
                 in: pane)
        let bar = try findBar(of: pane)
        try find(.showFindInterface, in: pane)
        try type("alpha", into: bar, of: pane)
        XCTAssertEqual(bar.status, "1 of 3")

        try find(.nextMatch, in: pane)
        XCTAssertEqual(bar.status, "2 of 3")
        try find(.nextMatch, in: pane)
        XCTAssertEqual(bar.status, "3 of 3")
        try find(.nextMatch, in: pane)
        XCTAssertEqual(bar.status, "1 of 3", "round the end")
        try find(.previousMatch, in: pane)
        XCTAssertEqual(bar.status, "3 of 3", "and round the other way")
    }

    /// The current match is brought into view: a hit ten screens down is
    /// scrolled to rather than counted at.
    @MainActor
    func testTheCurrentMatchIsScrolledTo() throws {
        let (pane, _) = try makePane()
        try show(
            makeNote(named: "page.html",
                     text: tallPage(titled: "Line", extra: "<p id=\"end\">alpha</p>")),
            in: pane
        )
        let bar = try findBar(of: pane)
        XCTAssertEqual(try number("window.scrollY", in: pane), 0)

        try find(.showFindInterface, in: pane)
        try type("alpha", into: bar, of: pane)

        XCTAssertEqual(bar.status, "1 of 1")
        XCTAssertGreaterThan(try number("window.scrollY", in: pane), 100,
                             "the page went to the match")
    }

    /// Escape puts the bands down and hands the match over: it stays visible
    /// as a real selection, and the keyboard goes back to the page.
    @MainActor
    func testEscapeClosesTheBarClearsTheBandsAndSelectsTheMatch() throws {
        let (pane, window) = try makePane()
        pane.takesKeyboard = true
        try show(makeNote(named: "page.html", text: "<p>alpha beta</p><p>alpha</p>"), in: pane)
        let bar = try findBar(of: pane)
        try find(.showFindInterface, in: pane)
        try type("alpha", into: bar, of: pane)
        XCTAssertEqual(try paintedMatches(in: pane).count, 2)

        try find(.hideFindInterface, in: pane)

        XCTAssertFalse(bar.isShown)
        XCTAssertFalse(pane.isFindBarVisible)
        XCTAssertEqual(try paintedMatches(in: pane), [], "the bands are down")
        XCTAssertEqual(try string("window.getSelection().toString()", in: pane).lowercased(),
                       "alpha", "and the match the reader was on is theirs")
        let responder = window.firstResponder as? NSView
        let view = try page(of: pane)
        XCTAssertTrue(responder === view || responder?.isDescendant(of: view) == true,
                      "the keyboard went back to the page")
    }

    /// Case- and diacritic-insensitive, the same as every other bar: `cafe`
    /// finds `Café`, and a match that runs across an inline element is still
    /// a match.
    @MainActor
    func testTheQueryIgnoresCaseAndAccentsAndCrossesTags() throws {
        let (pane, _) = try makePane()
        try show(makeNote(named: "page.html", text: "<p>Un caf\u{e9} noir</p><p>ca<b>fe</b></p>"),
                 in: pane)
        let bar = try findBar(of: pane)
        try find(.showFindInterface, in: pane)

        try type("cafe", into: bar, of: pane)
        XCTAssertEqual(bar.status, "1 of 2",
                       "the accented one and the one split across a tag")

        try type("CAFÉ", into: bar, of: pane)
        XCTAssertEqual(bar.status, "1 of 2", "and it reads the same the other way round")

        try type("zeta", into: bar, of: pane)
        XCTAssertEqual(bar.status, "No matches")
        XCTAssertEqual(try paintedMatches(in: pane), [])
    }

    /// In split the editor is on screen and has the keyboard, so ⌘F is the
    /// editor's bar and the page never sees the menu item at all.
    @MainActor
    func testInSplitModeCommandFIsStillTheEditorsBar() throws {
        _ = NSApplication.shared
        let controller = try makeReadingController(
            text: "<p>alpha</p>", in: try makeTemporaryDirectory()
        )
        let pane = controller.previewPanes.html
        let view = try page(of: pane)
        XCTAssertTrue(view.acceptsFirstResponder, "reading mode: the page has the keyboard")

        controller.setPreviewMode(.split)
        try XCTUnwrap(controller.window).layoutIfNeeded()
        XCTAssertFalse(view.acceptsFirstResponder,
                       "in split the caret is the editor's and so is ⌘F")

        let editor = try editorTextView(of: controller)
        editor.performTextFinderAction(finderItem(.showFindInterface))
        XCTAssertFalse(try findBar(of: pane).isShown, "the page's pill stayed down")
        let shown = allFindBars(in: controller).filter(\.isShown)
        XCTAssertEqual(shown.count, 1, "the editor's, and only that one")
        XCTAssertFalse(shown.first === (try findBar(of: pane)))
    }

    /// Find, Find Next, Find Previous and Use Selection all mean something
    /// over a page. Find and Replace… does not: a preview is not a second
    /// place to edit the file.
    @MainActor
    func testFindAndReplaceIsTheOneFindItemThePageTurnsDown() throws {
        let (pane, _) = try makePane()
        try show(makeNote(named: "page.html", text: "<p>alpha</p>"), in: pane)
        let view = try page(of: pane)

        for action in [NSTextFinder.Action.showFindInterface, .hideFindInterface,
                       .nextMatch, .previousMatch, .setSearchString] {
            XCTAssertTrue(view.validateUserInterfaceItem(finderItem(action)),
                          "\(action) belongs over a page")
        }
        for action in [NSTextFinder.Action.showReplaceInterface, .replace, .replaceAll] {
            XCTAssertFalse(view.validateUserInterfaceItem(finderItem(action)),
                           "\(action) has nothing to act on")
        }
        let bar = try findBar(of: pane)
        XCTAssertFalse(bar.handles(.showReplaceInterface))
        XCTAssertTrue(bar.handles(.nextMatch))
    }

    /// Typed a letter at a time, the way a reader types. Every band on the
    /// page has to be a band on the query as it stands now — the reader
    /// looking for `file` must not be left with every `f` in the page lit,
    /// which is what the bar did on the first build of it.
    @MainActor
    func testTypingALetterAtATimeLeavesOnlyTheWholeQueryBanded() throws {
        let (pane, _) = try makePane()
        try show(
            makeNote(named: "page.html", text:
                "<p>first file for four</p><p>from a file, finally</p><p>fifty</p>"),
            in: pane
        )
        let bar = try findBar(of: pane)
        try find(.showFindInterface, in: pane)

        for query in ["f", "fi", "fil", "file"] {
            try type(query, into: bar, of: pane)
            let painted = try paintedMatches(in: pane)
            XCTAssertEqual(
                Set(painted.map { $0.lowercased() }), [query],
                "after typing “\(query)” the page is showing bands on \(Set(painted))"
            )
            XCTAssertEqual(
                painted.count, try XCTUnwrap(pane.findMatchCount),
                "and there are as many bands as the count in the bar says"
            )
        }
        XCTAssertEqual(bar.status, "1 of 2")

        // And a step does not bring the old ones back either.
        try find(.nextMatch, in: pane)
        XCTAssertEqual(bar.status, "2 of 2")
        let painted = try paintedMatches(in: pane)
        XCTAssertEqual(Set(painted.map { $0.lowercased() }), ["file"])
        XCTAssertEqual(painted.count, 2)

        // The bands are the same two objects they were four keystrokes ago,
        // which is the whole of the fix: a highlight whose contents change
        // repaints what it used to cover, and one swapped out from under its
        // own name did not.
        XCTAssertEqual(
            try number("window.\(HTMLFindSession.namespace).bandsAreStable() ? 1 : 0",
                       in: pane),
            1
        )
    }

    /// The same, typed the way a reader types it: the next letter goes in
    /// before the page has answered for the last one. Every question crosses a
    /// process boundary, so the replies come back interleaved with the
    /// keystrokes, and the bands still have to be the query's.
    @MainActor
    func testTypingFasterThanThePageAnswersStillLeavesOnlyTheQueryBanded() throws {
        let controller = try makeReadingController(
            text: "<p>first file for four</p><p>from a file, finally</p><p>fifty</p>",
            in: try makeTemporaryDirectory()
        )
        let pane = controller.previewPanes.html
        let bar = try findBar(of: pane)
        try find(.showFindInterface, in: pane)

        // No waiting between them, which is the whole point.
        for query in ["f", "fi", "fil", "file"] {
            bar.query = query
            bar.controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification, object: bar.field)
            )
        }
        try settle(pane, until: { bar.status == "1 of 2" })

        let painted = try paintedMatches(in: pane)
        XCTAssertEqual(Set(painted.map { $0.lowercased() }), ["file"],
                       "the page is showing bands on \(Set(painted))")
        XCTAssertEqual(painted.count, 2)
    }

    /// And typed through the field editor, which is what a keystroke actually
    /// goes through — the pill's own `PillFieldEditor` in a real window, one
    /// letter at a time, nothing waited on.
    @MainActor
    func testTypingThroughTheFieldEditorLeavesOnlyTheQueryBanded() throws {
        let controller = try makeReadingController(
            text: "<p>first file for four</p><p>from a file, finally</p><p>fifty</p>",
            in: try makeTemporaryDirectory()
        )
        let pane = controller.previewPanes.html
        let bar = try findBar(of: pane)
        try find(.showFindInterface, in: pane)
        XCTAssertTrue(bar.isShown)

        let editor = try XCTUnwrap(bar.field.currentEditor() as? NSTextView,
                                   "the pill's field has the keyboard after ⌘F")
        for letter in ["f", "i", "l", "e"] {
            editor.insertText(letter, replacementRange: editor.selectedRange())
        }
        try settle(pane, until: { bar.status == "1 of 2" })

        XCTAssertEqual(bar.query, "file")
        let painted = try paintedMatches(in: pane)
        XCTAssertEqual(Set(painted.map { $0.lowercased() }), ["file"],
                       "the page is showing bands on \(Set(painted))")
        XCTAssertEqual(painted.count, 2)
    }

    /// A page with more one-letter hits than the bar will ever band, which is
    /// what a real file looks like: thousands of `f`s and two `file`s.
    @MainActor
    func testAPageWithMoreHitsThanTheCapStillBandsOnlyTheQuery() throws {
        let (pane, _) = try makePane()
        var paragraphs = (1 ... 900).map { "<p>far from fifty four, of \($0)</p>" }
        paragraphs.insert("<p>the file</p>", at: 10)
        paragraphs.append("<p>another file</p>")
        try show(makeNote(named: "page.html", text: paragraphs.joined()), in: pane)
        let bar = try findBar(of: pane)
        try find(.showFindInterface, in: pane)

        try type("f", into: bar, of: pane)
        XCTAssertEqual(bar.status, "1 of 2000+", "well past the cap")

        for query in ["fi", "fil", "file"] { try type(query, into: bar, of: pane) }

        XCTAssertEqual(bar.status, "1 of 2")
        let painted = try paintedMatches(in: pane)
        XCTAssertEqual(Set(painted.map { $0.lowercased() }), ["file"],
                       "the page is showing bands on \(Set(painted).sorted().prefix(5))")
        XCTAssertEqual(painted.count, 2)
    }

    /// ⌘F and then typing, without a pause between them — which is what a
    /// reader does, and which the tests above all politely waited out.
    ///
    /// ⌘F seeds the query from what is selected on the page, and only the
    /// page knows that, so the answer comes back a moment later. It must not
    /// land on top of what has been typed since.
    @MainActor
    func testTypingRightAfterCommandFIsNotOverwrittenByTheSeed() throws {
        let (pane, _) = try makePane()
        pane.takesKeyboard = true
        try show(
            makeNote(named: "page.html", text:
                "<p>first file for four</p><p>from a file, finally</p><p>fifty</p>"),
            in: pane
        )
        let bar = try findBar(of: pane)

        // A find that has been used and closed, which is how a page comes to
        // have a selection on it in the first place.
        try find(.showFindInterface, in: pane)
        try type("f", into: bar, of: pane)
        try find(.hideFindInterface, in: pane)
        XCTAssertEqual(try string("window.getSelection().toString()", in: pane).lowercased(),
                       "f", "Esc leaves the match selected, as it is meant to")

        // ⌘F again, and straight into typing: no waiting on the page.
        try page(of: pane).performTextFinderAction(finderItem(.showFindInterface))
        let editor = try XCTUnwrap(bar.field.currentEditor() as? NSTextView)
        for letter in ["f", "i", "l", "e"] {
            editor.insertText(letter, replacementRange: editor.selectedRange())
        }
        try settle(pane, until: { bar.query == "file" && bar.status == "1 of 2" })

        XCTAssertEqual(bar.query, "file", "the seed must not land on top of the typing")
        let painted = try paintedMatches(in: pane)
        XCTAssertEqual(Set(painted.map { $0.lowercased() }), ["file"],
                       "the page is showing bands on \(Set(painted))")
    }

    // MARK: - Helpers

    /// A file in the folder of examples checked in beside the app — a real
    /// folder a reader might keep notes in, rather than the temporary one.
    private func exampleURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/\(name)")
            .standardizedFileURL
    }

    /// Waits for the page and the pill to agree. Every answer the find bar
    /// gets is asynchronous, and a burst of keystrokes is a burst of replies.
    @MainActor
    private func settle(
        _ pane: HTMLPreviewView, until ready: @escaping () -> Bool
    ) throws {
        let settled = expectation(description: "the page and the pill agree")
        settled.assertForOverFulfill = false
        let poll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            if ready() { settled.fulfill() }
        }
        wait(for: [settled], timeout: 5)
        poll.invalidate()
    }

    /// What the page is actually showing bands on: every range in either
    /// highlight, as the text it covers. The count in the pill is one claim
    /// and the paint on the page is another, and this is the only way to ask
    /// the second.
    @MainActor
    private func paintedMatches(in pane: HTMLPreviewView) throws -> [String] {
        let script = """
        (function () {
            var out = [];
            ['nota-find', 'nota-find-current'].forEach(function (name) {
                var highlight = CSS.highlights.get(name);
                if (!highlight) { return; }
                for (var range of highlight) { out.push(range.toString()); }
            });
            return out;
        })()
        """
        let value = try evaluate(script, in: pane)
        return try XCTUnwrap(value as? [String])
    }

    /// A controller whose one `.html` tab is in reading with its page landed.
    /// A load is asynchronous, so the mode change is waited on rather than
    /// assumed.
    @MainActor
    private func makeReadingController(
        text: String, in directory: URL
    ) throws -> MainWindowController {
        let controller = try makeController(showing: "page.html", text: text, in: directory)
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFrontOffscreen()
        windows.append(window)
        let loaded = expectation(description: "the page loaded")
        loaded.assertForOverFulfill = false
        controller.previewPanes.html.onLoadFinished = { loaded.fulfill() }
        controller.setPreviewMode(.reading)
        window.layoutIfNeeded()
        wait(for: [loaded], timeout: 5)
        controller.previewPanes.html.onLoadFinished = nil
        return controller
    }

    /// The pane's pill.
    @MainActor
    private func findBar(of pane: HTMLPreviewView) throws -> FindBarView {
        try XCTUnwrap(descendant(of: pane, ofType: FindBarView.self))
    }

    /// Every find pill in the window — the editor's, the render's and the
    /// page's — so a test can say which one of them came up.
    @MainActor
    private func allFindBars(in controller: MainWindowController) -> [FindBarView] {
        guard let root = controller.window?.contentView else { return [] }
        var found: [FindBarView] = []
        var stack = [root]
        while let view = stack.popLast() {
            if let bar = view as? FindBarView { found.append(bar) }
            stack.append(contentsOf: view.subviews)
        }
        return found
    }

    /// A Find menu item as the menu builds it: nil-targeted, with the action
    /// in its tag.
    private func finderItem(_ action: NSTextFinder.Action) -> NSMenuItem {
        let item = NSMenuItem()
        item.action = #selector(NSTextView.performTextFinderAction(_:))
        item.tag = action.rawValue
        return item
    }

    /// One menu action put to the page, waited on. Every answer the find bar
    /// gets crosses a process boundary, so nothing about it is true the
    /// instant the call returns.
    @MainActor
    private func find(_ action: NSTextFinder.Action, in pane: HTMLPreviewView) throws {
        let answered = expectation(description: "the page answered the find bar")
        answered.assertForOverFulfill = false
        pane.onFindAnswered = { answered.fulfill() }
        try page(of: pane).performTextFinderAction(finderItem(action))
        wait(for: [answered], timeout: 5)
        pane.onFindAnswered = nil
    }

    /// The reader typing in the field, waited on the same way.
    @MainActor
    private func type(
        _ query: String, into bar: FindBarView, of pane: HTMLPreviewView
    ) throws {
        let answered = expectation(description: "the page answered the query")
        answered.assertForOverFulfill = false
        pane.onFindAnswered = { answered.fulfill() }
        bar.query = query
        bar.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: bar.field)
        )
        wait(for: [answered], timeout: 5)
        pane.onFindAnswered = nil
    }

    private func makeNote(named name: String, text: String) -> Note {
        Note(fileURL: URL(fileURLWithPath: "/tmp/\(name)"), untitledName: nil,
             text: text, attributes: [:], assets: nil)
    }

    private func context(isVisible: Bool = true) -> PreviewContext {
        PreviewContext(font: .systemFont(ofSize: 13), assets: nil, isVisible: isVisible)
    }

    /// The pane's web view, once it has one. Nothing exists until the first
    /// page is shown, so every test that asks for it has shown one.
    @MainActor
    private func page(of pane: HTMLPreviewView) throws -> HTMLPageView {
        try XCTUnwrap(pane.webView, "the pane has not been shown a page yet")
    }

    /// A pane in a window the window server is laying out, since a page that
    /// is never laid out has no viewport to compute a style against.
    @MainActor
    private func makePane() throws -> (HTMLPreviewView, NSWindow) {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        let pane = HTMLPreviewView(frame: frame)
        window.contentView = pane
        window.makeKeyAndOrderFrontOffscreen()
        windows.append(window)
        return (pane, window)
    }

    /// Shows the note and waits for the page to have arrived. A load is
    /// asynchronous and nothing about the pane is true until it has landed.
    @MainActor
    private func show(_ note: Note, in pane: HTMLPreviewView) throws {
        let loaded = expectation(description: "the page loaded")
        loaded.assertForOverFulfill = false
        pane.onLoadFinished = { loaded.fulfill() }
        pane.show(note, in: context())
        wait(for: [loaded], timeout: 5)
        pane.onLoadFinished = nil
    }

    @MainActor
    @discardableResult
    private func evaluate(_ javaScript: String, in pane: HTMLPreviewView) throws -> Any? {
        let answered = expectation(description: "the page answered")
        var value: Any?
        var failure: Error?
        try page(of: pane).evaluateJavaScript(
            javaScript, in: nil, in: .defaultClient
        ) { outcome in
            switch outcome {
            case .success(let result): value = result
            case .failure(let error): failure = error
            }
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)
        if let failure { throw failure }
        return value
    }

    @MainActor
    private func string(_ javaScript: String, in pane: HTMLPreviewView) throws -> String {
        try XCTUnwrap(try evaluate(javaScript, in: pane) as? String)
    }

    @MainActor
    private func number(_ javaScript: String, in pane: HTMLPreviewView) throws -> Double {
        try XCTUnwrap(try evaluate(javaScript, in: pane) as? Double)
    }

    /// Waits until the page has told the pane where it is. The report rides a
    /// frame, so a scroll set from a test is not in the pane the instant the
    /// call returns.
    @MainActor
    private func waitForScrollReport(
        in pane: HTMLPreviewView, of note: Note, toReach offset: Double
    ) throws {
        let id = note.id
        let reported = expectation(description: "the page reported its scroll")
        reported.assertForOverFulfill = false
        let poll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            if pane.rememberedScroll(ofTab: id).y == offset { reported.fulfill() }
        }
        wait(for: [reported], timeout: 5)
        poll.invalidate()
    }

    /// A page tall enough to be scrolled a long way down, and different
    /// enough from the next one to tell them apart.
    private func tallPage(titled title: String, extra: String = "") -> String {
        let lines = (1...200).map { "<p style=\"height: 40px\">\(title) \($0)</p>" }
        return "<!doctype html><body style=\"margin:0\">" + lines.joined() + extra
    }

    /// A window over a cache directory whose one tab is the given file — the
    /// same shape the Markdown and LaTeX suites use.
    @MainActor
    private func makeController(
        showing name: String, text: String, in directory: URL
    ) throws -> MainWindowController {
        let store = SessionStore(directory: directory)
        if store.load() == nil {
            let file = directory.appendingPathComponent(name)
            try text.write(to: file, atomically: true, encoding: .utf8)
            let id = UUID()
            store.save(SessionState(
                tabs: [SessionTab(
                    id: id, path: file.path, untitledName: nil,
                    isDirty: false, selection: 0, format: .default,
                    previewMode: .off
                )],
                selectedTabID: id,
                fontSize: 13
            ))
        }
        let controller = MainWindowController(store: store)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1000, height: 560))
        window.layoutIfNeeded()
        return controller
    }

    /// A real mouse press in the page, so the click travels the path a
    /// reader's does — which is the only path that could take the caret.
    @MainActor
    private func click(in view: NSView, of window: NSWindow) {
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ) else { return XCTFail("the event could not be made") }
        view.mouseDown(with: event)
    }

    @MainActor
    private func editorTextView(of controller: MainWindowController) throws -> NotaTextView {
        let content = try XCTUnwrap(controller.window?.contentView)
        return try XCTUnwrap(descendant(of: content, ofType: NotaTextView.self))
    }

    private func descendant<T: NSView>(
        of view: NSView, ofType type: T.Type, where matches: (T) -> Bool = { _ in true }
    ) -> T? {
        for subview in view.subviews {
            if let match = subview as? T, matches(match) { return match }
            if let match = descendant(of: subview, ofType: type, where: matches) { return match }
        }
        return nil
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotaHTMLTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}

