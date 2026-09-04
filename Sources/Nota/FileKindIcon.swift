import AppKit

/// The leading icon a tab — in the strip and in the ⌘P switcher — shows for
/// the kind of file behind it (SPEC Todo 15).
///
/// The name is all there is to go on: a tab's title is its file's last path
/// component, and the switcher is handed titles, not URLs. So the extension
/// decides, and a note with no file at all is asked for by its `nil` URL
/// rather than by a name it does not have.
///
/// Every symbol here is asked of the system before it is handed back. A few
/// of them (`text.document`, `text.page`) only arrived in the macOS 15 SF
/// Symbols set, and one that is not there draws nothing at all rather than
/// falling back on its own — so each kind names its preferred symbol and the
/// older spelling behind it, and the first one the running system actually
/// has is the one used.
enum FileKindIcon {

    /// A note that has never been saved: no name, so no kind.
    static var untitledSymbolName: String { resolved(["doc"]) }

    /// The icon for a note's file. `nil` — an untitled note — is a plain
    /// `doc`, which is the one case a name could never tell us about.
    static func symbolName(for url: URL?) -> String {
        guard let url else { return untitledSymbolName }
        return symbolName(forTitle: url.lastPathComponent)
    }

    /// The icon for a file name, which is what a tab title is.
    static func symbolName(forTitle title: String) -> String {
        resolved(candidates(forExtension: (title as NSString).pathExtension.lowercased()))
    }

    /// The preferred symbol first, older spellings after it.
    private static func candidates(forExtension ext: String) -> [String] {
        switch ext {
        case "md", "markdown", "mdown", "mkd":
            return ["text.document", "doc.text"]
        case "txt", "text", "":
            return ["doc.plaintext"]
        case "pdf":
            return ["doc.richtext", "doc.fill"]
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp":
            return ["photo"]
        case "html", "htm", "xhtml":
            return ["globe"]
        case "tex", "latex", "ltx", "sty", "bib":
            return ["function", "x.squareroot"]
        case "sql":
            return ["cylinder"]
        case "json", "yaml", "yml", "toml", "xml", "plist":
            return ["curlybraces"]
        case "csv", "tsv":
            return ["tablecells"]
        case "log":
            return ["list.bullet.rectangle"]
        case "swift", "js", "jsx", "ts", "tsx", "py", "rb", "go", "rs",
             "c", "h", "cpp", "cc", "hpp", "m", "mm", "java", "kt",
             "sh", "zsh", "bash", "pl", "php", "lua", "css", "scss":
            return ["chevron.left.forwardslash.chevron.right"]
        default:
            return ["text.page", "doc"]
        }
    }

    /// The first of `names` the running system can actually draw, `doc` if it
    /// can draw none of them. Asking AppKit for an image on every row would
    /// be wasteful, so each answer is kept.
    private static var resolvedNames: [String: String] = [:]

    private static func resolved(_ names: [String]) -> String {
        let key = names.joined(separator: "|")
        if let cached = resolvedNames[key] { return cached }
        let answer = names.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
            ?? "doc"
        resolvedNames[key] = answer
        return answer
    }
}
