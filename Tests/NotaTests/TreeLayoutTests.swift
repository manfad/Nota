import AppKit
import XCTest
@testable import Nota

/// The tree pane's own geometry, in the window rather than on its own: the
/// one column held to the pane it is drawn in, and every row of it laid out
/// to that column — including the rows made before the split had opened, in a
/// pane four points wide, which is how a big document came to be drawn with
/// its keys cut off after two letters.
final class TreeLayoutTests: AppKitTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    // MARK: - The column and its rows

    /// A document past `expandEverythingBelow`, pasted into an untitled tab
    /// and read as JSON: the column is the pane's, and the first row's text
    /// runs to the end of it rather than stopping a few points in.
    @MainActor
    func testABigJSONFillsTheColumnItIsDrawnIn() throws {
        let controller = try makeController()
        try openInSplit(Self.bigJSON(), as: .preview(.tree(.json)), in: controller)

        let pane = controller.previewPanes.tree
        XCTAssertGreaterThan(pane.outline.numberOfRows, 1, "there is a tree to measure")
        try assertRowsFillTheColumn(of: pane)
    }

    /// And the same for a big XML, which is the other grammar a reader is
    /// likely to paste a whole export of.
    @MainActor
    func testABigXMLFillsTheColumnItIsDrawnIn() throws {
        let controller = try makeController()
        try openInSplit(Self.bigXML(), as: .preview(.tree(.xml)), in: controller)

        let pane = controller.previewPanes.tree
        XCTAssertGreaterThan(pane.outline.numberOfRows, 1, "there is a tree to measure")
        try assertRowsFillTheColumn(of: pane)
    }

    /// Split, back to the editor, and split again. The column closes to
    /// nothing and opens again, and the tree that was already built has to
    /// come back the width of the pane rather than the width of the moment
    /// the divider passed through.
    @MainActor
    func testTheTreeComesBackWideAfterTheSplitIsClosedAndOpened() throws {
        let controller = try makeController()
        try openInSplit(Self.bigJSON(), as: .preview(.tree(.json)), in: controller)

        controller.setPreviewMode(.off)
        settle()
        controller.setPreviewMode(.split)
        settle()
        controller.window?.layoutIfNeeded()

        let pane = controller.previewPanes.tree
        XCTAssertGreaterThan(pane.outline.numberOfRows, 1, "the tree is still there")
        try assertRowsFillTheColumn(of: pane)
    }

    /// And the pane resized under a tree that is already on screen: the rows
    /// are as wide as the pane both ways, narrower and wider again.
    @MainActor
    func testTheRowsFollowThePaneBeingResized() throws {
        let controller = try makeController()
        try openInSplit(Self.bigJSON(), as: .preview(.tree(.json)), in: controller)
        let pane = controller.previewPanes.tree

        for width in [820.0, 1400.0] {
            controller.window?.setContentSize(NSSize(width: width, height: 700))
            settle()
            controller.window?.layoutIfNeeded()
            try assertRowsFillTheColumn(of: pane)
        }
    }

    /// The tree is on screen the moment the split opens: an untitled tab told
    /// what it is by the footer's badge has its rows at once, not after the
    /// next edit.
    @MainActor
    func testTheTreeIsThereAsSoonAsTheSplitOpens() throws {
        let controller = try makeController()
        try openInSplit(Self.bigJSON(), as: .preview(.tree(.json)), in: controller)

        let pane = controller.previewPanes.tree
        XCTAssertEqual(controller.previewPanes.kind, .tree)
        XCTAssertNil(pane.shownParseError)
        XCTAssertGreaterThan(pane.outline.numberOfRows, 1, "the rows are drawn straight away")
    }

    // MARK: - Helpers

    /// The one column is the width of the clip it is drawn in, and the field
    /// on a row runs to the end of that column with the whole of its key in
    /// it. Both are asked of the first row under the root, which is where the
    /// squeeze showed: the row was there, and two letters of it were legible.
    @MainActor
    private func assertRowsFillTheColumn(of pane: TreePreviewView) throws {
        let outline = pane.outline
        let scrollView = try XCTUnwrap(outline.enclosingScrollView)
        let column = try XCTUnwrap(outline.tableColumns.first)
        XCTAssertEqual(column.width, scrollView.contentSize.width, accuracy: 0.5,
                       "the column is exactly the pane it is drawn in")
        XCTAssertGreaterThan(column.width, 100, "the pane is open")

        let field = try XCTUnwrap(
            outline.view(atColumn: 0, row: 1, makeIfNecessary: true) as? NSTextField
        )
        // The row runs to the pane's edge, give or take the indentation
        // AppKit leaves after the deepest row on screen. The bug this is
        // here for left the field eighteen points wide in a pane five
        // hundred and sixty wide, so the slack is not what is being tested.
        XCTAssertGreaterThan(
            field.frame.width, column.width - field.frame.minX - 40,
            "the row's text runs to the end of the column"
        )
        XCTAssertGreaterThan(
            field.frame.width, field.attributedStringValue.size().width,
            "the whole row fits: \(field.stringValue) in \(field.frame.width) points"
        )
        // And no further: a document long enough to scroll has a scroller
        // over its right-hand edge, and a row written under it would put its
        // ellipsis where nobody can read it.
        XCTAssertLessThanOrEqual(field.frame.maxX, column.width,
                                 "the row stops at the pane's edge")
    }

    /// Text pasted into the front tab, read as `format`, with the tab put in
    /// split — the run through the window the reader takes, animation and
    /// all, so the render that is made before the divider moves is the one
    /// being measured.
    @MainActor
    private func openInSplit(
        _ text: String, as format: NoteFormat, in controller: MainWindowController
    ) throws {
        let editor = controller.editorScrolling.textView
        editor.insertText(text, replacementRange: editor.selectedRange())
        controller.window?.layoutIfNeeded()
        controller.setFormat(format)
        controller.setPreviewMode(.split)
        settle()
        controller.window?.layoutIfNeeded()
    }

    /// The divider slides, so the run loop has to turn for the pane to reach
    /// the width it is read at.
    @MainActor
    private func settle() {
        let end = Date().addingTimeInterval(0.6)
        while Date() < end {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    /// Past `TreePreviewView.expandEverythingBelow`, four deep, with values
    /// long enough that a narrow column would show it.
    private static func bigJSON() -> String {
        let entries = (0..<120).map { index in
            """
            {"identifier":\(index),\
            "name":"Entry number \(index), named at some length so a narrow column shows",\
            "detail":{"kind":"sample","notes":["the first note","the second note"]}}
            """
        }
        let head = #"{"generated":"2026-09-08","entries":["#
        return head + entries.joined(separator: ",") + "]}"
    }

    private static func bigXML() -> String {
        var xml = "<?xml version=\"1.0\"?>\n<catalogue>\n"
        for index in 0..<300 {
            xml += "  <entry id=\"\(index)\">\n"
            xml += "    <name>Entry number \(index), named at some length</name>\n"
            xml += "  </entry>\n"
        }
        return xml + "</catalogue>\n"
    }

    @MainActor
    private func makeController() throws -> MainWindowController {
        _ = NSApplication.shared
        let controller = MainWindowController(
            store: SessionStore(directory: try makeTemporaryDirectory())
        )
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1200, height: 700))
        window.makeKeyAndOrderFrontOffscreen()
        window.layoutIfNeeded()
        return controller
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotaTreeLayoutTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
