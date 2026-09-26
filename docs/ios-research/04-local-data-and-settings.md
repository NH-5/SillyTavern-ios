# SillyTavern 本地数据存储结构与设置项研究

> 目的：为 Swift / iOS 离线版 SillyTavern 的持久化层（SwiftData / JSON 文件）提供设计依据。
> 来源：本仓库 `dsh` 分支源码（只读）。所有结论均标注 `文件:行号`。
> 研究日期：基于当前工作区快照。

---

## 0. 全局结论（TL;DR）

| 结论 | 依据 |
|---|---|
| 所有用户数据都在 `data/<handle>/` 下，`handle` 默认是 `default-user` | `src/users.js:683-696`、`src/constants.js:54-62` |
| 聊天记录是 **JSONL**（每行一个 JSON 对象，`\n` 连接，无尾随换行） | `src/endpoints/chats.js:532-533` |
| 第 1 行永远是 `chat_metadata` 头，不是消息 | `public/script.js:7427-7442`、`public/global.d.ts:50-56` |
| 角色卡 = PNG 图片 + `tEXt` chunk（key `chara` / `ccv3`，值为 base64 的 JSON） | `src/character-card-parser.js:15-78` |
| 角色 = `characters/<name>.png`，`avatar` 字段就是文件名（含 `.png`），聊天目录名 = 去掉 `.png` | `src/endpoints/characters.js:1032-1035`、`src/endpoints/chats.js:548-551` |
| 世界书 = `worlds/<name>.json`，顶层 `{"entries": {...}}`，**entries 是「以 uid 为 key 的对象」而非数组** | `src/endpoints/worldinfo.js:17-35, 144-154`、`public/scripts/world-info.js:4082-4149` |
| 设置 = `data/<handle>/settings.json`，单文件、巨大的扁平 JSON | `src/endpoints/settings.js:206-216`、`src/constants.js:9` |
| Persona 名称就是全局 `username`（= prompt 里的 `name1`），头像文件在 `User Avatars/` | `public/scripts/personas.js:100, 522-530, 902-905` |
| 备份：设置快照 `backups/settings_<handle>_<ts>.json`；聊天备份 `backups/chat_<角色名 key>_<ts>.jsonl`；全量备份 = 用户目录 zip | `src/endpoints/settings.js:88-90,136-156`、`src/endpoints/chats.js:32-81`、`src/users.js:1148-1183` |

---

## 1. 目录结构

### 1.1 服务器侧根目录

| 路径 | 说明 | 依据 |
|---|---|---|
| `data/` | DATA_ROOT（可用 `--dataRoot` 改），当前仓库内只有 `.gitkeep` | `data/.gitkeep`、`src/server-main.js:268` |
| `data/_storage/` | 用户账号（lowdb 风格 JSON 存储） | `src/users.js:556-562` |
| `data/_uploads/` | multer 上传临时目录（处理完即删） | `src/constants.js:219`、`src/server-main.js:268`、`src/users.js:198-217` |
| `data/_cache/` | tokenizer / 模型缓存 | `src/endpoints/tokenizers.js:97`、`src/transformers.js:89` |
| `data/_errors/`、`data/_css/` | 自定义错误页、user.css | `src/users.js:491-531` |
| `default/content/` | 出厂内容（主题、预设、背景、示例世界书 Eldoria.json、settings.json 模板） | `default/content/`、`src/endpoints/content-manager.js:17-19` |
| `default/scaffold/` | 启动时给所有用户强制复制的内容 | `default/scaffold/README.md` |

### 1.2 每个用户的目录模板（`data/<handle>/…`）

来源：`src/constants.js:16-48`（`USER_DIRECTORY_TEMPLATE`），拼接逻辑 `src/users.js:683-696`。

```
data/<handle>/
├── settings.json            # 全部前端设置（唯一入口）
├── secrets.json             # API key（SECRETS_FILE，后端持有；iOS 应放 Keychain）
├── characters/              # 角色卡 PNG（枚举来源）
├── chats/<avatar>/          # 每个角色的聊天目录，<avatar> = 角色文件名去掉 .png
│   └── <chatname>.jsonl
├── group chats/             # 群聊 <chat_id>.jsonl
├── groups/                  # 群定义 <id>.json
├── worlds/                  # 世界书 <name>.json
├── User Avatars/            # persona 头像 PNG
├── user/images/             # 用户上传图片
├── user/files/              # 聊天附件
├── user/workflows/          # ComfyUI 工作流
├── backgrounds/             # 背景图
├── themes/                  # 主题 <name>.json
├── OpenAI Settings/         # Chat Completion 预设
├── TextGen Settings/        # Text Completion 预设
├── KoboldAI Settings/       # Kobold 预设
├── NovelAI Settings/        # NovelAI 预设
├── instruct/ context/ sysprompt/ reasoning/   # Instruct/上下文/系统提示/推理模板
├── QuickReplies/ movingUI/  # 快速回复、UI 布局预设
├── assets/                  # 扩展资源
├── vectors/                 # 向量库（RAG）
├── thumbnails/{bg,avatar,persona}/   # 缩略图缓存（可重新生成）
└── backups/                 # 设置快照 + 聊天备份
```

> iOS 建议：`thumbnails/`、`_cache/`、`_uploads/` 属于可丢弃缓存，不需要迁移；`characters/`、`chats/`、`group chats/`、`groups/`、`worlds/`、`User Avatars/`、`settings.json`、`themes/`、各预设目录是「用户资产」。

---

## 2. 聊天记录格式（JSONL）⭐

### 2.1 路径与命名

| 项 | 规则 | 依据 |
|---|---|---|
| 单聊路径 | `data/<handle>/chats/<avatar 去 .png>/<chatname>.jsonl` | `src/endpoints/chats.js:548-551, 592-614` |
| 群聊路径 | `data/<handle>/group chats/<chat_id>.jsonl` | `src/endpoints/chats.js:878-935`、`src/endpoints/groups.js:120-121,218` |
| `chatname` 来源 | 角色卡的 `chat` 字段，默认 `<角色名> - <humanizedDateTime>`（如 `Seraphina - 2025-09-26@15h04m33s123ms`） | `src/endpoints/characters.js:489, 590`、`public/scripts/RossAscends-mods.js:169-185` |
| 文件名安全化 | 服务端 `sanitize-filename`；重名时 `getUniqueName` 加数字后缀 | `src/endpoints/chats.js:550-551`、`src/endpoints/characters.js:1543-1547` |
| 目录自动创建 | `GET /api/chats/get` 时若目录不存在则创建 | `src/endpoints/chats.js:599-605` |
| 序列化 | `chatData.map(m => JSON.stringify(m)).join('\n')`，**没有结尾换行** | `src/endpoints/chats.js:532-533`（测试同样实现：`tests/chat-integrity.test.js:44-46`） |
| 写入方式 | `write-file-atomic`（原子替换，避免半截文件） | `src/endpoints/chats.js:541` |

### 2.2 第 1 行：chat 头（ChatHeader）

```json
{"chat_metadata": { ... }, "user_name": "unused", "character_name": "unused"}
```

| 字段 | 类型 | 值/默认 | 说明 | 依据 |
|---|---|---|---|---|
| `chat_metadata` | object | `{}` | 聊天级元数据，见 2.3 | `public/global.d.ts:50-56` |
| `user_name` | string | 固定 `"unused"` | **已废弃**，仅向后兼容 | `public/global.d.ts:52-53` |
| `character_name` | string | 固定 `"unused"` | **已废弃**，仅向后兼容 | `public/global.d.ts:54-55` |

> ⚠️ 任务中提到的 `create_date` / `chat_id` **在当前版本不写入 chat 头**（全仓库 `src/endpoints/chats.js` 与 `search.js` 中无该字段写入）。它们属于旧版 ST / 其他客户端的历史字段。iOS 解析器应「容忍但不依赖」：遇到时忽略即可。
> 读取端判定头部的逻辑是：第 1 行含 `chat_metadata` 对象即视为头部（`src/endpoints/chats.js:459-464`、`public/scripts/group-chats.js:272`）。

### 2.3 chat_metadata 的已知 key

