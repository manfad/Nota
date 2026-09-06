import Foundation

/// Subsequence matching for the ⇧⌘J tab picker.
///
/// A query matches if its characters appear in order in the title, not
/// necessarily together. Score favours matches that are early, contiguous, and
/// sitting on word boundaries, which is what makes typing initials work.
enum FuzzyMatch {
    struct Result: Equatable {
        let score: Int
        /// Indices in the title that the query matched, for highlighting.
        let matchedIndices: [Int]
    }

    static func match(query: String, in title: String) -> Result? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return Result(score: 0, matchedIndices: []) }

        let haystack = Array(title)
        let lowered = Array(title.lowercased())
        guard needle.count <= lowered.count else { return nil }

        var indices: [Int] = []
        var score = 0
        var position = 0
        var previousMatch = -1

        for character in needle {
            var found = -1
            var index = position
            while index < lowered.count {
                if lowered[index] == character { found = index; break }
                index += 1
            }
            guard found >= 0 else { return nil }

            if found == previousMatch + 1 {
                score += 8                          // contiguous run
            }
            if found == 0 || isBoundary(haystack, at: found) {
                // Weighted heavily: typing initials is the main way people
                // use this, so "td" must find "Think different".
                score += 12
            }
            score -= min(found - max(0, previousMatch), 4)   // distance penalty

            indices.append(found)
            previousMatch = found
            position = found + 1
        }

        // A mild nudge towards shorter titles — enough to break ties, not
        // enough to outrank a real word-boundary match in a longer one.
        score += max(0, 8 - (lowered.count - needle.count))
        return Result(score: score, matchedIndices: indices)
    }

    private static func isBoundary(_ characters: [Character], at index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = characters[index - 1]
        if previous == " " || previous == "-" || previous == "_" || previous == "/" { return true }
        return previous.isLowercase && characters[index].isUppercase
    }

    /// Titles that match, best first. Ties keep the original tab order.
    static func rank(query: String, titles: [String]) -> [(index: Int, result: Result)] {
        titles.enumerated()
            .compactMap { index, title in
                match(query: query, in: title).map { (index: index, result: $0) }
            }
            .enumerated()
            .sorted { left, right in
                if left.element.result.score != right.element.result.score {
                    return left.element.result.score > right.element.result.score
                }
                return left.offset < right.offset
            }
            .map(\.element)
    }
}
