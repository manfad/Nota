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

    /// The dragged tab has left the strip far enough to stop being part of
    /// this window: the strip has given up its own reorder, and the tab
    /// belongs to a window of its own from here. `grabOffset` is where
    /// inside the tab the pointer took hold of it, so the tab can be placed
    /// under the pointer in the window it lands in.
    func tabBar(_ bar: TabBarView, tearOff index: Int, grabOffset: NSPoint, screenPoint: NSPoint)
    /// Every drag after a tear-off. The strip has nothing left to move; it
    /// only keeps the gesture flowing to whoever owns the torn tab.
    func tabBarDragMoved(_ bar: TabBarView, to screenPoint: NSPoint)
    /// The release (`committed`) or Esc (`false`) that ends a torn-off drag.
    func tabBarDragEnded(_ bar: TabBarView, committed: Bool, at screenPoint: NSPoint)
}

/// Tear-off is the only part of the strip a delegate may ignore — a test
/// recorder that only cares about selection still compiles.
extension TabBarViewDelegate {
    func tabBar(_ bar: TabBarView, tearOff index: Int, grabOffset: NSPoint, screenPoint: NSPoint) {}
    func tabBarDragMoved(_ bar: TabBarView, to screenPoint: NSPoint) {}
    func tabBarDragEnded(_ bar: TabBarView, committed: Bool, at screenPoint: NSPoint) {}
}

/// The strip of tabs that sits in the title bar next to the traffic lights.
/// Tabs share one width that shrinks as tabs are added, the way a browser's
/// do; the strip never scrolls. `TabStripLayout` owns that arithmetic, this
/// view only puts the frames where it says and runs the drag.
final class TabBarView: NSView {
    weak var delegate: TabBarViewDelegate?

    /// Tabs are clipped to the strip rather than spilling over the window.
    override var clipsToBounds: Bool {
        get { true }
        set { _ = newValue }
    }

    static let height: CGFloat = 34

    private static let tabHeight: CGFloat = 24
    private static let spacing = TabStripLayout.spacing
    private static let newTabButtonSize = TabStripLayout.plusSize

    /// Drag-to-reorder tuning: how raised the dragged tab looks, how long a
    /// slide/settle animation takes, and — only when tabs are hidden — the
    /// hot zone at either end that reveals one more slot, and how often. The
    /// move-vs-click threshold itself lives on `TabItemView`, the only place
    /// that needs it.
    private static let draggedTabAlpha: CGFloat = 0.9
    private static let dragAnimationDuration: TimeInterval = 0.12
    /// Keeps a tab from flickering between two slots when the pointer rests
    /// directly on their boundary.
    private static let dragSlotHysteresis: CGFloat = 4
    private static let dragRevealEdge: CGFloat = 24
    private static let dragRevealInterval: TimeInterval = 0.25
    /// How far out of the strip the pointer goes before the tab stops being
    /// this window's — Chromium's `kTearawayDistance` in spirit.
    private static let tearOffDistance: CGFloat = 40
    /// The insertion caret a strip shows while a torn-off tab hovers it.
    private static let dropCaretWidth: CGFloat = 2

    /// The hairline drawn in the gap between two plain tabs.
    private static let separatorHeight: CGFloat = 12

    private var items: [TabBarItem] = []
    private var selectedIndex = 0
    private var itemViews: [TabItemView] = []
    private let newTabButton = NewTabButton()

    /// Where the sliding window starts when the tabs no longer fit even at
    /// their floor. Fed back into the next layout so the window stays put
    /// while the selection moves inside it.
    private var firstVisibleIndex = 0

    /// The tab under the pointer, if any: separators are not drawn beside it.
    private var hoveredIndex: Int?

    /// Chromium's `in_tab_close_`: after a ✕ the tabs that remain keep the
    /// widths they had and close up the gap, so a run of closes leaves each
    /// next ✕ under the pointer. Dropped when the pointer leaves the strip.
    /// ⌘W never comes through the ✕, so it relayouts straight away.
    private struct CloseFreeze {
        var widths: [CGFloat]
        var firstVisibleIndex: Int
        var plusX: CGFloat
    }

