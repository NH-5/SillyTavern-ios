# 07 · iOS 界面层（App/ + Views/）类型审查报告

**审查对象**：`ios/SillyTavern/App/`（3 个文件）+ `ios/SillyTavern/Views/`（6 个文件，共 1583 行），
以及它们调用的 `Models/`（10 个文件）与 `Services/`（16 个文件）。

**审查环境**：Xcode 27 / `iPhoneSimulator27.0.sdk`，目标 `arm64-apple-ios18.0-simulator`，`-swift-version 5`
（与 `ios/SillyTavern.xcodeproj` 的 `IPHONEOS_DEPLOYMENT_TARGET = 18.0` / `SWIFT_VERSION = 5.0` 一致）。

**审查方式**：**真实编译验证**，不是阅读推测。见 §0。

**总结论**：

| 档位 | 数量 |
| --- | --- |
| 确定会编译失败 | **0** |
| 可能有问题 / 需要确认 | 3 条实质问题（1 处运行期崩溃隐患、1 处功能缺陷、1 处注释与事实不符）+ 3 条明确标注「不确定」的项 |
| 已确认正确（逐条对应任务清单 1–8） | 见 §3 |

> 任务前提里「界面层从未经过类型检查」在本报告中被直接验证取代：**界面层可以编译，而且编译通过**。
> 下面先讲清楚怎么验证的（这是本报告最可复用的部分），再逐条给出结论。

---

## 0. 审查方法、冻结版本与可复现性

### 0.1 突破点：`swiftc -disable-sandbox`

之前无法编译界面层的原因是：`@State` / `@StateObject` / `#Preview` 在本 SDK 里是**宏**，声明形如：

```swift
@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(`_`), prefixed(__), prefixed(`$`))
public macro State() = #externalMacro(module: "SwiftUIMacros", type: "StateMacro")
```

宏展开由 `swift-plugin-server` 完成，而 swiftc 启动它时会套一层 `sandbox-exec`；
本会话已经在沙箱内，于是报：

```
sandbox-exec: sandbox_apply: Operation not permitted
error: external macro implementation type 'SwiftUIMacros.StateMacro' could not be found for macro 'State()'
```

`swiftc` 自带 `-disable-sandbox`（`swiftc --help` 中的原文：*Disable using the sandbox when executing subprocesses*），
它禁用的是**编译器给子进程套的那层沙箱**，不影响 DSH 自身的文件沙箱。
加上它之后宏展开正常，`@State` / `@StateObject` / `#Preview` 全部可用，界面层即可正常类型检查。

还有一个次要坑：模块缓存必须指向可写目录，默认的 `/var/folders/.../ModuleCache` 会被文件沙箱拒绝
（`error opening '.../ModuleCache/Swift-XXXX.swiftmodule' for output: Operation not permitted`）。

### 0.2 复现命令（本报告的全部结论都由它产生）

```bash
cd /Users/wuzheng/projects/SillyTavern-ios
SDK=/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk
FILES=$(find ios/SillyTavern -name '*.swift' | sort)      # 35 个文件，含全部 App/ 与 Views/

# ① 类型检查（最快，用来定位类型错误）
swiftc -target arm64-apple-ios18.0-simulator -sdk "$SDK" -swift-version 5 -disable-sandbox \
  -D DEBUG -D XCODE_BUILD \
  -module-cache-path "$PWD/ios/build/ui-review-mc" \
  -typecheck $FILES

# ② 完整编译 + 链接（更强，连 SIL 代码生成与链接都过一遍）
swiftc -target arm64-apple-ios18.0-simulator -sdk "$SDK" -swift-version 5 -disable-sandbox \
  -D DEBUG -D XCODE_BUILD -Onone -g \
  -module-cache-path "$PWD/ios/build/ui-review-mc" \
  -o /tmp/SillyTavernApp $FILES
```

实测结果：

```
① exit 0，error 0 条，warning 0 条
② exit 0，error 0 条；产物 Mach-O 64-bit executable arm64（3.2 MB）
唯一一条 warning 来自我的手工链接命令本身：clang: warning: using sysroot for 'macOS 27.0'
but targeting 'arm64-apple-ios18.0.0-simulator' [-Wincompatible-sysroot]，与源码无关。
```

`-D DEBUG -D XCODE_BUILD` 是按 Xcode Debug 配置复刻的（`SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG XCODE_BUILD $(inherited)"`）。

### 0.3 怎么确认「真的检查了界面层」而不是空跑

用一个故意写错参数的探针文件与源码一起编译，确认编译器的确在检查 View 的 body 与 `#Preview` 宏体：

```swift
// /tmp/probe.swift（与 35 个源文件一起编译）
import SwiftUI
func probeBroken()   { _ = MessageBubble(message: 1) }        // 故意：类型错
func probeMissingArg() { _ = CharacterDetailView() }          // 故意：少参数
func probeBadType()  { let b: Binding<Int> = .constant("no"); _ = Text("\(b)") }
```

