import Foundation

/// PNG 的一个数据块。
struct PNGChunk {
    /// 4 字节 ASCII 类型名，如 `IHDR`、`tEXt`、`IDAT`、`IEND`。
    var name: String
    var data: Data

    /// 原始 CRC 值（解析时记录，用于校验）。
    var storedCRC: UInt32?

    /// 按 PNG 规范计算该 chunk 应有的 CRC：覆盖 `type + data`。
    var computedCRC: UInt32 {
        CRC32.checksum([Array(name.utf8), Array(data)])
    }

    var isCRCCorrect: Bool {
        guard let storedCRC else { return true }
        return storedCRC == computedCRC
    }
}

/// PNG 读写。
///
/// 只做 SillyTavern 需要的那一层：拆出所有 chunk、按需增删、重新拼回字节流。
/// 这样做的好处是导入角色卡后可以**原样保底**地导出——图像数据一个字节都不动，
/// 只替换承载角色 JSON 的 tEXt 块。
enum PNGCodec {
    /// PNG 文件签名。
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    enum Error: LocalizedError {
        case notPNG
        case truncated
        case missingIEND
        case malformedChunk(String)

        var errorDescription: String? {
            switch self {
            case .notPNG:
                return "不是有效的 PNG 文件（文件头签名不匹配）"
            case .truncated:
                return "PNG 文件不完整，数据被截断"
            case .missingIEND:
                return "PNG 文件缺少 IEND 结束块"
            case .malformedChunk(let name):
                return "PNG 数据块「\(name)」格式异常"
            }
        }
    }

    // MARK: - 解析

    /// 拆出 PNG 的所有 chunk。
    ///
    /// 关于 CRC：SillyTavern 用的 `png-chunks-extract` 会对每个块校验 CRC 并在
    /// 不匹配时抛错。我们这里**记录但不强制**——因为移动端拿到的图片可能经过
    /// 各种工具重写，为了尽量让用户能导入成功，CRC 错误时仅在需要时提示。
    static func parse(_ data: Data) throws -> [PNGChunk] {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else { throw Error.truncated }
        guard Array(bytes[0..<8]) == signature else { throw Error.notPNG }

        var chunks: [PNGChunk] = []
        var offset = 8
        var sawIEND = false

        while offset + 8 <= bytes.count {
            // 长度（大端 UInt32）
            let length = Int(bytes[offset]) << 24
                | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8
                | Int(bytes[offset + 3])
            offset += 4

            guard length >= 0, offset + 4 <= bytes.count else { throw Error.truncated }

            // 类型（4 字节 ASCII）
            let nameBytes = Array(bytes[offset..<offset + 4])
            guard let name = String(bytes: nameBytes, encoding: .isoLatin1) else {
                throw Error.malformedChunk("????")
            }
            offset += 4

            guard offset + length + 4 <= bytes.count else { throw Error.truncated }

            let chunkData = Data(bytes[offset..<offset + length])
            offset += length

            let crc = UInt32(bytes[offset]) << 24
                | UInt32(bytes[offset + 1]) << 16
                | UInt32(bytes[offset + 2]) << 8
                | UInt32(bytes[offset + 3])
            offset += 4

            chunks.append(PNGChunk(name: name, data: chunkData, storedCRC: crc))

            if name == "IEND" {
                sawIEND = true
                break
            }
        }

        guard sawIEND else { throw Error.missingIEND }
        return chunks
    }

    // MARK: - 编码

    /// 把 chunk 列表拼回 PNG 字节流。CRC 一律重新计算。
    static func encode(_ chunks: [PNGChunk]) -> Data {
        var out = Data(signature)
        for chunk in chunks {
            let nameBytes = Array(chunk.name.utf8)
            out.append(contentsOf: bigEndianBytes(UInt32(chunk.data.count)))
            out.append(contentsOf: nameBytes)
            out.append(chunk.data)
            out.append(contentsOf: bigEndianBytes(chunk.computedCRC))
        }
        return out
    }

    private static func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
    }

    // MARK: - tEXt 块

    /// 解析 tEXt 块：`keyword` + 0x00 + `text`。
    ///
    /// 与 `png-chunk-text` 的 decode 一致：以第一个 NUL 分隔关键字与正文。
    static func decodeText(_ data: Data) -> (keyword: String, text: String)? {
        guard let nulIndex = data.firstIndex(of: 0x00) else { return nil }
        let keywordBytes = data[data.startIndex..<nulIndex]
        let textBytes = data[data.index(after: nulIndex)...]
        guard
            let keyword = String(bytes: keywordBytes, encoding: .isoLatin1),
            let text = String(bytes: textBytes, encoding: .isoLatin1)
        else { return nil }
        return (keyword, text)
    }

    /// 构造 tEXt 块。
    static func encodeText(keyword: String, text: String) -> PNGChunk {
        var data = Data(keyword.data(using: .isoLatin1) ?? Data())
        data.append(0x00)
        data.append(text.data(using: .isoLatin1) ?? Data())
        return PNGChunk(name: "tEXt", data: data)
    }

    /// 在 IEND 之前插入一个 chunk。
    ///
    /// 与 ST 的行为一致：连续插入时，先插入的排在前面，
    /// 最终顺序为 `IHDR, …, tEXt(chara), tEXt(ccv3), IEND`。
    static func insertingBeforeIEND(_ chunk: PNGChunk, into chunks: [PNGChunk]) -> [PNGChunk] {
        var result = chunks
        if let index = result.lastIndex(where: { $0.name == "IEND" }) {
            result.insert(chunk, at: index)
        } else {
            result.append(chunk)
        }
        return result
    }

    /// 移除关键字为 chara / ccv3 的 tEXt 块（大小写不敏感）。
    ///
    /// 只处理 `tEXt`，与 ST 一致：iTXt / zTXt 里的同名关键字不动。
    static func removingCharacterTexts(from chunks: [PNGChunk]) -> [PNGChunk] {
        chunks.filter { chunk in
            guard chunk.name == "tEXt" else { return true }
            guard let decoded = decodeText(chunk.data) else { return true }
            let keyword = decoded.keyword.lowercased()
            return keyword != "chara" && keyword != "ccv3"
        }
    }
}
