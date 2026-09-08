import AppKit

/// The `Location:` row both of Nota's own file dialogs wear — the Save
/// dialog's (SPEC Done 51) and the Export sheet's (Done 62).
///
/// One folder, shown the way the Finder shows it: the folder's own icon, its
/// name after it, and the whole path behind a tooltip. The field is read only
/// — a path is not something to be typed — so the row's other half is
/// `Choose…`, which opens the system's folder picker, the one part of a save
/// form a hand-built dialog has no business reimplementing.
///
/// The picker is run modally *inside* whichever dialog put the row up: a
/// nested `runModal` is what AppKit documents for a panel opened from a modal
/// window, and a sheet on a sheet is not a Mac shape anyway.
@MainActor
final class LocationRow: NSObject {
    private static let folderIconSize: CGFloat = 16

    /// Read only: the folder is picked through `Choose…`, never typed, so the
    /// field is here to be read.
    let field = NSTextField(labelWithString: "")
    let chooseButton = NSButton()
    /// The two of them side by side, for the dialog's own grid.
    let view: NSStackView

    /// The folder the composed name is written into. `Choose…` replaces it.
    private(set) var url: URL

    /// Fired after `Choose…` has landed on a new folder, for a dialog whose
    /// buttons depend on where the file is going.
    var onChange: (() -> Void)?

    init(url: URL) {
        self.url = url
        view = NSStackView(views: [field, chooseButton])
        super.init()

        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.isEditable = false
        field.isSelectable = false
        field.lineBreakMode = .byTruncatingMiddle
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        chooseButton.bezelStyle = .rounded
        chooseButton.target = self
        chooseButton.action = #selector(chooseClicked)

        view.orientation = .horizontal
        view.spacing = 8
        // `.fill`, not gravity areas: the field takes the width up to the
        // button instead of hugging its folder's name.
        view.distribution = .fill

        show()
        relabel()
    }

    /// Where a dialog with nothing else to go on opens: the file's own folder
    /// when it has one, else the folder remembered from the last time this
    /// dialog wrote something, else Documents — which is where a save panel
    /// with nothing to go on opens too.
    static func openingURL(existingFileURL: URL?, lastDirectory: URL?) -> URL {
        existingFileURL?.deletingLastPathComponent()
            ?? lastDirectory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// The one word the row wears, asked again on a language change.
    func relabel() {
        chooseButton.title = L10n.text("Choose…", chinese: "选择…")
    }

    /// Puts the row on `folder`, as `Choose…` would. Exposed so a test can
    /// send a dialog somewhere else without a picker.
    func choose(_ folder: URL) {
        url = folder
        show()
        onChange?()
    }

    /// The folder as the row shows it: its own Finder icon, then its name,
    /// with the whole path behind the tooltip.
    private func show() {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: Self.folderIconSize, height: Self.folderIconSize)
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let attachment = NSTextAttachment()
        attachment.image = icon
        // An attachment stands on the baseline, so a 16pt icon beside 13pt
        // text sat with its feet on the letters' feet and its head well above
        // theirs. Dropped so its middle is the capitals' middle instead.
        attachment.bounds = NSRect(
            x: 0, y: ((font.capHeight - Self.folderIconSize) / 2).rounded(),
            width: Self.folderIconSize, height: Self.folderIconSize
        )
        let line = NSMutableAttributedString(attachment: attachment)
        line.append(NSAttributedString(
            string: " " + url.lastPathComponent,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
            ]
        ))
        field.attributedStringValue = line
        field.toolTip = url.path
    }

    @objc private func chooseClicked() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.canCreateDirectories = true
        picker.allowsMultipleSelection = false
        picker.directoryURL = url
        picker.prompt = L10n.text("Choose", chinese: "选择")
        guard picker.runModal() == .OK, let chosen = picker.url else { return }
        choose(chosen)
    }
}
