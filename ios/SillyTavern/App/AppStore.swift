import Foundation
import SwiftUI

/// 应用全局状态。
///
/// 负责三类数据的加载与落盘，格式尽量与 SillyTavern 保持一致：
/// - 角色卡：`characters/<名字>.png`（角色 JSON 存在 PNG 的 tEXt 块里）
/// - 会话：`chats/<角色名>/<会话名>.jsonl`（与 ST 的 JSONL 格式一致）
/// - 设置：`settings.json`
///
/// API Key 不走文件，统一放 Keychain。
@MainActor
final class AppStore: ObservableObject {
    /// 已导入的角色卡。
    @Published var characters: [CharacterCard] = []

    /// 本地会话列表。
    @Published var sessions: [ChatSession] = []

    /// 应用设置。
    @Published var settings: AppSettings = AppSettings()

    /// 独立世界书（worlds/<名字>.json）。
    @Published var worldInfos: [String: CharacterBook] = [:]

    /// 最近一次操作的错误信息，供界面提示。
    @Published var lastError: String?

    let storage: LocalStorage

    /// 头像图片缓存。
    ///
    /// 用 `NSCache` 而不是字典：角色卡 PNG 可能有好几 MB，
    /// 解码后的位图更大，交给系统在内存吃紧时自动回收更安全。
    private let avatarCache = NSCache<NSString, PlatformImage>()

    /// 正在后台解码的头像，避免同一个角色被重复读取。
    private var avatarTasks: [UUID: Task<PlatformImage?, Never>] = [:]

    init(storage: LocalStorage = .shared) {
        self.storage = storage
        avatarCache.countLimit = 60
        loadSettings()
        loadCharacters()
        loadSessions()
        loadWorldInfos()
    }

    // MARK: - 角色卡

    /// 按 id 查找角色。
    func character(for id: UUID) -> CharacterCard? {
        characters.first { $0.id == id }
    }

    /// 导入角色卡文件。
    @discardableResult
    func importCharacter(from url: URL) -> Result<CharacterCard, Error> {
        do {
            // 安全作用域：从「文件」App 或分享面板进来的 URL 需要显式开启访问。
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

            let data = try Data(contentsOf: url)
            let result = try CharacterCardCodec.importCard(from: data, fileName: url.lastPathComponent)

            var card = result.card
            // 头像文件名要与磁盘上的 PNG 一致；重名时按 ST 规则加序号。
            let baseName = LocalStorage.sanitizeFileName(card.displayName)
            let fileName = uniqueAvatarName(baseName: baseName, excluding: card.id)
            card.avatarFileName = fileName

            // 落盘：PNG 角色卡（同时写 chara 与 ccv3 元数据）。
            let png = try CharacterCardCodec.exportPNG(card, baseImage: result.originalPNG)
            try storage.write(png, to: storage.charactersDirectory.appendingPathComponent(fileName))

            characters.append(card)
            invalidateAvatar(for: card.id)
            loadAvatarIfNeeded(for: card)
            saveCharactersIndex()
            return .success(card)
        } catch {
            lastError = error.localizedDescription
            return .failure(error)
        }
    }

    /// 删除角色及其会话。
    func deleteCharacter(_ card: CharacterCard) {
        characters.removeAll { $0.id == card.id }
        invalidateAvatar(for: card.id)

        let avatarURL = storage.charactersDirectory.appendingPathComponent(card.avatarFileName)
        try? storage.delete(avatarURL)

        // 会话数据一并清理，避免留下孤儿目录。
        sessions.removeAll { session in
            guard session.characterId == card.id else { return false }
            try? storage.delete(chatFileURL(for: card, session: session))
            return true
        }

        saveCharactersIndex()
        saveSessionsIndex()
    }

