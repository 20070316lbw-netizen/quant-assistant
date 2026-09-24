import Foundation

/// v0.1.0 范围：文本对话 + 工具调用轨迹的分离展示（参照 DSH 自己 web 前端的
/// "对话/轨迹"双视图设计），加上本地会话持久化、历史会话列表、跨会话研究记忆
/// 和清除记忆。权限确认、PDF 交付卡片（手册 11.6-11.8 节）留到 quant-tool-policy
/// 真的用上 "ask" 决策、以及报告工具做出来之后再接。
@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var toolTrajectory: [ToolTrajectoryRecord] = []
    /// 从聊天区的工具引用条点进来时设置，"轨迹"视图据此滚动定位、高亮。
    @Published var focusedToolCallId: String?
    @Published var input: String = ""
    @Published private(set) var statusText: String = "未连接"
    @Published private(set) var isSending: Bool = false
    /// 点了"停止"、还没等到 agent 以 cancelled 结束这一轮的这段时间。
    @Published private(set) var isCancelling: Bool = false
    /// 切换/新建会话时短暂为 true：这段时间发消息会进错的 agent session，先禁用发送。
    @Published private(set) var isSwitchingSession: Bool = false

    /// 历史会话列表（侧栏），按 updatedAt 倒序展示由 View 自己排序。
    @Published private(set) var conversations: [SavedConversation] = []
    @Published private(set) var currentConversationID: String = ""
    /// 跨会话研究记忆：过去每轮问答的摘录，注入到新会话的 prompt 里让 agent
    /// "记得"之前做过的研究。跟当前会话的历史消息（ResearchContext.historyExcerpts）
    /// 是两件独立的事——这个是跨会话的，那个是同一会话内的。
    @Published private(set) var memories: [ResearchMemory] = []
    @Published private(set) var memoryEnabled: Bool = true
    /// 状态栏用量仪表盘显示的数据（来自 ACP `usage_update`）。
    /// 切换/新开 agent session 时换成这条会话上次保存的用量，并把
    /// `usageIsStale` 置 true（界面标"上次"）；新 session 发来第一条 usage_update 后
    /// 变回实时数据。
    @Published private(set) var usage: SessionUsage?
    @Published private(set) var usageIsStale: Bool = false

    /// 钥匙串里存的 DeepSeek API key 的脱敏显示（"sk-…a1b2"），nil 表示没存。
    @Published private(set) var apiKeyMasked: String?
    @Published private(set) var balance: DeepSeekBalance?
    @Published private(set) var balanceError: String?
    @Published private(set) var isRefreshingBalance: Bool = false
    private let keychain = KeychainStore.deepSeek

    private let connection = ACPConnection()
    private var sessionId: String?
    private var currentAssistantMessageId: String?
    private var updatesTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?
    private var store: ConversationStorage?
    /// 每次开一个新的 agent session（launch/newConversation/selectConversation/
    /// 清除当前对话记忆之后）都为 true：agent 进程本身是全新的，下一条消息要把
    /// 这条会话已保存的历史消息重新塞进 prompt 里，发完这一条就复位。
    private var sessionNeedsHistoryContext = false

    // 路径先写死在这——手册 11.2 节要求 Swift 只启动固定的一个 dsh 子进程，
    // 参数不能从聊天内容拼，所以配置成常量而不是可自由填写的输入框正好符合
    // 这条设计原则。等做设置界面时再挪成用户可改的受信任配置。
    private let dshPath = "/Users/liu/quant/quant-assistant/node_modules/.bin/dsh"
    private let profile = "quant-acp"
    private let workingDirectory = "/Users/liu/quant/quant-assistant"

    func start() {
        guard sessionId == nil else { return }
        loadArchive()
        // 钥匙串里有 key 就注入给 dsh 子进程当环境变量。dsh 取 key 的顺序是
        // "自己的凭据存储（~/.dsh/.credentials.yaml）优先，环境变量兜底"，
        // 所以已经在 dsh 里配过 key 的话，dsh 仍用它自己那份；这里的 key
        // 主要用来查余额，顺便让没配过 dsh 凭据的机器也能直接用。
        var extraEnv: [String: String] = [:]
        let storedKey = loadAPIKey()
        if let storedKey { extraEnv["DEEPSEEK_API_KEY"] = storedKey }
        refreshBalance()
        statusText = "启动 dsh..."
        updatesTask = Task { [weak self] in
            guard let self else { return }
            for await update in await self.connection.updates {
                await self.handle(update)
            }
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.connection.launch(
                    dshPath: self.dshPath, profile: self.profile,
                    cwd: self.workingDirectory, extraEnv: extraEnv)
                self.statusText = "握手中..."
                _ = try await self.connection.initialize(
                    clientName: "quant-assistant-macos", clientVersion: "0.1.0")
                await self.startNewAgentSession()
                self.sessionNeedsHistoryContext = !self.messages.isEmpty
                // 每次启动都会连一次，旧会话里已经有一行同样的提示就不再重复堆。
                if self.messages.last?.text != "已连接到 quant-acp。" {
                    self.appendSystem("已连接到 quant-acp。")
                }
            } catch {
                self.statusText = "连接失败: \(error)"
                self.appendSystem("连接失败：\(error)")
            }
        }
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let sessionId, !isSending, !isSwitchingSession else { return }
        input = ""
        let priorSnapshot = snapshot()
        messages.append(ChatMessage(id: UUID().uuidString, role: .user, text: text))
        syncCurrentConversation()
        schedulePersist()
        isSending = true
        currentAssistantMessageId = nil
        let promptText = ResearchContext.prompt(
            userText: text, conversation: priorSnapshot, memories: memories,
            includeHistory: sessionNeedsHistoryContext, memoryEnabled: memoryEnabled)
        Task { [weak self] in
            guard let self else { return }
            do {
                let stopReason = try await self.connection.prompt(sessionId: sessionId, text: promptText)
                self.sessionNeedsHistoryContext = false
                self.isSending = false
                self.isCancelling = false
                if stopReason == "cancelled" {
                    // 被用户中途停下的回答是半截的，不记进跨会话研究记忆。
                    self.appendSystem("已停止。")
                } else if self.currentAssistantMessageId == nil {
                    // agent 一句回复都没流式推过来（比如直接被工具白名单之类的
                    // 逻辑短路），至少把 stopReason 露出来，别让界面看着像没反应。
                    self.appendSystem("(no content, stopReason=\(stopReason))")
                } else {
                    self.recordResearchMemory(question: text)
                }
                self.refreshBalance()
                self.syncCurrentConversation()
                self.schedulePersist()
            } catch {
                self.isSending = false
                self.isCancelling = false
                self.appendSystem("发送失败：\(error)")
                self.syncCurrentConversation()
                self.schedulePersist()
            }
        }
    }

    /// 中途停止当前这一轮。只发 `session/cancel`，状态复位等 prompt() 返回
    /// stopReason = "cancelled" 时在 send() 里统一处理。
    func cancel() {
        guard isSending, !isCancelling, let sessionId else { return }
        isCancelling = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.connection.cancel(sessionId: sessionId)
            } catch {
                self.isCancelling = false
                self.appendSystem("停止失败：\(error)")
            }
        }
    }

    // MARK: - API key 与账户余额

    /// 保存到钥匙串并立刻查一次余额验证 key 能用。dsh 子进程已经启动，
    /// 新 key 要下次启动 App 才会作为环境变量传给它。
    func saveAPIKey(_ raw: String) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try keychain.save(key)
            apiKeyMasked = KeychainStore.masked(key)
            balance = nil
            refreshBalance()
        } catch {
            balanceError = error.localizedDescription
        }
    }

    func deleteAPIKey() {
        do {
            try keychain.delete()
            apiKeyMasked = nil
            balance = nil
            balanceError = nil
        } catch {
            balanceError = error.localizedDescription
        }
    }

    func refreshBalance() {
        guard !isRefreshingBalance else { return }
        guard let key = loadAPIKey() else {
            balance = nil
            return
        }
        isRefreshingBalance = true
        Task { [weak self] in
            do {
                let fetched = try await DeepSeekBalance.fetch(apiKey: key)
                self?.balance = fetched
                self?.balanceError = nil
            } catch {
                self?.balanceError = error.localizedDescription
            }
            self?.isRefreshingBalance = false
        }
    }

    private func loadAPIKey() -> String? {
        do {
            let key = try keychain.load()
            apiKeyMasked = key.map(KeychainStore.masked)
            return key
        } catch {
            apiKeyMasked = nil
            balanceError = error.localizedDescription
            return nil
        }
    }

    // MARK: - 历史会话（新建/切换/删除）

    func newConversation() {
        syncCurrentConversation()
        let fresh = SavedConversation()
        conversations.insert(fresh, at: 0)
        currentConversationID = fresh.id
        messages = []
        toolTrajectory = []
        currentAssistantMessageId = nil
        sessionNeedsHistoryContext = false
        schedulePersist()
        Task { [weak self] in
            guard let self else { return }
            self.isSwitchingSession = true
            await self.startNewAgentSession()
            self.isSwitchingSession = false
        }
    }

    func selectConversation(_ id: String) {
        guard id != currentConversationID else { return }
        syncCurrentConversation()
        currentConversationID = id
        loadCurrentConversationIntoLiveState()
        currentAssistantMessageId = nil
        let needsHistory = !messages.isEmpty
        sessionNeedsHistoryContext = needsHistory
        schedulePersist()
        Task { [weak self] in
            guard let self else { return }
            self.isSwitchingSession = true
            await self.startNewAgentSession()
            self.sessionNeedsHistoryContext = needsHistory
            self.isSwitchingSession = false
        }
    }

    func deleteConversation(_ id: String) {
        conversations.removeAll { $0.id == id }
        if currentConversationID == id {
            let next = conversations.first ?? SavedConversation()
            if conversations.isEmpty { conversations = [next] }
            currentConversationID = next.id
            loadCurrentConversationIntoLiveState()
            currentAssistantMessageId = nil
            let needsHistory = !messages.isEmpty
            sessionNeedsHistoryContext = needsHistory
            Task { [weak self] in
                guard let self else { return }
                self.isSwitchingSession = true
                await self.startNewAgentSession()
                self.sessionNeedsHistoryContext = needsHistory
                self.isSwitchingSession = false
            }
        }
        schedulePersist()
    }

    // MARK: - 清除记忆

    /// 清除"当前这个对话"的记忆：之前的消息仍然留在历史里可以往上翻看，
    /// 但 contextStartIndex 之前的内容绝不会再被塞进发给 agent 的 prompt；
    /// 同时重开一个全新的 agent session，让 agent 进程本身也彻底忘掉这些内容。
    func clearCurrentConversationMemory() {
        guard let idx = currentConversationIndex else { return }
        conversations[idx].contextStartIndex = messages.count
        appendSystem("已清除当前对话的记忆：以上消息仍可查看，但不会再发给 Agent。")
        sessionNeedsHistoryContext = false
        syncCurrentConversation()
        schedulePersist()
        Task { [weak self] in
            guard let self else { return }
            self.isSwitchingSession = true
            await self.startNewAgentSession()
            self.isSwitchingSession = false
        }
    }

    /// 清除全部跨会话研究记忆（不影响任何会话自己的聊天记录）。
    func clearAllResearchMemories() {
        memories.removeAll()
        appendSystem("已清除全部跨会话研究记忆。")
        schedulePersist()
    }

    func setMemoryEnabled(_ enabled: Bool) {
        memoryEnabled = enabled
        schedulePersist()
    }

    // MARK: - 私有：持久化

    private func loadArchive() {
        do {
            let dir = SwiftDataConversationStore.defaultDirectoryURL
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let store = try SwiftDataConversationStore()
            self.store = store
            applyArchive(try store.load())
        } catch {
            // 打开失败要明确告知用户，不能悄悄换成内存存储——本次运行仍然可用，
            // 只是这次的会话记录不会落盘。
            appendSystem("本地会话存储打开失败：\(error.localizedDescription)（本次运行的会话记录不会保存）")
            self.store = try? SwiftDataConversationStore(inMemory: true)
            applyArchive(ConversationArchive())
        }
    }

    private func applyArchive(_ archive: ConversationArchive) {
        memories = archive.memories
        memoryEnabled = archive.memoryEnabled
        if archive.conversations.isEmpty {
            let fresh = SavedConversation()
            conversations = [fresh]
            currentConversationID = fresh.id
        } else {
            // 旧版本会把没识别的 session/update（主要是 usage_update）当系统消息存进
            // 历史里，读档时顺手清掉。
            conversations = archive.conversations.map { conversation in
                var cleaned = conversation
                cleaned.messages.removeAll { $0.role == .system && $0.text.hasPrefix("[未处理的 update]") }
                return cleaned
            }
            currentConversationID =
                archive.selectedConversationID.flatMap { id in conversations.first { $0.id == id }?.id }
                ?? conversations.max(by: { $0.updatedAt < $1.updatedAt })?.id
                ?? conversations[0].id
        }
        loadCurrentConversationIntoLiveState()
    }

    private func loadCurrentConversationIntoLiveState() {
        guard let idx = currentConversationIndex else { return }
        messages = conversations[idx].messages
        toolTrajectory = conversations[idx].toolTrajectory
    }

    private var currentConversationIndex: Int? {
        conversations.firstIndex { $0.id == currentConversationID }
    }

    /// 当前会话的快照：把还没写回 `conversations` 数组的最新 messages/toolTrajectory
    /// 合并进去。用于给 ResearchContext.prompt 提供"这条新消息之前"的历史。
    private func snapshot() -> SavedConversation {
        guard let idx = currentConversationIndex else {
            var fresh = SavedConversation(id: currentConversationID)
            fresh.messages = messages
            fresh.toolTrajectory = toolTrajectory
            return fresh
        }
        var conversation = conversations[idx]
        conversation.messages = messages
        conversation.toolTrajectory = toolTrajectory
        return conversation
    }

    private func syncCurrentConversation() {
        guard let idx = currentConversationIndex else { return }
        conversations[idx].messages = messages
        conversations[idx].toolTrajectory = toolTrajectory
        conversations[idx].updatedAt = Date()
        if conversations[idx].title == "新会话", let firstUser = messages.first(where: { $0.role == .user }) {
            let trimmed = firstUser.text.trimmingCharacters(in: .whitespacesAndNewlines)
            conversations[idx].title = trimmed.isEmpty ? "新会话" : String(trimmed.prefix(24))
        }
    }

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            self.persistNow()
        }
    }

    private func persistNow() {
        guard let store else { return }
        var archive = ConversationArchive()
        archive.conversations = conversations
        archive.memories = memories
        archive.selectedConversationID = currentConversationID
        archive.memoryEnabled = memoryEnabled
        do {
            try store.save(archive)
        } catch {
            appendSystem("保存会话失败：\(error.localizedDescription)")
        }
    }

    private func recordResearchMemory(question: String) {
        guard memoryEnabled, let id = currentAssistantMessageId,
              let answer = messages.first(where: { $0.id == id })?.text
        else { return }
        guard
            let memory = ResearchContext.memory(
                id: UUID().uuidString, conversationID: currentConversationID,
                question: question, answer: answer, date: Date())
        else { return }
        memories.append(memory)
    }

    // MARK: - 私有：agent session 生命周期

    private func startNewAgentSession() async {
        do {
            statusText = "创建会话..."
            let newSessionId = try await connection.newSession(cwd: workingDirectory)
            sessionId = newSessionId
            // 新 session 的上下文是空的，但下一条消息会把这条会话的历史重新带上，
            // 所以先显示上次的用量（标成"上次"）比显示空白更接近实际。
            usage = currentConversationIndex.flatMap { conversations[$0].lastUsage }
            usageIsStale = usage != nil
            statusText = "已连接（session \(newSessionId.prefix(8))…）"
        } catch {
            statusText = "会话创建失败: \(error)"
            appendSystem("会话创建失败：\(error)")
        }
    }

    // MARK: - 私有：更新流处理

    private func handle(_ update: ACPConnection.AgentUpdate) {
        switch update.kind {
        case .agentMessageChunk(let text):
            appendOrExtendAssistant(text)
        case .agentThoughtChunk:
            break // v0.1.0 不展示 reasoning，手册 11.7 节说这是可折叠/可隐藏的
        case .toolCall(let callId, let name, let title, let kind, let status, let rawInput):
            let record = ToolTrajectoryRecord(
                id: callId,
                index: toolTrajectory.count + 1,
                name: name,
                title: title,
                kind: kind,
                status: ToolTrajectoryRecord.Status(rawValue: status ?? "pending") ?? .pending,
                rawInput: rawInput,
                rawOutput: nil,
                startedAt: Date(),
                completedAt: nil)
            toolTrajectory.append(record)
            // 聊天区不再直接打一行摘要文字，只留一个可点的引用条——完整信息
            // 都在"轨迹"标签里，两边共享同一条 record，靠 callId 关联。
            messages.append(ChatMessage(id: UUID().uuidString, role: .toolRef, toolCallId: callId))
        case .toolCallUpdate(let callId, let title, let status, let rawOutput):
            guard let index = toolTrajectory.firstIndex(where: { $0.id == callId }) else { break }
            if let title { toolTrajectory[index].title = title }
            if let rawOutput { toolTrajectory[index].rawOutput = rawOutput }
            if let status, let parsed = ToolTrajectoryRecord.Status(rawValue: status) {
                toolTrajectory[index].status = parsed
                if parsed == .completed || parsed == .failed {
                    toolTrajectory[index].completedAt = Date()
                }
            }
        case .usage(let used, let size, let costAmount, let costCurrency):
            let latest = SessionUsage(used: used, size: size, costAmount: costAmount, costCurrency: costCurrency)
            usage = latest
            usageIsStale = false
            if let idx = currentConversationIndex { conversations[idx].lastUsage = latest }
            schedulePersist()
            return
        case .other:
            // available_commands_update / current_mode_update 之类暂时用不上的通知：
            // 静默忽略，不再往聊天区里打一行 "[未处理的 update] …"。
            return
        }
        syncCurrentConversation()
        schedulePersist()
    }

    private func appendOrExtendAssistant(_ chunk: String) {
        if let id = currentAssistantMessageId,
           let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].text += chunk
        } else {
            let id = UUID().uuidString
            currentAssistantMessageId = id
            messages.append(ChatMessage(id: id, role: .assistant, text: chunk))
        }
    }

    private func appendSystem(_ text: String) {
        messages.append(ChatMessage(id: UUID().uuidString, role: .system, text: text))
    }

    func stop() {
        updatesTask?.cancel()
        persistTask?.cancel()
        persistNow()
        Task { await connection.terminate() }
    }
}

/// 一次 `usage_update` 的快照：上下文窗口用了多少、总共多大，以及（agent 愿意给的话）
/// 会话累计费用。
struct SessionUsage: Equatable, Codable {
    let used: Int
    let size: Int
    let costAmount: Double?
    let costCurrency: String?

    var fraction: Double { size > 0 ? min(1, Double(used) / Double(size)) : 0 }
    var remaining: Int { max(0, size - used) }

    /// 10561 -> "10.6k"，1000000 -> "1M"
    static func compact(_ tokens: Int) -> String {
        switch tokens {
        case ..<1000: return "\(tokens)"
        case ..<1_000_000:
            let k = Double(tokens) / 1000
            return k < 100 ? String(format: "%.1fk", k) : String(format: "%.0fk", k)
        default:
            let m = Double(tokens) / 1_000_000
            return m.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0fM", m) : String(format: "%.2fM", m)
        }
    }
}
