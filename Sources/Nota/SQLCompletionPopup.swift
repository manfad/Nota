import AppKit

/// The little list under the caret in the query box.
///
/// A window rather than a view, because the box is five rows tall inside a
/// scroller and a dropdown clipped to it would be no dropdown at all. It is a
/// non-activating panel, a child of the window the box is in, and it never
/// becomes key: the caret stays where it is, the typing keeps going into the
/// text view, and every key the list answers to is one the text view reads and
/// forwards here. Nothing about the panel is focusable — clicking a row is the
/// only thing it does on its own.
///
/// It draws itself rather than borrowing a table: eight rows at most, the
/// query's own monospaced font on the left, a grey word on the right saying
/// where the suggestion came from, and the accent behind whichever row is
/// picked.
final class SQLCompletionPopup {

    /// A row was chosen, by ↩, by Tab or by a click.
    var onAccept: ((SQLCompletion.Item) -> Void)?

    private enum Metrics {
        /// The box's own bezel radius, so the two agree.
        static let radius: CGFloat = 6
        static let border: CGFloat = 1
        static let padding: CGFloat = 8
        /// Between the suggestion and the grey word after it.
        static let hintGap: CGFloat = 24
        /// How far under the caret's line the list hangs.
        static let drop: CGFloat = 3
        static let visibleRows = 8
        static let minWidth: CGFloat = 180
        static let maxWidth: CGFloat = 420
    }

    private let panel: SQLCompletionPanel
    private let frameView = SQLCompletionFrameView()
    private let scrollView = NSScrollView()
    private let list = SQLCompletionListView()

    private(set) var isOpen = false

    init() {
        panel = SQLCompletionPanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.minWidth, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.animationBehavior = .none

        frameView.wantsLayer = true
        frameView.layer?.cornerRadius = Metrics.radius
        frameView.layer?.borderWidth = Metrics.border
        frameView.layer?.masksToBounds = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = list
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        frameView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: frameView.topAnchor,
                                            constant: Metrics.border),
            scrollView.bottomAnchor.constraint(equalTo: frameView.bottomAnchor,
                                               constant: -Metrics.border),
            scrollView.leadingAnchor.constraint(equalTo: frameView.leadingAnchor,
                                                constant: Metrics.border),
            scrollView.trailingAnchor.constraint(equalTo: frameView.trailingAnchor,
                                                 constant: -Metrics.border),
        ])
        panel.contentView = frameView

        list.onPick = { [weak self] row in
            guard let self, row >= 0, row < items.count else { return }
            let item = items[row]
            close()
            onAccept?(item)
        }
    }

    deinit {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    var items: [SQLCompletion.Item] { list.items }

    var selectedItem: SQLCompletion.Item? {
        guard isOpen, list.selection >= 0, list.selection < list.items.count else { return nil }
        return list.items[list.selection]
    }

    /// Puts the list up under `caret` — a rect in screen coordinates, the one
    /// the text view gives for the insertion point — keeping whichever row was
    /// picked if it is still in the list, and starting at the top if it is not.
    func show(_ items: [SQLCompletion.Item], font: NSFont, under caret: NSRect, in host: NSView) {
        guard !items.isEmpty, let window = host.window else {
            close()
            return
        }
        let kept = selectedItem
        list.font = font
        list.items = items
        list.selection = items.firstIndex { $0 == kept } ?? 0
        list.needsDisplay = true

        let rowHeight = list.rowHeight
        list.frame = NSRect(x: 0, y: 0, width: width(for: items, font: font),
                            height: rowHeight * CGFloat(items.count))
        let rows = CGFloat(min(items.count, Metrics.visibleRows))
        let size = NSSize(width: list.frame.width + Metrics.border * 2,
                          height: rows * rowHeight + Metrics.border * 2)

        panel.appearance = window.appearance
        panel.setFrame(NSRect(origin: origin(under: caret, size: size, on: window), size: size),
                       display: false)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        isOpen = true
        scrollSelectionIntoView()
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// ↑ and ↓, wrapping round the ends the way a menu does.
    func moveSelection(by delta: Int) {
        guard isOpen, !list.items.isEmpty else { return }
        let count = list.items.count
        list.selection = ((list.selection + delta) % count + count) % count
        list.needsDisplay = true
        scrollSelectionIntoView()
    }

    private func scrollSelectionIntoView() {
        guard list.selection >= 0, list.selection < list.items.count else { return }
        list.scrollToVisible(NSRect(x: 0, y: CGFloat(list.selection) * list.rowHeight,
                                    width: list.frame.width, height: list.rowHeight))
    }

    /// Under the caret's line, unless the screen runs out below — then above
    /// it, which is where a dropdown at the bottom of a display belongs.
    private func origin(under caret: NSRect, size: NSSize, on window: NSWindow) -> NSPoint {
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_000_000, height: 1_000_000)
        var x = caret.minX - Metrics.padding
        x = min(max(x, visible.minX + 4), visible.maxX - size.width - 4)
        var y = caret.minY - Metrics.drop - size.height
        if y < visible.minY + 4 { y = caret.maxY + Metrics.drop }
        return NSPoint(x: x, y: y)
    }

    private func width(for items: [SQLCompletion.Item], font: NSFont) -> CGFloat {
        let hintFont = NSFont.systemFont(ofSize: max(9, font.pointSize - 2))
        var widest: CGFloat = 0
        for item in items {
            let text = (item.text as NSString).size(withAttributes: [.font: font]).width
            let hint = (item.hint as NSString).size(withAttributes: [.font: hintFont]).width
            widest = max(widest, text + hint)
        }
        let total = widest + Metrics.padding * 2 + Metrics.hintGap
        return min(max(total.rounded(.up), Metrics.minWidth), Metrics.maxWidth)
    }

    // MARK: - Tests

    var isOpenForTesting: Bool { isOpen }
    var itemsForTesting: [SQLCompletion.Item] { list.items }
    var selectionForTesting: Int { list.selection }
}

