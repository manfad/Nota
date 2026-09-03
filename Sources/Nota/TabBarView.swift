import AppKit

struct TabBarItem {
    var title: String
    var isDirty: Bool
}

protocol TabBarViewDelegate: AnyObject {
    func tabBar(_ bar: TabBarView, didSelect index: Int)
    func tabBar(_ bar: TabBarView, didRequestCloseAt index: Int)
    func tabBarDidRequestNewTab(_ bar: TabBarView)
    func tabBar(_ bar: TabBarView, didMove index: Int, to newIndex: Int)
}

/// The strip of tabs that sits in the title bar next to the traffic lights.
/// Tabs keep a comfortable width until they run out of room, then shrink
/// evenly down to a floor past that; they also reorder by dragging along
/// the strip.
final class TabBarView: NSView {
    weak var delegate: TabBarViewDelegate?

    /// Tabs are clipped to the strip rather than spilling over the window.
    override var clipsToBounds: Bool {
        get { true }
        set { _ = newValue }
    }

    static let height: CGFloat = 34

    private static let tabHeight: CGFloat = 24
    private static let spacing: CGFloat = 4
    private static let newTabButtonSize: CGFloat = 24
    private static let idealMaxWidth: CGFloat = 180
    private static let idealMinWidth: CGFloat = 110
    /// Tabs stop shrinking here; past it the strip scrolls instead.
    private static let minimumReadableWidth: CGFloat = 110

    /// Drag-to-reorder tuning: how raised the dragged tab looks, how long a
    /// slide/settle animation takes, the hot zone at either end of the
    /// viewport that auto-scrolls, and how far each auto-scroll tick moves
    /// the strip. The move-vs-click threshold itself lives on `TabItemView`,
    /// the only place that needs it.
    private static let draggedTabAlpha: CGFloat = 0.9
    private static let dragAnimationDuration: TimeInterval = 0.12
    /// Keeps a tab from flickering between two slots when the pointer rests
    /// directly on their boundary.
    private static let dragSlotHysteresis: CGFloat = 4
    private static let autoScrollEdge: CGFloat = 24
    private static let autoScrollStep: CGFloat = 6
    private static let autoScrollInterval: TimeInterval = 0.02

    private var items: [TabBarItem] = []
    private var selectedIndex = 0
    private var itemViews: [TabItemView] = []
    private let newTabButton = NewTabButton()

    /// How far the strip is scrolled when the tabs do not all fit.
    private var scrollOffset: CGFloat = 0

    /// Re-anchoring the selected tab happens on selection change and on
    /// viewport resize, but not on a manual trackpad scroll — these track
    /// what `layout()` last saw so it can tell which case it is in.
    private var lastViewportWidth: CGFloat?
    private var lastAnchoredSelectedIndex: Int?
    private var needsSelectedTabReveal = true

    /// State for a tab currently being dragged along the strip. `nil` when
    /// nothing is being dragged.
    private struct DragSession {
        /// Index of the dragged tab in `items`/`itemViews` — never changes
        /// during the drag; only its visual slot does.
        let originalIndex: Int
        /// Where `originalIndex` currently sits in `visualOrder`.
        var currentSlot: Int
        /// Display order as the drag has rearranged it so far, as a
        /// permutation of `items` indices. Never written back to `items` —
        /// the delegate is told the final slot and owns the real reorder.
        var visualOrder: [Int]
        /// Readable widths snapshot at drag start, indexed like `items`.
        let widths: [CGFloat]
        let startPointerX: CGFloat
        let startViewX: CGFloat
        var lastPointerX: CGFloat
    }

    private var dragSession: DragSession?
    private var dragAutoScrollTimer: Timer?
    private var dragEscMonitor: Any?

    /// Empty strip is title-bar background, so dragging it moves the window.
    override var mouseDownCanMoveWindow: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        newTabButton.target = self
        newTabButton.action = #selector(requestNewTab)
        addSubview(newTabButton)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Double-clicking the empty strip behaves like double-clicking a title bar,
    /// honouring System Settings ▸ Desktop & Dock ▸ "Double-click a window's title bar to".
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2, let window else { return super.mouseDown(with: event) }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize" {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }

