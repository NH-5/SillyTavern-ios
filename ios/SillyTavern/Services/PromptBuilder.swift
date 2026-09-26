import Foundation

/// Prompt 槽位。
///
/// SillyTavern 把最终消息数组建模成「可排序的槽位集合」，槽位顺序由用户的
/// Prompt Manager 决定。这里用同样的模型：默认顺序与 ST 的通用预设一致，
/// 需要时（例如世界书没有内容）可以整槽跳过。
enum PromptSlot: String, CaseIterable {
    case main
    case worldInfoBefore
    case characterDescription
    case characterPersonality
    case scenario
    case personaDescription
    case nsfw
    case worldInfoAfter
    case dialogueExamples
    case chatHistory
    case jailbreak
    case controlPrompts
}

/// 组装一次生成请求所需的全部输入。
struct PromptBuildInput {
    var card: CharacterCard
    var personaName: String
    var personaDescription: String
    var settings: AppSettings
    /// 聊天记录（正序，不含正在输入的这一条）。
    var messages: [ChatMessage]
    /// 追加到世界书扫描的独立世界书条目。
    var extraWorldInfoEntries: [WorldInfoEntry] = []
    /// 额外插入的消息（深度注入等）。
    var extraDepthInjections: [(depth: Int, role: String, content: String)] = []
    /// 槽位顺序。默认使用内建顺序。
    var slotOrder: [PromptSlot] = PromptBuilder.defaultSlotOrder
}

/// 组装结果，同时附带诊断信息便于排查「为什么模型没按预期回答」。
struct PromptBuildResult {
    var messages: [ChatCompletionMessage]
    /// 被激活的世界书条目（用于 UI 展示，ST 也有类似面板）。
    var activatedWorldInfo: [ActivatedWorldInfoEntry]
    /// 各槽位贡献的 token 估算。
    var tokenBreakdown: [(slot: String, tokens: Int)]
    /// 组装过程中被裁掉的历史消息条数。
    var droppedHistoryCount: Int
}

/// Prompt 组装器。
///
/// 顺序与 SillyTavern 的 Chat Completion 路径对齐
/// （`public/scripts/openai.js:1185-1347`）：
/// `main → worldInfoBefore → charDescription → charPersonality → scenario →
/// personaDescription → nsfw → worldInfoAfter → chatHistory → dialogueExamples →
/// jailbreak`，最后是深度注入与控制消息。
struct PromptBuilder {
    /// 默认槽位顺序，取自 ST 的通用预设 `Default.json`。
    static let defaultSlotOrder: [PromptSlot] = [
        .main,
        .worldInfoBefore,
        .characterDescription,
        .characterPersonality,
        .scenario,
        .personaDescription,
        .nsfw,
        .worldInfoAfter,
        .chatHistory,
        .dialogueExamples,
        .jailbreak,
        .controlPrompts,
    ]

    /// 主提示词模板。对应 ST 默认预设里的 `main`。
    static let defaultMainPrompt = "Write {{char}}'s next reply in a fictional chat between {{char}} and {{user}}."

    var worldInfoConfig = WorldInfoConfig()

    init() {}

