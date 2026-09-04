import Foundation

// MARK: - Pure helpers

/// Live counts shown in the status bar. Words are whitespace-separated
/// tokens; characters are Swift `Character`s (so an emoji counts once).
enum TextStats {
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    static func characterCount(_ text: String) -> Int {
        text.count
    }

    /// `"12 words · 34 characters"` — shown at the left of the status bar.
    static func counts(_ text: String) -> String {
        let words = wordCount(text)
        let characters = characterCount(text)
        return "\(words) \(words == 1 ? "word" : "words") · "
            + "\(characters) \(characters == 1 ? "character" : "characters")"
    }

    /// One piece of the middle of the footer. The case order is the order the
    /// segments are shown in, and the order they are given up in when the
    /// footer runs short of room — from the right.
    enum Segment: CaseIterable {
        case words, characters, images, lines

        var singular: String {
            switch self {
            case .words: "word"
            case .characters: "character"
            case .images: "image"
            case .lines: "line"
            }
        }

        var plural: String { singular + "s" }
    }

    static let separator = " · "

    static func phrase(_ segment: Segment, _ count: Int) -> String {
        "\(count) \(count == 1 ? segment.singular : segment.plural)"
    }

    /// Every way the counts can be written, longest first: all the enabled
    /// segments, then the same with segments dropped from the right one at a
    /// time, and last of all the bare numbers (`"38 · 152"`). Empty when
    /// nothing is enabled, which is what hides the label.
    ///
    /// `tasks` is a `.md`'s ticked-over-total, which is not a segment anyone
    /// turns on: it is there when the note has task items and gone when it
    /// has none. It rides after the counts in every variant, and is given up
    /// only when even the bare numbers with it will not fit.
    static func countVariants(
        words: Int, characters: Int, images: Int, lines: Int, segments: [Segment],
        tasks: (done: Int, total: Int)? = nil
    ) -> [String] {
        let counts = countVariants(
            words: words, characters: characters, images: images, lines: lines,
            segments: segments
        )
        guard let tasks, tasks.total > 0 else { return counts }
        let phrase = TaskList.phrase(done: tasks.done, total: tasks.total)
        guard !counts.isEmpty else { return [phrase] }
        return counts.map { $0 + separator + phrase } + counts
    }

    private static func countVariants(
        words: Int, characters: Int, images: Int, lines: Int, segments: [Segment]
    ) -> [String] {
        guard !segments.isEmpty else { return [] }

        func value(_ segment: Segment) -> Int {
            switch segment {
            case .words: words
            case .characters: characters
            case .images: images
            case .lines: lines
            }
        }

        var variants = (1...segments.count).reversed().map { length in
            segments.prefix(length)
                .map { phrase($0, value($0)) }
                .joined(separator: separator)
        }
        variants.append(segments.map { "\(value($0))" }.joined(separator: separator))
        return variants
    }

    /// The first variant that fits the width on offer — so the footer sheds
    /// words rather than truncating one mid-phrase. Falls back to the
    /// shortest when even that is too wide.
    static func variantFitting(
        _ variants: [String], within width: CGFloat, measuring: (String) -> CGFloat
    ) -> String {
        guard let shortest = variants.last else { return "" }
        return variants.first { measuring($0) <= width } ?? shortest
    }

    /// Hard lines: one per newline, plus the last line. An empty note is one
    /// line — the same count the gutter numbers to.
    static func lineCount(_ text: String) -> Int {
        let source = text as NSString
        var count = 1
        for index in 0..<source.length where source.character(at: index) == 0x0A {
            count += 1
        }
        return count
    }

    /// 1-based line and column for a caret. The column counts characters —
    /// graphemes — from the start of the line, so an emoji and an inline
    /// image are each worth one.
    static func cursorPosition(in text: NSString, at location: Int) -> (line: Int, column: Int) {
        let caret = max(0, min(location, text.length))
        var line = 1
        var lineStart = 0
        for index in 0..<caret where text.character(at: index) == 0x0A {
            line += 1
            lineStart = index + 1
        }
        let head = text.substring(with: NSRange(location: lineStart, length: caret - lineStart))
        return (line, head.count + 1)
    }

