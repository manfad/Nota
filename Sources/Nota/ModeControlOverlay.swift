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
/// line under the band stays as clickable as any other — the ⌘F pill in the
/// same corner included.
///
/// ⌘F's bar wants that corner too. Rather than leaving, the control drops the
/// height of the pill and keeps working under it: the band grows by the same
/// amount, so the whole top of the column is still the hover target, and the
/// move is instant — the bar fades, the control is simply somewhere else by
/// the time it arrives.
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
    /// The gap between the pill's bottom edge and the control under it.
    static let findBarGap: CGFloat = 6
    /// How far the control drops while this column's find bar is up with
    /// nothing but its query row. The replace row makes the bar taller, and
    /// the control moves by whatever it actually measures — see `drop(for:)`.
    static let findBarDrop: CGFloat = drop(forFindBarOfHeight: FindBarView.height)

    static func drop(forFindBarOfHeight height: CGFloat) -> CGFloat { height + findBarGap }
    /// Close enough to the small rounded bezel's own corner radius that the
    /// fill reads as part of it, not a shape of its own.
    private static let controlFillCornerRadius: CGFloat = 5.5

    let modeControl = NSSegmentedControl()

    /// An opaque fill in the editor's own background colour, sized and
    /// rounded to the control's bezel and sitting directly behind it. The
    /// unselected segments' bezel is drawn with some translucency, so without
    /// this the text under the band shows straight through it. It is a
    /// sibling layer behind the control's own — never a subview, so the
    /// overlay's view hierarchy stays just the control — and it fades with
    /// the control because both are driven by the same animation.
    private let controlFill = CALayer()

    private var trackingArea: NSTrackingArea?
    private var controlTop: NSLayoutConstraint?
    private var bandHeight: NSLayoutConstraint?

    /// How far down the column the control sits, beyond its usual drop below
    /// the strip. Nothing while the column's find bar is away; the pill's
    /// height while it is up, so the two never share the corner.
    ///
    /// Not animated: a control that slid down as the bar faded in would be
    /// two movements where the taste allows one.
    var findBarClearance: CGFloat = 0 {
        didSet {
            guard findBarClearance != oldValue else { return }
            controlTop?.constant = Self.controlTopInset + findBarClearance
            bandHeight?.constant = Self.hoverBandHeight + findBarClearance
            needsLayout = true
        }
    }

    /// Whether the control is on screen right now. Hover says so; a tab that
    /// is not Markdown, and zen, take the whole overlay away instead.
    private(set) var isRevealed = false

    /// The band is chrome over the text, not the title bar: dragging it must
    /// not move the window.
    override var mouseDownCanMoveWindow: Bool { false }

    init(target: AnyObject?, action: Selector) {
        super.init(frame: .zero)

        // The overlay itself needs a layer to host the fill behind the
        // control — a sibling of the control's own layer, not one of its
        // sublayers, so it never draws over the segments it is filling in
        // behind.
        wantsLayer = true
        controlFill.opacity = 0
        controlFill.cornerRadius = Self.controlFillCornerRadius
        layer?.addSublayer(controlFill)
        applyControlFillColor()

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

        // The band's own height, rather than the window controller's, because
        // it grows with the control's drop and the two must move together.
        let top = modeControl.topAnchor.constraint(
            equalTo: topAnchor, constant: Self.controlTopInset
        )
        let height = heightAnchor.constraint(equalToConstant: Self.hoverBandHeight)
        controlTop = top
        bandHeight = height
        NSLayoutConstraint.activate([
            top,
            height,
            modeControl.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Self.controlInset
            ),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        updateControlFillGeometry()
    }

    /// Keeps the fill pinned to the bezel's own alignment rect, which is a
    /// little smaller than the control's frame, and directly behind it in
    /// the layer stack — the fill is added once in `init`, so this only
    /// keeps its geometry current across layout passes.
    private func updateControlFillGeometry() {
        guard let overlayLayer = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if controlFill.superlayer !== overlayLayer {
            overlayLayer.insertSublayer(controlFill, at: 0)
        }
        controlFill.frame = modeControl.alignmentRect(forFrame: modeControl.frame)
        CATransaction.commit()
    }

    private func applyControlFillColor() {
        controlFill.backgroundColor = NSColor.textBackgroundColor.cgColor
    }

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
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            controlFill.opacity = revealed ? 1 : 0
            CATransaction.commit()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            modeControl.animator().alphaValue = revealed ? 1 : 0
            // Set directly, not through an `animator()` proxy — `CALayer`
            // has none — but it still animates: an implicit layer animation
            // picks up this transaction's duration and timing, so the fill
            // fades in step with the control above it.
            controlFill.opacity = revealed ? 1 : 0
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

    /// `secondaryLabelColor` is baked into the idle images, and the fill's
    /// `CGColor` is resolved once rather than tracking the appearance on its
    /// own, so both are drawn again when light and dark swap.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySegmentTints()
        applyControlFillColor()
    }
}
