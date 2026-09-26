# SillyTavern Prompt 组装 & 世界书触发引擎 —— Swift 重写规范

> **来源与版本**
> - 仓库：`/Users/wuzheng/projects/SillyTavern-ios`（SillyTavern Node.js 源码）
> - 分支：`dsh`，HEAD = `06bde939fb1e9c4c8d8641d810f0a916b5bce127`（2026-09-14）
> - 本文所有行号均相对该 commit。**只覆盖 Chat Completion（`main_api === 'openai'`）路径**，Text Completion 的 story-string 路径仅在与 Chat Completion 共享代码处提及。
> - 目标：可直接作为 Swift 实现的伪代码依据。

---

## 0. 总览：Chat Completion 一次生成的调用链

```
Generate(type, ..., dryRun)                       public/script.js:4470+
  ├─ getCharacterCardFields()                      public/script.js:3476   → description/personality/scenario/system/jailbreak/mesExamples/persona/charDepthPrompt/creatorNotes
  ├─ coreChat = chat.filter(非 system)              public/script.js:4496
  ├─ setFloatingPrompt()          → AN 扩展注入      public/scripts/authors-note.js:324
  ├─ chatForWI = coreChat.map("name: mes").reverse() public/script.js:4624
  ├─ getWorldInfoPrompt(chatForWI, maxCtx, …)      public/scripts/world-info.js:892
  │     └─ checkWorldInfo(...)                     public/scripts/world-info.js:4709   ← 世界书引擎
  ├─ 深度 WI → setExtensionPrompt(IN_CHAT, depth)   public/script.js:4668-4673
  ├─ 角色 depth_prompt → setExtensionPrompt         public/script.js:4473-4486
  ├─ persona 注入（非 IN_PROMPT 时）                 public/script.js:3223
  ├─ mesExamplesArray = parseMesExamples(...)      public/script.js:3501
  ├─ oaiMessages        = setOpenAIMessages()       public/scripts/openai.js:570
  ├─ oaiMessageExamples = setOpenAIMessageExamples()public/scripts/openai.js:656
  └─ prepareOpenAIMessages({...}, dryRun)           public/scripts/openai.js:1542
        ├─ preparePromptsForChatCompletion()        public/scripts/openai.js:1367
        └─ populateChatCompletion()                 public/scripts/openai.js:1185
              ├─ populationInjectionPrompts()       public/scripts/openai.js:810   ← 深度注入
              ├─ populateChatHistory()              public/scripts/openai.js:885
              └─ populateDialogueExamples()         public/scripts/openai.js:1101
```

**Swift 建议的模块切分**：`MacroEngine` → `WorldInfoEngine` → `PromptAssembler`（含 `ChatCompletion`/`MessageCollection`/`Message`/`TokenHandler` 四个等价类型）→ `Tokenizer`。

---

## 1. 最终消息数组的有序组装步骤

### 1.1 顶层：`ChatCompletion` 是一个「槽位数组」

`ChatCompletion.messages` 是 `MessageCollection`（root），其 `collection` 是槽位数组；每个槽位要么是单个 `Message`，要么是 `MessageCollection`（如 `chatHistory`、`dialogueExamples`）。
- 类定义：`public/scripts/openai.js:3917`
- `add(collection, position)`：`position === null | -1` → push 到末尾；否则替换 `collection[position]`。`public/scripts/openai.js:3998-4013`
- `insert(message, identifier, position)`：在指定槽位内部 `unshift`/`push`/`splice`。`public/scripts/openai.js:4042-4056`
- 最终扁平化 `getChat()`：跳过 `content` 与 `tool_calls` 都为空的 Message，输出 `{role, content, name?, tool_calls?, tool_call_id?, signature?, reasoning?}`。`public/scripts/openai.js:4120-4141`

> **Swift 关键点**：必须保留「槽位」概念，因为 token 预算裁剪与注入都是按槽位操作的（`insertAtStart` 把新消息塞到 `chatHistory` 头部 = 最旧位置）。用一个 `enum Slot { case message(Message); case collection(MessageCollection) }` 建模。

### 1.2 `populateChatCompletion` 的顺序（**这是权威顺序**）

`public/scripts/openai.js:1185-1347`：

| # | 动作 | 代码位置 | 说明 |
|---|------|---------|------|
| 0 | `chatCompletion.reserveBudget(3)` | :1210 | 为「回复前置符」预留 3 token（`<\|start\|>assistant<\|message\|>`） |
| 1 | `addToChatCompletion('worldInfoBefore')` | :1212 | role=system，**位置 = 用户 prompt_order 里 `worldInfoBefore` 的槽位索引** |
| 2 | `addToChatCompletion('main')` | :1213 | 主 system prompt |
| 3 | `addToChatCompletion('worldInfoAfter')` | :1214 | |
| 4 | `addToChatCompletion('charDescription')` | :1215 | |
| 5 | `addToChatCompletion('charPersonality')` | :1216 | |
| 6 | `addToChatCompletion('scenario')` | :1217 | |
| 7 | `addToChatCompletion('personaDescription')` | :1218 | persona 在 `IN_PROMPT` 时才有内容 |
| 8 | `controlPrompts = MessageCollection('controlPrompts')`；`setOverriddenPrompts()` | :1221-1222 | controlPrompts 最后追加 |
| 9 | `impersonate` 消息（仅 `type === 'impersonate'`） | :1224-1225 | 加入 controlPrompts |
| 10 | `quietPrompt` 消息（有内容才加） | :1229-1236 | 加入 controlPrompts，**永远在 controlPrompts 内部最后** |
| 11 | `reserveBudget(controlPrompts)` | :1238 | |
| 12 | `systemPrompts = ['nsfw','jailbreak']` 然后 `userRelativePrompts`（`system_prompt === false` 的 prompt，按 collection 顺序） | :1241-1257 | **按 identifier 逐个 add 到末尾** |
| 13 | `enhanceDefinitions`（若存在） | :1260 | |
| 14 | `bias`（`bias.trim().length` 时） | :1263 | role=assistant |
| 15 | 已知相对扩展 prompt `['summary','authorsNote','vectorsMemory','vectorsDataBank','smartContext']` → `injectToMain(prompt, prompt.position)` | :1286-1302 | `position` 来自 `getPromptPosition()`：`BEFORE_PROMPT → 'start'`、`IN_PROMPT → 'end'` |
| 16 | 其它 `extension && position` 的 prompt → `injectToMain` | :1305-1307 | |
| 17 | 工具调用 token 预留 | :1310-1316 | 可忽略（无 tool 时） |
| 18 | `continue`+`continue_prefill` 时把待续消息移入 controlPrompts | :1320-1331 | |
| 19 | `messages = populationInjectionPrompts(absolutePrompts, messages)` | :1334 | **深度注入，见 §1.4** |
| 20 | `power_user.pin_examples ? (examples 先, 再 history) : (history 先, 再 examples)` | :1337-1343 | 默认 `pin_examples=false` → **先 history 后 examples** |
| 21 | `freeBudget(controlPrompts)`；若有内容 `chatCompletion.add(controlPrompts)` | :1345-1346 | **controlPrompts 追加到数组末尾** |
| 22 | `squashSystemMessages()`（`oai_settings.squash_system_messages && !dryRun`） | :1608-1610 | 见 §1.6 |

> **注意 `addToChatCompletion` 的位置语义**（`public/scripts/openai.js:1187-1208`）：
> - 若该 prompt 在 `prompt_order` 里存在，`prompts.index(source)` 返回用户排序里的**索引**，`chatCompletion.add(collection, index)` 会**按索引替换/落位**。所以 step 1-7、12-14 的最终相对位置由用户在 Prompt Manager 里的 `prompt_order` 决定。
> - 若 prompt 的 `injection_position === ABSOLUTE`（In-Chat），则 `addToChatCompletion` 直接 **return 跳过**（:1198-1201），改由 step 19 处理。
> - 若 `promptManager.isPromptDisabledForActiveCharacter(source) && source !== 'main'`，跳过（:1191-1194）。

### 1.3 默认排序（`default/content/presets/openai/Default.json`）

`prompt_order` 的两套（`character_id: 100000` 单人 / `100001` 群聊）默认顺序：

```
main, worldInfoBefore, [personaDescription 仅群聊套], charDescription, charPersonality,
scenario, enhanceDefinitions(禁用), nsfw, worldInfoAfter, dialogueExamples,
chatHistory, jailbreak
```

- 文件：`default/content/presets/openai/Default.json:129-208`（100000）、`:209-289`（100001）
- `main` 默认内容：`Write {{char}}'s next reply in a fictional chat between {{char}} and {{user}}.`
- `enhanceDefinitions` 默认内容：`If you have more knowledge of {{char}}, add to the character's lore and personality to enhance them but keep the Character Sheet's definitions absolute.`（默认 `enabled: false`）
- `jailbreak`（= Post-History Instructions）默认内容为空字符串
- `nsfw`（= Auxiliary Prompt）默认内容为空字符串

`marker: true` 的条目是**占位符**（main / dialogueExamples / chatHistory / worldInfoAfter / worldInfoBefore / charDescription / charPersonality / scenario / personaDescription），其 `content` 由运行时填充。

### 1.4 深度注入：`populationInjectionPrompts`

`public/scripts/openai.js:810-875`。伪代码：

```
totalInserted = 0
for depth in 0...MAX_INJECTION_DEPTH (10000):        # :819-820, MAX_INJECTION_DEPTH=10000 @ script.js:500
    depthPrompts = absolutePrompts.filter(p => p.injection_depth == depth && p.content)
    if depthPrompts.isEmpty: continue

    # 1) 按 injection_order 分组，order 从大到小处理（低 order 先贴到更后面）
    orderGroups = group(depthPrompts, by: p.injection_order ?? 100)
    for order in orderGroups.keys.sorted(descending):       # :842
        # 2) 每个 order 内按 role 固定顺序：system, user, assistant   (:847)
        for role in ["system", "user", "assistant"]:
            rolePrompts = orderGroups[order].filter(role).map(content).joined("\n")
            # 3) 当 order == 100 时，额外拼上 extension_prompts 里同 depth/role 的 IN_CHAT 注入
            extPrompt = (order == 100)
                ? await getExtensionPrompt(IN_CHAT, depth, "\n", roleEnum(role), wrap=false)
                : ""
            joint = [rolePrompts, extPrompt].filter(非空).map(trim).joined("\n")
            if joint非空: roleMessages.append({role, content: joint, injected: true})

    if roleMessages非空:
        injectIdx = depth + totalInserted                        # :866-869
        messages.splice(injectIdx, 0, ...roleMessages)
        totalInserted += roleMessages.count

messages.reverse()                                               # :873
```

**语义要点（重要，容易搞错）**
1. 传入的 `messages` 数组此时是**逆序**的：索引 0 = 最新消息，索引 `len-1` = 最旧（因为 `setOpenAIMessages` 从 `chat.length-1` 往前遍历构造，见 `public/scripts/openai.js:578`）。
   - 所以「depth = 0」插到 `messages[0]`（最新之前），而函数末尾 `messages.reverse()` 把它转换成正序给后续 `populateChatHistory` 使用。
2. 注入位置公式 `depth + totalInserted`：`totalInserted` 累计已插入的**消息条数**，用于补偿前面的插入造成的索引偏移（因为插入后索引 0 仍是原先的最新消息，后续浅层 depth 需要继续往数组前面插）。
3. 同一个 `(depth, order, role)` 的多条 prompt 用 `\n` 拼接为**一条**消息。
4. `MAX_INJECTION_DEPTH = 10000`（`public/script.js:500`），`getExtensionPromptMaxDepth()` 直接返回它（`public/script.js:3281-3289`），所以循环是 0..10000，但 `continue` 掉空分组，实际只遍历有内容的 depth。
5. `getExtensionPrompt(position, depth, separator='\n', role, wrap)`（`public/script.js:3301-3329`）：从 `extension_prompts` 中 **按 key 字典序排序**，过滤 `position` 匹配、`value` 非空、`depth` 匹配（`x.depth === undefined` 视为匹配）、`role` 匹配（`x.role === undefined` 视为匹配）、`filter()` 通过，然后 `value.trim()` 用 `\n` join，最后整串再做一次 `substituteParams`。
6. `wrap=false`（`populationInjectionPrompts` 里硬编码 `const wrap = false`，`:826`），所以不加首尾分隔符。

**扩展注入 key 与字典序**（`public/scripts/constants.js:48-56`）
```
STORY_STRING      = '__STORY_STRING__'          # 仅 Text Completion
QUIET_PROMPT      = 'QUIET_PROMPT'
DEPTH_PROMPT      = 'DEPTH_PROMPT'              # 角色 depth_prompt
DEPTH_PROMPT_INDEX = i => `DEPTH_PROMPT_${i}`   # 群聊成员 depth prompt
CUSTOM_WI_DEPTH    = 'customDepthWI'
CUSTOM_WI_DEPTH_ROLE = (depth, role) => `customDepthWI_${depth}_${role}`   # 世界书 atDepth
CUSTOM_WI_OUTLET   = key => `customWIOutlet_${key}`
```
字典序意味着 `DEPTH_PROMPT` < `DEPTH_PROMPT_0` < `PERSONA_DESCRIPTION` < `QUIET_PROMPT` < `customDepthWI_…`。ASCII 大写字母 < 小写字母，故 `PERSONA_DESCRIPTION` 排在 `customDepthWI_*` 之前。

