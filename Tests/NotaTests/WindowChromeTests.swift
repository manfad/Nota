import AppKit
import XCTest
@testable import Nota

/// Settings › Appearance › Window: the tab strip, the traffic lights and the
/// strip's two trailing buttons can each be switched off, and every one of
/// them comes back the moment the setting does.
final class WindowChromeTests: XCTestCase {
    private var originals: (tabBar: Bool, autoTabBar: Bool, lights: Bool,
                            bookmark: Bool, settings: Bool)!

    override func setUp() {
        super.setUp()
        let prefs = Preferences.shared
        originals = (prefs.hidesTabBar, prefs.autoHidesTabBar, prefs.hidesTrafficLights,
                     prefs.hidesBookmarkButton, prefs.hidesSettingsButton)
        prefs.hidesTabBar = false
        prefs.autoHidesTabBar = false
        prefs.hidesTrafficLights = false
        prefs.hidesBookmarkButton = false
        prefs.hidesSettingsButton = false
    }

    override func tearDown() {
        let prefs = Preferences.shared
        prefs.hidesTabBar = originals.tabBar
        prefs.autoHidesTabBar = originals.autoTabBar
        prefs.hidesTrafficLights = originals.lights
        prefs.hidesBookmarkButton = originals.bookmark
        prefs.hidesSettingsButton = originals.settings
        super.tearDown()
    }

    /// Runs the main run loop for `seconds`, which is how a slide that is
    /// half animation and half deadline gets to land in a test.
    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor
    private func makeController() throws -> (MainWindowController, NSWindow) {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowChromeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let controller = MainWindowController(store: SessionStore(directory: directory))
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFrontOffscreen()
        window.layoutIfNeeded()
        return (controller, window)
    }

    /// Hiding the strip takes it off the window the way zen does — and the
    /// setting alone brings it back, zen untouched.
    @MainActor
    func testHidingTheTabBarTakesTheStripAwayAndBack() throws {
        let (controller, window) = try makeController()
        XCTAssertFalse(controller.tabStrip.isHidden)
        let stripTop = controller.tabStrip.frame

        Preferences.shared.hidesTabBar = true
        window.layoutIfNeeded()
        XCTAssertTrue(controller.tabStrip.isHidden)
        XCTAssertFalse(controller.isZenMode, "a hidden strip is not zen mode")

        Preferences.shared.hidesTabBar = false
        window.layoutIfNeeded()
        XCTAssertFalse(controller.tabStrip.isHidden)
        XCTAssertEqual(controller.tabStrip.frame, stripTop, "back exactly where it was")
    }

    /// "Hide tab bar" takes the traffic lights with it, the same way zen
    /// does — and they come back when the strip does.
    @MainActor
    func testHidingTheTabBarTakesTheTrafficLightsWithIt() throws {
        let (_, window) = try makeController()
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        XCTAssertTrue(buttons.allSatisfy { window.standardWindowButton($0)?.isHidden == false })

        Preferences.shared.hidesTabBar = true
        XCTAssertTrue(buttons.allSatisfy { window.standardWindowButton($0)?.isHidden == true })

        Preferences.shared.hidesTabBar = false
        XCTAssertTrue(buttons.allSatisfy { window.standardWindowButton($0)?.isHidden == false })
    }

    @MainActor
    func testHidingTheTrafficLightsHidesAllThreeButtons() throws {
        let (_, window) = try makeController()
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        XCTAssertTrue(buttons.allSatisfy { window.standardWindowButton($0)?.isHidden == false })

        Preferences.shared.hidesTrafficLights = true
        XCTAssertTrue(buttons.allSatisfy { window.standardWindowButton($0)?.isHidden == true })

        Preferences.shared.hidesTrafficLights = false
        XCTAssertTrue(buttons.allSatisfy { window.standardWindowButton($0)?.isHidden == false })
    }

    /// Hiding the lights hands their slot to the strip: it starts at the
    /// same 12pt inset a left sidebar gets, and moves back when they return.
    @MainActor
    func testHidingTheTrafficLightsMovesTheStripIntoTheirSlot() throws {
        let (controller, window) = try makeController()
        window.layoutIfNeeded()
        XCTAssertEqual(controller.tabStrip.frame.minX, MainWindowController.tabStripLeadingInset,
                       accuracy: 0.5)

        Preferences.shared.hidesTrafficLights = true
        window.layoutIfNeeded()
        XCTAssertEqual(controller.tabStrip.frame.minX, 12, accuracy: 0.5)

        Preferences.shared.hidesTrafficLights = false
        window.layoutIfNeeded()
        XCTAssertEqual(controller.tabStrip.frame.minX, MainWindowController.tabStripLeadingInset,
                       accuracy: 0.5)
    }

