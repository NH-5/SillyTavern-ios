import Foundation

/// 世界书文件编解码。
///
/// 这里要处理**两套字段体系**的转换，混用会直接导致 ST 读不懂或丢数据：
/// - 磁盘文件 `worlds/<名字>.json`：`entries` 是**以 uid 为键的对象**，
///   字段是 ST 的 camelCase（`key` / `keysecondary` / `order` / `disable`）；
/// - 角色卡内嵌的 `character_book`：`entries` 是**数组**，
///   字段是规范的下划线风格（`keys` / `secondary_keys` / `insertion_order` / `enabled`）。
///
/// 另外注意 `enabled` 与 `disable` **语义相反**，转换时必须取反。
enum WorldInfoCodec {
    enum Error: LocalizedError {
        case missingEntries

        var errorDescription: String? {
            switch self {
            case .missingEntries:
                return "世界书文件里缺少 entries 字段。"
            }
        }
    }

    // MARK: - 解码（磁盘 → CharacterBook）

    /// 解析 `worlds/*.json`。
    static func decode(_ data: Data, name: String) throws -> CharacterBook {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.missingEntries
        }
        guard let entriesObject = root["entries"] as? [String: Any] else {
            throw Error.missingEntries
        }

        var book = CharacterBook()
        book.name = root["name"] as? String ?? name
        if let extensions = root["extensions"] as? [String: Any] {
            book.extensions = extensions.compactMapValues { JSONValue.from($0) }
        }

        // 以 uid 数值排序，保证条目顺序稳定（对象键顺序不可靠）。
        let sortedEntries = entriesObject.compactMap { key, value -> (Int, [String: Any])? in
            guard let object = value as? [String: Any] else { return nil }
            let uid = (object["uid"] as? Int) ?? Int(key) ?? 0
            return (uid, object)
        }.sorted { $0.0 < $1.0 }

        book.entries = sortedEntries.map { uid, object in
            entryFromST(object, uid: uid)
        }