### 1.5 世界书注入点的落地位置

`checkWorldInfo` 返回（`public/scripts/world-info.js:5281`）：
`{ worldInfoBefore, worldInfoAfter, EMEntries, WIDepthEntries, ANBeforeEntries, ANAfterEntries, outletEntries, allActivatedEntries }`

| 返回字段 | 落地方式 | 代码位置 |
|---|---|---|
| `worldInfoBefore` | `formatWorldInfo()` 包裹 → `worldInfoBefore` prompt 槽位（默认 role=system，紧跟 main 之前/之后由 order 决定） | `openai.js:1376`, `openai.js:789-801` |
| `worldInfoAfter` | 同上 → `worldInfoAfter` 槽位 | `openai.js:1377` |
| `WIDepthEntries` | 每项 `{depth, role, entries[]}` → `setExtensionPrompt('customDepthWI_{depth}_{role}', entries.join('\n'), IN_CHAT, depth, scan=false, role)` → 被 `populationInjectionPrompts` 按 depth 插入 | `script.js:4668-4673` |
| `ANTopEntries` / `ANAfterEntries` | 直接拼接进 Author's Note 的值：`ANTop + "\n" + originalAN + "\n" + ANBottom`，再 `replace(/(^\n)|(\n$)/g,'')`，然后 `setExtensionPrompt(NOTE_MODULE_NAME, …)` | `world-info.js:5268-5272` |
| `EMEntries` | `{position: before|after, content}` → `baseChatReplace()` + `parseMesExamples()`，`before` 用 `unshift`，`after` 用 `push` 合进 `mesExamplesArray` | `script.js:4638-4655` |
| `outletEntries` | `setExtensionPrompt('customWIOutlet_{key}', joined, NONE, 0)`；由 `{{outlet::key}}` 宏取用 | `script.js:4674-4678`, `macros.js:596-599` |

`formatWorldInfo`（`public/scripts/openai.js:789-801`）：若 `oai_settings.wi_format`（默认 `'{0}'`）非空则 `stringFormat(format, value)`，否则原样返回。空 value 返回 `''`。

### 1.6 收尾处理

**`squashSystemMessages()`**（`public/scripts/openai.js:3922-3954`，默认 `squash_system_messages = false`）
- 先 `flatten()`。
- 跳过 `role === 'system' && !content` 的空消息。
- 相邻的、`role === 'system'` 且 `!name`、且 `identifier ∉ ['newMainChat','newChat','groupNudge']` 的消息合并为一条，`content += '\n' + next.content` 并重算 token。

**`getChat()`** 之后还会 emit `CHAT_COMPLETION_PROMPT_READY` 事件（`:1618-1619`），扩展可修改。

### 1.7 关键标识符清单（Swift 需逐一实现为常量）

| identifier | 来源 | role | 触发条件 |
|---|---|---|---|
| `main` | `prompt_order` | system | 总是；可被角色 `system_prompt` 覆盖（`prefer_character_prompt`） |
| `worldInfoBefore` | WI | system | 有 before 条目 |
| `worldInfoAfter` | WI | system | 有 after 条目 |
| `charDescription` | 卡 `description` | system | 非空 |
| `charPersonality` | `personality_format` 包裹 | system | 非空 |
| `scenario` | `scenario_format` 包裹 | system | 非空 |
| `personaDescription` | `power_user.persona_description` | system | `persona_description_position == IN_PROMPT(0)` |
| `nsfw` | 用户配置（Auxiliary） | system | 非空 |
| `jailbreak` | Post-History Instructions | system | 非空；可被卡 `post_history_instructions` 覆盖 |
| `dialogueExamples` | 示例消息 | 多条 system（见 §2） | `mes_example` 非空 |
| `chatHistory` | 聊天记录 | user/assistant | 总是 |
| `enhanceDefinitions` | 用户配置 | system | 存在且启用 |
| `impersonate` | `impersonation_prompt` | system | `type === 'impersonate'` |
| `quietPrompt` | 运行时 | system | 非空（extras/quiet 生成） |
| `groupNudge` | `group_nudge_prompt` | system | 群聊且非 impersonate |
| `bias` | prompt bias | assistant | `bias.trim().length > 0` |
| `summary`/`authorsNote`/`vectorsMemory`/`vectorsDataBank`/`smartContext` | 扩展 | 各自 role | 扩展 prompt 有值 |
| `newMainChat` / `newChat` / `newGroupChat` | 见 §6 | system | 见 §6 |

**`preparePromptsForChatCompletion`**（`public/scripts/openai.js:1367-1516`）里所有 system prompt 的构造：
```
worldInfoBefore : role system, content = formatWorldInfo(worldInfoBefore)
worldInfoAfter  : role system, content = formatWorldInfo(worldInfoAfter)
charDescription : role system, content = charDescription
charPersonality : role system, content = (charPersonality && personality_format) ? substituteParams(personality_format) : charPersonality
scenario        : role system, content = (scenario && scenario_format) ? substituteParams(scenario_format) : scenario
impersonate     : role system, content = substituteParams(impersonation_prompt)
quietPrompt     : role system, content = quietPrompt
groupNudge      : role system, content = substituteParams(group_nudge_prompt)
bias            : role assistant, content = bias
```
随后合并 systemPrompts 与 promptManager 的 collection：**若 collection 里已有同 identifier 的 prompt，则用 collection 的 `injection_position`/`injection_depth`/`injection_order`/`role` 覆盖该 prompt 的对应字段**（`:1477-1486`），再 `preparePrompt()`（做宏替换）并替换/追加（`:1488-1492`）。

**角色卡覆盖**（`:1495-1513`）：`main` ← `systemPromptOverride`（角色 `system_prompt`，需 `power_user.prefer_character_prompt`）；`jailbreak` ← `jailbreakPromptOverride`（角色 `post_history_instructions`，需 `prefer_character_jailbreak`）。当 `forbid_overrides === true` 或该 prompt 对当前角色被禁用时跳过。

**`Prompt` 对象的默认值**（`public/scripts/PromptManager.js:182-196`，常量 `DEFAULT_DEPTH = 4` / `DEFAULT_ORDER = 100` 见 `:31-32`）：
```js
constructor({ identifier, role, content, name, system_prompt, position,
              injection_depth, injection_position, forbid_overrides, extension,
              injection_order, injection_trigger } = {}) {
    this.identifier = identifier;        this.role = role;
    this.content = content;              this.name = name;
    this.system_prompt = system_prompt;  this.position = position;
    this.injection_depth = injection_depth;        // ← 可能是 undefined
    this.injection_position = injection_position;  // ← 可能是 undefined
    this.forbid_overrides = forbid_overrides;
    this.extension = extension ?? false;
    this.injection_order = injection_order ?? DEFAULT_ORDER;   // 100
    this.injection_trigger = injection_trigger ?? [];
}
```
- `injection_position` 未设时，`prompt.injection_position === INJECTION_POSITION.ABSOLUTE`（`1`，`PromptManager.js:37-40`）判定为 `false` → **默认按「相对位置（RELATIVE = 0）」处理**。
- `injection_depth` 未设时，`populationInjectionPrompts` 里 `prompt.injection_depth === i` 对 `i=0` 也**不成立**（`undefined === 0` 为 false），所以未设 depth 的 In-Chat prompt **不会**被注入（UI 层用 `DEFAULT_DEPTH = 4` 作为输入框显示默认值，`PromptManager.js:1378`；但这只在用户保存表单时才写回 prompt）。
- `injection_order` 默认 `100`（与 `populationInjectionPrompts` 里的 `?? 100` 一致）。

**`PromptCollection` 的组装顺序**（`public/scripts/PromptManager.js:1516-1541`）：
```js
getPromptCollection(generationType):
    promptOrder = this.getPromptOrderForCharacter(this.activeCharacter)   // 用户 prompt_order
    for entry in promptOrder:
        prompt = getPromptById(entry.identifier)
        if !prompt: continue
        if entry.enabled && shouldTrigger(prompt, generationType):
            collection.add(preparePrompt(prompt))          // ← 顺序 = prompt_order 顺序
        else if entry.identifier === 'main':
            clone = structuredClone(prompt); clone.content = ''
            collection.add(preparePrompt(clone))           // main 始终占位（空内容）
```
- `shouldTrigger`：`prompt.injection_trigger` 为空或包含当前 generation type（`normal`/`swipe`/`continue`/`impersonate`/`quiet`/…）时才启用（`:1549-1553`）。
- **禁用（`enabled: false`）的 prompt 不会进入 collection**，因此 `addToChatCompletion` 里 `prompts.has(source)` 为假而被跳过（唯一例外是 `main`，它会被替换为空内容占位，从而让相对注入有锚点）。

---

## 2. `mes_example` 解析与示例消息 role 分配

### 2.1 第一步：切成块 —— `parseMesExamples`

`public/script.js:3501-3515`：
```js
function parseMesExamples(examplesStr, isInstruct) {
    if (!examplesStr || examplesStr.length === 0 || examplesStr === '<START>') return [];
    if (!examplesStr.startsWith('<START>')) examplesStr = '<START>\n' + examplesStr.trim();

    const exampleSeparator = power_user.context.example_separator ? `${substituteParams(...)}\n` : '';
    const blockHeading = (main_api === 'openai' || isInstruct) ? '<START>\n' : exampleSeparator;
    const splitExamples = examplesStr.split(/<START>/gi).slice(1)
        .map(block => `${blockHeading}${block.trim()}\n`);
    return splitExamples;
}
```
- 分隔符正则 `/<START>/gi` → **大小写不敏感**。
- `.slice(1)` 丢弃 `<START>` 之前的文本。
- Chat Completion 下每个块被规范化为 `"<START>\n" + block.trim() + "\n"`。
- 没有 `<START>` 时会在开头补一个。

### 2.2 第二步：块 → 消息数组 —— `setOpenAIMessageExamples`

`public/scripts/openai.js:656-667`：
```js
for (const item of mesExamplesArray) {
    const replaced = item.replace(/<START>/i, '{Example Dialogue:}').replace(/\r/gm, '');
    const parsed = parseExampleIntoIndividual(replaced, true);
    examples.push(parsed);   // 数组的数组
}
```
- **`<START>` 被就地替换成 `{Example Dialogue:}`**（只替换第一个，`/i`），该行成为第一个 assistant 消息正文的一部分（因为 `parseExampleIntoIndividual` **跳过第一行**）。
- 示例块顺序 = `mesExamplesArray` 顺序 = `worldInfoExamples`(EMTop, unshift) + 卡片 `mes_example` + `worldInfoExamples`(EMBottom, push)（`script.js:4638-4655`）。

### 2.3 第三步：单块 → user/assistant 序列 —— `parseExampleIntoIndividual`

`public/scripts/openai.js:729-787`（逐字语义）：
```js
const groupBotNames = getGroupNames().map(n => `${n}:`);   // 群聊成员 "Name:"
let result = [], tmp = str.split('\n'), cur_msg_lines = [];
let in_user = false, in_bot = false, botName = name2;

function add_msg(name, role, system_name) {
    let parsed = cur_msg_lines.join('\n').replace(name + ':', '').trim();
    if (appendNamesForGroup && selected_group && ['example_user','example_assistant'].includes(system_name))
        parsed = `${name}: ${parsed}`;      // 群聊时前缀名字
    result.push({ role, content: parsed, name: system_name });
    cur_msg_lines = [];
}

for (let i = 1; i < tmp.length; i++) {     // ← 跳过第 0 行（"This is how {char} should talk" / "{Example Dialogue:}"）
    const cur_str = tmp[i];
    if (cur_str.startsWith(name1 + ':')) {              // "{{user}}:"
        in_user = true;
        if (in_bot) add_msg(botName, 'system', 'example_assistant');
        in_bot = false;
    } else if (cur_str.startsWith(name2 + ':') || groupBotNames.some(n => cur_str.startsWith(n))) {
        if (!cur_str.startsWith(name2 + ':') && groupBotNames.length) botName = cur_str.split(':')[0];
        in_bot = true;
        if (in_user) add_msg(name1, 'system', 'example_user');
        in_user = false;
    }
    cur_msg_lines.push(cur_str);
}
if (in_user) add_msg(name1, 'system', 'example_user');
else if (in_bot) add_msg(botName, 'system', 'example_assistant');
```

**总结规则（Swift 实现要点）**
- **role 一律是 `'system'`**；用 `name` 字段区分 `example_user` / `example_assistant`。这是 Chat Completion 路径里「示例消息」的真实表示。（`public/scripts/openai.js:750`、`:762`、`:773`）
- 触发切换的行必须**以 `"{名字}:"` 开头**（`startsWith`，**大小写敏感**）。`name1` = 用户名，`name2` = 角色名。
- 切换行本身**仍被 push 进 `cur_msg_lines`**，然后 `add_msg` 用 `replace(name + ':', '')` 把**第一次出现**的该前缀删掉（`String.replace` 传字符串只替换第一处）。
- 前缀匹配用的是**当前段的名字**（`name` 参数），但 `replace` 只删除首个 `name+':'`，且不校验位置，因此若消息正文里更早出现同一前缀会被误删（ST 的既有行为，复刻时保持一致即可）。
- `name` 字段：`example_user` / `example_assistant`（常量字符串，非真实名字）。群聊且 `appendNamesForGroup=true` 时，content 会被加上 `"{显示名}: "` 前缀。

