import AppKit

/// The preview column holding a `.json`, `.yaml`, `.toml` or `.xml` file as
/// the tree it is, where a Markdown tab would have its render.
///
/// One view for four grammars. Everything about a structured file that
/// differs between them is spent in its parser (`JSONTree`, `YAMLTree`,
/// `TOMLTree`, `XMLTree`), and what comes out is a `StructuredDocument` —
/// named parts, numbered parts and leaves. So this view has never heard of
/// JSON: it draws a tree of `StructuredNode`s, and the only place the format
/// is named is the line it puts on screen when a parse fails.
///
/// It is `NSOutlineView` and not a render, because a tree is a thing you
/// open and close rather than read top to bottom: the disclosure triangles,
/// ⌥-click to open a whole subtree, and the arrow keys are all AppKit's own
/// and none of them would have come with an attributed string.
///
/// What it keeps across a re-render — and it is re-rendered on the same
/// debounce the Markdown pane is, so it follows the file as it is typed — is
/// which branches were open, by path, and where the reader had scrolled to.
/// A path that no longer exists is simply gone; a branch that has just been
/// typed into being arrives closed.
///
/// Both halves of the block sync a render has: clicking a row selects the
/// node in the source beside it, and the caret lights the deepest row whose
/// own source it is standing in. Both work off the span every node carries,
/// which is what makes a one-line file — a whole JSON export on one line —
/// behave like any other: the line alone would say nothing about where a
/// member is. The click reveals rather than jumps — the `onSourceReveal` a
/// dump's cell click uses — so the keyboard stays in the tree and the arrows
/// go on walking it.
///
/// In reading mode, where the tree is what is being read, it has its own ⌘F:
/// `TreeFindSession` over the rows, in the pill every other column floats in
/// the same corner. In split the editor has the keyboard and ⌘F is the
/// editor's, whatever was last clicked here — the same rule the page keeps.
final class TreePreviewView: NSView, PreviewContent {

    // MARK: - The chrome

    private let scrollView = NSScrollView()
    private let outlineView = TreeOutlineView()
    /// The tree's own ⌘F bar, floating in the top-trailing corner of the
    /// column — the same pill the editor, the render and a document use, over
    /// the rows instead of a text storage.
    private let findBar = FindBarView(placeholder: L10n.text("Find in tree"))
    private lazy var findSession = TreeFindSession(bar: findBar, tree: self)
    /// What stands in the tree's place when the file will not parse: one
    /// centred line naming the format, the line and the reason.
    private let errorLabel = NSTextField(labelWithString: "")

    private enum Layout {
        /// The tree begins below the band the corner slot floats its capsule
        /// in, the way the dump's and the table's bars do: a row is a full
        /// width of wash, and one running under the control would read as a
        /// row half hidden rather than as text under a hover.
        /// The editor's own vertical padding, not the corner band's height:
        /// the tree starts where the source does, and the capsule floats over
        /// the first rows on hover the way it floats over the first lines.
        /// Rows under it still take their click (`TreeClipView`).
        static let topInset: CGFloat = 14 // MainWindowController.Layout.textPaddingVertical
        static let rowHeight: CGFloat = 20
        static let indentation: CGFloat = 14
        /// The gap between a row's key and the value after it.
        static let keyValueGap = "  "
        /// The most of the column the centred message may measure across.
        /// Three quarters left "document." alone on a line of its own in a
        /// narrow split; this is still plainly a measure and not a width. An
        /// upper bound and never an equality: a required equality between
        /// the label and the pane pulled the pane to the label's width — an
        /// empty, hidden label's — and the preview snapped shut every layout.
        static let messageWidth: CGFloat = 0.82
    }

    /// The document is expanded whole below this many nodes, and to two
    /// levels above it — a settings file opens showing everything, and a
    /// hundred-thousand-node export opens showing its shape.
    static let expandEverythingBelow = 400
    private static let defaultDepth = 2

    // MARK: - What the pane is showing

    /// One row of the outline. A class, because `NSOutlineView` identifies
    /// its items by object and a struct would arrive as a different item
    /// every time it was asked for.
    final class Row {
        let node: StructuredNode
        /// Where this node sits in the document, spelled by the keys and
        /// indices on the way down to it. It is what expansion is remembered
        /// by, so a re-render after a keystroke reopens the same branches.
        let path: String
        let depth: Int
        /// Nothing of the file is written before this node on the line it
        /// starts, so the indentation in front of it is the node's own
        /// run-up: a caret in it is a caret on this row.
        var startsItsLine = false
        private(set) var children: [Row] = []
        weak var parent: Row?

        init(node: StructuredNode, path: String, depth: Int) {
            self.node = node
            self.path = path
            self.depth = depth
        }

        func adopt(_ rows: [Row]) {
            children = rows
            for row in rows { row.parent = self }
        }
    }

