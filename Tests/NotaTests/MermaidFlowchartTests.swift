import AppKit
import CoreText
import XCTest
@testable import Nota

/// The flowchart engine on its own: the grammar it reads, the graph it builds
/// out of it, the boxes that graph turns into, and the promise that no fence
/// anybody can type makes it fall over.
final class MermaidFlowchartTests: XCTestCase {

    private let font = NSFont.systemFont(ofSize: 13)

    private func graph(_ source: String, file: StaticString = #filePath, line: UInt = #line)
        throws -> MermaidFlowchart.Graph {
        try XCTUnwrap(MermaidFlowchart.parse(source), "did not parse", file: file, line: line)
    }

    private func diagram(_ source: String, file: StaticString = #filePath, line: UInt = #line)
        throws -> MermaidFlowchart.Diagram {
        let laid = MermaidFlowchart.layout(source, font: font)
        return try XCTUnwrap(
            laid as? MermaidFlowchart.Diagram, "did not lay out", file: file, line: line
        )
    }

    private func shape(of source: String) throws -> MermaidFlowchart.NodeShape {
        let parsed = try graph("flowchart TD\n" + source)
        return try XCTUnwrap(parsed.nodes.first).shape
    }

    // MARK: - The header

    func testTheHeaderNamesTheGrammarAndTheDirection() throws {
        XCTAssertEqual(try graph("flowchart TD\nA-->B").direction, .down)
        XCTAssertEqual(try graph("flowchart TB\nA-->B").direction, .down)
        XCTAssertEqual(try graph("flowchart BT\nA-->B").direction, .up)
        XCTAssertEqual(try graph("flowchart LR\nA-->B").direction, .right)
        XCTAssertEqual(try graph("flowchart RL\nA-->B").direction, .left)
        XCTAssertEqual(try graph("graph LR\nA-->B").direction, .right)
        XCTAssertEqual(try graph("graph\nA-->B").direction, .down, "no direction reads as TD")
    }

    func testAHeaderInAnotherGrammarIsNotAFlowchart() {
        XCTAssertNil(MermaidFlowchart.parse("sequenceDiagram\nA->>B: hi"))
        XCTAssertNil(MermaidFlowchart.parse("gantt\ntitle A"))
        XCTAssertNil(MermaidFlowchart.parse("flowchart SIDEWAYS\nA-->B"))
    }

    // MARK: - Node shapes

    func testEveryBracketPairIsItsOwnShape() throws {
        XCTAssertEqual(try shape(of: "A"), .rectangle)
        XCTAssertEqual(try shape(of: "A[text]"), .rectangle)
        XCTAssertEqual(try shape(of: "A(text)"), .rounded)
        XCTAssertEqual(try shape(of: "A([text])"), .stadium)
        XCTAssertEqual(try shape(of: "A[[text]]"), .subroutine)
        XCTAssertEqual(try shape(of: "A[(text)]"), .cylinder)
        XCTAssertEqual(try shape(of: "A((text))"), .circle)
        XCTAssertEqual(try shape(of: "A{text}"), .diamond)
        XCTAssertEqual(try shape(of: "A{{text}}"), .hexagon)
        XCTAssertEqual(try shape(of: "A>text]"), .flag)
    }

    func testABareIdIsARectangleLabelledWithItself() throws {
        let parsed = try graph("flowchart TD\nA --> B")
        XCTAssertEqual(parsed.nodes.map(\.id), ["A", "B"])
        XCTAssertEqual(parsed.nodes.map(\.label), ["A", "B"])
        XCTAssertEqual(parsed.nodes.map(\.shape), [.rectangle, .rectangle])
    }

    func testAQuotedLabelKeepsItsBrackets() throws {
        let parsed = try graph("flowchart TD\nA[\"text with [brackets]\"] --> B")
        XCTAssertEqual(parsed.node("A")?.label, "text with [brackets]")
    }

    func testABreakTagIsALineBreakInALabel() throws {
        let parsed = try graph("flowchart TD\nA[first<br>second<br/>third] --> B")
        XCTAssertEqual(parsed.node("A")?.label, "first\nsecond\nthird")
    }

    func testANodeKeepsTheShapeAndLabelItWasFirstGiven() throws {
        let parsed = try graph("""
        flowchart TD
        A{Decide} --> B
        A[Something else] --> C
        """)
        XCTAssertEqual(parsed.node("A")?.shape, .diamond)
        XCTAssertEqual(parsed.node("A")?.label, "Decide")
    }

    func testAnEdgeOnlyMentionIsUpgradedByTheDeclarationThatFollowsIt() throws {
        let parsed = try graph("""
        flowchart TD
        A --> B
        B([Done])
        """)
        XCTAssertEqual(parsed.node("B")?.shape, .stadium)
        XCTAssertEqual(parsed.node("B")?.label, "Done")
    }

    // MARK: - Edges

    private func edge(_ statement: String) throws -> MermaidFlowchart.Edge {
        let parsed = try graph("flowchart TD\n" + statement)
        return try XCTUnwrap(parsed.edges.first)
    }

    func testEveryLineStyleAndEndCap() throws {
        var link = try edge("A --> B")
        XCTAssertEqual(link.style, .solid)
        XCTAssertEqual(link.head, .arrow)
        XCTAssertEqual(link.tail, .none)

        link = try edge("A --- B")
        XCTAssertEqual(link.style, .solid)
        XCTAssertEqual(link.head, .none)

        link = try edge("A -.-> B")
        XCTAssertEqual(link.style, .dotted)
        XCTAssertEqual(link.head, .arrow)

        link = try edge("A -.- B")
        XCTAssertEqual(link.style, .dotted)
        XCTAssertEqual(link.head, .none)

        link = try edge("A ==> B")
        XCTAssertEqual(link.style, .thick)
        XCTAssertEqual(link.head, .arrow)

        link = try edge("A === B")
        XCTAssertEqual(link.style, .thick)
        XCTAssertEqual(link.head, .none)

        link = try edge("A --x B")
        XCTAssertEqual(link.head, .cross)

        link = try edge("A --o B")
        XCTAssertEqual(link.head, .circle)

        link = try edge("A <--> B")
        XCTAssertEqual(link.head, .arrow)
        XCTAssertEqual(link.tail, .arrow, "an arrow at both ends")
    }

    func testEveryFormOfEdgeLabel() throws {
        XCTAssertEqual(try edge("A -- yes --> B").label, "yes")
        XCTAssertEqual(try edge("A -- yes --- B").label, "yes")
        XCTAssertEqual(try edge("A -. maybe .-> B").label, "maybe")
        XCTAssertEqual(try edge("A == no ==> B").label, "no")
        XCTAssertEqual(try edge("A -->|straight through| B").label, "straight through")
        XCTAssertEqual(try edge("A -. 3.5 sec .-> B").label, "3.5 sec",
                       "a dot inside the words is not the one that closes it")
        XCTAssertNil(try edge("A --> B").label)
    }

    func testALabelledEdgeKeepsItsStyleAndHead() throws {
        let dotted = try edge("A -. later .-> B")
        XCTAssertEqual(dotted.style, .dotted)
        XCTAssertEqual(dotted.head, .arrow)
        let thick = try edge("A == heavy ==> B")
        XCTAssertEqual(thick.style, .thick)
        XCTAssertEqual(thick.head, .arrow)
    }

    func testAChainOfDashesIsAChainOfLinksNotOneLabelledLink() throws {
        let parsed = try graph("flowchart TD\nA --- B --- C")
        XCTAssertEqual(parsed.nodes.map(\.id), ["A", "B", "C"])
        XCTAssertEqual(parsed.edges.count, 2)
        XCTAssertEqual(parsed.edges.map(\.label), [nil, nil])
    }

    func testAChainMakesOneEdgePerStep() throws {
        let parsed = try graph("flowchart TD\nA --> B --> C --> D")
        XCTAssertEqual(parsed.edges.map { "\($0.from)\($0.to)" }, ["AB", "BC", "CD"])
    }

    func testAFanOnEitherSideMakesEveryPairing() throws {
        XCTAssertEqual(
            try graph("flowchart TD\nA & B --> C").edges.map { "\($0.from)\($0.to)" },
            ["AC", "BC"]
        )
        XCTAssertEqual(
            try graph("flowchart TD\nA --> B & C").edges.map { "\($0.from)\($0.to)" },
            ["AB", "AC"]
        )
        XCTAssertEqual(
            try graph("flowchart TD\nA & B --> C & D").edges.map { "\($0.from)\($0.to)" },
            ["AC", "AD", "BC", "BD"]
        )
    }

    func testALongerArrowIsTheSameArrow() throws {
        XCTAssertEqual(try edge("A ----> B").head, .arrow)
        XCTAssertEqual(try edge("A ----> B").style, .solid)
        XCTAssertEqual(try edge("A ====> B").style, .thick)
    }

    // MARK: - Subgraphs

    func testASubgraphHoldsTheNodesDeclaredInsideIt() throws {
        let parsed = try graph("""
        flowchart TD
        A --> B
        subgraph one [The first]
        B --> C
        end
        C --> D
        """)
        XCTAssertEqual(parsed.subgraphs.count, 1)
        XCTAssertEqual(parsed.subgraphs.first?.id, "one")
        XCTAssertEqual(parsed.subgraphs.first?.title, "The first")
        XCTAssertEqual(parsed.subgraphs.first?.nodes, ["C"], "A and B were named before it opened")
    }

    func testASubgraphWithNoBracketsIsTitledByItsName() throws {
        let parsed = try graph("""
        flowchart LR
        subgraph Backend
        A --> B
        end
        """)
        XCTAssertEqual(parsed.subgraphs.first?.title, "Backend")
        XCTAssertEqual(parsed.subgraphs.first?.nodes, ["A", "B"])
    }

    func testSubgraphsNest() throws {
        let parsed = try graph("""
        flowchart TD
        subgraph outer [Outer]
        A --> B
        subgraph inner [Inner]
        C --> D
        end
        end
        """)
        XCTAssertEqual(parsed.subgraphs.count, 1)
        XCTAssertEqual(parsed.subgraphs.first?.nodes, ["A", "B"])
        XCTAssertEqual(parsed.subgraphs.first?.children.count, 1)
        XCTAssertEqual(parsed.subgraphs.first?.children.first?.title, "Inner")
        XCTAssertEqual(parsed.subgraphs.first?.children.first?.nodes, ["C", "D"])
    }

    func testASubgraphThatIsNeverClosedIsNotAFlowchart() {
        XCTAssertNil(MermaidFlowchart.parse("flowchart TD\nsubgraph one\nA --> B"))
    }

    // MARK: - Punctuation and directives

    func testCommentsAndSemicolonsAreReadAndDropped() throws {
        let parsed = try graph("""
        %% the whole diagram
        flowchart TD;
        A[Start] --> B; B --> C %% and this
        %% nothing here
        """)
        XCTAssertEqual(parsed.nodes.map(\.id), ["A", "B", "C"])
        XCTAssertEqual(parsed.edges.count, 2)
    }

    func testStylingDirectivesAreParsedAndIgnored() throws {
        let parsed = try graph("""
        flowchart TD
        A:::warm --> B
        classDef warm fill:#f96,stroke:#333
        class A warm
        style B fill:#eee
        click A "https://example.com" "a tooltip"
        linkStyle 0 stroke:#f00
        """)
        XCTAssertEqual(parsed.nodes.map(\.id), ["A", "B"])
        XCTAssertEqual(parsed.edges.count, 1)
    }

    func testJunkIsNotAFlowchart() {
        let refusals = [
            "",
            "hello world",
            "flowchart TD\nhello world here",
            "flowchart TD\nA[unclosed --> B",
            "flowchart TD\nA -->",
            "flowchart TD\n--> B",
            "flowchart TD\nA ??? B",
            "flowchart TD",
        ]
        for source in refusals {
            XCTAssertNil(MermaidFlowchart.parse(source), source.debugDescription)
        }
    }

    func testNoFenceEverCrashesTheParser() {
        let alphabet = Array("AB[]{}()<>-=.|&;\n \"%:*#\\/x o,")
        var seed: UInt64 = 0x5eed
        func next() -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(alphabet.count))
        }
        for _ in 0 ..< 400 {
            var source = "flowchart TD\n"
            for _ in 0 ..< 60 { source.append(alphabet[next()]) }
            _ = MermaidFlowchart.parse(source)
            _ = MermaidFlowchart.layout(source, font: font)
        }
        for _ in 0 ..< 200 {
            var source = ""
            for _ in 0 ..< 40 { source.append(alphabet[next()]) }
            _ = MermaidFlowchart.parse(source)
        }
    }

