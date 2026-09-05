import XCTest
@testable import Nota

/// The walker behind the `.json` tab's corner button. Everything here is the
/// text and nothing but the text: no `JSONSerialization`, so what the author
/// wrote comes back spelled the way they wrote it.
///
/// Every literal in this file is ASCII on purpose — the characters outside it
/// are spelled `\u{...}`, which is Swift's escape and not JSON's, so what
/// reaches the walker is the real character.
final class JSONFormatTests: XCTestCase {

    // MARK: - Order

    func testKeysKeepTheOrderTheyWereWrittenIn() throws {
        let source = #"{"zebra":1,"apple":2,"mango":3}"#
        XCTAssertEqual(
            try JSONFormat.reformat(source, as: .pretty),
            """
            {
              "zebra": 1,
              "apple": 2,
              "mango": 3
            }
            """,
            "a dictionary would have sorted them; the source order is the document"
        )
    }

    func testNestedObjectsAndArraysKeepTheirOrderToo() throws {
        let source = #"{"b":{"d":[3,1,2],"c":1},"a":[{"y":1,"x":2}]}"#
        XCTAssertEqual(
            try JSONFormat.reformat(source, as: .pretty),
            """
            {
              "b": {
                "d": [
                  3,
                  1,
                  2
                ],
                "c": 1
              },
              "a": [
                {
                  "y": 1,
                  "x": 2
                }
              ]
            }
            """
        )
    }

    func testDuplicateKeysBothSurvive() throws {
        // A parse into a dictionary would keep one of them. The document has
        // two, and reformatting is not the moment to throw one away.
        let source = #"{"a":1,"a":2}"#
        XCTAssertEqual(try JSONFormat.reformat(source, as: .compact), source)
    }

    // MARK: - Verbatim tokens

