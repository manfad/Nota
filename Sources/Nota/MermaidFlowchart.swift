import AppKit
import CoreText

/// `flowchart` / `graph`: the parser, the layered layout and the drawing.
///
/// Three passes, and each one can be read on its own. `parse` turns the fence
/// into a `Graph` — nodes with a shape and a label, edges with a line style
/// and end caps, subgraphs holding names — and knows nothing of points or
/// fonts. `Diagram` lays that graph out the way Sugiyama's method does:
/// cycles broken by reversing the edges that close them, ranks by longest
/// path, an order inside each rank settled by a few barycenter sweeps, then
/// coordinates, with a dummy node standing in every rank an edge passes
/// through so a long edge is routed rather than drawn over whatever is in the
/// way. Drawing is last and holds no colour of its own: the palette arrives at
/// draw time, so one laid-out diagram follows light and dark.
///
/// The parser is deliberately strict. Anything it cannot read — a grammar
/// from another diagram, a bracket that never closes, a line that is neither
/// a statement nor one of the directives it is allowed to ignore — comes back
/// `nil`, and the fence stays the code block it was. A half-typed diagram in
/// a note being written is code, never a broken picture.
enum MermaidFlowchart {

    // MARK: - The graph

    /// Which way the ranks run. `TD` and `TB` are the same thing.
    enum Direction: Equatable {
        case down, up, right, left

        static func named(_ word: String) -> Direction? {
            switch word.uppercased() {
            case "TD", "TB": return .down
            case "BT": return .up
            case "LR": return .right
            case "RL": return .left
            default: return nil
            }
        }

        var isVertical: Bool { self == .down || self == .up }
    }

    /// Every bracket pair Mermaid spells a node with.
    enum NodeShape: Equatable {
        case rectangle   // A[text]
        case rounded     // A(text)
        case stadium     // A([text])
        case subroutine  // A[[text]]
        case cylinder    // A[(text)]
        case circle      // A((text))
        case diamond     // A{text}
        case hexagon     // A{{text}}
        case flag        // A>text]
    }

    struct Node: Equatable {
        var id: String
        /// `<br>` already turned into a newline.
        var label: String
        var shape: NodeShape
        /// Whether a bracket pair said what this node is, or whether it was
        /// only ever named on the end of an arrow. An implicit node is
        /// upgraded by the first explicit declaration; a second one is
        /// ignored, so a node keeps the shape and label it was first given.
        var isExplicit: Bool
    }

    enum LineStyle: Equatable { case solid, dotted, thick }

    /// What the line wears at one of its ends.
    enum EndCap: Equatable { case none, arrow, cross, circle }

    struct Edge: Equatable {
        var from: String
        var to: String
        var label: String?
        var style: LineStyle
        /// At `to`.
        var head: EndCap
        /// At `from` — a `<-->` wears one at both ends.
        var tail: EndCap
    }

    struct Subgraph: Equatable {
        var id: String
        var title: String
        /// The nodes first named inside this frame and not inside one of its
        /// children.
        var nodes: [String]
        var children: [Subgraph]
    }

    struct Graph: Equatable {
        var direction: Direction
        var nodes: [Node]
        var edges: [Edge]
        var subgraphs: [Subgraph]

        func node(_ id: String) -> Node? { nodes.first { $0.id == id } }
    }

    /// The statements that are read for their effect on nothing: Mermaid's
    /// styling and interaction directives. Parsed only far enough to be
    /// skipped, so a diagram wearing them still draws.
    private static let ignoredKeywords: Set<String> = [
        "click", "style", "classdef", "class", "linkstyle", "direction",
        "linkstyle;", "default",
    ]

    /// A guard against a fence that is really a text file: past this the
    /// layout is not worth the wait, and the fence stays code.
    private static let sourceLimit = 20_000
    private static let nodeLimit = 300

    // MARK: - Parsing

    /// The graph a fence describes, or `nil` when it describes none.
    static func parse(_ source: String) -> Graph? {
        guard source.count <= sourceLimit else { return nil }
        let statements = self.statements(in: source)
        guard let header = statements.first else { return nil }
        var builder = Builder()
        guard builder.readHeader(header) else { return nil }
        for statement in statements.dropFirst() {
            guard builder.read(statement) else { return nil }
        }
        guard builder.open.isEmpty else { return nil }
        guard !builder.nodes.isEmpty, builder.nodes.count <= nodeLimit else { return nil }
        return Graph(
            direction: builder.direction, nodes: builder.nodes,
            edges: builder.edges, subgraphs: builder.roots
        )
    }

