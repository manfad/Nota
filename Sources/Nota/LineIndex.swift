import Foundation

/// Where every hard line starts.
///
/// The gutter, the footer's line count and the caret's line and column all
/// used to answer their question by walking the whole text — which is nothing
/// at all in a note and a frozen run loop in a 100 MB log. They ask this
/// table instead: built once when the note is made, kept current by the one
/// edit at a time the text storage reports, and read by binary search.
///
/// `starts[0]` is always 0 and there is one more entry after every `\n`, so
/// `lineCount == starts.count` — an empty text is one line, and a text ending
/// in a newline has one more, empty, line after it. Exactly what
/// `TextStats.lineCount` counts, and what the gutter numbers to.
///
/// Only `\n` starts a line, the same as everywhere else in Nota: a CRLF file
/// has its carriage returns sitting at the ends of the lines, and a lone CR
/// is not a line break at all.
struct LineIndex: Equatable {
    /// The line starts — but only up to `pivot`. From there on each one is
    /// stored short by `shift`, the move the last edit made and never paid
    /// for. See `apply`: paying it costs a pass over every line below the
    /// edit, and a typist who stays on one line would pay it again for every
    /// character. Nothing outside this file sees the arrangement; `start`
    /// hands out the real number.
    private var table: [Int]
    private var pivot: Int
    private var shift: Int

    /// The length of the text the table was built from, in UTF-16 units —
    /// kept so a line can name its own range without asking the text again.
    private(set) var length: Int

    /// The offset of the first character of each line, ascending, with the
    /// shift paid off — what the table means, for whoever wants the lot.
    var starts: [Int] {
        guard shift != 0 else { return table }
        var all = table
        for index in pivot..<all.count { all[index] += shift }
        return all
    }

    /// How much text is pulled out of the string at a time while scanning.
    /// Big enough that `getCharacters` is called a handful of times per
    /// megabyte, small enough that the buffer stays in cache.
    private static let chunk = 64 * 1024

    /// An empty text: one line, starting at 0.
    init() {
        table = [0]
        pivot = 1
        shift = 0
        length = 0
    }

    init(_ text: NSString) {
        table = [0]
        pivot = 0
        shift = 0
        length = text.length
        table.reserveCapacity(1 + length / 40)
        Self.appendLineStarts(
            of: text, in: NSRange(location: 0, length: length), into: &table
        )
        pivot = table.count
    }

    /// Two tables are the same when they say the same thing, whatever either
    /// is still carrying.
    static func == (lhs: LineIndex, rhs: LineIndex) -> Bool {
        lhs.length == rhs.length && lhs.starts == rhs.starts
    }

    /// Where a line really starts, shift and all.
    private func start(_ index: Int) -> Int {
        index < pivot ? table[index] : table[index] + shift
    }

    /// Every start a newline in `range` gives rise to, appended in order.
    ///
    /// Read in chunks with `getCharacters` rather than one `character(at:)`
    /// per index: the per-character call goes through the string's own
    /// machinery every time, and on a big file that is the difference between
    /// a fraction of a second and half a minute. A newline is a whole UTF-16
    /// unit that never appears inside a surrogate pair, so a chunk boundary
    /// can fall anywhere.
    private static func appendLineStarts(
        of text: NSString, in range: NSRange, into starts: inout [Int]
    ) {
        guard range.length > 0 else { return }
        var buffer = [unichar](repeating: 0, count: min(chunk, range.length))
        var offset = range.location
        let end = NSMaxRange(range)

        while offset < end {
            let count = min(chunk, end - offset)
            // The scan stays inside the buffer pointer: read through the
            // array itself and the bounds check on each of twenty million
            // characters is the slowest thing in the file.
            buffer.withUnsafeMutableBufferPointer { destination in
                let base = destination.baseAddress!
                text.getCharacters(base, range: NSRange(location: offset, length: count))
                var index = 0
                while index < count {
                    if base[index] == 0x0A { starts.append(offset + index + 1) }
                    index += 1
                }
            }
            offset += count
        }
    }

    /// Hard lines, counting the empty one after a trailing newline.
    var lineCount: Int { table.count }

    /// The 1-based line holding `location`. Out-of-range locations are
    /// clamped, so a caret that has run past the end still names the last
    /// line rather than trapping.
    func lineNumber(at location: Int) -> Int {
        guard location > 0 else { return 1 }
        // The last line whose start is at or before `location`.
        var low = 0
        var high = table.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if start(middle) <= location { low = middle } else { high = middle - 1 }
        }
        return low + 1
    }

    /// Where a 1-based line begins.
    func lineStart(ofLine line: Int) -> Int {
        start(max(0, min(line - 1, table.count - 1)))
    }

    /// A 1-based line's characters, including its trailing newline — the same
    /// span `NSString.lineRange(for:)` returns.
    func range(ofLine line: Int) -> NSRange {
        let index = max(0, min(line - 1, table.count - 1))
        let from = start(index)
        let to = index + 1 < table.count ? start(index + 1) : length
        return NSRange(location: from, length: max(0, to - from))
    }

    // MARK: Keeping up with edits

    /// Fold one edit into the table, from the three facts `NSTextStorage`
    /// reports: the range the edit *now* occupies, how much longer the text
    /// got, and the text as it now stands.
    ///
    /// Everything before the edit is untouched, everything after it merely
    /// slides by `changeInLength`, and only the starts the edit itself covers
    /// have to be worked out again — so typing into the middle of a 200k-line
    /// CSV costs the line it was typed on, not the file.
    ///
    /// The sliding is the part that would still have cost the file, half of
    /// it per keystroke. So it is not done: the move is remembered as a shift
    /// owed by everything below the edit, and the next edit in the same place
    /// — the next character typed — simply adds to it. Only an edit somewhere
    /// else has to settle up first, once.
    mutating func apply(editedRange: NSRange, changeInLength delta: Int, in text: NSString) {
        let oldLength = editedRange.length - delta
        let oldEnd = editedRange.location + max(0, oldLength)

        // A newline anywhere in the replaced text produced a start just past
        // it, so the starts that go are the ones in (location, oldEnd]. The
        // very first start is the top of the file and never one of them.
        let first = firstStart(after: editedRange.location)
        let last = firstStart(after: oldEnd)

        var replacements: [Int] = []
        Self.appendLineStarts(of: text, in: editedRange, into: &replacements)

        // The shift on hand is owed from `pivot` down. It can take this edit's
        // move as well only if it is owed from exactly where this edit ends;
        // anywhere else and it has to be paid off first.
        if pivot != last { settleShift() }
        table.replaceSubrange(first..<last, with: replacements)
        pivot = first + replacements.count
        shift += delta
        length += delta
    }

    /// Pay the shift into the table, so every start in it stands on its own
    /// again.
    private mutating func settleShift() {
        if shift != 0 {
            for index in pivot..<table.count { table[index] += shift }
            shift = 0
        }
        pivot = table.count
    }

    /// The index of the first start strictly past `location`, or the end of
    /// the table when there is none.
    private func firstStart(after location: Int) -> Int {
        var low = 0
        var high = table.count
        while low < high {
            let middle = (low + high) / 2
            if start(middle) <= location { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
