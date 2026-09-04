import Foundation

/// The files the reader has pinned (SPEC Todo 13).
///
/// A bookmark is a path and nothing else — not a tab, not a note id — so
/// closing the tab does not lose the note and a file bookmarked in one window
/// is bookmarked in all of them. The list is app-wide: `WindowRegistry` owns
/// the one every window reads and writes, and it rides in `session.json`
/// beside the windows.
///
/// Order is the order they were added, which is the order File › Bookmarks and
/// the picker list them in. A path whose file has gone is not dropped — it
/// stays in the list, greyed out, until it is removed by hand, because a
/// volume that is not mounted this morning is not a bookmark anybody meant to
/// throw away.
final class Bookmarks {
    /// Posted whenever the list changes, with the `Bookmarks` as the object:
    /// every window's strip and every menu built from it is out of date the
    /// moment one is added or removed.
    static let didChange = Notification.Name("NotaBookmarksDidChange")

    private(set) var paths: [String] = []

    init(paths: [String] = []) {
        self.paths = paths.map(Self.standardized)
    }

    /// The whole list at once — what a session file being read hands over.
    /// Silent: nothing has changed for anyone yet at the moment the app is
    /// still building itself.
    func replace(with paths: [String]) {
        self.paths = paths.map(Self.standardized)
    }

    // MARK: - Asking

    func contains(_ url: URL) -> Bool {
        paths.contains(Self.standardized(url.path))
    }

    func contains(path: String) -> Bool {
        paths.contains(Self.standardized(path))
    }

    var isEmpty: Bool { paths.isEmpty }

    /// Whether the file behind a bookmark is no longer there. A bookmark that
    /// is missing is still a bookmark — it is drawn greyed and refuses to be
    /// opened, rather than quietly disappearing.
    func isMissing(_ path: String) -> Bool {
        !FileManager.default.fileExists(atPath: Self.standardized(path))
    }

    var missingPaths: [String] {
        paths.filter(isMissing)
    }

    var hasMissing: Bool {
        paths.contains(where: isMissing)
    }

    /// The name a bookmark is listed under: the file's, extension and all,
    /// the same as a tab's title.
    static func name(of path: String) -> String {
        (path as NSString).lastPathComponent
    }

    // MARK: - Changing

    /// Adds the file if it is not bookmarked, removes it if it is, and says
    /// which of the two it did — ⌘D's whole behaviour.
    @discardableResult
    func toggle(_ url: URL) -> Bool {
        if contains(url) {
            remove(url)
            return false
        }
        add(url)
        return true
    }

    func add(_ url: URL) {
        let path = Self.standardized(url.path)
        guard !paths.contains(path) else { return }
        paths.append(path)
        announce()
    }

    func remove(_ url: URL) {
        remove(path: url.path)
    }

    func remove(path: String) {
        let target = Self.standardized(path)
        guard let index = paths.firstIndex(of: target) else { return }
        paths.remove(at: index)
        announce()
    }

    /// File › Bookmarks ▸ Remove Missing Bookmarks: every one whose file has
    /// gone, in one go.
    func removeMissing() {
        let remaining = paths.filter { !isMissing($0) }
        guard remaining.count != paths.count else { return }
        paths = remaining
        announce()
    }

    // MARK: - Plumbing

    /// `/tmp/../tmp/notes.md` and `/tmp/notes.md` are one bookmark, and the
    /// same file opened through either spelling finds it. Standardizing the
    /// string rather than resolving symlinks keeps this answerable for a file
    /// that is not there — which is exactly the case the greyed rows are for.
    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func announce() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