    /// The same answer, taken from a note's line table instead of by counting
    /// newlines from the top of the file: the line is a binary search, and the
    /// column costs the one line the caret is on.
    static func cursorPosition(
        in text: NSString, at location: Int, using index: LineIndex
    ) -> (line: Int, column: Int) {
        let caret = max(0, min(location, text.length))
        let line = index.lineNumber(at: caret)
        let lineStart = min(index.lineStart(ofLine: line), caret)
        let head = text.substring(with: NSRange(location: lineStart, length: caret - lineStart))
        return (line, head.count + 1)
    }

    /// `"Ln 12, Col 5"` — shown at the right of the footer, spelled out the
    /// way a status bar says it rather than as a bare pair of numbers.
    static func position(in text: NSString, at location: Int) -> String {
        write(cursorPosition(in: text, at: location))
    }

    /// The same, through the line table.
    static func position(in text: NSString, at location: Int, using index: LineIndex) -> String {
        write(cursorPosition(in: text, at: location, using: index))
    }

    private static func write(_ position: (line: Int, column: Int)) -> String {
        "Ln \(position.line), Col \(position.column)"
    }

    /// `"12 pages"` — the middle of the footer for a PDF tab, where there
    /// are no words to count and how long it is means how many pages.
    static func pageCounts(_ pages: Int) -> String {
        "\(pages) \(pages == 1 ? "page" : "pages")"
    }

    /// `"1200 × 800"` — the middle of the footer for a picture tab. How big
    /// it is, is the whole of what there is to say about it, and a picture is
    /// measured in pixels the way a document is measured in pages. The
    /// multiplication sign is the real one, not a letter x.
    static func pixelSize(of size: NSSize) -> String {
        "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
    }

    /// `"Page 3 of 12"` — the right of the footer for a PDF tab, in place of
    /// the caret's line and column. Both numbers are 1-based, the way the
    /// page they name is printed.
    static func pagePosition(current: Int, total: Int) -> String {
        "Page \(current) of \(total)"
    }

    /// `"13 pt"` — shown next to the gear at the right of the status bar.
    static func pointSize(_ size: Int) -> String {
        "\(size) pt"
    }
}

/// Naming for tabs that have never been saved: `Untitled`, `Untitled 2`, …
enum UntitledNaming {
    static let base = "Untitled"

    /// Lowest unused name given the titles already on screen.
    static func nextName(existing: [String]) -> String {
        let taken = Set(existing)
        if !taken.contains(base) { return base }
        var number = 2
        while taken.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }
}

/// A file name proposed in the save panel: the first non-empty line of the
/// text, trimmed and clipped, with path separators removed.
enum SuggestedName {
    /// What a new note is saved as unless the user types something else.
    static let defaultExtension = "md"

    /// The name the save panel opens with. A note that already has a file
    /// keeps its own name, extension and all — saving `app.js` must never
    /// propose `app.md`. A new one is proposed as Markdown.
    static func panelName(for fileURL: URL?, text: String) -> String {
        if let fileURL { return fileURL.lastPathComponent }
        return from(text: text) + "." + defaultExtension
    }