    func setItems(_ items: [TabBarItem], selectedIndex: Int) {
        // A tab closing (⌘W) or opening mid-drag changes the item count out
        // from under `dragSession.visualOrder`, which is a permutation of
        // indices sized for the old count — stale indices into it would be
        // a crash waiting to happen, so the drag is simply abandoned first.
        if dragSession != nil, items.count != itemViews.count {
            cancelDrag()
        }
        self.items = items
        self.selectedIndex = selectedIndex
        // A pushed item list can change what is selected without changing
        // the numeric index (e.g. a drag that shuffles tabs around the
        // selected one) — always double-check visibility on the next pass.
        needsSelectedTabReveal = true
        rebuild()
    }

    /// Trackpad and shift-wheel scrolling along the strip.
    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX
            : event.scrollingDeltaY
        guard delta != 0, contentWidth > tabsViewportWidth else {
            super.scrollWheel(with: event)
            return
        }
        setScrollOffset(scrollOffset - delta)
    }

    private func setScrollOffset(_ value: CGFloat) {
        let clamped = min(max(0, value), max(0, contentWidth - tabsViewportWidth))
        guard clamped != scrollOffset else { return }
        scrollOffset = clamped
        needsLayout = true
    }

    /// Room the tabs may occupy: the strip minus the pinned + and its gap.
    private var tabsViewportWidth: CGFloat {
        max(0, bounds.width - Self.newTabButtonSize - Self.spacing)
    }

    /// Total width the tabs want at their readable size.
    private var contentWidth: CGFloat {
        guard !items.isEmpty else { return 0 }
        let widths = items.map(Self.readableWidth)
        return widths.reduce(0, +) + Self.spacing * CGFloat(items.count - 1)
    }

    private static func readableWidth(_ item: TabBarItem) -> CGFloat {
        min(max(TabItemView.idealWidth(for: item), idealMinWidth), idealMaxWidth)
    }

    /// Forces the next layout pass to re-anchor the selected tab, even if
    /// neither the selection nor the viewport width has changed since the
    /// last layout. Existing callers that expect an explicit nudge (e.g.
    /// after `setItems`) keep working; the re-anchor itself now happens
    /// synchronously inside `layout()`.
    func scrollSelectedTabIntoView() {
        needsSelectedTabReveal = true
        needsLayout = true
    }

    /// Test hook: whether the selected tab is on-screen, unhidden, and
    /// entirely within the tabs viewport (never under the + button).
    internal func isSelectedTabFullyVisible() -> Bool {
        guard itemViews.indices.contains(selectedIndex) else { return false }
        let view = itemViews[selectedIndex]
        guard !view.isHidden else { return false }
        let frame = view.frame
        return frame.minX >= 0 && frame.maxX <= tabsViewportWidth
    }

    /// Test hook: the titles in their current display order.
    internal var titlesForTesting: [String] { items.map(\.title) }

    /// Test hook: starts a drag on `index`, as if the pointer had just
    /// crossed the threshold there, without going through mouse events.
    internal func beginDragForTesting(index: Int) {
        guard itemViews.indices.contains(index) else { return }
        let view = itemViews[index]
        beginDrag(for: view, pointerX: view.frame.midX)
    }

    /// Test hook: the dragged tab's current x, or `nil` when nothing is
    /// being dragged.
    internal var draggedTabXForTesting: CGFloat? {
        guard let session = dragSession else { return nil }
        return itemViews[session.originalIndex].frame.minX
    }

    /// Test hook: advances the active drag in the same coordinate space as
    /// `TabItemView`'s real mouse events.
    internal func updateDragForTesting(pointerX: CGFloat) {
        guard let session = dragSession else { return }
        updateDrag(for: itemViews[session.originalIndex], pointerX: pointerX)
    }

    /// Test hook: the slot the dragged tab would occupy if dropped now.
    internal var draggedTabSlotForTesting: Int? { dragSession?.currentSlot }

    /// Test hook: performs the delegate call a completed drag would make —
    /// `index` moved to `newIndex` — without going through mouse events or
    /// the slide/settle animations. The delegate owns the actual reorder
    /// (see `MainWindowController.moveTab`); this only exercises that the
    /// strip reports moves correctly.
    internal func moveTabForTesting(from index: Int, to newIndex: Int) {
        guard itemViews.indices.contains(index), itemViews.indices.contains(newIndex),
              index != newIndex else { return }
        delegate?.tabBar(self, didMove: index, to: newIndex)
    }

    private func rebuild() {
        while itemViews.count > items.count {
            itemViews.removeLast().removeFromSuperview()
        }
        while itemViews.count < items.count {
            let view = TabItemView()
            view.onSelect = { [weak self] tab in self?.select(tab) }
            view.onClose = { [weak self] tab in self?.close(tab) }
            view.onDragStart = { [weak self] tab, pointerX in self?.beginDrag(for: tab, pointerX: pointerX) }
            view.onDragMove = { [weak self] tab, pointerX in self?.updateDrag(for: tab, pointerX: pointerX) }
            view.onDragEnd = { [weak self] tab, committed in self?.endDrag(for: tab, committed: committed) }
            addSubview(view, positioned: .below, relativeTo: newTabButton)
            itemViews.append(view)
        }
        for (index, item) in items.enumerated() {
            itemViews[index].configure(item, isSelected: index == selectedIndex)
        }
        needsLayout = true
    }

    @objc private func requestNewTab() {
        delegate?.tabBarDidRequestNewTab(self)
    }

    private func select(_ view: TabItemView) {
        guard let index = itemViews.firstIndex(of: view) else { return }
        delegate?.tabBar(self, didSelect: index)
    }

    private func close(_ view: TabItemView) {
        guard let index = itemViews.firstIndex(of: view) else { return }
        delegate?.tabBar(self, didRequestCloseAt: index)
    }

    // MARK: - Drag to reorder

    private func beginDrag(for view: TabItemView, pointerX: CGFloat) {
        guard dragSession == nil, let index = itemViews.firstIndex(of: view) else { return }
        dragSession = DragSession(
            originalIndex: index,
            currentSlot: index,
            visualOrder: Array(itemViews.indices),
            widths: items.map(Self.readableWidth),
            startPointerX: pointerX,
            startViewX: view.frame.minX,
            lastPointerX: pointerX
        )
        // Above every sibling while it rides the pointer, and a touch
        // translucent so it reads as lifted off the strip.
        addSubview(view, positioned: .above, relativeTo: nil)
        view.alphaValue = Self.draggedTabAlpha
        startEscMonitor()
    }

    private func updateDrag(for view: TabItemView, pointerX: CGFloat) {
        guard dragSession != nil else { return }
        dragSession?.lastPointerX = pointerX
        updateDragPositions(pointerX: pointerX)
        updateAutoScroll(pointerX: pointerX)
    }

    /// Moves the tab one-to-one with the pointer, then snaps the gap to the
    /// nearest insertion slot. This is how browser tab strips behave: the
    /// possible resting places are fixed, and their halfway points are the
    /// reorder boundaries. It stays predictable with mixed tab widths and
    /// also lets a quick gesture skip several tabs in one event.
    private func updateDragPositions(pointerX: CGFloat) {
        guard var session = dragSession, itemViews.indices.contains(session.originalIndex) else { return }
        let viewport = tabsViewportWidth
        let widths = session.widths
        let draggedWidth = widths[session.originalIndex]
        let proposedX = session.startViewX + (pointerX - session.startPointerX)
        let clampedX = min(max(0, proposedX), max(0, viewport - draggedWidth))

        let draggedView = itemViews[session.originalIndex]
        var draggedFrame = draggedView.frame
        draggedFrame.origin.x = clampedX
        draggedView.frame = draggedFrame

        let draggedCenter = clampedX + draggedWidth / 2
        let siblings = session.visualOrder.filter { $0 != session.originalIndex }

        // The centre the dragged tab would have in each possible resting
        // slot. Adjacent centres define a natural halfway reorder boundary.
        var candidateCenters: [CGFloat] = []
        var x = -scrollOffset
        for slot in 0...siblings.count {
            candidateCenters.append(x + draggedWidth / 2)
            if slot < siblings.count {
                x += widths[siblings[slot]] + Self.spacing
            }
        }

        let nearestSlot = candidateCenters.indices.min {
            abs(draggedCenter - candidateCenters[$0])
                < abs(draggedCenter - candidateCenters[$1])
        } ?? session.currentSlot
        let currentDistance = abs(draggedCenter - candidateCenters[session.currentSlot])
        let nearestDistance = abs(draggedCenter - candidateCenters[nearestSlot])

        // A few points of hysteresis make the gap stay put under a resting
        // pointer instead of rapidly swapping back and forth on a boundary.
        if nearestSlot != session.currentSlot,
           nearestDistance + Self.dragSlotHysteresis < currentDistance {
            var newOrder = siblings
            newOrder.insert(session.originalIndex, at: nearestSlot)
            session.currentSlot = nearestSlot
            session.visualOrder = newOrder

            var siblingX = -scrollOffset
            for originalIndex in newOrder {
                if originalIndex != session.originalIndex {
                    animateSibling(itemViews[originalIndex], to: siblingX)
                }
                siblingX += widths[originalIndex] + Self.spacing
            }
        }

        dragSession = session
    }

    /// Starts, adjusts, or stops the auto-scroll timer for how close the
    /// pointer is sitting to either edge of the viewport.
    private func updateAutoScroll(pointerX: CGFloat) {
        guard let session = dragSession else { return stopAutoScroll() }
        let viewport = tabsViewportWidth
        let total = session.widths.reduce(0, +) + Self.spacing * CGFloat(max(0, session.widths.count - 1))
        let canScroll = total > viewport
        let direction: CGFloat
        if canScroll, pointerX < Self.autoScrollEdge {
            direction = -1
        } else if canScroll, pointerX > viewport - Self.autoScrollEdge {
            direction = 1
        } else {
            direction = 0
        }
        guard direction != 0 else { return stopAutoScroll() }
        guard dragAutoScrollTimer == nil else { return }
        let timer = Timer(timeInterval: Self.autoScrollInterval, repeats: true) { [weak self] timer in
            guard let self, self.dragAutoScrollTimer === timer, let session = self.dragSession else {
                return timer.invalidate()
            }
            let viewport = self.tabsViewportWidth
            let total = session.widths.reduce(0, +) + Self.spacing * CGFloat(max(0, session.widths.count - 1))
            self.scrollOffset = min(max(0, self.scrollOffset + direction * Self.autoScrollStep),
                                    max(0, total - viewport))
            self.repositionSiblingsDuringDrag(session: session)
            self.updateDragPositions(pointerX: session.lastPointerX)
        }
        RunLoop.main.add(timer, forMode: .common)
        dragAutoScrollTimer = timer
    }

    private func stopAutoScroll() {
        dragAutoScrollTimer?.invalidate()
        dragAutoScrollTimer = nil
    }

    /// Snaps every non-dragged tab to its current slot as the strip
    /// auto-scrolls under the pointer — a continuous scroll, not a slide,
    /// so it is not animated.
    private func repositionSiblingsDuringDrag(session: DragSession) {
        var x = -scrollOffset
        for slot in session.visualOrder {
            if slot != session.originalIndex {
                var frame = itemViews[slot].frame
                frame.origin.x = x
                itemViews[slot].frame = frame
            }
            x += session.widths[slot] + Self.spacing
        }
    }

    /// The drag-aware half of `layout()`: places the + button's already
    /// done by the caller, `scrollOffset` is clamped the same as always, but
    /// positions come from the session rather than `items`' plain order —
    /// the dragged tab is left exactly where the drag last put it (and is
    /// never hidden), while its siblings go to their current `visualOrder`
    /// slot, the same math `repositionSiblingsDuringDrag` already uses for
    /// an auto-scroll tick.
    private func layoutDuringDrag(_ session: DragSession) {
        let viewport = tabsViewportWidth
        let total = session.widths.reduce(0, +) + Self.spacing * CGFloat(max(0, session.widths.count - 1))
        scrollOffset = min(max(0, scrollOffset), max(0, total - viewport))

        repositionSiblingsDuringDrag(session: session)

        var x: CGFloat = -scrollOffset
        for slot in session.visualOrder {
            let width = session.widths[slot]
            if slot == session.originalIndex {
                itemViews[slot].isHidden = false
            } else {
                itemViews[slot].isHidden = x + width < 0 || x >= viewport || x + width > viewport
            }
            x += width + Self.spacing
        }
    }

    private func endDrag(for view: TabItemView, committed: Bool) {
        guard let session = dragSession else { return }
        stopAutoScroll()
        stopEscMonitor()
        dragSession = nil

        if committed, session.currentSlot != session.originalIndex {
            let targetX = slotX(session.currentSlot, order: session.visualOrder, widths: session.widths)
                - scrollOffset
            settle(view, to: targetX) { [weak self] in
                guard let self else { return }
                view.alphaValue = 1
                self.restoreSubviewOrdering()
                self.delegate?.tabBar(self, didMove: session.originalIndex, to: session.currentSlot)
            }
        } else {
            // Nothing moved, or Esc cancelled it: every tab that slid
            // during the drag animates back to where it started.
            let identityOrder = Array(itemViews.indices)
            for index in identityOrder {
                let targetX = slotX(index, order: identityOrder, widths: session.widths) - scrollOffset
                settle(itemViews[index], to: targetX, completion: index == session.originalIndex ? {
                    view.alphaValue = 1
                } : nil)
            }
            restoreSubviewOrdering()
        }
    }

    private func cancelDrag() {
        guard let session = dragSession else { return }
        endDrag(for: itemViews[session.originalIndex], committed: false)
    }

    /// Sum of the widths (plus spacing) of every tab before `slot` in
    /// `order` — the slot's un-scrolled x offset.
    private func slotX(_ slot: Int, order: [Int], widths: [CGFloat]) -> CGFloat {
        var x: CGFloat = 0
        for i in 0..<slot { x += widths[order[i]] + Self.spacing }
        return x
    }

    /// Animates a sibling sliding into the gap the dragged tab left —
    /// short, and skipped under Reduce Motion.
    private func animateSibling(_ view: NSView, to x: CGFloat) {
        settle(view, to: x, completion: nil)
    }

    private func settle(_ view: NSView, to x: CGFloat, completion: (() -> Void)?) {
        var frame = view.frame
        frame.origin.x = x
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            view.frame = frame
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.dragAnimationDuration
            view.animator().frame = frame
        }, completionHandler: completion)
    }

    /// Restores the strip's normal subview stacking (tabs in index order,
    /// all below the +) after a drag has brought one tab to the front.
    private func restoreSubviewOrdering() {
        for view in itemViews {
            addSubview(view, positioned: .below, relativeTo: newTabButton)
        }
    }

    /// Covers a drag that did not come from `TabItemView.mouseDown` — the
    /// test hook, in practice. A real drag runs inside that view's tracking
    /// loop, where local monitors are never called, so the loop handles Esc
    /// itself.
    private func startEscMonitor() {
        stopEscMonitor()
        dragEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.dragSession != nil else { return event }
            guard event.keyCode == 53 else { return event } // Esc
            self.cancelDrag()
            return nil
        }
    }

    private func stopEscMonitor() {
        if let dragEscMonitor { NSEvent.removeMonitor(dragEscMonitor) }
        dragEscMonitor = nil
    }

    override func layout() {
        super.layout()

        let plusSize = Self.newTabButtonSize
        newTabButton.frame = NSRect(
            x: bounds.width - plusSize,
            y: (bounds.height - plusSize) / 2,
            width: plusSize,
            height: plusSize
        )

        guard !itemViews.isEmpty else { return }

        // A drag owns the strip's positions while it is underway: the
        // dragged tab rides the pointer and its siblings sit at their
        // `visualOrder` slot. A layout arriving mid-drag — a resize, a
        // dirty-dot refresh from `setItems`, an autosave tick — must not
        // fight that by resetting every frame back to `items`' plain order,
        // which would yank the dragged tab out from under the pointer.
        if let session = dragSession {
            layoutDuringDrag(session)
            return
        }

        // Tabs never shrink below a readable width; once they no longer fit,
        // the strip scrolls rather than squeezing them into slivers. The +
        // stays pinned at the trailing edge, so they only use the leading
        // remainder — a tab that would sit under the + is hidden instead.
        let viewport = tabsViewportWidth
        let widths = items.map(Self.readableWidth)
        let total = widths.reduce(0, +) + Self.spacing * CGFloat(itemViews.count - 1)
        if total <= viewport { scrollOffset = 0 }
        scrollOffset = min(scrollOffset, max(0, total - viewport))

        // Re-anchor the selected tab whenever the selection changed or the
        // viewport was resized since the last layout — but not on a manual
        // trackpad scroll, which is allowed to move it out of view. This
        // runs before positioning the views so it can adjust `scrollOffset`
        // in one pass, with no async round trip.
        let selectionChanged = selectedIndex != lastAnchoredSelectedIndex
        let viewportChanged = viewport != lastViewportWidth
        if (selectionChanged || viewportChanged || needsSelectedTabReveal),
           itemViews.indices.contains(selectedIndex) {
            let selectedX = widths[0..<selectedIndex].reduce(0, +)
                + Self.spacing * CGFloat(selectedIndex)
            let selectedWidth = widths[selectedIndex]
            let frameMinX = selectedX - scrollOffset
            let frameMaxX = frameMinX + selectedWidth
            if frameMaxX > viewport {
                scrollOffset += frameMaxX - viewport
            } else if frameMinX < 0 {
                scrollOffset += frameMinX
            }
            scrollOffset = min(max(0, scrollOffset), max(0, total - viewport))
        }
        lastAnchoredSelectedIndex = selectedIndex
        lastViewportWidth = viewport
        needsSelectedTabReveal = false

        let y = (bounds.height - Self.tabHeight) / 2
        var x = -scrollOffset
        for (index, view) in itemViews.enumerated() {
            view.frame = NSRect(x: x, y: y, width: widths[index], height: Self.tabHeight)
            // Tabs scrolled off the edge should not be clickable, and a tab
            // that would cross the + slot is not shown there either — except
            // the selected tab, which the re-anchoring above always keeps
            // fully inside the viewport.
            view.isHidden = index != selectedIndex
                && (x + widths[index] < 0 || x >= viewport || x + widths[index] > viewport)
            x += widths[index] + Self.spacing
        }
    }
}

