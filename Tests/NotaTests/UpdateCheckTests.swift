import XCTest
@testable import Nota

/// The About page's update check: the version arithmetic, and what each
/// shape of answer from GitHub turns into. Every test answers the transport
/// itself, so nothing here touches the network.
final class UpdateCheckTests: XCTestCase {
    // MARK: - Helpers

    private func payload(
        tag: String = "v1.1.0",
        url: String = "https://github.com/manfad/Nota/releases/tag/v1.1.0"
    ) -> Data {
        let json = """
        {
          "tag_name": "\(tag)",
          "html_url": "\(url)",
          "name": "Nota \(tag)",
          "published_at": "2026-09-06T10:00:00Z"
        }
        """
        return Data(json.utf8)
    }

    private func response(_ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: UpdateCheck.endpoint, statusCode: code, httpVersion: nil, headerFields: nil
        )!
    }

    /// A transport that hands back exactly these three, synchronously.
    private func stub(
        _ data: Data?, _ response: URLResponse?, _ error: Error? = nil
    ) -> UpdateCheck.Transport {
        { _, completion in completion(data, response, error) }
    }

    private func result(
        current: String = "1.0.18", transport: @escaping UpdateCheck.Transport
    ) -> UpdateCheck.Result {
        var answer: UpdateCheck.Result?
        UpdateCheck.check(current: current, transport: transport) { answer = $0 }
        return answer ?? .failed(.malformed)
    }

    // MARK: - The request itself

    func testTheRequestNamesTheReleasesAPIAndAsksForJSON() {
        let request = UpdateCheck.request()
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://api.github.com/repos/manfad/Nota/releases/latest"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json"
        )
        XCTAssertEqual(request.timeoutInterval, 10)
        // No token, ever: the check is anonymous.
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: - Comparing versions

    /// Dotted integers compared part by part, not as text — otherwise
    /// `1.0.9` would sort after `1.0.18`.
    func testVersionsCompareAsNumbersPartByPart() {
        let ascending = ["1.0.9", "1.0.18", "1.0.19", "1.1.0", "1.10.0", "2.0.0"]
        for (index, lower) in ascending.enumerated() {
            for higher in ascending[(index + 1)...] {
                XCTAssertEqual(UpdateCheck.compare(lower, higher), .orderedAscending,
                               "\(lower) should be below \(higher)")
                XCTAssertEqual(UpdateCheck.compare(higher, lower), .orderedDescending,
                               "\(higher) should be above \(lower)")
            }
        }
    }

    /// A missing part is a zero, so a two-part version and its three-part
    /// spelling are the same version.
    func testMissingAndNonNumericPartsCountAsZero() {
        XCTAssertEqual(UpdateCheck.compare("1.0", "1.0.0"), .orderedSame)
        XCTAssertEqual(UpdateCheck.compare("1", "1.0.0"), .orderedSame)
        XCTAssertEqual(UpdateCheck.compare("1.0.0", "1.0"), .orderedSame)
        XCTAssertEqual(UpdateCheck.compare("1.0.1", "1.0"), .orderedDescending)
        // A suffix on a part is dropped rather than making the whole
        // comparison meaningless.
        XCTAssertEqual(UpdateCheck.compare("1.2.0-beta", "1.2.0"), .orderedSame)
        XCTAssertEqual(UpdateCheck.compare("1.x.0", "1.0.0"), .orderedSame)
    }

    // MARK: - Parsing an answer

    func testParseReadsTheFourFieldsAndStripsTheLeadingV() throws {
        let release = try XCTUnwrap(UpdateCheck.parse(payload()))
        XCTAssertEqual(release.version, "1.1.0")
        XCTAssertEqual(release.url, "https://github.com/manfad/Nota/releases/tag/v1.1.0")
        XCTAssertEqual(release.name, "Nota v1.1.0")
        XCTAssertEqual(release.publishedAt, "2026-09-06T10:00:00Z")
    }

    /// A tag written without the `v` is the same version.
    func testATagWithoutAVIsReadTheSameWay() {
        XCTAssertEqual(
            result(transport: stub(payload(tag: "1.1.0"), response(200))),
            .available(version: "1.1.0",
                       url: "https://github.com/manfad/Nota/releases/tag/v1.1.0")
        )
    }

    // MARK: - The four outcomes

    func testANewerReleaseIsOffered() {
        XCTAssertEqual(
            result(transport: stub(payload(), response(200))),
            .available(version: "1.1.0",
                       url: "https://github.com/manfad/Nota/releases/tag/v1.1.0")
        )
    }

    func testTheSameVersionIsUpToDate() {
        XCTAssertEqual(
            result(current: "1.1.0", transport: stub(payload(), response(200))),
            .upToDate("1.1.0")
        )
    }

    /// A development build ahead of the newest release is up to date, not
    /// offered a downgrade.
    func testAVersionAheadOfTheServerIsStillUpToDate() {
        XCTAssertEqual(
            result(current: "1.2.0", transport: stub(payload(tag: "v1.1.0"), response(200))),
            .upToDate("1.2.0")
        )
    }

    func testMalformedJSONFails() {
        XCTAssertEqual(
            result(transport: stub(Data("not json at all".utf8), response(200))),
            .failed(.malformed)
        )
        // Valid JSON without the one field a release must have.
        XCTAssertEqual(
            result(transport: stub(Data(#"{"message":"Not Found"}"#.utf8), response(200))),
            .failed(.malformed)
        )
    }

    /// A tag that is not a version at all is its own failure, so the page
    /// does not offer "Nota nightly is available".
    func testATagThatIsNotAVersionFails() {
        XCTAssertEqual(
            result(transport: stub(payload(tag: "nightly"), response(200))),
            .failed(.unreadableVersion)
        )
        XCTAssertEqual(
            result(transport: stub(payload(tag: ""), response(200))), .failed(.unreadableVersion)
        )
    }

    /// The anonymous API allowance is small, and running out of it has its
    /// own wording rather than a bare status number.
    func testRateLimitingHasItsOwnReason() {
        XCTAssertEqual(
            result(transport: stub(Data(), response(403))), .failed(.rateLimited)
        )
        XCTAssertEqual(
            result(transport: stub(Data(), response(429))), .failed(.rateLimited)
        )
        XCTAssertNotEqual(UpdateCheck.Reason.rateLimited.message,
                          UpdateCheck.Reason.server(403).message)
    }

    func testAnyOtherStatusIsReportedWithItsNumber() {
        XCTAssertEqual(result(transport: stub(Data(), response(404))), .failed(.server(404)))
        XCTAssertEqual(result(transport: stub(Data(), response(500))), .failed(.server(500)))
        XCTAssertTrue(UpdateCheck.Reason.server(500).message.contains("500"))
    }

    func testATransportErrorIsOffline() {
        let failure = URLError(.notConnectedToInternet)
        XCTAssertEqual(result(transport: stub(nil, nil, failure)), .failed(.offline))
        // An error wins even when a body came back with it.
        XCTAssertEqual(
            result(transport: stub(payload(), response(200), failure)), .failed(.offline)
        )
    }

    /// Every reason says something, and no two say the same thing.
    func testEveryReasonHasItsOwnWording() {
        let reasons: [UpdateCheck.Reason] = [
            .offline, .rateLimited, .server(500), .malformed, .unreadableVersion,
        ]
        let messages = reasons.map(\.message)
        XCTAssertFalse(messages.contains(where: \.isEmpty))
        XCTAssertEqual(Set(messages).count, reasons.count)
    }

    // MARK: - Where this copy came from

    /// A cask moves `Nota.app` into `/Applications` and keeps its metadata
    /// in the Caskroom, so the directory on disk is the tell — the bundle
    /// path alone looks like any hand-copied app.
    func testHomebrewIsDetectedByTheCaskroomDirectory() {
        let installed = UpdateCheck.installedWithHomebrew(
            bundlePath: "/Applications/Nota.app",
            directoryExists: { $0 == "/opt/homebrew/Caskroom/nota" }
        )
        XCTAssertTrue(installed)

        let intel = UpdateCheck.installedWithHomebrew(
            bundlePath: "/Applications/Nota.app",
            directoryExists: { $0 == "/usr/local/Caskroom/nota" }
        )
        XCTAssertTrue(intel)
    }

    /// An app still sitting in the Caskroom is a Homebrew copy whatever is
    /// on disk beside it.
    func testABundleInsideTheCaskroomIsHomebrew() {
        XCTAssertTrue(UpdateCheck.installedWithHomebrew(
            bundlePath: "/opt/homebrew/Caskroom/nota/1.0.18/Nota.app",
            directoryExists: { _ in false }
        ))
    }

    func testAHandCopiedAppIsNotHomebrew() {
        XCTAssertFalse(UpdateCheck.installedWithHomebrew(
            bundlePath: "/Applications/Nota.app", directoryExists: { _ in false }
        ))
        XCTAssertFalse(UpdateCheck.installedWithHomebrew(
            bundlePath: "/Users/someone/Downloads/Nota.app",
            directoryExists: { $0 == "/opt/homebrew/Caskroom/something-else" }
        ))
    }

    func testTheHomebrewCommandNamesTheTapsCask() {
        XCTAssertEqual(UpdateCheck.homebrewUpgradeCommand, "brew upgrade --cask nota")
    }
}
