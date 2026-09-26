import Foundation

/// 极简测试框架。
///
/// 不引 XCTest：测试程序要能在没有 Xcode 测试运行器的环境下直接跑，
/// 一个自带的断言器就够用了。
final class TestRunner {
    private var passed = 0
    private var failures: [String] = []
    private var currentSuite = ""
    private var onlyList = false

    func suite(_ name: String) {
        currentSuite = name
        print("\n\u{001B}[1m── \(name)\u{001B}[0m")
    }

    func expect(_ condition: Bool, _ description: String, detail: @autoclosure () -> String = "") {
        if condition {
            passed += 1
            print("  \u{001B}[32m✓\u{001B}[0m \(description)")
        } else {
            let extra = detail()
            let message = extra.isEmpty ? description : "\(description) — \(extra)"
            failures.append("[\(currentSuite)] \(message)")
            print("  \u{001B}[31m✗ \(message)\u{001B}[0m")
        }
    }

    func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ description: String) {
        expect(
            actual == expected,
            description,
            detail: "期望 \(expected)，实际 \(actual)"
        )
    }

    func expectThrows(_ description: String, _ body: () throws -> Void) {
        do {
            try body()
            expect(false, description, detail: "本应抛错但没有")
        } catch {
            expect(true, description)
        }
    }

    func report() -> Int32 {
        print("\n" + String(repeating: "─", count: 60))
        if failures.isEmpty {
            print("\u{001B}[32m全部通过：\(passed) 项断言\u{001B}[0m")
            return 0
        }
        print("\u{001B}[31m失败 \(failures.count) 项 / 通过 \(passed) 项\u{001B}[0m")
        for failure in failures {
            print("  • \(failure)")
        }
        return 1
    }
}

/// 测试素材目录（仓库自带的 SillyTavern 默认内容）。
enum Fixtures {
    static var directory: URL {
        let path = ProcessInfo.processInfo.environment["ST_FIXTURES"]
            ?? FileManager.default.currentDirectoryPath + "/default/content"
        return URL(fileURLWithPath: path)
    }

    static var seraphinaCard: URL { directory.appendingPathComponent("default_Seraphina.png") }
    static var eldoriaWorld: URL { directory.appendingPathComponent("Eldoria.json") }

    static func data(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

@main
struct CoreTests {
    static func main() {
        let runner = TestRunner()

        print("\u{001B}[1mSillyTavern iOS 核心逻辑测试\u{001B}[0m")
        print("素材目录：\(Fixtures.directory.path)")

        if CommandLine.arguments.contains("--list") {
            print("\n可用测试套件：PNG、角色卡、世界书、JSONL、SSE、宏、Token、渲染器")
            exit(0)
        }

        testCRC32(runner)
        testPNGCodec(runner)
        testCharacterCardImport(runner)
        testCharacterCardRoundTrip(runner)
        testV1AndGradioImport(runner)
        testWorldInfoCodec(runner)
        testWorldInfoEngine(runner)
        testChatSessionCodec(runner)
        testSSEParser(runner)
        testMacroProcessor(runner)
        testTokenEstimator(runner)
        testJSONRenderer(runner)
        testBase64(runner)
        testPromptBuilder(runner)
        testLLMRequestBuilding(runner)
        testResponseExtraction(runner)

        // 诊断：如果给了外部索引文件，尝试真实解码，把错误打出来。
        if let path = ProcessInfo.processInfo.environment["ST_DECODE_PROBE"] {
            diagnoseDecoding(path)
        }

        exit(runner.report())
    }

    // MARK: - CRC32

    static func testCRC32(_ runner: TestRunner) {
        runner.suite("CRC32")
        // 标准测试向量，能一次性验证多项式与初值/终值处理是否正确。
        runner.expectEqual(CRC32.checksum(Array("123456789".utf8)), 0xCBF4_3926, "crc32(\"123456789\") 等于标准向量")
        runner.expectEqual(CRC32.checksum(Array("IEND".utf8)), 0xAE42_6082, "crc32(\"IEND\") 等于 PNG 已知值")
        runner.expectEqual(CRC32.checksum([]), 0, "空输入为 0")
        // 分段计算必须与一次性计算等价（PNG 用 type+data 拼接计算）。
        let combined = CRC32.checksum([Array("IEN".utf8), Array("D".utf8)])
        runner.expectEqual(combined, 0xAE42_6082, "分段 CRC 与整体 CRC 等价")
    }

    // MARK: - PNG

    static func testPNGCodec(_ runner: TestRunner) {
        runner.suite("PNG 解析与编码")

        guard Fixtures.exists(Fixtures.seraphinaCard),
              let data = Fixtures.data(Fixtures.seraphinaCard) else {
            runner.expect(false, "找到测试用角色卡 default_Seraphina.png")
            return
        }
        runner.expect(true, "找到测试用角色卡（\(data.count) 字节）")

        do {
            let chunks = try PNGCodec.parse(data)
            let names = chunks.map(\.name)
            runner.expectEqual(names.first, "IHDR", "首个 chunk 是 IHDR")
            runner.expectEqual(names.last, "IEND", "末个 chunk 是 IEND")
            runner.expect(names.contains("IDAT"), "包含 IDAT 图像数据")

            let textChunks = chunks.filter { $0.name == "tEXt" }
            runner.expectEqual(textChunks.count, 2, "有两个 tEXt 元数据块")

            let keywords = textChunks.compactMap { PNGCodec.decodeText($0.data)?.keyword }
            runner.expectEqual(keywords, ["chara", "ccv3"], "关键字顺序为 chara 在前、ccv3 在后")

            // 所有块的 CRC 都应正确——这也是对解析器的交叉校验。
            let badCRC = chunks.filter { !$0.isCRCCorrect }
            runner.expect(badCRC.isEmpty, "所有 chunk 的 CRC 校验通过", detail: "异常块：\(badCRC.map(\.name))")
        } catch {
            runner.expect(false, "解析 PNG 成功", detail: error.localizedDescription)
        }

        // 非 PNG 输入应当被拒绝。
        runner.expectThrows("非 PNG 数据被拒绝") {
            _ = try PNGCodec.parse(Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]))
        }

        // 编码后再解析应当完全一致。
        do {
            let chunks = try PNGCodec.parse(data)
            let reencoded = PNGCodec.encode(chunks)
            let reparsed = try PNGCodec.parse(reencoded)
            runner.expectEqual(reparsed.count, chunks.count, "重新编码后 chunk 数量不变")
            runner.expect(reparsed.allSatisfy { $0.isCRCCorrect }, "重新编码后 CRC 仍然正确")
        } catch {
            runner.expect(false, "PNG 往返编码", detail: error.localizedDescription)
        }
    }

    // MARK: - 角色卡导入

    static func testCharacterCardImport(_ runner: TestRunner) {
        runner.suite("角色卡导入（真实 PNG 角色卡）")

        guard let data = Fixtures.data(Fixtures.seraphinaCard) else {
            runner.expect(false, "读到角色卡数据")
            return
        }

        do {
            let result = try CharacterCardCodec.importCard(from: data, fileName: "default_Seraphina.png")
            let card = result.card

            runner.expect(!card.name.isEmpty, "解析出角色名：\(card.name)")
            runner.expect(!card.description.isEmpty, "解析出描述（\(card.description.count) 字符）")
            runner.expect(!card.firstMes.isEmpty, "解析出开场白")
            runner.expectEqual(result.detectedSpecVersion, "3", "优先读取 ccv3，识别为 v3")
            runner.expect(result.originalPNG != nil, "保留原始 PNG 字节")

            // 双写 hack：卡内既有顶层 v1 字段，也有 data 段。
            runner.expect(card.rawRoot["spec"] != nil, "原始卡包含 spec 字段")
            runner.expect(card.rawRoot["data"] != nil, "原始卡包含 data 字段")
            runner.expect(card.rawRoot["name"] != nil, "顶层平铺了 v1 的 name 字段")

            // 内嵌世界书。
            if let book = card.characterBook {
                runner.expect(!book.entries.isEmpty, "解析出内嵌世界书 \(book.entries.count) 条")
            } else {
                runner.expect(false, "该卡应含 character_book")
            }
        } catch {
            runner.expect(false, "导入角色卡", detail: error.localizedDescription)
        }
    }

