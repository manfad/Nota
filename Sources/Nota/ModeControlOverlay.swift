import AppKit

/// The corner slot: the band across the top of a column, and whatever the tab
/// in front puts in its top-trailing corner.
///
/// The band is the same for every tab — the hover, the fade, the hit testing
/// and the drop out of ⌘F's way are all here and know nothing of what they
/// are carrying. What stands in the corner is the tab's own business, and
/// there are three answers (`Content`): a tab with a render gets the Editor ·
/// Split · Reading control, a `.json` tab gets the Beautify / Compact button,
/// and everything else gets nothing at all — the whole overlay goes away and
/// the band takes no clicks.
///
/// The choice is made by what the note *is*, never by a list of extensions
/// kept here: `Note.supportsRenderedPreview` answers the first, so a new kind
/// of render arrives in this corner without a line of this file changing.
///
/// There is one slot per column — the editor's and the preview's — so in
/// split mode each half of a rendered document has its own mode control, and
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
    /// One segment's width, so the button that stands where the three of them
    /// would have stood is the same shape as one of them.
    private static let jsonButtonWidth: CGFloat = 28

    /// What is standing in this column's corner. One slot, three answers, and
    /// the band around them is the same whichever it is.
    enum Content: Equatable {
        /// Nothing: a `.txt`, an untitled note, a PDF, zen. The overlay goes
        /// away whole, so the band takes no clicks at all.
        case none
        /// Editor · Split · Reading, for a tab with a render beside it.
        case modeControl
        /// Beautify / Compact, for a `.json` tab.
        case jsonFormat
    }

    /// Which way the JSON button would lay the file out — the one it is not
    /// laid out in already.
    enum JSONAction: Equatable {
        case beautify, compact

        /// Outline symbols, the pair the Mac itself uses for text laid out in
        /// lines and for something pulled back into its corner.
        var symbolName: String {
            switch self {
            case .beautify: "text.alignleft"
            case .compact: "arrow.down.right.and.arrow.up.left"
            }
        }

        var toolTip: String {
            switch self {
            case .beautify: "Beautify JSON"
            case .compact: "Compact JSON"
            }
        }
    }

    /// What the JSON button is showing: the reformat on offer, or the line the
    /// parse gave up on, which is the whole of what the reader needs in order
    /// to go and look at it.
    enum JSONState: Equatable {
        case action(JSONAction)
        case invalid(line: Int)
    }

    let modeControl = NSSegmentedControl()

    /// The `.json` tab's button, in the same corner and the same bezel. One
    /// button rather than two: the file is in one of the two shapes already,
    /// so the only thing worth offering is the other one.
    let jsonButton = NSButton()

    /// Which of them is up. `.modeControl` to begin with, which is the state
    /// every overlay was in before the slot had more than one thing to hold.
    private(set) var content: Content = .modeControl

    private(set) var jsonState: JSONState = .action(.beautify)

    /// What the window does when the JSON button is pressed. The button hands
    /// on the reformat it was offering, so the window never has to ask which
    /// way round it was.
    var onJSONFormat: ((JSONAction) -> Void)?

    /// The one control the slot is showing, or nothing at all. Everything
    /// about the band — the fade, the fill behind it, what a click lands on —
    /// asks this rather than naming a control.
    private var activeControl: NSControl? {
        switch content {
        case .none: nil
        case .modeControl: modeControl
        case .jsonFormat: jsonButton
        }
    }

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

    /// Whether the slot's control is on screen right now. Hover says so; a tab
    /// with nothing to put here, and zen, take the whole overlay away instead.
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

        jsonButton.translatesAutoresizingMaskIntoConstraints = false
        jsonButton.wantsLayer = true
        jsonButton.alphaValue = 0
        // The same bezel and the same control size as the segmented control
        // beside it, so the corner reads as one slot holding different things
        // rather than as two pieces of chrome that happen to share a corner.
        jsonButton.bezelStyle = .rounded
        jsonButton.controlSize = .small
        jsonButton.imagePosition = .imageOnly
        jsonButton.title = ""
        jsonButton.isHidden = true
        jsonButton.target = self
        jsonButton.action = #selector(jsonButtonClicked)
        addSubview(jsonButton)
        applyJSONState()

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
            // The same corner to the pixel: whichever of the two is up, it
            // stands where the reader's eye already goes.
            jsonButton.topAnchor.constraint(equalTo: modeControl.topAnchor),
            jsonButton.trailingAnchor.constraint(equalTo: modeControl.trailingAnchor),
            jsonButton.widthAnchor.constraint(equalToConstant: Self.jsonButtonWidth),
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
        if let control = activeControl {
            controlFill.frame = control.alignmentRect(forFrame: control.frame)
        }
        CATransaction.commit()
    }

    private func applyControlFillColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            controlFill.backgroundColor = NSColor.textBackgroundColor.cgColor
        }
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
            applyRevealedAlpha()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            controlFill.opacity = revealed ? 1 : 0
            CATransaction.commit()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            activeControl?.animator().alphaValue = revealed ? 1 : 0
            // Set directly, not through an `animator()` proxy — `CALayer`
            // has none — but it still animates: an implicit layer animation
            // picks up this transaction's duration and timing, so the fill
            // fades in step with the control above it.
            controlFill.opacity = revealed ? 1 : 0
        }
    }

    /// Both controls carry the reveal, not only the one that is up: a slot
    /// that changes hands while the pointer is in the band hands the new
    /// control over already visible rather than blank.
    private func applyRevealedAlpha() {
        let alpha: CGFloat = isRevealed ? 1 : 0
        modeControl.alphaValue = alpha
        jsonButton.alphaValue = alpha
    }

    /// Only the control itself ever answers a click, and only while it is on
    /// screen. Everything else in the band belongs to the text under it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isRevealed, !isHidden, let control = activeControl else { return nil }
        guard control.frame.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    // MARK: - What the slot is holding

    /// The front tab said what belongs here. `.none` takes the whole overlay
    /// away, so nothing is left floating over the text and the band under it
    /// takes no clicks at all.
    func setContent(_ content: Content) {
        guard content != self.content else { return }
        if content == .none { setRevealed(false, animated: false) }
        self.content = content
        isHidden = content == .none
        modeControl.isHidden = content != .modeControl
        jsonButton.isHidden = content != .jsonFormat
        applyRevealedAlpha()
        needsLayout = true
        updateControlFillGeometry()
    }

    /// Whether the mode control is what this slot is holding — the question
    /// the window's own layout asks, since only a rendered tab has modes.
    func setAvailable(_ available: Bool) {
        setContent(available ? .modeControl : .none)
    }

    // MARK: - The JSON button

    /// What the button offers, and what it says it cannot do. Invalid JSON
    /// leaves it there but disabled: the corner keeps its shape, and the tool
    /// tip names the line rather than making the reader hunt for it.
    func setJSONState(_ state: JSONState) {
        guard state != jsonState else { return }
        jsonState = state
        applyJSONState()
    }

    private func applyJSONState() {
        switch jsonState {
        case .action(let action):
            jsonButton.isEnabled = true
            jsonButton.toolTip = action.toolTip
        case .invalid(let line):
            jsonButton.isEnabled = false
            jsonButton.toolTip = "Not valid JSON: line \(line)"
        }
        applyJSONTint()
    }

    /// The same quiet the idle segments have — `secondaryLabelColor` over the
    /// text, a step quieter again while there is nothing to press. The colour
    /// is baked into the image rather than left to AppKit, which is what keeps
    /// the button and the segments beside it reading as one family.
    private func applyJSONTint() {
        let action: JSONAction = {
            if case .action(let action) = jsonState { return action }
            // A file that will not parse still shows the beautify symbol: it
            // is the shape of the offer, greyed out, not a second state.
            return .beautify
        }()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let colour: NSColor = jsonButton.isEnabled ? .secondaryLabelColor : .tertiaryLabelColor
            let image = NSImage(
                systemSymbolName: action.symbolName, accessibilityDescription: action.toolTip
            )?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(paletteColors: [colour])
            )
            // Already coloured: template would have AppKit tint it again.
            image?.isTemplate = false
            jsonButton.image = image
        }
    }

    @objc private func jsonButtonClicked() {
        guard case .action(let action) = jsonState else { return }
        onJSONFormat?(action)
    }

    /// The idle segments are quiet — `secondaryLabelColor`, so the control sits
    /// over the text without shouting at it — while the selected one keeps the
    /// standard filled look, which tints a template image for itself.
    func applySegmentTints() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
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
    }

    /// `secondaryLabelColor` is baked into the idle images, and the fill's
    /// `CGColor` is resolved once rather than tracking the appearance on its
    /// own, so both are drawn again when light and dark swap.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySegmentTints()
        applyJSONTint()
        applyControlFillColor()
    }
}
