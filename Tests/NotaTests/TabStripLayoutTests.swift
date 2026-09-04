import AppKit
import XCTest
@testable import Nota

/// The arithmetic behind the strip, with no views in the way: one width for
/// everybody, the selected tab kept wide enough for its ✕, the + riding
/// after the last tab, and a sliding window once even the floor no longer
/// fits.
final class TabStripLayoutTests: XCTestCase {
    private let plusSize = TabStripLayout.plusSize
    private let reserve = TabStripLayout.trailingReserve
    private let controls = TabStripLayout.trailingControls
    private let bookmarkSlot = TabStripLayout.bookmarkSlot
    private let plusGap = TabStripLayout.plusGap
    private let spacing = TabStripLayout.spacing

    func testAFewTabsInAWideStripStayAtTheComfortableWidth() {
        let layout = TabStripLayout(count: 3, selectedIndex: 0, viewportWidth: 900)

        XCTAssertEqual(layout.widths, [180, 180, 180])
        XCTAssertEqual(layout.xs, [0, 184, 368])
        XCTAssertEqual(layout.visibleRange, 0..<3)
        XCTAssertEqual(layout.firstVisibleIndex, 0)
        // The + rides right after the third tab rather than sitting at the
        // trailing edge of a half-empty strip.
        XCTAssertEqual(layout.plusX, 368 + 180 + plusGap)
        XCTAssertLessThan(layout.plusX, 900 - controls - plusSize)
    }

    func testManyTabsShrinkEvenlyAndPinThePlusAtTheEdge() {
        let layout = TabStripLayout(count: 14, selectedIndex: 0, viewportWidth: 900)

        let inactive = layout.widths.dropFirst()
        for width in inactive {
            XCTAssertEqual(width, inactive.first!, accuracy: 0.001, "every tab shares one width")
            XCTAssertLessThan(width, TabStripLayout.maxTabWidth)
            XCTAssertGreaterThanOrEqual(width, TabStripLayout.minInactiveWidth)
        }
        XCTAssertEqual(layout.visibleRange, 0..<14, "shrinking, not scrolling: nothing is hidden")
        XCTAssertEqual(layout.plusX, 900 - controls - plusSize, accuracy: 0.001, "a full strip pins the + short of the trailing controls")

        // Everything, gaps and + included, lands inside the strip.
        let total = layout.widths.reduce(0, +) + spacing * 13
        XCTAssertLessThanOrEqual(total, 900 - plusSize - plusGap - controls + 0.001)
    }

    func testTheSelectedTabKeepsRoomForItsCloseButtonAndTheRestPayForIt() {
        let layout = TabStripLayout(count: 14, selectedIndex: 5, viewportWidth: 900)

        XCTAssertEqual(layout.widths[5], TabStripLayout.minActiveWidth, accuracy: 0.001)
        let others = layout.widths.enumerated().filter { $0.offset != 5 }.map(\.element)
        for width in others {
            XCTAssertEqual(width, others[0], accuracy: 0.001)
            XCTAssertLessThan(width, layout.widths[5], "the others shrank to pay for it")
            XCTAssertGreaterThanOrEqual(width, TabStripLayout.minInactiveWidth)
        }
        let total = layout.widths.reduce(0, +) + spacing * 13
        XCTAssertLessThanOrEqual(total, 900 - plusSize - plusGap - controls + 0.001, "the raise did not overflow")
    }

    func testPastTheFloorTheStripBecomesASlidingWindowAroundTheSelectedTab() {
        let layout = TabStripLayout(count: 40, selectedIndex: 30, viewportWidth: 600)

        for (index, width) in layout.widths.enumerated() {
            XCTAssertEqual(
                width,
                index == 30 ? TabStripLayout.minActiveWidth : TabStripLayout.minInactiveWidth,
                accuracy: 0.001,
                "at the floor nothing shrinks further"
            )
        }
        XCTAssertTrue(layout.visibleRange.contains(30), "the selected tab is always in the window")
        XCTAssertLessThan(layout.visibleRange.count, 40, "the rest are hidden, not squeezed")
        XCTAssertGreaterThan(layout.firstVisibleIndex, 0)

        // Every visible tab is inside the strip, and the + is beyond the last.
        for index in layout.visibleRange {
            XCTAssertGreaterThanOrEqual(layout.xs[index], -0.001)
            XCTAssertLessThanOrEqual(layout.xs[index] + layout.widths[index], layout.plusX + 0.001)
        }
    }

