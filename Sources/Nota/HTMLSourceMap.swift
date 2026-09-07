import Foundation

/// Where in a page's source the element the reader pressed is written.
///
/// A DOM is not a list of source ranges, and this does not pretend otherwise.
/// It is a best-effort alignment between two sequences that usually agree and
/// sometimes do not: the start tags the file actually contains, in the order
/// they are written, and the elements WebKit ended up with, in document order.
/// The two drift for reasons that are all normal HTML — the parser implies an
/// `<html>`, a `<head>`, a `<body>` and a `<tbody>` nobody wrote; a script
/// adds a node the file never had; a `<p>` the author left open closes itself
/// somewhere the source gives no sign of. So the alignment walks both at once
/// by tag name, skips what one side has and the other does not, and, when it
/// can no longer tell where it is, answers `nil`. A caret in the wrong place is
/// worse than no caret: this would rather say nothing than point at the wrong
/// element.
///
/// Nothing here knows about WebKit. The page hands over an index and the tag
/// names up to it, and this hands back a range in the editor's own UTF-16
/// counting — the start tag, or the whole element when the element holds
/// nothing but text and inline markup and the walk found its end tag.
///
/// The tokeniser is `HTMLFormat`'s, the one the Beautify button already walks
/// a page with; a page it refuses — an unterminated comment, an unclosed
/// quote, nesting past 256 — simply has no map.
struct HTMLSourceMap {

    /// One element, as the file writes it, in the editor's own counting.
    private struct Tag {
        let name: String
        /// The start tag, `<p class="a">`.
        let open: NSRange
        /// The start tag through the end tag, when revealing the whole
        /// element is the better answer — a heading, a paragraph, a cell.
        let whole: NSRange?
    }

    private let tags: [Tag]
    /// The same tags' names on their own, since the alignment asks for them a
    /// great many times and never for anything else.
    private let names: [String]

    /// How far ahead either side may be searched when the two disagree. Three
    /// is what an implied `<html><head><body>` costs and four leaves a little
    /// room; past that the map has lost its place and says so.
    private static let window = 4

    /// `nil` for a page the tokeniser will not read, which is the same answer
    /// the Beautify button gives it.
    init?(source: String) {
        guard let found = try? HTMLFormat.sourceTags(of: source) else { return nil }
        let offsets = SourceOffsets.utf8(of: source)
        tags = found.map { tag in
            Tag(
                name: tag.name,
                open: offsets.range(from: tag.open.lowerBound, to: tag.open.upperBound),
                whole: tag.holdsTextOnly ? tag.whole.map {
                    offsets.range(from: $0.lowerBound, to: $0.upperBound)
                } : nil
            )
        }
        names = found.map(\.name)
    }

    /// How many elements the source itself writes — for the tests, and for a
    /// caller wanting to know whether there is anything here at all.
    var count: Int { tags.count }

    /// The source of the element at `domIndex` in the page's own document
    /// order, given the tag names of every element up to and including it
    /// (lowercased, as `querySelectorAll('*')` walks them).
    ///
    /// `nil` when the element is one the file never wrote, or when the two
    /// sequences have drifted too far apart to be sure which tag is which.
    func range(ofElementAt domIndex: Int, tagNames: [String]) -> NSRange? {
        guard domIndex >= 0, domIndex < tagNames.count else { return nil }
        var dom = 0
        var source = 0
        while dom <= domIndex {
            guard source < tags.count else { return nil }
            if tags[source].name == tagNames[dom] {
                if dom == domIndex { return tags[source].whole ?? tags[source].open }
                dom += 1
                source += 1
                continue
            }
            // They disagree. Either the DOM has elements the file does not —
            // the implied ones, and anything a script added — or the file has
            // tags the DOM did not keep. Look a little way ahead on both
            // sides and take the nearer recovery, the DOM's first when they
            // tie, since that is much the commoner of the two.
            let skip = Self.lookAhead(for: tags[source].name, in: tagNames, from: dom)
            let advance = Self.lookAhead(for: tagNames[dom], in: names, from: source)
            if let skip, advance == nil || skip <= advance! {
                // The DOM elements between here and there were never written.
                if domIndex < dom + skip { return nil }
                dom += skip
            } else if let advance {
                source += advance
            } else {
                // Neither side can find the other. Somewhere back there the
                // map lost its place, and guessing from here would point the
                // caret at a tag the reader did not press.
                return nil
            }
        }
        return nil
    }

    /// The nearest position after `from` where `name` turns up again, within
    /// the window — or `nil` if it does not.
    private static func lookAhead(for name: String, in names: [String], from: Int) -> Int? {
        for step in 1 ... window where from + step < names.count {
            if names[from + step] == name { return step }
        }
        return nil
    }
}
