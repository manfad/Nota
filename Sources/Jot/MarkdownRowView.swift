import AppKit

/// The Markdown tab's own row: a thin band under the window-wide tab strip and
/// above the first line of text, carrying the Editor · Split · Reading control
/// at its trailing end and nothing else.
///
/// Only a Markdown tab has one — a `.md`, a `.markdown`, or an untitled note,
/// which saves as `.md` by default. It takes the editor's paper and a hairline
/// along the bottom, the same one the strip above it draws, so the two read as
/// one piece of chrome above the text.
///
/// There are two of them, one per column. In the editor and split modes the
/// editor column's row is the one on screen; in reading mode that column is
/// collapsed, so the preview column shows its own. Same row, other side of the
/// divider.
final class MarkdownRowView: NSView {

    static let height: CGFloat = 26
    /// The same trailing inset the ⇧⌘F field keeps in the strip above.
    static let controlInset: CGFloat = 12

    /// Editor · Split · Reading. Monochrome template symbols, so the segments
    /// take the control's own tint rather than three colours of their own.
    let modeControl = NSSegmentedControl()

    /// The row is content, not title bar: dragging it must not move the
    /// window the way dragging the strip above it does.
    override var mouseDownCanMoveWindow: Bool { false }

    init(target: AnyObject?, action: Selector) {
        super.init(frame: .zero)

        modeControl.translatesAutoresizingMaskIntoConstraints = false
        modeControl.segmentStyle = .rounded
        modeControl.controlSize = .small
        modeControl.trackingMode = .selectOne
        modeControl.segmentCount = PreviewMode.allCases.count
        for (index, mode) in PreviewMode.allCases.enumerated() {
            let image = NSImage(
                systemSymbolName: mode.symbolName, accessibilityDescription: mode.controlTitle
            )
            image?.isTemplate = true
            modeControl.setImage(image, forSegment: index)
            modeControl.setToolTip(mode.controlToolTip, forSegment: index)
            modeControl.setWidth(28, forSegment: index)
        }
        modeControl.selectedSegment = 0
        modeControl.target = target
        modeControl.action = action
        addSubview(modeControl)

        NSLayoutConstraint.activate([
            modeControl.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Self.controlInset
            ),
            modeControl.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shown or hidden as one piece: the control goes with the band it sits
    /// in, so nothing is left floating over the text.
    func setVisible(_ visible: Bool) {
        isHidden = !visible
        modeControl.isHidden = !visible
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()

        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}