    private weak var note: Note?
    private var rows: [Row] = []
    /// Every row in the tree, by the line it starts on — what the caret falls
    /// back to for a node whose parser could not say how wide it is.
    private var rowsByLine: [Int: [Row]] = [:]
    /// Every row again, flat, in the order the document writes them: a parent
    /// before its children, whether or not the branch is open. It is what a
    /// search walks, and where a row sits in it is that row's place in the
    /// tree.
    private var flatRows: [Row] = []
    private var flatRowOrder: [ObjectIdentifier: Int] = [:]
    private var expandedPaths: Set<String> = []
    /// Whether the expansion set has been seeded for the document on screen.
    /// A fresh document opens by the rule above; a re-render of the same one
    /// keeps whatever the reader had opened.
    private var hasSeededExpansion = false
    private var renderedKey: RenderKey?
    private var parseError: StructuredParseError?
    private var format: StructuredFormat = .json
    /// The row the caret is lighting. It is a selection, so AppKit draws the
    /// wash; the flag is what keeps that selection from being read back as a
    /// click.
    private var isSelectingForCaret = false
    /// An edit has moved the lines under the rows: nothing on screen points
    /// anywhere until the next parse lands.
    private var rowsAreStale = false
    private var isColumnVisible = false
    private var font = NSFont.systemFont(ofSize: 13)

    // MARK: - What the pane reports

    var onDropFiles: (([URL]) -> Void)?
    /// Where the clicked node is written in the file. Split only, which is
    /// what `sendsBlockClicks` says: in reading there is no editor on screen
    /// to point at.
    var onSourceReveal: ((NSRange) -> Void)?
    /// Mirrors the render's own: true in split, where the tree is a way into
    /// the text beside it, and false in reading, where it is simply what is
    /// being read.
    var sendsBlockClicks = true

    /// Run when the find bar opens or closes, so the column's mode control
    /// drops below it — the same as over a render.
    var onFindBarVisibilityChange: ((Bool) -> Void)?

    var isFindBarVisible: Bool { findSession.isVisible }

    var findBarHeight: CGFloat { findBar.stackHeight }

    /// The tree's find, for the outline that forwards the menu's actions to
    /// it and for the tests.
    var find: TreeFindSession { findSession }

    // MARK: - Building

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes(PreviewFileDrop.types)
        buildOutline()
        buildErrorLabel()
        activateConstraints()

