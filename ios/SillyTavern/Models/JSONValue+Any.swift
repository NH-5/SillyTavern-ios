import Foundation

extension JSONValue {
    /// 转回 Swift 原生值，用于交给 `JSONSerialization` 序列化。
    ///
    /// 导出角色卡走的是 `JSONSerialization`（而不是 `JSONEncoder`），
    /// 因为需要把 `extensions` 这种结构不固定的字典原样透传，
    /// 混合使用两套编码器容易出现「编码后结构变了」的意外。
    var anyValue: Any {
        switch self {
        case .string(let value): return value
        case .integer(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .null: return NSNull()
        case .array(let values): return values.map { $0.anyValue }
        case .object(let values):
            var object: [String: Any] = [:]
            for (key, value) in values {
                object[key] = value.anyValue
            }
            return object
        }
    }

    /// 从 Swift 原生值构造（`JSONSerialization` 解出来的类型）。
    static func from(_ any: Any) -> JSONValue {
        switch any {
        case let value as String:
            return .string(value)
        case let value as Bool:
            return .bool(value)
        case let value as Int:
            return .integer(value)
        case let value as Double:
            return .number(value)
        case let value as NSNumber:
            // NSNumber 会同时匹配上面的 Int/Double/Bool，这里做兜底判定。
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            let doubleValue = value.doubleValue
            if doubleValue == doubleValue.rounded(), abs(doubleValue) < 1e15 {
                return .integer(Int(doubleValue))
            }
            return .number(doubleValue)
        case let value as [Any]:
            return .array(value.map { JSONValue.from($0) })
        case let value as [String: Any]:
            var object: [String: JSONValue] = [:]
            for (key, item) in value {
                object[key] = JSONValue.from(item)
            }
            return .object(object)
        case is NSNull:
            return .null
        default:
            return .null
        }
    }
}
