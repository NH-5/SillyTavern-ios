# 06. Swift 实现规格：Prompt 组装 / 世界书 / Token 预算 / LLM 流式客户端

> **定位**：本文是 `02-prompt-assembly-and-worldinfo.md` 与 `03-llm-api-protocols.md` 的**可编码化产物**。
> 02/03 回答「SillyTavern 是怎么做的」，本文回答「Swift 该写什么」。
>
> **来源与版本**
> - 仓库：`/Users/wuzheng/projects/SillyTavern-ios`（SillyTavern Node.js 源码），分支 `dsh`
> - 引用格式：文档章节 `02#4.6` / `03#1.6`；源码 `文件:行号`（如 `openai.js:1185`，路径均在 `public/scripts/` 下，除非写明 `src/`）
> - 本文所有源码引用均**已逐条打开核对**；与 02/03 文档不一致处已在文中显式标注 `⚠️ 勘误`
>
> **目标平台约定**
> - Swift 5 语言模式（`-swift-version 5`），iOS 18 SDK。**不使用** Swift 6 严格并发特性：
>   不使用 `actor`、不给自定义类型加 `Sendable` 约束、不依赖 `@MainActor` 隔离检查。
>   可变状态一律用 `final class` 承载，异步用 `async/await` + `AsyncThrowingStream`。
> - 完全离线：不访问 ST 服务端、不访问 `/api/tokenizers/*`。所有 token 计数走本地近似（§6）。
>
> **实现阶段图例**
> - `[P0]` 必须实现 —— 缺了就「跑不起来」或「行为明显不对」
> - `[P1]` 应当实现 —— 影响体验/兼容性，但可以先留桩
> - `[P2]` 可以延后 —— 高级特性、实验特性、扩展生态相关
>
> **建议的源码文件划分**（下文按此组织）
> ```
> Sources/Core/
>   Models/ChatMessage.swift          §1
>   Models/GenerationRequest.swift    §1
>   Prompt/PromptID.swift             §2.2
>   Prompt/PromptSlot.swift           §2.1
>   Prompt/ChatCompletion.swift       §2.1 / §6.4
>   Prompt/PromptAssembler.swift      §2.3 - §2.8
>   Prompt/ExampleParser.swift        §3
>   Macro/MacroEngine.swift           §4
>   Macro/MacroContext.swift          §4
>   Macro/RNG.swift                   §4.5
>   WorldInfo/WIEntry.swift           §5.1
>   WorldInfo/WorldInfoBuffer.swift   §5.3
>   WorldInfo/WorldInfoEngine.swift   §5.5
>   WorldInfo/TimedEffects.swift      §5.8
>   Token/TokenCounter.swift          §6
>   LLM/SSEFramer.swift               §7.2
>   LLM/LLMClient.swift               §7.3 - §7.5
>   LLM/LLMError.swift                §7.4
>   Flow/GenerationPipeline.swift     §8
> ```

---

## 0. 模块总览与数据流

```
用户点「发送」
   │
   ├─[1] 构造 GenerationContext（角色卡字段 / persona / 聊天记录 / 设置）
   │
   ├─[2] MacroEngine.substitute()            §4    ← 卡字段、prompt content 的宏替换
   │
   ├─[3] parseMesExamples() + setOpenAIMessageExamples()   §3
   │
   ├─[4] WorldInfoEngine.checkWorldInfo()    §5    ← 需要 [2] 的宏引擎
   │        └─ 产出 WIPromptResult { before, after, emEntries, depthEntries, anTop, anBottom, outlets }
   │
   ├─[5] PromptAssembler.assemble()          §2    ← 需要 [3][4] 与 TokenCounter
   │        ├─ populateChatCompletion 22 步
   │        ├─ populationInjectionPrompts（深度注入）
   │        ├─ populateChatHistory（裁剪）
   │        └─ populateDialogueExamples
   │        └─ 产出 [ChatCompletionMessage]  ← 最终请求体 messages
   │
   ├─[6] LLMClient.stream(request) → AsyncThrowingStream<GenerationEvent>   §7
   │
   └─[7] 落盘（chat.jsonl）+ 渲染                       §8
```

**模块间依赖方向（严格单向，不要反向引用）**

| 模块 | 依赖 | 被依赖 |
|---|---|---|
| `MacroEngine` | 无（数据由 `MacroContext` 注入） | 世界书、PromptAssembler、卡字段 |
| `WorldInfoEngine` | `MacroEngine`、`TokenCounter` | PromptAssembler |
| `TokenCounter` | 无 | 世界书、PromptAssembler、ChatCompletion |
| `PromptAssembler` | 全部上述 | `GenerationPipeline` |
| `LLMClient` | 无（纯协议层） | `GenerationPipeline` |

**关键设计原则（贯穿全文）**

1. **顺序即语义**：02#1.2 的 22 步顺序、02#3.2 的宏列表顺序、02#4.4 的排序顺序，都是**行为契约**，不是实现细节。改顺序 = 改行为。
2. **槽位而非数组**：最终消息数组不是「一个 list 从头 append 到尾」，而是「按用户 `prompt_order` 索引落位的槽位数组」，中间允许空洞（02#1.1、`openai.js:4120-4141`）。Swift 用 `[Slot?]` 建模，**不要**用 `[Slot]` + append 顺序模拟。
3. **预算记账是显式的**：每条消息的 token 数在创建时算好并缓存；`reserve`/`free`/`canAfford` 是独立操作，不是「事后统计」。
4. **宏替换是单趟线性扫描**，不是递归下降（02#3.2 结论 1）。

---

## 1. 生成参数与消息数据结构 `[P0]`

### 1.1 `ChatCompletionMessage`

**来源**：`02#1.1`（`openai.js:4120-4141` 的 `getChat()` 输出形状）、`03#0.1`、`03#1.3`。

```swift
/// 一条最终发往 /chat/completions 的 messages 元素。
/// 字段名 = 线上 JSON 字段名，直接 Codable。
public struct ChatCompletionMessage: Codable, Equatable {

    public enum Role: String, Codable, CaseIterable, Equatable {
        case system, user, assistant, tool
    }

    public var role: Role

    /// 允许为 nil：仅当 message 只有 tool_calls 时（P2 工具调用才会出现）。
    /// 编码时 nil ⇒ 字段被省略（对齐 JSON.stringify 丢弃 undefined 的行为，03#1.3）。
    public var content: String?

    /// 示例消息用 "example_user" / "example_assistant"（§3.3）；聊天历史在
    /// names_behavior == .completion 时用清洗后的角色名。
    public var name: String?

    // ---- [P2] 以下字段 v1 不产生，但保留以便平滑扩展 ----
    public var toolCalls: [ToolCall]?
    public var toolCallID: String?
    public var signature: String?
    public var reasoning: String?

    public struct ToolCall: Codable, Equatable {
        public var id: String
        public var type: String            // "function"
        public var function: Function
        public struct Function: Codable, Equatable {
            public var name: String
            public var arguments: String   // JSON 字符串
        }
    }

    public init(role: Role, content: String?, name: String? = nil) {
        self.role = role
        self.content = content
        self.name = name
    }
}
```

**编码规则（必须与 ST 的 `getChat()` 一致）**

1. `content == nil && toolCalls == nil` 的 message **不进入**最终数组（`openai.js:4125`）。
2. `name` 为空串或 nil ⇒ 省略字段（`openai.js:4129` 的 `...(item.name ? {name} : {})`；空串是 falsy）。
3. `role == "tool"` 时 `tool_call_id = identifier`（`openai.js:4131`）——注意 ST 用的是 **message.identifier**，不是某个专门字段。`[P2]`。

> **⚠️ 易错点 1.1**：不要用 `JSONEncoder` 直接编码 `content: String?` 后期待「nil 变成缺字段」——`Codable` 合成的 `encode` 对 `nil` 确实会调 `encodeIfPresent` 并省略，但**前提是**你用可选类型并走默认合成实现。若手写了 `encode(to:)`，务必用 `encodeIfPresent`。
>
> **⚠️ 易错点 1.2**：`content` 在 ST 里可以是 **parts 数组**（多模态，03#6）。v1 只支持 `String`。若日后要支持图片，把 `content` 改成 `enum MessageContent { case text(String); case parts([Part]) }` 并自定义 Codable；**不要**用 `AnyCodable`。

### 1.2 `GenerationRequest`

**来源**：`03#0.1`（客户端 `generate_data`）、`03#1.3`（服务端 requestBody）、`03#7`（默认值表）。默认值取自 `openai.js:411-518`（`default_settings`）与 `default/content/presets/openai/Default.json`。

```swift
public struct GenerationRequest {

    // ---- 必填 ----
    public var messages: [ChatCompletionMessage]
    public var model: String

    // ---- 采样参数（03#7）----
    /// default_settings.temp_openai = 1.0（openai.js:413 / Default.json:26）
    public var temperature: Double = 1.0
    /// freq_pen_openai = 0（openai.js:414）
    public var frequencyPenalty: Double = 0
    /// pres_pen_openai = 0（openai.js:415）
    public var presencePenalty: Double = 0
    /// top_p_openai = 1.0（openai.js:416）
    public var topP: Double = 1.0
    /// top_k_openai = 0（openai.js:417）—— 只有部分供应商接受
    public var topK: Double = 0
    /// min_p_openai = 0（openai.js:418）
    public var minP: Double = 0
    /// top_a_openai = 0（openai.js:419）
    public var topA: Double = 0
    /// repetition_penalty_openai = 1（openai.js:420）
    public var repetitionPenalty: Double = 1

    /// openai_max_tokens = 300（openai.js:423）
    public var maxTokens: Int = 300

    /// stream_openai 在 default_settings 里是 false（openai.js:421），
    /// 但 Default.json:53 的预设值是 true。本 App 恒定流式 ⇒ 恒为 true。
    public var stream: Bool = true

    /// stop 序列；空数组 ⇒ 不发送该字段（chat-completions.js:2620-2623）
    public var stop: [String] = []

    /// seed = -1 表示「不发送」（openai.js:514 + openai.js:3046-3048）
    public var seed: Int = -1

    /// n = 1（openai.js:515）
    public var n: Int = 1

    public var logitBias: [String: Int]? = nil

    // ---- 思考链 ----
    /// show_thoughts = true（openai.js:507）；纯客户端行为，不进请求体
    public var showThoughts: Bool = true
    /// reasoning_effort = "auto"（openai.js:508）
    public var reasoningEffort: String = "auto"
    /// verbosity = "auto"（openai.js:509）
    public var verbosity: String = "auto"

    // ---- 上下文预算（不是请求字段，但必须一起传）----
    /// openai_max_context = max_4k = 4095（openai.js:127 `const max_4k = 4095`；openai.js:422）
    /// 注意 Default.json:33 的预设值也是 4095，不是 4096。
    public var maxContextTokens: Int = 4095
    /// 与 maxTokens 同源，冗余保存便于 §6 计算 prompt 预算
    public var maxResponseTokens: Int { maxTokens }

    // ---- 供应商路由（决定 URL/认证/增量提取分支，§7）----
    public var provider: ProviderProfile
}
```

**字段裁剪规则（P1，03#1.3「客户端侧对请求体的进一步删改」）**

这些规则决定「哪些参数在什么模型下**不能**出现」，实现成一个纯函数即可：

```swift
extension GenerationRequest {
    /// 按供应商 + 模型名裁剪字段，返回真正要编码的 JSON 对象。
    /// 来源：openai.js:3046-3120（客户端）+ chat-completions.js:2652-2669（服务端白名单）
    func sanitizedForWire() -> [String: Any] { ... }
}
```

必须实现的裁剪（`[P1]`，按优先级）：

| 条件 | 动作 | 来源 |
|---|---|---|
| `seed < 0` | 删除 `seed` | `openai.js:3046-3048` |
| model 含 `o1`/`o3`/`o4` | `max_tokens` → `max_completion_tokens`；删 `logprobs/top_logprobs/stop/logit_bias/temperature/top_p/frequency_penalty/presence_penalty`；`o1` 还要把 `system` role 改 `user`、删 `n` | `openai.js:3050-3072` |
| model 以 `gpt-5` 开头 | `max_tokens` → `max_completion_tokens`；删 `logprobs/top_logprobs`；非 `chat-latest` 分支再删采样参数与 `stop/logit_bias` | `openai.js:3074-3095` |
| model 含 `claude` 且匹配 `fable/opus-5/sonnet-5` | 删所有采样参数 | `openai.js:3109-3120` |
| provider == `.deepseek` | `top_p = top_p == 0 ? Double.leastNonzeroMagnitude : top_p` | `openai.js:2955-2957` |
| provider == `.zai` | `top_p = top_p == 0 ? 0.01 : top_p`；删惩罚项 | `openai.js:2993-2999` |
| provider == `.makersuite`/`.vertexai` | `stop` 最多 5 条且长度 1...16；空 `stopSequences` 删除 | `openai.js:2905-2909`、`chat-completions.js:539-541` |
| provider == `.cohere` | `top_p` 夹到 `[0.01, 0.99]`，penalty 夹到 `[0, 1]` | `openai.js:2929-2937` |
| provider == `.minimax` | `temperature` 夹到 `(0, 1]` | `openai.js:3011-3014` |
| provider == `.mistralai` | 追加 `safe_prompt = false`（并剔除官方不认的字段） | `openai.js:2918` |

> **决不做的事**：不要发送 `stream_options`（`03#1.3` 明确「从不发送」，全仓库无使用）。

### 1.3 `ProviderProfile`（供应商档案）

把「URL 形状 / 认证头 / 请求体形状 / 流式提取分支」收敛成一个枚举，避免到处 `switch`。

```swift
public enum ProviderProfile: Equatable {
    case openAICompatible(base: String, apiKey: String, extraHeaders: [String: String] = [:], extractor: OpenAIExtractor = .generic)
    case anthropic(base: String, apiKey: String, beta: [String] = [])
    case gemini(apiKey: String, model: String, apiVersion: String = "v1beta", region: String? = nil)
    case ollama(base: String)          // [P2] textgen NDJSON，不属于 chat 协议
}

/// OpenAI 系内部的增量提取差异（03#1.5.3 / 03#4.1）
public enum OpenAIExtractor: Equatable {
    case generic        // delta.content ?? message.content ?? text
    case openRouter     // reasoning 优先链更长
    case deepseek       // delta.reasoning_content
    case mistral        // delta.content 可能是数组
    case cohere         // delta.message.content.text（自有事件协议）[P2]
}
```

> **⚠️ 易错点 1.3**：`base` 必须是**用户原样输入**的字符串，**不要**在存入 profile 时做规范化（§7.1 的规则依赖原串）。

### 1.4 易错点汇总（§1）

| # | 易错点 | 后果 |
|---|---|---|
| 1 | 把 `max_tokens` 和 `max_completion_tokens` 混用 | o 系列 / gpt-5 直接 400 |
| 2 | 忘记 `seed == -1` 时删字段 | 部分供应商对 `seed: -1` 报错 |
| 3 | `openai_max_context` 写成 4096 | 与 ST 默认 4095 差 1 token，golden test 会对不上（`openai.js:127`） |
| 4 | 把 `stream: false` 当默认 | 本 App 恒流式；`default_settings.stream_openai=false` 只说明「ST 允许非流式」 |
| 5 | `stop: []` 编码成 `"stop": []` | 少数供应商（Gemini）对空数组报错；应省略 |

---

## 2. Prompt 组装器（最核心）`[P0]`

### 2.1 槽位模型

#### 2.1.1 为什么必须是「槽位数组」

**来源**：`02#1.1`、`openai.js:3998-4013`、`openai.js:4120-4141`。

ST 的 `ChatCompletion.messages` 是一个 `MessageCollection`（root），其 `collection` 是 **JS 数组**，通过 `add(collection, position)` 用**下标赋值**落位：

```js
// openai.js:4002-4006
if (null !== position && -1 !== position) {
    this.messages.collection[position] = collection;   // ← 下标赋值，可能产生「洞」
} else {
    this.messages.collection.push(collection);
}
```

`position` 来自 `prompts.index(source)`，即该 prompt 在**用户 `prompt_order` 里的索引**。因此：

- 最终顺序**完全由 `prompt_order` 决定**，不由代码里 `add` 的先后决定；
- 没被 `add` 的索引是**洞**；`getChat()` 的 `for...of` 遍历会产出 `undefined`，落到 `else` 分支被静默跳过（`openai.js:4136-4138`）。

**Swift 建模（等价且安全）**

```swift
/// 一个槽位：要么是单条消息，要么是一个消息集合（chatHistory / dialogueExamples / controlPrompts / main）。
public struct Slot {
    public let identifier: String          // PromptID.rawValue，如 "worldInfoBefore"
    /// 单消息槽位 = 1 条；集合槽位 = 0..n 条。
    /// 用数组统一建模，避免 enum 分支到处 switch。
    public var messages: [Message]
    /// 是否是「集合」槽位。仅用于断言与日志，不参与行为。
    public let isCollection: Bool

    public var tokens: Int { messages.reduce(0) { $0 + $1.tokens } }
}

/// 运行时消息：role + content + 缓存 token 数。
public struct Message: Equatable {
    public var role: ChatCompletionMessage.Role
    public var content: String
    public var name: String?
    /// ST 的 message.identifier，用于 tool_call_id 与 squash 排除表（§2.8）
    public var identifier: String
    /// 创建时算好并缓存；content 变更后**必须**重算（§2.8）
    public var tokens: Int
}
```

```swift
public final class ChatCompletion {

    /// 剩余 token 预算（整数，可正可负——允许临时透支用于 reserve/free 配对）
    public private(set) var tokenBudget: Int

    /// 槽位数组，**下标 = prompt_order 索引**。
    /// nil 等价于 JS 稀疏数组的「洞」，flatten 时跳过。
    public private(set) var slots: [Slot?]

    public init(promptOrderCount: Int) {
        self.slots = Array(repeating: nil, count: promptOrderCount)
        self.tokenBudget = 0
    }

    // ---- 预算记账（openai.js:4199-4240 的等价物）----
    public func canAfford(_ tokens: Int) -> Bool { tokenBudget - tokens >= 0 }
    public func canAffordAll(_ list: [Int]) -> Bool { tokenBudget - list.reduce(0, +) >= 0 }
    public func reserve(_ tokens: Int) { tokenBudget -= tokens }
    public func free(_ tokens: Int) { tokenBudget += tokens }

    /// add(collection, position) 的等价物（openai.js:3998-4013）
    /// - position == nil 或 -1 ⇒ 追加到末尾
    /// - 否则「在该下标处落位」（覆盖原值），越界时扩展数组
    public func add(_ slot: Slot, at position: Int?) throws {
        guard canAfford(slot.tokens) else { throw TokenBudgetError.exceeded(slot.identifier) }
        if let p = position, p != -1 {
            if p >= slots.count { slots.append(contentsOf: Array(repeating: nil, count: p - slots.count + 1)) }
            slots[p] = slot
        } else {
            slots.append(slot)
        }
        tokenBudget -= slot.tokens
    }

    /// insert(message, identifier, position) 的等价物（openai.js:4042-4056）
    /// - .start ⇒ unshift；.end ⇒ push；.index(n) ⇒ splice(n, 0, m)
    /// - ★ 顺序（逐字对齐源码）：
    ///     ① checkTokenBudget(message) —— **即使消息是空的也会检查**，放不下就抛；
    ///     ② `if (message.content || message.tool_calls)` —— 空且无工具调用 ⇒ **什么也不做**
    ///        （不插入、**也不扣预算**，因为 decreaseTokenBudgetBy 在 if 内部，:4052）。
    public func insert(_ message: Message, into identifier: String, at position: InsertPosition = .end) throws {
        // ① 预算检查（openai.js:4044）
        guard canAfford(message.tokens) else { throw TokenBudgetError.exceeded(message.identifier) }
        // ② 空消息短路（openai.js:4047）
        guard !message.content.isEmpty else { return }
        guard let idx = slots.firstIndex(where: { $0?.identifier == identifier }) else {
            throw AssemblyError.slotNotFound(identifier)
        }
        switch position {
        case .start:        slots[idx]!.messages.insert(message, at: 0)
        case .end:          slots[idx]!.messages.append(message)
        case .index(let n): slots[idx]!.messages.insert(message, at: n)
        }
        tokenBudget -= message.tokens
    }

    public enum InsertPosition { case start, end, index(Int) }

    /// flatten → [ChatCompletionMessage]（openai.js:4120-4141）
    public func makeWireMessages() -> [ChatCompletionMessage] {
        var out: [ChatCompletionMessage] = []
        for case let slot? in slots {                       // 跳过 nil（洞）
            if slot.isCollection {
                for m in slot.messages { append(m, to: &out) }
            } else if let m = slot.messages.first {
                append(m, to: &out)
            }
        }
        return out
    }
    private func append(_ m: Message, to out: inout [ChatCompletionMessage]) {
        guard !m.content.isEmpty else { return }            // openai.js:4125
        var msg = ChatCompletionMessage(role: m.role,
                                        content: m.content,
                                        name: (m.name?.isEmpty == false) ? m.name : nil)
        if m.role == .tool { msg.toolCallID = m.identifier } // openai.js:4131
        out.append(msg)
    }
}
```

> **⚠️ 易错点 2.1**：`slots` 的下标语义**只对 `prompt_order` 内的 prompt 成立**。`controlPrompts` 是**追加**（`add(controlPrompts)` 无 position），所以它在 `prompt_order` 之后；`continueNudge` 用 `add(collection, -1)` 也是追加（`openai.js:1090`）。
>
> **⚠️ 易错点 2.2**：`add` 会**覆盖**该下标的原有槽位，不会合并。如果两个不同 identifier 的 prompt 在 `prompt_order` 里指向同一索引（不会发生，但配置损坏时可能），后者胜。

#### 2.1.2 「可排序、可开关」的 `PromptSlotSpec`

`prompt_order` 在 ST 里是**用户可拖拽**的配置（`PromptManager.getPromptOrderForCharacter`）。Swift 侧用两层建模：

```swift
/// 用户可配置的 prompt 条目（= PromptManager 的 Prompt 对象）
/// 来源：PromptManager.js:182-195（字段清单与默认值）
public struct PromptSpec: Codable, Identifiable, Equatable {

    public var identifier: String            // PromptID.rawValue
    public var name: String = ""             // UI 显示名
    public var role: ChatCompletionMessage.Role = .system
    public var content: String = ""
    public var systemPrompt: Bool?           // nil 表示「未指定」——不是 false！
    public var position: RelativePosition?   // .start / .end，仅扩展 prompt 用
    public var injectionDepth: Int?          // nil ≠ 0，见易错点 2.6
    public var injectionPosition: InjectionPosition?   // nil ⇒ 相对位置
    public var injectionOrder: Int?          // nil ⇒ 运行时按 100 处理
    public var injectionTrigger: [String] = []          // 唯一有默认值的字段
    public var forbidOverrides: Bool?
    public var isExtension: Bool = false

    public var id: String { identifier }

    public enum RelativePosition: String, Codable { case start, end }
    public enum InjectionPosition: Int, Codable { case relative = 0, absolute = 1 }
}

/// 用户排序的一项（= prompt_order 的 entry）
public struct PromptOrderEntry: Codable, Equatable {
    public var identifier: String
    public var enabled: Bool
}

/// 用户「Prompt Manager」的完整配置
public struct PromptManagerConfig: Codable {
    public var prompts: [PromptSpec]                 // 无序池
    public var promptOrder: [PromptOrderEntry]       // ★ 决定最终顺序
}
```

**默认 `prompt_order`（`02#1.3`，`default/content/presets/openai/Default.json:129-208`）**

```swift
public enum DefaultPromptOrder {
    /// 单人聊天（character_id = 100000）
    public static let solo: [PromptOrderEntry] = [
        .init(identifier: PromptID.main,               enabled: true),
        .init(identifier: PromptID.worldInfoBefore,    enabled: true),
        .init(identifier: PromptID.charDescription,    enabled: true),
        .init(identifier: PromptID.charPersonality,    enabled: true),
        .init(identifier: PromptID.scenario,           enabled: true),
        .init(identifier: PromptID.enhanceDefinitions, enabled: false),  // 默认禁用
        .init(identifier: PromptID.nsfw,               enabled: true),
        .init(identifier: PromptID.worldInfoAfter,     enabled: true),
        .init(identifier: PromptID.dialogueExamples,   enabled: true),
        .init(identifier: PromptID.chatHistory,        enabled: true),
        .init(identifier: PromptID.jailbreak,          enabled: true),
    ]
    /// 群聊（character_id = 100001）额外在 charDescription 之前插 personaDescription
}
```

> 顺序**必须可持久化、可拖拽**；`slots` 的容量 = `promptOrder.count`。

**「开关」语义（`02#1.7`，`PromptManager.js:1516-1541`）** —— 这是最容易做错的一处：

```
getPromptCollection(generationType):
    for entry in promptOrder:
        prompt = getPromptById(entry.identifier)
        if prompt == nil: continue
        if entry.enabled && shouldTrigger(prompt, generationType):
            collection.add(preparePrompt(prompt))          # ← 进入 collection（顺序 = prompt_order 顺序）
        else if entry.identifier == "main":
            clone = prompt; clone.content = ""             # ← main 永远占位（空内容）
            collection.add(preparePrompt(clone))
```

- **禁用的 prompt 不进入 collection** ⇒ 后面 `addToChatCompletion` 里 `prompts.has(source)` 为假 ⇒ 被跳过。
- **唯一例外是 `main`**：即使禁用也以**空内容**占位，因为扩展 prompt 的「相对注入」需要一个锚点（`openai.js:1266`）。
- `shouldTrigger`：`injectionTrigger` 为空 ⇒ 永远触发；否则必须包含当前 generation type（`normal`/`swipe`/`continue`/`impersonate`/`quiet`）。

> **⚠️ 易错点 2.3**：`main` 的空内容占位**仍然会走一遍 `preparePrompt`（宏替换）**。空串跑宏引擎返回空串，无害，但别把它当成「nil 时也是 nil」。

#### 2.1.3 为什么不直接 `[Slot]`

如果改成「按 22 步顺序 append」，那么 `prompt_order` 的拖拽就失效了。**必须**保留「下标落位 + 洞」的语义（§2.1.1 的 `[Slot?]`）。这是与 ST 行为对齐的关键，也是 §9.5 golden test 的主要断言点。

### 2.2 关键标识符清单 → Swift 常量 `[P0]`

**来源**：`02#1.7`（标识符表）、`constants.js:48-56`（扩展注入 key）。

```swift
/// prompt identifier 常量。rawValue 必须与 ST 字符串**逐字符一致**（用户配置里就是这些串）。
public enum PromptID {
    // ---- prompt_order 内的核心槽位 ----
    public static let main               = "main"
    public static let worldInfoBefore    = "worldInfoBefore"
    public static let worldInfoAfter     = "worldInfoAfter"
    public static let charDescription    = "charDescription"
    public static let charPersonality    = "charPersonality"
    public static let scenario           = "scenario"
    public static let personaDescription = "personaDescription"
    public static let nsfw               = "nsfw"
    public static let jailbreak          = "jailbreak"
    public static let dialogueExamples   = "dialogueExamples"
    public static let chatHistory        = "chatHistory"
    public static let enhanceDefinitions = "enhanceDefinitions"
    public static let impersonate        = "impersonate"
    public static let quietPrompt        = "quietPrompt"
    public static let groupNudge         = "groupNudge"
    public static let bias               = "bias"

    // ---- 扩展 prompt（相对注入到 main）----
    public static let summary        = "summary"
    public static let authorsNote    = "authorsNote"
    public static let vectorsMemory  = "vectorsMemory"
    public static let vectorsDataBank = "vectorsDataBank"
    public static let smartContext   = "smartContext"

    // ---- 运行时生成的 message identifier（不是 prompt identifier）----
    public static let newMainChat    = "newMainChat"
    public static let newChat        = "newChat"
    public static let newGroupChat   = "newGroupChat"
    public static let continueNudge  = "continueNudge"
    public static let continuePrefill = "continuePrefill"
    public static let emptyUserMessageReplacement = "emptyUserMessageReplacement"

    /// squashSystemMessages 的排除表（openai.js:3923）
    public static let squashExcludeList: Set<String> = [newMainChat, newChat, newGroupChat /* 实际是 groupNudge */]
}

/// 扩展注入 key（constants.js:48-56）。
/// ★ getExtensionPrompt 按 **key 的字典序** (= Swift 的 < 比较，UTF-8 字节序) 拼接，
///   不是按注册顺序。ASCII 大写 < 小写，所以 "PERSONA_DESCRIPTION" < "customDepthWI_*"。
public enum InjectID {
    public static let quietPrompt     = "QUIET_PROMPT"
    public static let depthPrompt     = "DEPTH_PROMPT"
    public static func depthPrompt(_ i: Int) -> String { "DEPTH_PROMPT_\(i)" }
    public static let customWIDepth   = "customDepthWI"
    public static func customWIDepth(depth: Int, role: Int) -> String { "customDepthWI_\(depth)_\(role)" }
    public static func customWIOutlet(_ key: String) -> String { "customWIOutlet_\(key)" }
}

/// 位置 / 逻辑枚举（02#4.1）
public enum WIPosition: Int, Codable {
    case before = 0, after = 1, anTop = 2, anBottom = 3, atDepth = 4, emTop = 5, emBottom = 6, outlet = 7
}
public enum WIRole: Int, Codable { case system = 0, user = 1, assistant = 2 }
public enum WISelectiveLogic: Int, Codable { case andAny = 0, notAll = 1, notAny = 2, andAll = 3 }
public enum WIInsertionStrategy: Int, Codable { case evenly = 0, characterFirst = 1, globalFirst = 2 }
public enum WIScanState: Int { case none = 0, initial = 1, recursion = 2, minActivations = 3 }
```

> **⚠️ 易错点 2.4**：`PromptID` 用 `static let` 而不是 `enum PromptID: String`。原因：`newMainChat`/`continuePrefill` 等是**运行时 message identifier**，而 `PromptID` 里的核心槽位是**配置里的 identifier**；二者混在一个 `CaseIterable` 里会让「遍历所有 prompt 槽位」出错。若你更想要 `enum`，请拆成 `PromptSlotID` 与 `MessageID` 两个类型。
>
> **⚠️ 易错点 2.5**：`InjectID` 的字典序问题在 §2.4 会咬人——`customDepthWI_10_system` 的字典序**小于** `customDepthWI_2_system`（"1" < "2"）。复刻时**必须**用原始字符串排序，不要按 depth 数值排序。

### 2.3 `populateChatCompletion`：22 步 → Swift 逐槽位实现 `[P0]`

**来源**：`02#1.2` 表格 + `openai.js:1185-1347`（**已逐行核对**）。

#### 2.3.0 前置：`preparePromptsForChatCompletion` 的等价物

在调用 22 步之前，必须先把「角色卡字段 + 运行时数据」灌进 `PromptSpec` 池并做宏替换。

**来源**：`02#1.7`（`openai.js:1367-1516`）。

```swift
/// 构造最终可用的 PromptSpec 池。
/// 步骤：
/// 1. 用角色卡字段填充 worldInfoBefore/After、charDescription、charPersonality、
///    scenario、personaDescription、impersonate、quietPrompt、groupNudge、bias 的 content。
/// 2. 把 systemPrompts 与用户的 prompt collection 合并：若 collection 里已有同 identifier，
///    用 collection 的 injectionPosition/injectionDepth/injectionOrder/role **覆盖**。
/// 3. 对每个 prompt 跑 macroEngine.substitute(content)。
/// 4. 角色卡覆盖：main ← systemPromptOverride（需 preferCharacterPrompt），
///    jailbreak ← jailbreakPromptOverride（需 preferCharacterJailbreak）；
///    forbidOverrides == true 或该 prompt 对当前角色禁用时跳过。
/// 来源：openai.js:1367-1516、:1495-1513
func preparePrompts(...) -> [PromptSpec]
```

各槽位的构造规则（`02#1.7`，逐条）：

| identifier | role | content 构造 |
|---|---|---|
| `worldInfoBefore` | system | `formatWorldInfo(wiResult.before, wiFormat)` |
| `worldInfoAfter` | system | `formatWorldInfo(wiResult.after, wiFormat)` |
| `charDescription` | system | `charDescription`（已 `baseChatReplace`） |
| `charPersonality` | system | `charPersonality.isEmpty ? "" : substituteParams(personalityFormat)`；`personalityFormat` 默认 `"{{personality}}"` |
| `scenario` | system | `scenario.isEmpty ? "" : substituteParams(scenarioFormat)`；默认 `"{{scenario}}"` |
| `personaDescription` | system | persona 文本；**仅当 `personaDescriptionPosition == .inPrompt` 时有值**（02#1.2 step 7） |
| `impersonate` | system | `substituteParams(impersonationPrompt)` |
| `quietPrompt` | system | 运行时 quiet prompt |
| `groupNudge` | system | `substituteParams(groupNudgePrompt)` |
| `bias` | **assistant** | `bias` 原样（不跑宏） |

```swift
/// formatWorldInfo（openai.js:789-801）：空值 → ""；wi_format 默认 "{0}"；
/// 若 format.trim() 为空 → 原样返回 value；否则 stringFormat(format, value)。
func formatWorldInfo(_ value: String, wiFormat: String) -> String {
    guard !value.isEmpty else { return "" }
    guard !wiFormat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return value }
    return stringFormat(wiFormat, value)   // 把 "{0}" / "{1}" 替换为值
}
```

#### 2.3.1 22 步 Swift 伪代码

