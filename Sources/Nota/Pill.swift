import AppKit

/// What a pill's field editor hands a menu action back to. ⌘F, ⌘G and their
/// neighbours are nil-targeted, so while the reader is typing in a pill they
/// reach the window's field editor first; this is how they get from there to
/// the pill that ought to answer them.
protocol PillActionResponder: AnyObject {
    func perform(_ action: NSTextFinder.Action)
    func handles(_ action: NSTextFinder.Action) -> Bool
}

/// The chrome every one of Nota's floating bars is made of: a small rounded
/// surface in the top-trailing corner of a column, over the text rather than
/// above it.
///
/// Nothing is pushed down for a pill. It fades in and out — opacity only, no
/// movement, under 150ms — takes no clicks while it is away, and stacks with
/// the others in the same corner, each `gap` under the one before it. The mode
/// control drops below the whole stack.
///
/// A pill carries one row and no more. ⌘F's query is one, its replacement is a
/// second below it, and ⌘J's line number is another that stands alone. What
/// goes in the row is the subclass's business; the surface, the fade and the
/// glyphs' quiet colouring are all here.
class PillView: NSView {

    static let height: CGFloat = 34
    static let width: CGFloat = 300
    /// The air between two pills stacked in one corner.
    static let gap: CGFloat = 6
    private static let cornerRadius: CGFloat = 10

    /// Whether the pill is up. Not `isHidden`: the fade out finishes after
    /// this is already false, and everything that asks — the mode control,
    /// the tests — means "is it open".
    private(set) var isShown = false

    /// Run when the pill arrives or leaves.
    var onVisibilityChange: ((Bool) -> Void)?

    /// Chrome over the text, not the title bar: dragging it must not move the
    /// window.
    override var mouseDownCanMoveWindow: Bool { false }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.borderWidth = 1
        let drop = NSShadow()
        drop.shadowColor = NSColor.black.withAlphaComponent(0.18)
        drop.shadowBlurRadius = 8
        drop.shadowOffset = NSSize(width: 0, height: -2)
        shadow = drop
        applyColors()