### 2.4 示例块 → `dialogueExamples` 槽位 —— `populateDialogueExamples`

`public/scripts/openai.js:1101-1134`：
```
add(new MessageCollection('dialogueExamples'), prompts.index('dialogueExamples'))
if messageExamples 非空:
    newExampleChat = Message.createAsync('system', substituteParams(oai_settings.new_example_chat_prompt), 'newChat')
        # new_example_chat_prompt 默认 "[Example Chat]"（preset:50）
    for dialogue in messageExamples:                       # 每个 <START> 块
        chatMessages = dialogue.map(p => {
            let m = Message.createAsync('system', p.content, `dialogueExamples ${blockIdx}-${msgIdx}`)
            m.setName(p.name)                              # example_user / example_assistant
            return m
        })
        if !canAffordAll([newExampleChat, ...chatMessages]): break   # 预算不足则整块放弃
        insert(newExampleChat, 'dialogueExamples')
        for m in chatMessages: insert(m, 'dialogueExamples')
```
- **每个示例块前都会插入一条 `[Example Chat]`（默认值）system 消息**，identifier = `newChat`。
- 预算是**逐块**检查的：某一块放不下就 `break`（后面的块全都不要）。
- `{{char}}`/`{{user}}` 在卡片字段阶段已经通过 `baseChatReplace()`（`substituteParams(..., replaceCharacterCard: false)`）替换过（`script.js:3448-3453`）；`dialogueExamples` 的 content 进入 `Message.createAsync` 前**不再做宏替换**。

---

## 3. 宏（Macro）替换

### 3.1 两条实现路径

| 路径 | 入口 | 是否默认 |
|---|---|---|
| **Legacy（默认）** | `substituteParamsLegacy` → `evaluateMacros` | ✅ `power_user.experimental_macro_engine === false` |
| 新引擎 | `substituteParams` → `MacroEnvBuilder` + `MacroEngine.evaluate` | ❌ 实验开关 |

- 分发：`public/script.js:2981-3015`（`if (!power_user?.experimental_macro_engine) return substituteParamsLegacy(...)`）
- Legacy 主循环：`public/scripts/macros.js:610-714`
- 完整签名：`substituteParams(content, {name1Override, name2Override, original, groupOverride, replaceCharacterCard, dynamicMacros, postProcessFn})`（`script.js:2970-2981`）

> **Swift 实现建议：以 Legacy 为准**（它是默认路径，也是既有角色卡/世界书作者实际依赖的行为），新引擎仅作为未来扩展。

### 3.2 Legacy 替换算法（必须逐条复刻的顺序）

`evaluateMacros(content, env, postProcessFn)`（`public/scripts/macros.js:610-714`）：

```js
// A. 先把所有注册宏灌进 env（MacrosParser 注册表）
MacrosParser.populateEnv(env);                       // macros.js:685
const nonce = uuidv4();                              // 函数型宏每次替换拿同一个 nonce

// B. 构造三批宏
macros = [
  // ---- preEnv 批次（按数组顺序执行）----
  /<USER>/gi                → env.user
  /<BOT>/gi                 → env.char
  /<CHAR>/gi                → env.char
  /<CHARIFNOTGROUP>/gi      → env.group
  /<GROUP>/gi               → env.group
  diceRoll                  /{{roll[ : ]([^}]+)}}/gi
  ...instructMacros
  ...variableMacros         setvar/addvar/incvar/decvar/getvar + global 变体
  /{{newline}}/gi           → '\n'
  /(?:\r?\n)*{{trim}}(?:\r?\n)*/gi → ''        ← 会连同前后换行一起吃掉
  /{{noop}}/gi              → ''
  /{{input}}/gi             → $('#send_textarea').val()

  // ---- env 批次（每个 env key 一个正则，按 env 的插入顺序）----
  new RegExp(`{{${escapeRegex(varName)}}}`, 'gi')

  // ---- postEnv 批次 ----
  maxPrompt|maxPromptTokens, maxContext|maxContextTokens, maxResponse|maxResponseTokens
  lastMessage, lastMessageId, lastUserMessage, lastCharMessage
  firstIncludedMessageId, firstDisplayedMessageId, lastSwipeId, currentSwipeId, allChatRange
  /{{reverse:(.+?)}}/gi
  /\{\{\/\/([\s\S]*?)\}\}/gm   → ''            ← {{// 注释}}
  time, date, weekday, isotime, isodate, datetimeformat <fmt>
  idle_duration
  /{{time_UTC([-+]\d+)}}/gi
  /{{outlet::(.+?)}}/gi
  timeDiff::a::b, banned "w", random, pick
];

// C. 逐条 replace（单遍，不递归）
for (const macro of macros) {
    if (!content) break;
    if (!macro.regex.source.startsWith('<') && !content.includes('{{')) break;   // 短路
    content = content.replace(macro.regex, (...args) => postProcessFn(macro.replace(...args)));
}
return content;
```

**核心结论**
1. **替换是「一趟线性扫描的宏列表」，不是递归下降。** 每条宏内部用 `String.replace(regex, fn)` 做一次全局替换。
2. **「递归」只来自顺序**：因为 `{{user}}` / `{{char}}` 在 env 批次里（`script.js:2949-2950` 明确注释 "Must be substituted last so that they're replaced inside {{description}}"），而 `{{description}}` 等卡字段也在 env 批次且**注册顺序在 user/char 之前**（`script.js:2926-2946`）。所以 `{{description}}` 展开出的文本里若含 `{{char}}`，会在随后的 env 迭代里被再次替换 → **一级递归**。
3. **每次 `substituteParams` 调用只做一趟**；外层调用者可能对结果再次调用（例如 `getExtensionPrompt` 会对已经注入的 value 再跑一次 `substituteParams`，`script.js:3325-3327`；`preparePrompt` 对 prompt content 跑一次，`PromptManager.js:1285`）。
4. **不区分大小写**：所有宏正则都带 `i` 标志（`{{CHAR}}`、`{{Char}}` 均可）。
5. **短路优化**：内容不含 `{{` 且当前宏并非 `<...>` 形式时**直接 break 整个循环**（不是 continue）——意味着一旦某条宏把内容清空（如 `{{trim}}` 或 `{{//}}` 把整串吃掉），后续宏全部跳过。这是 `if (!content) break;`。
6. `postProcessFn` 对**每一次**宏替换的返回值做后处理，默认恒等。

### 3.3 内置宏完整清单（Legacy 路径）

#### 3.3.1 卡字段 / 环境宏（`env` 批次）

| 宏 | 值 | 来源 |
|---|---|---|
| `{{char}}` | 角色名（`name2`） | `script.js:2950` |
| `{{user}}` | 用户名（`name1`） | `script.js:2949` |
| `{{group}}` / `{{charIfNotGroup}}` | 群聊成员名（含静音）或 `name2` | `script.js:2951`, `2878-2895` |
| `{{groupNotMuted}}` | 群聊成员名（不含静音） | `script.js:2952`, `2878-2895` |
| `{{notChar}}` | 除当前说话者外的成员 + 用户 | `script.js:2897-2922`, `2953` |
| `{{description}}` | 卡 `description`（已 `baseChatReplace`） | `script.js:2928` |
| `{{personality}}` | 卡 `personality` | `script.js:2929` |
| `{{scenario}}` | 卡 `scenario`（或 `chat_metadata.scenario`） | `script.js:2930`, `3445` |
| `{{persona}}` | `power_user.persona_description` | `script.js:2931` |
| `{{mesExamples}}` | `parseMesExamples(fields.mesExamples, isInstruct).join('')`（**函数型**） | `script.js:2932-2940` |
| `{{mesExamplesRaw}}` | 原始 `mes_example` 字符串 | `script.js:2941` |
| `{{charPrompt}}` | 卡 `system_prompt`（仅 `prefer_character_prompt`） | `script.js:2926` |
| `{{charInstruction}}` / `{{charJailbreak}}` | 卡 `post_history_instructions`（仅 `prefer_character_jailbreak`） | `script.js:2927` |
| `{{charDepthPrompt}}` | 卡 `extensions.depth_prompt.prompt` | `script.js:2944` |
| `{{charVersion}}` / `{{char_version}}` | 卡 `character_version` | `script.js:2942-2943` |
| `{{creatorNotes}}` | 卡 `creator_notes` | `script.js:2945` |
| `{{model}}` | `getGeneratingModel()` | `script.js:2954` |
| `{{original}}` | 由调用方传入的 `original`；**只允许替换一次**（第二次起返回 `''`） | `script.js:2866-2876` |
| `{{isMobile}}` | `"true"`/`"false"` | `macros.js:738-741` |
| `{{lastGenerationType}}` | `normal`/`swipe`/`continue`/… | `macros.js:723-737` |
| `{{input}}` | 输入框当前文本 | `macros.js:635` |
| `{{outlet::key}}` | `extension_prompts['customWIOutlet_'+key].value` | `macros.js:596-599`, `668` |

> ⚠️ `{{charPrompt}}`/`{{charInstruction}}`/`{{charJailbreak}}` 在 `_replaceCharacterCard === false` 时**不会**被注入 env（`script.js:2924`）。`baseChatReplace()` 用的正是 `replaceCharacterCard: false`（`script.js:3343`），所以卡字段内部的 `{{charPrompt}}` 不会被替换，但 `{{char}}`/`{{user}}` 会。

#### 3.3.2 时间 / 日期（`postEnv` 批次）

| 宏 | 展开 | 来源 |
|---|---|---|
| `{{time}}` | `moment().format('LT')` → 本地化时间如 `3:42 PM` | `macros.js:660` |
| `{{date}}` | `moment().format('LL')` → 如 `September 14, 2026` | `macros.js:661` |
| `{{weekday}}` | `moment().format('dddd')` → `Monday` | `macros.js:662` |
| `{{isotime}}` | `HH:mm` | `macros.js:663` |
| `{{isodate}}` | `YYYY-MM-DD` | `macros.js:664` |
| `{{datetimeformat <fmt>}}` | `moment().format(fmt)`（**空格**分隔，非 `::`） | `macros.js:665` |
| `{{time_UTC±N}}` | `moment().utc().utcOffset(N).format('LT')` | `macros.js:667` |
| `{{timeDiff::t1::t2}}` | `moment.duration(t1.diff(t2)).humanize(true)` | `macros.js:585-589` |
| `{{idle_duration}}` | 距最后一条「倒数第二条非 system 消息之后由用户发出的消息」的人类化时长，默认 `'just now'` | `macros.js:483-506`, `666` |

#### 3.3.3 聊天历史

| 宏 | 展开 | 来源 |
|---|---|---|
| `{{lastMessage}}` | 最后一条（排除未完成 swipe） | `macros.js:388-391`, `649` |
| `{{lastMessageId}}` | 其索引 | `macros.js:649` |
| `{{lastUserMessage}}` | 最后一条 `is_user && !is_system` | `macros.js:398-401`, `651` |
| `{{lastCharMessage}}` | 最后一条 `!is_user && !is_system` | `macros.js:407-410`, `652` |
| `{{firstIncludedMessageId}}` | `chat_metadata.lastInContextMessageId` | `macros.js:364-366`, `653` |
| `{{firstDisplayedMessageId}}` | DOM 上第一个 `.mes` 的 `mesid` | `macros.js:373-381`, `654` |
| `{{allChatRange}}` | `0-{chat.length-1}`，空聊天为 `''` | `macros.js:657` |
| `{{lastSwipeId}}` / `{{currentSwipeId}}` | 1-based swipe 数 / 当前 swipe | `macros.js:416-433`, `655-656` |

#### 3.3.4 随机 / 骰子 / 工具

| 宏 | 展开 | 来源 |
|---|---|---|
| `{{random:a,b,c}}` / `{{random::a::b}}` | 均匀随机取一项。分隔符：含 `::` 用 `::` 分（**不 trim**）；否则用 `,` 分并 **trim 每项**；`\,` 转义为字面逗号。熵源 `seedrandom('added entropy.', {entropy:true})` → **每次调用都不同** | `macros.js:489-509` |
| `{{pick:a,b,c}}` | 同上但**确定性**：种子 = `hash(chatIdHash + '-' + hash(rawContent) + '-' + matchOffset)`，`chatIdHash` 来自 `chat_metadata.chat_id_hash`（首次 = `getStringHash(chat_metadata.main_chat ?? getCurrentChatId())`） | `macros.js:513-544`, `315-328` |
| `{{roll:1d20}}` / `{{roll 1d20}}` | droll 公式；纯数字 `N` → `1dN`；非法公式返回 `''`；返回 `result.total` 字符串 | `macros.js:549-571` |
| `{{reverse:abc}}` | 按 Unicode code point 反转 | `macros.js:658` |
| `{{newline}}` | `'\n'` | `macros.js:632` |
| `{{trim}}` | 连同**前后紧邻的所有换行**一起删除：正则 `/(?:\r?\n)*{{trim}}(?:\r?\n)*/gi` | `macros.js:633` |
| `{{noop}}` | `''` | `macros.js:634` |
| `{{// 任意文本}}` | `''`（`/\{\{\/\/([\s\S]*?)\}\}/gm`，**跨行**，非贪婪） | `macros.js:659` |
| `{{banned "word"}}` | `''`，并把 word 加入 textgenerationwebui ban list | `macros.js:447-452` |
| `{{maxPrompt}}` / `{{maxPromptTokens}}` | `getMaxPromptTokens()` = context − response | `macros.js:643-644` |
| `{{maxContext}}` / `{{maxContextTokens}}` | `getMaxContextTokens()` | `macros.js:645-646` |
| `{{maxResponse}}` / `{{maxResponseTokens}}` | `getMaxResponseTokens()` | `macros.js:647-648` |