/// Trailing control on the tab strip. Same density as a tab (24pt), not an
/// iOS-sized hit target; the + never scrolls away with the tabs.
final class NewTabButton: NSButton {
    private var hoverArea: NSTrackingArea?
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")?
            .withSymbolConfiguration(config)
        isBordered = false
        bezelStyle = .inline
        imagePosition = .imageOnly
        contentTintColor = .secondaryLabelColor
        toolTip = "New Tab  ⌘T"
        setAccessibilityLabel("New Tab")
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered || isHighlighted {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.08 : 0.04).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
    }
}

// MARK: - One tab

/// A tab in the Safari/Xcode shape: a soft rounded fill when selected, the
/// title, and a single 16pt slot at the trailing edge.
///
/// The slot is always reserved, so a tab never changes width when it is
/// selected or hovered. It holds two stacked layers — the unsaved dot and the
/// close button — which cross-fade as the pointer arrives and leaves.
private final class TabItemView: NSView {
    var onSelect: ((TabItemView) -> Void)?
    var onClose: ((TabItemView) -> Void)?
    /// Fired once when the press turns into a drag, with the *original*
    /// mouse-down x in the tab bar's coordinates. Keeping that grab point
    /// prevents the tab from lagging behind the pointer by the activation
    /// threshold. It arrives from inside `mouseDown`'s tracking loop, after
    /// the tab has already been selected.
    var onDragStart: ((TabItemView, CGFloat) -> Void)?
    /// Fired on every subsequent drag, same coordinate space.
    var onDragMove: ((TabItemView, CGFloat) -> Void)?
    /// Fired once a drag was underway and has finished: `committed` is
    /// `true` on mouse-up, `false` when Esc abandoned it mid-gesture.
    var onDragEnd: ((TabItemView, Bool) -> Void)?