    private var closeFreeze: CloseFreeze?
    private var hoverArea: NSTrackingArea?

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
        /// Widths snapshot at drag start, indexed like `items`.
        let widths: [CGFloat]
        /// How many leading slots the window has hidden, and the leading x
        /// that follows from it. Edge-reveal moves both.
        var revealedSlots: Int
        var originX: CGFloat
        /// The + stays where it was for the length of the drag.
        let plusX: CGFloat
        let startPointerX: CGFloat
        let startViewX: CGFloat
        var lastPointerX: CGFloat
        /// Where inside the tab the pointer took hold of it. The tab must
        /// stay under the pointer when it lands in a window of its own.
        let grabOffset: NSPoint
    }

    private var dragSession: DragSession?
    private var dragRevealTimer: Timer?
    private var dragEscMonitor: Any?
    /// True from the moment a drag leaves the strip until it is released.
    /// The strip reorders nothing any more; it only carries the rest of the
    /// gesture to the delegate, which owns the window the tab is now in.
    private var isTornOff = false
    /// The gap a tab released now would drop into, when this strip is the
    /// one under another window's torn-off tab.
    private var dropCaretSlot: Int?

    /// The strip never lets AppKit move the window on its own: with the
    /// automatic region on, a press on a tab dragged the window *and* the
    /// tab at once (the tab's refusal was not honoured). Dragging the empty
    /// strip still moves the window — `mouseDown` starts that drag itself.
    override var mouseDownCanMoveWindow: Bool { false }

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
        guard let window else { return super.mouseDown(with: event) }
        guard event.clickCount == 2 else { return window.performDrag(with: event) }
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
        rebuild()
    }

    // MARK: - Dropping a torn-off tab

    /// Shows where a tab released now would go in: a caret in the gap
    /// itself, the way a browser marks the insertion point. `nil` clears it.
    func showDropCaret(at slot: Int?) {
        guard dropCaretSlot != slot else { return }
        dropCaretSlot = slot
        needsDisplay = true
    }

    /// This point on screen inside the strip, in the strip's own
    /// coordinates — `nil` when the pointer is somewhere else entirely.
    func barPoint(forScreenPoint point: NSPoint) -> NSPoint? {
        guard let window else { return nil }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        return bounds.contains(local) ? local : nil
    }

    /// The slot a tab released here would take. The visible tabs' midpoints
    /// are the boundaries, so the caret follows the pointer tab by tab.
    func dropSlot(at pointer: NSPoint) -> Int {
        var slot = itemViews.firstIndex { !$0.isHidden } ?? 0
        for (index, view) in itemViews.enumerated() where !view.isHidden {
            guard pointer.x >= view.frame.midX else { break }
            slot = index + 1
        }
        return slot
    }

    /// Where the caret is drawn for `slot`: the middle of the gap before
    /// that tab, or after the last one.
    private func dropCaretX(for slot: Int) -> CGFloat {
        if itemViews.indices.contains(slot), !itemViews[slot].isHidden {
            return itemViews[slot].frame.minX - Self.spacing / 2
        }
        return (itemViews.last { !$0.isHidden }?.frame.maxX ?? 0) + Self.spacing / 2
    }

    // MARK: - Test hooks

    /// Test hook: whether the selected tab is on-screen, unhidden, and
    /// entirely within the strip (never under the + button).
    internal func isSelectedTabFullyVisible() -> Bool {
        guard itemViews.indices.contains(selectedIndex) else { return false }
        let view = itemViews[selectedIndex]
        guard !view.isHidden else { return false }
        return view.frame.minX >= 0 && view.frame.maxX <= newTabButton.frame.minX + 0.01
    }

    /// Test hook: the titles in their current display order.
    internal var titlesForTesting: [String] { items.map(\.title) }

    /// Test hook: whether the tab at `index` shows the leading file icon
    /// (the same placeholder symbol for every kind, until per-type artwork
    /// arrives).
    internal func hasFileIconForTesting(at index: Int) -> Bool {
        guard itemViews.indices.contains(index) else { return false }
        return itemViews[index].iconImageForTesting != nil
    }

    /// Test hook: the view for the tab at `index`, for hit-testing.
    internal func tabViewForTesting(at index: Int) -> NSView? {
        itemViews.indices.contains(index) ? itemViews[index] : nil
    }

    /// Test hook: every tab's frame, hidden ones included.
    internal var tabFramesForTesting: [NSRect] { itemViews.map(\.frame) }

    /// Test hook: which tabs are on screen.
    internal var hiddenTabsForTesting: [Bool] { itemViews.map(\.isHidden) }

    /// Test hook: where the + sits.
    internal var newTabButtonFrameForTesting: NSRect { newTabButton.frame }

    /// Test hook: closes the tab at `index` the way its ✕ does — ⌘W arrives
    /// through `setItems` instead and never freezes the widths.
    internal func closeViaButtonForTesting(at index: Int) {
        guard itemViews.indices.contains(index) else { return }
        close(itemViews[index])
    }

    /// Test hook: whether a ✕ close is still holding the widths still.
    internal var isFrozenAfterCloseForTesting: Bool { closeFreeze != nil }

    /// Test hook: starts a drag on `index`, as if the pointer had just
    /// crossed the threshold there, without going through mouse events.
    internal func beginDragForTesting(index: Int) {
        guard itemViews.indices.contains(index) else { return }
        let view = itemViews[index]
        beginDrag(for: view, pointer: NSPoint(x: view.frame.midX, y: bounds.midY))
    }

    /// Test hook: the dragged tab's current x, or `nil` when nothing is
    /// being dragged.
    internal var draggedTabXForTesting: CGFloat? {
        guard let session = dragSession else { return nil }
        return itemViews[session.originalIndex].frame.minX
    }

    /// Test hook: advances the active drag in the same coordinate space as
    /// `TabItemView`'s real mouse events.
    internal func updateDragForTesting(pointerX: CGFloat,
                                       pointerY: CGFloat? = nil,
                                       screenPoint: NSPoint = .zero) {
        let index = dragSession?.originalIndex ?? 0
        guard itemViews.indices.contains(index) else { return }
        guard dragSession != nil || isTornOff else { return }
        updateDrag(
            for: itemViews[index],
            pointer: NSPoint(x: pointerX, y: pointerY ?? bounds.midY),
            screenPoint: screenPoint
        )
    }

    /// Test hook: releases (or, with `committed` false, abandons) the drag
    /// the way a mouse-up or Esc inside the tracking loop would.
    internal func endDragForTesting(committed: Bool, at screenPoint: NSPoint = .zero) {
        let index = dragSession?.originalIndex ?? 0
        guard itemViews.indices.contains(index) else { return }
        endDrag(for: itemViews[index], committed: committed, screenPoint: screenPoint)
    }

    /// Test hook: the gap the insertion caret is sitting in, if any.
    internal var dropCaretSlotForTesting: Int? { dropCaretSlot }

    /// Test hook: whether the strip has handed its tab to another window.
    internal var isTornOffForTesting: Bool { isTornOff }

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

    // MARK: - Items

    private func rebuild() {
        while itemViews.count > items.count {
            itemViews.removeLast().removeFromSuperview()
        }
        while itemViews.count < items.count {
            let view = TabItemView()
            view.onSelect = { [weak self] tab in self?.select(tab) }
            view.onClose = { [weak self] tab in self?.close(tab) }
            view.onHoverChange = { [weak self] tab, hovering in self?.hoverChanged(tab, hovering) }
            view.onDragStart = { [weak self] tab, grab in self?.beginDrag(for: tab, pointer: grab) }
            view.onDragMove = { [weak self] tab, pointer, screen in
                self?.updateDrag(for: tab, pointer: pointer, screenPoint: screen)
            }
            view.onDragEnd = { [weak self] tab, committed, screen in
                self?.endDrag(for: tab, committed: committed, screenPoint: screen)
            }
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
        freezeWidths(closing: index)
        delegate?.tabBar(self, didRequestCloseAt: index)
    }

    private func hoverChanged(_ view: TabItemView, _ hovering: Bool) {
        guard let index = itemViews.firstIndex(of: view) else { return }
        if hovering {
            hoveredIndex = index
        } else if hoveredIndex == index {
            hoveredIndex = nil
        }
        needsDisplay = true
    }

    // MARK: - Layout

    /// Room the tabs themselves may use: the strip minus the + and its gap.
    private var tabsWidth: CGFloat {
        TabStripLayout.tabsWidth(bounds.width)
    }

    /// The plan the strip is on right now: the frozen one while a ✕ close is
    /// holding the widths still, otherwise a fresh one.
    private func currentLayout() -> TabStripLayout {
        if let freeze = closeFreeze, freeze.widths.count == items.count {
            return TabStripLayout(
                widths: freeze.widths,
                firstVisibleIndex: freeze.firstVisibleIndex,
                plusX: freeze.plusX,
                viewportWidth: bounds.width
            )
        }
        // A freeze whose count no longer matches (the close was cancelled by
        // a save prompt, or a tab was opened meanwhile) is stale.
        closeFreeze = nil
        return TabStripLayout(
            count: items.count,
            selectedIndex: selectedIndex,
            viewportWidth: bounds.width,
            previousFirstVisibleIndex: firstVisibleIndex
        )
    }

    /// Snapshots the strip minus the tab that is about to go, so the tabs
    /// that remain keep their width and simply close the gap — the next ✕
    /// then lands under the pointer that just clicked one.
    private func freezeWidths(closing index: Int) {
        let plan = currentLayout()
        guard plan.widths.indices.contains(index), plan.widths.count > 1 else { return }
        var widths = plan.widths
        widths.remove(at: index)
        closeFreeze = CloseFreeze(
            widths: widths,
            firstVisibleIndex: min(plan.firstVisibleIndex, widths.count - 1),
            plusX: plan.plusX
        )
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

    /// The pointer leaving the strip is what ends a run of ✕ closes: the
    /// widths are free to settle again.
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredIndex = nil
        guard closeFreeze != nil else { return }
        closeFreeze = nil
        needsLayout = true
    }

    override func layout() {
        super.layout()

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

        let plan = currentLayout()
        firstVisibleIndex = plan.firstVisibleIndex
        place(plan)
        needsDisplay = true
    }

    private func place(_ plan: TabStripLayout) {
        let plusSize = Self.newTabButtonSize
        newTabButton.frame = NSRect(
            x: plan.plusX,
            y: (bounds.height - plusSize) / 2,
            width: plusSize,
            height: plusSize
        )

        let y = (bounds.height - Self.tabHeight) / 2
        for (index, view) in itemViews.enumerated() {
            guard plan.widths.indices.contains(index) else {
                view.isHidden = true
                continue
            }
            view.frame = NSRect(
                x: plan.xs[index], y: y, width: plan.widths[index], height: Self.tabHeight
            )
            // Outside the sliding window means off the strip: not drawn, and
            // not clickable either.
            view.isHidden = !plan.visibleRange.contains(index)
        }
    }

    /// Brave draws a hairline only between two plain tabs — never beside the
    /// selected one, never beside the one under the pointer. It lives in the
    /// gap, which belongs to the strip rather than to either tab.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if let slot = dropCaretSlot {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(rect: NSRect(
                x: dropCaretX(for: slot) - Self.dropCaretWidth / 2,
                y: (bounds.height - Self.tabHeight) / 2,
                width: Self.dropCaretWidth,
                height: Self.tabHeight
            )).fill()
        }

        guard itemViews.count > 1 else { return }
        NSColor.labelColor.withAlphaComponent(0.15).setFill()
        let y = (bounds.height - Self.separatorHeight) / 2
        for index in 0..<(itemViews.count - 1) {
            let left = itemViews[index], right = itemViews[index + 1]
            guard !left.isHidden, !right.isHidden else { continue }
            guard index != selectedIndex, index + 1 != selectedIndex else { continue }
            guard index != hoveredIndex, index + 1 != hoveredIndex else { continue }
            let center = (left.frame.maxX + right.frame.minX) / 2
            NSBezierPath(
                rect: NSRect(x: center - 0.5, y: y, width: 1, height: Self.separatorHeight)
            ).fill()
        }
    }

    // MARK: - Drag to reorder

    private func beginDrag(for view: TabItemView, pointer: NSPoint) {
        guard dragSession == nil, !isTornOff, let index = itemViews.firstIndex(of: view) else { return }
        let plan = currentLayout()
        guard plan.widths.count == itemViews.count else { return }
        dragSession = DragSession(
            originalIndex: index,
            currentSlot: index,
            visualOrder: Array(itemViews.indices),
            widths: plan.widths,
            revealedSlots: plan.firstVisibleIndex,
            originX: plan.xs.first ?? 0,
            plusX: plan.plusX,
            startPointerX: pointer.x,
            startViewX: view.frame.minX,
            lastPointerX: pointer.x,
            grabOffset: NSPoint(x: pointer.x - view.frame.minX, y: pointer.y - view.frame.minY)
        )
        // Above every sibling while it rides the pointer, and a touch
        // translucent so it reads as lifted off the strip.
        addSubview(view, positioned: .above, relativeTo: nil)
        view.alphaValue = Self.draggedTabAlpha
        startEscMonitor()
    }

    /// `pointer` is `nil` once the dragged tab has left the strip — the note
    /// has gone to another window and its view went with it, so there is no
    /// strip left to place it against. Only the screen point matters then.
    private func updateDrag(for view: TabItemView, pointer: NSPoint?, screenPoint: NSPoint) {
        // Past the tear-off the strip is only a courier: the tab is a window
        // now, and coming back over the strip does not dock it again —
        // Chromium does not re-dock either, the window simply follows.
        if isTornOff {
            delegate?.tabBarDragMoved(self, to: screenPoint)
            return
        }
        guard let pointer, let session = dragSession else { return }
        if hasLeftTheStrip(pointer) {
            tearOff(session, screenPoint: screenPoint)
            return
        }
        dragSession?.lastPointerX = pointer.x
        updateDragPositions(pointerX: pointer.x)
        updateEdgeReveal(pointerX: pointer.x)
    }

    /// Far enough above or below the strip, or off either side of the
    /// window: the pointer is no longer arranging this window's tabs.
    private func hasLeftTheStrip(_ pointer: NSPoint) -> Bool {
        if pointer.y < -Self.tearOffDistance || pointer.y > bounds.height + Self.tearOffDistance {
            return true
        }
        guard let window else { return false }
        let inWindow = convert(pointer, to: nil)
        return inWindow.x < 0 || inWindow.x > window.frame.width
    }

    /// Hands the tab over. The strip drops its own reorder outright rather
    /// than cancelling it: the dragged tab is about to leave `items`, so
    /// sliding it home would only animate a tab on its way out.
    private func tearOff(_ session: DragSession, screenPoint: NSPoint) {
        stopEdgeReveal()
        stopEscMonitor()
        dragSession = nil
        isTornOff = true
        itemViews[session.originalIndex].alphaValue = 1
        restoreSubviewOrdering()
        needsLayout = true
        delegate?.tabBar(self, tearOff: session.originalIndex,
                         grabOffset: session.grabOffset, screenPoint: screenPoint)
    }

    /// Moves the tab one-to-one with the pointer, then snaps the gap to the
    /// nearest insertion slot. This is how browser tab strips behave: the
    /// possible resting places are fixed, and their halfway points are the
    /// reorder boundaries. It stays predictable with mixed tab widths and
    /// also lets a quick gesture skip several tabs in one event.
    private func updateDragPositions(pointerX: CGFloat) {
        guard var session = dragSession, itemViews.indices.contains(session.originalIndex) else { return }
        let widths = session.widths
        let draggedWidth = widths[session.originalIndex]
        let proposedX = session.startViewX + (pointerX - session.startPointerX)
        let clampedX = min(max(0, proposedX), max(0, tabsWidth - draggedWidth))

        let draggedView = itemViews[session.originalIndex]
        var draggedFrame = draggedView.frame
        draggedFrame.origin.x = clampedX
        draggedView.frame = draggedFrame

        let draggedCenter = clampedX + draggedWidth / 2
        let siblings = session.visualOrder.filter { $0 != session.originalIndex }

        // The centre the dragged tab would have in each possible resting
        // slot. Adjacent centres define a natural halfway reorder boundary.
        var candidateCenters: [CGFloat] = []
        var x = session.originX
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

            var siblingX = session.originX
            for originalIndex in newOrder {
                if originalIndex != session.originalIndex {
                    animateSibling(itemViews[originalIndex], to: siblingX)
                }
                siblingX += widths[originalIndex] + Self.spacing
            }
        }

        dragSession = session
    }

    /// Total the tabs want, spacing included.
    private func totalWidth(_ session: DragSession) -> CGFloat {
        session.widths.reduce(0, +) + Self.spacing * CGFloat(max(0, session.widths.count - 1))
    }

    /// Only a strip with hidden tabs has an edge behaviour: holding the
    /// pointer at either end brings one more slot in, so a tab can be
    /// dropped onto a slot the window is not showing. A strip where
    /// everything fits has nothing to reveal and stays still.
    private func updateEdgeReveal(pointerX: CGFloat) {
        guard let session = dragSession, totalWidth(session) > tabsWidth else {
            return stopEdgeReveal()
        }
        let direction: Int
        if pointerX < Self.dragRevealEdge {
            direction = -1
        } else if pointerX > tabsWidth - Self.dragRevealEdge {
            direction = 1
        } else {
            direction = 0
        }
        guard direction != 0 else { return stopEdgeReveal() }
        guard dragRevealTimer == nil else { return }
        let timer = Timer(timeInterval: Self.dragRevealInterval, repeats: true) { [weak self] timer in
            guard let self, self.dragRevealTimer === timer, self.dragSession != nil else {
                return timer.invalidate()
            }
            self.revealOneSlot(direction: direction)
        }
        RunLoop.main.add(timer, forMode: .common)
        dragRevealTimer = timer
    }

    private func stopEdgeReveal() {
        dragRevealTimer?.invalidate()
        dragRevealTimer = nil
    }

    /// Slides the window by one slot, if there is anything to slide towards.
    private func revealOneSlot(direction: Int) {
        guard var session = dragSession else { return }
        if direction < 0 {
            guard session.revealedSlots > 0 else { return }
            session.revealedSlots -= 1
        } else {
            guard session.revealedSlots < session.widths.count - 1,
                  session.originX + totalWidth(session) > tabsWidth else { return }
            session.revealedSlots += 1
        }
        var origin: CGFloat = 0
        for slot in 0..<session.revealedSlots {
            origin -= session.widths[session.visualOrder[slot]] + Self.spacing
        }
        session.originX = origin
        dragSession = session
        layoutDuringDrag(session)
        updateDragPositions(pointerX: session.lastPointerX)
    }

    /// Snaps every non-dragged tab to its current slot — used when the window
    /// slides under the pointer, which is a jump rather than a slide, so it
    /// is not animated.
    private func repositionSiblingsDuringDrag(session: DragSession) {
        var x = session.originX
        for slot in session.visualOrder {
            if slot != session.originalIndex {
                var frame = itemViews[slot].frame
                frame.origin.x = x
                itemViews[slot].frame = frame
            }
            x += session.widths[slot] + Self.spacing
        }
    }

    /// The drag-aware half of `layout()`: positions come from the session
    /// rather than `items`' plain order — the dragged tab is left exactly
    /// where the drag last put it (and is never hidden), while its siblings
    /// go to their current `visualOrder` slot.
    private func layoutDuringDrag(_ session: DragSession) {
        let plusSize = Self.newTabButtonSize
        newTabButton.frame = NSRect(
            x: session.plusX,
            y: (bounds.height - plusSize) / 2,
            width: plusSize,
            height: plusSize
        )

        repositionSiblingsDuringDrag(session: session)

        var x = session.originX
        for slot in session.visualOrder {
            let width = session.widths[slot]
            if slot == session.originalIndex {
                itemViews[slot].isHidden = false
            } else {
                itemViews[slot].isHidden = x + width < 0 || x >= tabsWidth || x + width > tabsWidth
            }
            x += width + Self.spacing
        }
    }

    private func endDrag(for view: TabItemView, committed: Bool, screenPoint: NSPoint) {
        if isTornOff {
            isTornOff = false
            showDropCaret(at: nil)
            delegate?.tabBarDragEnded(self, committed: committed, at: screenPoint)
            return
        }
        guard let session = dragSession else { return }
        stopEdgeReveal()
        stopEscMonitor()
        dragSession = nil

        if committed, session.currentSlot != session.originalIndex {
            let targetX = slotX(session.currentSlot, order: session.visualOrder, widths: session.widths)
                + session.originX
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
                let targetX = slotX(index, order: identityOrder, widths: session.widths)
                    + session.originX
                settle(itemViews[index], to: targetX, completion: index == session.originalIndex ? {
                    view.alphaValue = 1
                } : nil)
            }
            restoreSubviewOrdering()
        }
    }

    private func cancelDrag() {
        guard let session = dragSession else { return }
        endDrag(for: itemViews[session.originalIndex], committed: false, screenPoint: .zero)
    }

    /// Sum of the widths (plus spacing) of every tab before `slot` in
    /// `order` — the slot's offset from the first one.
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
}