    /// A hidden button is not drawn, and its slot goes back to the tabs: the
    /// + moves right by exactly what the button took.
    @MainActor
    func testHidingTheStripsButtonsGivesTheirSlotsBackToTheTabs() throws {
        let (controller, window) = try makeController()
        let strip = controller.tabStrip
        func settle() {
            window.layoutIfNeeded()
            strip.layoutSubtreeIfNeeded()
        }
        settle()
        let plusWithBoth = strip.newTabButtonFrameForTesting.minX
        XCTAssertEqual(strip.trailingButtonsHiddenForTesting.bookmark, false)
        XCTAssertEqual(strip.trailingButtonsHiddenForTesting.settings, false)

        Preferences.shared.hidesSettingsButton = true
        settle()
        XCTAssertTrue(strip.trailingButtonsHiddenForTesting.settings)
        XCTAssertFalse(strip.trailingButtonsHiddenForTesting.bookmark)
        // The bookmark button moves into the gear's place…
        XCTAssertEqual(
            strip.bookmarksButtonFrameForTesting.minX,
            strip.bounds.width - TabStripLayout.trailingReserve - TabStripLayout.bookmarkSlot,
            accuracy: 0.5
        )
        // …and the + follows it right by one slot and a gap. The strip is
        // full here (one tab, so the + rides after it), so compare the room
        // the tabs are given instead.
        XCTAssertEqual(
            TabStripLayout.trailingControls,
            TabStripLayout.bookmarkSlot + TabStripLayout.bookmarkGap + TabStripLayout.trailingReserve
        )

        Preferences.shared.hidesBookmarkButton = true
        settle()
        XCTAssertTrue(strip.trailingButtonsHiddenForTesting.bookmark)
        XCTAssertEqual(TabStripLayout.trailingControls, TabStripLayout.trailingReserve)

        Preferences.shared.hidesBookmarkButton = false
        Preferences.shared.hidesSettingsButton = false
        settle()
        XCTAssertEqual(strip.newTabButtonFrameForTesting.minX, plusWithBoth, accuracy: 0.5)
        XCTAssertEqual(strip.trailingButtonsHiddenForTesting.bookmark, false)
        XCTAssertEqual(strip.trailingButtonsHiddenForTesting.settings, false)
    }

    // MARK: - Auto-hide

    /// Auto-hide takes the strip out of the layout exactly as the plain hide
    /// does: the split grows into the room the strip was using. The traffic
    /// lights idle the same way, gone until the pointer brings them back.
    @MainActor
    func testAutoHidingTakesTheStripOutOfTheLayout() throws {
        let (controller, window) = try makeController()
        let inLayout = controller.workspaceSplitForTesting.frame.height
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        XCTAssertFalse(controller.tabStrip.isHidden)

        Preferences.shared.autoHidesTabBar = true
        window.layoutIfNeeded()
        XCTAssertTrue(controller.tabStrip.isHidden, "the strip waits for the pointer")
        XCTAssertFalse(controller.isTabBarOverlayVisibleForTesting)
        XCTAssertEqual(controller.workspaceSplitForTesting.frame.height,
                       inLayout + TabBarView.height, accuracy: 0.5,
                       "the split takes the strip's room")
        XCTAssertTrue(buttons.allSatisfy { window.standardWindowButton($0)?.isHidden == true },
                      "idling, the lights are gone with the strip")
    }

    /// The pointer reaching the top edge brings the strip back as an opaque
    /// overlay: it lies over the split rather than pushing it down again. The
    /// traffic lights come back with it, and the strip clears them at 82pt
    /// again rather than keeping the idle 12pt inset.
    @MainActor
    func testReachingTheTopEdgeSlidesTheStripInOverTheSplit() throws {
        let (controller, window) = try makeController()
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        Preferences.shared.autoHidesTabBar = true
        window.layoutIfNeeded()
        let splitHeight = controller.workspaceSplitForTesting.frame.height

        controller.pointerEnteredHotZoneForTesting()
        settle(0.3)
        window.layoutIfNeeded()

        XCTAssertTrue(controller.isTabBarOverlayVisibleForTesting)
        XCTAssertFalse(controller.tabStrip.isHidden)
        XCTAssertTrue(controller.tabStrip.drawsOpaqueBackground,
                      "over the document the strip has to bring its own ground")
        XCTAssertTrue(controller.tabStrip.frame.intersects(controller.workspaceSplitForTesting.frame),
                      "the strip is an overlay, not a row above the split")
        XCTAssertTrue(buttons.allSatisfy { window.standardWindowButton($0)?.isHidden == false },
                      "the lights come back with the revealed strip")
        XCTAssertEqual(controller.tabStrip.frame.minX, MainWindowController.tabStripLeadingInset,
                       accuracy: 0.5)
        XCTAssertEqual(controller.workspaceSplitForTesting.frame.height, splitHeight, accuracy: 0.5,
                       "nothing moved to make room for it")
        let workspace = try XCTUnwrap(controller.tabStrip.superview)
        let strip = try XCTUnwrap(workspace.subviews.firstIndex(of: controller.tabStrip))
        let split = try XCTUnwrap(
            workspace.subviews.firstIndex(of: controller.workspaceSplitForTesting)
        )
        XCTAssertGreaterThan(strip, split, "the strip draws over the split")
    }

