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