    private static let font = NSFont.systemFont(ofSize: 12)
    private static let horizontalPadding: CGFloat = 10
    private static let slotSize: CGFloat = 16
    private static let slotTrailingPadding: CGFloat = 6
    private static let titleSlotGap: CGFloat = 4
    private static let crossFadeDuration: TimeInterval = 0.12
    private static let dragThreshold: CGFloat = 3

    private var title = ""
    private var isDirty = false
    private var isSelected = false
    private var isHovered = false
    private var isHoveringClose = false
    private var dragTrackingStart: NSPoint?
    private var isDraggingTab = false

    private let dotView = DirtyDotView()
    private let closeButton = TabCloseButton()
    private var hoverArea: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        dotView.alphaValue = 0
        addSubview(dotView)

        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")?
            .withSymbolConfiguration(config)
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.alphaValue = 0
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.onHoverChange = { [weak self] hovering in
            guard let self, self.isHoveringClose != hovering else { return }
            self.isHoveringClose = hovering
            self.needsDisplay = true
        }
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Independent of selection and hover — the slot is always accounted for.
    static func idealWidth(for item: TabBarItem) -> CGFloat {
        let titleWidth = (item.title as NSString).size(withAttributes: [.font: font]).width
        return horizontalPadding * 2 + titleWidth + slotSize
    }