```
/tmp/probe.swift:3:22: error: missing arguments for parameters 'characterName', 'showTimestamp' in call
/tmp/probe.swift:3:32: error: cannot convert value of type 'Int' to expected argument type 'ChatMessage'
/tmp/probe.swift:6:29: error: missing argument for parameter 'card' in call
/tmp/probe.swift:9:37: error: cannot convert value of type 'String' to expected argument type 'Int'
```

`#Preview` 宏体同样被检查（另一支探针）：

```swift
#Preview { MessageBubble(message: 1) }
// → error: missing arguments for parameters 'characterName', 'showTimestamp' in call
```

### 0.4 冻结版本（本报告的行号都基于这一版）

审查完成时间 2026-09-26 15:38（CST）。类型检查前后对全部源文件做过 sha256 比对，**检查期间源码未变动**。

| 文件 | 行数 | sha256 前 12 位 |
| --- | --- | --- |
| `App/AppStore.swift` | 454 | `e3304b44e953` |
| `App/RootView.swift` | 38 | `2d78a02b976c` |
| `App/SillyTavernApp.swift` | 19 | `8bbf0bd3b787` |
| `Views/Components/MessageBubble.swift` | 99 | `2e198799aa3a` |
| `Views/Screens/CharacterDetailView.swift` | 254 | `3559d2ddab82` |
| `Views/Screens/CharacterListView.swift` | 158 | `7b87611c9e48` |
| `Views/Screens/ChatListView.swift` | 87 | `6e3c12600df4` |
| `Views/Screens/ChatView.swift` | 226 | `f8f3a55d6c9c` |
| `Views/Screens/SettingsView.swift` | 248 | `36c70aa26774` |

### 0.5 ⚠️ 审查期间有另一个 agent 在并发修改这批文件

请务必知道这一点，否则会对不上号：

| 时间 | 变化 |
| --- | --- |
| 15:27:52 | `ios/build/intermediates/` 里留有一份**重构前**快照（`AppStore.swift` 404 行，Views 用 `store.avatarData(for:)` + `UIImage(data:)`） |
| 15:32:42 – 15:33:19 | `CharacterListView` / `CharacterDetailView` / `ChatListView` 改为 `store.avatarImage(for:)`；新增 `Services/PlatformImage.swift`；`AppStore.swift` 404 → 454 行（`NSCache` + `Task.detached` 异步解码头像） |
| 15:34:35 – 15:34:41 | `LLMClient` / `WorldInfoEngine` / `CharacterCardCodec` 修掉了 3 处 `warning`（未使用变量、未使用返回值） |
| 15:35:07 | `ChatView.swift` 220 → 226 行（新增生成结束后回焦输入框的 `onChange`） |

**两个状态我都编译过，都是 0 error**：

- 重构前快照（`/tmp/oldsnap`，即 `ios/build/intermediates/` 的 33 个文件）：0 error；
- 当前树（§0.4 的 35 个文件）：0 error、0 warning。

因此「界面层之前会不会编译失败」这个问题也有答案：**不会**。之前缺的是验证手段，不是正确性。

---

## 1. 确定会编译失败：**无（0 处）**

9 个界面层文件逐个类型检查 + 整体完整编译链接，均无 error、无 warning：

| 文件 | error | warning |
| --- | --- | --- |
| `App/SillyTavernApp.swift` | 0 | 0 |
| `App/RootView.swift` | 0 | 0 |
| `App/AppStore.swift` | 0 | 0 |
| `Views/Screens/CharacterListView.swift` | 0 | 0 |
| `Views/Screens/CharacterDetailView.swift` | 0 | 0 |
| `Views/Screens/ChatView.swift` | 0 | 0 |
| `Views/Screens/ChatListView.swift` | 0 | 0 |
| `Views/Screens/SettingsView.swift` | 0 | 0 |
| `Views/Components/MessageBubble.swift` | 0 | 0 |

另外确认过工程本身不会引入额外的编译失败：

- **旁证（独立路径）**：在我做上述验证的同一时间，另有 agent 用 Xcode 真机构建产出了 `ios/build/SillyTavern.app`
  （含 `_CodeSignature` 与 `Info.plist`，主程序 3.1 MB，15:36:09），并在 iOS 模拟器里把 App 跑了起来
  （截图 `ios/build/screenshot.png`，15:36:20）：首屏「角色」页正常渲染 `ContentUnavailableView`
  的标题/描述/按钮、右上角 `+` 工具栏按钮、底部三个 Tab。也就是说，除了源码编译，
  **真实 `xcodebuild` + 运行也是通的**，与本报告结论一致。
- `ios/SillyTavern.xcodeproj/project.pbxproj` 用的是 `PBXFileSystemSynchronizedRootGroup`（同步文件夹），
  所以 `App/`、`Views/`、`Models/`、`Services/` 下的文件**自动进 target**，不存在「文件没加进 target」的漏编译问题；
