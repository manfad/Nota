import AppKit
import XCTest
@testable import Nota

/// `sequenceDiagram` fences, read and drawn by Nota itself.
///
/// No WebView and no dependency, so a diagram is a model and a set of boxes:
/// these tests hold both ends of that — what the parser makes of the grammar,
/// and where the layout puts what it read — plus the promise a live preview
/// depends on most, that nothing anyone can type in a fence makes it crash,
/// hang or come back blank.
final class MermaidSequenceTests: XCTestCase {

    private let font = NSFont.systemFont(ofSize: 13)
    /// The label font's size: every distance in the layout is a multiple of it.
    private var em: CGFloat { MermaidSequence.labelFont(for: font).pointSize }

    private func parse(_ source: String) -> MermaidSequence.Diagram? {
        MermaidSequence.parse(source)
    }

    private func parsed(_ source: String) throws -> MermaidSequence.Diagram {
        try XCTUnwrap(MermaidSequence.parse(source), "should read as a sequence diagram")
    }

    private func drawn(_ source: String) throws -> MermaidSequence.Drawing {
        try XCTUnwrap(
            MermaidSequence.layout(source, font: font) as? MermaidSequence.Drawing,
            "should lay out"
        )
    }

    /// Every message in the diagram, in the order it was written, whatever
    /// block it sits inside.
    private func messages(_ items: [MermaidSequence.Item]) -> [MermaidSequence.Message] {
        items.flatMap { item -> [MermaidSequence.Message] in
            switch item {
            case .message(let message): return [message]
            case .block(let block): return block.sections.flatMap { messages($0.items) }
            default: return []
            }
        }
    }

    private func notes(_ items: [MermaidSequence.Item]) -> [MermaidSequence.Note] {
        items.compactMap { if case .note(let note) = $0 { return note } else { return nil } }
    }

    private func blocks(_ items: [MermaidSequence.Item]) -> [MermaidSequence.Block] {
        items.compactMap { if case .block(let block) = $0 { return block } else { return nil } }
    }

    // MARK: - The grammar

    func testEveryArrowFormKeepsItsLineAndItsHead() throws {
        let diagram = try parsed("""
        sequenceDiagram
            A->B: one
            A-->B: two
            A->>B: three
            A-->>B: four
            A-xB: five
            A--xB: six
            A-)B: seven
            A--)B: eight
        """)
        let read = messages(diagram.items)
        XCTAssertEqual(read.map(\.text), [
            "one", "two", "three", "four", "five", "six", "seven", "eight",
        ])
        XCTAssertEqual(read.map(\.stroke), [
            .solid, .dotted, .solid, .dotted, .solid, .dotted, .solid, .dotted,
        ])
        XCTAssertEqual(read.map(\.head), [
            .open, .open, .filled, .filled, .cross, .cross, .async, .async,
        ])
        for message in read {
            XCTAssertEqual(message.from, "A")
            XCTAssertEqual(message.to, "B")
        }
    }

    func testAMessageWithoutTextIsStillAMessage() throws {
        let diagram = try parsed("sequenceDiagram\nAlice->>Bob:")
        XCTAssertEqual(messages(diagram.items).map(\.text), [""])
    }

    func testAnAliasNamesTheLifelineAndTheIdStillAddressesIt() throws {
        let diagram = try parsed("""
        sequenceDiagram
            participant A as Alice Liddell
            participant B
            A->>B: hello
        """)
        XCTAssertEqual(diagram.participants.map(\.id), ["A", "B"])
        XCTAssertEqual(diagram.participants.map(\.label), ["Alice Liddell", "B"])
        XCTAssertEqual(messages(diagram.items).first?.from, "A")
    }

    func testAnActorIsAParticipantThatDrawsAFigure() throws {
        let diagram = try parsed("""
        sequenceDiagram
            actor U as Reader
            participant S as Server
            U->>S: GET
        """)
        XCTAssertEqual(diagram.participants.map(\.isActor), [true, false])
        XCTAssertEqual(diagram.participants.first?.label, "Reader")
    }

    func testParticipantsFirstSeenInAMessageKeepTheOrderTheyAppearedIn() throws {
        let diagram = try parsed("""
        sequenceDiagram
            participant B
            C->>A: first
            A->>B: second
            D->>C: third
        """)
        XCTAssertEqual(diagram.participants.map(\.id), ["B", "C", "A", "D"])
        XCTAssertTrue(diagram.participants.allSatisfy { $0.label == $0.id })
    }

