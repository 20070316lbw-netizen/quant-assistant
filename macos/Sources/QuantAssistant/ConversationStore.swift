import Foundation
import SwiftData

@MainActor
protocol ConversationStorage {
    func load() throws -> ConversationArchive
    func save(_ archive: ConversationArchive) throws
}

/// 整个归档保存为一条快照，记忆删除和聊天上下文截断在同一事务生效。
@Model
final class ConversationSnapshotRecord {
    @Attribute(.unique) var key: String
    var formatVersion: Int
    var payload: Data

    init(payload: Data) {
        key = "archive"
        formatVersion = 1
        self.payload = payload
    }
}

@MainActor
final class SwiftDataConversationStore: ConversationStorage {
    static var defaultDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuantAssistant", isDirectory: true)
    }

    static var defaultStoreURL: URL {
        defaultDirectoryURL.appendingPathComponent("conversations.store")
    }

    private let container: ModelContainer
    private let context: ModelContext

    enum StoreError: LocalizedError {
        case invalidSnapshot
        case unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case .invalidSnapshot: return "本地会话归档包含重复或无效快照，已停止写入以保护原数据。"
            case .unsupportedVersion(let version): return "本地会话归档版本 \(version) 暂不受支持，已保留原数据。"
            }
        }
    }

    /// 目录由应用启动流程创建；打开失败直接上报，不能悄悄改用内存存储。
    init(url: URL? = nil, inMemory: Bool = false) throws {
        let schema = Schema([ConversationSnapshotRecord.self])
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            configuration = ModelConfiguration(schema: schema, url: url ?? Self.defaultStoreURL)
        }
        container = try ModelContainer(for: schema, configurations: [configuration])
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    func load() throws -> ConversationArchive {
        guard let record = try snapshot() else { return ConversationArchive() }
        return try decode(record)
    }

    func save(_ archive: ConversationArchive) throws {
        do {
            let record = try snapshot()
            // 即使调用方跳过 load，也不能把无法读取的旧快照当成空归档覆盖。
            if let record { _ = try decode(record) }
            let data = try JSONEncoder().encode(archive)
            if let record {
                record.payload = data
            } else {
                context.insert(ConversationSnapshotRecord(payload: data))
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    private func snapshot() throws -> ConversationSnapshotRecord? {
        let records = try context.fetch(FetchDescriptor<ConversationSnapshotRecord>())
        guard records.count <= 1, records.allSatisfy({ $0.key == "archive" }) else {
            throw StoreError.invalidSnapshot
        }
        return records.first
    }

    private func decode(_ record: ConversationSnapshotRecord) throws -> ConversationArchive {
        guard record.formatVersion == 1 else { throw StoreError.unsupportedVersion(record.formatVersion) }
        return try JSONDecoder().decode(ConversationArchive.self, from: record.payload)
    }
}