- 工程没有 `SWIFT_TREAT_WARNINGS_AS_ERRORS`、没有 `SWIFT_STRICT_CONCURRENCY`（Swift 5 默认 minimal）；
- `IPHONEOS_DEPLOYMENT_TARGET = 18.0`，我的编译目标也是 iOS 18.0，因此**所有 API 的可用性都被真实校验过**：
  没有用到任何高于 iOS 18 的 API。

---

## 2. 可能有问题 / 需要确认

### 2.1 【运行期崩溃隐患】`CharacterListView.swift:71-75`：按下标边遍历边删除，多选删除会越界

```swift
.onDelete { indexSet in
    for index in indexSet {
        store.deleteCharacter(store.characters[index])   // ← 删除后数组整体前移
    }
}
```

`deleteCharacter` 会立刻 `characters.removeAll { $0.id == card.id }`，数组长度减 1，
而 `indexSet` 里的下标是按**删除前**的数组算的。只要 `indexSet` 含 2 个及以上下标
（例如 `[0, 1]`、数组只剩 1 个元素时再取 `[1]`），第 2 次访问就是
`Fatal error: Index out of range` —— 直接崩溃。

- **触发条件**：需要一次删除多行。当前界面没有 `EditButton`，所以最常见的「左滑删除单行」只会传单个下标，
  不会崩；但只要以后加编辑模式、多选、或 SwiftUI 在某些路径下批量回调，就会崩。
- **修复**（先取出卡片，再删；顺带用 `indices.contains` 兜住过期下标）：

```swift
// CharacterListView.swift:71-75 整段替换
            .onDelete { indexSet in
                // 先按当前下标取出要删的卡片，再统一删除：
                // deleteCharacter 会让后面的元素整体前移，边删边取下标会越界。
                let doomed = indexSet.compactMap { index in
                    store.characters.indices.contains(index) ? store.characters[index] : nil
                }
                for card in doomed {
                    store.deleteCharacter(card)
                }
            }
```

### 2.2 【功能缺陷，非崩溃】`CharacterDetailView.swift:86`：详情页头像可能永远是空白

头像解码被改成异步（`AppStore.loadAvatarIfNeeded(for:)`，`AppStore.swift:153-175`）之后，
「触发解码」这一步只写在两个列表行里：

- `CharacterListView.swift:149-152`（`CharacterRow.avatar` 上的 `.task`）
- `ChatListView.swift:78-81`

而 `CharacterDetailView` 只**读缓存**、不触发加载：

```swift
// CharacterDetailView.swift:86
if let image = store.avatarImage(for: currentCard) {   // 只查 NSCache，不发起解码
```

正常情况下从列表点进来时，行的 `.task` 已经解码过了，所以看得到；
但以下情况会一直空白（`header` 又没有 `else` 占位分支，于是那一格什么都没有）：

- 头像被 `NSCache` 回收（`countLimit = 60`，或内存压力）时；
- 角色卡被改名/更新后 `invalidateAvatar` 清了缓存（`AppStore.swift:136-140`、`:117`），而列表行没重新出现。

**修复**：在 Detail 的 `List` 链上加一行（用 `id:` 保证改名后也会重跑）：

```swift
// CharacterDetailView.swift:58 之后（.navigationBarTitleDisplayMode(.inline) 之前/之后均可）
        .task(id: currentCard.id) {
            store.loadAvatarIfNeeded(for: currentCard)
        }
```

可选：给 `header` 补一个占位分支，避免解码期间那一行塌陷：

```swift
// CharacterDetailView.swift:86-92
                if let image = store.avatarImage(for: currentCard) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.accentColor.opacity(0.2))
                        .frame(width: 84, height: 84)
                        .overlay { Text(String(currentCard.displayName.prefix(1))).font(.title) }
                }
```

### 2.3 【注释与事实不符】`AppStore.swift:332-335`：`$store.settings.x` 其实**成立**

原文注释：

```swift
    /// SwiftUI 的 `$store.settings.x` 对嵌套结构体不成立，
    /// 所以这里统一提供一层绑定：写入时自动落盘，界面代码不必到处写保存逻辑。
```

这是错的。`@EnvironmentObject` 的投影是 `EnvironmentObject<AppStore>.Wrapper`，
它的 `subscript(dynamicMember:)` 接受 `ReferenceWritableKeyPath`（class 的 `settings` 属性满足），
拿到 `Binding<AppSettings>`；`Binding` 自己也有 `@dynamicMemberLookup`
（`WritableKeyPath<AppSettings, Value>`），所以可以一路点到叶子。
我用探针实测（与全部源文件一起编译，**0 error**）：

```swift
struct ProbeBindingView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        Form {
            TextField("名字", text: $store.settings.userName)
            Stepper("tokens", value: $store.settings.maxTokens, in: 64...32768, step: 64)
        }
    }
}
```

**结论**：`settingsBinding(_:)` 该留，但理由不是「语法上不成立」，而是「写入时要顺带 `saveSettings()` 落盘」。
建议把注释改成：

```swift
    /// 取设置里某个字段的可写绑定。
    ///
    /// 其实 `$store.settings.x` 本身就能取到绑定（`EnvironmentObject.Wrapper` 与 `Binding` 都有
    /// `@dynamicMemberLookup`），但那样写入**不会落盘**。这里统一包一层：写入即 `saveSettings()`，
    /// 界面代码不必到处写保存逻辑。
```

