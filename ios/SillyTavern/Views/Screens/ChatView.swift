import SwiftUI

/// 聊天界面。
///
/// 职责：渲染消息列表、驱动流式生成、提供输入框与中断按钮。
/// 所有业务逻辑都在 `ChatViewModel` 里，这里只做展示与事件转发。
struct ChatView: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var viewModel: ChatViewModel
    @State private var inputText = ""
    @State private var showWorldInfoPanel = false
    @FocusState private var isInputFocused: Bool

    private let character: CharacterCard?

    init(store: AppStore, session: ChatSession) {
        _viewModel = StateObject(wrappedValue: ChatViewModel(store: store, session: session))
        self.character = store.character(for: session.characterId)
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            inputBar
        }
        .navigationTitle(character?.displayName ?? "对话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showWorldInfoPanel = true
                } label: {
                    Image(systemName: "book.closed")
                }
                .accessibilityLabel("查看本次激活的世界书条目")
            }
        }
        .sheet(isPresented: $showWorldInfoPanel) {
            WorldInfoActivationView(entries: viewModel.lastActivatedWorldInfo)
        }
        .alert("出错了", isPresented: errorBinding) {
            Button("好", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .onAppear {
            // 进入会话时默认聚焦输入框，省一次点击。
            if viewModel.messages.isEmpty { isInputFocused = true }
        }
        .onChange(of: viewModel.isGenerating) { wasGenerating, isGenerating in
            // 生成结束（或用户中断）后把焦点还给输入框，方便接着说话。
            if wasGenerating, !isGenerating {
                isInputFocused = true
            }
        }
    }

    // MARK: - 消息列表

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(viewModel.messages) { message in
                        VStack(alignment: .leading, spacing: 8) {
                            MessageBubble(
                                message: message,
                                characterName: character?.displayName ?? "",
                                showTimestamp: store.settings.showTimestamps
                            )
                            .equatable()

                            if let reasoning = message.extra.reasoning, !reasoning.isEmpty {
                                ReasoningDisclosure(text: reasoning)
                            }
                        }
                        .id(message.id)
                    }

                    // 流式气泡：紧跟在已提交消息之后。
                    if viewModel.isGenerating {
                        VStack(alignment: .leading, spacing: 8) {
                            MessageBubble(
                                message: ChatMessage(
                                    name: character?.displayName ?? "",
                                    mes: "",
                                    isUser: false
                                ),
                                characterName: character?.displayName ?? "",
                                showTimestamp: false,
                                isStreaming: true,
                                streamingOverride: viewModel.streamingText
                            )
                            .equatable()
                            .id("streaming")

                            if !viewModel.streamingReasoning.isEmpty {
                                ReasoningDisclosure(text: viewModel.streamingReasoning)
                            }
                        }
                    }

                    // 底部锚点：用于自动滚动。
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.messages.count) { _, _ in
                scrollToBottom(proxy, animated: true)
            }
            .onChange(of: viewModel.streamingText) { _, _ in
                // 流式期间不带动画，否则滚动会抖。
                scrollToBottom(proxy, animated: false)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    // MARK: - 输入栏

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("说点什么…", text: $inputText, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .focused($isInputFocused)
                .disabled(viewModel.isGenerating)

            if viewModel.isGenerating {
                Button {
                    viewModel.stop()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                }
                .accessibilityLabel("停止生成")
            } else {
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("发送")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func send() {
        let text = inputText
        inputText = ""
        viewModel.send(text)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }
}

/// 本次生成激活了哪些世界书条目。
///
/// SillyTavern 也有类似面板——排查「角色为什么没按设定回答」时非常有用。
struct WorldInfoActivationView: View {
    let entries: [ActivatedWorldInfoEntry]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "没有条目被激活",
                        systemImage: "book.closed",
                        description: Text("本轮没有世界书条目命中关键词。")
                    )
                } else {
                    List(entries, id: \.entry.id) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.entry.displayTitle)
                                .font(.headline)
                            if !item.matchedKeys.isEmpty {
                                Text("命中：" + item.matchedKeys.joined(separator: "、"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(item.entry.content)
                                .font(.footnote)
                                .lineLimit(4)
                        }
                    }
                }
            }
            .navigationTitle("本次激活的世界书")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
