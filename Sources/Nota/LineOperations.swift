import Foundation

/// The line hands a Notepad++ user's fingers already know — move a line,
/// duplicate it, comment it out, indent it — worked out here rather than in
/// the editor, so each one is an answer that can be read and tested on its
/// own.
///
/// Every question is asked of the note's `LineIndex`: which lines a selection
/// touches, where each of them starts and where it ends. Nothing walks the
/// text looking for newlines, so ⌥↓ in a 200k-line CSV costs the two lines it
/// swaps and not the file. The one thing the text itself is read for is the
/// characters of those lines.
///
/// Hard lines throughout, the same ones the gutter numbers: word wrap moves
/// nothing here.
enum LineOperations {

    /// A piece of what an operation puts back. The parts that are the note's
    /// own characters are named rather than copied out, so a line carrying a
    /// picture keeps its attachment (and its attributes) when it moves —
    /// spelling it as a `String` would leave the object-replacement character
    /// behind with nothing attached to it.
    enum Piece: Equatable {
        /// Characters of the note as it stands, by range.
        case copy(NSRange)
        /// Characters that were not there before: a newline, a comment token,
        /// an indent.
        case text(String)
    }

    /// One replacement, and where the selection goes once it is in. Every
    /// operation answers in this shape, so the editor has a single way to
    /// apply one and each press is a single undo step.
    struct Edit: Equatable {
        var range: NSRange
        var pieces: [Piece]
        var selection: [NSRange]

        /// What the pieces spell out — what `shouldChangeText` is told, and
        /// what a test compares against.
        func string(in text: NSString) -> String {
            var result = ""
            for piece in pieces {
                switch piece {
                case .copy(let range): result += text.substring(with: range)
                case .text(let value): result += value
                }
            }
            return result
        }
    }

    /// What one press of Tab, ⌘] or ⇧Tab is worth. Nota has no indent setting
    /// of its own — vim's `shiftwidth` and `expandtab` are spelled in the
    /// SPEC and not implemented — so the unit is one tab, the character the
    /// editor already inserts.
    static let indentUnit = "\t"

    /// How many spaces an outdent will take off a line indented with them
    /// instead. A tab's usual width, and only ever used to undo spaces
    /// somebody else put there.
    static let spacesPerIndent = 4

    // MARK: - Lines a selection touches

    /// The 1-based lines a selection covers. A selection that ends exactly
    /// where a line begins stops on the line before it: dragging down to the
    /// start of the next line has not touched that line.
    static func lines(touching selection: NSRange, in index: LineIndex) -> ClosedRange<Int> {
        let first = index.lineNumber(at: selection.location)
        var last = index.lineNumber(at: NSMaxRange(selection))
        if selection.length > 0, last > first,
           index.lineStart(ofLine: last) == NSMaxRange(selection) {
            last -= 1
        }
        return first...last
    }

    /// Where a line's characters stop, its newline excluded. Every line but
    /// the last one ends in a newline — that is what made the line after it —
    /// so this needs no look at the text.
    static func contentEnd(ofLine line: Int, in index: LineIndex) -> Int {
        let range = index.range(ofLine: line)
        return line < index.lineCount ? NSMaxRange(range) - 1 : NSMaxRange(range)
    }

    /// The characters of a run of lines, the last one's newline left off.
    private static func span(of lines: ClosedRange<Int>, in index: LineIndex) -> NSRange {
        let start = index.lineStart(ofLine: lines.lowerBound)
        return NSRange(location: start, length: contentEnd(ofLine: lines.upperBound, in: index) - start)
    }

    // MARK: - ⌥↑ / ⌥↓

    /// The lines the selection touches change places with the line above
    /// them. Nothing to do on the first line, and the newline count never
    /// changes, so no stray line is left at either end.
    static func moveUp(text: NSString, index: LineIndex, selection: NSRange) -> Edit? {
        let lines = lines(touching: selection, in: index)
        guard lines.lowerBound > 1 else { return nil }
        let above = index.range(ofLine: lines.lowerBound - 1)
        let block = span(of: lines, in: index)
        let range = NSRange(location: above.location, length: NSMaxRange(block) - above.location)
        return Edit(
            range: range,
            pieces: [
                .copy(block),
                .text("\n"),
                .copy(NSRange(location: above.location, length: above.length - 1)),
            ],
            selection: [shift(selection, by: -above.length)]
        )
    }

    /// The same the other way. The line below joins the note above the block,
    /// so the block lands one line further down.
    static func moveDown(text: NSString, index: LineIndex, selection: NSRange) -> Edit? {
        let lines = lines(touching: selection, in: index)
        guard lines.upperBound < index.lineCount else { return nil }
        let block = span(of: lines, in: index)
        let below = index.range(ofLine: lines.upperBound + 1)
        let belowContent = NSRange(
            location: below.location,
            length: contentEnd(ofLine: lines.upperBound + 1, in: index) - below.location
        )
        let range = NSRange(
            location: block.location, length: NSMaxRange(belowContent) - block.location
        )
        return Edit(
            range: range,
            pieces: [.copy(belowContent), .text("\n"), .copy(block)],
            selection: [shift(selection, by: belowContent.length + 1)]
        )
    }

