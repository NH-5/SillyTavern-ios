import Foundation

/// 一个会话（对应 ST 里某个角色下的一份聊天记录）。
struct ChatSession: Identifiable, Codable, Hashable {
    var id: UUID = UUID()

    /// 归属角色的本地 id。
    var characterId: UUID

    /// 会话文件名（不含扩展名）。ST 用 "角色名 - 日期 时间" 这类格式。
    var name: String

    var messages: [ChatMessage] = []

    /// 会话级元数据，对应 ST JSONL 的首行 chat_metadata。
    var metadata: ChatMetadata = ChatMetadata()

    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// 显式声明：提供了自定义 `init(from:)` 后 Swift 不再合成成员初始化器，
    /// 而调用方需要 `ChatSession(characterId:name:)` 这种写法。
    init(
        id: UUID = UUID(),
        characterId: UUID,
        name: String,
        messages: [ChatMessage] = [],
        metadata: ChatMetadata = ChatMetadata(),
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.characterId = characterId
        self.name = name
        self.messages = messages
        self.metadata = metadata
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 最后一条可见消息的预览文本。
    var preview: String {
        messages.last(where: { !$0.isSystem && !$0.isHidden })?.mes
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
    }

    // MARK: - Codable（本地索引格式）

    /// 消息在本地索引里的键名：驼峰风格，与 ST 的 JSONL 键名区分开。
    ///
    /// 之所以要分开：`ChatMessage` 的 `CodingKeys` 用的是 ST 的
    /// `is_user` / `send_date`（为了 JSONL 互通），如果本地索引直接复用它，
    /// 两条路径的键名就会混在一起；一旦外部写入或手工构造的索引用了驼峰，
    /// 解码就会整体失败，表现成「保存过的会话重启后全部消失」且没有任何提示。
    /// 这里显式转换，让索引文件与 JSONL 各用各的格式。
    private enum IndexKeys: String, CodingKey {
        case id, characterId, name, metadata, createdAt, updatedAt, messages
    }

    /// 消息在索引里的键名（驼峰）。
    private enum MessageIndexKeys: String, CodingKey {
        case name, mes, isUser, isSystem, sendDate, isHidden
        case extra, swipes, swipeId, genStarted, genFinished
        /// 消息级元数据在索引里的键名。
        case extraModel, extraApi, extraReasoning, extraTokenCount
    }

    /// 会话元数据在索引里的键名（驼峰）。
    ///
    /// `ChatMetadata` 自身的 `CodingKeys` 用的是 ST 的 `user_name` / `create_date`
    /// （为了 JSONL 互通），本地索引必须换成驼峰，否则写出去与读回来用的键不一致。
    private enum MetadataIndexKeys: String, CodingKey {
        case userName, characterName, createDate, worldInfo, scenario
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: IndexKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        characterId = try container.decode(UUID.self, forKey: .characterId)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "会话"

        if let metaContainer = try? container.nestedContainer(keyedBy: MetadataIndexKeys.self, forKey: .metadata) {
            var meta = ChatMetadata()
            meta.userName = (try? metaContainer.decode(String.self, forKey: .userName)) ?? ""
            meta.characterName = (try? metaContainer.decode(String.self, forKey: .characterName)) ?? ""
            if let createDate = try? metaContainer.decode(String.self, forKey: .createDate) {
                meta.createDate = createDate
            }
            meta.worldInfo = try? metaContainer.decodeIfPresent(String.self, forKey: .worldInfo)
            meta.scenario = try? metaContainer.decodeIfPresent(String.self, forKey: .scenario)
            metadata = meta
        } else {
            metadata = ChatMetadata()
        }

        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()

        // 逐条解析：单条数据异常时跳过它，而不是让整个会话丢失。
        messages = []
        if var list = try? container.nestedUnkeyedContainer(forKey: .messages) {
            var parsed: [ChatMessage] = []
            while !list.isAtEnd {
                guard let item = try? list.nestedContainer(keyedBy: MessageIndexKeys.self) else {
                    _ = try? list.decode(AnyDecodableSkip.self)
                    continue
                }
                var message = ChatMessage(
                    name: (try? item.decode(String.self, forKey: .name)) ?? "",
                    mes: (try? item.decode(String.self, forKey: .mes)) ?? "",
                    isUser: (try? item.decode(Bool.self, forKey: .isUser)) ?? false
                )
                message.isSystem = (try? item.decode(Bool.self, forKey: .isSystem)) ?? false
                message.isHidden = (try? item.decode(Bool.self, forKey: .isHidden)) ?? false
                if let sendDate = try? item.decode(String.self, forKey: .sendDate) {
                    message.sendDate = sendDate
                }
                message.genStarted = try? item.decodeIfPresent(String.self, forKey: .genStarted)
                message.genFinished = try? item.decodeIfPresent(String.self, forKey: .genFinished)
                message.swipes = (try? item.decode([String].self, forKey: .swipes)) ?? []
                message.swipeId = (try? item.decode(Int.self, forKey: .swipeId)) ?? 0

                var extra = MessageExtra()
                extra.model = try? item.decodeIfPresent(String.self, forKey: .extraModel)
                extra.api = try? item.decodeIfPresent(String.self, forKey: .extraApi)
                extra.reasoning = try? item.decodeIfPresent(String.self, forKey: .extraReasoning)
                extra.tokenCount = try? item.decodeIfPresent(Int.self, forKey: .extraTokenCount)
                message.extra = extra
                parsed.append(message)
            }
            messages = parsed
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: IndexKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(characterId, forKey: .characterId)
        try container.encode(name, forKey: .name)

        var metaContainer = container.nestedContainer(keyedBy: MetadataIndexKeys.self, forKey: .metadata)
        try metaContainer.encode(metadata.userName, forKey: .userName)
        try metaContainer.encode(metadata.characterName, forKey: .characterName)
        try metaContainer.encode(metadata.createDate, forKey: .createDate)
        try metaContainer.encodeIfPresent(metadata.worldInfo, forKey: .worldInfo)
        try metaContainer.encodeIfPresent(metadata.scenario, forKey: .scenario)

        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)

        var list = container.nestedUnkeyedContainer(forKey: .messages)
        for message in messages {
            var item = list.nestedContainer(keyedBy: MessageIndexKeys.self)
            try item.encode(message.name, forKey: .name)
            try item.encode(message.mes, forKey: .mes)
            try item.encode(message.isUser, forKey: .isUser)
            try item.encode(message.isSystem, forKey: .isSystem)
            try item.encode(message.sendDate, forKey: .sendDate)
            try item.encode(message.isHidden, forKey: .isHidden)
            try item.encode(message.swipes, forKey: .swipes)
            try item.encode(message.swipeId, forKey: .swipeId)
            try item.encodeIfPresent(message.genStarted, forKey: .genStarted)
            try item.encodeIfPresent(message.genFinished, forKey: .genFinished)
            // 元数据平铺在消息里，避免再套一层结构导致键名规则分散。
            try item.encodeIfPresent(message.extra.model, forKey: .extraModel)
            try item.encodeIfPresent(message.extra.api, forKey: .extraApi)
            try item.encodeIfPresent(message.extra.reasoning, forKey: .extraReasoning)
            try item.encodeIfPresent(message.extra.tokenCount, forKey: .extraTokenCount)
        }
    }
}

/// 用于跳过无法识别的数组元素，保证单条坏数据不会毁掉整个文件。
private struct AnyDecodableSkip: Decodable {}

/// 会话元数据，字段对齐 ST 的 chat_metadata。
struct ChatMetadata: Codable, Hashable {
    var userName: String = ""
    var characterName: String = ""
    /// 会话创建时间戳（字符串形式，与 ST 一致）。
    var createDate: String = ChatMessage.timestamp()
    /// 该会话绑定的世界书名（覆盖角色内嵌世界书）。
    var worldInfo: String?
    /// 会话级场景覆盖。
    var scenario: String?

    enum CodingKeys: String, CodingKey {
        case userName = "user_name"
        case characterName = "character_name"
        case createDate = "create_date"
        case worldInfo = "world_info"
        case scenario
    }
}
