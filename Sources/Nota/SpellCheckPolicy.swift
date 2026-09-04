import Foundation

/// Whether a tab gets the system spell checker. Off for anything that is not
/// prose — a `.log` or a `.swift` file is wrong on purpose, in a way English
/// is not — and off past `BigFile.threshold`, where `isContinuousSpellCheckingEnabled`
/// would otherwise scan the whole document on every keystroke.
enum SpellCheckPolicy {
    /// Extensions worth running a dictionary over. An untitled note has no
    /// extension yet and is prose until proven otherwise, same as a file
    /// that was saved with none at all.
    private static let proseExtensions: Set<String> = [
        "md", "markdown", "txt", "text", "tex", "latex", "ltx",
        "rst", "adoc", "asciidoc", "org",
    ]

    /// `nil` is an untitled note, which is prose until it is saved as
    /// something else.
    static func isProse(_ url: URL?) -> Bool {
        guard let url else { return true }
        let ext = url.pathExtension
        if ext.isEmpty { return true }
        return proseExtensions.contains(ext.lowercased())
    }

    /// Prose, and short enough that scanning it costs nothing worth noticing.
    static func shouldCheck(url: URL?, length: Int) -> Bool {
        isProse(url) && !BigFile.isBig(length: length)
    }
}
