import AppKit

/// The Markdown render's pane.
///
/// Everything a rendered pane does — blocks, the band, the find bar, the
/// frozen wrap width, the scroll position kept across renders — is
/// `RenderedPreviewView`'s. All that is left here is which renderer the note
/// goes through, which is the whole of what makes this pane the Markdown one.
final class MarkdownPreviewView: RenderedPreviewView {
    override func render(
        _ note: Note, in context: PreviewContext, width: CGFloat
    ) -> RenderedDocument {
        MarkdownRenderer.render(
            note.text, font: context.font, assets: context.assets, width: width
        )
    }
}
