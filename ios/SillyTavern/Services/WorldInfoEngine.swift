import Foundation

/// 世界书触发引擎的参数。
struct WorldInfoConfig {
    /// 全局扫描深度：扫描最近多少条消息。对应 ST 的 `world_info_depth`。
    var scanDepth: Int = 2
    /// 递归扫描的最大轮数。对应 `world_info_max_recursion_steps`。
    var maxRecursionSteps: Int = 3
    /// 是否允许递归扫描（被命中的条目内容可以作为新一轮扫描文本）。
    var recursiveScanning: Bool = true
    /// 上下文预算占比（百分比）。ST 默认 25%。
    var budgetPercent: Int = 25
    /// 上下文的绝对 token 上限，用于把预算夹住。
    var contextSize: Int = 8192
    /// 角色名，用于扫描角色描述相关的匹配位。
    var characterName: String = ""
    var characterDescription: String = ""
    var characterPersonality: String = ""
    var scenario: String = ""
    var creatorNotes: String = ""
    var personaDescription: String = ""

    init() {}
}

/// 被激活的世界书条目及其插入信息。
struct ActivatedWorldInfoEntry {
    var entry: WorldInfoEntry
    /// 插入时使用的角色（system / user / assistant）。
    var role: String
    /// 命中该条目的关键词（调试与 UI 展示用）。
    var matchedKeys: [String]
}

/// 世界书触发引擎。
///
/// 复刻 SillyTavern `public/scripts/world-info.js` 的核心语义：
/// - 扫描文本 = 最近 N 条消息（按 `名字: 内容` 拼接，**逆序**，跳过 system 消息）；
/// - `constant` 条目先于关键词检查无条件激活；
/// - 关键词支持正则 `/pattern/flags`、整词匹配与大小写开关；
/// - `selective` 决定次级关键词如何参与判定（AND_ANY / NOT_ALL / NOT_ANY / AND_ALL）；
/// - `probability` 小于 100 时按概率决定是否激活；
/// - 预算超限时丢弃当轮剩余条目，且 `ignore_budget` 的条目不参与记账。
///
/// 说明：这里实现的是 v1 必需子集，`sticky` / `cooldown` / `delay` 这类
/// 依赖时间戳的高级字段暂未启用（字段已保留，便于后续补齐）。
struct WorldInfoEngine {
    var config: WorldInfoConfig

    init(config: WorldInfoConfig = WorldInfoConfig()) {
        self.config = config
    }

