import AppKit
import CoreText

/// TeX's four sizes. Everything shrinks the same way it does on paper: a
/// script is seven tenths of what it sits on, a script of a script a half, and
/// nothing goes below that floor.
enum MathStyle {
    case display
    case text
    case script
    case scriptScript

    var scale: CGFloat {
        switch self {
        case .display, .text: return 1
        case .script: return 0.7
        case .scriptScript: return 0.5
        }
    }

    /// What a `^` or a `_` puts its argument into.
    var scriptStyle: MathStyle {
        switch self {
        case .display, .text: return .script
        case .script, .scriptScript: return .scriptScript
        }
    }

    /// What the two halves of a `\frac` are set in: full size in display, a
    /// step down inline, so a fraction in a sentence does not push the lines
    /// apart.
    var fractionStyle: MathStyle {
        switch self {
        case .display: return .text
        case .text: return .script
        case .script, .scriptScript: return .scriptScript
        }
    }

    var isDisplay: Bool { self == .display }
}

/// The font a piece of a formula is set in, and the metrics that go with it.
///
/// Every measurement in the layout comes out of the font rather than out of a
/// constant, so a formula grows with Settings' font size the way the rest of
/// the render does.
struct MathContext {
    let baseFont: NSFont
    let style: MathStyle
    let font: NSFont

    init(baseFont: NSFont, style: MathStyle) {
        self.baseFont = baseFont
        self.style = style
        let size = max(baseFont.pointSize * style.scale, 1)
        font = NSFont(descriptor: baseFont.fontDescriptor, size: size) ?? baseFont
    }

    func with(style: MathStyle) -> MathContext {
        MathContext(baseFont: baseFont, style: style)
    }

    /// The line a fraction is divided by, and the vinculum over a `\sqrt`:
    /// a hairline that thickens only when the text is very large.
    var ruleThickness: CGFloat { max(1, (font.pointSize / 18).rounded()) }

    /// The height a fraction bar, a big operator and a stretched delimiter all
    /// centre themselves on — half an x-height above the baseline.
    var axis: CGFloat { font.xHeight / 2 }

    var thinSpace: CGFloat { font.pointSize * 0.167 }

    /// The face a run is set in, falling back to the font itself when the
    /// family has no italic or bold to convert to.
    func face(_ face: MathFace) -> NSFont {
        let manager = NSFontManager.shared
        switch face {
        case .upright: return font
        case .italic: return manager.convert(font, toHaveTrait: .italicFontMask)
        case .bold: return manager.convert(font, toHaveTrait: .boldFontMask)
        case .boldItalic:
            return manager.convert(
                manager.convert(font, toHaveTrait: .boldFontMask), toHaveTrait: .italicFontMask
            )
        case .monospaced:
            return NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
        }
    }
}

/// A laid-out piece of a formula: how much room it takes, and how to draw it
/// once someone knows where it goes and what colour it is.
///
/// The colour arrives at draw time rather than at layout time, which is what
/// lets one laid-out formula follow light and dark without being measured
/// again. Origin is the baseline's left end, in a flipped coordinate system —
/// the one AppKit's text drawing already works in — so `ascent` is above the
/// origin and `descent` below it.
struct MathBox {
    var width: CGFloat
    var ascent: CGFloat
    var descent: CGFloat
    let render: (NSPoint, CGContext, NSColor) -> Void

    init(
        width: CGFloat = 0, ascent: CGFloat = 0, descent: CGFloat = 0,
        render: @escaping (NSPoint, CGContext, NSColor) -> Void = { _, _, _ in }
    ) {
        self.width = width
        self.ascent = ascent
        self.descent = descent
        self.render = render
    }

    var height: CGFloat { ascent + descent }
}

/// A laid-out formula: boxes with metrics, drawn on demand.
///
/// The tree is measured once, when the render is built, and drawn every time
/// the pane redraws. Nothing about the drawing depends on the appearance, so
/// switching to dark mode redraws the same boxes in the other colour.
final class MathFormula {
    /// The source, verbatim — what the note actually says between its dollars.
    let tex: String
    let isDisplay: Bool
    let size: NSSize
    let ascent: CGFloat
    let descent: CGFloat
    /// A Unicode approximation of the formula: what it would look like typed
    /// into a plain-text field, and what a screen reader is given.
    let plainText: String

    private let box: MathBox

