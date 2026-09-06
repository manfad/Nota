import AppKit

/// The offer a tab makes when its file has changed on disk while the tab had
/// edits of its own: take the file's text, or keep what is in the editor.
///
/// The same chrome the find bar and ⌘J's pill are made of, in the editor
/// column's *other* corner. The top-trailing one belongs to ⌘F and ⌘J, which
/// send each other away as they arrive; this is not a tool the reader opened,
/// it is the file speaking up, and it has to be able to stand there while a
/// search is open — so it takes the bottom-trailing corner and leaves the
/// stack, and the mode control under it, alone.
///
/// Non-modal and quiet: nothing is pushed down for it, it never takes the
/// keyboard, and it goes the moment either word is clicked. One offer per
/// change — a further change on disk is the only thing that brings it back.
final class ExternalChangePill: PillView {

    /// Take the file's text and let the edits go.
    var onReload: (() -> Void)?
    /// Keep the buffer. The tab stays dirty and marked, and the next ⌘S
    /// writes over the file.
    var onKeepMine: (() -> Void)?

    private static let symbolName = "clock.arrow.circlepath"
    private static let label = "Changed on disk"

    private let icon: NSImageView
    private let message = NSTextField(labelWithString: ExternalChangePill.label)
    private var reloadButton = NSButton()
    private var keepButton = NSButton()

    override init() {
        icon = PillView.glyphView(
            PillView.symbol(Self.symbolName, pointSize: 12, label: Self.label)
        )
        super.init()

        message.translatesAutoresizingMaskIntoConstraints = false
        message.font = .systemFont(ofSize: 11)
        message.textColor = .secondaryLabelColor
        message.lineBreakMode = .byTruncatingTail
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        reloadButton = wordButton(
            title: "Reload", tooltip: "Take the file’s text", action: #selector(reloadClicked)
        )
        keepButton = wordButton(
            title: "Keep mine",
            tooltip: "Keep the editor’s text; the next save writes over the file",
            action: #selector(keepMineClicked)
        )

        for view in [icon, message, reloadButton, keepButton] as [NSView] { addSubview(view) }

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),

            message.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            message.centerYAnchor.constraint(equalTo: centerYAnchor),
            message.trailingAnchor.constraint(
                lessThanOrEqualTo: reloadButton.leadingAnchor, constant: -8
            ),

            reloadButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            reloadButton.trailingAnchor.constraint(
                equalTo: keepButton.leadingAnchor, constant: -10
            ),

            keepButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            keepButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The glyph is coloured rather than templated, so it is laid on again
    /// when light and dark swap — and so are the two words.
    override func applySymbols() {
        icon.image = PillView.symbol(Self.symbolName, pointSize: 12, label: Self.label)
        PillView.applyTitle(to: reloadButton)
        PillView.applyTitle(to: keepButton)
    }

    @objc private func reloadClicked() { onReload?() }
    @objc private func keepMineClicked() { onKeepMine?() }

    /// The two words, for the tests to press without a mouse.
    var wordsForTesting: (reload: NSButton, keepMine: NSButton) { (reloadButton, keepButton) }
}
