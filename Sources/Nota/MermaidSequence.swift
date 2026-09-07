import AppKit
import CoreText

/// `sequenceDiagram`: the parser, the lane layout and the drawing.
///
/// Nota reads the grammar itself — no WebView and no dependency, the same
/// footing as the maths — so a diagram is boxes and lines: the source is read
/// into a model, the model is measured once against the render's font, and
/// the shapes draw themselves every time the appearance asks, in the palette
/// they are handed. Nothing here knows what colour it is until it is drawn.
enum MermaidSequence {

    // MARK: - The model

    /// One lifeline. `actor` draws a stick figure where `participant` draws a
    /// box; `label` is what the diagram calls it, `id` is what the messages
    /// say.
    struct Participant: Equatable {
        var id: String
        var label: String
        var isActor: Bool
    }

    /// `->` against `-->`: the line, not its end.
    enum Stroke: Equatable {
        case solid
        case dotted
    }

    /// The end of an arrow: `->` open, `->>` filled, `-x` a cross, `-)` the
    /// half arrow asynchrony has always been drawn with.
    enum Head: Equatable {
        case open
        case filled
        case cross
        case async
    }

    struct Message: Equatable {
        var from: String
        var to: String
        var text: String
        var stroke: Stroke
        var head: Head
        /// `A->>+B`: B's bar starts on this message.
        var activatesTarget: Bool
        /// `B-->>-A`: B's bar ends on this message.
        var deactivatesSource: Bool

        /// `A->>A: think` — drawn as a loop off the side of one lifeline
        /// rather than as a line between two.
        var isSelf: Bool { from == to }
    }

    enum NotePlacement: Equatable {
        case left
        case right
        case over
    }

    struct Note: Equatable {
        var placement: NotePlacement
        var participants: [String]
        var text: String
    }

    /// The frames. `rect` keeps its frame and loses its colour: the palette
    /// belongs to the appearance, not to the source.
    enum BlockKind: Equatable {
        case loop
        case alt
        case opt
        case par
        case critical
        case breaking
        case rect

        /// The word in the frame's tab.
        var keyword: String {
            switch self {
            case .loop: return "loop"
            case .alt: return "alt"
            case .opt: return "opt"
            case .par: return "par"
            case .critical: return "critical"
            case .breaking: return "break"
            case .rect: return "rect"
            }
        }
    }

    /// One arm of a block: everything up to the next `else` / `and` /
    /// `option`, under the label that arm was opened with.
    struct Section: Equatable {
        var label: String
        var items: [Item]
    }

    struct Block: Equatable {
        var kind: BlockKind
        var sections: [Section]
    }

    /// The recursion goes through the arrays, so nothing here needs to be
    /// `indirect`.
    enum Item: Equatable {
        case message(Message)
        case note(Note)
        case activate(String)
        case deactivate(String)
        case block(Block)
    }

    /// A `box … end` group of lifelines — a faint frame around their headers.
    struct Group: Equatable {
        var label: String
        var participants: [String]
    }

    struct Diagram: Equatable {
        var title: String?
        var participants: [Participant]
        var items: [Item]
        var groups: [Group]
        var autonumber: Bool
    }

    // MARK: - Reading the source

    /// One frame of the parser's stack: an open block, an open `box`, or the
    /// root everything else lands in.
    private struct Frame {
        var kind: BlockKind?
        var isGroup: Bool
        var label: String
        var mark: Int = 0
        var sections: [Section] = []
        var items: [Item] = []
    }

    private static let arrows: [(token: String, stroke: Stroke, head: Head)] = [
        ("-->>", .dotted, .filled),
        ("--x", .dotted, .cross),
        ("--)", .dotted, .async),
        ("->>", .solid, .filled),
        ("-->", .dotted, .open),
        ("->", .solid, .open),
        ("-x", .solid, .cross),
        ("-)", .solid, .async),
    ]