    /// 组装消息数组。
    func build(_ input: PromptBuildInput) -> PromptBuildResult {
        let card = input.card
        let settings = input.settings

        // 角色卡字段本身的宏替换：此时不应替换角色卡专属宏
        // （对应 ST 的 replaceCharacterCard: false）。
        let baseContext = MacroContext()

        var context = baseContext
        context.charName = card.name
        context.userName = input.personaName
        context.persona = input.personaDescription
        context.model = settings.activeModel

        // 先用 {{char}}/{{user}} 展开卡字段，再把这些内容作为宏值供后续使用。
        context.description = MacroProcessor.expand(
            card.description, context: context, includeCharacterCard: false
        )
        context.personality = MacroProcessor.expand(
            card.personality, context: context, includeCharacterCard: false
        )
        context.scenario = MacroProcessor.expand(
            card.scenario, context: context, includeCharacterCard: false
        )
        context.mesExamplesRaw = card.mesExample
        context.mesExamples = card.exampleMessages.joined(separator: "\n")
        context.charPrompt = card.systemPrompt
        context.charInstruction = card.postHistoryInstructions
        context.charVersion = card.characterVersion
        context.creatorNotes = card.creatorNotes

        // MARK: 世界书触发

        var entries = card.characterBook?.entries ?? []
        entries.append(contentsOf: input.extraWorldInfoEntries)

        var config = worldInfoConfig
        config.characterName = card.name
        config.characterDescription = context.description
        config.characterPersonality = context.personality
        config.scenario = context.scenario
        config.creatorNotes = card.creatorNotes
        config.personaDescription = input.personaDescription
        config.contextSize = settings.contextSize
        if let book = card.characterBook {
            if let depth = book.scanDepth { config.scanDepth = depth }
        }

        let engine = WorldInfoEngine(config: config)
        let activated = engine.activate(entries: entries, messages: input.messages)

        // 世界书内容也要做宏替换（ST 在计入预算前就地替换）。
        let beforeEntries = activated.filter { $0.entry.position == .beforeCharacter }
        let afterEntries = activated.filter { $0.entry.position == .afterCharacter }
        let depthEntries = activated.filter { $0.entry.position == .atDepth }

        let worldInfoBefore = expandWorldInfo(beforeEntries, context: context)
        let worldInfoAfter = expandWorldInfo(afterEntries, context: context)

        // MARK: 构造各槽位内容

        var slotContent: [PromptSlot: [ChatCompletionMessage]] = [:]

        let mainText = MacroProcessor.expand(Self.defaultMainPrompt, context: context)
        slotContent[.main] = [ChatCompletionMessage(role: "system", content: mainText)]

        if !worldInfoBefore.isEmpty {
            slotContent[.worldInfoBefore] = [
                ChatCompletionMessage(role: "system", content: worldInfoBefore),
            ]
        }
        if !context.description.isEmpty {
            slotContent[.characterDescription] = [
                ChatCompletionMessage(role: "system", content: context.description),
            ]
        }
        if !context.personality.isEmpty {
            slotContent[.characterPersonality] = [
                ChatCompletionMessage(role: "system", content: context.personality),
            ]
        }
        if !context.scenario.isEmpty {
            slotContent[.scenario] = [
                ChatCompletionMessage(role: "system", content: context.scenario),
            ]
        }
        if !input.personaDescription.isEmpty {
            let personaText = MacroProcessor.expand(input.personaDescription, context: context)
            slotContent[.personaDescription] = [
                ChatCompletionMessage(role: "system", content: personaText),
            ]
        }
        if !worldInfoAfter.isEmpty {
            slotContent[.worldInfoAfter] = [
                ChatCompletionMessage(role: "system", content: worldInfoAfter),
            ]
        }

        // 角色卡专属 system prompt 优先于全局 Post-History Instructions。
        let postHistory = card.systemPrompt.isEmpty
            ? card.postHistoryInstructions
            : card.postHistoryInstructions
        if !postHistory.isEmpty {
            let text = MacroProcessor.expand(postHistory, context: context)
            slotContent[.jailbreak] = [ChatCompletionMessage(role: "system", content: text)]
        }

        // MARK: 预算与消息组装

        // 先算出固定部分的 token，剩下的留给历史与示例。
        let reservedTokens = TokenEstimator.perMessageOverhead * 4
        let fixedTokens = slotContent.values
            .flatMap { $0 }
            .reduce(0) { $0 + TokenEstimator.estimate($1.flatContent) + TokenEstimator.perMessageOverhead }

        let budget = max(0, settings.contextSize - settings.maxTokens - reservedTokens - fixedTokens)

        // 历史裁剪：从最新往旧累加，放不下就停（更旧的一律丢弃）。
        let (historyMessages, droppedCount) = buildHistory(
            messages: input.messages,
            budget: budget,
            context: context
        )
        if !historyMessages.isEmpty {
            slotContent[.chatHistory] = historyMessages
        }

        // 示例对话放在历史之后（ST 默认 pin_examples = false）。
        let examples = buildExampleMessages(card: card, context: context)
        if !examples.isEmpty {
            slotContent[.dialogueExamples] = examples
        }

        // MARK: 按槽位顺序拼装

        var messages: [ChatCompletionMessage] = []
        for slot in input.slotOrder {
            guard let content = slotContent[slot], !content.isEmpty else { continue }
            messages.append(contentsOf: content)
        }

        // 深度注入：按深度从小到大插入到历史末尾倒数第 depth 条之前。
        if !depthEntries.isEmpty || !input.extraDepthInjections.isEmpty {
            var injections: [(depth: Int, role: String, content: String)] = input.extraDepthInjections
            for item in depthEntries {
                injections.append((
                    depth: max(1, item.entry.depth),
                    role: item.role,
                    content: MacroProcessor.expand(item.entry.content, context: context)
                ))
            }
            messages = Self.applyDepthInjections(injections, to: messages)
        }

        // 真正的第一条消息（问候语）不参与 prompt；历史里已有它。

        let breakdown = slotContent
            .map { (slot: $0.key.rawValue, tokens: $0.value.reduce(0) { $0 + TokenEstimator.estimate($1.flatContent) }) }
            .sorted { $0.slot < $1.slot }

        return PromptBuildResult(
            messages: messages,
            activatedWorldInfo: activated,
            tokenBreakdown: breakdown,
            droppedHistoryCount: droppedCount
        )
    }