#### 3.3.5 变量宏（`preEnv` 批次，`public/scripts/variables.js:238-261`）

| 宏 | 语义 |
|---|---|
| `{{getvar::name}}` | 读局部变量（`chat_metadata.variables`） |
| `{{setvar::name::value}}` | 写局部变量，展开为 `''` |
| `{{addvar::name::value}}` | 数值/字符串追加，展开为 `''` |
| `{{incvar::name}}` / `{{decvar::name}}` | 自增/自减，返回**新值** |
| `{{getglobalvar::name}}` / `{{setglobalvar::name::value}}` / `{{addglobalvar::…}}` / `{{incglobalvar::…}}` / `{{decglobalvar::…}}` | 同上，作用域 `extension_settings.variables.global` |

正则均为 `/{{...::([^:]+)::([^}]*)}}/gi` 风格 —— 变量名不能含 `:`，值不能含 `}`。

#### 3.3.6 Instruct 宏（仅 instruct 模式相关）

`getInstructMacros(env)`（`public/scripts/macros.js:629`）来自 `public/scripts/instruct-mode.js`，提供 `{{instructInput}}`、`{{instructUserPrefix}}`、`{{instructUserSuffix}}`、`{{instructAssistantPrefix}}`、`{{instructAssistantSuffix}}`、`{{instructFirstAssistantPrefix}}`、`{{instructLastAssistantPrefix}}`、`{{instructSystemPrefix}}`、`{{instructSystemSuffix}}`、`{{instructStop}}`、`{{instructStoryStringPrefix}}` 等。Chat Completion 路径基本用不到。

#### 3.3.7 新引擎额外宏（仅 `experimental_macro_engine = true` 时）

`charDescription`/`charPersonality`/`charScenario`/`charCreatorNotes`/`charFirstMessage`/`greeting`、`if/else`（`{{if cond}}…{{else}}…{{/if}}`）、作用域宏 `{{macro}}…{{/macro}}`、`{{space}}`、`{{hasvar}}`/`{{varexists}}`/`{{getvarkey}}`/`{{setvarkey}}`/`{{deletevar}}`/`{{flushvar}}`、宏 flag（前缀 `!?~#/`）、`{{.localvar}}`/`{{$globalvar}}` 简写、`{{banned}}`、`{{isMobile}}`、`{{hasExtension}}`、`{{systemPrompt}}` 等。注册点见 `public/scripts/macros/definitions/*.js`。

### 3.4 **必须实现的最小宏集合（Swift v1）**

```
{{char}} {{user}} {{description}} {{personality}} {{scenario}} {{persona}}
{{charPrompt}} {{charJailbreak}} {{charDepthPrompt}} {{creatorNotes}}
{{time}} {{date}} {{weekday}} {{isotime}} {{isodate}}
{{newline}} {{trim}} {{noop}} {{// …}}
{{random:a,b}} {{pick:a,b}} {{roll:1d20}}
{{getvar::x}} {{setvar::x::v}} {{getglobalvar::x}} {{setglobalvar::x::v}}
{{original}} {{input}} {{lastMessage}} {{lastUserMessage}} {{lastCharMessage}}
{{maxPrompt}} {{maxContext}} {{maxResponse}} {{model}} {{group}} {{notChar}}
```

### 3.5 大小写与转义

- **全部大小写不敏感**（统一 `gi` / `gim`）。
- Legacy 路径**不做 `{{` 转义/消毒**：用户输入里的 `{{char}}` 会被原样替换。这是 ST 的既有行为（属于「宏注入」问题）。
- `escapeRegex` 用于 env key 构造正则（`public/scripts/utils.js:1377`），意味着**宏名本身按字面量匹配**，`{{char}}` 里的 `char` 不会被当成正则。

### 3.6 宏替换发生的时间点（世界书相关，重要）

| 阶段 | 是否已做宏替换 | 位置 |
|---|---|---|
| WI 条目的 `key` / `keysecondary`（**扫描用**） | ✅ 每个 key 在匹配前 `substituteParams(key).trim()` | `world-info.js:4915`, `4947` |
| WI 条目 `content`（**激活并计入预算时**） | ✅ 就地写回 `entry.content = substituteParams(entry.content)` | `world-info.js:5058` |
| WI `content` 正则后处理 | `getRegexedString(content, WORLD_INFO, {depth, isMarkdown:false, isPrompt:true})` | `world-info.js:5205` |
| 扩展注入（AN / depth / persona） | ✅ `getExtensionPrompt` 里整串再跑一次 `substituteParams` | `script.js:3326` |
| prompt（main/nsfw/jailbreak/…) | ✅ `PromptManager.preparePrompt` → `substituteParams` | `PromptManager.js:1277-1290` |
| 卡字段 | ✅ `baseChatReplace` = `substituteParams(..., replaceCharacterCard:false)` + `collapseNewlines` + 去 `\r` | `script.js:3341-3352` |
| 聊天历史消息 | ❌ 在 `populateChatHistory` 里**不**做宏替换（历史在写入时已替换）；消息在 `generate` 开头 `chat[0].mes = substituteParams(chat[0].mes)` 仅针对欢迎语 | `script.js:4489-4491` |
| `dialogueExamples` 内容 | ❌ 已是替换后的卡字段 | `openai.js:1113-1121` |

---

## 4. 世界书（World Info）触发引擎

### 4.1 数据模型

条目字段定义（`public/scripts/world-info.js:4082-4125`）：

| 字段 | 默认 | 含义 |
|---|---|---|
| `uid` | — | 条目在 book 内的 ID |
| `key` | `[]` | 主关键词（字符串数组） |
| `keysecondary` | `[]` | 次关键词 |
| `comment` | `''` | 备注（不注入） |
| `content` | `''` | 注入正文 |
| `constant` | `false` | **蓝灯**，恒激活 |
| `vectorized` | `false` | 向量化（本规范忽略） |
| `selective` | `true` | 是否检查 `keysecondary`（现版本恒 true） |
| `selectiveLogic` | `0` (AND_ANY) | 次关键词逻辑 |
| `addMemo` | `false` | 编辑器用 |
| `order` | `100` | ** insertion_order，越大越靠前** |
| `position` | `0` (before) | 注入位置枚举 |
| `disable` | `false` | 禁用 |
| `ignoreBudget` | `false` | 不计入 token 预算 |
| `excludeRecursion` | `false` | 递归扫描时跳过 |
| `preventRecursion` | `false` | 不把 content 加入递归缓冲 |
| `matchPersonaDescription` | `false` | 扫描用户人设 |
| `matchCharacterDescription` | `false` | 扫描角色描述 |
| `matchCharacterPersonality` | `false` | |
| `matchCharacterDepthPrompt` | `false` | |
| `matchScenario` | `false` | |
| `matchCreatorNotes` | `false` | |
| `delayUntilRecursion` | `0` | `true`→级别 1；延迟到第 N 级递归才可激活 |
| `probability` | `100` | 激活概率 % |
| `useProbability` | `true` | |
| `depth` | `4` (`DEFAULT_DEPTH`) | atDepth 位置时的深度 |
| `outletName` | `''` | outlet 位置用 |
| `group` | `''` | 互斥组，逗号分隔 |
| `groupOverride` | `false` | 组优先级（`order` 大者胜） |
| `groupWeight` | `100` (`DEFAULT_WEIGHT`) | 组权重随机 |
| `scanDepth` | `null` | 覆写全局扫描深度 |
| `caseSensitive` | `null` | 覆写全局 |
| `matchWholeWords` | `null` | 覆写全局 |
| `useGroupScoring` | `null` | 覆写全局 |
| `automationId` | `''` | 快速编辑用 |
| `role` | `0` (system) | atDepth 时的消息 role |
| `sticky` | `null` | 粘滞 N 条消息 |
| `cooldown` | `null` | 冷却 N 条消息 |
| `delay` | `null` | 前 N 条消息内不激活 |
| `triggers` | `[]` | 生成类型白名单（`normal`/`continue`/`impersonate`/…） |
| `characterFilter` | — | `{names[], tags[], isExclude}` 角色/标签过滤 |

位置枚举（`world-info.js:855-864`）与 role 枚举（`script.js:494-498`）：
```
world_info_position = { before:0, after:1, ANTop:2, ANBottom:3, atDepth:4, EMTop:5, EMBottom:6, outlet:7 }
extension_prompt_roles = { SYSTEM:0, USER:1, ASSISTANT:2 }
world_info_logic = { AND_ANY:0, NOT_ALL:1, NOT_ANY:2, AND_ALL:3 }        # world-info.js:33-38
world_info_insertion_strategy = { evenly:0, character_first:1, global_first:2 }
scan_state = { NONE:0, INITIAL:1, RECURSION:2, MIN_ACTIVATIONS:3 }       # world-info.js:43-60
DEFAULT_DEPTH = 4; DEFAULT_WEIGHT = 100; MAX_SCAN_DEPTH = 1000            # world-info.js:96-98
```

### 4.2 全局设置与默认值（`world-info.js:69-82`）

| 设置 | 默认 | 含义 |
|---|---|---|
| `world_info_depth` | **2** | 扫描聊天历史的深度（条数） |
| `world_info_min_activations` | **0** | >0 时启用「最小激活数」多轮扫描 |
| `world_info_min_activations_depth_max` | **0** | 最小激活扫描的最大深度（0 = 不限） |
| `world_info_budget` | **25** | 预算 = `maxContext * 25%` |
| `world_info_include_names` | **true** | 扫描文本是否 `"{name}: {mes}"` 前缀 |
| `world_info_recursive` | **false** | 递归扫描开关 |
| `world_info_overflow_alert` | false | 超预算 toast |
| `world_info_case_sensitive` | **false** | |
| `world_info_match_whole_words` | **false** | |
| `world_info_use_group_scoring` | false | |
| `world_info_character_strategy` | **1** (character_first) | 角色书 vs 全局书顺序 |
| `world_info_budget_cap` | **0** | 预算绝对上限（token），0 = 无上限 |
| `world_info_max_recursion_steps` | **0** | 递归最大步数；>0 时禁用 min activations |

### 4.3 扫描范围（Scan Buffer）

`chatForWI = coreChat.map(x => world_info_include_names ? `${x.name}: ${x.mes}` : x.mes).reverse()`（`script.js:4624`）
- `coreChat = chat.filter(x => !x.is_system)`；`type === 'swipe'` 时 `pop()` 掉最后一条（`script.js:4496-4499`）。
- **reverse 后索引 0 = 最新消息**，与 `WorldInfoBuffer.#depthBuffer` 一致。

`WorldInfoBuffer`（`world-info.js:199-474`）：
```js
#initDepthBuffer(messages):
    for depth in 0..<MAX_SCAN_DEPTH:            # 1000
        if messages[depth]: #depthBuffer[depth] = messages[depth].trim()
        if depth === messages.length - 1: break
```
- 每条消息 **trim**。
- 扫描文本 `get(entry, scanState)`（`world-info.js:279-328`）：
```js
depth = entry.scanDepth ?? (world_info_depth + skew)
if depth <= startDepth: return ''
if depth < 0: return ''          # 报错
if depth > 1000: depth = 1000    # 告警后截断

MATCHER = '\x01'; JOINER = '\n' + MATCHER
result = MATCHER + #depthBuffer[startDepth..<depth].join(JOINER)

if entry.matchPersonaDescription  && globalScanData.personaDescription:  result += JOINER + …
if entry.matchCharacterDescription && …characterDescription:            result += JOINER + …
if entry.matchCharacterPersonality && …characterPersonality:            result += JOINER + …
if entry.matchCharacterDepthPrompt && …characterDepthPrompt:            result += JOINER + …
if entry.matchScenario            && …scenario:                         result += JOINER + …
if entry.matchCreatorNotes        && …creatorNotes:                     result += JOINER + …

if #injectBuffer.count > 0: result += JOINER + #injectBuffer.join(JOINER)
if #recurseBuffer.count > 0 && scanState != MIN_ACTIVATIONS:
    result += JOINER + #recurseBuffer.join(JOINER)
return result
```
- **`\x01` 是「词边界哨兵」**：让整词匹配正则的 `(?:^|\W)` / `(?:$|\W)` 能识别出拼接边界，避免跨消息误匹配。
- `#injectBuffer` = 所有 `extension_prompts[key].scan === true` 的 prompt 的**已宏替换值**（`world-info.js:4719-4726` + `script.js:3274`）。AN 的 `allowWIScan` 与角色 depth_prompt 的 scan 决定它们是否可被世界书扫描到。
- `#recurseBuffer` = 每轮递归把 `successfulNewEntriesForRecursion.map(content).join('\n')` 追加（`world-info.js:5138-5144`）。

`globalScanData`（`script.js:4625-4634`）：
```
personaDescription   = persona
characterDescription = description
characterPersonality = personality
characterDepthPrompt = charDepthPrompt
scenario             = scenario
creatorNotes         = creatorNotes
trigger              = GENERATE_TYPE_TRIGGERS.includes(type) ? type : 'normal'
```

### 4.4 条目集合的组装与排序 —— `getSortedEntries`

