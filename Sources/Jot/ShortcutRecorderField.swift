import AppKit

/// A field that records the next key you press, the way a shortcut setting
/// normally works: click it, press the combination, done. Escape cancels
/// without changing anything.
final class ShortcutRecorderField: NSTextField {
    var onRecord: ((GlobalHotKey.Shortcut) -> Void)?

    private var isRecording = false {
        didSet {
            needsDisplay = true
            refreshText()
        }
    }

    var shortcut: GlobalHotKey.Shortcut? {
        didSet { refreshText() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false
        isSelectable = false
        isBezeled = true
        bezelStyle = .roundedBezel
        alignment = .center
        font = .systemFont(ofSize: 12)
        refreshText()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { isRecording = true }
        return became
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        // Escape backs out and leaves the existing shortcut alone.
        if event.keyCode == 53 {
            isRecording = false
            window?.makeFirstResponder(nil)
            return
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift])
        // A bare letter would swallow ordinary typing everywhere, so insist
        // on at least one modifier.
        guard !modifiers.isEmpty else { NSSound.beep(); return }

        let recorded = GlobalHotKey.Shortcut(
            keyCode: UInt32(event.keyCode), modifiers: modifiers.rawValue
        )
        shortcut = recorded
        isRecording = false
        window?.makeFirstResponder(nil)
        onRecord?(recorded)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // While recording, ⌘-combinations are shortcuts to capture, not menu
        // commands to run.
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    private func refreshText() {
        if isRecording {
            stringValue = "Press keys…"
            textColor = .secondaryLabelColor
        } else {
            stringValue = shortcut?.displayName ?? "None"
            textColor = shortcut == nil ? .secondaryLabelColor : .labelColor
        }
    }
}
