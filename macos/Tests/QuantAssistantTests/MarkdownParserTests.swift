import XCTest
@testable import QuantAssistant

final class MarkdownParserTests: XCTestCase {
    /// 照 DeepSeek 在 App 里真实输出过的回复（截图里那段）改写的样例。
    func testTypicalAgentReply() {
        let source = """
        ## 5. 建议下一步（你挑）

        1. 把参数改到 6~12 个月档；
        2. 降低调仓频率（`freq=63`）看成本敏感度；

        | 指标 | 值 |
        |---|---:|
        | Sharpe / Sortino | 0.277 / 0.359 |
        | 最大回撤 | −38.59% |

        > 补充一句工具情况修正：`read` 被白名单拒了。

        ---
        方向对了，**单调性**也更像样。
        """
        let blocks = MarkdownParser.parse(source)
        XCTAssertEqual(blocks, [
            .heading(level: 2, text: "5. 建议下一步（你挑）"),
            .listItem(indent: 0, marker: "1.", text: "把参数改到 6~12 个月档；"),
            .listItem(indent: 0, marker: "2.", text: "降低调仓频率（`freq=63`）看成本敏感度；"),
            .table(
                header: ["指标", "值"], alignments: [.leading, .trailing],
                rows: [["Sharpe / Sortino", "0.277 / 0.359"], ["最大回撤", "−38.59%"]]),
            .quote("补充一句工具情况修正：`read` 被白名单拒了。"),
            .rule,
            .paragraph("方向对了，**单调性**也更像样。"),
        ])
    }

    func testUnclosedCodeFenceWhileStreaming() {
        let blocks = MarkdownParser.parse("看代码：\n```python\nx = 1\ny = 2")
        XCTAssertEqual(blocks, [.paragraph("看代码："), .code(language: "python", code: "x = 1\ny = 2")])
    }

    func testCodeFenceKeepsMarkdownLookalikesVerbatim() {
        let blocks = MarkdownParser.parse("```\n# not a heading\n| a | b |\n|---|---|\n```\n后文")
        XCTAssertEqual(blocks, [.code(language: nil, code: "# not a heading\n| a | b |\n|---|---|"), .paragraph("后文")])
    }

    func testNestedBulletsAndContinuationLines() {
        let blocks = MarkdownParser.parse("- 一级\n  - 二级\n    续行\n* 另一个")
        XCTAssertEqual(blocks, [
            .listItem(indent: 0, marker: "•", text: "一级"),
            .listItem(indent: 1, marker: "•", text: "二级\n续行"),
            .listItem(indent: 0, marker: "•", text: "另一个"),
        ])
    }

    func testSoftLineBreaksStayInOneParagraph() {
        XCTAssertEqual(MarkdownParser.parse("第一行\n第二行\n\n第二段"), [.paragraph("第一行\n第二行"), .paragraph("第二段")])
    }

    func testDashLineWithoutPipeIsRuleNotTableSeparator() {
        XCTAssertEqual(MarkdownParser.parse("a | b\n---"), [.paragraph("a | b"), .rule])
    }

    func testNotAHeadingWithoutSpace() {
        XCTAssertEqual(MarkdownParser.parse("#hashtag"), [.paragraph("#hashtag")])
    }

    func testTableCellsWithEscapedPipeAndRaggedRows() {
        let blocks = MarkdownParser.parse("| a | b |\n|:-:|---|\n| x \\| y |\n| 1 | 2 | 3 |")
        XCTAssertEqual(blocks, [
            .table(header: ["a", "b", ""], alignments: [.center, .leading, .leading],
                   rows: [["x | y", "", ""], ["1", "2", "3"]]),
        ])
    }
}
