import XCTest
@testable import FreeqMacosCore

final class MessageBlocksTests: XCTestCase {
    // MARK: - Fast path

    func testPlainTextIsSingleParagraph() {
        XCTAssertEqual(MessageBlockParser.parse("hello world"), [.paragraph("hello world")])
    }

    func testPlainMultilineIsSingleParagraph() {
        // No block syntax → one paragraph preserving internal newlines.
        XCTAssertEqual(
            MessageBlockParser.parse("line one\nline two\nline three"),
            [.paragraph("line one\nline two\nline three")])
    }

    func testEmptyInputIsEmptyParagraph() {
        XCTAssertEqual(MessageBlockParser.parse(""), [.paragraph("")])
    }

    func testInlineMarkdownStaysParagraph() {
        // **bold**, `code`, [x](y) are inline — not block syntax.
        let text = "this is **bold** and `code` and [link](https://x.com)"
        XCTAssertEqual(MessageBlockParser.parse(text), [.paragraph(text)])
        XCTAssertFalse(MessageBlockParser.containsBlockSyntax(text))
    }

    // MARK: - containsBlockSyntax pre-check

    func testContainsBlockSyntaxDetection() {
        XCTAssertFalse(MessageBlockParser.containsBlockSyntax("just some words"))
        XCTAssertFalse(MessageBlockParser.containsBlockSyntax(""))
        XCTAssertFalse(MessageBlockParser.containsBlockSyntax("use `inline` code"))
        XCTAssertTrue(MessageBlockParser.containsBlockSyntax("```\ncode\n```"))
        XCTAssertTrue(MessageBlockParser.containsBlockSyntax("> quote"))
        XCTAssertTrue(MessageBlockParser.containsBlockSyntax("- item"))
        XCTAssertTrue(MessageBlockParser.containsBlockSyntax("* item"))
        XCTAssertTrue(MessageBlockParser.containsBlockSyntax("+ item"))
        XCTAssertTrue(MessageBlockParser.containsBlockSyntax("1. item"))
        XCTAssertTrue(MessageBlockParser.containsBlockSyntax("a | b\n---|---\n1 | 2"))
    }

    func testAsteriskWithoutSpaceIsNotList() {
        // "*italic*" must not read as a bullet.
        XCTAssertFalse(MessageBlockParser.containsBlockSyntax("*italic* text"))
        XCTAssertFalse(MessageBlockParser.containsBlockSyntax("-5 degrees below zero"))
    }

    // MARK: - Code fences

    func testCodeFenceWithLanguage() {
        let text = "```swift\nlet x = 1\nprint(x)\n```"
        XCTAssertEqual(
            MessageBlockParser.parse(text),
            [.codeFence(language: "swift", code: "let x = 1\nprint(x)")])
    }

    func testCodeFenceWithoutLanguage() {
        let text = "```\nplain code\n```"
        XCTAssertEqual(
            MessageBlockParser.parse(text),
            [.codeFence(language: nil, code: "plain code")])
    }

    func testUnterminatedFenceRunsToEnd() {
        let text = "```python\nx = 1\ny = 2"
        XCTAssertEqual(
            MessageBlockParser.parse(text),
            [.codeFence(language: "python", code: "x = 1\ny = 2")])
    }

    func testFenceContentsStayVerbatim() {
        // Markdown-looking lines inside a fence must NOT be re-parsed.
        let text = "```\n# not a heading\n- not a list\n> not a quote\n| not | a table |\n```"
        XCTAssertEqual(
            MessageBlockParser.parse(text),
            [.codeFence(language: nil,
                        code: "# not a heading\n- not a list\n> not a quote\n| not | a table |")])
    }

    func testFencePreservesBlankLines() {
        let text = "```\nline1\n\nline3\n```"
        XCTAssertEqual(
            MessageBlockParser.parse(text),
            [.codeFence(language: nil, code: "line1\n\nline3")])
    }

    func testEmptyFence() {
        XCTAssertEqual(
            MessageBlockParser.parse("```\n```"),
            [.codeFence(language: nil, code: "")])
    }

    // MARK: - Block quotes

    func testSingleLineBlockQuote() {
        XCTAssertEqual(MessageBlockParser.parse("> hello"), [.blockQuote("hello")])
    }

    func testMultiLineBlockQuote() {
        XCTAssertEqual(
            MessageBlockParser.parse("> line one\n> line two\n> line three"),
            [.blockQuote("line one\nline two\nline three")])
    }

    func testBlockQuoteWithoutSpaceAfterMarker() {
        XCTAssertEqual(MessageBlockParser.parse(">tight"), [.blockQuote("tight")])
    }

    func testBlockQuoteThenParagraph() {
        XCTAssertEqual(
            MessageBlockParser.parse("> quoted\nnot quoted"),
            [.blockQuote("quoted"), .paragraph("not quoted")])
    }

    // MARK: - Unordered lists

    func testDashList() {
        XCTAssertEqual(
            MessageBlockParser.parse("- apple\n- banana\n- cherry"),
            [.unorderedList(["apple", "banana", "cherry"])])
    }

    func testStarList() {
        XCTAssertEqual(
            MessageBlockParser.parse("* one\n* two"),
            [.unorderedList(["one", "two"])])
    }

    func testPlusList() {
        XCTAssertEqual(
            MessageBlockParser.parse("+ a\n+ b"),
            [.unorderedList(["a", "b"])])
    }

    // MARK: - Ordered lists

    func testOrderedListWithDots() {
        XCTAssertEqual(
            MessageBlockParser.parse("1. first\n2. second\n3. third"),
            [.orderedList(["first", "second", "third"])])
    }

    func testOrderedListWithParens() {
        XCTAssertEqual(
            MessageBlockParser.parse("1) first\n2) second"),
            [.orderedList(["first", "second"])])
    }