    init(tex: String, isDisplay: Bool, box: MathBox, plainText: String) {
        self.tex = tex
        self.isDisplay = isDisplay
        self.box = box
        self.plainText = plainText
        ascent = max(box.ascent.rounded(.up), 0)
        descent = max(box.descent.rounded(.up), 0)
        size = NSSize(width: max(box.width.rounded(.up), 1), height: ascent + descent)
    }

    /// Draws the formula with its baseline's left end at `origin`, in a
    /// flipped context. The colour is resolved here rather than kept, so the
    /// same formula draws itself correctly in either appearance.
    func draw(at origin: NSPoint, in context: CGContext, color: NSColor) {
        box.render(origin, context, color)
    }
}

/// A TeX subset, laid out into boxes.
///
/// The one way in. Everything else in the file is the machinery underneath:
/// `MathParser` turns the source into nodes, and `layout(node:in:)` turns each
/// node into a `MathBox` that knows its own size and how to draw itself.
enum MathRenderer {

    /// Parses and lays out a TeX subset. `nil` only when the source cannot be
    /// read at all — an unbalanced `{`, a `\left` without its `\right`, an
    /// empty formula — in which case the caller shows the raw TeX as a code
    /// span. An unknown command never comes back `nil`: it renders as itself.
    static func layout(_ tex: String, font: NSFont, display: Bool) -> MathFormula? {
        guard let node = try? MathParser.parse(tex) else { return nil }
        let context = MathContext(baseFont: font, style: display ? .display : .text)
        let box = layout(node, in: context)
        guard box.width > 0 || box.height > 0 else { return nil }
        return MathFormula(
            tex: tex, isDisplay: display, box: box, plainText: MathPlainText.string(for: node)
        )
    }

    // MARK: - Nodes

    private static func layout(_ node: MathNode, in context: MathContext) -> MathBox {
        switch node {
        case .run(let text, let face):
            return glyphs(text, font: context.face(face))
        case .list(let nodes):
            return row(nodes, in: context)
        case .space(let ems):
            return MathBox(width: context.font.pointSize * ems)
        case .raw(let text):
            return rawBox(text, in: context)
        case .scripts(let base, let sub, let sup):
            return scripts(base: base, sub: sub, sup: sup, in: context)
        case .fraction(let numerator, let denominator, let rule, let size):
            return fraction(numerator, denominator, rule: rule, size: size, in: context)
        case .radical(let index, let radicand):
            return radical(index: index, radicand: radicand, in: context)
        case .bigOperator(let op):
            return bigOperator(op, in: context)
        case .delimited(let left, let right, let body):
            return delimited(left: left, right: right, body: body, in: context)
        case .accent(let mark, let body):
            return accent(mark, over: body, in: context)
        }
    }

    /// A horizontal list: children on one baseline, with the thin spaces that
    /// keep `a+b` from reading as a word.
    private static func row(_ nodes: [MathNode], in context: MathContext) -> MathBox {
        var placed: [(NSPoint, MathBox)] = []
        var x: CGFloat = 0
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        for (position, node) in nodes.enumerated() {
            if position > 0, spacesAround(node) { x += context.thinSpace }
            let box = layout(node, in: context)
            placed.append((NSPoint(x: x, y: 0), box))
            x += box.width
            ascent = max(ascent, box.ascent)
            descent = max(descent, box.descent)
            let last = position == nodes.count - 1
            if !last, spacesAround(node) || (context.style.isDisplay && isComma(node)) {
                x += context.thinSpace
            }
        }
        return compose(placed, width: x, ascent: ascent, descent: descent)
    }

    /// Binary operators and relations take room on both sides; everything else
    /// sits where it falls.
    private static func spacesAround(_ node: MathNode) -> Bool {
        guard case .run(let text, _) = node, text.count == 1,
              let character = text.first else { return false }
        return MathTables.spaced.contains(character)
    }

    private static func isComma(_ node: MathNode) -> Bool {
        if case .run(",", _) = node { return true }
        return false
    }

    // MARK: - Scripts

