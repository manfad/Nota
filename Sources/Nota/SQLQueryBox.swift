import AppKit

/// The query box beside a dump: five rows of a monospaced editor in the same
/// rounded bezel every other field in Nota wears.
///
/// It was one line once, and one line was wrong. A query is written over
/// lines — a select, a from, a where under it — and a box that ran the thing
/// the moment Return was pressed made those lines impossible to type. So
/// Return is a newline here, the way it is in the editor, and ⌘↩ is what
/// runs the query: the key every database tool answers to, and the one a
/// reader who knows one of them already knows. Esc puts the question down
/// and the picked table comes back.
///
/// Nothing about it is rich: no fonts but the editor's, no smart quotes to
/// turn `'shipped'` into something SQLite will not take, no substitutions at
/// all. What is typed is what is run.
///
/// Two things do help while it is being typed, and neither of them changes a
/// character. Keywords, strings, numbers and comments are coloured — as
/// display attributes over the layout manager, so the string is untouched and
/// the undo stack never hears about it. And a dropdown under the caret offers
/// the keyword, table or column the reader has started to write, filled from
/// a snapshot of the dump's own names (`SQLCompletion`). The list is a panel
/// that never takes the keyboard: every key it answers to is read here and
/// handed on.
final class SQLQueryBox: NSView {

    /// ⌘↩.
    var onRun: (() -> Void)?
    /// Esc.
    var onCancel: (() -> Void)?

    /// The grid's ⌘F. The box is an `NSTextView` and would answer the Find
    /// menu itself, with a find bar of AppKit's own over five rows of query —
    /// which is not what a reader who pressed ⌘F beside a table is looking
    /// for. The items go to the grid's session instead, so ⌘F with the caret
    /// in the box searches the rows.
    weak var findSession: GridFindSession? {
        didSet { textView.findSession = findSession }
    }

    /// Whether the pane owns the keyboard, which is reading mode. In split the
    /// editor beside it owns ⌘F, and the box hands the Find menu back up the
    /// chain rather than answering for a grid the reader is not in.
    var takesKeyboard = false {
        didSet { textView.takesKeyboard = takesKeyboard }
    }

    /// The names the dropdown offers: the dump's tables and their columns, as
    /// a plain value read off the pane's own queue. Empty while there is no
    /// database, which is also what takes the dropdown away.
    var completionSchema: SQLCompletion.Schema {
        get { textView.completionSchema }
        set { textView.completionSchema = newValue }
    }

    private enum Metrics {
        /// The bezel's own radius. The text inset inside it is `textInset`,
        /// so the corner the text turns is concentric with the one the box
        /// draws round it.
        static let radius: CGFloat = 6
        static let textInset: CGFloat = 5
        static let border: CGFloat = 1
    }

    private let scrollView = NSScrollView()
    private let textView = SQLQueryTextView()

    /// Whether the box is where the typing is going. A field that says so is
    /// the one cue this pane has for where the keyboard is pointed, since
    /// nothing else in it takes text.
    private var isFocused = false {
        didSet {
            guard isFocused != oldValue else { return }
            needsDisplay = true
        }
    }

    var string: String {
        get { textView.string }
        set {
            guard textView.string != newValue else { return }
            textView.string = newValue
            // Assigning the string does not go through the editing path, so
            // the colours have to be asked for by hand — session restore puts
            // a query here without a keystroke.
            textView.refreshHighlighting()
            textView.needsDisplay = true
        }
    }

    var placeholder: String {
        get { textView.placeholder }
        set { textView.placeholder = newValue }
    }

