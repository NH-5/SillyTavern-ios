import Foundation

/// CRC-32（IEEE 802.3，PNG 使用的那个多项式）。
///
/// PNG 每个 chunk 都要在尾部写 4 字节的大端 CRC，覆盖 `type + data`。
/// 写入时必须算对；读取时为了容错会参考但不强制。
enum CRC32 {
    /// 查表法用的预计算表。多项式 0xEDB8020（反射形式）。
    private static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 {
                if value & 1 == 1 {
                    value = 0xEDB8_8320 ^ (value >> 1)
                } else {
                    value >>= 1
                }
            }
            table[index] = value
        }
        return table
    }()

    /// 计算数据的 CRC-32。
    static func checksum(_ bytes: some Sequence<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// 计算多个片段的 CRC-32（PNG 需要把 type 与 data 连起来算）。
    static func checksum(_ chunks: [some Sequence<UInt8>]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for chunk in chunks {
            for byte in chunk {
                let index = Int((crc ^ UInt32(byte)) & 0xFF)
                crc = table[index] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
