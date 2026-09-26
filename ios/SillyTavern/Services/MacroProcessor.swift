import Foundation

/// 宏替换的取值上下文。
struct MacroContext {
    var charName: String = ""
    var userName: String = ""
    var description: String = ""
    var personality: String = ""
    var scenario: String = ""
    var persona: String = ""
    var mesExamples: String = ""
    var mesExamplesRaw: String = ""
    var charPrompt: String = ""
    var charInstruction: String = ""
    var charVersion: String = ""
    var creatorNotes: String = ""
    var model: String = ""
    /// 调用方传入的原文，对应 `{{original}}`（只允许替换一次）。
    var original: String?
    /// 输入框当前内容，对应 `{{input}}`。
    var input: String = ""
    /// 是否移动端。本 App 恒为 true。
    var isMobile: Bool = true

    init() {}

    /// 显式声明成员逐一初始化器。
    ///
    /// 一旦提供了 `init()`，Swift 就不再自动合成逐一初始化器，
    /// 而调用方经常需要一次性传入角色名、描述等多项，因此显式补上。
    init(
        charName: String = "",
        userName: String = "",
        description: String = "",
        personality: String = "",
        scenario: String = "",
        persona: String = "",
        mesExamples: String = "",
        mesExamplesRaw: String = "",
        charPrompt: String = "",
        charInstruction: String = "",
        charVersion: String = "",
        creatorNotes: String = "",
        model: String = "",
        original: String? = nil,
        input: String = "",
        isMobile: Bool = true
    ) {
        self.charName = charName
        self.userName = userName
        self.description = description
        self.personality = personality
        self.scenario = scenario
        self.persona = persona
        self.mesExamples = mesExamples
        self.mesExamplesRaw = mesExamplesRaw
        self.charPrompt = charPrompt
        self.charInstruction = charInstruction
        self.charVersion = charVersion
        self.creatorNotes = creatorNotes
        self.model = model
        self.original = original
        self.input = input
        self.isMobile = isMobile
    }
}

/// 宏替换引擎。
///
/// SillyTavern 默认走 Legacy 路径（`public/scripts/macros.js:610-714`），
/// 它的本质是**一趟线性扫描的宏列表**，而不是递归下降的解析器：
///
/// 1. 宏按固定批次顺序（preEnv → env → postEnv）逐条做一次全局替换；
/// 2. 所有宏**大小写不敏感**（`{{CHAR}}` 与 `{{char}}` 等价）；
/// 3. 不递归展开。「递归」只是顺序造成的：`{{description}}` 排在
///    `{{char}}` 之前，前者展开出的文本里若含 `{{char}}`，会在后续迭代中被替换；
/// 4. 内容被清空则整体短路退出。
enum MacroProcessor {
    /// 执行宏替换。
    ///
    /// - Parameter includeCharacterCard: 是否允许替换角色卡专属宏。
    ///   角色卡字段自身做替换时传 `false`，对应 ST 的 `replaceCharacterCard: false`。
    static func expand(
        _ content: String,
        context: MacroContext,
        includeCharacterCard: Bool = true
    ) -> String {
        guard content.contains("{{") || content.contains("<") else { return content }

        var result = content
        // 用引用持有「{{original}} 是否已用过」的状态：
        // 闭包不能捕获 inout 参数，而 ST 的语义是只替换第一次。
        let originalConsumed = Box(false)

        for macro in macroTable(
            context: context,
            includeCharacterCard: includeCharacterCard,
            originalConsumed: originalConsumed
        ) {
            if result.isEmpty { break }
            // ST 的短路判断：既不含 {{ 也不是尖括号宏时直接结束整轮替换。
            if !macro.isAngleBracket && !result.contains("{{") { break }
            result = apply(macro, to: result)
        }

        return result
    }

    // MARK: - 宏表示

    private final class Box {
        var value: Bool
        init(_ value: Bool) { self.value = value }
    }