        // Added after the tree, so the pill floats over the first rows, and
        // in the same corner every other column keeps its bars in.
        outlineView.findSession = findSession
        findSession.onVisibilityChange = { [weak self] visible in
            self?.onFindBarVisibilityChange?(visible)
        }
        findBar.onHeightChange = { [weak self] in
            guard let self else { return }
            onFindBarVisibilityChange?(isFindBarVisible)
        }
        findBar.floatStack(
            in: self, under: topAnchor, gap: ModeControlOverlay.controlTopInset,
            trailingInset: ModeControlOverlay.controlInset
        )
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildOutline() {
        outlineView.translatesAutoresizingMaskIntoConstraints = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.headerView = nil
        // Not a source list: this is the document, drawn on the document's
        // own background, not a sidebar of places to go.
        outlineView.selectionHighlightStyle = .regular
        outlineView.style = .plain
        // The outline paints nothing of its own: an NSOutlineView given the
        // document colour still came out a shade off it in the dark (27 to
        // the editor's 30). The pane's layer is the one background here.
        outlineView.backgroundColor = .clear
        outlineView.rowSizeStyle = .custom
        outlineView.rowHeight = Layout.rowHeight
        outlineView.indentationPerLevel = Layout.indentation
        outlineView.indentationMarkerFollowsCell = true
        outlineView.autoresizesOutlineColumn = false
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        outlineView.onRowClick = { [weak self] index in self?.reveal(row: index) }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("node"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        // The one column is exactly as wide as the column it is drawn in, and
        // is held there in `layout()`. A row is a line of a tree and not a
        // line of a file: a leaf holding a whole HTML page in one string
        // would otherwise make the column as wide as the string and run off
        // the pane, since a field only truncates at the width it is given.
        outlineView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        // Nothing to scroll sideways to: the row is cut off with an ellipsis
        // where the pane ends.
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        // The clip has to be ours before the document goes in it, or AppKit
        // makes a plain one and swaps this in over the top of it — and the
        // background has to be set after the clip is ours, since the scroll
        // view hands its colour to whichever clip view it has at the time;
        // set before, the new clip kept AppKit's default and the column read
        // a shade lighter than the editor in the dark.
        scrollView.contentView = TreeClipView()
        scrollView.documentView = outlineView
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(
            top: Layout.topInset, left: 0, bottom: 0, right: 0
        )
        addSubview(scrollView)
    }

    private func buildErrorLabel() {
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.alignment = .center
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 0
        errorLabel.isHidden = true
        addSubview(errorLabel)
    }

    private func activateConstraints() {
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            leadingConstraint, trailingConstraint,

            errorLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            errorLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor, constant: 20
            ),
            // A measure, not a width: a sentence run across the whole of a
            // wide window is a line nobody reads twice. See `Layout.messageWidth`
            // for why this is a bound and not an equality.
            errorLabel.widthAnchor.constraint(
                lessThanOrEqualTo: widthAnchor, multiplier: Layout.messageWidth
            ),
        ])
    }

    /// The column is held to the width of the pane, and the message to
    /// `Layout.messageWidth` of it. Done here rather than by a constraint because the
    /// outline is a scroll view's document view, whose width is the sum of its
    /// columns and not the clip view's — nothing binds the two on its own.
    override func layout() {
        super.layout()
        let width = scrollView.contentSize.width
        if width > 0, let column = outlineView.tableColumns.first,
           abs(column.width - width) > 0.5 {
            column.minWidth = width
            column.maxWidth = width
            column.width = width
        }
        let measure = (bounds.width * Layout.messageWidth).rounded(.down)
        if measure > 0, errorLabel.preferredMaxLayoutWidth != measure {
            errorLabel.preferredMaxLayoutWidth = measure
            // Without this a label laid out wider kept its old line count at
            // the new measure, and the last line was cut off.
            errorLabel.invalidateIntrinsicContentSize()
        }
    }

    private lazy var leadingConstraint =
        scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalInset)
    private lazy var trailingConstraint =
        scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalInset)

    /// The column's left and right margin, matched to the editor's own so the
    /// tree and the text beside it start on the same line.
    var horizontalInset: CGFloat = 20 {
        didSet {
            guard horizontalInset != oldValue else { return }
            leadingConstraint.constant = horizontalInset
            trailingConstraint.constant = -horizontalInset
        }
    }

    // MARK: - Content

    /// Parses the note, unless the tree on screen is already what it would
    /// make. The key is the render's own: a tab switch, a resize and a
    /// settings change all ask, and most of the time nothing it is made from
    /// has moved.
    func show(_ note: Note, in context: PreviewContext) {
        isColumnVisible = context.isVisible
        let isNewDocument = self.note !== note
        // Every row the search is holding belongs to the file being taken
        // out, the way a document's selections do.
        if isNewDocument { findSession.close() }
        self.note = note
        guard context.isVisible else { return }
        if case .tree(let format) = note.previewKind { self.format = format }
        let text = note.text
        if let renderedKey, !isNewDocument,
           renderedKey.matches(note: note, text: text, font: context.font) { return }
        if isNewDocument { hasSeededExpansion = false }
        apply(font: context.font)
        renderedKey = RenderKey(
            noteID: note.id, text: text, filePath: note.fileURL?.path,
            fontName: context.font.fontName, fontSize: context.font.pointSize
        )
        parse(text)
    }

    /// What the tree on screen was made from. Nothing here is about the look
    /// of it: the colours are the system's own and follow light and dark
    /// without a fresh parse.
    private struct RenderKey {
        let noteID: UUID
        let text: String
        let filePath: String?
        let fontName: String
        let fontSize: CGFloat

        func matches(note: Note, text: String, font: NSFont) -> Bool {
            noteID == note.id && self.text == text && filePath == note.fileURL?.path
                && fontName == font.fontName && fontSize == font.pointSize
        }
    }

    /// Throws the remembered tree away, so the next show parses afresh — the
    /// file changed on disk under the tab, or a setting moved under it.
    func invalidateRender() {
        renderedKey = nil
    }

    /// The one place the format is named. A failure leaves nothing of the
    /// last good tree behind: a tree that no longer matches the text beside
    /// it would be a map of somewhere else.
    private func parse(_ text: String) {
        let scroll = scrollView.contentView.bounds.origin
        do {
            let document = try format.parse(text)
            parseError = nil
            // A file that is one plain value is not a tree — YAML and TOML
            // will read a pasted page, or a paragraph of prose, as a single
            // scalar, and a row holding the whole file is not a reading of
            // it. It is the same news as a failure and it is told the same
            // way.
            guard !Self.isOnePlainValue(document) else {
                showMessage(
                    detail: String(
                        format: L10n.text(
                            "The whole file is one plain value, not a %@ document."
                        ),
                        format.displayName
                    ),
                    in: text
                )
                return
            }
            build(document)
            errorLabel.isHidden = true
            scrollView.isHidden = false
            restore(scroll: scroll)
        } catch let error as StructuredParseError {
            showFailure(error, in: text)
        } catch {
            showFailure(StructuredParseError(line: 1, message: "Not readable"), in: text)
        }
    }

    /// The whole document as one leaf — no mapping, no sequence, no element:
    /// nothing with parts. Several roots are a stream and still a tree.
    private static func isOnePlainValue(_ document: StructuredDocument) -> Bool {
        document.roots.count == 1 && document.roots[0].isBranch == false
    }

    private func showFailure(_ error: StructuredParseError, in text: String) {
        parseError = error
        showMessage(
            detail: String(format: L10n.text("Line %d — %@"), error.line, error.message),
            in: text
        )
    }

    /// What stands in the tree's place: the headline naming the format, one
    /// line of detail under it, and — where the text plainly reads as
    /// something else — the way out, which is the footer's own badge.
    ///
    /// The last good tree is not kept: a tree that no longer matched the text
    /// beside it would be a map of somewhere else.
    private func showMessage(detail: String, in text: String) {
        rows = []
        rowsByLine = [:]
        flatRows = []
        flatRowOrder = [:]
        rowsAreStale = false
        outlineView.reloadData()
        // There is no tree to search until the file parses again.
        findSession.refresh()
        errorLabel.attributedStringValue = Self.message(
            headline: String(format: L10n.text("Not valid %@"), format.displayName),
            detail: detail, hint: hint(for: text), font: font
        )
        errorLabel.isHidden = false
        scrollView.isHidden = true
        needsLayout = true
    }

    /// What the text reads as, if it is plainly something other than what the
    /// tab is being read as. The detector is the same one the footer's own
    /// offer is made from, so the two never disagree.
    private func hint(for text: String) -> String? {
        guard let kind = FormatDetector.detect(text), kind != .tree(format) else { return nil }
        return String(
            format: L10n.text("It reads as %@ — choose that in the footer's format badge."),
            NoteFormat.preview(kind).displayName
        )
    }

    /// The three lines as one centred string: the headline in the label
    /// colour at the editor's size, the detail and the way out quieter under
    /// it.
    private static func message(
        headline: String, detail: String, hint: String?, font: NSFont
    ) -> NSAttributedString {
        func centred(spacingAfter: CGFloat) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byWordWrapping
            style.paragraphSpacing = spacingAfter
            return style
        }
        // The headline stands a little further off what it is a headline for
        // than those lines stand off each other.
        let title = centred(spacingAfter: 7)
        let paragraph = centred(spacingAfter: 4)
        let message = NSMutableAttributedString(string: headline, attributes: [
            .font: NSFont.systemFont(ofSize: font.pointSize, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: title,
        ])
        for line in [detail, hint].compactMap({ $0 }) {
            message.append(NSAttributedString(string: "\n" + line, attributes: [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]))
        }
        return message
    }

    /// The document, turned into rows and put on screen with whatever was
    /// open still open.
    private func build(_ document: StructuredDocument) {
        var byLine: [Int: [Row]] = [:]
        var count = 0

        func makeRows(_ nodes: [StructuredNode], parentPath: String, depth: Int) -> [Row] {
            nodes.enumerated().map { index, node in
                count += 1
                // The key where there is one, the position where there is
                // not: `settings/font/size`, `bookmarks/0/path`.
                let component = node.key ?? String(index)
                let path = parentPath.isEmpty ? component : parentPath + "\u{1F}" + component
                let row = Row(node: node, path: path, depth: depth)
                byLine[node.line, default: []].append(row)
                row.adopt(makeRows(node.children, parentPath: path, depth: depth + 1))
                return row
            }
        }

        rows = makeRows(document.roots, parentPath: "", depth: 0)
        indexFlatRows()
        for (_, sharing) in byLine {
            let first = sharing
                .filter { $0.node.range != nil }
                .min { ($0.node.range?.location ?? 0) < ($1.node.range?.location ?? 0) }
            first?.startsItsLine = true
        }
        rowsByLine = byLine
        rowsAreStale = false
        if !hasSeededExpansion {
            hasSeededExpansion = true
            expandedPaths = seedExpansion(nodeCount: count)
        }
        outlineView.reloadData()
        applyExpansion()
        // The rows the search was holding were made by the last parse; the
        // query is run again over the ones that have just replaced them.
        findSession.refresh()
    }

    /// The flat walk a search reads the tree by, made once per parse.
    private func indexFlatRows() {
        flatRows = []
        flatRowOrder = [:]
        func walk(_ list: [Row]) {
            for row in list {
                flatRowOrder[ObjectIdentifier(row)] = flatRows.count
                flatRows.append(row)
                walk(row.children)
            }
        }
        walk(rows)
    }

    /// Everything, for a document small enough that everything is readable;
    /// the first two levels otherwise, which is its shape without its
    /// contents.
    private func seedExpansion(nodeCount: Int) -> Set<String> {
        var paths: Set<String> = []
        let limit = nodeCount <= Self.expandEverythingBelow ? Int.max : Self.defaultDepth
        func walk(_ list: [Row]) {
            for row in list where row.node.isBranch && row.depth < limit {
                paths.insert(row.path)
                walk(row.children)
            }
        }
        walk(rows)
        return paths
    }

    /// Reopens the branches the reader had open. A path that is no longer in
    /// the document is simply not there to open; one that has just appeared
    /// arrives closed, since nobody has asked for it.
    private func applyExpansion() {
        func walk(_ list: [Row]) {
            for row in list where row.node.isBranch {
                guard expandedPaths.contains(row.path) else { continue }
                outlineView.expandItem(row)
                walk(row.children)
            }
        }
        walk(rows)
    }

    private func restore(scroll origin: NSPoint) {
        guard origin.y > 0 else { return }
        let maximum = max(0, outlineView.bounds.height - scrollView.contentSize.height)
        scrollView.contentView.scroll(to: NSPoint(x: origin.x, y: min(origin.y, maximum)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func apply(font: NSFont) {
        guard font != self.font else { return }
        self.font = font
        outlineView.rowHeight = max(Layout.rowHeight, (font.pointSize * 1.55).rounded())
        errorLabel.font = font
    }

    // MARK: - A row's text

    /// The key, then the value. The key is the system font, so it reads as a
    /// name; the value is the editor's own monospaced face and is coloured by
    /// what it is, which is the whole of the tree's syntax highlighting.
    private func title(of row: Row) -> NSAttributedString {
        let line = NSMutableAttributedString()
        let key = keyText(of: row)
        if !key.string.isEmpty { line.append(key) }

        switch row.node.value {
        case .object, .array:
            // A closed branch says how much is inside it, quietly, so the
            // shape of the document reads without opening anything. An open
            // one has its members on screen already, and a branch with no
            // name at all — the document's own root — says it either way,
            // since otherwise the row would be blank.
            let isOpen = outlineView.isItemExpanded(row)
            guard !isOpen || key.string.isEmpty else { break }
            if !key.string.isEmpty { line.append(plain(Layout.keyValueGap)) }
            line.append(NSAttributedString(string: summary(of: row.node), attributes: [
                .font: monospaced, .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        default:
            if !key.string.isEmpty { line.append(plain(Layout.keyValueGap)) }
            line.append(NSAttributedString(string: valueText(of: row.node), attributes: [
                .font: monospaced, .foregroundColor: colour(of: row.node.value),
            ]))
        }
        applyFindBands(to: line, of: row)
        return line
    }

    /// The bands ⌘F leaves on a row. There is no text storage here to lay a
    /// temporary attribute on, so a match is a background colour on the row's
    /// own string, laid on as the row is built and gone the next time it is —
    /// which is why a query, a step and a re-parse all ask for the rows they
    /// touch to be drawn again.
    private func applyFindBands(to line: NSMutableAttributedString, of row: Row) {
        let whole = NSRange(location: 0, length: line.length)
        for band in findSession.bands(of: row) {
            let clamped = NSIntersectionRange(band.range, whole)
            guard clamped.length > 0 else { continue }
            guard band.isCurrent else {
                line.addAttribute(.backgroundColor, value: TreeFindSession.quietBand,
                                  range: clamped)
                continue
            }
            // `findHighlightColor` is AppKit's own find yellow, the same light
            // colour in both appearances, so the text on it is spelled black
            // rather than left as the row's own colour, which is white in the
            // dark and would disappear into the band.
            line.addAttributes([
                .backgroundColor: TreeFindSession.currentBand,
                .foregroundColor: NSColor.black,
            ], range: clamped)
        }
    }

    /// The member's key, or the item's own place in the array it is in. An
    /// index is quieter than a name: it is the tree counting, not the file
    /// saying something.
    private func keyText(of row: Row) -> NSAttributedString {
        if let key = row.node.key {
            return NSAttributedString(string: key, attributes: [
                .font: font, .foregroundColor: NSColor.labelColor,
            ])
        }
        guard let parent = row.parent, case .array = parent.node.value,
              let index = parent.children.firstIndex(where: { $0 === row })
        else { return NSAttributedString() }
        return NSAttributedString(string: String(index), attributes: [
            .font: font, .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    private func plain(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font])
    }

    /// `{3}` for three members, `[12]` for twelve items — the two brackets
    /// the grammars themselves use.
    private func summary(of node: StructuredNode) -> String {
        switch node.value {
        case .object: "{\(node.children.count)}"
        case .array: "[\(node.children.count)]"
        default: ""
        }
    }

    /// What a leaf says. A string wears its quotes, so an empty one and one
    /// made of spaces are still visible; everything else is spelled the way
    /// the file spells it. Not private: it is also what ⌘F searches, and a
    /// search over anything but the text on screen would be a search of
    /// something the reader cannot see.
    func valueText(of node: StructuredNode) -> String {
        switch node.value {
        case .string(let value): "\"\(value)\""
        case .number(let value): value
        case .bool(let value): value ? "true" : "false"
        case .null: "null"
        case .date(let value): value
        case .text(let value): value
        case .comment(let value): value
        case .object, .array: summary(of: node)
        }
    }

    /// System colours, so the tree reads in light and dark without a palette
    /// of its own: red for text the file quotes, blue for a number, purple
    /// for the words a grammar reserves, and the label greys for a run of
    /// XML text and for a comment.
    private func colour(of value: StructuredNode.Value) -> NSColor {
        switch value {
        case .string: .systemRed
        case .number: .systemBlue
        case .bool, .null, .date: .systemPurple
        case .text: .labelColor
        case .comment: .secondaryLabelColor
        case .object, .array: .tertiaryLabelColor
        }
    }

    private var monospaced: NSFont {
        NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
    }

    // MARK: - Both halves of the block sync

    /// A row was clicked: the source it stands for is selected in the editor,
    /// and the keyboard stays here. The tree is walked with the arrows and
    /// opened with the triangles, and a click that took the keyboard away
    /// would end the walk — the same reason a dump's cell click reveals
    /// rather than jumps.
    ///
    /// A leaf gives its **value** and nothing else, quotes and all, the way a
    /// dump's cell click gives the one value it stands over: the row says
    /// `name  "Nota"`, and `"Nota"` is what the reader pointed at. A branch
    /// gives the whole of itself, key and body together — its value part is
    /// only its brackets, if it has any, and nobody clicking `owner` means
    /// the punctuation around it.
    ///
    /// The line stands in where a parser could not say: a member of a compact
    /// file shares its line with the whole document, so that is the last
    /// resort and not the rule.
    private func reveal(row index: Int) {
        guard sendsBlockClicks, !rowsAreStale, let onSourceReveal, let note,
              let row = outlineView.item(atRow: index) as? Row
        else { return }
        let node = row.node
        // The whole member, key and value (decided 2026-09-06, after a day of
        // the value alone): what the row names is what the click selects.
        let source = node.range ?? note.lineIndex.range(ofLine: node.line)
        onSourceReveal(source)
    }

    /// Lights the deepest node the caret is standing in, and brings it into
    /// view. A row inside a closed branch is not on screen to light, so the
    /// deepest one that *is* stands in for it.
    ///
    /// Deepest by *span*: the caret is inside the root, inside the member of
    /// it that holds it, inside that member's own member, and the innermost
    /// of those is the row the reader is in. That is the answer a one-line
    /// file needs, where every node begins on line 1 and the line says
    /// nothing.
    ///
    /// Where a node has no span — a parser that could not say — the line
    /// stands in for it, and then the *outermost* node beginning that line is
    /// the one lit: a line usually begins exactly one node and the two are the
    /// same thing, while a line that begins several is a run of the document
    /// rather than one node's.
    @discardableResult
    func highlightBlock(containingSource location: Int) -> Bool {
        guard !rowsAreStale, let note, !rows.isEmpty else {
            clearHighlight()
            return false
        }
        let line = note.lineIndex.lineNumber(at: location)
        guard var candidate = row(containing: location, onLine: line)
            ?? rowsByLine[line]?.min(by: { $0.depth < $1.depth })
        else {
            clearHighlight()
            return false
        }
        // Up to the deepest ancestor that is actually on screen.
        while outlineView.row(forItem: candidate) < 0 {
            guard let parent = candidate.parent else {
                clearHighlight()
                return false
            }
            candidate = parent
        }
        let index = outlineView.row(forItem: candidate)
        isSelectingForCaret = true
        outlineView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        isSelectingForCaret = false
        outlineView.scrollRowToVisible(index)
        return true
    }

    /// The deepest row whose span holds a place in the source, found by
    /// walking down: the caret is in one of the roots, then in one of that
    /// row's children, and so on until nothing below holds it.
    private func row(containing location: Int, onLine line: Int) -> Row? {
        var found: Row?
        var list = rows
        while let row = Self.row(in: list, containing: location, onLine: line) {
            found = row
            list = row.children
        }
        return found
    }

    /// The one of a row's children the place is written in.
    ///
    /// Two edges, both of them where a caret actually sits. One exactly at
    /// the end of a node is still in it — that is where typing leaves you —
    /// unless the node beside it begins there, which wins. And one in the
    /// indentation before the first node of a line is in that node: the white
    /// space in front of `"b": 2` is nobody else's.
    private static func row(in list: [Row], containing location: Int, onLine line: Int) -> Row? {
        var touching: Row?
        for row in list {
            guard let range = row.node.range, location <= NSMaxRange(range) else { continue }
            guard location >= range.location || (row.startsItsLine && row.node.line == line)
            else { continue }
            if location < NSMaxRange(range) { return row }
            if touching == nil { touching = row }
        }
        return touching
    }

    /// Puts the lit row out without touching the tree — what reading mode
    /// does on the way in.
    func clearHighlight() {
        isSelectingForCaret = true
        outlineView.deselectAll(nil)
        isSelectingForCaret = false
    }

    /// An edit has moved every line: the rows point nowhere until the next
    /// parse lands.
    func invalidateBlocks() {
        rowsAreStale = true
        clearHighlight()
    }

    // MARK: - What ⌘F asks of the tree

    /// Every row, flat, in the order the file writes them — what a search
    /// walks. Rows inside a closed branch are in it like any other: a match is
    /// what opens the branch.
    var findRows: [Row] { flatRows }

    /// The parts of a row a search looks in, and where each of them begins in
    /// the row's own text.
    ///
    /// The key where the file names one — an array item's index is the tree
    /// counting rather than the file saying something, so it is drawn and not
    /// searched — and the value of a leaf as the row spells it, quotes and
    /// all. A branch's `{3}` is the tree counting too.
    func findFields(of row: Row) -> [TreeFindField] {
        var fields: [TreeFindField] = []
        let drawnKey = keyText(of: row).string as NSString
        if let key = row.node.key, !key.isEmpty {
            fields.append(TreeFindField(kind: .key, text: key, offset: 0))
        }
        guard !row.node.isBranch else { return fields }
        let gap = Layout.keyValueGap as NSString
        let offset = drawnKey.length == 0 ? 0 : drawnKey.length + gap.length
        fields.append(TreeFindField(kind: .value, text: valueText(of: row.node), offset: offset))
        return fields
    }

    /// Opens every branch above a row, so a match deep inside a closed one is
    /// on screen to land on. It goes through `expandedPaths`, the way the
    /// reader's own triangles do, so the next parse comes back with what the
    /// search opened still open. Nothing is ever closed: the branches the
    /// reader left open are theirs.
    func expandAncestors(of row: Row) {
        var chain: [Row] = []
        var above = row.parent
        while let parent = above {
            chain.append(parent)
            above = parent.parent
        }
        for branch in chain.reversed() {
            expandedPaths.insert(branch.path)
            outlineView.expandItem(branch)
        }
    }

    /// Lands on a row: it is selected and brought into view, without being
    /// read back as a click.
    func selectFindRow(_ row: Row) {
        let index = outlineView.row(forItem: row)
        guard index >= 0 else { return }
        isSelectingForCaret = true
        outlineView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        isSelectingForCaret = false
        outlineView.scrollRowToVisible(index)
    }

    /// The source a match stands for, sent to the editor so the caret follows
    /// what the reader found: the value alone where the value matched, and the
    /// whole member where its key did — a key has no span of its own, and the
    /// member is how it is found again in the file.
    ///
    /// Unlike a click, this is sent in reading mode too. A find is the reader
    /// saying where they want to be, and the editor they flip back to should
    /// already be there.
    func revealFindSource(of row: Row, kind: TreeFindKind) {
        guard !rowsAreStale, let onSourceReveal, let note else { return }
        let node = row.node
        let fallback = node.range ?? note.lineIndex.range(ofLine: node.line)
        onSourceReveal(kind == .value ? (node.valueRange ?? fallback) : fallback)
    }

    /// Draws the given rows again, for the bands they have just gained or
    /// lost. A row inside a closed branch is not on screen and has nothing to
    /// draw.
    func redrawFindRows(_ rows: [Row]) {
        var indexes = IndexSet()
        for row in rows {
            let index = outlineView.row(forItem: row)
            if index >= 0 { indexes.insert(index) }
        }
        guard !indexes.isEmpty else { return }
        outlineView.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: 0))
    }

    /// Where the row at the top of the column sits in the flat walk — where an
    /// incremental search counts from.
    var firstVisibleFindRowOrder: Int? {
        let visible = outlineView.rows(in: scrollView.contentView.documentVisibleRect)
        guard visible.length > 0,
              let row = outlineView.item(atRow: visible.location) as? Row
        else { return nil }
        return flatRowOrder[ObjectIdentifier(row)]
    }

    /// And where the selected row sits, which is where ⌘E counts from.
    var selectedFindRowOrder: Int? {
        guard let row = selectedFindRow else { return nil }
        return flatRowOrder[ObjectIdentifier(row)]
    }

    /// What ⌘E takes from the tree: the selected row's value where it has one,
    /// its key where it does not. A string's quotes are left behind — the
    /// reader means the word inside them, and the quotes are the row's
    /// spelling rather than the file's word.
    var selectionTextForFind: String? {
        guard let row = selectedFindRow else { return nil }
        switch row.node.value {
        case .string(let value): return value
        case .object, .array: return row.node.key
        default: return valueText(of: row.node)
        }
    }

    private var selectedFindRow: Row? {
        let index = outlineView.selectedRow
        guard index >= 0 else { return nil }
        return outlineView.item(atRow: index) as? Row
    }

    /// The keyboard back to the tree, which is where Escape leaves it.
    ///
    /// Only ever taken back from the bar itself: a find closed because the tab
    /// in front changed must not pull the keyboard out of whatever is being
    /// read now.
    func focusOutline() {
        guard let window = outlineView.window else { return }
        let responder = window.firstResponder
        let inBar = (responder as? NSView)?.isDescendant(of: findBar) ?? false
        guard inBar || responder === outlineView else { return }
        window.makeFirstResponder(outlineView)
    }

    // MARK: - The keyboard

    /// Reading mode, where the tree is what is being read. It is also what
    /// says whose ⌘F this is: in split the editor has the keyboard and the
    /// find is the editor's, the same rule the page keeps.
    var takesKeyboard = false {
        didSet {
            guard takesKeyboard != oldValue else { return }
            outlineView.takesKeyboard = takesKeyboard
        }
    }

    @discardableResult
    func focus(in window: NSWindow?) -> Bool {
        window?.makeFirstResponder(outlineView) ?? false
    }

    // MARK: - Files let go on the tree

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        PreviewFileDrop.operation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        PreviewFileDrop.operation(for: sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        PreviewFileDrop.accept(sender, by: onDropFiles)
    }

    // MARK: - Background

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // The row titles carry resolved colours, so they are made again when
        // light and dark swap.
        outlineView.reloadData()
        applyExpansion()
        needsDisplay = true
    }

    // MARK: - Tests

    /// The rows on screen, top to bottom, as `key` / `value` pairs — the one
    /// thing a test has to reach past the view for.
    var visibleRows: [(indent: Int, title: String)] {
        (0..<outlineView.numberOfRows).compactMap { index in
            guard let row = outlineView.item(atRow: index) as? Row else { return nil }
            return (row.depth, title(of: row).string)
        }
    }

    /// The line the tree failed on, and why. `nil` while it parses.
    var shownParseError: StructuredParseError? { parseError }

    /// What the pane says in place of the tree — all of it, the headline and
    /// the lines under it, as one string.
    var shownErrorMessage: String? { errorLabel.isHidden ? nil : errorLabel.stringValue }

    /// The same, as it is drawn, for a test that checks its two voices.
    var shownMessage: NSAttributedString? {
        errorLabel.isHidden ? nil : errorLabel.attributedStringValue
    }

    /// The row the caret has lit, by its path.
    var selectedPath: String? {
        let index = outlineView.selectedRow
        guard index >= 0, let row = outlineView.item(atRow: index) as? Row else { return nil }
        return row.path
    }

    /// The outline itself, for a test that has to click a row.
    var outline: NSOutlineView { outlineView }

    /// The row at a place in the outline, for the same reason.
    func path(atRow index: Int) -> String? {
        (outlineView.item(atRow: index) as? Row)?.path
    }
}

// MARK: - The tree itself

extension TreePreviewView: NSOutlineViewDataSource {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let row = item as? Row else { return false }
        return !row.children.isEmpty
    }

    private func children(of item: Any?) -> [Row] {
        guard let row = item as? Row else { return rows }
        return row.children
    }
}

extension TreePreviewView: NSOutlineViewDelegate {

    func outlineView(
        _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
    ) -> NSView? {
        guard let row = item as? Row else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("row")
        let field: NSTextField
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self)
            as? NSTextField {
            field = reused
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = identifier
            field.lineBreakMode = .byTruncatingTail
            field.cell?.usesSingleLineMode = true
        }
        field.attributedStringValue = title(of: row)
        return field
    }

    /// The reader opened or closed a branch. What is open is remembered by
    /// path, so the next parse — one keystroke later — comes back the same
    /// shape.
    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let row = notification.userInfo?["NSObject"] as? Row else { return }
        expandedPaths.insert(row.path)
        reloadTitle(of: row)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let row = notification.userInfo?["NSObject"] as? Row else { return }
        expandedPaths.remove(row.path)
        reloadTitle(of: row)
    }

    /// A branch's own row says how much is inside it while it is closed, so
    /// it is drawn again when it opens or closes.
    private func reloadTitle(of row: Row) {
        let index = outlineView.row(forItem: row)
        guard index >= 0 else { return }
        outlineView.reloadData(forRowIndexes: IndexSet(integer: index),
                               columnIndexes: IndexSet(integer: 0))
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { true }
}

// MARK: - The clip

/// `NSClipView` that answers for the whole of itself, inset and all.
///
/// The tree is held off the top of the column by the scroll view's own
/// `contentInsets` rather than by a constraint, so that a row scrolled up
/// there still shows — the band is a hover, not a lid, and the document
/// runs under it the way it runs under the ⌘F pill. AppKit's own clip view
/// does not agree: its `hitTest` stops at the inset, on the reasoning that
/// what scrolls under a translucent title bar is not there to be clicked.
/// Here it is: the rows in the top band are drawn, and the top 44pt of the
/// tree took no clicks at all — the root of a scrolled file and the row
/// under it were dead.
///
/// So the inset is given back. `super` still answers for everything it
/// would have, and only where it gives up does the document view get asked
/// itself — which is the same question, one view further in.
private final class TreeClipView: NSClipView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let hit = super.hitTest(point) { return hit }
        guard !isHidden, frame.contains(point) else { return nil }
        return documentView?.hitTest(convert(point, from: superview))
    }
}