    func testEveryEscapeComesBackExactlyAsItWasWritten() throws {
        let source = #"{"a":"tab\there\nline \" \\ \/ \b \f \r é 😀"}"#
        XCTAssertEqual(
            try JSONFormat.reformat(source, as: .pretty),
            #"""
            {
              "a": "tab\there\nline \" \\ \/ \b \f \r é 😀"
            }
            """#,
            "an escape is a pair of characters in the source, and stays one"
        )
        XCTAssertEqual(
            try JSONFormat.reformat(source, as: .compact), source, "and back again unchanged"
        )
    }

    func testNumbersKeepTheirSpelling() throws {
        let source = #"[1.50,1e5,1E+5,-0,0.0,123456789012345678901234567890]"#
        XCTAssertEqual(
            try JSONFormat.reformat(source, as: .compact), source,
            "a number parsed into a Double would come back rounded and respelled"
        )
    }

    func testTextOutsideASCIIIsUntouched() throws {
        // h<e-acute>llo, three CJK characters, an emoji and an em dash — all
        // real characters in the source, none of them escapes.
        let source = "{\"h\u{e9}llo\":\"\u{65e5}\u{672c}\u{8a9e} \u{1f389} \u{2014} ok\"}"
        XCTAssertEqual(
            try JSONFormat.reformat(source, as: .pretty),
            "{\n  \"h\u{e9}llo\": \"\u{65e5}\u{672c}\u{8a9e} \u{1f389} \u{2014} ok\"\n}"
        )
        XCTAssertEqual(try JSONFormat.reformat(source, as: .compact), source)
    }

    func testATopLevelScalarIsADocumentToo() throws {
        for source in [#""hello""#, "42", "true", "false", "null", "-1.5e-3"] {
            XCTAssertEqual(try JSONFormat.reformat(source, as: .pretty), source, source)
            XCTAssertEqual(try JSONFormat.reformat(source, as: .compact), source, source)
        }
    }

    // MARK: - Shape

    func testEmptyContainersStayOnTheirOwnLine() throws {
        let source = #"{"a":{},"b":[],"c":[{}],"d":{"e":[]}}"#
        XCTAssertEqual(
            try JSONFormat.reformat(source, as: .pretty),
            """
            {
              "a": {},
              "b": [],
              "c": [
                {}
              ],
              "d": {
                "e": []
              }
            }
            """,
            "an empty pair of brackets opened over two lines is noise"
        )
    }

    func testCompactHasNoWhitespaceOutsideStrings() throws {
        let source = """
        {
          "a": [ 1, 2 ],
          "b": "  spaces  kept  "
        }
        """
        XCTAssertEqual(
            try JSONFormat.reformat(source, as: .compact),
            #"{"a":[1,2],"b":"  spaces  kept  "}"#
        )
    }

    func testBeautifyingAndCompactingAgainGivesBackTheSameBytes() throws {
        let source = #"{"a":[1,{"b":null,"c":[true,false]}],"d":"x\ty"}"#
        let pretty = try JSONFormat.reformat(source, as: .pretty)
        XCTAssertEqual(try JSONFormat.reformat(pretty, as: .compact), source)
    }

    func testTheFilesTrailingNewlineIsKept() throws {
        XCTAssertTrue(
            try JSONFormat.reformat("{\"a\":1}\n", as: .pretty).hasSuffix("}\n"),
            "reformatting is not the moment to take the last line ending off a file"
        )
        XCTAssertEqual(try JSONFormat.reformat("{\"a\":1}\n", as: .compact), "{\"a\":1}\n")
        XCTAssertFalse(try JSONFormat.reformat("{\"a\":1}", as: .compact).hasSuffix("\n"))
    }

    // MARK: - Which way the button points

    func testCompactTextIsNotPretty() {
        XCTAssertFalse(JSONFormat.isPretty(#"{"a":1,"b":[2,3]}"#))
    }

    func testLaidOutTextIsPretty() {
        XCTAssertTrue(JSONFormat.isPretty("{\n  \"a\": 1\n}"))
    }

    func testTheFilesTrailingNewlineIsNotALayout() {
        XCTAssertFalse(
            JSONFormat.isPretty("{\"a\":1}\n"),
            "every well-kept text file ends in one; it says nothing about the shape"
        )
        XCTAssertFalse(JSONFormat.isPretty("{\"a\":1}\n\n"))
    }

    func testAnEscapedNewlineInsideAStringIsNotALayout() {
        XCTAssertFalse(
            JSONFormat.isPretty(#"{"a":"one\ntwo"}"#),
            "those are two characters in the source, not a line break in the file"
        )
    }

    // MARK: - Where the parse stopped

    func testValidJSONHasNoErrorLine() {
        XCTAssertNil(JSONFormat.errorLine(in: "{\n  \"a\": 1\n}\n"))
    }

    func testTheErrorLineIsTheLineTheParseStoppedOn() {
        let source = """
        {
          "a": 1,
          "b" 2,
          "c": 3
        }
        """
        XCTAssertEqual(JSONFormat.errorLine(in: source), 3, "the missing colon")
    }

    func testAnUnterminatedStringStopsAtTheEnd() {
        XCTAssertEqual(JSONFormat.errorLine(in: "{\n  \"a\": \"open\n}\n"), 2)
    }

    func testEmptyTextIsNotADocument() {
        XCTAssertEqual(JSONFormat.errorLine(in: ""), 1)
        XCTAssertEqual(JSONFormat.errorLine(in: "   \n  "), 2)
    }

    func testTheThingsThatLookLikeJSONAndAreNot() {
        // Trailing comma, comment, single quotes, unquoted key, two documents,
        // a leading zero, a hole in an array.
        XCTAssertNotNil(JSONFormat.errorLine(in: #"{"a":1,}"#))
        XCTAssertNotNil(JSONFormat.errorLine(in: "{\n// a note\n\"a\":1}"))
        XCTAssertNotNil(JSONFormat.errorLine(in: "{'a':1}"))
        XCTAssertNotNil(JSONFormat.errorLine(in: "{a:1}"))
        XCTAssertNotNil(JSONFormat.errorLine(in: #"{"a":1} {"b":2}"#))
        XCTAssertNotNil(JSONFormat.errorLine(in: "01"))
        XCTAssertNotNil(JSONFormat.errorLine(in: "[1,]"))
    }

    func testReformattingRefusesWhatWillNotParse() {
        XCTAssertThrowsError(try JSONFormat.reformat("{\n\"a\" 1\n}", as: .pretty)) { error in
            XCTAssertEqual(error as? JSONFormat.ParseError, JSONFormat.ParseError(line: 2))
        }
    }

    // MARK: - The example file

    /// `Examples/Settings.json` ships as one compact line, so the first click
    /// in the corner is Beautify. It must go pretty and come back to exactly
    /// the bytes it was, or the example is a lie about the walker.
    func testTheExampleFileRoundTrips() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Examples/Settings.json").standardizedFileURL
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(JSONFormat.isPretty(source), "the example ships compact")
        XCTAssertNil(JSONFormat.errorLine(in: source))
        let pretty = try JSONFormat.reformat(source, as: .pretty)
        XCTAssertTrue(JSONFormat.isPretty(pretty))
        XCTAssertTrue(pretty.contains("\"unicode\": \"\u{26A1} \u{7B46}\u{8A18} nota \u{2713}\""),
                      "non-ASCII comes through untouched")
        let compact = try JSONFormat.reformat(pretty, as: .compact)
        XCTAssertEqual(compact, source, "one line and the file's own trailing newline, as it shipped")
    }
}