```swift
public func populateChatCompletion(
    prompts: PromptCollection,          // preparePrompts 的产物，支持 index(of:) / has(_:) / get(_:)
    chat: ChatCompletion,
    options: PopulateOptions            // bias / quietPrompt / type / messages / messageExamples
) async throws {

    // ── 局部工具（openai.js:1187-1208）────────────────────────────────
    func addToChatCompletion(_ source: String, target: String? = nil) async throws {
        guard prompts.has(source) else { return }                              // :1189
        if promptManager.isPromptDisabledForActiveCharacter(source) && source != PromptID.main {
            return                                                             // :1191-1194
        }
        let prompt = prompts.get(source)!
        // ★ 绝对位置（In-Chat）的 prompt 在此**跳过**，交给 step 19 的深度注入处理
        if prompt.injectionPosition == .absolute { return }                    // :1198-1201
        let index = target.map { prompts.index(of: $0) } ?? prompts.index(of: source)  // :1203
        let slot = Slot(identifier: source,
                        messages: [await Message.fromPrompt(prompt)],
                        isCollection: false)
        try chat.add(slot, at: index)                                          // :1207
    }

    // ── step 0：为回复引导符预留 3 token（:1210）────────────────────────
    // "<|start|>assistant<|message|>" 的开销
    chat.reserve(3)

    // ── step 1-7：角色与世界信息（顺序固定，落位由 prompt_order 决定）──
    try await addToChatCompletion(PromptID.worldInfoBefore)     // :1212
    try await addToChatCompletion(PromptID.main)                // :1213
    try await addToChatCompletion(PromptID.worldInfoAfter)      // :1214
    try await addToChatCompletion(PromptID.charDescription)     // :1215
    try await addToChatCompletion(PromptID.charPersonality)     // :1216
    try await addToChatCompletion(PromptID.scenario)            // :1217
    try await addToChatCompletion(PromptID.personaDescription)  // :1218

    // ── step 8-10：controlPrompts（永远排在最后）──────────────────────
    var controlPrompts = Slot(identifier: "controlPrompts", messages: [], isCollection: true) // :1222
    if options.type == .impersonate {                                          // :1224-1225
        if let m = try? await Message.fromPromptOptional(prompts.get(PromptID.impersonate)) {
            controlPrompts.messages.append(m)
        }
    }
    // quietPrompt 必须**永远在 controlPrompts 内部最后**（:1228 注释）
    if let m = try? await Message.fromPromptOptional(prompts.get(PromptID.quietPrompt)), !m.content.isEmpty {
        controlPrompts.messages.append(m)                                      // :1229-1236
    }

    // ── step 11：为 controlPrompts 预留（:1238）─────────────────────────
    chat.reserve(controlPrompts.tokens)

    // ── step 12：nsfw, jailbreak, 然后所有 userRelativePrompts（:1241-1257）──
    let systemPrompts = [PromptID.nsfw, PromptID.jailbreak]
    // ★ 关键：`system_prompt === false`（严格等于 false），不是 `!= true`
    let userRelativePrompts = prompts.collection
        .filter { $0.systemPrompt == false && $0.injectionPosition != .absolute }
        .map { $0.identifier }
    for identifier in systemPrompts + userRelativePrompts {
        try await addToChatCompletion(identifier)
    }

    // ── step 13：enhanceDefinitions（:1260）────────────────────────────
    if prompts.has(PromptID.enhanceDefinitions) {
        try await addToChatCompletion(PromptID.enhanceDefinitions)
    }

    // ── step 14：bias（role = assistant，:1263）────────────────────────
    if !options.bias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        try await addToChatCompletion(PromptID.bias)
    }

    // ── step 15-16：扩展 prompt 相对注入到 main（:1265-1307）───────────
    let injectToMain: (PromptSpec, PromptSpec.RelativePosition) async throws -> Void = { prompt, position in
        if chat.has(PromptID.main) {
            // main 槽位存在 ⇒ 直接插到 main **内部**的 start/end（unshift / push）
            let message = await Message.fromPrompt(prompt)
            try chat.insert(message, into: PromptID.main,
                            at: position == .start ? .start : .end)            // :1268
        } else {
            // main 槽位不存在（main 被设为 In-Chat）⇒ 把它转成绝对注入，
            // 复制 main 的 role / position / depth / order，插在 main 的相邻位置。
            guard let indexOfMain = absolutePrompts.firstIndex(where: { $0.identifier == PromptID.main })
            else { return }                                                    // :1272-1283
            var copy = prompt
            let main = absolutePrompts[indexOfMain]
            copy.role = main.role
            copy.injectionPosition = main.injectionPosition
            copy.injectionDepth = main.injectionDepth
            copy.injectionOrder = main.injectionOrder
            absolutePrompts.insert(copy, at: position == .end ? indexOfMain + 1 : indexOfMain)
        }
    }
    let knownPrompts = [PromptID.summary, PromptID.authorsNote,
                        PromptID.vectorsMemory, PromptID.vectorsDataBank, PromptID.smartContext]
    for key in knownPrompts {
        if let p = prompts.get(key), let pos = p.position {                      // :1295-1302
            try await injectToMain(p, pos)
        }
    }
    for p in prompts.collection where p.isExtension && p.position != nil {       // :1305-1307
        try await injectToMain(p, p.position!)
    }

    // ── step 17：工具 token 预留（:1310-1316）—— v1 跳过 ───────────────

    // ── step 18：continue + continue_prefill（:1320-1331）—— v1 跳过 [P2] ─

    // ── step 19：深度注入（★ 见 §2.4）─────────────────────────────────
    var messages = try await populationInjectionPrompts(
        absolutePrompts: absolutePrompts,
        messages: options.messages,
        chat: chat
    )

    // ── step 20：history / examples 的先后（:1337-1343）────────────────
    if options.pinExamples {                       // power_user.pin_examples，默认 false
        try await populateDialogueExamples(prompts, chat, options.messageExamples)
        try await populateChatHistory(&messages, prompts, chat, options.type, options.cyclePrompt)
    } else {
        try await populateChatHistory(&messages, prompts, chat, options.type, options.cyclePrompt)
        try await populateDialogueExamples(prompts, chat, options.messageExamples)
    }

    // ── step 21：controlPrompts 追加到末尾（:1345-1346）────────────────
    chat.free(controlPrompts.tokens)
    if !controlPrompts.messages.isEmpty { try chat.add(controlPrompts, at: nil) }

    // ── step 22：squashSystemMessages（:1608-1610，默认 false）[P2] ─────
    if settings.squashSystemMessages && !options.dryRun {
        await chat.squashSystemMessages()
    }
}
```

**核对清单（每一步都要能在 Swift 里指出对应行）**

| step | 动作 | 源码 |
|---|---|---|
| 0 | `reserveBudget(3)` | `openai.js:1210` |
| 1-7 | 7 个 `addToChatCompletion` | `:1212-1218` |
| 8 | `setOverriddenPrompts` + 建 controlPrompts | `:1221-1222` |
| 9 | impersonate 仅 `type === 'impersonate'` | `:1224-1225` |
| 10 | quietPrompt 有内容才加，且在 controlPrompts 内最后 | `:1229-1236` |
| 11 | `reserveBudget(controlPrompts)` | `:1238` |
| 12 | `['nsfw','jailbreak', ...userRelative]` 逐个 add | `:1241-1257` |
| 13 | enhanceDefinitions | `:1260` |
| 14 | bias（`bias.trim().length`） | `:1263` |
| 15 | knownPrompts → injectToMain | `:1286-1302` |
| 16 | `p.extension && p.position` → injectToMain | `:1305-1307` |
| 17 | tool token 预留 | `:1310-1316` |
| 18 | continue prefill | `:1320-1331` |
| 19 | `populationInjectionPrompts` | `:1334` |
| 20 | pin_examples 分支 | `:1337-1343` |
| 21 | free + add controlPrompts | `:1345-1346` |
| 22 | squashSystemMessages | `:1608-1610` |

> **⚠️ 易错点 2.6（最容易错）**：step 12 的过滤条件是 `prompt.system_prompt === false`，**不是** `!prompt.system_prompt`。JS 里 `undefined === false` 为 `false`，所以**未显式设置 `system_prompt` 的 prompt 不会进入 `userRelativePrompts`**，只能靠 step 16 的 `extension && position` 路径注入。Swift 里必须写成 `$0.systemPrompt == false`（`Bool?` 与 `false` 比较，nil 时为 false）。写成 `$0.systemPrompt != true` 就会多注入一批 prompt。
>
> **⚠️ 易错点 2.7**：`injection_depth` 未设置时是 `undefined`，`undefined === 0` 为 `false`，所以**未设 depth 的 In-Chat prompt 永远不会被注入**。UI 上显示的默认值 4 只是显示默认（`PromptManager.js:1378` 的 `DEFAULT_DEPTH`），不写回数据。Swift 用 `Int?` 精确表达，**不要**用 `Int = 4`。
>
> **⚠️ 易错点 2.8**：`injection_order` 未设置时按 `?? 100` 处理（`openai.js:834`），但 `Prompt` 构造函数里默认是 `DEFAULT_ORDER`。Swift 侧统一在**使用点**做 `?? 100`，不要在解码时填默认值（否则无法区分「用户设为 100」与「未设置」——虽然行为相同，但 `filter` 分支依赖 `== 100` 的字面比较，见 §2.4）。
>
> **⚠️ 易错点 2.9**：`injectToMain` 的 `chat.insert(message, into: "main", ...)` 路径要求 `main` 槽位**已存在**。若 `main` 在 `prompt_order` 里被禁用，`getPromptCollection` 仍会用**空内容**占位（§2.1.2），所以槽位存在、插入成功——但插入后 `main` 槽位里就有内容了。这与 ST 一致。

### 2.4 深度注入 `populationInjectionPrompts` `[P0]`

**来源**：`02#1.4` + `openai.js:810-875`（**已逐行核对**）。

#### 2.4.1 语义前提（必须先理解，否则一定写错）

1. **传入的 `messages` 此时是逆序的**：索引 0 = 最新消息，索引 `len-1` = 最旧。
   因为 `setOpenAIMessages` 从 `chat.length-1` 往前遍历构造（`02#1.4` 要点 1）。
   Swift 侧**建议直接传入「最新在前」的数组**，在函数末尾 reverse 成正序返回，与 ST 一致。
2. **注入位置公式是 `depth + totalInserted`**（`openai.js:867`）：因为插入后索引 0 仍然是最新消息，后续更浅的 depth 需要继续往数组**前面**插，所以要补偿已插入条数。
3. **同一 `(depth, order, role)` 的多条 prompt 用 `\n` 拼成一条消息**（`openai.js:849-852`）。
4. `MAX_INJECTION_DEPTH = 10000`（`script.js:500`，`getExtensionPromptMaxDepth()` 直接返回它，`script.js:3281-3289`）。

#### 2.4.2 Swift 实现

```swift
public let MAX_INJECTION_DEPTH = 10000

/// 深度注入。输入 messages 为「最新在前」；返回**正序**（旧→新）数组。
/// 来源：openai.js:810-875
public func populationInjectionPrompts(
    absolutePrompts: [PromptSpec],       // 只有 injectionPosition == .absolute 的 prompt
    messages: [Message],                 // 最新在前（index 0 = 最新）
    extensionPrompts: ExtensionPromptStore
) async -> [Message] {

    var messages = messages
    var totalInserted = 0

    let roleOrder: [ChatCompletionMessage.Role] = [.system, .user, .assistant]
    let roleEnum: [ChatCompletionMessage.Role: WIRole] =
        [.system: .system, .user: .user, .assistant: .assistant]

    for depth in 0...MAX_INJECTION_DEPTH {                     // :820

        // (1) 取该 depth 下有内容的 prompt
        let depthPrompts = absolutePrompts.filter {
            $0.injectionDepth == depth && !$0.content.isEmpty  // ★ 严格相等；nil 不匹配任何 depth
        }

        var roleMessages: [Message] = []

        // (2) 按 injection_order 分组，order **从大到小**处理（:842）
        var orderGroups: [Int: [PromptSpec]] = [:]
        for p in depthPrompts { orderGroups[p.injectionOrder ?? 100, default: []].append(p) } // :834
        for order in orderGroups.keys.sorted(by: >) {

            // (3) 每个 order 内按 role 固定顺序 system → user → assistant（:847）
            for role in roleOrder {
                let roleContent = orderGroups[order]!
                    .filter { $0.role == role }
                    .map(\.content)
                    .joined(separator: "\n")                    // :849-852

                // (4) 仅 order == 100 时补上 extension_prompts 里同 depth/role 的 IN_CHAT 注入（:855）
                let extContent = (order == 100)
                    ? await extensionPrompts.prompt(position: .inChat, depth: depth,
                                                    separator: "\n", role: roleEnum[role],
                                                    wrap: false)   // ★ wrap 硬编码为 false（:826）
                    : ""

                // (5) 拼接并 trim；两段都空则跳过（:858-862）
                let joint = [roleContent, extContent]
                    .filter { !$0.isEmpty }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .joined(separator: "\n")

                if !joint.isEmpty {
                    roleMessages.append(Message(role: role, content: joint,
                                                name: nil, identifier: "injection-\(depth)-\(role)",
                                                tokens: 0))   // token 稍后统一算，见下
                }
            }
        }

        // (6) 插入位置补偿（:866-870）
        if !roleMessages.isEmpty {
            let injectIdx = min(depth + totalInserted, messages.count)   // JS splice 越界会夹到 length
            messages.insert(contentsOf: roleMessages, at: injectIdx)
            totalInserted += roleMessages.count
        }
    }

    messages.reverse()                                          // :873  ★ 千万别忘
    return messages
}
```

**`ExtensionPromptStore` 的等价物（`getExtensionPrompt`，`script.js:3301-3329`）**

```swift
public struct ExtensionPrompt: Equatable {
    public var value: String
    public var position: ExtensionPosition      // .none / .inPrompt / .inChat
    public var depth: Int?                      // nil ⇒ 匹配任意 depth
    public var role: WIRole?                    // nil ⇒ 匹配任意 role
    public var scan: Bool                       // 是否可被世界书扫描到（§5.3）
}

public final class ExtensionPromptStore {
    private var storage: [String: ExtensionPrompt] = [:]

    public func set(_ key: String, value: String, position: ExtensionPosition, depth: Int = 0,
                    scan: Bool = false, role: WIRole = .system) { ... }

    /// 来源：script.js:3301-3329
    /// 1. 按 key **字典序** 排序（Object.keys().sort()）★
    /// 2. 过滤 position 匹配、value 非空
    /// 3. 过滤 depth：x.depth === undefined **或** x.depth === depth
    /// 4. 过滤 role：x.role === undefined **或** x.role === role
    /// 5. 各 value 先 trim，再用 separator join
    /// 6. wrap 时才加首尾分隔符（populationInjectionPrompts 里 wrap = false）
    /// 7. **整串再跑一次 macroEngine.substitute()**（script.js:3326）
    public func prompt(position: ExtensionPosition, depth: Int? = nil,
                       separator: String = "\n", role: WIRole? = nil,
                       wrap: Bool = true) async -> String {
        var values = storage.keys.sorted()                      // ★ 字典序，不是注册顺序
            .compactMap { storage[$0] }
            .filter { $0.position == position && !$0.value.isEmpty }
            .filter { depth == nil || $0.depth == nil || $0.depth == depth }
            .filter { role == nil || $0.role == nil || $0.role == role }
            .map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: separator)

        if wrap && !values.isEmpty && !values.hasPrefix(separator) { values = separator + values }
        if wrap && !values.isEmpty && !values.hasSuffix(separator) { values += separator }
        if !values.isEmpty { values = macroEngine.substitute(values) }   // :3326
        return values
    }
}
```

**扩展注入 key 与字典序（`02#1.4` 表）**

```
STORY_STRING = "__STORY_STRING__"          # 仅 Text Completion
QUIET_PROMPT = "QUIET_PROMPT"
DEPTH_PROMPT = "DEPTH_PROMPT"              # 角色 depth_prompt
DEPTH_PROMPT_{i}                           # 群聊成员 depth prompt
customDepthWI                              # 世界书 atDepth 前缀
customDepthWI_{depth}_{role}               # 世界书 atDepth（script.js:4671）
customWIOutlet_{key}                       # 世界书 outlet
```

> **⚠️ 易错点 2.10（高危）**：`messages.reverse()` 与 `depth + totalInserted` **必须一起复刻**。漏掉 reverse ⇒ 深度注入方向完全反了；漏掉 `totalInserted` 补偿 ⇒ 多条注入互相覆盖位置。
>
> **⚠️ 易错点 2.11**：`wrap = false` 是**硬编码**在 `populationInjectionPrompts` 里的（`openai.js:826`），不是配置项。
>
> **⚠️ 易错点 2.12**：`STEP 4` 的 `order == 100` 判定用的是 **字面 100**（`openai.js:829` 的 `const extensionPromptsOrder = '100'`；`orderGroups` 先建了一个 `'100'` 桶）。所以用户把 `injection_order` 显式设为 100 或者不设（`?? 100`）都会走到扩展 prompt 合并。
>
> **⚠️ 易错点 2.13**：`getExtensionPrompt` 过滤里的 `x.depth === undefined` **视为匹配**。Swift 的 `Int?` 要写成 `$0.depth == nil || $0.depth == depth`，**不能**写 `$0.depth == depth`（nil == 4 为 false，会漏掉所有未设 depth 的注入）。
>
> **⚠️ 易错点 2.14**：深度注入的 token 计算。ST 里注入消息也在 `chatCompletion` 的预算之外（`populationInjectionPrompts` 直接 `splice` 进 `messages`，不经过 `chat.add`，所以**不扣预算也不检查预算**）。Swift 需要显式补上 `tokenCounter.count(role:content:name:)` 以便统计，但**不要**在这里做 budget 检查——要与 ST 一致。

### 2.5 世界书注入点落在哪些槽位 `[P0]`

**来源**：`02#1.5` 表 + `script.js:4635-4678`（**已核对**）。

`checkWorldInfo` 的返回值 → 落点：

| WI 返回字段 | Swift 落点 | 源码 |
|---|---|---|
| `worldInfoBefore` | `PromptID.worldInfoBefore` 槽位，content = `formatWorldInfo(before)` | `openai.js:1376`、`:789-801` |
| `worldInfoAfter` | `PromptID.worldInfoAfter` 槽位 | `openai.js:1377` |
| `WIDepthEntries` | 每个 `(depth, role)` 一条 → `extensionPrompts.set("customDepthWI_\(depth)_\(role)", entries.joined("\n"), position: .inChat, depth: depth, scan: false, role: role)` | `script.js:4668-4673` |
| `ANTopEntries` / `ANAfterEntries` | 拼进 Author's Note 的值：`"\(anTop)\n\(originalAN)\n\(anBottom)"` 再 `replace(/(^\n)|(\n$)/g, "")`，然后 `setExtensionPrompt(authorsNote, …)` | `world-info.js:5268-5272` |
| `EMEntries` | `{position: before/after, content}` → **先 `baseChatReplace()` 再 `parseMesExamples()`**；`before` 用 `unshift(contentsOf:)`，`after` 用 `append(contentsOf:)` 合进 `mesExamplesArray` | `script.js:4638-4655` |
| `outletEntries` | `setExtensionPrompt("customWIOutlet_\(key)", joined, position: .none, depth: 0)`；由 `{{outlet::key}}` 宏取用 | `script.js:4674-4678`、`macros.js:596-599` |

**两条容易忽略的细节**

1. **AN 的合并前提是 `shouldWIAddPrompt`**（`world-info.js:5268`）。AN 当前轮不插入时，`ANTop`/`ANBottom` 条目会被**静默丢弃**（不会作为普通注入出现）。
2. **EM 条目走的是「字符串 → 示例块」流程**，不是直接塞消息：`baseChatReplace` → `parseMesExamples` → `unshift`/`push` 到 `mesExamplesArray`，然后**与卡片的 `mes_example` 一起**在 §3 被解析。所以**EM 条目的 content 必须含 `<START>` 或至少是 `Name:` 开头的对话文本**，否则解析出来是空的。

### 2.6 `populateChatHistory`：顺序、裁剪、保护 `[P0]`

**来源**：`02#6.2` / `02#6.4` + `openai.js:885-1092`（**已逐行核对**）。

```swift
public func populateChatHistory(
    _ messages: inout [Message],           // 正序（旧→新），来自 §2.4 的输出
    prompts: PromptCollection,
    chat: ChatCompletion,
    type: GenerationType,
    cyclePrompt: String?
) async throws {

    guard prompts.has(PromptID.chatHistory) else { return }                // :886-888

    // (1) 落位空集合槽位（★ 空集合不占 token）
    try chat.add(Slot(identifier: PromptID.chatHistory, messages: [], isCollection: true),
                 at: prompts.index(of: PromptID.chatHistory))              // :890

    // (2) 为「新聊天提示」预留预算，保证它一定能放下（:893-895）
    let newChatText = isGroupChat ? settings.newGroupChatPrompt : settings.newChatPrompt
    let newChatMessage = Message(role: .system,
                                 content: macroEngine.substitute(newChatText),
                                 identifier: PromptID.newMainChat,
                                 tokens: tokenCounter.count(role: .system, content: ...))
    chat.reserve(newChatMessage.tokens)

    // (3) 群聊 nudge 预留（:897-903）[P2]
    // (4) continue nudge 预留（:905-927）[P2]

    // (5) send_if_empty：最后一条是 assistant 时补一条空 user 消息（:929-933）[P2]
    //     ★ 它在循环**之前** insert（追加到槽位末尾 = 最新位置）

    // (6) ★ 裁剪主循环：从最新到最旧逐条尝试（:947-1075）
    let chatPool = messages.reversed()                     // index 0 = 最新
    for (index, chatPrompt) in chatPool.enumerated() {
        var prompt = PromptSpec(from: chatPrompt)
        prompt.identifier = "chatHistory-\(messages.count - index)"        // :954

        // ★ 关键：会跑宏替换！见下方「⚠️ 勘误」
        let chatMessage = await Message.fromPrompt(preparePrompt(prompt))  // :955

        // names_behavior == COMPLETION 时才写 name（:957-960）[P2]
        if namesBehavior == .completion, let n = prompt.name {
            chatMessage.name = isValidName(n) ? n : sanitizeName(n)
        }

        if chat.canAfford(chatMessage.tokens) {                            // :1070
            try chat.insert(chatMessage, into: PromptID.chatHistory, at: .start)  // :1071
        } else {
            break                                                          // :1073 ★ 遇阻即停
        }
    }

    // (7) newMainChat 永远保留，且排在整个历史**之前**（:1077-1079）
    chat.free(newChatMessage.tokens)
    try chat.insert(newChatMessage, into: PromptID.chatHistory, at: .start)

    // (8) 群聊 nudge → insertAtEnd（:1081-1085）[P2]
    // (9) continue nudge collection → chat.add(collection, at: -1)（:1087-1091）[P2]
}
```

**裁剪语义（必须一致，逐条来自 `02#6.2` 结论）**

| 规则 | 说明 |
|---|---|
| **丢弃方向** | 丢弃**最旧**的消息，保留最新的**连续后缀** |
| **停止条件** | 遇到第一条放不下的消息**立即 `break`**。**没有**「跳过这条继续试更旧的」逻辑 |
| **单条超长** | 不做 message 级截断。单条超长只会导致自己+所有更旧消息被丢弃 |
| **槽位内部顺序** | 因为不断 `insertAtStart`，最终 `messages` 是**正序（旧→新）** |
| **`newMainChat`** | 预算在循环前预留 ⇒ 即使完全没空间也会出现，且 `insertAtStart` 后排在所有历史消息**之前** |
| **强制 prompt** | `main`/`worldInfo*`/`charDescription`/`charPersonality`/`scenario`/`personaDescription`/`nsfw`/`jailbreak`/`enhanceDefinitions` 不参与裁剪：`add()` 里 `canAfford` 失败会**抛异常**，整次生成失败（"Mandatory prompts exceed the context size."，`openai.js:1589-1592`） |
| **examples 裁剪** | 「整块」的：`canAffordAll([newChat, ...block])` 失败 ⇒ `break`，后续所有块丢弃（`openai.js:1124-1126`） |
| **`pin_examples`** | `true` 时**先** examples 再 history（examples 优先占预算，历史更容易被裁）。默认 `false` |

> **⚠️ 勘误（相对 02#3.6）**：02#3.6 的表格写「聊天历史消息 ❌ 不做宏替换」。**与源码不符**：
> `populateChatHistory` 在 `openai.js:955` 调用的是 `promptManager.preparePrompt(prompt)`，
> 而 `preparePrompt`（`PromptManager.js:1277-1290`）**无条件**对 `prompt.content` 跑 `substituteParams`。
> 因此**聊天历史消息的内容也会被宏替换**（`{{user}}`/`{{char}}`/`{{time}}`/`{{getvar::}}` 都会生效）。
> Swift 侧必须复刻这一点，否则历史里出现的宏会原样发给模型。
> （历史在写入 `chat` 时通常已替换过一次，所以多数情况下看不出差别——但只要用户手改过消息或消息里含动态宏就会暴露。）

> **⚠️ 易错点 2.15**：「如何保护 pinned 消息」——**ST 没有消息级 pin**（`02#6.3`）。
> 只有三种「保护」机制：① `newMainChat` 提前预留预算；② 强制 prompt 放不下就抛错（不裁剪）；
> ③ 世界书 `ignoreBudget` 条目不受 WI 预算限制。若要实现 iOS 特有的「置顶消息」，
> 必须**自行设计**并明确语义（见 §6.6 的扩展方案），不要臆造 ST 行为。

### 2.7 `populateDialogueExamples` `[P0]`

**来源**：`02#2.4` + `openai.js:1101-1134`。

```swift
public func populateDialogueExamples(
    _ prompts: PromptCollection,
    _ chat: ChatCompletion,
    _ messageExamples: [[ExampleMessage]]     // §3.2 的输出：数组的数组
) async throws {

    // (1) 落位空集合槽位
    try chat.add(Slot(identifier: PromptID.dialogueExamples, messages: [], isCollection: true),
                 at: prompts.index(of: PromptID.dialogueExamples))

    guard !messageExamples.isEmpty else { return }

    // (2) 每个 <START> 块之前都插一条 [Example Chat]（默认 new_example_chat_prompt，identifier = newChat）
    let newExampleChat = Message(role: .system,
                                 content: macroEngine.substitute(settings.newExampleChatPrompt),
                                 identifier: PromptID.newChat,
                                 tokens: ...)

    for (blockIdx, dialogue) in messageExamples.enumerated() {
        let chatMessages: [Message] = dialogue.enumerated().map { (msgIdx, p) in
            var m = Message(role: .system, content: p.content,
                            name: p.name,                       // "example_user" / "example_assistant"
                            identifier: "dialogueExamples \(blockIdx)-\(msgIdx)", tokens: ...)
            return m
        }

        // (3) ★ 预算**逐块**检查：某一块放不下就 break，后面的块全不要
        guard chat.canAffordAll([newExampleChat.tokens] + chatMessages.map(\.tokens)) else { break }  // :1124

        try chat.insert(newExampleChat, into: PromptID.dialogueExamples, at: .end)
        for m in chatMessages {
            try chat.insert(m, into: PromptID.dialogueExamples, at: .end)
        }
    }
}
```

> **⚠️ 易错点 2.16**：`[Example Chat]` 是**每个块一条**，插在块内消息**之前**；`identifier = newChat`（不是 `newMainChat`）。两者都在 `squashSystemMessages` 的排除表里（§2.8）。
>
> **⚠️ 易错点 2.17**：`dialogueExamples` 的 content 进入 `Message` 前**不再做宏替换**（`openai.js:1113-1121` 只做 `Message.createAsync('system', p.content, ...)`）。因为卡片字段阶段已经 `baseChatReplace` 过（§3.4）。**唯独 `newExampleChatPrompt` 要跑 `substituteParams`**（`openai.js:1108`）。

### 2.8 收尾处理 `[P2]`

**`squashSystemMessages`（`openai.js:3922-3954`，默认 `false`）**

```swift
extension ChatCompletion {
    /// 来源：openai.js:3922-3954
    public func squashSystemMessages(tokenCounter: TokenCounter) async {
        let excludeList: Set<String> = ["newMainChat", "newChat", "groupNudge"]   // :3923

        // (1) 先 flatten（丢掉「槽位」结构，变成一维消息数组）★ 不可逆
        var flat = makeFlatMessages()

        var squashed: [Message] = []
        var last: Message? = nil

        for var message in flat {
            // (2) 强制跳过空 system 消息
            if message.role == .system && message.content.isEmpty { continue }     // :3931

            func shouldSquash(_ m: Message) -> Bool {
                !excludeList.contains(m.identifier) && m.role == .system && (m.name?.isEmpty ?? true) // :3936
            }

            if shouldSquash(message) {
                if let l = last, shouldSquash(l) {
                    // (3) 合并到上一条，并**重算 token**（:3942）
                    last!.content += "\n" + message.content
                    last!.tokens = tokenCounter.count(role: last!.role, content: last!.content)
                    if let i = squashed.indices.last { squashed[i] = last! }
                } else {
                    squashed.append(message); last = message
                }
            } else {
                squashed.append(message); last = message
            }
        }
        self.replaceAllSlotsWithFlat(squashed)
    }
}
```

> **⚠️ 易错点 2.18**：squash 会**破坏槽位结构**（`this.messages.collection = squashedMessages`），之后 `flatten()` 得到的顺序就是 `squashed` 的顺序。Swift 侧要么让 `ChatCompletion` 支持「已 squash」状态（单槽位模式），要么在 squash 之后直接用扁平数组。**不要**试图保留槽位。
>
> **⚠️ 易错点 2.19**：ST 的 `excludeList` 是 `['newMainChat','newChat','groupNudge']`，而 `bias` 的 role 是 `assistant`（本来就不 squash），`worldInfoBefore`/`main` 等的 **identifier 不在排除表里**，所以它们会被合并！这与「世界书前后应该分开」的直觉相反，但这就是 ST 行为。

**`CHAT_COMPLETION_PROMPT_READY` 事件（`openai.js:1618-1619`）** —— `[P2]`，扩展可修改最终消息数组。iOS 无扩展生态，可省略。

### 2.9 易错点汇总（§2）

| # | 易错点 | 检测方式 |
|---|---|---|
| 1 | 用 append 顺序代替 `prompt_order` 落位 | 改 `prompt_order` 后输出顺序不变 ⇒ 错 |
| 2 | `system_prompt === false` 写成 `!= true` | 输出里多了本不该出现的 prompt |
| 3 | `injection_depth` 用 `Int = 4` 而非 `Int?` | 未设 depth 的 In-Chat prompt 被错误注入 |
| 4 | `populationInjectionPrompts` 漏 reverse | 深度注入全部错位 |
| 5 | 漏 `totalInserted` 补偿 | 多条同 depth 注入互相覆盖 |
| 6 | `getExtensionPrompt` 按注册顺序而非字典序 | 多扩展注入时拼接顺序错 |
| 7 | 历史裁剪「跳过太长的继续试更旧」 | 保留的消息不连续 |
| 8 | `newMainChat` 放在历史末尾而非开头 | 第一轮对话位置错 |
| 9 | examples 逐条检查预算而非逐块 | 出现「半个示例块」 |
| 10 | squash 后仍期望槽位结构 | crash 或顺序错 |
| 11 | 强制 prompt 放不下时静默丢弃 | 应抛错（ST 抛 `TokenBudgetExceededError`） |
| 12 | 忘记 `reserveBudget(3)` 引导符 | 轻微超预算（约 3 token） |

---

## 3. `mes_example` 解析 `[P0]`

三个函数的职责边界（**不要合并**）：

```
卡片 mes_example 字符串
   │
   ├─[A] parseMesExamples(str, isInstruct)                  → [String]       每块 "<START>\n…\n"
   │      （script.js:3501-3515）
   │
   ├─[B] setOpenAIMessageExamples(blocks)                    → [[ExampleMessage]]
   │      （openai.js:656-667）  把 <START> 换成 {Example Dialogue:}，再逐块 [C]
   │
   └─[C] parseExampleIntoIndividual(block, appendNamesForGroup) → [ExampleMessage]
          （openai.js:729-787）  role 一律 system，name = example_user/example_assistant
```

调用链上游还有一个**前置宏替换**（见 §3.4）。

### 3.1 `parseMesExamples`

**来源**：`02#2.1` + `script.js:3501-3515`（**已核对**）。

```swift
/// 把 mes_example 原文切成「块」数组。
/// 来源：script.js:3501-3515
public func parseMesExamples(_ examplesStr: String, isInstruct: Bool,
                             isChatCompletionAPI: Bool = true,
                             exampleSeparator: String) -> [String] {

    // (1) 空 / 纯 "<START>" ⇒ 返回空数组（★ 精确匹配 "<START>"，不是 hasPrefix）
    guard !examplesStr.isEmpty, examplesStr != "<START>" else { return [] }

    // (2) 不以 <START> 开头时，前面补一个
    var s = examplesStr
    if !s.hasPrefix("<START>") {                       // ★ 大小写敏感！
        s = "<START>\n" + s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // (3) 块标题
    let sep = exampleSeparator.isEmpty ? "" : "\(exampleSeparator)\n"
    let blockHeading = (isChatCompletionAPI || isInstruct) ? "<START>\n" : sep

    // (4) 按 /<START>/gi 切分（★ 大小写不敏感），丢弃第一段
    let regex = try! NSRegularExpression(pattern: "<START>", options: [.caseInsensitive])
    let parts = splitKeepingOrder(s, by: regex).dropFirst()

    // (5) 每块规范化为 "<START>\n" + block.trim() + "\n"
    return parts.map { block in
        blockHeading + block.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}
```

**三个细节，逐条对照源码**

| 细节 | 源码 | 说明 |
|---|---|---|
| 空值判断是 `examplesStr === '<START>'` | `script.js:3505` | **精确相等**，不是 `hasPrefix`。`"<START>x"` 不会被判空 |
| `startsWith('<START>')` 是**大小写敏感**的 | `script.js:3510` | 若原文是 `<start>`，会**再补一个** `<START>\n` 到开头 |
| 切分用 `/<START>/gi` 是**大小写不敏感**的 | `script.js:3514` | 所以补完之后 `<start>` 也会被当作分隔符 |

**边缘案例（必测）**

| 输入 | 输出 |
|---|---|
| `""` | `[]` |
| `"<START>"` | `[]` |
| `"{{user}}: hi\n{{char}}: hello"` | `["<START>\n{{user}}: hi\n{{char}}: hello\n"]` |
| `"<START>\nA\n<START>\nB"` | `["<START>\nA\n", "<START>\nB\n"]` |
| `"<start>\nA"` | `["<START>\n<start>\nA\n"]` ← 因为补了 `<START>\n`，然后按 `<start>` 切分，第 0 段是 `<START>\n`，第 1 段是 `\nA` |

### 3.2 `setOpenAIMessageExamples`

**来源**：`02#2.2` + `openai.js:656-667`（**已核对**）。

```swift
public struct ExampleMessage: Equatable {
    public var content: String
    /// 固定是 "example_user" / "example_assistant"，**不是**真实名字
    public var name: String
    public var role: ChatCompletionMessage.Role   // 恒为 .system
}

/// 来源：openai.js:656-667
public func setOpenAIMessageExamples(_ mesExamplesArray: [String],
                                     appendNamesForGroup: Bool = true) -> [[ExampleMessage]] {
    mesExamplesArray.map { item in
        // (1) 只替换**第一个** <START>（/i，大小写不敏感）为 "{Example Dialogue:}"
        //     并去掉所有 \r
        var replaced = replaceFirst(item, pattern: "<START>", options: [.caseInsensitive],
                                   with: "{Example Dialogue:}")
        replaced = replaced.replacingOccurrences(of: "\r", with: "")
        // (2) 逐块解析
        return parseExampleIntoIndividual(replaced, appendNamesForGroup: appendNamesForGroup)
    }
}
```

