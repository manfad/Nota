import AppKit

/// The zoom pill: `−  100%  +` in the bottom-leading corner of the preview
/// column, and the band under the column it lives in.
///
/// It is the mode control's twin at the other end of the diagonal — the same
/// small rounded bezel, the same opaque fill behind it, the same quiet symbol
/// tint, the same band that hovers it into view and hands every other click
/// back to what is underneath. What differs is why it is there: the corner
/// slot is a thing you go to, and this is a thing that answers. It appears
/// when the reader zooms and takes itself away again a second and a half
/// later, and it appears while the pointer is down in its own corner, for a
/// reader who wants the buttons rather than the keys.
///
/// Two things say it should be on screen and either is enough: the timer
/// after the last zoom, and the pointer in the band. So a reader who zooms
/// and then goes for the `+` finds it still there, and one who is only
/// reading sees the number for as long as it is news and no longer.
///
/// The three segments are ⌘-, ⌘0 and ⌘+ — the same three keys, pressed with
/// the mouse. The percentage is of the content's own actual size, so a page
/// fitted to the column reads 100% whatever scale that actually is, and a
/// content with no answer (a render, a grid) has no pill at all.
///
/// Zen keeps it. It is transient by nature: there is nothing to hide from a
/// reader in a thing that is only there while it is being used.
final class ZoomPillOverlay: NSView {

    /// How far up the column the pointer counts as being near the pill —
    /// the mirror of the corner slot's band at the top.
    static let hoverBandHeight: CGFloat = ModeControlOverlay.hoverBandHeight
    /// The pill's inset from the leading edge and its lift off the bottom,
    /// the same pair the mode control uses in the opposite corner.
    static let controlInset: CGFloat = ModeControlOverlay.controlInset
    static let controlBottomInset: CGFloat = ModeControlOverlay.controlTopInset

    /// How long the pill stays after the last zoom, and the two fades. In
    /// and out are not the same length: arriving should be quick enough to
    /// carry the number that was just asked for, leaving slow enough not to
    /// snatch it away.
    static let holdDuration: TimeInterval = 1.5
    static let fadeInDuration: TimeInterval = 0.15
    static let fadeOutDuration: TimeInterval = 0.3

    /// Close enough to the small rounded bezel's own corner radius that the
    /// fill reads as part of it, not a shape of its own.
    private static let controlFillCornerRadius: CGFloat = 5.5
    /// The two symbol segments, the same width as one segment of the mode
    /// control.
    private static let buttonSegmentWidth: CGFloat = 28

