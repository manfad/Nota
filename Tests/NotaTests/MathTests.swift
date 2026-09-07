import AppKit
import XCTest
@testable import Nota

/// LaTeX in the render, laid out by Nota itself.
///
/// No WebView and no dependency, so the maths is boxes: every construct
/// measures to a width, an ascent and a descent, and draws itself into
/// whatever context the render hands it. These tests hold the two ends of
/// that — what the parser makes of a formula, and what the layout measures —
/// plus the promise that matters most for a live preview: nothing anyone can
/// type makes it crash, hang or come back blank.
final class MathTests: AppKitTestCase {

    private let font = NSFont.systemFont(ofSize: 13)

    private func layout(_ tex: String, display: Bool = false) -> MathFormula? {
        MathRenderer.layout(tex, font: font, display: display)
    }

    private func measured(_ tex: String, display: Bool = false) throws -> MathFormula {
        try XCTUnwrap(layout(tex, display: display), "\(tex) should lay out")
    }

    // MARK: - What the parser makes of it

    func testPlainTextReadsBackAsTheFormulaWouldBeTyped() throws {
        let formula = try measured("x^2+\\alpha")
        XCTAssertTrue(formula.plainText.contains("x"), formula.plainText)
        XCTAssertTrue(formula.plainText.contains("²"), formula.plainText)
        XCTAssertTrue(formula.plainText.contains("α"), formula.plainText)
    }

    func testAFractionReadsAsASlash() throws {
        XCTAssertEqual(try measured("\\frac{a}{b}").plainText, "a/b")
        XCTAssertEqual(try measured("\\frac{1}{2}").plainText, "1/2")
    }

    func testASubscriptTakesUnicodesOwnSmallCharactersWhenThereAreSome() throws {
        XCTAssertEqual(try measured("x_i").plainText, "xᵢ")
        // And says so in TeX's own notation when there are none.
        XCTAssertTrue(try measured("x_{\\alpha}").plainText.contains("_"))
    }

    func testTeXTheSubsetDoesNotKnowKeepsItsOwnText() throws {
        let formula = try measured("\\foo{x} + 1")
        XCTAssertTrue(formula.plainText.contains("\\foo"), formula.plainText)
        // An environment is kept whole rather than half read.
        let matrix = try measured("\\begin{matrix} a & b \\end{matrix}")
        XCTAssertTrue(matrix.plainText.contains("\\begin{matrix}"), matrix.plainText)
        XCTAssertTrue(matrix.plainText.contains("\\end{matrix}"), matrix.plainText)
    }

    func testGreekAndSymbolsComeThroughAsUnicode() throws {
        XCTAssertEqual(try measured("\\alpha\\beta\\Omega").plainText, "αβΩ")
        XCTAssertEqual(try measured("\\infty\\leq\\to\\partial").plainText, "∞≤→∂")
        XCTAssertEqual(try measured("\\mathbb{R}").plainText, "ℝ")
        XCTAssertEqual(try measured("\\mathbb{NZQC}").plainText, "ℕℤℚℂ")
    }

    func testTextKeepsItsSpacesAndMathsDoesNot() throws {
        XCTAssertEqual(try measured("\\text{a b}").plainText, "a b")
        XCTAssertEqual(try measured("a b").plainText, "ab")
    }

    // MARK: - What comes back nil

    func testOnlySourceThatCannotBeReadAtAllComesBackNil() {
        XCTAssertNil(layout("", display: false), "an empty formula has nothing to draw")
        XCTAssertNil(layout("   ", display: false))
        XCTAssertNil(layout("{x", display: false), "an unbalanced brace")
        XCTAssertNil(layout("x}", display: false))
        XCTAssertNil(layout("\\left( x", display: false), "a \\left with no \\right")
        XCTAssertNil(layout("x \\right)", display: false))
        XCTAssertNil(layout("\\frac{a}", display: false), "a \\frac short of an argument")
        XCTAssertNil(layout("x^", display: false))
    }

    // MARK: - Every construct in the subset

