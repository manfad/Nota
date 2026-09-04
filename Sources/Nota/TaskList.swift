import AppKit

/// `- [ ]` and `- [x]`, which Foundation's parser knows nothing about.
///
/// A task item is a list item whose paragraph opens with a `[ ]` or a `[x]`,
/// so the box is found twice: once in the rendered text, where the marker is
/// taken off and a checkbox drawn in the bullet's slot, and once in the
/// source, where ticking one rewrites the single character between the
/// brackets. Both readings live here so the two can never drift apart, and
/// the footer's `3 / 7 done` counts by the same rule.
enum TaskList {

    /// The `[ ]` at the head of a rendered list item's text.
    struct Marker {
        let isDone: Bool
        /// How much of the rendered text the marker takes up — the brackets
        /// and the space after them, which the render draws none of.
        let length: Int
    }

    /// A box in the source: where its one character sits, and what it says.
    struct Box {
        /// The character between the brackets — the one a tick rewrites.
        let location: Int
        let isDone: Bool
    }

    /// The marker a rendered list item opens with, if it opens with one. The
    /// text is what Foundation handed back for the item's first paragraph,
    /// so `- [x] Buy milk` arrives here as `[x] Buy milk`.
    static func marker(atStartOf text: String) -> Marker? {
        let head = Array(text.prefix(4))
        guard head.count >= 3, head[0] == "[", head[2] == "]",
              let isDone = state(of: head[1])
        else { return nil }
        // A box with nothing after it is still a box; a `[x]words` is not.
        guard head.count > 3 else { return Marker(isDone: isDone, length: 3) }
        guard head[3] == " " else { return nil }
        return Marker(isDone: isDone, length: 4)
    }

    /// The box belonging to a task item whose source is `range` — the first
    /// line in it that opens as one. A hard-wrapped item carries its box on
    /// its opening line, and prose that happens to hold an `[x]` further
    /// along is not a box at all, since nothing but a list marker opens one.
    static func box(in source: NSString, within range: NSRange) -> Box? {
        let start = max(0, min(range.location, source.length))
        let end = max(start, min(NSMaxRange(range), source.length))
        var index = start
        while index < end {
            if let box = box(in: source, atLineStart: index, limit: end) { return box }
            index = nextLine(in: source, from: index, limit: end)
        }
        return nil
    }

    /// How many task items a note holds and how many are ticked. Walks the
    /// UTF-16 units line by line, taking no substrings: this runs over a big
    /// note on the background counting pass, and a note the size of a library
    /// must not be cut into a hundred thousand strings to be counted.
    static func counts(in text: String) -> (done: Int, total: Int) {
        let source = text as NSString
        let length = source.length
        var done = 0
        var total = 0
        var index = 0
        while index < length {
            if let box = box(in: source, atLineStart: index, limit: length) {
                total += 1
                if box.isDone { done += 1 }
            }
            index = nextLine(in: source, from: index, limit: length)
        }
        return (done, total)
    }

    /// `"3 / 7 done"` — what the footer adds after the counts for a `.md`
    /// with any task item in it.
    static func phrase(done: Int, total: Int) -> String {
        "\(done) / \(total) done"
    }

    // MARK: - One line

    /// The box on the line starting at `start`, if that line is a task item:
    /// optional indent, a list marker, then `[ ]` or `[x]` with a space or
    /// the line's end after it.
    private static func box(in source: NSString, atLineStart start: Int, limit: Int) -> Box? {
        var index = start
        while index < limit, isBlank(source.character(at: index)) { index += 1 }
        guard let afterMarker = listMarkerEnd(in: source, at: index, limit: limit) else {
            return nil
        }
        index = afterMarker
        guard index + 2 < limit,
              source.character(at: index) == UInt16(UnicodeScalar("[").value),
              source.character(at: index + 2) == UInt16(UnicodeScalar("]").value),
              let isDone = state(of: source.character(at: index + 1))
        else { return nil }
        let after = index + 3
        guard after == limit || isBlank(source.character(at: after))
            || source.character(at: after) == 0x0A
        else { return nil }
        return Box(location: index + 1, isDone: isDone)
    }

    /// Where a list item's own marker ends — `- `, `* `, `+ `, `12. `, `3) `
    /// — with the whitespace after it eaten. `nil` when the line does not
    /// open a list item at all.
    private static func listMarkerEnd(in source: NSString, at start: Int, limit: Int) -> Int? {
        guard start < limit else { return nil }
        var index = start
        let first = source.character(at: index)
        if first == UInt16(UnicodeScalar("-").value)
            || first == UInt16(UnicodeScalar("*").value)
            || first == UInt16(UnicodeScalar("+").value) {
            index += 1
        } else {
            var digits = 0
            while index < limit, isDigit(source.character(at: index)) {
                index += 1
                digits += 1
            }
            guard digits > 0, index < limit else { return nil }
            let delimiter = source.character(at: index)
            guard delimiter == UInt16(UnicodeScalar(".").value)
                || delimiter == UInt16(UnicodeScalar(")").value)
            else { return nil }
            index += 1
        }
        // A marker with no space after it is a word, not a list.
        guard index < limit, isBlank(source.character(at: index)) else { return nil }
        while index < limit, isBlank(source.character(at: index)) { index += 1 }
        return index
    }

    private static func nextLine(in source: NSString, from index: Int, limit: Int) -> Int {
        var cursor = index
        while cursor < limit, source.character(at: cursor) != 0x0A { cursor += 1 }
        return cursor + 1
    }

    /// What the character between the brackets says: a space is open, an `x`
    /// either way is ticked, and anything else is not a box.
    private static func state(of character: Character) -> Bool? {
        switch character {
        case " ": false
        case "x", "X": true
        default: nil
        }
    }

    private static func state(of unit: UInt16) -> Bool? {
        switch unit {
        case 0x20: false
        case 0x78, 0x58: true
        default: nil
        }
    }

    private static func isBlank(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x09 }

    private static func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }
}

/// A task item's box, as one character in the render.
///
/// The same mechanism the rule and the formulas use — an image the size of
/// the box, drawn through a handler so `labelColor` resolves at draw time and
/// follows light and dark — and it stands in the slot the bullet would have
/// taken, so a task item shows a checkbox and no bullet. Being a real glyph
/// is what lets a click land on it: the render maps the point to a character,
/// and this is the character it finds.
final class TaskCheckboxAttachment: NSTextAttachment {
    let isDone: Bool

    init(isDone: Bool, font: NSFont) {
        self.isDone = isDone
        super.init(data: nil, ofType: nil)

        let name = isDone ? "checkmark.square.fill" : "square"
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(
                pointSize: font.pointSize, weight: .regular
            ))
        let size = symbol?.size ?? NSSize(width: font.pointSize, height: font.pointSize)
        image = NSImage(size: size, flipped: false) { rect in
            symbol?.draw(in: rect)
            NSColor.labelColor.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        // Centred on the font's cap height rather than sat on the baseline,
        // so the box lines up with the words beside it.
        bounds = NSRect(
            x: 0, y: (font.capHeight / 2 - size.height / 2).rounded(),
            width: size.width, height: size.height
        )
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
