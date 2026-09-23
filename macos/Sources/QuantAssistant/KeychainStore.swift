import Foundation
import Security

/// DeepSeek API key 存在系统钥匙串里（手册 14.1 节：不写进源码、不写进配置文件、
/// 不要求每次启动前 `export`）。用的是传统的"登录"钥匙串 generic password：
/// 裸 `swift run` 可执行文件没有 entitlements，用不了 data-protection 钥匙串。
///
/// 注意：钥匙串按代码签名认"是谁存的"。开发期间每次重新编译签名都会变，
/// macOS 可能弹窗问"是否允许 QuantAssistant 访问钥匙串"，点"始终允许"即可。
struct KeychainStore {
    let service: String
    let account: String

    static let deepSeek = KeychainStore(service: "QuantAssistant.DeepSeek", account: "api-key")

    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)
        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
                return "钥匙串操作失败（\(status)）：\(message)"
            }
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ secret: String) throws {
        let data = Data(secret.utf8)
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError.unexpectedStatus(update) }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "QuantAssistant DeepSeek API key"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// 给界面显示用："sk-…a1b2"。永远不显示完整 key。
    static func masked(_ key: String) -> String {
        let tail = key.suffix(4)
        let head = key.hasPrefix("sk-") ? "sk-" : ""
        return "\(head)…\(tail)"
    }
}