| key | 类型 | 默认 | 语义 | 依据 |
|---|---|---|---|---|
| `integrity` | string (uuid v4) | 载入时若无则生成 | 乐观并发校验：保存时若与磁盘上的不一致则拒绝写入 | `public/script.js:7665-7667`、`src/endpoints/chats.js:337-368, 532-543` |
| `tainted` | boolean | `false` | 聊天已被修改（相对于角色卡初始问候），用于决定是否重新插入 first_mes | `public/script.js:1687, 6932`、`public/global.d.ts:59` |
| `scenario` | string | `''` | 本聊天覆盖角色卡的 scenario | `public/script.js:9002, 9051` |
| `mes_example` | string | `''` | 本聊天覆盖对话示例 | `public/script.js:9003, 9052` |
| `system_prompt` | string | `''` | 本聊天覆盖角色卡 system_prompt | `public/script.js:9004, 9053` |
| `persona` | string | 无 | 锁定到本聊天的 persona 头像文件名 | `public/scripts/personas.js:900, 936`、`public/global.d.ts:62` |
| `world_info` | string | 无 | 本聊天绑定的「聊天世界书」名称（`METADATA_KEY`） | `public/scripts/world-info.js:94, 1014, 1168` |
| `timedWorldInfo` | object | `{}` | 世界书 sticky/cooldown/delay 的运行态 | `public/scripts/world-info.js:560-567` |
| `note_prompt` / `note_interval` / `note_depth` / `note_position` / `note_role` | string/number | — | Author's Note（作者注）在每个聊天里的状态 | `public/scripts/authors-note.js:30-36` |
| `attachments` | array | `[]` | 聊天级附件（文件/图片） | `public/scripts/chats.js:1490, 1759-1760` |
| `main_chat` | string | 无 | 该文件是从哪个聊天分支/书签出来的（父聊天名） | `public/scripts/bookmarks.js:201, 284` |
| `lastInContextMessageId` | number | 无 | 最后一条进入上下文的 message id（用于「继续」定位） | `public/script.js:6100` |
| 其他 | any | — | `ChatMetadata` 定义为开放对象，扩展可自由加 key | `public/global.d.ts:58-64` |

### 2.4 消息行完整字段表（ChatMessage）

权威类型声明：`public/global.d.ts:66-128`（`ChatMessage` / `SwipeInfo` / `BaseMessageExtra`）。

| 字段 | 类型 | 是否存在/默认 | 语义 | 依据 |
|---|---|---|---|---|
| `name` | string | AI 消息=角色名；用户消息=`name1` | 显示名（群聊里是发言成员名） | `public/script.js:6746, 5878` |
| `is_user` | boolean | 用户消息 `true`，AI 消息 `false` | 消息来源 | `public/script.js:6747, 5879` |
| `is_system` | boolean | 通常省略；系统消息 `true` | 系统/提示类消息，**导出 txt 时被跳过**，某些场合不进 prompt | `public/script.js:5880`、`public/scripts/system-messages.js:39-41`、`src/endpoints/chats.js:728` |
| `send_date` | string (ISO 8601) | 必填 | `new Date().toISOString()`，如 `2025-09-26T07:04:33.123Z` | `public/scripts/RossAscends-mods.js:192-195` |
| `mes` | string | 必填（可为 `''`） | 消息正文（已做宏替换） | `public/script.js:6757, 5882` |
| `title` | string | 可选（`''`） | 消息标题（用于 continue / 特殊 UI） | `public/script.js:6758, 6700` |
| `gen_started` | string (ISO) | 仅 AI 消息 | 生成开始时间 | `public/script.js:6759` |
| `gen_finished` | string (ISO) | 仅 AI 消息 | 生成结束时间 | `public/script.js:6760` |
| `extra` | object | AI 消息至少 `{}` | 扩展元数据，见 2.5 | `public/script.js:6745` |
| `swipes` | string[] | 仅 AI 消息 | 所有候选回复文本，`swipes[swipe_id] === mes` | `public/script.js:6800-6802` |
| `swipe_id` | number | 仅 AI 消息，默认 `0` | 当前选中的 swipe 下标 | `public/script.js:6790-6800` |
| `swipe_info` | SwipeInfo[] | 仅 AI 消息 | 与 `swipes` 等长、一一对应 | `public/script.js:6787-6825` |
| `force_avatar` | string | 群聊/锁定 persona 时 | 强制头像 URL（如 `User Avatars/x.png`、缩略图路径） | `public/script.js:5894`、`public/scripts/group-chats.js:604-607` |
| `original_avatar` | string | 群聊时 | 发言角色原始头像文件名 | `public/script.js:6774` |

**SwipeInfo**（`public/global.d.ts:83-88`）：

| 字段 | 类型 | 默认 | 依据 |
|---|---|---|---|
| `send_date` | string (ISO) | 该 swipe 的生成时间 | `public/script.js:6793-6798, 6861-6866` |
| `gen_started` | string (ISO) | — | 同上 |
| `gen_finished` | string (ISO) | — | 同上 |
| `extra` | object | `{}`（首次创建时的 `extra` 深拷贝，去掉 `token_count`/`reasoning`/`reasoning_duration`） | `public/script.js:6812-6821` |

### 2.5 `extra` 子字段清单

类型声明 `public/global.d.ts:90-128`（`BaseMessageExtra`）。

| 子字段 | 类型 | 语义 | 依据 |
|---|---|---|---|
| `api` | string | 生成该消息的 API id（`openai` / `kobold` / `textgenerationwebui` …） | `public/script.js:6749` |
| `model` | string | 生成该消息的模型 id | `public/script.js:6750` |
| `reasoning` | string | 思维链原文 | `public/script.js:6751` |
| `reasoning_duration` | number\|null | 思考耗时（ms） | `public/script.js:6752` |
| `reasoning_signature` | string\|null | Anthropic 等需要的签名 | `public/script.js:6753` |
| `reasoning_display_text` | string | 展示用思维链 | `public/global.d.ts:99` |
| `token_count` | number | 消息 token 数（开启 `message_token_count_enabled` 时） | `public/script.js:6762-6765` |
| `bias` | string | 用户消息的 bias 文本 | `public/script.js:5898` |
| `isSmallSys` | boolean | 紧凑系统提示消息（不参与 swipe） | `public/script.js:5884`、`public/script.js:6846` |
| `uses_system_ui` | boolean | 用系统 UI 样式渲染 | `public/scripts/system-messages.js:69, 84` |
| `swipeable` | boolean | `false` 时不可滑动 | `public/scripts/system-messages.js:41` |
| `gen_id` | number | 群聊里标记同一次生成 | `public/scripts/group-chats.js:600`、`public/script.js:6775` |
| `type` | string | 系统消息子类型（`help`/`welcome`/`assistant_note` …） | `public/scripts/system-messages.js:18-32` |
| `display_text` | string | 导出 txt / 显示时替代 `mes` | `src/endpoints/chats.js:733` |
| `media` | array | 图片/视频附件（`{url,title,type,source,...}`） | `public/global.d.ts:111, 132-151` |
| `media_index` | number | 当前展示的媒体下标 | `public/scripts/chats.js:2102` |
| `media_display` | string | `list` / `gallery` 等 | `public/global.d.ts:109` |
| `inline_image` | boolean | 图片内联展示 | `public/global.d.ts:108` |
| `files` | FileAttachment[] | 附件文件 | `public/global.d.ts:107` |
| `branches` | string[] | 从该消息派生的分支聊天名列表 | `public/scripts/bookmarks.js:237-243` |
| `bookmark_link` | string | 该消息创建的书签（checkpoint）聊天名 | `public/scripts/bookmarks.js:275, 293` |
| `memory` | string | 已废弃的上下文记忆 | `public/global.d.ts:97` |
| `[IGNORE_SYMBOL]` | boolean | 该消息排除出 prompt 处理 | `public/global.d.ts:126-127` |

> 未知子字段必须原样保留（ST 自己就是 `Record<string, any>` 透传）。

### 2.6 系统消息与守卫消息

- 系统消息模板：`{name: systemUserName, force_avatar, is_user: false, is_system: true, extra: {swipeable: false}, mes}`（`public/scripts/system-messages.js:36-42`）。
- 类型枚举：`help / welcome / empty / generic / narrator / comment / slash_commands / formatting / hotkeys / macros / welcome_prompt / assistant_note / assistant_message`（`public/scripts/system-messages.js:18-32`）。
- 用户消息默认带 `is_system: false`（`public/script.js:5880`），AI 消息不带 `is_system` 字段（`public/script.js:6743-6760`）。
- `is_system: true` 的消息在「导出为 txt」时被跳过（`src/endpoints/chats.js:728-730`）。

### 2.7 群聊 / 分支 / 书签

**群聊**
- 群定义存 `groups/<id>.json`，字段：`id, name, members[], disabled_members[], chat_id, chats[], avatar_url, activation_strategy, generation_mode, generation_mode_join_prefix/suffix, auto_mode_delay, allow_self_responses, fav`（`src/endpoints/groups.js:163-178`、`public/global.d.ts:26-43`）。
- 群聊消息文件 `group chats/<chat_id>.jsonl`，格式与单聊**完全一致**；发言者靠每条消息的 `name` + `force_avatar` + `original_avatar` 区分（`public/scripts/group-chats.js:596-608`）。
- 首次打开空群聊时，会把每个成员的第一条消息（first_mes）依次写入（`public/scripts/group-chats.js:283-304`）。
- 历史兼容：老版本把 `chat_metadata` 存在 group JSON 里，现在已迁移到 JSONL 头部（`src/endpoints/groups.js:34-111`）。

