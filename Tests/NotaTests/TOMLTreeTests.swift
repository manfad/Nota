import XCTest
@testable import Nota

/// The TOML walker, one grammar feature at a time.
///
/// The expectations are `describe`, shared with `YAMLTreeTests`: one line per
/// node, two spaces a level, `@` the source line. Written out in full rather
/// than poked at member by member, because half of what a tree preview owes
/// the reader is the *shape* — which tables a header made, and in what order —
/// and a test that asks one question at a time never sees the shape at all.
final class TOMLTreeTests: XCTestCase {

    // MARK: - Keys and values

    func testKeyValuePairsKeepFileOrderAndLines() throws {
        let tree = try TOMLTree.parse(
            """
            name = "nota"
            count = 3
            ready = true
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              name: string("nota") @1
              count: number(3) @2
              ready: bool(true) @3
            """)
    }

    func testQuotedKeys() throws {
        let tree = try TOMLTree.parse(
            """
            "quoted key" = 1
            'literal key' = 2
            bare-key_9 = 3
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              quoted key: number(1) @1
              literal key: number(2) @2
              bare-key_9: number(3) @3
            """)
    }

    func testDottedKeysMakeNestedTables() throws {
        let tree = try TOMLTree.parse(
            """
            physical.colour = "orange"
            physical.shape = "round"
            site."google.com" = true
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              physical: object @1
                colour: string("orange") @1
                shape: string("round") @2
              site: object @3
                google.com: bool(true) @3
            """,
            "the table is made on the dotted key's first use, and keeps that line")
    }

    // MARK: - Tables

    func testTableHeaders() throws {
        let tree = try TOMLTree.parse(
            """
            [owner]
            name = "Tom"

            [database]
            ports = [8000, 8001]
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              owner: object @1
                name: string("Tom") @2
              database: object @4
                ports: array @5
                  number(8000) @5
                  number(8001) @5
            """)
    }

    func testImplicitSuperTablesAreMadeAtTheirFirstMention() throws {
        let tree = try TOMLTree.parse(
            """
            [a.b.c]
            x = 1

            [a]
            y = 2
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              a: object @1
                b: object @1
                  c: object @1
                    x: number(1) @2
                y: number(2) @5
            """,
            "`a` and `b` were never written out, so they belong to the line that "
                + "first named them; `[a]` afterwards only fills the table in")
    }

    func testArrayOfTables() throws {
        let tree = try TOMLTree.parse(
            """
            [[fruit]]
            name = "apple"

            [[fruit]]
            name = "banana"
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              fruit: array @1
                object @1
                  name: string("apple") @2
                object @4
                  name: string("banana") @5
            """,
            "the array is the first header's line; each item is its own header's")
    }

    func testTablesInsideAnArrayOfTablesGoToTheLastItem() throws {
        let tree = try TOMLTree.parse(
            """
            [[fruit]]
            name = "apple"

            [fruit.physical]
            colour = "red"

            [[fruit.variety]]
            name = "red delicious"
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              fruit: array @1
                object @1
                  name: string("apple") @2
                  physical: object @4
                    colour: string("red") @5
                  variety: array @7
                    object @7
                      name: string("red delicious") @8
            """)
    }

    func testInlineTable() throws {
        let tree = try TOMLTree.parse(
            """
            point = { x = 1, y = 2 }
            empty = {}
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              point: object @1
                x: number(1) @1
                y: number(2) @1
              empty: object @2
            """)
    }

    func testArrayAcrossLinesWithTrailingCommasAndComments() throws {
        let tree = try TOMLTree.parse(
            """
            nums = [
              1, # one
              # a whole line of comment
              2,
            ]
            nested = [[1, 2], []]
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              nums: array @1
                number(1) @2
                number(2) @4
              nested: array @6
                array @6
                  number(1) @6
                  number(2) @6
                array @6
            """)
    }

    // MARK: - Strings