    private static func scripts(
        base: MathNode?, sub: MathNode?, sup: MathNode?, in context: MathContext
    ) -> MathBox {
        // A big operator in display puts its scripts under and over itself
        // rather than beside it — that is what makes it a big operator.
        if case .bigOperator(let op)? = base, context.style.isDisplay {
            return limits(op, sub: sub, sup: sup, in: context)
        }
        let baseBox = base.map { layout($0, in: context) } ?? MathBox()
        let scriptContext = context.with(style: context.style.scriptStyle)
        let supBox = sup.map { layout($0, in: scriptContext) }
        let subBox = sub.map { layout($0, in: scriptContext) }
        let xHeight = context.font.xHeight

        var supShift: CGFloat = 0
        var subShift: CGFloat = 0
        if let supBox {
            supShift = max(xHeight * 0.8, baseBox.ascent - supBox.height * 0.6)
        }
        if let subBox {
            subShift = max(xHeight * 0.25, baseBox.descent - subBox.height * 0.5)
        }
        // With both on one atom, they must not touch each other.
        if let supBox, let subBox {
            let gap = xHeight * 0.25
            let clearance = (supShift - supBox.descent) - (subBox.ascent - subShift)
            if clearance < gap {
                let deficit = (gap - clearance) / 2
                supShift += deficit
                subShift += deficit
            }
        }

        var placed: [(NSPoint, MathBox)] = [(.zero, baseBox)]
        var ascent = baseBox.ascent
        var descent = baseBox.descent
        let x = baseBox.width + context.font.pointSize * 0.05
        var width = baseBox.width
        if let supBox {
            placed.append((NSPoint(x: x, y: -supShift), supBox))
            ascent = max(ascent, supShift + supBox.ascent)
            width = max(width, x + supBox.width)
        }
        if let subBox {
            placed.append((NSPoint(x: x, y: subShift), subBox))
            descent = max(descent, subShift + subBox.descent)
            width = max(width, x + subBox.width)
        }
        return compose(placed, width: width, ascent: ascent, descent: descent)
    }

    /// `\sum_{i=1}^{n}` in display: the operator with its limits stacked and
    /// centred on it.
    private static func limits(
        _ op: MathOperator, sub: MathNode?, sup: MathNode?, in context: MathContext
    ) -> MathBox {
        let operatorBox = bigOperator(op, in: context, trailingSpace: false)
        let limitContext = context.with(style: context.style.scriptStyle)
        let supBox = sup.map { layout($0, in: limitContext) }
        let subBox = sub.map { layout($0, in: limitContext) }
        let gap = context.font.pointSize * 0.15

        var width = operatorBox.width
        if let supBox { width = max(width, supBox.width) }
        if let subBox { width = max(width, subBox.width) }

        var placed: [(NSPoint, MathBox)] = [
            (NSPoint(x: (width - operatorBox.width) / 2, y: 0), operatorBox)
        ]
        var ascent = operatorBox.ascent
        var descent = operatorBox.descent
        if let supBox {
            let raise = operatorBox.ascent + gap + supBox.descent
            placed.append((NSPoint(x: (width - supBox.width) / 2, y: -raise), supBox))
            ascent = raise + supBox.ascent
        }
        if let subBox {
            let drop = operatorBox.descent + gap + subBox.ascent
            placed.append((NSPoint(x: (width - subBox.width) / 2, y: drop), subBox))
            descent = drop + subBox.descent
        }
        return compose(placed, width: width, ascent: ascent, descent: descent)
    }

    /// `\sum` and its kind. The glyph grows in display and sits on the axis;
    /// `\lim` is a word and stays on the baseline.
    private static func bigOperator(
        _ op: MathOperator, in context: MathContext, trailingSpace: Bool = true
    ) -> MathBox {
        if op.isWord {
            let box = glyphs(op.text, font: context.face(.upright))
            guard trailingSpace else { return box }
            return compose([(.zero, box)], width: box.width + context.thinSpace,
                           ascent: box.ascent, descent: box.descent)
        }
        let scale = context.style.isDisplay ? 1.4 : 1.15
        let font = NSFont(
            descriptor: context.font.fontDescriptor, size: context.font.pointSize * scale
        ) ?? context.font
        let glyph = measure(op.text, font: font)
        let box = glyphs(op.text, font: font)
        // Centred on the axis, the way TeX hangs its operators.
        let shift = context.axis - glyph.ink.midY
        let centred = MathBox(
            width: box.width,
            ascent: glyph.ink.maxY + shift,
            descent: -(glyph.ink.minY + shift)
        ) { origin, cgContext, color in
            box.render(NSPoint(x: origin.x, y: origin.y - shift), cgContext, color)
        }
        return centred
    }

    // MARK: - Fractions

