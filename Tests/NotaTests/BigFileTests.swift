import AppKit
import Foundation
import XCTest
@testable import Nota

/// SPEC Todo 16, editor half: spell checking follows the tab it is on
/// (prose, and under `BigFile.threshold`), and word wrap on a huge note lays
/// out only what the window can show rather than the whole document.
final class BigFileTests: AppKitTestCase {
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

    // MARK: - Spell checking per tab

    @MainActor
    func testAMarkdownTabHasSpellCheckingOn() throws {
        let controller = try makeController()
        controller.addTab(fileURL: URL(fileURLWithPath: "/tmp/notes.md"), text: "hello")
        XCTAssertTrue(controller.editorScrolling.textView.isContinuousSpellCheckingEnabled)
    }

    @MainActor
    func testALogTabHasSpellCheckingOff() throws {
        let controller = try makeController()
        controller.addTab(fileURL: URL(fileURLWithPath: "/tmp/app.log"), text: "hello")
        XCTAssertFalse(controller.editorScrolling.textView.isContinuousSpellCheckingEnabled)
    }

    @MainActor
    func testAMarkdownTabPastTheBigFileThresholdHasSpellCheckingOff() throws {
        let controller = try makeController()
        let huge = String(repeating: "a", count: BigFile.threshold)
        controller.addTab(fileURL: URL(fileURLWithPath: "/tmp/notes.md"), text: huge)
        XCTAssertFalse(controller.editorScrolling.textView.isContinuousSpellCheckingEnabled)
    }

    // MARK: - Word wrap does not lay out the whole document

    /// With `allowsNonContiguousLayout`, only what the window can show — plus
    /// whatever a little slack lays out around it — is laid out; the rest is
    /// an estimate until scrolling brings it into view. Generous on purpose:
    /// the point is that most of a 300k-line note is still unlaid, not that
    /// an exact boundary holds.
    @MainActor
    func testANoteFarBiggerThanTheWindowIsNotLaidOutInFull() throws {
        let previous = Preferences.shared.wrapsLines
        defer { Preferences.shared.wrapsLines = previous }
        Preferences.shared.wrapsLines = true

        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 820, height: 560))
        window.makeKeyAndOrderFrontOffscreen()

        // Well past `BigFile.threshold` (1,000,000 UTF-16 units) without
        // paying for the full 300k-line scale the real feature targets —
        // the point here is the ratio of laid-out to unlaid, not the size.
        let line = "the quick brown fox jumps over the lazy dog\n"
        let big = String(repeating: line, count: 60_000)
        controller.addTab(fileURL: URL(fileURLWithPath: "/tmp/huge.log"), text: big)
        window.displayIfNeeded()

        let editor = controller.editorScrolling
        let layoutManager = try XCTUnwrap(editor.textView.layoutManager)
        let length = editor.textView.textStorage?.length ?? 0
        XCTAssertGreaterThan(length, BigFile.threshold, "the note really is big")
        XCTAssertLessThan(
            layoutManager.firstUnlaidCharacterIndex(), length / 2,
            "installing and displaying a huge note should not lay out anywhere near all of it"
        )
    }

    // MARK: - Helpers

    @MainActor
    private func makeController() throws -> MainWindowController {
        let controller = MainWindowController(store: SessionStore(directory: try makeTemporaryDirectory()))
        if let window = controller.window { windows.append(window) }
        return controller
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BigFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
