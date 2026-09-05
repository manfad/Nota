import Foundation
import UniformTypeIdentifiers

/// Pure logic behind the save panel's name field and its extension combo,
/// kept apart from `NSSavePanel` itself so it can be unit tested without
/// putting a real panel on screen.
enum SaveNameComposer {
    /// What the combo offers, in the order it offers them: Nota's own
    /// favourites first, then whatever `TextFile.contentTypes` knows that
    /// isn't in that list already — deduped, case-insensitively.
    static let curatedExtensionOrder: [String] = [
        "md", "txt", "markdown", "json", "yaml", "toml", "csv", "html", "css",
        "js", "ts", "py", "swift", "sh", "xml", "log", "ini", "tex",
    ]

    static func knownExtensions() -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for ext in curatedExtensionOrder where seen.insert(ext.lowercased()).inserted {
            result.append(ext)
        }
        for type in TextFile.contentTypes {
            guard let ext = type.preferredFilenameExtension,
                  seen.insert(ext.lowercased()).inserted
            else { continue }
            result.append(ext)
        }
        return result
    }

    /// Splits a name the way `NSSavePanel`'s own field would: `"notes.md"` →
    /// `("notes", "md")`, `"Untitled"` → `("Untitled", nil)`. A dotfile like
    /// `.gitignore` has no extension of its own, matching `NSString`'s own
    /// notion of `pathExtension`.
    static func split(name: String) -> (base: String, extension: String?) {
        let ns = name as NSString
        let ext = ns.pathExtension
        guard !ext.isEmpty else { return (name, nil) }
        return (ns.deletingPathExtension, ext)
    }

    /// The file name Save produces from what the name field and the
    /// extension combo hold. The name field wins whenever it already spells
    /// out an extension of its own — typing `notes.md` with `txt` still
    /// picked in the combo must never produce `notes.md.txt` — otherwise the
    /// combo's extension (a leading dot and stray whitespace trimmed off) is
    /// appended, and an empty combo leaves the name bare.
    static func composedName(name: String, extension comboText: String) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if split(name: trimmedName).extension != nil { return trimmedName }
        let trimmedExtension = comboText
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !trimmedExtension.isEmpty else { return trimmedName }
        return "\(trimmedName).\(trimmedExtension)"
    }

    /// `composedName`, turned into the URL a save panel is about to write —
    /// what the panel's own delegate checks for an existing file at, since
    /// the panel's own name field never carries the extension the write
    /// actually lands on.
    static func composedURL(directory: URL, name: String, extension comboText: String) -> URL {
        directory.appendingPathComponent(composedName(name: name, extension: comboText))
    }
}
