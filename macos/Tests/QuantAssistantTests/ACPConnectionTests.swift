import Foundation
import XCTest
@testable import QuantAssistant

final class ACPConnectionTests: XCTestCase {
    func testIntegerAgentRequestDoesNotConsumePendingClientResponse() async throws {
        let fixture = try FakeAgent(mode: "reverse-request")
        defer { fixture.remove() }
        let connection = ACPConnection()
        let watchdog = terminateAfterTimeout(connection)
        defer { watchdog.cancel() }
        try await fixture.launch(connection)

        let result = try await connection.initialize(clientName: "test", clientVersion: "1")
        XCTAssertEqual(result["marker"]?.stringValue, "real-initialize-response")
        let sessionId = try await connection.newSession(cwd: fixture.directory.path)
        XCTAssertEqual(sessionId, "fresh-session")
        await connection.terminate()
    }

    /// 真实 dsh 在一轮 prompt 里会穿插发 usage_update 和 tool_call_update(结果在
    /// content 里)——确认它们经过整条 stdout -> 解析 -> updates 流的链路能到达上层。
    func testUsageAndToolOutputReachUpdatesStream() async throws {
        let fixture = try FakeAgent(mode: "usage")
        defer { fixture.remove() }
        let connection = ACPConnection()
        let watchdog = terminateAfterTimeout(connection)
        defer { watchdog.cancel() }
        try await fixture.launch(connection)
        try await connection.initialize(clientName: "test", clientVersion: "1")
        let sessionId = try await connection.newSession(cwd: fixture.directory.path)

        let collector = Task { () -> [ACPConnection.AgentUpdate.Kind] in
            var kinds: [ACPConnection.AgentUpdate.Kind] = []
            for await update in await connection.updates {
                kinds.append(update.kind)
                if kinds.count == 2 { break }
            }
            return kinds
        }
        let stopReason = try await connection.prompt(sessionId: sessionId, text: "hi")
        XCTAssertEqual(stopReason, "end_turn")
        let kinds = await collector.value
        guard kinds.count == 2,
              case .usage(let used, let size, _, _) = kinds[0],
              case .toolCallUpdate(_, _, _, let output) = kinds[1]
        else { return XCTFail("unexpected updates: \(kinds)") }
        XCTAssertEqual(used, 7508)
        XCTAssertEqual(size, 1_000_000)
        XCTAssertEqual(output?["row_count"], .number(4))
        await connection.terminate()
    }

    /// 停止按钮：prompt 进行中发 session/cancel 通知，fake agent 收到后让那次
    /// prompt 以 stopReason = "cancelled" 返回。
    func testCancelEndsPromptWithCancelledStopReason() async throws {
        let fixture = try FakeAgent(mode: "cancel")
        defer { fixture.remove() }
        let connection = ACPConnection()
        let watchdog = terminateAfterTimeout(connection)
        defer { watchdog.cancel() }
        try await fixture.launch(connection)
        try await connection.initialize(clientName: "test", clientVersion: "1")
        let sessionId = try await connection.newSession(cwd: fixture.directory.path)

        async let stopReason = connection.prompt(sessionId: sessionId, text: "run forever")
        try await Task.sleep(for: .milliseconds(200))
        try await connection.cancel(sessionId: sessionId)
        let result = try await stopReason
        XCTAssertEqual(result, "cancelled")
        await connection.terminate()
    }

    private func terminateAfterTimeout(_ connection: ACPConnection) -> Task<Void, Never> {
        Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            await connection.terminate()
        }
    }
}

private struct FakeAgent {
    let directory: URL
    let executable: URL
    let mode: String

    init(mode: String) throws {
        self.mode = mode
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quant-acp-tests-\(UUID().uuidString)", isDirectory: true)
        executable = directory.appendingPathComponent("fake-agent.py")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func launch(_ connection: ACPConnection) async throws {
        try await connection.launch(
            dshPath: executable.path, profile: "test", cwd: directory.path,
            extraEnv: ["ACP_TEST_MODE": mode])
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static let script = #"""
#!/usr/bin/python3
import json
import os
import sys

mode = os.environ["ACP_TEST_MODE"]

def send(value):
    os.write(1, (json.dumps(value) + "\n").encode())

for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if "id" not in request:
        continue  # 通知（如 session/cancel）在 cancel 模式里单独读
    request_id = request["id"]
    if method == "initialize":
        if mode == "reverse-request":
            send({"jsonrpc": "2.0", "id": request_id,
                  "method": "session/request_permission", "params": {}})
            reply = json.loads(sys.stdin.readline())
            if reply.get("id") != request_id or reply.get("error", {}).get("code") != -32601:
                os._exit(8)
        send({"jsonrpc": "2.0", "id": request_id,
              "result": {"marker": "real-initialize-response"}})
    elif method == "session/new":
        assert request["params"]["mcpServers"] == []
        send({"jsonrpc": "2.0", "id": request_id, "result": {"sessionId": "fresh-session"}})
    elif method == "session/prompt" and mode == "cancel":
        # 一直"跑"，直到收到针对同一个 session 的 session/cancel 通知。
        sid = request["params"]["sessionId"]
        while True:
            note = json.loads(sys.stdin.readline())
            if note.get("method") == "session/cancel" and "id" not in note:
                assert note["params"]["sessionId"] == sid
                break
        send({"jsonrpc": "2.0", "id": request_id, "result": {"stopReason": "cancelled"}})
    elif method == "session/prompt":
        sid = request["params"]["sessionId"]
        send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {
            "sessionUpdate": "usage_update", "used": 7508, "size": 1000000}}})
        send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {
            "sessionUpdate": "tool_call_update", "toolCallId": "c1", "status": "completed",
            "content": [{"type": "content", "content": {"type": "text", "text": "{\"row_count\": 4}"}}]}}})
        send({"jsonrpc": "2.0", "id": request_id, "result": {"stopReason": "end_turn"}})
"""#
}