    private static func fraction(
        _ numerator: MathNode, _ denominator: MathNode,
        rule: Bool, size: MathSizeOverride, in context: MathContext
    ) -> MathBox {
        let inner: MathContext
        switch size {
        case .inherit: inner = context.with(style: context.style.fractionStyle)
        case .display: inner = context.with(style: .text)
        case .text: inner = context.with(style: .script)
        }
        let top = layout(numerator, in: inner)
        let bottom = layout(denominator, in: inner)
        let thickness = rule ? context.ruleThickness : 0
        let gap = context.font.pointSize * (context.style.isDisplay ? 0.15 : 0.1)
        let padding = context.font.pointSize * 0.1
        let width = max(top.width, bottom.width) + padding * 2
        let axis = context.axis

        let topRaise = axis + thickness / 2 + gap + top.descent
        let bottomDrop = -axis + thickness / 2 + gap + bottom.ascent
        var placed: [(NSPoint, MathBox)] = [
            (NSPoint(x: (width - top.width) / 2, y: -topRaise), top),
            (NSPoint(x: (width - bottom.width) / 2, y: bottomDrop), bottom),
        ]
        if rule {
            placed.append((
                NSPoint(x: 0, y: -(axis + thickness / 2)),
                hairline(width: width, thickness: thickness)
            ))
        }
        return compose(
            placed, width: width,
            ascent: topRaise + top.ascent,
            descent: bottomDrop + bottom.descent
        )
    }

    // MARK: - Radicals

    private static func radical(
        index: MathNode?, radicand: MathNode, in context: MathContext
    ) -> MathBox {
        let body = layout(radicand, in: context)
        let thickness = context.ruleThickness
        let gap = context.font.pointSize * 0.12
        let padding = context.font.pointSize * 0.08

        // The sign is stretched to reach from under the content to the bar
        // over it.
        let top = body.ascent + gap + thickness
        let bottom = -body.descent
        let glyph = measure("√", font: context.font)
        let inkHeight = max(glyph.ink.height, 0.001)
        let scale = max((top - bottom) / inkHeight, 1)
        let offset = bottom - glyph.ink.minY * scale
        let signWidth = glyph.width
        let line = glyph.line

        // The optional index goes small at the top left, in the radical's own
        // crook, and pushes the sign right only when it is wider than that.
        var indexBox: MathBox?
        var shift: CGFloat = 0
        if let index {
            let box = layout(index, in: context.with(style: .scriptScript))
            shift = max(box.width - signWidth * 0.55, box.width * 0.3)
            indexBox = box
        }
        let barWidth = body.width + padding * 2
        var placed: [(NSPoint, MathBox)] = [
            (NSPoint(x: shift + signWidth + padding, y: 0), body),
            (
                NSPoint(x: shift + signWidth, y: -top),
                hairline(width: barWidth, thickness: thickness)
            ),
            (
                NSPoint(x: shift, y: -offset),
                MathBox(width: signWidth) { origin, cgContext, color in
                    draw(line, at: origin, scaleY: scale, in: cgContext, color: color)
                }
            ),
        ]
        var ascent = top + thickness
        if let indexBox {
            let raise = (top - bottom) * 0.55 + bottom
            placed.append((NSPoint(x: 0, y: -raise), indexBox))
            ascent = max(ascent, raise + indexBox.ascent)
        }
        return compose(
            placed, width: shift + signWidth + barWidth,
            ascent: ascent, descent: body.descent
        )
    }

    // MARK: - Delimiters

    private static func delimited(
        left: String?, right: String?, body: MathNode, in context: MathContext
    ) -> MathBox {
        let inner = layout(body, in: context)
        let axis = context.axis
        // Both sides grow together, around the axis, so a `(` and its `)` are
        // the same height whatever is between them.
        let half = max(
            max(inner.ascent - axis, inner.descent + axis),
            context.font.pointSize * 0.5
        )
        let leftBox = left.map { stretched($0, half: half, in: context) }
        let rightBox = right.map { stretched($0, half: half, in: context) }

        var placed: [(NSPoint, MathBox)] = []
        var x: CGFloat = 0
        var ascent = inner.ascent
        var descent = inner.descent
        if let leftBox {
            placed.append((NSPoint(x: x, y: 0), leftBox))
            x += leftBox.width
            ascent = max(ascent, leftBox.ascent)
            descent = max(descent, leftBox.descent)
        }
        placed.append((NSPoint(x: x, y: 0), inner))
        x += inner.width
        if let rightBox {
            placed.append((NSPoint(x: x, y: 0), rightBox))
            x += rightBox.width
            ascent = max(ascent, rightBox.ascent)
            descent = max(descent, rightBox.descent)
        }
        return compose(placed, width: x, ascent: ascent, descent: descent)
    }