    // MARK: - ⇧⌥↓ and ⌘D

    /// A second copy of the lines, straight below them, with the caret or the
    /// selection on the copy — the line you meant to work on is the new one.
    static func duplicate(text: NSString, index: LineIndex, selection: NSRange) -> Edit? {
        let lines = lines(touching: selection, in: index)
        let block = span(of: lines, in: index)
        return Edit(
            range: NSRange(location: NSMaxRange(block), length: 0),
            pieces: [.text("\n"), .copy(block)],
            selection: [shift(selection, by: block.length + 1)]
        )
    }

    /// The next place `needle` appears, starting at `location` and coming
    /// round the end of the note, skipping the places already selected.
    /// Case-sensitive and literal: ⌘D adds another of exactly what is in
    /// hand, not something that merely sorts the same.
    static func nextOccurrence(
        of needle: String, in text: NSString, from location: Int, skipping selected: [NSRange]
    ) -> NSRange? {
        let length = (needle as NSString).length
        guard length > 0, length <= text.length else { return nil }
        var from = max(0, min(location, text.length))
        let start = from
        var wrapped = false

        while true {
            let scope = NSRange(location: from, length: text.length - from)
            let found = scope.length >= length
                ? text.range(of: needle, options: .literal, range: scope)
                : NSRange(location: NSNotFound, length: 0)
            if found.location == NSNotFound {
                if wrapped { return nil }
                wrapped = true
                from = 0
                continue
            }
            if !selected.contains(where: { NSEqualRanges($0, found) }) { return found }
            // Already in hand: step past it, and give up once the walk has
            // come all the way back round to where it set off.
            from = found.location + 1
            if wrapped, found.location >= start { return nil }
        }
    }

    // MARK: - ⌘/

    /// What a line of this file is commented with, by extension — the
    /// author's own word for what the file is, the same rule the previews
    /// follow. Nothing for the formats that have no line comment (`md`,
    /// `txt`, `html`, `css`, `json`) or that Nota has never heard of, and
    /// there the menu item is disabled.
    static func commentToken(forExtension fileExtension: String) -> String? {
        let spelling = fileExtension.lowercased()
        for entry in commentTokens where entry.extensions.contains(spelling) {
            return entry.token
        }
        return nil
    }

    private static let commentTokens: [(token: String, extensions: Set<String>)] = [
        ("#", ["py", "sh", "bash", "zsh", "rb", "yaml", "yml", "toml", "ini", "cfg", "conf"]),
        ("//", ["js", "ts", "jsx", "tsx", "swift", "c", "h", "cpp", "hpp",
                "java", "kt", "go", "rs", "cs", "scala", "php"]),
        ("--", ["sql", "lua", "hs"]),
        ("%", ["tex", "latex"]),
        (";", ["lisp", "clj", "el"]),
    ]

    /// Comment the lines out, or take the comment off. Off only when every
    /// line with anything on it is already commented — a selection where one
    /// line is bare is a selection that wants commenting, so the bare ones
    /// join the rest.
    ///
    /// The token goes in at the smallest indent the block shares, so a
    /// commented block keeps its shape and uncommenting puts it back exactly.
    /// Blank lines are left alone, unless blank is all there is.
    static func toggleComment(
        text: NSString, index: LineIndex, selection: NSRange, token: String
    ) -> Edit? {
        let lines = lines(touching: selection, in: index)
        let shapes = lines.map { shape(ofLine: $0, text: text, index: index) }
        let written = shapes.filter { !$0.isBlank }
        let target = written.isEmpty ? shapes : written

        var changes: [Change] = []
        if target.allSatisfy({ isCommented($0, with: token, in: text) }) {
            let tokenLength = (token as NSString).length
            for shape in target {
                var removed = tokenLength
                // The space the comment went in with comes off with it, and
                // a comment typed without one still uncomments.
                let after = shape.indentEnd + tokenLength
                if after < shape.contentEnd, text.character(at: after) == 0x20 { removed += 1 }
                changes.append(Change(location: shape.indentEnd, removed: removed, inserted: ""))
            }
        } else {
            let indent = target.map(\.indentWidth).min() ?? 0
            for shape in target {
                changes.append(Change(
                    location: shape.start + indent, removed: 0, inserted: token + " "
                ))
            }
        }
        return edit(changes, over: span(of: lines, in: index), selection: selection)
    }

    private static func isCommented(_ shape: LineShape, with token: String, in text: NSString) -> Bool {
        let length = (token as NSString).length
        guard shape.indentEnd + length <= shape.contentEnd else { return false }
        let range = NSRange(location: shape.indentEnd, length: length)
        return text.compare(token, options: .literal, range: range) == .orderedSame
    }

    // MARK: - Tab / ⇧Tab and ⌘] / ⌘[

