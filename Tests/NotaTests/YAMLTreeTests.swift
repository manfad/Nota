import XCTest
@testable import Nota

/// The YAML walker, one grammar feature at a time.
///
/// Every assertion is made against `describe`, a flat rendering of the tree —
/// one line per node, two spaces a level, the key, the value spelled the way
/// the enum spells it, and `@` the source line. A tree that reads wrong here
/// reads wrong in the pane, and the line numbers are half of what the pane is
/// for, so they are in every expectation rather than checked separately.
final class YAMLTreeTests: XCTestCase {

    // MARK: - Block mappings and sequences

    func testBlockMappingKeepsFileOrderAndLines() throws {
        let tree = try YAMLTree.parse(
            """
            name: web
            port: 8080
            debug: false
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              name: string("web") @1
              port: number(8080) @2
              debug: bool(false) @3
            """)
    }

    func testNestedMappingIsIndentation() throws {
        let tree = try YAMLTree.parse(
            """
            server:
              host: localhost
              tls:
                enabled: true
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              server: object @1
                host: string("localhost") @2
                tls: object @3
                  enabled: bool(true) @4
            """,
            "a member is written down at its key, even when its value is below it")
    }

    func testBlockSequence() throws {
        let tree = try YAMLTree.parse(
            """
            - one
            - two
            - three
            """)
        XCTAssertEqual(
            describe(tree),
            """
            array @1
              string("one") @1
              string("two") @2
              string("three") @3
            """)
    }

    func testSequenceMayShareItsKeysIndentation() throws {
        // The form every hand-written config file uses, and the one a strict
        // recursive descent gets wrong: the `-` is at the key's own column.
        let tree = try YAMLTree.parse(
            """
            items:
            - a
            - b
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              items: array @1
                string("a") @2
                string("b") @3
            """)
    }

    func testIndentedSequenceUnderAKey() throws {
        let tree = try YAMLTree.parse(
            """
            items:
              - a
              - b
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              items: array @1
                string("a") @2
                string("b") @3
            """)
    }

    func testCompactNestedSequence() throws {
        let tree = try YAMLTree.parse(
            """
            - - a
            - - b
              - c
            """)
        XCTAssertEqual(
            describe(tree),
            """
            array @1
              array @1
                string("a") @1
              array @2
                string("b") @2
                string("c") @3
            """,
            "the inner sequence's indentation is the column the inner `-` stands at")
    }

    func testCompactMappingInASequenceItem() throws {
        let tree = try YAMLTree.parse(
            """
            - name: web
              port: 80
            - name: db
            """)
        XCTAssertEqual(
            describe(tree),
            """
            array @1
              object @1
                name: string("web") @1
                port: number(80) @2
              object @3
                name: string("db") @3
            """)
    }

    func testSequenceItemWithItsValueOnTheNextLine() throws {
        let tree = try YAMLTree.parse(
            """
            -
              a: 1
            -
              - x
            """)
        XCTAssertEqual(
            describe(tree),
            """
            array @1
              object @1
                a: number(1) @2
              array @3
                string("x") @4
            """)
    }

    func testAKeyWithNothingAfterItIsNull() throws {
        let tree = try YAMLTree.parse(
            """
            a:
            b: 1
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              a: null @1
              b: number(1) @2
            """)
    }

    // MARK: - Flow collections