    // MARK: - 历史裁剪

    /// 从最新往旧累加到预算上限。
    ///
    /// 与 ST 一致：**遇到第一条放不下的消息就停止**，而不是跳过它继续往前找，
    /// 这样能保证上下文连续、不出现「中间缺失」的对话。
    ///
    /// 历史消息同样要过宏替换——ST 的 `PromptManager.preparePrompt()` 对
    /// 每条历史消息都无条件调用 `substituteParams`，所以消息正文里写下的
    /// `{{char}}` / `{{user}}` 会在发送前被展开。
    private func buildHistory(
        messages: [ChatMessage],
        budget: Int,
        context: MacroContext
    ) -> ([ChatCompletionMessage], Int) {
        let usable = messages.filter { !$0.isSystem && !$0.isHidden && !$0.mes.isEmpty }
        guard !usable.isEmpty else { return ([], 0) }

        var selected: [ChatCompletionMessage] = []
        var used = 0
        var dropped = 0

        for message in usable.reversed() {
            let role = message.isUser ? "user" : "assistant"
            let content = MacroProcessor.expand(message.mes, context: context)

            let cost = TokenEstimator.estimate(content) + TokenEstimator.perMessageOverhead
            if used + cost > budget {
                // 剩余更旧的消息全部丢弃。
                dropped = usable.count - selected.count
                break
            }
            used += cost
            selected.append(ChatCompletionMessage(role: role, content: content))
        }

        return (selected.reversed(), dropped)
    }

    // MARK: - 示例对话

    /// 把 `mes_example` 拆成消息数组。
    ///
    /// 与 ST 的 Chat Completion 行为对齐（`setOpenAIMessageExamples` /
    /// `parseExampleIntoIndividual`）：
    /// - 按 `<START>` 切块（大小写不敏感），只保留分隔符之后的内容；
    /// - 每块内按 `名字:` 前缀切分发言；
    /// - 消息 role 统一用 `system`，靠 `name` 字段区分
    ///   `example_user` 与 `example_assistant`；
    /// - 每个示例块前插入一条 `[Example Chat]` 作为分节标记。
    func buildExampleMessages(card: CharacterCard, context: MacroContext) -> [ChatCompletionMessage] {
        let blocks = Self.parseExampleBlocks(card.mesExample)
        guard !blocks.isEmpty else { return [] }

        var messages: [ChatCompletionMessage] = []
        for block in blocks {
            var blockMessages: [ChatCompletionMessage] = []
            for line in block.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }

                guard let (speaker, body) = Self.splitSpeaker(trimmed) else {
                    // 没写说话人前缀：并入上一条示例消息。
                    if var last = blockMessages.popLast() {
                        last = ChatCompletionMessage(
                            role: last.role,
                            content: last.flatContent + "\n" + trimmed,
                            name: last.name
                        )
                        blockMessages.append(last)
                    } else {
                        blockMessages.append(ChatCompletionMessage(
                            role: "system",
                            content: trimmed,
                            name: "example_user"
                        ))
                    }
                    continue
                }

                let isUser = speaker.caseInsensitiveCompare(card.name) == .orderedSame
                    ? false
                    : speaker.caseInsensitiveCompare(context.userName) == .orderedSame

                blockMessages.append(ChatCompletionMessage(
                    role: "system",
                    content: MacroProcessor.expand(body, context: context),
                    name: isUser ? "example_user" : "example_assistant"
                ))
            }