### 2.4 【需要确认·非编译问题】没有资源目录，`AppIcon` / `AccentColor` 只在 Xcode 里出警告

`ios/SillyTavern/Resources/` 是空目录，工程里没有 `Assets.xcassets`，但 build settings 设了
`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` 与 `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor`。
这不会导致编译失败（模拟器跑得起来），但 Xcode 会提示找不到 AppIcon/AccentColor，App 也没有图标。
**修复**：在 `ios/SillyTavern/Resources/` 下建 `Assets.xcassets`（含 `AppIcon.appiconset` 与 `AccentColor.colorset`），
同步文件夹会自动把它加进 target，无需改 pbxproj。

### 2.5 明确标注「不确定」的项

以下内容**不是类型问题**，命令行编译无法覆盖，我不下结论：

1. `.equatable()`（`ChatView.swift:72`、`:95`）配合 `AppStore.loadAvatarIfNeeded` 里手工 `objectWillChange.send()`
   （`AppStore.swift:172`）的刷新时机，是否真的会让列表头像「及时」出现 —— 需要真机/模拟器跑一遍看；
2. `2.1` 的多选删除路径在**当前** UI 下是否可被用户触发（没有 `EditButton`，我判断常规左滑只传单下标，
   所以标为「隐患」而非「必崩」）；我没有在模拟器里实跑，无法给出 100% 触发条件；
3. Xcode 真实 `xcodebuild` 还包含资源编译、Info.plist 生成（`GENERATE_INFOPLIST_FILE = YES`）、签名等步骤，
   我本人只验证了「Swift 源码编译 + 链接」；不过同一时间另一个 agent 的 `xcodebuild` 已经成功产出
   `ios/build/SillyTavern.app` 并跑进模拟器（见 §1 旁证），这一条实际上已被外部证据覆盖。

---

## 3. 已确认正确（逐条对应任务清单 1–8）

### 3.1 属性包装器的声明与访问 —— 全部正确

| 位置 | 用法 | 结论 |
| --- | --- | --- |
| `SillyTavernApp.swift:10` | `@StateObject private var store = AppStore()`（`AppStore` 是 `@MainActor` class） | ✅ `App` 协议在 SDK 里是 `@preconcurrency @MainActor public protocol App`，类型被推断为 MainActor 隔离，属性初始值表达式合法 |
| `RootView.swift:8` | `@EnvironmentObject private var store: AppStore` | ✅ |
| `CharacterListView.swift:7-10` | `@EnvironmentObject` + 3 个 `@State`（含 `@State private var importedCard: CharacterCard?`） | ✅ |
| `CharacterListView.swift:32` | `fileImporter(isPresented: $isImporting, …)` | ✅ |
| `CharacterDetailView.swift:9-12` | `@State private var selectedGreeting/openedSession/sessionToDelete/exportURL`，用 `$selectedGreeting`、`$openedSession` | ✅ |
| `CharacterDetailView.swift:66-69` | 内联 `Binding(get:set:)` 驱动 `confirmationDialog` | ✅ setter 里写 `sessionToDelete`，仍是 MainActor 上下文 |
| `ChatView.swift:8-12` | `@EnvironmentObject` + `@StateObject` + `@State` + `@FocusState` | ✅ |
| `ChatView.swift:136` / `:12` | `.focused($isInputFocused)` 与 `@FocusState private var isInputFocused: Bool` | ✅ SDK：`FocusState<Value>.Binding` 由 `projectedValue` 提供，`Value: Hashable` |
| `ChatView.swift:189` | `@Environment(\.dismiss) private var dismiss` + `dismiss()` | ✅ SDK：`DismissAction.callAsFunction()`，iOS 15+ |
| `MessageBubble.swift:79` | `@State private var isExpanded` + `DisclosureGroup(isExpanded: $isExpanded)` | ✅ |
| `SettingsView.swift:8-11` | `@State` API Key / 提示信息 | ✅ |
| 全仓 | **没有任何 `$store.xxx` 直接取绑定的写法**（`grep '$store'` 只命中一条注释） | ✅ 见 §2.3：其实那样写也合法 |

补充一条容易踩的坑（本项目**没有**踩）：`ReasoningDisclosure(text:)`、`CharacterRow(card:)`
这类「`let` 属性 + `private` 属性包装器」的 struct，成员逐一初始化器仍可用（`@State` 在 SwiftUI 里会
把有默认值的属性处理成可省略参数），跨文件调用编译通过。

### 3.2 绑定类型 —— 全部一致