**分支（branch）**
- 分支 = **独立的普通聊天文件**，名字形如 `<原名> - Branch #N`（`public/scripts/bookmarks.js:209-222`）。
- 内容 = 父聊天前 `mesId+1` 条消息的快照（`public/scripts/bookmarks.js:172-184`）。
- 新文件头里写入 `chat_metadata.main_chat = 父聊天名` 和一个新的 `integrity`（`public/scripts/bookmarks.js:200-201, 233`）。
- 父消息的 `extra.branches` 追加分支名（`public/scripts/bookmarks.js:237-243`）。

**书签 / checkpoint**
- 也是独立聊天文件，`chat_metadata.main_chat = 父聊天名`，父消息 `extra.bookmark_link = 书签名`（`public/scripts/bookmarks.js:275-293`）。

### 2.8 完整性校验（integrity）

- 保存时：若 `chat_metadata.integrity` 存在且与磁盘上文件头里的值不同 → 抛 `IntegrityMismatchError`，HTTP 400 `{error:'integrity'}`（`src/endpoints/chats.js:532-543, 562-566`）。
- 客户端收到该错误会要求用户输入 `OVERWRITE` 才强制保存（`public/script.js:7454-7470`）。
- 旧文件没有 `integrity` 时跳过校验（`src/endpoints/chats.js:359-368`）。
- 读取时若头部缺 `integrity`，客户端会补一个 uuid 并在下次保存写回（`public/script.js:7665-7667`）。
- **iOS 建议**：保留该字段（UUID 字符串）并在写入前比对，可防止 iCloud 同步 / 多端冲突时静默覆盖。

### 2.9 最小完整 JSONL 示例（metadata 行 + 2 条消息）

文件：`data/default-user/chats/Seraphina/Seraphina - 2025-09-26@15h04m33s123ms.jsonl`

```jsonl
{"chat_metadata":{"integrity":"1e6905db-bab6-4901-913b-06d18cab5a8f","tainted":false,"scenario":"","mes_example":"","system_prompt":"","persona":"user-default.png","world_info":"Eldoria","timedWorldInfo":{},"note_prompt":"","note_interval":1,"note_depth":4,"note_position":0,"note_role":0,"attachments":[]},"user_name":"unused","character_name":"unused"}
{"name":"Seraphina","is_user":false,"is_system":false,"send_date":"2025-09-26T07:04:12.006Z","mes":"*She turns, her gown shimmering in the soft light.* \"Welcome to Eldoria, traveler.\"","extra":{"api":"openai","model":"gpt-4o","reasoning":"","reasoning_duration":null,"reasoning_signature":null,"token_count":24},"swipes":["*She turns, her gown shimmering in the soft light.* \"Welcome to Eldoria, traveler.\"","*A soft glow surrounds her as she tilts her head.* \"You are far from the road, aren't you?\""],"swipe_id":0,"swipe_info":[{"send_date":"2025-09-26T07:04:12.006Z","gen_started":"2025-09-26T07:04:10.114Z","gen_finished":"2025-09-26T07:04:12.006Z","extra":{"api":"openai","model":"gpt-4o"}},{"send_date":"2025-09-26T07:05:40.881Z","gen_started":"2025-09-26T07:05:38.220Z","gen_finished":"2025-09-26T07:05:40.881Z","extra":{"api":"openai","model":"gpt-4o"}}],"gen_started":"2025-09-26T07:04:10.114Z","gen_finished":"2025-09-26T07:04:12.006Z"}
{"name":"User","is_user":true,"is_system":false,"send_date":"2025-09-26T07:06:02.345Z","mes":"Who are you?","extra":{"isSmallSys":false}}
```

> 注意：文件末尾**没有**换行；所有行都是紧凑 JSON（无缩进）。

---

## 3. 角色卡与头像存储

### 3.1 目录与命名

| 项 | 规则 | 依据 |
|---|---|---|
| 目录 | `data/<handle>/characters/`，**只放 `.png`** | `src/constants.js:29`、`src/endpoints/characters.js:1468-1469` |
| 命名 | `<internalName>.png`，`internalName` 由角色名经 `sanitize-filename` 得到，重名时 `Name1.png`、`Name2.png`…（`getUniqueName`，最多 10000 次） | `src/endpoints/characters.js:1024-1035, 1543-1547, 978` |
| `avatar` 字段 | 就是**含扩展名的文件名**，如 `Seraphina.png`；哑值 `'none'` | `src/endpoints/characters.js:413, 589`、`src/endpoints/characters.js:605` |
| 聊天目录 | `<avatar>` 去掉 `.png`，即 `chats/Seraphina/` | `src/endpoints/chats.js:548-551`、`src/endpoints/characters.js:419` |
| persona 头像 | `data/<handle>/User Avatars/`，命名自由（默认 `user-default.png`，上传未命名时用 `${Date.now()}.png`） | `src/constants.js:24`、`src/endpoints/avatars.js:17-20, 41-60`、`public/scripts/personas.js:100` |
| 上传暂存 | `data/_uploads/`（不是 `characters/_uploads`），处理完立即 `unlink` | `src/server-main.js:268`、`src/users.js:198-217` |
| 其他 | `characters/` 目录里没有索引文件；**没有** `characters.json` | `src/endpoints/characters.js:1466-1478` |

> 任务里提到的 `_uploads` 是 DATA_ROOT 级临时目录（`src/constants.js:219`），不在 `characters/` 内。

### 3.2 角色列表如何被枚举

```
readdir(characters/)                       → 过滤 .png                (characters.js:1468-1469)
  └─ processCharacter(file)                                            (characters.js:406-441)
       ├─ readCharacterData(png)  读取 PNG 的 chara/ccv3 tEXt chunk     (characters.js:181-218)
       ├─ JSON.parse → getCharaCardV2(...)  统一升级成 Spec V2          (characters.js:450-461)
       ├─ character.avatar = 文件名                                     (characters.js:413)
       ├─ character.json_data = 原始 JSON 字符串                        (characters.js:415)
       ├─ character.date_added = stat.ctimeMs                           (characters.js:417)
       ├─ character.create_date                                         (characters.js:418)
       ├─ chat_size / date_last_chat  ← 扫 chats/<avatar>/ 目录统计     (characters.js:342-356, 419-423)
       └─ data_size = JSON 字节数                                       (characters.js:424)
```

- 单角色聊天列表：`readdir(chats/<avatar>/)` 过滤 `.jsonl`，每个文件跑 `getChatInfo()` 得到 `file_id / file_name / file_size / chat_items / mes / last_mes / chat_metadata`（`src/endpoints/characters.js:1499-1535`、`src/endpoints/chats.js:393-506`）。
- 空聊天判定：`chat_items = 总行数 - 1`（减掉 metadata 行）；最后一行不可解析时 `chat_items = 行数 - 2`（`src/endpoints/chats.js:482-499`）。

### 3.3 PNG 与角色卡的关系

- PNG `tEXt` chunk 两个 key（均 base64 编码 JSON）：
  - `chara`：Spec V1/V2 JSON（旧版兼容）
  - `ccv3`：Spec V3 JSON（写入时由 V2 复制并改 `spec='chara_card_v3'`, `spec_version='3.0'`）
- 读取优先级：**`ccv3` > `chara`**（`src/character-card-parser.js:54-78`）。
- 写入时会先删掉已存在的 `chara`/`ccv3` chunk，再在 `IEND` 前插入（`src/character-card-parser.js:15-46`）。
- 卡片 JSON 结构（`src/types/spec-v2.d.ts:1-24`）：

```jsonc
{
  "spec": "chara_card_v2",
  "spec_version": "2.0",
  "name": "...", "description": "...", "personality": "...", "scenario": "...",
  "first_mes": "...", "mes_example": "...", "creatorcomment": "...",   // V1 兼容字段
  "avatar": "none", "chat": "<角色名> - <时间戳>", "talkativeness": 0.5, "fav": false, "tags": [],
  "create_date": "ISO8601",
  "data": {
    "name": "...", "description": "...", "personality": "...", "scenario": "...",
    "first_mes": "...", "mes_example": "...",
    "creator_notes": "", "system_prompt": "", "post_history_instructions": "",
    "alternate_greetings": [], "character_book": { ... },     // 可选
    "tags": [], "creator": "", "character_version": "",
    "extensions": {
      "talkativeness": 0.5, "fav": false, "world": "<worlds 文件名,不含扩展名>",
      "depth_prompt": { "prompt": "", "depth": 4, "role": "system" }
    }
  }
}
```
（字段写入位置：`src/endpoints/characters.js:565-657`；默认值 `depth=4`、`role='system'`、`talkativeness=0.5`、`fav=false`）

