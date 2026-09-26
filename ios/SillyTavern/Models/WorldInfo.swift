import Foundation

/// 世界书（Lorebook）。
///
/// 对应 ST 的 `worlds/*.json` 与角色卡内嵌的 `character_book`。
/// 两者的条目结构相同，区别只是前者带 name/id 等顶层包装。
struct CharacterBook: Codable, Hashable {
    var name: String = ""
    var description: String = ""
    var scanDepth: Int?
    var tokenBudget: Int?
    var recursiveScanning: Bool?
    var extensions: [String: JSONValue] = [:]
    /// 条目列表。导出时按 ST 规范转成数组或对象（见研究文档）。
    var entries: [WorldInfoEntry] = []

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case scanDepth = "scan_depth"
        case tokenBudget = "token_budget"
        case recursiveScanning = "recursive_scanning"
        case extensions
        case entries
    }
}

/// 世界书条目。
struct WorldInfoEntry: Identifiable, Codable, Hashable {
    var id: UUID = UUID()

    /// 触发关键字。
    var keys: [String] = []
    /// 次级关键字；配合 selective 使用时需同时命中。
    var secondaryKeys: [String] = []
    /// 命中后插入的正文。
    var content: String = ""
    /// 是否启用。
    var enabled: Bool = true
    /// 是否始终激活（ST 里的「蓝灯」/constant）。
    var constant: Bool = false
    /// 是否需要次级关键字同时命中。
    var selective: Bool = false
    /// 大小写敏感匹配。
    var caseSensitive: Bool = false
    /// 整词匹配。
    var matchWholeWords: Bool = false
    /// 是否允许作为递归扫描的来源。
    var excludeRecursion: Bool = false
    /// 是否参与递归扫描。
    var preventRecursion: Bool = false
    /// 插入顺序，数值小者先插入。
    var insertionOrder: Int = 100
    /// 优先级（用于预算裁剪）。
    var priority: Int = 10
    /// 触发概率 0-100。
    var probability: Int = 100
    /// 注释（仅展示）。
    var comment: String = ""
    var name: String = ""

    /// 插入位置与深度。
    var position: WorldInfoPosition = .beforeCharacter
    var depth: Int = 4

    /// 与 ST 的 extensions 互通，保留未知字段。
    var extensions: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey {
        case keys
        case secondaryKeys = "secondary_keys"
        case content
        case enabled
        case constant
        case selective
        case caseSensitive = "case_sensitive"
        case matchWholeWords = "match_whole_words"
        case excludeRecursion = "exclude_recursion"
        case preventRecursion = "prevent_recursion"
        case insertionOrder = "insertion_order"
        case priority
        case probability
        case comment
        case name
        case position
        case depth
        case extensions
    }

    /// 界面显示用标题。
    var displayTitle: String {
        if !comment.isEmpty { return comment }
        if !name.isEmpty { return name }
        if !keys.isEmpty { return keys.joined(separator: ", ") }
        return "未命名条目"
    }
}

/// 世界书条目的插入位置。
///
/// **权威取值是 0-7 的整数**（`public/scripts/world-info.js:855-864`）。
/// 角色卡里的字符串 `position` 只能表达 `before_char` / `after_char` 两档，
/// 更精细的位置必须靠 `extensions.position` 的数字来传递，因此内部一律用数字表达。
enum WorldInfoPosition: Int, Codable, CaseIterable {
    /// 角色定义之前（字符串 `before_char`）。
    case beforeCharacter = 0
    /// 角色定义之后（字符串 `after_char`）。
    case afterCharacter = 1
    /// 作者注释顶部。
    case authorNoteTop = 2
    /// 作者注释底部。
    case authorNoteBottom = 3
    /// 聊天内指定深度，配合 `depth` 与 role 使用。
    case atDepth = 4
    /// 示例消息顶部。
    case exampleTop = 5
    /// 示例消息底部。
    case exampleBottom = 6
    /// Outlet，配合 outletName 使用。
    case outlet = 7

    init(numericValue: Int) {
        self = WorldInfoPosition(rawValue: numericValue) ?? .beforeCharacter
    }

    var numericValue: Int { rawValue }

    /// 角色卡字符串字段能表达的粗略位置。
    var roughTextValue: String {
        switch self {
        case .beforeCharacter: return "before_char"
        default: return "after_char"
        }
    }

    /// 从角色卡字符串反推（只能得到两档）。
    init(cardText: String) {
        self = cardText.lowercased() == "after_char" ? .afterCharacter : .beforeCharacter
    }

    var displayName: String {
        switch self {
        case .beforeCharacter: return "角色定义之前"
        case .afterCharacter: return "角色定义之后"
        case .authorNoteTop: return "作者注释顶部"
        case .authorNoteBottom: return "作者注释底部"
        case .atDepth: return "按深度插入"
        case .exampleTop: return "示例消息顶部"
        case .exampleBottom: return "示例消息底部"
        case .outlet: return "Outlet"
        }
    }
}
