import Foundation

/// 支持的 LLM 供应商协议类型。
///
/// 绝大多数服务商都兼容 OpenAI 的 `/v1/chat/completions`，
/// 因此单独实现三种协议即可覆盖大部分场景。
enum ProviderProtocol: String, Codable, CaseIterable {
    /// OpenAI 及其兼容服务（DeepSeek、Groq、OpenRouter、Ollama、LM Studio 等）。
    case openAICompatible
    /// Anthropic Messages API。
    case anthropic
    /// Google Gemini generateContent API。
    case google

    var displayName: String {
        switch self {
        case .openAICompatible: return "OpenAI 兼容"
        case .anthropic: return "Anthropic"
        case .google: return "Google Gemini"
        }
    }
}

/// 一个供应商端点的配置。
struct ProviderConfig: Identifiable, Codable, Hashable {
    /// 稳定标识，用于在设置里选中。
    var id: String
    /// 界面显示名。
    var name: String
    /// 协议类型，决定请求体与流式解析方式。
    var `protocol`: ProviderProtocol
    /// 接口基地址。
    var baseURL: String
    /// 是否需要 API Key 才能调用（Ollama 等本地服务不需要）。
    var requiresApiKey: Bool
    /// 可选模型的建议列表；允许用户手填其它模型名。
    var suggestedModels: [String]

    init(
        id: String,
        name: String,
        protocol proto: ProviderProtocol,
        baseURL: String,
        requiresApiKey: Bool = true,
        suggestedModels: [String] = []
    ) {
        self.id = id
        self.name = name
        self.protocol = proto
        self.baseURL = baseURL
        self.requiresApiKey = requiresApiKey
        self.suggestedModels = suggestedModels
    }

    /// 内建供应商。API Key 统一存 Keychain，key 为 "provider.<id>"。
    static let openAICompatibleId = "openai"

    static let defaults: [ProviderConfig] = [
        ProviderConfig(
            id: openAICompatibleId,
            name: "OpenAI",
            protocol: .openAICompatible,
            baseURL: "https://api.openai.com/v1",
            suggestedModels: ["gpt-4o", "gpt-4o-mini", "gpt-4.1", "o4-mini"]
        ),
        ProviderConfig(
            id: "deepseek",
            name: "DeepSeek",
            protocol: .openAICompatible,
            baseURL: "https://api.deepseek.com/v1",
            suggestedModels: ["deepseek-chat", "deepseek-reasoner"]
        ),
        ProviderConfig(
            id: "openrouter",
            name: "OpenRouter",
            protocol: .openAICompatible,
            baseURL: "https://openrouter.ai/api/v1",
            suggestedModels: []
        ),
        ProviderConfig(
            id: "groq",
            name: "Groq",
            protocol: .openAICompatible,
            baseURL: "https://api.groq.com/openai/v1",
            suggestedModels: []
        ),
        ProviderConfig(
            id: "anthropic",
            name: "Anthropic",
            protocol: .anthropic,
            baseURL: "https://api.anthropic.com",
            suggestedModels: ["claude-sonnet-4-5", "claude-opus-4-1", "claude-haiku-4-5"]
        ),
        ProviderConfig(
            id: "google",
            name: "Google AI Studio",
            protocol: .google,
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            suggestedModels: ["gemini-2.5-pro", "gemini-2.5-flash"]
        ),
        ProviderConfig(
            id: "ollama",
            name: "Ollama（本地）",
            protocol: .openAICompatible,
            baseURL: "http://localhost:11434/v1",
            requiresApiKey: false,
            suggestedModels: []
        ),
        ProviderConfig(
            id: "custom",
            name: "自定义端点",
            protocol: .openAICompatible,
            baseURL: "",
            requiresApiKey: false,
            suggestedModels: []
        ),
    ]
}
