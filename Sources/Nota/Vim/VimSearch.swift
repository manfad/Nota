import AppKit

/// A match, and whether getting to it went round the end of the note.
struct VimSearchMatch: Equatable {
    var range: NSRange
    var wrapped: Bool
}

/// Where the caret and the view were when a search prompt opened, and what was
/// waiting in front of it.
///
/// Escape has to put all of that back — vim's incremental search moves the
/// caret as you type and cancelling must leave no trace of it — and Return has
/// to pick the operator up again, since `d/foo⏎` measures from where the caret
/// was, not from where the preview left it.
struct VimSearchSession {
    var origin: Int
    var scroll: NSPoint?
    var count: Int?
    var pendingOperator: VimOperator?
    var operatorCount: Int?
    var register: Character?
}

/// Vim's own searching: `/` `?` `n` `N` `*` `#`.
///
/// None of this is the native find bar — ⌘F, ⌘G and ⇧⌘F still are, in every
/// mode. This is a pass over the note's own text with the same ICU regex `:s`
/// uses, which is what lets a search be a motion (`d/foo⏎`), wrap with a word
/// about it, and light up every match without the text storage — and so the
/// cache, and so the file — ever hearing about it.
enum VimSearch {

    // MARK: - Patterns

    /// `\c` anywhere in a pattern forces case-insensitivity and `\C` forces
    /// case-sensitivity, wherever in it they appear. ICU has no such flags, so
    /// they come out of the pattern here.
    static func caseFlag(in pattern: String) -> (pattern: String, ignoreCase: Bool?) {
        guard pattern.contains("\\") else { return (pattern, nil) }
        var cleaned = ""
        var forced: Bool?
        var escaped = false
        for character in pattern {
            if escaped {
                escaped = false
                switch character {
                case "c":
                    forced = true
                    continue
                case "C":
                    forced = false
                    continue
                default:
                    cleaned.append("\\")
                    cleaned.append(character)
                    continue
                }
            }
            if character == "\\" {
                escaped = true
                continue
            }
            cleaned.append(character)
        }
        if escaped { cleaned.append("\\") }
        return (cleaned, forced)
    }

    /// `'smartcase'`: with `'ignorecase'` on, an uppercase letter in the
    /// pattern means you meant it.
    static func isCaseInsensitive(
        pattern: String, ignoreCase: Bool, smartCase: Bool
    ) -> Bool {
        guard ignoreCase else { return false }
        guard smartCase else { return true }
        return !pattern.contains { $0.isUppercase }
    }

    /// What `*` and `#` look for: the word, and only the whole word.
    static func wordPattern(_ word: String) -> String {
        "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b"
    }

    // MARK: - Matching

    static func matches(
        of pattern: String, in text: NSString, ignoringCase: Bool
    ) -> [NSRange] {
        guard !pattern.isEmpty,
              let regex = try? NSRegularExpression(
                  pattern: pattern, options: ignoringCase ? [.caseInsensitive] : []
              )
        else { return [] }
        return regex
            .matches(in: text as String, range: NSRange(location: 0, length: text.length))
            .map(\.range)
    }

    /// The count'th match on from a location, wrapping round the end of the
    /// note the way vim does rather than stopping there.
    static func step(
        _ matches: [NSRange], from location: Int, forward: Bool, count: Int
    ) -> VimSearchMatch? {
        guard !matches.isEmpty else { return nil }
        var wrapped = false
        var current = location
        var landed = matches[0]

        for _ in 0..<max(1, count) {
            if forward {
                if let next = matches.first(where: { $0.location > current }) {
                    landed = next
                } else {
                    landed = matches[0]
                    wrapped = true
                }
            } else {
                if let previous = matches.last(where: { $0.location < current }) {
                    landed = previous
                } else {
                    landed = matches[matches.count - 1]
                    wrapped = true
                }
            }
            current = landed.location
        }
        return VimSearchMatch(range: landed, wrapped: wrapped)
    }

    // MARK: - The word under the caret