- 支持导入格式：`png / json / yaml / yml / charx / byaf`（`src/endpoints/characters.js:1567-1572`）。
- 导入 JSON 时若为 V2（有 `spec`）→ `readFromV2()` 并重新写 PNG；若为 V1（有 `name`）→ 转 V2 后写 PNG（`src/endpoints/characters.js:968-1019`）。
- 头像上传会被裁剪/缩放到 `AVATAR_WIDTH=512 × AVATAR_HEIGHT=768`（`src/constants.js:358-360`、`src/endpoints/avatars.js:41-60`）。
- 新建角色未给图片时用默认卡图 `./public/img/ai4.png`（`src/constants.js:360`、`src/endpoints/characters.js:1037-1038`）；默认角色是 `default/content/default_Seraphina.png`。

---

## 4. 世界书（worlds）存储

### 4.1 文件与顶层结构

| 项 | 规则 | 依据 |
|---|---|---|
| 路径 | `data/<handle>/worlds/<name>.json`（名字经 `sanitize`） | `src/endpoints/worldinfo.js:24-25, 151-152` |
| 顶层结构 | `{ "entries": { "<uid>": {…} }, "name"?: string, "extensions"?: object, "originalData"?: object }` | `src/endpoints/worldinfo.js:18, 50-57`、`public/scripts/world-info.js:5569` |
| **entries 是对象不是数组** | key = 字符串化的 `uid`（`"0"`, `"1"`, …），value = 条目 | `public/scripts/world-info.js:4145-4146`、`default/content/Eldoria.json` |
| 校验 | 导入/保存时必须含 `entries` 字段，否则 400 | `src/endpoints/worldinfo.js:114-121, 143-149` |
| 序列化 | `JSON.stringify(data, null, 4)` → 4 空格缩进 | `src/endpoints/worldinfo.js:154` |
| 列表 | 只返回 `{file_id, name, extensions}`，`name` 缺省用文件名 | `src/endpoints/worldinfo.js:39-69` |
| `originalData` | 若世界书是从角色卡 `character_book` 导入的，保留原始数组形式 | `public/scripts/world-info.js:5618`、`src/endpoints/characters.js:632-635` |

### 4.2 条目字段（WIEntry）

来源：`public/scripts/world-info.js:4082-4129`（`newWorldInfoEntryDefinition`，含默认值/类型）。

| 字段 | 类型 | 默认 | 语义 |
|---|---|---|---|
| `uid` | number | 自动分配的空闲整数 | 条目 id，同时是 `entries` 的 key |
| `key` | string[] | `[]` | 主关键词（正则） |
| `keysecondary` | string[] | `[]` | 次关键词 |
| `comment` | string | `''` | 备注/标题 |
| `content` | string | `''` | 注入内容 |
| `constant` | boolean | `false` | 常驻（无需关键词命中） |
| `vectorized` | boolean | `false` | 走向量检索 |
| `selective` | boolean | `true` | 启用次关键词 |
| `selectiveLogic` | number | `0` (AND_ANY) | 0=AND_ANY,1=NOT_ALL,2=NOT_ANY,3=AND_ALL（`world-info.js:33-38`） |
| `addMemo` | boolean | `false` | 显示备注 |
| `order` | number | `100` | 插入优先级 |
| `position` | number | `0` | 0=before,1=after,2=AN top,3=AN bottom,4=atDepth,5=EM top,6=EM bottom,7=outlet（`world-info.js:855-864`） |
| `disable` | boolean | `false` | 禁用 |
| `ignoreBudget` | boolean | `false` | 忽略 token 预算 |
| `excludeRecursion` / `preventRecursion` | boolean | `false` | 递归扫描控制 |
| `matchPersonaDescription` / `matchCharacterDescription` / `matchCharacterPersonality` / `matchCharacterDepthPrompt` / `matchScenario` / `matchCreatorNotes` | boolean | `false` | 附加匹配源 |
| `delayUntilRecursion` | number | `0` | 递归层数门槛 |
| `probability` | number | `100` | 触发概率 % |
| `useProbability` | boolean | `true` | 启用概率 |
| `depth` | number | `4` (`DEFAULT_DEPTH`) | atDepth 插入深度 |
| `outletName` | string | `''` | outlet 名 |
| `group` | string | `''` | 互斥分组 |
| `groupOverride` | boolean | `false` | 组内优先 |
| `groupWeight` | number | `100` | 组权重 |
| `scanDepth` | number\|null | `null` | 覆盖全局扫描深度 |
| `caseSensitive` | boolean\|null | `null` | 覆盖全局大小写 |
| `matchWholeWords` | boolean\|null | `null` | 覆盖全词匹配 |
| `useGroupScoring` | boolean\|null | `null` | 覆盖组评分 |
| `automationId` | string | `''` | 自动化 id |
| `role` | number\|null | 老文件为 `null` | 注入角色 0=system,1=user,2=assistant |
| `sticky` / `cooldown` / `delay` | number\|null | 老文件为 `0`，新模板为 `null` | 时序效果（存于 `chat_metadata.timedWorldInfo`） |
| `triggers` | string[] | `[]` | 触发时机（生成类型） |
| `displayIndex` | number | 老文件存在 | 仅 UI 排序（`characters.js:686`） |
| `characterFilterNames` / `characterFilterTags` / `characterFilterExclude` | — | 不写入模板 | 角色过滤（`excludeFromTemplate`） |

### 4.3 与内嵌 `character_book` 的关系

- 角色运行时使用的世界书文件名写在卡片 `data.extensions.world`（`src/endpoints/characters.js:617`）。
- 导出/保存角色时，ST 会把 `worlds/<world>.json` **转换并嵌入**到卡片的 `data.character_book`：
  - 若世界书有 `originalData`（本来就是从卡片导入的）→ 直接回填 `originalData`；
  - 否则 `convertWorldInfoToCharacterBook(name, entries)` 把对象形式 entries 转成 **数组**，字段名改成 Spec 驼峰下划线格式：`id, keys, secondary_keys, comment, content, constant, selective, insertion_order, enabled, position('before_char'|'after_char'), use_regex`，其余 ST 专有字段塞进 `extensions`（`src/endpoints/characters.js:628-644, 663-722`）。
- `CharacterBook` 类型见 `src/types/spec-v2.d.ts:26-56`。

> iOS 兼容要点：**磁盘上的 `worlds/*.json` 用「对象 + ST 字段名」**；**卡片里的 `character_book` 用「数组 + 下划线字段名」**。两者必须做转换，不能混用。

### 4.4 worlds JSON 示例（最小可用）

`data/default-user/worlds/Eldoria.json`：

```json
{
    "entries": {
        "0": {
            "uid": 0,
            "key": ["eldoria", "forest", "magical forest"],
            "keysecondary": [],
            "comment": "eldoria",
            "content": "{{user}}: \"What is Eldoria?\"\n{{char}}: *She gestures at the woods around her.* \"Eldoria is here, all of the woods.\"",
            "constant": false,
            "vectorized": false,
            "selective": true,
            "selectiveLogic": 0,
            "addMemo": true,
            "order": 100,
            "position": 0,
            "disable": false,
            "excludeRecursion": false,
            "preventRecursion": false,
            "delayUntilRecursion": 0,
            "probability": 100,
            "useProbability": true,
            "depth": 4,
            "group": "",
            "groupOverride": false,
            "groupWeight": 100,
            "scanDepth": null,
            "caseSensitive": null,
            "matchWholeWords": null,
            "useGroupScoring": null,
            "automationId": "",
            "role": null,
            "sticky": 0,
            "cooldown": 0,
            "delay": 0,
            "displayIndex": 0,
            "triggers": []
        },
        "1": {
            "uid": 1,
            "key": ["shadowfang", "shadowfangs"],
            "keysecondary": ["beast", "monster"],
            "comment": "The Shadowfangs",
            "content": "The Shadowfangs are the creatures that blighted Eldoria.",
            "constant": false,
            "selective": true,
            "selectiveLogic": 0,
            "order": 100,
            "position": 4,
            "depth": 4,
            "role": 0,
            "disable": false,
            "probability": 100,
            "useProbability": true
        }
    }
}
```

（`entries` 也可以是空对象 `{}` —— 服务端把 `{"entries":{}}` 当作合法的空世界书：`src/endpoints/worldinfo.js:18`）

---

## 5. 设置项（settings.json）

### 5.1 存储位置与读写

