# Swift 实现规格：角色卡 PNG/JSON、character_book、JSONL

> **本文定位**：可照着写代码的实现规格（不是研究文档）。每一条都给出 Swift 类型签名、编号算法步骤、边界容错、兼容性约束、以及「易错点」。
> **上游依据**：`docs/ios-research/01-character-card-spec.md`（引用格式 `01#1.2`）、`docs/ios-research/04-local-data-and-settings.md`（引用格式 `04#2.4`）。
> **源码复核**：所有字节级结论都在本仓库 `src/character-card-parser.js`、`src/png/encode.js`、`src/endpoints/characters.js`、`src/endpoints/chats.js`、`public/scripts/world-info.js`、`node_modules/png-chunk-text/*`、`node_modules/png-chunks-extract/index.js` 上复核过；引用格式 `src/endpoints/characters.js:565`。
> **语言/平台**：Swift 5（`-swift-version 5`）、iOS 18、Foundation + UIKit，**不引入任何第三方库**，不使用 Swift 6 严格并发（不写 `@Sendable`/`actor` 隔离，`enum` 命名空间 + `static func` 即可）。

---

## 目录

- [0. 全局约定与模块总览](#0-全局约定与模块总览)
- [1. 模块 A：PNG 解析器](#1-模块-apng-解析器)
- [2. 模块 B：PNG 写入器](#2-模块-bpng-写入器)
- [3. 模块 C：角色卡导入归一化](#3-模块-c角色卡导入归一化)
- [4. 模块 D：character_book ↔ WorldInfoEntry 映射](#4-模块-dcharacter_book--worldinfoentry-映射)
- [5. 模块 E：导出（JSON / PNG）](#5-模块-e导出json--png)
- [6. 模块 F：头像存储与文件名规则](#6-模块-f头像存储与文件名规则)
- [7. 模块 G：JSONL 聊天记录读写](#7-模块-gjsonl-聊天记录读写)
- [8. 模块 H：单元测试清单](#8-模块-h单元测试清单)
- [附录 A：现有 Swift 代码必须修改的点](#附录-a现有-swift-代码必须修改的点)
- [附录 B：常量速查](#附录-b常量速查)
- [附录 C：来源索引](#附录-c来源索引)

---

## 0. 全局约定与模块总览

### 0.1 文件与类型组织

```
ios/SillyTavern/
  Models/
    JSONValue.swift              既有，微调（见 A-6）
    CharacterCard.swift          重写（模块 C）
    CharacterBook.swift          新增（模块 D）
    WorldInfoEntry.swift         重写（模块 D）
    ChatMessage.swift            重写（模块 G）
    ChatMetadata.swift           新增（模块 G）
  Services/
    PNG/PNGChunk.swift           新增（模块 A）
    PNG/PNGReader.swift          新增（模块 A）
    PNG/PNGWriter.swift          新增（模块 B）
    PNG/CRC32.swift              新增（模块 A/B）
    CharacterCardImporter.swift  新增（模块 C）
    CharacterExporter.swift       新增（模块 E）
    CharacterBookConversion.swift 新增（模块 D）
    ChatJSONL.swift              新增（模块 G）
    FileNameSanitizer.swift      新增（模块 F）
    LocalStorage.swift           既有，改造（模块 F）
```

### 0.2 三条贯穿全篇的硬约束

| # | 约束 | 依据 |
|---|---|---|
| **H1** | **原始 PNG 字节必须始终保留**。角色卡的数据与头像在同一个文件里，没有任何独立 JSON 文件。任何「为了显示头像而重新 `pngData()`」的行为都会丢掉 `tEXt` chunk。 | `01#7.1`、`04#3.3` |
| **H2** | **未知键一律透传**。ST 的写入路径以「原始 JSON 解析结果」为基底再覆盖已知字段（`char = tryParse(data.json_data) || {}`），因此陌生扩展键永远不丢。Swift 侧用 `rawRoot: [String: JSONValue]` 承载，导出时以它为基底。 | `01#4.2` `src/endpoints/characters.js:567` |
| **H3** | **读宽容、写严格**。读取时容忍 CRC 错误 / 截断 / 缺字段；写入时必须产出正确 CRC、正确大端长度、与 ST 完全一致的 chunk 顺序。 | `01#1.6` |

### 0.3 模块依赖

```
A(PNG 读) ──► C(导入归一化) ──► D(character_book) ──► E(导出)
B(PNG 写) ◄──────────────────────────────────────────┘
F(头像/文件名) ──► C、E
G(JSONL) 独立，只复用 C 的 JSONValue / Sanitizer
```

### 0.4 命名约定

- Swift 属性用 camelCase，与 ST 的 snake_case 字段通过显式 `CodingKeys` 或手写映射函数转换；**不要**依赖 `JSONDecoder` 的 `convertFromSnakeCase`（它会把 `keysecondary`、`useProbability`、`selectiveLogic` 这类 ST 专有的「混合大小写」键弄错）。
- 类型里凡是「ST 内部形状」的字段名保持 ST 原样（如 `WorldInfoEntry.keysecondary`、`selectiveLogic`），凡是「规范形状」的用规范名（如 `CharacterBookEntry.secondaryKeys` 映射 `secondary_keys`）。两种形状**必须是两个类型**（`04#4.3` 明确警告不能混用）。

---

## 1. 模块 A：PNG 解析器

### 1.1 需要的 Swift 类型

```swift
import Foundation

// MARK: - 常量

enum PNGConstant {
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    /// PNG 规范：单个 chunk 的 length 字段最大 2^31-1
    static let maxChunkLength: UInt32 = 0x7FFF_FFFF
    /// tEXt keyword 长度上限（严格小于 80）
    static let maxKeywordLength = 80
    /// 角色数据关键字
    static let v2Keyword = "chara"
    static let v3Keyword = "ccv3"
}

// MARK: - Chunk

struct PNGChunk: Equatable {
    /// 4 字节 ASCII 类型名，如 "IHDR" / "tEXt" / "IEND"
    let name: String
    /// 载荷（不含 length / type / crc）
    let data: Data
    /// 文件里存的 CRC（大端读出的 UInt32）
    let storedCRC: UInt32
    /// 本地重算的 CRC（覆盖 type + data）
    let computedCRC: UInt32
    /// 仅供调试：该 chunk 在原始字节里的起始偏移
    let offset: Int

    var crcMatches: Bool { storedCRC == computedCRC }
}

// MARK: - 解析结果

struct PNGImage: Equatable {
    /// ★ 原始完整字节：头像显示、导出、无损回写都要用它（H1）
    let raw: Data
    let chunks: [PNGChunk]
    /// 解析过程中被容忍的问题（CRC 不符、被截断的 tEXt 等）
    let warnings: [PNGWarning]

    var textChunks: [PNGTextChunk] { PNGReader.decodeAllTextChunks(chunks) }
}

struct PNGTextChunk: Equatable {
    let keyword: String   // Latin-1 解码
    let text: String      // Latin-1 解码
    let chunkIndex: Int
    /// 来源：.text（tEXt）/ .international（iTXt）
    let origin: PNGTextOrigin
}

enum PNGTextOrigin: Equatable { case text, international }

// MARK: - 错误与策略

enum PNGParseError: Error, Equatable {
    case emptyInput
    case invalidSignature(actual: [UInt8])
    case truncated(atOffset: Int, needed: Int, available: Int)
    case firstChunkIsNotIHDR(found: String)
    case invalidChunkType(bytes: [UInt8], atOffset: Int)
    case chunkTooLarge(length: UInt32, atOffset: Int)
    case missingIEND
    case iendNotEmpty(length: UInt32)
    case crcMismatch(chunk: String, index: Int, stored: UInt32, computed: UInt32)  // 仅 .strict 抛
}

enum PNGCardError: Error, Equatable {
    case noTextChunks                 // 对应 ST 的 'No PNG metadata.'（无任何 tEXt）
    case noCharacterData              // 有 tEXt 但没有 chara/ccv3（同样报 'No PNG metadata.'）
    case invalidNullInText(keyword: String)   // 仅 .strictST：text 区域出现第二个 0x00
    case invalidBase64(chunk: String)
    case invalidUTF8(chunk: String)
    case invalidJSON(chunk: String, underlying: String)
}

/// CRC 校验策略
enum PNGCRCValidation: Equatable {
    /// 完全复刻 png-chunks-extract：任一 chunk CRC 不符即失败（`01#1.6`）
    case strict
    /// 推荐默认：标记 warning 后继续；写入时全部重算 CRC（顺带修复）
    case lenient
}

/// tEXt 内容里出现第二个 0x00 时的策略
enum PNGTextStrictness: Equatable {
    /// 复刻 png-chunk-text/decode.js:25 → 抛 'Invalid NULL character found'
    case strictST
    /// 推荐默认：在第一个 0x00 处截断并记 warning
    case lenient
}

// MARK: - 读取入口

struct PNGReadOptions {
    var crc: PNGCRCValidation = .lenient
    var textStrictness: PNGTextStrictness = .lenient
    /// 超集：ST 完全不支持 iTXt（`01#1.3`、`01` 附录 1），这里默认开，但优先级低于 tEXt
    var allowsITXt = true
    /// ST 不支持 zTXt，且需要 zlib；默认关闭
    var allowsZTXt = false

    /// 逐字节复刻 ST 1.19.0 的读取行为（用于「ST 等价」单元测试）
    static let stCompatible = PNGReadOptions(
        crc: .strict, textStrictness: .strictST, allowsITXt: false, allowsZTXt: false)
}

enum PNGWarning: Equatable {
    case crcMismatch(chunk: String, index: Int)
    case nullInTextContent(keyword: String, at: Int)
    case trailingBytesAfterIEND(count: Int)
    case unknownChunkType(String)
    case iTXtCompressed(keyword: String)   // iTXt 带压缩标志，我们不解压
}

enum PNGReader {

    // MARK: 主入口

    /// 遍历 PNG chunk。只读，绝不修改输入。
    static func parse(_ data: Data, options: PNGReadOptions = .init()) throws -> PNGImage

    /// 等价于 ST 的 `read(image)`：返回角色卡 JSON 字符串（未解析）
    static func readCharacterJSON(from data: Data,
                                  options: PNGReadOptions = .init()) throws -> String

    /// 变体：同时拿到原始字节（头像显示要用）
    static func readCharacterCardPNG(from data: Data,
                                     options: PNGReadOptions = .init())
        throws -> (json: String, image: PNGImage)

    // MARK: 子步骤（全部 pure，便于单测）

    /// 解码单个 tEXt chunk 的载荷（keyword + 0x00 + text，Latin-1）
    static func decodeTextChunk(_ payload: Data,
                                at index: Int,
                                strictness: PNGTextStrictness = .lenient)
        throws -> (chunk: PNGTextChunk, warnings: [PNGWarning])

    /// 解码 iTXt（仅未压缩）。压缩的返回 nil。
    static func decodeITXtChunk(_ payload: Data, at index: Int) -> PNGTextChunk?

    /// 在所有 tEXt（可选含 iTXt）里按 ST 优先级挑出角色数据
    static func pickCharacterJSON(from chunks: [PNGTextChunk],
                                  allowsITXt: Bool) throws -> (json: String, keyword: String)

    static func decodeAllTextChunks(_ chunks: [PNGChunk]) -> [PNGTextChunk]
}
```

### 1.2 `parse(_:options:)` 算法步骤

对应 `node_modules/png-chunks-extract/index.js:12-101`。

1. `guard !data.isEmpty else { throw .emptyInput }`
2. `guard data.count >= 8 else { throw .truncated(atOffset: 0, needed: 8, available: data.count) }`
3. 逐字节比对 8 字节签名 `89 50 4E 47 0D 0A 1A 0A`；不符 → `.invalidSignature(actual: Array(data.prefix(8)))`。
   （ST 对第 5/6/8 字节额外提示「可能是 DOS→Unix 换行转换」，我们只在错误描述里带上，不做特殊处理。）
4. `var offset = 8`；`var chunks: [PNGChunk] = []`；`var warnings: [PNGWarning] = []`
5. `while offset < data.count`：
   1. 剩余不足 8 字节 → `.truncated(atOffset: offset, needed: 8, available: data.count - offset)`
   2. `length = readUInt32BE(data, offset)`；`offset += 4`
   3. `typeBytes = data[offset ..< offset+4]`；`offset += 4`
   4. 类型名必须是 4 个 `A-Za-z` 字节（PNG 规范）。否则记 `.unknownChunkType` warning（宽容）或抛 `.invalidChunkType`（严格）。
   5. `length > PNGConstant.maxChunkLength` → `.chunkTooLarge`
   6. 剩余不足 `Int(length) + 4` → `.truncated(atOffset: offset, needed: Int(length)+4, available: data.count - offset)`
   7. `payload = data[offset ..< offset+Int(length)]`；`offset += Int(length)`
   8. `storedCRC = readUInt32BE(data, offset)`；`offset += 4`
   9. `computedCRC = CRC32.chunk(type: name, data: payload)`（见 §2.4）
   10. `if storedCRC != computedCRC`：`.strict` → 抛 `.crcMismatch`；`.lenient` → 追加 warning，继续
   11. `if chunks.isEmpty && name != "IHDR"` → `.firstChunkIsNotIHDR(found: name)`
   12. `chunks.append(PNGChunk(...))`
   13. `if name == "IEND"`：
       - `guard length == 0 else { throw .iendNotEmpty(length: length) }`（规范要求；ST 忽略长度直接当空数组处理，`png-chunks-extract/index.js:57-65`）
       - 若 `offset < data.count`，记 `.trailingBytesAfterIEND(count: data.count - offset)`
       - **`break`**（ST 在此 break，尾随字节被忽略）
6. 循环结束。若从未遇到 IEND → `.missingIEND`（对应 ST 的 `.png file ended prematurely: no IEND header was found`）。
7. `return PNGImage(raw: data, chunks: chunks, warnings: warnings)`

> **注意第 5.7 步**：`data[range]` 在 Swift 里返回的是 `Data` 的切片，索引沿用原 `Data` 的 index。**必须**用 `offset`（`data.startIndex` 起算）计算，并在构造 `PNGChunk` 前 `Data(payload)` 拷成独立存储，否则后续 `encodeChunks` 会踩到索引越界。

### 1.3 `decodeTextChunk` 算法步骤

对应 `node_modules/png-chunk-text/decode.js:3-34`。

1. `guard let sep = payload.firstIndex(of: 0x00)`：
   - 找不到 `0x00`：ST 的行为是 `keyword = 全串`、`text = ""`（`naming` 一直为 true 直到循环结束）。**照做，不报错。**
2. `keywordBytes = payload[payload.startIndex ..< sep]`
3. `keyword = String(bytes: keywordBytes, encoding: .isoLatin1) ?? ""`
   - `.isoLatin1` 对任意字节序列都不会失败；用 `?? ""` 只是消除 Optional。
4. `rest = payload[payload.index(after: sep)...]`
5. `if let nul = rest.firstIndex(of: 0x00)`：
   - `.strictST` → 抛 `PNGCardError.invalidNullInText(keyword: keyword)`
     （对应 ST 的 `Error('Invalid NULL character found. 0x00 character is not permitted in tEXt content')`，`node_modules/png-chunk-text/decode.js:25`，由 `read()` 的调用方冒泡）
   - `.lenient` → `rest = rest[..<nul]`，追加 `.nullInTextContent(keyword:at:)` warning
6. `text = String(bytes: rest, encoding: .isoLatin1) ?? ""`
7. 返回 `PNGTextChunk(keyword:text:chunkIndex:origin:.text)`

**为什么 Latin-1 而不是 UTF-8**：PNG 规范规定 `tEXt` 的 keyword 与 text 都是 Latin-1。ST 用 `String.fromCharCode(byte)`，正好是 Latin-1。而**载荷内容本身是 base64**（纯 ASCII），所以这一步的解码结果永远是可打印 ASCII；Latin-1 的严格性只在畸形文件上体现。

### 1.4 iTXt / zTXt 支持判定

| 类型 | 文档怎么说 | 本规格的决定 |
|---|---|---|
| **tEXt** | 唯一支持的类型。写入只写 tEXt；读取只过滤 `name === 'tEXt'`（`01#1.3`、`01#1.4`、`src/character-card-parser.js:57`） | **必须实现，读写都用它** |
| **iTXt** | ST 完全不支持。`01` 附录 1 明确：「你的 Swift 实现若想更宽容，建议额外支持 iTXt，但要知道 ST 本身读不了」 | **读：可选支持（默认开），仅未压缩（compression flag == 0）+ UTF-8；作为 fallback，优先级低于所有 tEXt。写：永不写。** 这样我们读得了别人的卡，我们产出的卡 ST 也读得了 |
| **zTXt** | ST 完全不支持，且 `PNGtext.decode` 会把压缩方法字节 `0x00` 当终止符产生垃圾（`01#1.3`） | **不实现**（默认 `allowsZTXt = false`）。要实现需 zlib 解压（`Compression.framework` 的 `COMPRESSION_ZLIB`），且只作为最低优先级 fallback |

iTXt 布局（PNG 规范，供实现参考）：
```
keyword \0 compressionFlag(1B: 0|1) compressionMethod(1B: 0) languageTag \0 translatedKeyword \0 text(UTF-8)
```
`decodeITXtChunk` 步骤：
1. 找第一个 `0x00` → keyword（Latin-1）
2. 下一字节 = compressionFlag；若为 1 → 返回 nil 并记 `.iTXtCompressed`
3. 再下一字节 = compressionMethod，忽略
4. 找下一个 `0x00` → languageTag（丢弃）
5. 找下一个 `0x00` → translatedKeyword（丢弃）
6. 余下字节按 **UTF-8** 解码为 text

### 1.5 `readCharacterJSON` / `pickCharacterJSON` 算法步骤

对应 `src/character-card-parser.js:54-78`。

1. `image = try parse(data, options: options)`
2. `var candidates: [PNGTextChunk] = []`
3. `candidates += image.chunks` 中所有 `name == "tEXt"` 的项 → `decodeTextChunk(...)`（解码失败的项跳过并记 warning，不中断）
4. `if options.allowsITXt`：`candidates += image.chunks` 中所有 `name == "iTXt"` 的项 → `decodeITXtChunk(...)`
   - **追加在 tEXt 之后**，保证「tEXt 优先」的语义
5. `guard !candidates.isEmpty else { throw PNGCardError.noTextChunks }`
6. **优先级 1**：`firstIndex { $0.keyword.lowercased() == "ccv3" }` → 命中则解码并返回
7. **优先级 2**：`firstIndex { $0.keyword.lowercased() == "chara" }` → 命中则解码并返回
8. 都没命中 → `throw PNGCardError.noCharacterData`
   - ST 在第 5 步和第 8 步都抛同一个 `'No PNG metadata.'`，调用方不区分（`01#1.4`）。我们的两个 error case 更精确，但 **UI 文案应统一为「这张 PNG 里没有角色卡数据」**。

**base64 → UTF-8 解码步骤**（`pickCharacterJSON` 内部）：

1. `var s = text`
2. 去掉首尾空白与**内部**所有 `\n` `\r` `\t` 空格（ST 的 `Buffer.from(text,'base64')` 会忽略非字母表字符；`01#1.4` 说 base64 内容不含换行，但外部工具可能会插入）
3. **URL-safe 兼容**：若含 `-` 或 `_`，先替换 `-` → `+`、`_` → `/`
   - ⚠️ 必须显式替换。`-`/`_` 不在标准字母表内，`.ignoreUnknownCharacters` 会把它们丢掉，导致长度错乱后**解码失败（返回 nil）或产出错误字节**（本机实测：对 URL-safe 串直接解码得到 `nil`，而正确替换后能得到原字节）
4. **补 padding**：`let rem = s.count % 4; if rem > 0 { s += String(repeating: "=", count: 4 - rem) }`
   - 实测：`Data(base64Encoded:)` 对缺 padding 的输入**返回 nil**（即使带 `.ignoreUnknownCharacters`），ST 则容忍。所以必须手工补
5. `guard let bytes = Data(base64Encoded: s, options: [.ignoreUnknownCharacters]) else { throw .invalidBase64 }`
6. `guard let json = String(data: bytes, encoding: .utf8) else`：
   - 容错链：依次尝试 `.utf16LittleEndian`、`.utf16BigEndian`、`.isoLatin1`；全部失败才抛 `.invalidUTF8`
   - （ST 会得到乱码然后 `JSON.parse` 失败，结果同样是导入失败；我们的多试一次更宽容且不改变成功路径）
7. 返回该字符串。**不做 `JSONSerialization` 解析**——解析在模块 C。

### 1.6 只读保证与「原始字节」的生命周期

| 要求 | 实现 |
|---|---|
| 绝不修改原文件 | 解析入口只接受 `Data`（值类型，天然拷贝语义）；写入走 `PNGWriter`（模块 B），产出**新** `Data` |
| 保留原始 PNG 供头像显示 | `PNGImage.raw` 必须一路传到 `CharacterAvatarStore`。显示用 `UIImage(data: image.raw)`，**不要** `image.pngData()` |
| 保留原始 PNG 供导出 | 导出时 `PNGWriter.writeCharacterCard(json:into: originalPNG)`：只重排 chunk，像素数据（`IDAT`）原样复用（`01#9-D-37`） |
| 大文件内存 | `try Data(contentsOf: url, options: .mappedIfSafe)`；`01#7.3` 实测默认卡约 511 KB，正常卡不会超过几 MB |
| 只读不改 chunk 类型 | 遍历时对 `name` 做**精确 4 字节比较**，不要用「前缀匹配」；`tEXt` ≠ `tEXtfoo` |

### 1.7 边界情况与容错要求

| 输入 | 期望行为 |
|---|---|
| 空 `Data` | `.emptyInput` → UI「文件为空」 |
| JPEG 改名为 `.png` | `.invalidSignature`，错误里带上实际前 8 字节；UI「这不是 PNG 文件」 |
| 合法 PNG 但没有 `tEXt` | `PNGCardError.noTextChunks`；UI「这张图没有角色卡数据」 |
| 合法 PNG，有 `tEXt` 但只有 `parameters`（A1111） | `noCharacterData`；同上文案 |
| `tEXt` keyword 大小写混合（`CHARA`/`Chara`） | 必须命中（`.lowercased()`，`01#9-A-2`） |
| 同时有 `chara` 和 `ccv3` | **`ccv3` 优先**（`01#9-A-3`） |
| 两个 `ccv3` | 取**第一个**（`01#9-A-3`） |
| `tEXt` 里出现多个 `0x00` | `.lenient` 截断 + warning；`.strictST` 抛错 |
| base64 里有换行 | 去掉后正常解码 |
| base64 缺 `=` | 补 padding 后正常解码 |
| base64 内容不是合法 base64 | `.invalidBase64` |
| 解出来不是 UTF-8（UTF-16 卡） | 依次尝试 UTF-16LE/BE，仍失败 → `.invalidUTF8` |
| `IHDR` 不在第一位 | `.firstChunkIsNotIHDR` |
| 没有 `IEND`（下载中断） | `.missingIEND` |
| `IEND` 的 length ≠ 0 | 严格模式抛 `.iendNotEmpty`；宽容模式当空处理 |
| 某个 `IDAT` 的 CRC 损坏 | `.lenient` 继续（能读出角色卡）；`.strict` 失败（ST 行为） |
| `tEXt` 的 CRC 损坏 | 同上；`.lenient` 下仍尝试解码该 chunk |
| chunk length 声称 4 GB | `.chunkTooLarge`，不要尝试分配内存 |

### 1.8 易错点（模块 A）

1. **`Data` 切片索引陷阱**：`data[offset..<offset+n]` 的 `startIndex` 不是 0。任何 `for i in 0..<slice.count { slice[i] }` 都会崩。统一用 `slice.withUnsafeBytes`，或立刻 `Data(slice)` 拷贝。
2. **Latin-1 不是 UTF-8**：`String(data:encoding:.utf8)` 对 `0xE9` 会返回 nil，必须 `.isoLatin1`。
3. **`Data(base64Encoded:)` 对缺 padding 返回 nil**（已实测）。不要假设它和 Node 的 `Buffer.from(...,'base64')` 一样宽容。
4. **不要用 `.ignoreUnknownCharacters` 兜 URL-safe base64**：`-`/`_` 会被静默丢弃，产出错误字节。必须先替换。
5. **CRC 覆盖 `type + data`，不含 4 字节 length**。写成 `crc(payload)` 是最常见的错误。
6. **不要在 `IEND` 之后继续读**：ST 在此 break，尾部垃圾字节应被忽略（只记 warning）。
7. **`readCharacterJSON` 不应假定角色 chunk 紧邻 `IEND`**：其他工具会在中间插 `pHYs`、`eXIf`、`iTXt`。必须全量扫描。
8. **`String.lowercased()` 对土耳其语等 locale 敏感**：keyword 比较用 `keyword.lowercased(with: Locale(identifier: "en_US_POSIX"))`，或干脆逐字节做 ASCII 大小写折叠。
9. **循环里不要 `try` 整个 chunk**：一个坏 chunk 不应该让整张卡读不出来（宽容模式）。
10. **`PNGImage.raw` 复制开销**：`Data` 是 COW，传递不会真的复制；但 `Data(slice)` 会。只在必须时拷贝。

---

## 2. 模块 B：PNG 写入器

### 2.1 需要的 Swift 类型

```swift
enum PNGWriter {

    struct Options {
        /// 写入永远重算正确 CRC；这个开关只影响「读入阶段」是否因坏 CRC 失败
        var inputCRC: PNGCRCValidation = .lenient
        /// 复刻 ST：同时写 ccv3（`01#1.2` 步骤 4）
        var writesCCv3 = true
        /// 保留所有非 chara/ccv3 的 tEXt（如 A1111 的 parameters、NovelAI 的 naidata）
        var preservesOtherTextChunks = true
        /// 写入前验证：重新解析产物，断言能读回同一份 JSON（仅 DEBUG 建议开）
        var selfVerify = false

        static let stCompatible = Options()
    }

    /// 主入口：在已有 PNG 上替换角色数据块，其余 chunk 原样保留
    static func writeCharacterCard(json: String,
                                   into originalPNG: Data,
                                   options: Options = .init()) throws -> Data

    /// 从零构造：调用方先准备好一张合规 PNG（默认头像），再插入角色数据
    static func writeCharacterCard(json: String,
                                   ontoBase basePNG: Data,
                                   options: Options = .init()) throws -> Data

    /// chunk 列表 → PNG 字节流
    static func encodeChunks(_ chunks: [PNGChunk]) throws -> Data

    /// 构造一个 tEXt chunk（含正确 CRC）
    static func makeTextChunk(keyword: String, text: String) throws -> PNGChunk

    /// 构造一个 iTXt chunk（本规格不用它写卡，但导出「给其他工具看」时可选）
    static func makeITXtChunk(keyword: String, text: String) throws -> PNGChunk
}
```

### 2.2 决策：复用原 PNG 还是重建？

| 场景 | 做法 | 依据 |
|---|---|---|
| 导入 PNG 后编辑并导出 | **复用原 PNG**：解析 chunk → 删旧角色块 → 插新块 → 重新编码。`IHDR`/`IDAT`/`PLTE`/`tRNS`/`pHYs`… 全部逐字节保留 | `01#6.1`（`rawBuffer = readFile(...)` → `write(rawBuffer, mutated)`）、`01#9-D-37` |
| JSON 卡导入（没有图） | **构造默认头像 PNG**再走同一条路径。ST 用 `./public/img/ai4.png`（`01#4.3`、`src/constants.js:360`）；我们程序化生成 512×768 的占位图 | `01#7.3`、`04#3.3` |
| 新建角色、用户上传 JPEG 头像 | `UIImage(data:)` → 裁到 512×768（仅在需要时）→ `pngData()` → 作为 base | `01#7.3`（`AVATAR_WIDTH=512` / `AVATAR_HEIGHT=768`） |

**绝不重写 `IDAT`**。重新编码像素会改变文件指纹、丢 chunk、放大体积，而且完全没有必要。

### 2.3 `writeCharacterCard` 算法步骤

对应 `src/character-card-parser.js:15-46` + `src/png/encode.js:9-68` + `01#1.2`。

1. `let image = try PNGReader.parse(originalPNG, options: .init(crc: options.inputCRC, textStrictness: .lenient))`
2. `var chunks = image.chunks`
3. **删除已有角色数据**（严格照 ST）：
   ```
   var kept: [PNGChunk] = []
   for chunk in chunks {
       guard chunk.name == "tEXt" else { kept.append(chunk); continue }   // ★ 只看精确的 "tEXt"
       guard let decoded = try? PNGReader.decodeTextChunk(chunk.data, at: 0, strictness: .lenient).chunk
       else { kept.append(chunk); continue }                              // 解不开就留着
       let kw = decoded.keyword.lowercased(with: Locale(identifier: "en_US_POSIX"))
       if kw == "chara" || kw == "ccv3" { continue }                       // 丢弃
       kept.append(chunk)
   }
   chunks = kept
   ```
   - ⚠️ **只遍历 `tEXt`**：`iTXt`/`zTXt` 里的 `chara` 既不被识别也不被删除（`01#1.2` 步骤 2 的警告、`01#9-A-9`）。
   - `naidata`（NovelAI）、`parameters`（A1111）等必须保留。
4. **计算 v2 载荷**：
   - `let b64v2 = Data(json.utf8).base64EncodedString(options: [])`
     - 标准字母表（`A-Za-z0-9+/`）+ `=` padding
     - **不要**加 `.withoutPadding`、**不要**用 URL-safe
     - `base64EncodedString` 默认不插换行（`lineLength` 默认 0）
   - `let chunkV2 = try PNGWriter.makeTextChunk(keyword: "chara", text: b64v2)`
5. **计算 v3 载荷**（失败静默跳过，`01#9-A-10`）：
   ```
   guard options.writesCCv3 else { /* skip */ }
   do {
       guard var obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
       else { throw ... }
       obj["spec"] = "chara_card_v3"
       obj["spec_version"] = "3.0"
       let v3json = try compactJSONString(obj)     // ★ 紧凑，无缩进
       let b64v3 = Data(v3json.utf8).base64EncodedString()
       let chunkV3 = try PNGWriter.makeTextChunk(keyword: "ccv3", text: b64v3)
   } catch {
       // 忽略：此时只写 chara（ST 行为）
   }
   ```
   - **只改 `spec` / `spec_version` 两个字段**，不注入任何 v3 新字段（`01#2.4`-3、`01#9-A-10`）。实测 `default/content/default_Seraphina.png` 的两个 chunk 除这两个键外逐字节相同。
6. **插入到 IEND 之前，且 `chara` 在前、`ccv3` 在后**：
   ```
   guard let iendIndex = chunks.firstIndex(where: { $0.name == "IEND" }) else { throw .missingIEND }
   var insertAt = iendIndex
   chunks.insert(chunkV2, at: insertAt); insertAt += 1     // ★ 必须递增
   if let chunkV3 { chunks.insert(chunkV3, at: insertAt) }
   ```
7. `let out = try encodeChunks(chunks)`
8. 若 `options.selfVerify`：`let back = try PNGReader.readCharacterJSON(from: out, options: .init(crc: .strict))`，断言 `back == json`。
9. `return out`

**最终 chunk 顺序**（已实测验证）：`IHDR, …, tEXt(chara), tEXt(ccv3), IEND`
来源：`01#1.2`「因为两次 `splice(-1, 0, x)` 都插在 IEND 前，第一次插入的 `chara` 在前」。

### 2.4 CRC32 实现要点

**语义**：PNG 使用标准 CRC-32/ISO-HDLC —— 反射多项式 `0xEDB88320`，初值 `0xFFFFFFFF`，输出异或 `0xFFFFFFFF`，输入/输出都反射。

```swift
enum CRC32 {

    /// 256 项查表，进程内只算一次
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) == 1 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    /// 标准 CRC32（无 seed）
    static func compute(_ bytes: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        bytes.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for b in buf {
                c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8)
            }
        }
        return c ^ 0xFFFF_FFFF
    }

    /// PNG chunk 的 CRC = CRC32(type || data)
    static func chunk(type: String, data: Data) -> UInt32 {
        var buf = Data(type.utf8)          // 恰好 4 字节
        buf.append(data)
        return compute(buf)
    }
}
```

**与 ST 的等价性（已实测）**：
`src/png/encode.js:58` 写的是 `crc32(data, crc32(new Uint8Array(nameChars)))`，用的是 npm `crc` 包的 `(input, previous)` 形式。实测 `crc32(b, crc32(a)) === crc32(concat(a,b))`，所以**直接对 `type+data` 算一次标准 CRC32 即可**，不需要复刻 seed 形式。

**回归测试向量**（用上面的实现已在本机 Swift 6.4 编译器上验证通过）：
| 输入 | 期望输出 |
|---|---|
| ASCII `"123456789"` | `0xCBF43926`（CRC-32/ISO-HDLC 标准校验值） |
| ASCII `"IEND"`（空 data 的 IEND chunk） | `0xAE426082` |
| `default/content/default_Seraphina.png` 的 `tEXt(chara)` chunk | 可用真实文件做 golden test（见模块 H） |

**字节序**：CRC 与 chunk length 都是 **大端（网络序）** 写入（`src/png/encode.js:43-47`、`:60-64`）。
```swift
static func appendUInt32BE(_ v: UInt32, to out: inout Data) {
    out.append(UInt8((v >> 24) & 0xFF))
    out.append(UInt8((v >> 16) & 0xFF))
    out.append(UInt8((v >>  8) & 0xFF))
    out.append(UInt8( v        & 0xFF))
}
```

### 2.5 `encodeChunks` 算法步骤

对应 `src/png/encode.js:9-68`。

1. `totalSize = 8 + Σ(chunk.data.count + 12)`（`+12` = 4 长度 + 4 类型 + 4 CRC；`01#1.5`）
2. `var out = Data(capacity: totalSize)`
3. `out.append(contentsOf: PNGConstant.signature)`
4. 对每个 chunk：
   1. `appendUInt32BE(UInt32(chunk.data.count))`
   2. `out.append(contentsOf: chunk.name.utf8)`（断言恰好 4 字节）
   3. `out.append(chunk.data)`
   4. `appendUInt32BE(CRC32.chunk(type: chunk.name, data: chunk.data))`
5. `return out`
6. `IEND` 的 `data` 长度为 0 → 整块占 12 字节

**关键**：`encodeChunks` 用**重算**的 CRC，而不是 `chunk.storedCRC`。这带来一个免费的好处：宽容模式读入的、CRC 已损坏的 PNG 会在写出时被自动修复。

### 2.6 tEXt 编码校验（`makeTextChunk`）

对应 `node_modules/png-chunk-text/encode.js:3-42`。

1. `guard keyword.utf8.count < PNGConstant.maxKeywordLength`（即最多 79 字节）→ 否则 `throw PNGWriteError.keywordTooLong`
2. `guard !keyword.contains("\0")` → 否则 `throw PNGWriteError.nullInKeyword`
3. `guard !text.contains("\0")` → 否则 `throw PNGWriteError.nullInContent`
4. **Latin-1 校验**：所有字符的 Unicode scalar 必须 ≤ `0xFF`
   ```swift
   guard keyword.unicodeScalars.allSatisfy({ $0.value <= 0xFF }),
         text.unicodeScalars.allSatisfy({ $0.value <= 0xFF })
   else { throw PNGWriteError.notLatin1 }
   ```
   - 实际使用中永远不会触发：内容恒为 base64（纯 ASCII），keyword 恒为 `chara`/`ccv3`
5. 布局：`keywordBytes + [0x00] + textBytes`（`01#1.3`）
6. 返回 `PNGChunk(name: "tEXt", data: payload, storedCRC: CRC32.chunk(...), computedCRC: 同, offset: -1)`

### 2.7 base64 / Latin-1 处理细节

| 项 | 要求 |
|---|---|
| 编码 | `Data(json.utf8).base64EncodedString(options: [])` → 标准字母表 + `=` padding + 无换行 |
| JSON → UTF-8 | **必须先 `Data(json.utf8)` 再 base64**，不能对 `String` 直接 base64 |
| 紧凑 JSON | 写入 PNG 的 JSON 是 `JSON.stringify(card)` 的等价物：无缩进、无换行。用 `JSONEncoder` 时**不要** `.prettyPrinted`；用 `JSONSerialization` 时**不要** `.prettyPrinted` |
| 斜杠转义 | ⚠️ **Swift `JSONEncoder` 与 `JSONSerialization` 默认把 `/` 转义成 `\/`**（本机实测）。JS 的 `JSON.stringify` 不转义。必须设置 `.withoutEscapingSlashes`（iOS 13+）。虽然 `\/` 是合法 JSON 且 ST 能解析，但会污染字节级往返测试 |
| 非 ASCII | Swift 默认原样输出 UTF-8（与 JS 一致），不要开启任何 ASCII-only 选项 |
| key 顺序 | Swift 字典无序 → 输出键顺序与 ST 不同。**JSON 对象无序，ST 的 `JSON.parse` 不依赖顺序**，语义完全等价。若要做字节级 diff，见 §5.4 |

### 2.8 从零构造 PNG（无原图时）

```swift
enum DefaultAvatarPNG {
    /// 生成 512×768 的占位头像 PNG（对应 ST 的 ./public/img/ai4.png）
    static func make(name: String, size: CGSize = CGSize(width: 512, height: 768)) -> Data
}
```
步骤：
1. `let renderer = UIGraphicsImageRenderer(size: size, format: format)`（`format.scale = 1`，避免 Retina 2x 得到 1024×1536）
2. 画不透明背景 + 角色名首字母（`01#7.3` 的标准尺寸是 512×768）
3. `let base = renderer.image { _ in ... }.pngData()!`
4. iOS 生成的 PNG 是合规的 RGBA8 无交错 PNG，天然没有 `tEXt`，可直接作为 `basePNG`
5. 走 `PNGWriter.writeCharacterCard(json:ontoBase:)`

**注意**：`UIGraphicsImageRenderer` 在非主线程可用，但它依赖 UIKit；若要在纯 Foundation 环境（如单元测试的 SPM target）跑，用 `CoreGraphics` + `CGImageDestination` 代替。

### 2.9 易错点（模块 B）

1. **插入下标必须递增**：`chunks.insert(a, at: i)` 然后 `chunks.insert(b, at: i)` 会得到 `b, a` 的顺序 —— 必须是 `chara` 在前。
2. **`ccv3` 只改标签**：多写任何 v3 新字段都会让往返 diff 出现噪音（ST 会原样保存它们，但你自己下次读回来时会看到多余字段）。
3. **JSON `parse` 失败要静默**：`01#9-A-10` 明确要求 `ccv3` 写入失败时不影响 `chara`。
4. **不要删 `iTXt` 里的 `chara`**：ST 不删，我们删了会导致「同一张卡有两个不同版本的角色数据」这种 ST 也修不了的混乱。保持与 ST 一致：只认 `tEXt`。
5. **`JSONEncoder` 默认转义 `/`（实测）**：写 PNG 时这个差异虽不致命，但请一并设上 `.withoutEscapingSlashes`，保持全局一致。
6. **CRC 表要 `static let`**：每次调用重建 256 项表会在批量导入时变成热点。
7. **`withUnsafeBytes` 里不要逃逸指针**：CRC 循环必须在闭包内完成。
8. **不要在写路径里做「先删后写」的文件级操作**：卡是单个 PNG 文件，先构造完整 `Data` 再 `write(options: .atomic)`，避免中途崩溃留下半截卡。
9. **`IDAT` 可能有多块**：复用 chunk 列表时天然处理好了；任何「按名字查单个 IDAT」的写法都是错的。
10. **CRC 修复语义**：宽容读 + 重算写 = 自动修复坏 CRC；但如果你在宽容模式下**只修改数据不重新编码**（比如直接改原 `Data` 的某几字节），CRC 就不匹配了。永远走 `encodeChunks`。

---

## 3. 模块 C：角色卡导入归一化

### 3.1 内部结构（= ST 的 `processCharacter` 产物）

Swift 属性名沿用现有 `Models/CharacterCard.swift` 的风格，新增项标 `＋`。

```swift
import Foundation

/// 卡片来源，影响导出时的默认处理
enum CardOrigin: String, Codable {
    case png          // 从 PNG 导入（保留原图）
    case json         // 从 JSON 导入（无图，用默认头像）
    case gradioJSON   // Pygmalion / Gradio notepad
    case generated    // App 内新建
}

/// 深度提示（对应 data.extensions.depth_prompt）
struct DepthPrompt: Codable, Hashable {
    var prompt: String = ""
    var depth: Int = 4                  // public/script.js:550
    var role: String = "system"         // 'system' | 'user' | 'assistant'，public/script.js:551

    /// 字符串角色 → ST 数字枚举（`01#3.4`）
    var roleCode: Int {
        switch role.lowercased() {
        case "user": return 1
        case "assistant": return 2
        default: return 0            // 未知值回退 SYSTEM（public/script.js:8942-8959）
        }
    }
}

struct CharacterCard: Identifiable, Hashable {

    // ── 本地标识（不写入文件）
    var id: UUID = UUID()

    // ── 核心内容：v1 顶层 / v2 `data.*` 归一化后同名
    var name: String = ""
    var description: String = ""
    var personality: String = ""
    var scenario: String = ""
    var firstMes: String = ""
    var mesExample: String = ""

    // ── v2 专属
    /// 作者备注。读：`creatorcomment` ⇄ `data.creator_notes` 双向；写：两处都写
    var creatorNotes: String = ""
    var systemPrompt: String = ""
    var postHistoryInstructions: String = ""
    var alternateGreetings: [String] = []
    var creator: String = ""
    var characterVersion: String = ""
    var tags: [String] = []

    // ── ST 扩展（data.extensions.*）
    /// 群聊发言倾向。默认 0.5；缺省时必须回填（`01#9-B-14`）
    var talkativeness: Double = 0.5
    /// 收藏。默认 false；缺省时必须回填（`01#9-B-14`）
    var fav: Bool = false
    /// 关联的**独立世界书文件名**（不含 `.json`），不是 character_book（`01#3.1` 表末）
    var world: String = ""
    var depthPrompt: DepthPrompt = .init()
    /// `data.extensions` 的**完整副本**（含上面 4 个已建模的键）。
    /// 导出时用属性值覆盖同名键，其余键原样写回 → 未知扩展永不丢（H2、`01#9-C-31`）
    var extensions: [String: JSONValue] = [:]

    // ── 版本与元数据（原样保留，不做升级/降级）
    /// 卡里原本的 `spec`，如 "chara_card_v2" / "chara_card_v3"；v1 卡为 nil
    var specRaw: String? = nil
    /// 卡里原本的 `spec_version`，如 "2.0" / "3.0"
    var specVersionRaw: String? = nil
    /// ISO 8601 字符串（`01#2.1` 表）
    var createDate: String = ""
    /// 卡内 `chat` 字段，默认 `"\(name) - \(humanizedDateTime())"`；导出前必须 unset
    var chatName: String = ""

    // ── 关联数据
    /// 内嵌世界书（character_book）。类型定义见 §4.1
    var characterBook: CharacterBook? = nil
    /// **含扩展名的文件名**，如 `Seraphina.png`；卡内 `avatar` 恒为 `"none"`（`01#9-B-24`）
    var avatarFileName: String = ""

    // ── 无损往返载体（H2）
    /// 导入时的**原始顶层 JSON 对象**（未经任何改写）。
    /// 导出时以它为基底，再覆盖已知字段 → 陌生键、`group_only_greetings`、
    /// v3 的 `nickname`/`assets` 等全部无损透传（`01#2.2`、`01#2.4`）
    var rawRoot: [String: JSONValue] = [:]
    var origin: CardOrigin = .generated
}
```

> **`extensions` 的语义**：读入时保存 `data.extensions` 的**全部内容**（包括 `talkativeness`/`fav`/`world`/`depth_prompt` 四个键）。导出时按 ST 的 `_.set` 顺序用属性值覆盖这 4 个键。这样：
> - 未知键（`regex_scripts`、`pygmalion_id`、`chub.full_path`、`sd_character_prompt`…，`01#2.3`）绝不丢失；
> - 属性与 `extensions` 不会长期分叉（每次导出都会重新同步）。

### 3.2 版本判定与校验

```swift
/// ST 侧实际支持的三个规范版本
enum CardSpec: String, Codable {
    case v1 = "1"
    case v2 = "2"
    case v3 = "3"
}

enum TavernCardValidator {

    /// 返回**第一个**通过的版本（V1 → V2 → V3），全失败返回 nil
    /// 语义严格复刻 src/validator/TavernCardValidator.js:32-48
    static func validate(_ root: [String: JSONValue]) -> CardSpec?

    /// V1：6 个键**存在**即可（不校验类型、不校验非空）
    /// src/validator/TavernCardValidator.js:55-64
    static func validateV1(_ root: [String: JSONValue]) -> Bool

    /// V2：spec == "chara_card_v2" && spec_version == "2.0"
    ///     && data 存在 && data 的 14 个必填键存在
    ///     && data.alternate_greetings 是数组 && data.tags 是数组
    ///     && data.extensions 是 object
    ///     && （若有 character_book）character_book.extensions 是 object
    ///        && character_book.entries 是数组
    /// src/validator/TavernCardValidator.js:71-141
    static func validateV2(_ root: [String: JSONValue]) -> Bool

    /// V3：spec == "chara_card_v3"
    ///     && 3.0 <= Number(spec_version) < 4.0
    ///     && data 是 object（**不校验任何 data 字段**）
    /// src/validator/TavernCardValidator.js:143-168
    static func validateV3(_ root: [String: JSONValue]) -> Bool
}
```

**V2 的 14 个 `data` 必填键**（`src/validator/TavernCardValidator.js:112`）：
`name, description, personality, scenario, first_mes, mes_example, creator_notes, system_prompt, post_history_instructions, alternate_greetings, tags, creator, character_version, extensions`
（`character_book` **不在**必填里，是可选。）

#### 校验顺序与优先级（必须复刻）

1. **V1 优先于 V2**：因为 ST 生成的 v2 卡顶层同时平铺着 6 个 v1 字段（§3.4 双写 hack），所以一张 v2 卡在 ST 里会先被判定为 V1（`01#2.5`，测试 `tests/tavern-card-validator.test.js:57-61`）。
2. V1 全失败 → 试 V2；V2 失败 → 试 V3；全失败返回 `nil`。
3. `lastValidationError` 记录第一个失败字段名（用于 `/merge-attributes` 的错误信息，`01#2.5`）。Swift 版用一个 `inout String?` 或返回 `(CardSpec?, failedField: String?)`。
4. ⚠️ **`validate()` 与导入路径的版本判定不是一回事**：导入走的是「`spec` 键是否存在」（§3.3），校验器只在 `/merge-attributes` 这类写回路径上用。两者都要实现，别混用。

#### `spec` / `spec_version` 缺失时如何判断版本

| 情况 | 判定 | 依据 |
|---|---|---|
| `spec` 存在，任意值 | **v2 路径**（v3 也走这条），不管 `spec_version` | `01#9-B-11`：分水岭是 `spec` 键**是否存在**，与其值无关（`src/endpoints/characters.js:451`） |
| `spec` 存在但 `data` 缺失 | 仍然 v2 路径，但**原样返回不报错** | `01#9-B-12`（`src/endpoints/characters.js:505-508`） |
| `spec` 缺失，`name` 存在 | **v1 路径** | `01#4.3` |
| `spec` 缺失，`name` 缺失，`char_name` 存在 | **Gradio/Pygmalion notepad 路径** | `01#4.3`（`src/endpoints/characters.js:929-955`） |
| 三者都缺 | 导入失败 | `01#4.3`（PNG 路径返回 `''` → HTTP 400） |

**UI 上显示「v2 / v3」的依据**（不要用 `TavernCardValidator.validate()`，那会显示成 v1）：
```swift
static func displaySpec(_ card: CharacterCard) -> CardSpec {
    guard card.specRaw != nil else { return .v1 }
    let n = Double(card.specVersionRaw ?? "") ?? 2.0
    if card.specRaw == "chara_card_v3" || (n >= 3.0 && n < 4.0) { return .v3 }
    return .v2
}
```

### 3.3 导入入口决策树

```swift
enum CardFileFormat: String {
    case png, json, yaml, yml, charx, byaf
}

enum CardImportError: Error {
    case unsupportedFileFormat(String)
    case notAnObject                       // JSON 顶层不是 object
    case unsupportedStructure              // 既无 spec 也无 name/char_name
    case png(PNGCardError)
    case invalidJSON(String)
}

enum CharacterImporter {

    /// PNG 入口（等价于 src/endpoints/characters.js:968-1020 importFromPng）
    static func importPNG(_ data: Data,
                          options: PNGReadOptions = .init()) throws -> ImportedCharacter

    /// JSON 入口（等价于 src/endpoints/characters.js:883-959 importFromJson）
    static func importJSON(_ data: Data) throws -> ImportedCharacter

    /// 统一入口（按扩展名分派）
    static func importCard(_ data: Data, format: CardFileFormat) throws -> ImportedCharacter

    // 内部步骤，全部开放给单测
    static func parseRoot(_ jsonString: String) throws -> [String: JSONValue]
    static func detectSpec(_ root: [String: JSONValue]) -> CardSpec?
    /// v2/v3 归一化（复刻 readFromV2）
    static func normalizeV2(_ root: [String: JSONValue]) -> NormalizedRoot
    /// v1 → v2 形状（复刻 convertToV2 + charaFormatData 的 v1 分支）
    static func normalizeV1(_ root: [String: JSONValue]) -> NormalizedRoot
    /// Gradio/Pygmalion notepad 形状
    static func normalizeGradio(_ root: [String: JSONValue]) -> NormalizedRoot
    /// v1（含 Gradio）中间对象 → 双写 v2 对象（★ §3.4）
    static func makeV2Root(from fields: V1SeedFields,
                           base: [String: JSONValue],
                           world: WorldInfoFile?) -> [String: JSONValue]
}

/// 归一化中间产物：既给出扁平字段，也给出完整的 v2 形状对象
struct NormalizedRoot {
    var flat: [String: JSONValue]     // processCharacter 产出的扁平对象（未 stringify）
    var warnings: [String]
}

struct ImportedCharacter {
    var card: CharacterCard
    /// PNG 导入时的原始字节；JSON 导入为 nil（H1）
    var originalPNG: Data?
    /// PNG 里解出的**原始 JSON 字节**（未改写），对应 ST 的 `json_data`（`01#4.1`）
    var originalJSON: Data
    var detectedSpec: CardSpec
    var warnings: [String]
}
```

**决策树**：

```
importCard(data, format):
  1. switch format:
       .png  → (jsonString, pngImage) = PNGReader.readCharacterCardPNG(data)
               originalPNG = pngImage.raw
       .json → jsonString = String(data: data, encoding: .utf8) ?? 抛 invalidJSON
               originalPNG = nil
       .yaml/.yml/.charx/.byaf → 抛 unsupportedFileFormat
               // ST 支持（01#4.3），但本期不做：yaml 需第三方库，charx 是 zip，
               // byaf 是 ST 专有格式。UI 上提示「暂不支持，请转成 PNG 或 JSON」
  2. root = parseRoot(jsonString)                    // 顶层必须是 object
  3. spec = detectSpec(root)
  4. switch spec:
       .v2, .v3 → n = normalizeV2(root)              // 复刻 readFromV2
                  n.flat["create_date"] = nowISO()   // ★ 导入 v2 后强制刷新（01#9-B-16）
       .v1      → n = (root["char_name"] != nil && root["name"] == nil)
                     ? normalizeGradio(root)
                     : normalizeV1(root)
                  n.flat["create_date"] = nowISO()   // ★ v1 分支也覆盖卡内 create_date（01#10.2-4）
       nil      → 抛 unsupportedStructure
  5. card = CharacterCard(fromFlat: n.flat, rawRoot: root, specRaw: root["spec"]?.stringValue,
                           specVersionRaw: root["spec_version"]?.stringValue)
  6. card.origin = (format == .png) ? .png : (spec == .v1 && root["char_name"] != nil ? .gradioJSON : .json)
  7. return ImportedCharacter(card:, originalPNG:, originalJSON: Data(jsonString.utf8),
                              detectedSpec: spec, warnings: n.warnings)
```

### 3.4 「同时平铺 v1 + v2」兼容 hack 的具体实现（★ 必须复刻）

ST 生成的每一张卡**同时**包含顶层 v1 字段和 `spec`/`spec_version`/`data`（`01#4.4`）。实测 `default/content/default_Seraphina.png` 的顶层键正是：
```
name, description, personality, first_mes, avatar, chat, mes_example, scenario,
create_date, talkativeness, fav, creatorcomment, spec, spec_version, data, tags
```

`makeV2Root` 的步骤，逐条对齐 `charaFormatData`（`src/endpoints/characters.js:565-657`）：

```swift
struct V1SeedFields {
    var name = ""
    var description = ""
    var personality = ""
    var scenario = ""
    var firstMes = ""
    var mesExample = ""
    var creatorNotes = ""            // ← creatorcomment / creator_notes 的来源
    var talkativeness: Double = 0.5
    var fav = false
    var creator = ""
    var tags: [String] = []
    var world = ""
    var depthPrompt = DepthPrompt()
    var alternateGreetings: [String] = []
    var systemPrompt = ""
    var postHistoryInstructions = ""
    var characterVersion = ""
    var chatName: String = ""        // 空则用 "\(name) - \(humanizedDateTime())"
    var createDate: String = ""
}
```

1. `var char = base`（= `tryParse(data.json_data) || {}`，**保留所有陌生键**）
2. `char.removeValue(forKey: "json_data")` —— 防递归（`src/endpoints/characters.js:570`）
3. **Spec V1 字段**（`:580-585`）：
   `char["name"] = .string(f.name)`；`description` / `personality` / `scenario` / `first_mes` / `mes_example` 一律 `f.value ?? ""`
4. **旧 ST 扩展字段**（`:588-593`）：
   - `char["creatorcomment"] = .string(f.creatorNotes)` ← ★ v1 ⇄ v2 双向映射
   - `char["avatar"] = .string("none")` ← ★ 卡内恒为 `none`
   - `char["chat"] = .string(f.chatName.isEmpty ? "\(f.name) - \(humanizedDateTime())" : f.chatName)`
   - `char["talkativeness"] = .number(f.talkativeness)`（缺省 `0.5`）
   - `char["fav"] = .bool(f.fav)`
     - ⚠️ ST 写侧是 `data.fav == 'true'`（**字符串比较**，`src/endpoints/characters.js:592`）。我们内部是 `Bool`，写 `Bool` 语义等价；但**读侧**必须能识别字符串 `"true"`/`"false"` 与布尔两种形态（§3.6 hack 5）
   - `char["tags"] = .array(tags.map(JSONValue.string))`
5. **Spec V2 骨架**（`:596-612`）：
   - `char["spec"] = "chara_card_v2"`；`char["spec_version"] = "2.0"`
   - `data.name / description / personality / scenario / first_mes / mes_example`
   - `data.creator_notes = f.creatorNotes`
   - `data.system_prompt`、`data.post_history_instructions`
   - `data.tags = 同上`
   - `data.creator`、`data.character_version`
   - `data.alternate_greetings = getAlternateGreetings(f.alternateGreetings)`
6. **ST 扩展到 V2**（`:615-617`）：
   - `data.extensions.talkativeness = f.talkativeness`
   - `data.extensions.fav = f.fav`
   - `data.extensions.world = f.world`
7. **depth_prompt**（`:620-626`）：
   - `data.extensions.depth_prompt.prompt = f.depthPrompt.prompt`
   - `data.extensions.depth_prompt.depth = f.depthPrompt.depth`（非数字时用 `4`）
   - `data.extensions.depth_prompt.role = f.depthPrompt.role`（缺省 `"system"`）
8. **character_book**（`:628-644`）：若 `f.world` 非空且能读到 `worlds/<world>.json`：
   - 该文件有 `originalData` → **原样写回** `data.character_book`（无损，`01#9-C-32`）
   - 否则 → `CharacterBookConversion.fromWorldInfo(name:entries:)`
   - 读文件失败 → 只记 warning，卡里**没有** `character_book`（`:641-643`）
9. **extensions 深合并**（`:646-654`）：若外部传入 `data.extensions` 的 JSON 字符串 → `deepMerge(char.data.extensions, parsed)`
   - Swift 版：`deepMerge` 的语义 = 递归合并 object，非 object 直接覆盖。实现要点见 §3.7-易错点
10. `return char` —— **顶层 v1 与 `data` 双写完成**

> **v1 导入路径不生成 `character_book`**：`convertToV2` 只传了 13 个字段，**没有传 `world`**（`src/endpoints/characters.js:471-487`）。所以即使 v1 卡里带了 `world` 也不会生成 `character_book`（`01#10.2` 第 8 点）。

### 3.5 完整字段映射表

#### 表 C-1：文件字段 → Swift 属性

| 文件字段路径 | Swift 属性 | 默认值 | 备注 |
|---|---|---|---|
| 顶层 `name` / `data.name` | `name` | `""` | `data.name` **总是覆盖**顶层（`01#9-B-13`） |
| `description` / `data.description` | `description` | `""` | 同上 |
| `personality` / `data.personality` | `personality` | `""` | |
| `scenario` / `data.scenario` | `scenario` | `""` | |
| `first_mes` / `data.first_mes` | `firstMes` | `""` | |
| `mes_example` / `data.mes_example` | `mesExample` | `""` | `<START>` 分隔（`01#5.1`） |
| 顶层 `creatorcomment` / `data.creator_notes` | `creatorNotes` | `""` | ★ 双向映射（`01#9-B-23`） |
| 顶层 `creator_notes`（v1 JSON 路径） | `creatorNotes` | `""` | 仅当 `creatorcomment` 缺失时兜底（`src/endpoints/characters.js:913`） |
| `data.system_prompt` | `systemPrompt` | `""` | v1 卡无此字段 |
| `data.post_history_instructions` | `postHistoryInstructions` | `""` | |
| `data.alternate_greetings` | `alternateGreetings` | `[]` | 字符串 → `[s]`；非数组非字符串 → `[]`（`01#9-B-19`） |
| `data.tags` / 顶层 `tags` | `tags` | `[]` | 逗号分隔字符串 → `split(",").map(trim).filter(!isEmpty)`（`01#9-B-19`） |
| `data.creator` / 顶层 `creator` | `creator` | `""` | |
| `data.character_version` | `characterVersion` | `""` | |
| `data.extensions.talkativeness` / 顶层 `talkativeness` | `talkativeness: Double` | `0.5` | ★ 仅此字段与 `fav` 会**回填默认值**（`01#9-B-14`）；接受 number 或 string `"0.5"` |
| `data.extensions.fav` / 顶层 `fav` | `fav: Bool` | `false` | 接受 `Bool` 或字符串 `"true"`（`01#9-B-18`） |
| `data.extensions.world` | `world` | `""` | 独立世界书文件名，不含 `.json` |
| `data.extensions.depth_prompt.prompt` | `depthPrompt.prompt` | `""` | |
| `data.extensions.depth_prompt.depth` | `depthPrompt.depth` | `4` | `public/script.js:550` |
| `data.extensions.depth_prompt.role` | `depthPrompt.role` | `"system"` | 字符串；未知值→`system` |
| `data.extensions`（其余全部） | `extensions` | `[:]` | 原样保留（`01#9-C-31`） |
| `data.character_book` | `characterBook` | `nil` | 见模块 D |
| 顶层 `spec` | `specRaw` | `nil` | 原样保留，不改写 |
| 顶层 `spec_version` | `specVersionRaw` | `nil` | |
| 顶层 `create_date` | `createDate` | 当前 ISO | 读取列表时不刷新（`hoistDate=false`）；**导入时强制刷新为 now**（`01#9-B-16`） |
| 顶层 `chat` | `chatName` | `"\(name) - \(humanizedDateTime())"` | 导出前 unset（`01#9-D-35`） |
| 顶层 `avatar` | `avatarFileName`（**运行时**） | `""` | 卡内恒 `"none"`，运行时被 PNG 文件名覆盖（`01#9-B-24`） |
| 顶层 `json_data` | `originalJSON`（`ImportedCharacter`） | — | 内部对象必须携带原始 JSON 字符串（`01#9-B-15`）；归一化前先删，防递归 |
| 其他所有顶层键 | `rawRoot` | `[:]` | 无损透传 |
| `data.group_only_greetings` | （无独立属性） | — | ST 完全不引用；留在 `rawRoot["data"]`（`01#2.2`、`01#9-19`） |
| `data.nickname` / `data.creator_notes_multilingual` / `data.source` / `data.assets` / `data.creation_date` / `data.modification_date` | （无独立属性） | — | v3 官方新增，ST 无引用，纯透传（`01#2.4`-4） |

#### 表 C-2：v3 与 v2 的差异（ST 1.19.0 实际行为）

| 项 | v2 | v3（ST 实现） | Swift 处理 |
|---|---|---|---|
| `spec` | `"chara_card_v2"` | `"chara_card_v3"` | 原样存 `specRaw` |
| `spec_version` | `"2.0"` | `"3.0"` | 原样存 `specVersionRaw` |
| `data` 结构 | 14 必填 | **与 v2 完全相同** | 走同一条 `normalizeV2` |
| 校验强度 | 严格（14 字段 + 类型） | 极宽松（只查 spec / spec_version / data 是 object） | `validateV3` 照做 |
| 读取路径 | `readFromV2` | 同 `readFromV2`（`spec` 存在即走这条） | 同一个函数 |
| PNG 写入 | 写 `chara` | 写 `chara` + `ccv3`（v3 只是改标签） | `PNGWriter` §2.3 |

### 3.6 兼容 hack 清单的 Swift 处理方式（逐条）

| # | Hack（`01#4.5`） | Swift 处理 |
|---|---|---|
| 1 | 顶层与 `data` 双写同名 v1 字段 | `makeV2Root` 步骤 3 + 5（§3.4） |
| 2 | `creatorcomment` ⇄ `creator_notes` 双向 | 读：`root["creatorcomment"] ?? data["creator_notes"]`；写：两处都写 |
| 3 | Gradio 字段（`char_name`/`char_persona`/`char_greeting`/`world_scenario`/`example_dialogue`） | `normalizeGradio`：见下表 C-3 |
| 4 | `talkativeness` 双写 + 默认 0.5 | 属性默认 `0.5`；`makeV2Root` 写两处 |
| 5 | `fav` 用字符串比较 `== 'true'` 解析 | 读：`asBool()` 助手（接受 `Bool` / `"true"` / `"false"` / `1` / `0`）；写：写 `Bool` |
| 6 | `tags` 支持 `string[]` 或逗号分隔 string | `asStringArray()` 助手 |
| 7 | `alternate_greetings` 单字符串 → 数组 | `asStringArray(singleAsArray: true)` |
| 8 | `world` → `data.extensions.world` + 生成 `character_book` | `world` 属性 + `CharacterBookConversion`（模块 D） |
| 9 | `avatar` 卡内恒 `'none'`，运行时被 PNG 文件名替换 | `makeV2Root` 恒写 `"none"`；`avatarFileName` 只由存储层赋值 |
| 10 | `chat` 默认 `"\(name) - \(humanizedDateTime())"`，导出时 unset | `chatName` 属性；`CharacterExporter.unsetPrivateFields` |
| 11 | `create_date`：卡内优先，否则用文件 `ctimeMs` 的 ISO | 属性 `createDate`；导入时设为 now；列表读取时保留卡内值，缺失则用文件创建时间 |
| 12 | `json_data` = 原始 PNG JSON，参与表单往返，导入时 unset | `ImportedCharacter.originalJSON`；`makeV2Root` 步骤 2 删除 |
| 13 | `spec` 存在但 `data` 缺失 → 原样返回不报错 | `normalizeV2` 里 `guard let data = root["data"] else { return flatFromTopLevel(root) }`，记 warning，不抛 |
| 14 | 顶层/`data` 值不一致只 warn，以 `data` 为准 | `normalizeV2` 比较后追加 warning，**无条件用 `data` 值** |
| 15 | 剥离字面量 `"Creator's notes go here."` | `creatorNotes.replacingOccurrences(of: "Creator's notes go here.", with: "")`，在 v1/Gradio 路径执行（`src/endpoints/characters.js:907`、`:934`、`:994`） |
| 16 | `data.character_book` 优先用 `originalData` 无损回写 | `WorldInfoFile.originalData`（模块 D §D.6） |
| 17 | 所有 key/value 名称走 `sanitize-filename`（replacement 为空串） | `FileNameSanitizer`（模块 F） |
| 18 | 重名 → `Name.png`, `Name1.png`, `Name2.png`… | `FileNameSanitizer.uniqueName(base:exists:)`（模块 F） |
| 19 | `group_only_greetings` / `priority` / entry `name` / 读取时 `use_regex` 全部忽略 | 一律留在 `rawRoot` / `CharacterBookEntry.unknownFields` 里透传，不建属性 |

#### 表 C-3：Gradio / Pygmalion notepad 映射（`src/endpoints/characters.js:929-955`）

| 旧字段 | Swift 属性 |
|---|---|
| `char_name` | `name` |
| `char_persona` | `description` |
| `char_greeting` | `firstMes` |
| `world_scenario` | `scenario` |
| `example_dialogue` | `mesExample` |
| `creator_notes` / `creatorcomment` | `creatorNotes` |
| — | `personality = ""`（**没有来源，硬编码空**） |
| — | `chat = "undefined - <时间>"`（已知 bug，见易错点） |

### 3.7 边界情况与容错要求

| 情况 | 处理 |
|---|---|
| JSON 顶层是数组 / 字符串 / 数字 | `throw .notAnObject`（ST 的 `JSON.parse` 会成功，随后 `.spec` 为 `undefined`、`.name` 为 `undefined` → 返回 `''`，等价于失败） |
| `spec` 存在但 `data` 缺失 | 不报错，把顶层当扁平字段用，记 warning（hack 13） |
| `data` 存在但不是 object | 同上看待：`guard case .object(let d) = root["data"]` 失败则走 hack 13 |
| `talkativeness` 是字符串 `"0.5"` | `Double("0.5")` 成功；否则用默认 `0.5` |
| `fav` 是字符串 `"true"` / `"false"` | 分别映射 `true` / `false`；其他值 → `false` |
| `tags` 是 `""`（空字符串） | `split(",")` → `[""]` → `filter` → `[]` |
| `alternate_greetings` 是 `null` | → `[]` |
| `alternate_greetings` 是数字 | → `[]`（`01#4.2` 步骤 4：其他 → `[]`） |
| `data.name` 与顶层 `name` 不一致 | 记 warning，用 `data.name` |
| 名字含 `/` `\` `?` `*` 等 | 导入后立即 `FileNameSanitizer.sanitize`（`src/endpoints/characters.js:974-977` 会对 `data.name` 和最终 `name` 各 sanitize 一次） |
| 名字 sanitize 后为空 | 用 `"unnamed"`（ST 会得到 `''.png`，是它的 bug，不复刻） |
| `mes_example` 不以 `<START>` 开头 | **保留原文**。`<START>` 的补齐发生在 prompt 组装阶段（`01#5.1`），不在导入阶段 |
| `rawRoot` 巨大（几十 MB 的 `assets`） | 正常保存；但 UI 层不要在列表里渲染它 |

### 3.8 易错点（模块 C）

1. **`spec` 的值不重要，存在性才重要**。写成 `if root["spec"] == "chara_card_v2"` 会让 `chara_card_v3` 和第三方 `spec` 值的卡全部误判为 v1。
2. **`data.*` 无条件覆盖顶层**，不是「顶层优先」。`readFromV2` 里 `char[charField] = v2Value` 是无条件的（`src/endpoints/characters.js:551`）。
3. **只有 `talkativeness` 和 `fav` 会回填默认值**。其余字段缺失时 ST 只是 warn + 保留顶层原值，**不会**填 `""`（`01#9-B-14`）。Swift 侧因为属性有默认值，效果等价，但要知道来源。
4. **`create_date` 在 v1 导入时被覆盖为 now**，卡内原值丢失（`01#10.2` 第 4 点）。这是 ST 的行为，要复刻，但 UI 上可以额外保留 `rawRoot["create_date"]` 作为「原始创建时间」。
5. **Gradio 分支的 `chat` 字段是 `"undefined - <时间>"`**（`src/endpoints/characters.js:944` 用了 `jsonData.name`，此时为 `undefined`）。`01#4.3` 明确说这是「已知 bug 要复刻」。**建议不复刻这个 bug**——`01` 的附录也把它列为「注意」项。规格决定：用 sanitize 后的 `char_name`，并在注释里标注「有意偏离 ST」。
6. **不要在导入阶段处理 `<START>`**。`mes_example` 原样存；`parseMesExamples` 是 prompt 层的事（`01#5.1`）。
7. **`deepMerge` 的语义**：递归合并 object；数组与标量**整体替换**而不是拼接（lodash `merge` 对数组是按索引合并的，但 extensions 里几乎不会有数组，遇到时按整体替换更安全，并记 warning）。
8. **`rawRoot` 与属性要一致**：每次保存前用 `makeV2Root` 重新生成 v2 形状，不要试图直接改 `rawRoot` 里的字段——那会绕过双写 hack。
9. **`spec`/`spec_version` 不要「修正」**：v2 卡导出仍是 v2，v3 卡导出仍是 v3，ST **从不主动升级**（`01#9-D-38`）。
10. **名字 sanitize 要执行两次**（`data.name` 与最终 `name`），因为 `jsonData.name = sanitize(jsonData.data?.name || jsonData.name)`（`src/endpoints/characters.js:977`）。

---

## 4. 模块 D：character_book ↔ WorldInfoEntry 映射

### 4.1 两种形状必须分开建模

> `04#4.3` 的警告：**磁盘上的 `worlds/*.json` 用「对象 + ST camelCase 字段名」**；**卡片里的 `character_book` 用「数组 + 下划线字段名」**。两者必须做转换，不能混用。

```swift
// ══════════════════════════════════════════════════════════
// 形状 1：规范形状（卡片内 data.character_book）
//         字段名下划线，entries 是【数组】
// ══════════════════════════════════════════════════════════

struct CharacterBook: Codable, Hashable {
    var name: String?                                   // 缺省导出时用 "<角色名>'s Lorebook"
    var description: String?                            // ST 不读，往返保留
    var scanDepth: Int?                                 // ST 不读（用全局设置）
    var tokenBudget: Int?                               // ST 不读
    var recursiveScanning: Bool?                        // ST 不读
    var extensions: [String: JSONValue] = [:]           // 规范必填（validator 校验是 object）
    var entries: [CharacterBookEntry] = []              // 规范必填（validator 校验是数组）
    /// 保留规范里的未知顶层键（如第三方扩展）
    var unknownFields: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey {
        case name, description, entries, extensions
        case scanDepth = "scan_depth"
        case tokenBudget = "token_budget"
        case recursiveScanning = "recursive_scanning"
    }
}

/// 规范里的字符串位置，只有两个取值
enum CharacterBookPosition: String, Codable {
    case beforeChar = "before_char"
    case afterChar  = "after_char"
}

struct CharacterBookEntry: Codable, Hashable {
    // ── 规范必填
    var keys: [String] = []
    var content: String = ""
    var extensions: [String: JSONValue] = [:]
    /// ⚠️ 规范必填。**缺失时 ST 会得到 `disable = true`（条目被禁用）**，见 §D.4
    var enabled: Bool? = nil
    var insertionOrder: Int? = nil

    // ── 规范可选
    var id: Int? = nil
    var comment: String? = nil
    var name: String? = nil              // 规范有，ST 忽略（内部用 comment）
    var priority: Int? = nil             // 规范有，ST 完全忽略
    var selective: Bool? = nil
    var secondaryKeys: [String]? = nil
    var constant: Bool? = nil
    var position: CharacterBookPosition? = nil
    var caseSensitive: Bool? = nil       // ⚠️ ST 读侧不读它，见 §D.5
    var useRegex: Bool? = nil            // 不在 v2 规范里，ST 写恒 true，读时忽略

    var unknownFields: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey {
        case id, keys, comment, name, content, constant, selective, enabled, position, priority, extensions
        case secondaryKeys = "secondary_keys"
        case insertionOrder = "insertion_order"
        case caseSensitive = "case_sensitive"
        case useRegex = "use_regex"
    }
}

// ══════════════════════════════════════════════════════════
// 形状 2：ST 内部形状（= worlds/*.json 的条目）
//         camelCase，position 等是【数字枚举】
// ══════════════════════════════════════════════════════════

/// ★ 替换现有 `Models/WorldInfo.swift:103` 的 `WorldInfoPosition: String`
enum WorldInfoPositionCode: Int, Codable, CaseIterable {
    case before   = 0   // 角色定义之前
    case after    = 1   // 角色定义之后
    case anTop    = 2   // Author's Note 顶部
    case anBottom = 3   // Author's Note 底部
    case atDepth  = 4   // 聊天内指定深度（配合 depth + role）
    case emTop    = 5   // 示例消息顶部
    case emBottom = 6   // 示例消息底部
    case outlet   = 7   // Outlet（配合 outletName）
}
// 来源：public/scripts/world-info.js:855-864；01#3.4

enum WorldInfoSelectiveLogic: Int, Codable, CaseIterable {
    case andAny = 0     // 主关键词命中 且 任一 secondary 命中
    case notAll = 1     // 主关键词命中 且 并非所有 secondary 都命中
    case notAny = 2     // 主关键词命中 且 无 secondary 命中
    case andAll = 3     // 主关键词命中 且 所有 secondary 都命中
}
// 来源：public/scripts/world-info.js:33-38；01#3.4

enum ExtensionPromptRole: Int, Codable, CaseIterable {
    case system = 0, user = 1, assistant = 2
}
// 来源：public/script.js:494-498；01#3.4

struct WorldInfoEntry: Identifiable, Codable, Hashable {
    /// ST 的条目 id，同时是磁盘 `entries` 对象的 key
    var uid: Int = 0
    var id: Int { uid }                 // Identifiable

    // ── 匹配
    var key: [String] = []
    var keysecondary: [String] = []
    var selective: Bool = false         // ⚠️ 默认值见 §D.6
    var selectiveLogic: Int = 0
    var constant: Bool = false
    var vectorized: Bool = false
    var caseSensitive: Bool? = nil
    var matchWholeWords: Bool? = nil
    var matchPersonaDescription: Bool = false
    var matchCharacterDescription: Bool = false
    var matchCharacterPersonality: Bool = false
    var matchCharacterDepthPrompt: Bool = false
    var matchScenario: Bool = false
    var matchCreatorNotes: Bool = false
    var triggers: [String] = []

    // ── 内容与显示
    var content: String = ""
    var comment: String = ""
    var addMemo: Bool = false
    var displayIndex: Int = 0

    // ── 时序 / 概率
    var probability: Int = 100
    var useProbability: Bool = true
    var sticky: Int? = nil
    var cooldown: Int? = nil
    var delay: Int? = nil

    // ── 插入
    var order: Int = 100
    var position: Int = 0               // ★ WorldInfoPositionCode.rawValue
    var depth: Int = 4
    var role: Int? = 0
    var outletName: String = ""
    var ignoreBudget: Bool = false

    // ── 递归
    var excludeRecursion: Bool = false
    var preventRecursion: Bool = false
    /// ⚠️ 类型是 `bool | number`（模板 `0`，转换时 `false`）。见 §D.8 易错点
    var delayUntilRecursion: JSONValue = .bool(false)
    var scanDepth: Int? = nil
    var useGroupScoring: Bool? = nil

    // ── 分组
    var group: String = ""
    var groupOverride: Bool = false
    var groupWeight: Int? = nil          // ⚠️ 模板 100，从卡片转换时写 null

    // ── 自动化
    var automationId: String = ""

    // ── 往返载体
    /// ★ `character_book.entries[].extensions` 的**原始副本**。
    /// ST 读侧把它整个塞进内部条目的 `extensions` 字段（`world-info.js:5667`），
    /// 我们把已知键提升为上面的属性，未知键留在这里，导出时再合并回去
    var originalExtensions: [String: JSONValue] = [:]
    /// 磁盘文件里的未知键
    var unknownFields: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey {
        case uid, key, keysecondary, comment, content, constant, vectorized, selective
        case selectiveLogic, addMemo, order, position, disable, ignoreBudget
        case excludeRecursion, preventRecursion, delayUntilRecursion
        case matchPersonaDescription, matchCharacterDescription, matchCharacterPersonality
        case matchCharacterDepthPrompt, matchScenario, matchCreatorNotes
        case probability, useProbability, depth, outletName, group, groupOverride, groupWeight
        case scanDepth, caseSensitive, matchWholeWords, useGroupScoring
        case automationId, role, sticky, cooldown, delay, triggers, displayIndex
        case extensions                  // 磁盘上可能出现；用 originalExtensions 承接
        case originalData
        // 未知键通过 unknownFields 的自定义 init/encode 处理
    }
}

/// 磁盘世界书文件形状
struct WorldInfoFile: Codable, Hashable {
    /// ★ key 是 `String(uid)`，不是数组（04#4.1）
    var entries: [String: WorldInfoEntry] = [:]
    var name: String? = nil
    var extensions: [String: JSONValue]? = nil
    /// ★ 从角色卡导入时保留的原始 character_book，导出卡时优先无损回写（04#4.1、01#9-C-32）
    var originalData: CharacterBook? = nil
    var unknownFields: [String: JSONValue] = [:]
}
```

### 4.2 需要的转换函数签名

```swift
enum CharacterBookConversion {

    /// character_book（数组 + 下划线）→ ST 内部条目（camelCase + 数字枚举）
    /// 语义严格复刻 public/scripts/world-info.js:5617-5674 convertCharacterBook
    static func toWorldInfoEntries(_ book: CharacterBook) -> [WorldInfoEntry]

    /// ST 内部条目 → character_book
    /// 语义严格复刻 src/endpoints/characters.js:663-722 convertWorldInfoToCharacterBook
    static func fromWorldInfo(name: String,
                              entries: [String: WorldInfoEntry],
                              unknownTopLevel: [String: JSONValue] = [:]) -> CharacterBook

    /// 单条：规范 → 内部
    static func toEntry(_ e: CharacterBookEntry, index: Int) -> WorldInfoEntry

    /// 单条：内部 → 规范
    static func fromEntry(_ e: WorldInfoEntry) -> CharacterBookEntry

    /// position 双向
    static func positionCode(_ e: CharacterBookEntry) -> Int
    static func bookPosition(fromPositionCode code: Int) -> CharacterBookPosition
}
```

### 4.3 `character_book` → `WorldInfoEntry` 完整映射表

来源：`public/scripts/world-info.js:5620-5670`、`01#3.2`、`01#3.3`。**右列是 Swift 属性名。**

#### 顶层条目字段

| character_book 字段 | 类型 | Swift `CharacterBookEntry` → `WorldInfoEntry` | 默认/缺省 |
|---|---|---|---|
| `keys` | string[] | `keys` → `key` | `[]` |
| `content` | string | `content` → `content` | `""` |
| `extensions` | object | `extensions` → **展开为下面的子字段 + `originalExtensions` 副本** | `[:]` |
| `enabled` | boolean | `enabled` → `disable = !(enabled ?? false)` | ★ 缺失 ⇒ `disable = true`（见易错点） |
| `insertion_order` | number | `insertionOrder` → `order` | 缺失时用 `100` |
| `case_sensitive` | boolean? | `caseSensitive`（**规范字段，ST 读侧忽略**） | `nil` |
| `name` | string? | —— **ST 忽略**（内部用 `comment`） | — |
| `priority` | number? | —— **ST 完全忽略** | — |
| `id` | number? | `id` → `uid`；**若为 `nil` 则就地写 `index`** | `index` |
| `comment` | string? | `comment` → `comment`；并令 `addMemo = !comment.isEmpty` | `""` |
| `selective` | boolean? | `selective` → `selective` | `false`（不是模板的 `true`！） |
| `secondary_keys` | string[]? | `secondaryKeys` → `keysecondary` | `[]` |
| `constant` | boolean? | `constant` → `constant` | `false` |
| `position` | `"before_char"\|"after_char"`? | `position` → 仅在 `extensions.position` 缺失时使用 | 见 §4.4 |
| `use_regex` | boolean? | —— **ST 读取时忽略**（关键词一律按正则处理） | — |

#### `extensions` 子字段 → 内部驼峰字段

| `extensions` 键 | 类型 | 内部字段（Swift 属性） | 缺省回填 |
|---|---|---|---|
| `position` | number | `position: Int` | `nil` ⇒ `position == "before_char" ? 0 : 1` |
| `exclude_recursion` | boolean | `excludeRecursion` | `false` |
| `display_index` | number | `displayIndex` | 条目数组下标 `index` |
| `probability` | number\|null | `probability` | `100`（用 `??`，保留 `0`） |
| `useProbability` | boolean | `useProbability` | `true`（用 `??`，保留 `false`） |
| `depth` | number | `depth` | `4`（`DEFAULT_DEPTH`，`world-info.js:96`） |
| `selectiveLogic` | number | `selectiveLogic` | `0`（`AND_ANY`） |
| `outlet_name` | string | `outletName` | `""` |
| `group` | string | `group` | `""` |
| `group_override` | boolean | `groupOverride` | `false` |
| `group_weight` | number\|null | `groupWeight: Int?` | `100`（内部默认；**转换时 ST 写 `null`**） |
| `prevent_recursion` | boolean | `preventRecursion` | `false` |
| `delay_until_recursion` | boolean | `delayUntilRecursion` | `false` |
| `scan_depth` | number\|null | `scanDepth: Int?` | `nil` |
| `match_whole_words` | boolean\|null | `matchWholeWords: Bool?` | `nil` |
| `use_group_scoring` | boolean\|null | `useGroupScoring: Bool?` | `nil` |
| `case_sensitive` | boolean\|null | `caseSensitive: Bool?` | `nil` |
| `automation_id` | string | `automationId` | `""` |
| `role` | number | `role: Int?` | `0`（`SYSTEM`） |
| `vectorized` | boolean | `vectorized` | `false` |
| `sticky` | number\|null | `sticky: Int?` | `nil` |
| `cooldown` | number\|null | `cooldown: Int?` | `nil` |
| `delay` | number\|null | `delay: Int?` | `nil` |
| `match_persona_description` | boolean | `matchPersonaDescription` | `false` |
| `match_character_description` | boolean | `matchCharacterDescription` | `false` |
| `match_character_personality` | boolean | `matchCharacterPersonality` | `false` |
| `match_character_depth_prompt` | boolean | `matchCharacterDepthPrompt` | `false` |
| `match_scenario` | boolean | `matchScenario` | `false` |
| `match_creator_notes` | boolean | `matchCreatorNotes` | `false` |
| `triggers` | string[] | `triggers` | `[]` |
| `ignore_budget` | boolean | `ignoreBudget` | `false` |
| **其他未知键** | — | 留在 `originalExtensions`，导出时 `...entry.extensions` 展开回去 | — |

### 4.4 position / depth / role 的双向映射

#### position（★ 最容易错的地方）

**读（character_book → 内部数字）：**
```
position = extensions.position            // 数字优先
        ?? (entry.position == "before_char" ? 0 : 1)
```
- `01#9-C-27`、`public/scripts/world-info.js:5636`
- ⚠️ **`entry.position` 为 `nil` 时结果是 `1`（after）**，因为 JS 里 `undefined === 'before_char'` 为 `false`。不是 `0`。
- ⚠️ **`extensions.position` 是唯一能表达 2..7 的通道**（`01#3.4`）。规范里的字符串 `position` 只能表达 0/1。

**写（内部数字 → character_book）：**
```
entry.position = (code == 0) ? .beforeChar : .afterChar   // ★ 只能表达 0 和 1
extensions.position = code                                // ★ 完整信息在这里
```
- 来源：`src/endpoints/characters.js:680`、`:684`
- ⚠️ 注意写侧用的是 `entry.position == 0 ? 'before_char' : 'after_char'`（**不是** `case .beforeChar`），所以 `2..7` 全都会被写成 `"after_char"`，真正的值靠 `extensions.position` 保留。**两者必须同时写**，否则 ST 往返会丢位置。

**双向映射表：**

| 内部 `position` | `character_book.position` | `extensions.position` | 语义 |
|---|---|---|---|
| `0` | `"before_char"` | `0` | 角色定义之前 |
| `1` | `"after_char"` | `1` | 角色定义之后 |
| `2` | `"after_char"` | `2` | Author's Note 顶部 |
| `3` | `"after_char"` | `3` | Author's Note 底部 |
| `4` | `"after_char"` | `4` | 聊天内指定深度 |
| `5` | `"after_char"` | `5` | 示例消息顶部 |
| `6` | `"after_char"` | `6` | 示例消息底部 |
| `7` | `"after_char"` | `7` | Outlet |

#### depth

| 方向 | 规则 |
|---|---|
| 读 | `extensions.depth ?? 4`（`world-info.js:5645`，`DEFAULT_DEPTH = 4`，`world-info.js:96`） |
| 写 | `extensions.depth = entry.depth ?? 4`（`characters.js:689`） |
| 与 position 的关系 | `depth` 只在 `position ∈ {2,3,4}`（ANTop/ANBottom/atDepth）时有意义；但**照 ST 一样无条件写**，不要做条件裁剪 |

#### role

| 方向 | 规则 |
|---|---|
| 读 | `extensions.role ?? 0`（`world-info.js:5656`，`extension_prompt_roles.SYSTEM`） |
| 写 | `extensions.role = entry.role ?? 0`（`characters.js:702`） |
| 类型 | 数字 `0=system / 1=user / 2=assistant`（`public/script.js:494-498`） |
| 注意 | `CharacterCard.depthPrompt.role` 用的是**字符串**形式 `'system'`；两者不要混（`01#3.4` 末尾） |

#### selectiveLogic

| 方向 | 规则 |
|---|---|
| 读 | `extensions.selectiveLogic ?? 0`（`world-info.js:5646`） |
| 写 | `extensions.selectiveLogic = entry.selectiveLogic ?? 0`（`characters.js:690`） |

### 4.5 文档与源码不一致（必须按源码实现）

> ⚠️ `01#3.2` 的表格里 `case_sensitive` 一行写的是「优先取 `extensions.case_sensitive`，否则 `entry.case_sensitive`，都没有则 `null`」。
> **源码不是这样**：`public/scripts/world-info.js:5652` 只有
> ```js
> caseSensitive: entry.extensions?.case_sensitive ?? null,
> ```
> **没有回退到条目级的 `entry.case_sensitive`。**
> 交叉佐证：`public/scripts/world-info.js:2687-2724` 的 `originalWIDataKeyMap`（ST 自己维护的「内部字段 ↔ originalData 路径」权威映射）里也写着 `'caseSensitive': 'extensions.case_sensitive'`。
> **Swift 实现按源码**：只读 `extensions.case_sensitive`；条目级 `entry.case_sensitive` 保留在 `CharacterBookEntry.caseSensitive` 里做无损往返，但**不参与**归一化。

### 4.6 ST 内部条目默认值表 → Swift `WorldInfoEntry` 默认值

来源：`public/scripts/world-info.js:4082-4133`（`newWorldInfoEntryDefinition` → `newWorldInfoEntryTemplate`，`01#3.5`）。

| 内部字段 | ST 模板默认 | Swift 属性默认 | `Codable` 是否总是输出 | 说明 |
|---|---|---|---|---|
| `key` | `[]` | `[]` | 是 | |
| `keysecondary` | `[]` | `[]` | 是 | |
| `comment` | `""` | `""` | 是 | |
| `content` | `""` | `""` | 是 | |
| `constant` | `false` | `false` | 是 | |
| `vectorized` | `false` | `false` | 是 | |
| `selective` | **`true`**（模板） / **`false`**（从卡转换） | `false` | 是 | ⚠️ 见 §4.8-1 |
| `selectiveLogic` | `0` | `0` | 是 | |
| `addMemo` | `false` | `false` | 是 | 从卡转换时 `= !!comment` |
| `order` | `100` | `100` | 是 | |
| `position` | `0` | `0` | 是 | 数字枚举 |
| `disable` | `false` | `false` | 是 | 从卡转换时 `= !enabled` |
| `ignoreBudget` | `false` | `false` | 是 | |
| `excludeRecursion` | `false` | `false` | 是 | |
| `preventRecursion` | `false` | `false` | 是 | |
| `delayUntilRecursion` | **`0`（number）** | `.bool(false)` | 是 | ⚠️ 类型 `bool\|number`，见 §4.8-2 |
| `matchPersonaDescription` | `false` | `false` | 是 | |
| `matchCharacterDescription` | `false` | `false` | 是 | |
| `matchCharacterPersonality` | `false` | `false` | 是 | |
| `matchCharacterDepthPrompt` | `false` | `false` | 是 | |
| `matchScenario` | `false` | `false` | 是 | |
| `matchCreatorNotes` | `false` | `false` | 是 | |
| `probability` | `100` | `100` | 是 | 用 `??` 保留 `0` |
| `useProbability` | `true` | `true` | 是 | 用 `??` 保留 `false` |
| `depth` | `4` | `4` | 是 | `DEFAULT_DEPTH` |
| `outletName` | `""` | `""` | 是 | |
| `group` | `""` | `""` | 是 | |
| `groupOverride` | `false` | `false` | 是 | |
| `groupWeight` | `100`（模板） / `null`（从卡转换） | `nil` | **否**（nil 时省略或输出 `null`，见下） | ⚠️ `01#9-C-30` 明确要求「保留 `null`」 |
| `scanDepth` | `null` | `nil` | 否 | |
| `caseSensitive` | `null` | `nil` | 否 | |
| `matchWholeWords` | `null` | `nil` | 否 | |
| `useGroupScoring` | `null` | `nil` | 否 | |
| `automationId` | `""` | `""` | 是 | |
| `role` | `0`（模板） / `null`（老文件） | `0` | 是（但老文件解出 `nil` 要保留） | 见 §4.8-3 |
| `sticky` | `null`（模板） / `0`（老文件） | `nil` | 否 | 见 §4.8-4 |
| `cooldown` | `null`（模板） / `0`（老文件） | `nil` | 否 | |
| `delay` | `null`（模板） / `0`（老文件） | `nil` | 否 | |
| `triggers` | `[]` | `[]` | 是 | 老条目可能缺 → 默认 `[]`（`04#8.4-4`） |
| `displayIndex` | 条目数组下标 / 老文件存在 | `0` | 是 | 仅 UI 排序 |
| `uid` | 由 `getFreeWorldEntryUid` 分配（不在模板中） | `0` | 是 | 同时是 `entries` 的 key |

**关于 `nil` 的编码**：
- 磁盘世界书要**保留 `null`**（ST 读 `sticky: null` 与 `sticky: 0` 有区别，`04#8.4-4`）。所以 `Codable` 合成实现里 `Int?` 的 `nil` 默认是**省略键**，不是写 `null`。需要自定义 `encode(to:)` 显式 `try c.encodeNil(forKey: .sticky)` 来写出 `"sticky": null`。
- 或者：把这类字段建模为 `JSONValue`（`.null` vs `.integer(0)`）能精确区分「缺失」与 `null` 与 `0`。**推荐**：对 `sticky/cooldown/delay/groupWeight/scanDepth/caseSensitive/matchWholeWords/useGroupScoring/role` 这几个「老文件用 0、新模板用 null」的字段，用 `JSONValue?` 存储，导出时原样回写。
  - 折中方案（本规格推荐）：语义上用 `Int?`/`Bool?`；`encode` 时对**这些字段**统一 `encodeIfPresent` → 写 `null`（因为 ST 新模板就是 `null`，写 `null` 比省略键更接近 ST 实际文件）。省略键 ST 也能读，但会产生文件 diff。

### 4.7 世界书磁盘文件（`worlds/<name>.json`）

```swift
enum WorldInfoStore {
    /// 读取。要求顶层含 entries（04#4.1）；否则视为无效
    static func read(from url: URL) throws -> WorldInfoFile

    /// 写入。4 空格缩进（src/endpoints/worldinfo.js:154），原子写
    static func write(_ file: WorldInfoFile, to url: URL) throws

    /// `{"entries":{}}` 是合法的空世界书（04#8.4-7）
    static func empty() -> WorldInfoFile
}
```
步骤：
1. 读 JSON → 顶层必须是 object
2. `guard root["entries"] != nil` 否则抛 `WorldInfoError.missingEntries`（`src/endpoints/worldinfo.js:114-121`）
3. `entries` 是 object 时：逐 key/value 解成 `WorldInfoEntry`，`uid` 从 value 里读；**若 value 里没有 `uid`，用 key 的整数值兜底**（老文件可能只在外层有 key）
4. `entries` 是**数组**时：按顺序赋 `uid = index`（对第三方写的文件宽容处理，记 warning）
5. `originalData` 若存在 → 解成 `CharacterBook`
6. 序列化：`JSONSerialization` 紧凑 → 再按 §5.4 输出 4 空格缩进；或直接自定义 writer

### 4.8 边界情况与容错要求

| 情况 | 处理 |
|---|---|
| `character_book.entries` 不是数组 | `CharacterBookConversion.toWorldInfoEntries` 返回 `[]` + warning（validator 会判 V2 失败，但导入路径不依赖 validator） |
| `character_book.extensions` 缺失 | 规范要求必填；缺失时用 `[:]` 并 warning |
| `entry.keys` 缺失 | `key = []` |
| `entry.content` 缺失 | `content = ""` |
| `entry.enabled` 缺失 | `disable = true`（★ ST 语义，见易错点 1） |
| `entry.id` 缺失 | 就地补 `index`，**并且要写回原对象**（`01#9-C-25`：注释明说「Not in the spec, but this is needed to find the entry in the original data」） |
| `entry.id` 重复 | ST 后写的覆盖先写的（`result.entries[entry.id] = ...`）。我们：保留第一个，记 warning |
| `extensions.probability = 0` | **必须保留 `0`**（用 `??` 而不是 `||`，`01#9-C-30`） |
| `extensions.useProbability = false` | 同上 |
| `extensions.group_weight = null` | 保留 `nil`，不要回填 `100`（`01#9-C-30` 明确） |
| 未知 `extensions` 键 | 原样透传（`01#9-C-31`） |
| 世界书文件只有 `{"entries":{}}` | 合法空书（`04#8.4-7`） |
| 老条目缺 `triggers`/`ignoreBudget`/`vectorized` | 用默认值 `[]`/`false`/`false`（`04#8.4-4`） |
| 老条目 `sticky/cooldown/delay = 0`，新模板 `null` | 保留原值不做归一（`04#8.4-4`） |
| 世界书文件读不到（`world` 指向不存在的文件） | 卡里**不写** `character_book`，只 warning（`src/endpoints/characters.js:641-643`） |

### 4.9 易错点（模块 D）

1. **`enabled` 缺失 ⇒ 条目被禁用**。`disable: !entry.enabled` 在 JS 里 `!undefined === true`。所以 `CharacterBookEntry.enabled` 必须是 `Bool?`，转换写 `disable = !(enabled ?? false)`。把它写成 `enabled: Bool = true` 会让一张「没写 enabled」的卡在 ST 里全部条目失效。
2. **`delayUntilRecursion` 的类型是 `bool | number`**：模板给 `0`，转换给 `false`，读取时 `?? false`。用 `JSONValue`（或一个能同时吃 `0`/`false` 的 `Bool` 解码助手）承载，不要硬编成 `Bool`——会解码失败让整条 entry 丢掉。
3. **`role` 的 `null` 与 `0` 不同**：`world-info.js` 里 `entry.role ?? 0` 会把 `null` 变成 `0`，但磁盘老文件的 `null` 应当原样保留（`04#8.4-4`）。读磁盘用 `role: Int?`，从卡转换时用 `?? 0`。
4. **`selective` 有两个默认值**：`newWorldInfoEntryTemplate` 里是 `true`，`convertCharacterBook` 里是 `entry.selective || false`（→ `false`）。选哪个取决于代码路径。Swift 侧：**属性默认 `false`**（因为我们的主要入口是「从卡转换」），需要「新建空白条目」时显式用 `true`（`01#3.5` 的警告）。
5. **`addMemo = !!comment`**，不是独立字段。`comment` 非空 ⇒ `addMemo = true`。
6. **`position` 字符串字段在写回时永远写成 `"after_char"`**（只要 code ≠ 0）。真正的位置在 `extensions.position`。只写一个会丢信息。
7. **`entries` 是 object 不是数组**（磁盘）。用 `[String: WorldInfoEntry]`，key = `String(uid)`；不要为了「好看」改成数组，那会让 ST 读不了（`src/endpoints/worldinfo.js:144-154`）。
8. **`originalData` 优先**：导出卡时若 `WorldInfoFile.originalData != nil`，**直接原样写回**，不要走转换（`01#9-C-32`）。这是 ST「导入的书能无损回写」的前提。
9. **`displayIndex` 的缺省是数组下标**，不是 `0`。在一张 20 条目的卡里全填 `0` 会让 UI 排序乱掉。
10. **`entry.extensions` 在 ST 内部是「副本 + 扁平字段」共存**。我们导出时要 `extensions` 里既有未知键又有全部已知键（`...entry.extensions` 展开后再写已知键，`src/endpoints/characters.js:683-714`）。顺序：**先展开 `originalExtensions`，再覆盖已知键**，这样 ST 会以已知键为准（与 ST 写侧一致）。
11. **`convertWorldInfoToCharacterBook` 写的 `useProbability` 默认值是 `false`**（`characters.js:688` 的 `entry.useProbability ?? false`），而读侧默认 `true`（`world-info.js:5644`）。这是 ST 自身的不对称，按源码照做（写 `false`）。
12. **数字与布尔混淆**：`probability`、`groupWeight`、`depth`、`order` 都是数字；但 `useProbability`、`groupOverride` 是布尔；JSON 里 `0`/`1` 与 `false`/`true` 不能互换。`JSONValue` 的 `.intValue` 助手要能识别，但**不要**把 `1` 当 `true`。

---

## 5. 模块 E：导出（JSON / PNG）

### 5.1 需要的 Swift 类型

```swift
enum CharacterExporter {

    struct JSONOptions {
        /// ST 用 4 空格（`JSON.stringify(obj, null, 4)`，01#6.2）
        var indent = 4
        /// `getCharaCardV2` 的 hoistDate：缺 create_date 时补 now（01#9-D-36）
        var hoistCreateDate = true
        /// 导出前 unset fav / chat（01#9-D-35）
        var unsetPrivateFields = true
        /// 是否包含 character_book（默认包含；ST 有书就带，没有就不带）
        var includeCharacterBook = true

        static let stCompatible = JSONOptions()
    }

    /// 导出为 JSON 文本（v2 卡出 v2，v3 卡出 v3 —— 01#9-D-38）
    static func exportJSONString(_ card: CharacterCard,
                                 world: WorldInfoFile? = nil,
                                 options: JSONOptions = .init()) throws -> String

    /// 导出为 JSON Data
    static func exportJSON(_ card: CharacterCard,
                           world: WorldInfoFile? = nil,
                           options: JSONOptions = .init()) throws -> Data

    /// 导出为 PNG：复用原图，只替换角色数据 chunk
    static func exportPNG(_ card: CharacterCard,
                          originalPNG: Data?,
                          world: WorldInfoFile? = nil,
                          options: PNGWriter.Options = .stCompatible) throws -> Data

    /// 导出文件名（ST 的下载名 = avatar 文件名；01#6.1 末尾）
    static func exportFileName(for card: CharacterCard, format: CardFileFormat) -> String

    // 内部步骤
    /// 生成 ST 形状的完整对象（顶层 v1 双写 + spec/spec_version/data）
    static func buildRoot(_ card: CharacterCard, world: WorldInfoFile?) -> [String: JSONValue]

    /// fav=false（顶层 + data.extensions.fav）、删除顶层 chat
    static func unsetPrivateFields(_ root: inout [String: JSONValue])
}
```

### 5.2 导出 JSON 的算法步骤

对应 `src/endpoints/characters.js:1669-1679`。

1. `var root = buildRoot(card, world)` —— 以 `card.rawRoot` 为基底，套用 §3.4 的 `makeV2Root` 全部步骤（保证双写、未知键透传）
2. 若 `options.unsetPrivateFields`：`unsetPrivateFields(&root)`：
   ```swift
   root["fav"] = .bool(false)
   if case .object(var ext) = root["data"]?["extensions"] { ... }   // 见下
   root.removeValue(forKey: "chat")
   ```
   - `data.extensions.fav = false`（**必须写 false，不是删除键**，`01#9-D-35`）
   - 其它 `data.extensions.*` 不动
3. 若 `options.hoistCreateDate && root["create_date"] == nil` → `root["create_date"] = .string(nowISO8601())`
   - ⚠️ 注意是「缺失才补」，不是「总是刷成 now」（`01#6.2`）
4. `spec` / `spec_version`：**保持 `card.specRaw` 原样**
   - v2 卡 → `"chara_card_v2"` / `"2.0"`
   - v3 卡 → `"chara_card_v3"` / `"3.0"`
   - v1 卡（App 内新建）→ 由 `makeV2Root` 写成 `"chara_card_v2"` / `"2.0"`
   - **ST 从不主动升级 v2 → v3**（`01#9-D-38`、`01#6.2`）
5. 序列化：4 空格缩进，**不转义 `/`**，非 ASCII 原样 UTF-8（见 §5.4 的实现）
6. `Data(string.utf8)`

**导出的是 v2 还是 v3？** → **取决于卡里原本是什么**（`01#6.2`）。`getCharaCardV2` 只看 `spec` 是否存在。

**是否包含 `character_book`？**
- 若 `world` 参数非 nil 且该世界书有 `originalData` → 原样写回 `data.character_book`
- 否则若有世界书条目 → `CharacterBookConversion.fromWorldInfo`
- 否则 → **不写 `data.character_book` 键**（不要写 `null`）

### 5.3 导出 PNG 的算法步骤

对应 `src/endpoints/characters.js:1658-1668` + `01#6.1`。

1. `let json = try exportJSONString(card, world: world, options: .init(indent: 0 /* 紧凑 */, ...))`
   - ⚠️ 写进 PNG 的 JSON 是**紧凑**的（`JSON.stringify` 无缩进，与 JSON 导出不同）
2. `let base = originalPNG ?? DefaultAvatarPNG.make(name: card.name)`
3. `let out = try PNGWriter.writeCharacterCard(json: json, into: base)`
   - 内部会自动写 `chara` + `ccv3`（§2.3）
4. 写盘：`try out.write(to: url, options: .atomic)`

**关于「导出不会把 v3 卡降级回 v2」**（`01#6.1` 的警告）：
- ST 的流程是 `read()`（ccv3 优先）→ `mutate` → `write()`。所以一张 v3 卡导出后，`chara` chunk 里其实也是 **v3 标签**的 JSON。
- **本规格的处理**（更干净且完全兼容）：
  - `chara` chunk ← `exportJSONString(card)`，**保持 `card.specRaw` 原样**
  - `ccv3` chunk ← 同内容但 `spec = "chara_card_v3"`、`spec_version = "3.0"`（仅当 `PNGWriter.Options.writesCCv3`）
- 结果验证：实测 `default/content/default_Seraphina.png` 的两个 chunk **除 `spec`/`spec_version` 外逐字节相同**，我们的输出与之同构。

**导出文件名**：
- PNG：`"\(card.avatarFileName)"`（若为空则 `"\(sanitize(card.name)).png"`）
- JSON：`"\(sanitize(card.name)).json"`

### 5.4 JSON 序列化的字节级细节（Swift 与 JS 的差异）

**已在本机 Swift 6.4 上实测的差异**：

| 项 | JS `JSON.stringify` | Swift `JSONEncoder` 默认 | Swift `JSONSerialization` 默认 | 修正 |
|---|---|---|---|---|
| `/` 转义 | 不转义 | **转义成 `\/`** | **转义成 `\/`** | 设 `.withoutEscapingSlashes` |
| 非 ASCII | 原样 UTF-8 | 原样 UTF-8 ✅ | 原样 UTF-8 ✅ | 无需处理 |
| 缩进 | `null, 4` → 4 空格 | `.prettyPrinted` → **2 空格**，且 `"k" : v`（冒号前有空格） | 同 | **自己写 4 空格渲染器** |
| 紧凑 | 无空格 | 默认 ✅ | 默认 ✅ | — |
| 数字 `1.0` | `1` | `1.0`（Double）或 `1`（Int） | `1` | 规范化：整数值输出为 Int |
| 键顺序 | 插入序 | 无序 | 无序 | 语义无影响；字节级测试需归一 |

**推荐实现：自己写一个 4 空格渲染器**，完全对齐 JS：

```swift
enum JSONTextWriter {

    /// 等价于 JS `JSON.stringify(value, null, indent)`，indent == 0 时等价于 `JSON.stringify(value)`
    static func stringify(_ value: JSONValue, indent: Int) -> String {
        var out = ""
        write(value, indent: indent, level: 0, into: &out)
        return out
    }

    private static func write(_ v: JSONValue, indent: Int, level: Int, into out: inout String) {
        switch v {
        case .null:            out += "null"
        case .bool(let b):     out += b ? "true" : "false"
        case .integer(let i):  out += String(i)
        case .number(let d):   out += formatNumber(d)          // ★ 见下
        case .string(let s):   out += quote(s)
        case .array(let a):
            if a.isEmpty { out += "[]"; return }
            let pad = String(repeating: " ", count: indent * (level + 1))
            let closePad = String(repeating: " ", count: indent * level)
            out += "[" + (indent > 0 ? "\n" : "")
            for (i, e) in a.enumerated() {
                if i > 0 { out += "," + (indent > 0 ? "\n" : "") }
                if indent > 0 { out += pad }
                write(e, indent: indent, level: level + 1, into: &out)
            }
            if indent > 0 { out += "\n" + closePad }
            out += "]"
        case .object(let o):
            if o.isEmpty { out += "{}"; return }
            let pad = String(repeating: " ", count: indent * (level + 1))
            let closePad = String(repeating: " ", count: indent * level)
            out += "{" + (indent > 0 ? "\n" : "")
            for (i, kv) in o.sorted(by: { $0.key < $1.key }).enumerated() {
                if i > 0 { out += "," + (indent > 0 ? "\n" : "") }
                if indent > 0 { out += pad }
                out += quote(kv.key) + ":" + (indent > 0 ? " " : "")
                write(kv.value, indent: indent, level: level + 1, into: &out)
            }
            if indent > 0 { out += "\n" + closePad }
            out += "}"
        }
    }

    /// JS 语义：整数值不带小数点和指数
    private static func formatNumber(_ d: Double) -> String {
        if d.isNaN || d.isInfinite { return "null" }         // JS 行为
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return String(d)                                     // Swift 的 Double.description 是短程往返表示
    }

    /// JSON 字符串转义：只转 " \ 和控制字符；★ 不转义 "/"，不转义非 ASCII
    private static func quote(_ s: String) -> String { ... }
}
```

**关于键顺序**：上面的实现用了 `sorted(by:)` 以**保证确定性**（否则每次导出的字节都不同，无法做测试）。这与 ST 的插入序不同，但 JSON 对象无序，语义完全等价。若将来需要**与 ST 逐字节一致**，把 `rawRoot` 换成有序容器（`[(String, JSONValue)]`）即可，其余逻辑不变。

### 5.5 边界情况与容错要求

| 情况 | 处理 |
|---|---|
| `card.rawRoot` 为空（App 内新建） | `buildRoot` 从零构造完整 v2 卡 |
| `card.specRaw == nil`（v1 卡） | 导出时写成 v2（`makeV2Root` 恒写 `spec = "chara_card_v2"`） |
| 没有原始 PNG（JSON 导入） | 用 `DefaultAvatarPNG.make` 生成 512×768 占位图 |
| 原始 PNG 的 CRC 已损坏 | 宽容读入 + 重算写出 = 自动修复 |
| `originalPNG` 不是 PNG | `PNGWriter` 抛错；UI 提示「原图已损坏，改用默认头像？」→ 用户确认后走默认头像 |
| 导出 JSON 时有 `character_book` 但世界书为空 | 仍写 `entries: []`（validator 要求 `entries` 是数组；空数组合法） |
| `character_book.name` 为空 | 导出时填 `"\(card.name)'s Lorebook"`（`01#9-C-33`） |
| 卡的 `name` 为空 | 文件名用 `"unnamed"`；`data.name` 也写 `"unnamed"`（避免 ST 侧出现空名条目） |
| 导出超大卡（含 base64 资产） | 正常；但注意 `JSONSerialization` 对超大对象的性能，优先用 `JSONValue` 直接渲染 |

### 5.6 易错点（模块 E）

1. **JSON 导出是 4 空格缩进，PNG 内嵌是紧凑**。两者不能共用同一个 `indent` 参数。
2. **Swift 的 `.prettyPrinted` 是 2 空格且冒号前有空格**（实测），与 ST 的 `"key": value` 不同。必须自己渲染（§5.4）。
3. **`JSONEncoder` 默认转义 `/`**（实测：`"a/b"` → `"a\/b"`）。虽然合法，但要设 `.withoutEscapingSlashes` 或用 §5.4 的渲染器。
4. **`unsetPrivateFields` 是写 `false` 不是删键**：`fav` 与 `data.extensions.fav` 都要 `false`；`chat` 要删除（`01#9-D-35`）。
5. **`hoistCreateDate` 只在缺失时补**，不要每次都刷。
6. **不要写 `data.character_book: null`**：键存在但值是 `null` 会让某些消费者困惑；ST 的行为是「没有就不写这个键」。
7. **不要给 v3 卡补 v3 字段**：`ccv3` chunk 只改标签（`01#9-A-10`）。
8. **`exportFileName` 要用 sanitize 后的名字**，且 PNG 优先用已有的 `avatarFileName`（保持用户在 ST 里认识的文件名）。
9. **`JSONValue` 的数字类型**：`1.0` 会被解码成 `.integer(1)`（本机实测：`probe 1.0 -> integer(1)`），回写时变 `1`。JSON 语义等价，但如果你的测试做字节比较会失败——测试要比「解析后的对象相等」。
10. **`Data.write(options: .atomic)` 会换掉 inode**：如果外部（Files App / iCloud）持有旧文件句柄，可能读到旧内容。对角色卡这种「整文件替换」是可接受的；聊天 JSONL 同理。

---

## 6. 模块 F：头像存储与文件名规则

### 6.1 需要的 Swift 类型

```swift
// MARK: - 文件名安全化（复刻 sanitize-filename + getUniqueName）

enum FileNameSanitizer {

    /// 复刻 node_modules/sanitize-filename/index.js（默认 replacement = 空串，即【删除】）
    /// 01#7.2、01#9-E-42
    static func sanitize(_ input: String, replacement: String = "") -> String

    /// 复刻 getPngName 的唯一化：`base.png`, `base1.png`, `base2.png`…（无分隔符）
    /// src/endpoints/characters.js:1543-1547 + src/util.js:606-618
    static func uniqueName(base: String,
                           maxTries: Int = 10_000,
                           startIndex: Int = 0,
                           exists: (String) -> Bool) -> String

    /// 聊天目录名 = avatar 去掉最后一个扩展名（public/scripts/utils.js:1342-1347）
    static func stripExtension(_ fileName: String) -> String

    /// 时间戳后缀（复刻 humanizedDateTime）
    /// 格式：`2025-9-26@15h04m33s123ms`（月/日不补零，时/分/秒补 2 位，毫秒补 3 位）
    static func humanizedDateTime(_ date: Date = Date()) -> String

    /// ISO 8601 带毫秒，如 `2025-09-26T07:04:33.123Z`
    static func iso8601(_ date: Date = Date()) -> String
}
```

### 6.2 `sanitize` 算法步骤

对应 `node_modules/sanitize-filename/index.js` + `01#7.2`。

1. `var s = input`
2. **删除非法字符** `/ ? < > \ : * | "` → 替换为 `replacement`（默认空串，即删除）
3. **删除控制字符** `\x00-\x1f` 与 `\x80-\x9f`
4. **纯点号名**（`^\.+$`）：`"."` / `".."` → 删除整个名字
5. **Windows 保留名**：`con|prn|aux|nul|com0-9|lpt0-9`（可带扩展名，**不分大小写**）→ 删除该前缀
6. **结尾的 `.` 和空格** → 删除（`/[\. ]+$/`）
7. **按 UTF-8 字节截断到 255 字节**：
   - 逐字符累加 `String(char).utf8.count`；
   - 超过 255 时**在最后一个完整字符边界截断**（不要切断多字节字符的中间）；
   - 对应 npm 的 `truncate-utf8-bytes`
8. 若 `replacement` 非空：再跑一次 `sanitize(output, "")` 清理替换后新产生的非法字符（`src/util.js:625-627` 的 CharX 用法是 `'_'`）
9. **空结果**：ST 会得到空串（进而产生 `''.png` 这种隐藏文件）；**我们的实现改为返回 `"unnamed"`**，并在规格里标注这是有意的偏离

Swift 实现要点：
```swift
static func sanitize(_ input: String, replacement: String = "") -> String {
    var s = input
    // 2. 非法字符
    let illegal = CharacterSet(charactersIn: "/?<>\\:*|\"")
    s = s.components(separatedBy: illegal).joined(separator: replacement)
    // 3. 控制字符
    s = s.unicodeScalars.filter { !($0.value <= 0x1F || (0x80...0x9F).contains($0.value)) }
         .reduce(into: "") { $0.unicodeScalars.append($1) }
    // 4. 纯点号
    if s.allSatisfy({ $0 == "." }) { s = "" }
    // 5. Windows 保留名
    let reserved = try! NSRegularExpression(
        pattern: "^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\\..*)?$", options: [.caseInsensitive])
    if reserved.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil { s = "" }
    // 6. 结尾点/空格
    while let last = s.last, last == "." || last == " " { s.removeLast() }
    // 7. UTF-8 字节截断到 255
    s = truncateUTF8Bytes(s, max: 255)
    // 8. 二次清理（replacement 非空时）
    if !replacement.isEmpty { s = sanitize(s, replacement: "") }
    // 9. 空结果兜底
    return s.isEmpty ? "unnamed" : s
}
```

### 6.3 唯一化命名

```swift
/// getPngName 的等价物
static func uniquePNGName(base: String, charactersDirectory: URL) -> String {
    let s = sanitize(base)
    return uniqueName(base: s, startIndex: 0, exists: { name in
        FileManager.default.fileExists(atPath:
            charactersDirectory.appendingPathComponent("\(name).png").path)
    })
}
```
- 名字构造：`i == 0 ? base : "\(base)\(i)"` —— **没有分隔符**（不是 `base (1)`）
- `startIndex: 0` 表示「先试不加数字的 `base.png`」
- 最多 10000 次；超限回退 `base`（`?? file`）

**`/duplicate` 用另一套规则**（`src/endpoints/characters.js:1613-1635`）：若名字以 `_数字` 结尾则数字 +1，否则加 `_1`，冲突继续递增。本 App 若做「复制角色」功能，照这套实现。

### 6.4 关于 `_uploads` 等特殊目录名

`04#3.1` 的说明：**`_uploads` 是 `DATA_ROOT` 级的临时目录（`data/_uploads/`），不在 `characters/` 内**（`src/constants.js:219`、`src/server-main.js:268`），是 multer 的上传暂存，处理完立即 `unlink`。

**iOS 上的处理**：
1. **不需要复刻 `_uploads`**。iOS 没有 multipart 上传服务；导入走 `UIDocumentPicker` / `Share Extension`，拿到的是 security-scoped URL。临时拷贝用 `FileManager.default.temporaryDirectory` 或 `.cachesDirectory` 即可。
2. **`characters/` 目录枚举只收 `.png` 普通文件**（`04#3.2`、`src/endpoints/characters.js:1468-1469`）：
   ```swift
   let files = try fm.contentsOfDirectory(at: charactersDirectory,
                                          includingPropertiesForKeys: [.isRegularFileKey],
                                          options: [.skipsHiddenFiles])
   let pngs = files.filter {
       (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
       && $0.pathExtension.lowercased() == "png"
   }
   ```
   这样即使目录里存在 `_covers/`、`sprites/`、`backgrounds/` 之类的子目录（`01#7.1` 提到 ST 会建 `characters/<角色名>/` 放精灵图），也不会被误当角色卡。
3. 若确实要建「特殊目录」，用 `_` 前缀 + 无 `.png` 后缀，靠上面的过滤规则天然排除。

### 6.5 iOS 上的存储布局建议

**总原则**：磁盘布局与 ST **逐字一致**，这样用户的 ST 用户目录可以整目录拷进 App 沙盒（`04#8.1-4`）。

```
Documents/                              ← 启用 UIFileSharingEnabled 后可被「文件」App 访问
├── characters/<internalName>.png        ★ 角色卡 = 头像；卡数据在 PNG 的 tEXt 里，没有独立 JSON
├── chats/<internalName>/<chatName>.jsonl
├── group chats/<chat_id>.jsonl          （群聊，后置）
├── groups/<id>.json                     （群定义，后置）
├── worlds/<name>.json
├── User Avatars/<file>.png              （persona 头像）
├── thumbnails/{avatar,persona,bg}/      （可丢弃缓存；建议放 Caches 而不是 Documents）
├── backups/
│   ├── settings_<handle>_<ts>.json
│   └── chat_<sanitized>_<8位hash>_<ts>.jsonl
└── settings.json
```

**改造现有 `LocalStorage` 的关键点**：

| 现状（`ios/SillyTavern/Services/LocalStorage.swift`） | 改为 |
|---|---|
| `characters/<角色名>.json` 与 `characters/<角色名>.png` **两份** | **只保留 PNG**。JSON 只作为导入/导出交换格式，不落盘（与 ST 一致，`01#7.1`） |
| `sanitizeFileName` 用 `_` 替换非法字符 | 用 §6.2 的 `FileNameSanitizer.sanitize`（**删除**，replacement 空串） |
| `String(trimmed.prefix(120))` 截断 | 按 **255 UTF-8 字节**截断（`01#7.2`） |
| 没有 `worlds/` 之外的目录 | 补 `User Avatars/`、`backups/`、`thumbnails/` |
| 目录不存在时静默返回 `[]` | 启动时建齐目录；读失败要能区分「空目录」与「IO 错误」 |

**头像在 App 内如何显示**：
```swift
enum AvatarProvider {
    /// ★ 始终从【原始 PNG 字节】解码，不要重新编码（H1）
    static func image(forAvatarNamed name: String, in charactersDirectory: URL) -> UIImage? {
        guard let data = try? Data(contentsOf: charactersDirectory
                .appendingPathComponent(name), options: .mappedIfSafe) else { return nil }
        return UIImage(data: data)
    }

    /// 列表缩略图（避免解码 512×768 的大图）
    static func thumbnail(forAvatarNamed name: String, size: CGSize) async -> UIImage? {
        guard let data = try? Data(contentsOf: ...) else { return nil }
        return await UIImage(data: data)?.byPreparingThumbnail(ofSize: size)
    }
}
```

### 6.6 边界情况与容错要求

| 情况 | 处理 |
|---|---|
| 角色名是中文 / Emoji | 文件名保留原字符（`sanitize-filename` 只删 ASCII 非法字符）；255 字节截断要按字符边界 |
| 角色名是 `".."` | `sanitize` → `""` → `"unnamed"` |
| 角色名是 `"CON"` | `sanitize` → `""` → `"unnamed"`（Windows 保留名） |
| 角色名全是不合法字符（`"///"`） | → `"unnamed"` |
| 同名角色再次导入 | `Name.png` 已存在 → `Name1.png`；再导入 → `Name2.png` |
| `avatarFileName` 为空 | 列表显示首字母占位图 |
| `avatarFileName == "none"` | 视为「无头像」（`04#8.4-6`） |
| PNG 文件存在但不是 PNG（扩展名伪造） | `UIImage(data:)` 返回 nil → 显示占位图；导入时 `PNGReader` 抛 `.invalidSignature` |
| 目录不存在的聊天路径 | 按需创建（`src/endpoints/chats.js:599-605`） |
| 文件名含 `/`（攻击路径） | `sanitize` 已删除；额外做一次 `guard !name.contains("/")` 兜底（`src/middleware/validateFileName.js:3`） |

### 6.7 易错点（模块 F）

1. **`sanitize-filename` 是删除不是替换**。现有 `LocalStorage.sanitizeFileName` 用 `_` 替换，会让 `a/b` 得到 `a_b` 而 ST 得到 `ab` → 同一张卡在两边名字不同，聊天目录对不上。
2. **255 是 UTF-8 字节数不是字符数**。用 `prefix(255)` 会把中文名截成 85 个字符，远超预期；且可能切断多字节字符。
3. **唯一的数字后缀没有分隔符**：`Name1.png` 不是 `Name (1).png`。混用会导致重名。
4. **`avatar` 字段不是稳定标识**：卡内恒 `"none"`，运行时才是文件名（`01#9-B-24`）。不要把它写进卡里。
5. **聊天地图目录名 = avatar 去掉 `.png`**：`Seraphina.png` → `chats/Seraphina/`。注意是**去掉最后一个扩展名**（`public/scripts/utils.js:1342-1347`），不是 `replace(".png","")`（后者会误伤 `a.png.png`）。
6. **精灵图目录用【角色名】不是文件名**（`01#7.1`）。如果实现 CharX 精灵图，别混。
7. **不要把 `thumbnails/` 放 Documents**：它是可重生成的缓存，放 `Library/Caches` 避免被 iCloud 同步（`04#1.2` 的注释明确说可丢弃）。
8. **原子写 + 目录创建顺序**：`Data.write(options: .atomic)` 需要父目录已存在，否则抛错。

---

## 7. 模块 G：JSONL 聊天记录读写

### 7.1 需要的 Swift 类型

```swift
// MARK: - 聊天头（JSONL 第 1 行）

/// 对应 04#2.2 的 chat 头对象
struct ChatHeader: Codable, Hashable {
    var chatMetadata: ChatMetadata = .init()
    /// 固定 "unused"，仅向后兼容（04#2.2）
    var userName: String = "unused"
    /// 固定 "unused"，仅向后兼容
    var characterName: String = "unused"
    /// ★ 头部里的未知键必须原样保留
    var unknownFields: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey {
        case chatMetadata = "chat_metadata"
        case userName = "user_name"
        case characterName = "character_name"
    }
}

/// 对应 04#2.3 的 chat_metadata（开放对象）
struct ChatMetadata: Codable, Hashable {
    /// ★ UUID v4 字符串。乐观并发校验用（04#2.8）
    var integrity: String? = nil
    /// 聊天相对于角色卡初始问候是否被改过
    var tainted: Bool? = nil
    /// 本聊天覆盖角色卡的同名字段
    var scenario: String? = nil
    var mesExample: String? = nil
    var systemPrompt: String? = nil
    /// 锁定到本聊天的 persona 头像文件名
    var persona: String? = nil
    /// 本聊天绑定的「聊天世界书」名称
    var worldInfo: String? = nil
    /// sticky/cooldown/delay 的运行态
    var timedWorldInfo: [String: JSONValue]? = nil
    /// Author's Note 状态
    var notePrompt: String? = nil
    var noteInterval: Int? = nil
    var noteDepth: Int? = nil
    var notePosition: Int? = nil
    var noteRole: Int? = nil
    var attachments: [JSONValue]? = nil
    /// 该文件从哪个聊天分支出来
    var mainChat: String? = nil
    var lastInContextMessageId: Int? = nil
    /// ★ 未知键（扩展可自由加 key，04#2.3 末行）
    var unknownFields: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey {
        case integrity, tainted, scenario, persona, attachments
        case mesExample = "mes_example"
        case systemPrompt = "system_prompt"
        case worldInfo = "world_info"
        case timedWorldInfo
        case notePrompt = "note_prompt"
        case noteInterval = "note_interval"
        case noteDepth = "note_depth"
        case notePosition = "note_position"
        case noteRole = "note_role"
        case mainChat = "main_chat"
        case lastInContextMessageId
    }
}

// MARK: - 消息

/// SwipeInfo（04#2.4 表）
struct SwipeInfo: Codable, Hashable {
    var sendDate: String? = nil
    var genStarted: String? = nil
    var genFinished: String? = nil
    var extra: MessageExtra? = nil
}

/// ★ 重写现有 Models/ChatMessage.swift
struct ChatMessage: Identifiable, Codable, Hashable {
    var id: UUID = UUID()                 // 本地，不参与编解码

    var name: String = ""
    var mes: String = ""
    var isUser: Bool = false
    var isSystem: Bool = false
    /// ★ ISO 8601 字符串，如 "2025-09-26T07:04:33.123Z"（04#2.4）
    var sendDate: String = ChatJSONL.nowISO8601()
    var title: String? = nil
    var genStarted: String? = nil
    var genFinished: String? = nil
    var extra: MessageExtra = .init()
    /// 仅 AI 消息；`swipes[swipeId] == mes` 必须成立（04#8.1-④）
    var swipes: [String]? = nil
    var swipeId: Int? = nil
    /// 与 swipes 等长（04#8.1-⑤）
    var swipeInfo: [SwipeInfo]? = nil
    /// 群聊/锁定 persona 时的强制头像
    var forceAvatar: String? = nil
    /// 群聊时的发言角色原始头像文件名
    var originalAvatar: String? = nil
    /// ★ 未知键必须原样保留
    var unknownFields: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey {
        case name, mes, title, extra, swipes
        case isUser = "is_user"
        case isSystem = "is_system"
        case sendDate = "send_date"
        case genStarted = "gen_started"
        case genFinished = "gen_finished"
        case swipeId = "swipe_id"
        case swipeInfo = "swipe_info"
        case forceAvatar = "force_avatar"
        case originalAvatar = "original_avatar"
    }
}

/// ★ 重写现有 MessageExtra（04#2.5）
struct MessageExtra: Codable, Hashable {
    var api: String? = nil
    var model: String? = nil
    var reasoning: String? = nil
    var reasoningDuration: Double? = nil
    var reasoningSignature: String? = nil
    var reasoningDisplayText: String? = nil
    var tokenCount: Int? = nil
    var bias: String? = nil
    var isSmallSys: Bool? = nil
    var usesSystemUI: Bool? = nil
    var swipeable: Bool? = nil
    var genId: Int? = nil
    var type: String? = nil
    var displayText: String? = nil
    var media: [JSONValue]? = nil
    var mediaIndex: Int? = nil
    var mediaDisplay: String? = nil
    var inlineImage: Bool? = nil
    var files: [JSONValue]? = nil
    var branches: [String]? = nil
    var bookmarkLink: String? = nil
    var memory: String? = nil
    /// ★ 未知子字段（ST 自己就是 `Record<string, any>` 透传，04#2.5 末）
    var unknownFields: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey {
        case api, model, reasoning, bias, type, media, files, branches, memory
        case reasoningDuration = "reasoning_duration"
        case reasoningSignature = "reasoning_signature"
        case reasoningDisplayText = "reasoning_display_text"
        case tokenCount = "token_count"
        case isSmallSys, usesSystemUI = "uses_system_ui", swipeable
        case genId = "gen_id"
        case displayText = "display_text"
        case mediaIndex = "media_index"
        case mediaDisplay = "media_display"
        case inlineImage = "inline_image"
        case bookmarkLink = "bookmark_link"
    }
}

// MARK: - 文件

struct ChatFile: Hashable {
    var header: ChatHeader
    var messages: [ChatMessage]
    /// 读取时容忍的问题
    var warnings: [ChatParseWarning] = []
    /// 物理行数（用于 chat_items 统计，04#3.2）
    var physicalLineCount: Int = 0
    /// 最后一行不可解析（截断容错）
    var lastLineUnparsable = false
}

enum ChatParseWarning: Equatable {
    case bomStripped
    case firstLineIsNotHeader
    case unparsableLine(index: Int)
    case truncatedLastLine(index: Int)
    case swipeIndexOutOfRange(messageIndex: Int)
    case swipeInfoCountMismatch(messageIndex: Int)
}

enum ChatIntegrityError: Error, Equatable {
    /// 磁盘上的 integrity 与内存中的不一致
    case mismatch(expected: String, onDisk: String)
}

enum ChatJSONL {

    struct DecodeOptions {
        /// 去掉 UTF-8 BOM（04#8.4-3）
        var stripBOM = true
        /// 最后一行被截断时容忍（04#8.4-2）
        var tolerateTruncatedLastLine = true
        /// 第 1 行没有 chat_metadata 时把它当消息（04#8.4-1）
        var treatNonHeaderFirstLineAsMessage = true
        /// 解析失败的行是跳过还是整体失败
        var skipUnparsableLines = true

        static let `default` = DecodeOptions()
    }

    // MARK: 读

    static func decode(_ data: Data, options: DecodeOptions = .default) throws -> ChatFile

    static func decode(contentsOf url: URL, options: DecodeOptions = .default) throws -> ChatFile

    /// 只读第一行，取 chat_metadata（用于 integrity 校验，不整文件加载）
    static func readHeader(from url: URL) -> ChatHeader?

    // MARK: 写

    static func encode(_ chat: ChatFile) throws -> Data

    /// 原子写 + integrity 预校验
    /// - Parameters:
    ///   - expectedIntegrity: 内存中期望的 integrity；为 nil 时跳过校验
    static func write(_ chat: ChatFile,
                      to url: URL,
                      expectedIntegrity: String?,
                      skipIntegrityCheck: Bool = false) throws

    // MARK: 助手

    static func nowISO8601(_ date: Date = Date()) -> String
    static func makeIntegrity() -> String            // UUID v4 字符串
    static func chatItemCount(_ chat: ChatFile) -> Int   // 04#3.2 的统计语义
}
```

### 7.2 写入算法步骤

对应 `src/endpoints/chats.js:532-533`、`04#2.1`、`04#8.1-1`。

1. **规整消息**（保证 ST 侧不变量）：
   1. 对每条 AI 消息（`isUser == false`）：
      - 若 `swipes == nil || swipes!.isEmpty` → `swipes = [mes]`
      - 若 `swipeId == nil || !(0..<swipes!.count).contains(swipeId!)` → `swipeId = 0`，并令 `mes = swipes![0]`
      - 若 `swipes![swipeId!] != mes` → `mes = swipes![swipeId!]`（**④ 不变量**）
      - 若 `swipeInfo` 为 nil → 建 `swipes!.count` 个空 `SwipeInfo()`
      - 若 `swipeInfo!.count != swipes!.count` → 补/截到等长（**⑤ 不变量**）
   2. 对用户消息：`swipes = nil`、`swipeId = nil`、`swipeInfo = nil`
   3. 系统消息（`isSystem == true`）：`extra.swipeable = false`（`public/scripts/system-messages.js:41`）
2. **构造头部行**：
   ```json
   {"chat_metadata":{...},"user_name":"unused","character_name":"unused"}
   ```
   - `chat_metadata` 用 `ChatMetadata` 编码，未知键合并回去
   - `user_name` / `character_name` **恒为 `"unused"`**（`04#2.2`）
   - ⚠️ 不要写 `create_date` / `chat_id`：当前版本不写入 chat 头（`04#2.2` 的警告）
3. **逐行紧凑序列化**：`lines = [headerJSON] + messages.map { compactJSON($0) }`
   - 紧凑 = 无缩进（`JSON.stringify` 默认行为）
   - **不要 `.prettyPrinted`**（`04#8.1-⑦`：缩进会破坏 ST 的逐行解析器）
4. **拼接**：`let text = lines.joined(separator: "\n")` —— **没有结尾换行**（`04#2.1`、`04#8.1-1`）
5. `let data = Data(text.utf8)` —— **不加 BOM**
6. **integrity 预校验**（§7.5）：
   - `skipIntegrityCheck == false && expectedIntegrity != nil` 时：
     - 目标文件不存在 → 通过
     - 文件大小为 0 → 通过
     - 读首行、去 BOM、`JSON.parse`；**首行不是 JSON 对象** → **不通过**（保守，防止覆盖外部编辑过的文件，`src/endpoints/chats.js:352-357`）
     - 首行里没有 `chat_metadata.integrity` → 通过（老聊天，`src/endpoints/chats.js:361-365`）
     - 有且 != `expectedIntegrity` → **抛 `ChatIntegrityError.mismatch`**，不写
7. `try data.write(to: url, options: .atomic)`（对应 ST 的 `write-file-atomic`，`04#2.1`）
8. **备份**（可选，成本极低）：把同一份 `data` 复制到
   `backups/chat_<sanitized>_<8位hash>_<ts>.jsonl`
   - 格式 = 聊天文件本身的**字节副本**，无额外头（`04#7`）

### 7.3 读取算法步骤

对应 `src/endpoints/chats.js:577-590`、`04#8.4`。

1. `let data = try Data(contentsOf: url, options: .mappedIfSafe)`
2. `guard !data.isEmpty` → 返回空 `ChatFile`（`header: ChatHeader()`、`messages: []`、`physicalLineCount: 0`）
3. **去 BOM**（`04#8.4-3`）：若前 3 字节是 `EF BB BF` → 跳过，记 `.bomStripped`
4. **按 `\n` 切分**：`let rawLines = text.components(separatedBy: "\n")`
   - 每行若以 `\r` 结尾 → 去掉（容忍 CRLF）
   - **若最后一个元素是空串**（文件有尾随换行）→ 丢弃它（ST 的文件没有尾随换行，但外部编辑器可能加）
5. `physicalLineCount = lines.count`
6. **第 1 行判定**（`src/endpoints/chats.js:459-464`、`04#2.2` 末）：
   - 解析为 JSON object 且 `chat_metadata` 是 object → 作为 `ChatHeader`
   - 否则 → **把它当普通消息处理**，`ChatHeader` 用空值，记 `.firstLineIsNotHeader`（`04#8.4-1`，老版本群聊的情况）
7. **逐行解析剩余行**：
   - `JSON.parse` 失败或结果不是 object →
     - 若是**最后一行** → 记 `.truncatedLastLine`，`lastLineUnparsable = true`（`04#8.4-2`）
     - 否则 → 记 `.unparsableLine(index:)`，跳过（`skipUnparsableLines` 为 false 时整体抛错）
     - **这是 ST 的 `getChatData()` 行为**：`lines.map(tryParse).filter(x => x)`（`src/endpoints/chats.js:584`）
   - 成功 → 解成 `ChatMessage`，缺字段用默认
8. **后处理每条消息**：
   - `sendDate` 缺失 → 用文件 mtime 的 ISO（`src/endpoints/chats.js:485` 的兜底逻辑）
   - `swipeId` 越界 → clamp 到 0 + warning
   - `swipeInfo` 数量不匹配 → 补齐 + warning（**只读不改**，写的时候才规整）
9. `chat_items` 统计（`04#3.2` 的语义，用于列表预览）：
   - 正常：`physicalLineCount - 1`（减掉 metadata 行）
   - 最后一行不可解析：`max(physicalLineCount - 2, 0)`
   - 空文件：`0`
   - 预览 `mes`：最后一条可解析消息的 `mes`；为空则 `"[The message is empty]"`
   - `last_mes`：最后一条的 `send_date`；缺失则文件 mtime 的 ISO

### 7.4 字段映射表（`04#2.4` / `04#2.5` → Swift）

#### 消息字段

| JSONL 字段 | 类型 | Swift `ChatMessage` | 默认 | 来源 |
|---|---|---|---|---|
| `name` | string | `name` | `""` | `04#2.4` |
| `mes` | string | `mes` | `""` | |
| `is_user` | boolean | `isUser` | `false` | |
| `is_system` | boolean | `isSystem` | `false` | 通常省略；用户消息显式 `false` |
| `send_date` | string **ISO 8601** | `sendDate` | now ISO | ★ 不是 `"yyyy-MM-dd HH:mm:ss"` |
| `title` | string? | `title` | `nil` | |
| `gen_started` | string? ISO | `genStarted` | `nil` | 仅 AI 消息 |
| `gen_finished` | string? ISO | `genFinished` | `nil` | 仅 AI 消息 |
| `extra` | object | `extra: MessageExtra` | `{}` | |
| `swipes` | string[]? | `swipes: [String]?` | `nil` | 仅 AI 消息 |
| `swipe_id` | number? | `swipeId: Int?` | `nil` | |
| `swipe_info` | SwipeInfo[]? | `swipeInfo: [SwipeInfo]?` | `nil` | 与 swipes 等长 |
| `force_avatar` | string? | `forceAvatar` | `nil` | |
| `original_avatar` | string? | `originalAvatar` | `nil` | |
| 其他 | — | `unknownFields` | `[:]` | 必须保留 |

#### `extra` 子字段（`04#2.5` 全表）

| 子字段 | 类型 | Swift `MessageExtra` | 说明 |
|---|---|---|---|
| `api` | string | `api` | `openai` / `kobold` / `textgenerationwebui` … |
| `model` | string | `model` | |
| `reasoning` | string | `reasoning` | 思维链原文 |
| `reasoning_duration` | number\|null | `reasoningDuration: Double?` | ms |
| `reasoning_signature` | string\|null | `reasoningSignature` | Anthropic 签名 |
| `reasoning_display_text` | string | `reasoningDisplayText` | 展示用 |
| `token_count` | number | `tokenCount: Int?` | |
| `bias` | string | `bias` | 用户消息的 bias 文本 |
| `isSmallSys` | boolean | `isSmallSys` | ★ 大小写混合，别写成 `is_small_sys` |
| `uses_system_ui` | boolean | `usesSystemUI` | |
| `swipeable` | boolean | `swipeable` | `false` 时不可滑动 |
| `gen_id` | number | `genId` | 群聊同一次生成 |
| `type` | string | `type` | `help`/`welcome`/`assistant_note`… |
| `display_text` | string | `displayText` | 导出 txt 时替代 `mes` |
| `media` | array | `media: [JSONValue]?` | `{url,title,type,source,...}` |
| `media_index` | number | `mediaIndex` | |
| `media_display` | string | `mediaDisplay` | `list`/`gallery` |
| `inline_image` | boolean | `inlineImage` | |
| `files` | array | `files: [JSONValue]?` | FileAttachment[] |
| `branches` | string[] | `branches` | 分支聊天名 |
| `bookmark_link` | string | `bookmarkLink` | 书签名 |
| `memory` | string | `memory` | 已废弃 |
| `[IGNORE_SYMBOL]` | boolean | `unknownFields` | 键名是运行时常量，用 unknownFields 承接 |
| 其他 | — | `unknownFields` | 原样透传 |

#### `ChatMetadata` 已知键

见 §7.1 的 `ChatMetadata` 定义，逐条对应 `04#2.3` 表格。

### 7.5 integrity 是否实现？

**实现，但按「软校验」的方式**。理由与做法：

| 项 | 决定 | 依据 |
|---|---|---|
| 是否保留 `integrity` 字段 | **保留**（读进 `ChatMetadata.integrity`，写回原值） | `04#2.8`、`04#8.2` |
| 读取时若缺失是否生成 | **生成一个 UUID v4 并写回**（与 ST 客户端一致，`public/script.js:7665-7667`） | `04#2.8` |
| 写入前是否比对 | **比对，但不硬失败**：不一致时抛 `ChatIntegrityError.mismatch`，由 UI 弹「文件已被其他设备修改，是否覆盖？」→ 用户确认后用 `skipIntegrityCheck: true` 重试 | `04#2.8`、`src/endpoints/chats.js:532-543` |
| 首行非 JSON | **视为不一致**（保守，防止覆盖外部编辑过的文件） | `src/endpoints/chats.js:352-357` |
| 文件不存在 / 为空 / 无 integrity | **通过** | `src/endpoints/chats.js:339-365` |
| iCloud 多端场景 | 这正是它最有价值的地方（`04#2.8` 的 iOS 建议） | `04#8.2` |

**必须比对的场景**：聊天在 App 内被打开（内存持有 integrity）→ 用户编辑 → 保存。保存前读一次磁盘首行，比对。

### 7.6 iOS 容错清单（`04#8.4` 逐条落地）

| # | `04#8.4` 原文 | Swift 落地 |
|---|---|---|
| 1 | 第 1 行可能是**没有** `chat_metadata` 的旧文件 → 当普通消息处理 + 自建空 metadata | `decode` 步骤 6：`if jsonObject["chat_metadata"] is object → header else → 当消息`；记 `.firstLineIsNotHeader` |
| 2 | 最后一行可能被截断 → `chat_items = 行数 - 2`、预览置空 | `decode` 步骤 7 + 9；`lastLineUnparsable = true` |
| 3 | 第 1 行可能带 UTF-8 BOM → `replace(/^\uFEFF/,'')` | `decode` 步骤 3（去 `EF BB BF`） |
| 4 | 老世界书条目可能缺 `triggers`/`ignoreBudget`/`vectorized`，且 `sticky/cooldown/delay` 是 `0` 而新模板是 `null` | 模块 D §4.6：全部「可选 + 默认值」；`sticky/cooldown/delay` 用 `Int?` 原样保留 |
| 5 | 角色卡可能是 V1（无 `spec`）→ 需要 V1→V2 升级 | 模块 C §3.3 `normalizeV1` |
| 6 | `avatar: 'none'` 表示无头像 | `AvatarProvider`：`avatarFileName == "none"` 视为空 |
| 7 | 世界书文件可能只有 `{"entries":{}}` | `WorldInfoStore.empty()`；解码时不因空 entries 报错 |
| — | （追加）swipes 不变量被外部破坏 | 读取时只在内存里记录 warning，写入时按 §7.2 步骤 1 规整 |

### 7.7 边界情况与容错要求

| 情况 | 处理 |
|---|---|
| 空文件（0 字节） | 空 `ChatFile`（`src/endpoints/chats.js:501-502`） |
| 只有 header 行 | `messages = []`，`chat_items = 0` |
| 文件末尾有空行 | 丢弃最后的空元素，不计入行数 |
| CRLF 换行 | 每行去掉尾随 `\r` |
| 中间某行 JSON 损坏 | 跳过该行 + warning（`src/endpoints/chats.js:584` 的 `filter(x => x)`） |
| 某行是数组 / 字符串 | 同上跳过 |
| `mes` 是 `null` | 当作 `""` |
| `send_date` 缺失 | 用文件 mtime 的 ISO |
| `swipes` 存在但 `swipe_id` 缺失 | clamp 到 `0` |
| `swipes` 存在但 `mes` 与之不符 | 只读时不动；写时按 §7.2 规整 |
| `swipe_info` 比 `swipes` 短 | 补齐空 `SwipeInfo()`；warning |
| 文件被外部并发修改 | integrity 校验拦截（§7.5） |
| 消息 `name` 是空串 | 保留（群聊里可能真的有） |
| 单文件 100 MB | `mappedIfSafe` + 按行流式处理；MVP 可以全量加载（ST 也是全量，`src/endpoints/chats.js:577-590`） |

### 7.8 易错点（模块 G）

1. **`send_date` 必须是 ISO 8601**。现有 `ChatMessage.timestamp()` 产出 `"2025-09-26 15:04:33"`（本地时间、无 `T`、无 `Z`、无毫秒），**这是必须修的 bug**。正确形式：`"2025-09-26T07:04:33.123Z"`（UTC + 毫秒）。
2. **文件末尾不能有换行**。`lines.joined(separator: "\n")` 即可；不要 `+ "\n"`。
3. **不能有 BOM**。
4. **不能缩进**。`JSONEncoder` 默认紧凑 ✅；一旦开了 `.prettyPrinted`，ST 的 `readline` 逐行解析会全线失败。
5. **`JSONEncoder` 默认转义 `/`**（本机实测）。JSONL 里 `</think>` 会变成 `<\/think>`。语义合法、ST 能解析，但会污染字节级测试。建议全局统一：`encoder.outputFormatting = [.withoutEscapingSlashes]`，或直接用 §5.4 的渲染器。
6. **`swipes[swipe_id] === mes`**：这是 ST 的硬不变量。写入前必须规整（`04#8.1-④`）。
7. **群聊文件格式与单聊完全一致**（`04#2.7`），靠 `name` + `force_avatar` + `original_avatar` 区分发言者。不要为群聊设计另一套结构。
8. **`extra.isSmallSys` 是驼峰，`uses_system_ui` 是下划线**。ST 的字段命名不统一，逐个按表映射，别用统一的转换规则。
9. **`chat_metadata` 是开放对象**，扩展会加任意 key（`04#2.3` 末行）。必须用 `unknownFields` 承接，否则用户装了扩展后聊天记录会掉数据。
10. **不要写 `create_date` / `chat_id` 到 chat 头**（`04#2.2` 的警告）。它们是旧版/其他客户端的历史字段，当前 ST 不写。**读取时要容忍但不依赖**。
11. **`chat_items` 是「总行数 - 1」而不是「成功解析的消息数」**（`04#3.2`）。截断时是「行数 - 2」。这会影响列表预览的数字。
12. **`is_system` 的消息不进 prompt、导出 txt 时跳过**（`04#2.6`）。这是渲染层的事，但不要在存储层把它们删掉。
13. **写入前先备份**：ST 每次保存都会写一份 `backups/chat_*.jsonl`（`src/endpoints/chats.js:542`）。这是最廉价的「撤销误删」，实现成本几乎为零（`04#7`）。

---

## 8. 模块 H：单元测试清单

### 8.1 测试夹具（Fixtures）

放在 `ios/SillyTavernTests/Fixtures/`：

| 夹具 | 来源 | 用途 |
|---|---|---|
| `seraphina.png` | 复制 `default/content/default_Seraphina.png`（约 511 KB IDAT + 两个 tEXt） | ★ 真实 ST 生成的卡，v2+v3 双 chunk golden file |
| `seraphina_chara.json` | 从上面的 PNG 里解出的 `chara` chunk 明文 | 字段级断言基线 |
| `seraphina_ccv3.json` | 同上，`ccv3` chunk 明文 | 验证「只差 spec/spec_version」 |
| `v1_card.json` | 手写（`01#10.2` 的示例） | v1 归一化 |
| `v2_clean.json` | 手写（`01#10.1` 的示例，但**只保留 spec/spec_version/data**） | 「干净 v2 卡」路径 |
| `v2_dual.json` | 手写（`01#10.1` 全量，含双写顶层字段 + character_book） | 双写 hack |
| `v3_card.json` | 由 `v2_dual` 改标签 + 加 `nickname`/`assets`/`creation_date` | v3 透传 |
| `gradio_card.json` | `{char_name, char_persona, char_greeting, world_scenario, example_dialogue}` | Gradio 路径 |
| `eldoria.json` | 复制 `default/content/Eldoria.json` | 磁盘世界书（object entries，含老式 `sticky: 0`） |
| `chat.jsonl` | 手写（`04#2.9` 的示例） | JSONL 往返 |
| `chat_bom.jsonl` | 上面 + BOM | BOM 容错 |
| `chat_truncated.jsonl` | 上面去掉最后一行的后半截 | 截断容错 |
| `chat_no_header.jsonl` | 去掉第 1 行 | 老群聊格式容错 |
| `chat_unknown_fields.jsonl` | 消息里塞 `"extra":{"vendor_xyz":123}` 与 metadata 塞未知键 | 未知键透传 |

**夹具生成脚本**（开发机一次性执行，不入库）：
```bash
node -e '
const extract=require("png-chunks-extract"),T=require("png-chunk-text"),fs=require("fs");
const c=extract(new Uint8Array(fs.readFileSync("default/content/default_Seraphina.png")));
for(const x of c.filter(c=>c.name==="tEXt")){
  const d=T.decode(x.data);
  fs.writeFileSync(`/tmp/seraphina_${d.keyword}.json`,
    Buffer.from(d.text,"base64").toString("utf8"));
}'
```

### 8.2 测试用例清单

#### A. PNG 解析器（模块 A）

| # | 用例 | 断言 |
|---|---|---|
| A-01 | `CRC32.compute("123456789")` | `== 0xCBF43926` |
| A-02 | `CRC32.chunk(type:"IEND", data: Data())` | `== 0xAE426082` |
| A-03 | 用 `seraphina.png` 解析 chunk | chunk 序列 `["IHDR","IDAT","tEXt","tEXt","IEND"]`，长度 `[13,511505,20158,20157,0]` |
| A-04 | `seraphina.png` 全部 chunk 的 `crcMatches` | 全为 `true` |
| A-05 | `readCharacterJSON(seraphina.png)` | 解析后 `spec == "chara_card_v3"`、`spec_version == "3.0"`（★ **`ccv3` 优先**，返回的是 v3 那份，`01#9-A-3`） |
| A-06 | 同一文件的 `chara` chunk 单独解码 | `spec == "chara_card_v2"`、`spec_version == "2.0"`（与 A-05 形成对照） |
| A-07 | 两 chunk 明文对比 | 除 `spec`/`spec_version` 外**逐字节相同** |
| A-08 | 构造只有 `chara` 的 PNG | 能读出 v2 |
| A-09 | 构造两个 `chara`（内容不同） | 取**第一个** |
| A-10 | keyword 写成 `CHARA` / `CcV3` | 能命中（大小写不敏感） |
| A-11 | 有 `tEXt(parameters)` 无 chara/ccv3 | 抛 `.noCharacterData` |
| A-12 | 没有任何 `tEXt` | 抛 `.noTextChunks` |
| A-13 | 输入 JPEG 字节 | 抛 `.invalidSignature`，`actual` 前 8 字节 = JPEG magic |
| A-14 | 输入空 `Data` | 抛 `.emptyInput` |
| A-15 | 截断在 IHDR 中间 | 抛 `.truncated` |
| A-16 | 截断在 IEND 之前 | 抛 `.missingIEND` |
| A-17 | 首个 chunk 是 `IDAT` | 抛 `.firstChunkIsNotIHDR` |
| A-18 | `IEND` 的 length 写成 5 | 抛 `.iendNotEmpty`（严格）/ 容忍（宽容） |
| A-19 | 改坏某个 `IDAT` 的 CRC 字节 | `.strict` 抛 `.crcMismatch`；`.lenient` 成功 + warning |
| A-20 | 改坏 `tEXt(chara)` 的 CRC 字节 | `.lenient` 仍能读出卡 |
| A-21 | `tEXt` 内容里插一个 `0x00` | `.strictST` 抛；`.lenient` 截断 + warning |
| A-22 | base64 换成缺 padding 的形式 | 能解码（补 padding） |
| A-23 | base64 里插入 `\n` | 能解码 |
| A-24 | base64 换成 URL-safe 字母表（含 `+`/`/` 的载荷） | 能正确解码（**这是 `.ignoreUnknownCharacters` 会静默出错的场景**） |
| A-25 | base64 内容乱写 | 抛 `.invalidBase64` |
| A-26 | 卡数据是 UTF-16LE 编码后再 base64 | 能解码（容错链） |
| A-27 | 构造 iTXt（未压缩）只有 `chara` | `allowsITXt == true` 时能读出；`false` 时抛 `.noCharacterData` |
| A-28 | 同时有 `tEXt(chara)` 与 `iTXt(chara)` | tEXt 优先 |
| A-29 | 构造 iTXt（压缩标志 = 1） | 被跳过 + `.iTXtCompressed` warning |
| A-30 | `IEND` 之后追加垃圾字节 | 解析成功 + `.trailingBytesAfterIEND` warning |
| A-31 | `IHDR` 后插一个未知 chunk 类型 `prVt` | 解析成功，chunk 数量 +1 |
| A-32 | 解析 `seraphina.png` 后 `image.raw` | `== 输入 Data`（**只读保证**） |
| A-33 | 大 chunk（length 声称 4 GB） | 抛 `.chunkTooLarge`，不 OOM |

#### B. PNG 写入器（模块 B）

| # | 用例 | 断言 |
|---|---|---|
| B-01 | `writeCharacterCard(json: v2json, into: seraphina.png)` | 输出 chunk 序列 `["IHDR","IDAT","tEXt","tEXt","IEND"]`，两个 tEXt 的 keyword 依次为 `chara`、`ccv3` |
| B-02 | B-01 输出的所有 chunk CRC | 全部匹配 |
| B-03 | B-01 输出的 `IDAT` | **逐字节等于**原图的 `IDAT`（像素未被重编码） |
| B-04 | B-01 输出 → `readCharacterJSON` | 返回的 JSON 对象与原 json 对象**深度相等** |
| B-05 | B-01 输出的 `chara` 明文 | `spec == "chara_card_v2"`；`ccv3` 明文 `spec == "chara_card_v3"`、`spec_version == "3.0"` |
| B-06 | B-05 两份明文 | 除 `spec`/`spec_version` 外深度相等（**不注入 v3 新字段**） |
| B-07 | 对一个含 `tEXt(parameters)` 的 PNG 写卡 | `parameters` 保留 |
| B-08 | 对已有 `chara` 的 PNG 再写一次 | 只有一份 `chara`、一份 `ccv3`（旧的被删） |
| B-09 | 对一个 `iTXt(chara)` 的 PNG 写卡 | iTXt 不被删除（ST 行为） |
| B-10 | `json` 不是合法 JSON 时写卡 | `chara` chunk 正常写入；**没有** `ccv3` chunk（静默跳过） |
| B-11 | 输入 CRC 损坏的 PNG | 输出全部 CRC 正确（自动修复） |
| B-12 | `makeTextChunk(keyword: String(repeating:"a",count:80), ...)` | 抛 `.keywordTooLong` |
| B-13 | `makeTextChunk(keyword:"chara", text:"a\0b")` | 抛 `.nullInContent` |
| B-14 | `makeTextChunk(keyword:"é", text:"x")` | 成功（Latin-1 允许 `0xE9`） |
| B-15 | `makeTextChunk(keyword:"中", text:"x")` | 抛 `.notLatin1` |
| B-16 | `encodeChunks` 的输出长度 | `== 8 + Σ(len + 12)` |
| B-17 | `encodeChunks` 的首 8 字节 | `== PNG 签名` |
| B-18 | `writeCharacterCard` 后原 `Data` 未被修改 | 输入 `Data` 的字节与调用前一致 |

#### C. 导入归一化（模块 C）

| # | 用例 | 断言 |
|---|---|---|
| C-01 | `detectSpec(v2_dual)` | `.v2` |
| C-02 | `detectSpec(v3_card)` | `.v3` |
| C-03 | `detectSpec(v1_card)` | `.v1` |
| C-04 | `detectSpec(gradio_card)` | `.v1`（走 Gradio 子分支） |
| C-05 | `detectSpec([:])` | `nil` |
| C-06 | `detectSpec({"spec":"weird_thing"})` | `.v2`（**只看存在性**，`01#9-B-11`） |
| C-07 | `detectSpec({"spec":"chara_card_v2"})`（无 data） | `.v2`，`normalizeV2` 不抛错（hack 13） |
| C-08 | `importPNG(seraphina.png)` | `detectedSpec == .v3`（ccv3 优先）；`originalPNG != nil`；`originalJSON` 是 ccv3 那份 |
| C-09 | C-08 的 `card.name` | 与 `seraphina_chara.json` 的 `data.name` 一致 |
| C-10 | C-08 的 `card.rawRoot` | 含全部 16 个顶层键（含 `group_only_greetings` 在 `data` 里） |
| C-11 | v1 卡导入 | `creatorNotes` 来自 `creatorcomment` |
| C-12 | 顶层 `creatorcomment="A"`、`data.creator_notes="B"` | 结果 `"B"`（`data` 优先）+ warning |
| C-13 | `talkativeness` 完全缺失 | `== 0.5` |
| C-14 | `fav` 完全缺失 | `== false` |
| C-15 | `fav` 是字符串 `"true"` | `== true` |
| C-16 | `talkativeness` 是字符串 `"0.5"` | `== 0.5` |
| C-17 | `tags` 是 `"a, b , ,c"` | `== ["a","b","c"]` |
| C-18 | `tags` 是 `["a","b"]` | 原样 |
| C-19 | `alternate_greetings` 是字符串 | `== [s]` |
| C-20 | `alternate_greetings` 是 `null` | `== []` |
| C-21 | `creator_notes` 含 `"Creator's notes go here."` | 被剥离（v1 路径） |
| C-22 | Gradio 卡导入 | `name`←`char_name`、`description`←`char_persona`、`personality == ""` |
| C-23 | v1 卡里的 `create_date` | 被覆盖为 now（`01#10.2`-4） |
| C-24 | `importJSON(v1_card)` | `originalPNG == nil`，`origin == .json` |
| C-25 | 顶层是数组的 JSON | 抛 `.notAnObject` |
| C-26 | `spec` 与 `data` 都缺、`name` 也缺 | 抛 `.unsupportedStructure` |
| C-27 | `mes_example` 不以 `<START>` 开头 | **原样保留**，不被改写 |
| C-28 | 名字是 `"a/b\\c"` | sanitize 后不含非法字符 |
| C-29 | 名字 sanitize 后为空 | `== "unnamed"` |
| C-30 | `validate(v2_dual)` | `== .v1`（**V1 优先**，`01#2.5`） |
| C-31 | `validate(v2_clean)` | `== .v2` |
| C-32 | `validate(v3_card)` | `== .v3` |
| C-33 | 去掉 v3 卡的 `spec_version` | `validateV3 == false`（`Number(undefined)` 是 NaN，NaN 比较全 false） |
| C-34 | v2 卡缺 `data.system_prompt` | `validateV2 == false` |
| C-35 | `character_book.extensions` 缺失的 v2 卡 | `validateV2 == false` |
| C-36 | `character_book.entries` 是 object 而非数组 | `validateV2 == false` |
| C-37 | v3 卡的 `data` 只有 `{"name":"x"}` | `validateV3 == true`（**不校验 data 字段**） |

#### D. character_book / 世界书（模块 D）

| # | 用例 | 断言 |
|---|---|---|
| D-01 | `convertCharacterBook` 的 `position`：`extensions.position = 4` | 内部 `position == 4` |
| D-02 | `extensions.position = 0` 且字符串 `position = "after_char"` | 内部 `position == 0`（**数字优先**） |
| D-03 | 无 `extensions.position`，字符串 `position = "before_char"` | `== 0` |
| D-04 | 无 `extensions.position`，字符串 `position = "after_char"` | `== 1` |
| D-05 | 无 `extensions.position`，字符串 `position` **缺失** | `== 1`（**不是 0！**） |
| D-06 | 反向：内部 `position = 2` | 字符串 `"after_char"` **且** `extensions.position == 2` |
| D-07 | 反向：内部 `position = 0` | 字符串 `"before_char"` 且 `extensions.position == 0` |
| D-08 | `enabled = false` | 内部 `disable == true` |
| D-09 | `enabled` **缺失** | 内部 `disable == true`（★ ST 语义） |
| D-10 | `comment = "标题"` | 内部 `addMemo == true`，`comment == "标题"` |
| D-11 | `comment` 缺失 | `addMemo == false`，`comment == ""` |
| D-12 | `id` 缺失（第 3 个条目） | 内部 `uid == 3` |
| D-13 | `extensions.probability = 0` | 内部 `probability == 0`（不是 100） |
| D-14 | `extensions.useProbability = false` | 内部 `== false` |
| D-15 | `extensions.group_weight = null` | 内部 `groupWeight == nil`（不是 100） |
| D-16 | `extensions.depth` 缺失 | 内部 `depth == 4` |
| D-17 | `extensions.role` 缺失 | 内部 `role == 0` |
| D-18 | `extensions.selectiveLogic` 缺失 | `== 0` |
| D-19 | `selective` 缺失 | 内部 `selective == false`（**不是模板的 `true`**） |
| D-20 | `case_sensitive` 只在**条目级**给了 `true`，`extensions.case_sensitive` 缺失 | 内部 `caseSensitive == nil`（**按源码，不回退**） |
| D-21 | `case_sensitive` 在 `extensions` 里给 `true` | 内部 `== true` |
| D-22 | `extensions` 里有未知键 `"vendor_x": 1` | 往返后仍在 |
| D-23 | 全字段往返：`fromWorldInfo ∘ toWorldInfoEntries` | 稳定（第二次转换结果与第一次相同） |
| D-24 | `extensions.triggers = ["normal"]` | 内部 `triggers == ["normal"]` |
| D-25 | 内部 `triggers = []` | 反向 `extensions.triggers == []` |
| D-26 | 内部 `ignoreBudget = true` | 反向 `extensions.ignore_budget == true` |
| D-27 | 反向输出的 `use_regex` | `== true`（ST 恒写 true） |
| D-28 | 反向输出的 `groupWeight = nil` 的条目 | `extensions.group_weight` 是 `null` |
| D-29 | 读 `eldoria.json` | 4 个条目，uid 0..3，`sticky/cooldown/delay` 保留 `0`（不变成 `null`） |
| D-30 | 写世界书（4 空格缩进） | 顶层含 `entries`；重新读回深度相等 |
| D-31 | 读 `{"entries":{}}` | 成功，`entries.isEmpty` |
| D-32 | 读一个没有 `entries` 键的 JSON | 抛 `missingEntries` |
| D-33 | `entries` 写成数组形式（第三方文件） | 宽容处理：按 index 赋 uid + warning |
| D-34 | `WorldInfoFile.originalData` 存在时的导出 | 卡里写回的是 `originalData` 的原样内容（不是重新转换的结果） |
| D-35 | `character_book.name` 为空时导出 | 填 `"<角色名>'s Lorebook"` |
| D-36 | `entries` 序列化成对象 | key 是 `"0"`, `"1"`, …（字符串化的 uid） |

#### E. 导出（模块 E）

| # | 用例 | 断言 |
|---|---|---|
| E-01 | `exportJSONString(v2卡)` | `spec == "chara_card_v2"`，**不升级为 v3** |
| E-02 | `exportJSONString(v3卡)` | `spec == "chara_card_v3"`、`spec_version == "3.0"` |
| E-03 | 导出后 `fav` | 顶层 `false` **且** `data.extensions.fav == false` |
| E-04 | 导出后 `chat` 键 | **不存在** |
| E-05 | 卡缺 `create_date` 导出 | 被补上 ISO now |
| E-06 | 卡有 `create_date` 导出 | 原值不变 |
| E-07 | 导出 JSON 的缩进 | 每级 4 空格；`"key": value`（冒号后一个空格） |
| E-08 | 导出 JSON 里的 `/` | **不转义**（`a/b` 原样，不是 `a\/b`） |
| E-09 | 导出 JSON 里的中文 | 原样 UTF-8（不是 `\uXXXX`） |
| E-10 | `exportPNG(v2卡, originalPNG: seraphina.png)` | `chara`+`ccv3` 双 chunk；`IDAT` 与原图逐字节相同 |
| E-11 | `exportPNG` 产物 → `readCharacterJSON` | 能读回同一份数据 |
| E-12 | `exportPNG(卡, originalPNG: nil)` | 生成一张 512×768 的合法 PNG，且含角色数据 |
| E-13 | 顶层 `group_only_greetings` 往返 | 导出后仍在（透传） |
| E-14 | v3 卡里的 `nickname`/`assets`/`creation_date` 往返 | 导出后仍在 |
| E-15 | 未知顶层键 `"my_custom_key": {...}` 往返 | 导出后仍在 |
| E-16 | 导出再导入（round-trip） | `CharacterCard` 的关键字段全部相等 |
| E-17 | `exportFileName(png)` | `== card.avatarFileName`（若非空） |
| E-18 | `exportJSONString` 两次调用 | 字节完全相同（键排序带来的确定性） |
| E-19 | 有 `world` 但世界书文件不存在 | 导出成功，卡里**没有** `character_book` 键 |
| E-20 | 数字往返：`depth_prompt.depth = 4` | 导出仍是 `4`（不是 `4.0`） |

#### F. 头像与文件名（模块 F）

| # | 用例 | 断言 |
|---|---|---|
| F-01 | `sanitize("a/b?c")` | `"abc"`（**删除**，不是 `a_b_c`） |
| F-02 | `sanitize("a\u{01}b")` | `"ab"` |
| F-03 | `sanitize("..")` | `"unnamed"`（ST 是 `""`，我们有意兜底） |
| F-04 | `sanitize("CON")` | `"unnamed"` |
| F-05 | `sanitize("con.txt")` | `"unnamed"` |
| F-06 | `sanitize("name ")` / `sanitize("name...")` | `"name"` |
| F-07 | `sanitize` 一个 300 字节的中文名 | UTF-8 字节数 ≤ 255，且不出现乱码（完整字符边界） |
| F-08 | `uniqueName(base:"A", exists: { $0 == "A" })` | `"A1"` |
| F-09 | `exists` 对 `A`/`A1`/`A2` 都为 true | `"A3"` |
| F-10 | `stripExtension("a.png.png")` | `"a.png"`（只去掉最后一个扩展名） |
| F-11 | `humanizedDateTime(2025-09-26 15:04:33.123)` | `"2025-9-26@15h04m33s123ms"`（月/日不补零） |
| F-12 | `iso8601` 格式 | 匹配 `^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$` |
| F-13 | 目录枚举：放一个 `_covers/` 子目录 + 一个真实 PNG | 只返回 1 个角色 |

#### G. JSONL（模块 G）

| # | 用例 | 断言 |
|---|---|---|
| G-01 | `decode(chat.jsonl)` | `physicalLineCount == 3`；`messages.count == 2`；`header.chatMetadata.integrity == "1e6905db-…"` |
| G-02 | G-01 的第 2 条消息 | `name == "Seraphina"`、`isUser == false`、`swipes.count == 2`、`swipeId == 0`、`swipes[0] == mes` |
| G-03 | G-01 的 `swipeInfo` | `count == swipes.count` |
| G-04 | `encode(decode(chat.jsonl))` | **与原始字节完全相同**（golden round-trip） |
| G-05 | 编码结果的末尾 | **没有** `\n` |
| G-06 | 编码结果的开头 | **没有** BOM |
| G-07 | 编码的每一行 | 单独 `JSON.parse` 成功；**无缩进**（行首不是空格） |
| G-08 | `decode(chat_bom.jsonl)` | 成功 + `.bomStripped` warning |
| G-09 | `decode(chat_truncated.jsonl)` | 成功；`lastLineUnparsable == true`；`chatItemCount == physicalLineCount - 2` |
| G-10 | `decode(chat_no_header.jsonl)` | 成功；`messages.count == 3`；`.firstLineIsNotHeader` warning |
| G-11 | 空文件 | `messages.isEmpty`，`chatItemCount == 0` |
| G-12 | 只有 header 行 | `chatItemCount == 0` |
| G-13 | 文件末尾多一个 `\n` | `physicalLineCount` 不含那个空行 |
| G-14 | CRLF 文件 | 解析成功，`mes` 里没有尾随 `\r` |
| G-15 | 中间一行是 `"not json"` | 跳过 + `.unparsableLine`；其余消息正常 |
| G-16 | `extra.unknown_vendor_key` 往返 | 仍在 |
| G-17 | `chat_metadata.unknown_key` 往返 | 仍在 |
| G-18 | `user_name`/`character_name` 往返 | 都是 `"unused"` |
| G-19 | 消息带 `title` / `force_avatar` / `original_avatar` | 往返保留 |
| G-20 | `swipeId` 越界（= 99） | 读取时 clamp 到 0 + warning |
| G-21 | `swipes` 存在但 `mes` 与之不符，写入后 | `swipes[swipeId] == mes`（自动规整） |
| G-22 | `swipeInfo` 比 `swipes` 短，写入后 | 等长 |
| G-23 | 用户消息写入后 | **没有** `swipes`/`swipe_id`/`swipe_info` 键 |
| G-24 | 系统消息写入后 | `extra.swipeable == false` |
| G-25 | `sendDate` 格式 | 匹配 ISO 8601 带毫秒（**不是 `"yyyy-MM-dd HH:mm:ss"`**） |
| G-26 | integrity：磁盘无该字段时写入 | 允许（老聊天） |
| G-27 | integrity：磁盘有 `"A"`，内存传 `"B"` | 抛 `.mismatch`，**文件未被修改** |
| G-28 | integrity：磁盘首行非 JSON | 抛 `.mismatch`（保守） |
| G-29 | integrity：文件不存在 | 允许 |
| G-30 | integrity：文件为空 | 允许 |
| G-31 | `skipIntegrityCheck: true` | 强制写入成功 |
| G-32 | `chatItemCount` 正常文件 | `== physicalLineCount - 1` |
| G-33 | 群聊文件（消息带 `force_avatar`） | 与单聊走同一套解析，字段正确 |
| G-34 | 1000 条消息的往返 | 成功；耗时记录基线 |

#### H. 集成 / 端到端

| # | 用例 | 断言 |
|---|---|---|
| H-01 | 真实 ST 卡 PNG → 导入 → 导出 PNG → 再导入 | 关键字段全部相等；`IDAT` 未变 |
| H-02 | H-01 的中间产物交给真实 ST 的 `read()`（Node 脚本，可选用例） | ST 能读出等价 JSON |
| H-03 | ST 生成的 v2 卡 → 导入 → 编辑名字 → 导出 → 检查双写 | 顶层与 `data` 的 `name` 都被更新 |
| H-04 | 用 ST 导出的 JSON（`/api/characters/export?format=json`）导入 | 成功，字段与 PNG 路径一致 |
| H-05 | 完整用户目录拷贝（`characters/` + `chats/` + `worlds/`） | App 能枚举出全部角色、聊天、世界书 |

### 8.3 测试组织建议

```swift
// ios/SillyTavernTests/
//   Fixtures.swift                 加载夹具的助手
//   PNGReaderTests.swift           A-01…A-33
//   PNGWriterTests.swift           B-01…B-18
//   CRC32Tests.swift               A-01, A-02
//   CharacterImporterTests.swift   C-01…C-29
//   TavernCardValidatorTests.swift C-30…C-37
//   CharacterBookConversionTests.swift  D-01…D-36
//   CharacterExporterTests.swift   E-01…E-20
//   FileNameSanitizerTests.swift   F-01…F-13
//   ChatJSONLTests.swift           G-01…G-34
//   RoundTripIntegrationTests.swift H-01…H-05
```

**金标准（golden file）用法**：凡涉及「字节级兼容」的用例（A-03、B-01、G-04），用**逐字节比较**；凡涉及「语义兼容」的用例（E-16、H-01），用**解析后的对象深度比较**（因为 Swift 的键顺序与数字格式与 JS 不同，见 §5.4）。

### 8.4 易错点（模块 H）

1. **不要用 `default_Seraphina.png` 的原文件做「写回原路径」的测试**——测试要写临时目录，夹具保持只读。
2. **A-05/A-06 的陷阱**：`readCharacterJSON` 返回的是 **`ccv3`**（v3 标签）而不是 `chara`。写测试时如果断言 `spec == "chara_card_v2"` 会误判成 bug。
3. **字节级 round-trip 只在特定条件下成立**：
   - PNG 路径：`chara` chunk 的 base64 内容取决于 JSON 序列化 → **只有在键顺序与数字格式完全一致时**才字节相同。用「解析后比较」。
   - JSONL 路径：如果 Swift 的 `JSONEncoder` 输出键顺序与 ST 的插入序不同，G-04 会失败。要么用有序容器，要么 G-04 改为「解析后比数组元素深度相等」。
4. **`Data == Data` 是值比较**，可以放心用。
5. **fixture 里的 PNG 会被 Git 当二进制**，确保 `.gitattributes` 不把它当文本处理（避免行尾转换破坏 CRC —— 这正是 `png-chunks-extract` 报「possibly caused by DOS-Unix line ending conversion」的场景）。

---

## 附录 A：现有 Swift 代码必须修改的点

| 文件:行 | 现状 | 必须改成 | 依据 |
|---|---|---|---|
| `Models/WorldInfo.swift:103-133` | `WorldInfoPosition: String`，取值 `"before_char"`/`"at_depth_system"` 等 | **删除**。改用 `WorldInfoPositionCode: Int`（0..7）+ `CharacterBookPosition: String`（只有两个值） | `01#3.4`、`public/scripts/world-info.js:855-864` |
| `Models/WorldInfo.swift:29-97` | `WorldInfoEntry` 有 `id: UUID`，缺 `uid`/`role`/`selectiveLogic`/`triggers`/`ignoreBudget`/`vectorized`/`sticky`/`cooldown`/`delay`/`addMemo`/`outletName`/`group*`；`caseSensitive`/`matchWholeWords` 是 `Bool`（应为 `Bool?`）；`probability`/`priority` 语义混淆 | 按 §4.1 重写 | `01#3.3`、`01#3.5` |
| `Models/WorldInfo.swift:7-26` | `CharacterBook.entries: [WorldInfoEntry]`（把两种形状混成一个类型） | 拆成 `CharacterBook.entries: [CharacterBookEntry]`（规范数组）与磁盘 `WorldInfoFile.entries: [String: WorldInfoEntry]` | `04#4.3` 的明确警告 |
| `Models/CharacterCard.swift:10-94` | 缺 `rawRoot`、`talkativeness`、`fav`、`chatName`、`depthPrompt`、`specRaw`、`origin` | 按 §3.1 补齐 | H2、`01#4.5-1/4/10` |
| `Models/CharacterCard.swift:43` | `specVersion: String = "2"`（自造的 "1"/"2"/"3"） | 改成 `specRaw: String?` + `specVersionRaw: String?` 原样保留；显示版本用 `displaySpec(_:)` | `01#9-D-38` |
| `Models/CharacterCard.swift:90-93` | `exampleMessages` 用 `components(separatedBy: "<START>")` | 分隔符是**大小写不敏感的正则** `/<START>/gi`，并且要复刻「不以 `<START>` 开头则前置 `<START>\n` + 整串 trim」的语义 | `01#5.1` `public/script.js:3501-3515` |
| `Models/ChatMessage.swift:57-62` | `timestamp()` 产出 `"yyyy-MM-dd HH:mm:ss"` | ★ **必须改**为 ISO 8601 带毫秒的 UTC 串 | `04#2.4` |
| `Models/ChatMessage.swift:42-54` | `CodingKeys` 缺 `title`/`swipe_info`/`force_avatar`/`original_avatar`/未知键 | 按 §7.1 补齐 | `04#2.4` |
| `Models/ChatMessage.swift:66-81` | `MessageExtra` 只有 4 个字段 | 按 §7.1 补齐到 22 个 + `unknownFields` | `04#2.5` |
| `Models/JSONValue.swift:25-48` | `init(from:)` 的顺序 Int → Double → Bool → String | 顺序基本可用，但需注意：JSON `1.0` 会解成 `.integer(1)`（实测），回写变 `1`。若要保真，**先判断 NSNumber 的底层类型**或接受这一语义等价 | 本机实测 |
| `Services/LocalStorage.swift:7-9` | 计划存 `characters/<名>.json` + `.png` 两份 | **只留 PNG**（卡数据在 tEXt 里） | `01#7.1`、`04#3.1` |
| `Services/LocalStorage.swift:66-71` | `sanitizeFileName` 用 `_` 替换 + `prefix(120)` | 用 `FileNameSanitizer.sanitize`（**删除**，255 **UTF-8 字节**截断） | `01#7.2`、`01#9-E-42` |
| `Services/LocalStorage.swift:29-37` | 只有 `characters/` `chats/` `worlds/` | 补 `User Avatars/`、`backups/`（`thumbnails/` 建议放 Caches） | `04#1.2`、`04#8.1-4` |

## 附录 B：常量速查

| 项 | 值 | 来源 |
|---|---|---|
| PNG 签名 | `89 50 4E 47 0D 0A 1A 0A` | `01#1.2` |
| 角色数据 chunk 类型 | `tEXt`（keyword `chara` / `ccv3`） | `01#1.1` |
| chunk 开销 | 每块 `data.length + 12` | `01#1.5` |
| CRC 多项式 | `0xEDB88320`（反射），init/xorout `0xFFFFFFFF` | PNG 规范 / `src/png/encode.js:58` |
| CRC 覆盖范围 | `type + data`（不含 length） | `src/png/encode.js:58` |
| tEXt keyword 上限 | `< 80` 字节 | `01#1.3` |
| 头像标准尺寸 | 512 × 768 | `01#7.3`、`src/constants.js:358-359` |
| 默认头像 | ST 用 `./public/img/ai4.png`；我们程序化生成 | `src/constants.js:360` |
| 世界书默认深度 | `DEFAULT_DEPTH = 4` | `01#3.5`、`world-info.js:96` |
| 世界书默认组权重 | `DEFAULT_WEIGHT = 100` | `world-info.js:97` |
| 最大扫描深度 | `MAX_SCAN_DEPTH = 1000` | `world-info.js:98` |
| `talkativeness` 默认 | `0.5` | `01#2.3` |
| `depth_prompt.depth` 默认 | `4` | `public/script.js:550` |
| `depth_prompt.role` 默认 | `"system"` | `public/script.js:551` |
| 唯一文件名最大尝试 | 10000（`getPngName`）/ 1000（`getUniqueName` 默认） | `01#7.2` |
| 文件名长度上限 | 255 **UTF-8 字节** | `01#7.2` |
| 合并哨兵值 | `'__@@UNSET@@__'` | `01` 附录 |
| JSON 导出的缩进 | 4 空格 | `01#6.2` |
| 世界书文件缩进 | 4 空格 | `04#4.1` |
| 允许导入的扩展名 | `json, png, yaml, yml, charx, byaf` | `01` 附录（本期只做 png/json） |
| `chat_metadata.integrity` | UUID v4 字符串 | `04#2.3` |
| chat 头占位字段值 | `"unused"` | `04#2.2` |
| 消息时间格式 | ISO 8601 带毫秒，如 `2025-09-26T07:04:33.123Z` | `04#2.4` |
| JSONL 分隔符 | `\n`，**无尾随换行**，无 BOM，紧凑 | `04#2.1`、`04#8.1-1` |

## 附录 C：来源索引

| 主题 | 文档章节 | 源码位置 |
|---|---|---|
| PNG 写入流程 | `01#1.2` | `src/character-card-parser.js:15-46` |
| tEXt 编解码 | `01#1.3` | `node_modules/png-chunk-text/{encode,decode}.js` |
| PNG 读取流程 | `01#1.4` | `src/character-card-parser.js:54-78` |
| PNG 字节布局 | `01#1.5` | `src/png/encode.js:9-68` |
| CRC 处理 | `01#1.6` | `node_modules/png-chunks-extract/index.js:79-85` |
| v1 / v2 字段 | `01#2.1`、`01#2.2` | `src/types/spec-v2.d.ts:1-23` |
| `extensions` 定义 | `01#2.3` | `src/endpoints/characters.js:615-626` |
| v3 差异 | `01#2.4` | `src/validator/TavernCardValidator.js:143-168` |
| 校验顺序 | `01#2.5` | `src/validator/TavernCardValidator.js:32-48` |
| character_book 规范 | `01#3.1`、`01#3.2` | `src/types/spec-v2.d.ts:25-52` |
| `extensions` 子字段 | `01#3.3` | `src/endpoints/characters.js:682-715`、`public/scripts/world-info.js:5636-5669` |
| 枚举取值 | `01#3.4` | `public/scripts/world-info.js:33-38,855-864`、`public/script.js:494-498` |
| 条目默认值 | `01#3.5` | `public/scripts/world-info.js:4082-4133` |
| 内部字段 ↔ originalData | （`01#3.3` 的补充） | `public/scripts/world-info.js:2687-2724` `originalWIDataKeyMap` |
| 世界书磁盘格式 | `01#3.6` | `src/endpoints/worldinfo.js:16-37,144-154` |
| character_book 往返 | `01#3.7` | `public/scripts/world-info.js:5617-5674`、`src/endpoints/characters.js:663-722` |
| 归一化函数 | `01#4.2` | `src/endpoints/characters.js:450-657` |
| 导入入口 | `01#4.3` | `src/endpoints/characters.js:883-1020` |
| 双写 hack | `01#4.4` | `src/endpoints/characters.js:580-612` |
| 兼容 hack 清单 | `01#4.5` | 见清单各行 |
| `<START>` 语义 | `01#5.1` | `public/script.js:3501-3515` |
| 导出 PNG/JSON | `01#6.1`、`01#6.2` | `src/endpoints/characters.js:1658-1679` |
| 头像存储 | `01#7.1` | `src/endpoints/characters.js:257,413,589` |
| 文件名规则 | `01#7.2` | `src/endpoints/characters.js:1543-1547`、`src/util.js:606-618` |
| 头像图像处理 | `01#7.3` | `src/endpoints/characters.js:239-334` |
| 必须复刻清单 | `01#9` | —— |
| 完整示例 | `01#10.1`、`01#10.2` | —— |
| JSONL 路径与序列化 | `04#2.1` | `src/endpoints/chats.js:532-533,548-551` |
| chat 头 | `04#2.2` | `public/global.d.ts:50-56` |
| chat_metadata | `04#2.3` | `public/global.d.ts:58-64` |
| 消息字段 | `04#2.4` | `public/global.d.ts:66-128` |
| extra 子字段 | `04#2.5` | `public/global.d.ts:90-128` |
| 系统消息 | `04#2.6` | `public/scripts/system-messages.js:18-42` |
| 群聊/分支/书签 | `04#2.7` | `public/scripts/bookmarks.js:172-301` |
| integrity | `04#2.8` | `src/endpoints/chats.js:337-368,532-543` |
| 最小 JSONL 示例 | `04#2.9` | —— |
| 角色与头像存储 | `04#3.1` | `src/constants.js:16-48` |
| 角色枚举 | `04#3.2` | `src/endpoints/characters.js:406-441,1466-1478` |
| PNG 与卡的关系 | `04#3.3` | `src/character-card-parser.js` |
| 世界书存储 | `04#4.1`、`04#4.2`、`04#4.4` | `src/endpoints/worldinfo.js:17-157` |
| 磁盘 vs 卡内形状 | `04#4.3` | `src/endpoints/characters.js:628-644,663-722` |
| iOS 兼容清单 | `04#8.1`~`04#8.4` | —— |

---

**文档结束。** 实现时如有与本规格冲突的源码行为，以 `src/` 的当前代码为准，并回写修正本文档。