    func testTheWindowStaysPutWhileTheSelectionMovesInsideItAndSlidesWhenItLeaves() {
        let first = TabStripLayout(count: 40, selectedIndex: 20, viewportWidth: 600)
        XCTAssertTrue(first.visibleRange.contains(20))
        XCTAssertGreaterThan(first.firstVisibleIndex, 0)

        // Selecting a neighbour that is already on screen must not make the
        // whole strip jump.
        let nearby = TabStripLayout(
            count: 40, selectedIndex: 15, viewportWidth: 600,
            previousFirstVisibleIndex: first.firstVisibleIndex
        )
        XCTAssertEqual(nearby.firstVisibleIndex, first.firstVisibleIndex)
        XCTAssertTrue(nearby.visibleRange.contains(15))

        // Selecting one past the end slides the window along.
        let far = TabStripLayout(
            count: 40, selectedIndex: 39, viewportWidth: 600,
            previousFirstVisibleIndex: first.firstVisibleIndex
        )
        XCTAssertGreaterThan(far.firstVisibleIndex, first.firstVisibleIndex)
        XCTAssertTrue(far.visibleRange.contains(39))

        // And back the other way.
        let leading = TabStripLayout(
            count: 40, selectedIndex: 0, viewportWidth: 600,
            previousFirstVisibleIndex: far.firstVisibleIndex
        )
        XCTAssertEqual(leading.firstVisibleIndex, 0)
        XCTAssertTrue(leading.visibleRange.contains(0))
    }

    /// The widths a close froze are placed by the same rules, with the +
    /// held where it was.
    func testFrozenWidthsArePlacedUnchangedWithThePlusHeldStill() {
        let layout = TabStripLayout(
            widths: [140, 140, 140], firstVisibleIndex: 0, plusX: 576, viewportWidth: 600
        )

        XCTAssertEqual(layout.widths, [140, 140, 140])
        XCTAssertEqual(layout.xs, [0, 144, 288])
        XCTAssertEqual(layout.plusX, 576, "the + does not close up the gap either")
        XCTAssertEqual(layout.visibleRange, 0..<3)
    }

    // MARK: - The bookmark button's slot (SPEC Todo 13)

    /// The bookmark button pins at the trailing edge, and the + steps left by
    /// exactly the slot it takes — nothing overlaps and nothing is
    /// subtracted twice.
    func testTheBookmarkButtonTakesASlotAndThePlusMovesLeftByIt() {
        let layout = TabStripLayout(count: 14, selectedIndex: 0, viewportWidth: 900)

        XCTAssertEqual(TabStripLayout.bookmarkX(900), 900 - reserve - bookmarkSlot,
                       "the bookmark button pins inside the reserve")
        XCTAssertEqual(layout.plusX, TabStripLayout.bookmarkX(900) - plusGap - plusSize,
                       accuracy: 0.001, "the + sits one gap to the left of it")
        XCTAssertEqual(controls, bookmarkSlot + TabStripLayout.bookmarkGap + reserve)

        // The room the tabs get shrank by the slot and its gap, and by
        // nothing else.
        XCTAssertEqual(
            TabStripLayout.tabsWidth(900),
            900 - plusSize - plusGap - bookmarkSlot - TabStripLayout.bookmarkGap - reserve,
            accuracy: 0.001
        )
        let total = layout.widths.reduce(0, +) + spacing * 13
        XCTAssertLessThanOrEqual(total, layout.plusX + 0.001, "the tabs stop short of the +")
    }

    /// A strip too narrow to hold anything still hands back sane numbers
    /// rather than negative ones.
    func testAVeryNarrowStripKeepsBothButtonsOnIt() {
        XCTAssertEqual(TabStripLayout.bookmarkX(20), 0)
        let layout = TabStripLayout(count: 3, selectedIndex: 0, viewportWidth: 20)
        XCTAssertGreaterThanOrEqual(layout.plusX, 0)
    }
}