    var font: NSFont? {
        get { textView.font }
        set {
            textView.font = newValue
            if let newValue {
                textView.typingAttributes = [
                    .font: newValue, .foregroundColor: NSColor.labelColor,
                ]
            }
            textView.refreshHighlighting()
            textView.needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude
        )
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: Metrics.textInset, height: Metrics.textInset)
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .labelColor
        textView.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        // Reading the layout manager is what puts the view in TextKit 1, and
        // TextKit 1 is what has temporary attributes — the colouring below
        // draws through them so the text storage, and with it the undo stack,
        // never sees a colour at all.
        _ = textView.layoutManager
        textView.onRun = { [weak self] in self?.onRun?() }
        textView.onCancel = { [weak self] in self?.onCancel?() }
        textView.onFocusChange = { [weak self] focused in self?.isFocused = focused }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.border),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.border),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.border),
            scrollView.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Metrics.border
            ),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// How tall the box has to be for that many lines of the font it is set
    /// in — asked of the layout manager, so a bigger editor font makes a
    /// taller box rather than a box with five lines it cannot show.
    func height(forRows rows: Int) -> CGFloat {
        let font = textView.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        let line = textView.layoutManager?.defaultLineHeight(for: font)
            ?? (font.ascender - font.descender + font.leading)
        return (line * CGFloat(rows) + Metrics.textInset * 2 + Metrics.border * 2).rounded(.up)
    }

    /// The bezel: the field background, a hairline round it, and the accent
    /// in place of that hairline while the typing is going here.
    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(
            roundedRect: bounds.insetBy(dx: Metrics.border / 2, dy: Metrics.border / 2),
            xRadius: Metrics.radius, yRadius: Metrics.radius
        )
        NSColor.textBackgroundColor.setFill()
        outline.fill()
        (isFocused ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        outline.lineWidth = Metrics.border
        outline.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Tests

    /// Types into the box the way a reader would, so a test drives the same
    /// text storage the editor does rather than assigning past it.
    func typeForTesting(_ text: String) {
        textView.insertText(text, replacementRange: textView.selectedRange())
    }

    /// ⌘↩ and Esc, as key presses.
    func pressRunForTesting() { textView.runFromKey() }
    func pressEscapeForTesting() { textView.cancelOperation(nil) }
    /// Return, which has to be a newline and not a run.
    func pressReturnForTesting() { textView.insertNewline(nil) }
    var textViewForTesting: NSTextView { textView }

    /// The dropdown, as it stands: whether it is up and what it is offering.
    var completionItemsForTesting: [SQLCompletion.Item] { textView.completionItemsForTesting }
    var completionIsOpenForTesting: Bool { textView.completionIsOpenForTesting }
    var completionSelectionForTesting: Int { textView.completionSelectionForTesting }
    func moveCompletionForTesting(by delta: Int) { textView.moveCompletion(by: delta) }
    func acceptCompletionForTesting() { textView.acceptCompletion() }
    func closeCompletionForTesting() { textView.closeCompletion() }
    /// The colours, as ranges — the same runs `SQLCompletion` found, so a
    /// test reads what is drawn rather than what was asked for.
    var highlightRunsForTesting: [(range: NSRange, kind: SQLCompletion.Highlight)] {
        SQLCompletion.highlights(in: textView.string)
    }
}

/// The editor inside the box. Everything about it that is not stock is about
/// a handful of keys, one drawn line of grey, the colours over the text and
/// the list under the caret.
private final class SQLQueryTextView: NSTextView {
    var onRun: (() -> Void)?
    var onCancel: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    weak var findSession: GridFindSession?
    var takesKeyboard = false

    /// The dump's names. Setting an empty one — the tab has gone, or its
    /// database with it — takes any open list away, since every row in it
    /// would now be about a database that is not there.
    var completionSchema: SQLCompletion.Schema = .empty {
        didSet {
            guard completionSchema != oldValue else { return }
            if completionSchema.isEmpty { closeCompletion() }
        }
    }

    /// Made on the first suggestion and kept afterwards, so a box nobody
    /// types a name into never builds a window.
    private var popup: SQLCompletionPopup?
    /// What an accepted row replaces: the partial word under the caret.
    private var completionRange = NSRange(location: 0, length: 0)
    /// True while an edit of ours is in flight, so the selection it moves is
    /// not read as the caret wandering off the word.
    private var isChangingText = false