`public/scripts/world-info.js:4590-4644`：
```
[globalLore, characterLore, chatLore, personaLore] = await Promise.all([...])

switch (world_info_character_strategy):
  evenly(0)          : entries = [...globalLore, ...characterLore].sort(sortFn)
  character_first(1) : entries = [...characterLore.sort(sortFn), ...globalLore.sort(sortFn)]   # 默认
  global_first(2)    : entries = [...globalLore.sort(sortFn), ...characterLore.sort(sortFn)]

entries = [...chatLore.sort(sortFn), ...personaLore.sort(sortFn), ...entries]   # 永远最前

# sortFn = (a,b) => b.order - a.order          # order 从大到小
# Array.sort 在 V8 中稳定 → 同 order 保持原插入顺序

entries = entries.map(e => { [decorators, content] = parseDecorators(e.content); return {...e, decorators, content} })
                 .map(e => ({...e, hash: getStringHash(JSON.stringify(e))}))
return structuredClone(entries)
```
- `characterLore` = `characters[this_chid].data.character_book` 的条目（`world-info.js:4475-4526`）
- `globalLore` = 勾选的所有全局世界书条目（`world-info.js:4527-4543`）
- `chatLore` = `chat_metadata[METADATA_KEY]` 指定的聊天书（`world-info.js:4544-4563`）
- `personaLore` = 当前 persona 绑定的书（`world-info.js:4564-4589`）

`parseDecorators`（`world-info.js:4652-4700`）：内容以 `@@` 开头时解析装饰器；已知装饰器只有 `['@@activate','@@dont_activate']`（`world-info.js:100`）。`@@@` 前缀可转义（跳过一层）。

> **扫描顺序 = 上面这个数组的顺序**。它决定了：同 `order` 时的激活优先级、以及预算耗尽时「谁先被计入」。

### 4.5 `checkWorldInfo` 主循环（伪代码）

`public/scripts/world-info.js:4709-5282`：

```
budget = round(world_info_budget * maxContext / 100) || 1
if world_info_budget_cap > 0 && budget > cap: budget = cap                     # :4736-4741

sortedEntries = await getSortedEntries()
timedEffects  = WorldInfoTimedEffects(chat=scanBuffer源, sortedEntries, isDryRun)
timedEffects.checkTimedEffects()                                               # :4745-4747

# delayUntilRecursion 分级
availableRecursionDelayLevels = sorted(unique(sortedEntries.filter(e=>e.delayUntilRecursion)
                                       .map(e => e.delayUntilRecursion === true ? 1 : e.delayUntilRecursion)))
currentRecursionDelayLevel = availableRecursionDelayLevels.shift() ?? 0

scanState = INITIAL; count = 0
allActivatedEntries = Map(); failedProbabilityChecks = Set(); allActivatedText = ''
token_budget_overflowed = false

while scanState != NONE:
    if world_info_max_recursion_steps && world_info_max_recursion_steps <= count: break   # :4768-4771
    count++
    nextScanState = NONE
    activatedNow = Set()

    for entry in sortedEntries:
        # ---------- A. 硬性跳过 ----------
        if failedProbabilityChecks.has(entry) || allActivatedEntries.has(key(entry)): continue  # :4797
        if entry.disable: continue                                                              # :4801
        if entry.triggers 非空 && !entry.triggers.includes(trigger): continue                    # :4807
        if characterFilter.names 非空 且 被过滤: continue                                        # :4816
        if characterFilter.tags  非空 且 被过滤: continue                                        # :4826

        isSticky   = timedEffects.isEffectActive('sticky', entry)
        isCooldown = timedEffects.isEffectActive('cooldown', entry)
        isDelay    = timedEffects.isEffectActive('delay', entry)
        if isDelay: continue                                                                    # :4849
        if isCooldown && !isSticky: continue                                                    # :4854
        if scanState != RECURSION && entry.delayUntilRecursion && !isSticky: continue            # :4860
        if scanState == RECURSION && entry.delayUntilRecursion > currentRecursionDelayLevel
           && !isSticky: continue                                                               # :4865
        if scanState == RECURSION && world_info_recursive && entry.excludeRecursion
           && !isSticky: continue                                                               # :4870

        # ---------- B. 无条件激活 ----------
        if '@@activate' in entry.decorators: activatedNow.add(entry); continue                    # :4875
        if '@@dont_activate' in entry.decorators: continue                                       # :4881
        if externallyActivated(entry): activatedNow.add(...); continue                           # :4886
        if entry.constant: activatedNow.add(entry); continue                                     # :4893  ← 蓝灯
        if isSticky: activatedNow.add(entry); continue                                           # :4899
        if entry.key 为空: continue                                                              # :4905

        # ---------- C. 关键词匹配 ----------
        textToScan = buffer.get(entry, scanState)
        primaryKeyMatch = entry.key.first { k in
            let s = substituteParams(k)
            return !s.isEmpty && buffer.matchKeys(textToScan, s.trim(), entry)
        }
        if primaryKeyMatch == nil: continue                                                      # :4919

        hasSecondary = entry.selective && entry.keysecondary.count > 0
        if !hasSecondary: activatedNow.add(entry); continue                                      # :4930

        # ---------- D. 次关键词逻辑 ----------
        satisfied = matchSecondaryKeys(entry, textToScan)     # 见下
        if !satisfied: continue
        activatedNow.add(entry)

    # ---------- E. 排序（sticky 优先，然后按 sortedEntries 索引）----------
    newEntries = activatedNow.sorted { (stickyOf($0) ? 1:0) > (stickyOf($1) ? 1:0)
                                       || indexIn(sortedEntries,$0) < indexIn(sortedEntries,$1) }  # :4993-5006

    textToScanTokens = await getTokenCountAsync(allActivatedText)
    filterByInclusionGroups(newEntries, allActivatedEntries, buffer, scanState, timedEffects)        # :5012

    # ---------- F. 概率 + 预算 ----------
    ignoresBudget = newEntries.count { $0.ignoreBudget }
    for entry in newEntries:
        ignoresBudget -= entry.ignoreBudget ? 1 : 0
        if token_budget_overflowed && !entry.ignoreBudget:
            if ignoresBudget > 0: continue
            break                                                                                    # :5019-5026
        if !verifyProbability(entry): continue          # useProbability=false 或 probability==100 → true
                                                        # sticky → 不重掷
                                                        # 否则 roll = random()*100，roll <= probability 才过
                                                        #   失败 → failedProbabilityChecks.add(entry)
        entry.content = substituteParams(entry.content)                                              # :5058
        newContent += entry.content + '\n'
        if !entry.ignoreBudget && (textToScanTokens + tokenCount(newContent)) >= budget:
            token_budget_overflowed = true; continue                                                 # :5061-5073
        allActivatedEntries[key(entry)] = entry

    successfulNewEntries = newEntries.filter { !failedProbabilityChecks.has($0) }
    successfulNewEntriesForRecursion = successfulNewEntries.filter { !$0.preventRecursion }

    # ---------- G. 决定下一轮 ----------
    if world_info_recursive && !token_budget_overflowed && successfulNewEntriesForRecursion:
        nextScanState = RECURSION
    if world_info_recursive && !token_budget_overflowed && scanState == MIN_ACTIVATIONS && buffer.hasRecurse():
        nextScanState = RECURSION
    if nextScanState == NONE && !token_budget_overflowed
       && world_info_min_activations > 0 && allActivatedEntries.count < world_info_min_activations:
        over_max = (min_activations_depth_max > 0 && buffer.depth > min_activations_depth_max)
                   || buffer.depth > chat.count
        if !over_max: nextScanState = MIN_ACTIVATIONS; buffer.advanceScan()   # skew++
    if nextScanState == NONE && availableRecursionDelayLevels 非空:
        nextScanState = RECURSION; currentRecursionDelayLevel = availableRecursionDelayLevels.shift()

    scanState = nextScanState
    if scanState != NONE:
        text = successfulNewEntriesForRecursion.map(content).join('\n')
        if !text.isEmpty: buffer.addRecurse(text); allActivatedText = text + '\n' + allActivatedText
    await eventSource.emit(WORLDINFO_SCAN_DONE, args)     # 扩展可改 state.next / budget / text
```

**关键结论**
1. **终止条件**：`scanState == NONE`（`0`）。正常情况下第二轮即 `NONE`（除非 recursive/minActivations/delayUntilRecursion 触发继续）。**递归没有固定上限**，只受 `world_info_max_recursion_steps`（默认 0 = 无限）与 `token_budget_overflowed` 限制。`world_info_max_recursion_steps > 0` 时会**顺带禁用 min activations**（因为 `break` 在循环顶部，见注释 `:4767`）。
2. **预算语义**（`:5061`）：`textToScanTokens + tokenCount(newContent) >= budget`。`textToScanTokens` 是**上一轮结束时的 `allActivatedText`** token 数（`:5010`），`newContent` 是本轮已累积内容。超了就 `token_budget_overflowed = true` 并 `continue`（该条目被丢弃）。
   - **超预算之后的处理是「丢掉当轮所有未插入的非 ignoreBudget 条目」**（`:5021-5025`），但 `ignoreBudget == true` 的条目仍会插入（`ignoresBudget` 计数控制跳过/break）。
   - **后续轮次**：一旦 `token_budget_overflowed`，`RECURSION` 不再启动（`:5097`），循环通常下一轮就结束。且 `:5021` 会在每轮开头直接跳过所有非 ignoreBudget 条目。
   - **哪些条目被丢**：`newEntries` 已按「sticky 优先 → `sortedEntries` 索引升序」排序，所以 **`order` 大、且（同 order 时）在 `getSortedEntries` 里靠前的条目优先保留**。
3. **激活顺序 ≠ 注入顺序**：激活用上面的排序；注入用 §4.6 的 `sortFn`（`order` 降序）+ `unshift`。
4. **宏替换发生在「通过概率检查、插入预算之前」**（`:5058`），并且**写回 `entry.content`**（所以第二次调用同一 entry 不会重复替换——但 `structuredClone` 保证每轮扫描是全新副本）。
5. `WORLDINFO_SCAN_DONE` 事件可修改 `state.next` / `activated.text` / `budget.current` / `budget.overflowed` / `recursionDelay.currentLevel`（`:5175-5186`）。Swift 版若不需要扩展，可省略。

### 4.6 关键词匹配 —— `WorldInfoBuffer.matchKeys`

`public/scripts/world-info.js:337-366`：
```js
matchKeys(haystack, needle, entry) {
    // 1) 正则优先：/pattern/flags
    const keyRegex = parseRegexFromString(needle);
    if (keyRegex) return keyRegex.test(haystack);

    // 2) 大小写
    const caseSensitive = entry.caseSensitive ?? world_info_case_sensitive;
    haystack = caseSensitive ? haystack : haystack.toLowerCase();
    needle   = caseSensitive ? needle   : needle.toLowerCase();

    const matchWholeWords = entry.matchWholeWords ?? world_info_match_whole_words;
    if (matchWholeWords) {
        const keyWords = needle.split(/\s+/);
        if (keyWords.length > 1) return haystack.includes(needle);   // 多词：退化为子串包含
        const regex = new RegExp(`(?:^|\\W)(${escapeRegex(needle)})(?:$|\\W)`);   // 单词：\W 边界
        if (regex.test(haystack)) return true;
    } else {
        return haystack.includes(needle);                            // 子串包含
    }
    return false;
}
```

`parseRegexFromString`（`world-info.js:2901-2926`）：
```js
const m = input.match(/^\/([\w\W]+?)\/([gimsuy]*)$/);
if (!m) return null;                                  // 不是 /…/ 形式
let [, pattern, flags] = m;
if (pattern.match(/(^|[^\\])\//)) return null;        // 未转义的 / → 无效
pattern = pattern.replace('\\/', '/');                // 反转义
try { return new RegExp(pattern, flags); } catch { return null; }
```
- 支持 flags `g i m s u y`。
- **正则 key 会覆盖其它所有选项**（大小写、整词、`selective` 之外的匹配方式）。
- ⚠️ 带 `g` 的正则 `test()` 有 `lastIndex` 状态问题——ST 每次新建 `RegExp`，Swift 实现时用无状态匹配（或每次重置）即可避免。

**次关键词逻辑**（`world-info.js:4943-4978`）：
```js
matchSecondaryKeys():
  hasAnyMatch = false; hasAllMatch = true
  for keysecondary in entry.keysecondary:
      s = substituteParams(keysecondary)
      hasSecondaryMatch = !s.isEmpty && buffer.matchKeys(textToScan, s.trim(), entry)
      if hasSecondaryMatch: hasAnyMatch = true
      if !hasSecondaryMatch: hasAllMatch = false
      // 顺序敏感：AND_ANY / NOT_ALL 在第一个满足/不满足处提前返回
      if selectiveLogic == AND_ANY(0) && hasSecondaryMatch: return true
      if selectiveLogic == NOT_ALL(1) && !hasSecondaryMatch: return true
  if selectiveLogic == NOT_ANY(2) && !hasAnyMatch: return true
  if selectiveLogic == AND_ALL(3) && hasAllMatch:  return true
  return false
```
真值表（`S_i` = 第 i 个次关键词是否命中）：
| logic | 值 | 成立条件 |
|---|---|---|
| AND_ANY | 0 | `∃ i: S_i` |
| NOT_ALL | 1 | `∃ i: ¬S_i`（等价 `¬∀S_i`） |
| NOT_ANY | 2 | `∀ i: ¬S_i` |
| AND_ALL | 3 | `∀ i: S_i` |