    func configure(_ item: TabBarItem, isSelected: Bool) {
        title = item.title
        isDirty = item.isDirty
        self.isSelected = isSelected
        toolTip = item.title
        updateSlot(animated: false)
        needsDisplay = true
        needsLayout = true
    }

    private var slotRect: NSRect {
        NSRect(
            x: bounds.maxX - Self.slotTrailingPadding - Self.slotSize,
            y: (bounds.height - Self.slotSize) / 2,
            width: Self.slotSize,
            height: Self.slotSize
        )
    }

    override func layout() {
        super.layout()
        dotView.frame = slotRect
        closeButton.frame = slotRect
    }

    /// Hovering swaps the dot for the ✕; a clean, unhovered tab shows neither.
    private func updateSlot(animated: Bool) {
        let dotAlpha: CGFloat = (isDirty && !isHovered) ? 1 : 0
        let closeAlpha: CGFloat = isHovered ? 1 : 0
        guard animated else {
            dotView.alphaValue = dotAlpha
            closeButton.alphaValue = closeAlpha
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.crossFadeDuration
            dotView.animator().alphaValue = dotAlpha
            closeButton.animator().alphaValue = closeAlpha
        }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateSlot(animated: true)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isHoveringClose = false
        updateSlot(animated: true)
        needsDisplay = true
    }

