import Foundation
import XCTest
@testable import Nota

final class SpellCheckPolicyTests: XCTestCase {

    // MARK: - isProse

    func testAnUntitledNoteIsProse() {
        XCTAssertTrue(SpellCheckPolicy.isProse(nil))
    }

    func testAFileWithNoExtensionIsProse() {
        XCTAssertTrue(SpellCheckPolicy.isProse(URL(fileURLWithPath: "/tmp/README")))
    }

    func testProseExtensionsAreProseWhateverCaseTheyAreTypedIn() {
        for ext in ["md", "markdown", "txt", "text", "tex", "latex", "ltx",
                    "rst", "adoc", "asciidoc", "org"] {
            for spelling in [ext, ext.uppercased()] {
                let url = URL(fileURLWithPath: "/tmp/file.\(spelling)")
                XCTAssertTrue(SpellCheckPolicy.isProse(url), "\(spelling) should read as prose")
            }
        }
    }

    func testSourceAndDataExtensionsAreNotProse() {
        for ext in ["log", "csv", "json", "xml", "yaml", "yml", "toml",
                    "ini", "sh", "py", "js", "ts", "swift", "css", "html", "htm"] {
            let url = URL(fileURLWithPath: "/tmp/file.\(ext)")
            XCTAssertFalse(SpellCheckPolicy.isProse(url), "\(ext) should not read as prose")
        }
    }

    // MARK: - shouldCheck

    func testShouldCheckIsProseAndUnderTheBigFileThreshold() {
        let markdown = URL(fileURLWithPath: "/tmp/notes.md")
        XCTAssertTrue(SpellCheckPolicy.shouldCheck(url: markdown, length: 10))
        XCTAssertFalse(
            SpellCheckPolicy.shouldCheck(url: markdown, length: BigFile.threshold),
            "a big note is not worth scanning even when it is prose"
        )
    }

    func testShouldCheckIsFalseForNonProseWhateverTheLength() {
        let log = URL(fileURLWithPath: "/tmp/app.log")
        XCTAssertFalse(SpellCheckPolicy.shouldCheck(url: log, length: 10))
    }

    func testShouldCheckIsTrueForAnUntitledNoteUnderTheThreshold() {
        XCTAssertTrue(SpellCheckPolicy.shouldCheck(url: nil, length: 0))
        XCTAssertFalse(SpellCheckPolicy.shouldCheck(url: nil, length: BigFile.threshold))
    }
}