> **注意**：`/\r/gm` 的 `m` 标志对 `\r` 无影响（没有 `^`/`$`），行为就是「删除所有 `\r`」。

### 3.3 `parseExampleIntoIndividual`（role 分配规则的核心）

**来源**：`02#2.3` + `openai.js:729-787`（**已逐行核对**）。这是最容易写错的函数，下面给**逐行**伪代码。

```swift
/// 来源：openai.js:729-787
/// - Parameters:
///   - messageExampleString: 已被 §3.2 处理过的块（首行是 "{Example Dialogue:}"）
///   - appendNamesForGroup: 群聊时是否给 content 加 "名字: " 前缀
///   - userName: 对应 name1（**已经是宏替换后的真实名字**，见 §3.4）
///   - charName: 对应 name2（同上）
///   - groupBotNames: 群聊成员名列表（不含 ":"），空数组表示非群聊
public func parseExampleIntoIndividual(
    _ messageExampleString: String,
    appendNamesForGroup: Bool = true,
    userName: String,
    charName: String,
    groupBotNames: [String],
    isGroupChat: Bool
) -> [ExampleMessage] {

    // (0) 每次调用都重新构造 "Name:" 前缀表（openai.js:730）
    let groupBotPrefixes = groupBotNames.map { "\($0):" }

    var result: [ExampleMessage] = []
    let lines = splitLines(messageExampleString, by: "\n")
    var curLines: [String] = []
    var inUser = false
    var inBot = false
    var botName = charName                       // :737

    /// 闭包：把 curLines 收成一条消息（openai.js:740-752）
    func addMessage(name: String, role: ChatCompletionMessage.Role, systemName: String) {
        // ★ JS 是 `cur_msg_lines.join('\n').replace(name + ':', '')`，
        //   而 String.replace(字符串, 字符串) **只替换第一次出现**，且**不校验位置**
        //   （可能在正文中间被误删）。Swift 的 replacingOccurrences 是全部替换 ⇒ 必须用 replaceFirst。
        var parsed = replaceFirst(curLines.joined(separator: "\n"), target: "\(name):", with: "")
        parsed = parsed.trimmingCharacters(in: .whitespacesAndNewlines)

        if appendNamesForGroup && isGroupChat
            && (systemName == "example_user" || systemName == "example_assistant") {   // :746
            parsed = "\(name): \(parsed)"
        }
        result.append(ExampleMessage(content: parsed, name: systemName, role: role))
        curLines = []
    }

    // (1) ★ 从 i = 1 开始：跳过第 0 行（"This is how {char} should talk" / "{Example Dialogue:}"）
    for i in 1..<lines.count {                                   // :754
        let cur = lines[i]

        // (2) 用户切换：行**以** "{user}:" **开头**（大小写敏感）
        if cur.hasPrefix("\(userName):") {                       // :758
            inUser = true
            if inBot { addMessage(name: botName, role: .system, systemName: "example_assistant") }  // :762
            inBot = false
        }
        // (3) 角色切换：行以 "{char}:" 开头，或以任一 groupBotName + ":" 开头
        else if cur.hasPrefix("\(charName):") || groupBotPrefixes.contains(where: { cur.hasPrefix($0) }) { // :765
            // 群聊里若命中的是别的成员名，切换 botName（用于后续 addMessage 的前缀剥离）
            if !cur.hasPrefix("\(charName):") && !groupBotPrefixes.isEmpty {
                botName = String(cur.split(separator: ":", maxSplits: 1)[0])   // :767
            }
            inBot = true
            if inUser { addMessage(name: userName, role: .system, systemName: "example_user") }   // :773
            inUser = false
        }

        // (4) ★ 切换行**也**被 push 进 curLines（:778）
        curLines.append(cur)
    }

    // (5) 收尾：最后一个块没有「下一条消息」来触发切换（:781-785）
    if inUser {
        addMessage(name: userName, role: .system, systemName: "example_user")
    } else if inBot {
        addMessage(name: botName, role: .system, systemName: "example_assistant")
    }

    return result
}

/// JS `String.replace("x", "")` 的等价物：只替换第一处
func replaceFirst(_ s: String, target: String, with replacement: String) -> String {
    guard let r = s.range(of: target) else { return s }
    return s.replacingCharacters(in: r, with: replacement)
}

/// 把字符串按 `regex` 切成 [String]，保留分隔符之间的所有片段，
/// 语义等价于 JS 的 `s.split(regex)`（含「相邻分隔符产生空片段」与「首尾空片段」）。
/// `parseMesExamples` 用 `.dropFirst()` 丢弃 `<START>` 之前的文本。
func splitKeepingOrder(_ s: String, by regex: NSRegularExpression) -> [String] {
    let ns = s as NSString
    let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
    var parts: [String] = []
    var cursor = 0
    for m in matches {
        let len = m.range.length
        parts.append(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
        cursor = m.range.location + len
    }
    parts.append(ns.substring(from: cursor))
    return parts
}
```

**role 分配规则总结**

| 规则 | 值 |
|---|---|
| `role` | **恒为 `.system`**（`openai.js:750`、`:762`、`:773`、`:782`、`:784`） |
| `name` | `"example_user"` 或 `"example_assistant"`（**常量字符串**，不是真实名字） |
| 切换判定 | `startsWith("{名字}:")`，**大小写敏感**，且必须是**行首** |
| 切换行归属 | 切换行本身**留在** `curLines` 里，由 `addMessage` 的 `replace` 剥离前缀 |
| 群聊前缀 | `appendNamesForGroup && selected_group` 时 content 变成 `"{name}: {parsed}"` |

**role 分配真值表（示例）**

输入块（首行已换成 `{Example Dialogue:}`）：
```
{Example Dialogue:}
{{user}}: Hi there
{{char}}: Hello!
How are you?
{{user}}: Fine.
```
解析后（userName = `You`, charName = `Alice`）:
```
[0] {role: system, name: example_user,      content: "Hi there"}
[1] {role: system, name: example_assistant, content: "Hello!\nHow are you?"}
[2] {role: system, name: example_user,      content: "Fine."}
```
（首行的 `{Example Dialogue:}` 被跳过；注意 `Hi there` 里前缀 `You:` 被剥掉。）

### 3.4 `{{user}}` / `{{char}}` 的代入时机（关键）

**来源**：`script.js:3402-3494`（`getCharacterCardFieldsLazy`，**已核对**）。

```
时间线：
 ① getCharacterCardFields()
      mesExamples = baseChatReplace(character.mes_example.trim())        # script.js:3450-3455
      # baseChatReplace = substituteParams(content, { replaceCharacterCard: false })
      #   + collapseNewlines + 去 \r                                  # script.js:3341-3352
      ⇒ 此时 {{user}} / {{char}} **已经被替换成真实名字**
 ② parseMesExamples(fields.mesExamples, isInstruct)                      # script.js:3501
 ③ setOpenAIMessageExamples(mesExamplesArray) → parseExampleIntoIndividual
      ⇒ startsWith(name1 + ':') / startsWith(name2 + ':') 用的是**真实名字**
```

**结论（Swift 必须一致）**

1. `parseExampleIntoIndividual` 的 `userName` / `charName` 参数必须是**宏替换后的真实名字**（`name1` / `name2`），**不是**字面量 `"{{user}}"` / `"{{char}}"`。
2. 因此**宏替换必须发生在例解析之前**。Swift 的调用顺序：
   `MacroEngine.substitute(card.mesExample)` → `parseMesExamples` → `setOpenAIMessageExamples`。
3. 世界书 EM 条目也遵循同一顺序（`script.js:4646-4647`：`baseChatReplace(exampleMessage)` → `parseMesExamples`）。
4. 如果用户把 `{{user}}` 宏放在**行中间**（如 `Hi {{user}}: hello`），不会被识别为切换行——因为 `startsWith` 只看行首。

> **⚠️ 易错点 3.1**：`baseChatReplace` 用的是 `replaceCharacterCard: false`，意味着卡片字段内部的 `{{charPrompt}}` / `{{charJailbreak}}` / `{{charInstruction}}` **不会**被替换（`script.js:2924` 的 gate），但 `{{char}}` / `{{user}}` **会**。Swift 的 `MacroContext` 必须支持这个开关（§4.2）。
>
> **⚠️ 易错点 3.2**：`parseExampleIntoIndividual` **跳过第 0 行**。所以 §3.2 里把 `<START>` 换成 `{Example Dialogue:}` 后，那一行正好充当「被跳过的首行」。若你自己实现时忘了跳过首行，`{Example Dialogue:}` 就会进入输出。
>
> **⚠️ 易错点 3.3（Swift 特有）**：JS 的 `str.replace(name + ':', '')` 传**字符串**时只替换**第一处**；Swift 的 `replacingOccurrences(of:with:)` 替换**全部**。必须用 `replaceFirst`。举例：`example_user` 的 content 是 `"You: A\nYou: B"`，JS 得到 `"A\nYou: B"`，Swift 天真实现会得到 `"A\nB"`。
>
> **⚠️ 易错点 3.4**：`add_msg` 的 `replace` **不校验位置**——如果正文里在行首前缀之前就出现了 `"{name}:"`，会被误删。这是 ST 既有行为，复刻时保持一致（不要"修正"）。
>
> **⚠️ 易错点 3.5**：`botName` 是**跨行可变状态**（`openai.js:737` 初始化，`:767` 在群聊里被改写）。非群聊时 `groupBotNames` 为空 ⇒ 永不改写。
>
> **⚠️ 易错点 3.6**：`getGroupNames()` 在**函数调用时**求值（`openai.js:730`），不是模块加载时。Swift 里 `groupBotNames` 必须作为参数传入，不要在 `parseExampleIntoIndividual` 里读全局状态。

### 3.5 易错点汇总（§3）

| # | 易错点 | 影响 |
|---|---|---|
| 1 | 用 `replacingOccurrences` 代替「只替换第一处」 | 正文里重复出现的前缀被全删 |
| 2 | 忘记跳过块首行 | `{Example Dialogue:}` 进入 prompt |
| 3 | 用 `"{{user}}"` 当 `userName` | 切换检测永远失败 ⇒ 整个块变成一条消息 |
| 4 | `role` 用 `.user`/`.assistant` | 与 ST 不一致（ST 恒 `.system` + `name` 区分） |
| 5 | `name` 用真实角色名 | 与 ST 不一致 |
| 6 | `<START>` 切分用大小写敏感正则 | `<start>` 不被识别 |
| 7 | 忘了「首行是 `<start>` 时补 `<START>\n`」的大小写敏感判定 | 少数卡片解析结果多一行 |
| 8 | `parseMesExamples` 的空值判断用 `hasPrefix("<START>")` | `"<START>x"` 被误判为空 |

---

## 4. 宏替换引擎 `[P0]`

### 4.1 实现路径选择

**来源**：`02#3.1`。

| 路径 | 入口 | 是否默认 | 本文态度 |
|---|---|---|---|
| **Legacy（默认）** | `substituteParamsLegacy` → `evaluateMacros` | ✅ `power_user.experimental_macro_engine === false` | **v1 只实现这个** |
| 新引擎 | `substituteParams` → `MacroEnvBuilder` + `MacroEngine.evaluate` | ❌ 实验开关 | `[P2]` 延后 |

> **结论**：Swift v1 以 Legacy 为准。理由：它是默认路径，也是既有角色卡/世界书作者实际依赖的行为。

### 4.2 `MacroContext`（= `env`）`[P0]`

**来源**：`02#3.2` A 段、`02#3.3.1`（`script.js:2831-2961`）。

```swift
/// 宏求值上下文。所有数据由外部注入——引擎本身不读全局状态。
public struct MacroContext {

    // ---- 名字 ----
    public var user: String                  // name1
    public var char: String                  // name2
    public var group: String                 // 群聊成员名（含静音），非群聊 = char
    public var groupNotMuted: String
    public var notChar: String               // 除当前说话者外的成员 + 用户

    // ---- 卡字段（★ 传入前必须已经 baseChatReplace 过）----
    public var description: String
    public var personality: String
    public var scenario: String
    public var persona: String
    public var charDepthPrompt: String
    public var creatorNotes: String
    public var charVersion: String
    public var mesExamplesRaw: String

    /// 函数型宏：每次替换时重新求值（`{{mesExamples}}`）
    public var mesExamples: () -> String

    // ---- 受 replaceCharacterCard 开关控制的字段（★ 见易错点 4.1）----
    public var charPrompt: String           // 卡 system_prompt，仅 preferCharacterPrompt
    public var charJailbreak: String        // 卡 post_history_instructions，仅 preferCharacterJailbreak

    // ---- 运行时 ----
    public var model: String
    public var isMobile: String = "true"     // iOS 恒为 "true"
    public var lastGenerationType: String = "normal"
    public var input: String = ""            // 输入框当前文本

    // ---- 聊天状态（供 postEnv 批次用）----
    public var chat: [ChatMessageSnapshot] = []
    public var maxPromptTokens: Int = 0
    public var maxContextTokens: Int = 0
    public var maxResponseTokens: Int = 0
    public var firstIncludedMessageID: Int? = nil

    // ---- 变量作用域（§4.6）----
    public var localVariables: [String: String] = [:]      // chat_metadata.variables
    public var globalVariables: [String: String] = [:]     // extension_settings.variables.global

    // ---- outlet 注入（§2.5）----
    public var outlets: [String: String] = [:]

    // ---- {{original}} 的一次性语义 ----
    public var original: String? = nil
    internal var originalConsumed = false

    // ---- 随机源（可注入以便测试）----
    public var rng: RandomSource = SystemRandomSource()
}

/// 让测试可确定化
public protocol RandomSource { func nextUnit() -> Double }         // [0, 1)
public struct SystemRandomSource: RandomSource {
    public func nextUnit() -> Double { Double.random(in: 0..<1) }
}
```

**`env` 的注册顺序（★ 递归只来自顺序，见 4.3）**

`script.js:2926-2955` 的注册顺序（**必须逐字复刻**）：

```
charPrompt, charInstruction/charJailbreak, description, personality, scenario, persona,
mesExamples(function), mesExamplesRaw, charVersion, charDepthPrompt, creatorNotes,
user, char, group, groupNotMuted, notChar, model
```

> **⚠️ 关键**：`{{user}}` / `{{char}}` **注册在最后**（`script.js:2949-2950` 有明确注释
> "Must be substituted last so that they're replaced inside {{description}}"）。
> 因为 `{{description}}` 展开出的文本里若含 `{{char}}`，会在后续的 env 迭代里被替换 ⇒ **一级递归**。
> Swift 的 `MacroEngine` 必须用**有序数组**表达 env，不能用 `Dictionary`（无序）。

> **⚠️ 易错点 4.1**：`{{charPrompt}}` / `{{charInstruction}}` / `{{charJailbreak}}` 在
> `_replaceCharacterCard === false` 时**不注入 env**（`script.js:2924`）。
> `baseChatReplace()`（用于所有卡字段）正是 `replaceCharacterCard: false`。
> Swift 的 `MacroEngine.substitute(_:options:)` 需要 `replaceCharacterCard: Bool` 参数，
> 为 false 时不注册这三个宏（**不是**注册成空串——注册成空串会把字面 `{{charPrompt}}` 替换掉，
> 而 ST 的行为是**保留原文**）。

### 4.3 替换流程 `[P0]`

**来源**：`02#3.2` + `macros.js:610-714`（**已逐行核对**）。

```swift
public final class MacroEngine {

    public var context: MacroContext

    /// 来源：macros.js:610-714
    /// ★ 单趟线性扫描：按 macros 数组顺序逐条做一次全局替换，**不递归**。
    public func substitute(_ content: String,
                           replaceCharacterCard: Bool = true,
                           postProcess: ((String) -> String)? = nil) -> String {
        guard !content.isEmpty else { return "" }                  // :611-613
        var content = content
        let rawContent = content                                   // :616（pick 的种子用）

        // ---- A. 组装宏列表（顺序即优先级）----
        var macros: [MacroRule] = []
        macros += preEnvRules(replaceCharacterCard: replaceCharacterCard)   // :622-636
        macros += orderedEnvRules(replaceCharacterCard: replaceCharacterCard) // :681-692
        macros += postEnvRules(rawContent: rawContent)             // :642-673

        // ---- B. 逐条替换 ----
        for rule in macros {
            if content.isEmpty { break }                            // :698-700 ★ break 不是 continue
            // ★ 短路：非 <...> 形式的宏，若内容里没有 "{{" 就**终止整个循环**
            if !rule.isAngleBracketForm && !content.contains("{{") { break }   // :703-705
            content = rule.apply(to: content, rng: context.rng, postProcess: postProcess) // :708
        }
        return content
    }
}
```

**两条「短路」语义，必须精确复刻**

1. `if (!content) break;` —— 内容一旦被清空（例如 `{{trim}}` 或 `{{// 注释}}` 把整串吃掉），**后续所有宏全部跳过**。
2. `if (!macro.regex.source.startsWith('<') && !content.includes('{{')) break;` —— 当前宏**不是** `<USER>`/`<BOT>`/… 这种尖括号形式，**且**内容里已不含 `{{` ⇒ **终止整个循环**（不是 `continue`）。

> **为什么 `break` 是对的**：剩下的宏都是 `{{...}}` 形式，内容里没有 `{{` 就不可能匹配。但对 `<...>` 形式的宏不成立（`<USER>` 没有 `{{`），所以第一条宏之后这个短路会立即触发——见易错点 4.2。

**`MacroRule` 的实现要点**

```swift
public struct MacroRule {
    public let pattern: NSRegularExpression
    public let isAngleBracketForm: Bool
    public let replacement: (NSTextCheckingResult, String) -> String   // (match, currentContent) -> 替换文本

    /// ★ 不能用 stringByReplacingMatches(withTemplate:)——替换文本可能含 "$"。
    /// 必须自己遍历匹配、从后往前拼接。
    func apply(to input: String, rng: RandomSource,
               postProcess: ((String) -> String)?) -> String {
        let ns = input as NSString
        let matches = pattern.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }

        var result = input
        for m in matches.reversed() {
            guard let r = Range(m.range, in: result) else { continue }
            let raw = replacement(m, input)
            let value = postProcess?(raw) ?? raw
            result.replaceSubrange(r, with: value)
        }
        return result
    }
}
```

