import AppKit
import PDFKit
import UniformTypeIdentifiers

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

/// Which preview a file gets beside its source, decided by how it is spelled
/// and by nothing else. Everything around them — the three modes, the mode
/// control, ⇧⌘P, the View items, the mode kept per tab — is the same for all
/// three. What differs is what does the drawing: Nota's own renderer reads
/// Markdown or LaTeX into its reading layout, and HTML is already a page, so
/// WebKit draws it as it stands.
enum RenderedPreviewKind {
    case markdown, latex, html, svg

    init?(fileExtension: String) {
        if fileExtension.caseInsensitiveCompare("md") == .orderedSame {
            self = .markdown
            return
        }
        for spelling in ["tex", "latex", "ltx"]
        where fileExtension.caseInsensitiveCompare(spelling) == .orderedSame {
            self = .latex
            return
        }
        // The page, not its parts: a `.css` or a `.js` beside it is source
        // with nothing to preview.
        for spelling in ["html", "htm"]
        where fileExtension.caseInsensitiveCompare(spelling) == .orderedSame {
            self = .html
            return
        }
        // A drawing is a document too. An `.svg` is text you edit — a tree of
        // tags, no different from HTML — so it is a tab with a preview beside
        // it, not one of the pictures Nota opens as a viewer.
        if fileExtension.caseInsensitiveCompare("svg") == .orderedSame {
            self = .svg
            return
        }
        return nil
    }

    /// What the View menu's item calls itself on a tab of this kind. The item
    /// is named for what is in front: a `.tex` tab is not offered a Markdown
    /// preview, it is offered its own, and a `.html` tab is offered its page.
    /// A tab with no preview at all keeps the plain name, since the item is
    /// disabled there and only ever read greyed out.
    static func previewMenuTitle(_ kind: RenderedPreviewKind?) -> String {
        switch kind {
        case .latex: "LaTeX Preview"
        case .html: "HTML Preview"
        case .svg: "SVG Preview"
        case .markdown, nil: "Markdown Preview"
        }
    }
}

/// What a tab is holding. Everything Nota edits is text; a PDF and a picture
/// are the binaries it opens at all, and they open as viewers — there is no
/// text storage behind either, nothing to save, and nothing to keep in the
/// cache.
enum NoteKind {
    case text, pdf, image

    /// Whether the tab is read rather than edited. Everything that follows
    /// from that — locked in reading, never dirty, never cached, never
    /// written, no format of its own — is asked here rather than of each
    /// kind by name.
    var isViewer: Bool { self != .text }
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
    /// Text, or the one binary Nota opens. A tab's kind is settled when it is
    /// made and never changes under it.
    let kind: NoteKind
    /// True when the cache holds edits that are not in the file yet. A viewer
    /// is a view of a file rather than a copy of one — there is nothing in it
    /// that is not on disk already — so it is never any of this.
    var isDirty: Bool {
        get { kind == .text && hasUnsavedEdits }
        set { hasUnsavedEdits = newValue }
    }
    private var hasUnsavedEdits = false
    /// A `:help`, `:reg` or `:marks` tab: read-only, and never written to the
    /// cache or brought back on relaunch. It is a view of something, not a
    /// note, so nothing about it is worth keeping.
    var isScratch: Bool = false
    /// Where the tab was left: the caret in a text note, the page being read
    /// in a PDF. One number either way, so the session keeps both the same.
    var selectionLocation: Int = 0
    /// How far the tab's content is zoomed — a document, a picture or a page,
    /// 1 being however it draws itself by default. Per tab and for as long as
    /// the tab is open, and no longer: it is not in `session.json`, since how
    /// close you were reading is not where you were reading.
    var previewZoom: CGFloat = 1
    /// What this tab does with its render — editor, split or reading. Per
    /// tab, not per app: ⇧⌘P on a Markdown note must not follow you into the
    /// next ⌘T. The editor until asked for.
    ///
    /// A PDF and a picture are the page and nothing else: they are locked in
    /// reading, and asking either for another mode is asking for nothing at
    /// all.
    var previewMode: PreviewMode {
        get { kind.isViewer ? .reading : requestedPreviewMode }
        set {
            guard kind == .text else { return }
            requestedPreviewMode = newValue
        }
    }
    private var requestedPreviewMode: PreviewMode = .off
    /// The shape the file was in when it was opened — encoding, byte-order
    /// mark, line endings — and the shape ⌘S puts back. A note that has never
    /// been a file starts out as UTF-8 with LF lines.
    var format: TextFileFormat = .default

