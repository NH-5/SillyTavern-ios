import SwiftUI
import UIKit

/// 角色详情页：查看角色卡内容、挑选开场白、开始或继续对话。
struct CharacterDetailView: View {
    @EnvironmentObject private var store: AppStore
    let card: CharacterCard

    @State private var selectedGreeting = 0
    @State private var openedSession: ChatSession?
    @State private var sessionToDelete: ChatSession?
    @State private var exportURL: URL?

    /// 每次都从 store 取最新数据，这样编辑后页面会自动刷新。
    private var currentCard: CharacterCard {
        store.character(for: card.id) ?? card
    }

    private var greetings: [String] {
        ([currentCard.firstMes] + currentCard.alternateGreetings)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var existingSessions: [ChatSession] {
        store.sessions(for: currentCard)
    }

    var body: some View {
        List {
            header

            if greetings.count > 1 {
                greetingSection
            }

            sessionSection
            characterSheetSection

            if let book = currentCard.characterBook, !book.entries.isEmpty {
                embeddedWorldInfoSection(book)
            }

            Section("文件") {
                Button {
                    exportCard()
                } label: {
                    Label("准备导出（PNG 角色卡）", systemImage: "square.and.arrow.up")
                }
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("分享角色卡文件", systemImage: "paperplane")
                    }
                }
                Text("导出的 PNG 同时包含 chara 与 ccv3 元数据，可直接导入任何 SillyTavern 实例。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(currentCard.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $openedSession) { session in
            ChatView(store: store, session: session)
        }
        .confirmationDialog(
            "删除这个会话？",
            isPresented: Binding(
                get: { sessionToDelete != nil },
                set: { if !$0 { sessionToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let session = sessionToDelete {
                    store.deleteSession(session)
                }
                sessionToDelete = nil
            }
        }
    }

    // MARK: - 各区块

    private var header: some View {
        Section {
            HStack(spacing: 14) {
                if let image = store.avatarImage(for: currentCard) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    // 头像尚未解码完成时的占位，避免出现空洞。
                    ZStack {
                        Color.accentColor.opacity(0.2)
                        Text(String(currentCard.displayName.prefix(1)))
                            .font(.largeTitle.bold())
                            .foregroundStyle(.tint)
                    }
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 6) {
                    if !currentCard.creator.isEmpty {
                        Label(currentCard.creator, systemImage: "person.crop.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !currentCard.characterVersion.isEmpty {
                        Label(currentCard.characterVersion, systemImage: "tag")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !currentCard.tags.isEmpty {
                        Text(currentCard.tags.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .task(id: currentCard.id) {
                // 详情页也要主动触发解码，否则头像缓存被回收或角色改名后
                // 这里会一直停在占位图上。
                store.loadAvatarIfNeeded(for: currentCard)
            }

            Button {
                startChat()
            } label: {
                Label("开始新对话", systemImage: "bubble.left.and.text.bubble.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
    }

    private var greetingSection: some View {
        Section("开场白") {
            Picker("选择开场白", selection: $selectedGreeting) {
                ForEach(Array(greetings.enumerated()), id: \.offset) { index, text in
                    Text(previewText(text))
                        .tag(index)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            if selectedGreeting < greetings.count {
                Text(greetings[selectedGreeting])
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
            }
        }
    }

    private var sessionSection: some View {
        Section("历史对话") {
            if existingSessions.isEmpty {
                Text("还没有对话记录。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(existingSessions) { session in
                    Button {
                        openedSession = session
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.name)
                                .font(.subheadline.weight(.medium))
                            Text(session.preview.isEmpty ? "（空会话）" : session.preview)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) {
                            sessionToDelete = session
                        }
                    }
                }
            }
        }
    }

    private var characterSheetSection: some View {
        Section("角色卡") {
            field("描述", currentCard.description)
            field("性格", currentCard.personality)
            field("场景", currentCard.scenario)
            field("开场白", currentCard.firstMes)
            field("对话示例", currentCard.mesExample)
            field("作者备注", currentCard.creatorNotes)
            field("主提示词", currentCard.systemPrompt)
            field("历史后指令", currentCard.postHistoryInstructions)
        }
    }

    private func embeddedWorldInfoSection(_ book: CharacterBook) -> some View {
        Section("内嵌世界书（\(book.entries.count) 条）") {
            ForEach(book.entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.displayTitle)
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text(entry.enabled ? "启用" : "停用")
                            .font(.caption2)
                            .foregroundStyle(entry.enabled ? .green : .secondary)
                    }
                    if !entry.keys.isEmpty {
                        Text("关键词：" + entry.keys.joined(separator: "、"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.content)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func field(_ title: String, _ value: String) -> some View {
        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            DisclosureGroup {
                Text(value)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            } label: {
                Text(title)
            }
        }
    }

    // MARK: - 动作

    private func startChat() {
        let session = store.createSession(for: currentCard, greetingIndex: selectedGreeting)
        openedSession = session
    }

    /// 导出角色卡：写一份 PNG 到临时目录，供分享面板使用。
    private func exportCard() {
        guard let png = try? CharacterCardCodec.exportPNG(
            currentCard,
            baseImage: store.avatarData(for: currentCard)
        ) else { return }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(LocalStorage.sanitizeFileName(currentCard.displayName)).png")
        try? png.write(to: url)
        exportURL = url
    }

    private func previewText(_ text: String) -> String {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? ""
        return firstLine.isEmpty ? "（空开场白）" : String(firstLine.prefix(30))
    }
}
