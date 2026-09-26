import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// 角色列表。导入角色卡、进入聊天、编辑角色都从这里开始。
struct CharacterListView: View {
    @EnvironmentObject private var store: AppStore
    @State private var isImporting = false
    @State private var importError: String?
    @State private var importedCard: CharacterCard?

    var body: some View {
        Group {
            if store.characters.isEmpty {
                emptyState
            } else {
                characterList
            }
        }
        .navigationTitle("角色")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isImporting = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("导入角色卡")
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.png, .json, .data],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert("导入失败", isPresented: importErrorBinding) {
            Button("好", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .navigationDestination(item: $importedCard) { card in
            // 导入成功后直接跳到该角色，方便立刻开聊。
            CharacterDetailView(card: card)
        }
    }

    // MARK: - 子视图

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有角色", systemImage: "person.crop.square.badge.plus")
        } description: {
            Text("导入 SillyTavern 角色卡（PNG 或 JSON）即可开始。")
        } actions: {
            Button("导入角色卡") { isImporting = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var characterList: some View {
        List {
            ForEach(store.characters) { card in
                NavigationLink {
                    CharacterDetailView(card: card)
                } label: {
                    CharacterRow(card: card)
                }
            }
            .onDelete { indexSet in
                // 先把要删的角色取出来再逐个删：直接在循环里按 indexSet 取下标，
                // 删除会让数组前移，多选删除时第二个下标就越界了。
                let targets = indexSet
                    .filter { store.characters.indices.contains($0) }
                    .map { store.characters[$0] }
                for card in targets {
                    store.deleteCharacter(card)
                }
            }
        }
    }

    // MARK: - 导入

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            switch store.importCharacter(from: url) {
            case .success(let card):
                importedCard = card
            case .failure(let error):
                importError = error.localizedDescription
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private var importErrorBinding: Binding<Bool> {
        Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )
    }
}

/// 角色列表的一行：头像 + 名字 + 简介。
struct CharacterRow: View {
    @EnvironmentObject private var store: AppStore
    let card: CharacterCard

    var body: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(card.displayName)
                        .font(.headline)
                    if card.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
                Text(card.creatorNotes.isEmpty ? card.description : card.creatorNotes)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private var avatar: some View {
        Group {
            if let image = store.avatarImage(for: card) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                // 头像还没解码完（或确实没有）时用首字母占位，避免列表出现空洞。
                ZStack {
                    Color.accentColor.opacity(0.2)
                    Text(String(card.displayName.prefix(1)))
                        .font(.title2.bold())
                        .foregroundStyle(.tint)
                }
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task {
            // 只在进入可见区域时解码，长列表滚动不会一次性解压所有头像。
            store.loadAvatarIfNeeded(for: card)
        }
    }
}

#Preview {
    NavigationStack { CharacterListView() }.environmentObject(AppStore())
}