/// A window that will not take the keyboard, whatever is clicked in it. That
/// is the whole point of the panel: the caret stays in the query box, so the
/// query goes on being typed while the list under it is being read.
private final class SQLCompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The rounded card the list sits in: the same field background and hairline
/// the query box's own bezel wears, so the two read as one control.
private final class SQLCompletionFrameView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The rows themselves, drawn rather than built: eight labels at most, none of
/// which ever needs to be a view.
private final class SQLCompletionListView: NSView {
    var items: [SQLCompletion.Item] = []
    var selection = 0
    var onPick: ((Int) -> Void)?

    var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular) {
        didSet { needsDisplay = true }
    }

    private enum Metrics {
        static let padding: CGFloat = 8
        static let rowPadding: CGFloat = 6
    }

    var rowHeight: CGFloat {
        (font.ascender - font.descender + font.leading + Metrics.rowPadding).rounded(.up)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let height = rowHeight
        let hintFont = NSFont.systemFont(ofSize: max(9, font.pointSize - 2))
        for (row, item) in items.enumerated() {
            let frame = NSRect(x: 0, y: CGFloat(row) * height,
                               width: bounds.width, height: height)
            guard frame.intersects(dirtyRect) else { continue }
            let picked = row == selection
            if picked {
                NSColor.controlAccentColor.setFill()
                frame.fill()
            }
            let text = NSAttributedString(string: item.text, attributes: [
                .font: font,
                .foregroundColor: picked ? NSColor.alternateSelectedControlTextColor
                    : NSColor.labelColor,
            ])
            let hint = NSAttributedString(string: item.hint, attributes: [
                .font: hintFont,
                .foregroundColor: picked ? NSColor.alternateSelectedControlTextColor
                    .withAlphaComponent(0.75)
                    : NSColor.secondaryLabelColor,
            ])
            let textSize = text.size()
            text.draw(at: NSPoint(x: Metrics.padding,
                                  y: frame.minY + (height - textSize.height) / 2))
            let hintSize = hint.size()
            hint.draw(at: NSPoint(x: bounds.width - Metrics.padding - hintSize.width,
                                  y: frame.minY + (height - hintSize.height) / 2))
        }
    }

    /// The panel is never key, so a click in it is always a first click and
    /// would otherwise be swallowed by the window rather than picking a row.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = Int(point.y / rowHeight)
        guard row >= 0, row < items.count else { return }
        selection = row
        needsDisplay = true
        onPick?(row)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
