import Foundation

/// The headings `@` in the ⌘P switcher lists (Todo 9): taken from the note's
/// own text, not the render, so it costs nothing about the pane being open
/// and reads the same note a `.md` file that has never been rendered has.
///
/// ATX headings (`#` … `######`) and setext ones (`===` / `---` under a line
/// of text) are both recognised; a fence's contents are skipped exactly the
/// way `MarkdownSourceMap` skips them, so a comment that happens to start
/// with `#` inside a code block is never mistaken for one.
enum MarkdownHeadings {
    struct Heading: Equatable {
        /// 1 for `#` / `===`, up to 6 for `######`; a setext `---` is 2.
        let level: Int
        /// The heading's words, markup (leading `#`s, a trailing closing run,
        /// surrounding whitespace) stripped.
        let text: String
        /// Where the heading's own line starts in the note's text.
        let location: Int
    }

    /// Every heading in `source`, in document order.
    static func extract(from source: String) -> [Heading] {
        guard !source.isEmpty else { return [] }
        let ns = source as NSString
        var headings: [Heading] = []

        var fenceMarker: Character?
        // The most recent non-blank line that was not itself a heading —
        // what a setext underline turns into one.
        var previousLine: (start: Int, text: String)?

        var index = 0
        while index < ns.length {
            let line = lineBounds(ns, at: index)
            let text = ns.substring(with: NSRange(
                location: line.start, length: max(0, line.contentsEnd - line.start)
            ))

            if let marker = fenceMarker {
                if MarkdownSourceMap.isFence(text), MarkdownSourceMap.fenceMarker(of: text) == marker {
                    fenceMarker = nil
                }
                previousLine = nil
            } else if MarkdownSourceMap.isFence(text) {
                fenceMarker = MarkdownSourceMap.fenceMarker(of: text)
                previousLine = nil
            } else if let atx = atxHeading(text) {
                headings.append(Heading(level: atx.level, text: atx.text, location: line.start))
                previousLine = nil
            } else if let level = setextLevel(text), let previous = previousLine {
                headings.append(Heading(level: level, text: previous.text, location: previous.start))
                previousLine = nil
            } else {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                previousLine = trimmed.isEmpty ? nil : (line.start, trimmed)
            }

            guard line.end > index else { break }
            index = line.end
        }
        return headings
    }

    // MARK: - ATX: `#` … `######`

    private static func atxHeading(_ line: String) -> (level: Int, text: String)? {
        // Up to three leading spaces are still an ATX heading; four make it
        // an indented code block instead, so this stays a heading only up to
        // that point.
        var rest = Substring(line)
        var leadingSpaces = 0
        while leadingSpaces < 3, rest.first == " " {
            rest = rest.dropFirst()
            leadingSpaces += 1
        }

        let hashes = rest.prefix { $0 == "#" }
        guard (1 ... 6).contains(hashes.count) else { return nil }
        rest = rest.dropFirst(hashes.count)
        // The hashes must be followed by a space/tab or the end of the line —
        // `#tag` is prose, not a heading.
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }

        let opened = rest.drop { $0 == " " || $0 == "\t" }
        return (hashes.count, stripClosingHashes(String(opened)))
    }

    /// `## Title ##` closes with a run of `#`s of its own, which is only ever
    /// decoration — dropped along with the space that set it apart.
    private static func stripClosingHashes(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        var closing = 0
        var index = trimmed.endIndex
        while index > trimmed.startIndex, trimmed[trimmed.index(before: index)] == "#" {
            index = trimmed.index(before: index)
            closing += 1
        }
        guard closing > 0 else { return trimmed }
        guard index == trimmed.startIndex || trimmed[trimmed.index(before: index)] == " " else {
            return trimmed
        }
        trimmed = String(trimmed[..<index]).trimmingCharacters(in: .whitespaces)
        return trimmed
    }

    // MARK: - Setext: a line of `===` or `---` under a paragraph

    /// `nil` unless the whole (trimmed) line is one repeated character that
    /// makes it a setext underline — `1` for `=`, `2` for `-`.
    private static func setextLevel(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.allSatisfy({ $0 == "=" }) { return 1 }
        if trimmed.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    // MARK: - Lines

    private static func lineBounds(
        _ source: NSString, at index: Int
    ) -> (start: Int, contentsEnd: Int, end: Int) {
        guard source.length > 0 else { return (0, 0, 0) }
        let probe = NSRange(location: min(max(0, index), source.length - 1), length: 0)
        var start = 0
        var end = 0
        var contentsEnd = 0
        source.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: probe)
        return (start, contentsEnd, end)
    }
}
