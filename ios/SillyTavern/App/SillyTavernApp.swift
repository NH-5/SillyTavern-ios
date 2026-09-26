import SwiftUI

/// SillyTavern iOS —— 完全离线的原生客户端。
///
/// 与 Web 版 SillyTavern 的差别：本 App 不连接任何 SillyTavern 服务器，
/// 角色卡解析、世界书触发、Prompt 组装、LLM 调用全部在设备本地完成。
@main
struct SillyTavernApp: App {
    /// 全局应用状态，持有角色库、会话库与设置。
    @StateObject private var store = AppStore()

    /// 通过 URL scheme 进来的深链目标。
    ///
    /// 支持 `sillytavern://chat/<会话 UUID>`：从「快捷指令」「文件」或其它 App
    /// 直接跳进某个会话。也让自动化验证能在无人点击屏幕的情况下打开聊天界面。
    @State private var pendingDeepLink: DeepLink?

    var body: some Scene {
        WindowGroup {
            RootView(deepLink: $pendingDeepLink)
                .environmentObject(store)
                .preferredColorScheme(nil)
                .onOpenURL { url in
                    pendingDeepLink = DeepLink(url: url)
                }
        }
    }
}

/// 深链目标。
struct DeepLink: Equatable {
    enum Target: Equatable {
        case chat(sessionId: UUID)
        case newChat(characterId: UUID)
    }

    var target: Target

    /// 解析 `sillytavern://chat/<uuid>` 或 `sillytavern://character/<uuid>`。
    init?(url: URL) {
        guard url.scheme?.lowercased() == "sillytavern" else { return nil }
        let host = url.host?.lowercased() ?? ""
        let identifier = url.pathComponents.dropFirst().first ?? ""
        guard let id = UUID(uuidString: identifier) else { return nil }

        switch host {
        case "chat": target = .chat(sessionId: id)
        case "character": target = .newChat(characterId: id)
        default: return nil
        }
    }
}

