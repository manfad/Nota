import AppKit
import UniformTypeIdentifiers

/// Settings › File types: making Nota the app the Mac opens a kind of file in.
///
/// The table below is the whole list — one place to add an extension — and the
/// protocol beneath it is the one door to Launch Services. Nothing else in the
/// app talks to `NSWorkspace` about defaults, because a default app is machine
/// state: a test that set one would change the reader's Mac the way the suite
/// that copied two customers' names onto the real clipboard did, so the page
/// takes its registry as a value and the tests hand it a fake one.
///
/// Launch Services has a setter and no unsetter. Everything about unticking a
/// row — remembering what was default before, putting it back, and the row that
/// can only be ticked because Nota was already there — follows from that.

/// One app bundle, as the page needs it: where it is, what to call it, and the
/// one string that finds it again after a relaunch.
struct DefaultAppBundle: Equatable {
    let url: URL
    /// What the Finder calls it, without the `.app`.
    let name: String
    /// The bundle identifier, or the path where a bundle has none. This is
    /// what `Preferences.previousDefaultApps` writes down.
    let identifier: String
}

/// One group of rows on the page.
struct DefaultAppGroup {
    let titleKey: String
    let extensions: [String]
    /// True where "Use Nota for all text types" reaches. The last group is
    /// false on purpose: nobody asked Nota to take over PDFs and photographs.
    let isTextLike: Bool
}

enum DefaultAppTypes {
    static let notaBundleIdentifier = "com.manfad.nota"

    /// Every extension the page offers, grouped as it lists them. Add here and
    /// the row, its icon and the "all text types" button all follow.
    static let groups: [DefaultAppGroup] = [
        DefaultAppGroup(
            titleKey: "Text",
            extensions: ["txt", "md", "markdown", "log", "rtf"],
            isTextLike: true
        ),
        DefaultAppGroup(
            titleKey: "Data",
            extensions: ["json", "yaml", "yml", "toml", "ini", "csv", "tsv", "sql", "xml"],
            isTextLike: true
        ),
        DefaultAppGroup(
            titleKey: "Code",
            extensions: ["html", "htm", "css", "js", "ts", "py", "sh", "swift", "go", "rs",
                         "rb", "java", "c", "h", "cpp", "tex"],
            isTextLike: true
        ),
        DefaultAppGroup(
            titleKey: "Documents and pictures",
            extensions: ["pdf", "epub", "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "svg"],
            isTextLike: false
        ),
    ]

    /// Every extension the page lists, in the order it lists them.
    static var allExtensions: [String] { groups.flatMap(\.extensions) }

    /// The extensions the "all text types" button covers.
    static var textLikeExtensions: [String] {
        groups.filter(\.isTextLike).flatMap(\.extensions)
    }

    /// Every extension the page lists that names the same type as this one.
    /// Launch Services keeps one default per *type*, not per extension, so
    /// `.md` and `.markdown` are one setting wearing two rows — and `.yaml` /
    /// `.yml`, `.html` / `.htm`, `.jpg` / `.jpeg` likewise. Both rows move
    /// together, and both remember the same app to hand back.
    static func extensions(sharingTypeWith ext: String) -> [String] {
        guard let wanted = type(forExtension: ext) else { return [ext] }
        return allExtensions.filter { type(forExtension: $0)?.identifier == wanted.identifier }
    }

    /// The type a row stands for. Dynamic types included: an extension the
    /// system has never heard of still gets a `dyn.…` identifier, and Launch
    /// Services takes a default app for one just as happily.
    static func type(forExtension ext: String) -> UTType? {
        UTType(filenameExtension: ext)
    }
}

/// The Launch Services seam. Two operations — what opens this type now, and
/// make this app open it — plus the two lookups the page needs to name an app
/// and to find a remembered one again.
protocol DefaultAppRegistry: AnyObject {
    /// Nota itself, which is what a ticked row means. `nil` where no copy of
    /// Nota can be found, and then the page has nothing to offer.
    var nota: DefaultAppBundle? { get }

    /// What the Mac opens this type in today, `nil` where nothing claims it.
    func defaultApplication(toOpen type: UTType) -> DefaultAppBundle?

    /// The app a `DefaultAppBundle.identifier` names, `nil` where it is gone.
    func application(forIdentifier identifier: String) -> DefaultAppBundle?

    /// Hands the type to this app. Asynchronous, and the completion lands on
    /// the main queue.
    func setDefaultApplication(
        at applicationURL: URL, toOpen type: UTType, completion: @escaping (Error?) -> Void
    )
}

/// The live one, over `NSWorkspace`.
final class SystemDefaultAppRegistry: DefaultAppRegistry {
    enum Failure: LocalizedError {
        /// The guard below, never anything a reader sees.
        case refusedUnderTests

        var errorDescription: String? {
            "Nota refuses to change the Mac's default apps from a test."
        }
    }

    var nota: DefaultAppBundle? {
        // The installed copy first, whichever copy is running: a tick made
        // from a build in the repo must not hand the Mac's files to that
        // build, which the next `git clean` or rebuild takes away.
        let installed = URL(fileURLWithPath: "/Applications/Nota.app")
        if Bundle(url: installed)?.bundleIdentifier == DefaultAppTypes.notaBundleIdentifier {
            return Self.bundle(at: installed)
        }
        let main = Bundle.main
        if main.bundleIdentifier == DefaultAppTypes.notaBundleIdentifier {
            return Self.bundle(at: main.bundleURL)
        }
        // Under the tests, and under `swift run`, the running binary is not
        // the app; the installed copy is the one Launch Services would hand a
        // file to, so it is the one the page speaks for.
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: DefaultAppTypes.notaBundleIdentifier
        ) else { return nil }
        return Self.bundle(at: url)
    }

    func defaultApplication(toOpen type: UTType) -> DefaultAppBundle? {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: type) else { return nil }
        return Self.bundle(at: url)
    }

    func application(forIdentifier identifier: String) -> DefaultAppBundle? {
        if identifier.hasPrefix("/") {
            let url = URL(fileURLWithPath: identifier)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return Self.bundle(at: url)
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        else { return nil }
        return Self.bundle(at: url)
    }

    func setDefaultApplication(
        at applicationURL: URL, toOpen type: UTType, completion: @escaping (Error?) -> Void
    ) {
        // The clipboard rule, one shelf up: a default app is the reader's own
        // machine, and a suite that rewrote it would be doing real damage on
        // every run. A test reaching this far has forgotten its fake registry.
        guard !Self.isRunningTests else {
            assertionFailure(
                "A test reached the real Launch Services. Set "
                    + "SettingsWindowController.defaultAppRegistry to a fake first."
            )
            completion(Failure.refusedUnderTests)
            return
        }
        NSWorkspace.shared.setDefaultApplication(at: applicationURL, toOpen: type) { error in
            DispatchQueue.main.async { completion(error) }
        }
    }

    private static var isRunningTests: Bool { NSClassFromString("XCTestCase") != nil }

    private static func bundle(at url: URL) -> DefaultAppBundle {
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        let identifier = Bundle(url: url)?.bundleIdentifier ?? url.path
        return DefaultAppBundle(url: url, name: name, identifier: identifier)
    }
}