// MARK: - The outline

/// `NSOutlineView` with the two things the column needs of it: a drag from
/// the Finder is the column's, not the tree's, and the background is the
/// document's rather than a list's.
private final class TreeOutlineView: NSOutlineView {

    /// The row a click landed on — never the disclosure triangle's, which is
    /// a branch being opened rather than a place to go.
    ///
    /// Said here rather than through the table's own target and action,
    /// because that action arrives on the mouse *up* at the end of AppKit's
    /// tracking loop: the same reason the dump's grid answers for its own
    /// clicks.
    var onRowClick: ((Int) -> Void)?

    /// The tree's find bar. Find…, Find Next, Find Previous and Use Selection
    /// for Find are nil-targeted `performTextFinderAction:` items, so they
    /// land here whenever the outline has the keyboard — which, after a click
    /// on a row, is split as well as reading.
    ///
    /// So they are answered here only in reading mode. In split the editor is
    /// what ⌘F belongs to, whatever was last clicked in the column, which is
    /// the same rule the page keeps — and the item is *handed on* rather than
    /// dropped: implementing the selector at all makes this view the target,
    /// so a silent return would grey ⌘F out the moment a reader clicked a
    /// row. It goes up the chain to `MainWindowController`, which is where
    /// the editor's own session is.
    weak var findSession: TreeFindSession?