    static func from(text: String, limit: Int = 40) -> String {
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? ""
        let cleaned = firstLine
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { return UntitledNaming.base }
        return String(cleaned.prefix(limit)).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Session model

/// One tab as it is written to `session.json`. The text itself lives beside
/// it in `cache/<id>.txt`.
struct SessionTab: Codable, Equatable {
    var id: UUID
    /// Path of the note's real file, if it has ever been saved.
    var path: String?
    /// Name shown for a never-saved tab, so numbering survives a restart.
    var untitledName: String?
    var isDirty: Bool
    /// Cursor location, restored on launch — and, for a PDF tab, the page
    /// that was being read, counted from zero. Both are one number about
    /// where the tab was left, so both come back through the same key.
    var selection: Int
    /// The file's encoding, byte-order mark and line endings, so a CRLF
    /// Latin-1 file is still one after a relaunch. `nil` for a note with no
    /// file, and for a session written before Nota remembered any of this.
    var format: TextFileFormat?
    /// Which of the three Markdown modes the tab was in. `nil` in a session
    /// written before the mode was a per-tab thing — those tabs come back in
    /// the editor.
    var previewMode: PreviewMode?

    /// Named, so the old yes/no key is decoded without being written back.
    enum CodingKeys: String, CodingKey {
        case id, path, untitledName, isDirty, selection, format, previewMode
    }

    private enum LegacyKeys: String, CodingKey {
        case showsPreview
    }
}

extension SessionTab {
    /// Before reading mode existed the pane was a `showsPreview` yes/no — and
    /// yes meant the pane beside the editor. Reading those files back as
    /// `.split` is what keeps an upgrade from quietly closing panes.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        untitledName = try container.decodeIfPresent(String.self, forKey: .untitledName)
        isDirty = try container.decode(Bool.self, forKey: .isDirty)
        selection = try container.decode(Int.self, forKey: .selection)
        format = try container.decodeIfPresent(TextFileFormat.self, forKey: .format)
        if let mode = try container.decodeIfPresent(PreviewMode.self, forKey: .previewMode) {
            previewMode = mode
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            previewMode = try legacy
                .decodeIfPresent(Bool.self, forKey: .showsPreview)
                .map { $0 ? .split : .off }
        }
    }
}

/// A window's frame, as four plain numbers so the session file stays
/// readable JSON. `nil` for a window that has never been placed — and for
/// every window in a file written before Nota had more than one.
struct SessionFrame: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.init(x: Double(rect.origin.x), y: Double(rect.origin.y),
                  width: Double(rect.width), height: Double(rect.height))
    }

    var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

/// One window of the session: the tabs in its strip, which of them was in
/// front, and where the window sat.
struct SessionWindow: Codable, Equatable {
    var tabs: [SessionTab]
    var selectedTabID: UUID?
    var frame: SessionFrame?

    init(tabs: [SessionTab], selectedTabID: UUID? = nil, frame: SessionFrame? = nil) {
        self.tabs = tabs
        self.selectedTabID = selectedTabID
        self.frame = frame
    }
}

struct SessionState: Codable, Equatable {
    /// One entry per open window, in the order they were opened.
    var windows: [SessionWindow]
    var fontSize: Double

    /// The first window's tabs and selection. The file used to be this flat
    /// pair and nothing else; both are still written beside `windows` for a
    /// release, so a build from before multi-window opens the session it
    /// finds rather than starting empty.
    var tabs: [SessionTab] { windows.first?.tabs ?? [] }
    var selectedTabID: UUID? { windows.first?.selectedTabID }

    init(windows: [SessionWindow], fontSize: Double) {
        self.windows = windows
        self.fontSize = fontSize
    }

    /// One window's worth — what a lone window, and every test that does not
    /// care about more than one, writes.
    init(tabs: [SessionTab], selectedTabID: UUID?, fontSize: Double) {
        self.init(
            windows: [SessionWindow(tabs: tabs, selectedTabID: selectedTabID)],
            fontSize: fontSize
        )
    }

    static let empty = SessionState(tabs: [], selectedTabID: nil, fontSize: 13)

    private enum CodingKeys: String, CodingKey {
        case windows, tabs, selectedTabID, fontSize
    }