| 项 | 说明 | 依据 |
|---|---|---|
| 文件 | `data/<handle>/settings.json`（`SETTINGS_FILE`） | `src/constants.js:9`、`src/endpoints/settings.js:208-209` |
| 写入 | `POST /api/settings/save`，`JSON.stringify(body, null, 4)` 原子写 | `src/endpoints/settings.js:206-216` |
| 读取 | `POST /api/settings/get`，返回 `{settings: "<原始字符串>", koboldai_settings, world_names, themes, instruct, context, sysprompt, reasoning, …}` | `src/endpoints/settings.js:219-296` |
| 自动快照 | 每 10 分钟若内容有变化，复制到 `backups/settings_<handle>_<ts>.json` | `src/endpoints/settings.js:23, 36-46, 136-156` |
| 出厂模板 | `default/content/settings.json`（仅作参考基线；真实默认值以 JS 里的默认对象为准） | `default/content/settings.json` |

### 5.2 settings.json 顶层结构

由 `saveSettings()` 组装（`public/script.js:8069-8094`）：

```jsonc
{
  "firstRun": false,
  "accountStorage": {},          // 每个账号的键值存储
  "currentVersion": "1.x.x",
  "username": "User",            // ← persona 名 = prompt 里的 name1
  "active_character": "",        // 上次打开的角色（avatar 文件名）
  "active_group": "",            // 上次打开的群 id
  "user_avatar": "user-default.png",  // ← 当前 persona 头像
  "amount_gen": 80,              // 生成长度上限
  "max_context": 2048,           // 上下文长度
  "main_api": "openai",          // kobold | koboldhorde | novel | textgenerationwebui | openai
  "world_info_settings": { ... },
  "textgenerationwebui_settings": { ... },   // Text Completion 参数
  "swipes": true,                // 是否允许滑动候选回复
  "horde_settings": { ... },
  "power_user": { ... },         // ★ 最大的设置块（UI + context/instruct/persona）
  "extension_settings": { ... }, // 各扩展自己的设置
  "tags": [], "tag_map": {},
  "nai_settings": { ... }, "kai_settings": { ... },
  "oai_settings": { ... },       // ★ Chat Completion 参数
  "background": { ... }, "proxies": [], "selected_proxy": ""
}
```

> `default/content/settings.json` 里示例值为 `username="User"`、`amount_gen=350`、`max_context=8192`、`main_api="koboldhorde"`、`swipes=true`，但真正的代码默认值是 `amount_gen=80`、`max_context=2048`（`public/script.js:616-620`）。iOS 应两者都不硬编码，而是"取到就用、缺省兜底"。

### 5.3 核心设置项清单

下面给出 5 张表，共 124 项，覆盖离线 iOS 客户端真正需要读写/透传的字段。若只做最小实现，**★ 标记的 38 项**即可跑通"选择角色 → 组 prompt → 生成 → 保存聊天"闭环：

- **生成参数**：`main_api`★、`amount_gen`★、`max_context`★、`oai_settings.chat_completion_source`★、`openai_max_context`★、`openai_max_tokens`★、`temp_openai`★、`top_p_openai`★、`rep_pen`/`repetition_penalty_openai`★、`freq_pen_openai`、`pres_pen_openai`、`seed`、`stream_openai`★、`streaming`(textgen)★、`custom_stopping_strings`★
- **模型与连接**：`openai_model`★、`claude_model`、`google_model`、`custom_model`/`custom_url`、`reverse_proxy`、`preset_settings_openai`、`preset`(textgen)
- **Prompt 组成**：`username`★、`user_avatar`★、`power_user.persona_description*`★、`power_user.context`★、`power_user.instruct`★、`power_user.sysprompt`★、`power_user.reasoning`、`power_user.tokenizer`★、`power_user.token_padding`
- **聊天行为**：`swipes`★、`power_user.auto_load_chat`★、`power_user.timestamps_enabled`★、`power_user.show_swipe_num_all_messages`、`power_user.trim_spaces`★、`confirm_message_delete`、`auto_scroll_chat_to_bottom`
- **世界书**：`world_info_settings.world_info.globalSelect`★、`world_info_depth`★、`world_info_budget`★、`world_info_recursive`、`world_info_case_sensitive`、`world_info_match_whole_words`、`world_info_character_strategy`
- **外观 / 状态**：`power_user.theme`★、`power_user.font_scale`、`power_user.avatar_style`、`power_user.chat_display`、`active_character`★、`active_group`、`firstRun`、`tags`/`tag_map`

#### A. 顶层生成 / API

| 键 | 类型 | 默认 | 语义 | 依据 |
|---|---|---|---|---|
| `main_api` | string | 无（首次引导选择） | 主 API：`openai`(Chat Completion) / `textgenerationwebui`(Text Completion) / `kobold` / `koboldhorde` / `novel` | `public/script.js:629, 8079` |
| `username` | string | `'User'` | 用户名 = prompt 里的 `name1` = persona 名 | `public/script.js:8073`、`public/scripts/personas.js:902-905` |
| `user_avatar` | string | `'user-default.png'` | 当前 persona 头像文件名（`User Avatars/` 下） | `public/script.js:8076` |
| `amount_gen` | number | `80` | 单次生成最大 token 数 | `public/script.js:616` |
| `max_context` | number | `2048` | 上下文长度（token） | `public/script.js:617` |
| `swipes` | boolean | `true` | 是否显示/允许 swipe | `public/script.js:620, 8082` |
| `firstRun` | boolean | `true` | 是否首次运行（决定是否走引导） | `public/script.js:8070` |
| `active_character` | string | `''` | 上次打开的角色（用来实现"打开即恢复"） | `public/script.js:8074` |
| `active_group` | string | `''` | 上次打开的群 id | `public/script.js:8075` |
| `currentVersion` | string | — | 客户端版本号 | `public/script.js:8072` |
| `preset_settings` | string | — | 当前 Kobold 预设名（示例文件里有） | `default/content/settings.json` |
| `tags` / `tag_map` | array / object | `[]` / `{}` | 角色标签与映射 | `public/script.js:8086-8087` |

#### B. `oai_settings`（Chat Completion）

默认值来源：`public/scripts/openai.js:411-518`。

| 键 | 类型 | 默认 | 语义 | 行号 |
|---|---|---|---|---|
| `chat_completion_source` | string | `'openai'` | 后端源，枚举见 `openai.js:177-204` | `openai.js:487` |
| `openai_max_context` | number | `4095` (`max_4k`) | 上下文窗口 | `openai.js:422`、`openai.js:127` |
| `openai_max_tokens` | number | `300` | 最大输出 token | `openai.js:423` |
| `temp_openai` | number | `1.0` | temperature | `openai.js:413` |
| `top_p_openai` | number | `1.0` | top_p | `openai.js:416` |
| `top_k_openai` | number | `0` | top_k | `openai.js:417` |
| `min_p_openai` | number | `0` | min_p | `openai.js:418` |
| `top_a_openai` | number | `0` | top_a | `openai.js:419` |
| `freq_pen_openai` | number | `0` | frequency penalty | `openai.js:414` |
| `pres_pen_openai` | number | `0` | presence penalty | `openai.js:415` |
| `repetition_penalty_openai` | number | `1` | repetition penalty | `openai.js:420` |
| `seed` | number | `-1` | 随机种子（-1 = 随机） | `openai.js:514` |
| `n` | number | `1` | 生成候选数 | `openai.js:515` |
| `stream_openai` | boolean | `false` | **流式开关** | `openai.js:421` |
| `openai_model` | string | `'gpt-5.6-terra'` | OpenAI 模型 | `openai.js:440` |
| `claude_model` | string | `'claude-sonnet-5'` | Claude 模型 | `openai.js:441` |
| `google_model` | string | `'gemini-3.7-flash'` | Google 模型 | `openai.js:442` |
| `custom_model` / `custom_url` | string | `''` | 自定义端点 | `openai.js:474-475` |
| `reverse_proxy` | string | `''` | 反向代理 URL | `openai.js:486` |
| `preset_settings_openai` | string | `'Default'` | 当前 Chat Completion 预设名 | `openai.js:412` |
| `use_sysprompt` | boolean | `false` | 是否发送 system prompt | `openai.js:493` |
| `names_behavior` | number | `DEFAULT` | 名字注入策略 | `openai.js:504` |
| `continue_postfix` | number | `SPACE` | continue 时的后缀策略 | `openai.js:505` |
| `reasoning_effort` / `verbosity` | string | `'auto'` | 推理强度/啰嗦度 | `openai.js:508-509` |
| `show_thoughts` | boolean | `true` | 显示思维链 | `openai.js:507` |
| `function_calling` | boolean | `false` | 工具调用 | `openai.js:502` |
| `media_inlining` | boolean | `true` | 图片内联 | `openai.js:498` |
| `squash_system_messages` | boolean | `false` | 合并 system 消息 | `openai.js:497` |
| `bind_preset_to_connection` | boolean | `true` | 预设绑定连接 | `openai.js:516` |
| `extensions` | object | `{}` | 扩展参数 | `openai.js:517` |