    func testTheActivationSuffixesAndTheExplicitWordsBothCount() throws {
        let diagram = try parsed("""
        sequenceDiagram
            Alice->>+John: hello
            activate Bob
            John-->>-Alice: hi back
            deactivate Bob
        """)
        let read = messages(diagram.items)
        XCTAssertEqual(read[0].to, "John")
        XCTAssertTrue(read[0].activatesTarget)
        XCTAssertFalse(read[0].deactivatesSource)
        XCTAssertEqual(read[1].to, "Alice")
        XCTAssertTrue(read[1].deactivatesSource)
        XCTAssertFalse(read[1].activatesTarget)
        XCTAssertEqual(diagram.items[1], .activate("Bob"))
        XCTAssertEqual(diagram.items[3], .deactivate("Bob"))
    }

    func testASelfMessageNamesTheSameLifelineTwice() throws {
        let diagram = try parsed("sequenceDiagram\nA->>A: think")
        let message = try XCTUnwrap(messages(diagram.items).first)
        XCTAssertTrue(message.isSelf)
        XCTAssertEqual(diagram.participants.count, 1)
    }

    func testANoteTakesEveryPlacementAndBreaksOnBr() throws {
        let diagram = try parsed("""
        sequenceDiagram
            participant A
            participant B
            Note left of A: to the left
            Note right of B: to the right
            Note over A: over one
            Note over A,B: over<br/>two
        """)
        let read = notes(diagram.items)
        XCTAssertEqual(read.map(\.placement), [.left, .right, .over, .over])
        XCTAssertEqual(read.map(\.participants), [["A"], ["B"], ["A"], ["A", "B"]])
        XCTAssertEqual(read[3].text, "over\ntwo")
    }

    func testANoteIntroducesTheLifelineItIsWrittenOver() throws {
        let diagram = try parsed("sequenceDiagram\nNote over Alice,Bob: pausing")
        XCTAssertEqual(diagram.participants.map(\.id), ["Alice", "Bob"])
    }

    func testEveryBlockKeepsItsKeywordItsLabelAndItsArms() throws {
        let diagram = try parsed("""
        sequenceDiagram
            loop every minute
                A->>B: tick
            end
            alt is up
                A->>B: yes
            else is down
                A->>B: no
            end
            opt maybe
                A->>B: perhaps
            end
            par first
                A->>B: one
            and second
                A->>B: two
            end
            critical connect
                A->>B: try
            option fails
                A->>B: shrug
            end
            break too much
                A->>B: stop
            end
            rect rgb(200, 150, 255)
                A->>B: tinted
            end
        """)
        let read = blocks(diagram.items)
        XCTAssertEqual(read.map(\.kind), [
            .loop, .alt, .opt, .par, .critical, .breaking, .rect,
        ])
        XCTAssertEqual(read[0].sections.map(\.label), ["every minute"])
        XCTAssertEqual(read[1].sections.map(\.label), ["is up", "is down"])
        XCTAssertEqual(read[3].sections.map(\.label), ["first", "second"])
        XCTAssertEqual(read[4].sections.map(\.label), ["connect", "fails"])
        // The rect keeps its frame and drops its colour.
        XCTAssertEqual(read[6].sections.map(\.label), [""])
        XCTAssertEqual(messages(read[1].sections[1].items).map(\.text), ["no"])
    }

    func testBlocksNest() throws {
        let diagram = try parsed("""
        sequenceDiagram
            loop outer
                alt inner
                    A->>B: x
                else other
                    A->>B: y
                end
                A->>B: after
            end
        """)
        let outer = try XCTUnwrap(blocks(diagram.items).first)
        XCTAssertEqual(outer.kind, .loop)
        let inner = try XCTUnwrap(blocks(outer.sections[0].items).first)
        XCTAssertEqual(inner.kind, .alt)
        XCTAssertEqual(inner.sections.map(\.label), ["inner", "other"])
        XCTAssertEqual(messages(diagram.items).map(\.text), ["x", "y", "after"])
    }

    func testAutonumberIsRememberedAndNumbersTheLabels() throws {
        XCTAssertEqual(parse("sequenceDiagram\nautonumber\nA->>B: x")?.autonumber, true)
        XCTAssertEqual(parse("sequenceDiagram\nA->>B: x")?.autonumber, false)
        XCTAssertEqual(parse("sequenceDiagram\nautonumber off\nA->>B: x")?.autonumber, false)

        let drawing = try drawn("""
        sequenceDiagram
            autonumber
            A->>B: first
            loop twice
                B->>A: second
            end
        """)
        XCTAssertEqual(drawing.arrows.map(\.text), ["1. first", "2. second"])
    }

