import AppKit

/// The Editor · Split · Reading control, floating over the top-trailing corner
/// of a column. There is one of these per column — the editor's and the
/// preview's — so in split mode each half of the document has its own, and
/// both drive the one mode the tab is in.
///
/// It is not a row: nothing is pushed down for it, and the text starts right
/// under the tab strip. The control is only there while the pointer is near it
/// — anywhere in the band across the top of the column — and fades away again
/// when the pointer leaves, so a note being read has nothing but the note in
/// it.
///
/// The whole band is the hover target, but only the control itself ever takes
/// a click: `hitTest` hands everything else back to the text underneath, so a
/// line under the band stays as clickable as any other.
///
/// One layer and no more: the segmented control's own rounded bezel is the
/// whole of it. There is no plate behind it — a second rounded shape around
/// the first only read as two things stacked up.
final class ModeControlOverlay: NSView {

    /// How far down the column the pointer counts as being near the control.
    static let hoverBandHeight: CGFloat = 44
    /// The control's inset from the trailing edge, matching the ⇧⌘F field's in
    /// the strip above, and its drop below the strip's hairline.
    static let controlInset: CGFloat = 12
    static let controlTopInset: CGFloat = 8

    let modeControl = NSSegmentedControl()

    private var trackingArea: NSTrackingArea?

    /// Whether the control is on screen right now. Hover says so; a tab that
    /// is not Markdown, and zen, take the whole overlay away instead.
    private(set) var isRevealed = false

    /// The band is chrome over the text, not the title bar: dragging it must
    /// not move the window.
    override var mouseDownCanMoveWindow: Bool { false }

    init(target: AnyObject?, action: Selector) {
        super.init(frame: .zero)

        modeControl.translatesAutoresizingMaskIntoConstraints = false
        // The fade is an opacity animation, so it wants a layer to run on.
        // The control used to inherit one from the plate it sat in; standing
        // on its own it has to ask for its own.
        modeControl.wantsLayer = true
        modeControl.alphaValue = 0
        modeControl.segmentStyle = .rounded
        modeControl.controlSize = .small
        modeControl.trackingMode = .selectOne
        modeControl.segmentCount = PreviewMode.allCases.count
        for (index, mode) in PreviewMode.allCases.enumerated() {
            modeControl.setToolTip(mode.controlToolTip, forSegment: index)
            modeControl.setWidth(28, forSegment: index)
        }
        modeControl.selectedSegment = 0
        modeControl.target = target
        modeControl.action = action
        addSubview(modeControl)
        applySegmentTints()

        NSLayoutConstraint.activate([
            modeControl.topAnchor.constraint(equalTo: topAnchor, constant: Self.controlTopInset),
            modeControl.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Self.controlInset
            ),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setRevealed(true)
    }

    override func mouseExited(with event: NSEvent) {
        setRevealed(false)
    }

    /// Opacity and nothing else: no bounce, no scale, and the control does not
    /// move as it arrives.
    func setRevealed(_ revealed: Bool, animated: Bool = true) {
        // A tab with no control has nothing to reveal: hovering the band where
        // one would be brings back nothing.
        guard !isHidden || !revealed else { return }
        guard revealed != isRevealed else { return }
        isRevealed = revealed
        guard animated else {
            modeControl.alphaValue = revealed ? 1 : 0
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            modeControl.animator().alphaValue = revealed ? 1 : 0
        }
    }

    /// Only the control itself ever answers a click, and only while it is on
    /// screen. Everything else in the band belongs to the text under it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isRevealed, !isHidden else { return nil }
        guard modeControl.frame.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    // MARK: - The segments

    /// Shown and hidden as one piece, so nothing is left floating over the
    /// text when the tab it belongs to is not a Markdown one.
    func setAvailable(_ available: Bool) {
        if !available { setRevealed(false, animated: false) }
        isHidden = !available
        modeControl.isHidden = !available
    }

    /// The idle segments are quiet — `secondaryLabelColor`, so the control sits
    /// over the text without shouting at it — while the selected one keeps the
    /// standard filled look, which tints a template image for itself.
    func applySegmentTints() {
        for (index, mode) in PreviewMode.allCases.enumerated() {
            let image = NSImage(
                systemSymbolName: mode.symbolName, accessibilityDescription: mode.controlTitle
            )
            if index == modeControl.selectedSegment {
                image?.isTemplate = true
                modeControl.setImage(image, forSegment: index)
            } else {
                let quiet = image?.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor])
                )
                // Already coloured: template would have AppKit tint it again.
                quiet?.isTemplate = false
                modeControl.setImage(quiet, forSegment: index)
            }
        }
    }

    /// `secondaryLabelColor` is baked into the idle images, so they are drawn
    /// again when light and dark swap.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySegmentTints()
    }
}