    /// One delimiter, scaled vertically to reach `half` above and below the
    /// axis. Scaling the glyph keeps the shape the font drew; composing one
    /// out of Unicode pieces would not.
    private static func stretched(
        _ text: String, half: CGFloat, in context: MathContext
    ) -> MathBox {
        let glyph = measure(text, font: context.font)
        let inkHeight = max(glyph.ink.height, 0.001)
        let scale = max(half * 2 / inkHeight, 1)
        let axis = context.axis
        let offset = (axis - half) - glyph.ink.minY * scale
        let line = glyph.line
        let ascent = glyph.ink.maxY * scale + offset
        let descent = -(glyph.ink.minY * scale + offset)
        return MathBox(width: glyph.width, ascent: ascent, descent: descent) {
            origin, cgContext, color in
            draw(
                line, at: NSPoint(x: origin.x, y: origin.y - offset),
                scaleY: scale, in: cgContext, color: color
            )
        }
    }

    // MARK: - Accents

    private static func accent(
        _ mark: Character, over body: MathNode, in context: MathContext
    ) -> MathBox {
        // A combining character is the whole of it when the accent goes on
        // plain letters, which is what `\hat x` and `\vec{AB}` are.
        if let text = MathPlainText.plainRun(body), !text.isEmpty {
            var accented = ""
            for character in text {
                accented.append(character)
                accented.append(mark)
            }
            let face: MathFace
            if case .run(_, let bodyFace) = body { face = bodyFace } else { face = .italic }
            return glyphs(accented, font: context.face(face))
        }
        // Anything else — an accent over a fraction — takes the mark as its
        // own glyph, centred above.
        let inner = layout(body, in: context)
        let markBox = glyphs(String(mark), font: context.face(.upright))
        let raise = inner.ascent + context.font.pointSize * 0.05
        return compose(
            [
                (.zero, inner),
                (NSPoint(x: (inner.width - markBox.width) / 2, y: -raise), markBox),
            ],
            width: inner.width,
            ascent: raise + markBox.ascent,
            descent: inner.descent
        )
    }

    // MARK: - Unknown TeX

    /// What the subset does not know, shown as itself in the code-span look
    /// the rest of the render uses: monospaced, on a labelColor wash.
    private static func rawBox(_ text: String, in context: MathContext) -> MathBox {
        let font = context.face(.monospaced)
        let box = glyphs(text, font: font)
        let padding = font.pointSize * 0.2
        let radius = min(3, font.pointSize * 0.25)
        let width = box.width + padding * 2
        let ascent = box.ascent
        let descent = box.descent
        return MathBox(width: width, ascent: ascent, descent: descent) {
            origin, cgContext, color in
            let rect = CGRect(
                x: origin.x, y: origin.y - ascent, width: width, height: ascent + descent
            )
            cgContext.saveGState()
            cgContext.setFillColor(resolved(color.withAlphaComponent(0.05)))
            cgContext.addPath(
                CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            )
            cgContext.fillPath()
            cgContext.restoreGState()
            box.render(NSPoint(x: origin.x + padding, y: origin.y), cgContext, color)
        }
    }

    // MARK: - Glyphs and rules

    /// A line of glyphs, measured once and drawn with whatever colour the
    /// context is filled with — which is how the colour stays late.
    private struct Glyph {
        let line: CTLine
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
        /// Where the ink actually lands, relative to the baseline, up positive.
        let ink: CGRect
    }

    private static func measure(_ text: String, font: NSFont) -> Glyph {
        // `kCTForegroundColorFromContext`: without it Core Text draws the line
        // in its own black whatever the context is filled with, and the
        // colour `draw(at:in:color:)` resolves at draw time never reaches the
        // ink — which is how a dark window's formulas came out black on a
        // dark page. The same attribute the Mermaid renderers' labels carry.
        let string = NSAttributedString(string: text, attributes: [
            .font: font,
            kCTForegroundColorFromContextAttributeName as NSAttributedString.Key: true,
        ])
        let line = CTLineCreateWithAttributedString(string)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        var ink = CTLineGetImageBounds(line, nil)
        if ink.isEmpty || ink.isNull {
            ink = CGRect(x: 0, y: -descent, width: width, height: ascent + descent)
        }
        return Glyph(line: line, width: width, ascent: ascent, descent: descent, ink: ink)
    }

