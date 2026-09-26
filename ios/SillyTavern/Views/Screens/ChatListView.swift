import SwiftUI

/// 会话列表。按最近更新时间排序，显示角色名与最后一条消息预览。
struct ChatListView: View {
    @EnvironmentObject private var store: AppStore
    /// 深链目标；处理后会清空，避免重复跳转。
    @Binding var deepLink: DeepLink?
    @State private var openedSession: ChatSession?

    init(deepLink: Binding<DeepLink?> = .constant(nil)) {
        _deepLink = deepLink
    }

    private var sortedSessions: [ChatSession] {
        store.sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        Group {
            if store.sessions.isEmpty {
                ContentUnavailableView {
                    Label("还没有对话", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("打开一个角色并发送消息，会话会出现在这里。")
                }
            } else {
                List {
                    ForEach(sortedSessions) { session in
                        Button {
                            openedSession = session
                        } label: {
                            row(for: session)
                        }
                        .swipeActions {
                            Button("删除", role: .destructive) {
                                store.deleteSession(session)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("对话")
        .navigationDestination(item: $openedSession) { session in
            ChatView(store: store, session: session)
        }
        .onChange(of: deepLink) { _, newValue in
            openDeepLinkedSession(newValue)
        }
        .onAppear {
            // 冷启动时直接带深链进来（例如从「快捷指令」打开）。
            openDeepLinkedSession(deepLink)
        }
    }

    /// 处理 `sillytavern://chat/<uuid>`。
    private func openDeepLinkedSession(_ link: DeepLink?) {
        guard case .chat(let sessionId) = link?.target else { return }
        guard let session = store.sessions.first(where: { $0.id == sessionId }) else {
            deepLink = nil
            return
        }
        openedSession = session
        deepLink = nil
    }

    private func row(for session: ChatSession) -> some View {
        let card = store.character(for: session.characterId)
        return HStack(spacing: 12) {
            // 用角色头像做视觉索引，比纯文字列表好认。
            if let card, let image = store.avatarImage(for: card) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Image(systemName: "bubble.left")
                    .frame(width: 44, height: 44)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(session.metadata.characterName.isEmpty ? session.name : session.metadata.characterName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(session.preview.isEmpty ? "（还没有消息）" : session.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(session.updatedAt, format: .dateTime.month().day().hour().minute())
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .task {
            // 进入可见区域时才解码头像。
            if let card { store.loadAvatarIfNeeded(for: card) }
        }
    }
}

#Preview {
    NavigationStack { ChatListView() }.environmentObject(AppStore())
}
