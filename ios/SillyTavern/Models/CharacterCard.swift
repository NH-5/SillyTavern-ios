import Foundation

/// 角色卡。
///
/// 内部结构采用 SillyTavern 的扁平形式（即 v1 布局），
/// 因为 ST 本身在解析 v2/v3 卡后也是归一化到这套字段上的；
/// 这样在导入导出时只需处理一层映射。
///
/// 字段语义与解析规则详见 docs/ios-research/01-character-card-spec.md。
struct CharacterCard: Identifiable, Codable, Hashable {
    /// 本地标识（不写入导出文件）。
    var id: UUID = UUID()

    // MARK: - 核心字段

    var name: String = ""
    /// 角色描述，对应 `{{description}}`。
    var description: String = ""
    /// 性格摘要，对应 `{{personality}}`。
    var personality: String = ""
    /// 场景设定，对应 `{{scenario}}`。
    var scenario: String = ""
    /// 开场白。
    var firstMes: String = ""
    /// 示例对话，内部用 `<START>` 分隔多组。
    var mesExample: String = ""
    /// 作者备注（不进入 Prompt，仅展示）。
    var creatorNotes: String = ""

    /// 覆盖主 Prompt 的角色专属系统提示。
    var systemPrompt: String = ""
    /// 插入到聊天记录之后、生成之前的指令。
    var postHistoryInstructions: String = ""

    /// 备选开场白。
    var alternateGreetings: [String] = []

    // MARK: - 元数据

    var creator: String = ""
    var characterVersion: String = ""
    var tags: [String] = []
    /// 角色卡规范版本："1" / "2" / "3"。
    var specVersion: String = "2"
    /// 创建时间字符串（ISO8601）。
    var createDate: String = ChatMessage.timestamp()

    // MARK: - ST 扩展字段

    /// 角色在群聊中的活跃度（ST 扩展，默认 0.5）。
    var talkativeness: Double = 0.5
    /// 是否收藏（ST 扩展）。
    var isFavorite: Bool = false
    /// 默认会话名。ST 用 "角色名 - 时间"；导出时会删除该字段。
    var chatName: String = ""
    /// 卡片内的深度提示（`extensions.depth_prompt`）。
    var depthPrompt: CharacterDepthPrompt?

    // MARK: - 关联数据

    /// 内嵌世界书（character_book）。
    var characterBook: CharacterBook?
    /// 绑定的独立世界书名（对应 ST 的 `world` 字段）。
    var world: String = ""
    /// 头像文件名。为空时使用首字母占位图。
    var avatarFileName: String = ""

    /// `data.extensions` 的原始内容。
    ///
    /// 结构不固定且扩展众多，这里原样保留：导出时先铺开这些键，
    /// 再覆盖本 App 认识的字段，做到「不丢别人的数据」。
    var extensions: [String: JSONValue] = [:]

    /// 整张卡的**原始顶层 JSON**。
    ///
    /// 对应 ST 的 `json_data`：ST 写入时以它为基底再叠加字段，
    /// 这样规范外的陌生键（例如别的生态加的 `nickname`、`assets`）能无损往返。
    var rawRoot: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey {
        // 注意：id 必须参与编解码。
        // 手写 CodingKeys 时漏掉它，Swift 会每次解码都生成新的 UUID，
        // 结果就是重启后会话与角色的关联全部断裂（会话列表变空）。
        case id
        case name
        case description
        case personality
        case scenario
        case firstMes = "first_mes"
        case mesExample = "mes_example"
        case creatorNotes = "creator_notes"
        case systemPrompt = "system_prompt"
        case postHistoryInstructions = "post_history_instructions"
        case alternateGreetings = "alternate_greetings"
        case creator
        case characterVersion = "character_version"
        case tags
        case specVersion = "spec_version"
        case createDate = "create_date"
        case talkativeness
        case isFavorite = "fav"
        case chatName = "chat"
        case depthPrompt = "depth_prompt"
        case characterBook = "character_book"
        case world
        case avatarFileName = "avatar"
        case extensions
        case rawRoot = "json_data"
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名角色" : trimmed
    }

    /// `<START>` 分隔的示例对话组。
    var exampleMessages: [String] {
        mesExample
            .components(separatedBy: "<START>")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// 角色卡里的深度提示（`data.extensions.depth_prompt`）。
///
/// ST 用它把一段提示按深度插进聊天记录，比 system_prompt 更靠近对话末尾。
struct CharacterDepthPrompt: Codable, Hashable {
    var prompt: String = ""
    var depth: Int = 4
    /// 0 = system，1 = user，2 = assistant。
    var role: Int = 0

    var roleName: String {
        switch role {
        case 1: return "user"
        case 2: return "assistant"
        default: return "system"
        }
    }
}