    /// The source cut into statements: a newline always ends one, a `;` ends
    /// one outside a label, and `%%` puts the rest of its line beyond reach.
    /// Quotes are opaque to all three.
    private static func statements(in source: String) -> [String] {
        var found: [String] = []
        var current = ""
        var quoted = false
        var depth = 0
        let characters = Array(source)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if quoted {
                current.append(character)
                if character == "\"" { quoted = false }
                index += 1
                continue
            }
            if character == "\"" {
                quoted = true
                current.append(character)
                index += 1
                continue
            }
            if character == "%", index + 1 < characters.count, characters[index + 1] == "%" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            }
            if character == "[" || character == "(" || character == "{" { depth += 1 }
            if character == "]" || character == ")" || character == "}" { depth = max(0, depth - 1) }
            if character == "\n" || (character == ";" && depth == 0) {
                found.append(current)
                current = ""
                index += 1
                continue
            }
            current.append(character)
            index += 1
        }
        found.append(current)
        return found
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The graph as it is being read: the nodes in the order they were first
    /// named, the edges in the order they were written, and the subgraph
    /// frames still open around them.
    private struct Builder {
        var direction: Direction = .down
        var nodes: [Node] = []
        var edges: [Edge] = []
        var roots: [Subgraph] = []
        var open: [Subgraph] = []
        /// Ids already placed in a frame — a node belongs to the innermost
        /// one open when it was first named, and to nothing afterwards.
        var placed: Set<String> = []
        var index: [String: Int] = [:]

        mutating func readHeader(_ statement: String) -> Bool {
            let words = statement.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let first = words.first, first == "flowchart" || first == "graph" else {
                return false
            }
            if words.count == 1 { return true }
            guard words.count == 2, let named = Direction.named(words[1]) else { return false }
            direction = named
            return true
        }

        mutating func read(_ statement: String) -> Bool {
            let word = String(statement.prefix { !$0.isWhitespace }).lowercased()
            if word == "subgraph" { return openFrame(statement) }
            if word == "end" { return closeFrame() }
            if MermaidFlowchart.ignoredKeywords.contains(word) { return true }
            if word.hasPrefix("acctitle") || word.hasPrefix("accdescr") { return true }
            return readChain(statement)
        }

        /// `subgraph id [Title]`, `subgraph Title`, `subgraph`.
        mutating func openFrame(_ statement: String) -> Bool {
            let rest = statement
                .dropFirst("subgraph".count)
                .trimmingCharacters(in: .whitespaces)
            if rest.isEmpty {
                open.append(Subgraph(id: "sub\(open.count)-\(roots.count)", title: "",
                                     nodes: [], children: []))
                return true
            }
            if let bracket = rest.firstIndex(of: "["), rest.hasSuffix("]") {
                let id = rest[rest.startIndex ..< bracket].trimmingCharacters(in: .whitespaces)
                let title = String(rest[rest.index(after: bracket) ..< rest.index(before: rest.endIndex)])
                guard !id.isEmpty else { return false }
                open.append(Subgraph(id: id, title: MermaidFlowchart.label(title),
                                     nodes: [], children: []))
                return true
            }
            let title = MermaidFlowchart.label(rest)
            open.append(Subgraph(id: title, title: title, nodes: [], children: []))
            return true
        }

        mutating func closeFrame() -> Bool {
            guard let finished = open.popLast() else { return false }
            if open.isEmpty {
                roots.append(finished)
            } else {
                open[open.count - 1].children.append(finished)
            }
            return true
        }

        /// One chain: node groups with a link between each pair. `A & B --> C`
        /// is two groups and one link, and every pairing across it is an edge.
        mutating func readChain(_ statement: String) -> Bool {
            var scanner = Scanner(statement)
            var groups: [[String]] = []
            var links: [Scanner.Link] = []

            while true {
                guard let group = readGroup(&scanner) else { return false }
                groups.append(group)
                scanner.skipSpaces()
                if scanner.isAtEnd { break }
                guard let link = scanner.readLink() else { return false }
                links.append(link)
            }
            guard links.count == groups.count - 1 else { return false }

            for (step, link) in links.enumerated() {
                for from in groups[step] {
                    for to in groups[step + 1] {
                        edges.append(Edge(
                            from: from, to: to, label: link.label,
                            style: link.style, head: link.head, tail: link.tail
                        ))
                    }
                }
            }
            return true
        }

        mutating func readGroup(_ scanner: inout Scanner) -> [String]? {
            var ids: [String] = []
            while true {
                scanner.skipSpaces()
                guard let id = readNode(&scanner) else { return nil }
                ids.append(id)
                scanner.skipSpaces()
                guard scanner.peek() == "&" else { break }
                scanner.advance()
            }
            return ids
        }

        mutating func readNode(_ scanner: inout Scanner) -> String? {
            guard let id = scanner.readIdentifier() else { return nil }
            let shape = scanner.readShape()
            scanner.skipClassSuffix()
            declare(
                id: id,
                shape: shape?.shape ?? .rectangle,
                label: shape.map { MermaidFlowchart.label($0.label) } ?? id,
                isExplicit: shape != nil
            )
            return id
        }

        mutating func declare(id: String, shape: NodeShape, label: String, isExplicit: Bool) {
            if let existing = index[id] {
                guard isExplicit, !nodes[existing].isExplicit else { return }
                nodes[existing].shape = shape
                nodes[existing].label = label.isEmpty ? id : label
                nodes[existing].isExplicit = true
                return
            }
            index[id] = nodes.count
            nodes.append(Node(
                id: id, label: label.isEmpty ? id : label,
                shape: shape, isExplicit: isExplicit
            ))
            if !open.isEmpty, placed.insert(id).inserted {
                open[open.count - 1].nodes.append(id)
            }
        }
    }

    /// A label as it is drawn: quotes off, `<br>` a line break, whitespace
    /// trimmed.
    private static func label(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast())
        }
        for token in ["<br/>", "<br />", "<br>"] {
            text = text.replacingOccurrences(
                of: token, with: "\n", options: [.caseInsensitive]
            )
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - The statement scanner

    /// One statement, read left to right. Everything that has to decide
    /// between "this is part of an id" and "this is the arrow" happens here,
    /// and it decides by trying to read the arrow: a `-` that opens no link is
    /// a character in a name.
    private struct Scanner {
        struct Link {
            var style: LineStyle
            var head: EndCap
            var tail: EndCap
            var label: String?
        }

        let characters: [Character]
        var index = 0

        init(_ text: String) { characters = Array(text) }

        var isAtEnd: Bool { index >= characters.count }

        func peek(_ offset: Int = 0) -> Character? {
            let at = index + offset
            return at >= 0 && at < characters.count ? characters[at] : nil
        }

        mutating func advance(_ count: Int = 1) { index = min(characters.count, index + count) }

        mutating func skipSpaces() {
            while let character = peek(), character == " " || character == "\t" { index += 1 }
        }

        func run(of character: Character, from start: Int) -> Int {
            var length = 0
            while start + length < characters.count, characters[start + length] == character {
                length += 1
            }
            return length
        }

        func matches(_ text: String) -> Bool {
            let wanted = Array(text)
            guard index + wanted.count <= characters.count else { return false }
            for (offset, character) in wanted.enumerated()
            where characters[index + offset] != character { return false }
            return true
        }

        private static func isIdentifier(_ character: Character) -> Bool {
            character.isLetter || character.isNumber
                || character == "_" || character == "-" || character == "."
        }

        /// A node's name. It stops at whitespace, at a bracket, and at any `-`
        /// `=` or `<` that turns out to open a link.
        mutating func readIdentifier() -> String? {
            var id = ""
            while let character = peek() {
                if character == "-" || character == "=" || character == "<" {
                    var probe = self
                    if probe.readLink() != nil { break }
                }
                guard Self.isIdentifier(character) else { break }
                id.append(character)
                index += 1
            }
            return id.isEmpty ? nil : id
        }

        /// The bracket pair after a name, longest first so `[[` is a
        /// subroutine before it is a rectangle holding a `[`.
        mutating func readShape() -> (shape: NodeShape, label: String)? {
            let start = index
            skipSpaces()
            let openers: [(String, String, NodeShape)] = [
                ("([", "])", .stadium),
                ("[[", "]]", .subroutine),
                ("[(", ")]", .cylinder),
                ("((", "))", .circle),
                ("{{", "}}", .hexagon),
                ("[", "]", .rectangle),
                ("(", ")", .rounded),
                ("{", "}", .diamond),
                (">", "]", .flag),
            ]
            for (opening, closing, shape) in openers where matches(opening) {
                advance(opening.count)
                guard let text = readLabel(until: closing) else {
                    index = start
                    return nil
                }
                return (shape, text)
            }
            index = start
            return nil
        }

        /// The text inside a bracket pair. A quoted label is opaque, which is
        /// how `A["a [b]"]` keeps its brackets.
        private mutating func readLabel(until closing: String) -> String? {
            skipSpaces()
            if peek() == "\"" {
                index += 1
                var text = ""
                while let character = peek(), character != "\"" {
                    text.append(character)
                    index += 1
                }
                guard peek() == "\"" else { return nil }
                index += 1
                skipSpaces()
                guard matches(closing) else { return nil }
                advance(closing.count)
                return text
            }
            var text = ""
            while !isAtEnd {
                if matches(closing) {
                    advance(closing.count)
                    return text
                }
                text.append(characters[index])
                index += 1
            }
            return nil
        }

        /// `:::className` after a node — parsed so it is skipped, never so it
        /// is used.
        mutating func skipClassSuffix() {
            guard matches(":::") else { return }
            advance(3)
            while let character = peek(), Self.isIdentifier(character) { index += 1 }
        }

        /// The link between two node groups, or `nil` when what is here is
        /// not one.
        ///
        /// Mermaid's own rule settles the one genuine ambiguity: after the
        /// two characters that open a link, another `-` (or a head) means a
        /// plain arrow and anything else opens the label. That is what keeps
        /// `A --- B --- C` a chain of two links rather than one link labelled
        /// `B`.
        mutating func readLink() -> Link? {
            let start = index
            var tail = EndCap.none
            if peek() == "<", let next = peek(1), next == "-" || next == "=" {
                tail = .arrow
                index += 1
            }
            guard let opening = peek() else {
                index = start
                return nil
            }
            var style = LineStyle.solid
            var label: String?

            switch opening {
            case "=":
                guard peek(1) == "=" else {
                    index = start
                    return nil
                }
                style = .thick
                advance(2)
                if let next = peek(), next == "=" {
                    advance(run(of: "=", from: index))
                } else if isHead(peek()) || peek() == nil {
                    break
                } else {
                    guard let text = readLinkLabel(terminator: "=", minimumRun: 2) else {
                        index = start
                        return nil
                    }
                    label = text
                }
            case "-" where peek(1) == ".":
                style = .dotted
                advance()
                advance(run(of: ".", from: index))
                if peek() == "-" {
                    advance(run(of: "-", from: index))
                } else {
                    guard let text = readDottedLabel() else {
                        index = start
                        return nil
                    }
                    label = text
                    guard peek() == "-" else {
                        index = start
                        return nil
                    }
                    advance(run(of: "-", from: index))
                }
            case "-":
                guard peek(1) == "-" else {
                    index = start
                    return nil
                }
                advance(2)
                if let next = peek(), next == "-" {
                    advance(run(of: "-", from: index))
                } else if isHead(peek()) || peek() == nil {
                    break
                } else {
                    guard let text = readLinkLabel(terminator: "-", minimumRun: 2) else {
                        index = start
                        return nil
                    }
                    label = text
                }
            default:
                index = start
                return nil
            }

            var head = EndCap.none
            switch peek() {
            case ">": head = .arrow; advance()
            case "x": head = .cross; advance()
            case "o": head = .circle; advance()
            default: break
            }

            if peek() == "|" {
                advance()
                var text = ""
                while let character = peek(), character != "|" {
                    text.append(character)
                    index += 1
                }
                guard peek() == "|" else {
                    index = start
                    return nil
                }
                advance()
                label = MermaidFlowchart.label(text)
            }

            return Link(
                style: style, head: head, tail: tail,
                label: (label?.isEmpty ?? true) ? nil : label
            )
        }

        private func isHead(_ character: Character?) -> Bool {
            character == ">" || character == "x" || character == "o"
        }

        /// The text of a `-- text -->` or `== text ==>` link, closed by a run
        /// of the same character.
        private mutating func readLinkLabel(
            terminator: Character, minimumRun: Int
        ) -> String? {
            let start = index
            var text = ""
            var at = index
            while at < characters.count {
                if characters[at] == terminator {
                    let length = run(of: terminator, from: at)
                    if length >= minimumRun {
                        index = at + length
                        return MermaidFlowchart.label(text)
                    }
                    text.append(contentsOf: characters[at ..< (at + length)])
                    at += length
                    continue
                }
                text.append(characters[at])
                at += 1
            }
            index = start
            return nil
        }

        /// The text of a `-. text .->` link. The closing dot has to be
        /// followed by a dash, so a label saying `3.5 sec` keeps its own.
        private mutating func readDottedLabel() -> String? {
            let start = index
            var text = ""
            var at = index
            while at < characters.count {
                if characters[at] == ".", at + 1 < characters.count, characters[at + 1] == "-" {
                    index = at + 1
                    return MermaidFlowchart.label(text)
                }
                text.append(characters[at])
                at += 1
            }
            index = start
            return nil
        }
    }

    // MARK: - Laid out

    /// A line of text measured once, drawn every time the appearance asks.
    struct TextBlock {
        let lines: [CTLine]
        let width: CGFloat
        let height: CGFloat
        let lineHeight: CGFloat
        let ascent: CGFloat

        var isEmpty: Bool { lines.isEmpty || width <= 0 }
    }

    struct PlacedNode {
        let id: String
        let shape: NodeShape
        var frame: CGRect
        let text: TextBlock
    }

    struct PlacedEdge {
        let from: String
        let to: String
        /// The centres the line passes through, ends already pulled back to
        /// the border of the node they touch.
        var points: [CGPoint]
        var path: CGPath
        let style: LineStyle
        let head: EndCap
        var headPoint: CGPoint
        var headAngle: CGFloat
        let tail: EndCap
        var tailPoint: CGPoint
        var tailAngle: CGFloat
        let label: TextBlock?
        var labelRect: CGRect
    }

    struct PlacedFrame {
        let title: TextBlock?
        var rect: CGRect
        var titleRect: CGRect
    }

    /// The fence laid out against the render's own font, or `nil` when it is
    /// not a flowchart this parser can read — the one door `Mermaid.layout`
    /// comes through.
    static func layout(_ source: String, font: NSFont) -> MermaidDiagram? {
        guard let graph = parse(source) else { return nil }
        return Diagram(graph: graph, font: font)
    }

    /// One laid-out flowchart. Everything about it is points; nothing about it
    /// is colour, which is what lets it draw itself in either appearance.
    final class Diagram: MermaidDiagram {
        let graph: Graph
        let size: CGSize
        let nodes: [PlacedNode]
        let edges: [PlacedEdge]
        let frames: [PlacedFrame]
        private let font: NSFont

        init(graph: Graph, font: NSFont) {
            self.graph = graph
            self.font = font
            let laid = MermaidFlowchart.place(graph, font: font)
            nodes = laid.nodes
            edges = laid.edges
            frames = laid.frames
            size = laid.size
        }

        func node(_ id: String) -> PlacedNode? { nodes.first { $0.id == id } }

        func draw(in context: CGContext, palette: MermaidPalette) {
            MermaidFlowchart.draw(self, in: context, palette: palette, font: font)
        }
    }

    // MARK: - Layout

    /// The font every label is set in: the render's own size taken down a
    /// notch, and the system family unless the render is monospaced, in which
    /// case the diagram keeps the company of the text around it.
    static func labelFont(for font: NSFont) -> NSFont {
        let size = max(6, (font.pointSize * 0.9).rounded())
        if font.fontDescriptor.symbolicTraits.contains(.monoSpace) {
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return .systemFont(ofSize: size)
    }

    /// One item in a rank: a node, or the placeholder a long edge passes
    /// through so it can be routed around what stands between its ends.
    private struct Item {
        var node: Int?
        var rank = 0
        var cross: CGFloat = 0
        var crossSize: CGFloat = 0
        var rankSize: CGFloat = 0
        var group: [Int] = []
        var up: [Int] = []
        var down: [Int] = []
    }

    private static func place(
        _ graph: Graph, font: NSFont
    ) -> (nodes: [PlacedNode], edges: [PlacedEdge], frames: [PlacedFrame], size: CGSize) {
        let labelFont = labelFont(for: font)
        let unit = labelFont.pointSize
        let siblingGap = (unit * 1.2).rounded()
        let margin = (unit * 0.6).rounded()
        // A labelled edge carries a box on the middle of it, and the box has
        // to fit between the ranks it runs between — otherwise the words sit
        // on the node they came from. Measured here, before anything is
        // placed, because the gap is what it changes.
        var labelExtent: CGFloat = 0
        for edge in graph.edges {
            guard let text = edge.label, !text.isEmpty else { continue }
            let block = measure(text, font: labelFont)
            labelExtent = max(
                labelExtent,
                graph.direction.isVertical ? block.height + unit * 0.3 : block.width + unit * 0.7
            )
        }
        let rankGap = max((unit * 2.2).rounded(), (labelExtent + unit).rounded())

        // 1. Every node measured, and the box its shape needs around the words.
        var texts: [TextBlock] = []
        var sizes: [CGSize] = []
        for node in graph.nodes {
            let text = measure(node.label, font: labelFont)
            texts.append(text)
            sizes.append(box(for: node.shape, text: text, unit: unit))
        }

        // 2. Cycles broken, so the ranking has a direction to run in.
        let reversed = backEdges(of: graph)

        // 3. Ranks by longest path over the acyclic edges.
        let ranks = self.ranks(of: graph, reversed: reversed)

        // 4. Items: one per node, plus a dummy in every rank a long edge
        //    crosses.
        var items: [Item] = []
        let groups = groupPaths(of: graph)
        for (index, node) in graph.nodes.enumerated() {
            var item = Item(node: index)
            item.rank = ranks[node.id] ?? 0
            item.crossSize = graph.direction.isVertical ? sizes[index].width : sizes[index].height
            item.rankSize = graph.direction.isVertical ? sizes[index].height : sizes[index].width
            item.group = groups[node.id] ?? []
            items.append(item)
        }
        var itemOf: [String: Int] = [:]
        for (index, node) in graph.nodes.enumerated() { itemOf[node.id] = index }

        /// The chain of items each edge runs through, in rank order.
        var chains: [[Int]] = []
        for (index, edge) in graph.edges.enumerated() {
            guard edge.from != edge.to,
                  let start = itemOf[edge.from], let end = itemOf[edge.to] else {
                chains.append([])
                continue
            }
            let isReversed = reversed.contains(index)
            let low = isReversed ? end : start
            let high = isReversed ? start : end
            var chain = [low]
            let from = items[low].rank
            let to = items[high].rank
            if to > from + 1 {
                for rank in (from + 1) ..< to {
                    var dummy = Item(node: nil)
                    dummy.rank = rank
                    dummy.crossSize = (unit * 0.8).rounded()
                    dummy.rankSize = 0
                    dummy.group = items[low].group
                    items.append(dummy)
                    chain.append(items.count - 1)
                }
            }
            chain.append(high)
            for step in 0 ..< (chain.count - 1) {
                items[chain[step]].down.append(chain[step + 1])
                items[chain[step + 1]].up.append(chain[step])
            }
            chains.append(isReversed ? Array(chain.reversed()) : chain)
        }

        // 5. The order inside each rank, settled by barycenter sweeps.
        var layers = self.layers(of: items)
        order(&layers, items: items)

        // 6. Coordinates.
        let extra = graph.subgraphs.isEmpty ? 0 : (unit * 1.4).rounded()
        crossPositions(
            &items, layers: layers, gap: siblingGap, extra: extra
        )
        let rankPositions = self.rankPositions(
            items: items, layers: layers, gap: rankGap + (extra > 0 ? extra * 0.5 : 0)
        )
        let lastDepth = layers.last.map { layer in
            layer.map { items[$0].rankSize }.max() ?? 0
        } ?? 0
        let depth = (rankPositions.last ?? 0) + lastDepth / 2

        var placed: [PlacedNode] = []
        var centres: [CGPoint] = Array(repeating: .zero, count: items.count)
        for (index, item) in items.enumerated() {
            let along = graph.direction == .up || graph.direction == .left
                ? depth - rankPositions[item.rank]
                : rankPositions[item.rank]
            let centre = graph.direction.isVertical
                ? CGPoint(x: item.cross, y: along)
                : CGPoint(x: along, y: item.cross)
            centres[index] = centre
            guard let node = item.node else { continue }
            let size = sizes[node]
            placed.append(PlacedNode(
                id: graph.nodes[node].id,
                shape: graph.nodes[node].shape,
                frame: CGRect(
                    x: (centre.x - size.width / 2).rounded(),
                    y: (centre.y - size.height / 2).rounded(),
                    width: size.width, height: size.height
                ),
                text: texts[node]
            ))
        }

        // 7. Subgraph frames around what they hold.
        var frames: [PlacedFrame] = []
        for subgraph in graph.subgraphs {
            frame(subgraph, in: placed, font: labelFont, unit: unit, into: &frames)
        }

        // 8. Edges, from border to border, a bundle between one pair of nodes
        //    spread so that no two of its lines share a corridor.
        let spread = crossOffsets(of: graph, nodes: placed, font: labelFont, unit: unit)
        let vertical = graph.direction.isVertical
        var wires: [PlacedEdge] = []
        for (index, edge) in graph.edges.enumerated() {
            if edge.from == edge.to {
                if let node = placed.first(where: { $0.id == edge.from }) {
                    wires.append(loop(edge, around: node, font: labelFont, unit: unit))
                }
                continue
            }
            let chain = chains[index]
            guard chain.count >= 2 else { continue }
            let offset = spread[index]
            var points = chain.map { centres[$0] }
            if offset != 0 {
                for step in points.indices {
                    if vertical { points[step].x += offset } else { points[step].y += offset }
                }
            }
            let head = placed.first { $0.id == edge.to }
            let tail = placed.first { $0.id == edge.from }
            if let tail {
                points[0] = border(
                    of: tail.shape, in: tail.frame, toward: points[1],
                    offsetAcross: offset, vertical: vertical
                )
            }
            if let head {
                points[points.count - 1] = border(
                    of: head.shape, in: head.frame, toward: points[points.count - 2],
                    offsetAcross: offset, vertical: vertical
                )
            }
            wires.append(wire(edge, through: points, font: labelFont, unit: unit))
        }

        // 9. Everything moved into a box that starts at the margin.
        var bounds = CGRect.null
        for node in placed { bounds = bounds.union(node.frame) }
        for frame in frames { bounds = bounds.union(frame.rect) }
        for wire in wires {
            bounds = bounds.union(wire.path.boundingBoxOfPath)
            if !wire.labelRect.isEmpty { bounds = bounds.union(wire.labelRect) }
        }
        if bounds.isNull { bounds = CGRect(x: 0, y: 0, width: 1, height: 1) }
        let shift = CGPoint(x: margin - bounds.minX, y: margin - bounds.minY)
        var transform = CGAffineTransform(translationX: shift.x, y: shift.y)

        for index in placed.indices { placed[index].frame.origin.x += shift.x }
        for index in placed.indices { placed[index].frame.origin.y += shift.y }
        for index in frames.indices {
            frames[index].rect = frames[index].rect.offsetBy(dx: shift.x, dy: shift.y)
            frames[index].titleRect = frames[index].titleRect.offsetBy(dx: shift.x, dy: shift.y)
        }
        for index in wires.indices {
            wires[index].points = wires[index].points.map {
                CGPoint(x: $0.x + shift.x, y: $0.y + shift.y)
            }
            wires[index].path = wires[index].path.copy(using: &transform) ?? wires[index].path
            wires[index].headPoint.x += shift.x
            wires[index].headPoint.y += shift.y
            wires[index].tailPoint.x += shift.x
            wires[index].tailPoint.y += shift.y
            if !wires[index].labelRect.isEmpty {
                wires[index].labelRect = wires[index].labelRect
                    .offsetBy(dx: shift.x, dy: shift.y)
            }
        }

        let size = CGSize(
            width: max(1, (bounds.width + margin * 2).rounded(.up)),
            height: max(1, (bounds.height + margin * 2).rounded(.up))
        )
        return (placed, wires, frames, size)
    }

    // MARK: - Layout, step by step

    /// The edges that close a cycle, found by a depth-first walk: an edge back
    /// onto the stack is one, and it is the one that gets turned round for the
    /// ranking.
    private static func backEdges(of graph: Graph) -> Set<Int> {
        var outgoing: [String: [Int]] = [:]
        for (index, edge) in graph.edges.enumerated() where edge.from != edge.to {
            outgoing[edge.from, default: []].append(index)
        }
        var reversed: Set<Int> = []
        var done: Set<String> = []
        var onStack: Set<String> = []

        func walk(_ id: String) {
            done.insert(id)
            onStack.insert(id)
            for index in outgoing[id] ?? [] {
                let next = graph.edges[index].to
                if onStack.contains(next) {
                    reversed.insert(index)
                } else if !done.contains(next) {
                    walk(next)
                }
            }
            onStack.remove(id)
        }

        for node in graph.nodes where !done.contains(node.id) { walk(node.id) }
        return reversed
    }

    /// Longest-path ranking over the acyclic edge set: a node sits one rank
    /// below the lowest thing pointing at it.
    private static func ranks(of graph: Graph, reversed: Set<Int>) -> [String: Int] {
        var incoming: [String: [String]] = [:]
        var outgoing: [String: [String]] = [:]
        var degree: [String: Int] = [:]
        for node in graph.nodes { degree[node.id] = 0 }

        for (index, edge) in graph.edges.enumerated() where edge.from != edge.to {
            let from = reversed.contains(index) ? edge.to : edge.from
            let to = reversed.contains(index) ? edge.from : edge.to
            guard degree[from] != nil, degree[to] != nil else { continue }
            outgoing[from, default: []].append(to)
            incoming[to, default: []].append(from)
            degree[to] = (degree[to] ?? 0) + 1
        }

        var rank: [String: Int] = [:]
        var queue = graph.nodes.map(\.id).filter { degree[$0] == 0 }
        for id in queue { rank[id] = 0 }
        var head = 0
        while head < queue.count {
            let id = queue[head]
            head += 1
            for next in outgoing[id] ?? [] {
                rank[next] = max(rank[next] ?? 0, (rank[id] ?? 0) + 1)
                degree[next] = (degree[next] ?? 1) - 1
                if degree[next] == 0 { queue.append(next) }
            }
        }
        // A node left in a knot the cycle breaking missed still needs a rank.
        for node in graph.nodes where rank[node.id] == nil { rank[node.id] = 0 }
        return rank
    }

    /// Which frames a node sits inside, outermost first — the key that keeps a
    /// subgraph's nodes beside each other in the first ordering.
    private static func groupPaths(of graph: Graph) -> [String: [Int]] {
        var paths: [String: [Int]] = [:]
        func walk(_ subgraphs: [Subgraph], prefix: [Int]) {
            for (index, subgraph) in subgraphs.enumerated() {
                let path = prefix + [index]
                for id in subgraph.nodes { paths[id] = path }
                walk(subgraph.children, prefix: path)
            }
        }
        walk(graph.subgraphs, prefix: [])
        return paths
    }

    private static func layers(of items: [Item]) -> [[Int]] {
        let depth = (items.map(\.rank).max() ?? 0) + 1
        var layers = [[Int]](repeating: [], count: depth)
        for (index, item) in items.enumerated() { layers[item.rank].append(index) }
        for rank in layers.indices {
            layers[rank].sort { left, right in
                let a = items[left].group
                let b = items[right].group
                if a != b { return a.lexicographicallyPrecedes(b) }
                return left < right
            }
        }
        return layers
    }

    /// Barycenter sweeps: an item drifts towards the average position of what
    /// it is joined to, down the ranks and then back up, a few times over.
    private static func order(_ layers: inout [[Int]], items: [Item]) {
        guard layers.count > 1 else { return }
        var position = [Int](repeating: 0, count: items.count)
        func note() {
            for layer in layers {
                for (index, item) in layer.enumerated() { position[item] = index }
            }
        }
        note()

        for sweep in 0 ..< 4 {
            let downward = sweep % 2 == 0
            let ranks = downward
                ? Array(1 ..< layers.count)
                : Array((0 ..< (layers.count - 1)).reversed())
            for rank in ranks {
                let weights = layers[rank].map { item -> CGFloat in
                    let neighbours = downward ? items[item].up : items[item].down
                    guard !neighbours.isEmpty else { return CGFloat(position[item]) }
                    let total = neighbours.reduce(CGFloat(0)) { $0 + CGFloat(position[$1]) }
                    return total / CGFloat(neighbours.count)
                }
                let sorted = zip(layers[rank], weights)
                    .enumerated()
                    .sorted { left, right in
                        left.element.1 == right.element.1
                            ? left.offset < right.offset
                            : left.element.1 < right.element.1
                    }
                layers[rank] = sorted.map { $0.element.0 }
                note()
            }
        }
    }

    /// The cross-axis coordinate of every item: packed so nothing overlaps,
    /// then pulled towards what it is joined to, a few passes each way.
    private static func crossPositions(
        _ items: inout [Item], layers: [[Int]], gap: CGFloat, extra: CGFloat
    ) {
        func space(_ left: Int, _ right: Int) -> CGFloat {
            let separation = items[left].group == items[right].group ? gap : gap + extra
            return items[left].crossSize / 2 + separation + items[right].crossSize / 2
        }

        // A first packing, so every item has somewhere to be pulled from.
        for layer in layers {
            var position: CGFloat = 0
            for (index, item) in layer.enumerated() {
                if index > 0 { position += space(layer[index - 1], item) }
                items[item].cross = position
            }
        }

        for pass in 0 ..< 4 {
            let downward = pass % 2 == 0
            let ranks = downward
                ? Array(0 ..< layers.count)
                : Array((0 ..< layers.count).reversed())
            for rank in ranks {
                let layer = layers[rank]
                guard !layer.isEmpty else { continue }
                let wanted = layer.map { item -> CGFloat in
                    let neighbours = downward ? items[item].up : items[item].down
                    guard !neighbours.isEmpty else { return items[item].cross }
                    let total = neighbours.reduce(CGFloat(0)) { $0 + items[$1].cross }
                    return total / CGFloat(neighbours.count)
                }
                var positions = wanted
                for index in 1 ..< max(1, layer.count) {
                    positions[index] = max(
                        positions[index], positions[index - 1] + space(layer[index - 1], layer[index])
                    )
                }
                for index in stride(from: layer.count - 2, through: 0, by: -1) {
                    let ceiling = positions[index + 1] - space(layer[index], layer[index + 1])
                    let floor = index > 0
                        ? positions[index - 1] + space(layer[index - 1], layer[index])
                        : -CGFloat.greatestFiniteMagnitude
                    positions[index] = max(floor, min(positions[index], ceiling))
                }
                for (index, item) in layer.enumerated() { items[item].cross = positions[index] }
            }
        }
    }

    /// Where each rank's centre line sits along the direction of flow.
    private static func rankPositions(
        items: [Item], layers: [[Int]], gap: CGFloat
    ) -> [CGFloat] {
        var positions: [CGFloat] = []
        var cursor: CGFloat = 0
        var previous: CGFloat = 0
        for (rank, layer) in layers.enumerated() {
            let depth = layer.map { items[$0].rankSize }.max() ?? 0
            if rank == 0 {
                cursor = depth / 2
            } else {
                cursor += previous / 2 + gap + depth / 2
            }
            positions.append(cursor.rounded())
            previous = depth
        }
        return positions
    }

    /// How far across the flow each edge is moved so that a bundle joining
    /// one pair of nodes runs side by side.
    ///
    /// Two edges between the same two nodes — `C --> E` and `E --> C`, or the
    /// same way round twice with a word on each — are laid out through the
    /// same ranks at the same place across them, so without this they are one
    /// line on the page wearing a cap at either end, and the label belonging
    /// to one sits on top of the other. Mermaid draws such a pair as two
    /// clearly separate curves; so does this. The bundle is centred on where
    /// the single edge would have run and spread by a spacing either side, so
    /// a pair sits at ±0.45 of a unit and each line carries its own words.
    /// A bundle carrying words is spread by at least the box those words sit
    /// in, so a label never reaches across onto its neighbour's line. A
    /// corridor that runs at a slant needs more than the box's width: the
    /// neighbouring line moves across as it goes down, and over the depth of
    /// the box it moves far enough to reach into a corner of it. The spread
    /// is never wider than the narrower node can carry, since both ends still
    /// have to leave and land on a border.
    private static func crossOffsets(
        of graph: Graph, nodes: [PlacedNode], font: NSFont, unit: CGFloat
    ) -> [CGFloat] {
        var offsets = [CGFloat](repeating: 0, count: graph.edges.count)
        var bundles: [String: [Int]] = [:]
        var order: [String] = []
        for (index, edge) in graph.edges.enumerated() where edge.from != edge.to {
            let pair = edge.from < edge.to
                ? "\(edge.from)\u{1}\(edge.to)" : "\(edge.to)\u{1}\(edge.from)"
            if bundles[pair] == nil { order.append(pair) }
            bundles[pair, default: []].append(index)
        }
        let vertical = graph.direction.isVertical
        for pair in order {
            guard let bundle = bundles[pair], bundle.count > 1 else { continue }
            let ends = [graph.edges[bundle[0]].from, graph.edges[bundle[0]].to]
                .compactMap { id in nodes.first { $0.id == id } }
            guard ends.count == 2 else { continue }
            let room = ends
                .map { vertical ? $0.frame.width : $0.frame.height }
                .min() ?? 0
            let dx = abs(ends[0].frame.midX - ends[1].frame.midX)
            let dy = abs(ends[0].frame.midY - ends[1].frame.midY)
            // The slant of the corridor: how far it moves across the flow for
            // every step it takes along it.
            let slant = vertical ? dx / max(dy, 1) : dy / max(dx, 1)
            var words: CGFloat = 0
            for index in bundle {
                guard let text = graph.edges[index].label, !text.isEmpty else { continue }
                let block = measure(text, font: font)
                let width = block.width + unit * 0.7
                let height = block.height + unit * 0.3
                let wide = vertical ? width : height
                let deep = vertical ? height : width
                words = max(words, wide + deep * slant)
            }
            let spacing = min(
                max(unit * 0.9, words + unit * 0.5), room * 0.7 / CGFloat(bundle.count - 1)
            )
            for (step, index) in bundle.enumerated() {
                offsets[index] = (CGFloat(step) - CGFloat(bundle.count - 1) / 2) * spacing
            }
        }
        return offsets
    }

    // MARK: - Shapes and text

    private static func measure(_ label: String, font: NSFont) -> TextBlock {
        let rows = label.isEmpty ? [""] : label.components(separatedBy: "\n")
        var lines: [CTLine] = []
        var width: CGFloat = 0
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        for row in rows {
            // `kCTForegroundColorFromContext`: the line takes the fill colour
            // set at draw time, so a label is the palette's text colour and
            // not CoreText's default black in the dark.
            let string = NSAttributedString(string: row, attributes: [
                .font: font,
                kCTForegroundColorFromContextAttributeName as NSAttributedString.Key: true,
            ])
            let line = CTLineCreateWithAttributedString(string)
            var a: CGFloat = 0
            var d: CGFloat = 0
            var l: CGFloat = 0
            let measured = CGFloat(CTLineGetTypographicBounds(line, &a, &d, &l))
            width = max(width, measured)
            ascent = max(ascent, a)
            descent = max(descent, d)
            leading = max(leading, l)
            lines.append(line)
        }
        let lineHeight = (ascent + descent + leading).rounded(.up)
        return TextBlock(
            lines: lines, width: width.rounded(.up),
            height: lineHeight * CGFloat(rows.count),
            lineHeight: lineHeight, ascent: ascent
        )
    }

    /// The box a shape needs around a measured label.
    private static func box(for shape: NodeShape, text: TextBlock, unit: CGFloat) -> CGSize {
        let horizontal = (unit * 0.8).rounded()
        let vertical = (unit * 0.5).rounded()
        var width = text.width + horizontal * 2
        var height = max(text.height + vertical * 2, (unit * 2).rounded())

        switch shape {
        case .rectangle, .rounded:
            break
        case .stadium:
            width += height * 0.4
        case .subroutine:
            width += unit
        case .cylinder:
            // Room for both caps: the words sit between them.
            height += (unit * 1.6).rounded()
        case .circle:
            let diameter = max(
                (sqrt(text.width * text.width + text.height * text.height) + horizontal * 2)
                    .rounded(),
                height
            )
            width = diameter
            height = diameter
        case .diamond:
            width = (width * 1.45).rounded()
            height = (height * 1.5).rounded()
        case .hexagon:
            width += height * 0.6
        case .flag:
            width += (unit * 0.8).rounded()
        }
        return CGSize(width: max(width, unit * 2).rounded(), height: height.rounded())
    }

    /// Where a line leaving a node's centre for `point` crosses its outline.
    static func border(of shape: NodeShape, in rect: CGRect, toward point: CGPoint) -> CGPoint {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let dx = point.x - centre.x
        let dy = point.y - centre.y
        guard abs(dx) > 0.001 || abs(dy) > 0.001 else { return centre }
        let halfWidth = max(rect.width / 2, 0.001)
        let halfHeight = max(rect.height / 2, 0.001)
        let scale: CGFloat

        switch shape {
        case .circle:
            let x = dx / halfWidth
            let y = dy / halfHeight
            scale = 1 / max(sqrt(x * x + y * y), 0.001)
        case .diamond:
            scale = 1 / max(abs(dx) / halfWidth + abs(dy) / halfHeight, 0.001)
        default:
            let horizontal = abs(dx) < 0.001
                ? CGFloat.greatestFiniteMagnitude : halfWidth / abs(dx)
            let vertical = abs(dy) < 0.001
                ? CGFloat.greatestFiniteMagnitude : halfHeight / abs(dy)
            scale = min(horizontal, vertical)
        }
        return CGPoint(x: centre.x + dx * scale, y: centre.y + dy * scale)
    }

    /// Where a run moved `offset` across the flow leaves a node's border.
    ///
    /// Sliding the border point sideways by the offset would take it off the
    /// border: on a diamond or a circle the border a few points to the side
    /// of the middle sits at a quite different distance along. So the answer
    /// comes from the same `border` above, which casts a ray out of the
    /// centre — the ray wanted is the one whose own answer comes back at the
    /// offset asked for. That answer is the full half-width for a ray with no
    /// tilt and shrinks to nothing as the ray is tipped along the flow, so
    /// halving the tilt closes on it, and the point it closes on is a border
    /// point of the shape, not an approximation of one.
    static func border(
        of shape: NodeShape, in rect: CGRect, toward point: CGPoint,
        offsetAcross offset: CGFloat, vertical: Bool
    ) -> CGPoint {
        guard abs(offset) > 0.001 else { return border(of: shape, in: rect, toward: point) }
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let halfAcross = max((vertical ? rect.width : rect.height) / 2, 0.001)
        let halfAlong = max((vertical ? rect.height : rect.width) / 2, 0.001)
        let across = min(max(offset, -halfAcross * 0.95), halfAcross * 0.95)
        let along: CGFloat = (vertical ? point.y - centre.y : point.x - centre.x) < 0 ? -1 : 1

        func ray(_ tilt: CGFloat) -> CGPoint {
            let toward = vertical
                ? CGPoint(x: centre.x + across, y: centre.y + along * tilt)
                : CGPoint(x: centre.x + along * tilt, y: centre.y + across)
            return border(of: shape, in: rect, toward: toward)
        }

        var low: CGFloat = 0
        var high = halfAlong * 64
        for _ in 0 ..< 40 {
            let middle = (low + high) / 2
            let hit = ray(middle)
            let reached = abs(vertical ? hit.x - centre.x : hit.y - centre.y)
            if reached > abs(across) { low = middle } else { high = middle }
        }
        let hit = ray((low + high) / 2)
        return vertical
            ? CGPoint(x: centre.x + across, y: hit.y)
            : CGPoint(x: hit.x, y: centre.y + across)
    }

    /// How deep a cylinder's end caps are.
    static func cylinderCap(of rect: CGRect, unit: CGFloat) -> CGFloat {
        min(rect.height * 0.2, unit * 0.9)
    }

    /// The outline of one node, in the box it was given.
    static func path(of shape: NodeShape, in rect: CGRect, unit: CGFloat) -> CGPath {
        let path = CGMutablePath()
        switch shape {
        case .rectangle:
            path.addRect(rect)
        case .rounded:
            path.addRoundedRect(in: rect, cornerWidth: unit * 0.4, cornerHeight: unit * 0.4)
        case .stadium:
            let radius = rect.height / 2
            path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
        case .subroutine:
            path.addRect(rect)
        case .cylinder:
            // Two half ellipses and two sides. The control offset is the
            // cubic that comes closest to a half ellipse, so the caps touch
            // the box exactly and never bulge out of it.
            let cap = cylinderCap(of: rect, unit: unit)
            let reach = cap * 4 / 3
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + cap))
            path.addCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY + cap),
                control1: CGPoint(x: rect.minX, y: rect.minY + cap - reach),
                control2: CGPoint(x: rect.maxX, y: rect.minY + cap - reach)
            )
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cap))
            path.addCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY - cap),
                control1: CGPoint(x: rect.maxX, y: rect.maxY - cap + reach),
                control2: CGPoint(x: rect.minX, y: rect.maxY - cap + reach)
            )
            path.closeSubpath()
        case .circle:
            path.addEllipse(in: rect)
        case .diamond:
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
        case .hexagon:
            let notch = min(rect.width * 0.25, rect.height * 0.5)
            path.move(to: CGPoint(x: rect.minX + notch, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - notch, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX - notch, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + notch, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
        case .flag:
            let notch = min(rect.width * 0.2, unit * 1.4)
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - notch, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX - notch, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }

    // MARK: - Edges

    /// One edge as a smooth run through its points, with the caps worked out
    /// and the label's box put on the middle of it.
    private static func wire(
        _ edge: Edge, through points: [CGPoint], font: NSFont, unit: CGFloat
    ) -> PlacedEdge {
        let path = CGMutablePath()
        path.move(to: points[0])
        for index in 1 ..< points.count {
            let from = points[index - 1]
            let to = points[index]
            let control1 = CGPoint(x: from.x, y: (from.y + to.y) / 2)
            let control2 = CGPoint(x: to.x, y: (from.y + to.y) / 2)
            let flat = abs(from.y - to.y) < 0.5
            path.addCurve(
                to: to,
                control1: flat ? CGPoint(x: (from.x + to.x) / 2, y: from.y) : control1,
                control2: flat ? CGPoint(x: (from.x + to.x) / 2, y: to.y) : control2
            )
        }

        let headAngle = angle(from: points[points.count - 2], to: points[points.count - 1])
        let tailAngle = angle(from: points[1], to: points[0])
        let middle = midpoint(of: points)

        var label: TextBlock?
        var labelRect = CGRect.zero
        if let text = edge.label, !text.isEmpty {
            let block = measure(text, font: font)
            label = block
            let width = block.width + unit * 0.7
            let height = block.height + unit * 0.3
            labelRect = CGRect(
                x: (middle.x - width / 2).rounded(), y: (middle.y - height / 2).rounded(),
                width: width.rounded(), height: height.rounded()
            )
        }

        return PlacedEdge(
            from: edge.from, to: edge.to, points: points, path: path, style: edge.style,
            head: edge.head, headPoint: points[points.count - 1], headAngle: headAngle,
            tail: edge.tail, tailPoint: points[0], tailAngle: tailAngle,
            label: label, labelRect: labelRect
        )
    }

    /// A node pointing at itself: a small loop off its trailing edge.
    private static func loop(
        _ edge: Edge, around node: PlacedNode, font: NSFont, unit: CGFloat
    ) -> PlacedEdge {
        let rect = node.frame
        let reach = unit * 2.2
        let start = CGPoint(x: rect.maxX, y: rect.midY - rect.height * 0.22)
        let end = CGPoint(x: rect.maxX, y: rect.midY + rect.height * 0.22)
        let path = CGMutablePath()
        path.move(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(x: rect.maxX + reach, y: start.y - reach * 0.6),
            control2: CGPoint(x: rect.maxX + reach, y: end.y + reach * 0.6)
        )
        var label: TextBlock?
        var labelRect = CGRect.zero
        if let text = edge.label, !text.isEmpty {
            let block = measure(text, font: font)
            label = block
            let width = block.width + unit * 0.7
            let height = block.height + unit * 0.3
            labelRect = CGRect(
                x: (rect.maxX + reach * 0.7).rounded(), y: (rect.midY - height / 2).rounded(),
                width: width.rounded(), height: height.rounded()
            )
        }
        return PlacedEdge(
            from: edge.from, to: edge.to, points: [start, end], path: path, style: edge.style,
            head: edge.head, headPoint: end, headAngle: .pi,
            tail: edge.tail, tailPoint: start, tailAngle: .pi,
            label: label, labelRect: labelRect
        )
    }

    private static func angle(from: CGPoint, to: CGPoint) -> CGFloat {
        atan2(to.y - from.y, to.x - from.x)
    }

    /// Halfway along the run, measured on the straight lines between the
    /// points — close enough to the curve for a label to sit on.
    private static func midpoint(of points: [CGPoint]) -> CGPoint {
        var lengths: [CGFloat] = []
        var total: CGFloat = 0
        for index in 1 ..< points.count {
            let dx = points[index].x - points[index - 1].x
            let dy = points[index].y - points[index - 1].y
            let length = sqrt(dx * dx + dy * dy)
            lengths.append(length)
            total += length
        }
        guard total > 0 else { return points[0] }
        var walked: CGFloat = 0
        for (index, length) in lengths.enumerated() {
            if walked + length >= total / 2 {
                let fraction = length > 0 ? (total / 2 - walked) / length : 0
                return CGPoint(
                    x: points[index].x + (points[index + 1].x - points[index].x) * fraction,
                    y: points[index].y + (points[index + 1].y - points[index].y) * fraction
                )
            }
            walked += length
        }
        return points[points.count - 1]
    }

    // MARK: - Subgraph frames

    private static func frame(
        _ subgraph: Subgraph, in nodes: [PlacedNode], font: NSFont, unit: CGFloat,
        into frames: inout [PlacedFrame]
    ) {
        var childFrames: [PlacedFrame] = []
        for child in subgraph.children {
            frame(child, in: nodes, font: font, unit: unit, into: &childFrames)
        }
        var bounds = CGRect.null
        for id in subgraph.nodes {
            if let node = nodes.first(where: { $0.id == id }) { bounds = bounds.union(node.frame) }
        }
        for child in childFrames { bounds = bounds.union(child.rect) }
        frames.append(contentsOf: childFrames)
        guard !bounds.isNull else { return }

        let padding = (unit * 0.9).rounded()
        let title = subgraph.title.isEmpty ? nil : measure(subgraph.title, font: font)
        let titleHeight = title.map { $0.height + unit * 0.5 } ?? 0
        let rect = CGRect(
            x: (bounds.minX - padding).rounded(),
            y: (bounds.minY - padding - titleHeight).rounded(),
            width: (bounds.width + padding * 2).rounded(),
            height: (bounds.height + padding * 2 + titleHeight).rounded()
        )
        frames.append(PlacedFrame(
            title: title, rect: rect,
            titleRect: CGRect(
                x: rect.minX, y: rect.minY + unit * 0.25,
                width: rect.width, height: titleHeight
            )
        ))
    }

    // MARK: - Drawing

    private static func draw(
        _ diagram: Diagram, in context: CGContext, palette: MermaidPalette, font: NSFont
    ) {
        let labelFont = self.labelFont(for: font)
        let unit = labelFont.pointSize
        let thin = max(1, (unit / 13).rounded())
        let bounds = CGRect(origin: .zero, size: diagram.size)

        // The frames first, so everything else stands inside them.
        for frame in diagram.frames {
            context.saveGState()
            context.setStrokeColor(resolved(palette.secondary))
            context.setLineWidth(thin)
            context.addPath(CGPath(
                roundedRect: frame.rect, cornerWidth: unit * 0.5, cornerHeight: unit * 0.5,
                transform: nil
            ))
            context.strokePath()
            context.restoreGState()
            if let title = frame.title {
                draw(title, centeredIn: frame.titleRect, color: palette.secondary, in: context)
            }
        }

        // Then the lines, with a hole punched where a label sits — every
        // label's, not each line's own. Two nodes joined both ways share one
        // corridor, and a hole cut for the "No" on the way down was drawn
        // straight through by the line on the way back up, since that line
        // knew nothing of the label it was crossing. A label is a box on the
        // page, and no line goes through it whichever line it belongs to.
        let labelHoles = diagram.edges.map(\.labelRect).filter { !$0.isEmpty }
        for edge in diagram.edges {
            context.saveGState()
            if !labelHoles.isEmpty {
                context.addRect(bounds)
                for hole in labelHoles { context.addRect(hole.insetBy(dx: -1, dy: -1)) }
                context.clip(using: .evenOdd)
            }
            context.saveGState()
            context.setStrokeColor(resolved(palette.stroke))
            context.setLineWidth(edge.style == .thick ? thin * 2.2 : thin)
            context.setLineCap(.round)
            if edge.style == .dotted {
                context.setLineDash(phase: 0, lengths: [unit * 0.35, unit * 0.35])
            }
            context.addPath(edge.path)
            context.strokePath()
            context.restoreGState()
            // The caps inside the same clip as the line they finish: an
            // arrowhead is as much a mark on the page as the line is, and
            // its base showing through a label's box reads as a line drawn
            // over the words just the same.
            cap(edge.head, at: edge.headPoint, angle: edge.headAngle,
                unit: unit, thin: thin, palette: palette, in: context)
            cap(edge.tail, at: edge.tailPoint, angle: edge.tailAngle,
                unit: unit, thin: thin, palette: palette, in: context)
            context.restoreGState()
        }

        // Then the nodes, which sit over the lines that reach them.
        for node in diagram.nodes {
            let path = self.path(of: node.shape, in: node.frame, unit: unit)
            context.saveGState()
            context.setFillColor(resolved(palette.fill))
            context.addPath(path)
            context.fillPath()
            context.setStrokeColor(resolved(palette.stroke))
            context.setLineWidth(thin)
            context.addPath(path)
            context.strokePath()
            if node.shape == .cylinder {
                let cap = cylinderCap(of: node.frame, unit: unit)
                let reach = cap * 4 / 3
                context.move(to: CGPoint(x: node.frame.minX, y: node.frame.minY + cap))
                context.addCurve(
                    to: CGPoint(x: node.frame.maxX, y: node.frame.minY + cap),
                    control1: CGPoint(x: node.frame.minX, y: node.frame.minY + cap + reach),
                    control2: CGPoint(x: node.frame.maxX, y: node.frame.minY + cap + reach)
                )
                context.setLineWidth(thin)
                context.strokePath()
            }
            if node.shape == .subroutine {
                let inset = min(unit * 0.6, node.frame.width / 4)
                context.setLineWidth(thin)
                context.move(to: CGPoint(x: node.frame.minX + inset, y: node.frame.minY))
                context.addLine(to: CGPoint(x: node.frame.minX + inset, y: node.frame.maxY))
                context.move(to: CGPoint(x: node.frame.maxX - inset, y: node.frame.minY))
                context.addLine(to: CGPoint(x: node.frame.maxX - inset, y: node.frame.maxY))
                context.strokePath()
            }
            context.restoreGState()

            var text = node.frame
            if node.shape == .cylinder {
                // Under the front cap, which is where the words go on a
                // drum seen from the side.
                let cap = cylinderCap(of: node.frame, unit: unit)
                text = CGRect(
                    x: node.frame.minX, y: node.frame.minY + cap * 2,
                    width: node.frame.width, height: node.frame.height - cap * 3
                )
            }
            draw(node.text, centeredIn: text, color: palette.text, in: context)
        }

        // The labels last, in the hole their box already cleared.
        for edge in diagram.edges {
            guard let label = edge.label, !edge.labelRect.isEmpty else { continue }
            context.saveGState()
            context.setFillColor(resolved(palette.fill))
            context.addPath(CGPath(
                roundedRect: edge.labelRect, cornerWidth: unit * 0.25, cornerHeight: unit * 0.25,
                transform: nil
            ))
            context.fillPath()
            context.restoreGState()
            draw(label, centeredIn: edge.labelRect, color: palette.text, in: context)
        }
    }

    /// An arrowhead, a cross or a circle at one end of a line.
    private static func cap(
        _ cap: EndCap, at point: CGPoint, angle: CGFloat, unit: CGFloat, thin: CGFloat,
        palette: MermaidPalette, in context: CGContext
    ) {
        guard cap != .none else { return }
        context.saveGState()
        context.setFillColor(resolved(palette.stroke))
        context.setStrokeColor(resolved(palette.stroke))
        context.setLineWidth(thin)
        let dx = cos(angle)
        let dy = sin(angle)

        switch cap {
        case .none:
            break
        case .arrow:
            let length = unit * 0.7
            let half = unit * 0.3
            let base = CGPoint(x: point.x - dx * length, y: point.y - dy * length)
            context.move(to: point)
            context.addLine(to: CGPoint(x: base.x - dy * half, y: base.y + dx * half))
            context.addLine(to: CGPoint(x: base.x + dy * half, y: base.y - dx * half))
            context.closePath()
            context.fillPath()
        case .cross:
            let arm = unit * 0.28
            let centre = CGPoint(x: point.x - dx * arm, y: point.y - dy * arm)
            context.move(to: CGPoint(x: centre.x - arm, y: centre.y - arm))
            context.addLine(to: CGPoint(x: centre.x + arm, y: centre.y + arm))
            context.move(to: CGPoint(x: centre.x + arm, y: centre.y - arm))
            context.addLine(to: CGPoint(x: centre.x - arm, y: centre.y + arm))
            context.strokePath()
        case .circle:
            let radius = unit * 0.26
            let centre = CGPoint(x: point.x - dx * radius, y: point.y - dy * radius)
            let box = CGRect(
                x: centre.x - radius, y: centre.y - radius,
                width: radius * 2, height: radius * 2
            )
            context.setFillColor(resolved(palette.fill))
            context.addEllipse(in: box)
            context.fillPath()
            context.addEllipse(in: box)
            context.strokePath()
        }
        context.restoreGState()
    }

    /// A measured block of text, centred in a box, in a flipped context.
    private static func draw(
        _ block: TextBlock, centeredIn rect: CGRect, color: NSColor, in context: CGContext
    ) {
        guard !block.lines.isEmpty else { return }
        context.saveGState()
        context.setFillColor(resolved(color))
        context.textMatrix = .identity
        var baseline = rect.midY - block.height / 2 + block.ascent
        for line in block.lines {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            context.saveGState()
            context.translateBy(x: (rect.midX - width / 2).rounded(), y: baseline.rounded())
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
            baseline += block.lineHeight
        }
        context.restoreGState()
    }

    /// The colour, resolved at draw time and nowhere earlier — the same rule
    /// the maths draws by, and what makes one laid-out diagram right in both
    /// appearances.
    private static func resolved(_ color: NSColor) -> CGColor {
        (color.usingColorSpace(.sRGB) ?? color).cgColor
    }
}
