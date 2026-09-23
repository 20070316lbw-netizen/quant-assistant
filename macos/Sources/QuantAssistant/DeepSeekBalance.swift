import Foundation

/// DeepSeek 账户余额（`GET https://api.deepseek.com/user/balance`）。
/// 响应格式照官方文档 api-docs.deepseek.com/api/get-user-balance 核对过：
/// `{is_available: Bool, balance_infos: [{currency, total_balance, granted_balance,
/// topped_up_balance}]}`，几个金额字段是字符串不是数字。
struct DeepSeekBalance: Equatable {
    struct Entry: Equatable {
        let currency: String
        let total: Decimal
        let granted: Decimal
        let toppedUp: Decimal
    }

    let isAvailable: Bool
    let entries: [Entry]
    let fetchedAt: Date

    /// 状态栏上显示哪一个币种：优先人民币。
    var primary: Entry? { entries.first { $0.currency == "CNY" } ?? entries.first }

    static let endpoint = URL(string: "https://api.deepseek.com/user/balance")!

    enum FetchError: LocalizedError {
        case http(Int)
        case malformed
        var errorDescription: String? {
            switch self {
            case .http(401), .http(403): return "API key 无效或没有权限（HTTP 401/403）"
            case .http(let code): return "余额接口返回 HTTP \(code)"
            case .malformed: return "余额接口返回的格式看不懂"
            }
        }
    }

    static func parse(_ data: Data, fetchedAt: Date = Date()) throws -> DeepSeekBalance {
        struct Raw: Decodable {
            struct Info: Decodable {
                let currency: String
                let total_balance: String
                let granted_balance: String?
                let topped_up_balance: String?
            }
            let is_available: Bool
            let balance_infos: [Info]
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else { throw FetchError.malformed }
        func number(_ s: String?) -> Decimal { s.flatMap { Decimal(string: $0) } ?? 0 }
        let entries = try raw.balance_infos.map { info -> Entry in
            guard let total = Decimal(string: info.total_balance) else { throw FetchError.malformed }
            return Entry(
                currency: info.currency, total: total,
                granted: number(info.granted_balance), toppedUp: number(info.topped_up_balance))
        }
        return DeepSeekBalance(isAvailable: raw.is_available, entries: entries, fetchedAt: fetchedAt)
    }

    static func fetch(apiKey: String, session: URLSession = .shared) async throws -> DeepSeekBalance {
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FetchError.http(http.statusCode)
        }
        return try parse(data)
    }

    static func format(_ amount: Decimal, currency: String) -> String {
        let symbol = ["CNY": "¥", "USD": "$"][currency] ?? "\(currency) "
        let number = NSDecimalNumber(decimal: amount).doubleValue
        return symbol + String(format: "%.2f", number)
    }
}
