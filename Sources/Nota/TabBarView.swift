import AppKit

struct TabBarItem {
    var title: String
    var isDirty: Bool
}

protocol TabBarViewDelegate: AnyObject {
    func tabBar(_ bar: TabBarView, didSelect index: Int)
    func tabBar(_ bar: TabBarView, didRequestCloseAt index: Int)
    func tabBarDidRequestNewTab(_ bar: TabBarView)
}

/// The strip of tabs that sits in the title bar next to the traffic lights.
/// Tabs keep a comfortable width until they run out of room, then shrink
/// evenly down to a floor — no scrolling, no reordering.
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

    private var items: [TabBarItem] = []
    private var selectedIndex = 0
    private var itemViews: [TabItemView] = []
    private let newTabButton = NewTabButton()

    /// How far the strip is scrolled when the tabs do not all fit.
    private var scrollOffset: CGFloat = 0

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
        self.items = items
        self.selectedIndex = selectedIndex
        rebuild()
        // Layout has to settle before the selected tab can be scrolled to.
        DispatchQueue.main.async { [weak self] in self?.scrollSelectedTabIntoView() }
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

    func scrollSelectedTabIntoView() {
        let viewport = tabsViewportWidth
        guard itemViews.indices.contains(selectedIndex), contentWidth > viewport else { return }
        let frame = itemViews[selectedIndex].frame
        if frame.minX < 0 {
            setScrollOffset(scrollOffset + frame.minX)
        } else if frame.maxX > viewport {
            setScrollOffset(scrollOffset + frame.maxX - viewport)
        }
    }

    private func rebuild() {
        while itemViews.count > items.count {
            itemViews.removeLast().removeFromSuperview()
        }
        while itemViews.count < items.count {
            let view = TabItemView()
            view.onSelect = { [weak self] tab in self?.select(tab) }
            view.onClose = { [weak self] tab in self?.close(tab) }
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

        // Tabs never shrink below a readable width; once they no longer fit,
        // the strip scrolls rather than squeezing them into slivers. The +
        // stays pinned at the trailing edge, so they only use the leading
        // remainder — a tab that would sit under the + is hidden instead.
        let viewport = tabsViewportWidth
        let widths = items.map(Self.readableWidth)
        let total = widths.reduce(0, +) + Self.spacing * CGFloat(itemViews.count - 1)
        if total <= viewport { scrollOffset = 0 }
        scrollOffset = min(scrollOffset, max(0, total - viewport))

        let y = (bounds.height - Self.tabHeight) / 2
        var x = -scrollOffset
        for (index, view) in itemViews.enumerated() {
            view.frame = NSRect(x: x, y: y, width: widths[index], height: Self.tabHeight)
            // Tabs scrolled off the edge should not be clickable, and a tab
            // that would cross the + slot is not shown there either.
            view.isHidden = x + widths[index] < 0 || x >= viewport || x + widths[index] > viewport
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

    private static let font = NSFont.systemFont(ofSize: 12)
    private static let horizontalPadding: CGFloat = 10
    private static let slotSize: CGFloat = 16
    private static let slotTrailingPadding: CGFloat = 6
    private static let titleSlotGap: CGFloat = 4
    private static let crossFadeDuration: TimeInterval = 0.12

    private var title = ""
    private var isDirty = false
    private var isSelected = false
    private var isHovered = false
    private var isHoveringClose = false

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

    override func mouseDown(with event: NSEvent) {
        onSelect?(self)
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