    private static func glyphs(_ text: String, font: NSFont) -> MathBox {
        // A hyphen typed in maths is a minus sign, and reads as one.
        let drawn = text == "-" ? "−" : text
        let glyph = measure(drawn, font: font)
        let line = glyph.line
        return MathBox(width: glyph.width, ascent: glyph.ascent, descent: glyph.descent) {
            origin, context, color in
            draw(line, at: origin, scaleY: 1, in: context, color: color)
        }
    }

    /// The line under a `\frac` and over a `\sqrt`. Its top edge is on the
    /// baseline it is given, so raising it puts it where it belongs.
    private static func hairline(width: CGFloat, thickness: CGFloat) -> MathBox {
        MathBox(width: width, ascent: 0, descent: thickness) { origin, context, color in
            context.saveGState()
            context.setFillColor(resolved(color))
            context.fill(CGRect(x: origin.x, y: origin.y, width: width, height: thickness))
            context.restoreGState()
        }
    }

    private static func compose(
        _ placed: [(NSPoint, MathBox)], width: CGFloat, ascent: CGFloat, descent: CGFloat
    ) -> MathBox {
        MathBox(width: width, ascent: ascent, descent: descent) { origin, context, color in
            for (offset, box) in placed {
                box.render(
                    NSPoint(x: origin.x + offset.x, y: origin.y + offset.y), context, color
                )
            }
        }
    }

    /// Draws a measured line with its baseline at `point` in a flipped
    /// context, optionally stretched vertically about that baseline — which is
    /// how a `(` grows to the height of what it holds.
    private static func draw(
        _ line: CTLine, at point: NSPoint, scaleY: CGFloat, in context: CGContext, color: NSColor
    ) {
        context.saveGState()
        context.setFillColor(resolved(color))
        context.textMatrix = .identity
        context.translateBy(x: point.x, y: point.y)
        context.scaleBy(x: 1, y: -scaleY)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// The colour, resolved here and nowhere earlier: `labelColor` is a
    /// different colour in light and dark, and this is the moment the render
    /// finds out which one it is drawing in.
    private static func resolved(_ color: NSColor) -> CGColor {
        (color.usingColorSpace(.sRGB) ?? color).cgColor
    }
}

/// The formula as plain characters — Unicode's own superscripts and symbols,
/// with a slash where a fraction was. It is what tests read, what a screen
/// reader is handed, and what someone copying the render gets.
enum MathPlainText {

    static func string(for node: MathNode) -> String {
        switch node {
        case .run(let text, _):
            return text
        case .list(let nodes):
            return nodes.map { string(for: $0) }.joined()
        case .space(let ems):
            return ems >= 0.2 ? " " : ""
        case .raw(let text):
            return text
        case .bigOperator(let op):
            return op.text
        case .accent(let mark, let body):
            return string(for: body) + String(mark)
        case .fraction(let numerator, let denominator, _, _):
            return string(for: numerator) + "/" + string(for: denominator)
        case .radical(let index, let radicand):
            let root = index.map { string(for: $0) } ?? ""
            return root + "√" + string(for: radicand)
        case .delimited(let left, let right, let body):
            return (left ?? "") + string(for: body) + (right ?? "")
        case .scripts(let base, let sub, let sup):
            var text = base.map { string(for: $0) } ?? ""
            if let sup { text += small(string(for: sup), through: MathTables.superscripts, marker: "^") }
            if let sub { text += small(string(for: sub), through: MathTables.subscripts, marker: "_") }
            return text
        }
    }

    /// A script in Unicode's own small characters where they exist, and with
    /// the TeX marker where they do not.
    private static func small(
        _ text: String, through table: [Character: Character], marker: Character
    ) -> String {
        var mapped = ""
        for character in text {
            guard let small = table[character] else {
                return String(marker) + (text.count > 1 ? "(" + text + ")" : text)
            }
            mapped.append(small)
        }
        return mapped
    }

    /// The letters an accent can be laid on directly, or `nil` when the body
    /// is something with a shape of its own.
    static func plainRun(_ node: MathNode) -> String? {
        switch node {
        case .run(let text, _):
            return text
        case .list(let nodes):
            var text = ""
            for node in nodes {
                guard let piece = plainRun(node) else { return nil }
                text += piece
            }
            return text
        default:
            return nil
        }
    }
}