    /// The word under the caret, or the next one on the line when the caret
    /// is on a space or a comma — vim's own rule for `*`.
    static func wordUnderCaret(_ text: NSString, at location: Int) -> String? {
        wordRangeUnderCaret(text, at: location).map(text.substring(with:))
    }

    /// The same word, and where it starts. `*` searches on from the word
    /// rather than from the caret, so standing in front of one takes you to
    /// its next occurrence rather than to the word itself.
    static func wordRangeUnderCaret(_ text: NSString, at location: Int) -> NSRange? {
        guard text.length > 0 else { return nil }
        var index = min(max(0, location), text.length)
        let lineEnd = VimMotions.lineEnd(text, at: index)
        while index < lineEnd, VimMotions.characterClass(text, at: index) != .word {
            index = VimMotions.nextIndex(text, after: index)
        }
        guard index < lineEnd, VimMotions.characterClass(text, at: index) == .word else {
            return nil
        }

        var start = index
        while start > 0 {
            let previous = VimMotions.previousIndex(text, before: start)
            guard VimMotions.characterClass(text, at: previous) == .word else { break }
            start = previous
        }
        var end = index
        while end < lineEnd, VimMotions.characterClass(text, at: end) == .word {
            end = VimMotions.nextIndex(text, after: end)
        }
        return NSRange(location: start, length: end - start)
    }
}

// MARK: - The engine's side

extension VimEngine {

    static let hitBottomMessage = "search hit BOTTOM, continuing at TOP"
    static let hitTopMessage = "search hit TOP, continuing at BOTTOM"

    // MARK: Finding

    /// Every match of a pattern in the note, with vim's case rules applied:
    /// `\c` and `\C` first, then `'ignorecase'` and `'smartcase'`.
    func searchMatches(_ pattern: String) -> [NSRange] {
        let flagged = VimSearch.caseFlag(in: pattern)
        let insensitive = flagged.ignoreCase ?? VimSearch.isCaseInsensitive(
            pattern: flagged.pattern, ignoreCase: ignoreCase, smartCase: smartCase
        )
        return VimSearch.matches(of: flagged.pattern, in: text, ignoringCase: insensitive)
    }

    func findMatch(
        _ pattern: String, forward: Bool, from location: Int, count: Int = 1
    ) -> VimSearchMatch? {
        VimSearch.step(searchMatches(pattern), from: location, forward: forward, count: count)
    }

    // MARK: `/` and `?`

    /// Opens the pane. The count and any waiting operator are put aside
    /// first: the prompt clears them, and Return needs them back.
    func beginSearch(forward: Bool) {
        searchSession = VimSearchSession(
            origin: caret,
            scroll: scrollOrigin,
            count: pendingCount,
            pendingOperator: pendingOperator,
            operatorCount: operatorCount,
            register: pendingRegister
        )
        beginPrompt(forward ? "/" : "?")
    }

    /// Vim's `'incsearch'`: the caret follows the first match as the pattern
    /// is typed, and goes back to where it started when there is not one.
    func searchIncrementally(_ pattern: String, forward: Bool) {
        guard let session = searchSession else { return }
        guard !pattern.isEmpty,
              let match = findMatch(pattern, forward: forward, from: session.origin)
        else {
            textView?.clearSearchHighlights()
            moveCaret(to: session.origin)
            return
        }
        if hlsearch {
            textView?.setSearchHighlights(searchMatches(pattern))
        }
        moveCaret(to: match.range.location)
    }

    /// Return: the pattern becomes the search, and the caret — or the
    /// operator waiting on it — lands on the match.
    func commitSearch(_ typed: String, forward: Bool) {
        guard let session = searchSession else { return }
        searchSession = nil

        let pattern = typed.isEmpty ? (lastSearchPattern ?? "") : typed
        guard !pattern.isEmpty else {
            moveCaret(to: session.origin)
            show("E35: No previous regular expression")
            return
        }
        lastSearchPattern = pattern
        searchIsForward = forward

        // Back to where the search started: an operator measures from there,
        // and a failed search leaves the caret alone.
        moveCaret(to: session.origin)
        guard let match = findMatch(
            pattern, forward: forward, from: session.origin, count: max(1, session.count ?? 1)
        ) else {
            searchHighlightsVisible = false
            textView?.clearSearchHighlights()
            show("E486: Pattern not found: \(pattern)")
            return
        }

        searchHighlightsVisible = true
        refreshSearchHighlights()
        land(on: match, forward: forward, restoring: session)
    }

