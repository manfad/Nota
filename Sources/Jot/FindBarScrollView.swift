import AppKit

/// A plain `NSScrollView` whose only job is to strip the focus ring off the
/// native find bar. `NSTextFinder` builds that bar lazily and installs it as
/// `findBarView` the first time ⌘F is used, so `didSet` is the one hook that
/// reliably sees it — whether it arrives via the menu, incremental search, or
/// AppKit re-creating the bar later.
final class FindBarScrollView: NSScrollView {
    override var findBarView: NSView? {
        didSet { FindBarScrollView.removeFocusRing(from: findBarView) }
    }

    /// Run when ⌘F's bar opens or closes. The bar takes the top of its column,
    /// which is where the mode control floats, so the window controller sends
    /// that control away for as long as the bar is up. Both the editor and the
    /// render have one of these, and in reading mode ⌘F searches the render.
    var onFindBarVisibilityChange: ((Bool) -> Void)?
    private var wasFindBarVisible = false

    /// A few of the bar's own decorations (its buttons' and segments' title
    /// labels are `NSTextField`s too) are only realized once the bar lays
    /// itself out, which happens after `findBarView` is first set — so the
    /// sweep repeats on every layout pass to catch those as well. Walking a
    /// small, already-built tree is cheap, and setting a focus ring type that
    /// is already off is a no-op.
    override func layout() {
        super.layout()
        FindBarScrollView.removeFocusRing(from: findBarView)
        reportFindBarVisibility()
    }

    /// `tile` is where the scroll view re-arranges its own parts, which is
    /// what showing and hiding the bar does — `layout` is not called for it.
    override func tile() {
        super.tile()
        reportFindBarVisibility()
    }

    private func reportFindBarVisibility() {
        guard isFindBarVisible != wasFindBarVisible else { return }
        wasFindBarVisible = isFindBarVisible
        onFindBarVisibilityChange?(isFindBarVisible)
    }

    /// Walks the bar's whole subview tree and turns off the focus ring on
    /// every field in it, including the replace field — the same treatment
    /// the ⌘P picker gives its own search field.
    static func removeFocusRing(from view: NSView?) {
        guard let view else { return }
        if let field = view as? NSTextField {
            field.focusRingType = .none
        }
        for subview in view.subviews {
            removeFocusRing(from: subview)
        }
    }
}
