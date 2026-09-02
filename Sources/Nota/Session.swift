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
    static func countVariants(
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

    /// `"Ln 12, Col 5"` — shown at the right of the footer, spelled out the
    /// way a status bar says it rather than as a bare pair of numbers.
    static func position(in text: NSString, at location: Int) -> String {
        let position = cursorPosition(in: text, at: location)
        return "Ln \(position.line), Col \(position.column)"
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
    /// Cursor location, restored on launch.
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

struct SessionState: Codable, Equatable {
    var tabs: [SessionTab]
    var selectedTabID: UUID?
    var fontSize: Double

    static let empty = SessionState(tabs: [], selectedTabID: nil, fontSize: 13)
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
