import Foundation

/// One hit: which tab it is in, a snippet of the line to show, and where the
/// match sits both in that snippet (for bolding) and in the note itself (for
/// selecting once the tab is switched to).
struct NoteSearchMatch: Equatable {
    let tabIndex: Int
    let tabTitle: String
    let snippet: String
    let rangeInSnippet: NSRange
    let rangeInText: NSRange
}

/// Case-insensitive substring search across every open tab.
///
/// Pure on purpose — it takes titles and text, so it can be exercised without
/// a window. The caller passes each note's storage string, in which an image
/// is a single object-replacement character; a query can therefore never
/// match inside an image, and every range lines up with the text storage.
enum NoteSearch {
    static let resultLimit = 200

    /// How much of the line to keep before the match when the line is long.
    private static let leadingContext = 24
    private static let maximumSnippetLength = 140
    private static let ellipsis = "…"

    static func matches(query: String, in notes: [(title: String, text: String)]) -> [NoteSearchMatch] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

        var results: [NoteSearchMatch] = []
        for (index, note) in notes.enumerated() {
            let text = note.text as NSString
            var cursor = 0

            while cursor < text.length, results.count < resultLimit {
                let remaining = NSRange(location: cursor, length: text.length - cursor)
                let found = text.range(of: needle, options: .caseInsensitive, range: remaining)
                guard found.location != NSNotFound else { break }

                results.append(match(at: found, in: text, tabIndex: index, tabTitle: note.title))
                cursor = found.location + max(1, found.length)
            }

            if results.count >= resultLimit { break }
        }
        return results
    }

    private static func match(
        at found: NSRange, in text: NSString, tabIndex: Int, tabTitle: String
    ) -> NoteSearchMatch {
        var line = text.substring(with: text.lineRange(for: found))
        while line.hasSuffix("\n") || line.hasSuffix("\r") { line.removeLast() }

        let lineStart = text.lineRange(for: found).location
        let (snippet, rangeInSnippet) = self.snippet(
            of: line, matchingAt: NSRange(location: found.location - lineStart, length: found.length)
        )

        return NoteSearchMatch(
            tabIndex: tabIndex,
            tabTitle: tabTitle,
            snippet: snippet,
            rangeInSnippet: rangeInSnippet,
            rangeInText: found
        )
    }

    /// Windows a long line around the match so the hit is always visible
    /// rather than truncated off the end of the row.
    private static func snippet(
        of line: String, matchingAt match: NSRange
    ) -> (String, NSRange) {
        let source = line as NSString
        var text = line
        var location = match.location

        if match.location > leadingContext {
            let cut = match.location - leadingContext
            text = ellipsis + source.substring(from: cut)
            location = match.location - cut + (ellipsis as NSString).length
        }

        let windowed = text as NSString
        if windowed.length > maximumSnippetLength {
            text = windowed.substring(to: maximumSnippetLength) + ellipsis
        }

        let final = text as NSString
        let clampedLocation = min(location, final.length)
        let clampedLength = min(match.length, final.length - clampedLocation)
        return (text, NSRange(location: clampedLocation, length: clampedLength))
    }
}