    private struct Macro {
        /// 正则模式。
        var pattern: String
        /// true 表示把第一个捕获组交给 transform；false 表示把整体匹配交给 transform。
        var usesCaptureGroup: Bool = false
        /// 尖括号宏（`<USER>` 等）不参与 `{{` 短路判断。
        var isAngleBracket: Bool = false
        var transform: (String) -> String
    }

    /// 对一段文本应用单个宏。
    private static func apply(_ macro: Macro, to text: String) -> String {
        replaceMatches(
            text,
            pattern: macro.pattern,
            usesCaptureGroup: macro.usesCaptureGroup,
            transform: macro.transform
        )
    }

    // MARK: - 宏表（顺序即语义）

    private static func macroTable(
        context: MacroContext,
        includeCharacterCard: Bool,
        originalConsumed: Box
    ) -> [Macro] {
        var macros: [Macro] = []

        // ---------- preEnv 批次 ----------

        macros.append(literal("<USER>", context.userName, angleBracket: true))
        macros.append(literal("<BOT>", context.charName, angleBracket: true))
        macros.append(literal("<CHAR>", context.charName, angleBracket: true))

        macros.append(capture("\\{\\{roll[: ]([^}]+)\\}\\}") { roll($0) })
        macros.append(literal("{{newline}}", "\n"))
        // {{trim}} 会连同前后换行一起吃掉。
        macros.append(Macro(pattern: "(?:\\r?\\n)*\\{\\{trim\\}\\}(?:\\r?\\n)*") { _ in "" })
        macros.append(literal("{{noop}}", ""))
        macros.append(literal("{{input}}", context.input))

        // ---------- env 批次 ----------
        // 顺序关键：卡字段宏必须排在 {{char}}/{{user}} 之前。

        if includeCharacterCard {
            macros.append(literal("{{charPrompt}}", context.charPrompt))
            macros.append(literal("{{charInstruction}}", context.charInstruction))
            macros.append(literal("{{charJailbreak}}", context.charInstruction))
            macros.append(literal("{{charVersion}}", context.charVersion))
            macros.append(literal("{{char_version}}", context.charVersion))
            macros.append(literal("{{creatorNotes}}", context.creatorNotes))
        }

        macros.append(literal("{{description}}", context.description))
        macros.append(literal("{{personality}}", context.personality))
        macros.append(literal("{{scenario}}", context.scenario))
        macros.append(literal("{{persona}}", context.persona))
        macros.append(literal("{{mesExamples}}", context.mesExamples))
        macros.append(literal("{{mesExamplesRaw}}", context.mesExamplesRaw))
        macros.append(literal("{{model}}", context.model))
        macros.append(literal("{{isMobile}}", context.isMobile ? "true" : "false"))

        // 必须最后替换，保证前面展开文本里的 {{char}}/{{user}} 也被处理。
        macros.append(literal("{{char}}", context.charName))
        macros.append(literal("{{user}}", context.userName))
        macros.append(literal("{{group}}", context.charName))
        macros.append(literal("{{charIfNotGroup}}", context.charName))

        // ---------- postEnv 批次 ----------

        macros.append(capture("\\{\\{reverse:([\\s\\S]+?)\\}\\}") { String($0.reversed()) })
        // {{// 注释}}
        macros.append(Macro(pattern: "\\{\\{//([\\s\\S]*?)\\}\\}") { _ in "" })

        macros.append(literal("{{time}}", timeFormatter.string(from: Date())))
        macros.append(literal("{{date}}", dateFormatter.string(from: Date())))
        macros.append(literal("{{weekday}}", weekdayFormatter.string(from: Date())))
        macros.append(literal("{{isotime}}", isoTimeFormatter.string(from: Date())))
        macros.append(literal("{{isodate}}", isoDateFormatter.string(from: Date())))

        macros.append(capture("\\{\\{random:(.+?)\\}\\}") { randomChoice($0) })
        macros.append(capture("\\{\\{pick:(.+?)\\}\\}") { randomChoice($0) })
        macros.append(capture("\\{\\{time_UTC([-+]\\d+)\\}\\}") { utcTimeString(offsetHours: Int($0) ?? 0) })

        if let original = context.original, !original.isEmpty {
            macros.append(Macro(pattern: "\\{\\{original\\}\\}") { _ in
                // 只允许替换一次，之后的调用返回空串。
                guard !originalConsumed.value else { return "" }
                originalConsumed.value = true
                return original
            })
        }

        return macros
    }

