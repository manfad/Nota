import AppKit

/// The rendered pane beside the editor: a read-only text view showing what
/// `MarkdownRenderer` made of the note.
///
/// It is a view of the note, never a second place to type in it — the text is
/// selectable and its links are clickable, but nothing here is editable and
/// the pane never takes focus away from the editor.
final class MarkdownPreviewView: NSView {

    private let scrollView = NSScrollView()
    private let textView: NSTextView

    /// Matched to the editor's own padding, so the two columns of text start
    /// the same distance from their edges.
    var horizontalInset: CGFloat = 20 {
        didSet {
            guard horizontalInset != oldValue else { return }
            applyInsets()
        }
    }

    /// Run when the pane changes width. Pictures and rules are drawn to fit
    /// the pane, so a resize is a reason to render again.
    var onWidthChange: (() -> Void)?
    private var renderedWidth: CGFloat = 0

    private static let verticalInset: CGFloat = 14

    override init(frame frameRect: NSRect) {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        textView = NSTextView(frame: .zero, textContainer: container)
        super.init(frame: frameRect)

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(
            width: horizontalInset, height: Self.verticalInset
        )
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        // Monochrome, like everything else in the pane: a link is underlined,
        // not tinted.
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.labelColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let width = contentWidth
        // Only a real change, and never while re-rendering at the width that
        // is already in the text: the render must not ask for another one.
        guard width > 0, abs(width - renderedWidth) >= 1 else { return }
        renderedWidth = width
        onWidthChange?()
    }

    // MARK: - Content

    /// The width a picture or a rule can be drawn to: the pane less the two
    /// margins. Zero before the first layout pass, which the renderer reads
    /// as "no width to fit to yet".
    var contentWidth: CGFloat {
        let width = scrollView.contentSize.width - horizontalInset * 2
        return width > 1 ? width : 0
    }

    /// What the pane is showing, for the tests.
    var renderedText: String { textView.string }

    var renderedContent: NSAttributedString {
        textView.attributedString()
    }

    /// Swaps in a fresh render. The pane is re-rendered on every keystroke
    /// once typing stops, so it stays where the reader left it rather than
    /// jumping back to the top each time.
    func show(_ rendered: NSAttributedString) {
        let previous = scrollFraction
        renderedWidth = contentWidth
        textView.textStorage?.setAttributedString(rendered)
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
        layoutSubtreeIfNeeded()
        follow(fraction: previous)
    }

    // MARK: - Scrolling

    /// How far down the pane is, 0 at the top and 1 at the bottom.
    var scrollFraction: CGFloat {
        Self.fraction(of: scrollView)
    }

    /// Puts the pane at the same relative position as the editor. Proportional
    /// rather than line-for-line: the two columns are different heights, and
    /// matching the ends is what keeps them feeling joined.
    func follow(fraction: CGFloat) {
        let clip = scrollView.contentView
        guard let document = scrollView.documentView else { return }
        let scrollable = document.bounds.height - clip.bounds.height
        guard scrollable > 0 else { return }
        let y = (scrollable * min(1, max(0, fraction))).rounded()
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Where a scroll view sits between its top and its bottom.
    static func fraction(of scrollView: NSScrollView) -> CGFloat {
        let clip = scrollView.contentView
        guard let document = scrollView.documentView else { return 0 }
        let scrollable = document.bounds.height - clip.bounds.height
        guard scrollable > 0 else { return 0 }
        return min(1, max(0, clip.bounds.origin.y / scrollable))
    }

    private func applyInsets() {
        textView.textContainerInset = NSSize(
            width: horizontalInset, height: Self.verticalInset
        )
    }
}