    /// One unit of indent on the front of every line the selection touches.
    /// An empty line in the middle of a block stays empty — there is nothing
    /// there to move — but ⌘] on an empty line with only the caret on it does
    /// what it was asked and inserts.
    static func indent(text: NSString, index: LineIndex, selection: NSRange) -> Edit? {
        let lines = lines(touching: selection, in: index)
        let skipsEmpty = selection.length > 0
        var changes: [Change] = []
        for line in lines {
            let shape = shape(ofLine: line, text: text, index: index)
            if skipsEmpty, shape.contentEnd == shape.start { continue }
            changes.append(Change(location: shape.start, removed: 0, inserted: indentUnit))
        }
        return edit(changes, over: span(of: lines, in: index), selection: selection)
    }

    /// One unit off the front of each line: a tab, or up to a tab's worth of
    /// the spaces somebody else indented with. A line with no indent to give
    /// back is left as it is.
    static func outdent(text: NSString, index: LineIndex, selection: NSRange) -> Edit? {
        let lines = lines(touching: selection, in: index)
        var changes: [Change] = []
        for line in lines {
            let shape = shape(ofLine: line, text: text, index: index)
            guard shape.start < shape.contentEnd else { continue }
            var removed = 0
            if text.character(at: shape.start) == 0x09 {
                removed = 1
            } else {
                while removed < spacesPerIndent, shape.start + removed < shape.contentEnd,
                      text.character(at: shape.start + removed) == 0x20 {
                    removed += 1
                }
            }
            guard removed > 0 else { continue }
            changes.append(Change(location: shape.start, removed: removed, inserted: ""))
        }
        return edit(changes, over: span(of: lines, in: index), selection: selection)
    }

    // MARK: - Lines, one at a time

    /// A line as these operations need it: where it starts, where its indent
    /// stops and where its characters do.
    private struct LineShape {
        var start: Int
        var indentEnd: Int
        var contentEnd: Int
        var isBlank: Bool { indentEnd == contentEnd }
        /// The indent in characters. Tabs and spaces both count as one, which
        /// is what keeps a block indented one way lined up with itself.
        var indentWidth: Int { indentEnd - start }
    }

    private static func shape(ofLine line: Int, text: NSString, index: LineIndex) -> LineShape {
        let start = index.lineStart(ofLine: line)
        let end = contentEnd(ofLine: line, in: index)
        var indentEnd = start
        while indentEnd < end {
            let character = text.character(at: indentEnd)
            guard character == 0x20 || character == 0x09 else { break }
            indentEnd += 1
        }
        return LineShape(start: start, indentEnd: indentEnd, contentEnd: end)
    }

    // MARK: - Many small changes, one edit

    /// One line's worth of change, in the note's own coordinates.
    private struct Change {
        var location: Int
        var removed: Int
        var inserted: String
    }

    /// Fold the per-line changes into the single replacement the editor
    /// applies, and carry the selection through them. The changes are in
    /// order and never overlap — one per line — so the fold is a walk.
    private static func edit(_ changes: [Change], over span: NSRange, selection: NSRange) -> Edit? {
        let real = changes.filter { $0.removed > 0 || !$0.inserted.isEmpty }
        guard !real.isEmpty else { return nil }

        var pieces: [Piece] = []
        var cursor = span.location
        for change in real {
            if change.location > cursor {
                pieces.append(.copy(NSRange(location: cursor, length: change.location - cursor)))
            }
            if !change.inserted.isEmpty { pieces.append(.text(change.inserted)) }
            cursor = change.location + change.removed
        }
        if NSMaxRange(span) > cursor {
            pieces.append(.copy(NSRange(location: cursor, length: NSMaxRange(span) - cursor)))
        }
        return Edit(range: span, pieces: pieces, selection: [map(selection, through: real)])
    }

    /// Where the selection is once the changes are in. A caret rides with the
    /// text it sits in front of; a selection keeps its lines, so its start
    /// stays put where a line was pushed right underneath it and its end
    /// takes in whatever was added.
    private static func map(_ selection: NSRange, through changes: [Change]) -> NSRange {
        guard selection.length > 0 else {
            return NSRange(
                location: map(selection.location, through: changes, sticksLeft: false), length: 0
            )
        }
        let start = map(selection.location, through: changes, sticksLeft: true)
        let end = map(NSMaxRange(selection), through: changes, sticksLeft: false)
        return NSRange(location: start, length: max(0, end - start))
    }

    private static func map(_ location: Int, through changes: [Change], sticksLeft: Bool) -> Int {
        var result = location
        for change in changes {
            let end = change.location + change.removed
            let inserted = (change.inserted as NSString).length
            if location > end || (location == end && !(change.removed == 0 && sticksLeft)) {
                result += inserted - change.removed
            } else if location > change.location {
                // Inside what went: as far into what came instead, at most.
                let inside = location - change.location
                result += min(inside, inserted) - inside
            }
        }
        return result
    }

    private static func shift(_ range: NSRange, by delta: Int) -> NSRange {
        NSRange(location: max(0, range.location + delta), length: range.length)
    }
}
