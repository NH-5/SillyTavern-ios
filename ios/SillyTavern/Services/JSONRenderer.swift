import Foundation

/// JSON 渲染工具。
///
/// 为什么不直接用 `JSONSerialization` 的 `.prettyPrinted`：
/// 它输出的是 **2 空格缩进 + `"key" : value`**（冒号前带空格），
/// 而 SillyTavern 用 `JSON.stringify(data, null, 4)` 输出 **4 空格 + `"key": value`**。
/// 为了让导出的世界书文件与 ST 生成的逐字一致（便于 diff 与人工比对），
/// 这里自己实现渲染。
///
/// 另一个坑：Swift 的 `JSONEncoder` / `JSONSerialization` 默认把 `/` 转义成 `\/`，
/// 而 JavaScript 不转义。这里统一不转义，保持与 ST 输出一致。
enum JSONRenderer {
    /// 紧凑输出（聊天记录 JSONL 用）。
    static func compact(_ value: Any) -> String {
        var out = ""
        write(value, into: &out, indent: nil, level: 0)
        return out
    }

    /// 4 空格缩进输出（世界书文件用）。
    static func pretty(_ value: Any, indentWidth: Int = 4) -> String {
        var out = ""
        write(value, into: &out, indent: indentWidth, level: 0)
        return out
    }

    // MARK: - 内部

    private static func write(_ value: Any, into out: inout String, indent: Int?, level: Int) {
        switch value {
        case let string as String:
            out += quote(string)

        case let number as NSNumber:
            // 先判布尔：NSNumber 会同时匹配数值类型。
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                out += number.boolValue ? "true" : "false"
            } else {
                out += numberString(number)
            }

        case let bool as Bool:
            out += bool ? "true" : "false"

        case let int as Int:
            out += String(int)

        case let double as Double:
            if double.isFinite {
                if double == double.rounded(), abs(double) < 1e15 {
                    out += String(Int(double))
                } else {
                    out += String(double)
                }
            } else {
                out += "null"
            }

        case let array as [Any]:
            writeArray(array, into: &out, indent: indent, level: level)

        case let dictionary as [String: Any]:
            writeObject(dictionary, into: &out, indent: indent, level: level)

        case is NSNull:
            out += "null"

        default:
            out += "null"
        }
    }

    private static func writeArray(_ array: [Any], into out: inout String, indent: Int?, level: Int) {
        if array.isEmpty {
            out += "[]"
            return
        }
        out += "["
        for (index, item) in array.enumerated() {
            if index > 0 { out += "," }
            newline(into: &out, indent: indent, level: level + 1)
            write(item, into: &out, indent: indent, level: level + 1)
        }
        newline(into: &out, indent: indent, level: level)
        out += "]"
    }

    private static func writeObject(_ object: [String: Any], into out: inout String, indent: Int?, level: Int) {
        if object.isEmpty {
            out += "{}"
            return
        }
        out += "{"
        // 按键排序，保证同样数据每次输出一致，便于回归比对。
        for (index, key) in object.keys.sorted().enumerated() {
            guard let value = object[key] else { continue }
            if index > 0 { out += "," }
            newline(into: &out, indent: indent, level: level + 1)
            out += quote(key)
            out += ":"
            if indent != nil { out += " " }
            write(value, into: &out, indent: indent, level: level + 1)
        }
        newline(into: &out, indent: indent, level: level)
        out += "}"
    }

    private static func newline(into out: inout String, indent: Int?, level: Int) {
        guard let indent else { return }
        out += "\n"
        out += String(repeating: " ", count: indent * level)
    }

    /// 数字输出：整数按整数写，避免 `1.0` 这种在部分服务端会被拒的写法。
    private static func numberString(_ number: NSNumber) -> String {
        let double = number.doubleValue
        guard double.isFinite else { return "null" }
        if double == double.rounded(), abs(double) < 1e15 {
            return String(number.int64Value)
        }
        return String(double)
    }

    /// JSON 字符串转义。**不转义 `/`**，与 JavaScript 的 `JSON.stringify` 一致。
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

/// Base64 编解码的容错封装。
///
/// `Data(base64Encoded:)` 只在 **标准字母表 + padding 完整** 时成功：
/// - 缺 padding（很多角色卡网站会截掉 `=`）直接返回 nil；
/// - 含换行时即便带 `.ignoreUnknownCharacters` 也可能失败；
/// - URL-safe 的 `-` / `_` 不在标准字母表里。
///
/// 角色卡生态里这几种写法都真实存在，因此这里统一先归一化再解码。
enum Base64 {
    /// 宽容解码：自动补 padding、把 URL-safe 字符换成标准字符、丢弃空白。
    static func decode(_ text: String) -> Data? {
        var normalized = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()

        // 补 padding 到 4 的倍数。
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }

        return Data(base64Encoded: normalized, options: [.ignoreUnknownCharacters])
    }

    /// 标准 base64 编码（带 padding），与 ST 写入 PNG 时的形式一致。
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
    }
}
