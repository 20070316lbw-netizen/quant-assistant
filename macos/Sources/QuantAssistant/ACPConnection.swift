import Foundation

enum ACPConnectionError: Error, CustomStringConvertible {
    case processExited(Int32)
    case decodeFailed(String)
    case agentError(String)
    case notLaunched

    var description: String {
        switch self {
        case .processExited(let code): return "dsh 子进程退出，状态码 \(code)"
        case .decodeFailed(let line): return "解析 ACP 消息失败: \(line)"
        case .agentError(let message): return "agent 返回错误: \(message)"
        case .notLaunched: return "ACP 连接还没启动"
        }
    }
}

/// 对应手册 11.4 节的状态机，v0.1.0 先不做 restartAfterFailure 的自动重试，
/// 失败了就停在 failed，交给上层（ChatViewModel）决定要不要重新 launch()。
enum ACPProcessState: Equatable, Sendable {
    case stopped
    case launching
    case handshaking
    case ready
    case stopping
    case failed(String)
}

/// 唯一能碰子进程 stdin/stdout 的对象——手册 11.3 节要求 UI 只通过结构化事件
/// 订阅它，不直接操作 Pipe。是个 actor，所以 stdin 写入天然串行化，不用另外
/// 拿锁（对应手册 11.2 节"stdin 写入由一个 Actor 串行化"）。
actor ACPConnection {
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var nextRequestId = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var lineBuffer = Data()
    private var stderrTail: [String] = []
    private let stderrTailLimit = 200

    /// agent_message_chunk 的文本增量、工具调用生命周期事件，按 sessionId 推给
    /// 上层。用 AsyncStream 而不是回调闭包，方便 ChatViewModel 用 for-await 消费，
    /// 断开时 finish() 一下就能让消费端的循环自然退出。
    let updates: AsyncStream<AgentUpdate>
    private let updatesContinuation: AsyncStream<AgentUpdate>.Continuation

    private(set) var state: ACPProcessState = .stopped

    struct AgentUpdate: Sendable {
        let sessionId: String
        let kind: Kind
        enum Kind: Sendable {
            case agentMessageChunk(text: String)
            case agentThoughtChunk(text: String)
            /// ACP `tool_call`：一次新的工具调用被发起。字段名跟
            /// @agentclientprotocol/sdk@1.4.0 的 schema.json 里 ToolCall 定义核对过：
            /// toolCallId/title 必填，name/kind/status/rawInput 都可能缺。
            case toolCall(
                callId: String, name: String?, title: String, kind: String?,
                status: String?, rawInput: JSONValue?)
            /// ACP `tool_call_update`：已有工具调用的状态/结果更新。除 toolCallId
            /// 外全部字段可选——只带发生变化的那些。
            case toolCallUpdate(
                callId: String, title: String?, status: String?, rawOutput: JSONValue?)
            /// ACP `usage_update`：当前上下文已用 token 数 / 上下文窗口大小，
            /// 可选的会话累计费用。字段照 schema.json 的 UsageUpdate/Cost 核对过，
            /// dsh 0.1.6-alpha.2 实测只带 used/size，不带 cost。
            case usage(used: Int, size: Int, costAmount: Double?, costCurrency: String?)
            case other(String)
        }
    }

    init() {
        var continuation: AsyncStream<AgentUpdate>.Continuation!
        self.updates = AsyncStream { continuation = $0 }
        self.updatesContinuation = continuation
    }

    /// 启动 `dsh --profile quant-acp` 子进程。dshPath 和 cwd 都要求绝对路径——
    /// 手册 11.2 节明确说 Swift 只启动"唯一的" dsh 子进程，且传入固定参数，
    /// 不能从聊天内容拼命令行。
    func launch(dshPath: String, profile: String, cwd: String, extraEnv: [String: String]) throws {
        guard case .stopped = state else { return }
        state = .launching

        let process = Process()
        process.executableURL = URL(fileURLWithPath: dshPath)
        process.arguments = ["--profile", profile]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        // 环境清理：手册 14.2 节要求"不要直接复制完整登录 Shell 环境"。
        // v0.1.0 先妥协成"继承当前进程环境 + 显式覆盖"，Keychain 凭据管理
        // （手册 14.1 节）是后面的加固工作；这里至少不是往源码里塞死密钥。
        var env = ProcessInfo.processInfo.environment
        for (key, value) in extraEnv { env[key] = value }
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        stdoutHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.appendStdout(data) }
        }
        stderrHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { await self?.appendStderr(text) }
        }

        process.terminationHandler = { [weak self] proc in
            Task { await self?.handleTermination(status: proc.terminationStatus) }
        }

        try process.run()
        state = .handshaking
    }

    private func appendStdout(_ data: Data) {
        lineBuffer.append(data)
        while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer[..<newlineIndex]
            lineBuffer.removeSubrange(...newlineIndex)
            if !lineData.isEmpty {
                handleLine(Data(lineData))
            }
        }
    }

    private func appendStderr(_ text: String) {
        stderrTail.append(contentsOf: text.split(separator: "\n").map(String.init))
        if stderrTail.count > stderrTailLimit {
            stderrTail.removeFirst(stderrTail.count - stderrTailLimit)
        }
    }

    /// 诊断用：最近的 stderr 行，UI 目前不展示，出问题时可以打印出来看。
    func recentStderr() -> [String] { stderrTail }

    private func handleTermination(status: Int32) {
        state = status == 0 ? .stopped : .failed("dsh 退出，状态码 \(status)")
        let error = ACPConnectionError.processExited(status)
        for (_, continuation) in pending { continuation.resume(throwing: error) }
        pending.removeAll()
        updatesContinuation.finish()
    }

    private func handleLine(_ data: Data) {
        guard let line = try? JSONDecoder().decode(IncomingLine.self, from: data) else {
            // 解析失败不让进程崩掉，记一条诊断然后继续读下一行——手册 11.2 节
            // 说的是"重启进程"，v0.1.0 先降级成"跳过并记录"，重启逻辑留给
            // restartAfterFailure() 以后再补。
            let raw = String(decoding: data.prefix(2000), as: UTF8.self)
            appendStderr("[acp-decode-error] \(raw)")
            return
        }

        if line.method == nil, let idValue = line.id, let requestId = intId(idValue) {
            // 这是对我们某个请求的响应。必须先确认没有 method：agent 反向发来的
            // 请求（比如 session/request_permission）也带整数 id，而且可能恰好跟
            // 我们某个还在等的请求 id 相同，不能被当成那个请求的响应吃掉。
            guard let continuation = pending.removeValue(forKey: requestId) else { return }
            if let error = line.error {
                let message = error["message"]?.stringValue ?? "unknown ACP error"
                continuation.resume(throwing: ACPConnectionError.agentError(message))
            } else {
                continuation.resume(returning: line.result ?? .null)
            }
            return
        }

        guard let method = line.method else { return }

        if method == "session/update", let params = line.params {
            routeSessionUpdate(params)
            return
        }

        if let idValue = line.id {
            // agent 反过来向我们发请求（权限确认、fs 读写……）。v0.1.0 还没实现
            // 任何这类能力，但必须回一个错误，不能坐视 agent 那边挂起等待。
            replyMethodNotFound(id: idValue, method: method)
        }
    }

    private func routeSessionUpdate(_ params: JSONValue) {
        guard let update = Self.parseSessionUpdate(params) else { return }
        updatesContinuation.yield(update)
    }

    /// 把一条 `session/update` 通知的 params 解析成 AgentUpdate。纯函数，
    /// 不碰 actor 状态，方便直接拿真实抓到的帧写单测。
    nonisolated static func parseSessionUpdate(_ params: JSONValue) -> AgentUpdate? {
        guard let sessionId = params["sessionId"]?.stringValue,
              let update = params["update"] else { return nil }
        let kindTag = update["sessionUpdate"]?.stringValue ?? ""
        switch kindTag {
        case "agent_message_chunk":
            let text = update["content"]?["text"]?.stringValue ?? ""
            return AgentUpdate(sessionId: sessionId, kind: .agentMessageChunk(text: text))
        case "agent_thought_chunk":
            let text = update["content"]?["text"]?.stringValue ?? ""
            return AgentUpdate(sessionId: sessionId, kind: .agentThoughtChunk(text: text))
        case "tool_call":
            let callId = update["toolCallId"]?.stringValue ?? UUID().uuidString
            let title = update["title"]?.stringValue ?? update["name"]?.stringValue ?? "未知工具"
            return AgentUpdate(
                sessionId: sessionId,
                kind: .toolCall(
                    callId: callId,
                    name: update["name"]?.stringValue,
                    title: title,
                    kind: update["kind"]?.stringValue,
                    status: update["status"]?.stringValue,
                    rawInput: update["rawInput"]))
        case "tool_call_update":
            guard let callId = update["toolCallId"]?.stringValue else { return nil }
            return AgentUpdate(
                sessionId: sessionId,
                kind: .toolCallUpdate(
                    callId: callId,
                    title: update["title"]?.stringValue,
                    status: update["status"]?.stringValue,
                    rawOutput: toolOutput(of: update)))
        case "usage_update":
            guard let used = update["used"]?.intValue, let size = update["size"]?.intValue else { return nil }
            let cost = update["cost"]
            return AgentUpdate(
                sessionId: sessionId,
                kind: .usage(
                    used: used, size: size,
                    costAmount: cost?["amount"]?.doubleValue,
                    costCurrency: cost?["currency"]?.stringValue))
        default:
            return AgentUpdate(sessionId: sessionId, kind: .other(kindTag))
        }
    }

    /// 工具结果：优先用 `rawOutput`；dsh 实际不填它，而是把结果放在
    /// `content: [{type: "content", content: {type: "text", text}}]` 里
    /// （ToolCallContent，2026-09-23 抓真实帧确认）。把所有文本块拼起来，
    /// 如果恰好是一段 JSON（MCP 工具通常返回 JSON）就解析成 JSONValue，
    /// 轨迹面板能按结构缩进显示；否则原样当字符串。
    nonisolated static func toolOutput(of update: JSONValue) -> JSONValue? {
        if let raw = update["rawOutput"], raw != .null { return raw }
        guard let blocks = update["content"]?.arrayValue else { return nil }
        let texts = blocks.compactMap { block -> String? in
            block["content"]?["text"]?.stringValue ?? block["text"]?.stringValue
        }
        guard !texts.isEmpty else { return nil }
        let joined = texts.joined(separator: "\n")
        if let data = joined.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(JSONValue.self, from: data),
           case .object = parsed {
            return parsed
        }
        return .string(joined)
    }

    private func replyMethodNotFound(id: JSONValue, method: String) {
        let response = OutgoingErrorResponse(
            id: id,
            error: .init(code: -32601, message: "quant-assistant v0.1.0 client 还没实现 \(method)"))
        try? writeLine(response)
    }

    private func intId(_ value: JSONValue) -> Int? {
        if case .number(let n) = value { return Int(n) }
        return nil
    }

    private func writeLine<T: Encodable>(_ value: T) throws {
        guard let stdinHandle else { throw ACPConnectionError.notLaunched }
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        try stdinHandle.write(contentsOf: data)
    }

    /// 发一个请求，挂起等对应 id 的 response 回来。所有出站请求都走这一个
    /// 方法，id 分配和 pending 表都在 actor 内部，不会有并发写冲突。
    private func request<Params: Encodable>(method: String, params: Params) async throws -> JSONValue {
        guard stdinHandle != nil else { throw ACPConnectionError.notLaunched }
        let id = nextRequestId
        nextRequestId += 1
        let payload = OutgoingRequest(id: id, method: method, params: params)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try writeLine(payload)
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    @discardableResult
    func initialize(clientName: String, clientVersion: String) async throws -> JSONValue {
        let result = try await request(
            method: "initialize",
            params: InitializeParams(clientInfo: .init(name: clientName, version: clientVersion)))
        state = .ready
        return result
    }

    func newSession(cwd: String) async throws -> String {
        let result = try await request(method: "session/new", params: NewSessionParams(cwd: cwd))
        guard let sessionId = result["sessionId"]?.stringValue else {
            throw ACPConnectionError.decodeFailed("session/new 响应里没有 sessionId")
        }
        return sessionId
    }

    /// 发一条 prompt，返回 stopReason；agent_message_chunk 增量走 `updates` 流，
    /// 不在这里返回——调用方应该在发 prompt 之前就开始消费 updates。
    @discardableResult
    func prompt(sessionId: String, text: String) async throws -> String {
        let result = try await request(
            method: "session/prompt",
            params: PromptParams(sessionId: sessionId, prompt: [TextContentBlock(text: text)]))
        return result["stopReason"]?.stringValue ?? "unknown"
    }

    /// 让 agent 停下正在进行的这一轮（ACP `session/cancel` 通知）。按协议，agent
    /// 收到后会尽快停止模型请求和工具调用，并让那次 `session/prompt` 以
    /// stopReason = "cancelled" 返回——所以这里不等任何响应，结果仍然从
    /// 原来那个 prompt() 调用里拿。
    func cancel(sessionId: String) throws {
        try writeLine(OutgoingNotification(method: "session/cancel", params: CancelParams(sessionId: sessionId)))
    }

    func terminate() {
        state = .stopping
        process?.terminate()
    }
}
