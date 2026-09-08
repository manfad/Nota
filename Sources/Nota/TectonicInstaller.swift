import CryptoKit
import Foundation

/// Nota's own copy of a TeX, for a Mac that has none.
///
/// Tectonic is one binary of about 30 MB that fetches the `.sty` files a
/// document asks for as it goes, so it is the only TeX that can be
/// *installed* rather than distributed — MacTeX is a 5 GB package and a
/// privileged installer, which is not something an editor should be putting
/// on anybody's Mac. The copy goes into
/// `~/Library/Application Support/Nota/bin`, never `/usr/local`: nothing
/// outside Nota's own folder changes, and deleting that folder undoes it.
///
/// The network is a closure, exactly as `UpdateCheck`'s is, so no test here
/// reaches GitHub and none of them downloads anything.
enum TectonicInstaller {
    // MARK: - What GitHub says

    /// One file attached to a release.
    struct Asset: Equatable {
        let name: String
        let downloadURL: String
        /// GitHub's own `size` in bytes — the fallback check when a release
        /// carries no checksums.
        let size: Int
    }

    /// Which build to fetch. The two Macs, named the way Rust names them,
    /// since that is how Tectonic spells its assets.
    enum Machine: Equatable {
        case appleSilicon
        case intel

        var assetInfix: String {
            switch self {
            case .appleSilicon: return "aarch64-apple-darwin"
            case .intel: return "x86_64-apple-darwin"
            }
        }
    }

    typealias Transport = UpdateCheck.Transport

    static let releaseEndpoint = URL(
        string: "https://api.github.com/repos/tectonic-typesetting/tectonic/releases/latest"
    )!

    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    /// The assets of a release payload, in the order GitHub listed them.
    static func assets(in data: Data) -> [Asset] {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let json = object as? [String: Any],
            let list = json["assets"] as? [[String: Any]]
        else { return [] }
        return list.compactMap { entry in
            guard let name = entry["name"] as? String,
                  let url = entry["browser_download_url"] as? String
            else { return nil }
            return Asset(name: name, downloadURL: url, size: entry["size"] as? Int ?? 0)
        }
    }

    /// The build for this Mac: the `.tar.gz` whose name carries the target
    /// triple. Tectonic also publishes `.dmg`s and Linux and Windows builds
    /// in the same release, so both halves of the test matter.
    static func asset(for machine: Machine, in assets: [Asset]) -> Asset? {
        assets.first { asset in
            asset.name.contains(machine.assetInfix) && asset.name.hasSuffix(".tar.gz")
        }
    }

    /// The release's checksum file, when it publishes one.
    static func checksumsAsset(in assets: [Asset]) -> Asset? {
        assets.first { $0.name.uppercased().contains("SHA256SUMS") }
    }

