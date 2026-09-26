import Foundation
import SwiftUI

/// 聊天业务编排：把「组装 → 调用 → 流式回写 → 落盘」串成一条链。
///
/// 视图层只负责显示，所有状态变更都收敛到这里，便于后续加分支（swipe）、
/// 重新生成、编辑消息等功能。
@MainActor
final class ChatViewModel: ObservableObject {
    /// 当前会话的消息，供界面直接绑定。
    @Published var messages: [ChatMessage] = []

    /// 正在生成中。
    @Published var isGenerating = false

    /// 流式过程中已累积的文本（显示在最后一条气泡里）。
    @Published var streamingText = ""

    /// 思维链内容（折叠显示）。
    @Published var streamingReasoning = ""

    /// 出错信息，非空时界面弹提示。
    @Published var errorMessage: String?

    /// 最近一次组装的可视化诊断信息。
    @Published var lastActivatedWorldInfo: [ActivatedWorldInfoEntry] = []

    /// 正在编辑中的用户输入由界面持有，这里只接收最终文本。
    private(set) var session: ChatSession
    private let store: AppStore
    private let client = LLMClient()
    private var generationTask: Task<Void, Never>?

    /// 流式文本的节流刷新。
    ///
    /// 模型可能每秒吐出几十个增量，每个都写 `@Published` 会让 SwiftUI 反复重绘
    /// 整个消息列表。这里把增量累积在私有变量里，最多每 0.05 秒同步一次到界面。
    private var throttledText = ""
    private var throttledReasoning = ""
    private var lastFlush = Date.distantPast
    private let flushInterval: TimeInterval = 0.05

    init(store: AppStore, session: ChatSession) {
        self.store = store
        self.session = session
        self.messages = session.messages
    }

    /// 把累积的流式文本同步到界面（按时间节流）。
    private func flushStreaming(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastFlush) >= flushInterval else { return }
        lastFlush = now
        if streamingText != throttledText { streamingText = throttledText }
        if streamingReasoning != throttledReasoning { streamingReasoning = throttledReasoning }
    }

    // MARK: - 发送

    /// 发送用户消息并请求回复。
    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isGenerating else { return }

        let userMessage = ChatMessage(
            name: store.settings.userName,
            mes: trimmed,
            isUser: true
        )
        messages.append(userMessage)
        persist()
        generate()
    }

    /// 重新生成最后一条回复（丢弃当前的助手消息）。
    func regenerate() {
        guard !isGenerating else { return }
        if let last = messages.last, !last.isUser {
            messages.removeLast()
        }
        persist()
        generate()
    }

    /// 中断生成。
    func stop() {
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
        // 把已生成的部分保留下来，避免用户白等。
        if !streamingText.isEmpty {
            commitAssistantMessage(streamingText, reasoning: streamingReasoning)
        }
        streamingText = ""
        streamingReasoning = ""
    }

    // MARK: - 生成流程

    private func generate() {
        guard let card = store.character(for: session.characterId) else {
            errorMessage = "找不到这个角色，可能已被删除。"
            return
        }

        let settings = store.settings
        guard let provider = settings.providers.first(where: { $0.id == settings.activeProviderId }) else {
            errorMessage = "没有选中的模型供应商，请到设置里配置。"
            return
        }

        let apiKey = APIKeyStore.key(for: provider.id)
        if provider.requiresApiKey && apiKey.isEmpty {
            errorMessage = LLMError.missingAPIKey(provider: provider.name).errorDescription
            return
        }
        if provider.baseURL.trimmingCharacters(in: .whitespaces).isEmpty {
            errorMessage = "供应商「\(provider.name)」还没有填写接口地址。"
            return
        }

        // 组装 Prompt。
        let builder = PromptBuilder()
        let input = PromptBuildInput(
            card: card,
            personaName: settings.userName,
            personaDescription: settings.userPersona,
            settings: settings,
            messages: messages,
            extraWorldInfoEntries: store.worldInfoEntries(for: card)
        )
        let buildResult = builder.build(input)
        lastActivatedWorldInfo = buildResult.activatedWorldInfo

        var request = GenerationRequest(
            model: settings.activeModel,
            messages: buildResult.messages,
            temperature: settings.temperature,
            topP: settings.topP,
            frequencyPenalty: settings.frequencyPenalty,
            presencePenalty: settings.presencePenalty,
            maxTokens: settings.maxTokens,
            stream: settings.streamingEnabled,
            stop: settings.stopSequences
        )
        request.extraBody = [:]

        isGenerating = true
        streamingText = ""
        streamingReasoning = ""
        throttledText = ""
        throttledReasoning = ""
        lastFlush = .distantPast
        errorMessage = nil

        let startedAt = ChatMessage.timestamp()

        generationTask = Task { [weak self] in
            guard let self else { return }
            var accumulated = ""
            var reasoning = ""

            do {
                for try await event in self.client.stream(
                    provider: provider,
                    apiKey: apiKey,
                    request: request
                ) {
                    if Task.isCancelled { break }
                    switch event {
                    case .text(let delta):
                        accumulated += delta
                        self.throttledText = accumulated
                        self.flushStreaming()
                    case .reasoning(let delta):
                        reasoning += delta
                        self.throttledReasoning = reasoning
                        self.flushStreaming()
                    case .finished:
                        break
                    }
                }

                // 收尾时强制刷新，保证最后一段增量一定显示出来。
                self.throttledText = accumulated
                self.throttledReasoning = reasoning
                self.flushStreaming(force: true)

                if !accumulated.isEmpty {
                    self.commitAssistantMessage(
                        accumulated,
                        reasoning: reasoning.isEmpty ? nil : reasoning,
                        startedAt: startedAt,
                        model: settings.activeModel,
                        api: provider.name
                    )
                } else if reasoning.isEmpty {
                    self.errorMessage = "模型没有返回任何内容，请检查模型名与参数。"
                } else {
                    // 只返回了思维链：也落盘，避免用户困惑。
                    self.commitAssistantMessage(reasoning, reasoning: reasoning)
                }
            } catch {
                let message = (error as? LLMError)?.errorDescription ?? error.localizedDescription
                self.errorMessage = message
                // 已经收到的部分内容不丢。
                if !accumulated.isEmpty {
                    self.commitAssistantMessage(accumulated, reasoning: reasoning.isEmpty ? nil : reasoning)
                }
            }

            self.streamingText = ""
            self.streamingReasoning = ""
            self.throttledText = ""
            self.throttledReasoning = ""
            self.isGenerating = false
        }
    }

    // MARK: - 落盘

    private func commitAssistantMessage(
        _ text: String,
        reasoning: String?,
        startedAt: String? = nil,
        model: String? = nil,
        api: String? = nil
    ) {
        var extra = MessageExtra()
        extra.model = model ?? store.settings.activeModel
        extra.api = api
        extra.reasoning = reasoning

        var message = ChatMessage(
            name: store.character(for: session.characterId)?.name ?? session.metadata.characterName,
            mes: text,
            isUser: false,
            extra: extra
        )
        message.swipes = [text]
        message.swipeId = 0
        message.genStarted = startedAt
        message.genFinished = ChatMessage.timestamp()

        messages.append(message)
        persist()
    }

    private func persist() {
        session.messages = messages
        session.updatedAt = Date()
        store.save(session: session)
    }
}