    /// 对给定聊天记录做一次触发扫描。
    ///
    /// - Parameters:
    ///   - entries: 候选条目（来自角色内嵌世界书，以及用户绑定的独立世界书）。
    ///   - messages: 完整聊天记录，按时间正序。
    /// - Returns: 按插入顺序排好的激活条目。
    func activate(entries: [WorldInfoEntry], messages: [ChatMessage]) -> [ActivatedWorldInfoEntry] {
        guard !entries.isEmpty else { return [] }

        let enabledEntries = entries.filter { $0.enabled }
        guard !enabledEntries.isEmpty else { return [] }

        // 预算：ST 取上下文的一部分，并允许被条目级上限夹住。
        let budget = max(1, config.contextSize * max(1, config.budgetPercent) / 100)

        var activated: [WorldInfoEntry] = []
        var activatedIds = Set<UUID>()
        /// 记录每个条目实际命中的关键词，供界面展示触发原因。
        var matchedKeysByEntry: [UUID: [String]] = [:]
        var usedTokens = 0

        // 扫描缓冲区随递归轮次增长（被激活条目的正文会加入下一轮扫描）。
        var scanBuffer = buildScanBuffer(messages: messages)

        var recursionStep = 0
        while true {
            // 排序规则：order 从大到小；同 order 保持原插入顺序（稳定排序）。
            let sorted = enabledEntries.enumerated().sorted { left, right in
                if left.element.insertionOrder != right.element.insertionOrder {
                    return left.element.insertionOrder > right.element.insertionOrder
                }
                return left.offset < right.offset
            }.map(\.element)

            var activatedThisRound: [WorldInfoEntry] = []

            for entry in sorted {
                if activatedIds.contains(entry.id) { continue }

                // constant 条目先于关键词检查无条件激活。
                let isConstant = entry.constant
                var matchedKeys: [String] = []

                if !isConstant {
                    guard let primary = matchPrimaryKeys(entry, in: scanBuffer) else { continue }
                    matchedKeys = primary
                    if !checkSecondaryKeys(entry, in: scanBuffer) { continue }
                }

                // 概率门：constant 条目不参与概率判定。
                if !isConstant, entry.probability < 100 {
                    guard Int.random(in: 1...100) <= max(0, entry.probability) else { continue }
                }

                let contentTokens = TokenEstimator.estimate(entry.content)
                let ignoreBudget = entry.extensions["ignore_budget"]?.boolValue ?? false

                if !ignoreBudget {
                    // ST 用「已用 + 新内容 >= 预算」判定溢出。
                    if usedTokens + contentTokens >= budget, !activated.isEmpty {
                        // 溢出后丢弃本轮剩余条目（不是跳过这一条）。
                        break
                    }
                    usedTokens += contentTokens
                }

                matchedKeysByEntry[entry.id] = isConstant ? ["（常驻条目）"] : matchedKeys
                activatedThisRound.append(entry)
            }

            for entry in activatedThisRound {
                activatedIds.insert(entry.id)
                activated.append(entry)
            }

            // 递归扫描：把本轮命中的正文加入扫描文本，最多 config.maxRecursionSteps 轮。
            recursionStep += 1
            let canRecurse = config.recursiveScanning
                && recursionStep < max(1, config.maxRecursionSteps)
                && !activatedThisRound.isEmpty

            guard canRecurse else { break }

            let additions = activatedThisRound
                .filter { !($0.extensions["prevent_recursion"]?.boolValue ?? false) }
                .map(\.content)
                .joined(separator: "\n")
            if additions.isEmpty { break }
            scanBuffer += "\n" + additions
        }

        // 按插入顺序升序输出（ST 在注入时是 order 降序遍历 + unshift，等价于最终升序）。
        let ordered = activated.enumerated().sorted { left, right in
            if left.element.insertionOrder != right.element.insertionOrder {
                return left.element.insertionOrder < right.element.insertionOrder
            }
            return left.offset < right.offset
        }.map(\.element)

        return ordered.map { entry in
            ActivatedWorldInfoEntry(
                entry: entry,
                role: roleFor(entry),
                matchedKeys: matchedKeysByEntry[entry.id] ?? []
            )
        }
    }

    // MARK: - 扫描缓冲区

    /// 取最近 N 条消息拼成扫描文本。
    ///
    /// 与 ST 一致：**跳过 system 消息**，按时间**逆序**拼接，
    /// 每条格式为 `名字: 内容`。
    func buildScanBuffer(messages: [ChatMessage]) -> String {
        let depth = max(1, config.scanDepth)
        let recent = messages
            .filter { !$0.isSystem && !$0.isHidden }
            .suffix(depth)
            .reversed()

        return recent
            .map { "\($0.name): \($0.mes)" }
            .joined(separator: "\n")
    }

    // MARK: - 关键词匹配

    /// 主关键词匹配。命中时返回命中的关键词列表。
    ///
    /// 关键词支持 `/pattern/flags` 的正则写法，此时**必须命中，且忽略整词匹配开关**
    /// （与 ST 的 `matchKeys` 分支一致）。
    private func matchPrimaryKeys(_ entry: WorldInfoEntry, in buffer: String) -> [String]? {
        let keys = entry.keys
            .flatMap { splitKeys($0) }
            .filter { !$0.isEmpty }
        guard !keys.isEmpty else { return nil }

        var matched: [String] = []
        for key in keys {
            if matches(key: key, in: buffer, entry: entry) {
                matched.append(key)
            }
        }
        return matched.isEmpty ? nil : matched
    }

    /// 次级关键词判定。
    ///
    /// 未启用 `selective` 时直接通过（ST 里 secondary 只在 selective 模式下生效）。
    /// 启用后按 `selectiveLogic` 决定语义，默认 `AND_ANY`。
    private func checkSecondaryKeys(_ entry: WorldInfoEntry, in buffer: String) -> Bool {
        guard entry.selective else { return true }

        let secondaryKeys = entry.secondaryKeys
            .flatMap { splitKeys($0) }
            .filter { !$0.isEmpty }
        // 声明了 selective 但没有次级关键词：ST 视作不通过（避免误触发）。
        guard !secondaryKeys.isEmpty else { return false }

        let hits = secondaryKeys.filter { matches(key: $0, in: buffer, entry: entry) }.count
        let logic = entry.extensions["selectiveLogic"]?.intValue ?? 0

        switch logic {
        case 1: // NOT_ALL：并非所有次级关键词都命中
            return hits < secondaryKeys.count
        case 2: // NOT_ANY：没有任何次级关键词命中
            return hits == 0
        case 3: // AND_ALL：全部命中
            return hits == secondaryKeys.count
        default: // AND_ANY：任一命中
            return hits > 0
        }
    }