    /// A file with no `windows` key was written before Nota had more than
    /// one window: its flat tab list is that single window.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try container.decode(Double.self, forKey: .fontSize)
        if let windows = try container.decodeIfPresent([SessionWindow].self, forKey: .windows) {
            self.windows = windows
        } else {
            self.windows = [SessionWindow(
                tabs: try container.decodeIfPresent([SessionTab].self, forKey: .tabs) ?? [],
                selectedTabID: try container.decodeIfPresent(UUID.self, forKey: .selectedTabID)
            )]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(windows, forKey: .windows)
        try container.encode(fontSize, forKey: .fontSize)
        try container.encode(tabs, forKey: .tabs)
        try container.encodeIfPresent(selectedTabID, forKey: .selectedTabID)
    }
}

// MARK: - Session store

/// Reads and writes the cache dir (`~/Library/Application Support/Nota` by
/// default). Every write is atomic — Foundation's `.atomic` option writes a
/// temporary file next to the target and renames it into place — so a crash
/// mid-write can never truncate a note.
final class SessionStore {
    let directory: URL
    let cacheDirectory: URL
    /// Sidecar images referenced by `![](nota://…)` tokens.
    let assets: AssetStore

    private let sessionURL: URL
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// `NOTA_SUPPORT_DIR` points the cache somewhere else — used to exercise a
    /// real launch without touching the notes you are actually working on.
    /// `applicationSupport` is only ever passed by tests, so the migration can
    /// be exercised against a scratch root.
    init(directory: URL? = nil, applicationSupport: URL? = nil) {
        let override = ProcessInfo.processInfo.environment["NOTA_SUPPORT_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let resolved: URL
        if let directory {
            resolved = directory
        } else if let override {
            resolved = override
        } else {
            resolved = SessionStore.supportDirectory(in: applicationSupport ?? FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
        }
        self.directory = resolved
        self.cacheDirectory = resolved.appendingPathComponent("cache", isDirectory: true)
        self.assets = AssetStore(
            directory: resolved.appendingPathComponent("assets", isDirectory: true)
        )
        self.sessionURL = resolved.appendingPathComponent("session.json")
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// The support directory, carrying the pre-rename one forward.
    ///
    /// The app used to keep everything in `Application Support/Jot`. The first
    /// time a renamed build launches, that whole directory — notes, cache and
    /// assets — is moved across to `Nota` in one rename, so nothing is copied
    /// and nothing is left behind. If the move fails, the old directory is
    /// used where it stands: the notes still open, and the move is tried
    /// again next launch.
    static func supportDirectory(in applicationSupport: URL) -> URL {
        let manager = FileManager.default
        let current = applicationSupport.appendingPathComponent("Nota", isDirectory: true)
        let legacy = applicationSupport.appendingPathComponent("Jot", isDirectory: true)
        guard !manager.fileExists(atPath: current.path),
              manager.fileExists(atPath: legacy.path)
        else { return current }
        do {
            try manager.moveItem(at: legacy, to: current)
            return current
        } catch {
            return legacy
        }
    }

    // MARK: Session file

    func load() -> SessionState? {
        guard let data = try? Data(contentsOf: sessionURL) else { return nil }
        return try? JSONDecoder().decode(SessionState.self, from: data)
    }

    func save(_ state: SessionState) {
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: sessionURL, options: .atomic)
    }

    // MARK: Cached text

    func cacheURL(for id: UUID) -> URL {
        cacheDirectory.appendingPathComponent("\(id.uuidString).txt")
    }

    func readText(for id: UUID) -> String? {
        try? String(contentsOf: cacheURL(for: id), encoding: .utf8)
    }

    func writeText(_ text: String, for id: UUID) {
        try? Data(text.utf8).write(to: cacheURL(for: id), options: .atomic)
    }

    func deleteText(for id: UUID) {
        try? FileManager.default.removeItem(at: cacheURL(for: id))
    }

    /// Drops cache files for tabs that are no longer in the session.
    func pruneCache(keeping ids: [UUID]) {
        let keep = Set(ids.map { "\($0.uuidString).txt" })
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: nil
        )) ?? []
        for url in contents where !keep.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
