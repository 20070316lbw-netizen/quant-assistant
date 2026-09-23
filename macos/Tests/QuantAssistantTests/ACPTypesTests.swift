import XCTest
@testable import QuantAssistant

final class ACPTypesTests: XCTestCase {
    func testNewSessionParamsAlwaysSendsMcpServersField() throws {
        // dsh-acp 的真实 zod 校验会拒绝没有 mcpServers 字段的 session/new
        // 请求（错误信息是 "mcpServers: Required value is missing"），哪怕
        // ACP 的公开 schema.json 把它标成看起来可选的 array 属性。这条用例
        // 是照实际探测结果补的回归测试：忘了带这个字段的话，这里会先炸，
        // 不用等真跑 App 才在连接失败弹窗里发现。
        let params = NewSessionParams(cwd: "/tmp")
        let data = try JSONEncoder().encode(params)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(value["mcpServers"]?.arrayValue?.count, 0)
    }


    func testJSONValueRoundTripsObjectsArraysAndScalars() throws {
        let json = """
        {"a": 1, "b": "text", "c": [1, 2, 3], "d": true, "e": null, "f": {"g": "h"}}
        """
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        XCTAssertEqual(value["b"]?.stringValue, "text")
        XCTAssertEqual(value["f"]?["g"]?.stringValue, "h")
        XCTAssertEqual(value["c"]?.arrayValue?.count, 3)

        // 重新编码、再解码一次，确认没有信息丢失（尤其是嵌套 object 的 key）。
        let reencoded = try JSONEncoder().encode(value)
        let roundTripped = try JSONDecoder().decode(JSONValue.self, from: reencoded)
        XCTAssertEqual(roundTripped["b"]?.stringValue, "text")
    }

    func testIncomingLineDecodesRealAgentMessageChunkShape() throws {
        // 这是照着 @agentclientprotocol/sdk 1.4.0 的 schema.json 里
        // SessionNotification/SessionUpdate 的字段名手写的一个样例帧，
        // 不是瞎编的形状——字段名对不上就说明 ACPConnection 那边解不出来。
        let json = """
        {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-123","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"你好"}}}}
        """
        let line = try JSONDecoder().decode(IncomingLine.self, from: Data(json.utf8))
        XCTAssertEqual(line.method, "session/update")
        XCTAssertNil(line.id)
        let params = try XCTUnwrap(line.params)
        XCTAssertEqual(params["sessionId"]?.stringValue, "sess-123")
        XCTAssertEqual(params["update"]?["sessionUpdate"]?.stringValue, "agent_message_chunk")
        XCTAssertEqual(params["update"]?["content"]?["text"]?.stringValue, "你好")
    }

    func testIncomingLineDecodesResponseWithIntegerId() throws {
        let json = """
        {"jsonrpc":"2.0","id":7,"result":{"sessionId":"sess-abc"}}
        """
        let line = try JSONDecoder().decode(IncomingLine.self, from: Data(json.utf8))
        guard case .number(let idNumber)? = line.id else {
            return XCTFail("expected numeric id")
        }
        XCTAssertEqual(Int(idNumber), 7)
        XCTAssertEqual(line.result?["sessionId"]?.stringValue, "sess-abc")
        XCTAssertNil(line.method)
    }

    func testIncomingLineDecodesErrorResponse() throws {
        let json = """
        {"jsonrpc":"2.0","id":3,"error":{"code":-32000,"message":"boom"}}
        """
        let line = try JSONDecoder().decode(IncomingLine.self, from: Data(json.utf8))
        XCTAssertEqual(line.error?["message"]?.stringValue, "boom")
    }

    func testOutgoingRequestEncodesProtocolVersionAsInteger() throws {
        // protocolVersion 是 schema 里的 uint16，不是日期字符串——这里锁死，
        // 免得以后手滑改成字符串又要debug半天。
        let params = InitializeParams(clientInfo: .init(name: "test", version: "0.1"))
        let request = OutgoingRequest(id: 1, method: "initialize", params: params)
        let data = try JSONEncoder().encode(request)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .number(let version)? = value["params"]?["protocolVersion"] else {
            return XCTFail("expected numeric protocolVersion")
        }
        XCTAssertEqual(version, 1)
        XCTAssertEqual(value["method"]?.stringValue, "initialize")
    }
}
