import SwiftUI

/// "轨迹"标签：把工具调用从聊天气泡里搬出来，单独列成一条条可展开的记录——
/// 设计上抄的是 DSH 自己 web 前端的 TrajectoryView/TrajectoryTable（见
/// packages/client/ui-trajectory），那边是完整的事件溯源+分组+时间线，这里
/// 按体量砍成"按发生顺序的一条列表"，核心的"分开地方展示"原则先立住。
struct TrajectoryView: View {
    let records: [ToolTrajectoryRecord]
    let focusedId: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if records.isEmpty {
                        Text("还没有工具调用记录。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                    ForEach(records) { record in
                        TrajectoryRow(record: record, isFocused: record.id == focusedId)
                            .id(record.id)
                    }
                }
                .padding()
            }
            .onChange(of: focusedId) { _, newValue in
                guard let newValue else { return }
                withAnimation { proxy.scrollTo(newValue, anchor: .center) }
            }
        }
    }
}

private struct TrajectoryRow: View {
    let record: ToolTrajectoryRecord
    let isFocused: Bool
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let rawInput = record.rawInput {
                    detail(label: "输入", value: rawInput.prettyPrinted)
                }
                if let rawOutput = record.rawOutput {
                    detail(label: "输出", value: rawOutput.prettyPrinted)
                }
                if record.rawInput == nil && record.rawOutput == nil {
                    Text("（还没有输入/输出数据）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Text("#\(record.index)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title).font(.body)
                    if let name = record.name {
                        Text(name)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(record.durationText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(isFocused ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func detail(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch record.status {
        case .pending:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .inProgress:
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

/// 聊天气泡流里的工具调用引用条：只显示状态+标题一行，点一下跳到"轨迹"标签
/// 并高亮对应记录——取代原来直接在聊天里打一行 "[工具调用] xxx" 文字。
struct ToolCallChip: View {
    let record: ToolTrajectoryRecord
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                statusIcon
                Text(record.title).font(.caption)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.gray.opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch record.status {
        case .pending:
            Image(systemName: "clock").font(.caption2).foregroundStyle(.secondary)
        case .inProgress:
            Image(systemName: "arrow.triangle.2.circlepath").font(.caption2).foregroundStyle(.orange)
        case .completed:
            Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").font(.caption2).foregroundStyle(.red)
        }
    }
}
