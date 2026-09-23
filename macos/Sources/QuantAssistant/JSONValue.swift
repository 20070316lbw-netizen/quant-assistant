// 一个最小的“任意 JSON”类型：ACP 协议里 params/result 的具体形状随 method 变化，
// 用一个通用 JSONValue 收进来，再按需要的字段手动解出来，比给每个 method 都定义
// 一整棵 Codable 结构体树要省事得多——尤其是我们目前只关心其中一小部分字段。
enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// 按 `["a"]["b"]` 这样的路径取字符串字段；取不到就返回 nil，不抛异常——
    /// 协议字段大多是可选的，调用方通常只想“有就用，没有就算了”。
    subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .number(let value) = self, value.isFinite { return Int(value) }
        return nil
    }
}

/// 给轨迹面板用的一个简单缩进打印，不追求跟标准 JSON.stringify 字节对齐，
/// 只要人能看清嵌套结构就行——手册目前也没要求这个格式要机器可解析回去。
extension JSONValue {
    var prettyPrinted: String {
        render(indent: 0)
    }

    private func render(indent: Int) -> String {
        let pad = String(repeating: "  ", count: indent)
        let childPad = String(repeating: "  ", count: indent + 1)
        switch self {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .number(let value):
            return value.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(value)) : String(value)
        case .string(let value):
            return "\"\(value)\""
        case .array(let items):
            if items.isEmpty { return "[]" }
            let body = items
                .map { childPad + $0.render(indent: indent + 1) }
                .joined(separator: ",\n")
            return "[\n\(body)\n\(pad)]"
        case .object(let dict):
            if dict.isEmpty { return "{}" }
            let body = dict.sorted { $0.key < $1.key }
                .map { "\(childPad)\"\($0.key)\": \($0.value.render(indent: indent + 1))" }
                .joined(separator: ",\n")
            return "{\n\(body)\n\(pad)}"
        }
    }
}
