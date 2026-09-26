import Foundation

/// Token 数量估算。
///
/// SillyTavern 服务端用 tiktoken 精确分词（`src/endpoints/tokenizers.js`），
/// 在 iOS 上内置 BPE 词表代价太大，因此这里复刻它**无 tokenizer 时的回退算法**
/// 并做了一点针对中文的修正。
///
/// 关键公式（`src/endpoints/tokenizers.js:440-538`，客户端再 -2）：
/// 单条消息净开销 = role + content + (有 name 则 1 + name) + 4。
enum TokenEstimator {
    /// 每条消息的固定结构开销（对应 ST 的 tokensPerMessage=3 加聊天层 padding）。
    static let perMessageOverhead = 4
    /// 带 name 字段时额外增加的开销（字段本身）。
    static let perNameOverhead = 1

    /// 估算一段文本的 token 数。
    ///
    /// ST 的回退公式是 `ceil(utf8字节数 / 3.35)`，那是为英文调的。
    /// 中文一个字 3 字节，用同一公式会明显低估，因此这里按字符类别分别处理：
    /// - CJK 等宽字符：1 字符 ≈ 1 token（BPE 里通常 1-2 token，取偏保守的 1）；
    /// - 其余非 ASCII（拉丁扩展、西里尔、emoji 等）：按 2 字节 ≈ 1 token；
    /// - 纯 ASCII：沿用 ST 的 字节数 / 3.35。
    static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }

        var asciiBytes = 0
        var wideCharacters = 0
        var narrowUnicodeBytes = 0

        for scalar in text.unicodeScalars {
            if scalar.isASCII {
                asciiBytes += 1
            } else if isWideCharacter(scalar) {
                wideCharacters += 1
            } else {
                narrowUnicodeBytes += scalar.utf8.count
            }
        }

        let asciiTokens = Double(asciiBytes) / 3.35
        let narrowTokens = Double(narrowUnicodeBytes) / 2.0
        let total = asciiTokens + narrowTokens + Double(wideCharacters)
        return max(1, Int(total.rounded(.up)))
    }

    /// 估算一整组消息占用的 token 数（含每条消息的结构开销）。
    static func estimate(messages: [ChatCompletionMessage]) -> Int {
        messages.reduce(0) { total, message in
            var cost = perMessageOverhead
            cost += estimate(message.role)
            cost += estimate(message.flatContent)
            if let name = message.name, !name.isEmpty {
                cost += perNameOverhead + estimate(name)
            }
            return total + cost
        }
    }

    /// 是否为「一个字约等于一个 token」的表意文字。
    private static func isWideCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F,       // 谚文字母
             0x2E80...0x303E,       // 中日韩部首、标点
             0x3041...0x33FF,       // 平假名、片假名、注音
             0x3400...0x4DBF,       // 中日韩扩展 A
             0x4E00...0x9FFF,       // 中日韩统一表意文字
             0xA000...0xA4CF,       // 彝文
             0xAC00...0xD7A3,       // 谚文音节
             0xF900...0xFAFF,       // 兼容表意文字
             0xFE30...0xFE4F,       // 兼容形式
             0xFF00...0xFF60,       // 全角形式
             0xFFE0...0xFFE6,
             0x20000...0x2FA1F:     // 中日韩扩展 B 及以后
            return true
        default:
            return false
        }
    }
}
