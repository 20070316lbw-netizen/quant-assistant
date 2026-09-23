import Foundation

struct ChatMessage: Identifiable, Codable, Sendable {
    let id: String
    enum Role: String, Codable, Sendable { case user, assistant, system, toolRef }
    let role: Role
    var text: String = ""
    var toolCallId: String? = nil
}

struct SavedConversation: Identifiable, Codable {
    var id: String = UUID().uuidString
    var title: String = "新会话"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var messages: [ChatMessage] = []
    var toolTrajectory: [ToolTrajectoryRecord] = []
    /// 清除记忆前的聊天仍可查看，但绝不能再次送给 Agent。
    var contextStartIndex: Int = 0
    /// 这条会话最后一次收到的上下文用量。切回这条会话时先显示它（标成"上次"），
    /// 不至于一打开旧会话仪表盘就是空的；新 session 发来 usage_update 后被覆盖。
    /// 可选字段，旧存档里没有这个键时解码成 nil，不影响兼容。
    var lastUsage: SessionUsage? = nil
}

struct ResearchMemory: Identifiable, Codable {
    let id: String
    let conversationID: String
    let question: String
    let findings: String
    let createdAt: Date
}

struct ConversationArchive: Codable {
    var conversations: [SavedConversation] = []
    var memories: [ResearchMemory] = []
    var selectedConversationID: String? = nil
    var memoryEnabled: Bool = true
}