| 调用点 | 期望类型 | 实际传入 | 结论 |
| --- | --- | --- | --- |
| `SettingsView.swift:132` `Toggle("流式输出", isOn:)` | `Binding<Bool>` | `bind(\.streamingEnabled)` | ✅ |
| `SettingsView.swift:134-139` `Stepper(value:in:step:)` | `Binding<Int>` / `ClosedRange<Int>` / `Int` | `bind(\.maxTokens)` / `64...32768` / `64` | ✅ |
| `SettingsView.swift:141-146` `Stepper` 同上 | `Int` | `bind(\.contextSize)` / `1024...200000` / `1024` | ✅ |
| `SettingsView.swift:148-151` `sliderRow(value:range:step:)` | `Binding<Double>` / `ClosedRange<Double>` / `Double` | `bind(\.temperature)` 等 4 个 | ✅ |
| `SettingsView.swift:173` `Slider(value:in:step:)` | `Binding<Double>` | 形参直传 | ✅ |
| `SettingsView.swift:55-56` `TextField(text:)` | `Binding<String>` | `bind(\.userName)` / `bind(\.userPersona)` | ✅ |
| `SettingsView.swift:69-72` `Picker(selection:)` + `.tag(item.id)` | `Binding<String>` / tag 同为 `String` | `bind(\.activeProviderId)` | ✅ |
| `SettingsView.swift:78` `SecureField(text:)` | `Binding<String>` | `$apiKey` | ✅ |
| `SettingsView.swift:93` `TextField(text:)` | `Binding<String>` | `store.providerBinding(providerId:\.baseURL)` | ✅ |
| `SettingsView.swift:101` `TextField(text:)` | `Binding<String>` | `bind(\.activeModel)` | ✅（写 `activeModel` 会落盘） |
| `ChatView.swift:135` `TextField(text:axis:)` | `Binding<String>` | `$inputText` | ✅ |
| `ChatView.swift:142` `.focused` | `FocusState<Bool>.Binding` | `$isInputFocused` | ✅ |
| `CharacterListView.swift:32` / `SettingsView.swift:38` | `Binding<Bool>` | `$isImporting` / `$isImportingWorldInfo` | ✅ |

泛型桥接也成立：`SettingsView.bind<Value>(_:)`（`:18-20`）→ `AppStore.settingsBinding<Value>(_:)`
（`AppStore.swift:336-346`）→ `Binding<Value>`，`WritableKeyPath<AppSettings, Value>` 一路无类型擦除丢失。
`providerBinding` 里 `ProviderConfig.defaults[0][keyPath: keyPath]`（`AppStore.swift:356`）类型也对
（`defaults` 是 8 个元素的 `static let`，下标 0 恒安全）。

### 3.3 自定义 View 的初始化器 —— 调用点与定义完全匹配

| View | 定义 | 调用点 | 结论 |
| --- | --- | --- | --- |
| `CharacterDetailView(card:)` | `CharacterDetailView.swift:5-12`（`@EnvironmentObject` + `let card`） | `CharacterListView.swift:45`、`:66` | ✅（宏生成的成员逐一初始化器跨文件可用） |
| `ChatView(store:session:)` | `ChatView.swift:16-19`，自定义 `init` 里 `_viewModel = StateObject(wrappedValue:)` | `CharacterDetailView.swift:62`、`ChatListView.swift:40` | ✅ 两个实参标签、顺序都对 |
| `MessageBubble(message:characterName:showTimestamp:)` | `MessageBubble.swift:7-14`，`isStreaming`、`streamingOverride` 有默认值 | `ChatView.swift:67-71`（省略后两个）、`:84-94`（`isStreaming: true, streamingOverride:`） | ✅ |
| `MessageBubble(…).equatable()` | `MessageBubble: View, Equatable`（`:7`，`==` 在 `:16-22`） | `ChatView.swift:72`、`:95` | ✅ |
| `CharacterRow(card:)` | `CharacterListView.swift:105-107` | `CharacterListView.swift:68` | ✅ |
| `WorldInfoActivationView(entries:)` | `ChatView.swift:187-189` | `ChatView.swift:40` | ✅ |
| `ReasoningDisclosure(text:)` | `MessageBubble.swift:77-79` | `ChatView.swift:75`、`:99` | ✅ |
| `MessageBubble(message: ChatMessage(name:mes:isUser:))` | `ChatMessage` 成员逐一初始化器 | `ChatView.swift:85-89` | ✅ 省略 `isSystem/sendDate/…` 合法 |
| `ChatMessage(name:mes:isUser:)`（AppStore） | 同上 | `AppStore.swift:269` | ✅ |

### 3.4 SwiftUI API 的可用性与签名（全部对着 SDK `.swiftinterface` 核对）

目标 iOS 18，下表「可用版本」都 ≤ 18.0，**没有签名不符、没有部署目标不支持**。

