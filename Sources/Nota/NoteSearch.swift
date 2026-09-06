import Foundation

/// Where a hit sits in the tab holding it. A note is one run of text, and a
/// range into it says everything; a document and a book are read in parts, so
/// the part comes with the range — the page a document's hit is printed on,
/// the chapter a book's is written in. What the window does to reveal one is
/// a different thing in each case, and this is what it asks.
enum NoteSearchLocation: Equatable {
    /// A range in the note's own text storage.
    case text(NSRange)
    /// A range in that page's own text, as PDFKit reads it back.
    case pdf(page: Int, range: NSRange)
    /// A range in that chapter's words, with the XHTML left behind.
    case book(chapter: Int, range: NSRange)

    /// The range inside whichever run of text the hit was found in.
    var range: NSRange {
        switch self {
        case .text(let range): return range
        case .pdf(_, let range): return range
        case .book(_, let range): return range
        }
    }
}

/// What one open tab hands the search.
///
/// A note hands its storage string, in which an image is a single
/// object-replacement character — a query can therefore never match inside an
/// image, and every range lines up with the text view the hit will be selected
/// in. A document hands its pages and a book its chapters, in the order they
/// are read, because that is the smallest thing either of them can be revealed
/// at.
struct NoteSearchSource: Equatable {
    enum Parts: Equatable {
        case text(String)
        case pages([String])
        case chapters([String])
    }

    let title: String
    let parts: Parts

    init(title: String, parts: Parts) {
        self.title = title
        self.parts = parts
    }

    init(title: String, text: String) {
        self.init(title: title, parts: .text(text))
    }
}

/// One hit: which tab it is in, a snippet of the line to show, where the match
/// sits in that snippet (for bolding), and where it lives in the tab itself
/// (for revealing once the tab is switched to).
struct NoteSearchMatch: Equatable {
    let tabIndex: Int
    let tabTitle: String
    let snippet: String
    let rangeInSnippet: NSRange
    let location: NoteSearchLocation

    /// Where the hit sits in the run of text it was found in — the note's
    /// storage, the page's text, the chapter's words. The name is the one it
    /// had when a note's storage was the only text there was.
    var rangeInText: NSRange { location.range }
}

/// Case-insensitive substring search across every open tab.
///
/// Pure on purpose — it takes titles and text, so it can be exercised without
/// a window. A text tab is searched as one run; a document is searched a page
/// at a time and a book a chapter at a time, so a hit carries the part it was
/// found in and the window has somewhere to take the reader.
enum NoteSearch {
    static let resultLimit = 200

    /// How much of the line to keep before the match when the line is long.
    private static let leadingContext = 24
    private static let maximumSnippetLength = 140
    private static let ellipsis = "…"

    static func matches(query: String, in notes: [NoteSearchSource]) -> [NoteSearchMatch] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

        var results: [NoteSearchMatch] = []
        for (index, note) in notes.enumerated() {
            for section in sections(of: note) {
                let text = section.text as NSString
                var cursor = 0

                while cursor < text.length, results.count < resultLimit {
                    let remaining = NSRange(location: cursor, length: text.length - cursor)
                    let found = text.range(of: needle, options: .caseInsensitive, range: remaining)
                    guard found.location != NSNotFound else { break }

                    results.append(match(
                        at: found, in: text, tabIndex: index, tabTitle: note.title,
                        location: section.location(found), prefix: section.prefix
                    ))
                    cursor = found.location + max(1, found.length)
                }

                if results.count >= resultLimit { break }
            }

            if results.count >= resultLimit { break }
        }
        return results
    }

    /// The older shape, for the callers that only ever have text: one part per
    /// tab and every hit a `.text` one.
    static func matches(
        query: String, in notes: [(title: String, text: String)]
    ) -> [NoteSearchMatch] {
        matches(query: query, in: notes.map { NoteSearchSource(title: $0.title, text: $0.text) })
    }

    /// The runs of text one tab is searched in, each with what a hit in it
    /// means and what its row says before the line itself. A page says which
    /// page it is — a document's hit is otherwise a line with no address — and
    /// a note and a chapter say nothing, the tab's title being the whole
    /// address either of them has.
    private static func sections(
        of source: NoteSearchSource
    ) -> [(text: String, location: (NSRange) -> NoteSearchLocation, prefix: String)] {
        switch source.parts {
        case .text(let text):
            return [(text, { .text($0) }, "")]
        case .pages(let pages):
            return pages.enumerated().map { index, text in
                (text, { .pdf(page: index, range: $0) },
                 "\(L10n.text("Page")) \(index + 1) · ")
            }
        case .chapters(let chapters):
            return chapters.enumerated().map { index, text in
                (text, { .book(chapter: index, range: $0) }, "")
            }
        }
    }

    private static func match(
        at found: NSRange, in text: NSString, tabIndex: Int, tabTitle: String,
        location: NoteSearchLocation, prefix: String
    ) -> NoteSearchMatch {
        var line = text.substring(with: text.lineRange(for: found))
        while line.hasSuffix("\n") || line.hasSuffix("\r") { line.removeLast() }

        let lineStart = text.lineRange(for: found).location
        let (windowed, rangeInWindow) = self.snippet(
            of: line, matchingAt: NSRange(location: found.location - lineStart, length: found.length)
        )
        let rangeInSnippet = NSRange(
            location: rangeInWindow.location + (prefix as NSString).length,
            length: rangeInWindow.length
        )

        return NoteSearchMatch(
            tabIndex: tabIndex,
            tabTitle: tabTitle,
            snippet: prefix + windowed,
            rangeInSnippet: rangeInSnippet,
            location: location
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
