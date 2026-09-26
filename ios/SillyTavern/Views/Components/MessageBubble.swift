import SwiftUI

/// 一条消息气泡。
///
/// 用 `Equatable` 收敛重绘范围：流式生成时列表会频繁刷新，
/// 如果每条气泡都参与重算，长对话会明显卡顿。
struct MessageBubble: View, Equatable {
    let message: ChatMessage
    let characterName: String
    let showTimestamp: Bool
    /// 是否处于「正在输入」状态（用于显示光标）。
    var isStreaming: Bool = false
    /// 流式过程中覆盖显示的文本。
    var streamingOverride: String?

    static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        lhs.message.id == rhs.message.id
            && lhs.message.mes == rhs.message.mes
            && lhs.isStreaming == rhs.isStreaming
            && lhs.streamingOverride == rhs.streamingOverride
            && lhs.showTimestamp == rhs.showTimestamp
    }

    private var displayText: String {
        streamingOverride ?? message.mes
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.isUser { Spacer(minLength: 40) }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                Text(message.isUser ? "你" : speakerName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(displayText)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(bubbleBackground)
                    .foregroundStyle(message.isUser ? Color.white : Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        if isStreaming {
                            // 生成中：末尾显示一个方块光标，表明还在输出。
                            Text("▍")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(6)
                        }
                    }

                if showTimestamp, let date = ChatMessage.parseTimestamp(message.sendDate) {
                    Text(date, format: .dateTime.hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if !message.isUser { Spacer(minLength: 40) }
        }
    }

    private var speakerName: String {
        message.name.isEmpty ? characterName : message.name
    }

    private var bubbleBackground: some ShapeStyle {
        message.isUser ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.secondarySystemBackground))
    }
}

/// 思维链折叠面板。
///
/// 推理模型的思维链默认折叠，避免刷屏；需要时可以展开查看。
struct ReasoningDisclosure: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Label("思考过程", systemImage: "brain")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