#### C. `textgenerationwebui_settings`（Text Completion）

代码默认值来源：`public/scripts/textgen-settings.js:144-189`；`default/content/settings.json` 里的是某个用户的示例（`temp:1, top_p:0.95, rep_pen:1.1`），不是出厂默认。

| 键 | 类型 | 代码默认 | 语义 | 行号 |
|---|---|---|---|---|
| `temp` | number | `0.7` | temperature | `textgen-settings.js:145` |
| `temperature_last` | boolean | `true` | temperature 最后应用 | `:146` |
| `top_p` | number | `0.5` | top_p | `:147` |
| `top_k` | number | `40` | top_k | `:148` |
| `min_p` | number | `0` | min_p | `:154` |
| `typical_p` | number | `1` | typical sampling | `:153` |
| `tfs` | number | `1` | tail-free sampling | `:150` |
| `rep_pen` | number | `1.2` | repetition penalty | `:155` |
| `rep_pen_range` | number | `0` | penalty 作用范围 | `:156` |
| `no_repeat_ngram_size` | number | `0` | 禁止重复 n-gram | `:159` |
| `preset` | string | `'Default'` | 当前预设名 | `:183` |
| `streaming` | boolean | `false` | **流式开关** | （在示例文件与 `script.js:3525` 使用） |
| `stopping_strings` | string[] | `[]` | 停止串 | `:185` |
| `seed` | number | `-1` | 种子 | `:182` |
| `add_bos_token` | boolean | `true` | 加 BOS | `:184` |
| `ban_eos_token` | boolean | `false` | 禁止 EOS | `:187` |
| `skip_special_tokens` | boolean | `true` | 跳过特殊 token | `:188` |
| `mirostat_mode` / `mirostat_tau` / `mirostat_eta` | number | `0 / 5 / 0.1` | Mirostat（见示例文件） | — |
| `samplers` / `sampler_priority` | string[] | 见示例文件 | 采样器顺序 | — |

#### D. `power_user`（UI 与 chat 行为）

默认值来源：`public/scripts/power-user.js:116-343`。

| 键 | 类型 | 默认 | 语义 | 行号 |
|---|---|---|---|---|
| `theme` | string | `'Default (Dark) 1.7.1'` | 当前主题名（对应 `themes/<name>.json`） | `power-user.js:177` |
| `auto_load_chat` | boolean | `false` | **打开角色时自动载入上次聊天** | `power-user.js:335` |
| `timestamps_enabled` | boolean | `true` | 显示消息时间戳 | `power-user.js:194` |
| `timer_enabled` | boolean | `true` | 显示计时器 | `power-user.js:193` |
| `timestamp_model_icon` | boolean | `false` | 时间戳旁显示模型图标 | `power-user.js:195` |
| `show_swipe_num_all_messages` | boolean | `false` | 所有消息都显示 swipe 序号 | `power-user.js:333` |
| `auto_swipe` | boolean | `false` | 自动滑动到下一个候选 | `power-user.js:180` |
| `auto_swipe_minimum_length` | number | `0` | 触发自动 swipe 的最短长度 | `power-user.js:181` |
| `chat_truncation` | number | `100` | 上下文裁剪百分比 | `power-user.js:133` |
| `streaming_fps` | number | `30` | 流式渲染帧率 | `power-user.js:134` |
| `smooth_streaming` | boolean | `false` | 平滑流式 | `power-user.js:135` |
| `trim_spaces` | boolean | `true` | 生成文本 trim | `power-user.js:208` |
| `send_on_enter` | number | `AUTO` | 回车发送行为 | `power-user.js:186` |
| `swipes` | — | — | （顶层 `swipes` 才是开关，`power_user` 内无同名项） | `public/script.js:620` |
| `fast_ui_mode` | boolean | `true` | 关闭动画 | `power-user.js:140` |
| `avatar_style` | number | `ROUND(0)` | 头像形状 | `power-user.js:141` |
| `chat_display` | number | `DEFAULT(0)` | 聊天样式 | `power-user.js:142` |
| `chat_width` | number | `50` | 聊天宽度 % | `power-user.js:144` |
| `font_scale` | number | `1` | 字号缩放 | `power-user.js:155` |
| `message_token_count_enabled` | boolean | `false` | 显示消息 token 数 | `power-user.js:199` |
| `hideChatAvatars_enabled` | boolean | `false` | 隐藏聊天头像 | `power-user.js:197` |
| `mesIDDisplay_enabled` | boolean | `false` | 显示消息 id | `power-user.js:196` |
| `confirm_message_delete` | boolean | `true` | 删除消息时确认 | `power-user.js:150` |
| `auto_save_msg_edits` | boolean | `false` | 编辑消息后自动保存 | `power-user.js:149` |
| `auto_scroll_chat_to_bottom` | boolean | `true` | 自动滚到底 | `power-user.js:184` |
| `auto_fix_generated_markdown` | boolean | `true` | 修复 Markdown | `power-user.js:185` |
| `forbid_external_media` | boolean | `true` | 禁止外链媒体（离线必须 true） | `power-user.js:336` |
| `reduced_motion` | boolean | `false` | 减弱动效 | `power-user.js:331` |
| `compact_input_area` | boolean | `true` | 紧凑输入区 | `power-user.js:332` |
| `restore_user_input` | boolean | `true` | 恢复未发送输入 | `power-user.js:330` |
| `tokenizer` | number | `BEST_MATCH(99)` | 分词器选择 | `power-user.js:118` |
| `token_padding` | number | `64` | token 预算余量 | `power-user.js:119` |
| `personas` | object | `{}` | persona 头像 → 名字映射（见 §6） | `power-user.js:286` |
| `persona_descriptions` | object | `{}` | persona 头像 → 描述对象（见 §6） | `power-user.js:288` |
| `default_persona` | string\|null | `null` | 默认 persona 头像 | `power-user.js:287` |
| `persona_description` | string | `''` | **当前生效**的 persona 描述（镜像） | `power-user.js:290` |
| `persona_description_position` | number | `0` (IN_PROMPT) | 描述注入位置 | `power-user.js:291` |
| `persona_description_role` | number | `0` (system) | 注入角色 | `power-user.js:292` |
| `persona_description_depth` | number | `2` | atDepth 深度 | `power-user.js:293` |
| `persona_description_lorebook` | string | `''` | persona 绑定的世界书 | `power-user.js:294` |
| `persona_auto_lock` | boolean | 无默认（隐藏项） | 选中 persona 时锁定到当前聊天 | `public/scripts/personas.js:900, 1658` |
| `instruct` | object | 见 `power-user.js:218-245` | Instruct 模式配置（`enabled`, `preset`, `input_sequence`, `output_sequence`, `stop_sequence`, `names_behavior`, …） | `power-user.js:218-245` |
| `context` | object | 见 `power-user.js:247-257` | 故事字符串模板（`story_string`, `chat_start`, `example_separator`, `story_string_position/role/depth`） | `power-user.js:247-257` |
| `sysprompt` | object | `{enabled:true, name:'Neutral - Chat', content:'Write {{char}}\'s next reply…', post_history:''}` | 系统提示 | `power-user.js:267-272` |
| `reasoning` | object | 见 `power-user.js:274-284` | 思维链模板（`prefix:'<think>'`, `suffix:'</think>'`, `auto_parse`, …） | `power-user.js:274-284` |
| `custom_stopping_strings` | string | `''` | 自定义停止串（逗号分隔） | `power-user.js:298` |
| `enableZenSliders` / `enableLabMode` | boolean | `false` | 解锁高级采样滑条 | `power-user.js:201-202` |
| `max_context_unlocked` | boolean | `false` | 解锁上下文上限 | `power-user.js:198` |
| `waifuMode` / `movingUI` / `noShadows` | boolean | `false` | UI 布局模式 | `power-user.js:172-176` |

#### E. `world_info_settings`

由 `getWorldInfoSettings()` 输出（`public/scripts/world-info.js:795-812`）；默认值取代码里的变量初始化（`world-info.js:65-82`），`default/content/settings.json` 里的值只是某个用户的示例。