> **⚠️ 易错点 4.2（Swift 特有）**：**不要**用 `NSRegularExpression.stringByReplacingMatches(in:range:withTemplate:)`。
> 原因有两个：① 替换文本里的 `$1`、`\` 会被当成模板元字符；② `{{random:$1,x}}` 这类内容会炸。
> 必须走「枚举 match → 反向 splice」的手工路径。反向遍历保证前面的 range 不被破坏。

> **⚠️ 易错点 4.3（Swift 特有）**：**正则里的 `{` `}` 必须转义**。
> JS 里 `/{{trim}}/` 能跑，但 ICU（Swift 的 `NSRegularExpression`）对 `{{trim}}` 的解析不保证与 JS 一致
> （`{` 可能被当作量词起始）。**统一写成 `\{\{trim\}\}`**。
> 建议封装：`func macroPattern(_ name: String) -> String { "\\{\\{\(NSRegularExpression.escapedPattern(for: name))\\}\\}" }`

> **⚠️ 易错点 4.4**：`{{` 的检测。JS 的 `content.includes('{{')` 是**子串包含**。
> Swift 的 `content.contains("{{")` 等价。但注意：不要在短路检查里用正则（性能）。

> **⚠️ 易错点 4.5**：`postProcessFn` 对**每一次**宏替换的返回值做后处理（`macros.js:708`），默认恒等。
> 常见用途是 `collapseNewlines`。Swift 用可选闭包参数实现。

> **⚠️ 易错点 4.6（Swift 特有）**：`offset` 参数。JS 的 `String.replace(regex, fn)` 会把
> match 在**当前字符串**里的偏移传给回调（`{{pick}}` 用它做种子）。
> Swift 的手工 splice 里必须传 `m.range.location`（相对**本次替换前**的字符串），
> 而不是相对原始 `rawContent` 的偏移。

### 4.4 最小宏集合 `[P0]` 与替换顺序

**来源**：`02#3.2`（preEnv / env / postEnv 三批）+ `02#3.4`（最小集合）。

#### 4.4.1 `preEnv` 批次（按数组顺序执行）

| # | 正则（JS） | Swift 正则 | 展开 |
|---|---|---|---|
| 1 | `/<USER>/gi` | `(?i)<USER>` | `env.user` |
| 2 | `/<BOT>/gi` | `(?i)<BOT>` | `env.char` |
| 3 | `/<CHAR>/gi` | `(?i)<CHAR>` | `env.char` |
| 4 | `/<CHARIFNOTGROUP>/gi` | `(?i)<CHARIFNOTGROUP>` | `env.group` |
| 5 | `/<GROUP>/gi` | `(?i)<GROUP>` | `env.group` |
| 6 | `getDiceRollMacro()` | `(?i)\{\{roll[ :]([^}]+)\}\}` | 见 §4.5.3 |
| 7 | `...instructMacros` | — | `[P2]` Chat Completion 基本用不到 |
| 8 | `...variableMacros` | 见 §4.6 | 变量宏 |
| 9 | `/{{newline}}/gi` | `(?i)\{\{newline\}\}` | `"\n"` |
| 10 | `/(?:\r?\n)*{{trim}}(?:\r?\n)*/gi` | `(?i)(?:\r?\n)*\{\{trim\}\}(?:\r?\n)*` | `""` ← **连同前后换行一起吃掉** |
| 11 | `/{{noop}}/gi` | `(?i)\{\{noop\}\}` | `""` |
| 12 | `/{{input}}/gi` | `(?i)\{\{input\}\}` | 输入框当前文本 |

> **注意 `{{roll}}` 在 preEnv 批次**（`macros.js:629`），而 `{{random}}`/`{{pick}}` 在 **postEnv** 批次
> （`macros.js:671-672`）。顺序不同 ⇒ 如果 `{{random:a,{{roll:1d2}}}}` 这种嵌套，行为由顺序决定。

#### 4.4.2 `env` 批次（每个 env key 一条规则，按 env 注册顺序）

```swift
// 每个 key 一条：new RegExp(`{{${escapeRegex(varName)}}}`, 'gi')
// 替换值 = MacrosParser.sanitizeMacroValue(typeof param === 'function' ? param(nonce) : param)
```

- 全部大小写不敏感。
- 函数型宏在**同一次** `substitute` 调用里共享同一个 `nonce`（`macros.js:677` 的 `uuidv4()`）。
  `[P1]`：v1 可以直接每次重算（`{{mesExamples}}` 无 nonce 依赖）。
- `sanitizeMacroValue`：`[P2]`（主要是 trim / null 归一）。

#### 4.4.3 `postEnv` 批次（最小集合，按数组顺序）

**`02#3.4` 明确列出的「v1 必须实现」集合**，逐条给正则与语义：

| 宏 | Swift 正则 | 语义 | 优先级 |
|---|---|---|---|
| `{{maxPrompt}}`/`{{maxPromptTokens}}` | `(?i)\{\{maxPrompt(Tokens)?\}\}` | `maxContext - maxResponse` | `[P1]` |
| `{{maxContext}}`/`{{maxContextTokens}}` | `(?i)\{\{maxContext(Tokens)?\}\}` | `maxContext` | `[P1]` |
| `{{maxResponse}}`/`{{maxResponseTokens}}` | `(?i)\{\{maxResponse(Tokens)?\}\}` | `maxResponse` | `[P1]` |
| `{{lastMessage}}` | `(?i)\{\{lastMessage\}\}` | 最后一条（排除未完成 swipe） | `[P1]` |
| `{{lastUserMessage}}` | `(?i)\{\{lastUserMessage\}\}` | 最后一条 `isUser && !isSystem` | `[P1]` |
| `{{lastCharMessage}}` | `(?i)\{\{lastCharMessage\}\}` | 最后一条 `!isUser && !isSystem` | `[P1]` |
| `{{lastMessageId}}` | `(?i)\{\{lastMessageId\}\}` | 其索引（`?? ''`） | `[P2]` |
| `{{firstIncludedMessageId}}` | 同形 | `chat_metadata.lastInContextMessageId` | `[P2]` |
| `{{firstDisplayedMessageId}}` | 同形 | DOM 概念，iOS 用「当前视口首条」或 `nil` | `[P2]` |
| `{{lastSwipeId}}`/`{{currentSwipeId}}` | 同形 | 1-based | `[P2]` |
| `{{allChatRange}}` | 同形 | `chat.isEmpty ? "" : "0-\(chat.count-1)"` | `[P2]` |
| `{{reverse:x}}` | `(?i)\{\{reverse:(.+?)\}\}` | 按 **Unicode code point** 反转 | `[P1]` |
| `{{// 注释}}` | `(?i)\{\{\/\/([\s\S]*?)\}\}` | `""`，**跨行、非贪婪** | `[P0]` |
| `{{time}}` | `(?i)\{\{time\}\}` | `moment().format('LT')` ⇒ 本地化短时间 | `[P1]` |
| `{{date}}` | `(?i)\{\{date\}\}` | `moment().format('LL')` ⇒ 本地化长日期 | `[P1]` |
| `{{weekday}}` | `(?i)\{\{weekday\}\}` | `dddd` ⇒ `Monday` | `[P1]` |
| `{{isotime}}` | `(?i)\{\{isotime\}\}` | `HH:mm`（24h，补零） | `[P1]` |
| `{{isodate}}` | `(?i)\{\{isodate\}\}` | `YYYY-MM-DD` | `[P1]` |
| `{{datetimeformat <fmt>}}` | `(?i)\{\{datetimeformat +([^}]*)\}\}` | `moment().format(fmt)`，**空格**分隔 | `[P2]` |
| `{{idle_duration}}` | `(?i)\{\{idle_duration\}\}` | 人类化时长，默认 `"just now"` | `[P2]` |
| `{{time_UTC±N}}` | `(?i)\{\{time_UTC([-+]\d+)\}\}` | `utcOffset(N).format('LT')` | `[P2]` |
| `{{outlet::key}}` | `(?i)\{\{outlet::(.+?)\}\}` | `outlets[key.trim()] ?? ""` | `[P1]` |
| `{{timeDiff::a::b}}` | `(?i)\{\{timeDiff::(.*?)::(.*?)\}\}` | `duration(a.diff(b)).humanize(true)` | `[P2]` |
| `{{banned "w"}}` | 见 `macros.js:447-452` | `""` + 加入 ban list。**chat 路径无 ban list，直接 `""`** | `[P2]` |
| `{{random:a,b}}` | `(?i)\{\{random\s?::?([^}]+)\}\}` | 见 §4.5.1 | `[P0]` |
| `{{pick:a,b}}` | `(?i)\{\{pick\s?::?([^}]+)\}\}` | 见 §4.5.2 | `[P0]` |

**时间/日期格式的 Swift 映射（`02#7` 陷阱 8/9）**

```swift
// moment().format('LT')  ⇒ 当前 locale 的短时间格式
let f1 = DateFormatter(); f1.locale = .current; f1.timeStyle = .short;  f1.dateStyle = .none
// moment().format('LL')  ⇒ 当前 locale 的长日期格式
let f2 = DateFormatter(); f2.locale = .current; f2.timeStyle = .none;   f2.dateStyle = .long
// moment().format('dddd') ⇒ 星期全名
let f3 = DateFormatter(); f3.locale = .current; f3.dateFormat = "EEEE"
// moment().format('HH:mm') / ('YYYY-MM-DD') ⇒ 固定格式，**必须用 en_US_POSIX locale**
let f4 = DateFormatter(); f4.locale = Locale(identifier: "en_US_POSIX"); f4.dateFormat = "HH:mm"
let f5 = DateFormatter(); f5.locale = Locale(identifier: "en_US_POSIX"); f5.dateFormat = "yyyy-MM-dd"
```

> **⚠️ 易错点 4.7**：`HH:mm` / `YYYY-MM-DD` 是 **fixed format**，必须 `Locale(identifier: "en_US_POSIX")`。
> 用 `.current` 在泰历/和历 locale 下会输出 `2569-09-14` 这类错误结果。
>
> **⚠️ 易错点 4.8**：`moment().format('YYYY-MM-DD')` 的 `YYYY` 是 **ISO 周历年份**（week-year），
> 不是日历年！在 1 月 1 日附近与 `yyyy` 会差一年。若要精确复刻，用 `"YYYY-MM-dd"` 配合
> `Calendar(identifier: .iso8601)`，或接受 `yyyy` 的细微差异（推荐后者并写明）。
>
> **⚠️ 易错点 4.9**：`{{//}}` 用的是 `[\s\S]*?`（跨行非贪婪）+ `gm`。
> Swift 的 `.` 默认不匹配换行，但 `[\s\S]` 显式覆盖了这一点，所以**不需要** `.dotMatchesLineSeparators`。
>
> **⚠️ 易错点 4.10**：`{{trim}}` 的正则 `(?:\r?\n)*{{trim}}(?:\r?\n)*` 会**吃掉前后所有换行**。
> 多个连续 `{{trim}}` 时，第一个就把后面的换行吃光了。

### 4.5 `{{random:}}` / `{{pick:}}` / `{{roll:}}` 精确语义 `[P0]`

**来源**：`macros.js:491-509`（random）、`:516-545`（pick）、`:550-572`（roll）——**已逐行核对**。

#### 4.5.1 `{{random:}}`

```swift
/// 来源：macros.js:491-509
/// 正则：/{{random\s?::?([^}]+)}}/gi
///   ⇒ 接受 {{random:a,b}} / {{random::a,b}} / {{random :a,b}} / {{random::a::b}}
func evaluateRandom(listString: String, rng: RandomSource) -> String {
    // (1) 分隔符：含 "::" ⇒ 用 "::" 分且**不 trim**；否则用 "," 分且**每项 trim**
    let list: [String]
    if listString.contains("::") {
        list = listString.components(separatedBy: "::")            // ★ 不 trim
    } else {
        // `\,` 转义为字面逗号：先换成占位符，分完再换回来
        let placeholder = "##\u{FFFD}COMMA\u{FFFD}##"
        list = listString
            .replacingOccurrences(of: "\\,", with: placeholder)
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: placeholder, with: ",") }
    }
    guard !list.isEmpty else { return "" }                          // :500-502
    // (2) 熵源：seedrandom('added entropy.', { entropy: true }) ⇒ **每次调用都不同**
    let index = Int(floor(rng.nextUnit() * Double(list.count)))     // :504
    return list[min(index, list.count - 1)]
}
```

**语义要点**

| 项 | 说明 |
|---|---|
| 分隔符判定 | `listString.contains("::")` —— **只要含 `::` 就整串按 `::` 分**，此时 `,` 也是普通字符 |
| `::` 模式 | **不 trim**（`{{random::a, b}}` → `["a", " b"]`，前导空格保留） |
| `,` 模式 | 每项 `trim()`；`\,` 转义成字面逗号（**转义只在 `,` 模式下生效**） |
| 熵源 | `seedrandom('added entropy.', {entropy:true})` ⇒ **每次调用重新播种** ⇒ 真正的随机 |
| 空列表 | `list.length === 0` 才返回 `""`。注意 `"".split(",")` 得到 `[""]`（长度 1），所以 `{{random:}}` 其实**不匹配**正则（`[^}]+` 要求至少 1 字符） |

#### 4.5.2 `{{pick:}}`（确定性）

```swift
/// 来源：macros.js:516-545
/// 与 random 唯一的差别：**种子确定**且**同一个宏在同一个 content 里每次都得到同一结果**
func evaluatePick(listString: String,
                  offset: Int,                 // ★ match 在当前字符串里的偏移
                  chatIdHash: Int,             // chat_metadata.chat_id_hash
                  rawContentHash: Int,         // getStringHash(本次 substitute 的原始 content)
                  rngFactory: (Int) -> RandomSource) -> String {

    let list = splitList(listString)               // 与 random 完全相同的分列逻辑
    guard !list.isEmpty else { return "" }

    // 种子 = hash("\(chatIdHash)-\(rawContentHash)-\(offset)")
    let seed = getStringHash("\(chatIdHash)-\(rawContentHash)-\(offset)")
    let rng = rngFactory(seed)                     // seedrandom(finalSeed)
    let index = Int(floor(rng.nextUnit() * Double(list.count)))
    return list[min(index, list.count - 1)]
}
```

**语义要点**

| 项 | 说明 |
|---|---|
| `chatIdHash` | `chat_metadata.chat_id_hash`，**首次计算后要持久化**：`getStringHash(chat_metadata.main_chat ?? getCurrentChatId())`（`macros.js:315-328`） |
| `rawContentHash` | `getStringHash(rawContent)`，其中 `rawContent` = **本次 `substitute` 的输入原文**（`macros.js:616`），不是当前中间态 |
| `offset` | match 在整个**当前**字符串里的偏移（`macros.js:523` 的第 3 个回调参数） |
| 确定性含义 | 同一条消息、同一个位置、同一个 chat ⇒ 每次都拿到同一个选项（刷新/重生成不变） |

**`getStringHash` 的 Swift 逐字移植（`utils.js:522-539`）**

```swift
/// cyrb53 变体。★ 必须用 UTF-16 code unit（对齐 JS charCodeAt）
/// ★ 必须用 32-bit 环绕乘法（对齐 Math.imul）
public func getStringHash(_ str: String, seed: UInt32 = 0) -> UInt64 {
    var h1: UInt32 = 0xdeadbeef ^ seed
    var h2: UInt32 = 0x41c6ce57 ^ seed
    for ch in str.utf16 {
        let c = UInt32(ch)
        h1 = (h1 ^ c) &* 2654435761
        h2 = (h2 ^ c) &* 1597334677
    }
    h1 = ((h1 ^ (h1 >> 16)) &* 2246822507) ^ ((h2 ^ (h2 >> 13)) &* 3266489909)
    h2 = ((h2 ^ (h2 >> 16)) &* 2246822507) ^ ((h1 ^ (h1 >> 13)) &* 3266489909)
    return 4294967296 * UInt64(2097151 & h2) + UInt64(h1)
}
```

> **⚠️ 易错点 4.11**：`Math.imul` 是 **32-bit 有符号**乘法并返回有符号结果，但后续都在做位运算，
> 用 `UInt32` + `&*`（溢出环绕）等价。**不要**用 `Int` 或 `Int64`（不会环绕，结果完全不同）。
>
> **⚠️ 易错点 4.12**：`str.charCodeAt(i)` 是 **UTF-16 code unit**。Swift 的 `for ch in str` 是
> `Character`（grapheme cluster），emoji / 组合字符会得到一个 Character 而不是两个 code unit。
> **必须 `str.utf16`**。

**`seedrandom` 的移植策略**

| 方案 | 说明 | 建议 |
|---|---|---|
| A. `SplitMix64` 播种 | 用 `hash` 喂 `SplitMix64` / `xorshift128+`，取 `nextUnit()` | ✅ **v1 采用** |
| B. 逐字移植 ARC4 | ST 用 David Bau 的 `seedrandom`（ARC4 + 256 轮 key 混合），约 60 行 | `[P2]` 仅当需要与桌面版结果一致时 |

> **明确写在文档里**：方案 A 下 `{{pick}}` 在 iOS 端与桌面 ST 端**可能选出不同选项**。
> 这是**可接受**的（`pick` 的契约是「同一端内确定」，不是「跨端一致」）。
> 若产品要求跨端一致，再上方案 B。

#### 4.5.3 `{{roll:}}`

```swift
/// 来源：macros.js:550-572 + dice 库（droll）
/// 正则：/{{roll[ : ]([^}]+)}}/gi  ⇒ {{roll:1d20}} 或 {{roll 1d20}}
func evaluateRoll(_ matchValue: String, rng: RandomSource) -> String {
    var formula = matchValue.trimmingCharacters(in: .whitespacesAndNewlines)
    // (1) 纯数字 N ⇒ 转成 "1dN"
    if formula.allSatisfy(\.isNumber) { formula = "1d\(formula)" }
    // (2) 校验公式；非法 ⇒ 返回 ""（★ 不是保留原文）
    guard isValidDiceFormula(formula) else { return "" }
    // (3) 掷骰；失败 ⇒ ""；成功 ⇒ String(result.total)
    guard let total = rollDice(formula, rng: rng) else { return "" }
    return String(total)
}
```

**必须支持的骰子语法（`[P1]` 子集即可）**

| 语法 | 示例 | 结果 |
|---|---|---|
| `NdM` | `1d20` | 1...20 的整数 |
| `NdM` | `2d6` | 2...12 |
| 纯数字 | `{{roll:20}}` | 等价 `1d20` |
| 修饰符 `+N`/`-N` | `1d20+3` | 骰值 + 3 |
| `NdMkhK`/`klK` 等 | `4d6kh3` | `[P2]` 完整 droll 语法 |
| 非法 | `{{roll:abc}}` | `""` |

> **⚠️ 易错点 4.13**：`{{roll}}` 的正则分隔符是 `[ : ]`（**冒号或空格**），且**只允许一个**分隔字符。
> `{{roll :1d20}}` 不匹配。而 `{{random}}` / `{{pick}}` 用的是 `\s?::?`（可选空白 + 可选第二个冒号）。
> 三者的正则**不统一**，不要图省事合并。
>
> **⚠️ 易错点 4.14**：非法公式返回 `""`（**不是保留原宏**）。所以 `{{roll:abc}}` 会变成空串。
> 但 `{{roll}}`（无参数）不匹配正则 ⇒ 原样保留。

### 4.6 变量宏 `[P1]`

**来源**：`02#3.3.5` + `variables.js:238-261`。

| 宏 | 语义 | 展开为 |
|---|---|---|
| `{{getvar::name}}` | 读局部变量 | 值（不存在 ⇒ `""`） |
| `{{setvar::name::value}}` | 写局部变量 | `""` |
| `{{addvar::name::value}}` | 数值追加 / 字符串拼接 | `""` |
| `{{incvar::name}}` / `{{decvar::name}}` | 自增/自减 | **新值** |
| `{{getglobalvar::name}}` 等 | 同上，作用域 `extension_settings.variables.global` | 同上 |

```swift
/// 正则风格：/{{setvar::([^:]+)::([^}]*)}}/gi
/// ★ 变量名不能含 ":"，值不能含 "}"
func registerVariableMacros(into engine: MacroEngine) {
    engine.registerPreEnv(pattern: "(?i)\\{\\{getvar::([^:}]+)\\}\\}") { m, c in
        c.localVariables[m.group(1)] ?? ""
    }
    engine.registerPreEnv(pattern: "(?i)\\{\\{setvar::([^:}]+)::([^}]*)\\}\\}") { m, c in
        c.localVariables[m.group(1)] = m.group(2); return ""
    }
    // addvar / incvar / decvar / global 变体同理
}
```

**变量宏在 `preEnv` 批次**（`macros.js:631`），所以它们在 `{{user}}`/`{{char}}` **之前**执行。
这意味着 `{{setvar::x::{{char}}}}` 里的 `{{char}}` 此时**还没被替换**。

> **⚠️ 易错点 4.15**：变量作用域要落在 `ChatSession`（每条 chat 一份 `localVariables`），
> 全局变量落在 App 设置。**不要**做成进程内单例——多聊天窗口会串。
>
> **⚠️ 易错点 4.16**：`incvar` 返回**新值**，`setvar`/`addvar` 返回**空串**。
> `incvar` 用在文本里（`你现在的分数是 {{incvar::score}}`）会输出数字。
>
> **⚠️ 易错点 4.17**：宏替换发生在 prompt 组装的**多个阶段**（§4.7），
> 所以 `{{setvar}}` 可能在一次生成里被执行**多次**（例如 AN 的值在 `getExtensionPrompt` 里
> 又被 `substituteParams` 一遍）。ST 就是这样，不要试图"只执行一次"。

### 4.7 宏替换的发生时机（世界书相关）`[P0 理解 / P1 实现]`

**来源**：`02#3.6`（**已修正一处勘误**）。

| 阶段 | 是否已做宏替换 | 源码 |
|---|---|---|
| WI 条目的 `key` / `keysecondary`（**扫描用**） | ✅ 每个 key 在匹配前 `substituteParams(key).trim()` | `world-info.js:4915`、`:4947` |
| WI 条目 `content`（**激活并计入预算时**） | ✅ **就地写回** `entry.content = substituteParams(entry.content)` | `world-info.js:5058` |
| WI `content` 正则后处理 | `getRegexedString(content, WORLD_INFO, {depth, …})` | `world-info.js:5205` |
| 扩展注入（AN / depth / persona） | ✅ `getExtensionPrompt` 里整串**再跑一次** `substituteParams` | `script.js:3326` |
| prompt（main/nsfw/jailbreak/…） | ✅ `PromptManager.preparePrompt` → `substituteParams` | `PromptManager.js:1277-1290` |
| 卡字段 | ✅ `baseChatReplace` = `substituteParams(…, replaceCharacterCard: false)` + `collapseNewlines` + 去 `\r` | `script.js:3341-3352` |
| **聊天历史消息** | ✅ **会做宏替换**（见 §2.6 勘误） | `openai.js:955` → `PromptManager.js:1277-1290` |
| `dialogueExamples` 内容 | ❌ 已是替换后的卡字段（`newExampleChatPrompt` 除外） | `openai.js:1113-1121` |

> **⚠️ 易错点 4.18**：WI 的 `entry.content = substituteParams(entry.content)` 是**就地写回**（`world-info.js:5058`）。
> 因为 `getSortedEntries` 返回 `structuredClone`，每轮扫描是全新副本，所以不会跨轮污染。
> **Swift 必须保证 `WIEntry` 是值类型（struct）**，否则第二级递归会拿到已替换的内容（如果内容里有
> `{{getvar::}}` 之类会产生副作用）。
>
> **⚠️ 易错点 4.19**：WI 的 **key 在每次匹配前**都跑一次 `substituteParams`（**不在**激活时缓存）。
> 所以 `key` 里可以写 `{{user}}`，但它会在**每一轮扫描的每一个 key** 上重新求值——
> 如果 key 里有 `{{incvar::x}}`，行为会很诡异。复刻即可，不要优化。

### 4.8 易错点汇总（§4）

| # | 易错点 | 检测方式 |
|---|---|---|
| 1 | env 用 `Dictionary`（无序） | `{{description}}` 里的 `{{char}}` 不被替换 |
| 2 | 用 `withTemplate:` 做替换 | 替换文本含 `$` 时结果错乱 |
| 3 | 正则里 `{` `}` 未转义 | ICU 抛异常或行为不一致 |
| 4 | `replaceCharacterCard: false` 时把三个宏注册成空串 | 卡字段里的 `{{charPrompt}}` 被吃掉 |
| 5 | `getStringHash` 用 `Int` 而非 `UInt32` + `&*` | `pick` 结果每端不同（可接受），但同端内也不稳定 |
| 6 | `getStringHash` 用 `Character` 而非 `utf16` | emoji 参与 hash 时结果不同 |
| 7 | `{{trim}}` 忘了吃掉前后换行 | 输出多空行 |
| 8 | `{{//}}` 用了 `.` 而非 `[\s\S]` | 跨行注释不生效 |
| 9 | `{{random}}` 的 `::` 模式误加 trim | `{{random:: a,b}}` 结果差一个空格 |
| 10 | 短路条件写成 `continue` 而非 `break` | 行为差异极小但会在边界 case 暴露 |
| 11 | `{{isotime}}`/`{{isodate}}` 用 `.current` locale | 非公历 locale 下日期错 |
| 12 | 宏引擎做成全局单例 | 多聊天串变量 |

---
## 5. 世界书触发引擎 `[P0 子集 / P1 其余]`

### 5.1 数据模型

**来源**：`02#4.1` + `world-info.js:4082-4125`（条目默认值）。

```swift
public struct WIEntry: Codable, Equatable, Identifiable {

    // ---- 身份 ----
    public var uid: Int
    /// 来源 book 的标识。运行时拼成 "\(world).\(uid)" 作为激活表 key（world-info.js:5075）
    public var world: String = ""

    // ---- 内容 ----
    public var key: [String] = []
    public var keysecondary: [String] = []
    public var comment: String = ""             // 备注，不注入
    public var content: String = ""             // 注入正文

    // ---- 激活控制 ----
    public var constant: Bool = false           // 蓝灯，恒激活
    public var disable: Bool = false
    public var selective: Bool = true           // 是否检查 keysecondary（现版本恒 true）
    public var selectiveLogic: WISelectiveLogic = .andAny
    public var order: Int = 100                 // ★ insertion_order，越大越靠前
    public var position: WIPosition = .before
    public var role: WIRole = .system           // atDepth 时的消息 role
    public var depth: Int = 4                   // DEFAULT_DEPTH，仅 atDepth 生效
    public var outletName: String = ""

    // ---- 预算 ----
    public var ignoreBudget: Bool = false

    // ---- 递归 ----
    public var excludeRecursion: Bool = false
    public var preventRecursion: Bool = false
    /// 0 = 不延迟；true ⇒ 级别 1；数值 N ⇒ 级别 N
    public var delayUntilRecursionLevel: Int = 0

    // ---- 扫描范围扩展 ----
    public var scanDepth: Int? = nil            // nil ⇒ 用全局 world_info_depth
    public var matchPersonaDescription: Bool = false
    public var matchCharacterDescription: Bool = false
    public var matchCharacterPersonality: Bool = false
    public var matchCharacterDepthPrompt: Bool = false
    public var matchScenario: Bool = false
    public var matchCreatorNotes: Bool = false

    // ---- 匹配选项覆写（nil ⇒ 用全局）----
    public var caseSensitive: Bool? = nil
    public var matchWholeWords: Bool? = nil
    public var useGroupScoring: Bool? = nil

    // ---- 概率 ----
    public var probability: Int = 100
    public var useProbability: Bool = true

    // ---- 互斥组 ----
    public var group: String = ""               // 逗号分隔，一个条目可属多组
    public var groupOverride: Bool = false
    public var groupWeight: Int = 100           // DEFAULT_WEIGHT

    // ---- 定时效果 [P2] ----
    public var sticky: Int? = nil
    public var cooldown: Int? = nil
    public var delay: Int? = nil

    // ---- 生成类型白名单 ----
    public var triggers: [String] = []

    // ---- 角色/标签过滤 [P1] ----
    public var characterFilter: CharacterFilter? = nil
    public struct CharacterFilter: Codable, Equatable {
        public var names: [String] = []
        public var tags: [String] = []
        public var isExclude: Bool = false
    }

    // ---- 运行时（不持久化）----
    /// getSortedEntries 计算：getStringHash(JSON)（world-info.js:4632）
    public var hash: UInt64 = 0
    /// parseDecorators 的结果：目前只有 "@@activate" / "@@dont_activate"
    public var decorators: [String] = []
    /// 在 sortedEntries 里的下标，用于激活排序（world-info.js:4996-5002）
    public var sortIndex: Int = -1

    public var id: String { "\(world).\(uid)" }
}

public enum WorldInfoPosition: Int { /* 见 §2.2 WIPosition */ }
```

> **⚠️ 易错点 5.1**：`delayUntilRecursion` 在 ST 里是**联合类型**（`false` / `true` / 数值）。
> JSON 里可能写 `false`、`true`、`0`、`1`、`2`。Swift 用 `Int` 承载并把 `true` 归一成 `1`、
> `false` 归一成 `0`（`world-info.js:4760-4763` 的 `x === true ? 1 : x`）。
> 建议自定义 `Codable` 同时接受 `Bool` 与 `Int`。
>
> **⚠️ 易错点 5.2**：`position` 的 JSON 值是**数字**（0-7），但 `world_info_position` 枚举里
> `before = 0`。有些旧卡把 `position` 写成字符串。解码时要容错。

### 5.2 全局设置与常量 `[P0]`

**来源**：`02#4.2`（`world-info.js:69-82`）+ `02#4.1`（`world-info.js:33-98`）。

```swift
public struct WISettings {
    /// world_info_depth = 2
    public var depth: Int = 2
    /// world_info_min_activations = 0   [P2]
    public var minActivations: Int = 0
    /// world_info_min_activations_depth_max = 0   [P2]
    public var minActivationsDepthMax: Int = 0
    /// world_info_budget = 25（百分比）
    public var budgetPercent: Int = 25
    /// world_info_budget_cap = 0（0 = 无上限）
    public var budgetCap: Int = 0
    /// world_info_include_names = true
    public var includeNames: Bool = true
    /// world_info_recursive = false   [P1]
    public var recursive: Bool = false
    public var overflowAlert: Bool = false
    /// world_info_case_sensitive = false
    public var caseSensitive: Bool = false
    /// world_info_match_whole_words = false
    public var matchWholeWords: Bool = false
    /// world_info_use_group_scoring = false   [P1]
    public var useGroupScoring: Bool = false
    /// world_info_character_strategy = 1 (character_first)
    public var characterStrategy: WIInsertionStrategy = .characterFirst
    /// world_info_max_recursion_steps = 0（0 = 无限）   [P1]
    public var maxRecursionSteps: Int = 0
}

public enum WIConstants {
    public static let defaultDepth = 4              // world-info.js:96
    public static let defaultWeight = 100           // world-info.js:97
    public static let maxScanDepth = 1000           // world-info.js:98
    /// ★ 词边界哨兵，见 §5.3
    public static let matcher = "\u{01}"
    public static let joiner = "\n\u{01}"
    /// 已知装饰器（world-info.js:100）
    public static let knownDecorators = ["@@activate", "@@dont_activate"]
}
```

**全局扫描数据（`script.js:4625-4634`）**

```swift
public struct GlobalScanData {
    public var personaDescription: String = ""
    public var characterDescription: String = ""
    public var characterPersonality: String = ""
    public var characterDepthPrompt: String = ""
    public var scenario: String = ""
    public var creatorNotes: String = ""
    /// GENERATE_TYPE_TRIGGERS 之外的 type 一律归一为 "normal"
    public var trigger: String = "normal"       // normal / continue / impersonate / …
}
```

### 5.3 扫描范围与 `WorldInfoBuffer` `[P0]`

**来源**：`02#4.3` + `world-info.js:199-474`（**已逐行核对**）。

#### 5.3.1 扫描文本（chatForWI）的构造

```swift
/// 来源：script.js:4624
/// - coreChat = chat.filter { !$0.isSystem }；type == .swipe 时去掉最后一条
/// - ★ reverse 后索引 0 = **最新**消息
public func makeScanBuffer(chat: [ChatMessageSnapshot], includeNames: Bool) -> [String] {
    var core = chat.filter { !$0.isSystem }
    if generationType == .swipe, !core.isEmpty { core.removeLast() }
    return core.reversed().map { includeNames ? "\($0.name): \($0.mes)" : $0.mes }
}
```

#### 5.3.2 `WorldInfoBuffer`

```swift
public final class WorldInfoBuffer {

    private let depthBuffer: [String]         // index 0 = 最新；每条已 trim
    private var recurseBuffer: [String] = []
    private var injectBuffer: [String] = []
    private var skew: Int = 0                 // min activations 用 [P2]
    private let startDepth: Int
    private let globalScanData: GlobalScanData

    public init(messages: [String], globalScanData: GlobalScanData, startDepth: Int = 0,
                injections: [String] = []) {
        self.depthBuffer = Self.initDepthBuffer(messages)     // world-info.js:250-260
        self.globalScanData = globalScanData
        self.startDepth = startDepth
        self.injectBuffer = injections
    }

    /// 来源：world-info.js:250-260
    /// ★ 上限 MAX_SCAN_DEPTH = 1000；每条 trim；空串不写入（保留 nil 洞）
    private static func initDepthBuffer(_ messages: [String]) -> [String] {
        var buf = [String](repeating: "", count: min(messages.count, WIConstants.maxScanDepth))
        for depth in 0..<WIConstants.maxScanDepth {
            if depth < messages.count, !messages[depth].isEmpty {
                buf[depth] = messages[depth].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if depth == messages.count - 1 { break }
        }
        return buf
    }

    /// 当前全局扫描深度 = world_info_depth + skew
    public var depth: Int { settings.depth + skew }

    /// 来源：world-info.js:279-328  ★ 这是整个引擎的正确性核心
    public func text(for entry: WIEntry, state: WIScanState) -> String {
        var depth = entry.scanDepth ?? self.depth                    // :280
        if depth <= startDepth { return "" }                         // :281-283
        if depth < 0 { return "" }                                   // :285-288（报错）
        if depth > WIConstants.maxScanDepth { depth = WIConstants.maxScanDepth }  // :290-293

        // ★ 前缀哨兵：让整词匹配的 (?:^|\W) 能识别拼接边界
        var result = WIConstants.matcher
            + depthBuffer[startDepth..<min(depth, depthBuffer.count)]
                .joined(separator: WIConstants.joiner)               // :297

        // 逐项追加全局扫描数据（顺序固定，不可换）
        func append(_ value: String) { result += WIConstants.joiner + value }
        if entry.matchPersonaDescription,     !globalScanData.personaDescription.isEmpty     { append(globalScanData.personaDescription) }   // :299
        if entry.matchCharacterDescription,   !globalScanData.characterDescription.isEmpty   { append(globalScanData.characterDescription) } // :302
        if entry.matchCharacterPersonality,   !globalScanData.characterPersonality.isEmpty   { append(globalScanData.characterPersonality) } // :305
        if entry.matchCharacterDepthPrompt,   !globalScanData.characterDepthPrompt.isEmpty   { append(globalScanData.characterDepthPrompt) } // :308
        if entry.matchScenario,               !globalScanData.scenario.isEmpty               { append(globalScanData.scenario) }             // :311
        if entry.matchCreatorNotes,           !globalScanData.creatorNotes.isEmpty           { append(globalScanData.creatorNotes) }         // :314

        if !injectBuffer.isEmpty { result += WIConstants.joiner + injectBuffer.joined(separator: WIConstants.joiner) }        // :318-320
        // ★ min activations 时**不含**递归缓冲
        if !recurseBuffer.isEmpty && state != .minActivations {
            result += WIConstants.joiner + recurseBuffer.joined(separator: WIConstants.joiner)                                // :323-325
        }
        return result
    }

    public func addRecurse(_ message: String) { recurseBuffer.append(message) }   // :372-374
    public func hasRecurse() -> Bool { !recurseBuffer.isEmpty }
    public func advanceScan() { skew += 1 }                                      // [P2]
}
```

**`MATCHER = "\x01"` / `JOINER = "\n\x01"` 的作用（`02#4.3`）**

每条消息之间用 `"\n\u{01}"` 拼接、整体以 `"\u{01}"` 开头。这样整词匹配的正则
`(?:^|\W)(key)(?:$|\W)` 能正确识别「第 0 条消息的开头」和「消息之间的边界」为词边界，
**避免跨消息误匹配**（例如上一条结尾 `foo`、下一条开头 `bar`，拼起来 `foobar` 不应命中 `bar`）。

`#injectBuffer` 的来源（`world-info.js:4719-4726` + `script.js:3274`）：
所有 `extensionPrompts[key].scan == true` 的 prompt 的**已宏替换值**。
AN 的 `allowWIScan` 与角色 `depth_prompt` 的 scan 标志决定它们能否被世界书扫描到。

> **⚠️ 易错点 5.3**：`JOINER` 是 `"\n\u{01}"`（换行 + 哨兵），`MATCHER` 是 `"\u{01}"`。
> **不要**写成 `"\u{01}\n"` 或少一个字符——整词匹配会失效。
>
> **⚠️ 易错点 5.4**：`depthBuffer` 只在 `messages[depth]` **truthy** 时写入（`world-info.js:252`）。
> JS 里空字符串是 falsy ⇒ 空洞。Swift 用 `[String]` + 占位空串 + 长度对齐即可，
> 但 `slice(startDepth, depth)` 的**下标语义**必须是「数组下标」而不是「已写入元素个数」。
>
> **⚠️ 易错点 5.5**：`depth` 的计算是 `entry.scanDepth ?? (world_info_depth + skew)`（`:280`）。
> `skew` **只在 min activations 时递增**（`:5127` 附近）。v1 如果只实现 `initial` 状态，
> `skew` 恒为 0。
>
> **⚠️ 易错点 5.6**：扫描文本是**逐条消息 trim 后的字符串直接拼接**，所以 `depth = 2` 只扫**最新 2 条**。
> 这与聊天历史的 `depth`（消息条数）是同一个概念，不要与 `atDepth` 注入的 `depth` 混淆
> （后者也是条数，但方向是「最新往下数第 n 条之前」）。

### 5.4 `getSortedEntries` 排序规则 `[P0]`

**来源**：`02#4.4` + `world-info.js:4590-4644`（**已逐行核对**）。

```swift
/// 来源：world-info.js:4590-4644
/// ★ 扫描顺序 = 本函数的输出顺序。它同时决定「同 order 时的激活优先级」与
///   「预算耗尽时谁先被计入」。
public func getSortedEntries(
    globalLore: [WIEntry],
    characterLore: [WIEntry],
    chatLore: [WIEntry],
    personaLore: [WIEntry],
    strategy: WIInsertionStrategy
) -> [WIEntry] {

    // (1) 排序函数：order 从大到小（world-info.js:4590 附近的 sortFn）
    //     ★ JS Array.sort 在 V8 中是**稳定排序** ⇒ 同 order 保持原插入顺序。
    //       Swift 的 sort() **不保证稳定**！必须自己带上原始下标做次级 key。
    func sortFn(_ a: WIEntry, _ b: WIEntry) -> Bool {
        if a.order != b.order { return a.order > b.order }
        return a.originalIndex < b.originalIndex          // ★ 保证稳定性
    }

    // (2) 按 strategy 合并 global + character
    var entries: [WIEntry]
    switch strategy {
    case .evenly:       entries = (globalLore + characterLore).sorted(by: sortFn)              // :4610
    case .characterFirst: entries = characterLore.sorted(by: sortFn) + globalLore.sorted(by: sortFn)  // :4613 ★ 默认
    case .globalFirst:  entries = globalLore.sorted(by: sortFn) + characterLore.sorted(by: sortFn)    // :4616
    }

    // (3) ★ chatLore 永远最前，然后 personaLore，然后上面的结果（:4625）
    entries = chatLore.sorted(by: sortFn) + personaLore.sorted(by: sortFn) + entries

    // (4) parseDecorators + 计算 hash（:4628-4634）
    //     ★ hash 是 getStringHash(JSON.stringify(entry))，**在 parseDecorators 之后**计算
    entries = entries.enumerated().map { (i, e) in
        var e = e
        (e.decorators, e.content) = parseDecorators(e.content)      // :4629
        e.hash = getStringHash(jsonString(e))                        // :4632
        e.sortIndex = i                                              // 供 §5.5 排序用
        return e
    }

    return entries        // ST 再 structuredClone（:4639）；Swift struct 天然值语义
}
```

**`parseDecorators`（`world-info.js:4652-4700`）**

```swift
/// 来源：world-info.js:4652-4700
/// 规则：
/// 1. content 不以 "@@" 开头 ⇒ 无装饰器，content 原样
/// 2. 逐行扫描；行以 "@@" 开头时：
///    - 以 "@@@" 开头且尚未 fallback ⇒ **continue**（跳过，不记录）
///    - isKnownDecorator ⇒ 记录（去掉一个 "@" 若是 "@@@" 形式），fallbacked = false
///    - 否则 fallbacked = true（后续的 "@@@" 行将按普通装饰器处理）
/// 3. 返回 (decorators, 去掉装饰器行后的 content)
public func parseDecorators(_ content: String) -> (decorators: [String], content: String)
```

> **⚠️ 易错点 5.7（高危，Swift 特有）**：**Swift 的 `Array.sorted(by:)` 不保证稳定**。
> `02#4.4` 明确写了「Array.sort 在 V8 中稳定 → 同 order 保持原插入顺序」，
> 而这直接影响「预算耗尽时谁先被保留」。Swift 必须显式加次级 key（原始下标），
> 否则同一份世界书在 iOS 上可能激活出**不同的条目集合**。
>
> **⚠️ 易错点 5.8**：`chatLore` / `personaLore` 的「永远最前」是**在排序之后拼在前面**（`:4625`），
> 不是「sort 时优先」。所以 chatLore 里 `order = 1` 的条目仍然排在 characterLore 里 `order = 100` 的条目**之前**。
>
> **⚠️ 易错点 5.9**：`hash` 是 `getStringHash(JSON.stringify(entry))`，用于 sticky/cooldown 的效果匹配
> （`world-info.js:624`）。JSON 键顺序影响 hash ⇒ Swift 若要跨端一致必须固定键顺序。
> v1 只要**端内稳定**即可（用 `sortKeys` 的确定性编码）。
>
> **⚠️ 易错点 5.10**：`getSortedEntries` 返回前 `structuredClone`（`:4639`），
> 保证「上一轮扫描对 `entry.content` 的宏替换写回」不污染下一轮。Swift 用 `struct` + `var` 副本天然满足，
> 但**不要**把 `WIEntry` 写成 `class`。

### 5.5 `checkWorldInfo` 主循环 `[P0]`

**来源**：`02#4.5` + `world-info.js:4709-5282`（关键段落已核对，行号逐条标注）。

#### 5.5.1 返回值类型

```swift
public struct WIPromptResult {
    public var before: String = ""
    public var after: String = ""
    /// (isBefore, content)：true ⇒ EMTop，false ⇒ EMBottom
    public var emEntries: [(isBefore: Bool, content: String)] = []
    /// (depth, role, entries)
    public var depthEntries: [(depth: Int, role: WIRole, entries: [String])] = []
    public var anBefore: [String] = []
    public var anAfter: [String] = []
    public var outlets: [String: [String]] = [:]
    public var activated: [WIEntry] = []
}
```

#### 5.5.2 主循环伪代码

```swift
public func checkWorldInfo(
    chatNewestFirst: [String],
    maxContext: Int,                      // = getMaxPromptTokens()（不含 response）
    global: GlobalScanData,
    settings: WISettings,
    sortedEntries: [WIEntry],
    extensionPrompts: ExtensionPromptStore,
    macroEngine: MacroEngine,
    tokenCounter: TokenCounter,
    timedStore: inout TimedStore          // [P2]
) async -> WIPromptResult {

    // ── (0) 预算（world-info.js:4736-4741）─────────────────────────────
    // ★ `|| 1`：预算向下取整为 0 时兜底成 1
    var budget = Int((Double(settings.budgetPercent) * Double(maxContext) / 100).rounded())
    if budget == 0 { budget = 1 }
    if settings.budgetCap > 0 { budget = min(budget, settings.budgetCap) }

    // ── (1) buffer（含可被扫描的扩展注入）──────────────────────────────
    // #injectBuffer = extensionPrompts 里 scan == true 的 prompt 的已宏替换值（world-info.js:4719-4726）
    let injections = extensionPrompts.scannableValues()      // 每个值都已经过 macroEngine.substitute
    let buffer = WorldInfoBuffer(messages: chatNewestFirst, globalScanData: global,
                                 startDepth: 0, injections: injections)

    // ── (2) 定时效果 [P2]（world-info.js:4745-4747）─────────────────────
    var timed = TimedEffects(chatLength: chatNewestFirst.count, store: timedStore, entries: sortedEntries)
    timed.check()

    // ── (3) delayUntilRecursion 分级（world-info.js:4757-4763）──────────
    // ★ true ⇒ 1；去重 + 升序
    var delayLevels = Array(Set(sortedEntries.compactMap { e -> Int? in
        let lvl = e.delayUntilRecursionLevel
        return lvl > 0 ? lvl : nil
    })).sorted()
    var currentDelayLevel = delayLevels.isEmpty ? 0 : delayLevels.removeFirst()

    // ── (4) 状态初始化 ────────────────────────────────────────────────
    var state: WIScanState = .initial
    var count = 0
    var overflowed = false
    var activated: [String: WIEntry] = [:]                  // key = "\(world).\(uid)"
    var failedProbability = Set<String>()                   // key 同上
    var allActivatedText = ""

    // ── (5) 主循环 ────────────────────────────────────────────────────
    while state != .none {

        // 5.0 max recursion steps（world-info.js:4768-4771）
        if settings.maxRecursionSteps > 0 && settings.maxRecursionSteps <= count { break }
        count += 1
        var next: WIScanState = .none
        var activatedNow: [WIEntry] = []

        for e in sortedEntries {
            let key = e.id

            // ═══ A. 硬性跳过（顺序不可换）═══
            if failedProbability.contains(key) || activated[key] != nil { continue }   // :4797
            if e.disable { continue }                                                 // :4801
            if !e.triggers.isEmpty && !e.triggers.contains(global.trigger) { continue } // :4807
            if isFilteredByCharacterOrTag(e) { continue }                             // :4816, :4826

            let isSticky   = timed.isEffectActive(.sticky, e)     // [P2]
            let isCooldown = timed.isEffectActive(.cooldown, e)   // [P2]
            let isDelay    = timed.isEffectActive(.delay, e)      // [P1]
            if isDelay { continue }                                                   // :4849
            if isCooldown && !isSticky { continue }                                   // :4854
            if state != .recursion && e.delayUntilRecursionLevel > 0 && !isSticky { continue }  // :4860
            if state == .recursion && e.delayUntilRecursionLevel > currentDelayLevel && !isSticky { continue }  // :4865
            if state == .recursion && settings.recursive && e.excludeRecursion && !isSticky { continue }        // :4870

            // ═══ B. 无条件激活 ═══
            if e.decorators.contains("@@activate") { activatedNow.append(e); continue }        // :4875
            if e.decorators.contains("@@dont_activate") { continue }                           // :4881
            // externallyActivated（:4886）[P2]
            if e.constant { activatedNow.append(e); continue }                                 // :4893 ← 蓝灯
            if isSticky { activatedNow.append(e); continue }                                   // :4899
            if e.key.isEmpty { continue }                                                      // :4905

            // ═══ C. 主关键词匹配 ═══
            let text = buffer.text(for: e, state: state)
            let primaryHit = e.key.contains { k in
                let s = macroEngine.substitute(k).trimmingCharacters(in: .whitespacesAndNewlines)  // :4915
                guard !s.isEmpty else { return false }
                return buffer.matchKeys(haystack: text, needle: s, entry: e, settings: settings)    // :4916
            }
            if !primaryHit { continue }                                                            // :4919

            // ═══ D. 次关键词 ═══
            let hasSecondary = e.selective && !e.keysecondary.isEmpty
            if !hasSecondary { activatedNow.append(e); continue }                                   // :4930
            if matchSecondaryKeys(e, text: text, buffer: buffer, macroEngine: macroEngine,
                                  settings: settings) {                                            // :4943-4978
                activatedNow.append(e)
            }
        }

        // ═══ E. 排序：sticky 优先，其次 sortedEntries 下标升序（:4993-5006）═══
        var newEntries = activatedNow.sorted { a, b in
            let sa = timed.isEffectActive(.sticky, a) ? 1 : 0
            let sb = timed.isEffectActive(.sticky, b) ? 1 : 0
            if sa != sb { return sa > sb }
            return a.sortIndex < b.sortIndex
        }

        // ═══ F. 概率 + 预算 ═══
        let textToScanTokens = tokenCounter.count(allActivatedText)      // :5010 ★ 上一轮的累积文本
        filterByInclusionGroups(&newEntries, activated: activated, buffer: buffer,
                                state: state, timed: timed)              // :5012  [P1] 会**原地删元素**
        var ignoresBudget = newEntries.filter(\.ignoreBudget).count      // :5017

        var newContent = ""
        for (i, e) in newEntries.enumerated() {
            ignoresBudget -= e.ignoreBudget ? 1 : 0                      // :5020
            if overflowed && !e.ignoreBudget {                           // :5021-5026
                if ignoresBudget > 0 { continue }
                break
            }
            guard verifyProbability(e, timed: timed, failed: &failedProbability) else { continue }  // :5028-5055

            // ★ 宏替换 + **就地写回**（:5058）
            //   JS 里 entry 是引用类型，写在 activated[key] 和 newEntries 上是同一个对象；
            //   Swift 里 WIEntry 是 struct ⇒ 必须显式写回 newEntries[i]，否则
            //   ① activated[key] 与 ② 后面的 forRecursion（递归缓冲）都拿不到替换后的内容。
            var entry = e
            entry.content = macroEngine.substitute(entry.content)
            newEntries[i] = entry                                        // ★ Swift 必需，JS 不需要
            newContent += entry.content + "\n"                           // :5059

            // ★ 预算是 `>=`（不是 `>`）；正好等于预算也会溢出（:5061）
            if !entry.ignoreBudget && (textToScanTokens + tokenCounter.count(newContent)) >= budget {
                if !overflowed { overflowed = true }                     // :5062-5071
                continue                                                 // ★ 丢弃该条目
            }
            activated[key] = entry                                       // :5075
        }

        let successful = newEntries.filter { !failedProbability.contains($0.id) }        // :5079
        let forRecursion = successful.filter { !$0.preventRecursion }                    // :5080

        // ═══ G. 决定下一轮（:5096-5133）═══
        if settings.recursive && !overflowed && !forRecursion.isEmpty { next = .recursion }        // :5097
        if settings.recursive && !overflowed && state == .minActivations && buffer.hasRecurse() { next = .recursion }
        if next == .none && !overflowed && settings.minActivations > 0
            && activated.count < settings.minActivations {                                          // :5116
            let overMax = (settings.minActivationsDepthMax > 0 && buffer.depth > settings.minActivationsDepthMax)
                       || buffer.depth > chatNewestFirst.count
            if !overMax { next = .minActivations; buffer.advanceScan() }
        }
        if next == .none && !delayLevels.isEmpty {                                                  // :5129-5133
            next = .recursion
            currentDelayLevel = delayLevels.removeFirst()
        }

        state = next
        if state != .none {                                                                          // :5138-5144
            let t = forRecursion.map(\.content).joined(separator: "\n")
            if !t.isEmpty {
                buffer.addRecurse(t)
                allActivatedText = t + "\n" + allActivatedText
            }
        }
        // WORLDINFO_SCAN_DONE 事件（:5175-5186）—— [P2] 无扩展生态可省略
    }

    // ── (6) 构建注入（见 §5.7）─────────────────────────────────────────
    return buildInjections(activated: activated, macroEngine: macroEngine, timed: &timed)
}
```

**终止条件（`02#4.5` 结论 1）**

- `state == .none` 时退出。正常情况（`recursive == false`、`minActivations == 0`、无 delayUntilRecursion）**第二轮即 NONE**。
- **递归没有固定上限**，只受 `maxRecursionSteps`（默认 0 = 无限）与 `overflowed` 限制。
- `maxRecursionSteps > 0` 时会**顺带禁用 min activations**（`break` 在循环顶部，`:4767` 注释）。

**预算语义（`02#4.5` 结论 2）**

- `textToScanTokens` 是**上一轮结束时的** `allActivatedText` 的 token 数（`:5010`）。
- `newContent` 是**本轮已累积**的内容。
- 超了 ⇒ `overflowed = true` 且 `continue`（该条目被丢弃）。
- **超预算之后的处理是「丢掉当轮所有未插入的非 `ignoreBudget` 条目」**（`:5021-5025`），
  但 `ignoreBudget == true` 的条目**仍会插入**（`ignoresBudget` 计数控制跳过/break）。
- 一旦 `overflowed`，`RECURSION` 不再启动（`:5097` 的条件含 `!token_budget_overflowed`）。

**激活顺序 ≠ 注入顺序（`02#4.5` 结论 3）**

- **激活**用 §5.5.2-E 的排序（sticky 优先 → `sortedEntries` 下标升序）。
- **注入**用 §5.7 的排序（`order` 降序 + `unshift`）。

> **⚠️ 易错点 5.11（高危）**：`02#4.5` 结论 2 说「超预算之后的处理是丢掉当轮所有未插入的非 ignoreBudget 条目」。
> 注意 `overflowed` 是**跨轮持久**的，所以第二轮开头 `:5021` 会直接跳过所有非 `ignoreBudget` 条目。
>
> **⚠️ 易错点 5.12**：`filterByInclusionGroups` 会**原地 `splice` 修改 `newEntries`**（`02#7` 陷阱 11），
> 影响后续预算处理的顺序。语义上：组内互斥淘汰发生在**概率检查之前**。
>
> **⚠️ 易错点 5.13**：`verifyProbability` 失败会把条目写入 `failedProbability`，
> 且在**本轮整个扫描（含所有递归轮）内不再被考虑**（`:4797`）。
> 概率检查在**预算检查之前**，所以失败**不占预算**。
>
> **⚠️ 易错点 5.14**：`entry.content = substituteParams(...)` 的结果被写进 `activated[key]`，
> 而 `forRecursion` 用的是 `newEntries` 里的**原始对象**（`:5080` 在 `:5058` 之后过滤，但数组元素是同一引用）。
> JS 里 `entry` 是引用类型，`newEntries` 里的元素与 `activated` 里的是**同一个对象**，
> 所以递归缓冲拿到的是**已宏替换**的内容。Swift 里 `WIEntry` 是 struct，
> `for e in newEntries` 的 `var entry = e; entry.content = ...` 只改了副本 ⇒
> **必须显式把替换后的内容写回 `newEntries` 数组**，否则递归扫描会拿到未替换的内容。
> 这是 §5 里最容易静默出错的一处。

### 5.6 `matchKeys` 匹配算法 `[P0]`

**来源**：`02#4.6` + `world-info.js:337-366`、`:2901-2926`（**已逐行核对**）。

```swift
/// 来源：world-info.js:337-366
public func matchKeys(haystack: String, needle: String, entry: WIEntry, settings: WISettings) -> Bool {

    // (1) ★ 正则优先：/pattern/flags ⇒ **覆盖其它所有选项**（大小写、整词都失效）
    if let regex = parseRegexFromString(needle) {
        return regex.firstMatch(in: haystack, range: NSRange(haystack.startIndex..., in: haystack)) != nil
        // ★ 注意 lastIndex 状态问题：JS 里带 g 的 test() 有状态；ST 每次新建 RegExp 规避。
        //   Swift 用 firstMatch（无状态），天然正确。
    }

    // (2) 大小写（entry 覆写全局）
    let caseSensitive = entry.caseSensitive ?? settings.caseSensitive
    let h = caseSensitive ? haystack : haystack.lowercased()
    let n = caseSensitive ? needle   : needle.lowercased()

    // (3) 整词（entry 覆写全局）
    let matchWholeWords = entry.matchWholeWords ?? settings.matchWholeWords
    if matchWholeWords {
        let words = n.split(whereSeparator: { $0.isWhitespace })      // JS: split(/\s+/)
        if words.count > 1 {
            return h.contains(n)                                     // ★ 多词：退化为子串包含
        }
        // 单词：\W 边界（含标点等非字母数字字符）
        let pattern = "(?:^|\\W)(\(NSRegularExpression.escapedPattern(for: n)))(?:$|\\W)"
        return (try? NSRegularExpression(pattern: pattern))?
            .firstMatch(in: h, range: NSRange(h.startIndex..., in: h)) != nil
    }

    // (4) 默认：子串包含
    return h.contains(n)
}

/// 来源：world-info.js:2901-2926
/// ★ 正则字面量解析
public func parseRegexFromString(_ input: String) -> NSRegularExpression? {
    // (1) 必须形如 /pattern/flags，flags ∈ [gimsuy]*
    guard let m = firstMatch(input, #"^\/([\w\W]+?)\/([gimsuy]*)$"#) else { return nil }
    var pattern = m.group(1)
    let flags = m.group(2)

    // (2) pattern 里存在**未转义的 /** ⇒ 无效
    if pattern.range(of: #"(^|[^\\])/"#, options: .regularExpression) != nil { return nil }

    // (3) 反转义 \/ → /
    pattern = pattern.replacingOccurrences(of: "\\/", with: "/")

    // (4) 编译；失败 ⇒ nil（退回普通匹配）
    var options: NSRegularExpression.Options = []
    if flags.contains("i") { options.insert(.caseInsensitive) }
    if flags.contains("m") { options.insert(.anchorsMatchLines) }
    if flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
    // g / u / y：Swift 无对应；u 是默认行为，g/y 对 firstMatch 无影响
    return try? NSRegularExpression(pattern: pattern, options: options)
}
```

**次关键词逻辑（`world-info.js:4943-4978`）**

```swift
/// 来源：world-info.js:4943-4978
/// ★ 顺序敏感：AND_ANY / NOT_ALL 在第一个满足/不满足处**提前返回**
public func matchSecondaryKeys(_ entry: WIEntry, text: String,
                               buffer: WorldInfoBuffer, macroEngine: MacroEngine,
                               settings: WISettings) -> Bool {
    var hasAnyMatch = false
    var hasAllMatch = true

    for k in entry.keysecondary {
        let s = macroEngine.substitute(k).trimmingCharacters(in: .whitespacesAndNewlines)   // :4947
        let hit = !s.isEmpty && buffer.matchKeys(haystack: text, needle: s, entry: entry, settings: settings)
        if hit { hasAnyMatch = true }
        if !hit { hasAllMatch = false }

        if entry.selectiveLogic == .andAny && hit  { return true }     // :4965-4967
        if entry.selectiveLogic == .notAll && !hit { return true }     // :4969-4971
    }
    if entry.selectiveLogic == .notAny && !hasAnyMatch { return true } // :4974
    if entry.selectiveLogic == .andAll &&  hasAllMatch { return true } // :4976
    return false
}
```

**真值表（`S_i` = 第 i 个次关键词是否命中）**

| logic | 值 | 成立条件 | 等价 |
|---|---|---|---|
| `AND_ANY` | 0 | `∃ i: S_i` | 任一次关键词命中 |
| `NOT_ALL` | 1 | `∃ i: ¬S_i` | `¬∀S_i` |
| `NOT_ANY` | 2 | `∀ i: ¬S_i` | 全部不命中 |
| `AND_ALL` | 3 | `∀ i: S_i` | 全部命中 |

**`constant`（蓝灯）的精确语义（`02#4.6` 末）**

- 在关键词检查**之前**（`:4893`），任何 `disable/triggers/characterFilter/timed-effect/delayUntilRecursion/excludeRecursion` 检查**之后**立即激活。
- **仍会**被 `@@dont_activate`、`failedProbability`、`probability`、预算限制影响。
- `excludeRecursion` 对它**无效**（因为不进关键词分支）。
- `isDelay`（`delay` 字段）**会**拦住它。

> **⚠️ 易错点 5.15**：正则 key 的 `g` 标志在 JS 里会造成 `lastIndex` 状态问题（第二次 `test()` 从上次位置开始）。
> ST 每次新建 `RegExp` 规避了。**Swift 用 `firstMatch` 无状态，天然正确**——
> 但如果你缓存了 `NSRegularExpression` 实例，注意它本身是线程安全且无状态的，可放心缓存。
>
> **⚠️ 易错点 5.16**：整词匹配的 `\W` 在 Swift/ICU 里默认是 ASCII 语义，
> 与 JS 的 `\W`（`[^A-Za-z0-9_]`）一致。但**中文/日文不会被当作词字符**，
> 所以整词匹配对 CJK 基本等价于子串匹配。这是 ST 的行为，保持一致。
>
> **⚠️ 易错点 5.17**：`parseRegexFromString` 的 flags 检查里 `pattern.match(/(^|[^\\])\//)` 用来拒绝
> 「未转义的 `/`」。注意 `^` 分支：**以 `/` 开头**也算无效（`(^|[^\\])` 的 `^` 匹配空串）。
> 所以 `//foo/` 这种空 pattern 开头的会被拒；`/a\/b/` 合法。
>
> **⚠️ 易错点 5.18**：大小写转换用 `lowercased()`。**土耳其语 locale 的 `I` → `ı`** 会出问题。
> ST 用的是 JS `toLowerCase()`（locale-independent）。Swift 的 `lowercased()` 也是 locale-independent
> （`lowercased(with:)` 才受 locale 影响），所以安全。但**不要**用 `lowercased(with: .current)`。

### 5.7 注入位置与 `depth` 语义 `[P0]`

**来源**：`02#4.7` + `world-info.js:5189-5282`（**已逐行核对**）。

```swift
/// 来源：world-info.js:5203-5263
/// ★ 先按 order **降序**遍历，再对每个数组用 `unshift`（插到头部）
///   ⇒ 最终数组是 **order 升序**
func buildInjections(activated: [String: WIEntry], macroEngine: MacroEngine,
                     timed: inout TimedEffects) -> WIPromptResult {

    var before: [String] = [], after: [String] = []
    var emTop: [String] = [], emBottom: [String] = []
    var anTop: [String] = [], anBottom: [String] = []
    var depthEntries: [(depth: Int, role: WIRole, entries: [String])] = []
    var outlets: [String: [String]] = [:]

    let ordered = activated.values.sorted { $0.order > $1.order }        // :5203 ★ 降序

    for e in ordered {
        let regexDepth = (e.position == .atDepth) ? e.depth : nil        // :5204
        let content = applyWorldInfoRegex(e.content, depth: regexDepth)   // :5205 getRegexedString
        guard !content.isEmpty else { continue }                          // :5207-5210

        switch e.position {
        case .before:   before.insert(content, at: 0)                     // :5214 unshift
        case .after:    after.insert(content, at: 0)                      // :5217
        case .emTop:    emTop.insert(content, at: 0)                      // :5220
        case .emBottom: emBottom.insert(content, at: 0)                   // :5225
        case .anTop:    anTop.insert(content, at: 0)                      // :5230
        case .anBottom: anBottom.insert(content, at: 0)                   // :5233
        case .atDepth:                                                    // :5235-5246
            let d = e.depth                       // ★ 注意：push 时用的是 e.depth 原值（见易错点 5.19）
            let r = e.role
            if let i = depthEntries.firstIndex(where: { $0.depth == d && $0.role == r }) {
                depthEntries[i].entries.insert(content, at: 0)            // :5238 unshift
            } else {
                depthEntries.append((depth: d, role: r, entries: [content]))  // :5240-5244
            }
        case .outlet:                                                     // :5248-5259
            guard !e.outletName.isEmpty else { continue }                 // :5249-5252
            outlets[e.outletName, default: []].append(content)            // :5253-5257 ★ push（不 unshift）
        }
    }

    // ★ 最终都是 order 升序
    return WIPromptResult(
        before: before.joined(separator: "\n"),                           // :5265
        after: after.joined(separator: "\n"),                             // :5266
        emEntries: emTop.map { (true, $0) } + emBottom.map { (false, $0) },
        depthEntries: depthEntries,
        anBefore: anTop, anAfter: anBottom,
        outlets: outlets,
        activated: Array(activated.values)
    )
}
```

**AN 合并（`world-info.js:5268-5272`）**

```swift
// ★ 仅在 shouldWIAddPrompt 为真时执行
if shouldWIAddPrompt {
    let originalAN = extensionPrompts.value(for: "2_floating_prompt")      // NOTE_MODULE_NAME
    var anWithWI = "\(anTop.joined(separator: "\n"))\n\(originalAN)\n\(anBottom.joined(separator: "\n"))"
    // ★ replace(/(^\n)|(\n$)/g, '')：只去掉**首尾各一个**换行
    if anWithWI.hasPrefix("\n") { anWithWI.removeFirst() }
    if anWithWI.hasSuffix("\n") { anWithWI.removeLast() }
    extensionPrompts.set("2_floating_prompt", value: anWithWI,
                         position: notePosition, depth: noteDepth,
                         scan: allowWIScan, role: noteRole)
}
```

**`position` 的最终落点（`02#4.7` 表）**

| position | 落点 | 受 `prompt_order` 影响 |
|---|---|---|
| `before`(0) | `worldInfoBefore` 槽位 | ✅ 用户可拖拽 |
| `after`(1) | `worldInfoAfter` 槽位 | ✅ |
| `anTop`(2) / `anBottom`(3) | 拼进 Author's Note 值的前/后 | 间接（AN 的位置/深度/role） |
| `atDepth`(4) | `IN_CHAT` 深度注入（role 可控） | ❌ 纯按 depth |
| `emTop`(5) / `emBottom`(6) | 示例消息块最前/最后 | 间接（`dialogueExamples` 槽位） |
| `outlet`(7) | `extensionPrompts["customWIOutlet_\(name)"]`，由 `{{outlet::name}}` 取值 | 由取值处决定 |

**`depth` 的精确语义（`02#4.7`）**

- `depth = 0` ⇒ 插到最后一条聊天消息**之后**（成为最新 message）。
- `depth = n` ⇒ 插到「最新消息往下数第 n 条」**之前**。
  严格说：`depthBuffer` 的索引 `d` 对应 `chat[chat.count - 1 - d]`。
- 超出聊天长度时 `splice` 会把消息**追加到末尾**（JS `splice` 越界 index 夹到 `length`）。
  Swift 用 `min(idx, messages.count)`。
- `atDepth` 条目在宏替换后**还要再过一次正则**（`regex_placement.WORLD_INFO`），
  传入 `depth` 供「按深度生效」的正则使用。

> **⚠️ 易错点 5.19**：`:5240-5244` 的 `WIDepthEntries.push({ depth: entry.depth, ... })` 用的是
> **`entry.depth` 原值**，而 `findIndex` 的比较用的是 `entry.depth ?? DEFAULT_DEPTH`（`:5236`）。
> 也就是说当 `entry.depth` 是 `undefined` 时，push 进去的对象 `depth` 字段是 `undefined`，
> 后续 `script.js:4671` 的 `inject_ids.CUSTOM_WI_DEPTH_ROLE(e.depth, e.role)` 会拼出
> `"customDepthWI_undefined_0"`，而 `:4671` 的 `setExtensionPrompt(..., e.depth, ...)` 传的 depth 也是 `undefined`。
> Swift 侧 `@Decodable` 会把缺省 `depth` 补成 `4`（`WIEntry.depth` 有默认值），
> 因此**行为比 ST 更"正确"**——这是**可接受的差异**（ST 那一条会静默失效）。
> 请在代码注释里写明这一点。
>
> **⚠️ 易错点 5.20**：`outlet` 用 `push`（`:5254`），其它 position 用 `unshift`。
> 所以 outlet 内容是 **order 降序**，其余是 **order 升序**。不要统一。
>
> **⚠️ 易错点 5.21**：`worldInfoBefore` / `worldInfoAfter` 只在**非空**时返回非空串
> （`:5265-5266` 的三元判断），空数组返回 `""`（不是 `[]` join 出来的 `""`——其实一样，
> 但 `formatWorldInfo("")` 返回 `""`，槽位内容为空会被 `getChat()` 跳过）。

### 5.8 高级字段 `[P1]` / `[P2]`

#### 5.8.1 `probability` / `useProbability` `[P1]`

```swift
/// 来源：world-info.js:5028-5049
func verifyProbability(_ entry: WIEntry, timed: TimedEffects,
                       failed: inout Set<String>, rng: RandomSource) -> Bool {
    if !entry.useProbability || entry.probability == 100 { return true }    // :5030-5033
    if timed.isEffectActive(.sticky, entry) { return true }                 // :5035-5039 ★ sticky 不重掷
    let roll = rng.nextUnit() * 100                                         // :5041
    if roll <= Double(entry.probability) { return true }                    // :5042
    failed.insert(entry.id)                                                 // :5047
    return false
}
```

- 失败条目在**本轮整个扫描（含所有递归轮）内**不再被考虑（`:4797`）。
- 概率检查在**预算检查之前** ⇒ 失败不占预算。

#### 5.8.2 `group` / `groupOverride` / `groupWeight` / `useGroupScoring` `[P1]`

**来源**：`02#4.8` + `world-info.js:5292-5475`。

```swift
/// 来源：world-info.js:5388-5475
/// ★ 会**原地修改** `newEntries`（splice），影响后续预算处理顺序
func filterByInclusionGroups(_ newEntries: inout [WIEntry],
                             activated: [String: WIEntry],
                             buffer: WorldInfoBuffer,
                             state: WIScanState,
                             timed: TimedEffects) {

    // (1) 按 group 分组；一个条目可属多个组（group.split(/,\s*/)）
    var grouped: [String: [WIEntry]] = [:]
    for e in newEntries {
        for g in e.group.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !g.isEmpty {
            grouped[String(g), default: []].append(e)
        }
    }
    guard !grouped.isEmpty else { return }

    // (2) 组内若有 sticky ⇒ 移除其它所有条目；移除组内在 cooldown/delay 的条目（:5337）
    var hasStickyMap: [String: Bool] = [:]
    filterGroupsByTimedEffects(&grouped, timed: timed, hasStickyMap: &hasStickyMap,
                               removeEntry: { remove(&newEntries, $0) })

    // (3) 组内评分（仅当 useGroupScoring 开启且组内无 sticky）（:5292）
    filterGroupsByScoring(&grouped, buffer: buffer, state: state,
                          hasStickyMap: hasStickyMap, removeEntry: { remove(&newEntries, $0) })

    // (4) 逐组裁决（:5398-5475）
    for (key, group) in grouped {
        if hasStickyMap[key] == true { continue }
        // 已有同组条目被激活 ⇒ 移除组内其余全部
        if activated.values.contains(where: { $0.group.split(separator: ",").map(String.init).contains(key) }) {
            removeAllBut(group, nil, from: &newEntries); continue
        }
        if group.count <= 1 { continue }
        // 显式优先级：groupOverride == true 的条目里取 order 最大者
        let prios = group.filter(\.groupOverride).sorted { $0.order > $1.order }
        if let winner = prios.first { removeAllBut(group, winner, from: &newEntries); continue }
        // 加权随机
        let totalWeight = group.reduce(0) { $0 + $1.groupWeight }
        var roll = rng.nextUnit() * Double(totalWeight)
        var winner: WIEntry? = nil
        for e in group { roll -= Double(e.groupWeight); if roll <= 0 { winner = e; break } }
        guard let w = winner else { continue }
        removeAllBut(group, w, from: &newEntries)
    }
}
```

**`getScore`（`world-info.js:428-473`）**

```swift
func getScore(_ entry: WIEntry, buffer: WorldInfoBuffer, state: WIScanState,
              settings: WISettings, macroEngine: MacroEngine) -> Int {
    let text = buffer.text(for: entry, state: state)
    let primary   = entry.key.count { k in
        let s = macroEngine.substitute(k).trimmingCharacters(in: .whitespacesAndNewlines)
        return !s.isEmpty && buffer.matchKeys(haystack: text, needle: s, entry: entry, settings: settings)
    }
    let secondary = entry.keysecondary.count { /* 同上 */ }
    if entry.key.isEmpty { return 0 }
    if !entry.keysecondary.isEmpty {
        switch entry.selectiveLogic {
        case .andAny: return primary + secondary
        case .andAll: return secondary == entry.keysecondary.count ? primary + secondary : primary
        default: break
        }
    }
    return primary
}
```

> **注意 `world_info_use_group_scoring` 的**触发条件**：全局开启 **或** 组内**任一**条目
> `useGroupScoring == true`，且组内**无 sticky**（`world-info.js:5292-5336`）。

#### 5.8.3 `sticky` / `cooldown` / `delay` `[P2]`

**来源**：`02#4.8` + `world-info.js:479-795`（**已核对关键段**）。

持久化位置：`chat_metadata.timedWorldInfo.{sticky,cooldown}[key]`，`key = "\(world).\(uid)"`。

```swift
/// 来源：world-info.js:604-611
struct WITimedEffect: Codable, Equatable {
    var hash: UInt64          // = entry.hash
    var start: Int            // = 扫描时的 chat.length（虚拟时钟）
    var end: Int              // = chat.length + Number(entry[type])
    var protected: Bool       // sticky 的写入用 true
}

final class TimedEffects {
    private var buffer: [EffectType: [WIEntry]] = [.sticky: [], .cooldown: [], .delay: []]

    /// 来源：world-info.js:619-660
    func checkTimedEffectOfType(_ type: EffectType, entries: [WIEntry],
                                store: inout [String: WITimedEffect],
                                onEnded: (WIEntry) -> Void) {
        for (key, value) in store {
            let entry = entries.first { String($0.hash) == String(value.hash) }   // :624
            // (a) 聊天未推进且未 protected ⇒ 删除（:626-630）
            if chatLength <= value.start && !value.protected { store[key] = nil; continue }
            // (b) 条目不存在（可能来自别的角色的书）：区间过了才删（:633-639）
            guard let entry else { if chatLength >= value.end { store[key] = nil }; continue }
            // (c) 条目已不再配置该效果 ⇒ 删除（:642-646）
            if !entry.hasEffect(type) { store[key] = nil; continue }
            // (d) 区间结束 ⇒ 删除 + 回调（:648-655）
            if chatLength >= value.end { store[key] = nil; onEnded(entry); continue }
            // (e) 生效中
            buffer[type, default: []].append(entry)                                // :657
        }
    }

    /// delay 不走 metadata（world-info.js:666-677）
    /// `chat.length < entry.delay` ⇒ 前 N 条消息内不激活
    func checkDelayEffect(entries: [WIEntry]) { ... }
}
```

**sticky 结束 → 立即进入 cooldown（`world-info.js:518-529`）**

```swift
onEnded[.sticky] = { entry in
    guard let cd = entry.cooldown, cd > 0 else { return }
    let effect = WITimedEffect(hash: entry.hash,
                               start: chatLength,
                               end: chatLength + cd,
                               protected: true)
    metadata.timedWorldInfo.cooldown[entry.id] = effect
    buffer[.cooldown, default: []].append(entry)     // ★ 本次求值立即生效
}
```

> **⚠️ 易错点 5.22**：`{` 虚拟时钟 `}` 是 `chat.length`（**整数**），不是时间戳。
> `start`/`end` 都是「扫描时的聊天长度」基础上的偏移。
>
> **⚠️ 易错点 5.23**：条目匹配用的是 **`entry.hash`**（`String(hash) == String(value.hash)` 的字符串比较，`:624`）
> 而不是 `world.uid`。而**写入**用的 key 是 `world.uid`（`:594`）。两者的更新时机不同步时会出现
> 「key 存在但 hash 匹配不到」⇒ 按 (b) 分支在区间结束后清理。

#### 5.8.4 `delayUntilRecursion` `[P1]`

- `true` ⇒ 级别 1；数值 N ⇒ 级别 N（`world-info.js:4760-4763`）。
- 非 `RECURSION` 轮次直接跳过（`:4860`）。
- `RECURSION` 轮次需 `entry.delayUntilRecursion <= currentDelayLevel`（`:4865`）。
- 主循环结束时若还有未消费的 level，会强制再跑一轮 `RECURSION`（`:5129-5133`）。
- **`sticky` 可绕过该限制**。

#### 5.8.5 `@@activate` / `@@dont_activate` 装饰器 `[P0]`

- 内容行首的 `@@activate` 让条目**无条件激活**（在 `constant` **之前**）。
- `@@dont_activate` 无条件跳过。
- `@@@` 前缀表示**转义**（不会当作装饰器，但仍被记录为带 `@@` 的装饰器字符串）。
- `parseDecorators` 只识别这两个（`KNOWN_DECORATORS`）。

#### 5.8.6 预算裁剪的完整语义汇总 `[P0]`

| 机制 | 行为 | 源码 |
|---|---|---|
| 预算公式 | `budget = round(world_info_budget * maxContext / 100) \|\| 1` | `:4736-4738` |
| 预算上限 | `world_info_budget_cap > 0` 时 `budget = min(budget, cap)` | `:4739-4741` |
| 累计口径 | `textToScanTokens`（**上一轮**已激活文本）+ `tokenCount(newContent)`（**本轮**累积） | `:5010`、`:5061` |
| 溢出判定 | `>= budget`（**不是** `>`） | `:5061` |
| 溢出后果 | 该条目丢弃；`overflowed = true`；后续轮次不再启动递归 | `:5062-5072`、`:5097` |
| 已溢出后的当轮 | 非 `ignoreBudget` 条目：`ignoresBudget > 0` 时 `continue`，否则 `break` | `:5021-5026` |
| `ignoreBudget` 条目 | **不计预算**，且预算溢出后**仍会插入** | `:5017`、`:5061` |
| 裁剪优先级 | `newEntries` 已按「sticky 优先 → `sortedEntries` 下标升序」排序 ⇒ **`order` 大且靠前的优先保留** | `:4993-5006` |
| 传入的 `maxContext` | = `getMaxPromptTokens()` = `maxContext - maxResponse`（**不含** response 预留） | `script.js:4560` |

> **⚠️ 易错点 5.24**：WI 预算的 `maxContext` 是 **prompt 预算**（`openai_max_context - openai_max_tokens`），
> 不是 `openai_max_context`。传错会让世界书吃太多预算。

### 5.9 ★ v1 最小可行子集 vs 可后续补的高级特性

这是本文最重要的一张表。**请严格按此排期，不要一次性实现全部。**

#### ✅ v1 必须实现（P0）—— 「能跑通且行为正确」

| # | 能力 | 依据 | 工作量 |
|---|---|---|---|
| 1 | `WIEntry` 数据模型 + JSON 导入（含 `delayUntilRecursion` 的 Bool/Int 兼容） | §5.1 | 小 |
| 2 | `getSortedEntries`：`character_first` 策略 + `order` 降序 + **稳定排序** + `chatLore`/`personaLore` 前置 | §5.4 | 小 |
| 3 | `parseDecorators`（`@@activate` / `@@dont_activate` / `@@@` 转义） | §5.8.5 | 小 |
| 4 | `WorldInfoBuffer`：`depthBuffer` + trim + `MATCHER`/`JOINER` 哨兵 + `globalScanData` 六项 | §5.3 | 中 |
| 5 | `matchKeys`：**完整**实现（正则 `/.../`、大小写、整词、子串全部四种） | §5.6 | 中 |
| 6 | 次关键词四逻辑（`andAny`/`notAll`/`notAny`/`andAll`）+ 自动返回语义 | §5.6 | 小 |
| 7 | 主循环：`INITIAL → NONE` 单轮（**不做递归**） | §5.5 | 中 |
| 8 | 硬性跳过：`disable` / `triggers` / `constant` / `key.isEmpty` | §5.5.2-A/B | 小 |
| 9 | 预算：百分比 + cap + `>=` 判定 + `ignoreBudget` | §5.8.6 | 小 |
| 10 | 注入落点：`before` / `after` / `atDepth` / `emTop` / `emBottom` / `anTop` / `anBottom` | §5.7 | 中 |
| 11 | `order` 降序 + `unshift` ⇒ 最终 `order` 升序 | §5.7 | 小 |
| 12 | `entry.content = macroEngine.substitute(content)` + 写回 | §4.7 | 小 |
| 13 | `key`/`keysecondary` 匹配前的宏替换 | §5.5.2-C | 小 |
| 14 | `WIPromptResult` → PromptAssembler 的接线（§2.5） | §2.5 | 中 |

**v1 明确不做**：`probability`、`group`、`recursive`、`minActivations`、`delayUntilRecursion`、
`sticky`/`cooldown`/`delay`、`characterFilter`、`outlet`、`getScore`/`useGroupScoring`、
`WORLDINFO_SCAN_DONE` 扩展点、`vectorized`。

**v1 实现主循环的方式**：把循环写成
```
state = .initial
一次 for e in sortedEntries { ... }
state = .none   // 直接终止
```
即保留循环骨架但只跑一轮，便于 P1 直接打开递归。

#### 🔶 P1（第二波）—— 「体验与兼容性」

| # | 能力 | 依据 | 说明 |
|---|---|---|---|
| 1 | `probability` / `useProbability` + `failedProbabilityChecks` | §5.8.1 | 6 行代码，但**必须**做对「跨轮不重掷」 |
| 2 | `delay`（前 N 条消息不激活） | §5.8.3 | 不需要持久化，最简单 |
| 3 | `group` / `groupOverride` / `groupWeight` | §5.8.2 | 互斥组，野外卡常用 |
| 4 | `recursive` + `maxRecursionSteps` + `recurseBuffer` | §5.5 | 打开递归后要**同时**实现 `preventRecursion`/`excludeRecursion` |
| 5 | `delayUntilRecursion` 分级 | §5.8.4 | 依赖递归 |
| 6 | `triggers` 生成类型白名单 | §5.5.2-A | 一行判断 |
| 7 | `characterFilter`（names/tags/isExclude） | §5.1 | 需要角色/标签数据接入 |
| 8 | `useGroupScoring` + `getScore` | §5.8.2 | 依赖 group |
| 9 | `wi_format` / `scenario_format` / `personality_format` | §2.3.0 | `stringFormat` 实现 |
| 10 | `outlet` + `{{outlet::}}` 宏 | §5.7 | 依赖 `ExtensionPromptStore` |
| 11 | `matchPersonaDescription` 等六项（已在 v1 的 buffer 里，只是没接数据） | §5.3 | 接数据即可 |

#### 🔷 P2（可延后）—— 「边缘/扩展生态」

| # | 能力 | 理由 |
|---|---|---|
| 1 | `sticky` / `cooldown` + `chat_metadata.timedWorldInfo` 持久化 | 需要聊天元数据存储；野外使用率低 |
| 2 | `minActivations` + `minActivationsDepthMax` + `skew` | 与 `maxRecursionSteps` 互斥，逻辑绕 |
| 3 | `getRegexedString`（`regex_placement.WORLD_INFO` 正则后处理） | 依赖整个正则扩展系统（`regex_placement` 有 6 种 placement） |
| 4 | `WORLDINFO_SCAN_DONE` 扩展点 | iOS 无扩展生态 |
| 5 | `vectorized` + 向量检索 | 见 04 文档的本地数据方案 |
| 6 | `externallyActivated`（`WorldInfoBuffer.externalActivations`） | 扩展 API |
| 7 | 跨端 hash/seed 一致性（`getStringHash` 已可跨端；`seedrandom` ARC4 移植） | 只在需要与桌面版对齐时 |

> **⚠️ 易错点 5.25（排期）**：不要因为「`recursive` 只是一个 bool」就先打开它。
> 一旦开启递归，你必须同时正确处理：`recurseBuffer` 的追加与参与扫描、
> `preventRecursion`、`excludeRecursion`、`overflowed` 对递归的抑制、
> `allActivatedText` 的累积、以及「宏替换后写回 `newEntries`」。
> 建议把递归作为**独立的一个 PR**，配 §9.2 的递归专项测试。

### 5.10 易错点汇总（§5）

| # | 易错点 | 后果 | 检测 |
|---|---|---|---|
| 1 | Swift `sorted` 不稳定 | 同 order 条目激活顺序与 ST 不同 | 同 order 多条目的 book，改输入顺序看输出是否变 |
| 2 | `JOINER` 写成 `"\u{01}\n"` | 整词匹配跨消息误命中 | 构造两条消息 `foo` / `bar`，整词匹配 `bar` |
| 3 | `depthBuffer` 用「已写入元素数」当下标 | `scanDepth` 越界错位 | `scanDepth = 5` 但聊天只有 2 条 |
| 4 | `getScore` 在 `key` 为空时返回 `0` 却仍参与分组 | 分组选错条目 | — |
| 5 | 预算用 `>` 而非 `>=` | 正好等于预算时不溢出（差异极小） | 边界构造 |
| 6 | `entry.content` 宏替换后没写回数组 | 递归扫描拿到未替换内容 | 内容里带 `{{user}}` 的递归条目 |
| 7 | `atDepth` 的 push 用 `e.depth` 而 findIndex 用 `?? 4` | 同 depth 的条目分成两组 | `depth` 未设置的 atDepth 条目 |
| 8 | 概率失败后没写入 `failedProbability` | 同一轮内重复掷骰 | `probability = 0` 的条目在第 2 轮又出现 |
| 9 | outlet 错用 `unshift` | outlet 内容顺序反了 | — |
| 10 | 忘记 `constant` 也会被 `probability`/预算影响 | 蓝灯条目在超预算时消失 | — |
| 11 | `parseRegexFromString` 用了 Swift 的 `Regex` 字面量语义 | flags 解析不同 | `/foo/i` 应大小写不敏感 |
| 12 | 整词匹配用 `\b` 而非 `\W` | 标点边界行为不同（`\b` 在 `foo-bar` 处认为有边界） | 搜索 `foo` 命中 `foo-bar` |
| 13 | 传给 WI 的 `maxContext` 用了 `openai_max_context` | 世界书预算偏大 | — |
| 14 | `chatForWI` 忘记 reverse | 扫描的是最旧的消息 | — |
| 15 | `chatForWI` 没过滤 `is_system` 消息 | 系统消息参与扫描 | — |

---

## 6. Token 计数与预算 `[P0]`

### 6.1 架构与 `TokenCounter` 协议

**来源**：`02#5.1` - `02#5.4`。

ST 的实际链路是「客户端把 `{role, content}` POST 到 ST 服务端 → 服务端用 tiktoken 计数」。
**iOS 完全离线，没有 tiktoken 词表**，因此必须分层：

```swift
public protocol TokenCounter {
    /// 单条消息的 token 数（见 §6.3 的公式）
    func count(role: ChatCompletionMessage.Role, content: String, name: String?) -> Int
    /// 一段裸文本的 token 数（用于世界书预算、squash 重算）
    func count(_ text: String) -> Int
}

public extension TokenCounter {
    func count(role: ChatCompletionMessage.Role, content: String) -> Int {
        count(role: role, content: content, name: nil)
    }
}
```

**三种实现，按精度/成本排序（v1 用第一种）**

```swift
/// A. 字节近似（v1 默认）。与 ST 的 guesstimate 完全一致。
public struct GuesstimateTokenCounter: TokenCounter {
    public static let bytesPerToken: Double = 3.35          // tokenizers.js:12
    public func count(_ text: String) -> Int {
        Int(ceil(Double(text.utf8.count) / Self.bytesPerToken))                // tokenizers.js:166-169
    }
    public func count(role: ChatCompletionMessage.Role, content: String, name: String?) -> Int {
        count(role.rawValue) + count(content) + (name.map { 1 + count($0) } ?? 0) + 4
    }
}

/// B. 内置 BPE 词表（[P2]）。见 §6.6。
public struct BPETokenCounter: TokenCounter { /* cl100k_base / o200k_base 紧凑 rank 表 */ }

/// C. 自适应校正（[P1]）。用 API 返回的 usage 校准 A 的偏差。
public final class CalibratedTokenCounter: TokenCounter {
    private var ratio: Double = 1.0      // 观测到的 实际/预估
    public func record(usagePromptTokens: Int, estimated: Int) { ... }
}
```

### 6.2 无 tokenizer 的近似算法 `[P0]`

**来源**：`02#5.4` + `tokenizers.js:12`、`:166-169`。

```swift
/// 来源：tokenizers.js:166-169
/// ★ 用 **UTF-8 字节数** 除以 3.35，向上取整。
///   不要用 String.count（grapheme cluster 数）——中文/emoji 会严重低估。
public func guesstimate(_ s: String) -> Int {
    Int(ceil(Double(s.utf8.count) / 3.35))
}
```

**精度参考（供测试基线）**

| 文本 | UTF-8 字节 | guesstimate | cl100k 实测（约） | 偏差 |
|---|---|---|---|---|
| `"Hello, world!"` | 13 | 4 | 4 | 0 |
| `"你好"` | 6 | 2 | 1–2 | +0~1 |
| 英文散文 1000 字符 | 1000 | 299 | 250–260 | +15% |
| 中文 1000 字 | 3000 | 896 | 700–1000 | ±20% |
| 代码（大量符号） | — | — | — | +30~50% |

> **结论**：`guesstimate` 对英文**高估约 10-20%**，对中文大致准。这会导致**比 ST 稍早裁剪历史**。
> 这是可接受的（宁可少发一点，也不要超上下文）。若要更准，见 §6.6。

### 6.3 ★ 消息 token 公式（必须逐字复刻）`[P0]`

**来源**：`02#5.3` + `src/endpoints/tokenizers.js:998-1023`、`tokenizers.js:884`（**已核对**）。

**服务端公式（逐字）**

```js
const tokensPerName    = queryModel.includes('gpt-3.5-turbo-0301') ? -1 : 1;
const tokensPerMessage = queryModel.includes('gpt-3.5-turbo-0301') ?  4 : 3;
const tokensPadding    = 3;

let num_tokens = 0;
for (const msg of req.body) {
    num_tokens += tokensPerMessage;
    for (const [key, value] of Object.entries(msg)) {
        num_tokens += tokenizer.encode(value).length;
        if (key === 'name') num_tokens += tokensPerName;
    }
}
num_tokens += tokensPadding;
if (queryModel.includes('gpt-3.5-turbo-0301')) num_tokens += 9;
```

**客户端修正（`tokenizers.js:884`）**

```js
if (!full) token_count -= 2;
```

`Message.createAsync` 调 `countAsync({role, content})` 且不传 `full` ⇒ **`full = false`** ⇒ **减 2**。

**推导出的单条消息净开销**

```
tokens(message) = 3                          # tokensPerMessage
                + len(encode(role))
                + len(encode(content))
                + (has_name ? 1 + len(encode(name)) : 0)
                + 3                          # tokensPadding
                - 2                          # 客户端修正
              = len(encode(role)) + len(encode(content))
                + (name ? 1 + len(encode(name)) : 0)
                + 4
```

**Swift 实现**

```swift
/// 来源：02#5.3 推导 + src/endpoints/tokenizers.js:998-1023 + tokenizers.js:884
/// ★ `+4` 净开销 = 3(per-message) + 3(padding) - 2(客户端修正)
public func messageTokens(role: String, content: String, name: String? = nil) -> Int {
    guesstimate(role)
      + guesstimate(content)
      + (name.map { 1 + guesstimate($0) } ?? 0)
      + 4
}
```

**示例**：`role = "system"`（1 token）⇒ `contentTokens + 5`。
`role = "user"` / `"assistant"` 同理（都是 1 token）。

**特例（`gpt-3.5-turbo-0301`）**

```swift
if model.contains("gpt-3.5-turbo-0301") {
    // tokensPerMessage = 4, tokensPerName = -1, 额外 +9
    tokens = 4 + enc(role) + enc(content) + (name ? enc(name) - 1 : 0) + 3 + 9 - 2
}
```
`[P2]`——该模型已下线，v1 可以不实现（但要在代码里留 TODO）。

**「整批」与「逐条求和」的差异（★ 必须知道）**

ST 是**逐条独立计数再求和**（`Message.createAsync` 每次只传一条），所以
`+tokensPadding(3)` 被**每条都加了一遍**，`-2` 也被每条都减了一遍。
真正按 API 公式算一批 N 条消息应该是 `Σ(3 + enc) + 3`。

**结论**：ST 的预算记账与「真实 API 计费」有系统性偏差（约 `+N - 3`）。
**Swift 必须复刻 ST 的记账方式**，否则裁剪点与 ST 不一致。

> **⚠️ 易错点 6.1**：`+4` 不是「固定开销 4 token」，而是 `3 + 3 - 2` 的巧合结果。
> 写代码时请把推导写在注释里，否则后人会以为写错了。
>
> **⚠️ 易错点 6.2**：`Message.token` 在 `createAsync` / `setName` / `setToolCalls` 时算一次并**缓存**
> （`02#7` 陷阱 7）。`setName` 会**重算**（带上 `name` 与 `+1`）。
> Swift 里 `Message.tokens` 是存储属性，**任何对 `content`/`name` 的写入都必须重算 tokens**。
> 建议封装 setter：
> ```swift
> extension Message {
>     mutating func setContent(_ new: String, counter: TokenCounter) {
>         content = new
>         tokens = counter.count(role: role, content: new, name: name)
>     }
>     mutating func setName(_ new: String?, counter: TokenCounter) {
>         name = new
>         tokens = counter.count(role: role, content: content, name: new)   // ★ 重算
>     }
> }
> ```
>
> **⚠️ 易错点 6.3**：`reserveBudget(3)` 的 3 token 是「回复前置符」（`<|start|>assistant<|message|>`）
> 的预留（`openai.js:1210`），**与 §6.3 的 `+4` 无关**。两者都要有。
>
> **⚠️ 易错点 6.4**：图片 `Message.tokensPerImage = 85`（`openai.js:3512`），本地近似。
> `[P2]`，v1 不支持多模态可忽略。

### 6.4 预算记账模型 `[P0]`

**来源**：`02#6.1` + `openai.js:4199-4240`（**已核对**部分）。

```swift
// 完整 API 面（都在 §2.1.1 的 ChatCompletion 上）
canAfford(m)      ⇔ 0 <= tokenBudget - m.tokens
canAffordAll(ms)  ⇔ 0 <= tokenBudget - Σ ms.tokens
reserve(x)        ⇒ tokenBudget -= (x 是 Int 还是 Tokened)
free(x)           ⇒ tokenBudget += x.tokens
add(m, id)        ⇒ if !canAfford(m) throw TokenBudgetExceededError(id)   ★ 抛错，不是丢弃
insert(m, id)     ⇒ 同上
```

**预留/释放的完整时间线（`02#6.1` 表，按时间顺序）** —— 这是排查「预算对不上」的对照表：

| # | 阶段 | 动作 | 源码 |
|---|---|---|---|
| 1 | 引导符 | `reserve(3)` | `openai.js:1210` |
| 2 | 强制 prompt | `add(worldInfoBefore/main/worldInfoAfter/charDescription/charPersonality/scenario/personaDescription)`，每条 `canAfford` 失败即抛 | `:1212-1218` |
| 3 | controlPrompts | `reserve(controlPrompts)` | `:1238` |
| 4 | 其余 system | `add(nsfw/jailbreak/userRelative/enhanceDefinitions/bias)` | `:1255-1263` |
| 5 | 工具 token | `reserve(toolTokens)` | `:1310-1316` |
| 6 | continue 前置 | `reserve(continueMessage)` | `:1330` |
| 7 | chatHistory 槽位 | `add(空 collection, index)` ⇒ **不占 token** | `:890` |
| 8 | newChatMessage | `reserve(newChatMessage)` | `:895` |
| 9 | groupNudge | `reserve(groupNudgeMessage)` | `:902` |
| 10 | continueNudge coll | `reserve(continueMessageCollection)` | `:926` |
| 11 | send_if_empty | `canAfford` 则 `insert`（追加到槽位末尾） | `:929-933` |
| 12 | **历史循环** | 从新到旧逐条，`canAfford` 失败即 `break` | `:948-1075` |
| 13 | newMainChat | `free(newChatMessage)` + `insertAtStart` | `:1078-1079` |
| 14 | 群聊 nudge | `free` + `insertAtEnd` | `:1082-1085` |
| 15 | continue nudge | `free` + `add(collection, -1)` | `:1088-1091` |
| 16 | examples | `add(dialogueExamples)` + 逐块 `canAffordAll` | `:1106-1133` |
| 17 | controlPrompts | `free(controlPrompts)` + `add(controlPrompts)` | `:1345-1346` |

> **⚠️ 易错点 6.5**：`reserve`/`free` **必须成对**。忘记 `free(newChatMessage)` 会让预算永久少一截；
> 忘记 `free(controlPrompts)` 同理。建议在 Swift 里把「预留句柄」做成
> `struct BudgetReservation { let tokens: Int }` + `defer { chat.free(reservation) }`。

### 6.5 消息裁剪与「pinned」`[P0]`

**裁剪算法本体已在 §2.6 给出**。这里只回答两个设计问题。

#### 6.5.1 「何时丢弃最旧消息」

```
每当 canAfford(chatMessage) == false 时，立即 break：
  - 当前这条消息被丢弃
  - **所有更旧的消息**也被丢弃（因为循环已 break）
  - 已插入的新消息保留
```

**没有**「跳过这条继续试更旧的」逻辑（`02#6.2` 结论 1）。
**没有** message 级截断（`02#6.2` 结论 5）。

#### 6.5.2 「如何保护 pinned 消息」—— ST 没有这个概念

**来源**：`02#6.3`（**已核对**）。

| 概念 | ST 的实现 | 位置 |
|---|---|---|
| `oai_settings.max_context_unlocked` | 预设字段，只控制 UI 是否允许把 `openai_max_context` 设到超过默认上限。**不改变组装算法** | `Default.json:53` |
| **无真正的 "unlimited context"** | — | — |
| **无消息级 "pin" 标志** | 裁剪是纯 token 预算驱动的，没有 `pinned` 字段 | — |
| `power_user.pin_examples` | 只调整 examples 与 history 的**插入顺序**（examples 优先占预算） | `openai.js:1337` |
| `power_user.strip_examples` | Text Completion 路径用；**Chat Completion 不使用** | `script.js:4738` |
| `ignoreBudget`（WI 条目字段） | 该条目**不计入** WI token 预算，且预算溢出后仍插入 | `world-info.js:5017-5026`, `:5061` |

**ST 里实际存在的三种「保护」**

1. **`newMainChat` 提前预留预算** ⇒ 无论多挤都出现在历史开头。
2. **强制 prompt 放不下就抛错**（`TokenBudgetExceededError`）⇒ 它们**不参与裁剪**，只会让整次生成失败。
3. **世界书 `ignoreBudget`** ⇒ 不受 WI 预算限制。

**如果你要做 iOS 特有的「置顶消息」（可选，需自行设计）**

建议的最小设计（**必须在 UI 上明确标注这是 iOS 版扩展行为**）：

```swift
/// iOS 扩展：用户可把某条聊天消息标记为「置顶」。
/// 语义（与 ST 的裁剪算法正交，不改变 ST 语义）：
/// 1. pinned 消息**跳过** canAfford 检查，始终插入；
/// 2. pinned 消息**不参与**「从新到旧」的预算竞争，但其余消息的可用预算 = tokenBudget - Σ pinnedTokens；
/// 3. pinned 消息之间的相对顺序保持原聊天顺序；
/// 4. 若 Σ pinnedTokens 本身就超过预算 ⇒ 抛 TokenBudgetError，提示用户取消置顶；
/// 5. pin 只影响**组装**，不影响落盘。
public struct PinnedMessagePolicy {
    public var pinnedIDs: Set<String> = []
    public var isEnabled: Bool = false        // 默认关闭，保持与 ST 一致
}
```

> **⚠️ 易错点 6.6**：如果实现了 pin，**必须**把它做成默认关闭的开关。
> 默认行为必须与 ST 完全一致，否则用户会发现「同一张卡在 iOS 和桌面版回复不一样」。

### 6.6 tiktoken 词表缺失的处理策略

**问题**：ST 依赖 `tiktoken`（服务端 WASM/native）做**精确**计数。iOS 上没有现成可用的
Swift BPE 实现，且 `cl100k_base`（~100k merges）+ `o200k_base`（~200k merges）体积不小。

**四个选项，按推荐度排序**

| 选项 | 做法 | 体积 | 精度 | 建议 |
|---|---|---|---|---|
| **A. 纯 guesstimate** | §6.2 的字节近似 | 0 | ±20% | ✅ **v1 采用** |
| **B. 自适应校正** | 每次响应读 `usage.prompt_tokens`，与本地预估求比值，用 EMA 更新 `ratio` | 0 | ±5% | ✅ **v1.1 采用**（推荐） |
| **C. 内置精简 BPE 表** | 只打包 `cl100k_base` 的 merge ranks，用紧凑二进制（约 1.5-1.7 MB），懒加载 | +1.7 MB | ±1% | `[P2]` 仅当用户反馈裁剪不准 |
| **D. 打包完整 tokenizer** | `o200k_base` + `cl100k_base` | +6 MB | ±0.5% | ❌ 不推荐（离线 App 体积敏感） |

**选项 B 的 Swift 实现（推荐在 v1.1 就上）**

```swift
/// 用 API 返回的 usage 校准 guesstimate。
/// - 每次请求前：estimatedPrompt = 本地预算账本的 Σ tokens
/// - 响应里若含 usage.prompt_tokens：ratio = ema(ratio, actual / estimated)
/// - 之后 count 时：Int(ceil(Double(raw) * ratio))
public final class CalibratedTokenCounter: TokenCounter {
    private let base = GuesstimateTokenCounter()
    private var ratio: Double = 1.0
    private let alpha: Double = 0.3                    // EMA 平滑系数

    public func record(actual: Int, estimated: Int) {
        guard estimated > 20, actual > 0 else { return }        // 样本太小不校准
        let observed = Double(actual) / Double(estimated)
        guard observed > 0.3, observed < 3.0 else { return }    // 异常值丢弃
        ratio = alpha * observed + (1 - alpha) * ratio
    }
    public func count(_ text: String) -> Int {
        Int(ceil(Double(base.count(text)) * ratio))
    }
    public func count(role: ChatCompletionMessage.Role, content: String, name: String?) -> Int {
        Int(ceil(Double(base.count(role: role, content: content, name: name)) * ratio))
    }
}
```

**`usage` 字段的位置（各协议不同）**

| 协议 | 位置 | 说明 |
|---|---|---|
| OpenAI | 最后一个 chunk 的 `usage`（需要 `stream_options: {include_usage: true}`） | ⚠️ **ST 从不发送 `stream_options`**（`03#1.3`），所以**流式下拿不到 usage**。非流式响应有 `usage` |
| OpenAI（部分自建服务） | 每个 chunk 都带 `usage` | 可以取 |
| Anthropic | `message_start.message.usage.input_tokens` + `message_delta.usage.output_tokens` | ✅ **流式下也能拿到** |
| Gemini | 每个 chunk 的 `usageMetadata.promptTokenCount` / `candidatesTokenCount` | ✅ |

> **⚠️ 易错点 6.7**：OpenAI 流式默认**不返回 usage**。若要校准，需自己加
> `stream_options: {include_usage: true}`——但这会**偏离 ST 行为**（ST 从不发送该字段）。
> 建议：**只在 Anthropic / Gemini 路径下校准**，OpenAI 路径保持纯 guesstimate，
> 或者把「发送 stream_options」做成一个默认关闭的高级选项。
>
> **⚠️ 易错点 6.8**：`ratio` 是**模型相关**的。换模型必须重置（或按 model 分别维护）。
> 建议 `CalibratedTokenCounter` 按 `model` 做 key。

### 6.7 易错点汇总（§6）

| # | 易错点 | 后果 |
|---|---|---|
| 1 | `guesstimate` 用 `String.count` 而非 `utf8.count` | 中文/emoji 严重低估 |
| 2 | 消息公式漏掉 `+4` 或写成 `+3` | 每条消息少算 1 token，长聊天裁剪点偏移 |
| 3 | 用「整批」公式（`Σ(3+enc)+3`）代替 ST 的「逐条求和」 | 预算账本与 ST 不一致 |
| 4 | `reserve`/`free` 不配对 | 预算泄漏，历史被过早裁剪 |
| 5 | 强制 prompt 放不下时静默丢弃 | 应抛错，否则模型收到残缺 system prompt |
| 6 | `Message.content` 变更后没重算 tokens | 裁剪点错误（squash 后尤其明显） |
| 7 | 裁剪时「跳过太长的单条继续试更旧的」 | 保留的消息不连续，对话逻辑断裂 |
| 8 | WI 预算的 `maxContext` 传成 `openai_max_context` | 世界书占掉 response 预算 |

---

## 7. LLM 客户端 `[P0]`

### 7.1 URL 拼接规则 `buildURL` `[P0]`

**来源**：`03#1.1`、`03#3.1`、`03#5`（**已用 Node 实测验证**）。

#### 7.1.1 实测结果（`new URL(x).toString()` 后拼接）

| 用户输入 base URL | `new URL(x).toString()` | `/chat/completions` 最终 URL |
|---|---|---|
| `https://api.openai.com/v1` | `https://api.openai.com/v1` | `https://api.openai.com/v1/chat/completions` ✅ |
| `https://api.openai.com/v1/` | `https://api.openai.com/v1/` | `https://api.openai.com/v1//chat/completions` ⚠️ **双斜杠** |
| `https://api.openai.com` | `https://api.openai.com/` | `https://api.openai.com//chat/completions` ⚠️ **双斜杠** |
| `https://api.openai.com/` | `https://api.openai.com/` | `https://api.openai.com//chat/completions` ⚠️ |
| `http://localhost:1234/v1` | `http://localhost:1234/v1` | `http://localhost:1234/v1/chat/completions` ✅ |
| `https://my.proxy.example.com/` | `https://my.proxy.example.com/` | `https://my.proxy.example.com//chat/completions` ⚠️ |
| `https://api.anthropic.com/v1/` | `https://api.anthropic.com/v1/` | `https://api.anthropic.com/v1//messages` ⚠️ |

**三条硬规则**

1. **不存在自动补 `/v1`**。`new URL()` 只做 URL 规范化，不做路径补全。
   UI 占位符明确提示用户带上 `/v1`（`openai.js:5755`：`https://api.openai.com/v1`；
   Claude 为 `https://api.anthropic.com/v1`，`:5744`）。
2. **不 trim 尾斜杠**。`trimTrailingSlash`（`src/util.js:910-912`）在整个 `chat-completions.js` 里
   **只用于 Gemini 的 `/status` 探测**（`:1910`），`/generate` 路径完全依赖 `new URL()`。
3. **「空路径变成 `/`」是真实存在的行为**：`https://api.openai.com` 会变成
   `https://api.openai.com/`，于是拼出双斜杠。用户必须自己写 `/v1`。

#### 7.1.2 Swift 实现

```swift
public enum LLMEndpoint {
    case chatCompletions      // OpenAI 系
    case messages             // Anthropic
    case geminiStream(model: String, apiVersion: String)   // Gemini
}

public enum URLBuilder {

    /// 等价于 JS `new URL(x).toString()`。
    /// ★ 关键差异：Swift 的 URL(string:).absoluteString **不会**给裸 origin 补 "/"。
    ///   必须手动补，否则 https://api.openai.com 会拼出单斜杠（与 ST 不一致）。
    static func normalizeBase(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var comps = URLComponents(string: trimmed),
              let scheme = comps.scheme, !scheme.isEmpty,
              let host = comps.host, !host.isEmpty else { return nil }

        // JS 会 lowercase host；URLComponents 不会
        comps.scheme = scheme.lowercased()
        comps.host = host.lowercased()

        // JS: 空 path ⇒ "/"（★ 这是双斜杠的根源）
        if comps.path.isEmpty { comps.path = "/" }

        // ★ 不要把 path 里的尾斜杠去掉：ST 不去，双斜杠是「正确」行为
        return comps.string
    }

    /// 来源：chat-completions.js:2281-2284, 2625-2628
    /// ★ 纯字符串拼接，**不做**任何路径合并（保留双斜杠）
    public static func buildURL(provider: ProviderProfile,
                                endpoint: LLMEndpoint,
                                isTextCompletion: Bool = false) throws -> URL {

        func join(_ base: String, _ suffix: String) -> URL? {
            URL(string: base + suffix)          // ★ 字符串拼接，不是 appendingPathComponent
        }

        switch provider {

        // ── OpenAI 兼容：{base}/chat/completions ──────────────────────
        case .openAICompatible(let base, _, _, _):
            guard let b = normalizeBase(base) else { throw LLMError.invalidBaseURL(base) }
            let suffix = isTextCompletion ? "/completions" : "/chat/completions"
            guard let url = join(b, suffix) else { throw LLMError.invalidBaseURL(base) }
            return url

        // ── Anthropic：{base}/messages ────────────────────────────────
        case .anthropic(let base, _, _):
            guard let b = normalizeBase(base) else { throw LLMError.invalidBaseURL(base) }
            guard let url = join(b, "/messages") else { throw LLMError.invalidBaseURL(base) }
            return url

        // ── Gemini：{base 去一个尾斜杠}/{version}/models/{model}:{op}?key=…&alt=sse ──
        case .gemini(let key, let model, let apiVersion, _):
            // ★ 唯一做 replace(/\/$/, '') 的分支（chat-completions.js:726, :730）
            var base = "https://generativelanguage.googleapis.com"
            if base.hasSuffix("/") { base.removeLast() }
            var comps = URLComponents(string: "\(base)/\(apiVersion)/models/\(model):streamGenerateContent")!
            comps.queryItems = [URLQueryItem(name: "key", value: key),
                                URLQueryItem(name: "alt", value: "sse")]     // ★ 流式必须 alt=sse
            guard let url = comps.url else { throw LLMError.invalidBaseURL(base) }
            return url

        case .ollama(let base):
            throw LLMError.unsupported("ollama textgen 不属于 chat 协议")   // [P2]
        }
    }

    /// CUSTOM 源：**零规范化**，直接字符串拼（chat-completions.js:2395）
    /// UI 侧只做 isValidUrl 校验（utils.js:173-180）
    static func buildCustomURL(customURL: String) -> URL? {
        URL(string: customURL + "/chat/completions")            // 可能出现三斜杠，容忍
    }
}
```

> **⚠️ 易错点 7.1（高危）**：**不要**用 `URL.appendingPathComponent("chat/completions")`。
> 它会做路径规范化（合并斜杠、转义、去掉重复分隔符），与 ST 的字符串拼接行为不一致。
> 也必须**不要**「好心」去掉用户输入里的尾斜杠。
>
> **⚠️ 易错点 7.2**：`URLComponents(string:)` 对含未转义空格的 URL 会返回 nil。
> 而 JS 的 `new URL()` 会自动把空格转成 `%20`。建议先做
> `trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)` 之类的容错，
> 或在 UI 层用 `isValidURL` 提前拦掉。
>
> **⚠️ 易错点 7.3**：Gemini 的 `model` 名要**原样**放进 path（可能是 `gemini-3.7-flash`），
> 不要 URL-encode 成 `gemini-3.7-flash` 之外的形式；`:` 分隔符前不能有斜杠。
>
> **⚠️ 易错点 7.4**：`localhost` → `127.0.0.1` 的替换**只在 textgen / kobold 路径**
> （`text-completions.js:104-106`、`:276-278`；`kobold.js:14-16`），**chat 路径不做**（`03#5`）。

### 7.2 SSE 解析状态机 `[P0]`

**来源**：`03#1.6` + `sse-stream.js:17-67`（**已逐行核对**）。

#### 7.2.1 必须复刻的 6 条分帧规则（逐条对照 `sse-stream.js`）

| # | 规则 | 源码行 | JS 代码 |
|---|---|---|---|
| 1 | **三种事件分隔符**，按左优先顺序尝试 `\r\n\r\n` → `\r\r` → `\n\n` | `:19` | `streamBuffer.split(/\r\n\r\n|\r\r|\n\n/g)` |
| 2 | **最后一段（无终止空行）留在 buffer** | `:24` | `streamBuffer = events.pop()` |
| 3 | **事件内按 `\n` / `\r` / `\r\n` 拆行** | `:29` | `eventChunk.split(/\n|\r|\r\n/g)` |
| 4 | **字段解析** `([^:]+)(?:: ?(.*))?`；只关心 `event`/`data`/`id` | `:32-51` | — |
| 5 | **`data` 行用 `\n` 拼接**（每个 data 行后追加一个 `\n`） | `:41-44` | `eventData += value; eventData += '\n'` |
| 6 | **空 `data` ⇒ 丢弃该事件**；否则**只裁掉最后一个 `\n`** | `:57-61` | — |

**规则 3 的一个重要推论**：JS 的 `split(/\n|\r|\r\n/g)` 是「左优先」，
所以 `\r\n` 会先被 `\r`（第二个候选，但第一个候选 `\n` 在该位置失败）匹配成**单字符**，
然后 `\n` 单独再匹配一次 ⇒ **产生一个空字符串元素**。
即 `"a\r\nb"` → `["a", "", "b"]`。空字符串不匹配字段正则 ⇒ 无影响。
**`\r\n` 这个候选实际上是死代码**。Swift 实现时按「`\n` 或 `\r` 各自单字符切分」即可。

**规则 1 的边界（必测）**

| 输入片段 | 是否分帧 | 说明 |
|---|---|---|
| `"...\r\n\r\n"` | ✅ | 第一候选 |
| `"...\n\n"` | ✅ | 第三候选 |
| `"...\r\r"` | ✅ | 第二候选 |
| `"...\r\n\n"` | ✅ | 位置 1 起是 `\n\n` |
| `"...\n\r\n"` | ❌ | **不分帧**！无相邻 `\n\n`，也无 `\r\n\r\n` / `\r\r` |

#### 7.2.2 Swift 实现

```swift
public struct SSEEvent: Equatable {
    public var type: String        // 默认 "message"
    public var data: String
    public var lastEventID: String
}

/// 严格复刻 sse-stream.js:10-81 的分帧器。
/// ★ 无状态机之外的假设：可以在任意字节处被切断（包括 `\r\n\r\n` 中间）。
public struct SSEFramer {

    private var buffer = ""
    private var lastEventID = ""

    public init() {}

    /// - Parameter chunk: 新增的已解码文本（可以是不完整的 UTF-8 边界——
    ///   建议在外部用 `AsyncBytes` 逐字节累积 + String(decoding:as:)，
    ///   或用 `URLSession.bytes` 的 `lines` 之外自己解码；见 §7.2.3）
    /// - Returns: 本次能完整解析出的事件
    public mutating func feed(_ chunk: String) -> [SSEEvent] {
        buffer += chunk
        var events: [SSEEvent] = []

        while true {
            // (1) 找最靠前的事件分隔符（左优先：\r\n\r\n > \r\r > \n\n）
            guard let sep = Self.firstSeparator(in: buffer) else { break }   // :19
            let eventChunk = String(buffer[buffer.startIndex..<sep.lowerBound])
            buffer = String(buffer[sep.upperBound...])                       // :24

            if let event = Self.parseEvent(eventChunk, lastEventID: &lastEventID) {  // :26-65
                events.append(event)
            }
        }
        return events
    }

    /// 左优先匹配三种分隔符，返回其 Range
    static func firstSeparator(in s: String) -> Range<String.Index>? {
        var i = s.startIndex
        while i < s.endIndex {
            let rest = s[i...]
            if rest.hasPrefix("\r\n\r\n") { return i..<s.index(i, offsetBy: 4) }
            if rest.hasPrefix("\r\r")     { return i..<s.index(i, offsetBy: 2) }
            if rest.hasPrefix("\n\n")     { return i..<s.index(i, offsetBy: 2) }
            i = s.index(after: i)
        }
        return nil
    }

    /// 来源：sse-stream.js:26-66
    static func parseEvent(_ eventChunk: String, lastEventID: inout String) -> SSEEvent? {
        var eventType = ""
        var eventData = ""

        // (3) 按 \n 或 \r 单字符切分（\r\n 候选是死代码，见 §7.2.1）
        for line in splitOnCRorLF(eventChunk) {
            // (4) 字段解析：/([^:]+)(?:: ?(.*))?/
            guard let (field, value) = parseField(line) else { continue }

            switch field {
            case "event": eventType = value                                  // :38-40
            case "data":  eventData += value; eventData += "\n"              // :41-44
            case "id":    if !value.contains("\0") { lastEventID = value }   // :45-48
            default:      break                                              // delay / 其他：忽略
            }
        }

        // (6) 空 data ⇒ 丢弃
        if eventData.isEmpty { return nil }                                  // :57
        // 只裁掉**最后一个** \n
        if eventData.hasSuffix("\n") { eventData.removeLast() }              // :59-61

        return SSEEvent(type: eventType.isEmpty ? "message" : eventType,
                        data: eventData,
                        lastEventID: lastEventID)                            // :64
    }

    /// `([^:]+)(?:: ?(.*))?` 的左优先语义：
    /// 找到**第一个非冒号字符**的下标 i；从 i 取到下一个冒号（或串尾）作为 field；
    /// 若下一个字符是 ':'，消费它，再可选消费一个空格，剩余部分为 value；否则 value = ""
    static func parseField(_ line: String) -> (String, String)? {
        guard let start = line.firstIndex(where: { $0 != ":" }) else { return nil }   // 整行都是 ':' ⇒ 无匹配
        var idx = start
        while idx < line.endIndex, line[idx] != ":" { idx = line.index(after: idx) }
        let field = String(line[start..<idx])
        guard idx < line.endIndex else { return (field, "") }        // 无冒号 ⇒ value = ""
        var v = line.index(after: idx)                               // 消费 ':'
        if v < line.endIndex, line[v] == " " { v = line.index(after: v) }   // `: ?` 只吃一个空格
        return (field, String(line[v...]))
    }

    /// JS `split(/\n|\r|\r\n/g)` 的等价物：每个 `\n` 或 `\r` 都是单字符分隔符。
    /// ★ 与 Swift 的 `split(separator:)` 不同：JS 保留空串元素。这里保留以完全对齐。
    static func splitOnCRorLF(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in s {
            if ch == "\n" || ch == "\r" { out.append(cur); cur = "" }
            else { cur.append(ch) }
        }
        out.append(cur)
        return out
    }
}
```

#### 7.2.3 消费侧

```swift
// ✅ 正确：URLSession.bytes(for:) 增量读取
let (bytes, response) = try await session.bytes(for: request)
var framer = SSEFramer()
var decoder = IncrementalUTF8Decoder()          // 见 ⚠️ 易错点 7.6

for try await byte in bytes {
    guard let chunk = decoder.append(byte) else { continue }
    for event in framer.feed(chunk) {
        if event.data == "[DONE]" { return }     // ★ 字面字符串比较，只对 OpenAI 系有效
        try handle(event)
    }
}
```

> **⚠️ 易错点 7.5**：**不要**用 `URLSession.data(for:)`（会缓冲整个响应，破坏流式）。
> 用 `URLSession.bytes(for:)` 或 `URLSessionDataDelegate.urlSession(_:dataTask:didReceive:)`。
>
> **⚠️ 易错点 7.6（Swift 特有）**：`URLSession.bytes(for:)` 给的是 `AsyncBytes`（**字节**），
> 而 SSE 是 UTF-8 文本。**多字节字符会被切在 chunk 边界上**。
> 必须做增量 UTF-8 解码：遇到不完整序列时把尾部字节留在状态里，等下一个字节。
> ```swift
> struct IncrementalUTF8Decoder {
>     private var pending: [UInt8] = []
>     mutating func append(_ byte: UInt8) -> String? {
>         pending.append(byte)
>         // 尝试解码；失败则继续累积（最多 3 字节的残片）
>         if let s = String(bytes: pending, encoding: .utf8) { pending = []; return s }
>         if pending.count >= 4 { pending = []; return nil }   // 非法序列，丢弃
>         return nil
>     }
> }
> ```
> 更简单的替代：用 `URLSession.bytes(for:).lines`？—— **不行**，`lines` 会按 `\n` 切分，
> 破坏「`\r` 也是分隔符」和「事件跨行」的语义。**必须自己分帧**。
>
> **⚠️ 易错点 7.7**：`URLSession` 默认带 `Accept-Encoding: gzip`。逐块解压是 `URLSession` 内部做的，
> 正常情况无影响；若遇到异常（有的自建服务 gzip 分帧有 bug），可显式设 `Accept-Encoding: identity`。
>
> **⚠️ 易错点 7.8**：`eventData.isEmpty` 与「空白 data」不同。
> `data: \ndata: \n` ⇒ `eventData = "\n\n"` ⇒ 裁一个 ⇒ `"\n"` ⇒ **不是空** ⇒ **会产生一个 data 为 `"\n"` 的事件**。
> 复刻这一点（不要 trim 后再判空）。
>
> **⚠️ 易错点 7.9**：取消。`Task.cancel()` 会中止 `URLSession.bytes` 的循环并抛 `CancellationError`。
> 必须在 `AsyncThrowingStream` 的 `onTermination` 里承接（§7.5）。

### 7.3 三条协议的请求构造与增量提取 `[P0]`

#### 7.3.1 统一入口签名

```swift
public protocol LLMTransport {
    /// 发起流式请求，返回增量事件流。
    func stream(_ request: GenerationRequest,
                provider: ProviderProfile) -> AsyncThrowingStream<GenerationEvent, Error>
}
```

#### 7.3.2 OpenAI 兼容路径

**请求**（`03#1.2` - `03#1.4`）

```swift
func makeOpenAIRequest(_ req: GenerationRequest,
                       base: String, apiKey: String,
                       extraHeaders: [String: String]) throws -> URLRequest {
    var r = URLRequest(url: try URLBuilder.buildURL(provider: .openAICompatible(base: base, apiKey: apiKey),
                                                    endpoint: .chatCompletions))
    r.httpMethod = "POST"
    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    // ★ 无密钥时 ST 会发 "Authorization: Bearer "（尾部一个空格）—— secrets.js:268-282
    r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    for (k, v) in extraHeaders { r.setValue(v, forHTTPHeaderField: k) }
    // ★ 长思考会被超时切断；建议禁用或设很长（03#8 第 10 条）
    r.timeoutInterval = 600
    r.httpBody = try JSONSerialization.data(withJSONObject: req.sanitizedForWire())
    return r
}
```

**内置额外头（`03#1.2`）**

| 供应商 | 头 |
|---|---|
| OpenRouter | `HTTP-Referer: https://sillytavern.app`、`X-Title: SillyTavern` |
| AI/ML API | 同上两个 |
| Fireworks | `x-session-affinity` = `HMAC-SHA256(cookieSecret, chat_id)` 前 16 个 hex |
| nano-gpt | `X-Provider`、`X-Billing-Mode: paygo` |
| Z.AI | `Accept-Language: en-US,en` |
| Azure | **`api-key`**（不是 Bearer） |

**增量文本提取（`03#1.5.3`，`openai.js:3289-3305`）**

```swift
/// 来源：openai.js:3222-3306（分支 :3289-3296 是 OpenAI 系主分支）
public func extractOpenAI(_ data: JSONValue, state: inout StreamState) -> String {
    // (1) 思维链（仅 showThoughts）：★ ?? 链，null/undefined 才继续，空串会短路
    if showThoughts {
        state.reasoning += firstChoice(data, "delta", "reasoning_content")
                        ?? firstChoice(data, "delta", "reasoning")
                        ?? ""
    }
    // (2) 正文：★ 严格按 ?? 顺序
    return firstChoice(data, "delta", "content")
        ?? firstChoice(data, "message", "content")
        ?? firstChoice(data, "text")
        ?? ""
}
```

**`??` 链的精确语义（`02#7` / `03#8` 第 3 条）**：`??` 只在 **null/undefined** 时继续，
**空字符串会立即短路返回**。Swift 里用 `String?` 表示「字段不存在」，用 `""` 表示「存在但为空」。

```swift
// ✅ 正确
func firstChoice(_ data: JSONValue, _ keys: String...) -> String? {
    // 逐级下钻 data.choices[0].<keys...>，返回 String?（字段不存在 ⇒ nil）
}
// ❌ 错误：把 "" 和 nil 混为一谈，会导致 delta.content == "" 时错误地回退到 message.content
```

> **⚠️ 易错点 7.10**：`delta.role`（首个 chunk 的 `"role":"assistant"`）**被忽略**，不产生文本。
> 因为 `delta.content` 不存在 ⇒ `??` 链回退 ⇒ 最终 `""`。不要「特殊处理 role 切换」。
>
> **⚠️ 易错点 7.11**：Mistral 的 `delta.content` 可以是**数组**
> （`openai.js:3297-3302`）：正文 = `content.map { $0.text }.filter { !$0.isEmpty }.joined()`；
> 思维链路径是 `delta.content[0].thinking[0].text`。**必须先判断是字符串还是数组**。
>
> **⚠️ 易错点 7.12**：多 swipe。`choices[0].index > 0` 表示这是第 n 个候选（`n > 1`），
> 文本要进**独立缓冲**（`openai.js:3177-3180`）。`choices` 为空数组按异常处理（`sse-stream.js:215-217`）。

#### 7.3.3 Anthropic 路径

**请求**（`03#2.1`，`chat-completions.js:230-443`）

```swift
func makeAnthropicRequest(_ req: GenerationRequest, base: String, apiKey: String,
                          beta: [String]) throws -> URLRequest {
    var r = URLRequest(url: try URLBuilder.buildURL(provider: .anthropic(base: base, apiKey: apiKey),
                                                    endpoint: .messages))
    r.httpMethod = "POST"
    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    r.setValue(apiKey, forHTTPHeaderField: "x-api-key")            // ★ 不是 Bearer
    // anthropic-beta 是**逗号连接的数组**（chat-completions.js:246-247）
    var allBeta = ["output-128k-2025-02-19", "context-1m-2025-08-07"] + beta
    r.setValue(allBeta.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
    r.timeoutInterval = 600
    r.httpBody = try JSONSerialization.data(withJSONObject: makeAnthropicBody(req))
    return r
}

/// 来源：chat-completions.js:269-279 + src/prompt-converters.js:197-313
func makeAnthropicBody(_ req: GenerationRequest) -> [String: Any] {
    var systemBlocks: [[String: String]] = []
    var messages: [[String: Any]] = []

    // (1) 开头的**连续** system 消息抽到 system 数组，并从 messages 移除
    var idx = 0
    while idx < req.messages.count, req.messages[idx].role == .system {
        systemBlocks.append(["type": "text", "text": req.messages[idx].content ?? ""])
        idx += 1
    }
    for m in req.messages[idx...] {
        var content = m.content ?? ""
        // (2) 空文本替换为**零宽空格** U+200B
        if content.isEmpty { content = "\u{200B}" }
        // (3) name 拼进文本前缀，然后删除 name
        var text = content
        if let n = m.name, !n.isEmpty { text = "\(n): \(content)" }
        var entry: [String: Any] = ["role": m.role == .assistant ? "assistant" : "user",
                                    "content": [["type": "text", "text": text]]]
        messages.append(entry)
    }
    // (4) 抽完后 messages 为空 ⇒ 插入 PROMPT_PLACEHOLDER 的 user 消息
    if messages.isEmpty { messages = [["role": "user", "content": [["type": "text", "text": PROMPT_PLACEHOLDER]]]] }

    var body: [String: Any] = [
        "messages": messages,
        "model": req.model,
        "max_tokens": req.maxTokens,                                 // ★ 必填
        "stop_sequences": req.stop,                                  // ★ 恒为数组（可为空）
        "stream": true,
    ]
    if !systemBlocks.isEmpty { body["system"] = systemBlocks }
    // ★ use_sysprompt 为假时，messages 里的 system 全部降级为 user
    body["temperature"] = req.temperature
    body["top_p"] = req.topP
    body["top_k"] = Int(req.topK)
    return body
}
```

**增量提取（`03#2.3`，`openai.js:3226-3230`）**

```swift
/// 来源：openai.js:3226-3230
/// ★ ST **完全忽略 `event:` 名**，只按 JSON 里有没有 delta.text / delta.thinking 判断。
///   本节建议按 event 名做状态机（更稳，能正确处理 error 事件），
///   但**文本提取必须与 ST 等价**。
public func extractAnthropic(_ data: JSONValue, eventName: String,
                             state: inout StreamState) -> String {
    if showThoughts { state.reasoning += data["delta"]?["thinking"]?.string ?? "" }
    return data["delta"]?["text"]?.string ?? ""
}
```

| Anthropic 事件 | `delta.type` | ST 的处理 | Swift 建议 |
|---|---|---|---|
| `message_start` | — | 返回 `""`（无副作用） | 记录 `usage.input_tokens`、`model` |
| `content_block_start` | `text`/`thinking`/`tool_use` | 返回 `""` | 记录 block index → type 映射 |
| `content_block_delta` | `text_delta` | `delta.text` → 正文 | ✅ |
| `content_block_delta` | `thinking_delta` | `delta.thinking` → **reasoning**（`showThoughts`） | ✅ |
| `content_block_delta` | `signature_delta` | ST 不处理 | `[P2]` 保存 `delta.signature` |
| `content_block_delta` | `input_json_delta` | ST 不解析 | `[P2]` 拼接 `partial_json` |
| `content_block_stop` | — | `""` | — |
| `message_delta` | — | `""`（`delta.stop_reason`） | 记录 finish reason + `usage.output_tokens` |
| `message_stop` | — | `""` | 结束标志 |
| `ping` | — | `""` | 忽略 |
| `error` | — | **ST 不识别**（会走 `getStreamingReply` 的兜底分支返回 `""`） | ✅ **建议解析为错误事件** |

#### 7.3.4 Gemini 路径

**请求**（`03#3.1` - `03#3.2`）

```swift
/// 来源：chat-completions.js:502-512, :624-666
func makeGeminiBody(_ req: GenerationRequest) -> [String: Any] {
    // (1) system 角色 → user；assistant → model
    var contents: [[String: Any]] = []
    var systemParts: [[String: String]] = []
    for m in req.messages {
        switch m.role {
        case .system:
            systemParts.append(["text": m.content ?? ""])     // 进 systemInstruction
        case .assistant:
            contents.append(["role": "model", "parts": [["text": m.content ?? ""]]])
        default:
            contents.append(["role": "user", "parts": [["text": m.content ?? ""]]])
        }
    }
    // [P2] 新模型（gemini-3.[67]-flash / gemini-3.5-flash-lite）末尾 model turn 改回 user（避免 prefill 被拒）

    // (2) 安全设置全部 OFF（src/constants.js:141-185）
    let safetyCategories = ["HARM_CATEGORY_HARASSMENT", "HARM_CATEGORY_HATE_SPEECH",
                            "HARM_CATEGORY_SEXUALLY_EXPLICIT", "HARM_CATEGORY_DANGEROUS_CONTENT",
                            "HARM_CATEGORY_CIVIC_INTEGRITY"]
    let safety = safetyCategories.map { ["category": $0, "threshold": "OFF"] }

    var generationConfig: [String: Any] = [
        "candidateCount": 1,
        "maxOutputTokens": req.maxTokens,
        "temperature": req.temperature,
        "topP": req.topP,
    ]
    if req.topK > 0 { generationConfig["topK"] = Int(req.topK) }
    if !req.stop.isEmpty { generationConfig["stopSequences"] = Array(req.stop.prefix(5)) }   // ★ 限 5 条

    var body: [String: Any] = ["contents": contents,
                               "safetySettings": safety,
                               "generationConfig": generationConfig]
    if !systemParts.isEmpty { body["systemInstruction"] = ["parts": systemParts] }
    return body
}
```

**增量提取（`03#3.4`，`openai.js:3231-3246`）**

```swift
/// 来源：openai.js:3231-3246
public func extractGemini(_ data: JSONValue, state: inout StreamState) -> String {
    let parts = data["candidates"]?[0]?["content"]?["parts"]?.array ?? []

    // (1) 图片：inlineData 且 !thought
    let inlineData = parts.filter { $0["inlineData"] != nil && $0["thought"]?.bool != true }
    if !inlineData.isEmpty {
        state.images.append(contentsOf: inlineData.compactMap { p in
            guard let mime = p["inlineData"]?["mimeType"]?.string,
                  let d = p["inlineData"]?["data"]?.string else { return nil }
            return "data:\(mime);base64,\(d)"
        })
    }
    // (2) 思维链：thought == true 的 part 的 text（★ 只取**第一个**）
    if showThoughts {
        state.reasoning += parts.first { $0["thought"]?.bool == true }?["text"]?.string ?? ""
    }
    // (3) thoughtSignature（P2）
    for p in parts where p["thoughtSignature"] != nil && p["text"]?.string != nil {
        state.signature = p["thoughtSignature"]?.string
    }
    // (4) 正文：★ 只取**第一个** !thought 且带 text 的 part（**不是拼接！**）
    return parts.first { $0["thought"]?.bool != true && $0["text"]?.string != nil }?["text"]?.string ?? ""
}
```

> **⚠️ 易错点 7.13**：Gemini 的正文是 `parts.filter{!thought}.map{text}.[0]`——**只取第一个**
> （`openai.js:3246` 的 `?.map(x => x.text)?.[0]`），**不是 `joined()`**。
> 这与非流式路径（`join('\n\n')`，`chat-completions.js:800`）**不同**，不要弄混。
>
> **⚠️ 易错点 7.14**：Gemini 的 SSE **没有 `[DONE]`**，流以连接关闭结束。
> `finishReason` 出现在最后一个 chunk 的 `candidates[0]` 上，但 **ST 不读取该字段**。
>
> **⚠️ 易错点 7.15**：Gemini 流式**必须**带 `?alt=sse`，否则上游返回**裸 JSON 数组**（不是 SSE）。

#### 7.3.5 ★ 三条路径的状态机差异表

| 维度 | OpenAI 兼容 | Anthropic | Gemini |
|---|---|---|---|
| **端点** | `{base}/chat/completions` | `{base}/messages` | `{base}/{v}/models/{m}:streamGenerateContent?key=&alt=sse` |
| **认证头** | `Authorization: Bearer {key}` | `x-api-key: {key}` + `anthropic-version: 2023-06-01` | query `?key={key}`（AI Studio） |
| **base 规范化** | `new URL(x)`，不 trim 尾斜杠 | 同左 | **额外 `.replace(/\/$/,'')`** |
| **SSE 事件名** | 无（全是默认 `message`） | **有**（`message_start`/`content_block_delta`/…） | 无 |
| **流结束标志** | 字面 `data: [DONE]` | **连接关闭** | **连接关闭** |
| **正文路径** | `choices[0].delta.content ?? message.content ?? text ?? ""` | `delta.text ?? ""` | `candidates[0].content.parts.filter{!thought}.first.text ?? ""` |
| **reasoning 路径** | `choices[filter].delta.reasoning_content ?? delta.reasoning ?? ""` | `delta.thinking ?? ""` | `parts.filter{thought}.first.text ?? ""` |
| **首 chunk** | `delta.role = "assistant"` ⇒ 被忽略 | `message_start` ⇒ 返回 `""` | 首 chunk 就是正文 |
| **finish 标志** | `choices[0].finish_reason` | `message_delta.delta.stop_reason` | `candidates[0].finishReason`（**ST 不读**） |
| **多候选** | `choices[0].index > 0` ⇒ 独立缓冲（多 swipe） | 无 | `candidates[0].index > 0` ⇒ 丢弃 |
| **usage** | 仅非流式 / 需 `stream_options` | `message_start.message.usage` + `message_delta.usage` | 每个 chunk 的 `usageMetadata` |
| **`n` 参数** | 支持 | 不支持 | `candidateCount: 1` |
| **stop 参数名** | `stop: [String]` | `stop_sequences: [String]` | `generationConfig.stopSequences`（限 5 条，长度 1-16） |
| **max tokens 参数名** | `max_tokens` / `max_completion_tokens` | `max_tokens`（**必填**） | `generationConfig.maxOutputTokens` |
| **system prompt** | messages 里的 system 消息 | 顶部连续 system 抽到 `system: [{type,text}]` | 抽到 `systemInstruction.parts` |
| **空 content 处理** | 原样发送 | 替换为零宽空格 `\u200B` | 原样 |
| **`name` 字段** | 原样传 | 拼进文本前缀后**删除** | 不支持（拼进 text） |
| **数组型 content** | 只有 Mistral | 总是数组 | 总是数组（parts） |
| **额外必需头** | — | `anthropic-beta` | — |
| **错误事件** | HTTP 非 2xx + body.error | `event: error` + `data.error`；HTTP 非 2xx ⇒ ST 包成 500 | HTTP 非 2xx ⇒ ST 包成 500 |

### 7.4 错误处理 `[P0]`

**来源**：`03#1.5.5` + `openai.js:1635-1715`（**已核对**）。

#### 7.4.1 错误消息优先级链

```swift
/// 来源：openai.js:1635-1639（getChatCompletionErrorMessage）
/// ★ 逐字复刻的优先级链：
///   error = data.error ?? data.detail?.error
///   message = (error is String) ? error : (error.message || error.code || error.type)
///   result  = message || (!response.ok && statusText) || "Unknown error"
public func errorMessage(from data: JSONValue?, response: HTTPURLResponse?) -> String {
    // (1) 取 error 对象：data.error 优先，其次 data.detail.error
    let errorValue = data?["error"] ?? data?["detail"]?["error"]

    // (2) 若 error 是字符串，直接用
    if let s = errorValue?.string, !s.isEmpty { return s }

    // (3) 否则按 message → code → type 顺序取第一个「非空」值（★ JS 的 || 是 falsy 判断）
    if let msg = errorValue?["message"]?.string, !msg.isEmpty { return msg }
    if let code = errorValue?["code"]?.string, !code.isEmpty { return code }
    if let type = errorValue?["type"]?.string, !type.isEmpty { return type }

    // (4) 回退到 statusText（Swift 的等价物）
    if let r = response, !(200..<300).contains(r.statusCode) {
        return HTTPURLResponse.localizedString(forStatusCode: r.statusCode)
    }
    // (5) 再回退到 data.message（Gemini 风格，见下方「兼容形状」）
    if let m = data?["message"]?.string, !m.isEmpty { return m }

    return "Unknown error"
}
```

**上游可能返回的三种错误形状（`03#1.5.5`）**

```jsonc
{ "error": { "message": "...", "type": "...", "code": "...", "param": "...", "metadata": {...} } }   // OpenAI 系
{ "detail": { "error": {...} } }                                                                     // 某些代理
{ "message": "..." }                                                                                 // Gemini 风格
```

#### 7.4.2 配额错误与 401/429 的识别

```swift
public enum LLMError: Error, Equatable {
    case invalidBaseURL(String)
    case http(status: Int, message: String, body: String?)
    case quotaExceeded(message: String)                  // 429 + insufficient_quota / quota_error
    case unauthorized(message: String)                   // 401 / 403
    case rateLimited(retryAfter: TimeInterval?, message: String)  // 429（非配额）
    case moderation(reasons: [String], flaggedInput: String?)
    case contextLengthExceeded(message: String)
    case noCandidates(message: String)                   // Gemini 空候选
    case decoding(String)
    case transport(Error)
    case cancelled
    case unsupported(String)
}

/// 来源：03#1.5.5 + openai.js:1689-1715（checkQuotaError / checkModerationError）
public func classify(_ body: JSONValue?, status: Int, retryAfter: TimeInterval?) -> LLMError {
    let msg = errorMessage(from: body, response: nil)

    // (1) 配额错误：非流式路径判定 = 429 && error.type == "insufficient_quota"
    //     流式路径判定 = body.quota_error == true（ST 服务端加的标记）
    if body?["quota_error"]?.bool == true {
        return .quotaExceeded(message: msg)
    }
    if status == 429, body?["error"]?["type"]?.string == "insufficient_quota" {
        return .quotaExceeded(message: msg)
    }
    // (2) 内容审核
    if let m = body?["error"]?["message"]?.string, m.contains("requires moderation") {
        let reasons = body?["error"]?["metadata"]?["reasons"]?.array?.compactMap(\.string) ?? []
        return .moderation(reasons: reasons, flaggedInput: body?["error"]?["metadata"]?["flagged_input"]?.string)
    }
    // (3) 401/403
    if status == 401 || status == 403 { return .unauthorized(message: msg) }
    // (4) 429（非配额）
    //     ★ 注意：ST 服务端会把上游 401 **改写成 400**（forwardFetchResponse，src/util.js:741-743）
    //       直连上游时**不需要**模仿这个改写（03#8 第 5 条）
    if status == 429 { return .rateLimited(retryAfter: retryAfter, message: msg) }
    // (5) 上下文超长（各家措辞不同，做启发式匹配）
    let lower = msg.lowercased()
    if lower.contains("context length") || lower.contains("too many tokens")
        || lower.contains("maximum context") || lower.contains("token limit") {
        return .contextLengthExceeded(message: msg)
    }
    return .http(status: status, message: msg, body: nil)
}
```

**⚠️ ST 的一个重要怪癖（必须知道，但 Swift 应做得更好）**

`tryParseStreamingError`（`openai.js:1648-1679`）把 `throw` **写在 `try` 块内部**，
而 `catch` 是裸的 `catch { /* No JSON. Do nothing. */ }`：

```js
try {
    const data = JSON.parse(decoded);
    if (data.error) { toastr.error(...); throw new Error(data); }   // ← 这个 throw 被下面的 catch 吃掉
    ...
} catch { /* No JSON. Do nothing. */ }
```

**结论：ST 的流式错误检测实际上永远不会抛错**，只弹一个 toast，生成会「静默结束」。
Swift 侧**不要**复刻这个 bug——应当把流式错误 body 解析成 `LLMError` 并
`throw` 进 `AsyncThrowingStream`，让 UI 能明确显示失败原因。

**非流式路径的 ST 行为（`03#1.5.5`）**

- ST 服务端把上游错误正文**丢弃**，只把 `statusText` 当消息，并返回 **HTTP 200** + `{error: {message}, quota_error}`。
- **Swift 直连上游，可以直接读 body**，比 ST 拿到的信息更多（`03#8` 第 5 条）。
  这是**有意的改进**，不是偏离。

#### 7.4.3 其他错误场景

| 场景 | 处理 |
|---|---|
| 网络层异常（连接被拒） | ST 返回 502 + `Connection refused: ` 前缀。Swift 直接 `URLSession` 的 `URLError` 包成 `.transport` |
| Gemini 空候选 / 被拦截 | `{error: {message}}`，message 里含 `promptFeedback.blockReason`。Swift 识别 `candidates` 缺失并给明确提示 |
| Claude 上游非 2xx | ST 包成 HTTP 500 + `{error: true}`，详情只写日志。Swift 保留原文 |
| 超时 | 流式请求**禁用** `timeoutIntervalForRequest`（或设 600s），否则长思考被切断（`03#8` 第 10 条） |

### 7.5 流式增量回调设计 `[P0]`

**建议用 `AsyncThrowingStream<GenerationEvent, Error>`。**

```swift
/// 一次生成过程中向 UI 推送的所有事件。
public enum GenerationEvent {
    /// 请求已发出、收到首字节
    case started(model: String)

    /// ★ 正文增量（可能是 0..n 个字符；ST 的增量粒度由上游决定）
    case delta(String)

    /// 思维链增量（仅 showThoughts；**不能**混进正文）
    case reasoningDelta(String)

    /// 图片（data URL）；[P2]
    case image(String)

    /// 思维链签名；[P2]
    case signature(String)

    /// token 用量（Anthropic/Gemini 流式可得；OpenAI 需 stream_options）
    case usage(promptTokens: Int?, completionTokens: Int?)

    /// 正常结束
    case finished(reason: FinishReason)
}

public enum FinishReason: Equatable {
    case stop                  // 上游 stop / end_turn / STOP
    case length                // max tokens / MAX_TOKENS
    case contentFilter         // SAFETY / RECITATION / content_filter
    case doneMarker            // 收到 [DONE]
    case connectionClosed      // 连接关闭（Anthropic/Gemini 的正常结束）
    case cancelled             // 用户取消
    case unknown(String)
}
```

**生产者实现骨架**

```swift
public final class URLSessionLLMClient: LLMTransport {

    private let session: URLSession
    private var currentTask: Task<Void, Never>?

    public func stream(_ req: GenerationRequest,
                       provider: ProviderProfile) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try self.makeRequest(req, provider: provider)
                    let (bytes, response) = try await self.session.bytes(for: request)

                    // (1) HTTP 状态检查（★ 在流开始前就能拿到状态码）
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        // 错误 body 需要读完（可能只有几十字节）
                        var body = Data()
                        for try await b in bytes { body.append(b); if body.count > 64 * 1024 { break } }
                        let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
                        throw classify(JSONValue(json), status: http.statusCode,
                                       retryAfter: http.value(forHTTPHeaderField: "Retry-After")
                                           .flatMap(Double.init))
                    }

                    continuation.yield(.started(model: req.model))

                    // (2) 分帧 + 解码 + 提取
                    var framer = SSEFramer()
                    var decoder = IncrementalUTF8Decoder()
                    var state = StreamState()
                    var sawDone = false

                    for try await byte in bytes {
                        try Task.checkCancellation()                       // ★ 支持取消
                        guard let chunk = decoder.append(byte) else { continue }
                        for event in framer.feed(chunk) {
                            // ★ [DONE] 是字面字符串比较，只对 OpenAI 系有效
                            if event.data == "[DONE]" { sawDone = true; break }

                            guard let json = try? JSONValue.parse(event.data) else {
                                // ★ JSON 解析失败要走错误探测，而不是崩（03#1.5.1 第 2 条）
                                if let err = detectStreamingError(event.data) { throw err }
                                continue
                            }
                            // ★ 若 data 里带 error/detail/message ⇒ 抛错（ST 只弹 toast，我们做得更好）
                            if let err = detectStreamingError(json) { throw err }

                            let text: String
                            switch provider {
                            case .openAICompatible(_, _, _, let ex):
                                text = extractOpenAI(json, extractor: ex, state: &state)
                            case .anthropic:
                                text = extractAnthropic(json, eventName: event.type, state: &state)
                            case .gemini:
                                text = extractGemini(json, state: &state)
                            case .ollama:
                                throw LLMError.unsupported("ollama NDJSON")
                            }
                            if !text.isEmpty { continuation.yield(.delta(text)) }
                            if let r = state.takePendingReasoning() { continuation.yield(.reasoningDelta(r)) }
                            if let u = state.takePendingUsage() { continuation.yield(.usage(promptTokens: u.0, completionTokens: u.1)) }
                        }
                        if sawDone { break }
                    }

                    continuation.yield(.finished(reason: sawDone ? .doneMarker : .connectionClosed))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.finished(reason: .cancelled))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            self.currentTask = task
            // ★ 消费端取消时中止网络任务
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func cancel() { currentTask?.cancel() }
}
```

**消费端（ViewModel）**

```swift
@MainActor
final class ChatViewModel: ObservableObject {
    @Published var streamingText: String = ""
    @Published var reasoningText: String = ""
    @Published var errorText: String?

    private var streamTask: Task<Void, Never>?

    func send() {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                let req = try await self.pipeline.buildRequest(type: .normal)
                for try await event in self.client.stream(req, provider: self.provider) {
                    switch event {
                    case .started:                 self.streamingText = ""
                    case .delta(let s):            self.streamingText += s
                    case .reasoningDelta(let s):   self.reasoningText += s
                    case .usage(let p, let c):     self.pipeline.tokenCounter.record(actual: p ?? 0, estimated: self.pipeline.lastEstimated)
                    case .finished(let reason):    try await self.pipeline.persist(streamingText: self.streamingText, reason: reason)
                    default: break
                    }
                }
            } catch {
                self.errorText = (error as? LLMError).map(describe) ?? error.localizedDescription
            }
        }
    }

    func stop() { streamTask?.cancel() }
}
```

> **⚠️ 易错点 7.16**：`AsyncThrowingStream` 的 `onTermination` **必须**设置，否则用户返回上一页时
> 网络请求会继续跑到结束（浪费流量 + 可能落盘到错误的地方）。
>
> **⚠️ 易错点 7.17**：`reasoningDelta` 与 `delta` **必须分开**。ST 的 `state.reasoning` 与
> `state.text` 是两个独立缓冲（`openai.js:3224`、`:3290`），reasoning **不进入正文**。
>
> **⚠️ 易错点 7.18**：`state` 是**每次请求一份**（不是每次 chunk 一份）。`reasoning` 要累积，
> 但推送时应该推**增量**（`takePendingReasoning()` 取走并清空）。
>
> **⚠️ 易错点 7.19**：Swift 5 模式下 `AsyncThrowingStream` 的 `continuation` 可以跨 task 使用；
> 若编译器在 Swift 6 模式下报并发警告，用 `@unchecked Sendable` 包装 continuation，
> **不要**为了消警告去引入 `actor`（会带来不必要的复杂度）。

### 7.6 易错点汇总（§7）

| # | 易错点 | 后果 |
|---|---|---|
| 1 | 用 `appendingPathComponent` 拼 URL | 双斜杠被规范化掉，与 ST 不一致（且某些自建服务依赖该行为） |
| 2 | 自动给 base 补 `/v1` | 用户填了 `/v1` 时变成 `/v1/v1/...` |
| 3 | 去掉用户输入的尾斜杠 | 与 ST 的双斜杠行为不一致 |
| 4 | 用 `URLSession.data(for:)` | 完全失去流式 |
| 5 | 逐 chunk 用 `String(data:encoding:.utf8)` 解码 | 多字节字符跨 chunk 时乱码或丢字 |
| 6 | SSE 分帧不保留跨 chunk buffer | 事件在任意字节处被切断时解析失败 |
| 7 | 事件分隔符只处理 `\n\n` | 上游用 `\r\n\r\n` 时完全不工作 |
| 8 | data 拼接用 `""` 而非 `"\n"` | 多行 data（少见但存在）被拼错 |
| 9 | 裁掉所有尾部 `\n` 而非只裁一个 | 多行 data 内容被改变 |
| 10 | 把空 data 事件当成有效事件 | 注入空 delta |
| 11 | `??` 链用 `if let x = a, !x.isEmpty` 实现 | 空串 `delta.content == ""` 时错误回退到 `message.content` |
| 12 | Gemini 正文用 `joined()` 而非 `first` | 多 part 时文本重复 |
| 13 | Gemini 忘记 `?alt=sse` | 上游返回裸 JSON 数组，解析全错 |
| 14 | OpenAI 流式忘记识别 `[DONE]` | 流不会正常结束（等连接关闭，某些服务不关闭） |
| 15 | Anthropic 用 `Authorization: Bearer` | 401 |
| 16 | Anthropic 忘记把顶部 system 抽到 `system` 数组 | 上游报错（system role 不在 messages 里允许） |
| 17 | Anthropic 的 `max_tokens` 没填 | 必填字段缺失 ⇒ 400 |
| 18 | Gemini `stopSequences` 超过 5 条 / 单条超 16 字符 | 400 |
| 19 | 流式请求沿用默认 60s 超时 | 长思考被切断 |
| 20 | 401/429 的错误消息只读 `data.error.message` | 代理返回 `detail.error` 或 `message` 时显示 "Unknown error" |
| 21 | 复刻 ST 的「流式错误只弹 toast 不抛错」 | 生成静默失败，用户不知道为什么 |

---

## 8. 端到端生成流程 `[P0]`

### 8.1 时序（用户点「发送」→ 落盘）

```
[UI] 用户点发送
  │
  ├─ 1. GenerationPipeline.buildRequest(type: .normal)          §8.2 step 1-3
  │       ├─ 组装 GenerationContext（卡字段 / persona / 聊天 / 设置）
  │       ├─ macroEngine 替换卡字段
  │       ├─ parseMesExamples + setOpenAIMessageExamples        §3
  │       └─ WorldInfoEngine.checkWorldInfo                     §5
  │
  ├─ 2. PromptAssembler.assemble(context)                       §2
  │       └─ → [ChatCompletionMessage]（= 请求体 messages）
  │
  ├─ 3. LLMClient.stream(request, provider)                     §7
  │       └─ AsyncThrowingStream<GenerationEvent, Error>
  │
  ├─ 4. UI 增量渲染（delta / reasoningDelta）                    §7.5
  │
  └─ 5. 落盘 ChatStore.append(assistantMessage)                 §8.3
```

### 8.2 Swift 函数级流程

```swift
/// 一次生成的完整编排。所有依赖通过 init 注入，便于测试。
public final class GenerationPipeline {

    // ---- 依赖 ----
    private let macroEngine: MacroEngine                  // §4
    private let tokenCounter: TokenCounter                // §6
    private let worldInfoEngine: WorldInfoEngine          // §5
    private let assembler: PromptAssembler                // §2
    private let client: LLMTransport                      // §7
    private let chatStore: ChatStore                      // 落盘
    private let settings: AppSettings

    /// 供 §6.6 的自适应校准使用
    private(set) var lastEstimatedPromptTokens: Int = 0

    // ═══════════════════════════════════════════════════════════════
    // 步骤 1-3：构造请求（不触网）
    // ═══════════════════════════════════════════════════════════════
    public func buildRequest(type: GenerationType,
                             chatSession: ChatSession,
                             dryRun: Bool = false) async throws -> GenerationRequest {

        // ── step 1a: 卡字段（★ 已经过 baseChatReplace 的宏替换）─────────
        //   来源：script.js:3402-3494
        let card = chatSession.characterCard
        let fields = CardFields(
            description:   macroEngine.substitute(card.description, replaceCharacterCard: false),
            personality:   macroEngine.substitute(card.personality, replaceCharacterCard: false),
            scenario:      macroEngine.substitute(chatSession.scenario ?? card.scenario,
                                                  replaceCharacterCard: false),
            persona:       macroEngine.substitute(settings.personaDescription ?? "",
                                                  replaceCharacterCard: false),
            systemPrompt:  macroEngine.substitute(card.systemPrompt, replaceCharacterCard: false),
            jailbreak:     macroEngine.substitute(card.postHistoryInstructions,
                                                  replaceCharacterCard: false),
            charDepthPrompt: macroEngine.substitute(card.depthPromptPrompt ?? "",
                                                    replaceCharacterCard: false),
            creatorNotes:  macroEngine.substitute(card.creatorNotes,
                                                  replaceCharacterCard: false),
            mesExamples:   macroEngine.substitute(card.mesExample, replaceCharacterCard: false),
            version:       card.characterVersion
        )

        // ── step 1b: 把 fields 灌进 macroEngine.context（供后续宏使用）──
        macroEngine.context.apply(fields: fields,
                                  userName: settings.userName,      // name1
                                  charName: card.name,              // name2
                                  groupMembers: chatSession.groupMembers,
                                  chat: chatSession.messages,
                                  maxContextTokens: settings.maxContextTokens,
                                  maxResponseTokens: settings.maxResponseTokens,
                                  localVariables: chatSession.variables)

        // ── step 1c: 世界书（★ 需要 macroEngine 已就绪）─────────────────
        //   来源：script.js:4624-4635 + world-info.js:4709
        let scanBuffer = makeScanBuffer(chat: chatSession.messages,      // §5.3.1
                                        includeNames: settings.wi.includeNames)
        let globalScanData = GlobalScanData(
            personaDescription: fields.persona,
            characterDescription: fields.description,
            characterPersonality: fields.personality,
            characterDepthPrompt: fields.charDepthPrompt,
            scenario: fields.scenario,
            creatorNotes: fields.creatorNotes,
            trigger: GenerationType.triggers.contains(type) ? type.rawValue : "normal")

        let sortedEntries = worldInfoEngine.getSortedEntries(               // §5.4
            globalLore: chatSession.activatedGlobalBooks.flatMap(\.entries),
            characterLore: card.characterBook?.entries ?? [],
            chatLore: chatSession.chatBook?.entries ?? [],
            personaLore: chatSession.personaBook?.entries ?? [],
            strategy: settings.wi.characterStrategy)

        let wiResult = await worldInfoEngine.checkWorldInfo(                 // §5.5
            chatNewestFirst: scanBuffer,
            maxContext: settings.maxContextTokens - settings.maxResponseTokens,   // ★ 见易错点 5.24
            global: globalScanData,
            settings: settings.wi,
            sortedEntries: sortedEntries,
            extensionPrompts: chatSession.extensionPrompts,
            macroEngine: macroEngine,
            tokenCounter: tokenCounter,
            timedStore: &chatSession.timedStore)                             // [P2]

        // ── step 1d: WI 结果落位（§2.5）────────────────────────────────
        //   worldInfoBefore/After → PromptSpec.content（在 assembler 里做）
        //   depthEntries → extensionPrompts.set("customDepthWI_{d}_{r}", ...)
        for d in wiResult.depthEntries {
            chatSession.extensionPrompts.set(
                InjectID.customWIDepth(depth: d.depth, role: d.role.rawValue),
                value: d.entries.joined(separator: "\n"),
                position: .inChat, depth: d.depth, scan: false, role: d.role)
        }
        //   outlets → extensionPrompts（position: .none）
        for (key, values) in wiResult.outlets {
            chatSession.extensionPrompts.set(InjectID.customWIOutlet(key),
                                             value: values.joined(separator: "\n"),
                                             position: .none, depth: 0)
        }
        //   EM 条目 → mesExamplesArray（★ 先 baseChatReplace 再 parseMesExamples）
        //   来源：script.js:4638-4655
        var mesExamplesArray = parseMesExamples(fields.mesExamples, isInstruct: false,   // §3.1
                                                exampleSeparator: settings.exampleSeparator)
        for em in wiResult.emEntries {
            let formatted = macroEngine.substitute(em.content, replaceCharacterCard: false)
            let cleaned = parseMesExamples(formatted, isInstruct: false,
                                           exampleSeparator: settings.exampleSeparator)
            if em.isBefore { mesExamplesArray.insert(contentsOf: cleaned, at: 0) }
            else { mesExamplesArray.append(contentsOf: cleaned) }
        }

        // ── step 2: 示例消息（§3.2 / §3.3）────────────────────────────
        let messageExamples = setOpenAIMessageExamples(
            mesExamplesArray,
            appendNamesForGroup: settings.appendNamesForGroup,
            userName: settings.userName,          // ★ 必须是**宏替换后**的真实名字
            charName: card.name,
            groupBotNames: chatSession.groupMembers.map(\.name),
            isGroupChat: chatSession.isGroup)

        // ── step 3: 组装（§2.3 的 22 步）──────────────────────────────
        let wireMessages = try await assembler.assemble(
            promptManager: chatSession.promptManager,
            wiResult: wiResult,
            fields: fields,
            runtime: RuntimeData(type: type,
                                 bias: chatSession.bias,
                                 quietPrompt: chatSession.quietPrompt,
                                 messages: chatSession.messages,      // 正序（旧→新）
                                 messageExamples: messageExamples,
                                 pinExamples: settings.pinExamples),
            settings: settings,
            dryRun: dryRun)

        lastEstimatedPromptTokens = wireMessages.reduce(0) {
            $0 + tokenCounter.count(role: $1.role, content: $1.content ?? "", name: $1.name)
        } + 3   // reply priming

        return GenerationRequest(messages: wireMessages,
                                 model: settings.model,
                                 temperature: settings.temperature,
                                 /* … 采样参数 … */
                                 maxTokens: settings.maxResponseTokens,
                                 maxContextTokens: settings.maxContextTokens,
                                 provider: settings.provider)
    }

    // ═══════════════════════════════════════════════════════════════
    // 步骤 4-5：调用 + 流式渲染 + 落盘
    // ═══════════════════════════════════════════════════════════════
    public func generate(type: GenerationType,
                         chatSession: ChatSession,
                         onEvent: @escaping (GenerationEvent) -> Void) async throws -> String {

        let request = try await buildRequest(type: type, chatSession: chatSession)

        // ── step 4: 流式 ─────────────────────────────────────────────
        var fullText = ""
        var reasoning = ""
        var finish: FinishReason = .unknown("no finish event")

        for try await event in client.stream(request, provider: request.provider) {
            onEvent(event)                                  // → UI
            switch event {
            case .delta(let s):          fullText += s
            case .reasoningDelta(let s): reasoning += s
            case .usage(let p, let c):
                // §6.6 自适应校准
                if let p, lastEstimatedPromptTokens > 0 {
                    (tokenCounter as? CalibratedTokenCounter)?
                        .record(actual: p, estimated: lastEstimatedPromptTokens)
                }
            case .finished(let r):       finish = r
            default: break
            }
        }

        // ── step 5: 落盘（§8.3）──────────────────────────────────────
        try await chatStore.appendAssistant(text: fullText,
                                            reasoning: reasoning,
                                            finish: finish,
                                            chatSession: chatSession)
        return fullText
    }
}
```

### 8.3 落盘

```swift
public protocol ChatStore {
    /// 追加一条 assistant 消息。
    /// 落盘字段（参考 04 文档的 chat.jsonl 结构）：
    /// {
    ///   "name": "<char name>",
    ///   "is_user": false,
    ///   "is_system": false,
    ///   "send_date": <ms>,
    ///   "mes": "<fullText>",
    ///   "extra": { "reasoning": "<reasoning>", "gen_finished": "<finish reason>" },
    ///   "swipe_id": 0,
    ///   "swipes": ["<fullText>"],
    ///   "swipe_info": [{ "send_date": …, "gen_finished": … }]
    /// }
    func appendAssistant(text: String, reasoning: String,
                         finish: FinishReason, chatSession: ChatSession) async throws

    /// 更新 chat_metadata（timedWorldInfo / variables / lastInContextMessageId 等）
    func updateMetadata(_ patch: ChatMetadataPatch, chatSession: ChatSession) async throws
}
```

**落盘必须一起写的元数据**

| 字段 | 何时写 | 来源 |
|---|---|---|
| `chat_metadata.variables` | 宏引擎跑过 `{{setvar}}` 后 | §4.6 |
| `chat_metadata.chat_id_hash` | 首次 `{{pick}}` 时 | §4.5.2 |
| `chat_metadata.timedWorldInfo.{sticky,cooldown}` | sticky/cooldown 生效时 | §5.8.3 `[P2]` |
| `chat_metadata.lastInContextMessageId` | 裁剪后（供 `{{firstIncludedMessageId}}`） | §4.4.3 `[P2]` |

> **⚠️ 易错点 8.1**：`{{pick}}` 的 `chat_id_hash` **必须持久化**，否则重命名/分支切换后
> pick 的结果会变（`macros.js:317-319` 的注释明确说了这一点）。
>
> **⚠️ 易错点 8.2**：落盘**必须**在流式**完全结束之后**（包括 `finished` 事件）。
> 中途取消时，已生成的部分要不要落盘是一个**产品决策**：
> ST 的行为是「取消后保留已生成内容」。建议：取消时也落盘，但标记 `gen_finished = "cancelled"`。
>
> **⚠️ 易错点 8.3**：`chatStore.appendAssistant` 必须是**幂等**的（用 message id 去重），
> 否则重试/超时会导致重复消息。

---

## 9. 测试清单 `[P0]`

### 9.1 宏替换测试（§4）

| # | 用例 | 输入 | 期望 | 断言点 |
|---|---|---|---|---|
| 1 | 基本替换 | ctx.user = "Alice"；`"Hi {{user}}"` | `"Hi Alice"` | — |
| 2 | 大小写不敏感 | `"{{USER}} {{Char}}"` | 都替换 | `.caseInsensitive` |
| 3 | **一级递归** | description = `"I am {{char}}"`，char = `"Bob"`；输入 `"{{description}}"` | `"I am Bob"` | ★ **env 顺序**：description 在 char 之前 |
| 4 | 反向不递归 | char = `"{{description}}"`；输入 `"{{char}}"` | `"{{description}}"`（不递归） | ★ char 在 description 之后 |
| 5 | 不递归（跨批次） | 输入 `"{{random:{{user}},x}}"` | 展开 `{{user}}` 后**不再**跑 random | 单趟语义 |
| 6 | `{{trim}}` 吃换行 | `"a\n\n{{trim}}\n\nb"` | `"ab"` | — |
| 7 | `{{//}}` 跨行 | `"a{{// x\ny }}b"` | `"ab"` | `[\s\S]` |
| 8 | `{{roll:20}}` | — | `1...20` 的字符串 | 纯数字 → `1dN` |
| 9 | `{{roll:abc}}` | — | `""` | 非法公式 |
| 10 | `{{random:a,b,c}}` | 注入固定 RNG | 三个值都可能出现 | 注入 `RandomSource` |
| 11 | `{{random::a, b}}` | — | 返回 `"a"` 或 `" b"`（**保留空格**） | ★ `::` 模式不 trim |
| 12 | `{{random:a\,b,c}}` | — | 第一项是 `"a,b"` | `\,` 转义 |
| 13 | `{{pick}}` 确定性 | 同一 content 跑两次 | 结果相同 | 固定 `chatIdHash` + `rawContentHash` |
| 14 | `{{pick}}` 位置敏感 | 同一宏出现在不同 offset | 结果**可能**不同 | offset 参与种子 |
| 15 | `{{getvar}}`/`{{setvar}}` | `"{{setvar::x::1}}{{getvar::x}}"` | `"1"` | setvar 展开 `""` |
| 16 | `{{incvar}}` | x = 5；`"{{incvar::x}}"` | `"6"` | ★ 返回**新值** |
| 17 | `replaceCharacterCard: false` | ctx.charPrompt = "X"；`"{{charPrompt}}"` | `"{{charPrompt}}"`（**保留**） | ★ 不注册而非注册空串 |
| 18 | 内容清空后 break | `"{{trim}}{{user}}"`（trim 吃掉全部） | `""` | 短路 |
| 19 | `getStringHash` 移植 | `getStringHash("test")` | 与 JS 相同值 | ★ 用已知向量 |
| 20 | `getStringHash` emoji | `getStringHash("👋")` | 与 JS 相同值 | ★ `utf16` 而非 `Character` |
| 21 | `{{time}}` locale | 固定 locale | `3:42 PM` 格式 | `timeStyle = .short` |
| 22 | `{{isodate}}` 非公历 locale | 泰历 locale | 仍是 `2026-09-14` | ★ `en_US_POSIX` |
| 23 | 无 `{{` 短路 | `"<USER> hi"` | 替换 `<USER>` | 尖括号宏不被短路跳过 |

**测试基建**：`MacroEngine` 必须支持注入 `RandomSource` 和固定 `Date`。

```swift
struct FixedRandomSource: RandomSource {
    var values: [Double]; var index = 0
    mutating func nextUnit() -> Double { defer { index += 1 }; return values[index % values.count] }
}
```

### 9.2 世界书匹配测试（§5）

| # | 用例 | 输入 | 期望 |
|---|---|---|---|
| 1 | 子串匹配 | key = `["foo"]`，扫描文本含 `foobar` | 命中 |
| 2 | 大小写不敏感（默认） | key = `["FOO"]`，文本 `foo` | 命中 |
| 3 | 大小写敏感 | `entry.caseSensitive = true`，key = `["FOO"]`，文本 `foo` | 不命中 |
| 4 | 整词匹配 | `matchWholeWords = true`，key = `["foo"]`，文本 `foo-bar` | **命中**（`\W` 边界） |
| 5 | 整词不命中 | 同上，文本 `foobar` | **不命中** |
| 6 | 整词多词退化 | key = `["foo bar"]`，文本 `xfoo barx` | **命中**（多词退化为子串） |
| 7 | 正则 key | key = `["/fo+/i"]`，文本 `FOOO` | 命中 |
| 8 | 正则覆盖大小写 | key = `["/FOO/"]`（无 `i`），`caseSensitive = false`，文本 `foo` | **不命中**（正则优先，忽略 entry 设置） |
| 9 | 非法正则 | key = `["/foo/bar/"]` | 退化为普通子串匹配 |
| 10 | **哨兵边界** | 消息 A = `"foo"`，消息 B = `"bar"`，key = `["foobar"]`，`matchWholeWords = true` | **不命中**（`\n\x01` 分隔） |
| 11 | 次关键词 `AND_ANY` | 2 个次关键词，只有第 2 个命中 | 命中 |
| 12 | 次关键词 `AND_ALL` | 2 个，只有 1 个命中 | 不命中 |
| 13 | 次关键词 `NOT_ANY` | 2 个都不命中 | 命中 |
| 14 | 次关键词 `NOT_ALL` | 2 个都命中 | 不命中 |
| 15 | 空次关键词 | `keysecondary = []`，`selective = true` | 直接激活（`hasSecondary == false` 分支） |
| 16 | **稳定排序** | 3 个条目同 `order`，不同插入顺序 | 输出顺序 = 输入顺序（★ **必测**） |
| 17 | `order` 降序 → 注入升序 | order = [1, 100, 50] | `worldInfoBefore` 字符串里的顺序是 1, 50, 100 |
| 18 | `chatLore` 前置 | chatLore order = 1，charLore order = 100 | chatLore 在前 |
| 19 | `constant` | `constant = true`，key 完全不匹配 | 激活 |
| 20 | `constant` 被 `disable` 拦住 | `constant = true, disable = true` | 不激活 |
| 21 | `@@dont_activate` | 内容首行 `@@dont_activate`，key 匹配 | 不激活 |
| 22 | `@@activate` | key 不匹配 | 激活 |
| 23 | `@@@activate` 转义 | 内容首行 `@@@activate` | **不**无条件激活（且 `@@activate` 不出现在 content 里） |
| 24 | 预算溢出 | budget = 10，两个各 8 token 的条目 | 只保留第一个（按 order/下标） |
| 25 | 预算 `>=` | 正好等于 budget | **溢出**（不保留） |
| 26 | `ignoreBudget` | 溢出处有 `ignoreBudget = true` 的条目 | 它**仍然**被激活 |
| 27 | `triggers` 白名单 | `triggers = ["continue"]`，type = `normal` | 跳过 |
| 28 | `probability = 0` | — | 一定失败，且写入 `failedProbability` |
| 29 | `probability` 跨轮不重掷 | `recursive = true`，`probability = 50`，注入固定 RNG 使第 1 轮失败 | 第 2 轮不再出现 |
| 30 | `atDepth` 分组 | 两个 `(depth: 4, role: system)` 条目 | 合成**一组**（entries 有 2 个） |
| 31 | `depth = 0` 注入 | — | 插到聊天历史**最末尾** |
| 32 | `depth` 越界 | depth = 100，聊天只有 3 条 | 追加到末尾（不崩） |
| 33 | 递归 `preventRecursion` | A 触发 B，B 有 `preventRecursion` | B 激活但**不**进入递归缓冲 |
| 34 | `excludeRecursion` | 条目只在第 2 轮能匹配 | 第 2 轮被跳过 |
| 35 | `scanDepth` 覆写 | `scanDepth = 1` | 只扫最新 1 条 |
| 36 | `world_info_include_names` | `true` | 扫描文本形如 `"Alice: hello"` |
| 37 | 空聊天 | chat 为空 | 不崩；`constant` 条目仍激活 |
| 38 | `is_system` 过滤 | 聊天里有 system 消息 | 不参与扫描 |

**golden test 建议**：把 ST 的 `checkWorldInfo` 在一组固定输入下的输出（
`worldInfoBefore` / `worldInfoAfter` / `depthEntries` / `allActivatedEntries` 的 uid 列表）
序列化成 JSON fixture，Swift 侧对拍。

### 9.3 SSE 分帧测试（§7.2）

| # | 用例 | 输入（可能分多次 feed） | 期望 |
|---|---|---|---|
| 1 | 单事件 | `"data: hello\n\n"` | 1 个事件，data = `"hello"` |
| 2 | **跨 chunk 切断** | `"data: hel"` + `"lo\n\n"` | 1 个事件，data = `"hello"` |
| 3 | **切在 `\r\n\r\n` 中间** | `"data: x\r\n"` + `"\r\n"` | 1 个事件 |
| 4 | `\r\n\r\n` 分隔 | `"data: a\r\n\r\ndata: b\r\n\r\n"` | 2 个事件 |
| 5 | `\r\r` 分隔 | `"data: a\r\rdata: b\r\r"` | 2 个事件 |
| 6 | `\n\n` 分隔 | `"data: a\n\ndata: b\n\n"` | 2 个事件 |
| 7 | **`\n\r\n` 不分帧** | `"data: a\n\r\ndata: b\n\n"` | **1 个事件**（★ 见 §7.2.1 边界） |
| 8 | **多行 data** | `"data: a\ndata: b\n\n"` | data = `"a\nb"`（★ 只裁最后一个 `\n`） |
| 9 | **空 data 丢弃** | `"data:\n\n"` | **0 个事件** |
| 10 | 空白 data 保留 | `"data: \ndata: \n\n"` | 1 个事件，data = `"\n"` |
| 11 | 只有 event 字段 | `"event: ping\n\n"` | **0 个事件**（eventData 为空） |
| 12 | `event` + `data` | `"event: content_block_delta\ndata: {}\n\n"` | 1 个事件，type = `content_block_delta` |
| 13 | `id` 字段 | `"id: 42\ndata: x\n\n"` | `lastEventID == "42"` |
| 14 | `id` 含 null | `"id: a\0b\ndata: x\n\n"` | `lastEventID` **不更新** |
| 15 | `delay` 字段忽略 | `"delay: 100\ndata: x\n\n"` | 正常 1 个事件 |
| 16 | 无冒号行 | `"datax\ndata: y\n\n"` | 1 个事件，data = `"y"` |
| 17 | 冒号后无空格 | `"data:x\n\n"` | data = `"x"` |
| 18 | 冒号后两个空格 | `"data:  x\n\n"` | data = `" x"`（★ 只吃一个空格） |
| 19 | **注释行** | `": ping\ndata: x\n\n"` | 1 个事件（注释行被忽略） |
| 20 | `[DONE]` | `"data: [DONE]\n\n"` | 1 个事件，data == `"[DONE]"` |
| 21 | 值里含冒号 | `"data: {\"a\":1}\n\n"` | data = `"{\"a\":1}"` |
| 22 | 尾部残留 | `"data: a\n\ndata: b"` | 第 1 次 feed 出 1 个事件；buffer 留 `"data: b"` |
| 23 | `\r\n` 行尾 | `"data: a\r\n\r\n"` | 1 个事件，data = `"a"` |
| 24 | 空事件块 | `"\n\ndata: a\n\n"` | 1 个事件（空块被丢弃） |

**测试基建**

```swift
func testFraming(chunks: [String], expected: [SSEEvent]) {
    var framer = SSEFramer()
    var got: [SSEEvent] = []
    for c in chunks { got += framer.feed(c) }
    XCTAssertEqual(got, expected)
}
// ★ 必须对每个用例额外跑一遍「逐字符 feed」—— 覆盖所有可能的切断点
func testFramingAllSplitPoints(_ input: String, expected: [SSEEvent]) {
    for i in 0...input.count {
        let a = String(input.prefix(i)), b = String(input.dropFirst(i))
        var framer = SSEFramer()
        let got = framer.feed(a) + framer.feed(b)
        XCTAssertEqual(got, expected, "split at \(i)")
    }
}
```

### 9.4 消息裁剪测试（§2.6 / §6）

| # | 用例 | 期望 |
|---|---|---|
| 1 | 预算充裕 | 所有历史消息都在 |
| 2 | 预算不足 | 只保留最新 N 条 |
| 3 | **遇阻即停** | 第 3 条放不下 ⇒ 第 3 条及**所有更旧**的都丢 |
| 4 | **不跳过超长消息** | 中间某条超长 ⇒ 它和更旧的都丢（**不**尝试更旧的短消息） |
| 5 | `newMainChat` 永在 | 预算为 0 时仍出现，且在**历史最前** |
| 6 | 强制 prompt 抛错 | `main` 放不下 ⇒ 抛 `TokenBudgetError` |
| 7 | examples 整块丢弃 | 第 2 块放不下 ⇒ 第 2、3 块都不出现 |
| 8 | `pin_examples` 顺序 | `true` 时 examples 槽位在 history 之前 |
| 9 | 槽位内部正序 | `chatHistory.messages` 是旧→新 |
| 10 | `reserve`/`free` 平衡 | 生成结束后 `tokenBudget` 为 0（或等于 chat 总 token 的负值一致性检查） |
| 11 | 空聊天 | 只有 `newMainChat` |
| 12 | `squashSystemMessages` | 相邻无 name 的 system 合并；`newMainChat`/`newChat`/`groupNudge` 不合并 |

### 9.5 Prompt 组装 golden test（§2）

**这是最关键的一组**。建议构造一个「全功能」角色卡 + 世界书 + 4 条聊天记录，
把 ST 的 `getChat()` 输出（完整 JSON）作为 fixture，Swift 侧逐字段对拍。

| # | 断言点 |
|---|---|
| 1 | 消息**顺序**完全一致（这是 `prompt_order` + 22 步的核心） |
| 2 | 每条消息的 `role` 一致 |
| 3 | 每条消息的 `name` 一致（示例消息为 `example_user`/`example_assistant`） |
| 4 | `content` 逐字符一致（含换行、尾空格） |
| 5 | 深度注入的消息位置一致（`depth = 0/2/4` 各一条） |
| 6 | `[Example Chat]` 出现在每个示例块之前 |
| 7 | `controlPrompts`（quietPrompt/impersonate）在**最末尾** |
| 8 | 修改 `prompt_order` 后顺序随之改变（验证不是 append 语义） |
| 9 | 禁用 `main` 时仍占位（扩展 prompt 能被相对注入） |
| 10 | `bias` 的 role 是 `assistant` |

### 9.6 端到端与协议测试（§7 / §8）

| # | 用例 | 期望 |
|---|---|---|
| 1 | URL 拼接 | 7 个 base URL 用例（§7.1.1 表）全部匹配 |
| 2 | 空路径 base | `https://api.openai.com` → `//chat/completions` |
| 3 | Gemini URL | 含 `?key=&alt=sse`，且 base 的尾斜杠被去掉 |
| 4 | 错误消息优先级 | 4 种 body 形状都能取到 message |
| 5 | 429 配额 | `error.type == "insufficient_quota"` → `.quotaExceeded` |
| 6 | 401 | → `.unauthorized` |
| 7 | Mistral 数组 content | 正确拼接 |
| 8 | Gemini 多 part | **只取第一个** `!thought` part |
| 9 | Anthropic system 抽取 | 顶部连续 system 进 `system` 数组；其余降级为 user |
| 10 | 取消 | `Task.cancel()` 后流立刻结束，`.finished(.cancelled)` |
| 11 | 多字节跨 chunk | 逐字节喂 `data: {"content":"你好"}\n\n`，正文正确 |
| 12 | 落盘幂等 | 同一条消息重复 `append` 只落一次 |

### 9.7 token 计数测试（§6）

| # | 用例 | 期望 |
|---|---|---|
| 1 | `guesstimate("")` | 0 |
| 2 | `guesstimate` 用 utf8 | `"你好"` → 2（6 字节 / 3.35 向上取整） |
| 3 | 消息公式 | `messageTokens("system", "Hello, world!")` == `1 + 4 + 4` = 9 |
| 4 | 带 name | 额外 `1 + guesstimate(name)` |
| 5 | 与 ST 对拍 | 用 ST 的 `guesstimate` 跑同一批字符串，逐个相等 |
| 6 | 校准器 | 喂 `actual/estimated = 1.2` 若干次后 `ratio` 收敛 |

### 9.8 易错点/测试基建

| # | 要点 |
|---|---|
| 1 | **所有随机都要可注入**：`MacroEngine.rng`、`WorldInfoEngine.rng`、`verifyProbability` 的 roll |
| 2 | **所有时间都要可注入**：`{{time}}`/`{{date}}`/`{{idle_duration}}` 需要一个 `Clock` 抽象 |
| 3 | golden fixture 用「ST 跑一遍导出 JSON」的方式生成，**不要手写期望值** |
| 4 | SSE 测试**必须**跑「所有切分点」的穷举（§9.3 的 `testFramingAllSplitPoints`） |
| 5 | 世界书测试**必须**包含「同 order 多条目的稳定性」（§9.2 用例 16） |
| 6 | 宏测试**必须**包含「一级递归」与「不递归」两个方向（用例 3/4） |

---

## 10. 实现优先级总表

| 阶段 | 模块 | 交付物 | 依赖 |
|---|---|---|---|
| **M1 数据层** | §1 | `ChatCompletionMessage` / `GenerationRequest` / `ProviderProfile` | — |
| **M2 宏引擎** | §4 | `MacroEngine` + 最小宏集合 + 单测 | M1 |
| **M3 Token** | §6.1-6.4 | `GuesstimateTokenCounter` + `ChatCompletion` 预算记账 | M1 |
| **M4 槽位与组装** | §2.1-2.3, §2.7, §2.8 | `PromptAssembler` 22 步（WI 输入先用空字符串） | M2, M3 |
| **M5 示例解析** | §3 | `parseMesExamples` / `parseExampleIntoIndividual` | M2 |
| **M6 历史裁剪** | §2.6 | `populateChatHistory` | M3, M4 |
| **M7 深度注入** | §2.4 | `populationInjectionPrompts` + `ExtensionPromptStore` | M4 |
| **M8 世界书 v1** | §5.1-5.7（P0 子集） | `WorldInfoEngine` + `WorldInfoBuffer` + `matchKeys` | M2, M3 |
| **M9 WI 接线** | §2.5 | WI 结果 → 槽位 / 扩展注入 / EM 数组 | M7, M8 |
| **M10 SSE** | §7.2 | `SSEFramer` + `IncrementalUTF8Decoder` + 25 个分帧测试 | — |
| **M11 客户端** | §7.1, §7.3, §7.5 | `URLBuilder` + 三条协议路径 + `GenerationEvent` | M1, M10 |
| **M12 错误** | §7.4 | `LLMError` + 分类函数 | M11 |
| **M13 E2E** | §8 | `GenerationPipeline` + 落盘 | 全部 |
| **M14 WI 高级** | §5.8（P1 项） | probability / group / recursive / delay | M8 |
| **M15 校准** | §6.6 选项 B | `CalibratedTokenCounter` | M11 |
| **M16 WI P2** | §5.8（P2 项） | sticky / cooldown / minActivations / regex placement | M14 |

**建议的里程碑验收标准**

| 里程碑 | 验收 |
|---|---|
| M1-M7 完成 | §9.1 / §9.4 / §9.5 测试通过（WI 用空输入） |
| M8-M9 完成 | §9.2 全 38 个用例通过 |
| M10-M12 完成 | §9.3 全 24 个用例（含穷举切分）+ §9.6 通过 |
| M13 完成 | 端到端能对真实供应商跑通并落盘 |
| M14 完成 | §9.2 的递归/概率/分组用例通过 |

---

## 11. 参考索引

### 11.1 源码索引（本文引用的关键位置）

| 主题 | 文件:行 |
|---|---|
| `populateChatCompletion`（22 步） | `public/scripts/openai.js:1185-1347` |
| `populationInjectionPrompts`（深度注入） | `public/scripts/openai.js:810-875` |
| `populateChatHistory`（裁剪） | `public/scripts/openai.js:885-1092` |
| `populateDialogueExamples` | `public/scripts/openai.js:1101-1134` |
| `setOpenAIMessageExamples` | `public/scripts/openai.js:656-667` |
| `parseExampleIntoIndividual` | `public/scripts/openai.js:729-787` |
| `formatWorldInfo` | `public/scripts/openai.js:789-801` |
| `preparePromptsForChatCompletion` | `public/scripts/openai.js:1367-1516` |
| `squashSystemMessages` | `public/scripts/openai.js:3922-3954` |
| `ChatCompletion` | `public/scripts/openai.js:3917-4268` |
| `ChatCompletion.getChat` | `public/scripts/openai.js:4120-4141` |
| `getStreamingReply` | `public/scripts/openai.js:3222-3306` |
| `getChatCompletionErrorMessage` | `public/scripts/openai.js:1635-1639` |
| `tryParseStreamingError` / `checkQuotaError` | `public/scripts/openai.js:1648-1715` |
| `default_settings`（采样默认值） | `public/scripts/openai.js:411-518` |
| `max_4k = 4095` | `public/scripts/openai.js:127` |
| `evaluateMacros`（宏表） | `public/scripts/macros.js:610-714` |
| `getRandomReplaceMacro` | `public/scripts/macros.js:491-509` |
| `getPickReplaceMacro` | `public/scripts/macros.js:516-545` |
| `getDiceRollMacro` | `public/scripts/macros.js:550-572` |
| `getChatIdHash` | `public/scripts/macros.js:315-328` |
| `getStringHash` | `public/scripts/utils.js:522-539` |
| `guesstimate` / `BYTES_PER_TOKEN` | `public/scripts/tokenizers.js:166-169`, `:12` |
| `if (!full) token_count -= 2` | `public/scripts/tokenizers.js:884` |
| `getExtensionPrompt` | `public/script.js:3301-3329` |
| `getCharacterCardFieldsLazy` | `public/script.js:3402-3494` |
| `parseMesExamples` | `public/script.js:3501-3515` |
| `baseChatReplace` | `public/script.js:3341-3352` |
| WI 结果落位（EM / depth / outlet） | `public/script.js:4635-4678` |
| `WorldInfoBuffer` | `public/scripts/world-info.js:199-474` |
| `matchKeys` | `public/scripts/world-info.js:337-366` |
| `getScore` | `public/scripts/world-info.js:428-473` |
| `WorldInfoTimedEffects` | `public/scripts/world-info.js:479-795` |
| `parseRegexFromString` | `public/scripts/world-info.js:2901-2926` |
| 条目默认值 | `public/scripts/world-info.js:4082-4125` |
| `getSortedEntries` | `public/scripts/world-info.js:4590-4644` |
| `parseDecorators` | `public/scripts/world-info.js:4652-4700` |
| `checkWorldInfo` | `public/scripts/world-info.js:4709-5282` |
| 概率检查 / 预算 | `public/scripts/world-info.js:5017-5077` |
| 注入构建 | `public/scripts/world-info.js:5189-5282` |
| `filterByInclusionGroups` | `public/scripts/world-info.js:5292-5475` |
| 常量 / 默认设置 | `public/scripts/world-info.js:33-100` |
| SSE 分帧 | `public/scripts/sse-stream.js:10-81` |
| `Prompt.preparePrompt` | `public/scripts/PromptManager.js:1277-1290` |
| `Prompt` 字段与默认值 | `public/scripts/PromptManager.js:182-195` |
| `getPromptCollection` | `public/scripts/PromptManager.js:1516-1541` |
| Token 服务端公式 | `src/endpoints/tokenizers.js:998-1023`, `:884` |
| URL 常量与拼接 | `src/endpoints/backends/chat-completions.js:73-101`, `:2281-2284`, `:2625-2628` |
| Claude 请求构造 | `src/endpoints/backends/chat-completions.js:230-443` |
| Gemini 请求构造 | `src/endpoints/backends/chat-completions.js:454-793` |
| Anthropic prompt 转换 | `src/prompt-converters.js:197-313` |
| Gemini prompt 转换 | `src/prompt-converters.js:432-...` |
| 默认预设 | `default/content/presets/openai/Default.json` |

### 11.2 本文对 02/03 文档的勘误汇总

| # | 文档原文 | 实际情况 | 依据 |
|---|---|---|---|
| 1 | `02#3.6` 表格：「聊天历史消息 ❌ 不做宏替换」 | **会做宏替换**：`populateChatHistory` 调用 `promptManager.preparePrompt()`，而它无条件跑 `substituteParams` | `openai.js:955` → `PromptManager.js:1277-1290` |
| 2 | `03#1.5.5`：「`tryParseStreamingError` … → toastr 报错」 | 该函数的 `throw` **被自己的 `catch` 吃掉**，实际上**永不抛错**，只弹 toast | `openai.js:1648-1679` |
| 3 | `02#4.7`：`WIDepthEntries.push({depth: entry.depth, ...})` | push 的是 `entry.depth` **原值**（可能 `undefined`），而 `findIndex` 比较用 `?? DEFAULT_DEPTH`。Swift 补默认值 4 是**可接受的改进** | `world-info.js:5236-5244` |
| 4 | `03#1.1` 表格未列「裸 host」 | `https://api.openai.com` ⇒ `new URL().toString()` = `https://api.openai.com/` ⇒ 拼出 `//chat/completions`（与带尾斜杠等价） | Node 实测 |

### 11.3 相关文档

| 文档 | 内容 |
|---|---|
| `01-character-card-spec.md` | 角色卡 V2/V3 字段规格 |
| `02-prompt-assembly-and-worldinfo.md` | Prompt 组装 + 世界书触发 + token 预算（**本文的主要来源**） |
| `03-llm-api-protocols.md` | LLM 供应商协议 + SSE 流式（**本文的主要来源**） |
| `04-local-data-and-settings.md` | 本地数据与设置持久化（本文 §8.3 的落盘结构） |

