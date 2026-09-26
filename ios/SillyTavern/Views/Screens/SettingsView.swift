import SwiftUI
import UniformTypeIdentifiers

/// 设置页：用户人设、供应商与 API Key、采样参数、数据文件。
struct SettingsView: View {
    @EnvironmentObject private var store: AppStore

    @State private var apiKey = ""
    @State private var keySaved = false
    @State private var isImportingWorldInfo = false
    @State private var message: String?

    private var provider: ProviderConfig? {
        store.settings.providers.first { $0.id == store.settings.activeProviderId }
    }

    /// 设置字段的简写绑定（写入即落盘）。
    private func bind<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        store.settingsBinding(keyPath)
    }

    var body: some View {
        Form {
            userSection
            providerSection
            samplingSection
            behaviorSection
            dataSection
            aboutSection
        }
        .navigationTitle("设置")
        .task(id: store.settings.activeProviderId) {
            // 切换供应商时重新读取对应的 Key。
            apiKey = APIKeyStore.key(for: store.settings.activeProviderId)
            keySaved = false
        }
        .fileImporter(
            isPresented: $isImportingWorldInfo,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleWorldInfoImport(result)
        }
        .alert("提示", isPresented: messageBinding) {
            Button("好", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    // MARK: - 用户

    private var userSection: some View {
        Section {
            TextField("你的名字", text: bind(\.userName))
            TextField("人设描述（注入为 {{persona}}）", text: bind(\.userPersona), axis: .vertical)
                .lineLimit(2...8)
        } header: {
            Text("用户")
        } footer: {
            Text("这里填的名字会替换 Prompt 里的 {{user}}；人设描述会作为你的角色设定发给模型。")
        }
    }

    // MARK: - 供应商

    private var providerSection: some View {
        Section {
            Picker("供应商", selection: bind(\.activeProviderId)) {
                ForEach(store.settings.providers) { item in
                    Text(item.name).tag(item.id)
                }
            }

            if let provider {
                if provider.requiresApiKey {
                    HStack {
                        SecureField("API Key", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button(keySaved ? "已保存" : "保存") {
                            APIKeyStore.setKey(apiKey, for: provider.id)
                            keySaved = true
                        }
                        .buttonStyle(.bordered)
                        .disabled(apiKey.isEmpty)
                    }
                }

                LabeledContent("接口地址") {
                    TextField(
                        "https://…",
                        text: store.providerBinding(providerId: provider.id, \.baseURL)
                    )
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(.secondary)
                }

                TextField("模型名", text: bind(\.activeModel))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                if !provider.suggestedModels.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(provider.suggestedModels, id: \.self) { model in
                                Button(model) {
                                    store.settings.activeModel = model
                                    store.saveSettings()
                                }
                                .font(.caption)
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("模型")
        } footer: {
            Text("API Key 保存在 iOS 钥匙串，不会写进聊天记录或导出的文件。接口地址按「基地址 + /chat/completions」拼接，因此通常以 /v1 结尾。")
        }
    }

    // MARK: - 采样参数

    private var samplingSection: some View {
        Section {
            Toggle("流式输出", isOn: bind(\.streamingEnabled))

            Stepper(
                "最大回复长度：\(store.settings.maxTokens) token",
                value: bind(\.maxTokens),
                in: 64...32768,
                step: 64
            )

            Stepper(
                "上下文长度：\(store.settings.contextSize) token",
                value: bind(\.contextSize),
                in: 1024...200000,
                step: 1024
            )

            sliderRow(title: "温度", value: bind(\.temperature), range: 0...2, step: 0.05)
            sliderRow(title: "Top P", value: bind(\.topP), range: 0...1, step: 0.01)
            sliderRow(title: "频率惩罚", value: bind(\.frequencyPenalty), range: -2...2, step: 0.05)
            sliderRow(title: "存在惩罚", value: bind(\.presencePenalty), range: -2...2, step: 0.05)
        } header: {
            Text("生成参数")
        } footer: {
            Text("上下文长度决定发送多少历史消息；装不下时会从最旧的消息开始丢弃。")
        }
    }

    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }

    // MARK: - 行为

    private var behaviorSection: some View {
        Section("对话行为") {
            Toggle("显示消息时间", isOn: bind(\.showTimestamps))
            Toggle("自动加载上次会话", isOn: bind(\.autoLoadLastChat))
        }
    }

    // MARK: - 数据

    private var dataSection: some View {
        Section {
            LabeledContent("角色卡", value: "\(store.characters.count) 个")
            LabeledContent("会话", value: "\(store.sessions.count) 个")
            LabeledContent("世界书", value: "\(store.worldInfos.count) 本")

            Button {
                isImportingWorldInfo = true
            } label: {
                Label("导入世界书（JSON）", systemImage: "book.closed")
            }

            ForEach(store.worldInfos.keys.sorted(), id: \.self) { name in
                LabeledContent(name, value: "\(store.worldInfos[name]?.entries.count ?? 0) 条")
            }
        } header: {
            Text("数据")
        } footer: {
            Text("数据保存在 App 的 Documents 目录，格式与 SillyTavern 一致：角色卡为 PNG、聊天记录为 JSONL、世界书为 JSON，可以直接互相拷贝。")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("版本", value: "1.0")
            LabeledContent("运行方式", value: "完全离线")
        } header: {
            Text("关于")
        } footer: {
            Text("本 App 不连接任何 SillyTavern 服务器：角色卡解析、世界书触发与 Prompt 组装都在设备本地完成，只把最终请求发给你选择的模型供应商。")
        }
    }

    // MARK: - 动作

    private func handleWorldInfoImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            switch store.importWorldInfo(from: url) {
            case .success(let name):
                message = "已导入世界书「\(name)」。"
            case .failure(let error):
                message = error.localizedDescription
            }
        case .failure(let error):
            message = error.localizedDescription
        }
    }

    private var messageBinding: Binding<Bool> {
        Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )
    }
}

#Preview {
    NavigationStack { SettingsView() }.environmentObject(AppStore())
}