/// Trailing control on the tab strip. Same density as a tab (24pt), not an
/// iOS-sized hit target; it rides after the last tab and pins at the edge.
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
/// The slot is always reserved down to `minActiveWidth`, so a tab never
/// changes width when it is selected or hovered. It holds two stacked layers
/// — the unsaved dot and the close button — which cross-fade as the pointer
/// arrives and leaves. Narrower than that there is no room for either: the
/// dot moves onto the icon and the ✕ is gone, as it is in Chromium.
private final class TabItemView: NSView {
    var onSelect: ((TabItemView) -> Void)?
    var onClose: ((TabItemView) -> Void)?
    /// Fired when the pointer arrives or leaves, so the strip knows which
    /// gaps must not show a separator.
    var onHoverChange: ((TabItemView, Bool) -> Void)?
    /// Fired once when the press turns into a drag, with the *original*
    /// mouse-down x in the tab bar's coordinates. Keeping that grab point
    /// prevents the tab from lagging behind the pointer by the activation
    /// threshold. It arrives from inside `mouseDown`'s tracking loop, after
    /// the tab has already been selected.
    var onDragStart: ((TabItemView, NSPoint) -> Void)?
    /// Fired on every subsequent drag, with the pointer in the bar's
    /// coordinates and on screen. The screen point is what survives the tab
    /// leaving the window: after a tear-off the events belong to the new
    /// window, and the bar's own coordinates mean nothing to it any more —
    /// the tab view itself is usually out of the strip by then, which is
    /// what the bar point being optional says.
    var onDragMove: ((TabItemView, NSPoint?, NSPoint) -> Void)?
    /// Fired once a drag was underway and has finished: `committed` is
    /// `true` on mouse-up, `false` when Esc abandoned it mid-gesture, with
    /// the pointer on screen at that moment.
    var onDragEnd: ((TabItemView, Bool, NSPoint) -> Void)?

