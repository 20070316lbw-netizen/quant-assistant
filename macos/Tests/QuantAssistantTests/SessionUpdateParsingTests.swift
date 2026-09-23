import Foundation
import XCTest
@testable import QuantAssistant

/// 用 2026-09-23 从 dsh 0.1.6-alpha.2（quant-acp profile）真实抓到的帧做样例。
final class SessionUpdateParsingTests: XCTestCase {
    private func params(_ update: String) throws -> JSONValue {
        let json = #"{"sessionId":"s1","update":"# + update + #"}"#
        return try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    func testUsageUpdate() throws {
        let parsed = ACPConnection.parseSessionUpdate(
            try params(#"{"sessionUpdate":"usage_update","used":10561,"size":1000000}"#))
        guard case .usage(let used, let size, let amount, let currency) = parsed?.kind else {
            return XCTFail("expected usage, got \(String(describing: parsed?.kind))")
        }
        XCTAssertEqual(used, 10561)
        XCTAssertEqual(size, 1_000_000)
        XCTAssertNil(amount)
        XCTAssertNil(currency)
    }

    func testUsageUpdateWithCost() throws {
        let parsed = ACPConnection.parseSessionUpdate(try params(
            #"{"sessionUpdate":"usage_update","used":5,"size":10,"cost":{"amount":0.0123,"currency":"CNY"}}"#))
        guard case .usage(_, _, let amount, let currency) = parsed?.kind else { return XCTFail() }
        XCTAssertEqual(amount, 0.0123)
        XCTAssertEqual(currency, "CNY")
    }

    /// dsh 不填 rawOutput，结果在 content 里；MCP 工具返回的 JSON 文本应解析成结构。
    func testToolCallUpdateOutputFromContentJSON() throws {
        let parsed = ACPConnection.parseSessionUpdate(try params(#"""
        {"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"completed","content":[{"type":"content","content":{"type":"text","text":"{\n  \"row_count\": 4,\n  \"truncated\": false\n}"}}]}
        """#))
        guard case .toolCallUpdate(let callId, _, let status, let output) = parsed?.kind else { return XCTFail() }
        XCTAssertEqual(callId, "c1")
        XCTAssertEqual(status, "completed")
        XCTAssertEqual(output?["row_count"], .number(4))
        XCTAssertEqual(output?["truncated"], .bool(false))
    }

    func testToolCallUpdateOutputFromContentPlainText() throws {
        let parsed = ACPConnection.parseSessionUpdate(try params(#"""
        {"sessionUpdate":"tool_call_update","toolCallId":"c2","status":"failed","content":[{"type":"content","content":{"type":"text","text":"Error: 工具 \"bash\" 不在 quant-acp 的白名单里，已被拒绝。"}}]}
        """#))
        guard case .toolCallUpdate(_, _, _, let output) = parsed?.kind else { return XCTFail() }
        XCTAssertEqual(output, .string(#"Error: 工具 "bash" 不在 quant-acp 的白名单里，已被拒绝。"#))
    }

    func testRawOutputWinsWhenPresent() throws {
        let parsed = ACPConnection.parseSessionUpdate(try params(
            #"{"sessionUpdate":"tool_call_update","toolCallId":"c3","rawOutput":{"ok":true},"content":[{"type":"content","content":{"type":"text","text":"ignored"}}]}"#))
        guard case .toolCallUpdate(_, _, _, let output) = parsed?.kind else { return XCTFail() }
        XCTAssertEqual(output, .object(["ok": .bool(true)]))
    }

    func testUnknownUpdateIsOther() throws {
        let parsed = ACPConnection.parseSessionUpdate(try params(#"{"sessionUpdate":"available_commands_update"}"#))
        guard case .other(let tag) = parsed?.kind else { return XCTFail() }
        XCTAssertEqual(tag, "available_commands_update")
    }

    func testCompactTokenFormatting() {
        XCTAssertEqual(SessionUsage.compact(950), "950")
        XCTAssertEqual(SessionUsage.compact(10561), "10.6k")
        XCTAssertEqual(SessionUsage.compact(250_000), "250k")
        XCTAssertEqual(SessionUsage.compact(1_000_000), "1M")
    }
}
