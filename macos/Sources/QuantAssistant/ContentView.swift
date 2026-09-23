import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ChatViewModel()
    @State private var selectedTab: Tab = .chat
    @State private var showClearAllMemoriesConfirm = false
    @FocusState private var inputFocused: Bool
    @State private var showSettings = false

    private enum Tab: String, CaseIterable, Identifiable {
        case chat = "对话"
        case trajectory = "轨迹"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationSplitView {
            conversationSidebar
        } detail: {
            detail
        }
        .frame(minWidth: 760, minHeight: 460)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
        .confirmationDialog(
            "清除全部跨会话研究记忆？", isPresented: $showClearAllMemoriesConfirm, titleVisibility: .visible
        ) {
            Button("清除", role: .destructive) { viewModel.clearAllResearchMemories() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会清除 Agent 记住的、跨所有历史会话的研究摘要。各个会话自己的聊天记录不受影响。")
        }
    }

    // MARK: - 侧栏：历史会话列表

    private var conversationSidebar: some View {
        List(selection: Binding(
            get: { viewModel.currentConversationID },
            set: { if let id = $0 { viewModel.selectConversation(id) } }
        )) {
            ForEach(viewModel.conversations.sorted(by: { $0.updatedAt > $1.updatedAt })) { conversation in
                conversationRow(conversation).tag(conversation.id)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("会话历史")
        .toolbar {
            ToolbarItem {
                Button {
                    viewModel.newConversation()
                } label: {
                    Label("新会话", systemImage: "square.and.pencil")
                }
            }
        }
    }

    private func conversationRow(_ conversation: SavedConversation) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(conversation.title)
                .font(.body)
                .lineLimit(1)
            Text(conversation.updatedAt, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("删除", role: .destructive) { viewModel.deleteConversation(conversation.id) }
        }
        .swipeActions {
            Button("删除", role: .destructive) { viewModel.deleteConversation(conversation.id) }
        }
    }

    // MARK: - 详情：对话 / 轨迹

    private var detail: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(viewModel.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                BalanceBadge(viewModel: viewModel) { showSettings = true }
                Divider().frame(height: 12)
                UsageGauge(usage: viewModel.usage, isStale: viewModel.usageIsStale)
            }
            .padding(8)

            Divider()

            // 参照 DSH 自己 web 前端"对话/轨迹"两个标签的设计：日常对话跟工具
            // 调用的完整输入输出分开看，聊天区不再被工具调用的文字摘要打断。
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            Group {
                switch selectedTab {
                case .chat:
                    chatView
                case .trajectory:
                    TrajectoryView(records: viewModel.toolTrajectory, focusedId: viewModel.focusedToolCallId)
                }
            }
            .frame(maxHeight: .infinity)

            Divider()

            HStack(alignment: .bottom, spacing: 8) {
                // macOS 上 `.roundedBorder` 样式的 TextField 底层是单行 NSTextField，
                // 就算写了 axis: .vertical 也不会换行，内容长了只会往左滚、前面的字被挤出
                // 视野。换成 `.plain` 样式才会真的按行数长高，边框自己画。
                // 回车发送，⌥↩（Option+Return）换行——这是 AppKit 文本框的标准换行键；
                // 中文输入法选词时的回车由输入法消化，不会误发送。
                TextField("跟量化助手说点什么…（↩ 发送，⌥↩ 换行）", text: $viewModel.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($inputFocused)
                    .onSubmit { viewModel.send() }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(
                                inputFocused ? Color.accentColor : Color.secondary.opacity(0.35),
                                lineWidth: inputFocused ? 2 : 1))
                if viewModel.isSending {
                    // Agent 在跑的时候，发送按钮变成停止；Esc 也能停。
                    Button {
                        viewModel.cancel()
                    } label: {
                        Label(viewModel.isCancelling ? "停止中…" : "停止", systemImage: "stop.fill")
                    }
                    .keyboardShortcut(.cancelAction)
                    .tint(.red)
                    .disabled(viewModel.isCancelling)
                    .help("停止当前这一轮（Esc）")
                    .padding(.bottom, 3)
                } else {
                    Button("发送") { viewModel.send() }
                        .disabled(
                            viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || viewModel.isSwitchingSession)
                        .padding(.bottom, 3)
                }
            }
            .padding(8)
        }
        .toolbar {
            ToolbarItem {
                memoryMenu
            }
            ToolbarItem {
                Button {
                    showSettings = true
                } label: {
                    Label("设置", systemImage: "key")
                }
                .help("DeepSeek API key（存在钥匙串里）")
            }
        }
        .sheet(isPresented: $showSettings) {
            APIKeySettingsView(viewModel: viewModel)
        }
    }

    /// "记忆"菜单：跨会话研究记忆的开关、清除当前对话记忆、清除全部研究记忆。
    /// 两种"清除"分别对应 ConversationModels 里两种独立的记忆概念——
    /// 当前对话的 contextStartIndex（本会话不再重发的历史）和全局 memories 数组
    /// （跨会话的研究摘要）。
    private var memoryMenu: some View {
        Menu {
            Toggle(
                "启用跨会话研究记忆",
                isOn: Binding(
                    get: { viewModel.memoryEnabled },
                    set: { viewModel.setMemoryEnabled($0) }
                ))
            Divider()
            Button("清除当前对话记忆") { viewModel.clearCurrentConversationMemory() }
            Button("清除全部研究记忆…", role: .destructive) { showClearAllMemoriesConfirm = true }
            Divider()
            Text("已记住 \(viewModel.memories.count) 条过往研究")
                .foregroundStyle(.secondary)
        } label: {
            Label("记忆", systemImage: "brain")
        }
    }

    private var chatView: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(viewModel.messages) { message in
                        bubble(for: message).id(message.id)
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                if let lastId = viewModel.messages.last?.id {
                    withAnimation { scrollProxy.scrollTo(lastId, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func bubble(for message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                copyableText(message.text)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        case .assistant:
            HStack {
                Group {
                    if message.text.isEmpty {
                        Text("…")
                    } else {
                        MarkdownView(message.text)
                    }
                }
                .contextMenu { copyButton(message.text, title: "复制原文（Markdown）") }
                .padding(10)
                .background(Color.gray.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                Spacer(minLength: 40)
            }
        case .system:
            Text(message.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        case .toolRef:
            if let callId = message.toolCallId,
               let record = viewModel.toolTrajectory.first(where: { $0.id == callId }) {
                ToolCallChip(record: record) {
                    viewModel.focusedToolCallId = callId
                    selectedTab = .trajectory
                }
            }
        }
    }

    /// 聊天气泡里的文字：既能像正常文本一样框选（`.textSelection`，SwiftUI
    /// 的 `Text` 默认是不可选的），也在右键菜单里放了一个直接写系统粘贴板的
    /// "复制"——不依赖菜单栏的 Edit>Copy 快捷键路由，`swift run` 起的裸可执行
    /// 文件如果哪天菜单栏没搭对，这个也不受影响。
    private func copyableText(_ text: String) -> some View {
        Text(text)
            .textSelection(.enabled)
            .contextMenu { copyButton(text, title: "复制") }
    }

    private func copyButton(_ text: String, title: String) -> some View {
        Button(title) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

/// 状态栏右侧的用量仪表盘：当前 agent session 的上下文窗口用了多少（ACP `usage_update`）。
/// 鼠标悬停看精确数字；agent 给了累计费用就一起显示。还没收到过用量时显示占位。
struct UsageGauge: View {
    let usage: SessionUsage?
    var isStale: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Text("上下文")
            // 进度条始终画出来：还没有数据时是一根空条，一眼能看出这里是仪表盘，
            // 而不是只有一个"—"让人以为功能没做。
            ProgressView(value: usage?.fraction ?? 0)
                .progressViewStyle(.linear)
                .tint(tint(usage?.fraction ?? 0))
                .frame(width: 110)
                .opacity(isStale ? 0.5 : 1)
            if let usage {
                Text("\(SessionUsage.compact(usage.used)) / \(SessionUsage.compact(usage.size))")
                    .monospacedDigit()
                if let amount = usage.costAmount {
                    Text(String(format: "%.4f %@", amount, usage.costCurrency ?? ""))
                        .monospacedDigit()
                }
                if isStale {
                    Text("上次").foregroundStyle(.tertiary)
                }
            } else {
                Text("发消息后显示").foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(helpText)
    }

    private var helpText: String {
        guard let usage else { return "发出第一条消息后，这里显示当前会话已经占用了多少上下文窗口" }
        let percent = String(format: "%.1f%%", usage.fraction * 100)
        let base = "上下文已用 \(usage.used) / \(usage.size) tokens（\(percent)），还剩 \(usage.remaining)。"
        return isStale ? base + "这是这条会话上次的数据，发下一条消息后刷新。" : base
    }

    private func tint(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.6: return .accentColor
        case ..<0.85: return .orange
        default: return .red
        }
    }
}

/// 状态栏里的账户余额：点一下刷新；没存 key 时变成"设置 API key"入口。
struct BalanceBadge: View {
    @ObservedObject var viewModel: ChatViewModel
    let openSettings: () -> Void

    var body: some View {
        Group {
            if viewModel.apiKeyMasked == nil {
                Button("设置 API key 查看余额", action: openSettings)
                    .buttonStyle(.link)
            } else if let entry = viewModel.balance?.primary {
                Button {
                    viewModel.refreshBalance()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: viewModel.balance?.isAvailable == false
                              ? "exclamationmark.triangle.fill" : "yensign.circle")
                            .foregroundStyle(viewModel.balance?.isAvailable == false ? .orange : .secondary)
                        Text("余额 \(DeepSeekBalance.format(entry.total, currency: entry.currency))")
                            .monospacedDigit()
                        if viewModel.isRefreshingBalance { ProgressView().controlSize(.mini) }
                    }
                }
                .buttonStyle(.plain)
                .help(balanceHelp(entry))
            } else if let error = viewModel.balanceError {
                Button {
                    viewModel.refreshBalance()
                } label: {
                    Label("余额查询失败", systemImage: "exclamationmark.circle")
                }
                .buttonStyle(.plain)
                .help("\(error)\n点一下重试。")
            } else {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("查询余额…")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func balanceHelp(_ entry: DeepSeekBalance.Entry) -> String {
        var lines = [
            "DeepSeek 账户余额 \(DeepSeekBalance.format(entry.total, currency: entry.currency))",
            "其中充值 \(DeepSeekBalance.format(entry.toppedUp, currency: entry.currency))，"
                + "赠送 \(DeepSeekBalance.format(entry.granted, currency: entry.currency))",
        ]
        if viewModel.balance?.isAvailable == false { lines.append("余额不足，API 调用可能会失败。") }
        if let fetched = viewModel.balance?.fetchedAt {
            lines.append("更新于 \(fetched.formatted(date: .omitted, time: .shortened))，每轮回答结束后自动刷新，点一下手动刷新。")
        }
        return lines.joined(separator: "\n")
    }
}

/// 设置 DeepSeek API key：只在钥匙串里保存，界面上只显示脱敏后的尾号。
struct APIKeySettingsView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("DeepSeek API key").font(.headline)

            if let masked = viewModel.apiKeyMasked {
                HStack {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("已保存在钥匙串：\(masked)").monospaced()
                    Spacer()
                    Button("删除", role: .destructive) { viewModel.deleteAPIKey() }
                }
            } else {
                Text("还没有保存。").foregroundStyle(.secondary)
            }

            SecureField(viewModel.apiKeyMasked == nil ? "粘贴 sk-… 开头的 key" : "粘贴新 key 以替换", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)

            if let error = viewModel.balanceError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let entry = viewModel.balance?.primary {
                Label("验证通过，余额 \(DeepSeekBalance.format(entry.total, currency: entry.currency))",
                      systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            Text("""
            key 只存在 macOS 钥匙串里，不写进任何文件。它用来查询账户余额；启动时也会作为 \
            DEEPSEEK_API_KEY 传给 dsh，但 dsh 会优先用它自己已保存的凭据，只有没配置时才用这个。\
            换了 key 之后重启 App 才会传给 dsh。
            """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func save() {
        viewModel.saveAPIKey(draft)
        draft = ""
    }
}
