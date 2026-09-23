import Foundation
import XCTest
@testable import QuantAssistant

final class DeepSeekBalanceTests: XCTestCase {
    /// 字段照官方文档 api-docs.deepseek.com/api/get-user-balance：金额是字符串。
    func testParseOfficialShape() throws {
        let json = #"""
        {"is_available": true, "balance_infos": [
          {"currency": "USD", "total_balance": "1.50", "granted_balance": "0.00", "topped_up_balance": "1.50"},
          {"currency": "CNY", "total_balance": "110.00", "granted_balance": "10.00", "topped_up_balance": "100.00"}
        ]}
        """#
        let balance = try DeepSeekBalance.parse(Data(json.utf8))
        XCTAssertTrue(balance.isAvailable)
        XCTAssertEqual(balance.entries.count, 2)
        XCTAssertEqual(balance.primary?.currency, "CNY") // 优先人民币
        XCTAssertEqual(balance.primary?.total, Decimal(string: "110.00"))
        XCTAssertEqual(balance.primary?.granted, 10)
        XCTAssertEqual(DeepSeekBalance.format(balance.primary!.total, currency: "CNY"), "¥110.00")
        XCTAssertEqual(DeepSeekBalance.format(Decimal(string: "1.5")!, currency: "USD"), "$1.50")
    }

    func testMalformedRejected() {
        XCTAssertThrowsError(try DeepSeekBalance.parse(Data(#"{"error":"nope"}"#.utf8)))
        XCTAssertThrowsError(try DeepSeekBalance.parse(Data(
            #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"abc"}]}"#.utf8)))
    }

    func testMaskedKeyNeverShowsMiddle() {
        XCTAssertEqual(KeychainStore.masked("sk-1234567890abcdef"), "sk-…cdef")
        XCTAssertEqual(KeychainStore.masked("abcd1234"), "…1234")
    }

    /// 真钥匙串读写一遍（用单独的 service，不碰 App 的那一条）。
    func testKeychainRoundTrip() throws {
        let store = KeychainStore(service: "QuantAssistant.Tests.\(UUID().uuidString)", account: "t")
        defer { try? store.delete() }
        XCTAssertNil(try store.load())
        try store.save("sk-first")
        XCTAssertEqual(try store.load(), "sk-first")
        try store.save("sk-second")
        XCTAssertEqual(try store.load(), "sk-second")
        try store.delete()
        XCTAssertNil(try store.load())
    }
}
