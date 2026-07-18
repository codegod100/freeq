import XCTest
@testable import FreeqMacosCore

final class SyntaxHighlighterTests: XCTestCase {
    /// Helper: the tokenizer must be lossless — concatenating token texts
    /// reproduces the input exactly.
    private func assertLossless(_ code: String, _ language: String?,
                                file: StaticString = #filePath, line: UInt = #line) {
        let tokens = SyntaxHighlighter.highlight(code, language: language)
        XCTAssertEqual(tokens.map(\.text).joined(), code, file: file, line: line)
    }

    private func kinds(_ code: String, _ language: String?) -> [SyntaxTokenKind] {
        SyntaxHighlighter.highlight(code, language: language).map(\.kind)
    }

    private func text(ofKind kind: SyntaxTokenKind, in code: String, _ lang: String?) -> [String] {
        SyntaxHighlighter.highlight(code, language: lang)
            .filter { $0.kind == kind }.map(\.text)
    }

    // MARK: - Empty / unknown

    func testEmptyCodeIsNoTokens() {
        XCTAssertEqual(SyntaxHighlighter.highlight("", language: "swift"), [])
        XCTAssertEqual(SyntaxHighlighter.highlight("", language: nil), [])
    }

    func testUnknownLanguageIsSinglePlainToken() {
        let code = "let x = 5 // whatever"
        XCTAssertEqual(
            SyntaxHighlighter.highlight(code, language: "brainfuck"),
            [SyntaxToken(text: code, kind: .plain)])
    }

    func testNilLanguageIsSinglePlainToken() {
        let code = "func foo() {}"
        XCTAssertEqual(
            SyntaxHighlighter.highlight(code, language: nil),
            [SyntaxToken(text: code, kind: .plain)])
    }

    // MARK: - Keywords

    func testSwiftKeyword() {
        XCTAssertEqual(text(ofKind: .keyword, in: "let x = 1", "swift"), ["let"])
    }

    func testMultipleKeywords() {
        let kws = text(ofKind: .keyword, in: "func foo() { return nil }", "swift")
        XCTAssertEqual(kws, ["func", "return", "nil"])
    }

    func testKeywordSubstringNotMatched() {
        // "letter" contains "let" but is not the keyword.
        XCTAssertEqual(text(ofKind: .keyword, in: "letter = 1", "swift"), [])
    }

    func testPythonKeyword() {
        XCTAssertEqual(text(ofKind: .keyword, in: "def f(): return", "python"),
                       ["def", "return"])
    }

    func testRustKeyword() {
        XCTAssertEqual(text(ofKind: .keyword, in: "fn main() {}", "rust"), ["fn"])
    }

    func testGoKeyword() {
        XCTAssertEqual(text(ofKind: .keyword, in: "func main() {}", "go"), ["func"])
    }

    // MARK: - Strings

    func testDoubleQuotedString() {
        XCTAssertEqual(text(ofKind: .string, in: "let s = \"hello\"", "swift"),
                       ["\"hello\""])
    }

    func testStringWithEscapedQuote() {
        XCTAssertEqual(text(ofKind: .string, in: "x = \"a\\\"b\"", "swift"),
                       ["\"a\\\"b\""])
    }

    func testSingleQuoteStringInPython() {
        XCTAssertEqual(text(ofKind: .string, in: "s = 'hi'", "python"), ["'hi'"])
    }

    func testUnterminatedStringStopsAtNewline() {
        // A stray quote must not swallow the following line.
        let code = "x = \"oops\nlet y = 1"
        let tokens = SyntaxHighlighter.highlight(code, language: "swift")
        // "let" on the next line still classified as a keyword.
        XCTAssertTrue(tokens.contains(SyntaxToken(text: "let", kind: .keyword)))
        assertLossless(code, "swift")
    }

    func testBacktickTemplateStringSpansLines() {
        let code = "const s = `line1\nline2`"
        XCTAssertEqual(text(ofKind: .string, in: code, "javascript"),
                       ["`line1\nline2`"])
    }

    // MARK: - Comments

    func testLineComment() {
        XCTAssertEqual(text(ofKind: .comment, in: "let x = 1 // note", "swift"),
                       ["// note"])
    }

    func testLineCommentStopsAtNewline() {
        let code = "// a\nlet x = 1"
        XCTAssertEqual(text(ofKind: .comment, in: code, "swift"), ["// a"])
        XCTAssertEqual(text(ofKind: .keyword, in: code, "swift"), ["let"])
    }

    func testHashCommentInPython() {
        XCTAssertEqual(text(ofKind: .comment, in: "x = 1  # hi", "python"), ["# hi"])
    }

    func testBlockComment() {
        XCTAssertEqual(text(ofKind: .comment, in: "a /* b\nc */ d", "c"),
                       ["/* b\nc */"])
    }

    func testUnterminatedBlockCommentRunsToEnd() {
        XCTAssertEqual(text(ofKind: .comment, in: "x /* forever", "swift"),
                       ["/* forever"])
    }

    // MARK: - Numbers

    func testIntegerNumber() {
        XCTAssertEqual(text(ofKind: .number, in: "x = 42", "swift"), ["42"])
    }

    func testFloatNumber() {
        XCTAssertEqual(text(ofKind: .number, in: "pi = 3.14", "python"), ["3.14"])
    }

    func testHexNumber() {
        XCTAssertEqual(text(ofKind: .number, in: "c = 0xFF", "swift"), ["0xFF"])
    }

    func testNumberInIdentifierNotMatched() {
        // "abc123" is one identifier, not "abc" + number "123".
        XCTAssertEqual(text(ofKind: .number, in: "abc123 = 1", "swift"), ["1"])
    }

    // MARK: - Losslessness (property)

    func testLosslessAcrossLanguages() {
        let samples: [(String, String)] = [
            ("func greet(name: String) -> String {\n  return \"hi \\(name)\" // ok\n}", "swift"),
            ("def add(a, b):\n    return a + b  # sum", "python"),
            ("const x = [1, 2, 3].map(n => n * 2); // arr", "javascript"),
            ("fn main() { let v = vec![1, 2]; /* c */ }", "rust"),
            ("package main\nfunc main() { println(`raw`) }", "go"),
            ("{ \"key\": 123, \"ok\": true }", "json"),
            ("echo \"hi\" # comment\nfor f in *; do :; done", "bash"),
            ("int main(void) { return 0; /* end */ }", "c"),
        ]
        for (code, lang) in samples {
            assertLossless(code, lang)
        }
    }

    func testJsonHighlighting() {
        let code = "{ \"n\": 42, \"ok\": true }"
        XCTAssertEqual(text(ofKind: .string, in: code, "json"), ["\"n\"", "\"ok\""])
        XCTAssertEqual(text(ofKind: .number, in: code, "json"), ["42"])
        XCTAssertEqual(text(ofKind: .keyword, in: code, "json"), ["true"])
    }

    func testMixedTokensOrder() {
        // "let n = 10 // c" → keyword, plain, number, comment (order preserved).
        let tokens = SyntaxHighlighter.highlight("let n = 10 // c", language: "swift")
        XCTAssertEqual(tokens.first, SyntaxToken(text: "let", kind: .keyword))
        XCTAssertEqual(tokens.last, SyntaxToken(text: "// c", kind: .comment))
        XCTAssertTrue(tokens.contains(SyntaxToken(text: "10", kind: .number)))
    }
}
