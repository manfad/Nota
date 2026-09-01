import AppKit

/// What `/`, `n`, `*` and `:noh` ask the window to do. The searching itself is
/// the native find bar's — Jot does not have a second one hiding behind it.
enum VimFindAction: Equatable {
    /// `/` and `?`: the bar comes down and the field takes the typing, so
    /// Return and Escape there are the bar's own.
    case showInterface
    case next
    case previous
    /// `:noh`.
    case hide
}

/// `/` `?` `n` `N` `*` `#`.
///
/// Vim's searching is the find bar's searching: the same field, the same
/// highlight, the same ⌘G, so a search started with `/` can be carried on from
/// the menu and the other way round. All the engine keeps is which way `n`
/// goes and, for `*` and `#`, what to put on the find pasteboard — the one
/// place AppKit and vim already agree on what is being looked for.
extension VimEngine {

    /// `/` forward, `?` backward. Jot's find bar has no direction of its own,
    /// so `?` is `/` with `n` and `N` swapped over.
    func beginSearch(forward: Bool) {
        searchIsForward = forward
        host?.vimFind(.showInterface)
    }

    /// `n` goes the way the search was started, `N` the other way.
    func repeatSearch(reversed: Bool) {
        let forward = reversed ? !searchIsForward : searchIsForward
        host?.vimFind(forward ? .next : .previous)
    }

    /// `*` and `#`: the word under the caret becomes the search.
    func searchWordUnderCaret(forward: Bool) {
        guard let word = VimSearch.wordUnderCaret(text, at: caret) else {
            host?.vimShow(message: "E348: No string under cursor")
            return
        }
        lastSearchPattern = word
        searchIsForward = forward
        findPasteboard.clearContents()
        findPasteboard.setString(word, forType: .string)
        host?.vimFind(forward ? .next : .previous)
    }

    /// A native find leaves its match selected, and normal mode has no
    /// selection: the next key collapses it onto the head of the match, which
    /// is what makes `n` and then `ciw` work.
    ///
    /// `n` and `N` are spared — the find bar searches on from the selection it
    /// made last time, and taking that away would land it on the same match.
    func collapseFoundSelection(before key: VimKey) {
        guard mode == .normal, visual == nil, let textView else { return }
        let selection = textView.selectedRange()
        guard selection.length > 0 else { return }
        if let character = key.plainCharacter, character == "n" || character == "N" { return }
        textView.setSelectedRange(NSRange(location: selection.location, length: 0))
    }
}

/// The one piece of searching that is not the find bar's: which word the caret
/// is standing in.
enum VimSearch {
    /// The word under the caret, or the next one on the line when the caret
    /// is on a space or a comma — vim's own rule for `*`.
    static func wordUnderCaret(_ text: NSString, at location: Int) -> String? {
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
        return text.substring(with: NSRange(location: start, length: end - start))
    }
}