    // MARK: - Layout

    func testEveryNodeGetsAFrameAndNoTwoOverlap() throws {
        let laid = try diagram("""
        flowchart TD
        A[Start] --> B{Choose}
        B -- yes --> C[Ship it]
        B -- no --> D[Think again]
        D --> A
        C --> E([Done])
        """)
        XCTAssertEqual(laid.nodes.count, 5)
        for node in laid.nodes {
            XCTAssertGreaterThan(node.frame.width, 0, node.id)
            XCTAssertGreaterThan(node.frame.height, 0, node.id)
        }
        for (index, node) in laid.nodes.enumerated() {
            for other in laid.nodes[(index + 1)...] {
                XCTAssertFalse(
                    node.frame.intersects(other.frame),
                    "\(node.id) and \(other.id) sit on top of each other"
                )
            }
        }
    }

    func testTheSizeCoversEveryFrame() throws {
        let laid = try diagram("""
        flowchart LR
        subgraph one [Service]
        A --> B
        end
        B -- calls --> C[(Store)]
        C --> A
        """)
        let box = CGRect(origin: .zero, size: laid.size)
        for node in laid.nodes {
            XCTAssertTrue(box.contains(node.frame), "\(node.id) is outside the diagram")
        }
        for frame in laid.frames {
            XCTAssertTrue(box.contains(frame.rect), "a subgraph frame is outside the diagram")
        }
        for edge in laid.edges {
            XCTAssertTrue(
                box.insetBy(dx: -1, dy: -1).contains(edge.path.boundingBoxOfPath),
                "\(edge.from)→\(edge.to) is outside the diagram"
            )
        }
    }