    /// 更新角色卡（编辑后回写 PNG）。
    func updateCharacter(_ card: CharacterCard) {
        guard let index = characters.firstIndex(where: { $0.id == card.id }) else { return }
        let previous = characters[index]
        characters[index] = card

        let baseImage = avatarData(for: card)
        if let png = try? CharacterCardCodec.exportPNG(card, baseImage: baseImage) {
            let url = storage.charactersDirectory.appendingPathComponent(card.avatarFileName)
            try? storage.write(png, to: url)
            invalidateAvatar(for: card.id)
        }

        // 角色改名后，头像文件名跟着变，避免磁盘上留下旧名字。
        if previous.displayName != card.displayName {
            let baseName = LocalStorage.sanitizeFileName(card.displayName)
            let newName = uniqueAvatarName(baseName: baseName, excluding: card.id)
            if newName != card.avatarFileName, let index = characters.firstIndex(where: { $0.id == card.id }) {
                let oldURL = storage.charactersDirectory.appendingPathComponent(card.avatarFileName)
                characters[index].avatarFileName = newName
                let newURL = storage.charactersDirectory.appendingPathComponent(newName)
                try? FileManager.default.moveItem(at: oldURL, to: newURL)
            }
        }

        saveCharactersIndex()
    }

    /// 让某个角色的头像缓存失效（角色卡被修改或删除后调用）。
    private func invalidateAvatar(for id: UUID) {
        avatarCache.removeObject(forKey: id.uuidString as NSString)
        avatarTasks[id]?.cancel()
        avatarTasks.removeValue(forKey: id)
    }

    /// 读取头像图片（用于界面显示）。
    ///
    /// 解码放到后台线程：角色卡 PNG 可能有几 MB，在主线程解码会让列表滚动掉帧。
    /// 缓存命中时直接返回，不产生额外开销。
    func avatarImage(for card: CharacterCard) -> PlatformImage? {
        let key = card.id.uuidString as NSString
        if let cached = avatarCache.object(forKey: key) { return cached }
        return nil
    }

    /// 异步准备头像；解码完成后通知界面刷新。
    func loadAvatarIfNeeded(for card: CharacterCard) {
        let key = card.id.uuidString as NSString
        guard avatarCache.object(forKey: key) == nil, avatarTasks[card.id] == nil else { return }

        let url = avatarFileURL(for: card)
        guard let url else { return }

        let task = Task.detached(priority: .utility) { () -> PlatformImage? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return makePlatformImage(from: data)
        }
        avatarTasks[card.id] = task

        Task { @MainActor in
            let image = await task.value
            self.avatarTasks.removeValue(forKey: card.id)
            if let image {
                self.avatarCache.setObject(image, forKey: key)
                // 触发依赖 objectWillChange 的界面刷新。
                self.objectWillChange.send()
            }
        }
    }

    /// 读取头像原始 PNG 字节（导出角色卡时需要完整图像数据）。
    func avatarData(for card: CharacterCard) -> Data? {
        guard let url = avatarFileURL(for: card) else { return nil }
        return try? storage.read(url)
    }