    /// One of each thing the subset promises, in both modes. None of them may
    /// come back nil, and every one of them must measure to a real box —
    /// which is the whole of the promise that the render never goes blank.
    func testEveryConstructInTheSubsetLaysOut() throws {
        let formulas = [
            "x", "x^2", "x_i", "x_i^2", "2^{2^{2^{2}}}",
            "\\alpha + \\beta = \\gamma", "\\Gamma\\Delta\\Omega",
            "a \\times b \\cdot c \\div d", "x \\leq y \\geq z \\neq w",
            "A \\subseteq B \\cup C \\cap D", "\\forall x \\in \\mathbb{R}",
            "\\frac{a}{b}", "\\dfrac{1}{2}", "\\tfrac{1}{2}",
            "\\frac{\\frac{a}{b}}{c}", "\\sqrt{x}", "\\sqrt[3]{x+1}",
            "\\sum_{i=1}^{n} i", "\\int_0^\\infty e^{-x} dx", "\\prod_{k}k",
            "\\oint C", "\\iint_D f", "\\bigcup_{i} A_i", "\\bigcap_{i} A_i",
            "\\lim_{x \\to 0} \\frac{\\sin x}{x}",
            "\\left( \\frac{a}{b} \\right)", "\\left[ x \\right]",
            "\\left\\{ x \\right\\}", "\\left| x \\right|", "\\left\\| x \\right\\|",
            "\\left\\langle x \\right\\rangle", "\\left\\lfloor x \\right\\rfloor",
            "\\left\\lceil x \\right\\rceil", "\\left. x \\right)",
            "\\text{if } x > 0", "\\mathrm{d}x", "\\mathbf{v}", "\\mathit{f}",
            "\\mathbb{R}^n", "\\mathcal{L}", "\\operatorname{tr} A",
            "\\sin x + \\cos y", "\\log n + \\ln n + \\exp x",
            "\\min(a,b) \\max(a,b) \\det A \\gcd(m,n)",
            "a\\,b\\:c\\;d\\!e\\quad f\\qquad g~h",
            "\\hat{x} \\bar{y} \\vec{v} \\tilde{n} \\dot{a} \\ddot{b}",
            "\\binom{n}{k}", "\\ldots \\cdots \\vdots \\ddots",
            "\\angle \\perp \\parallel \\prime \\hbar \\ell \\Re \\Im \\aleph",
            "\\lfloor x \\rfloor \\lceil x \\rceil \\langle x \\rangle",
            "\\{ x \\} \\| x \\| \\backslash \\%",
            "\\foo", "\\begin{cases} 1 \\end{cases}", "x'",
        ]
        for display in [false, true] {
            for tex in formulas {
                let formula = try XCTUnwrap(
                    layout(tex, display: display), "\(tex) (display: \(display))"
                )
                XCTAssertGreaterThan(formula.size.width, 0, tex)
                XCTAssertGreaterThan(formula.size.height, 0, tex)
                XCTAssertEqual(
                    formula.size.height, formula.ascent + formula.descent,
                    accuracy: 0.001, tex
                )
                XCTAssertEqual(formula.tex, tex)
                XCTAssertEqual(formula.isDisplay, display)
            }
        }
    }

    // MARK: - Metrics

    func testAFractionIsTallerThanEitherHalfOfIt() throws {
        let fraction = try measured("\\frac{a}{b}")
        let numerator = try measured("a")
        XCTAssertGreaterThan(fraction.size.height, numerator.size.height)
        XCTAssertGreaterThan(fraction.ascent, numerator.ascent)
        XCTAssertGreaterThan(fraction.descent, numerator.descent)
    }

    func testABigOperatorTakesItsLimitsAboveAndBelowInDisplayOnly() throws {
        let inline = try measured("\\sum_{i=1}^n", display: false)
        let display = try measured("\\sum_{i=1}^n", display: true)
        XCTAssertGreaterThan(display.size.height, inline.size.height)
        // Stacked, the limits make it narrower than the same thing beside it.
        XCTAssertLessThan(display.size.width, inline.size.width)
    }