    func testCommentsBlankLinesAndTheLinesWeIgnoreNeverStopIt() throws {
        let diagram = try parsed("""
        sequenceDiagram
        %% who talks to whom
            title The handshake
            accTitle: a handshake

            accDescr: two machines agree

            autonumber
            link A: Dashboard @ https://example.com
            links B: {"repo": "https://example.com"}
            box Backend
                participant A
                participant B
            end
            A->>B: syn ;
        """)
        XCTAssertEqual(diagram.title, "The handshake")
        XCTAssertTrue(diagram.autonumber)
        XCTAssertEqual(diagram.participants.map(\.id), ["A", "B"])
        XCTAssertEqual(diagram.groups.map(\.label), ["Backend"])
        XCTAssertEqual(diagram.groups.first?.participants, ["A", "B"])
        XCTAssertEqual(messages(diagram.items).map(\.text), ["syn"])
    }

    func testAMultilineAccessibilityDescriptionIsSwallowedWhole() throws {
        let diagram = try parsed("""
        sequenceDiagram
            accDescr {
                Alice greets Bob.
                Bob greets back.
            }
            A->>B: hi
        """)
        XCTAssertEqual(messages(diagram.items).map(\.text), ["hi"])
    }

    // MARK: - What comes back nil

    func testSourceThatCannotBeReadComesBackNil() {
        XCTAssertNil(parse(""), "nothing at all")
        XCTAssertNil(parse("flowchart TD\n A-->B"), "another grammar")
        XCTAssertNil(parse("sequenceDiagram\n    hello there"), "a sentence")
        XCTAssertNil(parse("sequenceDiagram\n    Note sideways of A: x"), "no such placement")
        XCTAssertNil(parse("sequenceDiagram\n    Note over A no colon"))
        XCTAssertNil(parse("sequenceDiagram\n    end"), "an end with nothing open")
        XCTAssertNil(parse("sequenceDiagram\n    else nope"), "an arm with no block")
        XCTAssertNil(parse("sequenceDiagram\n    loop forever\n    A->>B: x"), "left open")
        XCTAssertNil(parse("sequenceDiagram\n    ->>B: x"), "no sender")
        XCTAssertNil(parse("sequenceDiagram\n    A->>: x"), "no target")
        XCTAssertNil(parse("sequenceDiagram\n    participant"), "nobody named")
        XCTAssertNil(parse("sequenceDiagram\n    activate"))
        // Read, but with nothing to draw.
        XCTAssertNil(MermaidSequence.layout("sequenceDiagram", font: font))
        XCTAssertNil(MermaidSequence.layout("classDiagram\n A <|-- B", font: font))
    }

    func testNothingAnyoneCanTypeMakesItCrash() {
        var generator = Rolling(seed: 20_260_907)
        let alphabet = Array("ABab-<>+()xX:,%\n \t{}/\\\"'.—→")
        for _ in 0..<300 {
            var source = "sequenceDiagram\n"
            for _ in 0..<Int.random(in: 1...80, using: &generator) {
                source.append(alphabet[Int.random(in: 0..<alphabet.count, using: &generator)])
            }
            _ = MermaidSequence.layout(source, font: font)
        }
        let awkward = [
            "sequenceDiagram\n" + String(repeating: "-", count: 2000),
            "sequenceDiagram\nA->>B: " + String(repeating: "word ", count: 500),
            "sequenceDiagram\n" + String(repeating: "loop x\n", count: 60)
                + String(repeating: "end\n", count: 60),
            "sequenceDiagram\n" + (1...200).map { "P\($0)->>P\($0 + 1): m\($0)" }
                .joined(separator: "\n"),
            "sequenceDiagram\nNote over A,,B: x",
            "sequenceDiagram\nA->>B: <br/><br/><br/>",
            "sequenceDiagram\n\u{0}->>\u{0}: nul",
            "sequenceDiagram\nA->>B: 🙂👨‍👩‍👧‍👦 עברית",
        ]
        for source in awkward { _ = MermaidSequence.layout(source, font: font) }
    }

    // MARK: - Where the layout puts it

    private static let sample = """
    sequenceDiagram
        participant A as Alice
        actor B as Bob
        participant C
        A->>B: one
        B->>C: two
        C-->>A: three
        B->>B: think
    """

    func testTheLifelinesRunLeftToRightInTheOrderTheyWereDeclared() throws {
        let drawing = try drawn(Self.sample)
        XCTAssertEqual(drawing.columns.map(\.id), ["A", "B", "C"])
        XCTAssertEqual(drawing.columns.map(\.label), ["Alice", "Bob", "C"])
        XCTAssertLessThan(drawing.columns[0].x, drawing.columns[1].x)
        XCTAssertLessThan(drawing.columns[1].x, drawing.columns[2].x)
    }