            guard !blockMessages.isEmpty else { continue }
            messages.append(ChatCompletionMessage(role: "system", content: "[Example Chat]"))
            messages.append(contentsOf: blockMessages)
        }

        return messages
    }

    /// 把 `mes_example` 按 `<START>` 切成块。
    static func parseExampleBlocks(_ raw: String) -> [String] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != "<START>" else { return [] }

        // 与 ST 一致：若没有以 <START> 开头，先补一个，避免第一块被丢掉。
        let normalized = text.uppercased().hasPrefix("<START>") ? text : "<START>\n" + text

        return normalized
            .components(separatedBy: "<START>")
            .dropFirst() // 丢弃分隔符之前的部分
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 识别 `名字:` 前缀。ST 允许 `名字:` 或 `名字：`（中文冒号）。
    static func splitSpeaker(_ line: String) -> (String, String)? {
        guard let colonIndex = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else {
            return nil
        }
        let speaker = String(line[line.startIndex..<colonIndex])
            .trimmingCharacters(in: .whitespaces)
        // 说话人不应过长，也不应含空格（避免把普通句子里的冒号误判为前缀）。
        guard !speaker.isEmpty, speaker.count <= 40, !speaker.contains(" ") else { return nil }

        let body = String(line[line.index(after: colonIndex)...])
            .trimmingCharacters(in: .whitespaces)
        return (speaker, body)
    }

    // MARK: - 世界书与控制消息

    /// 把激活条目拼成一段文本。
    private func expandWorldInfo(
        _ entries: [ActivatedWorldInfoEntry],
        context: MacroContext
    ) -> String {
        entries
            .map { MacroProcessor.expand($0.entry.content, context: context) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// 深度注入：把消息插到聊天记录末尾倒数第 depth 条之前。
    ///
    /// `depth = 1` 表示插到最后一条消息之前（即最靠近生成位置）。
    static func applyDepthInjections(
        _ injections: [(depth: Int, role: String, content: String)],
        to messages: [ChatCompletionMessage]
    ) -> [ChatCompletionMessage] {
        guard !injections.isEmpty else { return messages }

        // 找到聊天历史在数组里的起点：深度是相对「历史」计算的。
        // 历史之后还有示例消息与 jailbreak，注入要落在历史区间内。
        let historyStart = messages.firstIndex { $0.name == nil && ($0.role == "user" || $0.role == "assistant") }
        guard let start = historyStart else {
            // 没有历史时直接追加到末尾。
            var result = messages
            for injection in injections.sorted(by: { $0.depth > $1.depth }) {
                result.append(ChatCompletionMessage(role: injection.role, content: injection.content))
            }
            return result
        }

        var historyEnd = messages.count
        for index in start..<messages.count {
            let role = messages[index].role
            if role != "user" && role != "assistant" {
                historyEnd = index
                break
            }
        }

        var result = messages
        // 深度大的先插，避免插入后索引位移影响后续计算。
        for injection in injections.sorted(by: { $0.depth > $1.depth }) {
            // 语义：depth = 1 表示插到最后一条历史消息之前（最靠近生成位置），
            // depth = 2 表示插到倒数第二条之前，依此类推。
            let available = max(1, historyEnd - start)
            let clamped = max(1, min(injection.depth, available))
            let insertIndex = max(start, historyEnd - clamped)
            result.insert(
                ChatCompletionMessage(role: injection.role, content: injection.content),
                at: insertIndex
            )
        }
        return result
    }
}