    func testDelimitersGrowToWhatTheyHold() throws {
        let fraction = try measured("\\frac{a}{b}")
        let wrapped = try measured("\\left(\\frac{a}{b}\\right)")
        XCTAssertGreaterThanOrEqual(wrapped.size.height, fraction.size.height)
        XCTAssertGreaterThan(wrapped.size.width, fraction.size.width)
        // And a taller thing inside makes taller delimiters.
        let taller = try measured("\\left(\\frac{\\frac{a}{b}}{c}\\right)")
        XCTAssertGreaterThan(taller.size.height, wrapped.size.height)
    }

    func testAScriptRaisesTheTopAndDeepensTheBottom() throws {
        let plain = try measured("x")
        XCTAssertGreaterThan(try measured("x^2").ascent, plain.ascent)
        XCTAssertGreaterThan(try measured("x_i").descent, plain.descent)
        let both = try measured("x_i^2")
        XCTAssertGreaterThan(both.ascent, plain.ascent)
        XCTAssertGreaterThan(both.descent, plain.descent)
        // Both scripts stack at one place rather than one after the other.
        XCTAssertLessThan(both.size.width, try measured("x^2x_i").size.width)
    }

    func testSpacingCommandsAreDifferentAmountsOfRoom() throws {
        let none = try measured("ab")
        let thin = try measured("a\\,b")
        let quad = try measured("a\\quad b")
        let qquad = try measured("a\\qquad b")
        XCTAssertGreaterThan(thin.size.width, none.size.width)
        XCTAssertGreaterThan(quad.size.width, thin.size.width)
        XCTAssertGreaterThan(qquad.size.width, quad.size.width)
        // And `\!` takes room back.
        XCTAssertLessThan(try measured("a\\!b").size.width, none.size.width)
    }

    func testARadicalIsTallerThanWhatItCovers() throws {
        let body = try measured("x")
        let root = try measured("\\sqrt{x}")
        XCTAssertGreaterThan(root.ascent, body.ascent)
        XCTAssertGreaterThan(root.size.width, body.size.width)
        // The index widens it further.
        XCTAssertGreaterThan(try measured("\\sqrt[3]{x}").size.width, root.size.width)
    }

    func testTheLayoutScalesWithTheFontItIsGiven() throws {
        let small = try XCTUnwrap(
            MathRenderer.layout("\\frac{a}{b}", font: NSFont.systemFont(ofSize: 11), display: false)
        )
        let large = try XCTUnwrap(
            MathRenderer.layout("\\frac{a}{b}", font: NSFont.systemFont(ofSize: 22), display: false)
        )
        XCTAssertGreaterThan(large.size.height, small.size.height)
        XCTAssertGreaterThan(large.size.width, small.size.width)
    }

    // MARK: - Drawing

    func testAFormulaPaintsSomethingTheSizeItSaidItWas() throws {
        for tex in ["\\frac{1}{2}", "\\sqrt{x}", "\\sum_{i=1}^n i"] {
            let formula = try measured(tex, display: true)
            let bitmap = try draw(formula, appearance: NSAppearance(named: .aqua))
            XCTAssertEqual(CGFloat(bitmap.pixelsWide), formula.size.width, tex)
            XCTAssertEqual(CGFloat(bitmap.pixelsHigh), formula.size.height, tex)
            XCTAssertGreaterThan(paintedPixels(in: bitmap), 0, "\(tex) drew nothing")
        }
    }

    func testTheColourIsResolvedAtDrawTimeSoDarkModeFollows() throws {
        let formula = try measured("\\frac{1}{2}", display: true)
        let light = try draw(formula, appearance: NSAppearance(named: .aqua))
        let dark = try draw(formula, appearance: NSAppearance(named: .darkAqua))
        XCTAssertEqual(paintedPixels(in: light), paintedPixels(in: dark), "the same boxes")
        let lightInk = try XCTUnwrap(brightestInk(in: light))
        let darkInk = try XCTUnwrap(brightestInk(in: dark))
        XCTAssertLessThan(lightInk, 0.2, "light mode's label is nearly black")
        XCTAssertGreaterThan(darkInk, 0.5, "dark mode's label is nearly white")
    }