    let storage: NSTextStorage
    let undoManager = UndoManager()

    /// Where every hard line of this note starts. The gutter, the line count
    /// in the footer and the caret's line all read it rather than walking the
    /// text, which is the whole of what keeps a 100 MB log usable. Built once
    /// here and folded forward one edit at a time, so it costs nothing to
    /// keep.
    private(set) var lineIndex: LineIndex
    /// The subscription that does the folding — the storage tells anyone who
    /// asks what it just changed, which is exactly the three facts the table
    /// needs.
    private var editObserver: NSObjectProtocol?

    /// The PDF once it has been read, and whether reading it has been tried
    /// — a file that could not be opened must not be re-opened on every tab
    /// switch.
    private var loadedPDF: PDFDocument?
    private var hasLoadedPDF = false
    private var loadedImage: NSImage?
    private var hasLoadedImage = false

    init(id: UUID = UUID(), fileURL: URL?, untitledName: String?, text: String,
         attributes: [NSAttributedString.Key: Any], assets: AssetStore?,
         format: TextFileFormat = .default, kind: NoteKind = .text) {
        self.id = id
        self.fileURL = fileURL
        self.untitledName = untitledName
        self.format = format
        self.kind = kind
        self.storage = NSTextStorage(
            attributedString: NoteText.render(text, attributes: attributes, assets: assets)
        )
        // Read through `mutableString`, the storage's own live view of its
        // characters. Bridging `storage.string` would copy the file — two
        // hundred megabytes for a hundred-megabyte log — to scan it once.
        self.lineIndex = LineIndex(storage.mutableString)
        observeEdits()
    }

    deinit {
        if let editObserver { NotificationCenter.default.removeObserver(editObserver) }
    }