    private static let font = NSFont.systemFont(ofSize: 12)
    private static let horizontalPadding: CGFloat = 10
    private static let slotSize: CGFloat = 16
    private static let slotTrailingPadding: CGFloat = 6
    private static let titleSlotGap: CGFloat = 4
    private static let crossFadeDuration: TimeInterval = 0.12
    private static let dragThreshold: CGFloat = 3
    private static let iconSize: CGFloat = 16
    private static let iconTitleGap: CGFloat = 5
    /// The title is clipped rather than ellipsized, with the last few points
    /// faded out; below the shorter figure there is no room worth drawing in.
    private static let titleFadeWidth: CGFloat = 12
    private static let minimumTitleWidth: CGFloat = 12
    /// The unsaved dot when it has to sit on the icon instead of in the slot.
    private static let compactDotDiameter: CGFloat = 5
    /// Every tab shows this symbol regardless of file kind for now (SPEC
    /// Todo 15's first step); keeping the name here means swapping in
    /// per-type artwork later only touches this one line.
    private static let fileSymbolName = "text.page"

    private var title = ""
    private var isDirty = false
    private var isSelected = false
    private var isHovered = false
    private var isHoveringClose = false
    private var dragTrackingStart: NSPoint?
    private var isDraggingTab = false
    /// The last pointer position on screen this gesture saw. Esc arrives as
    /// a key event, which has no useful location of its own.
    private var lastDragScreenPoint: NSPoint = .zero

