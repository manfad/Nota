import AppKit

/// One key press, in vim's terms rather than AppKit's.
///
/// Everything downstream — the engine, the tests, and later the vimrc's
/// mappings — speaks in these rather than in `NSEvent`s, so a mapping read
/// from a file and a key struck on the keyboard arrive as the same value.
struct VimKey: Equatable, Hashable {
    enum Base: Equatable, Hashable {
        case character(Character)
        case escape, enter, tab, backspace
        case up, down, left, right
    }

    var base: Base
    var control = false
    var option = false

    static func char(
        _ character: Character, control: Bool = false, option: Bool = false
    ) -> VimKey {
        VimKey(base: .character(character), control: control, option: option)
    }

    static let escape = VimKey(base: .escape)
    static let enter = VimKey(base: .enter)

    /// The plain character this key stands for — nil for anything wearing a
    /// modifier, so `⌃d` is never mistaken for `d`.
    var plainCharacter: Character? {
        guard case let .character(character) = base, !control, !option else { return nil }
        return character
    }

    /// The character regardless of modifiers, for matching `⌃d` and friends.
    var character: Character? {
        guard case let .character(character) = base else { return nil }
        return character
    }
}

// MARK: - From the keyboard

extension VimKey {
    /// `nil` when the event is not ours to take: anything with ⌘ belongs to
    /// the menus, in every mode.
    init?(event: NSEvent) {
        let flags = event.modifierFlags
        guard !flags.contains(.command) else { return nil }
        let control = flags.contains(.control)
        let option = flags.contains(.option)

        switch event.keyCode {
        case 53: self = .escape; return
        case 36, 76: self = VimKey(base: .enter, control: control, option: option); return
        case 48: self = VimKey(base: .tab, control: control, option: option); return
        case 51: self = VimKey(base: .backspace, control: control, option: option); return
        case 123: self = VimKey(base: .left, control: control, option: option); return
        case 124: self = VimKey(base: .right, control: control, option: option); return
        case 125: self = VimKey(base: .down, control: control, option: option); return
        case 126: self = VimKey(base: .up, control: control, option: option); return
        default: break
        }

        guard let characters = event.charactersIgnoringModifiers,
              let character = characters.first
        else { return nil }

        // A terminal sends ⌃[ as Escape, and vim has always taken it as one.
        if control, character == "[" {
            self = .escape
            return
        }
        self = VimKey(base: .character(character), control: control, option: option)
    }
}

// MARK: - From vim's own notation

extension VimKey {
    /// Parses `dw`, `<Esc>`, `<C-r>`, `<leader>x` and the like into keys.
    ///
    /// Used by the tests to type at the engine, and by the vimrc parser for
    /// the right-hand side of a mapping, so both agree on what `<C-w>` means.
    /// An unrecognised `<…>` is taken literally, the way vim takes it.
    static func parse(_ notation: String, leader: String = "\\") -> [VimKey] {
        var keys: [VimKey] = []
        let source = Array(notation)
        var index = 0

        while index < source.count {
            guard source[index] == "<",
                  let close = source[index...].firstIndex(of: ">"),
                  close > index + 1
            else {
                keys.append(.char(source[index]))
                index += 1
                continue
            }

            let name = String(source[(index + 1)..<close])
            if let parsed = named(name, leader: leader) {
                keys.append(contentsOf: parsed)
                index = close + 1
            } else {
                keys.append(.char(source[index]))
                index += 1
            }
        }
        return keys
    }

    /// The body of a `<…>`, or nil when it is not a name we know.
    private static func named(_ name: String, leader: String) -> [VimKey]? {
        switch name.lowercased() {
        case "esc": return [.escape]
        case "cr", "return", "enter": return [.enter]
        case "space": return [.char(" ")]
        case "tab": return [VimKey(base: .tab)]
        case "bs", "backspace": return [VimKey(base: .backspace)]
        case "up": return [VimKey(base: .up)]
        case "down": return [VimKey(base: .down)]
        case "left": return [VimKey(base: .left)]
        case "right": return [VimKey(base: .right)]
        case "lt": return [.char("<")]
        case "leader": return parse(leader, leader: "\\")
        case "nop": return []
        default: break
        }

        // <C-x>, <S-x>, <A-x>/<M-x>, and combinations like <C-S-x>.
        var control = false
        var option = false
        var shift = false
        var rest = Substring(name)
        while rest.count > 2, rest.dropFirst().first == "-" {
            switch rest.first?.lowercased() {
            case "c": control = true
            case "s": shift = true
            case "a", "m": option = true
            default: return nil
            }
            rest = rest.dropFirst(2)
        }
        guard control || option || shift else { return nil }

        // A named key can still wear modifiers: <C-CR>, <S-Tab>.
        if rest.count > 1 {
            guard let base = named(String(rest), leader: leader)?.first else { return nil }
            return [VimKey(base: base.base, control: control, option: option)]
        }
        guard var character = rest.first else { return nil }
        if shift { character = Character(character.uppercased()) }
        return [VimKey(base: .character(character), control: control, option: option)]
    }
}
