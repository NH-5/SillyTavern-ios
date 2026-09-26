# SillyTavern iOS —— 完全离线的原生客户端

这是一个用 SwiftUI 重写的 SillyTavern iOS 客户端。它**不连接任何 SillyTavern 服务器**：
角色卡解析、世界书触发、Prompt 组装、Token 预算全部在设备本地完成，只把最终请求发给你选择的模型供应商。

## 为什么是「离线的原生客户端」

SillyTavern 原本是「Node.js 服务端 + 浏览器前端」的架构。iOS 不允许 App 常驻后台运行 Node 服务，
因此这里把服务端那部分能力用 Swift 重新实现了一遍：

| 原 SillyTavern 组件 | 本项目的 Swift 对应实现 |
|---|---|
| `src/character-card-parser.js` + `src/png/*` | `Services/PNGCodec.swift`、`Services/CharacterCardCodec.swift`、`Services/CRC32.swift` |
| `public/scripts/world-info.js` | `Services/WorldInfoEngine.swift`、`Services/WorldInfoCodec.swift` |
| `public/scripts/openai.js`（Prompt 组装） | `Services/PromptBuilder.swift` |
| `public/scripts/macros.js` | `Services/MacroProcessor.swift` |
| `public/scripts/sse-stream.js` | `Services/SSEParser.swift` |
| `src/endpoints/backends/chat-completions.js` | `Services/LLMClient.swift` |
| `src/endpoints/chats.js`（JSONL 读写） | `Services/ChatSessionCodec.swift` |
| `src/endpoints/tokenizers.js` | `Services/TokenEstimator.swift` |

兼容性是硬目标：导出的角色卡、聊天记录、世界书都能和桌面版 SillyTavern 直接互相拷贝使用。
每一条兼容规则的来源都在 `docs/ios-research/` 里标注了对应的源码文件与行号。

## 目录结构

```
ios/
  SillyTavern.xcodeproj        在 Xcode 里打开这个工程
  SillyTavern/
    App/                       应用入口与全局状态（AppStore）
    Models/                    数据模型（角色卡、世界书、消息、设置）
    Services/                  纯逻辑层：解析、组装、网络、持久化
    Views/
      Screens/                 角色列表、角色详情、聊天、会话列表、设置
      Components/              消息气泡等可复用组件
  Tests/main.swift             核心逻辑测试（命令行运行）
  scripts/
    build.sh                   命令行构建 + 安装到模拟器
    test.sh                    命令行跑核心逻辑测试
docs/ios-research/             兼容性研究文档与实现规格
```

## 构建与运行

### 方式一：Xcode（推荐，完整功能）

```sh
open ios/SillyTavern.xcodeproj
```

选择任意 iOS 模拟器或真机，按 ⌘R。工程使用 Xcode 的「文件系统同步组」，
新增 Swift 文件不需要改工程配置。

### 方式二：命令行（无 Xcode GUI 时）

```sh
ios/scripts/build.sh --screenshot    # 编译 + 安装 + 启动 + 截图
ios/scripts/build.sh --no-run        # 只编译出 .app
```

### 运行核心逻辑测试

```sh
ios/scripts/test.sh
```

这套测试不需要模拟器，几秒内跑完 170+ 项断言，覆盖 PNG 解析与 CRC、角色卡三种格式
（v2/v3、v1、Gradio）的导入与往返、世界书文件编解码、世界书触发引擎的关键词匹配各模式、
JSONL 聊天记录往返、SSE 分帧（含三种换行、跨块、多行 data、命名事件）、宏替换、
Token 估算、JSON 渲染与 Base64 容错。

**改动 `Services/` 里的任何解析或组装逻辑后，都应该先跑这个测试。**

## 已知环境限制

当前开发环境启用了文件沙箱，它**禁止嵌套沙箱**（`sandbox-exec` 无法再创建一个沙箱）。
而 Xcode 的 `swift-plugin-server` 必须通过 `sandbox-exec` 启动，
结果是：

- ❌ `xcodebuild` 无法编译（clang 模块缓存被拒）。
- ❌ 命令行 `swiftc` **无法编译任何使用 SwiftUI 宏的代码**——`@State`、`@StateObject`、
  `@Observable`、`#Preview` 在 Xcode 27 里都是宏。

因此本项目的验证策略分两层：

1. **纯逻辑层**（`Models/` + `Services/`）用 `ios/scripts/test.sh` 编译并跑断言，
   这是真正被执行验证过的部分；
2. **界面层**（`Views/`）需要在 Xcode GUI 里编译运行。
   `ios/scripts/build.sh` 会条件化剥离 `#Preview` 块，以便命令行能编译不含 `@State` 的部分。

## 数据存放位置

App 的 Documents 目录（格式与 SillyTavern 一致，可直接互相拷贝）：

```
Documents/
  characters/<角色名>.png        角色卡（角色 JSON 存在 PNG 的 tEXt 块里）
  chats/<角色名>/<会话名>.jsonl   聊天记录
  worlds/<世界书名>.json          世界书
  settings.json                  应用设置
  characters.index.json          角色索引（加速启动，可安全删除后重建）
  sessions.index.json            会话索引
```

API Key 不写在文件里，统一存 iOS 钥匙串。

## 使用步骤