    /// Fold every character edit into the line table as the storage makes it.
    /// Attribute-only edits — a colour laid on a chip, the font changing —
    /// move nothing, so they are ignored.
    private func observeEdits() {
        editObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: storage, queue: nil
        ) { [weak self] notification in
            guard let self,
                  let storage = notification.object as? NSTextStorage,
                  storage.editedMask.contains(.editedCharacters)
            else { return }
            // The proxy again, and it matters most here: this runs on every
            // character typed, and only the edited range is read out of it.
            self.lineIndex.apply(
                editedRange: storage.editedRange,
                changeInLength: storage.changeInLength,
                in: storage.mutableString
            )
        }
    }

    /// How many pictures the note holds, counted through the storage's
    /// attribute runs rather than by serialising the text and matching
    /// tokens in it — a log with no pictures at all costs one run.
    var imageCount: Int {
        var count = 0
        storage.forEachAttachmentRun { value, _, _ in
            if value is NotaImageAttachment { count += 1 }
        }
        return count
    }

    /// The tab's name: the file's own, extension and all. `app.js` and
    /// `app.css` are different files and the strip has to say so.
    var title: String {
        if let fileURL { return fileURL.lastPathComponent }
        return untitledName ?? UntitledNaming.base
    }

    /// Which preview this tab has, if it has one at all. Only a saved file
    /// spelled one of the three ways does. Nota still edits any text file, but
    /// every other format keeps the full workspace for source.
    var previewKind: RenderedPreviewKind? {
        fileURL.flatMap(Note.previewKind)
    }

    /// Whether the tab has a preview beside its source.
    var supportsRenderedPreview: Bool { previewKind != nil }

    /// Whether the tab has anything at all to put in the preview column: a
    /// render for a saved `.md` or `.tex`, the page for a `.html` or an
    /// `.svg`, the document for a PDF, the picture for an image. A `.txt` and
    /// an untitled note have none of them, so no mode means anything there.
    var hasPreviewContent: Bool { kind.isViewer || supportsRenderedPreview }

    /// The same rule, for a file that has no note behind it yet — what the
    /// "open Markdown, LaTeX and HTML files in reading mode" setting asks
    /// about.
    ///
    /// This is the one question in Nota that stays by extension on purpose:
    /// what a file *is* — text, PDF, binary — comes from its bytes, but what
    /// it is *rendered as* is the author's own word, spelled in the name
    /// they gave it. A `.md` that happens to hold LaTeX macros still renders
    /// as Markdown; there is no content to sniff that would say otherwise.
    static func previewKind(_ url: URL) -> RenderedPreviewKind? {
        RenderedPreviewKind(fileExtension: url.pathExtension)
    }

    /// The same, as a yes or no.
    static func supportsRenderedPreview(_ url: URL) -> Bool {
        previewKind(url) != nil
    }

    /// What a file opens as when its name is all there is to go on — a file
    /// that is not there yet, or one whose bytes said nothing. `nil` for
    /// anything Nota would edit rather than show.
    static func viewerKind(_ url: URL) -> NoteKind? {
        if isPDFFile(url) { return .pdf }
        if isImageFile(url) { return .image }
        return nil
    }

    /// A PDF, by name. The spelling answers first, since that is all a file
    /// that is not there yet has; the system's own type is asked after it, so
    /// a `.PDF` from a Windows machine and a type-only oddity both land the
    /// same way.
    static func isPDFFile(_ url: URL) -> Bool {
        if url.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame { return true }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .pdf)
    }

    /// A picture Nota opens as a tab, by name.
    ///
    /// An `.svg` is not one of them, whatever the system says. Its bytes are
    /// text, you edit it in the editor like any other markup, and the drawing
    /// beside it is a preview — the same arrangement a `.html` has. The
    /// system files it under images all the same, so it is refused here by
    /// name and by type both.
    static func isImageFile(_ url: URL) -> Bool {
        if url.pathExtension.caseInsensitiveCompare("svg") == .orderedSame { return false }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .svg)
    }

    /// Whether a file is one Nota opens in a tab at all. The bytes decide
    /// first: `FileSniff` says PDF, picture or text and that is the answer,
    /// whatever the file is named — a `report` with no extension and a `.pdf`
    /// that is really a log both go by their content. A handful of types stay refused by name even when their
    /// bytes read as plain text, the same way `TextFile.isTextFile` refuses
    /// them — an RTF's own markup is ASCII, but it is not a note. Only when
    /// the bytes cannot say anything — the file is missing, unreadable, or a
    /// real binary — does the old name-based guess take over.
    static func isOpenable(_ url: URL) -> Bool {
        switch FileSniff.classify(at: url) {
        case .pdf, .image:
            return true
        case .text:
            return !TextFile.isDeliberatelyExcluded(url)
        case .binary, .unreadable:
            return viewerKind(url) != nil || TextFile.isTextFile(at: url)
        }
    }

    /// The parsed document behind a PDF tab, read the first time it is asked
    /// for and held afterwards, so switching back to the tab does not parse
    /// the file again. `nil` when the file is missing or unreadable — which
    /// is what the pane shows a message for.
    var pdfDocument: PDFDocument? {
        guard kind == .pdf else { return nil }
        if hasLoadedPDF { return loadedPDF }
        hasLoadedPDF = true
        loadedPDF = fileURL.flatMap { PDFDocument(url: $0) }
        return loadedPDF
    }

    /// The picture behind an image tab, read the first time it is asked for
    /// and held afterwards, the same way the document is. `nil` when the file
    /// is missing, or is not a picture `NSImage` can draw — which is what the
    /// pane shows a message for.
    var image: NSImage? {
        guard kind == .image else { return nil }
        if hasLoadedImage { return loadedImage }
        hasLoadedImage = true
        loadedImage = fileURL.flatMap { NSImage(contentsOf: $0) }
        return loadedImage
    }

    /// Whether the editor takes the keyboard for this tab. A scratch tab is
    /// vim's `'nomodifiable'`; a viewer has no text storage worth typing
    /// into.
    var isEditable: Bool { !isScratch && kind == .text }

    /// Whether the tab's text belongs in `cache/<id>.txt`. A scratch tab is a
    /// view of something rather than a note, and a viewer's text is not text
    /// at all — writing either would be writing an empty file over and over.
    var writesToCache: Bool { !isScratch && kind == .text }

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
            // Only a real text file has a shape worth keeping; an untitled
            // note comes back as the default whatever happened in between,
            // and a viewer has no encoding or line endings to speak of.
            format: (fileURL == nil || kind.isViewer) ? nil : format,
            previewMode: previewMode
        )
    }
}
