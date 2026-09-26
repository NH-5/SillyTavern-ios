import Foundation

/// 一条发给 Chat Completion 接口的消息。
///
/// 对应 OpenAI 的 `{role, content, name?}`。`name` 在 SillyTavern 里用于
/// 标记示例对话（`example_user` / `example_assistant`），部分供应商会忽略它。
struct ChatCompletionMessage: Codable, Hashable {
    var role: String
    var content: MessageContent
    var name: String?

    init(role: String, content: String, name: String? = nil) {
        self.role = role
        self.content = .text(content)
        self.name = name
    }

    init(role: String, content: MessageContent, name: String? = nil) {
        self.role = role
        self.content = content
        self.name = name
    }

    /// 纯文本内容；多模态时为空串。
    var flatContent: String {
        switch content {
        case .text(let value):
            return value
        case .parts(let parts):
            return parts.compactMap { part in
                if case .text(let value) = part { return value }
                return nil
            }.joined(separator: "\n")
        }
    }

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case name
    }
}

/// 消息内容：纯文本，或多模态分片数组。
enum MessageContent: Codable, Hashable {
    case text(String)
    case parts([ContentPart])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .text(value)
            return
        }
        self = .parts(try container.decode([ContentPart].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value):
            try container.encode(value)
        case .parts(let parts):
            try container.encode(parts)
        }
    }
}

/// 多模态分片。
enum ContentPart: Codable, Hashable {
    case text(String)
    case imageURL(url: String, detail: String?)

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }

    private struct ImageURLPayload: Codable, Hashable {
        var url: String
        var detail: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "image_url":
            let payload = try container.decode(ImageURLPayload.self, forKey: .imageURL)
            self = .imageURL(url: payload.url, detail: payload.detail)
        default:
            self = .text("")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode("text", forKey: .type)
            try container.encode(value, forKey: .text)
        case .imageURL(let url, let detail):
            try container.encode("image_url", forKey: .type)
            try container.encode(ImageURLPayload(url: url, detail: detail), forKey: .imageURL)
        }
    }
}