    func testEveryMessageIsDrawnBelowTheOneBeforeIt() throws {
        let drawing = try drawn(Self.sample)
        XCTAssertEqual(drawing.arrows.map(\.text), ["one", "two", "three", "think"])
        for (earlier, later) in zip(drawing.arrows, drawing.arrows.dropFirst()) {
            XCTAssertLessThan(earlier.y, later.y, "\(earlier.text) sits above \(later.text)")
        }
        XCTAssertGreaterThan(drawing.arrows[0].y, drawing.columns[0].x * 0)
    }

    func testAMessageReachesFromOneLifelineToTheOther() throws {
        let drawing = try drawn(Self.sample)
        let columns = Dictionary(uniqueKeysWithValues: drawing.columns.map { ($0.id, $0.x) })
        let first = drawing.arrows[0]
        XCTAssertEqual(first.fromX, try XCTUnwrap(columns["A"]), accuracy: em)
        XCTAssertEqual(first.toX, try XCTUnwrap(columns["B"]), accuracy: em)
        XCTAssertLessThan(first.fromX, first.toX, "A stands left of B")

        let back = drawing.arrows[2]
        XCTAssertEqual(back.fromX, try XCTUnwrap(columns["C"]), accuracy: em)
        XCTAssertEqual(back.toX, try XCTUnwrap(columns["A"]), accuracy: em)
        XCTAssertGreaterThan(back.fromX, back.toX, "and C answers leftwards")
    }

    func testASelfMessageStaysToTheRightOfItsOwnLifeline() throws {
        let drawing = try drawn(Self.sample)
        let loop = try XCTUnwrap(drawing.arrows.first { $0.isSelf })
        let lifeline = try XCTUnwrap(drawing.columns.first { $0.id == "B" }).x
        XCTAssertGreaterThanOrEqual(loop.fromX, lifeline)
        XCTAssertGreaterThan(loop.toX, lifeline + em)
        let next = try XCTUnwrap(drawing.columns.first { $0.id == "C" }).x
        XCTAssertLessThan(loop.toX, next, "and never reaches the next one")
    }

    func testTwoLifelinesStandFarEnoughApartForTheLabelBetweenThem() throws {
        let narrow = try drawn("sequenceDiagram\nA->>B: hi")
        let wide = try drawn(
            "sequenceDiagram\nA->>B: a much longer sentence than the other one"
        )
        XCTAssertGreaterThan(
            wide.columns[1].x - wide.columns[0].x,
            narrow.columns[1].x - narrow.columns[0].x
        )
    }

    func testAnActivationBarStandsOnTheLifelineItBelongsTo() throws {
        let drawing = try drawn("""
        sequenceDiagram
            A->>+B: hello
            B->>+B: think
            B-->>-B: done
            B-->>-A: hi back
        """)
        XCTAssertEqual(drawing.activations.count, 2, "the nested bar and the one it sits in")
        let lifeline = try XCTUnwrap(drawing.columns.first { $0.id == "B" }).x
        for bar in drawing.activations {
            XCTAssertEqual(bar.midX, lifeline, accuracy: em)
            XCTAssertGreaterThan(bar.height, 0)
        }
    }

    func testAFrameIsDrawnAroundTheMessagesItHolds() throws {
        let drawing = try drawn("""
        sequenceDiagram
            participant A
            participant B
            A->>B: before
            alt yes
                A->>B: inside
            else no
                B->>A: also inside
            end
            A->>B: after
        """)
        let frame = try XCTUnwrap(drawing.frames.first)
        let inside = drawing.arrows.filter { $0.text.contains("inside") }
        XCTAssertEqual(inside.count, 2)
        for arrow in inside {
            XCTAssertTrue(frame.minY < arrow.y && arrow.y < frame.maxY, "\(arrow.text)")
        }
        XCTAssertLessThan(drawing.arrows[0].y, frame.minY, "and not around the ones outside")
        XCTAssertGreaterThan(drawing.arrows[3].y, frame.maxY)
    }

    func testANoteOverTwoLifelinesReachesAcrossThem() throws {
        let drawing = try drawn("""
        sequenceDiagram
            participant A
            participant B
            Note over A,B: they agree
        """)
        let note = try XCTUnwrap(drawing.notes.first)
        XCTAssertLessThan(note.minX, drawing.columns[0].x)
        XCTAssertGreaterThan(note.maxX, drawing.columns[1].x)
    }