| 键 | 类型 | 代码默认 | 语义 | 依据 |
|---|---|---|---|---|
| `world_info` | object | `{}`，实际形如 `{globalSelect: []}` | 全局启用的世界书名数组（`globalSelect`） | `world-info.js:65, 85, 998` |
| `world_info_depth` | number | `2` | 扫描最近 N 条消息 | `world-info.js:69` |
| `world_info_budget` | number | `25` | 世界书预算（占上下文 %） | `world-info.js:73` |
| `world_info_include_names` | boolean | `true` | 扫描时包含说话人名字 | `world-info.js:74` |
| `world_info_recursive` | boolean | `false` | 允许递归扫描 | `world-info.js:75` |
| `world_info_case_sensitive` | boolean | `false` | 大小写敏感 | `world-info.js:77` |
| `world_info_match_whole_words` | boolean | `false` | 全词匹配 | `world-info.js:78` |
| `world_info_character_strategy` | number | `1` (`character_first`) | 0=evenly,1=character_first,2=global_first | `world-info.js:27-31, 80` |
| `world_info_budget_cap` | number | `0` | 预算上限（0=不限） | `world-info.js:81` |
| `world_info_min_activations` | number | `0` | >0 时继续往后扫直到激活足够条目 | `world-info.js:70` |
| `world_info_min_activations_depth_max` | number | `0` | 上者的最大扫描深度 | `world-info.js:71` |
| `world_info_overflow_alert` | boolean | `false` | 溢出提示 | `world-info.js:76` |
| `world_info_use_group_scoring` | boolean | `false` | 组评分 | `world-info.js:79` |
| `world_info_max_recursion_steps` | number | `0` | 最大递归步数（0=不限） | `world-info.js:82` |

#### F. 主题

- 主题是独立文件 `themes/<name>.json`，字段就是 `power_user` 里的 UI 子集（`name, blur_strength, main_text_color, italics_text_color, underline_text_color, quote_text_color, blur_tint_color, chat_tint_color, user_mes_blur_tint_color, bot_mes_blur_tint_color, shadow_color, shadow_width, border_color, font_scale, fast_ui_mode, waifuMode, avatar_style, chat_display, noShadows, chat_width, timer_enabled, timestamps_enabled, timestamp_model_icon, mesIDDisplay_enabled, hideChatAvatars_enabled, message_token_count_enabled, expand_message_actions, enableZenSliders, enableLabMode, hotswap_enabled, custom_css, bogus_folders, reduced_motion, compact_input_area`）。
- 例：`default/content/themes/Dark Lite.json`、`Azure.json`。
- `power_user.theme` 存名字；切主题 = 把主题 JSON 的字段写回 `power_user`（`public/scripts/power-user.js:177`）。

---

## 6. Persona（用户人设）

### 6.1 存储结构

Persona 没有独立文件，全部存在 `settings.json` 的 `power_user` 里。

| 结构 | 类型 | 说明 | 依据 |
|---|---|---|---|
| `power_user.personas` | `{ [avatarFileName: string]: string }` | 头像文件名 → 显示名（这个名字会被当成 `name1`/`username` 发给模型） | `public/scripts/personas.js:522-530, 583-591, 898-905`、`power-user.js:286` |
| `power_user.persona_descriptions` | `{ [avatarFileName: string]: PersonaDescriptor }` | 每个 persona 的详细配置 | `power-user.js:288`、`personas.js:523-530` |
| `power_user.default_persona` | `string \| null` | 新聊天的默认 persona 头像 | `power-user.js:287` |
| `power_user.persona_description` | string | **当前生效**的 persona 描述（切换 persona 时从 descriptor 同步过来的镜像，prompt 实际读这个） | `power-user.js:290`、`personas.js:907-920` |
| `power_user.persona_description_position` | number | 同上镜像 | `personas.js:911` |
| `power_user.persona_description_depth` | number | 同上镜像 | `personas.js:912` |
| `power_user.persona_description_role` | number | 同上镜像 | `personas.js:913` |
| `power_user.persona_description_lorebook` | string | 同上镜像 | `personas.js:914` |
| `user_avatar`（顶层） | string | 当前 persona 的头像文件名 | `public/script.js:8076` |
| `username`（顶层） | string | 冗余的显示名 | `public/script.js:8073` |

**PersonaDescriptor 字段**（`public/scripts/personas.js:523-530, 921-929`）：

| 字段 | 类型 | 默认 | 语义 |
|---|---|---|---|
| `description` | string | `''` | 人设描述文本 |
| `position` | number | `0` (IN_PROMPT) | 注入位置，枚举见下 |
| `depth` | number | `2` (`DEFAULT_DEPTH`) | `AT_DEPTH` 时的插入深度 |
| `role` | number | `0` (system) | 注入角色：0=system, 1=user, 2=assistant |
| `lorebook` | string | `''` | 绑定的世界书名 |
| `title` | string | `''` | 副标题（UI 显示） |
| `connections` | `{type:'character'\|'group', id:string}[]` | `[]` | 何时自动切换到这个 persona |

**position 枚举**（`public/scripts/personas.js:88-98`）：

| 值 | 名字 | 语义 |
|---|---|---|
| 0 | `IN_PROMPT` | 进故事字符串 / 主 prompt |
| 1 | `AFTER_CHAR` | **已废弃**，读到时自动改成 0（`personas.js:626-628`） |
| 2 | `TOP_AN` | 拼到 Author's Note 上方 |
| 3 | `BOTTOM_AN` | 拼到 Author's Note 下方 |
| 4 | `AT_DEPTH` | 按 `depth` 插入聊天历史 |
| 9 | `NONE` | 不注入 |

**role 枚举**：`extension_prompt_roles = {SYSTEM:0, USER:1, ASSISTANT:2}`（`public/script.js:494-497`）。

### 6.2 Persona 如何注入 prompt

1. 选择 persona（`selectCurrentPersona`）：把 `personas[avatar]` 写进 `name1`（用户名），把 descriptor 的 `description/position/depth/role/lorebook` 镜像到 `power_user.persona_description*`（`public/scripts/personas.js:897-932`）。
2. 注入（`addPersonaDescriptionExtensionPrompt`，`public/script.js:3203-3225`）：
   - `position = NONE` 或描述为空 → 不注入；
   - `position ∈ {TOP_AN, BOTTOM_AN}` → 与 Author's Note 文本拼接后一起注入（且仅当 `shouldWIAddPrompt` 为真）；
   - `position = AT_DEPTH` → `setExtensionPrompt('PERSONA_DESCRIPTION', desc, IN_CHAT, depth, true, role)`，即按 role 作为一条独立消息插到倒数第 `depth` 条位置；
   - `position = IN_PROMPT` → 作为扩展 prompt 进入主 prompt 组装流程（Text Completion 拼在故事字符串附近；Chat Completion 由 PromptManager 当作一个 prompt block）。
3. 扩展 prompt 的角色映射在 `public/script.js:5636-5639`（SYSTEM→空 name，USER→`name1`，ASSISTANT→AI 名）。
4. 名字方面：`{{user}}` 宏最终解析为 `name1`，因此 persona 名会同时影响 prompt 中的用户名和消息的 `name` 字段。

> iOS 建议：把 persona 建模为 `Persona {avatarFileName, name, description, position, depth, role, lorebook, title, connections}`，其中 `name` 存在 `power_user.personas` 这个「字典」里而非对象内——这是 ST 的既有形状，导入/导出时需要做映射。

---

## 7. 备份与迁移

| 机制 | 位置/格式 | 是否值得 iOS 支持 | 依据 |
|---|---|---|---|
| 设置快照 | `backups/settings_<handle>_<YYYYMMDD-HHMMSS>.json`，内容 = settings.json 原文；每 10 分钟自动、可手动/恢复 | 可直接支持：就是 settings.json 的副本，恢复=覆盖 | `src/endpoints/settings.js:88-90, 136-156, 298-374` |
| 聊天备份 | `backups/chat_<key>_<YYYYMMDD-HHMMSS>.jsonl`；`key = getBackupKey(角色名)`（保留 ASCII、非 ASCII 走 `sanitize` 后追加 8 位 sha256 前缀），内容 = 该聊天 JSONL 原文；**备份池按角色共享**，保存节流 10s，`backups.chat.maxTotalBackups` 控制总量 | 支持成本极低（同格式），可作为"撤销误删" | `src/endpoints/chats.js:32-81, 532-543`、`src/endpoints/backups.js:9-30`、`default/config.yaml`（`backups.chat.*`） |
| 全量备份 | `POST /api/users/backup` → `<handle>-<ts>.zip`，把整个用户目录（含 secrets.json，可被配置关闭）打包 | 可作为导入导出通道；iOS 至少应能读 zip 内的 characters/chats/worlds/settings.json | `src/users.js:1148-1183`、`src/endpoints/users-private.js:156-182` |
| 单聊天导出 | `POST /api/chats/export`：`format='jsonl'` 返回原文；其他返回 `Name: message\n\n` 的纯文本（跳过 `is_system`） | `jsonl` 必须支持（互通核心）；txt 可选 | `src/endpoints/chats.js:679-749` |
| 聊天导入 | `POST /api/chats/import`，支持 JSONL 原样导入，以及 oobabooga `data_visible` / Agnai `messages` / CAI Tools `histories` / Kobold Lite `savedsettings` / RisuAI `type='risuChat'` / Chub 格式的转换 | JSONL 优先；其他可后置 | `src/endpoints/chats.js:131-329, 771-810` |
| 世界书导入 | 只要求 JSON 里有 `entries` 字段 | 必需 | `src/endpoints/worldinfo.js:99-132` |
| 角色卡导入 | png / json / yaml / charx / byaf | png 必需 | `src/endpoints/characters.js:1567-1572` |

