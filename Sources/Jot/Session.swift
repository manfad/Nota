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
}

struct SessionState: Codable, Equatable {
    var tabs: [SessionTab]
    var selectedTabID: UUID?
    var fontSize: Double

    static let empty = SessionState(tabs: [], selectedTabID: nil, fontSize: 13)
}

// MARK: - Session store

/// Reads and writes the cache dir (`~/Library/Application Support/Jot` by
/// default). Every write is atomic — Foundation's `.atomic` option writes a
/// temporary file next to the target and renames it into place — so a crash
/// mid-write can never truncate a note.
final class SessionStore {
    let directory: URL
    let cacheDirectory: URL
    /// Sidecar images referenced by `![](jot://…)` tokens.
    let assets: AssetStore

    private let sessionURL: URL
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// `JOT_SUPPORT_DIR` points the cache somewhere else — used to exercise a
    /// real launch without touching the notes you are actually working on.
    init(directory: URL? = nil) {
        let override = ProcessInfo.processInfo.environment["JOT_SUPPORT_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let resolved = directory ?? override ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jot", isDirectory: true)
        self.directory = resolved
        self.cacheDirectory = resolved.appendingPathComponent("cache", isDirectory: true)
        self.assets = AssetStore(
            directory: resolved.appendingPathComponent("assets", isDirectory: true)
        )
        self.sessionURL = resolved.appendingPathComponent("session.json")
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
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
