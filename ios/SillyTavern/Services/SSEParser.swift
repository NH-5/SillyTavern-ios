import Foundation

/// 一个已完整接收的 SSE 事件。
struct SSEEvent {
    /// `event:` 行给出的名称。OpenAI 与 Gemini 不用它，Anthropic 会用到。
    var name: String?
    /// `data:` 行拼接后的内容（多行以 `\n` 连接）。
    var data: String

    /// OpenAI 的流结束标记为字面量 `[DONE]`。
    var isDone: Bool { data == "[DONE]" }
}

/// Server-Sent Events 增量解析器。
///
/// 逐字节喂入，按 SSE 规范分帧。SillyTavern 的浏览器端解析在
/// `public/scripts/sse-stream.js`，这里复刻它的关键行为：
/// - 事件分隔支持 `\r\n\r\n`、`\r\r`、`\n\n` 三种组合；
/// - 同一事件的多个 `data:` 行用 `\n` 连接；
/// - 空 `data` 值会被丢弃（不产生事件）；
/// - 每行只裁掉**一个**结尾换行符。
///
/// 之所以不用 `URLSession.data(for:)`：那个 API 会等响应整体结束，
/// 流式输出就失去意义了。必须配合 `URLSession.bytes(for:)` 使用本解析器。
struct SSEParser {
    /// 待处理缓冲区。
    private var buffer = Data()
    /// 当前事件累积的 data 行。
    private var dataLines: [String] = []
    /// 当前事件的名称。
    private var eventName: String?

    init() {}

    /// 喂入一段新到达的字节，返回其中包含的所有完整事件。
    mutating func feed(_ chunk: Data) -> [SSEEvent] {
        buffer.append(chunk)
        var events: [SSEEvent] = []

        while let (range, separatorLength) = Self.findEventBoundary(in: buffer) {
            let frameData = buffer[buffer.startIndex..<range.lowerBound]
            buffer.removeSubrange(buffer.startIndex..<(range.lowerBound + separatorLength))
            if let event = processFrame(frameData) {
                events.append(event)
            }
        }

        return events
    }

    /// 流结束时调用：把缓冲区里剩余的不完整帧也处理掉。
    ///
    /// 有些服务端（尤其 Anthropic）不发最后一个空行就关连接，
    /// 因此收尾时必须再冲一次，否则会丢掉最后一段增量。
    mutating func finish() -> [SSEEvent] {
        var events: [SSEEvent] = []
        if !buffer.isEmpty {
            if let event = processFrame(buffer) {
                events.append(event)
            }
            buffer.removeAll()
        }
        return events
    }

    // MARK: - 内部

    /// 找到事件分隔符。返回分隔符在全缓冲区中的范围与长度。
    private static func findEventBoundary(in data: Data) -> (Range<Data.Index>, Int)? {
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            // \r\n\r\n
            if bytes[index] == 0x0D, index + 3 < bytes.count,
               bytes[index + 1] == 0x0A, bytes[index + 2] == 0x0D, bytes[index + 3] == 0x0A {
                let start = data.startIndex + index
                return (start..<start, 4)
            }
            // \r\r
            if bytes[index] == 0x0D, index + 1 < bytes.count, bytes[index + 1] == 0x0D {
                let start = data.startIndex + index
                return (start..<start, 2)
            }
            // \n\n
            if bytes[index] == 0x0A, index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                let start = data.startIndex + index
                return (start..<start, 2)
            }
            index += 1
        }
        return nil
    }

    /// 解析一个事件帧（不含结尾的空行）。
    private mutating func processFrame(_ frame: Data) -> SSEEvent? {
        guard let text = String(data: frame, encoding: .utf8) else {
            // 非 UTF-8 的残留数据直接丢弃，避免污染后续帧。
            reset()
            return nil
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // 只裁掉一个结尾 \r，不做 trim（正文里的空白有意义）。
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }

            if line.isEmpty { continue }

            // 注释行（以 ':' 开头）按规范忽略。
            if line.hasPrefix(":") { continue }

            let (field, value) = Self.splitField(line)
            switch field {
            case "event":
                eventName = value
            case "data":
                dataLines.append(value)
            default:
                // id / retry 等字段当前不需要。
                break
            }
        }

        defer { reset() }

        // 空 data 丢弃。
        guard !dataLines.isEmpty else { return nil }
        let joined = dataLines.joined(separator: "\n")
        guard !joined.isEmpty else { return nil }
        return SSEEvent(name: eventName, data: joined)
    }

    /// 把 `field: value` 拆开，并按规范去掉值前的一个空格。
    private static func splitField(_ line: String) -> (String, String) {
        guard let colon = line.firstIndex(of: ":") else {
            return (line, "")
        }
        let field = String(line[line.startIndex..<colon])
        var value = String(line[line.index(after: colon)...])
        if value.hasPrefix(" ") { value.removeFirst() }
        return (field, value)
    }

    private mutating func reset() {
        dataLines.removeAll()
        eventName = nil
    }
}