**Chat backup 文件格式 = 聊天文件本身的字节副本**（不是打包格式、无额外头信息），所以 iOS 支持它几乎零成本：把 `.jsonl` 复制到 `backups/` 并保留命名约定即可。

---

## 8. 兼容性清单（Swift 持久化层设计建议）

### 8.1 必须严格保持兼容（决定能否与 ST / 其他前端互通）

| # | 格式 | 必须保持的细节 | 依据 |
|---|---|---|---|
| 1 | **聊天 JSONL** | ① UTF-8、每行一个**紧凑** JSON（`JSON.stringify` 默认无空格）、`\n` 分隔、**无 BOM、无末尾换行**；② 第 1 行必须是 `chat_metadata` 头（含 `user_name`/`character_name` 占位）；③ 未知字段必须原样保留（`extra` 是开放对象）；④ `swipes[swipe_id] === mes`；⑤ `swipe_info` 与 `swipes` 等长；⑥ `send_date`/`gen_started`/`gen_finished` 用 ISO 8601 字符串（ST 的 `timestampToMoment` 需要能解析；`src/endpoints/chats.js:485` 也允许数字/日期兜底）；⑦ `uid`/字段顺序无关，但不要重排成缩进 JSON（ST 有逐行解析器，缩进会破坏） | `src/endpoints/chats.js:532-533, 459-464, 482-485`、`public/global.d.ts:66-128` |
| 2 | **PNG 角色卡** | `tEXt` chunk 关键字 **`chara`**（必需）与 **`ccv3`**（可选，优先）；值是 **base64(UTF-8 JSON)**；遵守 Spec V2 字段名（`spec`, `spec_version`, `data.*`, `data.extensions.*`, `data.character_book`）。iOS 可直接用 ImageIO/CGImage 的 PNG 元数据读写实现 | `src/character-card-parser.js:15-78`、`src/types/spec-v2.d.ts` |
| 3 | **worlds JSON** | 顶层必须含 `entries`；`entries` 是**以 uid 字符串为 key 的对象**；条目用 ST 的 camelCase 字段名（`key`, `keysecondary`, `selectiveLogic`, `excludeRecursion`, `matchWholeWords`, `groupWeight`, `delayUntilRecursion`, `displayIndex`, `ignoreBudget`, …）；`position`/`selectiveLogic`/`role` 用整数枚举 | `src/endpoints/worldinfo.js:114-121,144-154`、`public/scripts/world-info.js:4082-4129` |
| 4 | **目录布局与命名** | `chats/<avatar 去 .png>/<chat>.jsonl`、`characters/<name>.png`、`worlds/<name>.json`、`User Avatars/*.png`、`group chats/<chat_id>.jsonl`、`groups/<id>.json`。iOS 若要"把 ST 用户目录直接拷进 App 沙盒"，这套路径必须逐字一致 | `src/constants.js:16-48`、`src/endpoints/chats.js:551` |
| 5 | **settings.json 字段名** | 至少 `username / user_avatar / amount_gen / max_context / main_api / swipes / active_character / active_group / power_user.{theme,personas,persona_descriptions,instruct,context,sysprompt,persona_description*} / oai_settings.{chat_completion_source,temp_openai,top_p_openai,openai_max_context,openai_max_tokens,stream_openai,openai_model,...} / world_info_settings.*` 要能互通 | `public/script.js:8069-8094` |
| 6 | **群定义 `groups/<id>.json`** | `id / name / members[]（存 avatar 文件名）/ disabled_members / chat_id / chats[]` 必居其一，否则群聊找不到文件 | `src/endpoints/groups.js:163-178`、`src/endpoints/chats.js:975-983` |

### 8.2 建议保留但可降级

- `chat_metadata.integrity`：保留（UUID 字符串）。多端/iCloud 场景下可防止覆盖写；缺失时 ST 会跳过校验，所以 iOS 端不写也能用。
- `chat_metadata.tainted` / `scenario` / `mes_example` / `system_prompt` / `persona` / `world_info` / `note_*` / `timedWorldInfo`：建议原样保存（未知 key 也不要丢），否则 ST 打开后行为会变化。
- 消息 `extra` 里的 `reasoning*` / `token_count` / `api` / `model` / `media*`：UI 可能用不到，但保留可无损往返。
- `thumbnails/`、`_cache/`、`_uploads/`：可丢弃。

### 8.3 可以自由设计的部分（iOS 内部实现）

- 索引：ST 靠 `readdir` + 逐文件扫描（`src/endpoints/chats.js:993-995, 1020-1023`）。iOS 可以用 SwiftData 建 `Character/Chat/Message/World` 实体做索引与搜索，但 **磁盘上的真实文件仍应是上面 §8.1 的格式**，索引只是缓存。
- 消息存储：可以把 JSONL 整文件按行读入内存（ST 也是 `getChatData()` 全量读：`src/endpoints/chats.js:577-590`），文件名即主键。
- API Key：ST 把密钥放 `secrets.json`（`src/constants.js`/`src/endpoints/secrets.js`），iOS 应改用 Keychain，settings.json 里只留非敏感项。

### 8.4 iOS 解析器容错清单（读 ST 文件时）

1. 第 1 行可能是**没有** `chat_metadata` 的旧文件（老版本群聊）：此时应把第 1 行当普通消息处理，并自建空 metadata（`src/endpoints/groups.js:78-85` 的迁移逻辑就是这种情况）。
2. 最后一行可能被截断：ST 的做法是 `chat_items = 行数 - 2`、预览置空（`src/endpoints/chats.js:489-499`）。
3. 第 1 行可能带 UTF-8 BOM：ST 读取时 `replace(/^\uFEFF/,'')`（`src/endpoints/chats.js:350`）。
4. 老世界书条目可能缺 `triggers`/`ignoreBudget`/`vectorized`，且 `sticky/cooldown/delay` 是 `0` 而新模板是 `null`（`default/content/Eldoria.json` vs `world-info.js:4118-4120`）→ 解码时全部用「可选 + 默认值」。
5. 角色卡可能是 V1（无 `spec`，只有扁平 `name/description/...`）→ 需要 V1→V2 升级（`src/endpoints/characters.js:469-493, 990-1017`）。
6. `avatar: 'none'` 表示无头像（`src/endpoints/characters.js:589`）。
7. 世界书文件可能只有 `{"entries":{}}`（`src/endpoints/worldinfo.js:18`）。

---

## 9. 附录：来源索引（快速跳转）

| 主题 | 关键文件:行 |
|---|---|
| 目录模板 | `src/constants.js:16-48` |
| 用户目录拼接 | `src/users.js:683-696` |
| 聊天保存/读取 | `src/endpoints/chats.js:545-619` |
| JSONL 序列化 | `src/endpoints/chats.js:532-533` |
| 聊天元信息扫描 | `src/endpoints/chats.js:393-506` |
| 完整性校验 | `src/endpoints/chats.js:337-368, 532-543` |
| 群聊保存/读取 | `src/endpoints/chats.js:878-935`、`public/scripts/group-chats.js:255-314, 623-642` |
| 前端 chat 头 | `public/script.js:7427-7446` |
| 前端类型声明 | `public/global.d.ts:26-128` |
| 消息构建 | `public/script.js:5861-5902, 6743-6829` |
| 分支/书签 | `public/scripts/bookmarks.js:172-301` |
| 角色枚举 | `src/endpoints/characters.js:406-441, 1466-1478` |
| 角色卡 V2 组装 | `src/endpoints/characters.js:565-657` |
| PNG 元数据 | `src/character-card-parser.js:15-78` |
| 世界书端点 | `src/endpoints/worldinfo.js:17-157` |
| WI 条目定义 | `public/scripts/world-info.js:4082-4149` |
| WI → character_book | `src/endpoints/characters.js:663-722` |
| 设置端点 | `src/endpoints/settings.js:206-296` |
| settings 保存载荷 | `public/script.js:8069-8094` |
| power_user 默认值 | `public/scripts/power-user.js:116-343` |
| oai_settings 默认值 | `public/scripts/openai.js:411-518` |
| Persona | `public/scripts/personas.js:88-105, 515-537, 897-932`、`public/script.js:3203-3225` |
| 备份 | `src/endpoints/settings.js:88-156`、`src/endpoints/chats.js:32-81`、`src/users.js:1148-1183` |