    /// 定位头像文件；索引里的文件名对不上时，退回按角色名找。
    private func avatarFileURL(for card: CharacterCard) -> URL? {
        let candidates = [
            storage.charactersDirectory.appendingPathComponent(card.avatarFileName),
            storage.charactersDirectory.appendingPathComponent("\(card.displayName).png"),
        ]
        for url in candidates where !url.lastPathComponent.isEmpty && url.lastPathComponent != ".png" {
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// 生成不冲突的头像文件名（ST 规则为 `名字.png`、`名字1.png`、`名字2.png`…）。
    private func uniqueAvatarName(baseName: String, excluding id: UUID) -> String {
        let used = Set(
            characters
                .filter { $0.id != id }
                .map { $0.avatarFileName.lowercased() }
        )
        var candidate = "\(baseName).png"
        var counter = 1
        while used.contains(candidate.lowercased()) {
            candidate = "\(baseName)\(counter).png"
            counter += 1
        }
        return candidate
    }

    // MARK: - 世界书

    /// 某个角色可用的世界书条目：内嵌书 + 绑定的独立世界书。
    func worldInfoEntries(for card: CharacterCard) -> [WorldInfoEntry] {
        var entries: [WorldInfoEntry] = []
        if let book = worldInfos[card.world] {
            entries.append(contentsOf: book.entries)
        }
        return entries
    }

    /// 导入世界书 JSON。
    func importWorldInfo(from url: URL) -> Result<String, Error> {
        do {
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

            let data = try Data(contentsOf: url)
            let name = url.deletingPathExtension().lastPathComponent
            let book = try WorldInfoCodec.decode(data, name: name)
            worldInfos[name] = book
            try WorldInfoCodec.encode(book).write(to: storage.worldsDirectory.appendingPathComponent("\(name).json"))
            return .success(name)
        } catch {
            lastError = error.localizedDescription
            return .failure(error)
        }
    }

    // MARK: - 会话

    /// 为一个角色创建新会话。
    func createSession(for card: CharacterCard, greetingIndex: Int = 0) -> ChatSession {
        var session = ChatSession(
            characterId: card.id,
            name: "\(card.displayName) - \(Self.sessionTimestamp())"
        )
        session.metadata.characterName = card.name
        session.metadata.userName = settings.userName
        session.metadata.worldInfo = card.world.isEmpty ? nil : card.world

        // 开场白：first_mes 是第 0 个 swipe，备选开场白依次排在后面。
        var greetings = [card.firstMes] + card.alternateGreetings
        greetings = greetings.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !greetings.isEmpty {
            let index = min(max(0, greetingIndex), greetings.count - 1)
            let template = MacroContext(
                charName: card.name,
                userName: settings.userName,
                description: card.description,
                personality: card.personality,
                scenario: card.scenario,
                persona: settings.userPersona,
                mesExamples: card.exampleMessages.joined(separator: "\n"),
                mesExamplesRaw: card.mesExample
            )
            let text = MacroProcessor.expand(greetings[index], context: template)

            var message = ChatMessage(name: card.name, mes: text, isUser: false)
            message.swipes = greetings.map {
                MacroProcessor.expand($0, context: template)
            }
            message.swipeId = index
            session.messages = [message]
        }

        sessions.insert(session, at: 0)
        save(session: session)
        return session
    }

    /// 保存会话。
    func save(session: ChatSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
        guard let card = character(for: session.characterId) else { return }

        do {
            let data = try ChatSessionCodec.encodeJSONL(session)
            try storage.write(data, to: chatFileURL(for: card, session: session))
            saveSessionsIndex()
        } catch {
            lastError = "保存会话失败：\(error.localizedDescription)"
        }
    }

    /// 删除会话。
    func deleteSession(_ session: ChatSession) {
        if let card = character(for: session.characterId) {
            try? storage.delete(chatFileURL(for: card, session: session))
        }
        sessions.removeAll { $0.id == session.id }
        saveSessionsIndex()
    }

    /// 某个角色的全部会话，按更新时间倒序。
    func sessions(for card: CharacterCard) -> [ChatSession] {
        sessions
            .filter { $0.characterId == card.id }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 会话文件路径：`chats/<角色名>/<会话名>.jsonl`，与 ST 的目录约定一致。
    private func chatFileURL(for card: CharacterCard, session: ChatSession) -> URL {
        let folder = storage.chatsDirectory
            .appendingPathComponent(LocalStorage.sanitizeFileName(card.displayName), isDirectory: true)
        return folder.appendingPathComponent("\(LocalStorage.sanitizeFileName(session.name)).jsonl")
    }

    private static func sessionTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    // MARK: - 设置的绑定

    /// 取设置里某个字段的可写绑定。
    ///
    /// 说明：`$store.settings.x` 本身是能编译的（`EnvironmentObject` 的包装器
    /// 支持 `@dynamicMemberLookup`），但那样写入不会落盘。
    /// 这里包一层，让界面上的每次改动都自动调用 `saveSettings()`，
    /// 避免在几十个控件上散落保存逻辑。
    func settingsBinding<Value>(
        _ keyPath: WritableKeyPath<AppSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { newValue in
                self.settings[keyPath: keyPath] = newValue
                self.saveSettings()
            }
        )
    }

    /// 供应商基地址等「数组元素上的字段」的可写绑定。
    func providerBinding<Value>(
        providerId: String,
        _ keyPath: WritableKeyPath<ProviderConfig, Value>
    ) -> Binding<Value> {
        Binding(
            get: {
                guard let provider = self.settings.providers.first(where: { $0.id == providerId }) else {
                    return ProviderConfig.defaults[0][keyPath: keyPath]
                }
                return provider[keyPath: keyPath]
            },
            set: { newValue in
                guard let index = self.settings.providers.firstIndex(where: { $0.id == providerId }) else { return }
                self.settings.providers[index][keyPath: keyPath] = newValue
                self.saveSettings()
            }
        )
    }

    // MARK: - 持久化：设置

    func saveSettings() {
        do {
            let data = try JSONEncoder().encode(settings)
            try storage.write(data, to: storage.root.appendingPathComponent("settings.json"))
        } catch {
            lastError = "保存设置失败：\(error.localizedDescription)"
        }
    }

    private func loadSettings() {
        let url = storage.root.appendingPathComponent("settings.json")
        guard let data = try? storage.read(url),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return }
        settings = decoded
        // 新增的内建供应商要能补进来（老配置文件里没有）。
        let knownIds = Set(settings.providers.map(\.id))
        for provider in ProviderConfig.defaults where !knownIds.contains(provider.id) {
            settings.providers.append(provider)
        }
    }

    // MARK: - 持久化：索引

    /// 角色索引单独存一份，避免每次启动都要解析所有 PNG。
    private func saveCharactersIndex() {
        let url = storage.root.appendingPathComponent("characters.index.json")
        if let data = try? JSONEncoder().encode(characters) {
            try? storage.write(data, to: url)
        }
    }

    private func loadCharacters() {
        let url = storage.root.appendingPathComponent("characters.index.json")
        if let data = try? storage.read(url),
           let decoded = try? JSONDecoder().decode([CharacterCard].self, from: data) {
            characters = decoded
            return
        }
        // 没有索引时，扫描目录里的 PNG 重建（例如用户直接拷进来一批卡）。
        rebuildCharacterIndex()
    }

    /// 扫描 `characters/` 目录重建索引。
    private func rebuildCharacterIndex() {
        var found: [CharacterCard] = []
        for url in storage.list(storage.charactersDirectory) where url.pathExtension.lowercased() == "png" {
            guard let data = try? storage.read(url),
                  let result = try? CharacterCardCodec.importCard(from: data, fileName: url.lastPathComponent)
            else { continue }
            var card = result.card
            card.avatarFileName = url.lastPathComponent
            found.append(card)
        }
        if !found.isEmpty {
            characters = found
            saveCharactersIndex()
        }
    }

    private func saveSessionsIndex() {
        let url = storage.root.appendingPathComponent("sessions.index.json")
        if let data = try? JSONEncoder().encode(sessions) {
            try? storage.write(data, to: url)
        }
    }

    private func loadSessions() {
        let url = storage.root.appendingPathComponent("sessions.index.json")
        guard let data = try? storage.read(url),
              let decoded = try? JSONDecoder().decode([ChatSession].self, from: data)
        else { return }
        sessions = decoded
    }

    private func loadWorldInfos() {
        for url in storage.list(storage.worldsDirectory) where url.pathExtension.lowercased() == "json" {
            guard let data = try? storage.read(url) else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            if let book = try? WorldInfoCodec.decode(data, name: name) {
                worldInfos[name] = book
            }
        }
    }
}
