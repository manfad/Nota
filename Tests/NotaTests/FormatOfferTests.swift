import AppKit
import XCTest
@testable import Nota

/// The footer's format badge and the offer beside it: what a tab is read as
/// when its name says nothing, who gets to say so, and how quietly Nota
/// suggests it.
///
/// Nothing here sleeps and nothing here puts a sheet up: the debounce has a
/// seam (`formatOfferDelay`), the look itself has a hook
/// (`runFormatDetection()`) and the paste's question has a presenter
/// (`formatAlertPresenter`), so every test drives the offer by hand and
/// answers it by hand. A real sheet would be a run that never comes back.
final class FormatOfferTests: AppKitTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    // MARK: - The model

    func testEveryFormatHasAWordAndASpelling() {
        XCTAssertEqual(NoteFormat.all.count, 11)
        XCTAssertEqual(NoteFormat.all.map(\.displayName).first, "Plain")
        XCTAssertEqual(
            NoteFormat.all.map(\.canonicalExtension),
            ["txt", "md", "tex", "html", "svg", "json", "yaml", "toml", "xml", "csv", "sql"]
        )
        for format in NoteFormat.all {
            XCTAssertEqual(NoteFormat(canonicalExtension: format.canonicalExtension), format,
                           "\(format.displayName) does not read back")
        }
    }

    func testAnOverrideGivesAnUntitledNoteAPreview() {
        let note = Note(fileURL: nil, untitledName: "Untitled", text: "{\"a\": 1}",
                        attributes: [:], assets: nil)
        XCTAssertNil(note.previewKind)
        XCTAssertEqual(note.effectiveFormat, .plainText)

        note.formatOverride = .preview(.tree(.json))
        XCTAssertEqual(note.previewKind, .tree(.json))
        XCTAssertTrue(note.supportsRenderedPreview)
        XCTAssertTrue(note.isJSON, "the corner slot's Beautify action follows the override")
        XCTAssertFalse(note.isHTML)
    }

    func testAnOverrideCanTakeAPreviewAwayAgain() {
        let note = Note(fileURL: URL(fileURLWithPath: "/tmp/notes.md"), untitledName: nil,
                        text: "# hi", attributes: [:], assets: nil)
        XCTAssertEqual(note.previewKind, .markdown)
        XCTAssertTrue(note.countsTasks)

        note.formatOverride = .plainText
        XCTAssertNil(note.previewKind)
        XCTAssertFalse(note.supportsRenderedPreview)
        XCTAssertFalse(note.countsTasks, "no render, no task counts")
        XCTAssertEqual(note.effectiveFormat, .plainText)
    }

    func testTheOverrideMakesAPageAPage() {
        let note = Note(fileURL: nil, untitledName: "Untitled", text: "<p>hi</p>",
                        attributes: [:], assets: nil)
        note.formatOverride = .preview(.html)
        XCTAssertTrue(note.isHTML)
        XCTAssertEqual(PreviewContentKind(note), .html)
    }

    // MARK: - The session

    func testTheOverrideSurvivesASessionRoundTrip() throws {
        let note = Note(fileURL: nil, untitledName: "Untitled", text: "{}",
                        attributes: [:], assets: nil)
        note.formatOverride = .preview(.tree(.json))

        note.needsSaveAs = true
        let tab = note.sessionTab()
        XCTAssertEqual(tab.formatOverride, "json")
        XCTAssertEqual(tab.needsSaveAs, true)

        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(SessionTab.self, from: data)
        XCTAssertEqual(decoded, tab)
        XCTAssertEqual(NoteFormat(canonicalExtension: decoded.formatOverride ?? ""),
                       .preview(.tree(.json)))
    }

    func testATabGoingByItsNameWritesNoOverride() {
        let note = Note(fileURL: URL(fileURLWithPath: "/tmp/notes.md"), untitledName: nil,
                        text: "# hi", attributes: [:], assets: nil)
        XCTAssertNil(note.sessionTab().formatOverride)
    }

    func testASessionWrittenBeforeTheBadgeStillDecodes() throws {
        let json = """
        {"id":"\(UUID().uuidString)","path":"/tmp/notes.md","isDirty":false,
         "selection":0,"previewMode":"split"}
        """
        let tab = try JSONDecoder().decode(SessionTab.self, from: Data(json.utf8))
        XCTAssertNil(tab.formatOverride)
        XCTAssertNil(tab.needsSaveAs, "and it owes no name it never asked for")
        XCTAssertEqual(tab.previewMode, .split)
    }

    @MainActor
    func testAWindowRestoresTheOverrideOntoTheTab() throws {
        let directory = try makeTemporaryDirectory()
        let store = SessionStore(directory: directory)
        let id = UUID()
        store.save(SessionState(
            tabs: [SessionTab(
                id: id, path: nil, untitledName: "Untitled", isDirty: true,
                selection: 0, formatOverride: "json"
            )],
            selectedTabID: id,
            fontSize: 13
        ))
        try Data("{\"a\": 1}".utf8)
            .write(to: directory.appendingPathComponent("cache")
                .appendingPathComponent("\(id.uuidString).txt"))

        let controller = try makeController(store: store)
        XCTAssertEqual(controller.currentTabFormat.override, .preview(.tree(.json)))
        XCTAssertEqual(controller.currentRenderedPreviewKind, .tree(.json))
        XCTAssertTrue(controller.canShowRenderedPreview,
                      "an untitled note the reader called JSON has the three modes")
    }

    // MARK: - The badge and its menu

    @MainActor
    func testTheBadgeSaysWhatTheTabIsReadAs() throws {
        let controller = try makeController()
        XCTAssertEqual(controller.footerRegions.format.stringValue, "Plain")

        controller.setFormat(.preview(.tree(.json)))
        XCTAssertEqual(controller.footerRegions.format.stringValue, "JSON")
    }

    @MainActor
    func testTheMenuOffersEveryFormatWithTheCurrentOneTicked() throws {
        let controller = try makeController()
        let menu = try XCTUnwrap(controller.formatKindMenu())
        XCTAssertEqual(menu.items.map(\.title), NoteFormat.all.map(\.displayName))
        XCTAssertEqual(menu.items.filter { $0.state == .on }.map(\.title), ["Plain"])

        controller.setFormat(.preview(.markdown))
        let after = try XCTUnwrap(controller.formatKindMenu())
        XCTAssertEqual(after.items.filter { $0.state == .on }.map(\.title), ["MD"])
    }

    /// Picking what the file name already says is not an override at all —
    /// the name is saying it, and a later Save As is free to change it again.
    @MainActor
    func testPickingWhatTheNameAlreadySaysPutsTheOverrideDown() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("notes.md")
        try Data("# hi\n\n- one\n".utf8).write(to: file)

        let controller = try makeController()
        controller.open(url: file)
        controller.setFormat(.plainText)
        XCTAssertEqual(controller.currentTabFormat.override, .plainText)
        XCTAssertNil(controller.currentRenderedPreviewKind)

        controller.setFormat(.preview(.markdown))
        XCTAssertNil(controller.currentTabFormat.override, "the name says it")
        XCTAssertEqual(controller.currentRenderedPreviewKind, .markdown)
    }

    @MainActor
    func testPickingAFormatGivesTheTabItsCornerSegments() throws {
        let controller = try makeController()
        XCTAssertEqual(controller.cornerSlotContents.editor, .none)

        controller.setFormat(.preview(.tree(.json)))
        XCTAssertEqual(controller.cornerSlotContents.editor, .modeControlWithFormat(.json),
                       "a tab called JSON gets Beautify beside its modes")
        XCTAssertTrue(controller.canShowRenderedPreview)

        controller.setPreviewMode(.split)
        XCTAssertEqual(controller.previewState.mode, .split)
        XCTAssertTrue(controller.previewPanes.showsTree)
    }

    @MainActor
    func testTakingTheFormatAwayTakesTheSplitWithIt() throws {
        let controller = try makeController()
        controller.setFormat(.preview(.markdown))
        controller.setPreviewMode(.split)
        XCTAssertEqual(controller.previewState.mode, .split)

        controller.setFormat(.plainText)
        XCTAssertEqual(controller.previewState.mode, .off, "nothing left to show")
        XCTAssertEqual(controller.cornerSlotContents.editor, .none)
    }

    // MARK: - Saving

    /// The name says it now, so there is nothing left for the tab to
    /// remember.
    @MainActor
    func testSavingUnderTheFormatsOwnExtensionDropsTheOverride() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeController()
        controller.setFormat(.preview(.tree(.json)))
        controller.savePanelProvider = { _ in directory.appendingPathComponent("blob.json") }
        controller.saveCurrent(forcePanel: false)

        XCTAssertNil(controller.currentTabFormat.override)
        XCTAssertEqual(controller.currentRenderedPreviewKind, .tree(.json),
                       "the extension is the authority now, and it agrees")
    }

    /// Saved as something else, the reader's word stands: they said what it
    /// is, and a file name did not unsay it.
    @MainActor
    func testSavingUnderAnotherExtensionKeepsTheOverride() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeController()
        controller.setFormat(.preview(.tree(.json)))
        controller.savePanelProvider = { _ in directory.appendingPathComponent("blob.txt") }
        controller.saveCurrent(forcePanel: false)

        XCTAssertEqual(controller.currentTabFormat.override, .preview(.tree(.json)))
        XCTAssertEqual(controller.currentRenderedPreviewKind, .tree(.json))
    }

    // MARK: - A file the reader has renamed the format of

    /// The tab and the file no longer agree, and the tab says so the way any
    /// other unsaved edit says it — the dot in the strip, the close
    /// confirmation, the session record. The next ⌘S asks for a name.
    @MainActor
    func testPickingAFormatOnAFileDirtiesTheTabAndOwesItAName() throws {
        let controller = try makeController()
        let file = try writeFile(named: "notes.txt", markdownText)
        controller.open(url: file)
        XCTAssertFalse(controller.currentTabState.isDirty, "as it came off disk")
        XCTAssertFalse(controller.currentTabFormat.needsSaveAs)
        XCTAssertEqual(controller.currentSaveExtension, "txt")

        controller.setFormat(.preview(.markdown))
        XCTAssertTrue(controller.currentTabState.isDirty, "the name on disk is not this")
        XCTAssertTrue(controller.currentTabFormat.needsSaveAs)
        XCTAssertEqual(controller.currentSaveExtension, "md",
                       "the panel opens on the format the badge is showing")
    }

    /// Put back, the need goes. The dirty mark does not: dirty is one flag
    /// for the whole tab and there may be a real edit under it.
    @MainActor
    func testPickingTheNamesOwnFormatAgainPutsTheNeedDown() throws {
        let controller = try makeController()
        controller.open(url: try writeFile(named: "notes.txt", markdownText))
        controller.setFormat(.preview(.markdown))
        XCTAssertTrue(controller.currentTabFormat.needsSaveAs)

        controller.setFormat(.plainText)
        XCTAssertNil(controller.currentTabFormat.override, "the name says it")
        XCTAssertFalse(controller.currentTabFormat.needsSaveAs)
        XCTAssertEqual(controller.currentSaveExtension, "txt")
    }

    @MainActor
    func testPickingWhatTheNameAlreadySaysChangesNothing() throws {
        let controller = try makeController()
        controller.open(url: try writeFile(named: "notes.md", markdownText))

        controller.setFormat(.preview(.markdown))
        XCTAssertNil(controller.currentTabFormat.override)
        XCTAssertFalse(controller.currentTabFormat.needsSaveAs)
        XCTAssertFalse(controller.currentTabState.isDirty, "nothing was said that was not said")
    }

    /// ⌘S on a tab owing a name is the Save As flow — and only until it is
    /// answered: the save after it writes where that one landed.
    @MainActor
    func testSaveOnATabOwingANameOpensThePanelOnce() throws {
        let controller = try makeController()
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("notes.txt")
        try Data(markdownText.utf8).write(to: file)
        controller.open(url: file)
        controller.setFormat(.preview(.markdown))

        var asked: [String] = []
        controller.savePanelProvider = { note in
            asked.append(note.title)
            return directory.appendingPathComponent("notes.md")
        }
        controller.saveCurrent(forcePanel: false)

        XCTAssertEqual(asked.count, 1, "the panel was put up")
        XCTAssertNil(controller.currentTabFormat.override, "the name says it now")
        XCTAssertFalse(controller.currentTabFormat.needsSaveAs)
        XCTAssertFalse(controller.currentTabState.isDirty)
        XCTAssertEqual(controller.currentRenderedPreviewKind, .markdown)

        controller.saveCurrent(forcePanel: false)
        XCTAssertEqual(asked.count, 1, "and is not put up again")
    }

    /// The combo's word wins over the badge's: saved as `.txt` on purpose,
    /// the reader's format still stands — they said what the tab is, and a
    /// file name did not unsay it — but the name has been settled, so the
    /// next ⌘S writes rather than asks.
    @MainActor
    func testSavingUnderAnotherExtensionKeepsTheWordAndStopsAsking() throws {
        let controller = try makeController()
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("notes.txt")
        try Data(markdownText.utf8).write(to: file)
        controller.open(url: file)
        controller.setFormat(.preview(.markdown))

        var asked = 0
        controller.savePanelProvider = { _ in
            asked += 1
            return directory.appendingPathComponent("notes-copy.txt")
        }
        controller.saveCurrent(forcePanel: false)

        XCTAssertEqual(asked, 1)
        XCTAssertEqual(controller.currentTabFormat.override, .preview(.markdown))
        XCTAssertEqual(controller.currentRenderedPreviewKind, .markdown)
        XCTAssertFalse(controller.currentTabFormat.needsSaveAs)
        XCTAssertFalse(controller.currentTabState.isDirty)

        controller.saveCurrent(forcePanel: false)
        XCTAssertEqual(asked, 1, "the question was asked and answered")
    }

    /// It is an unsaved change like any other, so the tab does not go
    /// quietly.
    @MainActor
    func testClosingATabOwingANameAsksFirst() throws {
        let controller = try makeController()
        controller.open(url: try writeFile(named: "notes.txt", markdownText))
        controller.setFormat(.preview(.markdown))

        var asked = 0
        controller.confirmDiscardOverrideForTesting = {
            asked += 1
            return .alertSecondButtonReturn   // Don’t Save
        }
        controller.closeTab(at: controller.selectedTabIndex)
        XCTAssertEqual(asked, 1, "an unsaved change is an unsaved change")
    }

    @MainActor
    func testTheNeedForANameIsWrittenToTheSession() {
        let note = Note(fileURL: URL(fileURLWithPath: "/tmp/notes.txt"), untitledName: nil,
                        text: "# hi", attributes: [:], assets: nil)
        XCTAssertNil(note.sessionTab().needsSaveAs, "an ordinary tab writes nothing")

        note.formatOverride = .preview(.markdown)
        note.needsSaveAs = true
        let tab = note.sessionTab()
        XCTAssertEqual(tab.needsSaveAs, true)
        XCTAssertEqual(tab.formatOverride, "md")
    }

    @MainActor
    func testAWindowRestoresTheNameATabOwes() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("notes.txt")
        try Data(markdownText.utf8).write(to: file)

        let store = SessionStore(directory: directory.appendingPathComponent("session"))
        let id = UUID()
        store.save(SessionState(
            tabs: [SessionTab(
                id: id, path: file.path, untitledName: nil, isDirty: true,
                selection: 0, formatOverride: "md", needsSaveAs: true
            )],
            selectedTabID: id,
            fontSize: 13
        ))

        let controller = try makeController(store: store)
        XCTAssertEqual(controller.currentTabFormat.override, .preview(.markdown))
        XCTAssertTrue(controller.currentTabFormat.needsSaveAs, "still owing the name")
        XCTAssertTrue(controller.currentTabState.isDirty)
        XCTAssertEqual(controller.currentSaveExtension, "md")
    }

    // MARK: - The offer

    @MainActor
    func testTheOfferAppearsForJSONInAnUntitledNote() throws {
        let controller = try makeKeyController()
        type(jsonText, into: controller)
        controller.runFormatDetection()

        XCTAssertTrue(controller.formatOffer.isShown)
        XCTAssertEqual(controller.formatOffer.offeredKind, .tree(.json))
        XCTAssertEqual(controller.formatOffer.messageForTesting, "JSON detected")
        XCTAssertEqual(controller.formatOffer.wordsForTesting.accept.identifier?.rawValue,
                       "Preview in JSON")
        XCTAssertEqual(controller.formatOffer.wordsForTesting.dismiss.identifier?.rawValue,
                       "Not now")
    }

    @MainActor
    func testTakingTheOfferGivesTheTabItsPreview() throws {
        let controller = try makeKeyController()
        type(jsonText, into: controller)
        controller.runFormatDetection()
        controller.formatOffer.wordsForTesting.accept.performClick(nil)

        XCTAssertFalse(controller.formatOffer.isShown, "answered, so it goes")
        XCTAssertEqual(controller.currentTabFormat.override, .preview(.tree(.json)))
        XCTAssertEqual(controller.currentRenderedPreviewKind, .tree(.json))
        XCTAssertTrue(controller.canShowRenderedPreview)
    }

    @MainActor
    func testNotNowIsRememberedForThatReading() throws {
        let controller = try makeKeyController()
        type(jsonText, into: controller)
        controller.runFormatDetection()
        controller.formatOffer.wordsForTesting.dismiss.performClick(nil)

        XCTAssertFalse(controller.formatOffer.isShown)
        XCTAssertNil(controller.currentTabFormat.override, "nothing was changed")

        controller.runFormatDetection()
        XCTAssertFalse(controller.formatOffer.isShown, "the same guess is not put twice")
    }

    /// Only a different reading brings it back.
    @MainActor
    func testAnotherReadingOfTheSameTabIsOfferedAgain() throws {
        let controller = try makeKeyController()
        type(jsonText, into: controller)
        controller.runFormatDetection()
        controller.formatOffer.wordsForTesting.dismiss.performClick(nil)

        let editor = controller.editorScrolling.textView
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.count))
        type(markdownText, into: controller)
        controller.runFormatDetection()

        XCTAssertTrue(controller.formatOffer.isShown)
        XCTAssertEqual(controller.formatOffer.offeredKind, .markdown)
    }

    /// A file is never offered anything, whatever is in it: its name is its
    /// author saying what it is, and the badge in the footer is there for
    /// anybody who disagrees.
    @MainActor
    func testTheOfferNeverAppearsOnAFile() throws {
        let directory = try makeTemporaryDirectory()
        let markdown = directory.appendingPathComponent("notes.md")
        try Data(jsonText.utf8).write(to: markdown)
        let plain = directory.appendingPathComponent("notes.txt")
        try Data(jsonText.utf8).write(to: plain)

        let controller = try makeKeyController()
        controller.open(url: markdown)
        controller.runFormatDetection()
        XCTAssertFalse(controller.formatOffer.isShown, "a `.md` already has a preview")

        controller.open(url: plain)
        controller.runFormatDetection()
        XCTAssertFalse(controller.formatOffer.isShown, "and a `.txt` is somebody's `.txt`")
    }

    @MainActor
    func testAFormatPickedInTheFooterTakesTheOfferDown() throws {
        let controller = try makeKeyController()
        type(jsonText, into: controller)
        controller.runFormatDetection()
        XCTAssertTrue(controller.formatOffer.isShown)

        controller.setFormat(.preview(.markdown))
        XCTAssertFalse(controller.formatOffer.isShown)
    }

    @MainActor
    func testTheOfferIsNotMadeUnderTheMinimum() throws {
        let controller = try makeKeyController()
        type("{\"a\": 1}", into: controller)
        controller.runFormatDetection()
        XCTAssertFalse(controller.formatOffer.isShown)
    }

    /// The debounce: typing schedules the look rather than making it, and the
    /// interval is a seam so the test does not sleep for a second and a half.
    @MainActor
    func testTypingOffersAfterThePause() throws {
        let controller = try makeKeyController()
        controller.formatOfferDelay = 0
        type(jsonText, into: controller)
        XCTAssertFalse(controller.formatOffer.isShown, "not while the keys are still going")

        let offered = expectation(description: "the pause is waited out")
        DispatchQueue.main.async { offered.fulfill() }
        wait(for: [offered], timeout: 2)
        XCTAssertTrue(controller.formatOffer.isShown)
    }

    // MARK: - The paste, and the sheet it asks in

    /// The case the offer is really for: a note pasted whole into a fresh
    /// tab. Nothing waits and nothing is interrupted, so this half is a real
    /// question — the sheet, and not the corner's pill.
    @MainActor
    func testAPasteAsksInASheetAndNotInThePill() throws {
        let controller = try makeKeyController()
        var asked: [RenderedPreviewKind] = []
        controller.formatAlertPresenter = { kind, _ in asked.append(kind) }

        paste(markdownText, into: controller)

        XCTAssertEqual(asked, [.markdown], "asked on the spot, with no pause")
        XCTAssertFalse(controller.formatOffer.isShown, "the corner says nothing over a sheet")
    }

    /// The words the sheet is built from, checked where they are written
    /// rather than through a sheet no test may put up.
    @MainActor
    func testTheSheetSaysWhatWasDetectedAndOffersBothWords() {
        let alert = FormatOfferAlert.make(for: .markdown)
        XCTAssertEqual(alert.messageText, "MD detected")
        XCTAssertEqual(alert.informativeText,
                       "Preview this tab in MD? You can change this any time "
                       + "from the format badge in the footer.")
        XCTAssertEqual(alert.buttons.map(\.title), ["Preview in MD", "Not now"])
        XCTAssertEqual(alert.buttons.first?.keyEquivalent, "\r", "Return takes the offer")
    }

    @MainActor
    func testTakingTheSheetsOfferGivesTheTabItsPreview() throws {
        let controller = try makeKeyController()
        controller.formatAlertPresenter = { _, answer in answer(true) }

        paste(markdownText, into: controller)

        XCTAssertEqual(controller.currentTabFormat.override, .preview(.markdown))
        XCTAssertEqual(controller.currentRenderedPreviewKind, .markdown)
        XCTAssertTrue(controller.canShowRenderedPreview)
        XCTAssertFalse(controller.formatOffer.isShown)
    }

    /// "Not now" in the sheet is remembered exactly as it is in the pill: the
    /// same guess is never put to this tab again, by either half.
    @MainActor
    func testDecliningTheSheetIsRememberedForThatReading() throws {
        let controller = try makeKeyController()
        var asked = 0
        controller.formatAlertPresenter = { _, answer in
            asked += 1
            answer(false)
        }

        paste(markdownText, into: controller)
        XCTAssertEqual(asked, 1)
        XCTAssertNil(controller.currentTabFormat.override, "nothing was changed")

        controller.runFormatDetection()
        XCTAssertFalse(controller.formatOffer.isShown, "the pill does not ask it again either")

        paste("\n\n- and one more line\n", into: controller)
        XCTAssertEqual(asked, 1, "nor does a second paste that reads the same way")
    }

    /// One question at a time: a second paste while the sheet is still up is
    /// the same tab asking again, and the sheet already answers for it.
    @MainActor
    func testASecondPasteWhileTheSheetIsUpIsIgnored() throws {
        let controller = try makeKeyController()
        var answers: [(Bool) -> Void] = []
        controller.formatAlertPresenter = { _, answer in answers.append(answer) }

        paste(markdownText, into: controller)
        paste("\n\n- and one more line\n", into: controller)
        XCTAssertEqual(answers.count, 1)

        // And the pause in the typing stays quiet under it too.
        controller.runFormatDetection()
        XCTAssertFalse(controller.formatOffer.isShown)

        answers[0](true)
        XCTAssertEqual(controller.currentRenderedPreviewKind, .markdown)
    }

    /// The typing pause is untouched: the pill, and never the sheet.
    @MainActor
    func testATypingPauseStillOffersInThePillAndNeverAsks() throws {
        let controller = try makeKeyController()
        var asked = 0
        controller.formatAlertPresenter = { _, _ in asked += 1 }

        type(jsonText, into: controller)
        controller.runFormatDetection()

        XCTAssertTrue(controller.formatOffer.isShown)
        XCTAssertEqual(controller.formatOffer.offeredKind, .tree(.json))
        XCTAssertEqual(asked, 0, "nothing was interrupted, so nothing interrupts")
    }

    /// A paste into a tab that is not offered anything asks nothing, exactly
    /// as it shows nothing.
    @MainActor
    func testAPasteIntoAFileAsksNothing() throws {
        let directory = try makeTemporaryDirectory()
        let plain = directory.appendingPathComponent("notes.txt")
        try Data("hello\n".utf8).write(to: plain)

        let controller = try makeKeyController()
        controller.open(url: plain)
        var asked = 0
        controller.formatAlertPresenter = { _, _ in asked += 1 }

        paste(markdownText, into: controller)
        XCTAssertEqual(asked, 0, "a `.txt` is somebody's `.txt`")
        XCTAssertFalse(controller.formatOffer.isShown)
    }

    /// The big-note guard is the detector's, so both halves keep it.
    @MainActor
    func testABigPasteIsNeverAskedAbout() throws {
        let controller = try makeKeyController()
        var asked = 0
        controller.formatAlertPresenter = { _, _ in asked += 1 }

        let line = "{\"key\": \"value\"},\n"
        let big = "[" + String(repeating: line, count: BigFile.threshold / line.count + 1) + "{}]"
        paste(big, into: controller)

        XCTAssertEqual(asked, 0, "a megabyte is not parsed on every paste either")
        XCTAssertFalse(controller.formatOffer.isShown)
    }

    /// A big note is never read: the detector parses the whole text, and the
    /// rest of the editor already stops doing whole-text work past this size.
    @MainActor
    func testABigNoteIsNeverOfferedAnything() throws {
        let controller = try makeKeyController()
        let line = "{\"key\": \"value\"},\n"
        let big = "[" + String(repeating: line, count: BigFile.threshold / line.count + 1) + "{}]"
        XCTAssertTrue(BigFile.isBig(length: (big as NSString).length))
        type(big, into: controller)
        controller.runFormatDetection()
        XCTAssertFalse(controller.formatOffer.isShown, "a megabyte is not parsed on every pause")
    }

    @MainActor
    func testTheOfferBelongsToTheTabAndGoesWithIt() throws {
        let controller = try makeKeyController()
        type(jsonText, into: controller)
        controller.runFormatDetection()
        XCTAssertTrue(controller.formatOffer.isShown)

        controller.newTab()
        XCTAssertFalse(controller.formatOffer.isShown, "an empty tab is nothing yet")

        controller.selectTab(at: 0)
        XCTAssertTrue(controller.formatOffer.isShown, "and the reading comes back with it")
    }

    // MARK: - Settings

    func testTheFormatBadgeCanBeSwitchedOff() {
        let preferences = Preferences.shared
        let original = preferences.footerShowsFormat
        defer { preferences.footerShowsFormat = original }
        XCTAssertTrue(preferences.footerShowsFormat, "on by default")
        preferences.footerShowsFormat = false
        XCTAssertFalse(preferences.footerShowsFormat)
    }

    // MARK: - Helpers

    private let jsonText = """
    {
      "name": "nota",
      "version": "1.1.1",
      "tags": ["editor", "macos"]
    }
    """

    private let markdownText = """
    # Nota

    A small editor, and this is what it does.

    - it opens
    - it closes
    """

    @MainActor
    private func type(_ text: String, into controller: MainWindowController) {
        let editor = controller.editorScrolling.textView
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    /// A real paste, through the editor's own reading of a board — which is
    /// what fires `onBulkInsert` and so the offer's sheet. A board of its
    /// own: a test never writes the reader's clipboard.
    @MainActor
    private func paste(_ text: String, into controller: MainWindowController) {
        let board = NSPasteboard(name: .init("NotaFormatOfferTests-\(UUID().uuidString)"))
        board.clearContents()
        board.setString(text, forType: .string)
        let editor = controller.editorScrolling.textView as? NotaTextView
        editor?.setSelectedRange(NSRange(location: editor?.string.count ?? 0, length: 0))
        XCTAssertTrue(editor?.readSelection(from: board) == true, "the paste landed")
    }

    @MainActor
    private func makeController(store: SessionStore? = nil) throws -> MainWindowController {
        _ = NSApplication.shared
        let controller = MainWindowController(
            store: try store ?? SessionStore(directory: makeTemporaryDirectory())
        )
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1000, height: 560))
        window.layoutIfNeeded()
        return controller
    }

    @MainActor
    private func makeKeyController() throws -> MainWindowController {
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFrontOffscreen()
        window.layoutIfNeeded()
        return controller
    }

    @discardableResult
    private func writeFile(named name: String, _ text: String) throws -> URL {
        let url = try makeTemporaryDirectory().appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nota-format-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