| API | SDK 原文签名（节选） | 可用版本 | 代码位置 |
| --- | --- | --- | --- |
| `navigationDestination(item:)` | `func navigationDestination<D, C>(item: Binding<Optional<D>>, @ContentBuilder destination: @escaping (D) -> C) where D : Hashable, C : View` | iOS 17.0+ | `CharacterListView.swift:43`、`CharacterDetailView.swift:61`、`ChatListView.swift:39` |
| `fileImporter(isPresented:allowedContentTypes:allowsMultipleSelection:onCompletion:)` | `… allowsMultipleSelection: Bool, onCompletion: @escaping (Result<[URL], any Error>) -> Void` | iOS 14.0+ | `CharacterListView.swift:31-37`、`SettingsView.swift:37-43`（回调 `Result<[URL], Error>` 与 `handleImport` 形参一致） |
| `ContentUnavailableView { } description: { } actions: { }` | `init(@ContentBuilder label: () -> Label, @ContentBuilder description: () -> Description = { EmptyView() }, @ContentBuilder actions: () -> Actions = { EmptyView() })` | iOS 17.0+ | `CharacterListView.swift:52-59`（含 `actions`） |
| `ContentUnavailableView(_:systemImage:description:)` | `init(_ title: LocalizedStringKey, systemImage name: String, description: Text? = nil)` | iOS 17.0+ | `ChatView.swift:195-199`（注意 `description` 是 `Text?` 而非 ViewBuilder，这里传 `Text` 正确） |
| `ShareLink(item:label:)` | `init(item: URL, subject: Text? = nil, message: Text? = nil, @ContentBuilder label: () -> Label) where Data == CollectionOfOne<URL>` | iOS 16.0+ | `CharacterDetailView.swift:50-52` |
| `onChange(of:) { oldValue, newValue in }` | `func onChange<V>(of value: V, initial: Bool = false, _ action: @escaping (_ oldValue: V, _ newValue: V) -> Void) where V : Equatable` | iOS 17.0+ | `ChatView.swift:51-56`、`:111-113`、`:114-117`（单参数 `perform:` 版本在 iOS 17 已 deprecated，这里用的是新版本 ✅） |
| `scrollDismissesKeyboard(_:)` | `func scrollDismissesKeyboard(_ mode: ScrollDismissesKeyboardMode)` | iOS 16.0+ | `ChatView.swift:110` |
| `textSelection(_:)` | `func textSelection<S>(_ selectability: S) where S : TextSelectability` | iOS 15.0+ | `MessageBubble.swift:38`、`:86`、`CharacterDetailView.swift:221` |
| `DisclosureGroup(isExpanded:content:label:)` | `init(isExpanded: Binding<Bool>, @ContentBuilder content: @escaping () -> Content, @ContentBuilder label: () -> Label)` | iOS 14.0+ | `MessageBubble.swift:82-93`（`content` 是第一个尾随闭包、`label:` 是带标签尾随闭包，顺序正确）、`CharacterDetailView.swift:218-226` |
| `confirmationDialog(_:isPresented:titleVisibility:actions:)` | `func confirmationDialog<A>(_ titleKey: LocalizedStringKey, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic, @ContentBuilder actions: () -> A)` | iOS 15.0+ | `CharacterDetailView.swift:64-78` |
| `swipeActions(edge:allowsFullSwipe:content:)` | `func swipeActions<T>(edge: HorizontalEdge = .trailing, allowsFullSwipe: Bool = true, @ContentBuilder content: () -> T)` | iOS 15.0+ | `CharacterDetailView.swift:165-169`、`ChatListView.swift:29-33` |
| `ToolbarItem(placement: .topBarTrailing)` | `@backDeployed(before: iOS 17.0) public static var topBarTrailing` | iOS 14.0+ | `CharacterListView.swift:22`、`ChatView.swift:30`（`.confirmationAction` 在 `:220`） |
| `task(id:)` | `func task<T>(id: T, …, @_inheritActorContext _ action: @escaping @Sendable () async -> Void)` | iOS 15.0+ | `SettingsView.swift:32-36`、`CharacterListView.swift:149-152`、`ChatListView.swift:78-81` |
| `TextField(_:text:axis:)` + `.lineLimit(1...6)` | `axis: Axis = .horizontal` / `lineLimit(_ limit: ClosedRange<Int>)` | iOS 16.0+ | `ChatView.swift:129-130`、`SettingsView.swift:56-57` |
| `LabeledContent(_:value:)` / `LabeledContent(_:content:)` | iOS 16.0+ | `SettingsView.swift:90`、`:190-192`、`:201` |
| `Color(_ color: UIKit.UIColor)` | `@_disfavoredOverload public init(_ color: UIKit.UIColor)` | iOS 15.0+ | `MessageBubble.swift:70`、`:96`、`ChatView.swift:140`、`ChatListView.swift:57`（`import SwiftUI` 即可，探针实测 `Color(.secondarySystemBackground)` 无需显式 `import UIKit`） |
| `AnyShapeStyle` 作为 `some ShapeStyle` 返回 | `struct AnyShapeStyle : ShapeStyle` | iOS 15.0+ | `MessageBubble.swift:69-71` 两个分支同类型，`some ShapeStyle` 推断成立 |

`List(entries, id: \.entry.id)`（`ChatView.swift:201`）也正确：`ActivatedWorldInfoEntry.entry` 是
`WorldInfoEntry`（`Identifiable`，`id: UUID`），键路径指向 `Hashable` 的 `UUID` ✅。