    /// The source read into a model, or `nil` when it does not open with
    /// `sequenceDiagram`, holds a line this grammar cannot make sense of, or
    /// leaves a block open. One pass, no backtracking: it cannot hang, and a
    /// fence it refuses stays the code block it was.
    static func parse(_ source: String) -> Diagram? {
        var participants: [Participant] = []
        var indexOf: [String: Int] = [:]
        var groups: [Group] = []
        var title: String?
        var autonumber = false
        var stack: [Frame] = [Frame(kind: nil, isGroup: false, label: "")]
        var sawHeader = false
        var skippingBraces = false

        func declare(_ id: String, label: String?, isActor: Bool) {
            if let at = indexOf[id] {
                if let label { participants[at].label = label }
                if isActor { participants[at].isActor = true }
                return
            }
            indexOf[id] = participants.count
            participants.append(Participant(id: id, label: label ?? id, isActor: isActor))
        }
        func mention(_ id: String) { declare(id, label: nil, isActor: false) }
        func append(_ item: Item) { stack[stack.count - 1].items.append(item) }

        for raw in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while line.hasSuffix(";") {
                line.removeLast()
                line = line.trimmingCharacters(in: .whitespaces)
            }
            if line.isEmpty || line.hasPrefix("%%") { continue }
            if skippingBraces {
                if line.hasSuffix("}") { skippingBraces = false }
                continue
            }
            let (head, rest) = firstWord(line)
            let word = head.lowercased()

            if !sawHeader {
                guard word == "sequencediagram" else { return nil }
                sawHeader = true
                continue
            }

            switch word {
            case "participant", "actor":
                guard let declaration = declaration(rest) else { return nil }
                declare(declaration.id, label: declaration.label, isActor: word == "actor")

            case "create":
                // `create participant X as Y`, and the bare `create X`.
                let (second, tail) = firstWord(rest)
                let isActor = second.lowercased() == "actor"
                let body = isActor || second.lowercased() == "participant" ? tail : rest
                guard let declaration = declaration(body) else { return nil }
                declare(declaration.id, label: declaration.label, isActor: isActor)

            case "destroy":
                guard !rest.isEmpty else { return nil }
                mention(rest)

            case "autonumber":
                autonumber = rest.lowercased() != "off"

            case "activate", "deactivate":
                guard !rest.isEmpty else { return nil }
                mention(rest)
                append(word == "activate" ? .activate(rest) : .deactivate(rest))

            case "note":
                guard let note = note(rest) else { return nil }
                for id in note.participants { mention(id) }
                append(.note(note))

            case "loop", "alt", "opt", "par", "critical", "break", "rect":
                let kind: BlockKind
                switch word {
                case "loop": kind = .loop
                case "alt": kind = .alt
                case "opt": kind = .opt
                case "par": kind = .par
                case "critical": kind = .critical
                case "break": kind = .breaking
                default: kind = .rect
                }
                // `rect rgb(200,150,255)` keeps its frame and drops its
                // colour: the palette is the appearance's to choose.
                stack.append(Frame(kind: kind, isGroup: false, label: kind == .rect ? "" : rest))

            case "else", "and", "option":
                guard var frame = stack.last, frame.kind != nil else { return nil }
                frame.sections.append(Section(label: frame.label, items: frame.items))
                frame.label = rest
                frame.items = []
                stack[stack.count - 1] = frame

            case "box":
                stack.append(
                    Frame(kind: nil, isGroup: true, label: rest, mark: participants.count)
                )

            case "end":
                guard stack.count > 1 else { return nil }
                let frame = stack.removeLast()
                if frame.isGroup {
                    let members = participants[min(frame.mark, participants.count)...].map(\.id)
                    if !members.isEmpty {
                        groups.append(Group(label: frame.label, participants: members))
                    }
                    for item in frame.items { append(item) }
                } else if let kind = frame.kind {
                    var sections = frame.sections
                    sections.append(Section(label: frame.label, items: frame.items))
                    append(.block(Block(kind: kind, sections: sections)))
                }

            case "title", "title:":
                title = rest

            case "link", "links", "style", "properties", "details":
                continue

            default:
                // The accessibility lines are read and kept out of the
                // picture, including `accDescr { … }` over several lines.
                if word.hasPrefix("acctitle") || word.hasPrefix("accdescr") {
                    if line.hasSuffix("{") { skippingBraces = true }
                    continue
                }
                guard let message = message(line) else { return nil }
                mention(message.from)
                mention(message.to)
                append(.message(message))
            }
        }