    /// The one control's font. Monospaced digits, so 100% and 111% are the
    /// same width and the number does not shuffle as it counts.
    private static let labelFont = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.smallSystemFontSize, weight: .regular
    )

    /// Wide enough for `1000%`, which is past anything any content will
    /// actually reach, so the pill is one shape for the whole of a zoom
    /// rather than a thing that grows a pixel at 100%.
    private static let labelSegmentWidth: CGFloat = {
        let width = ("1000%" as NSString)
            .size(withAttributes: [.font: labelFont]).width
        return (width + 12).rounded(.up)
    }()

    /// What a segment means. The same three things the View menu's size items
    /// mean, in the same order the reader reads them.
    enum Command: Equatable {
        case zoomOut, actualSize, zoomIn
    }

    private static let commands: [Command] = [.zoomOut, .actualSize, .zoomIn]

    let control = NSSegmentedControl()

    /// What the window does when a segment is pressed. It presses the key:
    /// there is one path through the window for a zoom, and a click on the
    /// pill is on it rather than beside it.
    var onCommand: ((Command) -> Void)?

    /// What the pill is saying, and whether it has anything to say at all.
    /// `nil` is a tab whose content does not zoom — a render, a grid, a
    /// document beside an editor — and takes the whole overlay away.
    private(set) var percent: Int?

    /// Whether the pill is on screen right now.
    private(set) var isRevealed = false

    /// Whether the pointer is in the band. One of the two things that keep
    /// the pill up; the timer is the other.
    private(set) var isHovering = false

    private var holdWork: DispatchWorkItem?

    /// An opaque fill in the editor's own background colour, sized and
    /// rounded to the control's bezel and sitting directly behind it — the
    /// unselected segments are translucent, and without it the content
    /// under the pill shows straight through. A sibling layer, never a
    /// subview, and it fades with the control because both are driven by
    /// the same animation.
    private let controlFill = CALayer()

    private var trackingArea: NSTrackingArea?

    /// The band is chrome over the content, not the title bar: dragging it
    /// must not move the window.
    override var mouseDownCanMoveWindow: Bool { false }

    init() {
        super.init(frame: .zero)

        wantsLayer = true
        controlFill.opacity = 0
        controlFill.cornerRadius = Self.controlFillCornerRadius
        layer?.addSublayer(controlFill)
        applyControlFillColor()

        control.translatesAutoresizingMaskIntoConstraints = false
        // The fade is an opacity animation, so the control wants a layer of
        // its own to run it on.
        control.wantsLayer = true
        control.alphaValue = 0
        control.segmentStyle = .rounded
        control.controlSize = .small
        control.font = Self.labelFont
        // Nothing here is a state to be in: each segment is a press.
        control.trackingMode = .momentary
        control.segmentCount = Self.commands.count
        control.setWidth(Self.buttonSegmentWidth, forSegment: 0)
        control.setWidth(Self.labelSegmentWidth, forSegment: 1)
        control.setWidth(Self.buttonSegmentWidth, forSegment: 2)
        control.target = self
        control.action = #selector(segmentClicked)
        addSubview(control)
        applyToolTips()
        applyPercent()
        applySegmentTints()

        // The whole overlay is hidden until a content that zooms is in
        // front: a band that reveals nothing is a band that should not be
        // taking mouse events at all.
        isHidden = true

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.hoverBandHeight),
            control.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: Self.controlInset
            ),
            control.bottomAnchor.constraint(
                equalTo: bottomAnchor, constant: -Self.controlBottomInset
            ),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        updateControlFillGeometry()
    }

    /// Keeps the fill pinned to the bezel's own alignment rect, which is a
    /// little smaller than the control's frame, and behind it in the layer
    /// stack.
    private func updateControlFillGeometry() {
        guard let overlayLayer = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if controlFill.superlayer !== overlayLayer {
            overlayLayer.insertSublayer(controlFill, at: 0)
        }
        controlFill.frame = control.alignmentRect(forFrame: control.frame)
        CATransaction.commit()
    }

    private func applyControlFillColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            controlFill.backgroundColor = NSColor.textBackgroundColor.cgColor
        }
    }

    // MARK: - What it says

    /// The number in the middle, or `nil` for a tab with no zoom to report,
    /// which takes the pill away at once — a Markdown tab arriving in front
    /// of a PDF must not leave the PDF's percentage floating over it.
    func setPercent(_ percent: Int?) {
        self.percent = percent
        guard percent != nil else {
            holdWork?.cancel()
            holdWork = nil
            setRevealed(false, animated: false)
            isHidden = true
            return
        }
        isHidden = false
        applyPercent()
    }

    /// A zoom happened — a key, a pinch, or the pill's own buttons. The new
    /// number goes up, the pill comes in, and the clock starts again from
    /// this change rather than from the first of a run of them.
    func noteZoomChanged(percent: Int?) {
        setPercent(percent)
        guard percent != nil else { return }
        setRevealed(true)
        startHold()
    }

    private func applyPercent() {
        control.setLabel("\(percent ?? 100)%", forSegment: 1)
    }

    private func applyToolTips() {
        control.setToolTip(L10n.text("Zoom Out"), forSegment: 0)
        control.setToolTip(L10n.text("Actual Size"), forSegment: 1)
        control.setToolTip(L10n.text("Zoom In"), forSegment: 2)
    }

    // MARK: - When it is on screen

    private func startHold() {
        holdWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.holdExpired() }
        holdWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDuration, execute: work)
    }

    private func holdExpired() {
        holdWork = nil
        // The pointer in the band is the other reason to be up, and it
        // outlives the clock.
        guard !isHovering else { return }
        setRevealed(false)
    }

    /// Fires the hold immediately — the tests' way of reaching 1.5 s from
    /// now without waiting 1.5 s.
    func fireHoldTimerForTesting() {
        guard let work = holdWork else { return }
        work.cancel()
        holdExpired()
    }

    /// The pointer is in the band, or has left it. Driven by the tracking
    /// area, and by the tests, which have no pointer.
    func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        guard hovering else {
            // Leaving puts the pill down unless the clock is still running,
            // in which case it has its own reason to be there.
            if holdWork == nil { setRevealed(false) }
            return
        }
        guard percent != nil else { return }
        setRevealed(true)
    }

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

    override func mouseEntered(with event: NSEvent) { setHovering(true) }

    override func mouseExited(with event: NSEvent) { setHovering(false) }

    /// Opacity and nothing else: no bounce, no scale, and the pill does not
    /// move as it arrives.
    func setRevealed(_ revealed: Bool, animated: Bool = true) {
        guard !isHidden || !revealed else { return }
        guard revealed != isRevealed else { return }
        isRevealed = revealed
        guard animated else {
            control.alphaValue = revealed ? 1 : 0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            controlFill.opacity = revealed ? 1 : 0
            CATransaction.commit()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = revealed ? Self.fadeInDuration : Self.fadeOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            control.animator().alphaValue = revealed ? 1 : 0
            // Set directly, not through an `animator()` proxy — `CALayer` has
            // none — but it still animates: an implicit layer animation picks
            // up this transaction's duration and timing.
            controlFill.opacity = revealed ? 1 : 0
        }
    }

    /// Only the control itself ever answers a click, and only while it is on
    /// screen. Everything else in the band belongs to the content under it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isRevealed, !isHidden else { return nil }
        guard control.frame.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    // MARK: - Pressing it

    @objc private func segmentClicked() {
        sendCommand(forSegment: control.selectedSegment)
    }

    /// A press on one segment by its index. `.momentary` keeps no selection
    /// of its own — `selectedSegment` is only meaningful for the length of a
    /// real click — so this is also the tests' way in.
    func pressSegment(_ index: Int) {
        sendCommand(forSegment: index)
    }

    private func sendCommand(forSegment index: Int) {
        guard Self.commands.indices.contains(index) else { return }
        onCommand?(Self.commands[index])
    }

    /// The two symbols are as quiet as the corner slot's idle segments —
    /// `secondaryLabelColor` baked into the image rather than left to AppKit,
    /// which is what keeps the two ends of the diagonal reading as one
    /// family. The number in the middle is a label and takes the control's
    /// own text colour.
    func applySegmentTints() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for (index, name) in [(0, "minus"), (2, "plus")] {
                let image = NSImage(
                    systemSymbolName: name, accessibilityDescription: nil
                )?.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor])
                )
                // Already coloured: template would have AppKit tint it again.
                image?.isTemplate = false
                control.setImage(image, forSegment: index)
            }
        }
    }

    /// The tints are baked in and the fill's `CGColor` is resolved once, so
    /// both are drawn again when light and dark swap.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySegmentTints()
        applyControlFillColor()
    }
}
