import Foundation

// 字段名和取值都是从 dsh 实际依赖的 @agentclientprotocol/sdk@1.4.0 的
// schema/schema.json 里核对过的，不是猜的：
//   - protocolVersion 是整数（当前 PROTOCOL_VERSION = 1），不是日期字符串。
//   - initialize / session/new / session/prompt 是 x-side: "agent" 的请求，
//     也就是客户端（我们）发起，agent（dsh）响应。
//   - session/update 是 x-side: "client" 的通知，agent 推给我们，没有 id。
// v0.1.0 范围内只用得到这几个：initialize、session/new、session/prompt、
// session/update 里的 agent_message_chunk。工具调用、权限请求（ask）、
// fs/* 请求这些手册里也提到的能力，等 quant-tool-policy 真的用上 "ask"
// 决策、或者要在界面上展示工具状态时再加。

/// 出站 JSON-RPC 请求：`{jsonrpc, id, method, params}`。
struct OutgoingRequest<Params: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: Params
}

/// 出站 JSON-RPC 通知：`{jsonrpc, method, params}`，没有 id、不等响应。
/// 目前只有 `session/cancel` 用它。
struct OutgoingNotification<Params: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let method: String
    let params: Params
}

/// `session/cancel` 的参数（schema.json 里的 CancelNotification）。
struct CancelParams: Encodable {
    let sessionId: String
}

/// 收到的一行，先按最松散的结构解一遍，再按 method/id/result/error 分流。
/// 三种可能：
///   - 有 id 有 result/error：我们发的某个请求的响应。
///   - 有 method 没 id：agent 推来的通知（目前只处理 session/update）。
///   - 有 method 也有 id：agent 反过来向我们发请求（比如 session/request_permission、
///     fs/read_text_file）——v0.1.0 还没实现任何这类能力，收到就回一个
///     "method not found" 错误，不能不理，否则 agent 会一直等这个请求超时。
struct IncomingLine: Decodable {
    let id: JSONValue?
    let method: String?
    let result: JSONValue?
    let error: JSONValue?
    let params: JSONValue?
}

struct EmptyParams: Encodable {}

struct InitializeParams: Encodable {
    struct ClientCapabilities: Encodable {
        struct Fs: Encodable {
            let readTextFile = false
            let writeTextFile = false
        }
        let fs = Fs()
        let terminal = false
    }
    struct ClientInfo: Encodable {
        let name: String
        let version: String
    }
    let protocolVersion = 1
    let clientCapabilities = ClientCapabilities()
    let clientInfo: ClientInfo
}

struct NewSessionParams: Encodable {
    let cwd: String
    // dsh-acp 的实际 zod 校验把 mcpServers 当成必填字段（哪怕是空数组），
    // 跟 schema.json 里看起来"可选"的 properties 声明对不上——用真实探测
    // 结果核对过：不传这个字段会拿到 "Invalid params" / mcpServers Required。
    // quant-mcp 已经在 profile 层面挂好了，这里传空数组就行，不用重复声明。
    let mcpServers: [String] = []
}

struct TextContentBlock: Encodable {
    let type = "text"
    let text: String
}

struct PromptParams: Encodable {
    let sessionId: String
    let prompt: [TextContentBlock]
}

/// JSON-RPC 错误对象，用来回复 agent 反向发来的、我们还不支持的请求。
struct OutgoingErrorResponse: Encodable {
    struct ErrorBody: Encodable {
        let code: Int
        let message: String
    }
    let jsonrpc = "2.0"
    let id: JSONValue
    let error: ErrorBody
}
