import Foundation

/// `qa` … `q` … `@a`.
///
/// A macro is nothing but the keys you struck, written into the register you
/// named — which is why `"ap` pastes them out as text you can read and edit,
/// and why yanking a line of key notation and running `@a` on it works. The
/// notation is vim's own, so what comes back out of the register is the same
/// thing `VimKey.parse` reads on the way in.
extension VimKey {
    /// The inverse of `VimKey.parse` for one key.
    var notation: String {
        let body: String
        var named = true
        switch base {
        case .character(let character):
            body = String(character)
            named = false
        case .escape: body = "Esc"
        case .enter: body = "CR"
        case .tab: body = "Tab"
        case .backspace: body = "BS"
        case .up: body = "Up"
        case .down: body = "Down"
        case .left: body = "Left"
        case .right: body = "Right"
        }
        var modifiers = ""
        if control { modifiers += "C-" }
        if option { modifiers += "A-" }
        if named || !modifiers.isEmpty { return "<\(modifiers)\(body)>" }
        // A bare `<` would read back as the start of a key name.
        return body == "<" ? "<lt>" : body
    }
}

extension VimEngine {

    /// `qa`. An uppercase name appends to what the register already holds,
    /// the same way a yank into `"A` does.
    func startRecording(into name: Character) {
        guard name.isLetter else { return }
        recordingRegister = name
        recordedKeys = []
        publishPendingKeys()
    }

    /// The second `q`.
    func stopRecording() {
        guard let name = recordingRegister else { return }
        recordingRegister = nil
        registers.write(
            VimRegisters.Entry(text: recordedKeys.map(\.notation).joined(), isLinewise: false),
            to: name
        )
        recordedKeys = []
        publishPendingKeys()
    }

    /// Called for every key that reached the engine from a keyboard. Keys
    /// played back by a macro or by `.` are not struck by anyone, so they are
    /// not written down; nor is the `q` that stopped the recording.
    func noteRecordedKey(_ key: VimKey, wasRecording: Character?) {
        guard let current = recordingRegister, current == wasRecording,
              macroDepth == 0, !isReplaying
        else { return }
        recordedKeys.append(key)
    }

    /// `@a`, and `@@` for whichever was played last.
    func playMacro(register name: Character, count: Int) {
        guard let target = name == "@" ? lastPlayedRegister : name,
              let entry = registers.read(target), !entry.text.isEmpty
        else { return }
        lastPlayedRegister = target
        // A macro that plays itself would otherwise never come back.
        guard macroDepth < 32 else { return }
        macroDepth += 1
        let keys = VimKey.parse(entry.text)
        for _ in 0..<max(1, count) {
            for key in keys { feed(key) }
        }
        macroDepth -= 1
        discardCommandKeys()
    }
}