    /// The overlaid strip reuses the same leading constraint as the docked
    /// one, so hiding the lights moves it in too.
    @MainActor
    func testTheOverlayStripAlsoMovesIntoTheLightsSlotWhenTheyAreHidden() throws {
        let (controller, window) = try makeController()
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        Preferences.shared.hidesTrafficLights = true
        Preferences.shared.autoHidesTabBar = true
        window.layoutIfNeeded()

        controller.pointerEnteredHotZoneForTesting()
        settle(0.3)
        window.layoutIfNeeded()

        XCTAssertTrue(controller.isTabBarOverlayVisibleForTesting)
        XCTAssertEqual(controller.tabStrip.frame.minX, 12, accuracy: 0.5)
        XCTAssertTrue(buttons.allSatisfy { window.standardWindowButton($0)?.isHidden == true },
                      "\"Hide traffic lights\" keeps them off through the reveal")
    }

    /// And leaving it sends the strip away again, after the grace period.
    @MainActor
    func testLeavingTheStripSlidesItAwayAfterTheGracePeriod() throws {
        let (controller, window) = try makeController()
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        Preferences.shared.autoHidesTabBar = true
        window.layoutIfNeeded()
        controller.pointerEnteredHotZoneForTesting()
        settle(0.3)
        XCTAssertTrue(controller.isTabBarOverlayVisibleForTesting)

        controller.pointerLeftTabBarForTesting()
        XCTAssertTrue(controller.isTabBarOverlayVisibleForTesting, "the grace period is not up")

        settle(0.7)
        window.layoutIfNeeded()
        XCTAssertFalse(controller.isTabBarOverlayVisibleForTesting)
        XCTAssertTrue(controller.tabStrip.isHidden)
        XCTAssertTrue(buttons.allSatisfy { window.standardWindowButton($0)?.isHidden == true },
                      "the lights go with the strip again once it slides away")
    }

    /// "Hide tab bar" beats auto-hide: the strip is gone for good and the top
    /// edge brings back nothing.
    @MainActor
    func testHidingTheTabBarBeatsAutoHide() throws {
        let (controller, window) = try makeController()
        Preferences.shared.autoHidesTabBar = true
        window.layoutIfNeeded()
        controller.pointerEnteredHotZoneForTesting()
        settle(0.3)
        XCTAssertTrue(controller.isTabBarOverlayVisibleForTesting)

        Preferences.shared.hidesTabBar = true
        window.layoutIfNeeded()
        XCTAssertTrue(controller.tabStrip.isHidden)
        XCTAssertFalse(controller.isTabBarOverlayVisibleForTesting)
        XCTAssertFalse(controller.tabStrip.drawsOpaqueBackground)

        controller.pointerEnteredHotZoneForTesting()
        settle(0.3)
        window.layoutIfNeeded()
        XCTAssertTrue(controller.tabStrip.isHidden, "the top edge reveals nothing")
        XCTAssertFalse(controller.isTabBarOverlayVisibleForTesting)
    }

    /// Turning auto-hide off puts the strip back where it was, in the layout.
    @MainActor
    func testTurningAutoHideOffPutsTheStripBackInTheLayout() throws {
        let (controller, window) = try makeController()
        window.layoutIfNeeded()
        let inLayout = controller.tabStrip.frame

        Preferences.shared.autoHidesTabBar = true
        window.layoutIfNeeded()
        controller.pointerEnteredHotZoneForTesting()
        settle(0.3)

        Preferences.shared.autoHidesTabBar = false
        window.layoutIfNeeded()
        XCTAssertFalse(controller.tabStrip.isHidden)
        XCTAssertFalse(controller.tabStrip.drawsOpaqueBackground)
        XCTAssertFalse(controller.isTabBarOverlayVisibleForTesting)
        XCTAssertEqual(controller.tabStrip.frame, inLayout, "back exactly where it was")
    }
}