1. 打开 App → 「角色」→ 右上角 `+` → 选择 SillyTavern 角色卡（PNG 或 JSON）。
2. 到「设置」→ 选择供应商 → 填 API Key → 填模型名。
3. 回到角色页进入角色 → 「开始新对话」→ 发送消息。

## 已实现 / 尚未实现

已实现：

- 角色卡 v2/v3（PNG `tEXt` 的 `chara` + `ccv3`）与 v1、Gradio/Pygmalion 格式导入
- 角色卡导出（同时写 `chara` 与 `ccv3`，保留原图像数据）、分享
- 内嵌世界书（`character_book`）与独立世界书（`worlds/*.json`）的读写
- 世界书触发：关键词 / 正则 / 整词 / 大小写 / 次级关键词四种逻辑 / constant /
  概率 / 扫描深度 / 递归扫描 / 预算裁剪 / `ignoreBudget`
- Prompt 组装：主提示词、角色描述与性格、场景、用户人设、世界书前后注入、
  示例对话（`<START>` 解析、`[Example Chat]` 标记）、历史裁剪、深度注入
- 宏替换：角色卡字段、时间日期、`random` / `pick` / `roll` / `trim` / `newline` /
  `reverse` / 注释 / `original` 等
- 三家供应商协议：OpenAI 兼容（含 DeepSeek、OpenRouter、Groq、Ollama 等）、
  Anthropic、Google Gemini
- SSE 流式输出（逐字渲染）、中断生成、思维链折叠显示
- 聊天记录 JSONL 读写（与 ST 互通）、swipes 存储
- 设置：供应商、API Key（钥匙串）、采样参数、上下文长度、persona

尚未实现（后续可加）：

- 消息编辑、swipe 左右切换、重新生成已有回复的 UI
- 世界书的图形化编辑（目前只读展示 + JSON 导入）
- 多模态图片输入（协议层已支持 `image_url`，缺 UI）
- 群聊、会话分支与书签
- 文本补全（Text Completion）类后端
- 世界书的 `sticky` / `cooldown` / `delay` 时序效果（字段已保留）

## 开发时容易踩的坑

这些都是实际调试中踩到并修复过的问题，改代码时留意：

### 1. 手写 `CodingKeys` 会屏蔽 Swift 合成的初始化器

一旦给结构体加了 `init()` 或 `init(from:)`，Swift 就不再自动合成成员逐一初始化器，
`Foo(a:b:)` 这种调用会直接编译失败。需要显式把初始化器补回来
（见 `MessageExtra`、`MacroContext`、`ChatSession`）。

### 2. 一个类型不能同时用两套键名

`ChatMessage` / `ChatMetadata` 的 `CodingKeys` 用的是 ST 的 JSONL 字段名
（`is_user`、`user_name`），因为要写 ST 兼容的聊天记录。
但**本地索引文件必须用驼峰键名**——两者混用会出现「保存过的会话重启后全部消失」
且没有任何报错。现在 `ChatSession` 自己实现 `Codable`，把索引格式与 JSONL 格式分开；
`ChatSessionCodec` 负责 JSONL。改动这两处时请一起看 `ios/Tests/main.swift` 里的
「本地索引格式」测试。

### 3. 忘了把 `id` 放进 `CodingKeys`

`CharacterCard` 曾经漏了 `id`，导致每次启动都生成新的 UUID，
会话与角色的关联全部断裂（会话列表变空）。凡是靠 UUID 关联的数据模型，
都必须把 `id` 写进 `CodingKeys`。已有测试覆盖。

### 4. `Date` 的 Codable 编码不是 Unix 时间戳

Swift 的 `Date` 默认编码为**Apple 参考日期**（2001-01-01 起算的秒数）。
用外部脚本构造索引文件时写 Unix 时间戳会让整个数组解码失败。

### 5. JSON 输出格式

- `JSONEncoder` / `JSONSerialization` 默认把 `/` 转义成 `\/`，而 JavaScript 不转义；
- `.prettyPrinted` 是 2 空格缩进且写成 `"key" : value`，
  而 ST 用 `JSON.stringify(data, null, 4)`，是 4 空格 + `"key": value`。

因此导出世界书、聊天记录时统一走 `Services/JSONRenderer.swift`。

### 6. iOS 27 的 App 图标

iOS 27 模拟器上 `Assets.car` 里的图标**不会**显示（需要 Icon Composer 的 `.icon` 格式，
而它只有 GUI、没有命令行）。`ios/scripts/build.sh` 因此改用传统方式：
生成各尺寸 PNG 放进 bundle 根目录并手写 `CFBundleIconFiles`。
`Assets.xcassets` 仍然保留，供 Xcode GUI 构建与上架使用。

### 7. `#Preview` 与界面层的编译验证

`@State` / `@StateObject` / `#Preview` 在 Xcode 27 里都是宏，需要 `swift-plugin-server`。
如果运行环境禁止嵌套沙箱，宏展开会失败。解决办法是给 `swiftc` 加
`-disable-sandbox`（见 `ios/scripts/test.sh` 末段的界面层类型检查）。

### 8. 菜单项 `swipeActions` / `onDelete` 里的下标

在 `onDelete` 里边循环边按下标取元素，多选删除时会因为数组前移而越界崩溃。
先把目标元素取出来再删（见 `CharacterListView`）。