    /// The strip sits in the title-bar region, so a press while another app
    /// is frontmost is an activation click. Views refuse those by default,
    /// which leaves the press to the frame view, and a drag from there moves
    /// the window; the tab only gets the *next* press. Accepting first mouse
    /// delivers that first press here, so a tab in a background window can be
    /// selected and dragged in one go, as in Chromium and Safari.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Selects on the press, the way every browser tab strip does, and then
    /// runs the rest of the gesture itself.
    ///
    /// The loop is what makes one press both select and drag. Selecting a
    /// background tab rebuilds the editor hierarchy and the tab strip
    /// underneath the pointer, and AppKit's per-window routing of the
    /// following drag/up events does not survive that churn — they stop
    /// arriving here, so the press could only ever select and the user had
    /// to press a second time to drag. Dequeuing this gesture's own events
    /// directly means nothing can steal them. Local `NSEvent` monitors are
    /// not called inside a nested tracking loop, which is why Esc is
    /// handled in the loop rather than by the bar's monitor.
    override func mouseDown(with event: NSEvent) {
        dragTrackingStart = event.locationInWindow
        isDraggingTab = false
        onSelect?(self)

        // No window means no event queue to track — unit tests drive the
        // mouse methods directly on a bar that was never put in one.
        // Selection can also have removed this tab outright.
        guard superview != nil, window != nil else { return }

        while let window = self.window,
              let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown],
                                          until: .distantFuture,
                                          inMode: .eventTracking,
                                          dequeue: true) {
            switch next.type {
            case .leftMouseDragged:
                mouseDragged(with: next)
            case .leftMouseUp:
                mouseUp(with: next)
                return
            case .keyDown:
                // Esc abandons a drag in progress, but the button is still
                // down: keep dequeuing until it comes up. Every other key is
                // swallowed for the duration of the gesture.
                guard next.keyCode == 53 else { break }
                let wasDragging = isDraggingTab
                isDraggingTab = false
                dragTrackingStart = nil
                if wasDragging { onDragEnd?(self, false) }
            default:
                break
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragTrackingStart else { return }
        let location = event.locationInWindow
        if !isDraggingTab {
            // Count the user's actual pointer travel. Looking only at x made
            // a natural, slightly diagonal gesture take longer to engage.
            guard hypot(location.x - start.x, location.y - start.y) >= Self.dragThreshold else {
                return
            }
            isDraggingTab = true
            // The grab point, not the current location: the tab must not
            // jump forward by the threshold the moment it lifts off.
            if let grabX = superview?.convert(start, from: nil).x {
                onDragStart?(self, grabX)
            }
        }
        if let barX = superview?.convert(location, from: nil).x {
            onDragMove?(self, barX)
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragTrackingStart = nil
        guard isDraggingTab else { return }
        isDraggingTab = false
        onDragEnd?(self, true)
    }

    /// Middle-click closes, the way it does in a browser.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        onClose?(self)
    }

    @objc private func closeClicked() {
        onClose?(self)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        if isSelected || isHovered {
            NSColor.labelColor.withAlphaComponent(isSelected ? 0.08 : 0.04).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }

        // Sits behind the ✕, which is a subview and so draws on top of this.
        if isHoveringClose {
            NSColor.labelColor.withAlphaComponent(0.1).setFill()
            NSBezierPath(ovalIn: slotRect).fill()
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: isSelected ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]

        let x = Self.horizontalPadding
        let width = max(0, slotRect.minX - Self.titleSlotGap - x)
        let height = (title as NSString).size(withAttributes: attributes).height
        (title as NSString).draw(
            in: NSRect(x: x, y: (bounds.height - height) / 2, width: width, height: height),
            withAttributes: attributes
        )
    }
}

/// The unsaved-changes dot. Transparent to the mouse, so clicking it selects
/// the tab rather than doing nothing.
private final class DirtyDotView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let diameter: CGFloat = 6
        let rect = NSRect(
            x: (bounds.width - diameter) / 2,
            y: (bounds.height - diameter) / 2,
            width: diameter,
            height: diameter
        )
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }
}

/// Reports pointer enter/exit so the tab can draw the circle behind the ✕.
private final class TabCloseButton: NSButton {
    var onHoverChange: ((Bool) -> Void)?

    private var hoverArea: NSTrackingArea?

    /// While faded out the ✕ must not swallow clicks — otherwise clicking the
    /// slot of a tab in a background window would close it instead of
    /// selecting it, since hover tracking only runs in the key window.
    override func hitTest(_ point: NSPoint) -> NSView? {
        alphaValue > 0 ? super.hitTest(point) : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange?(false)
    }
}
