import Foundation

/// 应用设置。持久化为 Documents/settings.json。
struct AppSettings: Codable, Hashable {
    // MARK: - 用户身份

    /// 当前用户 persona 名，对应 ST 的 `{{user}}`。
    var userName: String = "User"

    /// 用户 persona 描述，注入 Prompt 时对应 `{{persona}}`。
    var userPersona: String = ""

    // MARK: - 供应商

    /// 所有供应商配置。API Key 不存这里，存 Keychain。
    var providers: [ProviderConfig] = ProviderConfig.defaults

    /// 当前选中的供应商 id。
    var activeProviderId: String = ProviderConfig.openAICompatibleId

    /// 当前选中的模型名。
    var activeModel: String = "gpt-4o-mini"

    // MARK: - 采样参数

    var temperature: Double = 1.0
    var topP: Double = 1.0
    var frequencyPenalty: Double = 0.0
    var presencePenalty: Double = 0.0
    /// 最大回复 token 数。
    var maxTokens: Int = 512
    /// 上下文总长度（token），超出后从最旧消息开始丢弃。
    var contextSize: Int = 8192
    var streamingEnabled: Bool = true
    /// 停止序列。
    var stopSequences: [String] = []

    // MARK: - 生成行为

    /// 是否自动加载该角色最近一次会话。
    var autoLoadLastChat: Bool = true
    /// 消息中是否显示发送时间。
    var showTimestamps: Bool = false
    /// 是否让模型在回复前输出思维链（仅部分供应商支持）。
    var requestReasoning: Bool = false
}
