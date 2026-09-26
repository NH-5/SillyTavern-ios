import Foundation

/// 角色卡编解码器：负责在「文件字节」与 `CharacterCard` 之间转换。
///
/// 兼容性目标（与 SillyTavern 1.19.0 对齐，详见
/// `docs/ios-research/01-character-card-spec.md`）：
/// - 读 PNG 时**优先 `ccv3`，回退 `chara`**，两者都是 `tEXt` + Base64(JSON)；
/// - 版本分水岭是 **`spec` 键是否存在**，而不是它的取值；
/// - ST 生成的卡会**同时平铺 v1 字段与 `data`**，因此两条路径都要能吃；
/// - 导入 v1 时要走 `creatorcomment` ⇄ `creator_notes` 等历史字段映射。
enum CharacterCardCodec {
    enum ImportError: LocalizedError {
        case unsupportedFile(String)
        case noCharacterData
        case invalidJSON(String)
        case missingName

        var errorDescription: String? {
            switch self {
            case .unsupportedFile(let ext):
                return "不支持的文件格式：.\(ext)。请导入 PNG 角色卡或 JSON 文件。"
            case .noCharacterData:
                return "这个 PNG 里没有找到角色数据（缺少 chara / ccv3 元数据块）。"
            case .invalidJSON(let detail):
                return "角色数据不是有效的 JSON：\(detail)"
            case .missingName:
                return "角色卡里没有 name 字段，无法导入。"
            }
        }
    }

    /// 导入结果：角色 + 原始 PNG 字节（用于头像与原样导出）。
    struct ImportResult {
        var card: CharacterCard
        /// 若来源是 PNG，保留原始字节；JSON 导入时为 nil。
        var originalPNG: Data?
        /// 卡内原始 JSON（对应 ST 的 `json_data`，导出时可无损回写未知字段）。
        var rawJSON: Data?
        /// 推断出的规范版本："1" / "2" / "3"。
        var detectedSpecVersion: String
    }

    // MARK: - 导入

    /// 从文件数据导入角色卡。
    ///
    /// - Parameters:
    ///   - data: 文件字节。
    ///   - fileName: 文件名（用于判断扩展名与生成头像名）。
    static func importCard(from data: Data, fileName: String) throws -> ImportResult {
        let ext = (fileName as NSString).pathExtension.lowercased()

        if ext == "png" || isPNG(data) {
            return try importFromPNG(data, fileName: fileName)
        }
        if ext == "json" || ext.isEmpty {
            return try importFromJSON(data, fileName: fileName)
        }
        throw ImportError.unsupportedFile(ext)
    }

    /// 判断字节流是否为 PNG。
    static func isPNG(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        return Array(data.prefix(8)) == PNGCodec.signature
    }

    /// 从 PNG 角色卡导入。
    static func importFromPNG(_ data: Data, fileName: String) throws -> ImportResult {
        let chunks = try PNGCodec.parse(data)

        // 先收集所有 tEXt 块并解码，再按 ccv3 > chara 的优先级取用。
        var decoded: [(keyword: String, text: String)] = []
        for chunk in chunks where chunk.name == "tEXt" {
            if let entry = PNGCodec.decodeText(chunk.data) {
                decoded.append(entry)
            }
        }

        let keywordPriority = ["ccv3", "chara"]
        var payload: String?
        var usedKeyword = ""
        for keyword in keywordPriority {
            if let match = decoded.first(where: { $0.keyword.lowercased() == keyword }) {
                payload = match.text
                usedKeyword = keyword
                break
            }
        }

        guard let base64Text = payload else { throw ImportError.noCharacterData }
        // 用容错解码：真实世界的卡常见缺 padding、URL-safe 字母表或带换行。
        guard let jsonData = Base64.decode(base64Text) else {
            throw ImportError.invalidJSON("Base64 解码失败")
        }

        var result = try parseCardJSON(jsonData, fileName: fileName)
        result.originalPNG = data
        if usedKeyword == "ccv3" {
            // ccv3 只是把标签改成 v3，数据结构与 v2 相同。
            result.detectedSpecVersion = "3"
        }
        return result
    }

    /// 从 JSON 文件导入。
    static func importFromJSON(_ data: Data, fileName: String) throws -> ImportResult {
        var result = try parseCardJSON(data, fileName: fileName)
        result.rawJSON = data
        return result
    }

