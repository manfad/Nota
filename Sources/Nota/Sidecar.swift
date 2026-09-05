import AppKit

/// The folder of pictures a saved note keeps beside itself.
///
/// A note in the editor is chips over an asset store under Application
/// Support; a note on disk should be something anyone can read. So saving
/// under a name writes every chip's picture into `<basename>.assets/` next to
/// the file — `notes.md` gets `notes.assets/` — each picture keeping the
/// asset id it already has as its name, and the token in the file becomes an
/// ordinary relative Markdown link: `![](notes.assets/3f9a….png)`. The note
/// is then portable: copy the two together and every other editor draws the
/// pictures too.
///
/// Opening reads the same links back. A relative link to a picture that is
/// really there — the sidecar's own, or any other folder beside the file —
/// becomes a chip, and the note remembers the path it was spelled with, so
/// the next save writes that same link rather than moving the picture into a
/// sidecar of Nota's choosing.
///
/// The store under Application Support is untouched by any of this. It stays
/// the source the editor and the render draw from; a sidecar is a copy made
/// at save time. Nothing in one is ever deleted, which is the promise the
/// store already makes.
enum Sidecar {
    /// What is appended to the file's base name. `.assets` and not `.files`
    /// or `_media`: it reads as what it holds, and it sorts next to the note.
    static let folderSuffix = ".assets"

    // MARK: - Where the pictures go

