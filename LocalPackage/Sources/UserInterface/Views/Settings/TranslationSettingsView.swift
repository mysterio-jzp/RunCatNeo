import Model
import SwiftUI

struct TranslationSettingsView: View {
    @StateObject private var store = TranslationSettings()

    var body: some View {
        Form {
            Section {
                Toggle("启用划词翻译", isOn: $store.isEnabled)
                Text("按 Option + R，在任意应用中翻译当前选中的文本。首次使用需要在系统设置中授予辅助功能权限。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("划词翻译")
            }
            Section {
                SecureField("API Key", text: $store.apiKey)
                Picker("Provider", selection: $store.provider) {
                    Text("Aliyun").tag("Aliyun")
                }
                Picker("模型", selection: $store.model) {
                    ForEach(store.models, id: \.self) { Text($0).tag($0) }
                }
                Picker("目标语言", selection: $store.targetLanguage) {
                    Text("自动选择").tag("自动选择")
                    Text("中文").tag("中文")
                    Text("English").tag("English")
                }
            } header: {
                Text("翻译服务")
            }
            Section {
                SecureField("App Key", text: $store.youdaoAppKey)
                SecureField("App Secret", text: $store.youdaoAppSecret)
                Text("可选。配置后会在阿里云结果下显示有道翻译结果。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("有道翻译")
            }
        }
        .formStyle(.grouped)
        .task {
            if store.isEnabled { TranslationService.shared.start() }
        }
        .onChange(of: store.isEnabled) { _, enabled in
            if enabled { TranslationService.shared.start() } else { TranslationService.shared.stop() }
        }
    }
}