    private let dotView = DirtyDotView()
    private let closeButton = TabCloseButton()
    private let iconView = TabIconView()
    private var hoverArea: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let iconConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        iconView.image = NSImage(systemSymbolName: Self.fileSymbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(iconConfig)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

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

    /// Test hook: the icon image currently shown, so a test can confirm
    /// every tab gets one without launching the app.
    internal var iconImageForTesting: NSImage? { iconView.image }

    func configure(_ item: TabBarItem, isSelected: Bool) {
        title = item.title
        isDirty = item.isDirty
        self.isSelected = isSelected
        toolTip = item.title
        updateSlot(animated: false)
        needsDisplay = true
        needsLayout = true
    }

    /// Too narrow for the trailing slot: no ✕ even on hover, and the unsaved
    /// dot rides on the icon instead.
    private var isCompact: Bool { bounds.width < TabStripLayout.minActiveWidth }

    private var slotRect: NSRect {
        NSRect(
            x: bounds.maxX - Self.slotTrailingPadding - Self.slotSize,
            y: (bounds.height - Self.slotSize) / 2,
            width: Self.slotSize,
            height: Self.slotSize
        )
    }

    private var iconRect: NSRect {
        NSRect(
            x: Self.horizontalPadding,
            y: (bounds.height - Self.iconSize) / 2,
            width: Self.iconSize,
            height: Self.iconSize
        )
    }

    /// The room left for the title once the icon, and the slot when there is
    /// one, have taken theirs.
    private var titleRect: NSRect {
        let x = Self.horizontalPadding + Self.iconSize + Self.iconTitleGap
        let trailing = isCompact
            ? bounds.maxX - Self.horizontalPadding
            : slotRect.minX - Self.titleSlotGap
        return NSRect(x: x, y: 0, width: max(0, trailing - x), height: bounds.height)
    }

    override func layout() {
        super.layout()
        iconView.frame = iconRect
        dotView.frame = slotRect
        closeButton.frame = slotRect
        let compact = isCompact
        dotView.isHidden = compact
        closeButton.isHidden = compact
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
        onHoverChange?(self, true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isHoveringClose = false
        updateSlot(animated: true)
        needsDisplay = true
        onHoverChange?(self, false)
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
        lastDragScreenPoint = screenPoint(of: event)
        isDraggingTab = false
        onSelect?(self)

        // No window means no event queue to track — unit tests drive the
        // mouse methods directly on a bar that was never put in one.
        // Selection can also have removed this tab outright.
        guard superview != nil, window != nil else { return }

        // The app's queue, not this window's: a tear-off makes a new window
        // key half way through the gesture, and the drags and the mouse-up
        // then belong to that one. Asking only this window for its own
        // events would strand the tab the moment it left the strip. The
        // view can also leave the strip while the loop runs — the note goes
        // to another window, its tab view goes with it — so the loop holds
        // itself alive and ends on the mouse-up rather than on the window.
        withExtendedLifetime(self) {
            while let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown],
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
                    if wasDragging { onDragEnd?(self, false, lastDragScreenPoint) }
                default:
                    break
                }
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragTrackingStart else { return }
        let location = event.locationInWindow
        let screen = screenPoint(of: event)
        lastDragScreenPoint = screen
        if !isDraggingTab {
            // Count the user's actual pointer travel. Looking only at x made
            // a natural, slightly diagonal gesture take longer to engage.
            guard hypot(location.x - start.x, location.y - start.y) >= Self.dragThreshold else {
                return
            }
            isDraggingTab = true
            // The grab point, not the current location: the tab must not
            // jump forward by the threshold the moment it lifts off.
            if let grab = superview?.convert(start, from: nil) {
                onDragStart?(self, grab)
            }
        }
        onDragMove?(self, barPoint(of: event, onScreen: screen), screen)
    }

    override func mouseUp(with event: NSEvent) {
        dragTrackingStart = nil
        guard isDraggingTab else { return }
        isDraggingTab = false
        onDragEnd?(self, true, screenPoint(of: event))
    }

    /// The pointer on screen. An event carries its location in *its own*
    /// window, which stops being this one the moment a tab is torn off, so
    /// the event's window is the only sound thing to convert through.
    private func screenPoint(of event: NSEvent) -> NSPoint {
        let source = event.window ?? window
        return source?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    }

    /// The same pointer in the strip's coordinates. An event from another
    /// window comes back through the screen; one from this window is
    /// converted directly, which is what every drag before a tear-off is.
    private func barPoint(of event: NSEvent, onScreen screen: NSPoint) -> NSPoint? {
        guard let superview else { return nil }
        guard let window, event.window !== window else {
            return superview.convert(event.locationInWindow, from: nil)
        }
        return superview.convert(window.convertPoint(fromScreen: screen), from: nil)
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
        if isHoveringClose, !isCompact {
            NSColor.labelColor.withAlphaComponent(0.1).setFill()
            NSBezierPath(ovalIn: slotRect).fill()
        }

        drawTitle()

        // With the slot gone, the only place left to say "unsaved" is the
        // corner of the icon.
        if isCompact, isDirty {
            let diameter = Self.compactDotDiameter
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(ovalIn: NSRect(
                x: iconRect.maxX - diameter + 1,
                y: iconRect.minY - 1,
                width: diameter,
                height: diameter
            )).fill()
        }
    }

    /// Draws the title clipped, not ellipsized: a tab strip that shrinks
    /// wants a title that keeps as many letters as it can and simply runs
    /// out, so the last few points are faded away instead. Erasing through a
    /// gradient inside a transparency layer takes the text's own alpha with
    /// it, which is what makes the fade work whatever sits behind the tab.
    private func drawTitle() {
        let available = titleRect
        guard available.width >= Self.minimumTitleWidth else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: isSelected ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]

        let size = (title as NSString).size(withAttributes: attributes)
        let rect = NSRect(
            x: available.minX,
            y: (bounds.height - size.height) / 2,
            width: available.width,
            height: size.height
        )

        guard size.width > available.width, let context = NSGraphicsContext.current?.cgContext else {
            (title as NSString).draw(in: rect, withAttributes: attributes)
            return
        }

        context.saveGState()
        context.clip(to: rect)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        (title as NSString).draw(in: rect, withAttributes: attributes)
        context.setBlendMode(.destinationOut)
        NSGradient(
            starting: NSColor(white: 0, alpha: 0),
            ending: NSColor(white: 0, alpha: 1)
        )?.draw(
            in: NSRect(
                x: rect.maxX - Self.titleFadeWidth,
                y: rect.minY,
                width: Self.titleFadeWidth,
                height: rect.height
            ),
            angle: 0
        )
        context.endTransparencyLayer()
        context.restoreGState()
    }
}

/// The file icon. Hit-testing goes through to the tab: an `NSImageView` is
/// not opaque, and in the title-bar region a press on any non-opaque view
/// that does not refuse `mouseDownCanMoveWindow` drags the window instead.
private final class TabIconView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
    /// Same reason as `NewTabButton`: a press on the ✕ must never move the window.
    override var mouseDownCanMoveWindow: Bool { false }
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