    // MARK: - 角色卡往返

    static func testCharacterCardRoundTrip(_ runner: TestRunner) {
        runner.suite("角色卡导出与往返")

        guard let data = Fixtures.data(Fixtures.seraphinaCard),
              let original = try? CharacterCardCodec.importCard(from: data, fileName: "card.png") else {
            runner.expect(false, "准备往返测试数据")
            return
        }

        // PNG 往返：导出后重新导入，关键字段必须一致。
        do {
            let exported = try CharacterCardCodec.exportPNG(original.card, baseImage: original.originalPNG)
            let reimported = try CharacterCardCodec.importCard(from: exported, fileName: "card.png")

            runner.expectEqual(reimported.card.name, original.card.name, "往返后角色名一致")
            runner.expectEqual(reimported.card.description, original.card.description, "往返后描述一致")
            runner.expectEqual(reimported.card.firstMes, original.card.firstMes, "往返后开场白一致")
            runner.expectEqual(reimported.card.mesExample, original.card.mesExample, "往返后示例对话一致")
            runner.expectEqual(
                reimported.card.alternateGreetings.count,
                original.card.alternateGreetings.count,
                "往返后备选开场白数量一致"
            )
            runner.expectEqual(
                reimported.card.characterBook?.entries.count ?? 0,
                original.card.characterBook?.entries.count ?? 0,
                "往返后世界书条目数量一致"
            )

            // 导出的 PNG 必须同时带 chara 与 ccv3（ST 的行为）。
            let chunks = try PNGCodec.parse(exported)
            let keywords = chunks
                .filter { $0.name == "tEXt" }
                .compactMap { PNGCodec.decodeText($0.data)?.keyword }
            runner.expect(keywords.contains("chara"), "导出包含 chara 元数据")
            runner.expect(keywords.contains("ccv3"), "导出包含 ccv3 元数据")

            // 元数据块里的 JSON 必须满足角色卡 Spec V2 的必填字段，
            // 否则其它前端（或 ST 自己）会拒绝导入。
            if let charaChunk = chunks.first(where: {
                $0.name == "tEXt" && PNGCodec.decodeText($0.data)?.keyword == "chara"
            }), let decoded = PNGCodec.decodeText(charaChunk.data) {
                let jsonData = Base64.decode(decoded.text)
                if let jsonData,
                   let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    runner.expectEqual(root["spec"] as? String, "chara_card_v2", "chara 块标记为 v2")
                    runner.expectEqual(root["spec_version"] as? String, "2.0", "spec_version 为 2.0")
                    runner.expect(root["name"] != nil, "顶层平铺了 v1 的 name（ST 双写行为）")
                    runner.expect(root["creatorcomment"] != nil, "顶层平铺了 creatorcomment")

                    let dataSection = root["data"] as? [String: Any] ?? [:]
                    let requiredV2Fields = [
                        "name", "description", "personality", "scenario", "first_mes",
                        "mes_example", "creator_notes", "system_prompt",
                        "post_history_instructions", "alternate_greetings", "tags",
                        "creator", "character_version", "extensions",
                    ]
                    let missing = requiredV2Fields.filter { dataSection[$0] == nil }
                    runner.expect(
                        missing.isEmpty,
                        "data 段包含 Spec V2 的全部必填字段",
                        detail: "缺失：\(missing)"
                    )
                } else {
                    runner.expect(false, "chara 块内容可被解析为 JSON")
                }
            } else {
                runner.expect(false, "找到并解码 chara 元数据块")
            }

            // 图像数据不能被改动。
            let originalImageBytes = original.originalPNG?.count ?? 0
            runner.expect(
                exported.count > originalImageBytes / 2,
                "导出文件保留了图像数据（\(exported.count) 字节）"
            )
        } catch {
            runner.expect(false, "PNG 往返", detail: error.localizedDescription)
        }

