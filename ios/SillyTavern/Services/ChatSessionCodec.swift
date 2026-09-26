import Foundation

/// 聊天记录编解码：与 SillyTavern 的 JSONL 格式互通。
///
/// 格式约束（`docs/ios-research/04-local-data-and-settings.md` §2）：
/// - 第 1 行是会话头：`{chat_metadata:{...}, user_name:"unused", character_name:"unused"}`；
///   其中 `user_name` / `character_name` 已废弃，但**必须写**，否则旧版本 ST 会报错；
/// - 之后每行一条消息；
/// - **紧凑 JSON，无尾随换行**。
enum ChatSessionCodec {
    enum Error: LocalizedError {
        case emptyFile
        case malformedHeader

        var errorDescription: String? {
            switch self {
            case .emptyFile: return "聊天记录文件是空的。"
            case .malformedHeader: return "聊天记录的文件头无法解析。"
            }
        }
    }

    /// 编码成 JSONL。
    static func encodeJSONL(_ session: ChatSession) throws -> Data {
        var lines: [String] = []

        // 第一行：会话头。
        let header: [String: Any] = [
            "chat_metadata": metadataObject(session.metadata),
            // 这两个字段是历史遗留，ST 仍会写入，保持一致。
            "user_name": "unused",
            "character_name": "unused",
        ]
        lines.append(try compactJSON(header))

        for message in session.messages {
            lines.append(try compactJSON(messageObject(message)))
        }

        // 无尾随换行，与 ST 的 `chat.map(JSON.stringify).join('\n')` 一致。
        let text = lines.joined(separator: "\n")
        return Data(text.utf8)
    }

    /// 解析 JSONL。
    ///
    /// 容错策略：头部解析失败时退化为「全部当消息」，消息行解析失败则跳过该行——
    /// 导入别人的聊天记录时，宁可少几条也不要整份失败。
    static func decodeJSONL(_ data: Data, characterId: UUID, fallbackName: String) throws -> ChatSession {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw Error.emptyFile
        }

        var lines = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { throw Error.emptyFile }

        var metadata = ChatMetadata()
        var messages: [ChatMessage] = []

        // 判定首行是否为会话头：含 chat_metadata 或那两个废弃字段。
        if let first = lines.first,
           let object = try? JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any],
           object["chat_metadata"] != nil || object["user_name"] != nil {
            if let metaObject = object["chat_metadata"] as? [String: Any] {
                metadata = metadataFrom(metaObject)
            }
            lines.removeFirst()
        }

        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                continue
            }
            if let message = messageFrom(object) {
                messages.append(message)
            }
        }

        var session = ChatSession(characterId: characterId, name: fallbackName)
        session.metadata = metadata
        session.messages = messages
        return session
    }

    // MARK: - 消息 ↔ 字典

    private static func messageObject(_ message: ChatMessage) -> [String: Any] {
        var object: [String: Any] = [
            "name": message.name,
            "is_user": message.isUser,
            "is_system": message.isSystem,
            "send_date": message.sendDate,
            "mes": message.mes,
        ]
        if message.isHidden { object["is_hidden"] = true }

        var extra: [String: Any] = [:]
        if let model = message.extra.model { extra["model"] = model }
        if let api = message.extra.api { extra["api"] = api }
        if let reasoning = message.extra.reasoning { extra["reasoning"] = reasoning }
        if let tokenCount = message.extra.tokenCount { extra["token_count"] = tokenCount }
        if !extra.isEmpty { object["extra"] = extra }

        if !message.swipes.isEmpty {
            object["swipes"] = message.swipes
            object["swipe_id"] = message.swipeId
            // swipe_info 与 swipes 必须等长，否则 ST 读取时会错位。
            object["swipe_info"] = message.swipes.enumerated().map { index, _ -> [String: Any] in
                [
                    "send_date": message.sendDate,
                    "gen_started": message.genStarted ?? NSNull(),
                    "gen_finished": message.genFinished ?? NSNull(),
                    "extra": index == message.swipeId ? extra : [String: Any](),
                ]
            }
        }

        if let started = message.genStarted { object["gen_started"] = started }
        if let finished = message.genFinished { object["gen_finished"] = finished }

        return object
    }

    private static func messageFrom(_ object: [String: Any]) -> ChatMessage? {
        guard let mes = object["mes"] as? String else { return nil }

        var message = ChatMessage(
            name: object["name"] as? String ?? "",
            mes: mes,
            isUser: object["is_user"] as? Bool ?? false
        )
        message.isSystem = object["is_system"] as? Bool ?? false
        message.isHidden = object["is_hidden"] as? Bool ?? false
        if let sendDate = object["send_date"] as? String {
            message.sendDate = sendDate
        }
        message.genStarted = object["gen_started"] as? String
        message.genFinished = object["gen_finished"] as? String
        message.swipes = object["swipes"] as? [String] ?? []
        message.swipeId = object["swipe_id"] as? Int ?? 0

        if let extra = object["extra"] as? [String: Any] {
            var messageExtra = MessageExtra()
            messageExtra.model = extra["model"] as? String
            messageExtra.api = extra["api"] as? String
            messageExtra.reasoning = extra["reasoning"] as? String
            messageExtra.tokenCount = extra["token_count"] as? Int
            message.extra = messageExtra
        }

        // 不变式：swipes[swipe_id] 应当等于 mes；不一致时以 mes 为准修正。
        if !message.swipes.isEmpty {
            if message.swipeId < 0 || message.swipeId >= message.swipes.count {
                message.swipeId = 0
            }
            if message.swipes[message.swipeId] != message.mes {
                message.swipes[message.swipeId] = message.mes
            }
        }

        return message
    }

    private static func metadataObject(_ metadata: ChatMetadata) -> [String: Any] {
        var object: [String: Any] = [
            "user_name": metadata.userName,
            "character_name": metadata.characterName,
            "create_date": metadata.createDate,
        ]
        if let worldInfo = metadata.worldInfo { object["world_info"] = worldInfo }
        if let scenario = metadata.scenario { object["scenario"] = scenario }
        return object
    }

    private static func metadataFrom(_ object: [String: Any]) -> ChatMetadata {
        var metadata = ChatMetadata()
        metadata.userName = object["user_name"] as? String ?? ""
        metadata.characterName = object["character_name"] as? String ?? ""
        if let createDate = object["create_date"] as? String {
            metadata.createDate = createDate
        }
        metadata.worldInfo = object["world_info"] as? String
        metadata.scenario = object["scenario"] as? String
        return metadata
    }

    /// 紧凑 JSON（无空格、无换行）。
    ///
    /// 用自写渲染器而不是 `JSONSerialization`：后者会把 `/` 转义成 `\/`，
    /// 而 ST（JavaScript）不转义，输出应当逐字一致。
    private static func compactJSON(_ object: [String: Any]) throws -> String {
        JSONRenderer.compact(object)
    }
}