> **早期返回的顺序副作用**：`AND_ANY`/`NOT_ALL` 在循环内 `return`，所以即使后面的关键词能改变 `hasAllMatch`，也不影响结果（这两个逻辑本来就不用 `hasAllMatch`）。但 **`NOT_ALL` 的提前返回意味着空 `keysecondary` 不会走到这里**（外层 `hasSecondaryKeywords` 已排除空数组）。

**`constant`（蓝灯）**：在关键词检查之前（`:4893`），任何 `disable/triggers/characterFilter/timed-effect/delayUntilRecursion/excludeRecursion` 检查之后立即激活。**注意：`constant` 条目仍会被 `@@dont_activate`、`failedProbabilityChecks`、`probability`、预算限制影响**；`excludeRecursion` 对它无效（因为不进关键词分支）；`isDelay` 会拦住它。

### 4.7 注入位置与 `depth` 语义

`world-info.js:5203-5263`（**先 `sortFn` 降序，再 `unshift` → 最终数组是 `order` 升序**）：
```js
[...allActivatedEntries.values()].sort((a,b) => b.order - a.order).forEach(entry => {
    regexDepth = entry.position == atDepth ? (entry.depth ?? 4) : null
    content = getRegexedString(entry.content, WORLD_INFO, {depth: regexDepth, isMarkdown:false, isPrompt:true})
    if (!content) return

    switch entry.position:
      before(0)   : WIBeforeEntries.unshift(content)
      after(1)    : WIAfterEntries.unshift(content)
      EMTop(5)    : EMEntries.unshift({position: wi_anchor_position.before(0), content})
      EMBottom(6) : EMEntries.unshift({position: wi_anchor_position.after(1),  content})
      ANTop(2)    : ANTopEntries.unshift(content)
      ANBottom(3) : ANBottomEntries.unshift(content)
      atDepth(4)  : idx = WIDepthEntries.findIndex(e => e.depth == entry.depth ?? 4
                                                     && e.role == entry.role ?? SYSTEM)
                    if idx >= 0: WIDepthEntries[idx].entries.unshift(content)
                    else: WIDepthEntries.push({depth: entry.depth, entries:[content],
                                               role: entry.role ?? SYSTEM})
      outlet(7)   : if !entry.outletName { warn; break }
                    WIOutletEntries[entry.outletName] ??= []; WIOutletEntries[entry.outletName].push(content)
})
worldInfoBefore = WIBeforeEntries.length ? WIBeforeEntries.join('\n') : ''
worldInfoAfter  = WIAfterEntries.length  ? WIAfterEntries.join('\n')  : ''

if shouldWIAddPrompt:                       # AN 当前轮确实要插入时才合并
    originalAN = extensionPrompts['2_floating_prompt'].value
    ANWithWI = `${ANTopEntries.join('\n')}\n${originalAN}\n${ANBottomEntries.join('\n')}`
                 .replace(/(^\n)|(\n$)/g, '')
    context.setExtensionPrompt('2_floating_prompt', ANWithWI,
        chat_metadata.note_position, chat_metadata.note_depth,
        extension_settings.note.allowWIScan, chat_metadata.note_role)
```

**`depth` 语义**（对于 `atDepth` 与所有 `IN_CHAT` 注入）：
- `depth = 0` → 插到**最后一条聊天消息之后**（作为最新的 message，实际由 `populationInjectionPrompts` 的 `splice(0 + totalInserted)` 实现）。
- `depth = n` → 插到**倒数第 n 条消息之前**，即「聊天记录里的第 n 条（从末尾数，1-based）」之前。
  - 严格说：`depthBuffer` 的索引 `d` 对应 `chat[chat.length - 1 - d]`，所以 `depth = n` 的注入位于「最新消息往下数第 n 条」之前。
- 超出聊天长度时 `populationInjectionPrompts` 的 `splice(injectIdx)` 会把消息追加到数组末尾（JS `splice` 越界 index 会被夹到 `length`）。
- `atDepth` 条目在**宏替换**后（`:5058`）还要再过一次正则（`regex_placement.WORLD_INFO`），传入 `depth` 供「按深度生效」的正则使用。

**`position` 的最终落点**

| position | 落点 | 是否受 prompt_order 影响 |
|---|---|---|
| `before`(0) | `worldInfoBefore` 槽位 | ✅ 是（用户可拖动） |
| `after`(1) | `worldInfoAfter` 槽位 | ✅ 是 |
| `ANTop`(2) / `ANBottom`(3) | 拼进 Author's Note 值的前/后 | 间接（AN 的位置/深度/role） |
| `atDepth`(4) | `IN_CHAT` 深度注入（role 可控） | ❌ 否，纯按 depth |
| `EMTop`(5) / `EMBottom`(6) | 示例消息块最前/最后 | 间接（`dialogueExamples` 槽位） |
| `outlet`(7) | `extension_prompts['customWIOutlet_'+name]`，由 `{{outlet::name}}` 取出 | 由取值处决定 |

### 4.8 高级字段

#### `probability` / `useProbability`
- `verifyProbability()`（`:5028-5049`）：`!useProbability || probability == 100` → 直接通过；sticky → 不重掷直接通过；否则 `roll = Math.random()*100`，`roll <= probability` 通过。
- 失败会写入 `failedProbabilityChecks`，**该条目在本轮整个扫描（含所有递归轮）内不再被考虑**（`:4797`）。
- 概率检查发生在**预算检查之前**，所以失败不占预算。

#### `group` / `groupOverride` / `groupWeight` / `useGroupScoring` —— `filterByInclusionGroups`
`world-info.js:5388-5475`：
```
grouped = newEntries.filter(has group).groupBy(group.split(/,\s*/))    # 一个条目可属多组
if empty: return

hasStickyMap = filterGroupsByTimedEffects(grouped, timedEffects, removeEntry)   # :5337
      # 组内若有 sticky → 移除其它所有条目（hasStickyMap[group]=true）
      # 移除组内在 cooldown / delay 的条目
filterGroupsByScoring(grouped, buffer, removeEntry, scanState, hasStickyMap)    # :5292
      # 仅当 world_info_use_group_scoring 或组内某条目 useGroupScoring
      # 且组内无 sticky
      # 对组内有 useGroupScoring 的条目算 buffer.getScore()，低于 maxScore 的移除

for (key, group) in grouped:
    if hasStickyMap[key]: continue
    if allActivatedEntries 已有 group == key 的条目: removeAllBut(group, null); continue
    if group.count <= 1: continue
    prios = group.filter(groupOverride).sort(order desc)
    if prios 非空: removeAllBut(group, prios[0]); continue      # 显式优先级
    totalWeight = Σ (groupWeight ?? 100)
    roll = random()*totalWeight; 累加选中 winner
    if winner == nil: continue
    removeAllBut(group, winner)
```

`getScore(entry, scanState)`（`world-info.js:428-473`）：
```
primaryScore   = entry.key.count { matchKeys(buffer, $0, entry) }
secondaryScore = entry.keysecondary.count { matchKeys(buffer, $0, entry) }
if entry.key.isEmpty: return 0
if keysecondary 非空:
    AND_ANY: return primaryScore + secondaryScore
    AND_ALL: return secondaryScore == keysecondary.count ? primaryScore + secondaryScore : primaryScore
return primaryScore
```

#### `sticky` / `cooldown` / `delay` —— `WorldInfoTimedEffects`
`world-info.js:479-795`，持久化于 `chat_metadata.timedWorldInfo.{sticky,cooldown}[key]`，`key = "{world}.{uid}"`：

```js
#getEntryTimedEffect(type, entry, isProtected) => {
    hash: entry.hash,
    start: chat.length,                      // 以「扫描时的聊天长度」为虚拟时钟
    end:   chat.length + Number(entry[type]),
    protected: !!isProtected
}
```
`checkTimedEffectOfType(type, buffer, onEnded)`（`:619-660`）：
```
for (key, value) in chat_metadata.timedWorldInfo[type]:
    entry = entries.find(e => String(e.hash) === String(value.hash))
    if chat.length <= value.start && !value.protected: 删除并 continue     # 聊天未推进 → 丢弃
    if entry == nil:
        if chat.length >= value.end: 删除
        continue
    if !entry[type]: 删除并 continue                                        # 条目已不再配置该效果
    if chat.length >= value.end: 删除; onEnded(entry); continue
    buffer.push(entry)
```
`delay` 不走 metadata（`:666-675`）：`if entry.delay && chat.length < entry.delay → buffer.push(entry)`（前 `delay` 条消息内不激活）。

`setTimedEffects(activatedEntries)`（`:2740+`）：条目被激活时按需写入 sticky/cooldown（sticky 用 `protected: true`）。
`onEnded.sticky`（`:518-529`）：sticky 结束时若条目有 `cooldown`，**立刻**写入 cooldown（`protected: true`）并 push 进当前 buffer。

`isEffectActive(type, entry)` 即「entry 在 `#buffer[type]` 中」。

#### `delayUntilRecursion`
- `true` → 级别 1；数值 N → 级别 N。
- 非 RECURSION 轮次直接跳过（`:4860`）。
- RECURSION 轮次需 `entry.delayUntilRecursion <= currentRecursionDelayLevel`（`:4865`）。
- 主循环结束时若还有未消费的 level，会强制再跑一轮 RECURSION（`:5129-5133`）。
- `sticky` 可绕过该限制。

#### `@@activate` / `@@dont_activate` 装饰器
内容行首的 `@@activate` 让条目无条件激活（在 `constant` 之前），`@@dont_activate` 无条件跳过。`@@@` 前缀表示转义（不会当作装饰器，但仍被记录为带 `@@` 的装饰器字符串）。`parseDecorators` 只识别这两个（`KNOWN_DECORATORS`）。

### 4.9 世界书引擎 Swift 伪代码骨架