### 3.5 类型转换与可选值 —— 全部正确

- **`UIImage(data:)`**：重构后界面层已不再直接调用；统一走 `PlatformImage`（`Services/PlatformImage.swift:9`
  `typealias PlatformImage = UIImage`，`:15-17` `UIImage(data:)`），界面层只写 `Image(uiImage:)`
  （`CharacterListView.swift:134`、`ChatListView.swift:49`、`CharacterDetailView.swift:87`），
  `UIImage` 是 `Image(uiImage:)` 的形参类型 ✅。
- **`if let` 绑定**：`if let exportURL`（`CharacterDetailView.swift:49`）、`if let provider`（`SettingsView.swift:75`）、
  `if let card`（`ChatListView.swift:48`、`:80`）、`if let book = currentCard.characterBook, !book.entries.isEmpty`
  （`CharacterDetailView.swift:39`）、`if let reasoning = message.extra.reasoning, !reasoning.isEmpty`
  （`ChatView.swift:74`）—— 语法糖（Swift 5.7+ 的 `if let x` 简写）与可选链都合法 ✅。
- **`??` 兜底**：`viewModel.errorMessage ?? ""`（`ChatView.swift:45`）、`character?.displayName ?? ""`（`:69`、`:86`、`:90`）、
  `store.worldInfos[name]?.entries.count ?? 0`（`SettingsView.swift:201`）、
  `text.split(separator: "\n").first.map(String.init) ?? ""`（`CharacterDetailView.swift:251`）——
  左右类型都一致 ✅。
- **`try?` + 可选绑定**：`guard let png = try? CharacterCardCodec.exportPNG(currentCard, baseImage: store.avatarData(for: currentCard))`
  （`CharacterDetailView.swift:239-242`）：`exportPNG` 形参是 `(CharacterCard, Data?) throws -> Data`，
  `avatarData(for:)` 返回 `Data?`，`try?` 产出 `Data?`，绑定成立 ✅。

### 3.6 访问控制 —— 合法，没有跨文件越权

- `ChatViewModel.session` 是 `private(set) var`（`ChatViewModel.swift:29`）：**读**是 internal（跨文件可读），
  **写**仅限类内部 —— 界面层只读、不写，编译通过 ✅。
- `AppStore` 的 `private func avatarFileURL / invalidateAvatar / uniqueAvatarName / chatFileURL / loadXxx`
  与 `private let avatarCache`、`private var avatarTasks`：都在类的同一文件内使用，
  界面层没有引用任何 `private` 成员（编译验证）✅。
- 界面层里所有 `private var xxx: some View`（如 `CharacterListView.emptyState`、`CharacterDetailView.header`）
  都是**同文件内**使用 ✅。
- 无重复声明：`CharacterRow`、`WorldInfoActivationView`、`ReasoningDisclosure` 全仓各只有一处定义 ✅。

### 3.7 闭包与并发（Swift 5 模式）—— 不会报错，也不会警告

- `ChatView.swift:17` 的 `_viewModel = StateObject(wrappedValue: ChatViewModel(store:store, session:session))`：
  `ChatViewModel` 标了 `@MainActor`。SDK 里 `StateObject` 的声明是
  `@inlinable nonisolated public init(wrappedValue thunk: @autoclosure @escaping () -> ObjectType)`，
  而 `View` 是 `@preconcurrency @MainActor public protocol View` —— `ChatView` 因此被推断为 MainActor 隔离，
  这个非 `@Sendable` 的 autoclosure 继承主线程隔离，所以调用 `@MainActor` 的 `ChatViewModel.init` 合法。
  实测 `-swift-version 5` 下 **0 error、0 warning** ✅。
- `.task { store.loadAvatarIfNeeded(for: card) }`（`CharacterListView.swift:149`、`ChatListView.swift:78`）：
  SDK 中 `task` 的动作参数带 `@_inheritActorContext`，闭包继承视图的 MainActor 隔离，
  因此在闭包里调用 `@MainActor` 的 `AppStore` 方法不会报隔离错误 ✅。
- `SettingsView.swift:32-36` 的 `.task(id:)` 里写 `apiKey` / `keySaved`（`@State`）同样合法 ✅。
- `AppStore.settingsBinding` / `providerBinding` 里 `Binding(get:set:)` 的闭包是非 `@Sendable` 闭包，
  会继承 `@MainActor` 方法（`AppStore` 是 `@MainActor final class`）的隔离，读写 `self.settings` 合法 ✅。
- `AppStore.loadAvatarIfNeeded`（`AppStore.swift:153-175`）的 `Task.detached` + `Task { @MainActor in … }`：
  Swift 5 minimal 检查下不报错；`UIImage` 非 Sendable 只在 Swift 6 严格模式下才会成为问题 —— 见 §2.5 第 3 条。
- 界面层没有 `try!` / `as!` / `fatalError`（对这 9 个文件 grep，命中数全为 0）✅。

### 3.8 其它（`some View` / ViewBuilder / Group / Section）—— 正确

