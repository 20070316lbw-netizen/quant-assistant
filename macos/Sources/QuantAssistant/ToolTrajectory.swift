import Foundation

/// ACP 工具调用的完整生命周期记录。
///
/// 参照 DSH 自己 web 前端的"轨迹"("trajectory")设计（packages/client/ui-trajectory）：
/// 工具调用不再夹在聊天气泡里打一行摘要就完事，而是单独收集成一条条结构化记录
/// （name/kind/status/耗时/完整 rawInput-rawOutput），聊天区只留一个可点的小
/// 引用（见 ContentView 里的 ToolCallChip），点了跳到"轨迹"标签看完整细节。
/// DSH 那边是完整的事件溯源 + turn/step 分组 + 时间线 + 搜索索引，这里按
/// v0.1.0 的体量砍成了"一个数组、按发生顺序、可展开看细节"，先把"分开展示"
/// 这个核心设计原则立住，复杂的分组/搜索留到真的需要时再加。
struct ToolTrajectoryRecord: Identifiable, Codable {
    let id: String // ACP 的 toolCallId
    let index: Int
    var name: String?
    var title: String
    var kind: String?
    var status: Status
    var rawInput: JSONValue?
    var rawOutput: JSONValue?
    let startedAt: Date
    var completedAt: Date?

    /// 对应 ACP schema 里的 ToolCallStatus：pending/in_progress/completed/failed。
    enum Status: String, Codable {
        case pending
        case inProgress = "in_progress"
        case completed
        case failed
    }

    var durationText: String {
        guard let completedAt else { return "运行中…" }
        let seconds = completedAt.timeIntervalSince(startedAt)
        return String(format: "%.1fs", seconds)
    }
}