    /// 解析角色卡 JSON，按 spec / name / char_name 三种形状归一化。
    static func parseCardJSON(_ data: Data, fileName: String) throws -> ImportResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw ImportError.invalidJSON(String(text.prefix(200)))
        }

        let detectedVersion: String
        let card: CharacterCard

        if root["spec"] != nil {
            // v2 / v3 路径。注意：有 spec 但没 data 时 ST 会原样返回，
            // 我们这里按 v1 形状尽量解析，避免用户完全导不进来。
            if let dataObject = root["data"] as? [String: Any] {
                card = cardFromV2(root: root, data: dataObject)
                let specVersion = (root["spec_version"] as? String) ?? ""
                detectedVersion = specVersion.hasPrefix("3") ? "3" : "2"
            } else {
                card = cardFromV1(root)
                detectedVersion = "1"
            }
        } else if root["name"] != nil {
            // v1 扁平结构。
            card = cardFromV1(root)
            detectedVersion = "1"
        } else if root["char_name"] != nil {
            // Gradio / Pygmalion notepad 历史格式。
            card = cardFromGradio(root)
            detectedVersion = "1"
        } else {
            throw ImportError.missingName
        }

        let result = ImportResult(
            card: finalize(card, fileName: fileName),
            originalPNG: nil,
            rawJSON: data,
            detectedSpecVersion: detectedVersion
        )
        if result.card.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ImportError.missingName
        }
        return result
    }

    // MARK: - 三种来源形状 → CharacterCard

    /// v2/v3：`data` 是权威，顶层 v1 字段只作残留兼容。
    private static func cardFromV2(root: [String: Any], data: [String: Any]) -> CharacterCard {
        var card = CharacterCard()

        // 保留整张原始卡，导出时作为基底。
        card.rawRoot = (root).compactMapValues { JSONValue.from($0) }

        card.name = string(data["name"]) ?? string(root["name"]) ?? ""
        card.description = string(data["description"]) ?? string(root["description"]) ?? ""
        card.personality = string(data["personality"]) ?? string(root["personality"]) ?? ""
        card.scenario = string(data["scenario"]) ?? string(root["scenario"]) ?? ""
        card.firstMes = string(data["first_mes"]) ?? string(root["first_mes"]) ?? ""
        card.mesExample = string(data["mes_example"]) ?? string(root["mes_example"]) ?? ""
        card.systemPrompt = string(data["system_prompt"]) ?? ""
        card.postHistoryInstructions = string(data["post_history_instructions"]) ?? ""
        card.creator = string(data["creator"]) ?? ""
        card.characterVersion = string(data["character_version"]) ?? ""

        // creator_notes 优先，回退 v1 时代的 creatorcomment。
        // 并剥离作者模板里的占位文字（ST 会这么做）。
        let notes = string(data["creator_notes"])
            ?? string(root["creatorcomment"])
            ?? string(root["creator_notes"])
            ?? ""
        card.creatorNotes = strippingPlaceholderNotes(notes)

        // tags 兼容数组与逗号分隔字符串。
        card.tags = stringArray(data["tags"]) ?? stringArray(root["tags"]) ?? []

        // alternate_greetings 兼容单字符串。
        card.alternateGreetings = stringArray(data["alternate_greetings"]) ?? []

        // extensions：talkativeness / fav / world / depth_prompt 等 ST 扩展都在这里。
        if let extensions = data["extensions"] as? [String: Any] {
            card.extensions = extensions.compactMapValues { JSONValue.from($0) }
            card.world = string(extensions["world"]) ?? ""
            card.talkativeness = double(extensions["talkativeness"]) ?? 0.5
            // ST 用字符串比较解析 fav，这里两种写法都认。
            card.isFavorite = bool(extensions["fav"]) ?? false
            if let depth = extensions["depth_prompt"] as? [String: Any] {
                card.depthPrompt = CharacterDepthPrompt(
                    prompt: string(depth["prompt"]) ?? "",
                    depth: int(depth["depth"]) ?? 4,
                    role: int(depth["role"]) ?? 0
                )
            }
        }

        card.specVersion = string(root["spec_version"])
            ?? (string(root["spec"]) == "chara_card_v3" ? "3.0" : "2.0")

        card.createDate = string(root["create_date"]) ?? string(data["creation_date"]) ?? ChatMessage.timestamp()
        card.chatName = string(root["chat"]) ?? ""

        // 内嵌世界书。
        if let book = data["character_book"] as? [String: Any] {
            card.characterBook = characterBook(from: book)
        }

        return card
    }

    /// v1：顶层扁平字段。
    private static func cardFromV1(_ root: [String: Any]) -> CharacterCard {
        var card = CharacterCard()

        card.rawRoot = root.compactMapValues { JSONValue.from($0) }
        card.name = string(root["name"]) ?? ""
        card.description = string(root["description"]) ?? ""
        card.personality = string(root["personality"]) ?? ""
        card.scenario = string(root["scenario"]) ?? ""
        card.firstMes = string(root["first_mes"]) ?? ""
        card.mesExample = string(root["mes_example"]) ?? ""
        card.creatorNotes = strippingPlaceholderNotes(
            string(root["creatorcomment"]) ?? string(root["creator_notes"]) ?? ""
        )
        card.creator = string(root["creator"]) ?? ""
        card.characterVersion = string(root["character_version"]) ?? ""
        card.tags = stringArray(root["tags"]) ?? []
        card.alternateGreetings = stringArray(root["alternate_greetings"]) ?? []
        card.systemPrompt = string(root["system_prompt"]) ?? ""
        card.postHistoryInstructions = string(root["post_history_instructions"]) ?? ""
        card.createDate = string(root["create_date"]) ?? ChatMessage.timestamp()
        card.chatName = string(root["chat"]) ?? ""
        card.specVersion = "1"

        if let extensions = root["extensions"] as? [String: Any] {
            card.extensions = extensions.compactMapValues { JSONValue.from($0) }
        }
        card.world = string(root["world"]) ?? card.extensions["world"]?.stringValue ?? ""
        card.talkativeness = double(root["talkativeness"]) ?? double(card.extensions["talkativeness"]) ?? 0.5
        card.isFavorite = bool(root["fav"]) ?? bool(card.extensions["fav"]) ?? false

        if let book = root["character_book"] as? [String: Any] {
            card.characterBook = characterBook(from: book)
        }

        return card
    }

    /// Gradio / Pygmalion notepad 的历史字段名。
    private static func cardFromGradio(_ root: [String: Any]) -> CharacterCard {
        var card = CharacterCard()

        card.name = string(root["char_name"]) ?? ""
        card.description = string(root["char_persona"]) ?? ""
        card.firstMes = string(root["char_greeting"]) ?? ""
        card.scenario = string(root["world_scenario"]) ?? ""
        card.mesExample = string(root["example_dialogue"]) ?? ""
        // 这个格式里没有性格字段，与 ST 一致地留空。
        card.personality = ""
        card.creatorNotes = strippingPlaceholderNotes(
            string(root["creator_notes"]) ?? string(root["creatorcomment"]) ?? ""
        )
        card.specVersion = "1"
        card.createDate = string(root["create_date"]) ?? ChatMessage.timestamp()

        return card
    }

    // MARK: - character_book → CharacterBook

    /// 解析 `character_book`（数组式 entries）。
    static func characterBook(from object: [String: Any]) -> CharacterBook {
        var book = CharacterBook()

        book.name = string(object["name"]) ?? ""
        book.description = string(object["description"]) ?? ""
        book.scanDepth = int(object["scan_depth"])
        book.tokenBudget = int(object["token_budget"])
        book.recursiveScanning = bool(object["recursive_scanning"])
        if let extensions = object["extensions"] as? [String: Any] {
            book.extensions = extensions.compactMapValues { JSONValue.from($0) }
        }

        if let entries = object["entries"] as? [[String: Any]] {
            book.entries = entries.enumerated().map { index, entry in
                worldInfoEntry(from: entry, fallbackIndex: index)
            }
        }

        return book
    }

    /// 解析单个世界书条目。
    ///
    /// 关键映射（`docs/ios-research/01-character-card-spec.md` §3.2）：
    /// - 卡内字段名是下划线风格（`insertion_order` / `secondary_keys`）；
    /// - `enabled` 在卡里是正向语义，ST 内部用 `disable` 取反；
    /// - `position` 字符串只表达 before_char / after_char，更精细的位置
    ///   藏在 `extensions.position`（数字 0-7），它**优先**于字符串。
    static func worldInfoEntry(from object: [String: Any], fallbackIndex: Int = 0) -> WorldInfoEntry {
        var entry = WorldInfoEntry()

        entry.keys = stringArray(object["keys"]) ?? []
        entry.secondaryKeys = stringArray(object["secondary_keys"]) ?? []
        entry.content = string(object["content"]) ?? ""
        // 注意默认值语义：ST 内部把 `enabled` 转成 `disable = !enabled`，
        // 字段缺失时 `!undefined === true`，即**条目被禁用**。
        entry.enabled = bool(object["enabled"]) ?? false
        entry.constant = bool(object["constant"]) ?? false
        entry.selective = bool(object["selective"]) ?? false
        entry.caseSensitive = bool(object["case_sensitive"]) ?? false
        entry.matchWholeWords = bool(object["match_whole_words"]) ?? false
        entry.insertionOrder = int(object["insertion_order"]) ?? int(object["order"]) ?? 100
        entry.priority = int(object["priority"]) ?? 10
        entry.probability = int(object["probability"]) ?? 100
        entry.comment = string(object["comment"]) ?? ""
        entry.name = string(object["name"]) ?? ""

        if let extensions = object["extensions"] as? [String: Any] {
            entry.extensions = extensions.compactMapValues { JSONValue.from($0) }
            entry.excludeRecursion = bool(extensions["exclude_recursion"]) ?? false
            entry.preventRecursion = bool(extensions["prevent_recursion"]) ?? false
            if let probability = int(extensions["probability"]) { entry.probability = probability }
        }

        // 位置：extensions.position 的数字优先，它才能表达 0-7 的全部取值。
        if let numeric = entry.extensions["position"]?.intValue {
            entry.position = WorldInfoPosition(numericValue: numeric)
        } else if let positionText = string(object["position"]) {
            entry.position = WorldInfoPosition(cardText: positionText)
        } else {
            // 字符串 position 缺失时 ST 落到 1（after），而不是 0。
            entry.position = .afterCharacter
        }

        // 深度：extensions.depth 优先，回退顶层 depth。
        if let depth = entry.extensions["depth"]?.intValue {
            entry.depth = depth
        } else {
            entry.depth = int(object["depth"]) ?? 4
        }

        return entry
    }

    // MARK: - CharacterCard → v2 JSON（导出用）

    /// 把角色卡编码成规范 v2 结构。
    ///
    /// 复刻 ST 的「双写」行为：顶层平铺一份 v1 字段，同时写 `spec`/`spec_version`/`data`。
    /// 这样导出的卡在任何 SillyTavern 版本与其他前端里都能正常读。
    static func exportJSON(_ card: CharacterCard, prettyPrinted: Bool = true) throws -> Data {
        let object = exportObject(card, specVersion: card.specVersion.hasPrefix("3") ? "3.0" : "2.0")
        let text = prettyPrinted ? JSONRenderer.pretty(object) : JSONRenderer.compact(object)
        return Data(text.utf8)
    }

    /// 构造导出用的字典（内部方法，也供 PNG 导出复用）。
    static func exportObject(_ card: CharacterCard, specVersion: String) -> [String: Any] {
        let isV3 = specVersion.hasPrefix("3")

        // ---- 基底：原始卡里的陌生键先铺开，保证无损往返 ----
        // 对应 ST 的 charaFormatData(data)：以 json_data 为基底再叠加已知字段。
        var root: [String: Any] = card.rawRoot.compactMapValues { $0.anyValue }
        root.removeValue(forKey: "json_data") // 防止递归嵌套

        // ---- extensions：先铺原始扩展，再覆盖我们维护的字段 ----
        var extensions: [String: Any] = card.extensions.compactMapValues { $0.anyValue }
        extensions["world"] = card.world
        extensions["talkativeness"] = card.talkativeness
        extensions["fav"] = card.isFavorite
        if let depthPrompt = card.depthPrompt {
            extensions["depth_prompt"] = [
                "prompt": depthPrompt.prompt,
                "depth": depthPrompt.depth,
                "role": depthPrompt.role,
            ]
        }

        // ---- data 段 ----
        var existingData = root["data"] as? [String: Any] ?? [:]
        existingData["name"] = card.name
        existingData["description"] = card.description
        existingData["personality"] = card.personality
        existingData["scenario"] = card.scenario
        existingData["first_mes"] = card.firstMes
        existingData["mes_example"] = card.mesExample
        existingData["creator_notes"] = card.creatorNotes
        existingData["system_prompt"] = card.systemPrompt
        existingData["post_history_instructions"] = card.postHistoryInstructions
        existingData["alternate_greetings"] = card.alternateGreetings
        existingData["tags"] = card.tags
        existingData["creator"] = card.creator
        existingData["character_version"] = card.characterVersion
        existingData["extensions"] = extensions
        if let book = card.characterBook {
            existingData["character_book"] = characterBookObject(book)
        }

        // ---- 顶层：v1 平铺 + v2 骨架（ST 的双写 hack）----
        root["name"] = card.name
        root["description"] = card.description
        root["personality"] = card.personality
        root["scenario"] = card.scenario
        root["first_mes"] = card.firstMes
        root["mes_example"] = card.mesExample
        root["creatorcomment"] = card.creatorNotes
        root["avatar"] = "none"
        root["tags"] = card.tags
        root["create_date"] = card.createDate
        root["talkativeness"] = card.talkativeness
        root["fav"] = card.isFavorite
        if !card.chatName.isEmpty {
            root["chat"] = card.chatName
        }
        root["spec"] = isV3 ? "chara_card_v3" : "chara_card_v2"
        root["spec_version"] = isV3 ? "3.0" : "2.0"
        root["data"] = existingData

        return root
    }

    /// `CharacterBook` → 卡内 `character_book` 字典（数组式 entries，下划线字段名）。
    static func characterBookObject(_ book: CharacterBook) -> [String: Any] {
        var object: [String: Any] = [
            "name": book.name,
            "description": book.description,
            "entries": book.entries.enumerated().map { index, entry in
                worldInfoEntryObject(entry, index: index)
            },
        ]
        if let scanDepth = book.scanDepth { object["scan_depth"] = scanDepth }
        if let tokenBudget = book.tokenBudget { object["token_budget"] = tokenBudget }
        if let recursive = book.recursiveScanning { object["recursive_scanning"] = recursive }
        if !book.extensions.isEmpty {
            object["extensions"] = book.extensions.compactMapValues { $0.anyValue }
        }
        return object
    }

    /// `WorldInfoEntry` → 卡内条目字典。
    static func worldInfoEntryObject(_ entry: WorldInfoEntry, index: Int) -> [String: Any] {
        var extensions: [String: Any] = entry.extensions.compactMapValues { $0.anyValue }
        // 精细位置与深度用数字表达（ST 读卡时优先看这两个）。
        extensions["position"] = entry.position.numericValue
        extensions["depth"] = entry.depth
        extensions["exclude_recursion"] = entry.excludeRecursion
        extensions["prevent_recursion"] = entry.preventRecursion

        return [
            "keys": entry.keys,
            "secondary_keys": entry.secondaryKeys,
            "content": entry.content,
            "enabled": entry.enabled,
            "constant": entry.constant,
            "selective": entry.selective,
            "case_sensitive": entry.caseSensitive,
            "match_whole_words": entry.matchWholeWords,
            "insertion_order": entry.insertionOrder,
            "priority": entry.priority,
            "probability": entry.probability,
            "comment": entry.comment,
            "name": entry.name.isEmpty ? entry.displayTitle : entry.name,
            // 字符串位置只表达粗略的两档，精细信息在 extensions 里。
            "position": entry.position.roughTextValue,
            "depth": entry.depth,
            "extensions": extensions,
        ]
    }

    // MARK: - 导出 PNG

    /// 用角色卡数据生成一张 PNG 角色卡。
    ///
    /// 若提供 `baseImage`（导入时的原始 PNG），则只替换元数据块，图像数据完全不动；
    /// 否则生成一张 1x1 的占位 PNG。
    ///
    /// 与 ST 一致：同时写 `chara`（v2 标签）与 `ccv3`（v3 标签），
    /// 顺序为 `…, tEXt(chara), tEXt(ccv3), IEND`。
    static func exportPNG(_ card: CharacterCard, baseImage: Data?) throws -> Data {
        var chunks: [PNGChunk]
        if let baseImage, isPNG(baseImage), let parsed = try? PNGCodec.parse(baseImage) {
            chunks = parsed
        } else {
            chunks = try placeholderPNGChunks()
        }

        // 去掉旧的 chara / ccv3，避免同关键字重复。
        chunks = PNGCodec.removingCharacterTexts(from: chunks)

        let v2Text = JSONRenderer.compact(exportObject(card, specVersion: "2.0"))
        let v3Text = JSONRenderer.compact(exportObject(card, specVersion: "3.0"))

        chunks = PNGCodec.insertingBeforeIEND(
            PNGCodec.encodeText(keyword: "chara", text: Base64.encode(Data(v2Text.utf8))),
            into: chunks
        )
        chunks = PNGCodec.insertingBeforeIEND(
            PNGCodec.encodeText(keyword: "ccv3", text: Base64.encode(Data(v3Text.utf8))),
            into: chunks
        )

        return PNGCodec.encode(chunks)
    }

    /// 生成 1x1 透明 PNG 的 chunk 列表，用于没有原图时导出。
    private static func placeholderPNGChunks() throws -> [PNGChunk] {
        // IHDR: 宽 1、高 1、8 位深、色彩类型 6（RGBA）、无隔行。
        let ihdr = Data([0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0])
        // 一行像素：filter 字节 0 + 4 字节 RGBA。
        let raw = Data([0x00, 0x00, 0x00, 0x00, 0x00])
        let idat = zlibStored(raw)
        return [
            PNGChunk(name: "IHDR", data: ihdr),
            PNGChunk(name: "IDAT", data: idat),
            PNGChunk(name: "IEND", data: Data()),
        ]
    }

    /// 用 zlib 的「存储（未压缩）」块包装数据。
    ///
    /// 自己拼而不引第三方库：PNG 的 IDAT 只要求 zlib 流，
    /// 存储块（BTYPE=00）实现简单且无需压缩库。
    private static func zlibStored(_ data: Data) -> Data {
        var out = Data([0x78, 0x01]) // zlib 头：默认压缩级别
        var remaining = data
        while true {
            let blockSize = min(remaining.count, 65535)
            let isLast = remaining.count <= 65535
            out.append(isLast ? 0x01 : 0x00) // BFINAL + BTYPE=00
            let length = UInt16(blockSize)
            let negated = ~length
            out.append(UInt8(length & 0xFF))
            out.append(UInt8((length >> 8) & 0xFF))
            out.append(UInt8(negated & 0xFF))
            out.append(UInt8((negated >> 8) & 0xFF))
            out.append(remaining.prefix(blockSize))
            remaining = remaining.dropFirst(blockSize)
            if isLast { break }
        }
        out.append(adler32(data))
        return out
    }

    /// zlib 流尾部需要的 Adler-32 校验。
    private static func adler32(_ data: Data) -> Data {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        let value = (b << 16) | a
        return Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ])
    }

    // MARK: - 辅助

    /// 补齐导入后的收尾工作。
    private static func finalize(_ card: CharacterCard, fileName: String) -> CharacterCard {
        var result = card
        if result.avatarFileName.isEmpty {
            let stem = (fileName as NSString).deletingPathExtension
            result.avatarFileName = stem.isEmpty ? "\(result.name).png" : "\(stem).png"
        }
        return result
    }

    /// ST 会剥掉模板里的占位备注文字。
    private static func strippingPlaceholderNotes(_ notes: String) -> String {
        notes.replacingOccurrences(of: "Creator's notes go here.", with: "")
    }

    private static func string(_ any: Any?) -> String? {
        switch any {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    private static func int(_ any: Any?) -> Int? {
        switch any {
        case let value as Int:
            return value
        case let value as Double:
            return Int(value)
        case let value as String:
            return Int(value)
        case let value as NSNumber:
            return value.intValue
        default:
            return nil
        }
    }

    private static func double(_ any: Any?) -> Double? {
        switch any {
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        case let value as String:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        default:
            return nil
        }
    }

    private static func bool(_ any: Any?) -> Bool? {
        switch any {
        case let value as Bool:
            return value
        // ST 用字符串比较解析 fav，这里把 "true" 也认下来。
        case let value as String:
            return value.lowercased() == "true"
        case let value as NSNumber:
            return value.boolValue
        default:
            return nil
        }
    }

    /// 兼容 `["a","b"]` 与 `"a, b"` 两种写法。
    private static func stringArray(_ any: Any?) -> [String]? {
        if let array = any as? [String] {
            return array
        }
        if let array = any as? [Any] {
            return array.compactMap { string($0) }
        }
        if let text = any as? String {
            return text
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return nil
    }
}
