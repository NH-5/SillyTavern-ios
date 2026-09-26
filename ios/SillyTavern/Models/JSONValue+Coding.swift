import Foundation

extension JSONValue {
    /// 序列化成 JSON 数据。
    ///
    /// 没有用 `JSONEncoder`：它对嵌套的 `[String: JSONValue]` 会走 `encode(to:)`
    /// 的容器路径，行为正确但输出不带格式化，且这里需要保证 `.null` 之类的
    /// 边界值不抛错。手写序列化更可控，也便于保持键顺序无关的稳定输出。
    func encoded() throws -> Data {
        var out = ""
        write(into: &out)
        guard let data = out.data(using: .utf8) else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(codingPath: [], debugDescription: "无法编码为 UTF-8")
            )
        }
        return data
    }

    private func write(into out: inout String) {
        switch self {
        case .string(let value):
            out += JSONValue.quote(value)
        case .integer(let value):
            out += String(value)
        case .number(let value):
            // 避免输出 "1.0" 这种在部分服务端会被拒的写法：整数值按整数输出。
            if value.isFinite {
                if value == value.rounded(), abs(value) < 1e15 {
                    out += String(Int(value))
                } else {
                    out += String(value)
                }
            } else {
                out += "null"
            }
        case .bool(let value):
            out += value ? "true" : "false"
        case .null:
            out += "null"
        case .array(let values):
            out += "["
            for (index, value) in values.enumerated() {
                if index > 0 { out += "," }
                value.write(into: &out)
            }
            out += "]"
        case .object(let values):
            out += "{"
            var first = true
            for key in values.keys.sorted() {
                guard let value = values[key] else { continue }
                if !first { out += "," }
                first = false
                out += JSONValue.quote(key)
                out += ":"
                value.write(into: &out)
            }
            out += "}"
        }
    }

    /// JSON 字符串转义。
    private static func quote(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}