        alphaValue = 0
        isHidden = true

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Floats the pill in a column's corner, under whatever it stacks below —
    /// the column's own top edge, or the pill above it.
    func float(in container: NSView, under top: NSLayoutYAxisAnchor, gap: CGFloat,
               trailingInset: CGFloat) {
        container.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: top, constant: gap),
            trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -trailingInset
            ),
        ])
    }

    /// Opacity and nothing else — the pill does not slide in.
    func setShown(_ shown: Bool, animated: Bool = true) {
        guard shown != isShown else { return }
        isShown = shown
        if shown { isHidden = false }
        if animated, window != nil {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().alphaValue = shown ? 1 : 0
            }, completionHandler: { [weak self] in
                guard let self, !self.isShown else { return }
                self.isHidden = true
            })
        } else {
            alphaValue = shown ? 1 : 0
            isHidden = !shown
        }
        onVisibilityChange?(shown)
    }

    /// The other corner: a pill that stands at the *bottom* of a column
    /// rather than the top. Nothing stacks under it, so there is only ever
    /// the one — the top-trailing corner is where the stack lives.
    func floatBottom(in container: NSView, above bottom: NSLayoutYAxisAnchor,
                     gap: CGFloat, trailingInset: CGFloat) {
        container.addSubview(self)
        NSLayoutConstraint.activate([
            bottomAnchor.constraint(equalTo: bottom, constant: -gap),
            trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -trailingInset
            ),
        ])
    }

    /// A pill that is away answers no clicks, whatever its layer is still
    /// fading through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isShown else { return nil }
        return super.hitTest(point)
    }

    // MARK: - What a pill is made of

    /// A borderless glyph button: a hit target and nothing drawn round it.
    func glyphButton(tooltip: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.bezelStyle = .shadowlessSquare
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.focusRingType = .none
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 24),
        ])
        return button
    }

    /// A word rather than a bezel, so a row reads as one line and not as a
    /// dialogue with buttons in it.
    func wordButton(title: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.bezelStyle = .shadowlessSquare
        button.imagePosition = .noImage
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.focusRingType = .none
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.identifier = NSUserInterfaceItemIdentifier(title)
        Self.applyTitle(to: button)
        return button
    }

    static func applyTitle(to button: NSButton) {
        button.attributedTitle = NSAttributedString(
            string: button.identifier?.rawValue ?? "",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
    }

    /// The pill's own kind of field: borderless, no background, and none of
    /// AppKit's focus ring — the slab of light blue that would be most of the
    /// pill. It knows which pill answers for it, so the window can hand it the
    /// right field editor.
    ///
    /// Dressed rather than built, since a subclass's `let` field has to exist
    /// before `super.init` runs and cannot name `self` until after it.
    static func style(
        _ field: PillTextField, placeholder: String,
        owner: AnyObject & PillActionResponder & NSTextFieldDelegate
    ) {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = owner
        field.owner = owner
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    /// The small right-hand label a pill says its count in.
    static func quietLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.isHidden = true
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    /// The glyphs are coloured rather than templates, the way the mode
    /// control's idle segments are, so AppKit does not tint them again.
    static func symbol(
        _ name: String, pointSize: CGFloat, label: String,
        colour: NSColor = .secondaryLabelColor
    ) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: label)
        let quiet = image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [colour]))
        )
        quiet?.isTemplate = false
        return quiet
    }

    /// A symbol with a small chevron after it, drawn as one image so a
    /// glyph button can wear both: the chevron is what says "this opens
    /// something". `up` for a control whose something is already out.
    static func symbolWithChevron(
        _ name: String, pointSize: CGFloat, label: String,
        colour: NSColor = .secondaryLabelColor, up: Bool
    ) -> NSImage? {
        guard let glyph = symbol(name, pointSize: pointSize, label: label, colour: colour),
              let chevron = symbol(up ? "chevron.up" : "chevron.down", pointSize: 6,
                                   label: "", colour: colour)
        else { return nil }
        let gap: CGFloat = 1
        let size = NSSize(
            width: glyph.size.width + gap + chevron.size.width,
            height: max(glyph.size.height, chevron.size.height)
        )
        let image = NSImage(size: size, flipped: false) { _ in
            glyph.draw(in: NSRect(
                x: 0, y: (size.height - glyph.size.height) / 2,
                width: glyph.size.width, height: glyph.size.height
            ))
            chevron.draw(in: NSRect(
                x: glyph.size.width + gap, y: (size.height - chevron.size.height) / 2,
                width: chevron.size.width, height: chevron.size.height
            ))
            return true
        }
        image.accessibilityDescription = label
        image.isTemplate = false
        return image
    }

    static func glyphView(_ image: NSImage?) -> NSImageView {
        let view = NSImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.imageScaling = .scaleProportionallyDown
        view.image = image
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 14),
            view.heightAnchor.constraint(equalToConstant: 14),
        ])
        return view
    }

    // MARK: - Colours

    /// A raised surface: `windowBackgroundColor` stands off the paper the text
    /// is on in both appearances, where `controlBackgroundColor` is the same
    /// colour as the paper and would leave the pill as a hairline outline.
    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    /// Laid on again when light and dark swap. A pill with glyphs in it says
    /// here how they are drawn.
    func applySymbols() { }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
        applySymbols()
    }
}

// MARK: - The fields

/// A field in a pill. It knows which pill answers for it so the window can
/// hand it the right field editor — see `PillFieldEditor`.
final class PillTextField: NSTextField {
    weak var owner: (AnyObject & PillActionResponder)?
}

/// The field editor Nota hands its pills' fields.
///
/// Find…, Find and Replace…, Find Next, Find Previous and Use Selection for
/// Find are nil-targeted `performTextFinderAction:` menu items, so they go to
/// the first responder first — and while the reader is typing in a pill, that
/// is the window's field editor, an `NSTextView` of AppKit's own which would
/// answer for them with a find bar of its own. This one passes them back to
/// the pill the field belongs to instead, so ⌘G in a field is the same ⌘G as
/// everywhere else.
final class PillFieldEditor: NSTextView {
    /// The pill whose field is currently being edited. The window sets it as
    /// it hands the editor over, since one editor serves every field in the
    /// window.
    weak var owner: (AnyObject & PillActionResponder)?

    override func performTextFinderAction(_ sender: Any?) {
        guard let item = sender as? NSValidatedUserInterfaceItem,
              let action = NSTextFinder.Action(rawValue: item.tag),
              owner?.handles(action) == true
        else { return }
        owner?.perform(action)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(NSTextView.performTextFinderAction(_:)) else {
            return super.validateUserInterfaceItem(item)
        }
        guard let action = NSTextFinder.Action(rawValue: item.tag) else { return false }
        return owner?.handles(action) == true
    }
}
