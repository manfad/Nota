import AppKit
import Foundation
import XCTest
@testable import Nota

/// The LaTeX render: the parser that reads a `.tex` file into blocks, the
/// renderer that gives them the pane's look, and the tab they are read in —
/// which is the Markdown tab's arrangement with another grammar inside it.
final class LaTeXTests: AppKitTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    private let editorFont = NSFont.systemFont(ofSize: 13)

    private func parse(_ source: String) -> LaTeXDocument {
        LaTeXParser.parse(source)
    }

    private func render(
        _ source: String, baseURL: URL? = nil, width: CGFloat = 400
    ) -> RenderedDocument {
        LaTeXRenderer.render(source, font: editorFont, baseURL: baseURL, width: width)
    }

    /// What each block says, in order — the render's own text, block by block.
    private func rendered(_ source: String, width: CGFloat = 400) -> [String] {
        let result = render(source, width: width)
        return result.blocks.map { result.text.attributedSubstring(from: $0.range).string }
    }

    /// The source each block came from, taken out of the note by the range
    /// the parser gave it. This is the whole of block sync: if these are not
    /// the right substrings, nothing downstream can be.
    private func sources(_ source: String) -> [String] {
        let text = source as NSString
        return parse(source).blocks.map { text.substring(with: $0.source) }
    }

    private func plain(_ nodes: [LaTeXInline]) -> String {
        LaTeXRenderer.plainText(nodes)
    }

    /// Every inline node of a document, flattened, so a test can ask what a
    /// piece of a paragraph came out as.
    private func inlines(_ source: String) -> [LaTeXInline] {
        parse(source).blocks.flatMap { block -> [LaTeXInline] in
            switch block.kind {
            case .paragraph(let content), .heading(_, _, let content),
                 .caption(_, let content):
                return flatten(content)
            case .listItem(_, _, let term, let content):
                return flatten(term) + flatten(content)
            case .title(let title, let author, let date):
                return flatten(title) + flatten(author) + flatten(date)
            case .table(let rows):
                return rows.flatMap { $0.flatMap { flatten($0) } }
            case .math, .code, .unknown, .abstractTitle:
                return []
            }
        }
    }

    private func flatten(_ nodes: [LaTeXInline]) -> [LaTeXInline] {
        nodes.flatMap { node -> [LaTeXInline] in
            switch node {
            case .face(_, let children, _), .footnote(let children, _):
                return [node] + flatten(children)
            case .link(_, let children, _):
                return [node] + flatten(children)
            default:
                return [node]
            }
        }
    }

    private func attributes(
        _ rendered: NSAttributedString, at text: String
    ) throws -> [NSAttributedString.Key: Any] {
        let range = (rendered.string as NSString).range(of: text)
        try XCTSkipIf(range.location == NSNotFound, "\(text.debugDescription) is not there")
        return rendered.attributes(at: range.location, effectiveRange: nil)
    }

    // MARK: - Comments and the preamble

    func testCommentsAreStrippedButAnEscapedPercentIsAPercentSign() {
        XCTAssertEqual(
            rendered("Words % and a comment\nmore words."),
            ["Words more words."]
        )
        XCTAssertEqual(rendered("100\\% of it."), ["100% of it."])
        // A comment on its own line still parts two paragraphs, since the
        // newline that ends it is left where it is.
        XCTAssertEqual(rendered("One.\n% between\n\nTwo."), ["One.", "Two."])
    }

    func testAVerbatimKeepsItsPercentSigns() {
        XCTAssertEqual(
            rendered("\\begin{verbatim}\n50% off % really\n\\end{verbatim}"),
            ["50% off % really"]
        )
    }

    func testThePreambleRendersNothingAndGivesUpOnlyItsTitleFields() {
        let source = """
        \\documentclass[11pt]{article}
        \\usepackage{amsmath}
        \\newcommand{\\x}{y}
        \\title{A Title}
        \\author{An Author}
        \\date{2026}
        \\begin{document}
        Body.
        \\end{document}
        """
        let document = parse(source)
        XCTAssertEqual(plain(document.title), "A Title")
        XCTAssertEqual(plain(document.author), "An Author")
        XCTAssertEqual(plain(document.date), "2026")
        XCTAssertEqual(rendered(source), ["Body."], "nothing of the preamble is on the page")
    }

    func testMaketitleLaysTheTitleFieldsOut() {
        let source = """
        \\title{On Reading}
        \\author{Nota}
        \\date{September}
        \\begin{document}
        \\maketitle
        \\end{document}
        """
        XCTAssertEqual(rendered(source), ["On Reading\nNota\nSeptember"])
        XCTAssertEqual(sources(source), ["\\maketitle"])
    }

    func testAFileWithNoDocumentEnvironmentIsRenderedWhole() {
        let source = "\\section{Fragment}\n\nJust a piece of a paper."
        XCTAssertEqual(rendered(source), ["1 Fragment", "Just a piece of a paper."])
    }

    // MARK: - Sections

    func testSectionsAreNumberedAndTheStarredFormsAreNot() {
        let source = """
        \\section{One}
        \\subsection{One One}
        \\subsubsection{Deep}
        \\subsection{One Two}
        \\section*{Unnumbered}
        \\section{Two}
        \\paragraph{Run in}
        """
        XCTAssertEqual(rendered(source), [
            "1 One", "1.1 One One", "1.1.1 Deep", "1.2 One Two",
            "Unnumbered", "2 Two", "Run in",
        ])
    }

    func testAStarredSectionDoesNotAdvanceTheCounter() {
        XCTAssertEqual(
            rendered("\\section{A}\n\\section*{Aside}\n\\section{B}"),
            ["1 A", "Aside", "2 B"]
        )
    }

    // MARK: - Lists

    func testListsNestAndKeepTheirOwnMarkers() {
        let source = """
        \\begin{itemize}
        \\item Outer
        \\begin{enumerate}
        \\item Inner one
        \\item Inner two
        \\end{enumerate}
        \\item Back out
        \\end{itemize}
        """
        XCTAssertEqual(rendered(source), [
            "•\tOuter", "1.\tInner one", "2.\tInner two", "•\tBack out",
        ])
        let depths = parse(source).blocks.compactMap { block -> Int? in
            guard case .listItem(let depth, _, _, _) = block.kind else { return nil }
            return depth
        }
        XCTAssertEqual(depths, [1, 2, 2, 1])
    }

    func testADescriptionListSetsItsLabelInBold() throws {
        let result = render("\\begin{description}\n\\item[Term] What it means.\n\\end{description}")
        XCTAssertEqual(result.text.string, "Term What it means.")
        let font = try XCTUnwrap(try attributes(result.text, at: "Term")[.font] as? NSFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
    }

    // MARK: - Maths

    func testEveryFormOfMathsComesBackAsAMathNodeWithTheRightDisplay() {
        let inline = inlines("Text $a$ and \\(b\\) here.")
        let forms = inline.compactMap { node -> (String, Bool)? in
            guard case .math(let tex, let display, _) = node else { return nil }
            return (tex, display)
        }
        XCTAssertEqual(forms.map(\.0), ["a", "b"])
        XCTAssertEqual(forms.map(\.1), [false, false])

        for source in ["\\[x\\]", "\\begin{equation}x\\end{equation}",
                       "\\begin{displaymath}x\\end{displaymath}",
                       "\\begin{gather}x\\end{gather}",
                       "\\begin{align}x\\end{align}",
                       "\\begin{multline}x\\end{multline}",
                       "\\begin{eqnarray}x\\end{eqnarray}",
                       "\\begin{equation*}x\\end{equation*}",
                       "\\begin{align*}x\\end{align*}"] {
            let blocks = parse(source).blocks
            guard case .math(let tex, _)? = blocks.first?.kind else {
                return XCTFail("\(source) is not a display formula")
            }
            XCTAssertEqual(tex, "x", source)
        }
    }

    func testTheStarredMathEnvironmentsAreUnnumbered() {
        let numbers = { (source: String) -> [Int?] in
            self.parse(source).blocks.compactMap { block in
                guard case .math(_, let number) = block.kind else { return nil }
                return .some(number)
            }
        }
        XCTAssertEqual(numbers("\\begin{equation}a\\end{equation}"), [1])
        XCTAssertEqual(numbers("\\begin{equation*}a\\end{equation*}"), [Int?.none])
        XCTAssertEqual(numbers("\\[a\\]"), [Int?.none])
    }

    func testAnAlignSplitsIntoARowPerLineEachNumberedAndEachItsOwnBlock() {
        let source = """
        \\begin{align}
        a &= b \\\\
        c &= d \\\\
        e &= f
        \\end{align}
        """
        let blocks = parse(source).blocks
        XCTAssertEqual(blocks.count, 3)
        let rows = blocks.compactMap { block -> (String, Int?)? in
            guard case .math(let tex, let number) = block.kind else { return nil }
            return (tex, number)
        }
        XCTAssertEqual(rows.map(\.0), ["a  = b", "c  = d", "e  = f"],
                       "the alignment ampersands are dropped")
        XCTAssertEqual(rows.map(\.1), [1, 2, 3])
        XCTAssertEqual(sources(source), ["a &= b", "c &= d", "e &= f"],
                       "each row is its own block, at its own line")
    }

    func testNonumberTakesARowOutOfTheNumbering() {
        let source = "\\begin{align}\na &= b \\nonumber \\\\\nc &= d\n\\end{align}"
        let numbers = parse(source).blocks.compactMap { block -> Int?? in
            guard case .math(_, let number) = block.kind else { return nil }
            return .some(number)
        }
        XCTAssertEqual(numbers, [Int?.none, 1])
    }

    // MARK: - Code

    func testVerbatimIsUntouchedIncludingDollarsAndBackslashes() {
        let source = """
        \\begin{verbatim}
        if [ $x -gt 0 ]; then echo "\\frac{1}{2}"; fi
        \\end{verbatim}
        """
        XCTAssertEqual(rendered(source), ["if [ $x -gt 0 ]; then echo \"\\frac{1}{2}\"; fi"])
    }

    func testListingsAndMintedAreCodeBlocksToo() {
        XCTAssertEqual(
            rendered("\\begin{lstlisting}[language=C]\nint x = 1;\n\\end{lstlisting}"),
            ["int x = 1;"]
        )
        XCTAssertEqual(
            rendered("\\begin{minted}{python}\nx = 1\n\\end{minted}"),
            ["x = 1"]
        )
    }

    // MARK: - The unknown

    func testAnUnknownCommandKeepsItsRawSourceBracesAndAll() {
        let nodes = inlines("Before \\marginpar[note]{like this} after.")
        let raw = nodes.compactMap { node -> String? in
            guard case .unknown(let raw, _) = node else { return nil }
            return raw
        }
        XCTAssertEqual(raw, ["\\marginpar[note]{like this}"])
        XCTAssertEqual(rendered("A \\foo{bar} b."), ["A \\foo{bar} b."])
    }

    func testAnUnknownEnvironmentComesBackWhole() {
        let source = "\\begin{theorem}\nEvery cat is a cat.\n\\end{theorem}"
        let blocks = parse(source).blocks
        guard case .unknown(let raw)? = blocks.first?.kind else {
            return XCTFail("an unknown environment is one block")
        }
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(raw, source)
        XCTAssertEqual(sources(source), [source])
    }

    // MARK: - Source ranges

    func testEveryBlockKnowsExactlyWhereInTheSourceItCameFrom() {
        let source = """
        \\section{Heading}

        A paragraph of prose.

        \\begin{itemize}
        \\item An item
        \\end{itemize}

        \\begin{equation}
        E = mc^2
        \\end{equation}

        \\begin{verbatim}
        raw
        \\end{verbatim}
        """
        XCTAssertEqual(sources(source), [
            "\\section{Heading}",
            "A paragraph of prose.",
            "\\item An item",
            "\\begin{equation}\nE = mc^2\n\\end{equation}",
            "\\begin{verbatim}\nraw\n\\end{verbatim}",
        ])
    }

    func testAnInlineSpanKnowsWhereItCameFromToo() {
        let source = "Say \\textbf{loudly} that $x^2$ and \\cite{key} matter."
        let text = source as NSString
        let spans = inlines(source).map { text.substring(with: $0.source) }
        XCTAssertTrue(spans.contains("\\textbf{loudly}"), "\(spans)")
        XCTAssertTrue(spans.contains("$x^2$"), "\(spans)")
        XCTAssertTrue(spans.contains("\\cite{key}"), "\(spans)")
        XCTAssertTrue(spans.contains("Say "), "\(spans)")
    }

    func testRangesSurviveCharactersThatAreMoreThanOneUTF16Unit() {
        // An emoji is two UTF-16 units, which is what `NSString` counts and
        // what the editor beside the render is indexed by.
        let source = "🐈🐈 first.\n\n\\section{Second}"
        XCTAssertEqual(sources(source), ["🐈🐈 first.", "\\section{Second}"])
    }

    func testTheParserSurvivesAnythingAtAll() {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("\\{}$&%^_~#[]abc \n\t*'`-01\\\\begin{end}itemsection")
        for _ in 0 ..< 300 {
            let length = Int.random(in: 0 ... 240, using: &generator)
            let source = String((0 ..< length).map { _ in
                alphabet.randomElement(using: &generator) ?? "a"
            })
            let document = LaTeXParser.parse(source)
            let text = source as NSString
            for block in document.blocks {
                XCTAssertGreaterThanOrEqual(block.source.location, 0, source.debugDescription)
                XCTAssertLessThanOrEqual(
                    NSMaxRange(block.source), text.length, source.debugDescription
                )
            }
            _ = LaTeXRenderer.render(source, font: editorFont, baseURL: nil, width: 300)
        }
    }

    // MARK: - The look

    func testHeadingsScaleTheSameWayTheMarkdownRendersDo() throws {
        let source = "\\section{One}\n\\subsection{Two}\n\\subsubsection{Three}\n\\paragraph{Four}"
        let result = render(source)
        for (level, word) in ["One", "Two", "Three", "Four"].enumerated() {
            let font = try XCTUnwrap(try attributes(result.text, at: word)[.font] as? NSFont)
            XCTAssertEqual(
                font.pointSize,
                (editorFont.pointSize * RenderStyle.headingScales[level]).rounded(),
                "level \(level + 1)"
            )
            XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold), word)
        }
    }

    func testDisplayMathsIsCentredAndNumberedAtTheTrailingEdge() throws {
        let source = """
        \\begin{align}
        a &= b \\\\
        c &= d
        \\end{align}
        """
        let result = render(source, width: 400)
        XCTAssertTrue(result.text.string.contains("(1)"))
        XCTAssertTrue(result.text.string.contains("(2)"))
        XCTAssertTrue(result.dependsOnWidth, "the number is held against the pane's edge")

        let style = try XCTUnwrap(
            result.text.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                as? NSParagraphStyle
        )
        XCTAssertEqual(style.tabStops.count, 2)
        XCTAssertEqual(style.tabStops.first?.alignment, .center)
        XCTAssertEqual(style.tabStops.last?.alignment, .right)
        XCTAssertEqual(
            style.tabStops.last?.location,
            400 - LaTeXRenderer.equationNumberInset * 2
        )
    }

    func testAnUnnumberedFormulaIsSimplyCentredAndNeedsNoWidth() throws {
        let result = render("\\[ x = 1 \\]")
        let style = try XCTUnwrap(
            result.text.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                as? NSParagraphStyle
        )
        XCTAssertEqual(style.alignment, .center)
        XCTAssertFalse(result.dependsOnWidth, "maths is measured against the font, not the pane")
    }

    func testInlineMathsIsAMathAttachmentInTheRunningText() throws {
        let result = render("The value $x^2$ matters.")
        var formulas: [MathFormula] = []
        result.text.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: result.text.length)
        ) { value, _, _ in
            if let attachment = value as? MathAttachment { formulas.append(attachment.formula) }
        }
        XCTAssertEqual(formulas.count, 1)
        XCTAssertEqual(formulas.first?.tex, "x^2")
        XCTAssertEqual(formulas.first?.isDisplay, false)
    }

    func testTeXThatCannotBeReadComesBackAsItsOwnSource() throws {
        let result = render("Broken $\\frac{1$ here.")
        XCTAssertTrue(result.text.string.contains("$\\frac{1$"), result.text.string)
        let attributes = try attributes(result.text, at: "$\\frac{1$")
        let font = try XCTUnwrap(attributes[.font] as? NSFont)
        XCTAssertEqual(font, RenderStyle.monospaced(editorFont.pointSize))
    }

    func testFootnotesAndCitationsAreQuietPlaceholders() throws {
        let result = render("A claim\\footnote{a note} from \\cite{key} and \\ref{sec:x}.")
        XCTAssertEqual(result.text.string, "A claim [a note] from [key] and (sec:x).")
        for piece in ["a note", "[key]", "(sec:x)"] {
            XCTAssertEqual(
                try attributes(result.text, at: piece)[.foregroundColor] as? NSColor,
                .secondaryLabelColor, piece
            )
        }
    }

    func testALinkIsUnderlinedAndClickable() throws {
        let result = render("See \\href{https://example.com}{the page}.")
        XCTAssertEqual(result.text.string, "See the page.")
        let attributes = try attributes(result.text, at: "the page")
        XCTAssertEqual(attributes[.link] as? URL, URL(string: "https://example.com"))
        XCTAssertEqual(
            attributes[.underlineStyle] as? Int, NSUnderlineStyle.single.rawValue
        )
    }

    func testAnUnknownCommandIsSetAsACodeSpan() throws {
        let result = render("Here \\marginpar{note} stands.")
        let attributes = try attributes(result.text, at: "\\marginpar{note}")
        let font = try XCTUnwrap(attributes[.font] as? NSFont)
        XCTAssertEqual(font, RenderStyle.monospaced(editorFont.pointSize))
        XCTAssertNotNil(attributes[.backgroundColor])
    }

    func testAnUnknownEnvironmentIsSetAsACodeBlock() throws {
        let result = render("\\begin{theorem}\nA claim.\n\\end{theorem}")
        XCTAssertNotNil(
            result.text.attribute(.notaCodeBlock, at: 0, effectiveRange: nil),
            "the box the pane draws behind a code block"
        )
    }

    func testAQuoteTakesTheHairlineBarTheMarkdownQuoteHas() {
        XCTAssertEqual(
            rendered("\\begin{quote}\nSaid so.\n\\end{quote}"),
            ["▏\tSaid so."]
        )
    }

    func testATabularLinesItsColumnsUpAsText() {
        XCTAssertEqual(
            rendered("\\begin{tabular}{ll}\n\\hline\na & bb \\\\\nccc & d\n\\end{tabular}"),
            ["a    bb\nccc  d"]
        )
    }

    func testAFigureAndATableNumberTheirCaptions() {
        let source = """
        \\begin{figure}
        \\caption{First picture}
        \\end{figure}
        \\begin{table}
        \\caption{First table}
        \\end{table}
        \\begin{figure}
        \\caption{Second picture}
        \\end{figure}
        """
        XCTAssertEqual(rendered(source), [
            "Figure 1: First picture", "Table 1: First table", "Figure 2: Second picture",
        ])
    }

    // MARK: - Pictures

    func testAnIncludegraphicsResolvesBesideTheFile() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("paper.tex")
        try makePNG(width: 40, height: 20).write(to: directory.appendingPathComponent("plot.png"))
        try "\\includegraphics{plot}".write(to: file, atomically: true, encoding: .utf8)

        let result = render("\\includegraphics{plot}", baseURL: file)
        var pictures: [MarkdownImageAttachment] = []
        result.text.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: result.text.length)
        ) { value, _, _ in
            if let picture = value as? MarkdownImageAttachment { pictures.append(picture) }
        }
        XCTAssertEqual(pictures.count, 1, "the extension is tried when the path has none")
        XCTAssertEqual(pictures.first?.displaySize, NSSize(width: 40, height: 20))
        XCTAssertTrue(result.dependsOnWidth, "a picture is drawn to the pane")
    }

    func testAPathThatResolvesToNothingShowsAsItsOwnAltText() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("paper.tex")
        let result = render("\\includegraphics{missing.png}", baseURL: file)
        XCTAssertEqual(result.text.string, "missing.png")
        XCTAssertEqual(
            try attributes(result.text, at: "missing.png")[.foregroundColor] as? NSColor,
            .secondaryLabelColor
        )
    }

    // MARK: - The tab

    @MainActor
    func testOpeningATexFileGivesItARenderInTheEditorMode() throws {
        _ = NSApplication.shared
        let controller = try makeLaTeXController()
        XCTAssertTrue(controller.canShowRenderedPreview, "the View items are offered")
        XCTAssertEqual(controller.previewMode, .off, "the editor until asked for")
        XCTAssertFalse(controller.previewState.isVisible)
    }

    @MainActor
    func testEveryLaTeXSpellingCountsAndAPlainTextFileStillDoesNot() throws {
        _ = NSApplication.shared
        let controller = try makeLaTeXController()
        let directory = try makeTemporaryDirectory()
        for name in ["a.tex", "b.latex", "c.ltx", "d.TeX"] {
            let file = directory.appendingPathComponent(name)
            try "\\section{X}".write(to: file, atomically: true, encoding: .utf8)
            controller.open(url: file)
            XCTAssertTrue(controller.canShowRenderedPreview, name)
        }
        let plainText = directory.appendingPathComponent("notes.txt")
        try "\\section{X}".write(to: plainText, atomically: true, encoding: .utf8)
        controller.open(url: plainText)
        XCTAssertFalse(controller.canShowRenderedPreview, "a .txt has no render")
        controller.toggleMarkdownPreview()
        XCTAssertFalse(controller.previewState.isVisible)
    }

    @MainActor
    func testCommandPWalksATexTabToReadingAndBackThroughSplit() throws {
        _ = NSApplication.shared
        let controller = try makeLaTeXController()
        controller.toggleMarkdownPreview()
        XCTAssertEqual(controller.previewMode, .split)
        XCTAssertTrue(controller.previewState.isVisible)
        XCTAssertTrue(controller.previewState.renderedText.contains("1 Introduction"))

        controller.toggleMarkdownPreview()
        XCTAssertEqual(controller.previewMode, .reading)
        controller.toggleMarkdownPreview()
        XCTAssertEqual(controller.previewMode, .split, "from reading, ⌘P comes back through split")
        controller.toggleMarkdownPreview()
        XCTAssertEqual(controller.previewMode, .off, "and from that split, on to the editor")

        controller.toggleReadingMode()
        XCTAssertEqual(controller.previewMode, .reading, "⇧⌘P jumps straight there")
        controller.toggleReadingMode()
        XCTAssertEqual(controller.previewMode, .off)
    }

    @MainActor
    func testATexTabComesBackFromTheSessionInTheModeItWasLeftIn() throws {
        _ = NSApplication.shared
        let directory = try makeTemporaryDirectory()
        do {
            let controller = try makeLaTeXController(in: directory)
            controller.setPreviewMode(.reading)
            controller.flushAll()
        }
        let relaunched = try makeLaTeXController(in: directory)
        XCTAssertEqual(relaunched.previewMode, .reading)
        XCTAssertTrue(relaunched.previewState.isVisible)
    }

    @MainActor
    func testTheReadingModeSettingCoversLaTeXFilesToo() throws {
        _ = NSApplication.shared
        let previous = Preferences.shared.opensMarkdownInReadingMode
        defer { Preferences.shared.opensMarkdownInReadingMode = previous }

        let controller = try makeLaTeXController()
        let file = try makeTemporaryDirectory().appendingPathComponent("opened.tex")
        try "\\section{Opened}".write(to: file, atomically: true, encoding: .utf8)

        Preferences.shared.opensMarkdownInReadingMode = false
        controller.open(url: file)
        XCTAssertEqual(controller.previewMode, .off)

        Preferences.shared.opensMarkdownInReadingMode = true
        let second = try makeTemporaryDirectory().appendingPathComponent("again.tex")
        try "\\section{Again}".write(to: second, atomically: true, encoding: .utf8)
        controller.open(url: second)
        XCTAssertEqual(controller.previewMode, .reading)
    }

    @MainActor
    func testTheCaretLightsTheBlockItIsInAndAClickSelectsItBack() throws {
        _ = NSApplication.shared
        let controller = try makeLaTeXController()
        controller.setPreviewMode(.split)
        controller.window?.layoutIfNeeded()
        let editor = try editorTextView(of: controller)
        let source = "\\section{Alpha}\n\nA paragraph.\n\n\\section{Beta}\n"
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText(source, replacementRange: editor.selectedRange())
        waitForDebounce()

        let preview = controller.previewPanes.latex
        let text = source as NSString
        editor.setSelectedRange(NSRange(location: text.range(of: "\\section{Beta}").location + 3,
                                        length: 0))
        XCTAssertEqual(preview.highlightedSourceRange, text.range(of: "\\section{Beta}"))

        editor.setSelectedRange(NSRange(location: text.range(of: "A paragraph.").location,
                                        length: 0))
        XCTAssertEqual(preview.highlightedSourceRange, text.range(of: "A paragraph."))

        // And the other way: a click on a block selects its source.
        try clickPreview(of: controller, on: "1 Alpha")
        XCTAssertEqual(editor.selectedRange(), text.range(of: "\\section{Alpha}"),
                       "the whole heading, its `\\section{…}` part of it")
    }

    @MainActor
    func testSwitchingBetweenATexTabAndAMarkdownTabSwapsTheContentViews() throws {
        _ = NSApplication.shared
        let controller = try makeLaTeXController()
        controller.setPreviewMode(.split)
        XCTAssertEqual(controller.previewPanes.kind, .latex)

        let markdown = try makeTemporaryDirectory().appendingPathComponent("notes.md")
        try "# Markdown heading".write(to: markdown, atomically: true, encoding: .utf8)
        controller.open(url: markdown)
        controller.setPreviewMode(.split)
        XCTAssertEqual(controller.previewPanes.kind, .markdown)
        XCTAssertEqual(controller.previewState.renderedText, "Markdown heading")

        controller.selectTab(at: 0)
        XCTAssertEqual(controller.previewPanes.kind, .latex)
        XCTAssertTrue(controller.previewState.renderedText.contains("1 Introduction"))
    }

    // MARK: - Helpers

    /// A window whose front tab is a real `.tex` file, the way the other
    /// preview tests build one over a `.md`.
    @MainActor
    private func makeLaTeXController() throws -> MainWindowController {
        try makeLaTeXController(in: try makeTemporaryDirectory())
    }

    @MainActor
    private func makeLaTeXController(in directory: URL) throws -> MainWindowController {
        let store = SessionStore(directory: directory)
        if store.load() == nil {
            let file = directory.appendingPathComponent("paper.tex")
            try "\\section{Introduction}\n\nOpening words.\n"
                .write(to: file, atomically: true, encoding: .utf8)
            let id = UUID()
            store.save(SessionState(
                tabs: [SessionTab(
                    id: id, path: file.path, untitledName: nil,
                    isDirty: false, selection: 0, format: .default,
                    previewMode: .off
                )],
                selectedTabID: id,
                fontSize: 13
            ))
        }
        let controller = MainWindowController(store: store)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1000, height: 560))
        window.layoutIfNeeded()
        return controller
    }

    @MainActor
    private func editorTextView(of controller: MainWindowController) throws -> NotaTextView {
        let content = try XCTUnwrap(controller.window?.contentView)
        return try XCTUnwrap(descendant(of: content, ofType: NotaTextView.self))
    }

    /// Clicks the pane where a piece of the rendered text is drawn, through a
    /// real mouse event, so the click travels the path a reader's does.
    @MainActor
    private func clickPreview(of controller: MainWindowController, on text: String) throws {
        let window = try XCTUnwrap(controller.window)
        let preview = controller.previewPanes.latex
        let textView = try XCTUnwrap(descendant(of: preview, ofType: NSTextView.self))
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)

        let range = (textView.string as NSString).range(of: text)
        try XCTSkipIf(range.location == NSNotFound, "\(text.debugDescription) is not in the pane")
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y

        let location = textView.convert(NSPoint(x: rect.minX + 2, y: rect.midY), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: location,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            ))
        }

        // A press in the render runs `NSTextView`'s own tracking loop to the
        // mouse up, since a drag there selects text (2026-09-07). So the
        // release is queued before the press, the way a reader's already is,
        // and anything the loop left behind is taken back out.
        window.postEvent(try event(.leftMouseUp), atStart: false)
        textView.mouseDown(with: try event(.leftMouseDown))
        while NSApp.nextEvent(
            matching: .leftMouseUp, until: nil, inMode: .default, dequeue: true
        ) != nil {}
    }

    /// Long enough for the 150 ms render to have fired.
    @MainActor
    private func waitForDebounce() {
        let fired = expectation(description: "the preview re-rendered")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { fired.fulfill() }
        wait(for: [fired], timeout: 2)
    }

    @MainActor
    private func descendant<T: NSView>(of view: NSView, ofType type: T.Type) -> T? {
        for subview in view.subviews {
            if let match = subview as? T { return match }
            if let match = descendant(of: subview, ofType: type) { return match }
        }
        return nil
    }

    private func makePNG(width: Int, height: Int) throws -> Data {
        let representation = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        NSColor.gray.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotaLaTeXTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
