import Foundation

/// A real TeX on the Mac, found and run: the other half of Todo 1's
/// "Export as PDF…" on a `.tex` tab. Nota's own LaTeX render is a reading
/// layout of a document (see the LaTeX preview section of SPEC); this is
/// TeX's own pixels, for the times the reader wants the paper itself.
///
/// Nothing here is remembered. Detection is three or four `access(2)` calls
/// and a TeX comes and goes with a Homebrew command, so a preference would
/// only ever be a stale answer to a cheap question. Both the search paths
/// and the file check are injectable, so the tests decide what exists
/// without a TeX being installed.
enum TeXEngineKind: String, CaseIterable {
    /// Nota's own choice: one self-contained binary, no distribution.
    case tectonic
    /// TeX Live / MacTeX.
    case pdflatex
    case xelatex

    /// The name on disk; the enum is spelled after it on purpose.
    var executableName: String { rawValue }
}

/// One engine, found at one path.
struct TeXEngine: Equatable {
    let kind: TeXEngineKind
    let url: URL

    // MARK: - Where Nota keeps its own copy

    /// `~/Library/Application Support/Nota/bin`, where `TectonicInstaller`
    /// puts the copy it downloads. The support directory itself is the one
    /// `SessionStore` names, so the Jot → Nota rename is honoured here too.
    static func binDirectory(
        applicationSupport: URL? = nil
    ) -> URL {
        let root = applicationSupport ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SessionStore.supportDirectory(in: root)
            .appendingPathComponent("bin", isDirectory: true)
    }

    // MARK: - Detection

    /// The directories searched, in order: Nota's own bin first (a copy Nota
    /// installed is the one Nota trusts), then whatever the process was
    /// launched with, then the three places a Mac TeX actually lives. A
    /// double-clicked `.app` gets the bare launchd `PATH`, so the fixed three
    /// are not a nicety — they are usually the only ones that hit.
    static func searchPaths(
        binDirectory: URL? = nil,
        path: String? = ProcessInfo.processInfo.environment["PATH"],
        fixed: [String] = ["/Library/TeX/texbin", "/opt/homebrew/bin", "/usr/local/bin"]
    ) -> [URL] {
        var directories: [String] = [(binDirectory ?? TeXEngine.binDirectory()).path]
        directories += (path ?? "").split(separator: ":").map(String.init)
        directories += fixed
        var seen = Set<String>()
        return directories.compactMap { directory in
            let trimmed = directory.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let url = URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
            guard seen.insert(url.path).inserted else { return nil }
            return url
        }
    }

    /// The engine to compile with, or `nil` when the Mac has none.
    ///
    /// The kind is the outer loop and the directory the inner one: a
    /// `tectonic` anywhere beats a `pdflatex` anywhere, because Tectonic is
    /// the one Nota can install, the one whose version it reads, and the one
    /// that fetches the packages a document asks for instead of failing on
    /// them.
    static func installed(
        searchPaths: [URL] = TeXEngine.searchPaths(),
        isExecutable: (URL) -> Bool = { url in
            FileManager.default.isExecutableFile(atPath: url.path)
        }
    ) -> TeXEngine? {
        for kind in TeXEngineKind.allCases {
            for directory in searchPaths {
                let url = directory.appendingPathComponent(kind.executableName)
                if isExecutable(url) { return TeXEngine(kind: kind, url: url) }
            }
        }
        return nil
    }

    // MARK: - The command line

    /// Tectonic's V2 command line (`tectonic -X compile …`) arrived in 0.7;
    /// before that the binary took `--outdir` and the file directly. 0.15
    /// still answers the old form, but the new one is the documented one, so
    /// the version decides and both are covered.
    static let tectonicV2Version = "0.7.0"

    /// What to run, for a given engine and — for Tectonic — the version it
    /// reported. Pure, so the tests pin every form.
    static func arguments(
        for kind: TeXEngineKind,
        tectonicVersion: String?,
        input: URL,
        outputDirectory: URL
    ) -> [String] {
        switch kind {
        case .tectonic:
            let version = tectonicVersion ?? tectonicV2Version
            let v2 = UpdateCheck.compare(version, tectonicV2Version) != .orderedAscending
            return (v2 ? ["-X", "compile"] : [])
                + ["--outdir", outputDirectory.path, input.path]
        case .pdflatex, .xelatex:
            // `nonstopmode` so a missing file never sits waiting on stdin, and
            // `halt-on-error` so the first `!` line is the one worth showing.
            return [
                "-interaction=nonstopmode",
                "-halt-on-error",
                "-output-directory", outputDirectory.path,
                input.path,
            ]
        }
    }

    /// The word LaTeX prints when the `.aux` it wrote this pass changed what
    /// the next pass would typeset — numbers, references, a table of
    /// contents. Tectonic reruns by itself; TeX Live does not.
    static let rerunMarker = "Rerun to get cross-references right"