    /// Whether the tree is what is being read. Not `acceptsFirstResponder`:
    /// the arrows go on walking the tree in split, where a click leaves the
    /// keyboard here on purpose.
    var takesKeyboard = false

    override var acceptsFirstResponder: Bool { true }

    override func performTextFinderAction(_ sender: Any?) {
        guard takesKeyboard else {
            // Split: the editor's, so the item goes on up the chain rather
            // than stopping here.
            nextResponder?.tryToPerform(
                #selector(performTextFinderAction(_:)), with: sender
            )
            return
        }
        guard let item = sender as? NSValidatedUserInterfaceItem,
              let action = NSTextFinder.Action(rawValue: item.tag)
        else { return }
        findSession?.perform(action)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(performTextFinderAction(_:)) else {
            return super.validateUserInterfaceItem(item)
        }
        guard let action = NSTextFinder.Action(rawValue: item.tag) else { return false }
        // In split the answer is the editor's, and the editor takes every
        // action a text session takes — Find and Replace… among them.
        return takesKeyboard
            ? TreeFindSession.handles(action)
            : TextFindSession.handles(action)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = row(at: point)
        let triangle = index >= 0 ? frameOfOutlineCell(atRow: index) : .zero
        let onTriangle = triangle.width > 0 && point.x < triangle.maxX
        super.mouseDown(with: event)
        guard index >= 0, !onTriangle else { return }
        onRowClick?(index)
    }

    /// The tree is chrome over nothing: a drag anywhere in the column opens
    /// the files let go on it, and the outline never answers for one itself.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        PreviewFileDrop.operation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        PreviewFileDrop.operation(for: sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        (enclosingScrollView?.superview as? TreePreviewView)
            .map { PreviewFileDrop.accept(sender, by: $0.onDropFiles) } ?? false
    }
}

// MARK: - What a format is called

extension StructuredFormat {
    /// The name the pane puts on screen when a file will not parse. The
    /// grammar's own name, spelled the way its authors spell it, and the same
    /// in every language — "Not valid JSON" names a format, not a word.
    var displayName: String {
        switch self {
        case .json: "JSON"
        case .yaml: "YAML"
        case .toml: "TOML"
        case .xml: "XML"
        }
    }
}
