import XCTest
@testable import FolderBase

final class MarkdownDocumentParserTests: XCTestCase {
    func testParsesCommonAssistantMarkdownBlocks() {
        let markdown = """
        # Risposta

        Testo con **grassetto** e [link](https://example.com).

        - primo
        - secondo

        3. terzo
        4. quarto

        > Una nota importante.

        ```swift
        let answer = 42
        ```
        """

        XCTAssertEqual(
            MarkdownDocumentParser.parse(markdown),
            [
                .heading(level: 1, text: "Risposta"),
                .paragraph("Testo con **grassetto** e [link](https://example.com)."),
                .unorderedList(["primo", "secondo"]),
                .orderedList(start: 3, items: ["terzo", "quarto"]),
                .quote("Una nota importante."),
                .code(language: "swift", text: "let answer = 42")
            ]
        )
    }

    func testParsesMarkdownTableAndDivider() {
        let markdown = """
        | File | Stato |
        | :--- | ---: |
        | A.md | Pronto |
        | B.md | In corso |

        ---
        """

        XCTAssertEqual(
            MarkdownDocumentParser.parse(markdown),
            [
                .table(
                    headers: ["File", "Stato"],
                    rows: [["A.md", "Pronto"], ["B.md", "In corso"]]
                ),
                .divider
            ]
        )
    }

    func testInlineMarkdownRemovesSyntaxAndKeepsLink() {
        let rendered = MarkdownDocumentParser.inlineAttributedString("Un testo **forte** con [link](https://example.com)")

        XCTAssertEqual(String(rendered.characters), "Un testo forte con link")
        XCTAssertTrue(rendered.runs.contains { $0.link?.absoluteString == "https://example.com" })
    }

    func testUnclosedCodeFenceStillRendersCode() {
        XCTAssertEqual(
            MarkdownDocumentParser.parse("```json\n{\"ok\": true}"),
            [.code(language: "json", text: "{\"ok\": true}")]
        )
    }
}
