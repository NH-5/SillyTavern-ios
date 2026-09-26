import Foundation

/// 一次生成请求的参数。
struct GenerationRequest {
    var model: String
    var messages: [ChatCompletionMessage]
    var temperature: Double = 1.0
    var topP: Double = 1.0
    var frequencyPenalty: Double = 0.0
    var presencePenalty: Double = 0.0
    var maxTokens: Int = 512
    var stream: Bool = true
    /// 停止序列。为空时不发送该字段。
    var stop: [String] = []
    /// 传给供应商的自定义附加请求体字段（原样合并）。
    var extraBody: [String: JSONValue] = [:]
}

/// 生成过程中的增量事件。
enum GenerationEvent {
    /// 正文增量。
    case text(String)
    /// 思维链增量（部分推理模型返回）。
    case reasoning(String)
    /// 正常结束。
    case finished(reason: String?)
}

/// 统一的 LLM 调用错误。
enum LLMError: LocalizedError {
    case missingAPIKey(provider: String)
    case invalidURL(String)
    case httpStatus(code: Int, message: String, body: String)
    case emptyResponse
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "还没有为「\(provider)」配置 API Key，请到设置里填写。"
        case .invalidURL(let value):
            return "接口地址无效：\(value)"
        case .httpStatus(let code, let message, _):
            return "请求失败（HTTP \(code)）：\(message)"
        case .emptyResponse:
            return "服务端返回了空响应。"
        case .decodingFailed(let detail):
            return "无法解析服务端响应：\(detail)"
        }
    }

    /// 供 UI 展示的详细正文（出错时把上游返回体贴出来，便于排查）。
    var detail: String? {
        if case .httpStatus(_, _, let body) = self, !body.isEmpty {
            return body
        }
        return nil
    }
}

/// LLM 客户端：把统一请求翻译成各供应商协议，并把响应流解析成增量事件。
///
/// SillyTavern 把这个过程拆在 Node 服务端（翻译请求）与浏览器端（解析 SSE）两层，
/// 在 iOS 上必须合并成一层，因此这里同时负责 URL 拼接、请求体构造与流式解析。
struct LLMClient {
    /// 会话配置：放宽超时，避免长回复被中途掐断。
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 1800
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    // MARK: - 请求构造

    /// 按供应商协议构造 URLRequest。
    ///
    /// URL 规则与 ST 一致：不自动补 `/v1`，只在基地址后拼路径；
    /// 但会去掉基地址结尾多余的斜杠，避免出现 `//chat/completions`。
    func makeRequest(
        provider: ProviderConfig,
        apiKey: String,
        request: GenerationRequest
    ) throws -> URLRequest {
        let url = try buildURL(provider: provider, model: request.model, stream: request.stream)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        let body: [String: JSONValue]

        switch provider.protocol {
        case .openAICompatible:
            if provider.requiresApiKey {
                guard !apiKey.isEmpty else { throw LLMError.missingAPIKey(provider: provider.name) }
                urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            body = openAIBody(request: request)

        case .anthropic:
            guard !apiKey.isEmpty else { throw LLMError.missingAPIKey(provider: provider.name) }
            urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = anthropicBody(request: request)

        case .google:
            guard !apiKey.isEmpty else { throw LLMError.missingAPIKey(provider: provider.name) }
            urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            body = googleBody(request: request)
        }

        urlRequest.httpBody = try JSONValue.object(body).encoded()
        return urlRequest
    }

    /// 拼接请求 URL。
    private func buildURL(provider: ProviderConfig, model: String, stream: Bool) throws -> URL {
        var base = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw LLMError.invalidURL(provider.baseURL) }
        while base.hasSuffix("/") { base.removeLast() }

        let path: String
        switch provider.protocol {
        case .openAICompatible:
            path = "/chat/completions"
        case .anthropic:
            path = "/v1/messages"
        case .google:
            // Gemini 的流式接口是 SSE 形式，必须带 alt=sse。
            path = "/models/\(model):\(stream ? "streamGenerateContent?alt=sse" : "generateContent")"
        }

        guard let url = URL(string: base + path) else {
            throw LLMError.invalidURL(base + path)
        }
        return url
    }

    // MARK: - 请求体

