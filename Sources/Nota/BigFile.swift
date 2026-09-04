import Foundation

/// The size past which a note is *big*: the word and character counts move to
/// a background queue, spell checking goes off, and the cache write waits
/// longer between keystrokes. Measured in UTF-16 units of the text storage,
/// so a 100 MB log and a 200k-line CSV both qualify and an ordinary note
/// never does.
enum BigFile {
    static let threshold = 1_000_000

    static func isBig(length: Int) -> Bool { length >= threshold }
}
