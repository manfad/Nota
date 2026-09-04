import AppKit

/// A field that records the next key you press, the way a shortcut setting
/// normally works: click it, press the combination, done. Escape cancels
/// without changing anything.
///
/// It records two different things, because Nota has two different kinds of
/// shortcut. Summon is a `GlobalHotKey.Shortcut` — a key code, because Carbon
/// registers a system-wide hotkey by position. Everything in the menu is a
/// `KeyCombo` — a character, because that is what AppKit matches a key
/// equivalent against.
final class ShortcutRecorderField: NSTextField {
    /// Which of the two this field is recording.
    enum Kind {
        case globalHotKey
        case appShortcut
    }

    private let kind: Kind

    var onRecord: ((GlobalHotKey.Shortcut) -> Void)?
    var onRecordCombo: ((KeyCombo) -> Void)?

    /// What Delete puts back while recording an app shortcut. A menu command
    /// with no key at all is a command nobody can reach, so the key it ships
    /// with is what "clear" means here.
    var defaultCombo: KeyCombo?

    private var isRecording = false {
        didSet {
            needsDisplay = true
            refreshText()
        }
    }

    var shortcut: GlobalHotKey.Shortcut? {
        didSet { refreshText() }
    }

    var combo: KeyCombo? {
        didSet { refreshText() }
    }

    init(kind: Kind = .globalHotKey) {
        self.kind = kind
        super.init(frame: .zero)
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
            stopRecording()
            return
        }

        switch kind {
        case .globalHotKey: recordHotKey(event)
        case .appShortcut: recordCombo(event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // While recording, ⌘-combinations are shortcuts to capture, not menu
        // commands to run.
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    /// A test has no window to make this field first responder in, so it opens
    /// the recording itself and hands the event straight over.
    func recordForTesting(_ event: NSEvent) {
        isRecording = true
        keyDown(with: event)
    }

    private func recordHotKey(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift])
        // A bare letter would swallow ordinary typing everywhere, so insist
        // on at least one modifier.
        guard !modifiers.isEmpty else { NSSound.beep(); return }

        let recorded = GlobalHotKey.Shortcut(
            keyCode: UInt32(event.keyCode), modifiers: modifiers.rawValue
        )
        shortcut = recorded
        stopRecording()
        onRecord?(recorded)
    }

    private func recordCombo(_ event: NSEvent) {
        // Delete puts the command's own key back rather than leaving it with
        // none — see `defaultCombo`.
        if event.keyCode == 51 || event.keyCode == 117, let fallback = defaultCombo {
            combo = fallback
            stopRecording()
            onRecordCombo?(fallback)
            return
        }
        guard let recorded = KeyCombo.recorded(from: event) else { NSSound.beep(); return }
        combo = recorded
        stopRecording()
        onRecordCombo?(recorded)
    }

    private func stopRecording() {
        isRecording = false
        window?.makeFirstResponder(nil)
    }

    private func refreshText() {
        if isRecording {
            stringValue = L10n.text("Press keys…")
            textColor = .secondaryLabelColor
        } else {
            let name = kind == .appShortcut ? combo?.displayName : shortcut?.displayName
            stringValue = name ?? L10n.text("None")
            textColor = name == nil ? .secondaryLabelColor : .labelColor
        }
    }
}
