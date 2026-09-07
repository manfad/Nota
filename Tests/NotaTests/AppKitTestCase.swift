import Foundation
import XCTest

/// Tests which create AppKit windows, panels, or WebKit/PDF views.
///
/// These have to ask the window server to create real desktop resources, even
/// when their windows are transparent and placed off screen.  Keep the normal
/// `swift test` run suitable for working at a desktop; run this coverage
/// deliberately with `NOTA_RUN_APPKIT_TESTS=1 swift test`.
class AppKitTestCase: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["NOTA_RUN_APPKIT_TESTS"] == "1" else {
            throw XCTSkip("AppKit integration test. Run with NOTA_RUN_APPKIT_TESTS=1.")
        }
    }
}
