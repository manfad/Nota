import AppKit

/// ⌘J's pill: a line number, and where in the note it lands you.
///
/// The same chrome the find bar is made of, in the same corner — one row with
/// the word `Jump`, a field, the note's line total and a ✕. The word is only a
/// label: there is one place to go, not a walk through several, and nothing
/// here to fold out. It lights up while the keyboard is in the field, the way
/// `Find` and `Replace` do.
final class GoToLinePill: PillView, NSTextFieldDelegate, PillActionResponder {

    let field: PillTextField
    private(set) var jumpWord: PillWordLabel!
    private let countLabel = PillView.quietLabel()
    private var closeButton = NSButton()

    /// The number changed under the reader's fingers. Typing moves the caret
    /// as it goes, so this fires on every keystroke.
    var onQueryChange: ((String) -> Void)?
    /// Return, or the ✕: leave the caret where the number put it.
    var onCommit: (() -> Void)?
    /// Escape: put the caret and the view back where they were.
    var onCancel: (() -> Void)?
    /// ⌘F or ⌘R, asked for from inside the field.
    var onFinderAction: ((NSTextFinder.Action) -> Void)?

    var query: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    override init() {
        field = PillTextField()
        super.init()

        PillView.style(field, owner: self)
        jumpWord = leadWordLabel("Jump")
        closeButton = glyphButton(tooltip: "Close (Esc)", action: #selector(close))

        addSubview(jumpWord)
        for view in [field, countLabel, closeButton] { addSubview(view) }
        // The ✕ used to arrive only with the first appearance change, which
        // in a window that opens in light mode never comes.
        applySymbols()

        NSLayoutConstraint.activate([
            jumpWord.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            jumpWord.centerYAnchor.constraint(equalTo: centerYAnchor),

            field.leadingAnchor.constraint(equalTo: jumpWord.trailingAnchor, constant: 8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.trailingAnchor.constraint(equalTo: countLabel.leadingAnchor, constant: -6),

            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.trailingAnchor.constraint(
                equalTo: closeButton.leadingAnchor, constant: -4
            ),

            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func focusField() { field.focusSelectingAll() }

    /// `"1,234 lines"` while the number is a line, `"Not a line"` when what is
    /// typed is not one at all.
    func setStatus(_ text: String?) {
        countLabel.stringValue = text ?? ""
        countLabel.isHidden = text == nil
    }

    /// What the label is showing, for the tests.
    var status: String? { countLabel.isHidden ? nil : countLabel.stringValue }

    @objc private func close() { onCommit?() }

    // MARK: - Menu actions from inside the field

    /// ⌘F and ⌘R reach here through the field editor. They mean "not this
    /// pill, the other one", and the owner swaps them over. Nothing else in
    /// the Find menu means anything while a line number is being typed, so
    /// nothing else stays enabled.
    func perform(_ action: NSTextFinder.Action) { onFinderAction?(action) }

    func handles(_ action: NSTextFinder.Action) -> Bool {
        action == .showFindInterface || action == .showReplaceInterface
    }

    // MARK: - The field

    func controlTextDidChange(_ notification: Notification) {
        onQueryChange?(field.stringValue)
    }

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onCommit?()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }

    override func applySymbols() {
        closeButton.image = PillView.symbol("xmark", pointSize: 11, label: "Close")
    }
}

// MARK: - What a line number means

/// What ⌘J's pill does to the editor: the number, where it lands, and putting
/// everything back if the reader changes their mind.
///
/// The lines come from the note's own `LineIndex` — the table the gutter and
/// the footer read — rather than from counting newlines, so jumping to line
/// 400,000 of a log costs a binary search and not a pass over the file.
final class GoToLineSession {

    let pill: GoToLinePill
    private weak var textView: NSTextView?

    /// The front note's line table. The window controller hands this over,
    /// the same way it does for the gutter.
    var lineIndexProvider: (() -> LineIndex?)?
    /// Run when the pill arrives or leaves.
    var onVisibilityChange: ((Bool) -> Void)?
    /// ⌘F or ⌘R asked for from inside the pill: this one closes and the find
    /// bar opens in its place.
    var onFindRequested: ((NSTextFinder.Action) -> Void)?

    /// Where the caret and the view were when the pill opened. Escape puts
    /// both back — typing a number walks the caret about, and cancelling has
    /// to leave no trace of it.
    private var origin: NSRange?
    private var scrollOrigin: NSPoint?

    var isVisible: Bool { pill.isShown }

    init(pill: GoToLinePill, textView: NSTextView) {
        self.pill = pill
        self.textView = textView
        pill.onQueryChange = { [weak self] query in self?.go(to: query) }
        pill.onCommit = { [weak self] in self?.hide(restoring: false) }
        pill.onCancel = { [weak self] in self?.hide(restoring: true) }
        pill.onVisibilityChange = { [weak self] shown in self?.onVisibilityChange?(shown) }
        pill.onFinderAction = { [weak self] action in
            self?.hide(restoring: false)
            self?.onFindRequested?(action)
        }
    }

    // MARK: - Opening and closing

    func show() {
        guard let textView else { return }
        origin = textView.selectedRange()
        scrollOrigin = textView.enclosingScrollView?.contentView.bounds.origin
        pill.query = ""
        pill.setShown(true)
        pill.focusField()
        showTotal()
    }

    /// Return and the ✕ keep the place the number found; Escape puts the caret
    /// and the view back where they were. Either way the keyboard goes back to
    /// the text.
    func hide(restoring: Bool) {
        guard pill.isShown else { return }
        pill.setShown(false)
        guard let textView else { return }
        if restoring, let origin {
            let length = textView.textStorage?.length ?? 0
            let location = min(origin.location, length)
            textView.setSelectedRange(
                NSRange(location: location, length: min(origin.length, length - location))
            )
            if let scrollOrigin, let scrollView = textView.enclosingScrollView {
                let clip = scrollView.contentView
                clip.scroll(to: scrollOrigin)
                scrollView.reflectScrolledClipView(clip)
            }
        }
        origin = nil
        scrollOrigin = nil
        textView.window?.makeFirstResponder(textView)
    }

    // MARK: - The number

    /// `N` or `N:M`, both 1-based. Anything else — a word, a nothing, a third
    /// colon — is not a line.
    static func parse(_ text: String) -> (line: Int, column: Int?)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, let line = Int(parts[0]), line > 0 else { return nil }
        guard parts.count == 2 else { return (line, nil) }
        guard let column = Int(parts[1]), column > 0 else { return nil }
        return (line, column)
    }

    /// Moves as the reader types. An empty field has asked for nothing, so the
    /// caret goes back where it started; junk leaves it alone and says so; a
    /// number past the end lands on the last line rather than refusing.
    private func go(to query: String) {
        guard let textView, let index = lineIndexProvider?() else { return }
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            if let origin, NSMaxRange(origin) <= (textView.textStorage?.length ?? 0) {
                textView.setSelectedRange(origin)
            }
            showTotal()
            return
        }
        guard let asked = Self.parse(query) else {
            pill.setStatus("Not a line")
            return
        }
        let line = min(asked.line, index.lineCount)
        let range = index.range(ofLine: line)
        let target = Self.location(in: range, column: asked.column, of: textView.string as NSString)
        textView.setSelectedRange(NSRange(location: target, length: 0))
        reveal(target)
        showTotal()
    }

    /// Where in a line the caret lands: the column asked for, clamped to the
    /// line's own length, or the first thing on the line that is not a space.
    static func location(in range: NSRange, column: Int?, of text: NSString) -> Int {
        // The line's characters without its newline: a caret is never put
        // after the break.
        var content = range.length
        if content > 0, text.character(at: NSMaxRange(range) - 1) == 0x0A { content -= 1 }
        if let column { return range.location + min(column - 1, content) }
        var offset = 0
        while offset < content {
            let character = text.character(at: range.location + offset)
            guard character == 0x20 || character == 0x09 else { break }
            offset += 1
        }
        return range.location + offset
    }

    /// Brings the line into view, centred where there is room to centre it.
    private func reveal(_ location: Int) {
        guard let textView, let scrollView = textView.enclosingScrollView else { return }
        let caret = NSRange(location: location, length: 0)
        // First the guarantee — this also lays out as far as the line, which
        // is what the rect below needs — then the centring.
        textView.scrollRangeToVisible(caret)
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer
        else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: caret, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.y += textView.textContainerInset.height
        let clip = scrollView.contentView
        let room = max(0, textView.bounds.height - clip.bounds.height)
        let centred = min(max(0, rect.midY - clip.bounds.height / 2), room)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: centred))
        scrollView.reflectScrolledClipView(clip)
    }

    /// `"1,234 lines"`, so the reader can see what they are aiming inside.
    private func showTotal() {
        guard let count = lineIndexProvider?()?.lineCount else {
            pill.setStatus(nil)
            return
        }
        pill.setStatus(count == 1 ? "1 line" : "\(Self.grouped(count)) lines")
    }

    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static func grouped(_ count: Int) -> String {
        formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }
}