    /// The Find menu, handed to the grid beside the box rather than answered
    /// here — but only in reading mode. In split the editor owns ⌘F, so the
    /// action goes back up the chain to the window, which hands it to the
    /// editor's own session.
    override func performTextFinderAction(_ sender: Any?) {
        guard takesKeyboard, let findSession else {
            nextResponder?.tryToPerform(#selector(performTextFinderAction(_:)), with: sender)
            return
        }
        guard let item = sender as? NSValidatedUserInterfaceItem,
              let action = NSTextFinder.Action(rawValue: item.tag),
              GridFindSession.handles(action)
        else { return }
        findSession.perform(action)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(performTextFinderAction(_:)),
              let action = NSTextFinder.Action(rawValue: item.tag)
        else { return super.validateUserInterfaceItem(item) }
        guard takesKeyboard, findSession != nil else { return TextFindSession.handles(action) }
        return GridFindSession.handles(action)
    }

    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    func runFromKey() { onRun?() }

    /// ⌘↩ runs; the arrows, Tab, Return and Esc belong to the dropdown while
    /// it is up; every other key, Return included, is the editor's own.
    ///
    /// The list is read here rather than in the panel because the panel is
    /// never key: the caret has to stay in this view for the query to go on
    /// being typed, so the keys it answers to arrive here first and are
    /// forwarded.
    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, event.modifierFlags.contains(.command) {
            // ⌘↩ runs even with the list up — the reader has stopped picking
            // and asked for the answer.
            closeCompletion()
            onRun?()
            return
        }
        if popup?.isOpen == true {
            let plain = event.modifierFlags
                .intersection([.command, .option, .control, .shift]).isEmpty
            switch event.keyCode {
            case 125 where plain: moveCompletion(by: 1); return
            case 126 where plain: moveCompletion(by: -1); return
            case 48 where plain: acceptCompletion(); return
            case 36 where plain, 76 where plain: acceptCompletion(); return
            case 53: closeCompletion(); return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    /// Typing is what opens the list: one character a name is made of, or the
    /// dot that asks a table for its columns.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        isChangingText = true
        super.insertText(string, replacementRange: replacementRange)
        isChangingText = false
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        if typed.count == 1, let character = typed.first,
           SQLCompletion.opensSuggestions(character) {
            updateCompletion(opening: true)
        } else if popup?.isOpen == true {
            updateCompletion(opening: false)
        }
    }

    /// Every edit at all — a delete, a paste, an undo — recolours the box and
    /// narrows whatever list is already up.
    override func didChangeText() {
        super.didChangeText()
        refreshHighlighting()
        if popup?.isOpen == true { updateCompletion(opening: false) }
    }

    /// The caret moving off the word the list was about closes it: a click
    /// elsewhere, an arrow past the end, a selection dragged over the query.
    override func setSelectedRanges(
        _ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool
    ) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard popup?.isOpen == true, !isChangingText, !stillSelecting else { return }
        let caret = selectedRange().location
        if selectedRange().length > 0 || caret < completionRange.location
            || caret > completionRange.location + completionRange.length {
            closeCompletion()
        }
    }

    override func mouseDown(with event: NSEvent) {
        closeCompletion()
        super.mouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { closeCompletion() }
    }

    // MARK: - The dropdown

    /// Asks `SQLCompletion` what could go where the caret is, and puts the
    /// list up under it — or takes it away when the answer is nothing.
    /// `opening` is false for the passes that only narrow a list already up,
    /// so a delete never conjures one.
    private func updateCompletion(opening: Bool) {
        guard opening || popup?.isOpen == true else { return }
        guard selectedRange().length == 0 else {
            closeCompletion()
            return
        }
        let answer = SQLCompletion.suggestions(
            in: string, caret: selectedRange().location, schema: completionSchema
        )
        guard !answer.items.isEmpty else {
            closeCompletion()
            return
        }
        completionRange = answer.range
        let popup = popup ?? makePopup()
        popup.show(answer.items, font: font ?? .monospacedSystemFont(ofSize: 13, weight: .regular),
                   under: caretRectOnScreen(), in: self)
    }

    private func makePopup() -> SQLCompletionPopup {
        let made = SQLCompletionPopup()
        made.onAccept = { [weak self] item in self?.insertCompletion(item) }
        popup = made
        return made
    }

    /// Where the list hangs from: the line the word being completed starts
    /// on, in screen coordinates. `firstRect(forCharacterRange:)` is the same
    /// answer an input method's own candidate window is placed by.
    private func caretRectOnScreen() -> NSRect {
        let anchor = NSRange(location: completionRange.location, length: 0)
        let rect = firstRect(forCharacterRange: anchor, actualRange: nil)
        guard rect.height > 0 else {
            // A view that cannot say where its caret is (offscreen, no
            // window) still gets a sane box under its own top-left.
            let fallback = NSRect(x: 0, y: 0, width: 1, height: bounds.height)
            return window?.convertToScreen(convert(fallback, to: nil)) ?? fallback
        }
        return rect
    }

    func moveCompletion(by delta: Int) { popup?.moveSelection(by: delta) }

    func acceptCompletion() {
        guard let item = popup?.selectedItem else { return }
        insertCompletion(item)
    }

    private func insertCompletion(_ item: SQLCompletion.Item) {
        closeCompletion()
        let length = (string as NSString).length
        let start = min(max(0, completionRange.location), length)
        let range = NSRange(location: start, length: min(completionRange.length, length - start))
        isChangingText = true
        super.insertText(item.text, replacementRange: range)
        isChangingText = false
    }

    func closeCompletion() { popup?.close() }

    var completionItemsForTesting: [SQLCompletion.Item] { popup?.items ?? [] }
    var completionIsOpenForTesting: Bool { popup?.isOpen ?? false }
    var completionSelectionForTesting: Int { popup?.selectionForTesting ?? -1 }

    // MARK: - Colour

    /// The keywords, strings, numbers and comments, drawn in their colours.
    ///
    /// Temporary attributes, not stored ones: the text storage keeps exactly
    /// the characters and the one font it was given, nothing an undo could
    /// step back over is registered, and the colours are semantic so light
    /// and dark need no second pass. The whole string every time — the box is
    /// five rows tall, and a range-by-range recolour would cost more thought
    /// than it saves.
    func refreshHighlighting() {
        guard let layoutManager, let textStorage else { return }
        let whole = NSRange(location: 0, length: textStorage.length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
        for run in SQLCompletion.highlights(in: string) {
            guard run.range.location + run.range.length <= whole.length else { continue }
            layoutManager.addTemporaryAttribute(
                .foregroundColor, value: colour(for: run.kind), forCharacterRange: run.range
            )
        }
    }

    private func colour(for kind: SQLCompletion.Highlight) -> NSColor {
        switch kind {
        case .keyword: .systemPurple
        case .string: .systemRed
        case .number: .systemTeal
        case .comment: .secondaryLabelColor
        }
    }

    /// ⌘↩ again, for the case where something up the chain claims it as a
    /// key equivalent before the key ever reaches `keyDown`.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, event.modifierFlags.contains(.command), window?.firstResponder === self {
            onRun?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Esc with the list up is caught in `keyDown` and never reaches here, so
    /// this is Esc meaning what it always meant: put the question down.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            closeCompletion()
            onFocusChange?(false)
        }
        return resigned
    }

    /// The placeholder, in the same font and the same place the first
    /// character would be, so the box does not shuffle its text sideways the
    /// moment one is typed.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty,
              let font = font ?? NSFont(name: "Menlo", size: 13)
        else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
                             y: textContainerInset.height)
        placeholder.draw(at: origin, withAttributes: attributes)
    }
}
