import AppKit

/// What a tab does with the Markdown render: nothing, beside the editor, or
/// instead of it. The case order is the order ⇧⌘P cycles them in, and the
/// order the mode control's segments sit in.
enum PreviewMode: String, Codable, CaseIterable {
    case off, split, reading

    /// The next one round the ring — what ⇧⌘P moves to.
    var next: PreviewMode {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }

    /// The segment's picture in the mode control.
    var symbolName: String {
        switch self {
        case .off: "pencil"
        case .split: "rectangle.split.2x1"
        case .reading: "book"
        }
    }

    /// What the segment is called — the tool tip's first half, and the label
    /// VoiceOver reads.
    var controlTitle: String {
        switch self {
        case .off: "Editor"
        case .split: "Split"
        case .reading: "Reading"
        }
    }

    /// The tool tip: the state, then the keys that get to it.
    var controlToolTip: String {
        switch self {
        case .off: controlTitle + "  ⇧⌘P"
        case .split: controlTitle + "  ⇧⌘P"
        case .reading: controlTitle + "  ⌥⇧⌘P"
        }
    }
}

/// One tab. Each note owns its own text storage and undo manager, so undo
/// never bleeds between tabs — switching tabs swaps both into the single
/// shared text view.
final class Note {
    let id: UUID
    /// The user's real file. `nil` until the note has been saved once.
    var fileURL: URL? {
        didSet { if fileURL != nil { untitledName = nil } }
    }
    /// Display name while the note has no file (`Untitled`, `Untitled 2`, …).
    var untitledName: String?
    /// True when the cache holds edits that are not in the file yet.
    var isDirty: Bool = false
    /// A `:help`, `:reg` or `:marks` tab: read-only, and never written to the
    /// cache or brought back on relaunch. It is a view of something, not a
    /// note, so nothing about it is worth keeping.
    var isScratch: Bool = false
    var selectionLocation: Int = 0
    /// What this tab does with the Markdown render — editor, split or
    /// reading. Per tab, not per app: ⇧⌘P on a Markdown note must not follow
    /// you into the next ⌘T. The editor until asked for.
    var previewMode: PreviewMode = .off
    /// The shape the file was in when it was opened — encoding, byte-order
    /// mark, line endings — and the shape ⌘S puts back. A note that has never
    /// been a file starts out as UTF-8 with LF lines.
    var format: TextFileFormat = .default

    let storage: NSTextStorage
    let undoManager = UndoManager()

    init(id: UUID = UUID(), fileURL: URL?, untitledName: String?, text: String,
         attributes: [NSAttributedString.Key: Any], assets: AssetStore?,
         format: TextFileFormat = .default) {
        self.id = id
        self.fileURL = fileURL
        self.untitledName = untitledName
        self.format = format
        self.storage = NSTextStorage(
            attributedString: NoteText.render(text, attributes: attributes, assets: assets)
        )
    }

    /// The tab's name: the file's own, extension and all. `app.js` and
    /// `app.css` are different files and the strip has to say so.
    var title: String {
        if let fileURL { return fileURL.lastPathComponent }
        return untitledName ?? UntitledNaming.base
    }

    /// Only saved `.md` files have a rendered companion. Nota still edits any
    /// text file, but other formats always keep the full workspace for source.
    var supportsMarkdownPreview: Bool {
        fileURL.map(Note.supportsMarkdownPreview) ?? false
    }

    /// The same rule, for a file that has no note behind it yet — what the
    /// "open Markdown files in reading mode" setting asks about.
    static func supportsMarkdownPreview(_ url: URL) -> Bool {
        url.pathExtension.caseInsensitiveCompare("md") == .orderedSame
    }

    /// The note as it is written to the cache and to the user's file: plain
    /// text, with each image collapsed back to its `![](nota://…)` token.
    var text: String { NoteText.serialize(storage) }

    /// The same text with tokens removed — what the counts are taken from.
    var countableText: String { NoteText.strippingTokens(text) }

    func sessionTab() -> SessionTab {
        SessionTab(
            id: id,
            path: fileURL?.path,
            untitledName: untitledName,
            isDirty: isDirty,
            selection: selectionLocation,
            // Only a real file has a shape worth keeping; an untitled note
            // comes back as the default whatever happened in between.
            format: fileURL == nil ? nil : format,
            previewMode: previewMode
        )
    }
}
