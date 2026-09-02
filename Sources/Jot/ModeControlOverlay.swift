import AppKit

/// The Editor · Split · Reading control, floating over the top-trailing corner
/// of whichever column is on screen.
///
/// It is not a row: nothing is pushed down for it, and the text starts right
/// under the tab strip. The control is only there while the pointer is near it
/// — anywhere in the band across the top of the column — and fades away again
/// when the pointer leaves, so a note being read has nothing but the note in
/// it.
///
/// The whole band is the hover target, but only the control's own backing ever
/// takes a click: `hitTest` hands everything else back to the text underneath,
/// so a line under the band stays as clickable as any other.
final class ModeControlOverlay: NSView {

    /// How far down the column the pointer counts as being near the control.
    static let hoverBandHeight: CGFloat = 44
    /// The control's inset from the trailing edge, matching the ⇧⌘F field's in
    /// the strip above, and its drop below the strip's hairline.
    static let controlInset: CGFloat = 12
    static let controlTopInset: CGFloat = 8
    /// The air between the control and the edge of its backing. The backing's
    /// radius is the control's plus this, so the two curves are concentric.
    private static let padding: CGFloat = 4
    private static let controlRadius: CGFloat = 6

    let modeControl = NSSegmentedControl()
    /// The rounded plate the control sits on: the editor's own background and
    /// a hairline, so the control never reads as part of the text under it.
    let backing = ModeControlBackingView()

    private var trackingArea: NSTrackingArea?

    /// Whether the control is on screen right now. Hover says so; a tab that
    /// is not Markdown, and zen, take the whole overlay away instead.
    private(set) var isRevealed = false

    /// The band is chrome over the text, not the title bar: dragging it must
    /// not move the window.
    override var mouseDownCanMoveWindow: Bool { false }

    init(target: AnyObject?, action: Selector) {
        super.init(frame: .zero)

        backing.translatesAutoresizingMaskIntoConstraints = false
        backing.wantsLayer = true
        backing.layer?.cornerRadius = Self.controlRadius + Self.padding
        backing.layer?.cornerCurve = .continuous
        backing.layer?.borderWidth = 1
        backing.alphaValue = 0
        addSubview(backing)

        modeControl.translatesAutoresizingMaskIntoConstraints = false
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
        backing.addSubview(modeControl)
        applySegmentTints()

        NSLayoutConstraint.activate([
            backing.topAnchor.constraint(equalTo: topAnchor, constant: Self.controlTopInset),
            backing.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Self.controlInset
            ),

            modeControl.topAnchor.constraint(equalTo: backing.topAnchor, constant: Self.padding),
            modeControl.bottomAnchor.constraint(
                equalTo: backing.bottomAnchor, constant: -Self.padding
            ),
            modeControl.leadingAnchor.constraint(
                equalTo: backing.leadingAnchor, constant: Self.padding
            ),
            modeControl.trailingAnchor.constraint(
                equalTo: backing.trailingAnchor, constant: -Self.padding
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
            backing.alphaValue = revealed ? 1 : 0
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            backing.animator().alphaValue = revealed ? 1 : 0
        }
    }

    /// Only the control's own plate ever answers a click, and only while it is
    /// on screen. Everything else in the band belongs to the text under it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isRevealed, !isHidden else { return nil }
        guard backing.frame.contains(convert(point, from: superview)) else { return nil }
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

/// The control's plate. The colours are dynamic, so they are laid on in
/// `updateLayer` rather than once at build time.
final class ModeControlBackingView: NSView {
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