    func testBasicStringEscapes() throws {
        let tree = try TOMLTree.parse(#"a = "tab\there\nnew \" \\ \u00e9 \U0001F600""#)
        XCTAssertEqual(
            describe(tree),
            #"""
            object @1
              a: string("tab\there\nnew \" \\ é 😀") @1
            """#)
    }

    func testLiteralStringTakesNoEscapes() throws {
        let tree = try TOMLTree.parse(
            #"""
            path = 'C:\Users\nota'
            regex = '\d+\.\d+'
            """#)
        XCTAssertEqual(
            describe(tree),
            #"""
            object @1
              path: string("C:\\Users\\nota") @1
              regex: string("\\d+\\.\\d+") @2
            """#)
    }

    func testMultiLineBasicString() throws {
        let tree = try TOMLTree.parse(
            """
            a = \"""
            Roses are red
            Violets are blue\"""
            """)
        XCTAssertEqual(
            describe(tree),
            #"""
            object @1
              a: string("Roses are red\nViolets are blue") @1
            """#,
            "the newline straight after the opening delimiter belongs to the delimiter")
    }

    func testLineEndingBackslashSwallowsTheBreak() throws {
        let tree = try TOMLTree.parse(
            """
            a = \"""
            The quick brown \\
                fox jumps over \\
                the lazy dog.\"""
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              a: string("The quick brown fox jumps over the lazy dog.") @1
            """)
    }

    func testMultiLineLiteralString() throws {
        let tree = try TOMLTree.parse(
            """
            a = '''
            one
            two
            '''
            """)
        XCTAssertEqual(
            describe(tree),
            #"""
            object @1
              a: string("one\ntwo\n") @1
            """#)
    }

    // MARK: - Numbers, booleans, dates

    func testNumbersAreKeptAsSpelled() throws {
        let tree = try TOMLTree.parse(
            """
            a = 1_000
            b = +99
            c = -17
            d = 0
            e = 0xDEADBEEF
            f = 0o755
            g = 0b1101
            h = 3.1415
            i = 5e+22
            j = 6.626e-34
            k = 224_617.445_991_228
            l = inf
            m = -inf
            n = nan
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              a: number(1_000) @1
              b: number(+99) @2
              c: number(-17) @3
              d: number(0) @4
              e: number(0xDEADBEEF) @5
              f: number(0o755) @6
              g: number(0b1101) @7
              h: number(3.1415) @8
              i: number(5e+22) @9
              j: number(6.626e-34) @10
              k: number(224_617.445_991_228) @11
              l: number(inf) @12
              m: number(-inf) @13
              n: number(nan) @14
            """,
            "`1_000` is what the author wrote, so `1_000` is what the tree shows")
    }

    func testDatesAndTimes() throws {
        let tree = try TOMLTree.parse(
            """
            a = 1979-05-27T07:32:00Z
            b = 1979-05-27T00:32:00-07:00
            c = 1979-05-27T00:32:00.999999-07:00
            d = 1979-05-27 07:32:00Z
            e = 1979-05-27T07:32:00
            f = 1979-05-27
            g = 07:32:00
            h = 00:32:00.999999
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              a: date(1979-05-27T07:32:00Z) @1
              b: date(1979-05-27T00:32:00-07:00) @2
              c: date(1979-05-27T00:32:00.999999-07:00) @3
              d: date(1979-05-27 07:32:00Z) @4
              e: date(1979-05-27T07:32:00) @5
              f: date(1979-05-27) @6
              g: date(07:32:00) @7
              h: date(00:32:00.999999) @8
            """,
            "a space in place of the `T` is the same instant and a different line of file")
    }

    func testCommentsAreNotContent() throws {
        let tree = try TOMLTree.parse(
            """
            # a heading
            a = 1 # trailing
            # between
            b = "#not a comment"
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              a: number(1) @2
              b: string("#not a comment") @4
            """)
    }

    // MARK: - What it refuses

    func testDuplicateKey() throws {
        assertRefused("a = 1\na = 2", line: 2, message: "Duplicate key `a`")
    }

    func testDuplicateKeyInsideATable() throws {
        assertRefused("[t]\nx = 1\nx = 2", line: 3, message: "Duplicate key `x`")
    }

    func testTableDefinedTwice() throws {
        assertRefused("[a]\nx = 1\n\n[a]\ny = 2", line: 4, message: "Table `a` is defined twice")
    }

    func testHeaderThatWouldOverwriteAValue() throws {
        assertRefused("[a]\nb = 1\n\n[a.b]\nc = 2", line: 4, message: "`a.b` is not a table")
    }

    func testDottedKeyIntoAClosedInlineTable() throws {
        assertRefused(
            "a = { x = 1 }\na.y = 2", line: 2, message: "Inline table `a` is closed")
    }

    func testInvalidEscape() throws {
        assertRefused(#"a = "\q""#, line: 1, message: #"Invalid escape `\q`"#)
    }

    func testUnterminatedString() throws {
        assertRefused("a = \"never closed\nb = 1", line: 1, message: "Unterminated string")
    }

    func testMissingEquals() throws {
        assertRefused("a 1", line: 1, message: "Expected `=`")
    }

    func testBadNumber() throws {
        assertRefused("a = 12abc", line: 1, message: "Bad value `12abc`")
    }

    func testBadDate() throws {
        assertRefused("a = 1979-5-27", line: 1, message: "Bad value `1979-5-27`")
    }

    func testTextAfterAValue() throws {
        assertRefused("a = 1 2", line: 1, message: "Unexpected text after a value")
    }

    func testArrayLeftOpen() throws {
        assertRefused("a = [1, 2", line: 1, message: "Array left open")
    }

    // MARK: - A file someone would actually have

    func testACargoishManifest() throws {
        let tree = try TOMLTree.parse(
            """
            # what this crate is
            [package]
            name = "nota"
            version = "0.4.1"
            edition = "2021"
            authors = ["Someone <a@example.com>", "Someone Else"]
            published = 2026-09-06T10:15:00Z
            keywords = [
              "editor",
              "macos",   # and nothing else
            ]

            [package.metadata.docs.rs]
            all-features = true

            [dependencies]
            regex = "1"
            serde = { version = "1.0", features = ["derive"] }

            [dependencies.tokio]
            version = "1.38"
            features = ["full"]

            [[bin]]
            name = "nota"
            path = "src/main.rs"

            [[bin]]
            name = "notad"
            path = "src/daemon.rs"

            [profile.release]
            opt-level = 3
            lto = true
            """)
        XCTAssertEqual(
            describe(tree),
            """
            object @1
              package: object @2
                name: string("nota") @3
                version: string("0.4.1") @4
                edition: string("2021") @5
                authors: array @6
                  string("Someone <a@example.com>") @6
                  string("Someone Else") @6
                published: date(2026-09-06T10:15:00Z) @7
                keywords: array @8
                  string("editor") @9
                  string("macos") @10
                metadata: object @13
                  docs: object @13
                    rs: object @13
                      all-features: bool(true) @14
              dependencies: object @16
                regex: string("1") @17
                serde: object @18
                  version: string("1.0") @18
                  features: array @18
                    string("derive") @18
                tokio: object @20
                  version: string("1.38") @21
                  features: array @22
                    string("full") @22
              bin: array @24
                object @24
                  name: string("nota") @25
                  path: string("src/main.rs") @26
                object @28
                  name: string("notad") @29
                  path: string("src/daemon.rs") @30
              profile: object @32
                release: object @32
                  opt-level: number(3) @33
                  lto: bool(true) @34
            """,
            "`[package.metadata.docs.rs]` makes three tables nobody wrote, all on line 13, "
                + "and `[dependencies.tokio]` adds to the table `[dependencies]` opened above")
    }

    // MARK: - Helpers

    private func assertRefused(
        _ source: String, line: Int, message: String,
        file: StaticString = #filePath, line testLine: UInt = #line
    ) {
        do {
            let tree = try TOMLTree.parse(source)
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
