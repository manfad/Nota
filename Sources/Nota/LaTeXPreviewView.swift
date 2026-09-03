import AppKit

/// The LaTeX render's pane.
///
/// A `.tex` tab is read exactly the way a `.md` one is — the same three modes,
/// the same band under the block the caret is in, the same click back into the
/// source, the same ⌘F over the page — because all of that is
/// `RenderedPreviewView`'s and none of it knows which grammar it is showing.
/// The only thing said here is which renderer the note goes through, and where
/// its pictures are: `\includegraphics` resolves beside the file, so the
/// render needs the note's own URL where the Markdown one needs the asset
/// store.
final class LaTeXPreviewView: RenderedPreviewView {
    override func render(
        _ note: Note, in context: PreviewContext, width: CGFloat
    ) -> RenderedDocument {
        LaTeXRenderer.render(
            note.text, font: context.font, baseURL: note.fileURL, width: width
        )
    }
}