    func testTheDirectionSaysWhichWayTheRanksRun() throws {
        let down = try diagram("flowchart TD\nA --> B")
        let a = try XCTUnwrap(down.node("A"))
        let b = try XCTUnwrap(down.node("B"))
        XCTAssertGreaterThan(b.frame.minY, a.frame.maxY, "TD puts B below A")

        let right = try diagram("flowchart LR\nA --> B")
        let left = try XCTUnwrap(right.node("A"))
        let far = try XCTUnwrap(right.node("B"))
        XCTAssertGreaterThan(far.frame.minX, left.frame.maxX, "LR puts B right of A")

        let up = try diagram("flowchart BT\nA --> B")
        XCTAssertLessThan(
            try XCTUnwrap(up.node("B")).frame.maxY, try XCTUnwrap(up.node("A")).frame.minY,
            "BT puts B above A"
        )

        let backwards = try diagram("flowchart RL\nA --> B")
        XCTAssertLessThan(
            try XCTUnwrap(backwards.node("B")).frame.maxX,
            try XCTUnwrap(backwards.node("A")).frame.minX,
            "RL puts B left of A"
        )
    }

    func testAnEdgeRunsFromOneNodesBorderToTheOthers() throws {
        let laid = try diagram("flowchart TD\nA[Start] --> B{Choose}\nB --> C")
        XCTAssertEqual(laid.edges.map { "\($0.from)\($0.to)" }, ["AB", "BC"])
        for edge in laid.edges {
            let from = try XCTUnwrap(laid.node(edge.from))
            let to = try XCTUnwrap(laid.node(edge.to))
            XCTAssertTrue(
                from.frame.insetBy(dx: -1, dy: -1).contains(edge.tailPoint),
                "\(edge.from)→\(edge.to) does not start on \(edge.from)"
            )
            XCTAssertTrue(
                to.frame.insetBy(dx: -1, dy: -1).contains(edge.headPoint),
                "\(edge.from)→\(edge.to) does not end on \(edge.to)"
            )
        }
    }

