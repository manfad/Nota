import AppKit
import XCTest
@testable import Jot

@MainActor
final class DirtyProbeTests: XCTestCase {
    private final class UndoHost: NSObject, NSTextViewDelegate {
        let manager = UndoManager()
        var changes = 0
        func undoManager(for view: NSTextView) -> UndoManager? { manager }
        func textDidChange(_ notification: Notification) { changes += 1 }
    }
    private var hosts: [UndoHost] = []

    private func make(_ text: String) -> (JotTextView, VimEngine, UndoHost) {
        let storage = NSTextStorage()
        let lm = NSLayoutManager()
        let c = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(lm); lm.addTextContainer(c)
        let view = JotTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: c)
        view.isRichText = false; view.isEditable = true; view.allowsUndo = true
        view.attributesProvider = { [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 13)] }
        let host = UndoHost(); hosts.append(host); view.delegate = host
        view.string = text
        view.setSelectedRange(NSRange(location: 0, length: 0))
        let engine = VimEngine(textView: view)
        engine.pasteboard = NSPasteboard(name: NSPasteboard.Name("Dirty-\(UUID().uuidString)"))
        engine.isEnabled = true
        host.changes = 0
        return (view, engine, host)
    }

    func testWhichCommandsDirtyTheEditor() {
        let cases: [(String, String)] = [
            ("v", "abc\ndef"),
            ("vl", "abc\ndef"),
            ("V", "abc\ndef"),
            ("Vj", "abc\ndef"),
            ("V<Esc>", "abc\ndef"),
            ("v<Esc>", "abc\ndef"),
            ("Vy", "abc\ndef"),
            ("vly", "abc\ndef"),
            ("yy", "abc\ndef"),
            ("yiw", "abc\ndef"),
            ("j", "abc\ndef"),
            ("gv", "abc\ndef"),
            ("ma", "abc\ndef"),
            ("qaq", "abc\ndef"),
            (">>", "abc"),
            ("<<", "abc"),
            ("==", "abc"),
            ("g~w", "abc"),
            ("guw", "abc"),
            ("~", "abc"),
        ]
        for (keys, text) in cases {
            let (view, engine, host) = make(text)
            let before = view.string
            for key in VimKey.parse(keys) { engine.handle(key) }
            let changed = view.string != before
            print("KEYS \(keys.padding(toLength: 10, withPad: " ", startingAt: 0)) notifications=\(host.changes) textChanged=\(changed)")
        }
    }
}
