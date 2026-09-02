import Foundation

/// Works out which sidebar thumbnails to highlight for a given caret or
/// selection.
///
/// Pure, because the interesting case is easy to get wrong: with two chips
/// side by side the caret between them touches both, and a rule that accepts
/// a chip on either side lights up two thumbnails for one click.
enum ChipHighlight {
    /// - Parameters:
    ///   - clickedChipLocation: character index of a chip the person just
    ///     clicked, remembered until the selection moves some other way.
    ///   - selection: the text view's current selection.
    ///   - chipLocations: character index of every chip, in document order.
    /// - Returns: indices into `chipLocations`.
    ///   - caretIsBlock: vim's normal and visual caret sits *on* a character
    ///     rather than between two, so the chip under it is the one meant.
    static func resolve(
        clickedChipLocation: Int?,
        selection: NSRange,
        chipLocations: [Int],
        caretIsBlock: Bool = false
    ) -> Set<Int> {
        // An explicit click is unambiguous and beats everything else.
        if let clickedChipLocation,
           let index = chipLocations.firstIndex(of: clickedChipLocation) {
            return [index]
        }

        // A real selection lights up every chip it covers.
        if selection.length > 0 {
            let covered = chipLocations.enumerated().filter { _, location in
                location >= selection.location && location < NSMaxRange(selection)
            }
            return Set(covered.map(\.offset))
        }

        // A bare caret takes only the chip immediately before it — or, when
        // it is a block, the chip it is sitting on. Looking on both sides
        // would light two thumbnails whenever chips are adjacent.
        let wanted = caretIsBlock ? selection.location : selection.location - 1
        if let index = chipLocations.firstIndex(of: wanted) {
            return [index]
        }
        return []
    }
}
