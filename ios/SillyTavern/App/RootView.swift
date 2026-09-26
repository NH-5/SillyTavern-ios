import SwiftUI

/// 主界面骨架：底部三个标签页。
///
/// 之所以先立这个骨架，是为了让后续每个模块都能独立编译运行，
/// 避免一次性写完几十个文件才发现架构性问题。
struct RootView: View {
    @EnvironmentObject private var store: AppStore
    /// 由 `SillyTavernApp` 传入的深链目标；处理完会被清空。
    @Binding var deepLink: DeepLink?

    @State private var selectedTab = 0

    init(deepLink: Binding<DeepLink?> = .constant(nil)) {
        _deepLink = deepLink
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                CharacterListView()
            }
            .tabItem {
                Label("角色", systemImage: "person.2.fill")
            }
            .tag(0)

            NavigationStack {
                ChatListView(deepLink: $deepLink)
            }
            .tabItem {
                Label("对话", systemImage: "bubble.left.and.bubble.right.fill")
            }
            .tag(1)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("设置", systemImage: "gearshape.fill")
            }
            .tag(2)
        }
        .onChange(of: deepLink) { _, newValue in
            // 深链指向会话时，自动切到「对话」标签。
            if case .chat = newValue?.target {
                selectedTab = 1
            }
        }
    }
}

#Preview {
    RootView().environmentObject(AppStore())
}