```swift
struct WISettings {
    var depth = 2, minActivations = 0, minActivationsDepthMax = 0
    var budgetPercent = 25, budgetCap = 0
    var includeNames = true, recursive = false
    var caseSensitive = false, matchWholeWords = false, useGroupScoring = false
    var characterStrategy: InsertionStrategy = .characterFirst
    var maxRecursionSteps = 0
}

func checkWorldInfo(chatNewestFirst: [String], maxContext: Int,
                    global: GlobalScanData, settings: WISettings,
                    entries: [WIEntry], timedStore: inout TimedStore,
                    injections: [Int: [String]]) async -> WIPromptResult {
    var budget = max(1, Int((Double(settings.budgetPercent) * Double(maxContext) / 100).rounded()))
    if settings.budgetCap > 0 { budget = min(budget, settings.budgetCap) }

    let buffer = WorldInfoBuffer(messages: chatNewestFirst, global: global,
                                 startDepth: 0, injectBuffer: injections)
    var timed = TimedEffects(chatLength: chatNewestFirst.count, store: timedStore, entries: entries)
    timed.check()

    var delayLevels = Set(entries.filter { ($0.delayUntilRecursion ?? 0) > 0 }
                                 .map { $0.delayUntilRecursion == 1 ? 1 : $0.delayUntilRecursion! }).sorted()
    var currentDelayLevel = delayLevels.isEmpty ? 0 : delayLevels.removeFirst()

    var state: ScanState = .initial
    var count = 0, overflowed = false
    var activated = [String: WIEntry]()          // key = "\(world).\(uid)"
    var failedProbability = Set<String>()
    var allActivatedText = ""

    while state != .none {
        if settings.maxRecursionSteps > 0 && settings.maxRecursionSteps <= count { break }
        count += 1
        var next: ScanState = .none
        var activatedNow = [WIEntry]()

        for e in entries {
            let k = "\(e.world).\(e.uid)"
            if failedProbability.contains(k) || activated[k] != nil { continue }
            if e.disable { continue }
            if !e.triggers.isEmpty && !e.triggers.contains(global.trigger) { continue }
            if filteredByCharacterOrTag(e) { continue }

            let sticky = timed.isActive(.sticky, e), cd = timed.isActive(.cooldown, e)
            let delay = timed.isActive(.delay, e)
            if delay { continue }
            if cd && !sticky { continue }
            if state != .recursion, let lvl = e.delayUntilRecursion, lvl > 0, !sticky { continue }
            if state == .recursion, let lvl = e.delayUntilRecursion, lvl > currentDelayLevel, !sticky { continue }
            if state == .recursion, settings.recursive, e.excludeRecursion, !sticky { continue }

            if e.decorators.contains("@@activate") { activatedNow.append(e); continue }
            if e.decorators.contains("@@dont_activate") { continue }
            if e.constant { activatedNow.append(e); continue }
            if sticky { activatedNow.append(e); continue }
            if e.key.isEmpty { continue }

            let text = buffer.text(for: e, state: state, globalDepth: settings.depth)
            guard let _ = e.key.first(where: { kk in
                let s = substituteParams(kk).trimmed
                return !s.isEmpty && buffer.matchKeys(haystack: text, needle: s, entry: e,
                                                      defaultCS: settings.caseSensitive,
                                                      defaultWW: settings.matchWholeWords)
            }) else { continue }

            if !(e.selective && !e.keysecondary.isEmpty) { activatedNow.append(e); continue }
            if matchSecondaryKeys(e, text: text, buffer: buffer, defaults: settings) {
                activatedNow.append(e)
            }
        }

        var newEntries = activatedNow.sorted { a, b in
            let sa = timed.isActive(.sticky, a) ? 1 : 0, sb = timed.isActive(.sticky, b) ? 1 : 0
            if sa != sb { return sa > sb }
            return (indexIn(entries, a) ?? -1) < (indexIn(entries, b) ?? -1)
        }

        let textToScanTokens = await tokenCount(allActivatedText)
        filterByInclusionGroups(&newEntries, activated, buffer, state, timed)

        var ignoresBudget = newEntries.filter { $0.ignoreBudget }.count
        var newContent = ""
        for e in newEntries {
            ignoresBudget -= e.ignoreBudget ? 1 : 0
            if overflowed && !e.ignoreBudget { if ignoresBudget > 0 { continue } else { break } }
            if !verifyProbability(e, timed, &failedProbability) { continue }
            var content = substituteParams(e.content)
            newContent += content + "\n"
            if !e.ignoreBudget && (textToScanTokens + (await tokenCount(newContent))) >= budget {
                overflowed = true; continue
            }
            activated[k] = e
        }

        let successful = newEntries.filter { !failedProbability.contains("\($0.world).\($0.uid)") }
        let forRecursion = successful.filter { !$0.preventRecursion }

        if settings.recursive && !overflowed && !forRecursion.isEmpty { next = .recursion }
        if settings.recursive && !overflowed && state == .minActivations && buffer.hasRecurse { next = .recursion }
        if next == .none && !overflowed && settings.minActivations > 0 && activated.count < settings.minActivations {
            let overMax = (settings.minActivationsDepthMax > 0 && buffer.depth > settings.minActivationsDepthMax)
                          || buffer.depth > chatNewestFirst.count
            if !overMax { next = .minActivations; buffer.advanceScan() }
        }
        if next == .none && !delayLevels.isEmpty { next = .recursion; currentDelayLevel = delayLevels.removeFirst() }

        state = next
        if state != .none {
            let t = forRecursion.map { $0.content }.joined(separator: "\n")
            if !t.isEmpty { buffer.addRecurse(t); allActivatedText = t + "\n" + allActivatedText }
        }
    }

    // ---- 构建 ----
    var before = [String](), after = [String](), emTop = [String](), emBottom = [String]()
    var anTop = [String](), anBottom = [String](), depthEntries = [(Int, Role, [String])]()
    var outlets = [String: [String]]()
    for e in activated.values.sorted(by: { $0.order > $1.order }) {     // unshift ⇒ 最终升序
        let content = applyRegex(e.content, placement: .worldInfo,
                                 depth: e.position == .atDepth ? (e.depth ?? 4) : nil)
        if content.isEmpty { continue }
        switch e.position {
        case .before:   before.insert(content, at: 0)
        case .after:    after.insert(content, at: 0)
        case .emTop:    emTop.insert(content, at: 0)
        case .emBottom: emBottom.insert(content, at: 0)
        case .anTop:    anTop.insert(content, at: 0)
        case .anBottom: anBottom.insert(content, at: 0)
        case .atDepth:
            let d = e.depth ?? 4, r = e.role ?? .system
            if let i = depthEntries.firstIndex(where: { $0.0 == d && $0.1 == r }) {
                depthEntries[i].2.insert(content, at: 0)
            } else { depthEntries.append((d, r, [content])) }
        case .outlet:
            guard !e.outletName.isEmpty else { continue }
            outlets[e.outletName, default: []].append(content)
        }
    }
    timed.setTimedEffects(Array(activated.values)); timed.cleanUp()
    return WIPromptResult(before: before.joined(separator: "\n"),
                          after: after.joined(separator: "\n"),
                          emEntries: emTop.map { (true, $0) } + emBottom.map { (false, $0) },
                          depthEntries: depthEntries,
                          anBefore: anTop, anAfter: anBottom,
                          outlets: outlets, activated: Array(activated.values))
}
```

---

## 5. Token 计数

### 5.1 架构

```
Message.createAsync / setName / setToolCalls
   → tokenHandler.countAsync({role, content, [name], [tool_calls], [reasoning]})
      → countTokensOpenAIAsync(messages, full=false)              public/scripts/tokenizers.js:846
         → POST /api/tokenizers/openai/count?model=<tokenizerModel>   src/endpoints/tokenizers.js:916
            → tiktoken.encoding_for_model(model) 或 WebTokenizer/SentencePiece
```
- `tokenHandler` 实例：`public/scripts/openai.js:3482`（`new TokenHandler(countTokensOpenAIAsync)`）
- Token 缓存：`tokenCache[chatId][`${model}-${hash(JSON.stringify(message))}`]`（`tokenizers.js:863-881`），本会话内可省略或改为内存 LRU。

### 5.2 模型 → tokenizer 映射

客户端 `getTokenizerModel()`（`public/scripts/tokenizers.js:569-...`）：
| 条件 | 返回 |
|---|---|
| `chat_completion_source == OPENAI` | `oai_settings.openai_model` |
| `AZURE_OPENAI` | `azure_openai_model ?? 'gpt-3.5-turbo'` |
| `DEEPSEEK` | `'deepseek'` |
| OpenRouter | 按 `model.architecture.tokenizer` 映射：`Llama2→llama`、`Llama3→llama3`、`Mistral→mistral`、`Yi→yi`、`Gemini→gemma`、`Qwen→qwen2`、`Cohere→command-r/command-a`；再退化到 id 子串匹配（`gpt-4o`→`gpt-4o`、`gpt-4`→`gpt-4`、`gpt-3.5-turbo`→`gpt-3.5-turbo`、`claude`→`claude`、`jamba`、`deepseek`、`GPT-NeoXT`→`gpt2`） |
| 其他 | 继续向后（Claude/Google/Mistral/Cohere/…各 source 分支） |

服务端 `getTokenizerModel(requestModel)`（`src/endpoints/tokenizers.js:440-527`）：
```
o1 / o1-preview / o1-mini / o3-mini / gpt-5* / gpt-6-astra / o3* / o4-mini → 'o1'   # ⇒ o200k_base
gpt-4o / chatgpt-4o-latest / gpt-4.1 / gpt-4.5                              → 'gpt-4o'
gpt-4-32k → 'gpt-4-32k' ; gpt-4 → 'gpt-4' ; gpt-3.5-turbo-0301 → 同 ; gpt-3.5-turbo → 同
claude → 'claude' ; llama3/llama-3 → 'llama3' ; llama → 'llama' ; mistral → 'mistral'
yi / deepseek / gemma|gemini|learnlm / jamba / qwen2 / command-r / command-a / nemo
default → 'gpt-3.5-turbo'
```
tiktoken 的 `encoding_for_model` 把这些名字解析到 `cl100k_base` / `o200k_base` 等（`src/endpoints/tokenizers.js:529-538`）。
**列出的 `TEXT_COMPLETION_MODELS` 直接原样返回**（`:473-475`）。

### 5.3 **Chat Completion 消息 token 公式（必须逐字复刻）**

`src/endpoints/tokenizers.js:998-1023`：
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
**即：**
```
tokens(message) = 3                          # per-message overhead
                + Σ_over_fields len(encode(value))   # 注意 value 必须可编码；非字符串会抛错并被 catch 忽略
                + (has_name ? 1 : 0)
总数 = Σ tokens(message) + 3                 # tokensPadding（回复引导）
```

**客户端再减 2**：`public/scripts/tokenizers.js:884`
```js
if (!full) token_count -= 2;
```
`Message.createAsync` 调 `countAsync({role, content})` 且 `full` 为 `undefined` ⇒ **`full = false`**（`openai.js:3461-3462` 透传，`openai.js:3562` 未传 full）。
所以单条消息的净开销是：

```
messageTokens(role, content, name?) =
     3 (per-message) + len(encode(role)) + len(encode(content)) + (name ? 1 + len(encode(name)) : 0)
   + 3 (padding)
   - 2 (客户端修正)
   = len(encode(role)) + len(encode(content)) + (name ? 1 + len(encode(name)) : 0) + 4
```
**示例**：`role = "system"`（1 token）→ `contentTokens + 5`；`role = "user"`（1 token）→ `contentTokens + 5`；`role = "assistant"`（1 token）→ `contentTokens + 5`。

`tokensPerName = 1` 对非 `gpt-3.5-turbo-0301`；命中 `0301` 时 `tokensPerMessage = 4`、`tokensPerName = -1`、外加 `+9`。

图片：`Message.tokensPerImage = 85`（`public/scripts/openai.js:3512`），在 `addImage` 中累加（本地近似，非真实计费）。
视频/音频：见 `openai.js:3637+` 的 `addVideo` / `addAudio`。

### 5.4 无 tokenizer 的近似算法（Swift 必用）

**客户端 `guesstimate`**（`public/scripts/tokenizers.js:166-169`）：
```js
const BYTES_PER_TOKEN = 3.35;                        // tokenizers.js:12
export function guesstimate(str) {
    const byteLength = textEncoder.encode(str).length;   // UTF-8 字节数
    return Math.ceil(byteLength / BYTES_PER_TOKEN);
}
```
服务端 catch 分支也用 `guesstimate(JSON.stringify(req.body))`（`src/endpoints/tokenizers.js:1030-1033`）。
WebTokenizer 失败时：`countWebTokenizerTokens` 里 `if (!tokenizer) return guesstimate(jsonBody)`，其中 `jsonBody = messages.flatMap(x => Object.values(x)).join('\n\n')`（`src/endpoints/tokenizers.js:546-556`）。

**Swift 建议**：
```swift
let BYTES_PER_TOKEN = 3.35
func guesstimate(_ s: String) -> Int {
    Int(ceil(Double(s.utf8.count) / BYTES_PER_TOKEN))
}
func messageTokens(_ role: String, _ content: String, name: String? = nil) -> Int {
    guesstimate(role) + guesstimate(content) + (name.map { 1 + guesstimate($0) } ?? 0) + 4
}
```
若要更准，可内置 `cl100k_base`/`o200k_base` 的 BPE 表（ST 本体依赖 `tiktoken` wasm/native，Swift 端可用一段精简 BPE 实现或直接走服务端 `/api/tokenizers/openai/count`）。

### 5.5 上下文与预算

```
getMaxContextTokens()  = oai_settings.openai_max_context         # script.js:5956-5957
getMaxResponseTokens() = oai_settings.openai_max_tokens          # script.js:5970-5971
getMaxPromptTokens()   = getMaxContextTokens() - getMaxResponseTokens()   # script.js:5981-5987
this_max_context       = getMaxPromptTokens()                    # script.js:4560  ← 传给 getWorldInfoPrompt 的 maxContext
ChatCompletion.setTokenBudget(context, response):
    tokenBudget = context - response                             # openai.js:3982-3989
    # 调用处：chatCompletion.setTokenBudget(userSettings.openai_max_context,
    #                                       userSettings.openai_max_tokens)   openai.js:1567
```
默认 preset：`openai_max_context = 4095`、`openai_max_tokens = 300`（`default/content/presets/openai/Default.json:36-37`）。

世界书预算：`budget = round(world_info_budget * maxContext / 100) || 1`，再被 `world_info_budget_cap` 夹住（`world-info.js:4736-4741`）。传入的 `maxContext` 是 `this_max_context`（= prompt 预算，不含 response）。

---

## 6. Chat History 裁剪与预算控制

### 6.1 预算记账模型

`ChatCompletion` 内部维护一个**整数 token 预算**，所有「放入 / 预留」都直接加减（`public/scripts/openai.js:4199-4240`）：
```js
canAfford(m)    = 0 <= tokenBudget - m.getTokens()
canAffordAll(ms)= 0 <= tokenBudget - Σ ms.getTokens()
reserveBudget(x)= tokenBudget -= (typeof x === 'number' ? x : x.getTokens())
freeBudget(x)   = tokenBudget += x.getTokens()
checkTokenBudget(m, id): if !canAfford(m) throw TokenBudgetExceededError(id)   // 用于 add/insert
```

**预留/释放的完整顺序**（按时间）：

| 阶段 | 动作 | 代码 |
|---|---|---|
| 1 | `reserveBudget(3)` 回复引导符 | `openai.js:1210` |
| 2 | `add(worldInfoBefore/main/worldInfoAfter/charDescription/charPersonality/scenario/personaDescription)` — 每条都 `checkTokenBudget` → 不够直接抛 `TokenBudgetExceededError`（**强制 prompt 放不下就报错 "Mandatory prompts exceed the context size."**，`openai.js:1589-1592`） | `openai.js:1212-1218` |
| 3 | `reserveBudget(controlPrompts)`（impersonate + quietPrompt） | `openai.js:1238` |
| 4 | `add` nsfw/jailbreak/其余相对 prompt/enhanceDefinitions/bias | `openai.js:1255-1263` |
| 5 | 工具 token 预留（有工具时） | `openai.js:1310-1316` |
| 6 | `continue` 前置消息预留 | `openai.js:1330` |
| 7 | `add(new MessageCollection('chatHistory'), index)` → **只占槽位不占 token**（空集合） | `openai.js:890` |
| 8 | `reserveBudget(newChatMessage)` 为「新聊天提示」预留 | `openai.js:895` |
| 9 | `reserveBudget(groupNudgeMessage)`（群聊） | `openai.js:902` |
| 10 | `reserveBudget(continueMessageCollection)`（continue） | `openai.js:926` |
| 11 | 若最后一条是 assistant 且有 `send_if_empty` 且 `canAfford` → `insert(emptyUserMessageReplacement, 'chatHistory')`（追加到**末尾**） | `openai.js:929-933` |
| 12 | **从新到旧逐条插入**，`canAfford` 失败即 `break` | `openai.js:948-1075` |
| 13 | `freeBudget(newChatMessage)` 然后 `insertAtStart(newChatMessage, 'chatHistory')` | `openai.js:1078-1079` |
| 14 | 群聊 nudge：`freeBudget` + `insertAtEnd` | `openai.js:1082-1085` |
| 15 | continue nudge collection：`freeBudget` + `add(collection, -1)` 追加到末尾 | `openai.js:1088-1091` |
| 16 | `add(dialogueExamples)` + 逐块 `canAffordAll`，放不下 `break` | `openai.js:1106-1133` |
| 17 | `freeBudget(controlPrompts)` + `add(controlPrompts)` | `openai.js:1345-1346` |