    /// `<64 hex digits>  <file name>`, one per line — the format `shasum` and
    /// `sha256sum` both write, with the name sometimes marked `*` for a
    /// binary read.
    static func checksum(for name: String, inSHA256SUMS text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let listed = parts[1].hasPrefix("*") ? String(parts[1].dropFirst()) : String(parts[1])
            if listed == name { return String(parts[0]).lowercased() }
        }
        return nil
    }

    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// How complete a download has to be before it is unpacked. A checksum is
    /// the real answer; the byte count is what is left when a release carries
    /// no `SHA256SUMS`, and it catches the case that actually happens — a
    /// truncated or redirected download — rather than a tampered one.
    enum Verification: Equatable {
        case checksum(String)
        case size(Int)
    }

    static func verify(_ data: Data, against verification: Verification) -> Bool {
        switch verification {
        case let .checksum(expected):
            return sha256(of: data) == expected.lowercased()
        case let .size(expected):
            return expected <= 0 || data.count == expected
        }
    }

    // MARK: - Which Mac this is

    /// The hardware, not the process. An Intel slice running under Rosetta on
    /// an Apple silicon Mac reports `x86_64` from `hw.machine`, and Nota would
    /// then install a translated TeX on a machine that can run a native one —
    /// so `sysctl.proc_translated` gets the last word.
    static func machine(named name: String, translated: Bool) -> Machine {
        if name.hasPrefix("arm") || translated { return .appleSilicon }
        return .intel
    }

    static var currentMachine: Machine {
        machine(named: sysctlString("hw.machine"), translated: sysctlInteger("sysctl.proc_translated") == 1)
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }

    private static func sysctlInteger(_ name: String) -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return 0 }
        return Int(value)
    }

    // MARK: - Installing

    /// Fetch, verify, unpack, and hand back the engine — or say why not.
    /// Every step reports through `progress`, and both callbacks land on the
    /// main queue, since what they drive is a sheet.
    static func install(
        binDirectory: URL? = nil,
        machine: Machine = TectonicInstaller.currentMachine,
        transport: @escaping Transport = UpdateCheck.urlSession,
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<TeXEngine, Error>) -> Void
    ) {
        let bin = binDirectory ?? TeXEngine.binDirectory()
        func fail(_ error: TeXExportError) { onMain { completion(.failure(error)) } }
        func say(_ message: String) { onMain { progress(message) } }

        say(L10n.text("Looking for Tectonic…"))
        transport(request(releaseEndpoint)) { data, response, error in
            guard let data, error == nil, isOK(response) else {
                return fail(.installFailed(L10n.text("Nota couldn't reach GitHub.")))
            }
            let all = assets(in: data)
            guard let wanted = asset(for: machine, in: all), let url = URL(string: wanted.downloadURL)
            else {
                return fail(.installFailed(
                    L10n.text("GitHub doesn't have a Tectonic build for this Mac.")
                ))
            }
            verification(for: wanted, in: all, transport: transport) { verification in
                say(String(
                    format: L10n.text("Downloading Tectonic (%@)…"),
                    ByteCountFormatter.string(fromByteCount: Int64(wanted.size), countStyle: .file)
                ))
                transport(request(url)) { payload, response, error in
                    guard let payload, error == nil, isOK(response) else {
                        return fail(.installFailed(L10n.text("Nota couldn't reach GitHub.")))
                    }
                    guard verify(payload, against: verification) else {
                        return fail(.installFailed(
                            L10n.text("The Tectonic download didn't arrive complete.")
                        ))
                    }
                    say(L10n.text("Unpacking…"))
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let engine = try unpack(payload, into: bin)
                            say(L10n.text("Done"))
                            onMain { completion(.success(engine)) }
                        } catch let error as TeXExportError {
                            fail(error)
                        } catch {
                            fail(.installFailed(L10n.text("Nota couldn't unpack Tectonic.")))
                        }
                    }
                }
            }
        }
    }

    /// The checksum when the release publishes one, the byte count when it
    /// does not — best effort, and SPEC says so.
    private static func verification(
        for asset: Asset, in assets: [Asset], transport: @escaping Transport,
        then answer: @escaping (Verification) -> Void
    ) {
        guard let sums = checksumsAsset(in: assets), let url = URL(string: sums.downloadURL) else {
            return answer(.size(asset.size))
        }
        transport(request(url)) { data, response, error in
            guard let data, error == nil, isOK(response),
                  let text = String(data: data, encoding: .utf8),
                  let expected = checksum(for: asset.name, inSHA256SUMS: text)
            else { return answer(.size(asset.size)) }
            answer(.checksum(expected))
        }
    }

    private static func isOK(_ response: URLResponse?) -> Bool {
        guard let http = response as? HTTPURLResponse else { return true }
        return http.statusCode == 200
    }

    private static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    // MARK: - Unpacking

    /// Untar, install, and prove it runs.
    ///
    /// The archive is expanded into a scratch directory rather than straight
    /// into Nota's bin: a release tarball is free to carry a README or a
    /// completions folder beside the binary, and only the binary belongs in a
    /// directory Nota searches. `tar` itself is `/usr/bin/tar` — SPEC's rule
    /// is that a dependency has to earn its keep over what macOS already
    /// does, and `.tar.gz` is a thing macOS already does.
    static func unpack(_ archive: Data, into binDirectory: URL) throws -> TeXEngine {
        let manager = FileManager.default
        let staging = manager.temporaryDirectory
            .appendingPathComponent("nota-tectonic-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }

        let tarball = staging.appendingPathComponent("tectonic.tar.gz")
        try archive.write(to: tarball)
        let extracted = staging.appendingPathComponent("out", isDirectory: true)
        try manager.createDirectory(at: extracted, withIntermediateDirectories: true)
        let tar = try TeXEngine.run(
            URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xzf", tarball.path, "-C", extracted.path],
            cwd: staging, timeout: 120
        )
        guard tar.status == 0, let binary = findBinary(named: "tectonic", under: extracted) else {
            throw TeXExportError.installFailed(L10n.text("Nota couldn't unpack Tectonic."))
        }

        try manager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let installed = binDirectory.appendingPathComponent("tectonic")
        try? manager.removeItem(at: installed)
        try manager.moveItem(at: binary, to: installed)
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installed.path)
        // A file Nota downloaded is quarantined, and a quarantined command
        // line tool is refused with no dialogue to allow it. Failure is fine:
        // the attribute is only there when the download set it.
        _ = try? TeXEngine.run(
            URL(fileURLWithPath: "/usr/bin/xattr"),
            arguments: ["-d", "com.apple.quarantine", installed.path],
            cwd: binDirectory, timeout: 20
        )

        // The proof: it runs on this Mac. A build for the wrong architecture,
        // or one macOS refuses, fails here rather than at the reader's first
        // export.
        guard let result = try? TeXEngine.run(
            installed, arguments: ["--version"], cwd: binDirectory, timeout: 30
        ), result.status == 0 else {
            try? manager.removeItem(at: installed)
            throw TeXExportError.installFailed(
                L10n.text("The Tectonic Nota downloaded doesn't run on this Mac.")
            )
        }
        return TeXEngine(kind: .tectonic, url: installed)
    }

    /// The first file of that name anywhere in the expanded archive.
    static func findBinary(named name: String, under directory: URL) -> URL? {
        let manager = FileManager.default
        guard let walker = manager.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return nil }
        for case let url as URL in walker where url.lastPathComponent == name {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true { return url }
        }
        return nil
    }
}
