import AppKit

/// Nota's own ⌘F bar: the query pill, floating in the top-trailing corner of a
/// column over the text rather than above it.
///
/// The pill leads with the word `Find` rather than a glyph, and that word is a
/// toggle. Clicking it fades a second pill in under this one — same width,
/// same surface, 6pt below — holding the replacement and the two words that
/// apply it, and clicking it again fades that away. Neither pill ever changes
/// size or moves; the mode control drops below whichever stack is standing.
/// Where nothing can be edited — the rendered page, a tab that cannot be typed
/// in — the word is only a word and the second pill is out of reach.
///
/// Neither field carries a placeholder: the word says what the row is for, and
/// a grey sentence beside it would only say it again.
///
/// The pills are only the pills. What a query *means* — the matches, the bands
/// behind them, which one is current, what replacing one does — belongs to
/// `TextFindSession`, so the same chrome serves the editor and the rendered
/// page without knowing which of them it is floating over.
final class FindBarView: PillView, NSTextFieldDelegate, PillActionResponder {

    /// The field the query is typed in.
    let field: PillTextField
    /// The pill under this one, and the field in it.
    let replacePill: ReplaceBarView
    var replaceField: PillTextField { replacePill.field }

    /// The word `Find`, which is also the replace pill's toggle — clicking it
    /// is how that pill arrives and leaves.
    private(set) var findWord: PillWordButton!
    private let countLabel = PillView.quietLabel()
    private var previousButton = NSButton()
    private var nextButton = NSButton()
    private var closeButton = NSButton()

    /// A menu action, a button or a key in either field — all three arrive
    /// here as the same `NSTextFinder.Action`s, and the session answers them.
    var onFinderAction: ((NSTextFinder.Action) -> Void)?
    /// The query changed under the reader's fingers.
    var onQueryChange: ((String) -> Void)?
    /// Run when the replace pill arrives or leaves, so the mode control below
    /// moves by the height of the stack rather than being covered by it.
    var onHeightChange: (() -> Void)?

    /// Which of the Find menu's actions the session behind this bar answers
    /// for — asked while the reader is typing in a field, where the menu
    /// items reach the field editor rather than the view being searched. A
    /// text session takes them all; a document's takes everything but the
    /// replace half. Unset means the text session's answer, which is what
    /// every bar over an `NSTextView` wants.
    var handlesAction: ((NSTextFinder.Action) -> Bool)?

    /// Whether the replace pill is out. It goes down with the bar — closing
    /// and opening again is find and no more, and ⌘R is what asks for the
    /// second row.
    private(set) var isExpanded = false

    /// Whether there is anything here to replace. False over a rendered page
    /// and over a tab that cannot be typed in, where the word is only a word
    /// and the second pill is out of reach.
    var canReplace = true {
        didSet {
            guard canReplace != oldValue else { return }
            if !canReplace { setExpanded(false) }
            findWord.toolTip = canReplace ? "Replace (⌘R)" : nil
        }
    }

    /// How tall the whole stack in this corner is standing: the query pill
    /// alone, or that and the replace pill under it with their gap between.
    var stackHeight: CGFloat {
        isExpanded ? Self.height + Self.gap + Self.height : Self.height
    }

    /// What is in the two fields.
    var query: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    var replacement: String { replacePill.replacement }