- `@ViewBuilder private func field(_:_:) -> some View`（`CharacterDetailView.swift:215-228`）：`if` 无 `else`，
  ViewBuilder 生成 `Optional<DisclosureGroup<…>>`，类型自洽 ✅；8 个调用点在 ViewBuilder 上限（10）之内 ✅。
- `Group { if … { emptyState } else { characterList } }`（`CharacterListView.swift:13-19`、
  `ChatListView.swift:14-37`）：两个分支都是 `some View`，ViewBuilder 生成 `_ConditionalContent` ✅。
- `CharacterRow.avatar`（`CharacterListView.swift:131-153`）：`Group { if let … else … }` 之后统一
  `.frame`/`.clipShape`/`.task`，修饰符作用在 `Group` 上合法 ✅。
- `Section("文件") { … }`、`Section("开场白") { … }`、`Section { } header: { } footer: { }`
  （`SettingsView.swift:54-62` 等）：`Section(_ titleKey:content:)` 与 `Section(content:header:footer:)` 都存在且用法正确 ✅。
- `List { header; if … ; sessionSection; characterSheetSection; if let book … ; Section("文件") { … } }`
  （`CharacterDetailView.swift:29-58`）：混合 `Section` 与条件分支，编译通过 ✅。
- `ForEach(Array(greetings.enumerated()), id: \.offset)`（`CharacterDetailView.swift:129`）：
  元组元素上的键路径 `\.offset` 与 `{ index, text in }` 解构在本编译器下都成立 ✅（这一条我原本怀疑，
  实测通过 —— 见 §0.2 的编译结果）。
- `VStack(alignment: message.isUser ? .trailing : .leading, …)`（`MessageBubble.swift:32`）、
  `foregroundStyle(entry.enabled ? .green : .secondary)`（`CharacterDetailView.swift:198`）：
  三元表达式两分支同类型 ✅。

---

## 附录 A：建议把界面层纳入自动化验证（可直接加进 `ios/scripts/test.sh`）

`test.sh` 目前把 `App/SillyTavernApp.swift`、`App/RootView.swift`、`Views/` 排除在外，
理由是「命令行编译不了 SwiftUI 宏」。加了 `-disable-sandbox` 之后这个理由不再成立**（仅限 iOS 目标）**，
可以加一个独立阶段（注意：界面层依赖 UIKit，必须编 iOS 目标，不能像现在这样编 macOS 主机程序）：

```bash
echo "==> 界面层类型检查（iOS 18 模拟器目标）"
UI_MODULE_CACHE="${IOS_DIR}/build/modulecache-ui"
mkdir -p "${UI_MODULE_CACHE}"
UI_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
set +e
xcrun swiftc \
    -target arm64-apple-ios18.0-simulator \
    -sdk "${UI_SDK}" \
    -swift-version 5 \
    -disable-sandbox \
    -D DEBUG -D XCODE_BUILD \
    -module-cache-path "${UI_MODULE_CACHE}" \
    -typecheck $(find "${SRC_DIR}" -name '*.swift' -type f | sort) 2>&1 | tee "${BUILD_DIR}/uicheck.log"
STATUS=${PIPESTATUS[0]}
set -e
[ "${STATUS}" -eq 0 ] || { echo "界面层类型检查失败" >&2; grep -E "error:" "${BUILD_DIR}/uicheck.log" | head -20 >&2; exit "${STATUS}"; }
```

想更严格就把 `-typecheck` 换成 `-o "${BUILD_DIR}/SillyTavernApp"` 做完整编译 + 链接（本次实测可过）。

## 附录 B：本次用到的探针（可用于回归）

```swift
// probe1.swift —— 证明 body 真被检查
import SwiftUI
func probeBroken()   { _ = MessageBubble(message: 1) }
func probeMissingArg() { _ = CharacterDetailView() }

// probe2.swift —— 证明 #Preview 宏体被检查
import SwiftUI
#Preview { MessageBubble(message: 1) }

// probe3.swift —— 证明 $store.settings.x 合法（推翻 AppStore.swift:334 的注释）
import SwiftUI
struct ProbeBindingView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        Form {
            TextField("名字", text: $store.settings.userName)
            Stepper("tokens", value: $store.settings.maxTokens, in: 64...32768, step: 64)
        }
    }
}
```

## 附录 C：核验清单（回执用）

- [x] 9 个界面层文件全部读完（§0.4 冻结版本，行号可对应）
- [x] `Models/`（10 个）+ `Services/`（16 个）全部读完，用于核对被调用 API 的签名
- [x] 属性包装器 / 绑定类型 / 自定义初始化器 / SwiftUI API 签名与可用性 / 可选值 / 访问控制 /
      闭包与并发 / `some View` 与 ViewBuilder —— 逐条给出结论（§3.1–§3.8）
- [x] 用 SDK `.swiftinterface` 核对第 3、4 条（§3.4 表内均为 SDK 原文签名）
- [x] 确定会编译失败的问题：**0 处**；另有 1 处运行期崩溃隐患 + 1 处功能缺陷 + 1 处错误注释（§2）
