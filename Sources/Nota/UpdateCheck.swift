import Foundation

/// "Check for Updates" on the About page, stage one: ask GitHub what the
/// newest release is and say so. Nothing installs itself — the app is
/// ad-hoc signed, so a self-updater would hand the user a copy macOS
/// distrusts, and Sparkle would be the project's first package.
///
/// One request to the releases API, no auth and no token, run only when the
/// button is pressed and remembered nowhere. The transport is a closure so
/// the tests answer it themselves and never touch the network.
enum UpdateCheck {
    /// Where the answer comes from, and what of it is read.
    struct Release: Equatable {
        /// `tag_name` with a leading `v` taken off: `v1.1.0` → `1.1.0`.
        let version: String
        /// `html_url` — the release page a Download button opens.
        let url: String
        /// `name`, the release's own title; empty when GitHub sends none.
        let name: String
        /// `published_at`, as GitHub spells it (ISO 8601).
        let publishedAt: String
    }

    /// Why a check came back with nothing. The wording lives on `message`
    /// so the tests can name the case rather than match a sentence.
    enum Reason: Equatable {
        /// The request never reached GitHub.
        case offline
        /// 403 or 429: the unauthenticated hourly allowance is spent.
        case rateLimited
        /// Any other non-200.
        case server(Int)
        /// Not JSON, or JSON without the fields a release has.
        case malformed
        /// A release whose tag is not a version Nota can compare.
        case unreadableVersion

        var message: String {
            switch self {
            case .offline:
                return L10n.text("Nota couldn't reach GitHub.")
            case .rateLimited:
                return L10n.text("GitHub is rate-limiting update checks. Try again later.")
            case let .server(code):
                return String(
                    format: L10n.text("GitHub answered with status %@."), String(code)
                )
            case .malformed:
                return L10n.text("The answer from GitHub wasn't readable.")
            case .unreadableVersion:
                return L10n.text("GitHub didn't name a version.")
            }
        }
    }

    enum Result: Equatable {
        /// Nothing newer is published. Carries the version now installed.
        case upToDate(String)
        case available(version: String, url: String)
        case failed(Reason)
    }

    /// Everything the check needs of the network: a request in, the three
    /// things `URLSession` hands back out. Injected so a test answers it.
    typealias Transport = (URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> Void

    static let endpoint = URL(string: "https://api.github.com/repos/manfad/Nota/releases/latest")!

    static let urlSession: Transport = { request, completion in
        URLSession.shared.dataTask(with: request) { data, response, error in
            completion(data, response, error)
        }.resume()
    }

    static func request() -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    /// Asks GitHub, compares, and answers on the main queue exactly once.
    static func check(
        current: String = AppVersion.current,
        transport: @escaping Transport = urlSession,
        completion: @escaping (Result) -> Void
    ) {
        transport(request()) { data, response, error in
            let result = outcome(current: current, data: data, response: response, error: error)
            if Thread.isMainThread {
                completion(result)
            } else {
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    /// The whole decision, as a function of what came back — which is the
    /// part worth testing.
    static func outcome(
        current: String, data: Data?, response: URLResponse?, error: Error?
    ) -> Result {
        if error != nil { return .failed(.offline) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if http.statusCode == 403 || http.statusCode == 429 { return .failed(.rateLimited) }
            return .failed(.server(http.statusCode))
        }
        guard let data, let release = parse(data) else { return .failed(.malformed) }
        guard isReadableVersion(release.version) else { return .failed(.unreadableVersion) }
        if compare(release.version, current) == .orderedDescending {
            return .available(version: release.version, url: release.url)
        }
        return .upToDate(current)
    }

    /// The four fields of a release payload. `tag_name` is the only one
    /// required; the rest come back empty when GitHub leaves them out.
    static func parse(_ data: Data) -> Release? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let json = object as? [String: Any],
            let tag = json["tag_name"] as? String
        else { return nil }
        var version = tag.trimmingCharacters(in: .whitespaces)
        if version.hasPrefix("v") || version.hasPrefix("V") { version.removeFirst() }
        return Release(
            version: version,
            url: json["html_url"] as? String ?? "",
            name: json["name"] as? String ?? "",
            publishedAt: json["published_at"] as? String ?? ""
        )
    }

    /// A version has to start with a digit for the comparison below to mean
    /// anything; `nightly` and an empty tag do not.
    static func isReadableVersion(_ version: String) -> Bool {
        version.first.map { $0.isNumber } ?? false
    }

    /// Dotted integers, part by part, missing parts and non-numeric parts
    /// both read as 0 — so `1.0.18` < `1.0.19` < `1.1.0` < `2.0.0`, and
    /// `1.0` and `1.0.0` are the same version.
    static func compare(_ left: String, _ right: String) -> ComparisonResult {
        let a = parts(of: left), b = parts(of: right)
        for index in 0..<max(a.count, b.count) {
            let one = index < a.count ? a[index] : 0
            let two = index < b.count ? b[index] : 0
            if one != two { return one < two ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private static func parts(of version: String) -> [Int] {
        version.split(separator: ".", omittingEmptySubsequences: false).map { part in
            Int(part.prefix(while: \.isNumber)) ?? 0
        }
    }

    // MARK: - Where this copy came from

    /// True when this copy of Nota came from `brew install --cask nota`, in
    /// which case the update to offer is a command rather than a download.
    ///
    /// A cask *moves* `Nota.app` into `/Applications` and leaves a symlink
    /// back to it in the Caskroom, so the bundle path of an installed cask
    /// looks exactly like a hand-copied one. Two rules, then: the bundle
    /// path itself sitting under a `/Caskroom/` (an app still staged, or one
    /// pointed at in place), or a `Caskroom/nota` directory existing under a
    /// Homebrew prefix — the metadata the cask keeps for as long as it is
    /// installed.
    static var installedWithHomebrew: Bool {
        installedWithHomebrew(bundlePath: Bundle.main.bundlePath)
    }

    static let homebrewPrefixes = ["/opt/homebrew", "/usr/local"]

    static func installedWithHomebrew(
        bundlePath: String,
        directoryExists: (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        }
    ) -> Bool {
        if bundlePath.contains("/Caskroom/") { return true }
        var prefixes = homebrewPrefixes
        if let prefix = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"], !prefix.isEmpty {
            prefixes.insert(prefix, at: 0)
        }
        return prefixes.contains { directoryExists($0 + "/Caskroom/nota") }
    }

    /// What the About page prints for a Homebrew copy to run.
    static let homebrewUpgradeCommand = "brew upgrade --cask nota"
}