        guard sawHeader, stack.count == 1 else { return nil }
        return Diagram(
            title: title, participants: participants, items: stack[0].items,
            groups: groups, autonumber: autonumber
        )
    }

    /// The first whitespace-delimited word and everything after it, trimmed.
    private static func firstWord(_ line: String) -> (String, String) {
        guard let space = line.firstIndex(where: { $0.isWhitespace }) else { return (line, "") }
        return (
            String(line[..<space]),
            line[space...].trimmingCharacters(in: .whitespaces)
        )
    }

    /// `A`, or `A as Alice`.
    private static func declaration(_ rest: String) -> (id: String, label: String?)? {
        guard !rest.isEmpty else { return nil }
        guard let alias = rest.range(of: " as ", options: .caseInsensitive) else {
            return (rest, nil)
        }
        let id = rest[..<alias.lowerBound].trimmingCharacters(in: .whitespaces)
        let label = rest[alias.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !label.isEmpty else { return nil }
        return (id, label)
    }

    /// `left of A: text`, `right of A: text`, `over A: text`, `over A,B: text`.
    private static func note(_ rest: String) -> Note? {
        let lowered = rest.lowercased()
        let placement: NotePlacement
        let body: Substring
        if lowered.hasPrefix("left of ") {
            placement = .left
            body = rest.dropFirst(8)
        } else if lowered.hasPrefix("right of ") {
            placement = .right
            body = rest.dropFirst(9)
        } else if lowered.hasPrefix("over ") {
            placement = .over
            body = rest.dropFirst(5)
        } else {
            return nil
        }
        guard let colon = body.firstIndex(of: ":") else { return nil }
        let names = body[..<colon]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !names.isEmpty, !names.contains(where: \.isEmpty) else { return nil }
        let text = breaks(
            body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        )
        return Note(placement: placement, participants: names, text: text)
    }

    /// `A->>+B: text` and its seven siblings.
    private static func message(_ line: String) -> Message? {
        guard let arrow = arrow(in: line) else { return nil }
        var from = line[..<arrow.range.lowerBound].trimmingCharacters(in: .whitespaces)
        // `<<->>` is the two-headed form; it is drawn as its right-hand half.
        if from.hasSuffix("<<") { from.removeLast(2) }
        if from.hasSuffix("<") { from.removeLast() }
        from = from.trimmingCharacters(in: .whitespaces)

        var tail = line[arrow.range.upperBound...].drop(while: \.isWhitespace)
        var activates = false
        var deactivates = false
        if tail.first == "+" {
            activates = true
            tail = tail.dropFirst()
        } else if tail.first == "-" {
            deactivates = true
            tail = tail.dropFirst()
        }
        let to: String
        var text = ""
        if let colon = tail.firstIndex(of: ":") {
            to = tail[..<colon].trimmingCharacters(in: .whitespaces)
            text = breaks(tail[tail.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        } else {
            to = tail.trimmingCharacters(in: .whitespaces)
        }
        guard !from.isEmpty, !to.isEmpty else { return nil }
        return Message(
            from: from, to: to, text: text, stroke: arrow.stroke, head: arrow.head,
            activatesTarget: activates, deactivatesSource: deactivates
        )
    }

    /// The leftmost arrow in the line, longest form first, so `-->>` is never
    /// read as `-->`.
    private static func arrow(
        in line: String
    ) -> (range: Range<String.Index>, stroke: Stroke, head: Head)? {
        var index = line.startIndex
        while index < line.endIndex {
            let tail = line[index...]
            for arrow in arrows where tail.hasPrefix(arrow.token) {
                return (
                    index..<line.index(index, offsetBy: arrow.token.count),
                    arrow.stroke, arrow.head
                )
            }
            index = line.index(after: index)
        }
        return nil
    }

    /// Mermaid's own line break inside a label.
    private static func breaks(_ text: String) -> String {
        var result = text
        for token in ["<br />", "<br/>", "<br>"] {
            result = result.replacingOccurrences(of: token, with: "\n", options: .caseInsensitive)
        }
        return result
    }

    // MARK: - The one door

    /// The diagram laid out against the render's font, or `nil` when the
    /// source cannot be read or has no lifeline to draw.
    static func layout(_ source: String, font: NSFont) -> MermaidDiagram? {
        guard let diagram = parse(source), !diagram.participants.isEmpty else { return nil }
        return Drawing(diagram, font: font)
    }

    /// The face the labels are set in: the render's own size a step down, in
    /// the system family unless the note is being read in a monospaced one —
    /// the rule the maths follows, so a diagram belongs to its page.
    static func labelFont(for font: NSFont) -> NSFont {
        let size = max(font.pointSize * 0.9, 6)
        if font.isFixedPitch {
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return NSFont.systemFont(ofSize: size)
    }
}

// MARK: - The layout

extension MermaidSequence {

    /// A `sequenceDiagram` measured against a font: lifelines across the top,
    /// rows down the page, and every shape a closure that is handed its
    /// colour at draw time — so one layout draws itself in light and in dark.
    ///
    /// Everything is laid out in its own coordinates first and moved into the
    /// box afterwards, which is what lets a note hang off the left of the
    /// first lifeline without anyone having to guess a margin for it.
    final class Drawing: MermaidDiagram {

        /// A lifeline and where it stands. In declaration order, left to
        /// right.
        struct Column: Equatable {
            let id: String
            let label: String
            let x: CGFloat
        }

        /// A message as it was drawn: the ends of its line and the height it
        /// was drawn at. `text` is the label as it is painted, so an
        /// autonumbered diagram carries its number here. `y` grows down the
        /// page in the order the messages were written.
        struct Arrow: Equatable {
            let from: String
            let to: String
            let text: String
            let fromX: CGFloat
            let toX: CGFloat
            let y: CGFloat
            let isSelf: Bool
        }

        typealias Element = (CGContext, MermaidPalette) -> Void

        let source: Diagram
        let size: CGSize
        let columns: [Column]
        let arrows: [Arrow]
        let notes: [CGRect]
        let frames: [CGRect]
        let activations: [CGRect]

        private let elements: [Element]

        // MARK: Measuring

        /// Every distance the layout uses, taken off the label font, so the
        /// diagram grows with Settings rather than with a table of constants.
        struct Metrics {
            let font: NSFont
            let em: CGFloat
            let ascent: CGFloat
            let lineHeight: CGFloat

            init(font: NSFont) {
                self.font = font
                em = font.pointSize
                ascent = font.ascender
                lineHeight = max(font.ascender - font.descender, font.pointSize)
            }

            var barWidth: CGFloat { em * 0.6 }
            var margin: CGFloat { em * 0.7 }
            var loopWidth: CGFloat { em * 2.4 }
            var headLength: CGFloat { em * 0.55 }
            var headWidth: CGFloat { em * 0.3 }
            var corner: CGFloat { em * 0.3 }
        }

        /// One measured line of text. Only the width comes out of it — the
        /// heights are the font's, so every row in the diagram sits on the
        /// same rhythm.
        struct Text {
            let line: CTLine
            let width: CGFloat
        }

        /// A label: one line, or several where `<br/>` broke it.
        struct Label {
            let lines: [Text]
            let width: CGFloat
            let height: CGFloat
        }

        static func measure(_ text: String, font: NSFont) -> Text {
            // `kCTForegroundColorFromContext`: the line takes the fill colour
            // set at draw time, so a label is the palette's text colour and
            // not CoreText's default black in the dark.
            let string = NSAttributedString(string: text, attributes: [
                .font: font,
                kCTForegroundColorFromContextAttributeName as NSAttributedString.Key: true,
            ])
            let line = CTLineCreateWithAttributedString(string)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            return Text(line: line, width: width)
        }

        static func label(_ text: String, metrics: Metrics) -> Label {
            let pieces = text.isEmpty ? [] : text.components(separatedBy: "\n")
            let lines = pieces.map { measure($0, font: metrics.font) }
            return Label(
                lines: lines,
                width: lines.map(\.width).max() ?? 0,
                height: CGFloat(lines.count) * metrics.lineHeight
            )
        }

        // MARK: The events the layout walks

        /// The tree flattened into the order it is drawn in, with the block
        /// frames turned into the marks that open, divide and close them.
        enum Event {
            case message(message: Message, label: String)
            case note(Note)
            case activate(String)
            case deactivate(String)
            case blockStart(kind: BlockKind, label: String, span: [String])
            case divider(label: String)
            case blockEnd
        }

        static func events(_ items: [Item], autonumber: Bool, number: inout Int) -> [Event] {
            var result: [Event] = []
            for item in items {
                switch item {
                case .message(let message):
                    number += 1
                    let text: String
                    if !autonumber {
                        text = message.text
                    } else if message.text.isEmpty {
                        text = "\(number)."
                    } else {
                        text = "\(number). \(message.text)"
                    }
                    result.append(.message(message: message, label: text))
                case .note(let note):
                    result.append(.note(note))
                case .activate(let id):
                    result.append(.activate(id))
                case .deactivate(let id):
                    result.append(.deactivate(id))
                case .block(let block):
                    var span: [String] = []
                    for section in block.sections { mentioned(section.items, into: &span) }
                    result.append(
                        .blockStart(
                            kind: block.kind, label: block.sections.first?.label ?? "", span: span
                        )
                    )
                    for (position, section) in block.sections.enumerated() {
                        if position > 0 { result.append(.divider(label: section.label)) }
                        result += events(section.items, autonumber: autonumber, number: &number)
                    }
                    result.append(.blockEnd)
                }
            }
            return result
        }

        /// Which lifelines a block reaches, so its frame is drawn around
        /// those and not around the whole page.
        static func mentioned(_ items: [Item], into ids: inout [String]) {
            func add(_ id: String) { if !ids.contains(id) { ids.append(id) } }
            for item in items {
                switch item {
                case .message(let message):
                    add(message.from)
                    add(message.to)
                case .note(let note):
                    note.participants.forEach(add)
                case .activate(let id), .deactivate(let id):
                    add(id)
                case .block(let block):
                    for section in block.sections { mentioned(section.items, into: &ids) }
                }
            }
        }

        // MARK: The header band

        private struct Header {
            let label: Label
            let width: CGFloat
            let height: CGFloat
            let isActor: Bool
        }

        private let offset: CGPoint

        // MARK: Laying it out

        init(_ diagram: Diagram, font: NSFont) {
            source = diagram
            let metrics = Metrics(font: MermaidSequence.labelFont(for: font))
            let em = metrics.em
            let people = diagram.participants
            let count = people.count
            var indexOf: [String: Int] = [:]
            for (position, person) in people.enumerated() { indexOf[person.id] = position }

            // The header band: a box the width of its name, or a figure with
            // its name under it. Every header ends at the same line, so all
            // the lifelines start together.
            var headers: [Header] = []
            for person in people {
                let text = Drawing.label(person.label, metrics: metrics)
                let height = max(text.height, metrics.lineHeight)
                if person.isActor {
                    headers.append(Header(
                        label: text, width: max(text.width + em * 0.6, em * 2.6),
                        height: em * 1.5 + em * 0.3 + height, isActor: true
                    ))
                } else {
                    headers.append(Header(
                        label: text, width: max(text.width + em * 1.2, em * 3.2),
                        height: height + em * 0.8, isActor: false
                    ))
                }
            }
            let headerHeight = headers.map(\.height).max() ?? metrics.lineHeight

            // The tree, flattened into the order it is drawn in, and every
            // label measured once.
            var number = 0
            let events = Drawing.events(
                diagram.items, autonumber: diagram.autonumber, number: &number
            )
            var texts: [Label] = []
            for event in events {
                switch event {
                case .message(_, let label): texts.append(Drawing.label(label, metrics: metrics))
                case .note(let note): texts.append(Drawing.label(note.text, metrics: metrics))
                case .blockStart(_, let label, _), .divider(let label):
                    texts.append(Drawing.label(label, metrics: metrics))
                default: texts.append(Drawing.label("", metrics: metrics))
                }
            }

            // How far apart the lifelines stand: far enough for the two
            // headers, and far enough for every label written between them.
            var gaps = [CGFloat](repeating: 0, count: max(count - 1, 0))
            for index in gaps.indices {
                gaps[index] = headers[index].width / 2 + headers[index + 1].width / 2 + em * 1.6
            }
            var spans: [(from: Int, to: Int, need: CGFloat)] = []
            for (position, event) in events.enumerated() {
                let width = texts[position].width
                switch event {
                case .message(let message, _):
                    guard let a = indexOf[message.from], let b = indexOf[message.to] else { break }
                    if a == b {
                        // A loop off the right of the lifeline, and its label
                        // beyond that, must not reach the next one.
                        if a < count - 1 {
                            gaps[a] = max(gaps[a], metrics.loopWidth + width + em * 1.4)
                        }
                    } else {
                        spans.append((min(a, b), max(a, b), width + em * 1.8))
                    }
                case .note(let note):
                    let columns = note.participants.compactMap { indexOf[$0] }.sorted()
                    guard let first = columns.first, let last = columns.last else { break }
                    let box = width + em * 1.4
                    switch note.placement {
                    case .over:
                        // A note over one lifeline may overhang it; one over
                        // two has to reach across.
                        if first != last { spans.append((first, last, box - em * 2)) }
                    case .left:
                        if first > 0 { gaps[first - 1] = max(gaps[first - 1], box + em * 0.8) }
                    case .right:
                        if last < count - 1 { gaps[last] = max(gaps[last], box + em * 0.8) }
                    }
                default:
                    break
                }
            }
            // The short spans first, so widening one of them cannot undo a
            // wider requirement that was already met.
            for span in spans.sorted(by: { $0.to - $0.from < $1.to - $1.from }) {
                let current = gaps[span.from..<span.to].reduce(0, +)
                guard current < span.need else { continue }
                let extra = (span.need - current) / CGFloat(span.to - span.from)
                for index in span.from..<span.to { gaps[index] += extra }
            }
            var centres: [CGFloat] = [0]
            for gap in gaps { centres.append(centres[centres.count - 1] + gap) }

            // MARK: The rows

            var backdrop: [Element] = []
            var barElements: [Element] = []
            var body: [Element] = []
            var bounds = CGRect.null
            func grow(_ rect: CGRect) { bounds = bounds.union(rect.standardized) }

            func leftEdge(_ column: Int, active: Int) -> CGFloat {
                active > 0 ? centres[column] - metrics.barWidth / 2 : centres[column]
            }
            func rightEdge(_ column: Int, active: Int) -> CGFloat {
                guard active > 0 else { return centres[column] }
                return centres[column] + metrics.barWidth / 2
                    + CGFloat(active - 1) * metrics.barWidth * 0.5
            }
            func barRect(_ column: Int, depth: Int, from top: CGFloat, to bottom: CGFloat) -> CGRect {
                CGRect(
                    x: centres[column] - metrics.barWidth / 2
                        + CGFloat(depth) * metrics.barWidth * 0.5,
                    y: top, width: metrics.barWidth,
                    height: max(bottom - top, metrics.barWidth)
                )
            }

            var laidOutArrows: [Arrow] = []
            var noteRects: [CGRect] = []
            var frameRects: [CGRect] = []
            var barRects: [CGRect] = []
            var stacks: [String: [CGFloat]] = [:]
            var open: [
                (kind: BlockKind, label: Label, top: CGFloat, left: CGFloat, right: CGFloat,
                 dividers: [(CGFloat, Label)])
            ] = []
            var y = headerHeight + em * 1.1

            for (position, event) in events.enumerated() {
                let text = texts[position]
                let labelHeight = max(text.height, metrics.lineHeight)
                switch event {

                case .message(let message, let drawn):
                    guard let a = indexOf[message.from], let b = indexOf[message.to] else { break }
                    let dash: [CGFloat] = message.stroke == .dotted ? [em * 0.32, em * 0.26] : []
                    let head = message.head

                    if a == b {
                        let top = y + em * 0.45
                        let bottom = top + em * 1.15
                        if message.activatesTarget { stacks[message.to, default: []].append(top) }
                        let active = stacks[message.from]?.count ?? 0
                        let x0 = rightEdge(a, active: active)
                        let x1 = x0 + metrics.loopWidth
                        let labelTop = (top + bottom) / 2 - labelHeight / 2
                        let labelX = x1 + em * 0.45
                        if message.deactivatesSource, let start = stacks[message.from]?.popLast() {
                            barRects.append(barRect(
                                a, depth: stacks[message.from]?.count ?? 0, from: start, to: bottom
                            ))
                        }
                        let block = text
                        body.append { context, palette in
                            Drawing.line(
                                [
                                    CGPoint(x: x0, y: top), CGPoint(x: x1, y: top),
                                    CGPoint(x: x1, y: bottom), CGPoint(x: x0, y: bottom),
                                ],
                                color: palette.stroke, dash: dash, in: context
                            )
                            Drawing.head(
                                head, at: CGPoint(x: x0, y: bottom), direction: -1,
                                metrics: metrics, color: palette.stroke, in: context
                            )
                            Drawing.draw(
                                block, at: CGPoint(x: labelX, y: labelTop), width: nil,
                                metrics: metrics, color: palette.text, in: context
                            )
                        }
                        grow(CGRect(x: x0, y: top, width: metrics.loopWidth, height: bottom - top))
                        grow(CGRect(
                            x: labelX, y: labelTop, width: text.width, height: labelHeight
                        ))
                        laidOutArrows.append(Arrow(
                            from: message.from, to: message.to, text: drawn,
                            fromX: x0, toX: x1, y: top, isSelf: true
                        ))
                        y = max(bottom + em * 0.75, labelTop + labelHeight + em * 0.5)
                        break
                    }

                    let labelTop = y + em * 0.15
                    let lineY = labelTop + labelHeight + em * 0.4
                    if message.activatesTarget { stacks[message.to, default: []].append(lineY) }
                    let rightwards = a < b
                    let fromActive = stacks[message.from]?.count ?? 0
                    let toActive = stacks[message.to]?.count ?? 0
                    let start = rightwards
                        ? rightEdge(a, active: fromActive) : leftEdge(a, active: fromActive)
                    let end = rightwards
                        ? leftEdge(b, active: toActive) : rightEdge(b, active: toActive)
                    if message.deactivatesSource, let began = stacks[message.from]?.popLast() {
                        barRects.append(barRect(
                            a, depth: stacks[message.from]?.count ?? 0, from: began, to: lineY
                        ))
                    }
                    let direction: CGFloat = rightwards ? 1 : -1
                    let tip = end - direction * (head == .cross ? metrics.headWidth : 0)
                    let stop = end - direction * (head == .cross ? metrics.headWidth * 2 : 0)
                    let labelX = min(start, end)
                    let labelWidth = abs(end - start)
                    let block = text
                    body.append { context, palette in
                        Drawing.line(
                            [CGPoint(x: start, y: lineY), CGPoint(x: stop, y: lineY)],
                            color: palette.stroke, dash: dash, in: context
                        )
                        Drawing.head(
                            head, at: CGPoint(x: tip, y: lineY), direction: direction,
                            metrics: metrics, color: palette.stroke, in: context
                        )
                        Drawing.draw(
                            block, at: CGPoint(x: labelX, y: labelTop), width: labelWidth,
                            metrics: metrics, color: palette.text, in: context
                        )
                    }
                    grow(CGRect(
                        x: labelX - metrics.headLength, y: lineY - 1,
                        width: labelWidth + metrics.headLength * 2, height: 2
                    ))
                    grow(CGRect(
                        x: labelX + (labelWidth - text.width) / 2, y: labelTop,
                        width: text.width, height: labelHeight
                    ))
                    laidOutArrows.append(Arrow(
                        from: message.from, to: message.to, text: drawn,
                        fromX: start, toX: end, y: lineY, isSelf: false
                    ))
                    y = lineY + em * 0.7

                case .note(let note):
                    let columns = note.participants.compactMap { indexOf[$0] }.sorted()
                    guard let first = columns.first, let last = columns.last else { break }
                    let width = text.width + em * 1.4
                    let height = labelHeight + em * 0.7
                    let top = y + em * 0.3
                    let rect: CGRect
                    switch note.placement {
                    case .over:
                        let middle = (centres[first] + centres[last]) / 2
                        let span = max(width, centres[last] - centres[first] + em * 1.8)
                        rect = CGRect(x: middle - span / 2, y: top, width: span, height: height)
                    case .left:
                        rect = CGRect(
                            x: centres[first] - em * 0.8 - width, y: top,
                            width: width, height: height
                        )
                    case .right:
                        rect = CGRect(
                            x: centres[first] + em * 0.8, y: top, width: width, height: height
                        )
                    }
                    let block = text
                    let corner = metrics.corner
                    body.append { context, palette in
                        Drawing.box(
                            rect, radius: corner, fill: palette.accent,
                            stroke: palette.secondary, in: context
                        )
                        Drawing.draw(
                            block, at: CGPoint(x: rect.minX, y: rect.midY - block.height / 2),
                            width: rect.width, metrics: metrics, color: palette.text, in: context
                        )
                    }
                    grow(rect)
                    noteRects.append(rect)
                    y = rect.maxY + em * 0.7

                case .activate(let id):
                    stacks[id, default: []].append(y + em * 0.2)

                case .deactivate(let id):
                    guard let column = indexOf[id], let began = stacks[id]?.popLast() else { break }
                    barRects.append(barRect(
                        column, depth: stacks[id]?.count ?? 0, from: began, to: y + em * 0.2
                    ))

                case .blockStart(let kind, _, let span):
                    let columns = span.compactMap { indexOf[$0] }
                    let first = columns.min() ?? 0
                    let last = columns.max() ?? max(count - 1, 0)
                    // A nested frame is drawn inside the one it sits in, even
                    // when the two reach the same lifelines.
                    let inset = CGFloat(open.count) * em * 0.4
                    let left = centres[first] - headers[first].width / 2 - em * 0.5 + inset
                    let right = centres[last] + headers[last].width / 2 + em * 0.5 - inset
                    open.append((
                        kind: kind, label: text, top: y, left: left,
                        right: max(right, left + em * 4), dividers: []
                    ))
                    y += max(labelHeight, metrics.lineHeight + em * 0.35) + em * 0.5

                case .divider:
                    guard !open.isEmpty else { break }
                    let line = y + em * 0.25
                    open[open.count - 1].dividers.append((line, text))
                    y = line + labelHeight + em * 0.5

                case .blockEnd:
                    guard let frame = open.popLast() else { break }
                    let bottom = y + em * 0.35
                    let rect = CGRect(
                        x: frame.left, y: frame.top,
                        width: frame.right - frame.left, height: bottom - frame.top
                    )
                    let keyword = Drawing.label(frame.kind.keyword, metrics: metrics)
                    let label = frame.label
                    let dividers = frame.dividers
                    let tab = CGRect(
                        x: rect.minX, y: rect.minY,
                        width: keyword.width + em * 0.7,
                        height: metrics.lineHeight + em * 0.3
                    )
                    let corner = metrics.corner
                    let dash: [CGFloat] = [em * 0.3, em * 0.24]
                    body.append { context, palette in
                        Drawing.box(
                            rect, radius: corner, fill: nil, stroke: palette.secondary,
                            in: context
                        )
                        Drawing.box(
                            tab, radius: corner * 0.6, fill: palette.fill,
                            stroke: palette.secondary, in: context
                        )
                        Drawing.draw(
                            keyword, at: CGPoint(x: tab.minX, y: tab.midY - keyword.height / 2),
                            width: tab.width, metrics: metrics, color: palette.text, in: context
                        )
                        Drawing.draw(
                            label,
                            at: CGPoint(x: tab.maxX + em * 0.7, y: tab.midY - label.height / 2),
                            width: nil, metrics: metrics, color: palette.text, in: context
                        )
                        for (at, divider) in dividers {
                            Drawing.line(
                                [CGPoint(x: rect.minX, y: at), CGPoint(x: rect.maxX, y: at)],
                                color: palette.secondary, dash: dash, in: context
                            )
                            Drawing.draw(
                                divider, at: CGPoint(x: rect.minX + em * 0.6, y: at + em * 0.15),
                                width: nil, metrics: metrics, color: palette.text, in: context
                            )
                        }
                    }
                    grow(rect)
                    grow(CGRect(
                        x: tab.maxX + em * 0.7, y: tab.minY, width: label.width, height: tab.height
                    ))
                    frameRects.append(rect)
                    y = bottom + em * 0.85
                }
            }

            // Bars nobody closed run to the foot of the diagram.
            for person in people {
                guard let column = indexOf[person.id], let starts = stacks[person.id] else {
                    continue
                }
                for (depth, began) in starts.enumerated() {
                    barRects.append(barRect(column, depth: depth, from: began, to: y + em * 0.2))
                }
            }
            for rect in barRects {
                let corner = min(metrics.corner * 0.5, rect.width / 2)
                barElements.append { context, palette in
                    Drawing.box(
                        rect, radius: corner, fill: palette.fill, stroke: palette.stroke,
                        in: context
                    )
                }
                grow(rect)
            }

            // MARK: The band at the top, its mirror at the foot, the lifelines

            let footTop = y + em * 0.6
            func header(_ column: Int, top: CGFloat) {
                let header = headers[column]
                let centre = centres[column]
                let label = header.label
                let width = header.width
                if header.isActor {
                    let labelTop = top + em * 1.5 + em * 0.3
                    backdrop.append { context, palette in
                        Drawing.actor(
                            at: centre, top: top, metrics: metrics, color: palette.stroke,
                            in: context
                        )
                        Drawing.draw(
                            label, at: CGPoint(x: centre - width / 2, y: labelTop), width: width,
                            metrics: metrics, color: palette.text, in: context
                        )
                    }
                    grow(CGRect(x: centre - width / 2, y: top, width: width, height: header.height))
                    return
                }
                let rect = CGRect(
                    x: centre - width / 2, y: top, width: width, height: header.height
                )
                let corner = metrics.corner
                backdrop.append { context, palette in
                    Drawing.box(
                        rect, radius: corner, fill: palette.fill, stroke: palette.stroke,
                        in: context
                    )
                    Drawing.draw(
                        label, at: CGPoint(x: rect.minX, y: rect.midY - label.height / 2),
                        width: rect.width, metrics: metrics, color: palette.text, in: context
                    )
                }
                grow(rect)
            }

            // A `box … end` group, behind the headers it gathers.
            for group in diagram.groups {
                let columns = group.participants.compactMap { indexOf[$0] }
                guard let first = columns.min(), let last = columns.max() else { continue }
                let label = Drawing.label(group.label, metrics: metrics)
                let top = -(label.height + em * 0.5)
                let rect = CGRect(
                    x: centres[first] - headers[first].width / 2 - em * 0.4, y: top,
                    width: centres[last] + headers[last].width / 2 + em * 0.4
                        - (centres[first] - headers[first].width / 2 - em * 0.4),
                    height: headerHeight - top + em * 0.35
                )
                let corner = metrics.corner
                backdrop.append { context, palette in
                    Drawing.box(
                        rect, radius: corner, fill: nil, stroke: palette.secondary, in: context
                    )
                    Drawing.draw(
                        label, at: CGPoint(x: rect.minX + em * 0.5, y: top + em * 0.25),
                        width: nil, metrics: metrics, color: palette.text, in: context
                    )
                }
                grow(rect)
            }

            for column in 0..<count {
                header(column, top: headerHeight - headers[column].height)
                header(column, top: footTop)
                let x = centres[column]
                let dash: [CGFloat] = [em * 0.35, em * 0.35]
                backdrop.append { context, palette in
                    Drawing.line(
                        [CGPoint(x: x, y: headerHeight), CGPoint(x: x, y: footTop)],
                        color: palette.secondary, dash: dash, in: context
                    )
                }
                grow(CGRect(x: x - 0.5, y: 0, width: 1, height: footTop + headerHeight))
            }

            // MARK: Into the box

            let box = bounds.isNull ? CGRect(x: 0, y: 0, width: em, height: em) : bounds
            let shift = CGPoint(x: metrics.margin - box.minX, y: metrics.margin - box.minY)
            offset = shift
            size = CGSize(
                width: max(box.width + metrics.margin * 2, 1).rounded(.up),
                height: max(box.height + metrics.margin * 2, 1).rounded(.up)
            )
            elements = backdrop + barElements + body
            columns = people.enumerated().map { position, person in
                Column(id: person.id, label: person.label, x: centres[position] + shift.x)
            }
            arrows = laidOutArrows.map {
                Arrow(
                    from: $0.from, to: $0.to, text: $0.text,
                    fromX: $0.fromX + shift.x, toX: $0.toX + shift.x, y: $0.y + shift.y,
                    isSelf: $0.isSelf
                )
            }
            notes = noteRects.map { $0.offsetBy(dx: shift.x, dy: shift.y) }
            frames = frameRects.map { $0.offsetBy(dx: shift.x, dy: shift.y) }
            activations = barRects.map { $0.offsetBy(dx: shift.x, dy: shift.y) }
        }

        // MARK: Drawing

        func draw(in context: CGContext, palette: MermaidPalette) {
            context.saveGState()
            context.translateBy(x: offset.x, y: offset.y)
            for element in elements { element(context, palette) }
            context.restoreGState()
        }

        static func line(
            _ points: [CGPoint], color: NSColor, width: CGFloat = 1, dash: [CGFloat] = [],
            in context: CGContext
        ) {
            guard points.count > 1 else { return }
            context.saveGState()
            context.setStrokeColor(resolved(color))
            context.setLineWidth(width)
            context.setLineJoin(.miter)
            context.setLineDash(phase: 0, lengths: dash)
            context.beginPath()
            context.move(to: points[0])
            for point in points.dropFirst() { context.addLine(to: point) }
            context.strokePath()
            context.restoreGState()
        }

        static func box(
            _ rect: CGRect, radius: CGFloat, fill: NSColor?, stroke: NSColor?,
            dash: [CGFloat] = [], in context: CGContext
        ) {
            let rect = rect.standardized
            guard rect.width > 0, rect.height > 0 else { return }
            let corner = max(min(radius, min(rect.width, rect.height) / 2), 0)
            let path = CGPath(
                roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil
            )
            context.saveGState()
            context.setLineDash(phase: 0, lengths: dash)
            if let fill {
                context.setFillColor(resolved(fill))
                context.addPath(path)
                context.fillPath()
            }
            if let stroke {
                context.setStrokeColor(resolved(stroke))
                context.setLineWidth(1)
                context.addPath(path)
                context.strokePath()
            }
            context.restoreGState()
        }

        /// The end of an arrow, pointing along `direction` (+1 right, -1
        /// left). `-)` takes the half arrow asynchrony is drawn with, which is
        /// what keeps it apart from `->`'s open one.
        static func head(
            _ kind: Head, at point: CGPoint, direction: CGFloat, metrics: Metrics,
            color: NSColor, in context: CGContext
        ) {
            let length = metrics.headLength * direction
            let half = metrics.headWidth
            switch kind {
            case .filled:
                context.saveGState()
                context.setFillColor(resolved(color))
                context.beginPath()
                context.move(to: point)
                context.addLine(to: CGPoint(x: point.x - length, y: point.y - half))
                context.addLine(to: CGPoint(x: point.x - length, y: point.y + half))
                context.closePath()
                context.fillPath()
                context.restoreGState()
            case .open:
                line(
                    [
                        CGPoint(x: point.x - length, y: point.y - half), point,
                        CGPoint(x: point.x - length, y: point.y + half),
                    ],
                    color: color, in: context
                )
            case .async:
                line(
                    [CGPoint(x: point.x - length * 1.3, y: point.y - half), point],
                    color: color, in: context
                )
            case .cross:
                let arm = metrics.headWidth
                line(
                    [
                        CGPoint(x: point.x - arm, y: point.y - arm),
                        CGPoint(x: point.x + arm, y: point.y + arm),
                    ],
                    color: color, in: context
                )
                line(
                    [
                        CGPoint(x: point.x - arm, y: point.y + arm),
                        CGPoint(x: point.x + arm, y: point.y - arm),
                    ],
                    color: color, in: context
                )
            }
        }

        /// The stick figure an `actor` gets instead of a box.
        static func actor(
            at centre: CGFloat, top: CGFloat, metrics: Metrics, color: NSColor,
            in context: CGContext
        ) {
            let em = metrics.em
            let radius = em * 0.3
            let head = CGPoint(x: centre, y: top + radius + 1)
            context.saveGState()
            context.setStrokeColor(resolved(color))
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [])
            context.beginPath()
            context.addEllipse(in: CGRect(
                x: head.x - radius, y: head.y - radius, width: radius * 2, height: radius * 2
            ))
            context.strokePath()
            context.restoreGState()
            let shoulder = head.y + radius
            let hip = top + em * 1.05
            line(
                [CGPoint(x: centre, y: shoulder), CGPoint(x: centre, y: hip)],
                color: color, in: context
            )
            let arms = shoulder + em * 0.18
            line(
                [
                    CGPoint(x: centre - em * 0.42, y: arms),
                    CGPoint(x: centre + em * 0.42, y: arms),
                ],
                color: color, in: context
            )
            line(
                [
                    CGPoint(x: centre - em * 0.34, y: top + em * 1.5),
                    CGPoint(x: centre, y: hip),
                    CGPoint(x: centre + em * 0.34, y: top + em * 1.5),
                ],
                color: color, in: context
            )
        }

        /// A label with its block's top-left at `origin`, centred on `width`
        /// when one is given. The colour is set on the context rather than in
        /// the string, which is what keeps it out of the layout.
        static func draw(
            _ label: Label, at origin: CGPoint, width: CGFloat?, metrics: Metrics,
            color: NSColor, in context: CGContext
        ) {
            var y = origin.y
            for text in label.lines {
                let x = width.map { origin.x + ($0 - text.width) / 2 } ?? origin.x
                draw(text.line, at: CGPoint(x: x, y: y + metrics.ascent), color: color, in: context)
                y += metrics.lineHeight
            }
        }

        static func draw(
            _ line: CTLine, at point: CGPoint, color: NSColor, in context: CGContext
        ) {
            context.saveGState()
            context.setFillColor(resolved(color))
            context.textMatrix = .identity
            context.translateBy(x: point.x, y: point.y)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
        }

        /// The colour resolved here and nowhere earlier: `labelColor` is a
        /// different colour in light and in dark, and this is the moment the
        /// drawing finds out which one it is in.
        static func resolved(_ color: NSColor) -> CGColor {
            (color.usingColorSpace(.sRGB) ?? color).cgColor
        }
    }
}