    /// 单个关键词是否命中。
    ///
    /// `wholeWords` 只对「反向整词匹配」生效——这是 ST 的既有行为，予以复刻。
    /// 正则形式（`/re/flags`）优先，且不参与整词匹配。
    private func matches(key: String, in buffer: String, entry: WorldInfoEntry) -> Bool {
        let caseSensitive = entry.caseSensitive
        let wholeWords = entry.matchWholeWords

        // 正则关键词：/pattern/flags
        if let regex = Self.compileRegexKey(key) {
            let range = NSRange(buffer.startIndex..<buffer.endIndex, in: buffer)
            return regex.firstMatch(in: buffer, range: range) != nil
        }

        let haystack = caseSensitive ? buffer : buffer.lowercased()
        let needle = caseSensitive ? key : key.lowercased()

        guard wholeWords else {
            return haystack.contains(needle)
        }
        return Self.containsWholeWord(needle, in: haystack)
    }

    /// 把关键词按逗号拆开（ST 允许一个 key 字段写多个词）。
    private func splitKeys(_ key: String) -> [String] {
        // 正则写法里可能含逗号，此时不拆。
        if Self.compileRegexKey(key) != nil { return [key] }
        return key
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 解析 `/pattern/flags` 形式的正则关键词。
    static func compileRegexKey(_ key: String) -> NSRegularExpression? {
        guard key.count > 2, key.hasPrefix("/") else { return nil }
        // 找到最后一个未转义的斜杠作为结束符。
        let characters = Array(key)
        var endIndex: Int?
        var index = characters.count - 1
        while index > 0 {
            if characters[index] == "/", characters[index - 1] != "\\" {
                endIndex = index
                break
            }
            index -= 1
        }
        guard let closingIndex = endIndex, closingIndex > 0 else { return nil }

        let pattern = String(characters[1..<closingIndex])
        let flagsText = String(characters[(closingIndex + 1)...])

        var options: NSRegularExpression.Options = []
        if flagsText.contains("i") { options.insert(.caseInsensitive) }
        if flagsText.contains("m") { options.insert(.anchorsMatchLines) }
        if flagsText.contains("s") { options.insert(.dotMatchesLineSeparators) }
        if flagsText.contains("x") { options.insert(.allowCommentsAndWhitespace) }

        return try? NSRegularExpression(pattern: pattern, options: options)
    }

    /// 整词匹配。
    ///
    /// 用「前后都不是字母或数字」判定边界；同时对 CJK 放宽——
    /// 中文没有空格分词，若严格按词边界会让绝大多数中文关键词永不命中。
    static func containsWholeWord(_ needle: String, in haystack: String) -> Bool {
        guard !needle.isEmpty else { return false }

        var searchStart = haystack.startIndex
        while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            let beforeOK: Bool
            if range.lowerBound == haystack.startIndex {
                beforeOK = true
            } else {
                let before = haystack[haystack.index(before: range.lowerBound)]
                beforeOK = !isWordCharacter(before)
            }

            let afterOK: Bool
            if range.upperBound == haystack.endIndex {
                afterOK = true
            } else {
                let after = haystack[range.upperBound]
                afterOK = !isWordCharacter(after)
            }

            if beforeOK && afterOK { return true }
            searchStart = haystack.index(after: range.lowerBound)
        }
        return false
    }

    /// 是否为「词字符」：字母或数字（不含 CJK，理由见上）。
    private static func isWordCharacter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        if scalar.isASCII {
            return CharacterSet.alphanumerics.contains(scalar)
        }
        // 拉丁扩展、西里尔等仍按词字符处理；CJK 视为非词字符。
        return CharacterSet.letters.contains(scalar) && !isCJK(scalar)
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFF00...0xFF60, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }

    // MARK: - 注入位置

    /// 条目内容以什么角色插入。
    private func roleFor(_ entry: WorldInfoEntry) -> String {
        if let role = entry.extensions["role"]?.intValue {
            switch role {
            case 1: return "user"
            case 2: return "assistant"
            default: return "system"
            }
        }
        return "system"
    }
}