    func testANoteBesideALifelineSitsOnTheSideItWasWrittenOn() throws {
        let drawing = try drawn("""
        sequenceDiagram
            participant A
            participant B
            Note left of B: on the left
            Note right of B: on the right
        """)
        let lifeline = drawing.columns[1].x
        XCTAssertLessThan(drawing.notes[0].maxX, lifeline)
        XCTAssertGreaterThan(drawing.notes[1].minX, lifeline)
    }

    func testTheSizeCoversEveryShapeItDrew() throws {
        let drawing = try drawn("""
        sequenceDiagram
            autonumber
            participant A as Alice
            actor B as Bob
            Note left of A: it starts here
            A->>+B: a question with a fairly long label
            loop until answered
                B->>B: think
                Note over A,B: still thinking
            end
            B-->>-A: an answer
            Note right of B: it ends here
        """)
        XCTAssertGreaterThan(drawing.size.width, 0)
        XCTAssertGreaterThan(drawing.size.height, 0)
        let box = CGRect(origin: .zero, size: drawing.size)
        for rect in drawing.notes + drawing.frames + drawing.activations {
            XCTAssertTrue(box.contains(rect.standardized), "\(rect) inside \(box)")
        }
        for arrow in drawing.arrows {
            XCTAssertTrue(box.contains(CGPoint(x: arrow.fromX, y: arrow.y)), arrow.text)
            XCTAssertTrue(box.contains(CGPoint(x: arrow.toX, y: arrow.y)), arrow.text)
        }
        for column in drawing.columns {
            XCTAssertTrue(0...box.maxX ~= column.x, column.id)
        }
    }

    func testADiagramGrowsWithTheFontItIsMeasuredAgainst() throws {
        let small = try XCTUnwrap(MermaidSequence.layout(Self.sample, font: font))
        let large = try XCTUnwrap(
            MermaidSequence.layout(Self.sample, font: NSFont.systemFont(ofSize: 26))
        )
        XCTAssertGreaterThan(large.size.width, small.size.width)
        XCTAssertGreaterThan(large.size.height, small.size.height)
    }

    // MARK: - Drawing

    func testItPaintsSomethingInEitherAppearance() throws {
        let drawing = try drawn(Self.sample)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let bitmap = try paint(drawing, appearance: NSAppearance(named: name))
            let painted = paintedPixels(in: bitmap)
            XCTAssertGreaterThan(painted, 200, "\(name.rawValue) should draw the diagram")
            XCTAssertLessThan(
                painted, bitmap.pixelsWide * bitmap.pixelsHigh,
                "and should not flood the box"
            )
        }
    }

    func testEveryFeatureAtOnceDrawsWithoutComplaint() throws {
        let drawing = try drawn("""
        sequenceDiagram
            autonumber
            box Front
                actor U as Reader
            end
            participant S as Server
            participant D as Disk
            U->>+S: open
            Note right of U: tapping the file
            S->>+D: read
            D-->>-S: bytes
            alt it fits
                S-->>U: the page
            else it does not
                S-)U: a warning
                S--xU: give up
            end
            par one
                S->>S: cache
            and two
                S->>D: log
            end
            critical keep the lock
                S->>D: flush
            option it drops
                S->>S: retry
            end
            rect rgb(10, 10, 10)
                S-->>-U: done
            end
            Note over U,D: everyone agrees
        """)
        let bitmap = try paint(drawing, appearance: NSAppearance(named: .darkAqua))
        XCTAssertGreaterThan(paintedPixels(in: bitmap), 1000)
    }

    func testADiagramWithOneLifelineAndNothingElseStillDraws() throws {
        let drawing = try drawn("sequenceDiagram\nparticipant Alone")
        XCTAssertEqual(drawing.columns.count, 1)
        XCTAssertGreaterThan(paintedPixels(in: try paint(drawing, appearance: nil)), 20)
    }

    // MARK: - Helpers

    private func paint(
        _ drawing: MermaidSequence.Drawing, appearance: NSAppearance?
    ) throws -> NSBitmapImageRep {
        let width = max(Int(drawing.size.width), 1)
        let height = max(Int(drawing.size.height), 1)
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
            drawing.draw(in: context, palette: .standard)
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
            for x in 0..<bitmap.pixelsWide
            where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                painted += 1
            }
        }
        return painted
    }

    /// A generator with a seed, so the junk the fuzz test types is the same
    /// junk every run.
    private struct Rolling: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed | 1 }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }
}