    /// `…/notes.md` → `…/notes.assets`. A file with no extension at all keeps
    /// its whole name, so `README` gets `README.assets`.
    static func folderURL(for fileURL: URL) -> URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent(folderName(for: fileURL), isDirectory: true)
    }

    static func folderName(for fileURL: URL) -> String {
        fileURL.deletingPathExtension().lastPathComponent + folderSuffix
    }

    /// Whether a remembered relative path may be written again for a file
    /// being saved as `ownFolderName`'s note.
    ///
    /// A path the author chose — `pics/a.png` — is theirs and is left alone.
    /// A path inside somebody else's sidecar is not: Save As to `copy.md`
    /// must write `copy.assets/`, not go on pointing at `notes.assets/`,
    /// or the copy would be tied to the note it was copied from.
    static func isPortable(_ path: String, ownFolderName: String) -> Bool {
        guard let first = path.split(separator: "/").first else { return false }
        return !first.hasSuffix(folderSuffix) || first == ownFolderName
    }

    // MARK: - Spelling a path as a link

    /// A relative path as it goes into a Markdown link: each segment
    /// percent-encoded, so a folder with a space in its name still gives a
    /// link every reader can follow. `(` and `)` are encoded too — they are
    /// allowed in a URL path and would end the link early.
    static func link(forRelativePath path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { segment in
                String(segment).addingPercentEncoding(
                    withAllowedCharacters: segmentAllowed
                ) ?? String(segment)
            }
            .joined(separator: "/")
    }

    private static let segmentAllowed = CharacterSet.urlPathAllowed
        .subtracting(CharacterSet(charactersIn: "()/"))

    /// The paths a link target might mean, best first — decoded, then the
    /// raw characters. Both are tried against the disk, so a file that spells
    /// a space `%20` and one that leaves it as a space are read alike.
    ///
    /// Empty when the target is not a plain relative path: an absolute path,
    /// anything with a scheme (`http`, `nota`, `mailto`), a `#` fragment, a
    /// `//host` authority, or a path that climbs out of the file's own
    /// folder. None of those is a picture beside the note, and a link to
    /// one is left as the text it is.
    static func candidatePaths(fromLinkTarget target: String) -> [String] {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~"), !trimmed.hasPrefix("#"),
              !trimmed.hasPrefix("//"),
              schemeRegex?.firstMatch(
                  in: trimmed,
                  range: NSRange(location: 0, length: (trimmed as NSString).length)
              ) == nil
        else { return [] }

        var candidates: [String] = []
        if let decoded = trimmed.removingPercentEncoding, !decoded.isEmpty {
            candidates.append(decoded)
        }
        if !candidates.contains(trimmed) { candidates.append(trimmed) }
        return candidates.filter { path in
            !path.split(separator: "/").contains("..")
        }
    }

    private static let schemeRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "^[A-Za-z][A-Za-z0-9+.-]*:")
    }()

    // MARK: - Writing one picture

    /// Puts one picture in the folder, making the folder on demand. Bytes
    /// already there and identical are left exactly as they are — a note
    /// saved twice rewrites nothing, so the file dates stay honest.
    @discardableResult
    static func write(_ data: Data, named name: String, into folder: URL) -> Bool {
        let destination = folder.appendingPathComponent(name)
        if let existing = try? Data(contentsOf: destination), existing == data { return true }
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Saving

    /// The save side, handed to `NoteText.serialize(_:sidecar:)`: it answers
    /// with the link for each chip and writes the picture behind it beside
    /// the file as it goes.
    ///
    /// A chip whose asset has gone gets no link at all; `serialize` then
    /// leaves its `nota://` token exactly as it was, so nothing is lost from
    /// the file because a picture went missing from the store.
    final class Writer {
        let fileURL: URL
        /// Where each chip ended up, relative to the file — what the note
        /// remembers for its next save.
        private(set) var paths: [String: String] = [:]

        private let assets: AssetStore
        private let remembered: [String: String]
        private let reusesRemembered: Bool
        private let folderName: String

        /// `remembered` is the note's own map of asset id → the relative path
        /// the file spelled it with, and `rememberedBase` the folder those
        /// paths are relative to. Saving somewhere else makes every one of
        /// them meaningless, so they are used only when the destination is in
        /// the same folder they were read in.
        init(fileURL: URL, assets: AssetStore,
             remembered: [String: String], rememberedBase: URL?) {
            self.fileURL = fileURL
            self.assets = assets
            self.remembered = remembered
            self.folderName = Sidecar.folderName(for: fileURL)
            let directory = fileURL.deletingLastPathComponent().standardizedFileURL
            self.reusesRemembered =
                rememberedBase?.standardizedFileURL.path == directory.path
        }

        func link(forAssetID assetID: String) -> String? {
            if let path = paths[assetID] { return Sidecar.link(forRelativePath: path) }
            if reusesRemembered, let path = remembered[assetID],
               Sidecar.isPortable(path, ownFolderName: folderName) {
                paths[assetID] = path
                return Sidecar.link(forRelativePath: path)
            }
            guard let data = assets.data(for: assetID),
                  Sidecar.write(data, named: assetID, into: Sidecar.folderURL(for: fileURL))
            else { return nil }
            let path = folderName + "/" + assetID
            paths[assetID] = path
            return Sidecar.link(forRelativePath: path)
        }
    }

    // MARK: - Opening

    /// The open side, handed to `NoteText.render(_:…:importing:)`: the
    /// closure it asks about every ordinary image link in the file.
    ///
    /// A link that resolves to a picture under the file's own folder is taken
    /// into the store and becomes a chip; anything else is left as the text
    /// it is. The same target asked about twice is answered from what was
    /// found the first time, so a picture used three times in a note is
    /// imported once.
    static func importer(
        forFileAt fileURL: URL, assets: AssetStore
    ) -> NoteText.RelativeImporter {
        let directory = fileURL.deletingLastPathComponent().standardizedFileURL
        var seen: [String: (id: String, path: String)] = [:]
        return { target in
            if let hit = seen[target] { return hit }
            for path in candidatePaths(fromLinkTarget: target) {
                let candidate = directory.appendingPathComponent(path).standardizedFileURL
                guard isInside(candidate, directory),
                      FileManager.default.fileExists(atPath: candidate.path),
                      AssetStore.isImageFile(candidate),
                      let assetID = assets.importFileDeduplicating(at: candidate)
                else { continue }
                let hit = (id: assetID, path: path)
                seen[target] = hit
                return hit
            }
            return nil
        }
    }

    /// Never above the file's own folder, whatever the link says. `..` is
    /// already refused by `candidatePaths`; a symlink standardising its way
    /// out is caught here.
    private static func isInside(_ url: URL, _ directory: URL) -> Bool {
        let root = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        return url.path.hasPrefix(root)
    }
}