    func testOrderedListDoesNotRequireSequential() {
        // Renderer numbers by position; parser keeps whatever text follows.
        XCTAssertEqual(
            MessageBlockParser.parse("1. a\n1. b\n1. c"),
            [.orderedList(["a", "b", "c"])])
    }

    // MARK: - Tables

    func testSimpleTable() {
        let text = "| Name | Age |\n| --- | --- |\n| Alice | 30 |\n| Bob | 25 |"
        XCTAssertEqual(
            MessageBlockParser.parse(text),
            [.table(headers: ["Name", "Age"],
                    rows: [["Alice", "30"], ["Bob", "25"]])])
    }

    func testTableWithoutOuterPipes() {
        let text = "Name | Age\n--- | ---\nAlice | 30"
        XCTAssertEqual(
            MessageBlockParser.parse(text),
            [.table(headers: ["Name", "Age"], rows: [["Alice", "30"]])])
    }

    func testTableWithAlignmentColons() {
        let text = "| L | C | R |\n| :-- | :-: | --: |\n| a | b | c |"
        XCTAssertEqual(
            MessageBlockParser.parse(text),
            [.table(headers: ["L", "C", "R"], rows: [["a", "b", "c"]])])
    }

    func testTableRowShorterThanHeaderIsPadded() {
        let text = "| A | B | C |\n| - | - | - |\n| x | y |"
        XCTAssertEqual(
            MessageBlockParser.parse(text),
            [.table(headers: ["A", "B", "C"], rows: [["x", "y", ""]])])
    }

    func testTableRowLongerThanHeaderIsTruncated() {
        let text = "| A | B |\n| - | - |\n| x | y | z |"
        XCTAssertEqual(
            MessageBlockParser.parse(text),
            [.table(headers: ["A", "B"], rows: [["x", "y"]])])
    }

    func testTableStopsAtBlankLine() {
        let text = "| A | B |\n| - | - |\n| 1 | 2 |\n\nafter"
        XCTAssertEqual(
            MessageBlockParser.parse(text),
            [.table(headers: ["A", "B"], rows: [["1", "2"]]),
             .paragraph("after")])
    }

    func testHorizontalRuleIsNotTable() {
        // "text" then "---" (no pipes) must not become a table.
        let result = MessageBlockParser.parse("- item\n- another")
        XCTAssertEqual(result, [.unorderedList(["item", "another"])])
    }

    // MARK: - Mixed documents

    func testParagraphThenFenceThenParagraph() {
        let text = "Here is code:\n```js\nconst x = 1;\n```\nThat was code."
        XCTAssertEqual(
            MessageBlockParser.parse(text),
            [.paragraph("Here is code:"),
             .codeFence(language: "js", code: "const x = 1;"),
             .paragraph("That was code.")])
    }

    func testAllBlockTypesMixed() {
        let text = """
        Intro paragraph.

        > a quote

        - bullet one
        - bullet two

        1. step one
        2. step two

        | H1 | H2 |
        | -- | -- |
        | a | b |

        ```rust
        fn main() {}
        ```

        Outro.
        """
        XCTAssertEqual(
            MessageBlockParser.parse(text),
            [.paragraph("Intro paragraph."),
             .blockQuote("a quote"),
             .unorderedList(["bullet one", "bullet two"]),
             .orderedList(["step one", "step two"]),
             .table(headers: ["H1", "H2"], rows: [["a", "b"]]),
             .codeFence(language: "rust", code: "fn main() {}"),
             .paragraph("Outro.")])
    }

    func testAdjacentDifferentListsSplit() {
        let text = "- bullet\n1. number"
        XCTAssertEqual(
            MessageBlockParser.parse(text),
            [.unorderedList(["bullet"]), .orderedList(["number"])])
    }

    func testParagraphImmediatelyBeforeList() {
        let text = "Shopping:\n- milk\n- eggs"
        XCTAssertEqual(
            MessageBlockParser.parse(text),
            [.paragraph("Shopping:"), .unorderedList(["milk", "eggs"])])
    }

    // MARK: - Line-ending normalization

    func testCRLFHandledInFence() {
        let text = "```\r\ncode line\r\nmore\r\n```"
        XCTAssertEqual(
            MessageBlockParser.parse(text),
            [.codeFence(language: nil, code: "code line\nmore")])
    }

    func testCRLFInParagraph() {
        XCTAssertEqual(
            MessageBlockParser.parse("plain\r\ntext"),
            [.paragraph("plain\ntext")])
    }

    func testBareCRHandled() {
        XCTAssertEqual(
            MessageBlockParser.parse("> a\r> b"),
            [.blockQuote("a\nb")])
    }

    // MARK: - Edge cases

    func testBlankLinesAloneStayOnFastPath() {
        // No block markers → single paragraph (blank lines are not block syntax).
        let text = "first\n\n\n\nsecond"
        XCTAssertEqual(MessageBlockParser.parse(text), [.paragraph(text)])
    }

    func testMultipleBlankLinesSplitParagraphsWhenParserActive() {
        // Once a block is present the line parser runs, and runs of blank
        // lines collapse into a single paragraph boundary.
        let text = "> q\n\nfirst\n\n\n\nsecond"
        XCTAssertEqual(
            MessageBlockParser.parse(text),
            [.blockQuote("q"), .paragraph("first"), .paragraph("second")])
    }

    func testFenceInsideParagraphFlow() {
        // A fence terminates the preceding paragraph even without a blank line.
        let text = "intro\n```\ncode\n```"
        XCTAssertEqual(
            MessageBlockParser.parse(text),
            [.paragraph("intro"), .codeFence(language: nil, code: "code")])
    }
}
