import CoreGraphics

/// Where every tab and the + button sit in the strip, worked out from the
/// counts and the room available alone — no views, so the whole rule is
/// unit-testable on its own.
///
/// The shape is Chromium's: one width for every tab, shrinking as tabs are
/// added rather than scrolling, with the selected tab held wide enough to
/// keep its ✕. Once even the floor no longer fits, the strip becomes a
/// sliding window over the tabs instead of squeezing them into slivers.
struct TabStripLayout {
    /// A comfortable tab, and the two floors: an inactive tab may shrink to
    /// icon-plus-a-sliver, the selected one keeps room for its ✕.
    static let maxTabWidth: CGFloat = 180
    static let minInactiveWidth: CGFloat = 40
    static let minActiveWidth: CGFloat = 60
    static let spacing: CGFloat = 4
    static let plusSize: CGFloat = 24
    static let plusGap: CGFloat = 4
    /// Room kept empty past the +, so it never reaches the strip's end.
    /// Brave keeps a tab-search chevron there; Nota keeps it clear for now.
    static let trailingReserve: CGFloat = 40

    /// One width per tab, indexed like the items.
    let widths: [CGFloat]
    /// Leading x of each tab. Tabs before the window are negative; tabs past
    /// its end run off the trailing edge. Both are outside `visibleRange`.
    let xs: [CGFloat]
    /// Leading x of the + button: right after the last visible tab, pinned at
    /// the trailing edge once the strip is full.
    let plusX: CGFloat
    let firstVisibleIndex: Int
    /// The tabs actually on screen. Always contains the selected one.
    let visibleRange: Range<Int>

    /// - Parameter previousFirstVisibleIndex: where the window sat last time,
    ///   kept if the selected tab is still inside it so that selecting a
    ///   neighbour does not make the whole strip jump.
    init(
        count: Int,
        selectedIndex: Int,
        viewportWidth: CGFloat,
        previousFirstVisibleIndex: Int = 0
    ) {
        let widths = Self.tabWidths(
            count: count, selectedIndex: selectedIndex, viewportWidth: viewportWidth
        )
        let first = Self.windowStart(
            widths: widths,
            selectedIndex: selectedIndex,
            viewportWidth: viewportWidth,
            previous: previousFirstVisibleIndex
        )
        self.init(
            widths: widths,
            firstVisibleIndex: first,
            viewportWidth: viewportWidth,
            frozenPlusX: nil
        )
    }

    /// Widths that were decided earlier — the close freeze — placed by the
    /// same rules, with the + held exactly where it was.
    init(
        widths: [CGFloat],
        firstVisibleIndex: Int,
        plusX: CGFloat,
        viewportWidth: CGFloat
    ) {
        self.init(
            widths: widths,
            firstVisibleIndex: firstVisibleIndex,
            viewportWidth: viewportWidth,
            frozenPlusX: plusX
        )
    }

    private init(
        widths: [CGFloat],
        firstVisibleIndex: Int,
        viewportWidth: CGFloat,
        frozenPlusX: CGFloat?
    ) {
        let count = widths.count
        guard count > 0 else {
            self.widths = []
            self.xs = []
            self.plusX = frozenPlusX ?? 0
            self.firstVisibleIndex = 0
            self.visibleRange = 0..<0
            return
        }

        let first = min(max(firstVisibleIndex, 0), count - 1)
        let last = Self.lastVisible(widths: widths, from: first, viewportWidth: viewportWidth)

        var prefix: [CGFloat] = []
        var running: CGFloat = 0
        for width in widths {
            prefix.append(running)
            running += width + Self.spacing
        }
        let origin = prefix[first]

        self.widths = widths
        self.xs = prefix.map { $0 - origin }
        self.firstVisibleIndex = first
        self.visibleRange = first..<(last + 1)
        self.plusX = frozenPlusX ?? min(
            self.xs[last] + widths[last] + Self.plusGap,
            max(0, viewportWidth - Self.trailingReserve - Self.plusSize)
        )
    }

    /// Room the tabs themselves may use: the strip minus the +, its gap, and
    /// the reserve past it.
    static func tabsWidth(_ viewportWidth: CGFloat) -> CGFloat {
        max(0, viewportWidth - plusSize - plusGap - trailingReserve)
    }

    /// One width for everybody, shrinking with the count; the selected tab is
    /// then raised to `minActiveWidth` and the others shrink evenly to pay
    /// for it, never past `minInactiveWidth`.
    private static func tabWidths(
        count: Int, selectedIndex: Int, viewportWidth: CGFloat
    ) -> [CGFloat] {
        guard count > 0 else { return [] }
        let available = tabsWidth(viewportWidth) - spacing * CGFloat(count - 1)
        let base = min(max(available / CGFloat(count), minInactiveWidth), maxTabWidth)
        let active = max(base, minActiveWidth)
        var inactive = base
        if count > 1, active > base {
            inactive = max(minInactiveWidth, base - (active - base) / CGFloat(count - 1))
        }
        var widths = [CGFloat](repeating: inactive, count: count)
        widths[min(max(selectedIndex, 0), count - 1)] = active
        return widths
    }

    /// How far a run starting at `first` reaches before it runs out of room.
    /// Always at least the tab it starts on, so a window that begins on the
    /// selected tab never hides it.
    private static func lastVisible(
        widths: [CGFloat], from first: Int, viewportWidth: CGFloat
    ) -> Int {
        let room = tabsWidth(viewportWidth)
        var x: CGFloat = 0
        var last = first
        for index in first..<widths.count {
            if index > first, x + widths[index] > room + 0.01 { break }
            last = index
            x += widths[index] + spacing
        }
        return last
    }

    /// Keeps the window where it was when that still shows the selected tab,
    /// and slides it by the least that brings the selection back in.
    private static func windowStart(
        widths: [CGFloat], selectedIndex: Int, viewportWidth: CGFloat, previous: Int
    ) -> Int {
        let count = widths.count
        guard count > 0 else { return 0 }
        let selected = min(max(selectedIndex, 0), count - 1)

        // Never start so late that the strip grows empty space at its
        // trailing edge: this is the last start that still shows the end.
        var maxFirst = count - 1
        while maxFirst > 0,
              lastVisible(widths: widths, from: maxFirst - 1, viewportWidth: viewportWidth) == count - 1 {
            maxFirst -= 1
        }

        var first = min(max(previous, 0), maxFirst)
        if selected < first { first = selected }
        while first < count - 1,
              selected > lastVisible(widths: widths, from: first, viewportWidth: viewportWidth) {
            first += 1
        }
        return first
    }
}
