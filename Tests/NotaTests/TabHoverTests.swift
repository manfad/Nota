import XCTest
import AppKit
@testable import Nota

/// The strip's three greys: the selected tab wears its own fill and never the
/// pointer's wash, an unselected tab takes the wash while the pointer is on
/// it, and nothing wears it at rest.
@MainActor
final class TabHoverTests: XCTestCase {
    private func makeBar() -> (NSWindow, TabBarView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: TabBarView.height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 640, height: TabBarView.height))
        window.contentView = bar
        bar.setItems([
            TabBarItem(title: "Untitled", isDirty: true),
            TabBarItem(title: "notes.md", isDirty: false),
        ], selectedIndex: 0)
        bar.layoutSubtreeIfNeeded()
        return (window, bar)
    }

    private func enterEvent(_ window: NSWindow) -> NSEvent {
        NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        )!
    }

    /// The wash fades in with the slot rather than snapping on, so its alpha
    /// only arrives once the runloop has turned; the test waits for it the
    /// way it would wait for any other report.
    @discardableResult
    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    func testHoverWashOnlyOnTheUnselectedTab() {
        let (window, bar) = makeBar()
        XCTAssertEqual(bar.hoverFillAlphasForTesting, [0, 0], "no wash at rest")

        bar.tabViewForTesting(at: 1)?.mouseEntered(with: enterEvent(window))
        XCTAssertTrue(
            waitUntil { bar.hoverFillAlphasForTesting[1] > 0 },
            "the hovered tab takes the wash"
        )
        XCTAssertEqual(bar.hoverFillAlphasForTesting[0], 0, "the selected tab never takes it")

        bar.tabViewForTesting(at: 1)?.mouseExited(with: enterEvent(window))
        XCTAssertTrue(
            waitUntil { bar.hoverFillAlphasForTesting == [0, 0] },
            "and gives it back on the way out"
        )
    }

    func testTheSelectedTabTakesNoWashWhenThePointerIsOnIt() {
        let (window, bar) = makeBar()
        bar.tabViewForTesting(at: 0)?.mouseEntered(with: enterEvent(window))
        // Nothing to wait for here — the point is that nothing arrives — so
        // the runloop is turned for longer than the fade would have taken.
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
        XCTAssertEqual(bar.hoverFillAlphasForTesting[0], 0)
    }

    func testTheNewTabButtonWearsTheSameWash() {
        let (window, bar) = makeBar()
        XCTAssertEqual(bar.newTabButtonHoverAlphaForTesting, 0)

        let plus = bar.subviews.first { $0 is NewTabButton }
        plus?.mouseEntered(with: enterEvent(window))
        XCTAssertTrue(waitUntil { bar.newTabButtonHoverAlphaForTesting > 0 })
    }
}