    // MARK: - The attachment

    func testTheAttachmentSitsOnTheTextsOwnBaseline() throws {
        let formula = try measured("x^2 + \\frac{1}{2}")
        let attachment = MathAttachment(formula: formula, font: font)
        XCTAssertEqual(attachment.bounds.height, formula.size.height, accuracy: 0.001)
        XCTAssertEqual(attachment.bounds.width, formula.size.width, accuracy: 0.001)
        XCTAssertEqual(attachment.bounds.origin.y, -formula.descent, accuracy: 0.001)
        XCTAssertEqual(attachment.bounds.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(attachment.image?.size, formula.size)
        XCTAssertTrue(attachment.formula === formula)
    }

    func testTheAttachmentIsOneCharacterInTheRender() throws {
        let formula = try measured("\\alpha")
        let attachment = MathAttachment(formula: formula, font: font)
        let string = NSAttributedString(attachment: attachment)
        XCTAssertEqual(string.length, 1)
        XCTAssertEqual(string.string, "\u{FFFC}")
    }

    // MARK: - Nothing anyone can type breaks it

    func testRandomTeXNeverCrashesOrHangs() {
        let alphabet = [
            "\\", "{", "}", "^", "_", "a", "z", "0", "9", "+", "-", "=",
            "(", ")", "[", "]", "frac", "sqrt", "left", "right", "sum",
            "alpha", "text", "begin", "end", " ", "$", "&", "%", "~",
        ]
        var seed: UInt64 = 0x5EED
        func next(_ bound: Int) -> Int {
            // A small deterministic generator, so a failure comes back the
            // same way on the next run.
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }
        let started = Date()
        for _ in 0..<500 {
            var tex = ""
            for _ in 0..<(1 + next(12)) {
                tex += alphabet[next(alphabet.count)]
            }
            if let formula = MathRenderer.layout(tex, font: font, display: next(2) == 0) {
                XCTAssertEqual(
                    formula.size.height, formula.ascent + formula.descent, accuracy: 0.001, tex
                )
                XCTAssertGreaterThan(formula.size.width, 0, tex)
            }
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 20,
            "500 formulas is a keystroke's worth of work"
        )
    }

    func testDeepNestingStopsRatherThanRunningTheStackOut() {
        let deep = String(repeating: "{", count: 500) + "x" + String(repeating: "}", count: 500)
        XCTAssertNil(layout(deep), "past the depth bound a formula is refused, not crashed into")
        let fractions = String(repeating: "\\frac{1}{", count: 200) + "x"
            + String(repeating: "}", count: 200)
        XCTAssertNil(layout(fractions))
    }

    // MARK: - Drawing helpers

    private func draw(_ formula: MathFormula, appearance: NSAppearance?) throws -> NSBitmapImageRep {
        let width = Int(formula.size.width)
        let height = Int(formula.size.height)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        let paint = {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            let context = graphics.cgContext
            // The render's own coordinate system: y down from the top.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            formula.draw(
                at: NSPoint(x: 0, y: formula.ascent), in: context, color: .labelColor
            )
            NSGraphicsContext.restoreGraphicsState()
        }
        if let appearance {
            appearance.performAsCurrentDrawingAppearance(paint)
        } else {
            paint()
        }
        return bitmap
    }

    private func paintedPixels(in bitmap: NSBitmapImageRep) -> Int {
        var painted = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                painted += 1
            }
        }
        return painted
    }

    /// The brightest thing painted — the ink's own colour, since the ground is
    /// left empty and the edges of the glyphs fade into it.
    private func brightestInk(in bitmap: NSBitmapImageRep) -> CGFloat? {
        var brightest: CGFloat?
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      color.alphaComponent > 0.5 else { continue }
                brightest = max(brightest ?? 0, color.brightnessComponent)
            }
        }
        return brightest
    }
}