    static func needsSecondPass(log: String) -> Bool {
        log.contains(rerunMarker)
    }

    // MARK: - Compiling

    /// How long a compile may take before it is killed. A first Tectonic run
    /// downloads its package files, so the limit is generous rather than
    /// tight.
    static let timeLimit: TimeInterval = 120

    /// Compile `source` and leave the PDF at `destination`.
    ///
    /// The source is written into a temp directory and everything sitting
    /// beside the original `.tex` is copied in next to it. The other way
    /// round — the source directory as the working directory, with
    /// `-output-directory` pointing at the temp — was tried on paper and
    /// dropped: pdflatex resolves `\input`, `\includegraphics` and `.bib`
    /// against the working directory, but Tectonic anchors them on the input
    /// file's *own* directory, so only the copy makes all three engines
    /// resolve the same names. It also means an unsaved buffer compiles
    /// exactly like a saved one, and that nothing — no `.aux`, no `.log`, no
    /// `.pdf` — is ever written into the reader's folder.
    static func compile(
        engine: TeXEngine,
        source: String,
        sourceURL: URL?,
        to destination: URL,
        timeout: TimeInterval = TeXEngine.timeLimit,
        progress: (String) -> Void = { _ in }
    ) throws {
        let manager = FileManager.default
        let workspace = manager.temporaryDirectory
            .appendingPathComponent("nota-tex-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: workspace) }

        let name = jobName(for: sourceURL)
        let input = workspace.appendingPathComponent(name + ".tex")
        try Data(source.utf8).write(to: input)
        if let sourceURL { copySiblings(of: sourceURL, into: workspace) }

        let version = engine.kind == .tectonic ? tectonicVersion(of: engine.url) : nil
        let arguments = arguments(
            for: engine.kind, tectonicVersion: version,
            input: input, outputDirectory: workspace
        )

        progress(L10n.text("Typesetting…"))
        var log = try run(engine.url, arguments: arguments, cwd: workspace, timeout: timeout).output
        // A second pass only for the TeX Live engines: Tectonic decides for
        // itself how many passes a document needs.
        if engine.kind != .tectonic, needsSecondPass(log: log) {
            progress(L10n.text("Typesetting…"))
            log = try run(engine.url, arguments: arguments, cwd: workspace, timeout: timeout).output
        }
        // The `.log` file says more than the terminal does, and is where the
        // `! …` and `l.N` lines are certain to be.
        let logFile = workspace.appendingPathComponent(name + ".log")
        if let written = try? String(contentsOf: logFile, encoding: .utf8) { log = written + "\n" + log }

        let pdf = workspace.appendingPathComponent(name + ".pdf")
        guard manager.fileExists(atPath: pdf.path) else {
            throw TeXExportError.compileFailed(failureMessage(inLog: log))
        }
        try? manager.removeItem(at: destination)
        try manager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try manager.moveItem(at: pdf, to: destination)
    }

    /// The base name the job runs under. TeX's own file-name parsing stops at
    /// a space and takes `"` for a quoted name, so anything but plain
    /// characters is turned into a hyphen; a name with nothing left of it —
    /// an untitled tab — is `document`.
    static func jobName(for sourceURL: URL?) -> String {
        let raw = sourceURL?.deletingPathExtension().lastPathComponent ?? ""
        let cleaned = String(raw.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character : "-"
        }).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? "document" : cleaned
    }

    /// How much of the source's own folder is worth copying in beside it.
    /// A `.tex` sits in a document folder, not a home directory, but the
    /// reader is not obliged to keep it that way — so the copy stops rather
    /// than duplicating a library of videos to typeset one page.
    static let siblingBudget = 256 * 1024 * 1024