    // MARK: - 宏构造工具

    /// 字面量宏：内容里的正则元字符会被转义，替换值原样写入。
    private static func literal(
        _ token: String,
        _ value: String,
        angleBracket: Bool = false
    ) -> Macro {
        Macro(
            pattern: NSRegularExpression.escapedPattern(for: token),
            isAngleBracket: angleBracket
        ) { _ in value }
    }

    /// 带捕获组的宏。
    private static func capture(_ pattern: String, _ transform: @escaping (String) -> String) -> Macro {
        Macro(pattern: pattern, usesCaptureGroup: true, transform: transform)
    }

    // MARK: - 正则替换

    /// 全局替换。`transform` 收到捕获组内容或整体匹配内容。
    private static func replaceMatches(
        _ text: String,
        pattern: String,
        usesCaptureGroup: Bool,
        transform: (String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        // 注意：不能用 match.range.location 去推 String.Index——NSString 用 UTF-16
        // 偏移，遇到 emoji 会错位甚至越界。统一用 Range(_:in:) 转换并靠游标切片。
        var result = ""
        var cursor = text.startIndex
        for match in matches {
            guard let matchRange = Range(match.range, in: text) else { continue }
            result += text[cursor..<matchRange.lowerBound]

            let argument: String
            if usesCaptureGroup, match.numberOfRanges > 1,
               let groupRange = Range(match.range(at: 1), in: text) {
                argument = String(text[groupRange])
            } else {
                argument = String(text[matchRange])
            }

            result += transform(argument)
            cursor = matchRange.upperBound
        }
        result += text[cursor...]
        return result
    }

    // MARK: - 具体宏语义

    /// `2d6` / `d20` / `1d20+3` 形式的骰子。
    private static func roll(_ expression: String) -> String {
        let trimmed = expression.trimmingCharacters(in: .whitespaces).lowercased()
        let parts = trimmed.split(separator: "d", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return "0" }

        let count = Int(parts[0]) ?? 1
        var sidesText = String(parts[1])
        var modifier = 0

        if let signIndex = sidesText.firstIndex(where: { $0 == "+" || $0 == "-" }) {
            let isNegative = sidesText[signIndex] == "-"
            let modifierText = String(sidesText[sidesText.index(after: signIndex)...])
            modifier = Int(modifierText) ?? 0
            if isNegative { modifier = -modifier }
            sidesText = String(sidesText[sidesText.startIndex..<signIndex])
        }

        guard let sides = Int(sidesText), sides > 0, count > 0, count <= 1000 else { return "0" }
        let total = (0..<count).reduce(0) { partial, _ in partial + Int.random(in: 1...sides) }
        return String(total + modifier)
    }

    /// `{{random:a,b,c}}` / `{{pick:a::b::c}}` 的选项切分。
    private static func randomChoice(_ body: String) -> String {
        let separator = body.contains("::") ? "::" : ","
        let items = body
            .components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return items.randomElement() ?? ""
    }

    private static func utcTimeString(offsetHours: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: offsetHours * 3600)
        return formatter.string(from: Date())
    }

    // MARK: - 时间格式

    private static let timeFormatter = makeFormatter("HH:mm")
    private static let dateFormatter = makeFormatter("MMMM d, yyyy")
    private static let weekdayFormatter = makeFormatter("EEEE")
    private static let isoTimeFormatter = makeFormatter("HH:mm:ss")
    private static let isoDateFormatter = makeFormatter("yyyy-MM-dd")

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }
}
