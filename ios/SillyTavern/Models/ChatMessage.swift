import Foundation

/// 一条聊天消息。
///
/// 字段与 SillyTavern 的 JSONL 聊天记录格式保持兼容，方便后续做导入导出
/// 互通（详见 docs/ios-research/04-local-data-and-settings.md）。
struct ChatMessage: Identifiable, Codable, Hashable {
    /// 本地标识。ST 的 JSONL 里没有 id，因此不参与编解码。
    var id: UUID = UUID()

    /// 发送者显示名。用户消息为当前 persona 名。
    var name: String

    /// 消息正文。
    var mes: String

    /// 是否为用户发送。
    var isUser: Bool

    /// 是否为系统消息（不参与常规对话渲染）。
    var isSystem: Bool = false

    /// 发送时间。ST 存的是 **ISO8601**（形如 `2025-09-26T07:04:33.123Z`），
    /// 不是本地时间字符串——写错会让 ST 的时间解析与排序全部失准。
    var sendDate: String = ChatMessage.timestamp()

    /// 是否被用户隐藏。
    var isHidden: Bool = false

    /// 生成参数与供应商返回的附加信息。
    var extra: MessageExtra = MessageExtra()

    /// 同一轮回复的候选分支。
    var swipes: [String] = []

    /// 当前选中的分支索引。
    var swipeId: Int = 0

    /// 生成开始/结束时间（毫秒级字符串，用于耗时统计）。
    var genStarted: String?
    var genFinished: String?

    /// 键名沿用 ST 的 JSONL 字段（`is_user` / `send_date` / `swipe_id` …）。
    ///
    /// 这样 `ChatSessionCodec` 才能直接复用同一套键写到 ST 兼容的 JSONL 里。
    /// 本地索引文件（sessions.index.json）需要的是另一套驼峰键，
    /// 由 `ChatSession` 自己的 `Codable` 实现负责转换——
    /// 两处混用会出现「保存过的会话重启后全部消失」的问题。
    enum CodingKeys: String, CodingKey {
        case name
        case mes
        case isUser = "is_user"
        case isSystem = "is_system"
        case sendDate = "send_date"
        case isHidden = "is_hidden"
        case extra
        case swipes
        case swipeId = "swipe_id"
        case genStarted = "gen_started"
        case genFinished = "gen_finished"
    }

    /// 生成 ISO8601 时间戳（与 ST 的 `send_date` 格式一致）。
    ///
    /// 带毫秒并固定 UTC，这样跨时区导入导出不会产生漂移。
    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// 解析 ST 写下的时间戳；兼容带与不带毫秒两种写法。
    static func parseTimestamp(_ value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}

/// 消息的额外元数据。字段名沿用 ST，未使用的字段在编解码时忽略。
struct MessageExtra: Codable, Hashable {
    /// 该条消息实际使用的模型名。
    var model: String?
    var api: String?
    /// 思维链内容（部分供应商返回）。
    var reasoning: String?
    /// token 统计。
    var tokenCount: Int?

    /// 显式声明：一旦提供了带参数的自定义 init（下面的索引格式解码），
    /// Swift 就不再自动合成无参初始化器，而业务代码里 `MessageExtra()` 用得很多。
    init() {}

    init(model: String? = nil, api: String? = nil, reasoning: String? = nil, tokenCount: Int? = nil) {
        self.model = model
        self.api = api
        self.reasoning = reasoning
        self.tokenCount = tokenCount
    }

    /// 键名沿用 ST 的字段风格（`token_count`），用于 JSONL 互通。
    enum CodingKeys: String, CodingKey {
        case model
        case api
        case reasoning
        case tokenCount = "token_count"
    }
}
