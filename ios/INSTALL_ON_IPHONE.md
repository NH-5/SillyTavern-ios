# 将 SillyTavern 安装到自己的 iPhone

此工程会在 iPhone **本机**运行 SillyTavern 服务，并在 App 内打开页面；不需要另开一台电脑运行服务。AI 回复仍需要在 SillyTavern 中配置手机能访问的模型 API。

## 准备

- Mac 已安装带 iPhone SDK 的 Xcode，以及 Node.js 20 或更新版本和 npm。
- iPhone 运行 iOS 16 或更新版本，有可用于连接 Mac 的数据线。
- 有可登录 Xcode 的 Apple 账户；免费账户显示为 *Personal Team*，可用于在自己的设备上测试。

## 1. 准备项目资源

在仓库根目录运行：

```sh
bash ios/setup-runtime.sh
bash ios/prepare-bundle.sh
open ios/SillyTavern.xcodeproj
```

前两个脚本分别准备内嵌 Node 运行时和 SillyTavern 服务资源。它们在当前工作区已运行过；全新克隆仓库或修改网页、服务端文件后，需要重新运行相应脚本。不要把 `ios/Vendor/`、`ios/Bundle/` 手工加入 Git。

## 2. 连接 iPhone 并开启开发者模式

1. 用数据线连接 iPhone，保持解锁，在手机弹窗中选择“信任此电脑”并输入锁屏密码。
2. 如果 Xcode 提示启用开发者模式，到手机的 **设置 → 隐私与安全性 → 开发者模式** 开启，按提示重启，然后再次确认。[Apple：在设备上启用开发者模式](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
3. 在 Xcode 的运行设备列表中确认出现**实体 iPhone**。列表中的 `iPhone 12 Pro Simulator` 是模拟器，不能代替实体手机验证。

也可在终端运行 `xcrun devicectl list devices`，通过 `Reality` 一列区分实体设备与模拟器。

## 3. 配置 Xcode 签名

1. 在 **Xcode → Settings → Apple Accounts** 登录自己的 Apple 账户。
2. 在 Xcode 左侧选择 **SillyTavern 项目 → SillyTavern Target → Signing & Capabilities**。
3. 勾选 **Automatically manage signing**，在 **Team** 选择自己的团队或 *Personal Team*。
4. 将占位的 `com.example.SillyTavernLocal` 改为自己的唯一 **Bundle Identifier**，例如 `com.yourname.sillytavern.local`。如果 Xcode 显示标识符已被占用，换一个名称。

为了避免个人签名设置使 Git 工作区出现未提交更改，可以在仓库根目录新建 `ios/SillyTavern/Signing.local.xcconfig`：

```text
DEVELOPMENT_TEAM = 你的 Apple Team ID
PRODUCT_BUNDLE_IDENTIFIER = com.yourname.sillytavern.local
```

这个文件已被 Git 忽略。填入后重新打开 Xcode 项目或重新构建，检查 **Signing & Capabilities** 显示的 Team 和 Bundle Identifier。Team ID 可在 Xcode 的 Apple 账户设置中查看；若先通过 Xcode 界面选择 Team，也可以把该值复制进本地文件，并撤销 Xcode 对 `project.pbxproj` 的相应改动。不要将个人 Team ID 提交到仓库。

自动签名会由 Xcode 管理开发证书、设备注册和描述文件。[Apple：在实体设备上运行 App](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)

## 4. 构建并安装

在 Xcode 顶部选择 **SillyTavern** scheme，将运行目标设为你的**实体 iPhone 12 Pro**，然后按 **⌘R** 或点击运行按钮。首次构建和安装需要复制内嵌服务资源，可能比普通 App 久。构建成功后，手机桌面会出现 SillyTavern 图标。

> 实体设备必须使用 Xcode 的开发签名。用于无签名编译检查的 `CODE_SIGNING_ALLOWED=NO` 不适用于手机安装。

首次打开时等待本机服务初始化，按欢迎页提示完成设置，再配置模型 API。App 在前台时提供本机服务；切到后台后，iOS 可能暂停服务。

## 常见问题

| 现象 | 检查方法 |
| --- | --- |
| Xcode 只显示模拟器 | 检查数据线、手机解锁状态和“信任此电脑”弹窗；等待 Xcode 完成设备配对。 |
| 签名要求开发团队或 Bundle ID 冲突 | 在 **Signing & Capabilities** 选择 Team、启用自动签名，并使用唯一 Bundle Identifier。 |
| 提示 Developer Mode 未开启 | 按第 2 步在手机上开启并重启；开发者模式通常在设备开始与 Mac 配对后出现。 |
| 缺少 `NodeMobile.xcframework` 或 `STServer` | 回到仓库根目录，重新运行第 1 步的两个脚本。 |
| App 打开后未生成 AI 回复 | 在 App 内配置可从手机访问的模型 API；本机服务本身不包含 AI 模型。 |

免费 *Personal Team* 的开发描述文件有效期为 **7 天**，到期后需要用 Xcode 重新构建安装。[Apple：个人开发团队限制](https://developer.apple.com/help/account/basics/about-your-developer-account)
