import PDFKit
import XCTest
@testable import Nota

/// Export as PDF via TeX: finding an engine, the command line each one takes,
/// the one sentence worth pulling out of a 400-line log, and the Tectonic
/// install from the asset list down to the binary running.
///
/// Nothing here reaches the network — the release payload and the tarball are
/// both made in the test — nothing is written outside a temp directory, and
/// the install prompt is a fake, so no modal is ever raised.
final class TeXEngineTests: XCTestCase {
    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nota-tex-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func exampleURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/\(name)")
            .standardizedFileURL
    }

    /// A file system that exists only in the test: these paths are
    /// executable and nothing else is.
    private func fileSystem(_ paths: [String]) -> (URL) -> Bool {
        let set = Set(paths)
        return { set.contains($0.path) }
    }

    // MARK: - Where Nota looks

    func testTheSearchPathsLeadWithNotasOwnBinAndEndWithTheFixedThree() {
        let bin = URL(fileURLWithPath: "/tmp/nota-bin", isDirectory: true)
        let paths = TeXEngine.searchPaths(binDirectory: bin, path: "/usr/bin:/bin")
        XCTAssertEqual(paths.map(\.path), [
            "/tmp/nota-bin", "/usr/bin", "/bin",
            "/Library/TeX/texbin", "/opt/homebrew/bin", "/usr/local/bin",
        ])
    }

    func testTheSearchPathsDropEmptyAndRepeatedDirectories() {
        let bin = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
        let paths = TeXEngine.searchPaths(binDirectory: bin, path: "/usr/bin::/usr/bin: ")
        XCTAssertEqual(paths.map(\.path), [
            "/usr/local/bin", "/usr/bin", "/Library/TeX/texbin", "/opt/homebrew/bin",
        ])
    }

    func testNoEngineAnywhereIsNil() {
        XCTAssertNil(TeXEngine.installed(
            searchPaths: [URL(fileURLWithPath: "/usr/bin")], isExecutable: fileSystem([])
        ))
    }

    func testTectonicWinsOverAPdflatexInAnEarlierDirectory() {
        // The kind is the outer loop: Tectonic is the one Nota installs and
        // the one that fetches the packages a document asks for.
        let paths = ["/nota/bin", "/Library/TeX/texbin"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        let engine = TeXEngine.installed(
            searchPaths: paths,
            isExecutable: fileSystem(["/nota/bin/pdflatex", "/Library/TeX/texbin/tectonic"])
        )
        XCTAssertEqual(engine?.kind, .tectonic)
        XCTAssertEqual(engine?.url.path, "/Library/TeX/texbin/tectonic")
    }

    func testTheFirstDirectoryHoldingAnEngineWins() {
        let paths = ["/nota/bin", "/Library/TeX/texbin"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        let engine = TeXEngine.installed(
            searchPaths: paths,
            isExecutable: fileSystem(["/nota/bin/pdflatex", "/Library/TeX/texbin/pdflatex"])
        )
        XCTAssertEqual(engine?.url.path, "/nota/bin/pdflatex")
    }

    func testXelatexIsTheLastResort() {
        let engine = TeXEngine.installed(
            searchPaths: [URL(fileURLWithPath: "/opt/homebrew/bin")],
            isExecutable: fileSystem(["/opt/homebrew/bin/xelatex"])
        )
        XCTAssertEqual(engine?.kind, .xelatex)
    }

    func testNotasOwnBinSitsUnderTheSupportDirectory() throws {
        let root = try makeTemporaryDirectory()
        let bin = TeXEngine.binDirectory(applicationSupport: root)
        XCTAssertEqual(bin.path, root.appendingPathComponent("Nota/bin").path)
    }

    // MARK: - The command line

    func testTectonicV2TakesTheCompileSubcommand() {
        let arguments = TeXEngine.arguments(
            for: .tectonic, tectonicVersion: "0.15.0",
            input: URL(fileURLWithPath: "/tmp/w/paper.tex"),
            outputDirectory: URL(fileURLWithPath: "/tmp/w")
        )
        XCTAssertEqual(arguments, ["-X", "compile", "--outdir", "/tmp/w", "/tmp/w/paper.tex"])
    }

    func testTectonicBeforeV2TakesTheFileDirectly() {
        let arguments = TeXEngine.arguments(
            for: .tectonic, tectonicVersion: "0.6.1",
            input: URL(fileURLWithPath: "/tmp/w/paper.tex"),
            outputDirectory: URL(fileURLWithPath: "/tmp/w")
        )
        XCTAssertEqual(arguments, ["--outdir", "/tmp/w", "/tmp/w/paper.tex"])
    }

    func testATectonicThatWontSayItsVersionIsTreatedAsCurrent() {
        let arguments = TeXEngine.arguments(
            for: .tectonic, tectonicVersion: nil,
            input: URL(fileURLWithPath: "/tmp/w/paper.tex"),
            outputDirectory: URL(fileURLWithPath: "/tmp/w")
        )
        XCTAssertEqual(arguments.prefix(2), ["-X", "compile"])
    }

    func testPdflatexAndXelatexRunWithoutAPromptAndStopOnTheFirstError() {
        for kind in [TeXEngineKind.pdflatex, .xelatex] {
            let arguments = TeXEngine.arguments(
                for: kind, tectonicVersion: nil,
                input: URL(fileURLWithPath: "/tmp/w/paper.tex"),
                outputDirectory: URL(fileURLWithPath: "/tmp/w")
            )
            XCTAssertEqual(arguments, [
                "-interaction=nonstopmode", "-halt-on-error",
                "-output-directory", "/tmp/w", "/tmp/w/paper.tex",
            ], "\(kind)")
        }
    }

    func testASecondPassIsOnlyForALogThatAsksForOne() {
        XCTAssertTrue(TeXEngine.needsSecondPass(
            log: "LaTeX Warning: Label(s) may have changed. Rerun to get cross-references right."
        ))
        XCTAssertFalse(TeXEngine.needsSecondPass(log: "Output written on paper.pdf (2 pages)."))
    }

    func testTheVersionIsTheFirstDottedNumberTheToolPrints() {
        XCTAssertEqual(TeXEngine.version(inVersionOutput: "Tectonic 0.15.0\n"), "0.15.0")
        XCTAssertEqual(TeXEngine.version(inVersionOutput: "tectonic v0.9.1"), "0.9.1")
        XCTAssertNil(TeXEngine.version(inVersionOutput: "Tectonic nightly"))
    }

    func testTheJobNameIsPlainOrDocument() {
        XCTAssertEqual(TeXEngine.jobName(for: URL(fileURLWithPath: "/a/Paper.tex")), "Paper")
        // TeX's own file-name parsing stops at a space.
        XCTAssertEqual(TeXEngine.jobName(for: URL(fileURLWithPath: "/a/My paper v2.tex")),
                       "My-paper-v2")
        XCTAssertEqual(TeXEngine.jobName(for: URL(fileURLWithPath: "/a/筆記.tex")), "筆記")
        XCTAssertEqual(TeXEngine.jobName(for: nil), "document")
        XCTAssertEqual(TeXEngine.jobName(for: URL(fileURLWithPath: "/a/--.tex")), "document")
    }

    // MARK: - Reading the log

    func testTheFirstBangLineAndItsSourceLineBecomeTheMessage() {
        let log = """
        This is pdfTeX, Version 3.141592653
        (./paper.tex
        ! Undefined control sequence.
        l.12 \\foo
                  {bar}
        ! Emergency stop.
        """
        let error = TeXEngine.firstError(inLog: log)
        XCTAssertEqual(error?.message, "Undefined control sequence.")
        XCTAssertEqual(error?.line, 12)
        XCTAssertEqual(
            TeXEngine.failureMessage(inLog: log), "LaTeX error on line 12: Undefined control sequence."
        )
    }

    func testAnErrorWithNoSourceLineStillGetsASentence() {
        let log = "! LaTeX Error: File `nosuch.sty' not found.\n\nType X to quit.\n"
        XCTAssertNil(TeXEngine.firstError(inLog: log)?.line)
        XCTAssertEqual(
            TeXEngine.failureMessage(inLog: log),
            "LaTeX error: LaTeX Error: File `nosuch.sty' not found."
        )
    }

    func testALogWithNoErrorAtAllStillSaysSomething() {
        XCTAssertNil(TeXEngine.firstError(inLog: "Output written on paper.pdf (0 pages)."))
        XCTAssertEqual(
            TeXEngine.failureMessage(inLog: "no pdf here"),
            "The TeX engine didn't produce a PDF."
        )
    }

    // MARK: - What sits beside the file

    func testTheSourcesOwnFolderIsCopiedInBesideIt() throws {
        let source = try makeTemporaryDirectory()
        let workspace = try makeTemporaryDirectory()
        let tex = source.appendingPathComponent("paper.tex")
        try "on disk".write(to: tex, atomically: true, encoding: .utf8)
        try "@book{}".write(to: source.appendingPathComponent("refs.bib"),
                           atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("figures"), withIntermediateDirectories: true
        )
        try "png".write(to: source.appendingPathComponent("figures/one.png"),
                        atomically: true, encoding: .utf8)
        try "hidden".write(to: source.appendingPathComponent(".DS_Store"),
                           atomically: true, encoding: .utf8)

        TeXEngine.copySiblings(of: tex, into: workspace)
        let manager = FileManager.default
        XCTAssertTrue(manager.fileExists(atPath: workspace.appendingPathComponent("refs.bib").path))
        XCTAssertTrue(manager.fileExists(
            atPath: workspace.appendingPathComponent("figures/one.png").path
        ))
        XCTAssertFalse(manager.fileExists(atPath: workspace.appendingPathComponent(".DS_Store").path))
        // The buffer's text is what is typeset, not what is on disk.
        XCTAssertFalse(manager.fileExists(atPath: workspace.appendingPathComponent("paper.tex").path))
    }

    func testAFileBiggerThanTheBudgetIsLeftBehind() throws {
        let source = try makeTemporaryDirectory()
        let workspace = try makeTemporaryDirectory()
        let tex = source.appendingPathComponent("paper.tex")
        try "x".write(to: tex, atomically: true, encoding: .utf8)
        try Data(repeating: 0, count: 4096)
            .write(to: source.appendingPathComponent("movie.mov"))
        try "small".write(to: source.appendingPathComponent("a.bib"),
                          atomically: true, encoding: .utf8)

        TeXEngine.copySiblings(of: tex, into: workspace, budget: 100)
        let manager = FileManager.default
        XCTAssertTrue(manager.fileExists(atPath: workspace.appendingPathComponent("a.bib").path))
        XCTAssertFalse(manager.fileExists(atPath: workspace.appendingPathComponent("movie.mov").path))
    }

    // MARK: - Which Mac, and which asset

    func testTheHardwareDecidesTheBuildEvenUnderRosetta() {
        XCTAssertEqual(TectonicInstaller.machine(named: "arm64", translated: false), .appleSilicon)
        XCTAssertEqual(TectonicInstaller.machine(named: "x86_64", translated: false), .intel)
        // An Intel slice under Rosetta still sits on an Apple silicon Mac.
        XCTAssertEqual(TectonicInstaller.machine(named: "x86_64", translated: true), .appleSilicon)
    }

    private var releasePayload: Data {
        let json = """
        {
          "tag_name": "tectonic@0.15.0",
          "assets": [
            {"name": "tectonic-0.15.0-x86_64-unknown-linux-gnu.tar.gz",
             "browser_download_url": "https://example.invalid/linux.tar.gz", "size": 10},
            {"name": "tectonic-0.15.0-x86_64-apple-darwin.tar.gz",
             "browser_download_url": "https://example.invalid/intel.tar.gz", "size": 20},
            {"name": "tectonic-0.15.0-aarch64-apple-darwin.tar.gz",
             "browser_download_url": "https://example.invalid/arm.tar.gz", "size": 30},
            {"name": "tectonic-0.15.0-aarch64-apple-darwin.dmg",
             "browser_download_url": "https://example.invalid/arm.dmg", "size": 40},
            {"name": "SHA256SUMS",
             "browser_download_url": "https://example.invalid/sums", "size": 50}
          ]
        }
        """
        return Data(json.utf8)
    }

    func testTheAssetForEachMacIsTheTarballWithItsTriple() {
        let assets = TectonicInstaller.assets(in: releasePayload)
        XCTAssertEqual(assets.count, 5)
        XCTAssertEqual(
            TectonicInstaller.asset(for: .appleSilicon, in: assets)?.name,
            "tectonic-0.15.0-aarch64-apple-darwin.tar.gz"
        )
        XCTAssertEqual(TectonicInstaller.asset(for: .appleSilicon, in: assets)?.size, 30)
        XCTAssertEqual(
            TectonicInstaller.asset(for: .intel, in: assets)?.name,
            "tectonic-0.15.0-x86_64-apple-darwin.tar.gz"
        )
        XCTAssertEqual(TectonicInstaller.checksumsAsset(in: assets)?.name, "SHA256SUMS")
    }

    func testAReleaseWithNoMacBuildHasNoAsset() {
        let json = Data("""
        {"assets": [{"name": "tectonic-linux.tar.gz",
                     "browser_download_url": "https://example.invalid/x", "size": 1}]}
        """.utf8)
        let assets = TectonicInstaller.assets(in: json)
        XCTAssertNil(TectonicInstaller.asset(for: .appleSilicon, in: assets))
        XCTAssertNil(TectonicInstaller.asset(for: .intel, in: assets))
        XCTAssertTrue(TectonicInstaller.assets(in: Data("not json".utf8)).isEmpty)
    }

    // MARK: - Verifying the download

    func testSHA256IsTheRealDigest() {
        XCTAssertEqual(
            TectonicInstaller.sha256(of: Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testTheChecksumFileIsReadByName() {
        let sums = """
        aaaa  tectonic-0.15.0-x86_64-apple-darwin.tar.gz
        bbbb *tectonic-0.15.0-aarch64-apple-darwin.tar.gz
        """
        XCTAssertEqual(
            TectonicInstaller.checksum(
                for: "tectonic-0.15.0-aarch64-apple-darwin.tar.gz", inSHA256SUMS: sums
            ), "bbbb"
        )
        XCTAssertNil(TectonicInstaller.checksum(for: "nosuch.tar.gz", inSHA256SUMS: sums))
    }

    func testAChecksumPassesOnTheRealTarballAndFailsOnAnyOther() throws {
        let tarball = try makeFakeTectonicTarball()
        let digest = TectonicInstaller.sha256(of: tarball)
        XCTAssertTrue(TectonicInstaller.verify(tarball, against: .checksum(digest)))
        XCTAssertTrue(TectonicInstaller.verify(tarball, against: .checksum(digest.uppercased())))
        XCTAssertFalse(TectonicInstaller.verify(tarball, against: .checksum(String(repeating: "0", count: 64))))
    }

    func testTheSizeIsTheBestEffortCheckWhenThereAreNoChecksums() throws {
        let tarball = try makeFakeTectonicTarball()
        XCTAssertTrue(TectonicInstaller.verify(tarball, against: .size(tarball.count)))
        XCTAssertFalse(TectonicInstaller.verify(tarball, against: .size(tarball.count + 1)))
        // A release that doesn't say how big the file is can't be checked.
        XCTAssertTrue(TectonicInstaller.verify(tarball, against: .size(0)))
    }

    // MARK: - Unpacking

    /// A `.tar.gz` holding one executable called `tectonic` that answers
    /// `--version`. Made here, so no test downloads anything.
    private func makeFakeTectonicTarball(
        script: String = "#!/bin/sh\necho \"Tectonic 0.15.0\"\n", named name: String = "tectonic"
    ) throws -> Data {
        let directory = try makeTemporaryDirectory()
        let binary = directory.appendingPathComponent(name)
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: binary.path
        )
        let tarball = directory.appendingPathComponent("fake.tar.gz")
        let result = try TeXEngine.run(
            URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-czf", tarball.path, "-C", directory.path, name],
            cwd: directory, timeout: 30
        )
        XCTAssertEqual(result.status, 0, result.output)
        return try Data(contentsOf: tarball)
    }

    func testUnpackingInstallsTheBinaryExecutableAndProvesItRuns() throws {
        let bin = try makeTemporaryDirectory().appendingPathComponent("bin", isDirectory: true)
        let engine = try TectonicInstaller.unpack(makeFakeTectonicTarball(), into: bin)

        XCTAssertEqual(engine.kind, .tectonic)
        XCTAssertEqual(engine.url.path, bin.appendingPathComponent("tectonic").path)
        let attributes = try FileManager.default.attributesOfItem(atPath: engine.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        XCTAssertEqual(TeXEngine.tectonicVersion(of: engine.url), "0.15.0")
    }

    func testABinaryThatWontRunIsRemovedAndSaidSo() throws {
        let bin = try makeTemporaryDirectory().appendingPathComponent("bin", isDirectory: true)
        let tarball = try makeFakeTectonicTarball(script: "#!/bin/sh\nexit 1\n")
        XCTAssertThrowsError(try TectonicInstaller.unpack(tarball, into: bin)) { error in
            XCTAssertEqual(
                error as? TeXExportError,
                .installFailed("The Tectonic Nota downloaded doesn't run on this Mac.")
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: bin.appendingPathComponent("tectonic").path)
        )
    }

    func testAnArchiveWithNoTectonicInItIsRefused() throws {
        let bin = try makeTemporaryDirectory().appendingPathComponent("bin", isDirectory: true)
        let tarball = try makeFakeTectonicTarball(named: "README")
        XCTAssertThrowsError(try TectonicInstaller.unpack(tarball, into: bin)) { error in
            XCTAssertEqual(error as? TeXExportError, .installFailed("Nota couldn't unpack Tectonic."))
        }
    }

    // MARK: - The install, end to end, over a fake network

    /// A transport that answers by URL and never leaves the process.
    private func stub(_ answers: [String: Data]) -> TectonicInstaller.Transport {
        { request, completion in
            let url = request.url?.absoluteString ?? ""
            guard let data = answers[url] else {
                return completion(nil, nil, URLError(.fileDoesNotExist))
            }
            completion(data, HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            ), nil)
        }
    }

    func testTheInstallFetchesVerifiesUnpacksAndReportsAsItGoes() throws {
        let tarball = try makeFakeTectonicTarball()
        let sums = "\(TectonicInstaller.sha256(of: tarball))  tectonic-0.15.0-aarch64-apple-darwin.tar.gz\n"
        let bin = try makeTemporaryDirectory().appendingPathComponent("bin", isDirectory: true)
        var said: [String] = []
        var answer: Result<TeXEngine, Error>?
        let done = expectation(description: "installed")

        TectonicInstaller.install(
            binDirectory: bin, machine: .appleSilicon,
            transport: stub([
                TectonicInstaller.releaseEndpoint.absoluteString: releasePayload,
                "https://example.invalid/sums": Data(sums.utf8),
                "https://example.invalid/arm.tar.gz": tarball,
            ]),
            progress: { said.append($0) },
            completion: { answer = $0; done.fulfill() }
        )
        wait(for: [done], timeout: 30)

        guard case let .success(engine)? = answer else {
            return XCTFail("install said \(String(describing: answer))")
        }
        XCTAssertEqual(engine.url.path, bin.appendingPathComponent("tectonic").path)
        XCTAssertEqual(said.first, "Looking for Tectonic…")
        XCTAssertTrue(said.contains { $0.hasPrefix("Downloading Tectonic (") }, "\(said)")
        XCTAssertTrue(said.contains("Unpacking…"), "\(said)")
        XCTAssertEqual(said.last, "Done")
    }

    func testADownloadThatDoesntMatchTheChecksumIsNotUnpacked() throws {
        let tarball = try makeFakeTectonicTarball()
        let sums = "\(String(repeating: "0", count: 64))  tectonic-0.15.0-aarch64-apple-darwin.tar.gz\n"
        let bin = try makeTemporaryDirectory().appendingPathComponent("bin", isDirectory: true)
        var answer: Result<TeXEngine, Error>?
        let done = expectation(description: "refused")

        TectonicInstaller.install(
            binDirectory: bin, machine: .appleSilicon,
            transport: stub([
                TectonicInstaller.releaseEndpoint.absoluteString: releasePayload,
                "https://example.invalid/sums": Data(sums.utf8),
                "https://example.invalid/arm.tar.gz": tarball,
            ]),
            progress: { _ in }, completion: { answer = $0; done.fulfill() }
        )
        wait(for: [done], timeout: 30)

        guard case let .failure(error)? = answer else { return XCTFail("the download was accepted") }
        XCTAssertEqual(
            error as? TeXExportError, .installFailed("The Tectonic download didn't arrive complete.")
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: bin.appendingPathComponent("tectonic").path)
        )
    }

    func testAReleaseWithNoBuildForThisMacSaysSo() throws {
        let bin = try makeTemporaryDirectory().appendingPathComponent("bin", isDirectory: true)
        var answer: Result<TeXEngine, Error>?
        let done = expectation(description: "no build")
        let json = Data("""
        {"assets": [{"name": "tectonic-linux.tar.gz",
                     "browser_download_url": "https://example.invalid/x", "size": 1}]}
        """.utf8)

        TectonicInstaller.install(
            binDirectory: bin, machine: .intel,
            transport: stub([TectonicInstaller.releaseEndpoint.absoluteString: json]),
            progress: { _ in }, completion: { answer = $0; done.fulfill() }
        )
        wait(for: [done], timeout: 10)

        guard case let .failure(error)? = answer else { return XCTFail("a build was found") }
        XCTAssertEqual(
            error as? TeXExportError,
            .installFailed("GitHub doesn't have a Tectonic build for this Mac.")
        )
    }

    func testAnUnreachableGitHubIsSaidPlainly() throws {
        let bin = try makeTemporaryDirectory().appendingPathComponent("bin", isDirectory: true)
        var answer: Result<TeXEngine, Error>?
        let done = expectation(description: "offline")

        TectonicInstaller.install(
            binDirectory: bin, machine: .intel, transport: stub([:]),
            progress: { _ in }, completion: { answer = $0; done.fulfill() }
        )
        wait(for: [done], timeout: 10)

        guard case let .failure(error)? = answer else { return XCTFail("something came back") }
        XCTAssertEqual(error as? TeXExportError, .installFailed("Nota couldn't reach GitHub."))
    }

    // MARK: - The export, and the three answers to the prompt

    private final class FakePrompt: TeXInstallPrompting {
        var answer: TeXInstallChoice
        private(set) var asked = 0
        init(_ answer: TeXInstallChoice) { self.answer = answer }
        func promptForTeXInstall() -> TeXInstallChoice {
            asked += 1
            return answer
        }
    }

    private func exportError(
        prompt: FakePrompt, seams: TeXExport.Seams
    ) -> Error? {
        var answer: Result<Void, Error>?
        TeXExport.export(
            source: "\\documentclass{article}\\begin{document}hi\\end{document}",
            sourceURL: nil, to: FileManager.default.temporaryDirectory
                .appendingPathComponent("nota-tex-\(UUID().uuidString).pdf"),
            presenter: prompt, progress: { _ in }, using: seams,
            completion: { answer = $0 }
        )
        if case let .failure(error)? = answer { return error }
        return nil
    }

    func testWithNoEngineCancelStopsTheExport() {
        var seams = TeXExport.Seams()
        seams.findEngine = { nil }
        let prompt = FakePrompt(.cancel)
        XCTAssertEqual(exportError(prompt: prompt, seams: seams) as? TeXExportError, .cancelled)
        XCTAssertEqual(prompt.asked, 1)
    }

    func testWithNoEngineNotasOwnRenderComesBackAsItsOwnError() {
        var seams = TeXExport.Seams()
        seams.findEngine = { nil }
        // Not a failure: the caller falls back to the native render on it.
        XCTAssertEqual(
            exportError(prompt: FakePrompt(.useNativeRender), seams: seams) as? TeXExportError,
            .useNativeRender
        )
    }

    func testWithNoEngineInstallRunsTheInstallerAndCarriesItsFailure() {
        var seams = TeXExport.Seams()
        seams.findEngine = { nil }
        var installs = 0
        seams.install = { progress, completion in
            installs += 1
            progress("Unpacking…")
            completion(.failure(TeXExportError.installFailed("Nota couldn't unpack Tectonic.")))
        }
        XCTAssertEqual(
            exportError(prompt: FakePrompt(.install), seams: seams) as? TeXExportError,
            .installFailed("Nota couldn't unpack Tectonic.")
        )
        XCTAssertEqual(installs, 1)
    }

    func testAnInstalledEngineTypesetsWithoutAsking() {
        var seams = TeXExport.Seams()
        let engine = TeXEngine(kind: .tectonic, url: URL(fileURLWithPath: "/nota/bin/tectonic"))
        seams.findEngine = { engine }
        var compiled: (TeXEngine, String, URL)?
        seams.compile = { engine, source, _, destination, _ in
            compiled = (engine, source, destination)
        }
        let prompt = FakePrompt(.cancel)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("nota-tex-\(UUID().uuidString).pdf")
        let done = expectation(description: "compiled")
        TeXExport.export(
            source: "hello", sourceURL: nil, to: destination, presenter: prompt,
            progress: { _ in }, using: seams, completion: { _ in done.fulfill() }
        )
        wait(for: [done], timeout: 10)

        XCTAssertEqual(prompt.asked, 0)
        XCTAssertEqual(compiled?.0, engine)
        XCTAssertEqual(compiled?.1, "hello")
        XCTAssertEqual(compiled?.2.path, destination.path)
    }

    func testTheInstallerTheExportGotIsTheOneItTypesetsWith() {
        var seams = TeXExport.Seams()
        seams.findEngine = { nil }
        let installed = TeXEngine(kind: .tectonic, url: URL(fileURLWithPath: "/nota/bin/tectonic"))
        seams.install = { _, completion in completion(.success(installed)) }
        var compiledWith: TeXEngine?
        seams.compile = { engine, _, _, _, _ in compiledWith = engine }
        let done = expectation(description: "compiled")
        TeXExport.export(
            source: "hello", sourceURL: nil,
            to: FileManager.default.temporaryDirectory
                .appendingPathComponent("nota-tex-\(UUID().uuidString).pdf"),
            presenter: FakePrompt(.install), progress: { _ in }, using: seams,
            completion: { _ in done.fulfill() }
        )
        wait(for: [done], timeout: 10)
        XCTAssertEqual(compiledWith, installed)
    }

    func testACompileFailureComesBackAsTheLogsOwnSentence() {
        var seams = TeXExport.Seams()
        seams.findEngine = { TeXEngine(kind: .pdflatex, url: URL(fileURLWithPath: "/x/pdflatex")) }
        seams.compile = { _, _, _, _, _ in
            throw TeXExportError.compileFailed("LaTeX error on line 12: Undefined control sequence.")
        }
        var answer: Result<Void, Error>?
        let done = expectation(description: "failed")
        TeXExport.export(
            source: "x", sourceURL: nil,
            to: FileManager.default.temporaryDirectory.appendingPathComponent("x.pdf"),
            presenter: FakePrompt(.cancel), progress: { _ in }, using: seams,
            completion: { answer = $0; done.fulfill() }
        )
        wait(for: [done], timeout: 10)
        guard case let .failure(error)? = answer else { return XCTFail("it succeeded") }
        XCTAssertEqual(
            error as? TeXExportError,
            .compileFailed("LaTeX error on line 12: Undefined control sequence.")
        )
    }

    // MARK: - A real TeX, when this Mac has one

    /// The only test that runs a TeX, and only where one is installed.
    func testTheExampleCompilesToAPDF() throws {
        guard let engine = TeXEngine.installed() else {
            throw XCTSkip("this Mac has no TeX installed")
        }
        let source = exampleURL("LaTeX.tex")
        let destination = try makeTemporaryDirectory().appendingPathComponent("LaTeX.pdf")

        try TeXEngine.compile(
            engine: engine, source: try String(contentsOf: source, encoding: .utf8),
            sourceURL: source, to: destination
        )
        let document = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertGreaterThanOrEqual(document.pageCount, 1)
    }
}
