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
