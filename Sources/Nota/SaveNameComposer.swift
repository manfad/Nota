import Foundation
import UniformTypeIdentifiers

/// Pure logic behind the Save dialog's name field and its Format popup,
/// kept apart from `SaveDialog` itself so it can be unit tested without
/// putting a window on screen.
enum SaveNameComposer {
    /// What the popup offers, in the order it offers them: Nota's own
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

    /// What the Format popup lists once the dialog knows which extension it
    /// opens on: the known extensions, with `chosen` put in front unless one
    /// of them already spells it. A file saved as `.mdx` — or a `.mdx`
    /// remembered in `Preferences.lastSaveExtension` — must be selectable in
    /// a popup that cannot be typed into, so the list carries it.
    static func formatOptions(including chosen: String) -> [String] {
        let known = knownExtensions()
        let trimmed = chosen
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !trimmed.isEmpty,
              !known.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return known }
        return [trimmed] + known
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

    /// The file name Save produces from what the name field and the Format
    /// popup hold. The name field wins whenever it already spells out an
    /// extension of its own — typing `notes.md` with `txt` still picked in
    /// the popup must never produce `notes.md.txt` — otherwise the popup's
    /// extension (a leading dot and stray whitespace trimmed off) is
    /// appended, and an empty one leaves the name bare.
    static func composedName(name: String, extension popUpText: String) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if split(name: trimmedName).extension != nil { return trimmedName }
        let trimmedExtension = popUpText
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !trimmedExtension.isEmpty else { return trimmedName }
        return "\(trimmedName).\(trimmedExtension)"
    }

    /// The same composition where the extension is *pinned* rather than
    /// picked — the Export sheet, whose target is the format and whose
    /// `.pdf` is a label rather than a popup. The name field's own extension
    /// wins only when it is already the pinned one, so `notes.pdf` stays
    /// `notes.pdf` while `report.v2` becomes `report.v2.pdf` rather than a
    /// PDF called `.v2`.
    static func composedName(name: String, pinnedExtension ext: String) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedExtension = ext
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !trimmedExtension.isEmpty else { return trimmedName }
        if let own = split(name: trimmedName).extension,
           own.caseInsensitiveCompare(trimmedExtension) == .orderedSame {
            return trimmedName
        }
        return "\(trimmedName).\(trimmedExtension)"
    }

    /// `composedName`, turned into the URL Save is about to write — what the
    /// dialog checks for an existing file at, since its name field never
    /// carries the extension the write actually lands on.
    static func composedURL(directory: URL, name: String, extension popUpText: String) -> URL {
        directory.appendingPathComponent(composedName(name: name, extension: popUpText))
    }
}