    /// The one thing `/⏎`, `n` and `*` all do at the end: move the caret, or
    /// hand the range to the operator that was waiting on the motion.
    private func land(
        on match: VimSearchMatch, forward: Bool, restoring session: VimSearchSession? = nil
    ) {
        if let waiting = session?.pendingOperator {
            pendingOperator = waiting
            operatorCount = session?.operatorCount
            pendingRegister = session?.register
            setMode(.operatorPending)
        }
        if pendingOperator != nil {
            // A search is an exclusive motion: `d/foo⏎` stops in front of the
            // match rather than eating it.
            applyMotion(VimMotionResult(location: match.range.location, kind: .exclusive))
            finishCommand()
        } else {
            // A search is a jump, and a jump leaves `` ` `` where it set off.
            marks.set("'", to: caret)
            moveCaret(to: match.range.location)
        }
        if match.wrapped {
            show(forward ? Self.hitBottomMessage : Self.hitTopMessage)
        }
    }

    // MARK: `n`, `N`, `*`, `#`

    /// `n` goes the way the search was started, `N` the other way.
    func repeatSearch(reversed: Bool) {
        let count = takeCount()
        guard let pattern = lastSearchPattern, !pattern.isEmpty else {
            show("E35: No previous regular expression")
            return
        }
        let forward = reversed ? !searchIsForward : searchIsForward
        guard let match = findMatch(pattern, forward: forward, from: caret, count: count) else {
            show("E486: Pattern not found: \(pattern)")
            return
        }
        searchHighlightsVisible = true
        refreshSearchHighlights()
        // The operator, if there is one, is still where `dn` left it.
        land(on: match, forward: forward)
    }

    /// `*` and `#`: the whole word under the caret becomes the search.
    func searchWordUnderCaret(forward: Bool) {
        let count = takeCount()
        guard let range = VimSearch.wordRangeUnderCaret(text, at: caret) else {
            show("E348: No string under cursor")
            return
        }
        let word = text.substring(with: range)
        let pattern = VimSearch.wordPattern(word)
        lastSearchPattern = pattern
        searchIsForward = forward
        // From the word, not from the caret: `*` in front of a word takes you
        // to that word's next occurrence, not to the word you are looking at.
        guard let match = findMatch(
            pattern, forward: forward, from: range.location, count: count
        ) else {
            show("E486: Pattern not found: \(word)")
            return
        }
        searchHighlightsVisible = true
        refreshSearchHighlights()
        land(on: match, forward: forward)
    }

    // MARK: Highlighting

    /// `'hlsearch'`: every match wears a temporary attribute — the layout
    /// manager's, not the storage's — so nothing about the highlight can ever
    /// reach the cache or the file.
    func refreshSearchHighlights() {
        guard hlsearch, searchHighlightsVisible,
              let pattern = lastSearchPattern, !pattern.isEmpty
        else {
            textView?.clearSearchHighlights()
            return
        }
        textView?.setSearchHighlights(searchMatches(pattern))
    }

    /// `:noh`. The pattern is remembered — `n` brings the highlights back,
    /// the way it does in vim — but they are off until then.
    func clearSearchHighlights() {
        searchHighlightsVisible = false
        textView?.clearSearchHighlights()
    }

    /// Where the view is looking, so Escape can put it back.
    var scrollOrigin: NSPoint? {
        textView?.enclosingScrollView?.contentView.bounds.origin
    }

    func restoreScroll(to origin: NSPoint?) {
        guard let origin, let scrollView = textView?.enclosingScrollView else { return }
        let clip = scrollView.contentView
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }
}