    func testFlowMappingAndSequence() throws {
        let tree = try YAMLTree.parse("root: {a: 1, b: [x, y]}")
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              root: object @1
                a: number(1) @1
                b: array @1
                  string("x") @1
                  string("y") @1
            """)
    }

    func testFlowCollectionAcrossLines() throws {
        let tree = try YAMLTree.parse(
            """
            root: {a: 1,
                   b: [x,
                       y]}
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              root: object @1
                a: number(1) @1
                b: array @2
                  string("x") @2
                  string("y") @3
            """,
            "inside a flow collection the line breaks are whitespace, but each "
                + "node still remembers the line it was written on")
    }

    func testEmptyFlowCollections() throws {
        let tree = try YAMLTree.parse(
            """
            a: {}
            b: []
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              a: object @1
              b: array @2
            """)
    }

    func testFlowSequenceOfMappings() throws {
        let tree = try YAMLTree.parse("a: [{x: 1}, {y: 2}]")
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              a: array @1
                object @1
                  x: number(1) @1
                object @1
                  y: number(2) @1
            """)
    }

    // MARK: - Scalars

    func testPlainScalarFoldsOverSeveralLines() throws {
        let tree = try YAMLTree.parse(
            """
            text: this is
              one long
              sentence
            next: 1
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              text: string("this is one long sentence") @1
              next: number(1) @4
            """)
    }

    func testSingleQuotedScalar() throws {
        let tree = try YAMLTree.parse(
            """
            a: 'it''s here'
            b: '# not a comment'
            c: '123'
            """)
        XCTAssertEqual(
            describe(tree),
            #"""
            object @1
              a: string("it\'s here") @1
              b: string("# not a comment") @2
              c: string("123") @3
            """#,
            "a quoted scalar is a string, whatever it looks like")
    }

    func testDoubleQuotedEscapes() throws {
        let tree = try YAMLTree.parse(#"a: "tab\there\nnew \" \\ \u00e9 \x41""#)
        XCTAssertEqual(
            describe(tree),
            #"""
            object @1
              a: string("tab\there\nnew \" \\ é A") @1
            """#)
    }

    func testUnterminatedQuoteIsRefused() throws {
        assertRefused("a: 1\nb: \"never closed\nc: 2", line: 2, message: "Unterminated quote")
    }

    func testLiteralBlockScalar() throws {
        let tree = try YAMLTree.parse(
            """
            script: |
              line one
              line two
            after: 1
            """)
        XCTAssertEqual(
            describe(tree),
            #"""
            object @1
              script: string("line one\nline two\n") @1
              after: number(1) @4
            """#,
            "clipping keeps one trailing newline")
    }

    func testBlockScalarChomping() throws {
        let tree = try YAMLTree.parse(
            """
            strip: |-
              x
            keep: |+
              y

            clip: |
              z
            """)
        XCTAssertEqual(
            describe(tree),
            #"""
            object @1
              strip: string("x") @1
              keep: string("y\n\n") @3
              clip: string("z\n") @6
            """#)
    }

    func testFoldedBlockScalar() throws {
        let tree = try YAMLTree.parse(
            """
            note: >
              one
              two

              three
            """)
        XCTAssertEqual(
            describe(tree),
            #"""
            object @1
              note: string("one two\nthree\n") @1
            """#,
            "a single break folds to a space; a blank line stays a break")
    }

    func testFoldedBlockScalarStripped() throws {
        let tree = try YAMLTree.parse(
            """
            note: >-
              one
              two
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              note: string("one two") @1
            """)
    }

    func testBlockScalarWithAnExplicitIndentDigit() throws {
        let tree = try YAMLTree.parse(
            """
            a: |2
                indented
              back
            """)
        XCTAssertEqual(
            describe(tree),
            #"""
            object @1
              a: string("  indented\nback\n") @1
            """#,
            "the digit says where the content starts, so the extra spaces are content")
    }

    // MARK: - Comments, documents, directives

    func testCommentsAreNotContent() throws {
        let tree = try YAMLTree.parse(
            """
            # a heading
            a: 1 # trailing
            # between
            b: two # and here
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @2
              a: number(1) @2
              b: string("two") @4
            """,
            "the mapping starts where its first key is, not where the file starts")
    }

    func testHashInsideAScalarIsNotAComment() throws {
        let tree = try YAMLTree.parse(
            """
            colour: "#ff0000"
            tag: v1#2
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              colour: string("#ff0000") @1
              tag: string("v1#2") @2
            """)
    }

    func testEachDocumentIsItsOwnRoot() throws {
        let tree = try YAMLTree.parse(
            """
            ---
            a: 1
            ---
            b: 2
            ...
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @2
              a: number(1) @2
            object @4
              b: number(2) @4
            """)
    }

    func testDocumentContentMayFollowTheMarker() throws {
        let tree = try YAMLTree.parse(
            """
            --- a: 1
            --- 42
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              a: number(1) @1
            number(42) @2
            """)
    }

    func testLeadingDirectiveIsSkipped() throws {
        let tree = try YAMLTree.parse(
            """
            %YAML 1.2
            ---
            a: 1
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @3
              a: number(1) @3
            """)
    }

    // MARK: - The core schema

    func testNullsAndBooleans() throws {
        let tree = try YAMLTree.parse(
            """
            n1: null
            n2: Null
            n3: NULL
            n4: ~
            n5:
            b1: true
            b2: True
            b3: TRUE
            b4: false
            b5: False
            b6: FALSE
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              n1: null @1
              n2: null @2
              n3: null @3
              n4: null @4
              n5: null @5
              b1: bool(true) @6
              b2: bool(true) @7
              b3: bool(true) @8
              b4: bool(false) @9
              b5: bool(false) @10
              b6: bool(false) @11
            """)
    }

    func testNumbersKeepTheirSpelling() throws {
        let tree = try YAMLTree.parse(
            """
            a: 42
            b: -17
            c: +3
            d: 0x1F
            e: 0o17
            f: 1.50
            g: 6.02e23
            h: -1.0E-9
            i: .inf
            j: -.inf
            k: .nan
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              a: number(42) @1
              b: number(-17) @2
              c: number(+3) @3
              d: number(0x1F) @4
              e: number(0o17) @5
              f: number(1.50) @6
              g: number(6.02e23) @7
              h: number(-1.0E-9) @8
              i: number(.inf) @9
              j: number(-.inf) @10
              k: number(.nan) @11
            """,
            "`1.50` is what the author wrote, so `1.50` is what the tree shows")
    }

    func testEverythingElseIsAString() throws {
        let tree = try YAMLTree.parse(
            """
            a: 1_000
            b: yes
            c: 2026-09-06
            d: "12"
            e: 0b1010
            f: 1:30
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              a: string("1_000") @1
              b: string("yes") @2
              c: string("2026-09-06") @3
              d: string("12") @4
              e: string("0b1010") @5
              f: string("1:30") @6
            """,
            "the 1.2 core schema, not 1.1: `yes` is a word and `1_000` is a name")
    }

    // MARK: - Anchors, aliases, merges, tags

    func testAliasCopiesTheAnchoredNodeAndKeepsItsOwnLine() throws {
        let tree = try YAMLTree.parse(
            """
            base: &base
              a: 1
            copy: *base
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              base: object @1
                a: number(1) @2
              copy: object @3
                a: number(1) @2
            """,
            "the copy sits on the alias's line; its members keep the lines they were written on")
    }

    func testAliasOfAScalar() throws {
        let tree = try YAMLTree.parse(
            """
            a: &v 42
            b: *v
            c: [*v, *v]
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              a: number(42) @1
              b: number(42) @2
              c: array @3
                number(42) @3
                number(42) @3
            """)
    }

    func testMergeKeyFillsInWhatTheMappingDoesNotSay() throws {
        let tree = try YAMLTree.parse(
            """
            defaults: &defaults
              adapter: postgres
              pool: 5
            development:
              <<: *defaults
              database: dev
              pool: 10
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              defaults: object @1
                adapter: string("postgres") @2
                pool: number(5) @3
              development: object @4
                adapter: string("postgres") @2
                database: string("dev") @6
                pool: number(10) @7
            """,
            "`pool` is spelled out, so the merged one loses even though it came first")
    }

    func testMergeOfSeveralAnchors() throws {
        let tree = try YAMLTree.parse(
            """
            a: &a {x: 1}
            b: &b {x: 2, y: 3}
            c:
              <<: [*a, *b]
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              a: object @1
                x: number(1) @1
              b: object @2
                x: number(2) @2
                y: number(3) @2
              c: object @3
                x: number(1) @1
                y: number(3) @2
            """,
            "the first source wins")
    }

    func testTagsAreStrippedButTheStandardOnesDecideTheType() throws {
        let tree = try YAMLTree.parse(
            """
            a: !!str 123
            b: !!int "12"
            c: !custom hello
            d: !!float 1.5
            e: !!bool true
            f: !!null x
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              a: string("123") @1
              b: number(12) @2
              c: string("hello") @3
              d: number(1.5) @4
              e: bool(true) @5
              f: null @6
            """)
    }

    // MARK: - What it refuses

    func testTabInIndentation() throws {
        assertRefused("a:\n\tb: 1", line: 2, message: "Tab in indentation")
    }

    func testBadIndentation() throws {
        assertRefused("a: 1\n  b: 2", line: 2, message: "Bad indentation")
    }

    func testDedentBetweenTwoLevels() throws {
        assertRefused(
            """
            a:
              b:
                  c: 1
               d: 2
            """, line: 4, message: "Bad indentation")
    }

    func testUnknownAlias() throws {
        assertRefused("a: *nope", line: 1, message: "Unknown alias `nope`")
    }

    func testFlowCollectionLeftOpen() throws {
        assertRefused("a: {b: 1,\n   c: 2", line: 1, message: "Flow collection left open")
    }

    func testMappingKeyWhereASequenceItemBelongs() throws {
        assertRefused("- a\nb: 1", line: 2, message: "Expected a sequence item")
    }

    func testSequenceItemWhereAMappingKeyBelongs() throws {
        assertRefused("a: 1\n- b", line: 2, message: "Expected a mapping key")
    }

    func testComplexKeysAreRefused() throws {
        assertRefused("? [a, b]\n: 1", line: 1, message: "Complex keys are not supported")
    }

    func testInvalidEscape() throws {
        assertRefused(#"a: "\q""#, line: 1, message: "Invalid escape `\\q`")
    }

    // MARK: - A file someone would actually have

    func testADockerComposeishFile() throws {
        let tree = try YAMLTree.parse(
            """
            %YAML 1.2
            ---
            version: "3.9"

            x-common: &common
              restart: unless-stopped
              logging:
                driver: json-file

            services:
              web:
                <<: *common
                image: nginx:1.25
                ports:
                  - "8080:80"
                  - 443
                environment: {TZ: UTC, DEBUG: false}
                command: |
                  nginx -g
                  daemon off;
              db:
                <<: *common
                image: postgres:16
                restart: always   # this one insists

            volumes: []
            """)
        XCTAssertEqual(
            describe(tree),
            #"""
            object @3
              version: string("3.9") @3
              x-common: object @5
                restart: string("unless-stopped") @6
                logging: object @7
                  driver: string("json-file") @8
              services: object @10
                web: object @11
                  restart: string("unless-stopped") @6
                  logging: object @7
                    driver: string("json-file") @8
                  image: string("nginx:1.25") @13
                  ports: array @14
                    string("8080:80") @15
                    number(443) @16
                  environment: object @17
                    TZ: string("UTC") @17
                    DEBUG: bool(false) @17
                  command: string("nginx -g\ndaemon off;\n") @18
                db: object @21
                  logging: object @7
                    driver: string("json-file") @8
                  image: string("postgres:16") @23
                  restart: string("always") @24
              volumes: array @26
            """#,
            "`db` spells `restart` out, so the merged one loses and never appears; `web` does "
                + "not, so the anchor's answer stands, on the line the anchor was written on")
    }

    // MARK: - Helpers

    private func assertRefused(
        _ source: String, line: Int, message: String,
        file: StaticString = #filePath, line testLine: UInt = #line
    ) {
        do {
            let tree = try YAMLTree.parse(source)
            XCTFail("expected a refusal, got:\n\(describe(tree))", file: file, line: testLine)
        } catch let error as StructuredParseError {
            XCTAssertEqual(
                error, StructuredParseError(line: line, message: message),
                file: file, line: testLine)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: testLine)
        }
    }
}

/// The tree as indented lines: `key: string("v") @3`. Compact enough to write
/// a whole expectation out, and it shows the two things a tree preview lives
/// or dies by — the shape and the line each row points at.
func describe(_ document: StructuredDocument) -> String {
    var out: [String] = []
    func walk(_ node: StructuredNode, depth: Int) {
        var row = String(repeating: "  ", count: depth)
        if let key = node.key { row += key + ": " }
        row += spell(node.value) + " @\(node.line)"
        out.append(row)
        for child in node.children { walk(child, depth: depth + 1) }
    }
    for root in document.roots { walk(root, depth: 0) }
    return out.joined(separator: "\n")
}

private func spell(_ value: StructuredNode.Value) -> String {
    switch value {
    case .object: "object"
    case .array: "array"
    case .string(let text): "string(\(text.debugDescription))"
    case .number(let text): "number(\(text))"
    case .bool(let flag): "bool(\(flag))"
    case .null: "null"
    case .date(let text): "date(\(text))"
    case .text(let text): "text(\(text.debugDescription))"
    case .comment(let text): "comment(\(text.debugDescription))"
    }
}
