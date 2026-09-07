import AppKit

/// The offer Nota makes when an untitled note turns out to be holding
/// something: "JSON detected — Preview in JSON / Not now".
///
/// The same chrome and the same corner as `ExternalChangePill`, and for the
/// same reason: this is not a tool the reader opened, it is Nota speaking up,
/// and it has to be able to stand there while a search is open. Non-modal,
/// never takes the keyboard, and goes the moment either word is clicked —
/// an alert here would stop the typing that produced the text in the first
/// place, which is the one thing an offer must not do.
///
/// Once per tab per reading. "Not now" is remembered on the note against the
/// kind it declined, so only text that reads as something *else* ever brings
/// the pill back.
final class FormatOfferPill: PillView {

    /// Take the offer: the tab is that format from here on, exactly as if the
    /// format had been picked in the footer.
    var onAccept: (() -> Void)?
    /// Leave it. The tab stays as it is, and this reading is not offered
    /// again.
    var onDismiss: (() -> Void)?

    /// The offer carries a sentence and two words rather than a text field,
    /// and the longest of them — "Markdown detected · Preview in Markdown"
    /// — does not fit the ordinary pill.
    override class var width: CGFloat { 380 }

    /// What is being offered, so the words can be laid on again when the
    /// language changes under a pill that is already up.
    private(set) var offeredKind: RenderedPreviewKind?

    private static let symbolName = "wand.and.stars"

    private let icon: NSImageView
    private let message = NSTextField(labelWithString: "")
    private var acceptButton = NSButton()
    private var dismissButton = NSButton()

    override init() {
        icon = PillView.glyphView(
            PillView.symbol(Self.symbolName, pointSize: 12, label: "")
        )
        super.init()

        message.translatesAutoresizingMaskIntoConstraints = false
        message.font = .systemFont(ofSize: 11)
        message.textColor = .secondaryLabelColor
        message.lineBreakMode = .byTruncatingTail
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        acceptButton = wordButton(
            title: "", tooltip: "", action: #selector(acceptClicked)
        )
        dismissButton = wordButton(
            title: FormatOfferPill.dismissTitle,
            tooltip: FormatOfferPill.dismissTooltip,
            action: #selector(dismissClicked)
        )

        for view in [icon, message, acceptButton, dismissButton] as [NSView] { addSubview(view) }

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),

            message.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            message.centerYAnchor.constraint(equalTo: centerYAnchor),
            message.trailingAnchor.constraint(
                lessThanOrEqualTo: acceptButton.leadingAnchor, constant: -8
            ),

            acceptButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            acceptButton.trailingAnchor.constraint(
                equalTo: dismissButton.leadingAnchor, constant: -10
            ),

            dismissButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Puts a reading in the pill. The name of a format is the same in every
    /// language, so only the sentence around it is translated — one string
    /// with the name filled in, the way the update line on the About page is
    /// written.
    func offer(_ kind: RenderedPreviewKind) {
        offeredKind = kind
        applyWords()
    }

    private func applyWords() {
        guard let offeredKind else { return }
        let name = NoteFormat.preview(offeredKind).displayName
        message.stringValue = String(format: FormatOfferPill.messageFormat, name)
        acceptButton.identifier = NSUserInterfaceItemIdentifier(
            String(format: FormatOfferPill.acceptFormat, name)
        )
        acceptButton.toolTip = String(format: FormatOfferPill.acceptTooltipFormat, name)
        PillView.applyTitle(to: acceptButton)
    }

    /// The glyph is coloured rather than templated, so it is laid on again
    /// when light and dark swap — and so are the two words.
    override func applySymbols() {
        icon.image = PillView.symbol(Self.symbolName, pointSize: 12, label: "")
        dismissButton.identifier = NSUserInterfaceItemIdentifier(FormatOfferPill.dismissTitle)
        dismissButton.toolTip = FormatOfferPill.dismissTooltip
        PillView.applyTitle(to: dismissButton)
        applyWords()
    }

    @objc private func acceptClicked() { onAccept?() }
    @objc private func dismissClicked() { onDismiss?() }

    /// The two words, for the tests to press without a mouse.
    var wordsForTesting: (accept: NSButton, dismiss: NSButton) { (acceptButton, dismissButton) }

    /// What the pill says right now — for the tests, and for nothing else.
    var messageForTesting: String { message.stringValue }

    // MARK: - The words

    private static var messageFormat: String {
        L10n.text("%@ detected")
    }

    private static var acceptFormat: String {
        L10n.text("Preview in %@")
    }

    private static var acceptTooltipFormat: String {
        L10n.text("Show this tab in %@")
    }

    private static var dismissTitle: String {
        L10n.text("Not now")
    }

    private static var dismissTooltip: String {
        L10n.text("Keep this tab as it is")
    }
}

/// The other half of the offer: the question Nota asks when a note arrives
/// whole rather than a letter at a time.
///
/// A paste and a drop are not typing, and there is nothing to interrupt —
/// the reader has just put a document in front of themselves and is looking
/// straight at it, so that case is worth a real sheet with a default button
/// on Return. The typing pause keeps the pill above, where an alert would
/// stop the very keystrokes that produced the text.
///
/// The same two words as the pill, and a line underneath saying where to
/// change its mind later, so the sheet never reads as the last chance to
/// decide.
enum FormatOfferAlert {

    /// The sheet, built and not yet shown. The caller owns the window it
    /// hangs on and the answer it gives.
    static func make(for kind: RenderedPreviewKind) -> NSAlert {
        let name = NoteFormat.preview(kind).displayName
        let alert = NSAlert()
        alert.messageText = String(format: L10n.text("%@ detected"), name)
        alert.informativeText = String(format: L10n.text("Preview this tab in %@?"), name)
            + " "
            + L10n.text("You can change this any time from the format badge in the footer.")
        // First is the default button, so Return takes the offer.
        alert.addButton(withTitle: String(format: L10n.text("Preview in %@"), name))
        alert.addButton(withTitle: L10n.text("Not now"))
        return alert
    }
}