### 6.2 Chat History 裁剪算法（核心）

`populateChatHistory`（`public/scripts/openai.js:885-1092`）：
```js
// 逆序遍历（index 0 = 最新消息）
const chatPool = [...messages].reverse();
for (let index = 0; index < chatPool.length; index++) {
    const chatPrompt = chatPool[index];
    const prompt = new Prompt(chatPrompt);
    prompt.identifier = `chatHistory-${messages.length - index}`;
    const chatMessage = await Message.fromPromptAsync(promptManager.preparePrompt(prompt));
    if (names_behavior === COMPLETION && prompt.name) {
        await chatMessage.setName(isValidName(name) ? name : sanitizeName(name));
    }
    /* 媒体内联、tool invocations 处理（略） */
    if (chatCompletion.canAfford(chatMessage)) {
        chatCompletion.insertAtStart(chatMessage, 'chatHistory');   // ← 新消息插到最前 = 最旧位置
    } else {
        break;                                                       // ← 立即停止，不尝试更旧的消息
    }
}
chatCompletion.freeBudget(newChatMessage);
chatCompletion.insertAtStart(newChatMessage, 'chatHistory');          // newMainChat 永远保留（在新历史之前）
```

**结论（Swift 必须一致）**
1. **按从新到旧的顺序逐条尝试**，遇到第一条放不下的消息就 `break`——所有更旧的消息一律丢弃。**没有「跳过太长的单条消息继续试更旧的」逻辑**。
2. **被丢弃的是最旧的消息**；保留的是最新的连续后缀。
3. **`chatHistory` 槽位内部顺序**：由于不断 `insertAtStart`，最终 `collection` 的顺序是**正序（旧 → 新）**。`newMainChat` 最后 `insertAtStart`，所以它排在**所有历史消息之前**（即聊天历史的开头）。
4. **`newMainChat`（`oai_settings.new_chat_prompt`，默认 `"[Start a new Chat]"`，群聊用 `new_group_chat_prompt`）永远会被插入**——它的预算在循环前就已预留（`:895`），所以即使完全没有空间，它也会出现在历史开头。它还是 `squashSystemMessages` 的排除项（`openai.js:3923`）。
5. **没有 message 级别的截断**：`populateChatHistory` 不裁剪单条消息内容。单条超长消息只会导致自己（及其之前的所有更旧消息）被丢弃。
6. **`main` / `worldInfoBefore` / `worldInfoAfter` / `charDescription` / `charPersonality` / `scenario` / `personaDescription` / `nsfw` / `jailbreak` / `enhanceDefinitions` 都是「强制 prompt」**：`add()` 里 `canAfford` 失败会**抛异常**从而整次生成失败，而不是丢弃。它们不参与裁剪。
7. **`dialogueExamples` 的裁剪是「整块」的**：`canAffordAll([newChat, ...block])` 失败 → `break`，后续所有块都丢弃（`openai.js:1124-1126`）。
8. **`pin_examples` 的效果**：`power_user.pin_examples = true` 时**先**放 examples 再放 history（`openai.js:1337-1339`），即 examples 优先占预算，历史更容易被裁掉。默认 `false`（`power-user.js:121`）。

### 6.3 "Unlimited context" / "Pin" 概念

| 概念 | 实现 | 位置 |
|---|---|---|
| `oai_settings.max_context_unlocked` | 预设字段，控制 UI 是否允许把 `openai_max_context` 设到超过默认上限（**不改变组装算法**，只影响设置输入范围） | `default/content/presets/openai/Default.json:53` |
| **无真正的 "unlimited context"** | — | — |
| **无消息级 "pin" 标志** | 裁剪是纯 token 预算驱动的，没有 `pinned` 字段 | — |
| `power_user.pin_examples` | 只调整 examples 与 history 的**插入顺序**（examples 优先） | `openai.js:1337`; `power-user.js:121` |
| `power_user.strip_examples` | Text Completion 路径用（story string 后清空 `mesExamplesArray`）；**Chat Completion 不使用** | `script.js:4738` |
| `ignoreBudget`（世界书条目字段） | 该条目**不计入** WI token 预算，且预算溢出后仍会插入 | `world-info.js:5017-5026`, `5061` |
| `MAX_INJECTION_DEPTH = 10000` | 深度注入的扫描上限 | `script.js:500` |

> 若 iOS 版要做「unlimited context」，需自行设计；ST 原版没有该行为。

### 6.4 裁剪伪代码（Swift）

```swift
struct ChatCompletion {
    var tokenBudget: Int
    var slots: [Slot] = []          // Slot = .message(Message) | .collection(MessageCollection)

    mutating func setTokenBudget(context: Int, response: Int) { tokenBudget = context - response }
    func canAfford(_ m: Tokened) -> Bool { tokenBudget - m.tokens >= 0 }
    mutating func reserve(_ n: Int) { tokenBudget -= n }
    mutating func free(_ n: Int) { tokenBudget += n }

    mutating func add(_ item: SlotContent, at position: Int?) throws {
        guard canAfford(item) else { throw TokenBudgetExceeded(item.identifier) }  // 强制项失败 = 抛错
        if let p = position, p != -1 { slots[p] = item } else { slots.append(item) }
        tokenBudget -= item.tokens
    }

    mutating func insert(_ m: Message, into identifier: String, atStart: Bool = false) throws {
        guard canAfford(m) else { throw TokenBudgetExceeded(m.identifier) }
        let idx = slots.firstIndex { $0.identifier == identifier }!
        if m.content.isEmptyOrNil && m.toolCalls == nil { return }   // 空消息被忽略
        if atStart { slots[idx].collection.insert(m, at: 0) } else { slots[idx].collection.append(m) }
        tokenBudget -= m.tokens
    }
}

// 历史填充
func populateChatHistory(messages: [Prompt], ...) async throws {
    try chat.add(collection: .init("chatHistory"), at: prompts.index("chatHistory"))
    let newChat = Message(role: "system", content: substituteParams(newChatPrompt), id: "newMainChat")
    chat.reserve(newChat.tokens)                          // 先预留，保证一定能放下

    var history: [Message] = []
    for p in messages.reversed() {                        // 0 = 最新
        let m = try await Message.fromPrompt(...)
        guard chat.canAfford(m) else { break }            // ← 遇阻即停，更旧的全丢
        history.insert(m, at: 0)                          // insertAtStart
        chat.tokenBudget -= m.tokens
    }
    chat.free(newChat.tokens)
    history.insert(newChat, at: 0)                        // newMainChat 永远在最前
    // 群聊 nudge → append 到末尾；continue nudge → 追加到数组末尾（新槽位）
}
```

---

## 7. Swift 实现优先级建议

| 阶段 | 必须实现 | 说明 |
|---|---|---|
| **P0** | `Message`/`MessageCollection`/`ChatCompletion` 槽位模型 + 预算加减 + `populateChatCompletion` 的 22 步顺序 + `populateChatHistory` 裁剪 + `populationInjectionPrompts` | 这是「能不能跑通」的核心 |
| **P0** | `substituteParams`（Legacy 宏列表 + 大小写不敏感 + 线性单趟 + env 顺序） | 最小宏集见 §3.4 |
| **P0** | `parseMesExamples` + `parseExampleIntoIndividual` + `populateDialogueExamples` | 注意 role 一律 `system` + `name = example_user/example_assistant` |
| **P0** | WI 引擎：`getSortedEntries` + 主循环（constant/keys/secondary/logic/budget/position/depth） | §4.5/§4.9 |
| **P1** | WI 高级：`probability` / `group` / `sticky` / `cooldown` / `delay` / `delayUntilRecursion` / `@@` 装饰器 | §4.8 |
| **P1** | `guesstimate` + Chat Completion 消息开销公式（+4 净开销） | §5.3/§5.4 |
| **P1** | `formatWorldInfo`（`wi_format`）、`scenario_format`、`personality_format` | `stringFormat` |
| **P2** | `squashSystemMessages`、`continue` 系列（`continue_prefill`/`continue_postfix`）、群聊 nudge、`shouldWIAddPrompt` 的 AN 合并 | |
| **P2** | 新宏引擎（`{{if}}`、作用域宏、变量简写） | 实验特性，可延后 |
| **P3** | tool calling / 媒体内联 / reasoning signature / vectors / summary | 非核心 |

### 已知陷阱清单
1. `populationInjectionPrompts` 的 `messages.reverse()` 与 `depth + totalInserted` 索引补偿必须一起复刻，否则深度注入全错位。
2. `getExtensionPrompt` 内部 prompt **按 key 字典序** 拼接，不是按注册顺序。
3. `world_info_position` 的 `unshift` + `order` 降序遍历 ⇒ 最终 `worldInfoBefore` 字符串里是 **`order` 升序**。
4. `parseExampleIntoIndividual` **跳过块的第一行**，且 `setOpenAIMessageExamples` 已把 `<START>` 换成 `{Example Dialogue:}`。
5. `{{trim}}` 会吃掉前后换行；`{{//}}` 跨行且非贪婪。
6. Legacy 宏**不递归**，跨宏展开只发生在 env 批次内部的顺序依赖上。
7. `Message` 的 token 数在 `createAsync` / `setName` / `setToolCalls` 时算一次并**缓存**；`setName` 会重算（带上 `name` 与 `+1`）。
8. `microtime` 无关，但 `{{time}}` 用 `moment().format('LT')`，Swift 需用当前 locale 的短时间格式（`DateFormatter.timeStyle = .short`）。
9. `{{date}}` 用 `moment().format('LL')` ⇒ `DateFormatter.dateStyle = .long`。
10. 世界书 `get()` 用的 `depth` 是 **`scanDepth ?? (world_info_depth + skew)`**，`skew` 只在 min activations 时递增。
11. `filterByInclusionGroups` 会**修改 `newEntries` 数组**（`splice`），影响后续预算处理的顺序。
12. WI 预算检查用的是 `>= budget`（不是 `>`），所以正好等于预算时也会溢出。

---

## 8. 参考索引

| 主题 | 文件:行 |
|---|---|
| 消息组装主流程 | `public/scripts/openai.js:1185-1347` |
| prompt 构造与合并 | `public/scripts/openai.js:1367-1516` |
| `prepareOpenAIMessages` | `public/scripts/openai.js:1542-1624` |
| 深度注入 | `public/scripts/openai.js:810-875` |
| 示例解析 | `public/scripts/openai.js:729-787`, `656-667`, `1101-1134` |
| 历史填充与裁剪 | `public/scripts/openai.js:885-1092` |
| `Message` / `MessageCollection` / `ChatCompletion` | `public/scripts/openai.js:3511-3566`, `3808-3905`, `3917-4268` |
| `TokenHandler` | `public/scripts/openai.js:3420-3482` |
| `parseMesExamples` | `public/script.js:3501-3515` |
| `getCharacterCardFields` | `public/script.js:3402-3494` |
| `baseChatReplace` | `public/script.js:3341-3352` |
| `substituteParams` 分发 | `public/script.js:2981-3015` |
| `substituteParamsLegacy` env 构造 | `public/script.js:2831-2961` |
| `evaluateMacros`（宏表） | `public/scripts/macros.js:610-714` |
| 变量宏 | `public/scripts/variables.js:238-261` |
| `getExtensionPrompt` | `public/script.js:3301-3329` |
| `setExtensionPrompt` / `inject_ids` | `public/script.js:8926-8935`, `public/scripts/constants.js:48-56` |
| AN 频率/位置/角色 | `public/scripts/authors-note.js:324-392`, `271-322` |
| WI 主循环 | `public/scripts/world-info.js:4709-5282` |
| WI Buffer / 匹配 | `public/scripts/world-info.js:199-474` |
| WI 条目定义 | `public/scripts/world-info.js:4082-4125` |
| WI 排序 | `public/scripts/world-info.js:4590-4644` |
| WI 分组/加权 | `public/scripts/world-info.js:5292-5475` |
| WI 定时效果 | `public/scripts/world-info.js:479-795` |
| WI 注入构建 | `public/scripts/world-info.js:5189-5282` |
| 正则 key 解析 | `public/scripts/world-info.js:2901-2926` |
| 预设顺序 | `default/content/presets/openai/Default.json:129-289` |
| Token 服务端公式 | `src/endpoints/tokenizers.js:998-1023`, `916-1035` |
| Tokenizer 映射 | `src/endpoints/tokenizers.js:440-538`, `public/scripts/tokenizers.js:569-...` |
| `guesstimate` | `public/scripts/tokenizers.js:12`, `166-169` |
| 预算/上下文 | `public/script.js:5929-5987`, `public/scripts/openai.js:3982-3989` |