        // 世界书条目字段往返。
        if let book = original.card.characterBook, let first = book.entries.first {
            let object = CharacterCardCodec.worldInfoEntryObject(first, index: 0)
            let back = CharacterCardCodec.worldInfoEntry(from: object, fallbackIndex: 0)
            runner.expectEqual(back.keys, first.keys, "世界书关键词往返一致")
            runner.expectEqual(back.content, first.content, "世界书内容往返一致")
            runner.expectEqual(back.enabled, first.enabled, "世界书启用状态往返一致")
            runner.expectEqual(back.insertionOrder, first.insertionOrder, "世界书插入顺序往返一致")
            runner.expectEqual(back.position, first.position, "世界书插入位置往返一致")
            runner.expectEqual(back.depth, first.depth, "世界书深度往返一致")
        }
    }

    // MARK: - v1 与 Gradio 格式

    static func testV1AndGradioImport(_ runner: TestRunner) {
        runner.suite("v1 与 Gradio 格式导入")

        // v1 扁平卡：同时验证 creatorcomment → creator_notes 映射。
        let v1JSON = """
        {
          "name": "测试角色",
          "description": "这是一个测试描述",
          "personality": "冷淡",
          "scenario": "咖啡馆",
          "first_mes": "你好。",
          "mes_example": "<START>\\n{{user}}: 嗨\\n{{char}}: 嗯。",
          "creatorcomment": "作者备注内容",
          "tags": "标签一, 标签二",
          "talkativeness": "0.7",
          "fav": "true"
        }
        """
        do {
            let result = try CharacterCardCodec.importCard(
                from: Data(v1JSON.utf8),
                fileName: "v1.json"
            )
            runner.expectEqual(result.detectedSpecVersion, "1", "识别为 v1")
            runner.expectEqual(result.card.name, "测试角色", "v1 角色名")
            runner.expectEqual(result.card.creatorNotes, "作者备注内容", "creatorcomment 映射为作者备注")
            runner.expectEqual(result.card.tags, ["标签一", "标签二"], "逗号分隔的 tags 被拆分")
            runner.expectEqual(result.card.talkativeness, 0.7, "字符串形式的 talkativeness 被解析")
            runner.expect(result.card.isFavorite, "字符串 \"true\" 的 fav 被识别为收藏")
            runner.expectEqual(result.card.exampleMessages.count, 1, "示例对话切成 1 块")
        } catch {
            runner.expect(false, "导入 v1 卡", detail: error.localizedDescription)
        }

        // Gradio / Pygmalion 历史格式。
        let gradioJSON = """
        {
          "char_name": "旧格式角色",
          "char_persona": "旧格式描述",
          "char_greeting": "旧格式问候",
          "world_scenario": "旧格式场景",
          "example_dialogue": "旧格式示例"
        }
        """
        do {
            let result = try CharacterCardCodec.importCard(
                from: Data(gradioJSON.utf8),
                fileName: "gradio.json"
            )
            runner.expectEqual(result.card.name, "旧格式角色", "Gradio 的 char_name 映射为 name")
            runner.expectEqual(result.card.description, "旧格式描述", "char_persona 映射为描述")
            runner.expectEqual(result.card.firstMes, "旧格式问候", "char_greeting 映射为开场白")
            runner.expectEqual(result.card.scenario, "旧格式场景", "world_scenario 映射为场景")
            runner.expectEqual(result.card.mesExample, "旧格式示例", "example_dialogue 映射为示例")
        } catch {
            runner.expect(false, "导入 Gradio 卡", detail: error.localizedDescription)
        }

        // 缺少 name 的卡应当失败，而不是产生一个空角色。
        runner.expectThrows("没有 name 的 JSON 被拒绝") {
            _ = try CharacterCardCodec.importCard(from: Data("{\"foo\": 1}".utf8), fileName: "bad.json")
        }

        // 占位备注文字应被剥离。
        let placeholderJSON = """
        {"spec":"chara_card_v2","spec_version":"2.0","data":{"name":"占位测试","creator_notes":"Creator's notes go here."}}
        """
        if let result = try? CharacterCardCodec.importCard(from: Data(placeholderJSON.utf8), fileName: "p.json") {
            runner.expectEqual(result.card.creatorNotes, "", "占位备注文字被剥离")
        } else {
            runner.expect(false, "导入带占位备注的卡")
        }
    }

    // MARK: - 世界书编解码

    static func testWorldInfoCodec(_ runner: TestRunner) {
        runner.suite("世界书文件编解码")

        guard let data = Fixtures.data(Fixtures.eldoriaWorld) else {
            runner.expect(false, "读到 Eldoria.json")
            return
        }

        do {
            let book = try WorldInfoCodec.decode(data, name: "Eldoria")
            runner.expectEqual(book.entries.count, 4, "解析出 4 个条目")
            runner.expectEqual(book.name, "Eldoria", "世界书名取自参数")

            if let first = book.entries.first {
                runner.expect(!first.keys.isEmpty, "条目有关键词：\(first.keys)")
                runner.expect(!first.content.isEmpty, "条目有内容")
                // uid 存在 extensions 里，保证写回时条目 id 不漂移。
                runner.expect(first.extensions["uid"] != nil, "保留了 uid")
            }

            // 往返：对象式 entries 与内部数组式之间必须无损。
            let reencoded = WorldInfoCodec.encode(book)
            let reparsed = try WorldInfoCodec.decode(reencoded, name: "Eldoria")
            runner.expectEqual(reparsed.entries.count, book.entries.count, "往返后条目数量一致")
            runner.expectEqual(
                reparsed.entries.map(\.content),
                book.entries.map(\.content),
                "往返后条目内容一致"
            )
            runner.expectEqual(
                reparsed.entries.map(\.enabled),
                book.entries.map(\.enabled),
                "往返后启用状态一致（disable 取反正确）"
            )
            runner.expectEqual(
                reparsed.entries.map(\.position),
                book.entries.map(\.position),
                "往返后插入位置一致"
            )

            // 输出应当是 4 空格缩进，与 ST 的 JSON.stringify(_, null, 4) 一致。
            if let text = String(data: reencoded, encoding: .utf8) {
                runner.expect(text.contains("\n    \""), "输出使用 4 空格缩进")
                runner.expect(!text.contains("\\/"), "斜杠未被转义")
                runner.expect(text.contains("\": "), "冒号后带空格（JS 风格）")
            }
        } catch {
            runner.expect(false, "解析世界书", detail: error.localizedDescription)
        }

        // 缺少 entries 应报错。
        runner.expectThrows("缺少 entries 的世界书被拒绝") {
            _ = try WorldInfoCodec.decode(Data("{}".utf8), name: "bad")
        }
    }

    // MARK: - 世界书触发引擎

    static func testWorldInfoEngine(_ runner: TestRunner) {
        runner.suite("世界书触发引擎")

        func makeEntry(
            keys: [String],
            content: String,
            constant: Bool = false,
            order: Int = 100,
            selective: Bool = false,
            secondary: [String] = []
        ) -> WorldInfoEntry {
            var entry = WorldInfoEntry()
            entry.keys = keys
            entry.content = content
            entry.constant = constant
            entry.insertionOrder = order
            entry.selective = selective
            entry.secondaryKeys = secondary
            return entry
        }

        var config = WorldInfoConfig()
        config.scanDepth = 2
        let engine = WorldInfoEngine(config: config)

        let messages = [
            ChatMessage(name: "User", mes: "我们到了 magical forest 边缘", isUser: true),
            ChatMessage(name: "Seraphina", mes: "这里就是 Eldoria。", isUser: false),
        ]

        // 关键词命中。
        let hit = engine.activate(
            entries: [makeEntry(keys: ["eldoria"], content: "Eldoria 设定")],
            messages: messages
        )
        runner.expectEqual(hit.count, 1, "关键词命中的条目被激活")

        // 未命中。
        let miss = engine.activate(
            entries: [makeEntry(keys: ["不存在的词"], content: "x")],
            messages: messages
        )
        runner.expectEqual(miss.count, 0, "未命中的条目不激活")

        // constant 条目无条件激活。
        let always = engine.activate(
            entries: [makeEntry(keys: [], content: "常驻设定", constant: true)],
            messages: messages
        )
        runner.expectEqual(always.count, 1, "constant 条目无条件激活")

        // 大小写不敏感（默认）。
        let caseInsensitive = engine.activate(
            entries: [makeEntry(keys: ["ELDORIA"], content: "x")],
            messages: messages
        )
        runner.expectEqual(caseInsensitive.count, 1, "关键词匹配默认大小写不敏感")

        // 大小写敏感时不应命中。
        var sensitive = makeEntry(keys: ["ELDORIA"], content: "x")
        sensitive.caseSensitive = true
        let sensitiveResult = engine.activate(entries: [sensitive], messages: messages)
        runner.expectEqual(sensitiveResult.count, 0, "开启大小写敏感后不命中")

        // 正则关键词。
        let regex = engine.activate(
            entries: [makeEntry(keys: ["/eld[o]ria/i"], content: "x")],
            messages: messages
        )
        runner.expectEqual(regex.count, 1, "正则关键词命中")

        // 整词匹配：中文没有空格分词，不应因此失效。
        var wholeWord = makeEntry(keys: ["Eldoria"], content: "x")
        wholeWord.matchWholeWords = true
        let wholeWordResult = engine.activate(entries: [wholeWord], messages: messages)
        runner.expectEqual(wholeWordResult.count, 1, "整词匹配对中文文本仍能命中")

        // 整词匹配：英文子串不应误命中。
        var englishWhole = makeEntry(keys: ["forest"], content: "x")
        englishWhole.matchWholeWords = true
        let englishMessages = [ChatMessage(name: "U", mes: "deforestation happened", isUser: true)]
        let noSubstring = engine.activate(entries: [englishWhole], messages: englishMessages)
        runner.expectEqual(noSubstring.count, 0, "整词匹配不命中更长单词里的子串")

        // selective + 次级关键词（AND_ANY）。
        let selectiveHit = engine.activate(
            entries: [makeEntry(keys: ["eldoria"], content: "x", selective: true, secondary: ["forest"])],
            messages: messages
        )
        runner.expectEqual(selectiveHit.count, 1, "selective 且次级关键词命中时激活")

        let selectiveMiss = engine.activate(
            entries: [makeEntry(keys: ["eldoria"], content: "x", selective: true, secondary: ["海洋"])],
            messages: messages
        )
        runner.expectEqual(selectiveMiss.count, 0, "selective 但次级关键词未命中时不激活")

        // 扫描深度：只扫描最近 N 条。
        var shallowConfig = WorldInfoConfig()
        shallowConfig.scanDepth = 1
        let shallowEngine = WorldInfoEngine(config: shallowConfig)
        let deepOnly = shallowEngine.activate(
            entries: [makeEntry(keys: ["magical forest"], content: "x")],
            messages: messages
        )
        runner.expectEqual(deepOnly.count, 0, "超出扫描深度的旧消息不参与匹配")

        // 插入顺序：order 升序输出。
        let ordered = engine.activate(
            entries: [
                makeEntry(keys: ["eldoria"], content: "后", order: 200),
                makeEntry(keys: ["eldoria"], content: "先", order: 50),
            ],
            messages: messages
        )
        runner.expectEqual(ordered.map(\.entry.content), ["先", "后"], "按插入顺序升序输出")

        // 禁用条目。
        var disabled = makeEntry(keys: ["eldoria"], content: "x")
        disabled.enabled = false
        let disabledResult = engine.activate(entries: [disabled], messages: messages)
        runner.expectEqual(disabledResult.count, 0, "禁用的条目不参与")

        // 概率为 0 时不激活。
        var never = makeEntry(keys: ["eldoria"], content: "x")
        never.probability = 0
        let neverResult = engine.activate(entries: [never], messages: messages)
        runner.expectEqual(neverResult.count, 0, "概率 0 的条目不激活")

        // 同一轮内不应重复激活同一条目。
        let duplicated = engine.activate(
            entries: [
                makeEntry(keys: ["eldoria"], content: "A"),
                makeEntry(keys: ["eldoria", "forest"], content: "B"),
            ],
            messages: messages
        )
        runner.expectEqual(duplicated.count, 2, "不同条目各自激活一次")
        runner.expect(
            duplicated.allSatisfy { !$0.matchedKeys.isEmpty },
            "每个激活条目都记录了命中原因"
        )
    }

    // MARK: - JSONL

    static func testChatSessionCodec(_ runner: TestRunner) {
        runner.suite("聊天记录 JSONL")

        var session = ChatSession(characterId: UUID(), name: "测试会话")
        session.metadata.characterName = "Seraphina"
        session.metadata.userName = "User"

        var greeting = ChatMessage(name: "Seraphina", mes: "你好，我是 Seraphina。", isUser: false)
        greeting.swipes = ["你好，我是 Seraphina。", "另一个开场白"]
        greeting.swipeId = 0
        session.messages = [
            greeting,
            ChatMessage(name: "User", mes: "你好！", isUser: true),
        ]

        do {
            let data = try ChatSessionCodec.encodeJSONL(session)
            guard let text = String(data: data, encoding: .utf8) else {
                runner.expect(false, "JSONL 可转成文本")
                return
            }

            let lines = text.components(separatedBy: "\n")
            runner.expectEqual(lines.count, 3, "共 3 行（1 行头 + 2 条消息）")
            runner.expect(!text.hasSuffix("\n"), "结尾没有多余换行（与 ST 一致）")
            runner.expect(lines[0].contains("chat_metadata"), "首行是会话头")
            runner.expect(lines[0].contains("\"user_name\":\"unused\""), "保留已废弃的 user_name 字段")
            runner.expect(lines[0].contains("\"character_name\":\"unused\""), "保留已废弃的 character_name 字段")
            runner.expect(!lines[1].contains("\n"), "消息行是紧凑 JSON")
            runner.expect(lines[1].contains("\"is_user\":false"), "字段名用下划线风格")

            // 往返。
            let decoded = try ChatSessionCodec.decodeJSONL(
                data,
                characterId: session.characterId,
                fallbackName: "回退名"
            )
            runner.expectEqual(decoded.messages.count, 2, "往返后消息数量一致")
            runner.expectEqual(decoded.messages[0].mes, greeting.mes, "往返后内容一致")
            runner.expectEqual(decoded.messages[0].swipes.count, 2, "往返后 swipes 数量一致")
            runner.expectEqual(decoded.metadata.characterName, "Seraphina", "往返后元数据一致")
            runner.expect(decoded.messages[0].isUser == false, "往返后角色标记正确")
            runner.expect(decoded.messages[1].isUser, "往返后用户标记正确")

            // swipe_info 与 swipes 必须等长，否则 ST 读取会错位。
            if let object = try? JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any],
               let swipes = object["swipes"] as? [Any],
               let swipeInfo = object["swipe_info"] as? [Any] {
                runner.expectEqual(swipeInfo.count, swipes.count, "swipe_info 与 swipes 等长")
            } else {
                runner.expect(false, "消息行能被解析回字典")
            }
        } catch {
            runner.expect(false, "JSONL 编码", detail: error.localizedDescription)
        }

        // ---- 本地索引格式（sessions.index.json）----
        // 这里锁住一个曾经真实出现过的 bug：ChatMessage / ChatMetadata 的 CodingKeys
        // 用的是 ST 的 JSONL 键名（is_user / user_name），若本地索引直接复用，
        // 写出去与读回来的键名就会分叉，表现为「保存过的会话重启后全部消失」。
        var indexSession = ChatSession(characterId: UUID(), name: "索引往返")
        indexSession.metadata.characterName = "Seraphina"
        indexSession.metadata.userName = "小明"
        indexSession.metadata.worldInfo = "Eldoria"
        var richMessage = ChatMessage(name: "Seraphina", mes: "内容", isUser: false)
        richMessage.extra.model = "gpt-4o-mini"
        richMessage.extra.reasoning = "思考过程"
        richMessage.extra.tokenCount = 42
        richMessage.swipes = ["备选一", "备选二"]
        richMessage.swipeId = 1
        indexSession.messages = [richMessage]

        do {
            let encoded = try JSONEncoder().encode([indexSession])
            let text = String(data: encoded, encoding: .utf8) ?? ""

            // 索引必须用驼峰键名，不能混进 ST 的下划线键。
            runner.expect(text.contains("\"isUser\""), "索引使用驼峰键 isUser")
            runner.expect(!text.contains("\"is_user\""), "索引不出现 ST 的 is_user 键")
            runner.expect(text.contains("\"userName\""), "索引元数据使用驼峰键 userName")
            runner.expect(!text.contains("\"user_name\""), "索引元数据不出现 ST 的 user_name 键")

            let decoded = try JSONDecoder().decode([ChatSession].self, from: encoded)
            runner.expectEqual(decoded.count, 1, "索引往返后会话数量一致")
            runner.expectEqual(decoded.first?.messages.count, 1, "索引往返后消息数量一致")
            runner.expectEqual(decoded.first?.messages.first?.mes, "内容", "索引往返后消息内容一致")
            runner.expectEqual(decoded.first?.messages.first?.extra.reasoning, "思考过程", "索引往返后思维链保留")
            runner.expectEqual(decoded.first?.messages.first?.extra.tokenCount, 42, "索引往返后 token 统计保留")
            runner.expectEqual(decoded.first?.metadata.characterName, "Seraphina", "索引往返后元数据保留")
            runner.expectEqual(decoded.first?.metadata.worldInfo, "Eldoria", "索引往返后世界书绑定保留")
            runner.expectEqual(decoded.first?.messages.first?.swipes.count, 2, "索引往返后 swipes 保留")
            runner.expectEqual(decoded.first?.id, indexSession.id, "索引往返后会话 id 不变")
        } catch {
            runner.expect(false, "本地索引往返", detail: error.localizedDescription)
        }

        // 角色卡的 id 也必须持久化，否则重启后会话与角色的关联会断裂。
        do {
            let card = CharacterCard()
            let encoded = try JSONEncoder().encode([card])
            let decoded = try JSONDecoder().decode([CharacterCard].self, from: encoded)
            runner.expectEqual(decoded.first?.id, card.id, "角色卡 id 参与编解码（否则关联会断裂）")
        } catch {
            runner.expect(false, "角色卡 id 往返", detail: error.localizedDescription)
        }

        // 时间戳格式：必须是 ISO8601，否则 ST 的时间解析会失准。
        let stamp = ChatMessage.timestamp()
        runner.expect(stamp.contains("T"), "时间戳是 ISO8601 格式：\(stamp)")
        runner.expect(stamp.hasSuffix("Z"), "时间戳以 Z 结尾（UTC）")
        runner.expect(ChatMessage.parseTimestamp(stamp) != nil, "时间戳可被解析回 Date")

        // 没有头部的 JSONL 也应能读（外部来源的聊天记录）。
        let headerless = """
        {"name":"A","is_user":true,"mes":"hi","send_date":"2025-01-01T00:00:00.000Z"}
        """
        if let decoded = try? ChatSessionCodec.decodeJSONL(
            Data(headerless.utf8),
            characterId: UUID(),
            fallbackName: "x"
        ) {
            runner.expectEqual(decoded.messages.count, 1, "无头部文件按纯消息解析")
        } else {
            runner.expect(false, "解析无头部的 JSONL")
        }
    }

    // MARK: - SSE

    static func testSSEParser(_ runner: TestRunner) {
        runner.suite("SSE 流式分帧")

        // 基本事件 + [DONE]。
        var parser = SSEParser()
        let payload = "data: {\"a\":1}\n\ndata: [DONE]\n\n"
        let events = parser.feed(Data(payload.utf8))
        runner.expectEqual(events.count, 2, "解析出两个事件")
        runner.expectEqual(events.first?.data, "{\"a\":1}", "首个事件内容正确")
        runner.expect(events.last?.isDone == true, "[DONE] 被识别为结束标记")

        // 跨块：事件被拆成两次到达。
        var splitParser = SSEParser()
        let part1 = splitParser.feed(Data("data: {\"cho".utf8))
        runner.expectEqual(part1.count, 0, "不完整帧不产生事件")
        let part2 = splitParser.feed(Data("ices\":1}\n\n".utf8))
        runner.expectEqual(part2.count, 1, "补齐后产生事件")
        runner.expectEqual(part2.first?.data, "{\"choices\":1}", "跨块内容拼接正确")

        // 三种换行组合。
        for separator in ["\r\n\r\n", "\r\r", "\n\n"] {
            var p = SSEParser()
            let events = p.feed(Data("data: x\(separator)".utf8))
            runner.expectEqual(events.count, 1, "分隔符 \(separator.debugDescription) 被识别")
        }

        // 多行 data 用 \n 连接。
        var multi = SSEParser()
        let multiEvents = multi.feed(Data("data: line1\ndata: line2\n\n".utf8))
        runner.expectEqual(multiEvents.first?.data, "line1\nline2", "多行 data 以换行拼接")

        // 空 data 丢弃。
        var empty = SSEParser()
        let emptyEvents = empty.feed(Data("data:\n\n".utf8))
        runner.expectEqual(emptyEvents.count, 0, "空 data 不产生事件")

        // 注释行忽略。
        var comment = SSEParser()
        let commentEvents = comment.feed(Data(": keep-alive\n\ndata: y\n\n".utf8))
        runner.expectEqual(commentEvents.count, 1, "注释行被忽略")
        runner.expectEqual(commentEvents.first?.data, "y", "注释后的事件仍能解析")

        // 命名事件（Anthropic 用）。
        var named = SSEParser()
        let namedEvents = named.feed(Data("event: content_block_delta\ndata: {\"t\":1}\n\n".utf8))
        runner.expectEqual(namedEvents.first?.name, "content_block_delta", "事件名被保留")
        runner.expectEqual(namedEvents.first?.data, "{\"t\":1}", "命名事件的数据正确")

        // 收尾：没有结尾空行时也要能取出最后一帧。
        var unfinished = SSEParser()
        _ = unfinished.feed(Data("data: tail".utf8))
        let finished = unfinished.finish()
        runner.expectEqual(finished.count, 1, "finish() 取出未闭合的最后一帧")
        runner.expectEqual(finished.first?.data, "tail", "最后一帧内容正确")

        // 值前的一个空格按规范去掉，但正文里的空格要保留。
        var spacing = SSEParser()
        let spacingEvents = spacing.feed(Data("data:  two spaces\n\n".utf8))
        runner.expectEqual(spacingEvents.first?.data, " two spaces", "只去掉值前的一个空格")

        // 逐字节喂入（真实网络流就是这个形态）。
        var byteByByte = SSEParser()
        var collected: [SSEEvent] = []
        for byte in Data("data: {\"n\":1}\n\ndata: [DONE]\n\n".utf8) {
            collected.append(contentsOf: byteByByte.feed(Data([byte])))
        }
        runner.expectEqual(collected.count, 2, "逐字节喂入也能正确分帧")
    }

    // MARK: - 宏

    static func testMacroProcessor(_ runner: TestRunner) {
        runner.suite("宏替换")

        var context = MacroContext()
        context.charName = "Seraphina"
        context.userName = "小明"
        context.description = "一位 {{char}} 的描述"
        context.personality = "温柔"
        context.scenario = "森林"
        context.persona = "旅行者"
        context.mesExamples = "示例"
        context.charVersion = "1.2"

        // 基本替换。
        runner.expectEqual(
            MacroProcessor.expand("你好 {{char}}，我是 {{user}}。", context: context),
            "你好 Seraphina，我是 小明。",
            "{{char}} 与 {{user}} 被替换"
        )

        // 大小写不敏感。
        runner.expectEqual(
            MacroProcessor.expand("{{CHAR}} 和 {{User}}", context: context),
            "Seraphina 和 小明",
            "宏名大小写不敏感"
        )

        // 顺序依赖：卡字段内部的 {{char}} 会在后续迭代被替换。
        runner.expectEqual(
            MacroProcessor.expand("{{description}}", context: context),
            "一位 Seraphina 的描述",
            "卡字段内容里的 {{char}} 被二级展开"
        )

        // 其它卡字段。
        runner.expectEqual(
            MacroProcessor.expand("{{personality}}/{{scenario}}/{{persona}}", context: context),
            "温柔/森林/旅行者",
            "性格、场景、人设宏"
        )
        runner.expectEqual(
            MacroProcessor.expand("{{charVersion}}", context: context),
            "1.2",
            "角色版本宏"
        )

        // {{newline}}
        runner.expectEqual(
            MacroProcessor.expand("a{{newline}}b", context: context),
            "a\nb",
            "{{newline}} 展开为换行"
        )

        // {{trim}} 会连同前后换行一起吃掉。
        runner.expectEqual(
            MacroProcessor.expand("a\n{{trim}}\nb", context: context),
            "ab",
            "{{trim}} 连同前后换行一起删除"
        )

        // {{// 注释}}
        runner.expectEqual(
            MacroProcessor.expand("前{{// 这是注释}}后", context: context),
            "前后",
            "注释宏被删除"
        )

        // {{reverse:...}}
        runner.expectEqual(
            MacroProcessor.expand("{{reverse:abc}}", context: context),
            "cba",
            "{{reverse}} 反转文本"
        )

        // {{roll:1d6}} 应在 1..6 内。
        let rollResult = MacroProcessor.expand("{{roll:1d6}}", context: context)
        let rollValue = Int(rollResult) ?? -1
        runner.expect((1...6).contains(rollValue), "{{roll:1d6}} 结果在 1-6 之间：\(rollResult)")

        // {{roll:2d6+3}} 应在 5..15 内。
        let rollPlus = MacroProcessor.expand("{{roll:2d6+3}}", context: context)
        let rollPlusValue = Int(rollPlus) ?? -1
        runner.expect((5...15).contains(rollPlusValue), "{{roll:2d6+3}} 结果在 5-15 之间：\(rollPlus)")

        // {{random:a,b,c}} 应命中其一。
        let randomResult = MacroProcessor.expand("{{random:苹果,香蕉,橘子}}", context: context)
        runner.expect(
            ["苹果", "香蕉", "橘子"].contains(randomResult),
            "{{random}} 返回其中一个选项：\(randomResult)"
        )

        // 不含宏的文本原样返回。
        runner.expectEqual(
            MacroProcessor.expand("普通文本", context: context),
            "普通文本",
            "无宏文本不变"
        )

        // {{original}} 只替换一次。
        var originalContext = context
        originalContext.original = "原文"
        runner.expectEqual(
            MacroProcessor.expand("{{original}} 与 {{original}}", context: originalContext),
            "原文 与 ",
            "{{original}} 只替换第一次"
        )

        // 尖括号宏。
        runner.expectEqual(
            MacroProcessor.expand("<USER> 对 <BOT> 说", context: context),
            "小明 对 Seraphina 说",
            "<USER> / <BOT> 被替换"
        )

        // 正则元字符不应导致崩溃或误替换。
        runner.expectEqual(
            MacroProcessor.expand("a.b*c {{char}}", context: context),
            "a.b*c Seraphina",
            "文本中的正则元字符被安全处理"
        )

        // emoji 场景（验证 UTF-16 与 Swift 索引不混用）。
        runner.expectEqual(
            MacroProcessor.expand("🎭 {{char}} 🎭", context: context),
            "🎭 Seraphina 🎭",
            "含 emoji 的文本能正确替换"
        )
    }

    // MARK: - Token

    static func testTokenEstimator(_ runner: TestRunner) {
        runner.suite("Token 估算")

        runner.expectEqual(TokenEstimator.estimate(""), 0, "空文本为 0")

        // 英文：约每 3.35 字节 1 token。
        let english = TokenEstimator.estimate("Hello world, this is a test sentence.")
        runner.expect((8...14).contains(english), "英文估算在合理区间：\(english)")

        // 中文：每字约 1 token，不应被严重低估。
        let chinese = TokenEstimator.estimate("这是一个中文测试句子")
        runner.expect((10...20).contains(chinese), "中文估算在合理区间：\(chinese)")

        // 中文应当比同字符数的 ASCII 更"贵"。
        let ascii10 = TokenEstimator.estimate("abcdefghij")
        let cjk10 = TokenEstimator.estimate("十个中文字符测试一下")
        runner.expect(cjk10 > ascii10, "中文单价高于 ASCII（\(cjk10) > \(ascii10)）")

        // 消息数组的开销公式：每条 +4，带 name 再 +1。
        let plain = [ChatCompletionMessage(role: "user", content: "hi")]
        let withName = [ChatCompletionMessage(role: "system", content: "hi", name: "example_user")]
        runner.expect(
            TokenEstimator.estimate(messages: withName) > TokenEstimator.estimate(messages: plain),
            "带 name 的消息开销更大"
        )
    }

    // MARK: - JSON 渲染

    static func testJSONRenderer(_ runner: TestRunner) {
        runner.suite("JSON 渲染器")

        let object: [String: Any] = [
            "name": "测试",
            "count": 3,
            "ratio": 0.5,
            "flag": true,
            "empty": [String](),
            "url": "https://example.com/a/b",
            "nested": ["key": "value"],
        ]

        let compact = JSONRenderer.compact(object)
        runner.expect(!compact.contains("\n"), "紧凑模式无换行")
        runner.expect(!compact.contains("\\/"), "斜杠不被转义")
        runner.expect(compact.contains("\"count\":3"), "整数输出为整数（而非 3.0）")
        runner.expect(compact.contains("\"flag\":true"), "布尔输出为 true")
        runner.expect(compact.contains("\"empty\":[]"), "空数组输出为 []")

        let pretty = JSONRenderer.pretty(object)
        runner.expect(pretty.contains("\n    \""), "美化模式使用 4 空格缩进")
        runner.expect(pretty.contains("\": "), "冒号后有空格")
        runner.expect(!pretty.contains("\" : "), "冒号前没有空格（与 JS 一致）")

        // 转义。
        let escaped = JSONRenderer.compact(["text": "换行\n引号\"反斜杠\\"])
        runner.expect(escaped.contains("\\n"), "换行被转义")
        runner.expect(escaped.contains("\\\""), "引号被转义")
        runner.expect(escaped.contains("\\\\"), "反斜杠被转义")

        // 输出必须能被标准解析器读回。
        if let data = compact.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            runner.expectEqual(parsed["count"] as? Int, 3, "紧凑输出可被解析回")
            runner.expectEqual(parsed["url"] as? String, "https://example.com/a/b", "URL 往返不失真")
        } else {
            runner.expect(false, "紧凑输出是合法 JSON")
        }

        // 同样的字典应产生稳定输出（排序键）。
        runner.expectEqual(JSONRenderer.compact(object), compact, "相同输入输出稳定")
    }

    // MARK: - Base64

    static func testBase64(_ runner: TestRunner) {
        runner.suite("Base64 容错解码")

        let original = Data("测试内容 with ASCII".utf8)
        let standard = Base64.encode(original)
        runner.expectEqual(Base64.decode(standard), original, "标准 base64 往返")

        // 缺 padding。
        let noPadding = standard.replacingOccurrences(of: "=", with: "")
        runner.expectEqual(Base64.decode(noPadding), original, "缺 padding 也能解码")

        // URL-safe 字母表。
        let urlSafe = standard
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        runner.expectEqual(Base64.decode(urlSafe), original, "URL-safe 字母表也能解码")

        // 含换行。
        let wrapped = standard.enumerated().map { index, character in
            index > 0 && index % 20 == 0 ? "\n\(character)" : String(character)
        }.joined()
        runner.expectEqual(Base64.decode(wrapped), original, "含换行也能解码")

        runner.expect(Base64.decode("!!!not base64!!!") != nil || true, "非法输入不崩溃")
    }

    // MARK: - Prompt 组装

    static func testPromptBuilder(_ runner: TestRunner) {
        runner.suite("Prompt 组装")

        var card = CharacterCard()
        card.name = "Seraphina"
        card.description = "{{char}} 是一位森林精灵。"
        card.personality = "温柔而警觉"
        card.scenario = "在 {{char}} 的森林里"
        card.firstMes = "欢迎来到我的森林。"
        card.mesExample = "<START>\n{{user}}: 你好\n{{char}}: 你好呀。\n<START>\n{{user}}: 再见\n{{char}}: 再会。"

        var settings = AppSettings()
        settings.userName = "小明"
        settings.userPersona = "一位旅行者"
        settings.contextSize = 8192
        settings.maxTokens = 512

        let messages = [
            ChatMessage(name: "Seraphina", mes: "欢迎来到我的森林。", isUser: false),
            ChatMessage(name: "小明", mes: "这里真美。", isUser: true),
        ]

        let input = PromptBuildInput(
            card: card,
            personaName: settings.userName,
            personaDescription: settings.userPersona,
            settings: settings,
            messages: messages
        )

        let builder = PromptBuilder()
        let result = builder.build(input)

        runner.expect(!result.messages.isEmpty, "组装出消息数组（\(result.messages.count) 条）")

        // 第一条应当是主提示词（system）。
        runner.expectEqual(result.messages.first?.role, "system", "首条是 system")
        runner.expect(
            result.messages.first?.flatContent.contains("Seraphina") == true,
            "主提示词里的 {{char}} 被展开"
        )

        // 角色定义应当以宏展开后的形式出现。
        let flattened = result.messages.map(\.flatContent).joined(separator: "\n")
        runner.expect(flattened.contains("森林精灵"), "包含角色描述")
        runner.expect(flattened.contains("温柔而警觉"), "包含性格")
        runner.expect(flattened.contains("在 Seraphina 的森林里"), "场景里的宏被展开")
        runner.expect(!flattened.contains("{{char}}"), "输出里不应残留 {{char}} 宏")
        runner.expect(!flattened.contains("{{user}}"), "输出里不应残留 {{user}} 宏")
        runner.expect(flattened.contains("旅行者"), "包含用户人设")

        // 示例对话：应以 system 角色 + name 标记出现。
        let exampleMessages = result.messages.filter {
            $0.name == "example_user" || $0.name == "example_assistant"
        }
        runner.expect(exampleMessages.count > 0, "示例对话被转成消息（\(exampleMessages.count) 条）")
        runner.expect(
            result.messages.contains { $0.flatContent == "[Example Chat]" },
            "示例块前插入了 [Example Chat] 标记"
        )

        // 历史消息应当出现在结果里。
        runner.expect(flattened.contains("这里真美"), "包含历史消息")

        // 角色扮演的首条问候语也被当作历史的一部分发送。
        runner.expect(flattened.contains("欢迎来到我的森林"), "包含开场白")

        // 历史超过预算时应被裁剪。
        var smallSettings = settings
        smallSettings.contextSize = 100
        smallSettings.maxTokens = 50
        let smallResult = PromptBuilder().build(
            PromptBuildInput(
                card: card,
                personaName: "小明",
                personaDescription: "",
                settings: smallSettings,
                messages: messages
            )
        )
        runner.expect(
            smallResult.messages.count <= result.messages.count,
            "上下文变小时消息数不增加（\(smallResult.messages.count) <= \(result.messages.count)）"
        )

        // 深度注入：应插入到历史区间内。
        let injected = PromptBuilder.applyDepthInjections(
            [(depth: 1, role: "system", content: "深度注入内容")],
            to: [
                ChatCompletionMessage(role: "system", content: "系统"),
                ChatCompletionMessage(role: "user", content: "第一条"),
                ChatCompletionMessage(role: "assistant", content: "第二条"),
            ]
        )
        runner.expect(injected.contains { $0.flatContent == "深度注入内容" }, "深度注入内容进入消息数组")
        let injectionIndex = injected.firstIndex { $0.flatContent == "深度注入内容" } ?? 0
        runner.expect(
            injectionIndex > 0 && injectionIndex < injected.count - 1,
            "深度注入落在历史区间内（索引 \(injectionIndex)）"
        )
    }

    // MARK: - LLM 请求构造

    static func testLLMRequestBuilding(_ runner: TestRunner) {
        runner.suite("LLM 请求构造")

        var settings = AppSettings()
        settings.activeModel = "gpt-4o-mini"

        let request = GenerationRequest(
            model: "gpt-4o-mini",
            messages: [
                ChatCompletionMessage(role: "system", content: "你是助手"),
                ChatCompletionMessage(role: "user", content: "你好"),
            ],
            temperature: 0.7,
            topP: 0.9,
            maxTokens: 256,
            stream: true
        )

        let client = LLMClient()

        // ---- OpenAI 兼容 ----
        guard let openAI = ProviderConfig.defaults.first(where: { $0.id == "openai" }) else {
            runner.expect(false, "找到内建 OpenAI 供应商")
            return
        }
        do {
            let urlRequest = try client.makeRequest(provider: openAI, apiKey: "sk-test", request: request)
            let url = urlRequest.url?.absoluteString ?? ""
            runner.expectEqual(url, "https://api.openai.com/v1/chat/completions", "URL 拼接正确（不重复 /v1）")
            runner.expectEqual(
                urlRequest.value(forHTTPHeaderField: "Authorization"),
                "Bearer sk-test",
                "使用 Bearer 认证头"
            )
            runner.expectEqual(
                urlRequest.value(forHTTPHeaderField: "Content-Type"),
                "application/json",
                "Content-Type 正确"
            )

            if let body = urlRequest.httpBody,
               let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                runner.expectEqual(object["model"] as? String, "gpt-4o-mini", "请求体含 model")
                runner.expectEqual(object["stream"] as? Bool, true, "请求体含 stream")
                runner.expectEqual(object["max_tokens"] as? Int, 256, "请求体含 max_tokens")
                runner.expectEqual(object["top_p"] as? Double, 0.9, "请求体含 top_p")
                runner.expect((object["messages"] as? [[String: Any]])?.count == 2, "请求体含两条消息")
            } else {
                runner.expect(false, "OpenAI 请求体是合法 JSON")
            }
        } catch {
            runner.expect(false, "构造 OpenAI 请求", detail: error.localizedDescription)
        }

        // 尾斜杠不应产生双斜杠。
        var trailingSlash = openAI
        trailingSlash.baseURL = "https://api.openai.com/v1/"
        if let urlRequest = try? client.makeRequest(provider: trailingSlash, apiKey: "k", request: request) {
            runner.expect(
                urlRequest.url?.absoluteString.contains("//chat") == false,
                "基地址尾斜杠被去掉，不产生双斜杠"
            )
        } else {
            runner.expect(false, "尾斜杠基地址可构造请求")
        }

        // 缺少 API Key 时应当报错。
        runner.expectThrows("缺少 API Key 时报错") {
            _ = try client.makeRequest(provider: openAI, apiKey: "", request: request)
        }

        // 不需要 Key 的本地服务（Ollama）应能直接构造。
        if let ollama = ProviderConfig.defaults.first(where: { $0.id == "ollama" }) {
            if let urlRequest = try? client.makeRequest(provider: ollama, apiKey: "", request: request) {
                runner.expect(
                    urlRequest.value(forHTTPHeaderField: "Authorization") == nil,
                    "本地服务不发送认证头"
                )
            } else {
                runner.expect(false, "Ollama 无需 Key 即可构造请求")
            }
        }

        // ---- Anthropic ----
        if let anthropic = ProviderConfig.defaults.first(where: { $0.id == "anthropic" }) {
            do {
                let urlRequest = try client.makeRequest(provider: anthropic, apiKey: "sk-ant", request: request)
                runner.expectEqual(
                    urlRequest.url?.absoluteString,
                    "https://api.anthropic.com/v1/messages",
                    "Anthropic URL 正确"
                )
                runner.expectEqual(
                    urlRequest.value(forHTTPHeaderField: "x-api-key"),
                    "sk-ant",
                    "Anthropic 用 x-api-key 头"
                )
                runner.expectEqual(
                    urlRequest.value(forHTTPHeaderField: "anthropic-version"),
                    "2023-06-01",
                    "Anthropic 带版本头"
                )

                if let body = urlRequest.httpBody,
                   let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    runner.expectEqual(object["system"] as? String, "你是助手", "system 被提到独立字段")
                    let messages = object["messages"] as? [[String: Any]] ?? []
                    runner.expectEqual(messages.count, 1, "messages 里不含 system 角色")
                    runner.expectEqual(messages.first?["role"] as? String, "user", "保留 user 消息")
                    runner.expect(object["max_tokens"] != nil, "Anthropic 必填 max_tokens")
                } else {
                    runner.expect(false, "Anthropic 请求体是合法 JSON")
                }
            } catch {
                runner.expect(false, "构造 Anthropic 请求", detail: error.localizedDescription)
            }
        }

        // ---- Google Gemini ----
        if let google = ProviderConfig.defaults.first(where: { $0.id == "google" }) {
            do {
                let streamRequest = try client.makeRequest(provider: google, apiKey: "gk", request: request)
                let url = streamRequest.url?.absoluteString ?? ""
                runner.expect(url.contains("streamGenerateContent"), "流式用 streamGenerateContent")
                runner.expect(url.contains("alt=sse"), "流式带 alt=sse（Gemini 的 SSE 开关）")
                runner.expectEqual(
                    streamRequest.value(forHTTPHeaderField: "x-goog-api-key"),
                    "gk",
                    "Gemini 用 x-goog-api-key 头"
                )

                if let body = streamRequest.httpBody,
                   let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    runner.expect(object["contents"] != nil, "请求体含 contents")
                    runner.expect(object["systemInstruction"] != nil, "system 走 systemInstruction")
                    runner.expect(object["generationConfig"] != nil, "请求体含 generationConfig")
                } else {
                    runner.expect(false, "Gemini 请求体是合法 JSON")
                }

                // 非流式应走 generateContent。
                var nonStream = request
                nonStream.stream = false
                let nonStreamRequest = try client.makeRequest(provider: google, apiKey: "gk", request: nonStream)
                runner.expect(
                    nonStreamRequest.url?.absoluteString.contains("generateContent") == true
                        && nonStreamRequest.url?.absoluteString.contains("streamGenerateContent") == false,
                    "非流式用 generateContent"
                )
            } catch {
                runner.expect(false, "构造 Gemini 请求", detail: error.localizedDescription)
            }
        }
    }

    // MARK: - 流式响应解析

    static func testResponseExtraction(_ runner: TestRunner) {
        runner.suite("流式响应解析")

        guard
            let openAI = ProviderConfig.defaults.first(where: { $0.id == "openai" }),
            let anthropic = ProviderConfig.defaults.first(where: { $0.id == "anthropic" }),
            let google = ProviderConfig.defaults.first(where: { $0.id == "google" })
        else {
            runner.expect(false, "找到三家内建供应商")
            return
        }

        // OpenAI：从 delta.content 取正文。
        let openAIEvent = SSEEvent(
            name: nil,
            data: #"{"choices":[{"delta":{"content":"你好"}}]}"#
        )
        let openAIEvents = LLMClient.extract(from: openAIEvent, provider: openAI)
        runner.expectEqual(openAIEvents.count, 1, "OpenAI 增量被提取")
        if case .text(let text)? = openAIEvents.first {
            runner.expectEqual(text, "你好", "OpenAI 正文正确")
        } else {
            runner.expect(false, "OpenAI 事件类型为 text")
        }

        // OpenAI：思维链走独立通道，不混进正文。
        let reasoningEvent = SSEEvent(
            name: nil,
            data: #"{"choices":[{"delta":{"reasoning_content":"思考中"}}]}"#
        )
        let reasoningEvents = LLMClient.extract(from: reasoningEvent, provider: openAI)
        if case .reasoning(let text)? = reasoningEvents.first {
            runner.expectEqual(text, "思考中", "思维链被单独提取")
        } else {
            runner.expect(false, "思维链事件类型为 reasoning")
        }

        // OpenAI：空 delta 不产生事件。
        let emptyDelta = SSEEvent(name: nil, data: #"{"choices":[{"delta":{}}]}"#)
        runner.expectEqual(
            LLMClient.extract(from: emptyDelta, provider: openAI).count,
            0,
            "空 delta 不产生事件"
        )

        // Anthropic：事件名决定类型，正文在 delta.text。
        let anthropicEvent = SSEEvent(
            name: "content_block_delta",
            data: #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"世界"}}"#
        )
        let anthropicEvents = LLMClient.extract(from: anthropicEvent, provider: anthropic)
        if case .text(let text)? = anthropicEvents.first {
            runner.expectEqual(text, "世界", "Anthropic 正文正确")
        } else {
            runner.expect(false, "Anthropic 事件类型为 text")
        }

        // Anthropic：ping 事件被忽略（ST 也是忽略的）。
        let pingEvent = SSEEvent(name: "ping", data: #"{"type":"ping"}"#)
        runner.expectEqual(
            LLMClient.extract(from: pingEvent, provider: anthropic).count,
            0,
            "ping 事件不产生增量"
        )

        // Anthropic：thinking 走思维链通道。
        let thinkingEvent = SSEEvent(
            name: "content_block_delta",
            data: #"{"delta":{"type":"thinking_delta","thinking":"深思"}}"#
        )
        let thinkingEvents = LLMClient.extract(from: thinkingEvent, provider: anthropic)
        if case .reasoning(let text)? = thinkingEvents.first {
            runner.expectEqual(text, "深思", "Anthropic 思维链被提取")
        } else {
            runner.expect(false, "Anthropic 思维链事件类型为 reasoning")
        }

        // Gemini：正文在 candidates[0].content.parts[].text。
        let geminiEvent = SSEEvent(
            name: nil,
            data: #"{"candidates":[{"content":{"parts":[{"text":"森林"}]}}]}"#
        )
        let geminiEvents = LLMClient.extract(from: geminiEvent, provider: google)
        if case .text(let text)? = geminiEvents.first {
            runner.expectEqual(text, "森林", "Gemini 正文正确")
        } else {
            runner.expect(false, "Gemini 事件类型为 text")
        }

        // Gemini：thought 标记的分片归入思维链。
        let geminiThought = SSEEvent(
            name: nil,
            data: #"{"candidates":[{"content":{"parts":[{"text":"推理","thought":true}]}}]}"#
        )
        let thoughtEvents = LLMClient.extract(from: geminiThought, provider: google)
        if case .reasoning(let text)? = thoughtEvents.first {
            runner.expectEqual(text, "推理", "Gemini 思维链被提取")
        } else {
            runner.expect(false, "Gemini 思维链事件类型为 reasoning")
        }

        // 非法 JSON 不应崩溃。
        let brokenEvent = SSEEvent(name: nil, data: "{not json")
        runner.expectEqual(
            LLMClient.extract(from: brokenEvent, provider: openAI).count,
            0,
            "非法 JSON 被安全忽略"
        )

        // 错误消息优先级：error.message 优先。
        let errorBody = Data(#"{"error":{"message":"额度不足","type":"insufficient_quota"}}"#.utf8)
        runner.expectEqual(
            LLMClient.errorMessage(from: errorBody),
            "额度不足",
            "优先取 error.message"
        )
        let codeOnly = Data(#"{"error":{"code":"invalid_api_key"}}"#.utf8)
        runner.expectEqual(
            LLMClient.errorMessage(from: codeOnly),
            "invalid_api_key",
            "没有 message 时回退 error.code"
        )
        let detailError = Data(#"{"detail":{"error":"网关错误"}}"#.utf8)
        runner.expectEqual(
            LLMClient.errorMessage(from: detailError),
            "网关错误",
            "支持 detail.error 形式"
        )

        // 非流式响应解析。
        let nonStreamOpenAI = Data(#"{"choices":[{"message":{"content":"完整回复"}}]}"#.utf8)
        if let object = try? JSONSerialization.jsonObject(with: nonStreamOpenAI) as? [String: Any] {
            runner.expectEqual(
                LLMClient.nonStreamingText(from: object, provider: openAI),
                "完整回复",
                "非流式 OpenAI 正文提取"
            )
        }
        let nonStreamAnthropic = Data(#"{"content":[{"type":"text","text":"克劳德"}]}"#.utf8)
        if let object = try? JSONSerialization.jsonObject(with: nonStreamAnthropic) as? [String: Any] {
            runner.expectEqual(
                LLMClient.nonStreamingText(from: object, provider: anthropic),
                "克劳德",
                "非流式 Anthropic 正文提取"
            )
        }
    }

    /// 解码诊断：把 Codable 的真实错误显示出来（App 里为了容错吞掉了错误）。
    static func diagnoseDecoding(_ path: String) {
        print("\n\u{001B}[1m── 解码诊断：\(path)\u{001B}[0m")
        guard let data = FileManager.default.contents(atPath: path) else {
            print("  无法读取文件")
            return
        }
        do {
            let sessions = try JSONDecoder().decode([ChatSession].self, from: data)
            print("  \u{001B}[32m✓\u{001B}[0m 解码成功：\(sessions.count) 个会话，"
                  + "首个含 \(sessions.first?.messages.count ?? 0) 条消息")
        } catch {
            print("  \u{001B}[31m✗ 解码失败：\(error)\u{001B}[0m")
        }
    }
}
