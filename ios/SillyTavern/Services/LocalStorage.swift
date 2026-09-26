import Foundation

/// 本地文件存储。
///
/// 目录布局刻意向 SillyTavern 靠拢，便于后续直接读写 ST 的导出文件：
/// ```
/// Documents/
///   characters/<角色名>.json    角色卡
///   characters/<角色名>.png     角色卡原始 PNG（保留头像与元数据）
///   chats/<角色名>/<会话名>.jsonl  聊天记录（与 ST JSONL 格式一致）
///   worlds/<世界书名>.json      世界书
///   settings.json               应用设置
/// ```
final class LocalStorage {
    static let shared = LocalStorage()

    private let fm = FileManager.default

    /// Documents 根目录。启用文件共享后可被「文件」App 访问，便于导入导出。
    let root: URL

    private init() {
        root = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? createDirectories()
    }

    // MARK: - 目录

    var charactersDirectory: URL { root.appendingPathComponent("characters", isDirectory: true) }
    var chatsDirectory: URL { root.appendingPathComponent("chats", isDirectory: true) }
    var worldsDirectory: URL { root.appendingPathComponent("worlds", isDirectory: true) }

    private func createDirectories() throws {
        for dir in [charactersDirectory, chatsDirectory, worldsDirectory] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - 通用读写

    func read(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func write(_ data: Data, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func delete(_ url: URL) throws {
        guard fm.fileExists(atPath: url.path) else { return }
        try fm.removeItem(at: url)
    }

    /// 列出目录下的文件，按文件名排序。
    func list(_ directory: URL) -> [URL] {
        let contents = (try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 把用户输入的名字转成安全的文件名。
    ///
    /// 与 ST 的 `sanitize-filename` 行为一致：
    /// - **直接删除**非法字符（replacement 默认空串），而不是替换成下划线；
    /// - 按 **255 UTF-8 字节** 截断（中文一个字 3 字节，按字符截会超限）。
    static func sanitizeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = name.components(separatedBy: invalid).joined()
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "untitled" }

        // 按 UTF-8 字节数截断，且不切断多字节字符。
        var result = ""
        var byteCount = 0
        for character in trimmed {
            let size = String(character).utf8.count
            if byteCount + size > 255 { break }
            result.append(character)
            byteCount += size
        }
        return result.isEmpty ? "untitled" : result
    }
}
