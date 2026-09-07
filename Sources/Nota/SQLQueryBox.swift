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
}

/// The editor inside the box. Everything about it that is not stock is about
/// two keys and one drawn line of grey.
private final class SQLQueryTextView: NSTextView {
    var onRun: (() -> Void)?
    var onCancel: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    weak var findSession: GridFindSession?
    var takesKeyboard = false

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

    /// ⌘↩ runs; every other key, Return included, is the editor's own.
    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, event.modifierFlags.contains(.command) {
            onRun?()
            return
        }
        super.keyDown(with: event)
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
        if resigned { onFocusChange?(false) }
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
