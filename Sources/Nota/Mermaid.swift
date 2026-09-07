import AppKit

/// A ```` ```mermaid ```` fence in a Markdown note, read and drawn by Nota
/// itself (SPEC "Mermaid diagrams"; todo 6). No WebView and no dependency,
/// the same footing as the maths: two grammars — `flowchart` / `graph`, and
/// `sequenceDiagram` — and a fence in any other grammar, or one that cannot
/// be read, stays the code block it is today. Errors never break the page.
///
/// `Mermaid.layout` is the one door: it names the grammar off the first
/// meaningful line and hands the source to that grammar's own file
/// (`MermaidFlowchart.swift`, `MermaidSequence.swift`), each of which parses,
/// lays out and draws its own kind and knows nothing of the other.
enum Mermaid {
    enum Kind: Equatable {
        case flowchart
        case sequence
    }

    /// The grammar the fence opens with: `flowchart TD`, `graph LR`,
    /// `sequenceDiagram`. `%%` comments and blank lines before it are skipped.
    /// `nil` for any other first word — `classDiagram`, `gantt`, a stray
    /// sentence.
    static func kind(of source: String) -> Kind? {
        for rawLine in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("%%") { continue }
            let word = line.prefix { !$0.isWhitespace && $0 != ";" }
            switch word {
            case "flowchart", "graph": return .flowchart
            case "sequenceDiagram": return .sequence
            default: return nil
            }
        }
        return nil
    }

    /// The diagram laid out against `font` — the render's own, so it grows
    /// with Settings the way the maths does. `nil` when the grammar is not
    /// one of ours or the source cannot be read, and the fence stays code.
    static func layout(_ source: String, font: NSFont) -> MermaidDiagram? {
        switch kind(of: source) {
        case .flowchart: return MermaidFlowchart.layout(source, font: font)
        case .sequence: return MermaidSequence.layout(source, font: font)
        case nil: return nil
        }
    }

    /// Whether this fence is one Nota can draw at all — asked by the Markdown
    /// pass *before* the fence is lifted out of the note, so a diagram in a
    /// grammar we do not read, or one half way through being typed, stays the
    /// code block it already is rather than becoming a blank in the page.
    /// The answer costs a parse; the font it is measured against afterwards
    /// cannot change it.
    static func canDraw(_ source: String) -> Bool {
        switch kind(of: source) {
        case .flowchart: return MermaidFlowchart.parse(source) != nil
        case .sequence: return MermaidSequence.layout(source, font: probeFont) != nil
        case nil: return false
        }
    }

    /// A font to ask the question with, since layout wants one. Nothing about
    /// whether a diagram can be drawn depends on it.
    private static let probeFont = NSFont.systemFont(ofSize: 13)
}

/// One laid-out diagram: a box of `size` (points, origin top-left, y down —
/// the context handed to `draw` is flipped, as `NSImage(size:flipped:)`
/// gives it) that draws itself in the colours it is handed. Laid out once,
/// drawn every time the appearance asks, so light and dark follow without a
/// second layout.
protocol MermaidDiagram {
    var size: CGSize { get }
    func draw(in context: CGContext, palette: MermaidPalette)
}

/// The colours a diagram is drawn in, resolved at draw time — never stored
/// — so they are the appearance's own. Nothing hardcoded: every value is a
/// semantic system colour or a wash of one.
struct MermaidPalette {
    /// Lines, arrows, the outline of every box.
    let stroke: NSColor
    /// The inside of a box.
    let fill: NSColor
    /// Every label.
    let text: NSColor
    /// A lifeline, a subgraph's frame, a `loop` / `alt` frame: the quieter
    /// stroke.
    let secondary: NSColor
    /// The note box in a sequence diagram, a highlighted node.
    let accent: NSColor

    static var standard: MermaidPalette {
        MermaidPalette(
            stroke: .labelColor.withAlphaComponent(0.8),
            fill: .labelColor.withAlphaComponent(0.05),
            text: .labelColor,
            secondary: .labelColor.withAlphaComponent(0.35),
            accent: .systemYellow.withAlphaComponent(0.25)
        )
    }
}