    /// Everything beside the `.tex` — the figures, the `.bib`, the chapters
    /// it `\input`s — copied in so the engine resolves them. The file itself
    /// is skipped (the buffer's text is what is being typeset, not what is on
    /// disk) and so is anything hidden.
    static func copySiblings(
        of sourceURL: URL, into workspace: URL, budget: Int = TeXEngine.siblingBudget
    ) {
        let manager = FileManager.default
        let directory = sourceURL.deletingLastPathComponent()
        guard let entries = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var spent = 0
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if entry.lastPathComponent == sourceURL.lastPathComponent { continue }
            let values = try? entry.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            let size = values?.fileSize ?? 0
            if values?.isRegularFile == true, spent + size > budget { continue }
            spent += size
            try? manager.copyItem(
                at: entry, to: workspace.appendingPathComponent(entry.lastPathComponent)
            )
        }
    }

    // MARK: - Running one process

    /// Run a tool and hand back what it said. stdout and stderr go to a file
    /// rather than a `Pipe`: a chatty run fills a pipe's buffer and the
    /// process would then sit blocked on a write nobody is reading.
    @discardableResult
    static func run(
        _ executable: URL, arguments: [String], cwd: URL, timeout: TimeInterval
    ) throws -> (status: Int32, output: String) {
        let manager = FileManager.default
        let outputURL = manager.temporaryDirectory
            .appendingPathComponent("nota-tex-out-\(UUID().uuidString).txt")
        manager.createFile(atPath: outputURL.path, contents: nil)
        defer { try? manager.removeItem(at: outputURL) }
        guard let handle = try? FileHandle(forWritingTo: outputURL) else {
            throw TeXExportError.compileFailed(L10n.text("Nota couldn't run the TeX engine."))
        }
        defer { try? handle.close() }

        let task = Process()
        task.executableURL = executable
        task.arguments = arguments
        task.currentDirectoryURL = cwd
        task.standardOutput = handle
        task.standardError = handle
        task.standardInput = FileHandle.nullDevice
        // The engine calls its own helpers (`kpsewhich`, `bibtex`), so its own
        // directory has to be on the PATH it is handed.
        var environment = ProcessInfo.processInfo.environment
        let directory = executable.deletingLastPathComponent().path
        environment["PATH"] = directory + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        task.environment = environment

        let finished = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in finished.signal() }
        do {
            try task.run()
        } catch {
            throw TeXExportError.compileFailed(L10n.text("Nota couldn't run the TeX engine."))
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            task.terminate()
            // A TeX that ignores SIGTERM is still holding the export open.
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(task.processIdentifier, SIGKILL)
            }
            throw TeXExportError.timedOut
        }
        let output = (try? String(contentsOf: outputURL, encoding: .utf8))
            ?? (try? String(contentsOf: outputURL, encoding: .isoLatin1)) ?? ""
        return (task.terminationStatus, output)
    }

    /// `tectonic --version` → `0.15.0`, or `nil` when it says something else.
    static func tectonicVersion(of executable: URL) -> String? {
        guard let result = try? run(executable, arguments: ["--version"],
                                    cwd: FileManager.default.temporaryDirectory, timeout: 20),
              result.status == 0
        else { return nil }
        return version(inVersionOutput: result.output)
    }

    /// The first dotted number in a line such as `Tectonic 0.15.0`.
    static func version(inVersionOutput output: String) -> String? {
        for word in output.split(whereSeparator: { $0 == " " || $0.isNewline }) {
            let candidate = word.trimmingCharacters(in: CharacterSet(charactersIn: "vV()"))
            guard let first = candidate.first, first.isNumber, candidate.contains(".") else { continue }
            return candidate
        }
        return nil
    }

    // MARK: - Reading the log

    /// LaTeX marks an error with a line beginning `! `, and names the line of
    /// the source it was reading on a following line beginning `l.` — the two
    /// halves of the only sentence worth showing a reader who is not going to
    /// read a 400-line log.
    static func firstError(inLog log: String) -> (message: String, line: Int?)? {
        let lines = log.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("! ") }) else { return nil }
        var message = String(lines[start].dropFirst(2)).trimmingCharacters(in: .whitespaces)
        if message.isEmpty { message = L10n.text("The TeX engine stopped.") }
        var line: Int?
        for candidate in lines[lines.index(after: start)...].prefix(20) where candidate.hasPrefix("l.") {
            let digits = candidate.dropFirst(2).prefix(while: \.isNumber)
            if let number = Int(digits) { line = number }
            break
        }
        return (message, line)
    }

    /// That sentence, wrapped in Nota's own words and translated.
    static func failureMessage(inLog log: String) -> String {
        guard let error = firstError(inLog: log) else {
            return L10n.text("The TeX engine didn't produce a PDF.")
        }
        if let line = error.line {
            return String(
                format: L10n.text("LaTeX error on line %d: %@"), line, error.message
            )
        }
        return String(format: L10n.text("LaTeX error: %@"), error.message)
    }
}

/// Why an export gave nothing back. Two of these are not failures at all —
/// they are the reader's answer to the install prompt, handed to the caller
/// so it can render the tab natively instead, or leave it alone.
enum TeXExportError: LocalizedError, Equatable {
    /// No TeX, and the reader chose Nota's own render instead.
    case useNativeRender
    /// No TeX, and the reader chose neither.
    case cancelled
    /// A TeX was expected and is not there.
    case noEngine
    /// TeX ran and refused the document; the message is the `! ` line.
    case compileFailed(String)
    /// The engine was still running after `TeXEngine.timeLimit`.
    case timedOut
    /// Downloading or unpacking Tectonic went wrong.
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .useNativeRender:
            return L10n.text("Nota rendered this file itself.")
        case .cancelled:
            return L10n.text("Export cancelled.")
        case .noEngine:
            return L10n.text("Nota couldn't find a TeX engine.")
        case let .compileFailed(message):
            return message
        case .timedOut:
            return L10n.text("The TeX engine took too long and was stopped.")
        case let .installFailed(message):
            return message
        }
    }
}