    private func openAIBody(request: GenerationRequest) -> [String: JSONValue] {
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "messages": .array(request.messages.map(Self.encodeMessage)),
            "temperature": .number(request.temperature),
            "top_p": .number(request.topP),
            "frequency_penalty": .number(request.frequencyPenalty),
            "presence_penalty": .number(request.presencePenalty),
            "max_tokens": .integer(request.maxTokens),
            "stream": .bool(request.stream),
        ]
        if !request.stop.isEmpty {
            body["stop"] = .array(request.stop.map { .string($0) })
        }
        for (key, value) in request.extraBody {
            body[key] = value
        }
        return body
    }

    private func anthropicBody(request: GenerationRequest) -> [String: JSONValue] {
        // Anthropic 的 system 是独立字段，messages 里不能出现 system 角色。
        let systemText = request.messages
            .filter { $0.role == "system" }
            .map(\.flatContent)
            .joined(separator: "\n\n")

        let conversation = request.messages
            .filter { $0.role != "system" }
            .map { message -> [String: JSONValue] in
                [
                    "role": .string(message.role == "assistant" ? "assistant" : "user"),
                    "content": .string(message.flatContent),
                ]
            }

        var body: [String: JSONValue] = [
            "model": .string(request.model),
            // max_tokens 在 Anthropic 是必填项。
            "max_tokens": .integer(request.maxTokens),
            "messages": .array(conversation.map { JSONValue.object($0) }),
            "temperature": .number(request.temperature),
            "top_p": .number(request.topP),
            "stream": .bool(request.stream),
        ]
        if !systemText.isEmpty {
            body["system"] = .string(systemText)
        }
        if !request.stop.isEmpty {
            body["stop_sequences"] = .array(request.stop.map { .string($0) })
        }
        for (key, value) in request.extraBody {
            body[key] = value
        }
        return body
    }

    private func googleBody(request: GenerationRequest) -> [String: JSONValue] {
        // 角色名映射：assistant → model，其余 → user；system 走 systemInstruction。
        let systemText = request.messages
            .filter { $0.role == "system" }
            .map(\.flatContent)
            .joined(separator: "\n\n")

        let contents = request.messages
            .filter { $0.role != "system" }
            .map { message -> JSONValue in
                .object([
                    "role": .string(message.role == "assistant" ? "model" : "user"),
                    "parts": .array([.object(["text": .string(message.flatContent)])]),
                ])
            }

        var generationConfig: [String: JSONValue] = [
            "temperature": .number(request.temperature),
            "topP": .number(request.topP),
            "maxOutputTokens": .integer(request.maxTokens),
        ]
        if !request.stop.isEmpty {
            generationConfig["stopSequences"] = .array(request.stop.map { .string($0) })
        }

        var body: [String: JSONValue] = [
            "contents": .array(contents),
            "generationConfig": .object(generationConfig),
        ]
        if !systemText.isEmpty {
            body["systemInstruction"] = .object([
                "parts": .array([.object(["text": .string(systemText)])]),
            ])
        }
        for (key, value) in request.extraBody {
            body[key] = value
        }
        return body
    }

    private static func encodeMessage(_ message: ChatCompletionMessage) -> JSONValue {
        var object: [String: JSONValue] = [
            "role": .string(message.role),
        ]
        switch message.content {
        case .text(let value):
            object["content"] = .string(value)
        case .parts(let parts):
            object["content"] = .array(parts.map { part in
                switch part {
                case .text(let value):
                    return .object(["type": .string("text"), "text": .string(value)])
                case .imageURL(let url, let detail):
                    var payload: [String: JSONValue] = ["url": .string(url)]
                    if let detail { payload["detail"] = .string(detail) }
                    return .object([
                        "type": .string("image_url"),
                        "image_url": .object(payload),
                    ])
                }
            })
        }
        if let name = message.name, !name.isEmpty {
            object["name"] = .string(name)
        }
        return .object(object)
    }

    // MARK: - 调用

    /// 发起生成请求，流式返回增量事件。
    ///
    /// 之所以返回 `AsyncThrowingStream`：UI 层可以边收边渲染，
    /// 不需要等整段回复结束。
    func stream(
        provider: ProviderConfig,
        apiKey: String,
        request: GenerationRequest
    ) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try makeRequest(provider: provider, apiKey: apiKey, request: request)
                    if request.stream {
                        try await runStreaming(
                            urlRequest: urlRequest,
                            provider: provider,
                            continuation: continuation
                        )
                    } else {
                        try await runNonStreaming(
                            urlRequest: urlRequest,
                            provider: provider,
                            continuation: continuation
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 流式路径：逐字节读取并解析 SSE。
    private func runStreaming(
        urlRequest: URLRequest,
        provider: ProviderConfig,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        let (bytes, response) = try await session.bytes(for: urlRequest)
        try await validate(response: response, bytes: bytes)

        var parser = SSEParser()
        for try await byte in bytes {
            try Task.checkCancellation()
            var events = parser.feed(Data([byte]))
            if events.isEmpty { continue }

            for event in events {
                if event.isDone {
                    continuation.yield(.finished(reason: nil))
                    return
                }
                for extracted in Self.extract(from: event, provider: provider) {
                    continuation.yield(extracted)
                }
            }
            events.removeAll()
        }

        // 收尾：处理没有以空行结束的最后一帧。
        for event in parser.finish() {
            if event.isDone { continue }
            for extracted in Self.extract(from: event, provider: provider) {
                continuation.yield(extracted)
            }
        }
        continuation.yield(.finished(reason: nil))
    }

    /// 非流式路径：一次性拿完整响应再提取文本。
    private func runNonStreaming(
        urlRequest: URLRequest,
        provider: ProviderConfig,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.emptyResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.httpStatus(
                code: http.statusCode,
                message: Self.errorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = Self.nonStreamingText(from: root, provider: provider)
        else {
            throw LLMError.decodingFailed(String(data: data, encoding: .utf8) ?? "")
        }

        continuation.yield(.text(text))
        continuation.yield(.finished(reason: nil))
    }

    /// 检查 HTTP 状态；出错时把响应体读出来用于报错。
    private func validate(
        response: URLResponse,
        bytes: URLSession.AsyncBytes
    ) async throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }

        var body = Data()
        for try await byte in bytes {
            body.append(byte)
            if body.count > 8192 { break }
        }
        throw LLMError.httpStatus(
            code: http.statusCode,
            message: Self.errorMessage(from: body) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
            body: String(data: body, encoding: .utf8) ?? ""
        )
    }

    // MARK: - 响应解析

    /// 从一条 SSE 事件里提取增量。
    ///
    /// 三条路径的结构差异较大，分别处理：
    /// - OpenAI 兼容：`choices[0].delta.content`，思维链在 `delta.reasoning_content` / `delta.reasoning`；
    /// - Anthropic：事件名决定类型，正文在 `delta.text`，思维链在 `delta.thinking`；
    /// - Gemini：正文在 `candidates[0].content.parts[0].text`，思维链分片的 `thought == true`。
    static func extract(from event: SSEEvent, provider: ProviderConfig) -> [GenerationEvent] {
        guard let data = event.data.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        var results: [GenerationEvent] = []

        switch provider.protocol {
        case .openAICompatible:
            if let choices = root["choices"] as? [[String: Any]],
               let first = choices.first {
                if let delta = first["delta"] as? [String: Any] {
                    if let text = delta["content"] as? String, !text.isEmpty {
                        results.append(.text(text))
                    }
                    // 思维链字段在不同供应商里叫法不同。
                    if let reasoning = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String),
                       !reasoning.isEmpty {
                        results.append(.reasoning(reasoning))
                    }
                }
                if let finish = first["finish_reason"] as? String {
                    results.append(.finished(reason: finish))
                }
            }

        case .anthropic:
            switch event.name {
            case "content_block_delta":
                if let delta = root["delta"] as? [String: Any] {
                    if let text = delta["text"] as? String, !text.isEmpty {
                        results.append(.text(text))
                    }
                    if let thinking = delta["thinking"] as? String, !thinking.isEmpty {
                        results.append(.reasoning(thinking))
                    }
                }
            case "message_stop":
                results.append(.finished(reason: nil))
            case "error":
                break
            default:
                break
            }

        case .google:
            if let candidates = root["candidates"] as? [[String: Any]],
               let first = candidates.first,
               let content = first["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]] {
                for part in parts {
                    guard let text = part["text"] as? String, !text.isEmpty else { continue }
                    if (part["thought"] as? Bool) == true {
                        results.append(.reasoning(text))
                    } else {
                        results.append(.text(text))
                    }
                }
            }
            if let finish = (root["candidates"] as? [[String: Any]])?.first?["finishReason"] as? String {
                results.append(.finished(reason: finish))
            }
        }

        return results
    }

    /// 非流式响应里的正文。
    static func nonStreamingText(from root: [String: Any], provider: ProviderConfig) -> String? {
        switch provider.protocol {
        case .openAICompatible:
            guard
                let choices = root["choices"] as? [[String: Any]],
                let message = choices.first?["message"] as? [String: Any],
                let content = message["content"] as? String
            else { return nil }
            return content
        case .anthropic:
            guard let blocks = root["content"] as? [[String: Any]] else { return nil }
            let text = blocks.compactMap { $0["text"] as? String }.joined()
            return text.isEmpty ? nil : text
        case .google:
            guard
                let candidates = root["candidates"] as? [[String: Any]],
                let parts = candidates.first?["content"] as? [String: Any],
                let blocks = parts["parts"] as? [[String: Any]]
            else { return nil }
            let text = blocks.compactMap { $0["text"] as? String }.joined()
            return text.isEmpty ? nil : text
        }
    }

    /// 按 ST 的优先级从错误响应里取可读消息：
    /// `error.message` → `error.code` → `error.type` → `detail.error` → `message`。
    static func errorMessage(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = root["error"] as? [String: Any] {
            if let message = error["message"] as? String, !message.isEmpty { return message }
            if let code = error["code"] as? String, !code.isEmpty { return code }
            if let type = error["type"] as? String, !type.isEmpty { return type }
        }
        if let detail = root["detail"] as? [String: Any],
           let message = detail["error"] as? String, !message.isEmpty {
            return message
        }
        if let message = root["message"] as? String, !message.isEmpty { return message }
        return nil
    }
}

/// 访问设置里的 API Key（存 Keychain，不落盘到 JSON）。
enum APIKeyStore {
    private static let service = "app.sillytavern.ios.apikeys"

    static func key(for providerId: String) -> String {
        Keychain.read(service: service, account: providerId) ?? ""
    }

    static func setKey(_ value: String, for providerId: String) {
        if value.isEmpty {
            _ = Keychain.delete(service: service, account: providerId)
        } else {
            _ = Keychain.write(service: service, account: providerId, value: value)
        }
    }
}
