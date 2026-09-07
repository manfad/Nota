import AppKit
import XCTest
@testable import Nota

/// Diagrams where the reader meets them: in the Markdown render, between the
/// words. The engine is `MermaidFlowchartTests`' subject; this is the seam
/// around it — which fences become a picture, which stay the code they are,
/// and the promise that the maths beside them never notices.
final class MarkdownMermaidTests: XCTestCase {

    private let editorFont = NSFont.systemFont(ofSize: 13)

    private func result(
        _ markdown: String, font: NSFont? = nil, width: CGFloat = 400
    ) -> MarkdownRenderer.Result {
        MarkdownRenderer.render(
            markdown, font: font ?? editorFont, assets: nil, width: width
        )
    }

    private func render(_ markdown: String, width: CGFloat = 400) -> NSAttributedString {
        result(markdown, width: width).text
    }

    private func attachments<T: NSTextAttachment>(
        _ rendered: NSAttributedString, of kind: T.Type
    ) -> [T] {
        var found: [T] = []
        rendered.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: rendered.length)
        ) { value, _, _ in
            if let attachment = value as? T { found.append(attachment) }
        }
        return found
    }

    /// The source text each rendered block came from, in order.
    private func sources(_ markdown: String) -> [String] {
        let source = markdown as NSString
        return result(markdown).blocks.map { source.substring(with: $0.source) }
    }

    private func isCodeBlock(_ rendered: NSAttributedString, containing text: String) -> Bool {
        let range = (rendered.string as NSString).range(of: text)
        guard range.location != NSNotFound else { return false }
        return rendered.attribute(
            .notaCodeBlock, at: range.location, effectiveRange: nil
        ) as? Bool == true
    }

    private let flowchart = """
    ```mermaid
    flowchart TD
      A[Start] --> B{Ready?}
      B -- yes --> C([Ship])
      B -- no --> A
    ```
    """

    // MARK: - A fence that draws

    func testAMermaidFenceBecomesOneDiagramBlock() throws {
        let rendered = render("Before.\n\n\(flowchart)\n\nAfter.")

        let diagrams = attachments(rendered, of: MermaidAttachment.self)
        XCTAssertEqual(diagrams.count, 1)
        let diagram = try XCTUnwrap(diagrams.first)
        XCTAssertGreaterThan(diagram.displaySize.width, 0)
        XCTAssertGreaterThan(diagram.displaySize.height, 0)
        XCTAssertFalse(
            rendered.string.contains("flowchart TD"),
            "the source is drawn, not spelled"
        )
    }

    func testTheDiagramStandsInTheMiddleOfThePane() throws {
        let rendered = render(flowchart)
        let range = (rendered.string as NSString).range(of: "\u{FFFC}")
        let style = try XCTUnwrap(
            rendered.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                as? NSParagraphStyle
        )
        XCTAssertEqual(style.alignment, .center)
        XCTAssertGreaterThan(style.paragraphSpacingBefore, 0, "air above")
        XCTAssertGreaterThan(style.paragraphSpacing, 0, "and below")
    }

    func testADiagramWiderThanTheColumnIsScaledDownToIt() throws {
        let wide = """
        ```mermaid
        flowchart LR
          A[The first step here] --> B[The second step here] --> C[The third step here]
          C --> D[The fourth step here] --> E[The fifth step here]
        ```
        """
        let narrow = try XCTUnwrap(
            attachments(render(wide, width: 200), of: MermaidAttachment.self).first
        )
        XCTAssertLessThan(narrow.scale, 1, "it did not fit")
        XCTAssertLessThanOrEqual(narrow.displaySize.width, 201)
        let natural = narrow.diagram.size
        XCTAssertEqual(
            narrow.displaySize.height, (natural.height * narrow.scale).rounded(), accuracy: 0.51,
            "the aspect ratio is kept: both sides took the same scale"
        )

        let roomy = try XCTUnwrap(
            attachments(render(wide, width: 4000), of: MermaidAttachment.self).first
        )
        XCTAssertEqual(roomy.scale, 1, "with room it is drawn at its own size")
    }

    func testTheDiagramIsMeasuredAgainstTheRendersOwnFont() throws {
        let small = try XCTUnwrap(attachments(
            result(flowchart, font: NSFont.systemFont(ofSize: 11), width: 4000).text,
            of: MermaidAttachment.self
        ).first)
        let large = try XCTUnwrap(attachments(
            result(flowchart, font: NSFont.systemFont(ofSize: 22), width: 4000).text,
            of: MermaidAttachment.self
        ).first)
        XCTAssertGreaterThan(large.diagram.size.width, small.diagram.size.width)
    }

    func testTheRenderKnowsItWasFittedToTheColumn() {
        XCTAssertTrue(result(flowchart).dependsOnWidth)
        XCTAssertFalse(result("Just words.").dependsOnWidth)
    }

    // MARK: - A fence that stays code

    func testAnUnsupportedGrammarStaysACodeBlock() {
        let rendered = render("""
        ```mermaid
        gantt
        title A schedule
        ```
        """)
        XCTAssertTrue(attachments(rendered, of: MermaidAttachment.self).isEmpty)
        XCTAssertTrue(rendered.string.contains("gantt"))
        XCTAssertTrue(isCodeBlock(rendered, containing: "gantt"))
    }

    func testAMalformedFlowchartStaysACodeBlock() {
        let rendered = render("""
        ```mermaid
        flowchart TD
          A[Start --> B
        ```
        """)
        XCTAssertTrue(attachments(rendered, of: MermaidAttachment.self).isEmpty)
        XCTAssertTrue(isCodeBlock(rendered, containing: "A[Start --> B"))
    }

    func testAHalfTypedDiagramStaysACodeBlock() {
        let rendered = render("""
        ```mermaid
        flowchart TD
          A -->
        ```
        """)
        XCTAssertTrue(attachments(rendered, of: MermaidAttachment.self).isEmpty)
        XCTAssertTrue(isCodeBlock(rendered, containing: "A -->"))
    }

    func testAnOrdinaryCodeFenceIsUntouched() {
        let rendered = render("""
        ```swift
        let a = 1
        ```
        """)
        XCTAssertTrue(attachments(rendered, of: MermaidAttachment.self).isEmpty)
        XCTAssertTrue(isCodeBlock(rendered, containing: "let a = 1"))
    }

    // MARK: - The source map

    func testADiagramBlockIsFoundBackAtItsFence() {
        let markdown = "Before.\n\n\(flowchart)\n\nAfter."
        XCTAssertEqual(sources(markdown), ["Before.", flowchart, "After."])
    }

    func testTwoDiagramsEachFindTheirOwnFence() {
        let second = "```mermaid\nflowchart LR\n  X --> Y\n```"
        let markdown = "\(flowchart)\n\n\(second)"
        XCTAssertEqual(sources(markdown), [flowchart, second])
    }

    func testADiagramBesideACodeFenceFindsTheRightOne() {
        let code = "```swift\nlet a = 1\n```"
        let markdown = "\(code)\n\n\(flowchart)"
        XCTAssertEqual(sources(markdown), [code, flowchart])
    }

    // MARK: - The maths beside it

    func testAMathsFenceIsUnaffected() throws {
        let markdown = """
        \(flowchart)

        ```math
        x^2 + y^2
        ```

        And $a_1$ inline.
        """
        let rendered = render(markdown)
        XCTAssertEqual(attachments(rendered, of: MermaidAttachment.self).count, 1)
        let maths = attachments(rendered, of: MathAttachment.self)
        XCTAssertEqual(maths.count, 2)
        XCTAssertEqual(maths.first?.formula.tex, "x^2 + y^2")
        XCTAssertEqual(maths.last?.formula.tex, "a_1")
    }

    func testADollarInsideADiagramIsNotAFormula() {
        let rendered = render("""
        ```mermaid
        flowchart TD
          A[Costs $5] --> B[Costs $10]
        ```
        """)
        XCTAssertEqual(attachments(rendered, of: MermaidAttachment.self).count, 1)
        XCTAssertTrue(attachments(rendered, of: MathAttachment.self).isEmpty)
    }

    // MARK: - Drawing through the attachment

    func testTheAttachmentDrawsItsDiagramIntoItsImage() throws {
        let diagram = try XCTUnwrap(
            attachments(render(flowchart), of: MermaidAttachment.self).first
        )
        let image = try XCTUnwrap(diagram.image)
        XCTAssertEqual(image.size, diagram.displaySize)
        let representation = try XCTUnwrap(
            image.representations.first ?? NSBitmapImageRep(data: image.tiffRepresentation ?? Data())
        )
        XCTAssertGreaterThan(representation.size.width, 0)
        // Drawing it is the point: it must not fall over on the way.
        XCTAssertNotNil(image.tiffRepresentation)
    }
}