    override init() {
        replacePill = ReplaceBarView()
        field = PillTextField()
        super.init()

        PillView.style(field, owner: self)
        findWord = leadWordButton(
            "Find", tooltip: "Replace (⌘R)", action: #selector(toggleReplace)
        )
        previousButton = glyphButton(
            tooltip: "Previous match "
                + "(\(Preferences.shared.combo(for: .findPrevious).displayName))",
            action: #selector(previousMatch)
        )
        nextButton = glyphButton(
            tooltip: "Next match (\(Preferences.shared.combo(for: .findNext).displayName))",
            action: #selector(nextMatch)
        )
        closeButton = glyphButton(tooltip: "Close (Esc)", action: #selector(closeBar))

        replacePill.onFinderAction = { [weak self] action in self?.perform(action) }
        replacePill.onCollapse = { [weak self] in self?.perform(.hideReplaceInterface) }
        // Tab walks between the two fields, and back again.
        field.nextKeyView = replacePill.field
        replacePill.field.nextKeyView = field

        addSubview(findWord)
        for view in [field, countLabel, previousButton, nextButton, closeButton] {
            addSubview(view)
        }
        applySymbols()
        installConstraints()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func installConstraints() {
        NSLayoutConstraint.activate([
            findWord.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            findWord.centerYAnchor.constraint(equalTo: centerYAnchor),

            field.leadingAnchor.constraint(equalTo: findWord.trailingAnchor, constant: 8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.trailingAnchor.constraint(equalTo: countLabel.leadingAnchor, constant: -6),

            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.trailingAnchor.constraint(
                equalTo: previousButton.leadingAnchor, constant: -4
            ),

            previousButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            previousButton.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor),
            nextButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            nextButton.trailingAnchor.constraint(
                equalTo: closeButton.leadingAnchor, constant: -2
            ),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
    }

    /// Puts both pills in a column's corner, the replace one under the query
    /// one and sharing its trailing edge.
    func floatStack(in container: NSView, under top: NSLayoutYAxisAnchor, gap: CGFloat,
                    trailingInset: CGFloat) {
        float(in: container, under: top, gap: gap, trailingInset: trailingInset)
        replacePill.float(
            in: container, under: bottomAnchor, gap: Self.gap, trailingInset: trailingInset
        )
    }

    // MARK: - Showing and hiding

    /// The replace pill is part of the bar: it comes and goes with it, and
    /// comes back out with it if that is how the column was left.
    override func setShown(_ shown: Bool, animated: Bool = true) {
        super.setShown(shown, animated: animated)
        replacePill.setShown(shown && isExpanded, animated: animated)
    }

    /// Fades the replace pill in under this one, or away again. The bar itself
    /// never changes size — that is the whole point of a second pill.
    func setExpanded(_ expanded: Bool) {
        guard canReplace || !expanded else { return }
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        replacePill.setShown(expanded && isShown)
        applySymbols()
        onHeightChange?()
    }

    /// Puts the keyboard in the query field with everything in it selected, so
    /// the next thing typed replaces the query the bar came up holding.
    func focusField() { field.focusSelectingAll() }

    func focusReplaceField() {
        guard isExpanded else { return }
        replacePill.field.focusSelectingAll()
    }

    // MARK: - The count

    /// `"3 of 12"`, `"No matches"`, or nothing at all while the field is
    /// empty.
    func setStatus(_ text: String?) {
        countLabel.stringValue = text ?? ""
        countLabel.isHidden = text == nil
    }

    /// What the count is showing, for the tests.
    var status: String? { countLabel.isHidden ? nil : countLabel.stringValue }

    // MARK: - Actions

    /// Everything the bar can be asked to do arrives here — from either pill's
    /// buttons and keys, and from the Find menu by way of the field editor.
    func perform(_ action: NSTextFinder.Action) {
        onFinderAction?(action)
    }

    func handles(_ action: NSTextFinder.Action) -> Bool {
        handlesAction?(action) ?? TextFindSession.handles(action)
    }

    @objc private func nextMatch() { perform(.nextMatch) }
    @objc private func previousMatch() { perform(.previousMatch) }
    @objc private func closeBar() { perform(.hideFindInterface) }

    @objc private func toggleReplace() {
        guard canReplace else { return }
        perform(isExpanded ? .hideReplaceInterface : .showReplaceInterface)
    }

    // MARK: - The field

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === field else { return }
        onQueryChange?(field.stringValue)
    }

    /// Return steps forward, ⇧Return back, Escape closes. AppKit binds plain
    /// and shifted Return to the same command, so the shift is read off the
    /// event that is being handled.
    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let shifted = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            perform(shifted ? .previousMatch : .nextMatch)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            perform(.hideFindInterface)
            return true
        default:
            return false
        }
    }

    /// The word is coloured by `PillView`, by whether the keyboard is in this
    /// pill's field; only the three glyphs at the trailing end are laid on
    /// here.
    override func applySymbols() {
        previousButton.image = Self.symbol("chevron.up", pointSize: 11, label: "Previous")
        nextButton.image = Self.symbol("chevron.down", pointSize: 11, label: "Next")
        closeButton.image = Self.symbol("xmark", pointSize: 11, label: "Close")
    }
}

// MARK: - The replace pill

/// The second pill: what to put in place of a match, and the two words that
/// do it. It stands under the query pill and belongs to it — it arrives when
/// `Find` is clicked, and it leaves whenever the query pill does.
final class ReplaceBarView: PillView, NSTextFieldDelegate, PillActionResponder {

    let field: PillTextField
    /// The word `Replace`: a click folds this pill away, the mirror of the
    /// `Find` above that brought it out.
    private(set) var replaceWord: PillWordButton!
    private var replaceButton = NSButton()
    private var replaceAllButton = NSButton()

    /// Handed to the query pill, which is what the session listens to.
    var onFinderAction: ((NSTextFinder.Action) -> Void)?
    /// The icon was clicked: the query pill folds this one away.
    var onCollapse: (() -> Void)?

    var replacement: String { field.stringValue }

    override init() {
        field = PillTextField()
        super.init()

        PillView.style(field, owner: self)
        replaceWord = leadWordButton(
            "Replace", tooltip: "Hide Replace", action: #selector(collapse)
        )
        replaceButton = wordButton(
            title: "One", tooltip: "Replace this match (Return)",
            action: #selector(replaceOne)
        )
        replaceAllButton = wordButton(
            title: "All", tooltip: "Replace all matches (⌥Return)", action: #selector(replaceAll)
        )

        addSubview(replaceWord)
        for view in [field, replaceButton, replaceAllButton] { addSubview(view) }

        NSLayoutConstraint.activate([
            replaceWord.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            replaceWord.centerYAnchor.constraint(equalTo: centerYAnchor),

            field.leadingAnchor.constraint(equalTo: replaceWord.trailingAnchor, constant: 8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.trailingAnchor.constraint(
                equalTo: replaceButton.leadingAnchor, constant: -8
            ),

            replaceButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            replaceButton.trailingAnchor.constraint(
                equalTo: replaceAllButton.leadingAnchor, constant: -8
            ),
            replaceAllButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            replaceAllButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func perform(_ action: NSTextFinder.Action) { onFinderAction?(action) }

    func handles(_ action: NSTextFinder.Action) -> Bool { TextFindSession.handles(action) }

    @objc private func collapse() { onCollapse?() }

    @objc private func replaceOne() { perform(.replace) }
    @objc private func replaceAll() { perform(.replaceAll) }

    /// Return replaces the match being stood on, ⌥Return replaces the lot, and
    /// Escape closes the whole bar rather than only this pill.
    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            perform(.replace)
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            perform(.replaceAll)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            perform(.hideFindInterface)
            return true
        default:
            return false
        }
    }

    /// The word follows the same rule the one above it does — lit while the
    /// keyboard is in this pill's field, quiet otherwise — so only the two
    /// small words at the trailing end are laid on here.
    override func applySymbols() {
        PillView.applyTitle(to: replaceButton)
        PillView.applyTitle(to: replaceAllButton)
    }
}