    func testALabelledEdgeCarriesItsBoxOnTheLine() throws {
        let laid = try diagram("flowchart TD\nA --> B\nB -- yes --> C")
        let plain = try XCTUnwrap(laid.edges.first { $0.to == "B" })
        XCTAssertTrue(plain.labelRect.isEmpty, "no label, no box")
        let labelled = try XCTUnwrap(laid.edges.first { $0.to == "C" })
        XCTAssertFalse(labelled.labelRect.isEmpty)
        XCTAssertTrue(
            labelled.path.boundingBoxOfPath.insetBy(dx: -2, dy: -2)
                .intersects(labelled.labelRect),
            "the box sits on the line it belongs to"
        )
    }

    /// The size the layout measures its spacings in.
    private var unit: CGFloat { MermaidFlowchart.labelFont(for: font).pointSize }

    /// The line an edge draws, walked at half a point a step, so a box can be
    /// asked whether the line goes through it rather than whether the line's
    /// bounding box does — a diagonal run's box is most of the page.
    private func trail(of path: CGPath) -> [CGPoint] {
        var walked: [CGPoint] = []
        var cursor = CGPoint.zero
        let steps = 400

        func line(to end: CGPoint) {
            for step in 1 ... steps {
                let along = CGFloat(step) / CGFloat(steps)
                walked.append(CGPoint(
                    x: cursor.x + (end.x - cursor.x) * along,
                    y: cursor.y + (end.y - cursor.y) * along
                ))
            }
        }

        func curve(_ first: CGPoint, _ second: CGPoint, to end: CGPoint) {
            let from = cursor
            for step in 1 ... steps {
                let along = CGFloat(step) / CGFloat(steps)
                let rest = 1 - along
                let a = rest * rest * rest
                let b = 3 * rest * rest * along
                let c = 3 * rest * along * along
                let d = along * along * along
                walked.append(CGPoint(
                    x: a * from.x + b * first.x + c * second.x + d * end.x,
                    y: a * from.y + b * first.y + c * second.y + d * end.y
                ))
            }
        }

        path.applyWithBlock { element in
            let points = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint:
                cursor = points[0]
                walked.append(cursor)
            case .addLineToPoint:
                line(to: points[0])
                cursor = points[0]
            case .addCurveToPoint:
                curve(points[0], points[1], to: points[2])
                cursor = points[2]
            case .addQuadCurveToPoint:
                line(to: points[1])
                cursor = points[1]
            case .closeSubpath:
                break
            @unknown default:
                break
            }
        }
        return walked
    }

    func testTwoNodesJoinedBothWaysGetALineEach() throws {
        let down = try diagram("flowchart TD\nA[Note] --> B[Queue]\nB --> A")
        let there = try XCTUnwrap(down.edges.first { $0.from == "A" })
        let back = try XCTUnwrap(down.edges.first { $0.from == "B" })
        for one in there.points {
            for other in back.points {
                XCTAssertGreaterThanOrEqual(
                    abs(one.x - other.x), unit * 0.6,
                    "the two lines share a corridor going down"
                )
            }
        }
        // And each one still leaves and lands on a border.
        for edge in down.edges {
            let from = try XCTUnwrap(down.node(edge.from))
            let to = try XCTUnwrap(down.node(edge.to))
            XCTAssertTrue(
                from.frame.insetBy(dx: -1, dy: -1).contains(edge.tailPoint),
                "\(edge.from)→\(edge.to) does not start on \(edge.from)"
            )
            XCTAssertTrue(
                to.frame.insetBy(dx: -1, dy: -1).contains(edge.headPoint),
                "\(edge.from)→\(edge.to) does not end on \(edge.to)"
            )
        }

        let across = try diagram("flowchart LR\nA{Online?} --> B((Hold))\nB --> A")
        let out = try XCTUnwrap(across.edges.first { $0.from == "A" })
        let home = try XCTUnwrap(across.edges.first { $0.from == "B" })
        for one in out.points {
            for other in home.points {
                XCTAssertGreaterThanOrEqual(
                    abs(one.y - other.y), unit * 0.6,
                    "the two lines share a corridor going across"
                )
            }
        }
        for edge in across.edges {
            let from = try XCTUnwrap(across.node(edge.from))
            let to = try XCTUnwrap(across.node(edge.to))
            XCTAssertTrue(
                from.frame.insetBy(dx: -1, dy: -1).contains(edge.tailPoint),
                "a diamond's border point moved sideways is off the diamond"
            )
            XCTAssertTrue(
                to.frame.insetBy(dx: -1, dy: -1).contains(edge.headPoint),
                "a circle's border point moved sideways is off the circle"
            )
        }
    }

    func testTwoEdgesTheSameWayRoundEachCarryTheirOwnWords() throws {
        let laid = try diagram("flowchart TD\nA[Queue change] -->|one| B[Merge]\nA -->|two| B")
        XCTAssertEqual(laid.edges.count, 2)
        let first = laid.edges[0]
        let second = laid.edges[1]
        XCTAssertFalse(
            first.labelRect.intersects(second.labelRect), "the two labels sit on top of each other"
        )
        XCTAssertTrue(
            first.path.boundingBoxOfPath.insetBy(dx: -2, dy: -2).intersects(first.labelRect),
            "the first box sits on its own line"
        )
        XCTAssertTrue(
            second.path.boundingBoxOfPath.insetBy(dx: -2, dy: -2).intersects(second.labelRect),
            "the second box sits on its own line"
        )
        XCTAssertFalse(
            second.path.boundingBoxOfPath.intersects(first.labelRect),
            "the first box reaches onto the second line"
        )
        XCTAssertFalse(
            first.path.boundingBoxOfPath.intersects(second.labelRect),
            "the second box reaches onto the first line"
        )
    }

    func testTheQueueChartKeepsItsWordsOffEveryOtherLine() throws {
        let laid = try diagram("""
        flowchart TD
          A[Note edited locally] --> B[Queue change]
          B --> C{Online?}
          C -->|Yes| D[Push to sync service]
          C -->|No| E[Hold in local queue]
          D --> F[Merge on server]
          E --> C
        """)
        XCTAssertEqual(laid.edges.filter { !$0.labelRect.isEmpty }.count, 2)
        for edge in laid.edges where !edge.labelRect.isEmpty {
            let box = edge.labelRect
            XCTAssertTrue(
                trail(of: edge.path).contains { box.contains($0) },
                "\(edge.from)→\(edge.to) does not carry its box on its line"
            )
            for other in laid.edges where other.from != edge.from || other.to != edge.to {
                XCTAssertFalse(
                    trail(of: other.path).contains { box.insetBy(dx: -1, dy: -1).contains($0) },
                    "\(other.from)→\(other.to) runs through \(edge.from)→\(edge.to)'s words"
                )
            }
        }
    }

    func testASubgraphFrameEnclosesWhatItHolds() throws {
        let laid = try diagram("""
        flowchart LR
        A --> B
        subgraph one [Inside]
        C --> D
        end
        B --> C
        """)
        XCTAssertEqual(laid.frames.count, 1)
        let frame = try XCTUnwrap(laid.frames.first)
        for id in ["C", "D"] {
            XCTAssertTrue(
                frame.rect.contains(try XCTUnwrap(laid.node(id)).frame),
                "\(id) should be inside the frame"
            )
        }
        XCTAssertFalse(
            frame.rect.contains(try XCTUnwrap(laid.node("A")).frame),
            "A is not in the subgraph"
        )
        XCTAssertNotNil(frame.title)
    }

    func testACycleStillLaysOut() throws {
        let laid = try diagram("flowchart TD\nA --> B\nB --> C\nC --> A")
        XCTAssertEqual(laid.nodes.count, 3)
        XCTAssertEqual(laid.edges.count, 3)
        XCTAssertGreaterThan(laid.size.width, 0)
        XCTAssertGreaterThan(laid.size.height, 0)
    }

    func testANodePointingAtItselfIsALoop() throws {
        let laid = try diagram("flowchart TD\nA --> A\nA --> B")
        let loop = try XCTUnwrap(laid.edges.first { $0.from == "A" && $0.to == "A" })
        let node = try XCTUnwrap(laid.node("A"))
        XCTAssertGreaterThan(
            loop.path.boundingBoxOfPath.maxX, node.frame.maxX,
            "the loop stands clear of the node"
        )
    }

    func testALargerFontMakesALargerDiagram() throws {
        let small = try XCTUnwrap(
            MermaidFlowchart.layout("flowchart TD\nA[Start] --> B[End]", font: font)
        )
        let large = try XCTUnwrap(MermaidFlowchart.layout(
            "flowchart TD\nA[Start] --> B[End]", font: NSFont.systemFont(ofSize: 26)
        ))
        XCTAssertGreaterThan(large.size.width, small.size.width)
        XCTAssertGreaterThan(large.size.height, small.size.height)
    }

    // MARK: - Drawing

    /// Draws into a bitmap and counts the pixels that came out of it.
    private func inkedPixels(of diagram: MermaidDiagram) throws -> Int {
        let width = Int(diagram.size.width.rounded(.up))
        let height = Int(diagram.size.height.rounded(.up))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // The diagram draws in a flipped context, the one the render hands it.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        diagram.draw(in: context, palette: .standard)

        let data = try XCTUnwrap(context.data)
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var inked = 0
        for index in stride(from: 3, to: width * height * 4, by: 4)
        where pixels[index] > 0 { inked += 1 }
        return inked
    }

    /// The pixels inside one edge's label box, so two drawings can be asked
    /// whether anything else was drawn through it.
    private func pixels(in rect: CGRect, of diagram: MermaidDiagram) throws -> [UInt8] {
        let width = Int(diagram.size.width.rounded(.up))
        let height = Int(diagram.size.height.rounded(.up))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        diagram.draw(in: context, palette: .standard)
        let data = try XCTUnwrap(context.data)
        let all = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var out: [UInt8] = []
        // The bitmap is drawn flipped, so a row of the diagram is a row of
        // the bitmap counted from the top.
        for y in Int(rect.minY) ..< Int(rect.maxY.rounded(.up)) where y >= 0 && y < height {
            for x in Int(rect.minX) ..< Int(rect.maxX.rounded(.up)) where x >= 0 && x < width {
                out.append(all[(y * width + x) * 4 + 3])
            }
        }
        return out
    }

    func testALineComingBackTheOtherWayDoesNotRunThroughALabel() throws {
        // C and E are joined both ways, so the two lines share one corridor
        // and the "No" sits on it. The line coming back up must leave the
        // label's box exactly as the line going down left it.
        let oneWay = try diagram("""
        flowchart TD
        C{Online?} -->|No| E[Hold in local queue]
        """)
        let bothWays = try diagram("""
        flowchart TD
        C{Online?} -->|No| E[Hold in local queue]
        E --> C
        """)
        let label = try XCTUnwrap(bothWays.edges.first { !$0.labelRect.isEmpty }).labelRect
        let alone = try XCTUnwrap(oneWay.edges.first { !$0.labelRect.isEmpty }).labelRect
        XCTAssertEqual(label.size, alone.size)
        XCTAssertEqual(
            try pixels(in: label, of: bothWays), try pixels(in: alone, of: oneWay),
            "the return line drew through the label's box"
        )
        XCTAssertGreaterThan(
            try inkedPixels(of: bothWays), try inkedPixels(of: oneWay),
            "the return line is still drawn everywhere else"
        )
    }

    func testDrawingAFlowchartLeavesInkOnThePage() throws {
        let laid = try diagram("""
        flowchart TD
        A[Start] --> B{Ready?}
        B -- yes --> C([Ship])
        B -- no --> D[(Wait)]
        D -.-> A
        """)
        XCTAssertGreaterThan(try inkedPixels(of: laid), 500)
    }

    func testEveryShapeAndEveryStyleDrawsWithoutFalling() throws {
        let laid = try diagram("""
        flowchart LR
        A[rect] --> B(round)
        B --> C([stadium])
        C --> D[[sub]]
        D --> E[(store)]
        E --> F((circle))
        F --> G{choice}
        G --> H{{hex}}
        H --> I>flag]
        I === J[thick]
        J -.-> K[dotted]
        K --x L[cross]
        L --o M[circle cap]
        M <--> A
        """)
        XCTAssertEqual(laid.nodes.count, 13)
        XCTAssertGreaterThan(try inkedPixels(of: laid), 500)
    }

    func testASubgraphDrawsWithoutFalling() throws {
        let laid = try diagram("""
        flowchart LR
        A[Client] --> B
        subgraph server [The server]
        B[API] --> C[(Database)]
        end
        C -- rows --> A
        """)
        XCTAssertGreaterThan(try inkedPixels(of: laid), 500)
    }
}
