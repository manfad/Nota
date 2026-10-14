import AppKit

/// A workbook's sheets as a row of tabs across the top of the grid, in the
/// shape of Safari's compact tab bar: one rounded grey track the full width
/// of the pane, every sheet an equal share of it, the one in front a raised
/// light pill, and a hairline between two sheets neither of which is in front.
/// A click picks a sheet; ←/→ are not taken, since the grid has the keyboard.
final class SheetTabStrip: NSView {

    var titles: [String] = [] {
        didSet {
            selectedIndex = min(selectedIndex, max(0, titles.count - 1))
            toolTip = nil
            needsDisplay = true
        }
    }

    var selectedIndex = 0 {
        didSet { needsDisplay = true }
    }

    /// A sheet was clicked that was not already in front.
    var onSelect: ((Int) -> Void)?

    static let height: CGFloat = 28
    private static let radius: CGFloat = 8
    private static let inset: CGFloat = 2
    private static let font = NSFont.systemFont(ofSize: 12)

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
    }

    private func segmentRect(_ index: Int) -> NSRect {
        let inner = bounds.insetBy(dx: Self.inset, dy: Self.inset)
        let width = inner.width / CGFloat(max(1, titles.count))
        return NSRect(x: inner.minX + width * CGFloat(index), y: inner.minY,
                      width: width, height: inner.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !titles.isEmpty else { return }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

        // The track.
        (dark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.07))
            .setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Self.radius, yRadius: Self.radius).fill()

        // The hairlines, between two sheets neither of which is in front.
        NSColor.separatorColor.setFill()
        for index in 1 ..< titles.count where index != selectedIndex && index - 1 != selectedIndex {
            let rect = segmentRect(index)
            NSRect(x: rect.minX - 0.5, y: rect.minY + 6, width: 1, height: rect.height - 12).fill()
        }

        // The sheet in front, raised.
        let pill = segmentRect(selectedIndex)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.5 : 0.18)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        (dark ? NSColor(white: 0.36, alpha: 1) : NSColor.white).setFill()
        let pillRadius = Self.radius - Self.inset
        NSBezierPath(roundedRect: pill, xRadius: pillRadius, yRadius: pillRadius).fill()
        NSGraphicsContext.restoreGraphicsState()

        // The names, centred, cut short with an ellipsis rather than spilling
        // into the next sheet.
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        for (index, title) in titles.enumerated() {
            let rect = segmentRect(index).insetBy(dx: 8, dy: 0)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Self.font,
                .foregroundColor: index == selectedIndex ? NSColor.labelColor
                    : NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
            let height = Self.font.boundingRectForFont.height
            let line = NSRect(x: rect.minX, y: rect.midY - height / 2 + 1,
                              width: rect.width, height: height)
            (title as NSString).draw(in: line, withAttributes: attributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = titles.indices.first(where: { segmentRect($0).contains(point) }),
              index != selectedIndex else { return }
        selectedIndex = index
        onSelect?(index)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .tabGroup }
    override func accessibilityLabel() -> String? { L10n.text("Sheet") }

    /// A click on a sheet, for the tests.
    func selectForTesting(_ index: Int) {
        guard titles.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
        onSelect?(index)
    }
}
