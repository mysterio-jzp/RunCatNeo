import Foundation
import Security
import Combine

@MainActor
public final class TranslationSettings: ObservableObject {
    @Published public var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "translation.enabled") }
    }
    @Published public var apiKey: String {
        didSet { saveKey(apiKey) }
    }
    @Published public var provider: String {
        didSet { UserDefaults.standard.set(provider, forKey: "translation.provider") }
    }
    @Published public var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "translation.model") }
    }
    @Published public var targetLanguage: String {
        didSet { UserDefaults.standard.set(targetLanguage, forKey: "translation.targetLanguage") }
    }

    public let models = ["deepseek-v3.2", "qwen-mt-flash"]

    public init() {
        isEnabled = UserDefaults.standard.object(forKey: "translation.enabled") as? Bool ?? false
        provider = UserDefaults.standard.string(forKey: "translation.provider") ?? "Aliyun"
        model = UserDefaults.standard.string(forKey: "translation.model") ?? "deepseek-v3.2"
        targetLanguage = UserDefaults.standard.string(forKey: "translation.targetLanguage") ?? "中文"
        apiKey = Self.loadKey()
    }

    private func saveKey(_ value: String) {
        let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: "RunCatNeo.translation", kSecAttrAccount: "apiKey"] as [String: Any]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query
        item[kSecValueData] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func loadKey() -> String {
        let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: "RunCatNeo.translation", kSecAttrAccount: "apiKey", kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as [String: Any]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