        return book
    }

    /// ST 磁盘条目 → 内部条目。
    private static func entryFromST(_ object: [String: Any], uid: Int) -> WorldInfoEntry {
        var entry = WorldInfoEntry()

        // uid 存在 extensions 里，写回时优先复用它，避免 ST 侧条目 id 漂移。
        entry.extensions["uid"] = .integer(uid)

        entry.keys = object["key"] as? [String] ?? []
        entry.secondaryKeys = object["keysecondary"] as? [String] ?? []
        entry.content = object["content"] as? String ?? ""
        entry.comment = object["comment"] as? String ?? ""
        entry.constant = object["constant"] as? Bool ?? false
        entry.selective = object["selective"] as? Bool ?? true
        entry.insertionOrder = object["order"] as? Int ?? 100
        entry.probability = object["probability"] as? Int ?? 100
        // disable 与 enabled 语义相反。
        entry.enabled = !(object["disable"] as? Bool ?? false)
        entry.caseSensitive = object["caseSensitive"] as? Bool ?? false
        entry.matchWholeWords = object["matchWholeWords"] as? Bool ?? false
        entry.excludeRecursion = object["excludeRecursion"] as? Bool ?? false
        entry.preventRecursion = object["preventRecursion"] as? Bool ?? false
        entry.depth = object["depth"] as? Int ?? 4
        entry.position = WorldInfoPosition(numericValue: object["position"] as? Int ?? 0)

        // selectiveLogic / role / ignoreBudget / group 等 ST 专有字段放进 extensions，
        // 内部引擎会从 extensions 里读取。
        if let logic = object["selectiveLogic"] as? Int {
            entry.extensions["selectiveLogic"] = .integer(logic)
        }
        if let role = object["role"] as? Int {
            entry.extensions["role"] = .integer(role)
        }
        if let ignoreBudget = object["ignoreBudget"] as? Bool {
            entry.extensions["ignore_budget"] = .bool(ignoreBudget)
        }
        for key in ["group", "groupWeight", "groupOverride", "outletName",
                    "scanDepth", "sticky", "cooldown", "delay", "delayUntilRecursion",
                    "useProbability", "vectorized", "automationId", "displayIndex",
                    "matchPersonaDescription", "matchCharacterDescription",
                    "matchCharacterPersonality", "matchCharacterDepthPrompt",
                    "matchScenario", "matchCreatorNotes", "triggers"] {
            if let value = object[key] {
                entry.extensions[key] = JSONValue.from(value)
            }
        }

        return entry
    }

    // MARK: - 编码（CharacterBook → 磁盘）

    /// 生成 `worlds/*.json` 数据（4 空格缩进，与 ST 一致）。
    static func encode(_ book: CharacterBook) -> Data {
        var root: [String: Any] = [:]

        var entries: [String: Any] = [:]
        for (index, entry) in book.entries.enumerated() {
            // 复用导入时记下的 uid；没有则按顺序分配。
            let uid = entry.extensions["uid"]?.intValue ?? index
            entries[String(uid)] = entryToST(entry, uid: uid)
        }
        root["entries"] = entries

        if !book.name.isEmpty { root["name"] = book.name }
        if !book.extensions.isEmpty {
            root["extensions"] = book.extensions.compactMapValues { $0.anyValue }
        }

        // 用自写渲染器：ST 用 `JSON.stringify(data, null, 4)`，
        // 而 JSONSerialization 的 prettyPrinted 是 2 空格且冒号前带空格。
        return Data(JSONRenderer.pretty(root).utf8)
    }

    /// 内部条目 → ST 磁盘条目。
    private static func entryToST(_ entry: WorldInfoEntry, uid: Int) -> [String: Any] {
        var object: [String: Any] = [
            "uid": uid,
            "key": entry.keys,
            "keysecondary": entry.secondaryKeys,
            "comment": entry.comment,
            "content": entry.content,
            "constant": entry.constant,
            "selective": entry.selective,
            "order": entry.insertionOrder,
            "position": entry.position.numericValue,
            // disable 与 enabled 语义相反，这里取反。
            "disable": !entry.enabled,
            "depth": entry.depth,
            "probability": entry.probability,
            "caseSensitive": entry.caseSensitive,
            "matchWholeWords": entry.matchWholeWords,
            "excludeRecursion": entry.excludeRecursion,
            "preventRecursion": entry.preventRecursion,
        ]

        // 把 extensions 里的 ST 专有字段还原到顶层。
        for (key, value) in entry.extensions {
            switch key {
            case "uid":
                continue
            case "selectiveLogic", "role", "ignoreBudget", "group", "groupWeight",
                 "groupOverride", "outletName", "scanDepth", "sticky", "cooldown",
                 "delay", "delayUntilRecursion", "useProbability", "vectorized",
                 "automationId", "displayIndex", "matchPersonaDescription",
                 "matchCharacterDescription", "matchCharacterPersonality",
                 "matchCharacterDepthPrompt", "matchScenario", "matchCreatorNotes",
                 "triggers":
                object[key] = value.anyValue
            case "ignore_budget":
                object["ignoreBudget"] = value.anyValue
            default:
                break
            }
        }

        // 补齐 ST 期望存在的默认字段，避免它读到时是 undefined。
        if object["selectiveLogic"] == nil { object["selectiveLogic"] = 0 }
        if object["useProbability"] == nil { object["useProbability"] = true }
        if object["group"] == nil { object["group"] = "" }
        if object["groupWeight"] == nil { object["groupWeight"] = 100 }
        if object["groupOverride"] == nil { object["groupOverride"] = false }
        if object["outletName"] == nil { object["outletName"] = "" }
        if object["delayUntilRecursion"] == nil { object["delayUntilRecursion"] = 0 }
        if object["vectorized"] == nil { object["vectorized"] = false }
        if object["addMemo"] == nil { object["addMemo"] = false }
        if object["triggers"] == nil { object["triggers"] = [String]() }

        return object
    }

    // MARK: - 与角色卡 character_book 的互转

    /// 把独立世界书转换成可内嵌进角色卡的形式。
    static func toCharacterBook(_ book: CharacterBook, name: String) -> CharacterBook {
        var result = book
        if result.name.isEmpty { result.name = name }
        return result
    }
}
