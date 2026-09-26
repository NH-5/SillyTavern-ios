# SillyTavern 角色卡格式与解析逻辑规范（Swift 重写依据）

> **研究基线**：本仓库工作区 `/Users/wuzheng/projects/SillyTavern-ios`，分支 `dsh`，`package.json` 版本 **1.19.0**（只读，未切换分支）。
> **来源标注约定**：所有结论后跟 `文件:行号`。引用 `node_modules/` 的地方是本仓库**实际依赖的实现**（`png-chunk-text`、`png-chunks-extract`、`sanitize-filename`），属于必须复刻的行为，不是猜测。
> **重要前提**：在 ST 1.19.0 中，**角色卡的解析与写入完全在服务端完成**。浏览器端的"导入"只是把文件上传到 `/api/characters/import`（`public/script.js:10530-10594`），"导出"只是从 `/api/characters/export` 拉二进制（`public/script.js:12038-12070`）。客户端**没有**通用的角色卡 PNG 解析器：`public/scripts/utils.js:1502` 的 `extractDataFromPng()` 只用于 NovelAI 的 `naidata` chunk（`public/scripts/world-info.js:5863`），不参与角色卡流程。

---

## 目录

1. [PNG 载体格式（Q1）](#1-png-载体格式q1)
2. [角色卡数据规范 v1 / v2 / v3（Q2）](#2-角色卡数据规范)
3. [`character_book` 内嵌世界书（Q3）](#3-character_book-内嵌世界书)
4. [导入归一化与内部结构（Q4）](#4-导入归一化与-st-内部角色对象)
5. [`mes_example` 的 `<START>` 与 `alternate_greetings`（Q5）](#5-mes_example-与-alternate_greetings)
6. [导出（Q6）](#6-导出)
7. [头像存储与文件名规则（Q7）](#7-头像avatar存储与文件名)
8. [解析流程图（文字）](#8-解析流程图文字描述)
9. [必须复刻的兼容逻辑清单](#9-必须复刻的兼容逻辑清单)
10. [完整示例](#10-完整示例)

---

## 1. PNG 载体格式（Q1）

### 1.1 结论速查

| 问题 | 结论 |
|---|---|
| 存在哪个 chunk | **`tEXt`**（Latin-1 文本 chunk），关键字 `chara`（v2）和 `ccv3`（v3）。**仅 `tEXt`，不支持 `iTXt` / `zTXt`** |
| 关键字名 | `chara`、`ccv3`，**读取时大小写不敏感**（`.toLowerCase()` 比较） |
| 内容编码 | 角色 JSON（UTF-8 字符串）→ **Base64（标准字母表，带 `=` padding）**，Base64 文本再作为 tEXt 的 text 部分写入 |
| 是否支持多个关键字 | **是**。`chara` 与 `ccv3` 可同时存在；读取时 `ccv3` **优先**，缺失才回退 `chara`。同一关键字出现多次时取**第一个**匹配 |
| tEXt 其他关键字 | 保留不删（例如 A1111 的 `parameters`、NovelAI 的 `naidata`）——只删除关键字为 `chara`/`ccv3` 的 tEXt chunk |
| CRC | **写：必须正确计算**（覆盖 `type + data`，大端写入）；**读：`png-chunks-extract` 会逐个校验，不匹配即抛异常**（ST 不捕获） |

来源：`src/character-card-parser.js:15-46`（写）、`src/character-card-parser.js:54-78`（读）、`src/character-card-parser.js:86-97`（`parse`）。

### 1.2 写入流程（字节级）

`src/character-card-parser.js:15-46`，配合 `src/png/encode.js:9-68`：

```
write(image: Buffer, data: string) -> Buffer:

 1. chunks = png-chunks-extract(image)
      - 校验 8 字节签名 89 50 4E 47 0D 0A 1A 0A（不匹配抛错）
      - 要求首个 chunk 是 IHDR，要求存在 IEND
      - 每个 chunk 校验 CRC32(type+data)，不匹配抛
      - 解析成 [{name: 4字符ASCII, data: Uint8Array}]，IEND 的 data 为空数组
      (node_modules/png-chunks-extract/index.js:12-20 签名, :50-53 IHDR,
       :55-65 IEND, :79-85 CRC, :98 无 IEND)

 2. 删除已有角色数据：
      for chunk in chunks where name == 'tEXt':        // 严格等于 'tEXt'，只看名字
          d = PNGtext.decode(chunk.data)
          if lower(d.keyword) in {'chara','ccv3'}: remove chunk
      (src/character-card-parser.js:17-25)
      ⚠️ 注意：只遍历 tEXt；iTXt/zTXt 里的 chara 不会被识别也不会被删除

 3. 写入 v2：
      b64 = base64_utf8(data)
      chunks.insert(at = len-1, PNGtext.encode('chara', b64))   // 插到 IEND 之前
      (src/character-card-parser.js:28-29)

 4. 写入 v3（失败静默忽略）：
      try:
        v3 = JSON.parse(data)
        v3.spec = 'chara_card_v3'
        v3.spec_version = '3.0'
        b64v3 = base64_utf8(json_stringify(v3))
        chunks.insert(at = len-1, PNGtext.encode('ccv3', b64v3))
      catch: 忽略（此时只写 chara）
      (src/character-card-parser.js:31-42)

 5. return encode(chunks)     // 重新拼 PNG 字节流
      (src/character-card-parser.js:44)
```

**最终 chunk 顺序**（已实测验证）：`IHDR, …, tEXt(chara), tEXt(ccv3), IEND`。
因为两次 `splice(-1, 0, x)` 都插在 IEND 前，第一次插入的 `chara` 在前，第二次的 `ccv3` 在后。

> ⚠️ **文档注释与代码不一致**：`src/character-card-parser.js:10` 的注释写着 "Writes only 'chara', 'ccv3' is not supported and removed not to create a mismatch"，但 `:31-42` 明确会写 `ccv3`。**以代码为准：两者都写**。实测 `default/content/default_Seraphina.png` 也确实同时含 `chara` 与 `ccv3`（chunk 列表：`IHDR(13), IDAT(511505), tEXt(20158), tEXt(20157), IEND`）。

**实证验证记录**（本次研究实际跑的 Node 脚本）：
```
write(default_Seraphina.png, "{\"spec\":\"chara_card_v2\",...}")
  → chunks: IHDR,IDAT,tEXt,tEXt,IEND
  → chunks[2](chara).spec === 'chara_card_v2'
  → chunks[3](ccv3 ).spec === 'chara_card_v3'
  → read(out).spec === 'chara_card_v3'      // 确认 ccv3 优先
```

### 1.3 `png-chunk-text` 的 tEXt 编码/解码细节（必须复刻）

**encode**（`node_modules/png-chunk-text/encode.js`）：

- 布局：`keyword` 字节 + `0x00` + `text` 字节。
- 校验：`/^[\x00-\xFF]+$/` —— **只允许 Latin-1**，否则抛错。
- 校验：关键字长度必须 `< 80`（即最多 79 字节，PNG 规范）。
- 校验：keyword 与 text 中都不允许出现 `0x00`。
- 返回 `{name:'tEXt', data:Uint8Array}`。
- 因为内容永远是 Base64（纯 ASCII），这些限制在实际使用中不会触发。

**decode**（`node_modules/png-chunk-text/decode.js`）：

- 逐字节扫描，遇到第一个 `0x00` 前的字节拼成 `keyword`（`String.fromCharCode`，即 Latin-1）。
- 之后到结尾拼成 `text`；**若 text 区域再遇到 `0x00` 则抛 `Invalid NULL character found`**。
- 返回 `{keyword, text}`。
- ⚠️ **decode 不区分 tEXt/iTXt/zTXt**，它只是"keyword 到第一个 NUL，其余到结尾都是 text"。若真喂给它别种 chunk：
  - `zTXt` 布局是 `keyword + 0x00 + 压缩方法(0x00) + 压缩数据` → keyword 之后**立刻又是一个 NUL**，decode 会抛 `Invalid NULL character found. 0x00 character is not permitted in tEXt content`。
  - `iTXt` 布局是 `keyword + 0x00 + 压缩标志 + 压缩方法 + 语言标签 + 0x00 + 翻译关键字 + 0x00 + 文本` → decode 会把中间那堆元数据当成 `text`，得到垃圾。
  - **结论：ST 只在 `name === 'tEXt'` 的 chunk 上调用 decode，因此实际不支持 zTXt/iTXt 角色卡。**

### 1.4 读取流程（字节级）

`src/character-card-parser.js:54-78`：

```
read(image: Buffer) -> string:

 1. chunks = png-chunks-extract(image)                        // 同写入，含 CRC 校验
 2. textChunks = chunks.filter(name == 'tEXt').map(PNGtext.decode)
 3. if textChunks.length == 0: throw new Error('No PNG metadata.')
 4. i = textChunks.findIndex(c => lower(c.keyword) == 'ccv3')
      if i > -1: return utf8(base64_decode(textChunks[i].text))
 5. j = textChunks.findIndex(c => lower(c.keyword) == 'chara')
      if j > -1: return utf8(base64_decode(textChunks[j].text))
 6. throw new Error('No PNG metadata.')
```

**关键点**：
- 只过滤 **`tEXt`**（`src/character-card-parser.js:57`）。`iTXt` / `zTXt` 完全被忽略。
- 优先级：**`ccv3` > `chara`**（`:64-74`）。同一关键字多份时取**第一个**。
- 解码：`base64 → UTF-8`（`:67`、`:73`）。Base64 内容不含 NUL 与换行。
- 找不到文本块或找不到角色数据都抛 `No PNG metadata.`（`:61`、`:77`），调用方不区分这两种失败。

`parse(cardUrl, format)`（`src/character-card-parser.js:86-97`）：只支持 `format === 'png'`（默认 `'png'`），读文件后调 `read()`；其他格式抛 `Unsupported format`。

### 1.5 `src/png/encode.js` 的字节布局（写 PNG 用）

`src/png/encode.js:9-68`（改写自 `png-chunks-encode`，MIT）：

```
out = 0x89 'P' 'N' 'G' 0x0D 0x0A 0x1A 0x0A          // :24-31
for each chunk:
    size = data.length
    write uint32 BE(size)                             // :43-47
    write 4 bytes name (charCodeAt 0..3)              // :49-52
    write data bytes                                  // :54-56
    crc = crc32(data, crc32(nameBytes))               // :58（crc npm 包的 (input, previous) 形式）
    write uint32 BE(crc)                              // :60-64
```

总长度 = `8 + Σ(data.length + 12)`（`:14-20`；`+12` = 4 长度 + 4 类型 + 4 CRC）。IEND 的 data 长度为 0，即占 12 字节。
CRC 语义等价于 PNG 标准的 `CRC32(type_bytes || data_bytes)`。

### 1.6 CRC 处理总结

- **写入 ST 生成的 PNG**：每个 chunk（含新增的 `tEXt`）都必须写正确的 CRC。
- **读取任意 PNG**：`png-chunks-extract` 对**每个** chunk 校验 CRC（`node_modules/png-chunks-extract/index.js:79-85`，`crcExpect = crc32.buf(chunk)` 其中 chunk 含 4 字节类型头），不匹配直接抛 `CRC values for <name> header do not match, PNG file is likely corrupted`。ST 不 try/catch，导入会整体失败。
  → **Swift 实现建议**：读时宽容（CRC 错误可选择跳过并继续），写时必须正确。但若要 100% 兼容 ST 当前行为，读时也应视为失败。

---

## 2. 角色卡数据规范

### 2.1 v1（扁平字段）

v1 就是**顶层平铺**的角色对象。规范定义的 6 个必填字段（`src/validator/TavernCardValidator.js:56`）：

| 字段 | 类型 | ST 默认值 | 说明 |
|---|---|---|---|
| `name` | string | `''` | 角色名，必填 |
| `description` | string | `''` | 描述/人设正文 |
| `personality` | string | `''` | 性格摘要 |
| `scenario` | string | `''` | 场景 |
| `first_mes` | string | `''` | 首条消息 |
| `mes_example` | string | `''` | 对话示例（`<START>` 分隔） |

v1 生态中还常见（**非 v1 规范必填，但 ST 会读写**）：

| 字段 | 类型 | ST 默认 | 备注 |
|---|---|---|---|
| `creatorcomment` | string | `''` | v1 时代的"作者备注"，对应 v2 的 `creator_notes`。ST 双向保留（`src/endpoints/characters.js:588`、`:913`） |
| `avatar` | string | `'none'` | 写入卡内时固定为 `'none'`（`src/endpoints/characters.js:589`）；**运行时会被 PNG 文件名覆盖**（`:413`） |
| `chat` | string | `` `${name} - ${humanizedDateTime()}` `` | 默认聊天文件名（不含 `.jsonl`）。导出时会被 unset |
| `talkativeness` | string/number | `0.5` | ST 扩展字段 |
| `fav` | boolean | `false` | 收藏标记 |
| `tags` | string[] 或逗号分隔 string | `[]` | 见 §4.4 |
| `create_date` | string | 当前时间 ISO 或人类可读格式 | ST 写入时用 `new Date().toISOString()`（`src/endpoints/characters.js:455`） |

### 2.2 v2 结构

```jsonc
{
  "spec": "chara_card_v2",       // 固定字符串
  "spec_version": "2.0",         // 固定字符串
  "data": { /* 见下表 */ },
  // ⚠️ 真实卡里通常还同时平铺保留一份 v1 字段（见 §4.4）
}
```

来源：`src/types/spec-v2.d.ts:1-23`、`src/endpoints/characters.js:596-597`。

**`data` 的 v2 必填字段**（`src/validator/TavernCardValidator.js:112`，共 14 个）：

| 字段 | 类型 | 默认 | 语义 |
|---|---|---|---|
| `name` | string | `''` | 角色名 |
| `description` | string | `''` | 描述 |
| `personality` | string | `''` | 性格 |
| `scenario` | string | `''` | 场景 |
| `first_mes` | string | `''` | 首条消息 |
| `mes_example` | string | `''` | 对话示例 |
| `creator_notes` | string | `''` | 作者备注（UI 显示在角色面板） |
| `system_prompt` | string | `''` | 覆盖全局 Main Prompt（`power_user.prefer_character_prompt` 为真时生效，`public/script.js:3413-3417`） |
| `post_history_instructions` | string | `''` | 覆盖全局 Post-History Instructions / Jailbreak（`public/script.js:3418-3421`） |
| `alternate_greetings` | string[] | `[]` | 备选开场白。若是字符串会被包成单元素数组（`src/endpoints/characters.js:573-577`） |
| `tags` | string[] | `[]` | 标签。字符串会按 `,` 切分并 trim 去空（`src/endpoints/characters.js:593`、`:609`） |
| `creator` | string | `''` | 作者名 |
| `character_version` | string | `''` | 角色版本号 |
| `extensions` | object | `{}` | 扩展字典，必须存在且为 object（`src/validator/TavernCardValidator.js:121`） |
| `character_book` | object? | 无 | **可选**。内嵌世界书，见 §3（`src/validator/TavernCardValidator.js:124-141`） |

**非规范但真实存在的 `data` 字段**：

| 字段 | 来源 | ST 行为 |
|---|---|---|
| `group_only_greetings` | 出现在 `default/content/default_Seraphina.png` 内嵌卡中 | **ST 代码完全不引用**（全仓库 `src/`、`public/` grep 无命中）。复刻时保留原值即可 |
| `assets` | v3 / CharX | 仅 CharX 导入时读取（`src/charx.js:173`），普通 PNG/JSON 导入忽略 |
| `nickname` / `creator_notes_multilingual` / `source` / `creation_date` / `modification_date` | v3 规范 | **ST 1.19.0 无任何引用**，作为未知键原样保留 |

### 2.3 `data.extensions` 的 ST 定义字段

`src/endpoints/characters.js:615-626`、`public/scripts/char-data.js:68-85`：

| 键 | 类型 | 默认 | 语义 |
|---|---|---|---|
| `talkativeness` | number（也见过字符串 `"0.5"`） | `0.5` | 群聊发言倾向 |
| `fav` | boolean | `false` | 收藏 |
| `world` | string | `''` | 关联的**独立世界书文件名**（不含 `.json`）。与 `character_book` 是两种不同机制 |
| `depth_prompt` | object | 见下 | 角色专属 Author's Note |
| `depth_prompt.prompt` | string | `''` | 插入文本 |
| `depth_prompt.depth` | number | `4` | 插入深度（`public/script.js:550`） |
| `depth_prompt.role` | `'system'\|'user'\|'assistant'` | `'system'` | 插入角色（`public/script.js:551`） |
| `regex_scripts` | array | — | 角色作用域正则（`public/scripts/extensions/regex/index.js`） |
| `pygmalion_id` | string? | — | 来源标识（`public/script.js:1260`） |
| `github_repo` | string? | — | 来源标识（`public/script.js:1266`） |
| `source_url` | string? | — | 来源标识（`public/script.js:1272`） |
| `chub.full_path` | string? | — | 来源标识（`public/script.js:1254`） |
| `risuai.source` | string[]? | — | RisuAI 来源 + 精灵图（`src/endpoints/sprites.js:48-71`） |
| `risuai.additionalAssets` / `risuai.emotions` | array? | — | RisuAI 精灵图，导入时落盘 |
| `sd_character_prompt.{positive,negative}` | string? | — | Stable Diffusion 扩展 |
| `perchance_data.{slug,char_url,uuid,avatar_url,folder_path,folder_name,custom_data}` | — | — | Perchance 导入写入（`src/endpoints/content-manager.js:819-827`） |
| `display_name` | string? | — | BYAF 导入保留原始显示名（`src/byaf.js:267`） |

> **extensions 合并语义**：`charaFormatData` 中若前端传来 `data.extensions`（JSON 字符串），会与已生成的对象做 **deepMerge**（`src/endpoints/characters.js:646-654`），不是覆盖。

### 2.4 v3 差异（ST 1.19.0 的实际行为）

ST 对 v3 的支持是**最小化**的，与官方 CCv3 规范有差距：

1. **校验极宽松**：`#validateDataV3()` 只要求 `card.spec === 'chara_card_v3'`、`Number(spec_version) >= 3.0 && < 4.0`、`data` 是 object（`src/validator/TavernCardValidator.js:143-168`）。**不校验任何 data 字段**。
2. **读取路径与 v2 完全相同**：`getCharaCardV2()` 判断 `jsonObject.spec === undefined`；只要 `spec` 存在就走 `readFromV2()`（`src/endpoints/characters.js:450-461`），因此 v3 卡被当作 v2 处理。
3. **PNG 写入 v3 是"改标签"**：`ccv3` chunk 的内容就是 v2 的 JSON，仅把 `spec`/`spec_version` 改成 `chara_card_v3`/`3.0`（`src/character-card-parser.js:34-38`）。`data` 不加任何 v3 新字段。实测 `default/content/default_Seraphina.png` 的两个 chunk 内容除 `spec`/`spec_version` 外**逐字节相同**。
4. **v3 官方新增字段全部被忽略**：`group_only_greetings`、`creator_notes_multilingual`、`nickname`、`source`、`assets`（除 CharX）、`creation_date`、`modification_date` 在 ST 中无引用。
5. **CharX 要求 `spec` 存在**：`CharXParser.parse()` 在 `card.spec === undefined` 时抛错（`src/charx.js:76-78`），但**不要求**是 v3。

### 2.5 校验顺序与优先级

`TavernCardValidator.validate()`（`src/validator/TavernCardValidator.js:32-48`）按 **V1 → V2 → V3** 顺序，返回**第一个**通过的版本号（1/2/3），全失败返回 `false`。

- **V1 优先于 V2**：因为 v2 卡顶层通常也平铺着 6 个 v1 字段（见 §4.4），所以一张 v2 卡在 ST 里会先被判定为 V1。这一点在 `tests/tavern-card-validator.test.js:57-61`（`prefers V1 when card satisfies both V1 and V2`）被显式测试。实测本文档 §10.1 的示例卡 → 返回 `1`；把它裁成只有 `spec`/`spec_version`/`data` → 返回 `2`。
- `lastValidationError` 记录第一个失败字段名，用于 `/api/characters/merge-attributes` 的错误返回（`src/endpoints/characters.js:1295-1299`）。⚠️ 它**只在 `validate()` 开头重置一次**，后续成功分支不会清空它（`src/validator/TavernCardValidator.js:33`），所以"校验通过"时它仍可能残留前一次失败的字段名——只有在返回 `false` 时才应把它当有效错误信息。

---

## 3. `character_book` 内嵌世界书

规范类型定义：`src/types/spec-v2.d.ts:25-52`。运行时归一化：`public/scripts/world-info.js:5617-5674`（`convertCharacterBook`）；反向（ST 世界书 → character_book）：`src/endpoints/characters.js:663-722`（`convertWorldInfoToCharacterBook`）。

### 3.1 `character_book` 顶层

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `entries` | CharacterBookEntry[] | **是**（必须是数组，`src/validator/TavernCardValidator.js:140`） | 条目数组 |
| `extensions` | object | **是**（必须是 object，`src/validator/TavernCardValidator.js:140`） | 扩展字典 |
| `name` | string? | 否 | 书名字。导入为 ST 独立世界书时用作文件名；缺省用 `` `${char.name}'s Lorebook` ``（`public/scripts/world-info.js:5744`） |
| `description` | string? | 否 | 描述（ST **不读取**，仅在往返时随 `originalData` 保留） |
| `scan_depth` | number? | 否 | 扫描深度（ST 内部条目级 `scanDepth` 优先，书级字段不参与计算） |
| `token_budget` | number? | 否 | 预算（ST 用全局 `world_info_budget`，不读此字段） |
| `recursive_scanning` | boolean? | 否 | 递归扫描（ST 用全局 `world_info_recursive`，不读此字段） |

来源：`src/types/spec-v2.d.ts:25-33`、`public/scripts/world-info.js:5618`（`{entries:{}, originalData: characterBook}` —— **整个原始 character_book 被原样保存在 `originalData` 里**，这是 ST 导入世界书后能无损回写的前提，见 `src/endpoints/characters.js:630-640`）。

> ⚠️ **重要陷阱：ST 自己生成的 `character_book` 不满足 ST 自己的 v2 校验规则。**
> `convertWorldInfoToCharacterBook` 只产出 `{ entries, name }`（`src/endpoints/characters.js:665`），**没有 `extensions`**；而 `TavernCardValidator.#validateCharacterBookV2()` 要求在 character_book 存在时**必须有 `extensions` 且为 object**（`src/validator/TavernCardValidator.js:131-140`）。
> 实测：`default/content/default_Seraphina.png` 内嵌卡的 `character_book` 顶层键就是 `['entries','name']`（无 `extensions`）。
> **为什么没炸**：`validate()` 先跑 V1，v2 卡顶层平铺着 6 个 v1 字段，于是返回 `1` 提前结束，永远走不到 V2 校验（`src/validator/TavernCardValidator.js:35-41`）。
> **对 Swift 实现的启示**：解析时不要把"character_book 缺 extensions"当作致命错误（否则读不了 ST 自己导出的卡）；生成时建议补上 `extensions: {}` 以符合规范。

### 3.2 `character_book.entries[]` 条目字段

规范定义（`src/types/spec-v2.d.ts:35-52`）+ ST 读取逻辑（`public/scripts/world-info.js:5620-5671`）：

| 字段 | 类型 | 必填 | 默认 | 语义 & ST 映射 |
|---|---|---|---|---|
| `keys` | string[] | 是 | — | 主关键词 → 内部 `key`（`:5629`） |
| `content` | string | 是 | — | 注入正文 → 内部 `content`（`:5632`） |
| `extensions` | object | 是 | `{}` | 扩展，见 §3.3 → 内部 `extensions`（`:5667`） |
| `enabled` | boolean | 是 | — | → 内部 `disable = !enabled`（**取反**，`:5640`） |
| `insertion_order` | number | 是 | — | → 内部 `order`（`:5635`） |
| `case_sensitive` | boolean? | 否 | `null` | 优先取 `extensions.case_sensitive`，否则 `entry.case_sensitive`，都没有则 `null`（`:5652`） |
| `name` | string? | 否 | — | 条目名。**ST 忽略**（内部用 `comment`） |
| `priority` | number? | 否 | — | **ST 完全忽略**（无任何引用） |
| `id` | number? | 否 | 数组下标 `index` | 作为内部 `uid`。若为 `undefined` 会被**就地写入** `entry.id = index`（`:5621-5624`，注释明说 "Not in the spec, but this is needed to find the entry in the original data"） |
| `comment` | string? | 否 | `''` | 条目标题/备注 → 内部 `comment`，并令 `addMemo = !!comment`（`:5631`、`:5641`） |
| `selective` | boolean? | 否 | `false` | 是否启用次级关键词 → 内部 `selective`（`:5634`） |
| `secondary_keys` | string[]? | 否 | `[]` | → 内部 `keysecondary`（`:5630`） |
| `constant` | boolean? | 否 | `false` | 常驻（蓝灯）→ 内部 `constant`（`:5633`） |
| `position` | `'before_char'\|'after_char'`? | 否 | — | → 内部整数 `position`：`'before_char'` → `0`，其他 → `1`；**`extensions.position`（数字）优先**（`:5636`） |
| `use_regex` | boolean? | 否 | — | **不在 v2 规范里**，但 `convertWorldInfoToCharacterBook` 恒写 `true`（`src/endpoints/characters.js:681`，注释："ST keys are always regex"）。读取时 ST **忽略**此字段（关键词一律按正则处理） |

### 3.3 `entries[].extensions` 子字段（ST 扩展，事实标准）

ST 写入侧（`src/endpoints/characters.js:682-715`）与读取侧（`public/scripts/world-info.js:5636-5669`）对照：

| extensions 键 | 类型 | 默认（读）/ 缺省回填（写） | 内部字段 |
|---|---|---|---|
| `position` | number | `null`（读时 `?? (position==='before_char' ? 0 : 1)`） | `position` |
| `exclude_recursion` | boolean | `false` | `excludeRecursion` |
| `display_index` | number | 条目数组下标 | `displayIndex` |
| `probability` | number\|null | `100` | `probability` |
| `useProbability` | boolean | `true` | `useProbability` |
| `depth` | number | `4`（`DEFAULT_DEPTH`，`public/scripts/world-info.js:96`） | `depth` |
| `selectiveLogic` | number | `0`（`world_info_logic.AND_ANY`） | `selectiveLogic` |
| `outlet_name` | string | `''` | `outletName` |
| `group` | string | `''` | `group` |
| `group_override` | boolean | `false` | `groupOverride` |
| `group_weight` | number\|null | `100`（`DEFAULT_WEIGHT`，`public/scripts/world-info.js:97`） | `groupWeight` |
| `prevent_recursion` | boolean | `false` | `preventRecursion` |
| `delay_until_recursion` | boolean | `false` | `delayUntilRecursion` |
| `scan_depth` | number\|null | `null` | `scanDepth` |
| `match_whole_words` | boolean\|null | `null` | `matchWholeWords` |
| `use_group_scoring` | boolean\|null | `null` | `useGroupScoring` |
| `case_sensitive` | boolean\|null | `null` | `caseSensitive` |
| `automation_id` | string | `''` | `automationId` |
| `role` | number | `0`（`extension_prompt_roles.SYSTEM`） | `role` |
| `vectorized` | boolean | `false` | `vectorized` |
| `sticky` | number\|null | `null` | `sticky` |
| `cooldown` | number\|null | `null` | `cooldown` |
| `delay` | number\|null | `null` | `delay` |
| `match_persona_description` | boolean | `false` | `matchPersonaDescription` |
| `match_character_description` | boolean | `false` | `matchCharacterDescription` |
| `match_character_personality` | boolean | `false` | `matchCharacterPersonality` |
| `match_character_depth_prompt` | boolean | `false` | `matchCharacterDepthPrompt` |
| `match_scenario` | boolean | `false` | `matchScenario` |
| `match_creator_notes` | boolean | `false` | `matchCreatorNotes` |
| `triggers` | string[] | `[]` | `triggers` |
| `ignore_budget` | boolean | `false` | `ignoreBudget` |
| 其他未知键 | — | — | 通过 `...entry.extensions` 展开（`src/endpoints/characters.js:683`）与 `extensions: entry.extensions ?? {}`（`public/scripts/world-info.js:5667`）**原样保留** |

### 3.4 枚举取值汇总

**`position`（内部整数），`public/scripts/world-info.js:855-864`：**

| 值 | 名称 | 语义 |
|---|---|---|
| 0 | `before` | 角色定义**之前**（对应 character_book 的 `'before_char'`） |
| 1 | `after` | 角色定义**之后**（对应 `'after_char'`） |
| 2 | `ANTop` | Author's Note 顶部 |
| 3 | `ANBottom` | Author's Note 底部 |
| 4 | `atDepth` | 聊天内指定深度（配合 `depth` + `role`） |
| 5 | `EMTop` | 示例消息顶部 |
| 6 | `EMBottom` | 示例消息底部 |
| 7 | `outlet` | Outlet（配合 `outletName`） |

`character_book` 的字符串 `position` 只能表达 `before_char`(→0) / `after_char`(→1)；**其余取值只能通过 `extensions.position` 数字传递**（`public/scripts/world-info.js:5636`）。

**`selectiveLogic`，`public/scripts/world-info.js:33-38`：**

| 值 | 名称 | 语义 |
|---|---|---|
| 0 | `AND_ANY` | 主关键词命中 且 任一 secondary 命中 |
| 1 | `NOT_ALL` | 主关键词命中 且 并非所有 secondary 都命中 |
| 2 | `NOT_ANY` | 主关键词命中 且 无 secondary 命中 |
| 3 | `AND_ALL` | 主关键词命中 且 所有 secondary 都命中 |

**`role`，`public/script.js:494-498`：**

| 值 | 名称 |
|---|---|
| 0 | `SYSTEM` |
| 1 | `USER` |
| 2 | `ASSISTANT` |

字符串形式 `'system'|'user'|'assistant'` 由 `getExtensionPromptRoleByName` 转换，未知值回退 `SYSTEM`（`public/script.js:8942-8959`）。`data.extensions.depth_prompt.role` 用的是**字符串**形式。

**其他相关枚举**：
- `world_info_insertion_strategy`：`evenly:0, character_first:1, global_first:2`（`public/scripts/world-info.js:27-31`）—— 全局设置，不属于角色卡。
- `extension_prompt_types`：`NONE:-1, IN_PROMPT:0, IN_CHAT:1, BEFORE_PROMPT:2`（`public/script.js:485-490`）。

### 3.5 ST 内部世界书条目模板（默认值权威来源）

`public/scripts/world-info.js:4082-4133`（`newWorldInfoEntryDefinition` → `newWorldInfoEntryTemplate`，后者在 `:4127`）：

| 内部字段 | 类型 | 默认 |
|---|---|---|
| `key` | array | `[]` |
| `keysecondary` | array | `[]` |
| `comment` | string | `''` |
| `content` | string | `''` |
| `constant` | boolean | `false` |
| `vectorized` | boolean | `false` |
| `selective` | boolean | `true` |
| `selectiveLogic` | enum | `0` |
| `addMemo` | boolean | `false` |
| `order` | number | `100` |
| `position` | number | `0` |
| `disable` | boolean | `false` |
| `ignoreBudget` | boolean | `false` |
| `excludeRecursion` | boolean | `false` |
| `preventRecursion` | boolean | `false` |
| `matchPersonaDescription` … `matchCreatorNotes` | boolean | `false` |
| `delayUntilRecursion` | number | `0` |
| `probability` | number | `100` |
| `useProbability` | boolean | `true` |
| `depth` | number | `4` |
| `outletName` | string | `''` |
| `group` | string | `''` |
| `groupOverride` | boolean | `false` |
| `groupWeight` | number | `100` |
| `scanDepth` | number? | `null` |
| `caseSensitive` | boolean? | `null` |
| `matchWholeWords` | boolean? | `null` |
| `useGroupScoring` | boolean? | `null` |
| `automationId` | string | `''` |
| `role` | enum | `0` |
| `sticky` | number? | `null` |
| `cooldown` | number? | `null` |
| `delay` | number? | `null` |
| `triggers` | array | `[]` |
| `uid` | number | 由 `getFreeWorldEntryUid` 分配（不在模板中） |

> ⚠️ 注意两处默认值**不一致**，复刻时要小心：
> - `selective`：ST 内部模板默认 `true`（`public/scripts/world-info.js:4078`），但从 character_book 转换时默认 `false`（`:5634` 的 `entry.selective || false`）。
> - `probability` / `useProbability`：ST 内部默认 `100` / `true`；从 character_book 转换时也是 `100` / `true`（`:5643-5644`，注意用的是 `??`，所以 `extensions.probability = 0` 不会被吞掉）。

### 3.6 ST 世界书文件格式（磁盘）

路径：`{userData}/worlds/{sanitized(name)}.json`（`src/endpoints/worldinfo.js:25`，读取函数 `readWorldInfoFile` 在 `:16-37`）。

```jsonc
{
  "entries": {
    "0": { "uid": 0, "key": [...], "keysecondary": [...], "comment": "...", "content": "...",
           "constant": false, "selective": true, "order": 100, "position": 0, "disable": false,
           "displayIndex": 0, "addMemo": true, "group": "", "groupOverride": false, "groupWeight": 100,
           "sticky": 0, "cooldown": 0, "delay": 0, "probability": 100, "depth": 4, "useProbability": true,
           "role": null, "vectorized": false, "excludeRecursion": false, "preventRecursion": false,
           "delayUntilRecursion": false, "scanDepth": null, "caseSensitive": null,
           "matchWholeWords": null, "useGroupScoring": null, "automationId": "" }
  }
}
```

**关键差异**：磁盘格式的 `entries` 是 **object（字符串 uid → 条目）**，而 `character_book.entries` 是 **数组**。顶层还可以有 `name` / `extensions`（`src/endpoints/worldinfo.js:58-63`）。

`default/content/Eldoria.json` 是 ST 自带世界书实例（顶层只有 `entries` 一个键，含 4 个条目，`uid` 为 `0..3`）。

### 3.7 character_book ↔ 世界书的往返

- **导入（character_book → 世界书）**：`importEmbeddedWorldInfo()`（`public/scripts/world-info.js:5731-5770`）。书名 = `character_book.name || `${char.name}'s Lorebook``，调 `convertCharacterBook()` 后 `saveWorldInfo(bookName, convertedBook, true)`，再把 `#character_world` 设为书名（即写回 `data.extensions.world`）。`convertCharacterBook` 的产物包含 `originalData: characterBook`（`:5618`）。
- **导出（世界书 → character_book）**：`charaFormatData()` 中若前端传了 `world`，先 `readWorldInfoFile`；**若文件里有 `originalData`（说明这本世界书本来就是从卡里导入的），直接原样写回 `data.character_book`（`src/endpoints/characters.js:630-635`）；否则用 `convertWorldInfoToCharacterBook` 转换**（`:638-640`）。读取失败只打 warn，卡里就没有 character_book（`:641-643`）。
- **移除**：在角色面板里清空世界书选择时，前端会把 `json_data.data.character_book` 置 `undefined`（`public/scripts/world-info.js:6108-6122`，注释直称 "Dirty hack"）。

---

## 4. 导入归一化与 ST 内部角色对象

### 4.1 ST 内部角色对象完整字段表

由 `processCharacter()`（`src/endpoints/characters.js:406-441`）产出，是前端 `characters[]` 里每个元素的形状：

| 字段 | 类型 | 来源 / 默认 | 说明 |
|---|---|---|---|
| `name` | string | 卡顶层或 `data.name` | 由 `readFromV2` 统一（`:551`） |
| `description` | string | `data.description` | `:551` |
| `personality` | string | `data.personality` | `:551` |
| `scenario` | string | `data.scenario` | `:551` |
| `first_mes` | string | `data.first_mes` | `:551` |
| `mes_example` | string | `data.mes_example` | `:551` |
| `tags` | string[] | `data.tags` | `:551` |
| `talkativeness` | number | `data.extensions.talkativeness`，缺省回填 `0.5` | `:532-533`, `:551` |
| `fav` | boolean | `data.extensions.fav`，缺省回填 `false` | `:536-537`, `:551` |
| `spec` | string | 原样 | v2/v3 |
| `spec_version` | string | 原样 | |
| `data` | object | 原样（v2/v3 `data`） | |
| `creatorcomment` | string | v1 遗留，原样保留 | |
| `avatar` | string | **PNG 文件名**（如 `Seraphina.png`），由 `jsonObject.avatar = item` 覆盖 `'none'` | `:413` |
| `chat` | string | 卡内 `chat`，缺省 `` `${name} - ${humanizedDateTime()}` `` | `:554`, 前端 `public/script.js:1309-1311` 再兜底一次 |
| `json_data` | string | **整张卡的原始 JSON 字符串**（PNG 里解出来的那份，未经改写） | `:415` |
| `date_added` | number | PNG 文件 `ctimeMs` | `:417` |
| `create_date` | string | 卡内 `create_date`，否则 `new Date(ctimeMs).toISOString()` | `:418` |
| `chat_size` | number | `chats/{name}/` 目录下所有文件大小之和 | `:422` |
| `date_last_chat` | number | 该目录下最新文件的 `mtimeMs`（无聊天为 0） | `:423` |
| `data_size` | number | `Σ String(v).length` over `data` 的所有 value | `:424`, `:361-363` |
| `shallow` | boolean | 仅懒加载模式下存在（`toShallow`） | `:370-395` |

**解析失败时的兜底返回**（`:435-439`）：`{date_added: 0, date_last_chat: 0, chat_size: 0}`。前端 `/api/characters/all` 会用 `.filter(c => c.name)` 把这种条目丢掉（`:1471`）。

**浅对象 `toShallow`**（`:370-395`）字段：`shallow, name, avatar, chat, fav, date_added, create_date, date_last_chat, chat_size, data_size, tags, data{name, character_version, creator, creator_notes, tags, extensions{fav, world}}`。用于 `performance.lazyLoadCharacters`。

### 4.2 三条核心归一化函数（服务端）

#### `getCharaCardV2(jsonObject, directories, hoistDate = true)` —— `src/endpoints/characters.js:450-461`

```
if (jsonObject.spec === undefined) {
    jsonObject = convertToV2(jsonObject, directories);
    if (hoistDate && !jsonObject.create_date) jsonObject.create_date = new Date().toISOString();
} else {
    jsonObject = readFromV2(jsonObject);
}
```

- **分水岭是 `spec` 字段是否存在**，不校验其值。
- `processCharacter` 调用时 `hoistDate = false`（`:412`），避免每次列角色都刷新 `create_date`。

#### `convertToV2(char, directories)` —— `src/endpoints/characters.js:469-493`

把"v1 形状"经 `charaFormatData` 转换成 v2，然后补 `chat` / `create_date`：

```
result = charaFormatData({
    json_data: JSON.stringify(char),     // ★ 原始 v1 JSON 塞进 json_data，用于保留陌生键
    ch_name, description, personality, scenario, first_mes, mes_example,
    creator_notes: char.creatorcomment,  // ★ v1 creatorcomment → v2 creator_notes
    talkativeness, fav, creator, tags,
    depth_prompt_prompt, depth_prompt_depth, depth_prompt_role,
}, directories);
result.chat = char.chat ?? `${char.name} - ${humanizedDateTime()}`;
result.create_date = char.create_date;    // ★ 可能为 undefined（调用方决定是否补）
```

#### `readFromV2(char)` —— `src/endpoints/characters.js:504-557`

```
if (char.data === undefined) { warn; return char; }   // ★ 有 spec 但没 data：原样返回
unset(char, 'json_data');                             // ★ 防止 json_data 递归传播
for (charField, v2Path) in {
    name:'name', description:'description', personality:'personality', scenario:'scenario',
    first_mes:'first_mes', mes_example:'mes_example',
    talkativeness:'extensions.talkativeness', fav:'extensions.fav', tags:'tags'
}:
    v2Value = get(char.data, v2Path)
    if v2Value === undefined:
        if v2Path == 'extensions.talkativeness': char[charField] = 0.5
        elif v2Path == 'extensions.fav':         char[charField] = false
        else: warn; continue
    else if char[charField] != undefined && String(char[charField]) !== String(v2Value): warn(mismatch)
    char[charField] = v2Value
char.chat = char.chat ?? `${char.name} - ${humanizedDateTime()}`
```

**语义要点**：
- `data` 里的值**总是覆盖**顶层同名 v1 值（`:551` 无条件赋值）。顶层字段只是兼容残留。
- **不做任何类型转换**：`char[charField] = v2Value` 是直接赋值（`:551`）。只有 `String(顶层值) !== String(data 值)` 时才打 `mismatch` warn（`:548-550`），且 warn 后仍然以 `data` 值为准。这解释了为什么真实卡里 `talkativeness` 可能是字符串 `"0.5"`（`default/content/default_Seraphina.png` 就是 `"talkativeness": "0.5"` 字符串）。
- `data.extensions.talkativeness` / `fav` 缺失时会**回填默认值** `0.5` / `false`，其他字段缺失只 warn 并保留顶层值。

#### `charaFormatData(data, directories)` —— `src/endpoints/characters.js:565-657`

**这是写入路径的唯一入口**（`/create`、`/edit`、`convertToV2` 都走它）。逐段：

1. `char = tryParse(data.json_data) || {}` —— **以传入的 `json_data` 为基底**，保留所有 ST 不认识的键（`:566-567`）。然后 `unset(char, 'json_data')` 防递归（`:570`）。
2. **v1 字段**（`:580-585`）：`name` ← `data.ch_name`；`description/personality/scenario/first_mes/mes_example` ← 同名，`|| ''`。
3. **旧 ST 扩展字段**（`:588-593`）：
   - `creatorcomment` ← `data.creator_notes || ''`
   - `avatar` ← 固定 `'none'`
   - `chat` ← `` `${data.ch_name} - ${humanizedDateTime()}` ``
   - `talkativeness` ← `data.talkativeness || 0.5`
   - `fav` ← `data.fav == 'true'`（**字符串比较！**）
   - `tags` ← 字符串按 `,` split + trim + 过滤空；否则 `data.tags || []`
4. **v2 骨架**（`:596-612`）：`spec='chara_card_v2'`、`spec_version='2.0'`；`data.name` ← `ch_name`；`data.{description,personality,scenario,first_mes,mes_example}` `|| ''`；`data.creator_notes/system_prompt/post_history_instructions` `|| ''`；`data.tags` 同 v1 的 tags 规则；`data.creator` `|| ''`；`data.character_version` `|| ''`；`data.alternate_greetings` ← `getAlternateGreetings(data)`（数组直接用；字符串包成 `[s]`；其他 → `[]`，`:573-577`）。
5. **ST 扩展**（`:615-617`）：`data.extensions.talkativeness` ← `data.talkativeness || 0.5`；`data.extensions.fav` ← `data.fav == 'true'`；`data.extensions.world` ← `data.world || ''`。
6. **depth_prompt**（`:620-626`）：`depth` 默认 `4`（`!isNaN(Number(...))` 才用传入值）；`role` 默认 `'system'`；`prompt` 默认 `''`。
7. **character_book 生成**（`:628-644`）：若 `data.world` 非空 → `readWorldInfoFile` → 有 `originalData` 则原样写回，否则 `convertWorldInfoToCharacterBook`。
8. **extensions 深合并**（`:646-654`）：若 `data.extensions` 是 JSON 字符串，`deepMerge(char.data.extensions, parsed)`。

#### `unsetPrivateFields(char)` —— `src/endpoints/characters.js:498-502`

```js
_.set(char, 'fav', false);            // 顶层 fav 置 false
_.set(char, 'data.extensions.fav', false);
_.unset(char, 'chat');                // 删掉顶层 chat
```

导出（PNG / JSON）前都会调用（`:1662`、`:1674`）。

### 4.3 各导入入口的分支逻辑

| 入口 | 函数:行 | 判定顺序 |
|---|---|---|
| PNG | `importFromPng` `src/endpoints/characters.js:968-1020` | 先 `readCharacterData` → `JSON.parse` → `sanitize(name)`/`sanitize(data.name)` → `spec !== undefined` ? v2 路径 : `name !== undefined` ? v1 路径 : 返回 `''`（失败） |
| JSON | `importFromJson` `:883-959` | ① `spec !== undefined` → v2/v3 路径；② `name !== undefined` → **v1 JSON**；③ `char_name !== undefined` → **Pygmalion/Gradio notepad** 路径 |
| YAML | `importFromYaml` `:731-755` | `yaml.parse` → 直接构造 v1 形状再 `convertToV2` |
| CharX | `importFromCharX` `:765-801` | ZIP 内 `card.json`，**要求 `spec` 存在**（`src/charx.js:76-78`） |
| BYAF | `importFromByaf` `:803-874` | `ByafParser` 构造 CCv2 卡（`src/byaf.js:248-272`；`create_date` 是 `data` **外**的非标准顶层键，`:269-270`） |
| URL（chub/pygmalion/janny/perchance） | `src/endpoints/content-manager.js:440/506/595/783` | 服务端下载后直接构造 CCv2 卡 JSON，再 `write()` 成 PNG |

**v1/v2 路径统一的后处理**（v2 分支）：`importRisuSprites` → `unsetPrivateFields` → `readFromV2` → `create_date = now ISO` → `sanitize` 名字 → `getPngName` → `writeCharacterData(DEFAULT_AVATAR_PATH 或上传图, JSON)`。
（PNG 走上传图，JSON 全用默认头像 `./public/img/ai4.png`，`src/constants.js:360`）

**v1 路径**（PNG `:997-1012`，JSON `:910-925`）显式构造这个中间对象：

```js
{
  name, description: ?? '', creatorcomment: ?? creator_notes ?? '', personality: ?? '',
  first_mes: ?? '', avatar: 'none', chat: `${name} - ${humanizedDateTime()}`,
  mes_example: ?? '', scenario: ?? '', create_date: new Date().toISOString(),
  talkativeness: ?? 0.5, creator: ?? '', tags: ?? ''
}
```

**Gradio/Pygmalion notepad 映射**（`:929-955`，字段名全变）：

| 旧字段 | 映射到 |
|---|---|
| `char_name` | `name` |
| `char_persona` | `description` |
| `char_greeting` | `first_mes` |
| `world_scenario` | `scenario` |
| `example_dialogue` | `mes_example` |
| `creator_notes` / `creatorcomment` | `creatorcomment` |
| — | `personality: ''`（**没有来源，硬编码空**） |

> ⚠️ **已知 bug 要复刻**：Gradio 分支的 `chat` 用的是 `jsonData.name`（此时为 `undefined`），会得到 `"undefined - <时间>"`（`src/endpoints/characters.js:944`）。而 YAML 分支的 `name` 已 sanitize（`:736`）。

### 4.4 "同时平铺 v1 + v2" 的兼容 hack（**必须复刻**）

ST 生成的每一张卡**同时**包含：
- 顶层 v1 字段：`name, description, personality, first_mes, scenario, mes_example, tags, avatar, chat, create_date, talkativeness, fav, creatorcomment`
- 顶层 `spec` / `spec_version` / `data`

证据：`charaFormatData` 先写 v1（`:580-593`）再写 v2（`:596-612`），两者共存于同一个对象；默认卡 `default/content/default_Seraphina.png` 的顶层键正是
`['name','description','personality','first_mes','avatar','chat','mes_example','scenario','create_date','talkativeness','fav','creatorcomment','spec','spec_version','data','tags']`。

**后果**：`TavernCardValidator.validate()` 会先把这种卡判为 V1（§2.5）。

### 4.5 需要复刻的兼容 hack 清单（速查）

| # | Hack | 位置 |
|---|---|---|
| 1 | 顶层与 `data` **双写**同名 v1 字段 | `src/endpoints/characters.js:580-612` |
| 2 | `creatorcomment` ⇄ `creator_notes` 双向映射 | `:479`（读）、`:588`（写）、`:913`、`:1000` |
| 3 | `char_name` / `char_persona` / `char_greeting` / `world_scenario` / `example_dialogue`（Gradio） | `:929-951` |
| 4 | `talkativeness` 顶层 + `data.extensions.talkativeness` 双写，默认 `0.5` | `:591`、`:615`、`:532-533` |
| 5 | `fav` 用**字符串比较** `data.fav == 'true'` 解析 | `:592`、`:616` |
| 6 | `tags` 支持 `string[]` 或逗号分隔 string | `:593`、`:609` |
| 7 | `alternate_greetings` 支持 string 单值 → 包成数组 | `:573-577` |
| 8 | `world` → `data.extensions.world`，并据此生成 `data.character_book` | `:617`、`:628-644` |
| 9 | `avatar` 卡内恒为 `'none'`，运行时被 PNG 文件名替换 | `:589`、`:413` |
| 10 | `chat` 默认 `` `${name} - ${humanizedDateTime()}` ``，导出时 unset | `:590`、`:554`、`:501` |
| 11 | `create_date`：卡内优先，否则用 PNG 文件的 `ctimeMs` ISO | `:418`、`:455` |
| 12 | `json_data` = 原始 PNG JSON 字符串，参与表单往返，导入时 `unset` 防递归 | `:415`、`:511`、`:570` |
| 13 | `spec` 存在但 `data` 缺失 → 原样返回不报错 | `:505-508` |
| 14 | 顶层/`data` 值不一致只 warn，以 `data` 为准 | `:548-551` |
| 15 | `creator_notes` 中剥离字面量 `"Creator's notes go here."` | `:907`、`:934`、`:994` |
| 16 | `data.character_book` 优先用 `originalData` 无损回写 | `:630-635` |
| 17 | 所有 key/value 名称处理走 `sanitize-filename`（默认 replacement 为空串） | `:736`、`:894`、`:905`、`:1028`、`:1544` |
| 18 | 重复名字 → `Name.png`, `Name1.png`, `Name2.png`… | `:1543-1547` + `src/util.js:606-618` |
| 19 | `group_only_greetings`、`priority`、`name`(entry)、`use_regex`(读取时) 全部忽略/透传 | 见 §2.2、§3.2 |

---

## 5. `mes_example` 与 `alternate_greetings`

### 5.1 `<START>` 分隔符语义

**完整实现**（`public/script.js:3501-3515`）：

```js
export function parseMesExamples(examplesStr, isInstruct) {
    if (!examplesStr || examplesStr.length === 0 || examplesStr === '<START>') return [];
    if (!examplesStr.startsWith('<START>')) examplesStr = '<START>\n' + examplesStr.trim();

    const exampleSeparator = power_user.context.example_separator
        ? `${substituteParams(power_user.context.example_separator)}\n` : '';
    const blockHeading = (main_api === 'openai' || isInstruct) ? '<START>\n' : exampleSeparator;

    return examplesStr.split(/<START>/gi).slice(1)
                     .map(block => `${blockHeading}${block.trim()}\n`);
}
```

语义要点：

1. **分隔符是 `<START>`，大小写不敏感的正则** `/<START>/gi`。
2. **只保留分隔符之后的内容**：`split(...).slice(1)` 丢弃第 0 段。因此若文本不以 `<START>` 开头，会先**自动前置** `'<START>\n'`（`:3506-3508`），保证第一块内容不被丢掉。注意前置用的是 `examplesStr.trim()`，即**整个字符串首尾被 trim**。
3. 空串、或字符串恰好等于 `'<START>'` → 返回 `[]`（`:3502-3504`）。
4. 每个块被 `trim()`，末尾追加一个 `\n`。
5. **块前缀（blockHeading）取决于模式**：
   - OpenAI API 或 Instruct 模式 → 前缀为字面量 `"<START>\n"`。
   - 其他（默认 text completion）→ 前缀为 `power_user.context.example_separator` 经过 `substituteParams`（宏替换）+ `\n`；未配置则为空串。
6. 调用方：`public/script.js:2932-2941`（`environment.mesExamples`，Instruct 时再过 `formatInstructModeExamples`）、`public/script.js:4616`（构建 prompt，`:4658` 另存 `mesExamplesRaw`）。

### 5.2 `alternate_greetings` 用法

- **存储位置**：`data.alternate_greetings`（string[]）。前端读取 `characters[chid].data.alternate_greetings`（`public/script.js:3461`、`:7712`）。
- **读写为 swipes**（`public/script.js:7710-7742` `getFirstMessage()`）：
  ```
  swipes = [first_mes, ...alternate_greetings]     // first_mes 是第 0 个 swipe
  if (first_mes 为空) { swipes.shift(); message.mes = swipes[0]; }   // 首条为空则用第一个备选
  message.swipe_id = 0
  message.swipes = swipes
  message.swipe_info = swipes.map(...)             // 每个 swipe 一个 send_date/gen_started/gen_finished/extra
  ```
  → **备选开场白就是第 1 条消息的 swipe 列表**，用户左滑右滑切换。每个 greeting 都会过 `getRegexedString(..., regex_placement.AI_OUTPUT)`。
- **UI 编辑**：`openAlternateGreetings()`（`public/script.js:9623` 附近）。若 `data.alternate_greetings` 不是数组则**就地初始化为 `[]`**（`:9630-9632`）。表单以重复的 `alternate_greetings` 字段提交（`:9784-9787`、`:9875-9879`）。
- **导出**：`charaFormatData` 的 `getAlternateGreetings` 会保留数组（`src/endpoints/characters.js:573-577`、`:612`）。注意：**通过表单保存时，`create_save.alternate_greetings` 是权威来源**（不存在卡里但 UI 未加载的情况）。
- **`group_only_greetings` 完全是另一回事**：它**不是** swipe 列表，ST 不读取（§2.2）。

---

## 6. 导出

### 6.1 导出 PNG

`POST /api/characters/export` body `{format:'png', avatar_url}`（`src/endpoints/characters.js:1658-1668`）：

```
rawBuffer = readFile(characters/{avatar_url})
rawData   = read(rawBuffer)                                    // 解出 JSON 字符串（ccv3 优先！）
mutated   = mutateJsonString(rawData, unsetPrivateFields)      // 解析→改→重新 stringify
                                                     // （src/util.js:1354-1363；解析失败则原样返回）
mutatedBuffer = write(rawBuffer, mutated)                       // 见 §1.2
Content-Type: image/png
Content-Disposition: attachment; filename="{basename}"
```

**关键结论**：
- **同时写 `chara` 与 `ccv3`**（`src/character-card-parser.js:29`、`:39`）。
- `chara` chunk 内是 **v2 结构的 JSON**（`spec:'chara_card_v2'`）；`ccv3` chunk 内是同一份数据但 `spec:'chara_card_v3'`、`spec_version:'3.0'`。**v3 只是改标签**。
- 写之前会 `unsetPrivateFields`：`fav=false`（顶层 + `data.extensions.fav`）、删除顶层 `chat`。
- ⚠️ **注意 `read()` 优先 `ccv3`**：因此导出时若原图已有 `ccv3`（内容为 v3 标签），`rawData` 是那份 v3 标签的 JSON，再写回去时 `write()` 又会把它的 `spec` 强制设成 `chara_card_v3`。**导出不会把 v3 卡降级回 v2**。
- 导出文件的下载名由前端决定：`characters[this_chid].avatar.replace('.png', '.' + format)`，即 `Seraphina.png` → `Seraphina.png`（format=png）或 `Seraphina.json`（format=json）（`public/script.js:12060`）。

### 6.2 导出 JSON

`src/endpoints/characters.js:1669-1679`：

```
json = readCharacterData(filename)                       // 卡内原始 JSON 字符串
jsonObject = getCharaCardV2(JSON.parse(json), directories) // ★ hoistDate 默认 true → 若缺 create_date 会补 now
unsetPrivateFields(jsonObject)
response.type('json').send(JSON.stringify(jsonObject, null, 4))   // 4 空格缩进
```

**导出的是 v2 还是 v3？**
→ **取决于卡里原本是什么**。`getCharaCardV2` 只看 `spec` 是否存在：v2 卡导出 v2（`spec:'chara_card_v2'`），v3 卡导出 v3（`spec:'chara_card_v3'`）。**ST 从不主动升级 v2→v3，也不会写 `ccv3` 到 JSON 里**。
导出内容是**顶层平铺 + `data` 的完整对象**（含所有 ST 内部扩展字段如 `data.extensions`、`data.character_book`、`group_only_greetings` 等透传键）。

### 6.3 其他写入路径（都会重写整张卡）

| 端点 | 行 | 说明 |
|---|---|---|
| `POST /create` | `:1024-1051` | `charaFormatData(request.body)` → PNG。`file_name` 可指定内部名 |
| `POST /edit` | `:1101-1140` | 同 `charaFormatData`，但 `chat` / `create_date` 用请求体回填（`:1115-1116`），避免丢字段 |
| `POST /edit-attribute` | `:1193-1232` | **同时**写 `char[field]` 与 `char.data[field]`（`:1222-1223`）；禁止改 `json_data` |
| `POST /merge-attributes` | `:1328-1414` | `deepMerge` + 哨兵值 `__@@UNSET@@__` 删除键（`:1243`、`:1256-1264`），写完过一次 `TavernCardValidator`（接受 V1/V2/V3，`:1295-1299`）。支持批量 `avatars[]`，并发 10（`:1246`） |
| `POST /rename` | `:1053-1099` | 只改 `data.name` + `name`，重写 PNG，重命名聊天目录 |
| `POST /duplicate` | `:1601-1644` | 文件级复制；名字以 `_N` 递增 |

**重要**：`merge-attributes` 是前端保存角色编辑的主要通道（`public/script.js:10785`、`public/scripts/extensions.js:2111`、`public/scripts/world-info.js:4299` 等），它**不做 `readFromV2` 归一化**，直接 `deepMerge` 后校验后写回，因此 `data` 与顶层字段可能不一致——ST 容忍这种不一致。

---

## 7. 头像（avatar）存储与文件名

### 7.1 存储形式

- **角色卡本身就是头像 PNG**：`{userData}/characters/{internal_name}.png`（`src/endpoints/characters.js:257`）。JSON 数据就嵌在同一文件的 `tEXt` chunk 里，**没有独立的数据文件**。
- 卡内 `avatar` 字段在**写入时恒为字符串 `'none'`**（`src/endpoints/characters.js:589`），运行时由服务端覆盖为真实文件名（`:413`）。**不要把 `avatar` 字段当作持久化的标识符**。
- 真正的角色标识符 = **PNG 文件名**（含 `.png`），前端叫 `avatar`（例：`Seraphina.png`）。
- 聊天目录 = `{userData}/chats/{avatar 去掉 .png}/`（`:419`、`:1503-1504`），里面是 `*.jsonl`。
- 精灵图/表情目录 = `{userData}/characters/{角色名}/`（**用角色名，不是文件名**，`src/endpoints/sprites.js:18-38`；CharX 导入时注释也强调这点 `src/endpoints/characters.js:784-786`）。
- 图库/杂项资源目录 = `{userData}/user/images/{角色名}/`（`src/charx.js:336`）。
- 角色背景目录 = `{userData}/characters/{角色名}/backgrounds/`（`src/charx.js:370`）。
- 缩略图 = `{userData}/thumbnails/avatar/`（`src/endpoints/thumbnails.js:66-67`）。
- 目录常量见 `src/constants.js:16-48`（`USER_DIRECTORY_TEMPLATE`；`characters: 'characters'` 在 `:29`、`chats: 'chats'` 在 `:28`、`worlds: 'worlds'` 在 `:22`、`userImages: 'user/images'` 在 `:25`、`thumbnailsAvatar: 'thumbnails/avatar'` 在 `:20`）。

### 7.2 文件名规则

```js
function getPngName(file, directories) {                    // src/endpoints/characters.js:1543-1547
    file = sanitize(file);
    return getUniqueName(file,
        (name) => fs.existsSync(path.join(directories.characters, `${name}.png`)),
        { nameBuilder: (base, i) => i === 0 ? base : `${base}${i}`, startIndex: 0, maxTries: 10000 }) ?? file;
}
```

- **清洗**：`sanitize-filename`（`node_modules/sanitize-filename/index.js`），默认 **replacement = 空串**（删除而非替换）：
  - 删除 `/ ? < > \ : * | "`（`illegalRe`)
  - 删除控制字符 `\x00-\x1f` 与 `\x80-\x9f`（`controlRe`）
  - 纯点号名（`.`、`..`）→ 删除（`reservedRe = /^\.+$/`）
  - Windows 保留名（`con|prn|aux|nul|com0-9|lpt0-9`，可带扩展名，不分大小写）→ 删除
  - 结尾的 `.` 和空格 → 删除（`windowsTrailingRe = /[\. ]+$/`）
  - **按 UTF-8 字节截断到 255 字节**（`truncate-utf8-bytes`）
  - 若指定了 `replacement`，会再跑一次 `sanitize(output, '')` 清理替换后残留的非法字符（CharX 用 `'_'`，见 `src/util.js:625-627`）
- **重名去重**：`base.png`、`base1.png`、`base2.png`…（注意**没有分隔符**，直接拼数字），最多尝试 10000 次，超限回退 `base`。
- `/duplicate` 端点用另一套规则：若文件名以 `_数字` 结尾则数字 +1，否则加 `_1`，冲突继续递增（`src/endpoints/characters.js:1613-1635`）。
- **文件名安全校验**：`forbiddenRegExp = /[/\x00]/`（Windows 上含 `\\`），在 `/rename`、`/edit`、`/edit-avatar`、`/edit-attribute`、`/get`、`/delete`、`/export`、`/merge-attributes` 上作为中间件（`src/middleware/validateFileName.js:3`、`:24-45`）。`/delete` 还额外要求 `avatar_url === sanitize(avatar_url)`（`src/endpoints/characters.js:1421-1424`）。
- 前端 `getCharaFilename(chid)` = `avatar.replace(/\.[^/.]+$/, '')`，即**去掉最后一个扩展名**（`public/scripts/utils.js:1342-1347`）。用于关联 `world_info.charLore`（额外世界书）。

### 7.3 头像图像处理

- 上传的头像会经 Jimp 重新编码为 PNG，可选裁剪/缩放（`src/endpoints/characters.js:239-334`）。
- 标准头像尺寸：`AVATAR_WIDTH = 512`、`AVATAR_HEIGHT = 768`（`src/constants.js:358-359`），仅在 `crop.want_resize` 为真时应用。
- Jimp 读取失败（例如 APNG）→ **直接读原文件字节**，不重编码（`:329-333`）。
- 图像整体失败 → 回退默认头像 `./public/img/ai4.png`（`src/constants.js:360`，使用点在 `:249`）。
- 裁剪参数 `crop = {x, y, width, height, want_resize}` 从 query `?crop=<urlencoded json>` 传入（`:1041`、`:1125`）。

---

## 8. 解析流程图（文字描述）

### 8.1 PNG 读卡（服务端 `importFromPng`）

```
[上传 .png] 
   └─> readCharacterData(path)                              src/endpoints/characters.js:181-209
         ├─ memoryCache 命中？(key = path + mtimeMs)          :182-185
         ├─ diskCache (node-persist, DATA_ROOT/_cache/characters) 命中？ :186-196
         └─> parse(path,'png')                              src/character-card-parser.js:86-97
               └─> read(buffer)                             src/character-card-parser.js:54-78
                     ├─ png-chunks-extract: 校验 8B 签名 / IHDR 首块 / IEND 存在 / 每块 CRC32
                     ├─ 收集所有 name === 'tEXt' 的块 → PNGtext.decode → {keyword,text}
                     ├─ 空 → throw 'No PNG metadata.'
                     ├─ 找 keyword.toLowerCase()==='ccv3' → 有则 utf8(base64decode(text)) 返回
                     ├─ 找 keyword.toLowerCase()==='chara' → 有则 utf8(base64decode(text)) 返回
                     └─ 都没有 → throw 'No PNG metadata.'
   └─> JSON.parse(jsonData)
   └─> sanitize(jsonData.data?.name) / jsonData.name = sanitize(data.name || name)   :974-977
   └─> getPngName() → 内部文件名（重名则加数字）                                     :978
   ├─ spec !== undefined ?
   │    ├─ YES → importRisuSprites → unsetPrivateFields → readFromV2 → create_date = now
   │    │        → writeCharacterData(上传的原图, JSON) → 删除临时上传文件          :980-989
   │    └─ NO
   │         └─ name !== undefined ?
   │              ├─ YES → 剥离 "Creator's notes go here." → 构造 v1 中间对象
   │              │        → convertToV2 → charaFormatData → writeCharacterData     :990-1016
   │              └─ NO  → 返回 ''（导入失败 → HTTP 400）                            :1019
   └─> writeCharacterData: 读图/裁剪/重编码 → write(image, json) → 
        characters/{name}.png (writeFileAtomicSync)                                 :220-265
```

### 8.2 写卡（`write()` 内部）

```
JSON.stringify(card)
  → utf8 bytes → Base64（标准字母表）
  → PNGtext.encode('chara', b64)  → Uint8Array(keyword + 0x00 + b64)
  → 删除所有 keyword∈{chara,ccv3}(lower) 的 tEXt 块
  → chunks.splice(len-1, 0, charaChunk)                    // 插在 IEND 前
  → try { 改 spec/spec_version → 同样 base64 → PNGtext.encode('ccv3', b64)
          → chunks.splice(len-1, 0, ccv3Chunk) } catch {}   // 最终 chara 在 ccv3 之前
  → encode(chunks): 重写签名 + 逐块 [BE32 len][4B name][data][BE32 CRC32(name+data)] 
  → writeFileAtomicSync(characters/{name}.png)
```

### 8.3 角色列表装配（`processCharacter`）

```
对 characters/ 下每个 *.png：
  readCharacterData → JSON.parse
  → getCharaCardV2(obj, dirs, hoistDate=false)
       spec 缺失 ? convertToV2(v1 形状) : readFromV2(把 data.* 拍平到顶层)
  → avatar = 文件名; json_data = 原始 JSON 字符串
  → date_added = ctimeMs; create_date = 卡内值 || ISO(ctimeMs)
  → chat_size / date_last_chat = 扫描 chats/{name}/ 目录
  → data_size = Σ len(String(v)) over data 的所有一级 value
  → shallow ? toShallow(...) : 完整对象
  （异常 → {date_added:0, date_last_chat:0, chat_size:0}，前端按无 name 过滤掉）
```

---

## 9. 必须复刻的兼容逻辑清单

按"实现优先级"排序，每条都给出可验证的行为：

**A. 装载/解析**
1. [ ] 只解析 `tEXt`；`iTXt`/`zTXt` 一律忽略（`src/character-card-parser.js:57`）。
2. [ ] 关键字大小写不敏感比较（`.toLowerCase()`）。
3. [ ] `ccv3` 优先于 `chara`；同关键字取第一个匹配。
4. [ ] Base64 → UTF-8 解码；Base64 是标准字母表 + `=` padding。
5. [ ] 找不到 tEXt 或找不到角色数据 → 导入失败（不区分原因）。
6. [ ] 读时校验每个 chunk 的 CRC32（**ST 行为：严格失败**）。若你的实现选择放宽（跳过坏块继续扫描），要意识到这与 ST 不一致。
7. [ ] 写入必须产出正确 CRC 与正确的大端长度字段。
8. [ ] 写入顺序：`tEXt(chara)` 在前、`tEXt(ccv3)` 在后，均紧邻 `IEND` 之前。
9. [ ] 写入时删除已有的 `chara` / `ccv3` tEXt 块，保留其他 tEXt。
10. [ ] 写 `ccv3` 时只改 `spec`/`spec_version`，不注入任何 v3 新字段；`JSON.parse` 失败时静默跳过 `ccv3`。

**B. 卡片版本判定与归一化**
11. [ ] 分水岭是 `spec` 键**是否存在**，与其值无关（`src/endpoints/characters.js:451`）。
12. [ ] 有 `spec` 但 `data` 缺失 → 原样返回，不抛错（`:505-508`）。
13. [ ] `readFromV2`：`data.*` 覆盖顶层同名字段；顶层值仅用于 warn 比较。
14. [ ] `talkativeness` 缺省回填 `0.5`；`fav` 缺省回填 `false`（仅这两个字段会回填）。
15. [ ] 内部对象必须同时携带 `json_data`（原始 JSON 字符串），且导入/归一化时先 `unset` 防递归。
16. [ ] 导入 v2 后强制 `create_date = now ISO`；读取列表（hoistDate=false）不刷新。
17. [ ] 生成卡时**顶层与 `data` 双写** v1 字段 + `creatorcomment`。
18. [ ] `fav` 解析用字符串比较 `== 'true'`。
19. [ ] `tags` 兼容逗号分隔字符串（split + trim + 去空）。
20. [ ] `alternate_greetings` 兼容单字符串。
21. [ ] 剥离字面量 `"Creator's notes go here."`。
22. [ ] Gradio/Pygmalion 字段映射：`char_name`/`char_persona`/`char_greeting`/`world_scenario`/`example_dialogue`。
23. [ ] `creatorcomment` ⇄ `creator_notes` 双向。
24. [ ] `avatar` 在卡内写 `'none'`，运行时替换为文件名。

**C. character_book → 世界书**
25. [ ] `entry.id` 缺失时就地补 `index`（并且要写回原对象，供 `originalData` 用）。
26. [ ] `enabled` → `disable` 取反。
27. [ ] `position`：`extensions.position`（数字）优先，否则 `position === 'before_char' ? 0 : 1`。
28. [ ] 所有 `extensions.*` → 内部驼峰字段的映射表（§3.3），以及**反向**写回表（§3.3 右列）。
29. [ ] `addMemo = !!comment`。
30. [ ] `probability`/`useProbability` 用 `??`（保留 `0`/`false`）；`group_weight` 保留 `null`（ST 内部默认是 `100`，但转换时会写入 `null`）。
31. [ ] 未知 `extensions` 键必须原样透传（`...entry.extensions` 展开 + `extensions: entry.extensions`）。
32. [ ] 世界书顶层保留 `originalData`，导出卡时优先无损回写。
33. [ ] `character_book.name` 缺省 → `` `${char.name}'s Lorebook` ``。
34. [ ] 磁盘世界书 `entries` 是 **object（uid 字符串键）**，卡内是 **array**。

**D. 导出**
35. [ ] 导出前 `fav=false`（顶层 + `data.extensions.fav`）、删除顶层 `chat`。
36. [ ] JSON 导出用 4 空格缩进，且会补 `create_date`。
37. [ ] PNG 导出保留原图其余 chunk，只替换角色数据块。
38. [ ] 不主动把 v2 升为 v3。

**E. 文件系统**
39. [ ] 角色卡 = `characters/{sanitized(name)}.png`；重名 → `name1.png`、`name2.png`。
40. [ ] 聊天 = `chats/{avatar 去扩展名}/*.jsonl`。
41. [ ] 精灵图 = `characters/{角色名}/`（用名字而非文件名）。
42. [ ] `sanitize-filename` 的字符删除规则 + 255 UTF-8 字节截断。

---

## 10. 完整示例

### 10.1 最小但完整的 v2 角色卡（含 `character_book`）

这是 ST 实际会产出的形状：**顶层平铺 v1 字段 + `spec`/`spec_version`/`data` 三段**。

```json
{
  "name": "Lyra",
  "description": "Lyra is a lighthouse keeper on a storm-wracked coast.",
  "personality": "Quiet, patient, wry.",
  "scenario": "A lighthouse on the Cliffs of Mourne, present day.",
  "first_mes": "*The lamp sweeps past the window as Lyra looks up from her logbook.* \"You picked a rough night to climb the stairs.\"",
  "mes_example": "<START>\n{{user}}: What do you do out here?\n{{char}}: *She shrugs, one hand on the rail.* \"I keep the light turning. That's the whole job.\"\n<START>\n{{user}}: Aren't you lonely?\n{{char}}: *A pause.* \"The sea talks enough for two.\"",
  "creatorcomment": "Written as a test card.",
  "avatar": "none",
  "chat": "Lyra - 2024-1-1 @12h 0m 0s 0ms",
  "create_date": "2024-01-01T12:00:00.000Z",
  "talkativeness": 0.5,
  "fav": false,
  "tags": ["slice-of-life", "female"],
  "spec": "chara_card_v2",
  "spec_version": "2.0",
  "data": {
    "name": "Lyra",
    "description": "Lyra is a lighthouse keeper on a storm-wracked coast.",
    "personality": "Quiet, patient, wry.",
    "scenario": "A lighthouse on the Cliffs of Mourne, present day.",
    "first_mes": "*The lamp sweeps past the window as Lyra looks up from her logbook.* \"You picked a rough night to climb the stairs.\"",
    "mes_example": "<START>\n{{user}}: What do you do out here?\n{{char}}: *She shrugs, one hand on the rail.* \"I keep the light turning. That's the whole job.\"\n<START>\n{{user}}: Aren't you lonely?\n{{char}}: *A pause.* \"The sea talks enough for two.\"",
    "creator_notes": "Written as a test card.",
    "system_prompt": "",
    "post_history_instructions": "",
    "alternate_greetings": [
      "*Rain hammers the glass. Lyra doesn't turn around.* \"Door's not locked. It never is.\""
    ],
    "tags": ["slice-of-life", "female"],
    "creator": "example-author",
    "character_version": "1.0",
    "extensions": {
      "talkativeness": 0.5,
      "fav": false,
      "world": "",
      "depth_prompt": {
        "prompt": "",
        "depth": 4,
        "role": "system"
      }
    },
    "character_book": {
      "name": "Lyra's Lorebook",
      "description": "Background lore for the lighthouse.",
      "scan_depth": 4,
      "token_budget": 512,
      "recursive_scanning": false,
      "extensions": {},
      "entries": [
        {
          "id": 0,
          "keys": ["lighthouse", "the light"],
          "secondary_keys": ["storm"],
          "comment": "The lighthouse",
          "content": "The lighthouse is 90 years old and automated on paper only. Lyra still winds the mechanism by hand every night.",
          "constant": false,
          "selective": true,
          "insertion_order": 100,
          "enabled": true,
          "position": "before_char",
          "case_sensitive": false,
          "name": "The Lighthouse",
          "priority": 10,
          "use_regex": true,
          "extensions": {
            "position": 0,
            "exclude_recursion": false,
            "display_index": 0,
            "probability": 100,
            "useProbability": true,
            "depth": 4,
            "selectiveLogic": 0,
            "group": "",
            "group_override": false,
            "group_weight": null,
            "prevent_recursion": false,
            "delay_until_recursion": false,
            "scan_depth": null,
            "match_whole_words": null,
            "use_group_scoring": false,
            "case_sensitive": null,
            "automation_id": "",
            "role": 0,
            "vectorized": false,
            "sticky": null,
            "cooldown": null,
            "delay": null,
            "match_persona_description": false,
            "match_character_description": false,
            "match_character_personality": false,
            "match_character_depth_prompt": false,
            "match_scenario": false,
            "match_creator_notes": false,
            "ignore_budget": false
          }
        }
      ]
    },
    "group_only_greetings": []
  }
}
```

> **对最小实现者的说明**：只有 `spec` / `spec_version` / `data` 的"干净 v2 卡"**可以**被 ST 读取（`readFromV2` 会把 `data.*` 拍平到顶层，并给 `talkativeness`/`fav` 回填默认值）。但要让**别人**的 ST 也能读你导出的卡，就必须按上面的形状双写顶层 v1 字段。反过来，你的 Swift 实现**必须能吃下**两种形状：只有 `data` 的干净卡，和 ST 导出的双写卡。

### 10.2 v1 角色卡 JSON 示例

v1 卡就是纯平铺对象（PNG 的 `chara` chunk 内容，或一个 `.json` 文件）：

```json
{
  "name": "Old Mariner",
  "description": "A retired sailor who tells stories for drinks.",
  "personality": "Boisterous, sentimental, unreliable.",
  "scenario": "A dockside tavern, late evening.",
  "first_mes": "*He waves you over with a hand missing two fingers.* \"Sit, sit! You look like someone who buys a story.\"",
  "mes_example": "<START>\n{{user}}: Tell me about the storm.\n{{char}}: *He goes quiet for a moment.* \"There's storms, and then there's that one. Another round first.\"",
  "creatorcomment": "Public domain test card.",
  "avatar": "none",
  "chat": "Old Mariner - 2024-1-1 @12h 0m 0s 0ms",
  "create_date": "2024-01-01T12:00:00.000Z",
  "talkativeness": 0.5,
  "fav": false,
  "tags": "male, historical, tavern"
}
```

**导入时 ST 的行为**（`src/endpoints/characters.js:997-1012`，PNG 路径；JSON 路径 `:910-925` 相同）：

1. `jsonData.name` 存在、`spec` 不存在 → 走 v1 分支。
2. `creatorcomment` ← `creatorcomment ?? creator_notes ?? ''`（本示例取 `"Public domain test card."`）。
3. 未提供的字段一律 `?? ''`（`description`/`personality`/`first_mes`/`mes_example`/`scenario`/`creator`），`talkativeness` ← `?? 0.5`，`tags` ← `?? ''`。
4. `create_date` **被覆盖为当前时间**（不保留卡内的 `2024-01-01T12:00:00.000Z`）。
5. `avatar` 被硬编码为 `'none'`；`chat` 重新生成为 `"Old Mariner - <humanizedDateTime()>"`。
6. 上面这个对象作为 `json_data` 传入 `convertToV2` → `charaFormatData`，最终产出 §10.1 那样的双写 v2 卡。
7. `tags` 是逗号分隔字符串 → 变成 `["male","historical","tavern"]`。
8. 因为没有 `world` 字段，`data.character_book` **不会**被生成。

> ⚠️ 注意第 8 点：**v1 卡的路由不会生成 character_book**，即使 v1 卡里带了 `world` 也不会（`convertToV2` 只传了上列字段，没有 `world`，见 `src/endpoints/characters.js:471-487`）。只有走前端表单（`/create` / `/edit`）时 `world` 才会被处理。

---

## 附录：关键常量与路径速查

| 项 | 值 | 来源 |
|---|---|---|
| 标准头像尺寸 | 512 × 768 | `src/constants.js:358-359` |
| 默认头像 | `./public/img/ai4.png` | `src/constants.js:360` |
| 角色卡目录 | `{dataRoot}/{handle}/characters` | `src/constants.js:29` |
| 聊天目录 | `{dataRoot}/{handle}/chats` | `src/constants.js:28` |
| 世界书目录 | `{dataRoot}/{handle}/worlds` | `src/constants.js:22` |
| 角色图库 | `{dataRoot}/{handle}/user/images` | `src/constants.js:25` |
| 头像缩略图 | `{dataRoot}/{handle}/thumbnails/avatar` | `src/constants.js:20` |
| 磁盘缓存 | `{dataRoot}/_cache/characters` | `src/endpoints/characters.js:69` |
| 缓存同步间隔 | 5 分钟 | `src/endpoints/characters.js:49` |
| 允许导入的扩展名 | `json, png, yaml, yml, charx, byaf` | `public/script.js:10537`、`src/endpoints/characters.js:1567-1574` |
| WI 默认深度 | `DEFAULT_DEPTH = 4` | `public/scripts/world-info.js:96` |
| WI 默认权重 | `DEFAULT_WEIGHT = 100` | `public/scripts/world-info.js:97` |
| WI 最大扫描深度 | `MAX_SCAN_DEPTH = 1000` | `public/scripts/world-info.js:98` |
| 合并哨兵值 | `'__@@UNSET@@__'` | `src/endpoints/characters.js:1243` |
| 批量合并并发 | `BULK_MERGE_CONCURRENCY = 10` | `src/endpoints/characters.js:1246` |

## 附录：本次未能确认 / 需注意的点

1. **zTXt / iTXt 的读取**：ST 代码路径完全不支持。其他工具（如部分卡站导出器）可能写 iTXt——**你的 Swift 实现若想更宽容，建议额外支持 iTXt**，但要知道 ST 本身读不了。
2. **CRC 校验的严格程度**：ST 读时严格失败；这会让一些由粗糙工具产出的卡直接导入失败。是否放宽是产品决策。
3. **`character_book` 顶层 `scan_depth`/`token_budget`/`recursive_scanning`/`description`**：ST 明确不消费（只用全局设置），但会通过 `originalData` 原样保留。若你的实现要成为"更好的 ST"，可以考虑消费这些字段。
4. **`group_only_greetings`**：官方 CCv2/v3 社区字段，ST 1.19.0 完全无引用，纯透传。
5. **v3 官方新增字段**（`nickname`、`creator_notes_multilingual`、`source`、`assets`、`creation_date`、`modification_date`）：除 CharX 的 `assets` 外无引用，纯透传。
