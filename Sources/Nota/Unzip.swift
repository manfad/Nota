import Foundation

/// A zip unpacked into a scratch folder of its own, for the two Office viewers
/// (`DOCXDocument`, `XLSXWorkbook`). `/usr/bin/ditto` does the unpacking, for
/// the reason `EPUBBook` gives: it is already on every Mac, and a zip library
/// would be a dependency for the one thing the system already does.
///
/// The folder belongs to whoever asked for it and goes when they do — each
/// caller removes it in its own `deinit`.
enum Unzip {

    /// A fresh folder in the temporary directory, `prefix` and a UUID, with
    /// `archive` unpacked into it. `nil` when the archive will not come apart,
    /// and then nothing is left behind.
    static func toTemporaryFolder(_ archive: URL, prefix: String) -> URL? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true
        )) != nil else { return nil }
        guard extract(archive, into: folder) else {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        return folder
    }

    private static func extract(_ archive: URL, into folder: URL) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-x", "-k", archive.path, folder.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return false
        }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
}

/// The little XML walking both Office readers do over `XMLDocument`: children
/// by local name, whatever prefix the writer gave the namespace — Word writes
/// `w:`, but nothing in the format says it must.
extension XMLNode {
    var local: String { localName ?? name ?? "" }
}

extension XMLElement {
    /// Element children, in order.
    var elementChildren: [XMLElement] {
        (children ?? []).compactMap { $0 as? XMLElement }
    }

    /// The first element child with this local name.
    func child(_ name: String) -> XMLElement? {
        elementChildren.first { $0.local == name }
    }

    /// Every element child with this local name.
    func children(named name: String) -> [XMLElement] {
        elementChildren.filter { $0.local == name }
    }

    /// Every descendant with this local name, depth first.
    func descendants(named name: String) -> [XMLElement] {
        var found: [XMLElement] = []
        for child in elementChildren {
            if child.local == name { found.append(child) }
            found += child.descendants(named: name)
        }
        return found
    }

    /// An attribute by local name — `w:val` and `val` alike.
    func attr(_ name: String) -> String? {
        (attributes ?? []).first { $0.local == name }?.stringValue
    }

    /// The `w:val` of a child, the shape almost every Word property takes.
    func val(of name: String) -> String? {
        child(name)?.attr("val")
    }

    /// A toggle property (`<w:b/>`, `<w:b w:val="0"/>`): present and not
    /// switched off. `nil` when the property is not there at all.
    func toggle(_ name: String) -> Bool? {
        guard let element = child(name) else { return nil }
        guard let value = element.attr("val") else { return true }
        return !["0", "false", "off", "none"].contains(value.lowercased())
    }
}

/// An `.rels` part: relationship id → target, resolved against the folder the
/// part's owner sits in. External targets (a hyperlink's web address) are kept
/// as they are written.
struct OfficeRelationships {
    struct Target {
        let path: String
        let isExternal: Bool
    }

    private(set) var targets: [String: Target] = [:]

    init(relsAt url: URL, ownerFolder: String) {
        guard let document = try? XMLDocument(contentsOf: url, options: []),
              let root = document.rootElement() else { return }
        for relation in root.children(named: "Relationship") {
            guard let id = relation.attr("Id"), let target = relation.attr("Target") else {
                continue
            }
            if relation.attr("TargetMode") == "External" {
                targets[id] = Target(path: target, isExternal: true)
            } else if target.hasPrefix("/") {
                targets[id] = Target(path: String(target.dropFirst()), isExternal: false)
            } else {
                targets[id] = Target(
                    path: OfficeRelationships.normalized(ownerFolder + target), isExternal: false
                )
            }
        }
    }

    subscript(id: String) -> Target? { targets[id] }

    /// `word/../media/x.png` folded to `media/x.png`.
    static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == ".." { _ = parts.popLast() } else if part != "." { parts.append(part) }
        }
        return parts.joined(separator: "/")
    }
}
