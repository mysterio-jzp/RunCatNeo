import AppKit
import Carbon.HIToolbox
import CryptoKit
import Foundation
import OSLog
import SwiftUI

public struct TranslationResult: Sendable {
    public let text: String
    public let sourceLanguage: String
}

public struct SupplementalTranslationResult: Sendable {
    public let provider: String
    public let text: String
    public let sourceLanguage: String
}

private struct TranslationCacheEntry: Sendable {
    let primary: String?
    let youdao: String?
}

public enum TranslationError: LocalizedError {
    case missingAPIKey
    case emptySelection
    case request(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "请先在翻译设置中填写 API Key"
        case .emptySelection: return "没有检测到选中文本"
        case .request(let message): return message
        }
    }
}

@MainActor
public final class TranslationService {
    public static let shared = TranslationService()
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var panel: NSPanel?
    private var dismissMonitors: [Any] = []
    private var panelState: TranslationPanelState?
    private var translationCache: [String: TranslationCacheEntry] = [:]
    private let logger = Logger(subsystem: "com.kyome.Neo.RunCat", category: "Translation")

    private init() {}

    public func start() {
        guard hotKeyRef == nil else { return }
        var hotKeyID = EventHotKeyID(signature: OSType(0x52434154), id: 1)
        let target = GetEventDispatcherTarget()
        let eventSpec = EventTypeSpec(eventClass: UInt32(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let service = Unmanaged<TranslationService>.fromOpaque(userData).takeUnretainedValue()
            let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let accessibilityText = TranslationService.captureAccessibilityText()
            Task.detached {
                let selectedText: String?
                if accessibilityText == "" {
                    selectedText = nil
                } else {
                    selectedText = accessibilityText ?? TranslationService.captureSelectedTextViaClipboard(for: frontmostBundleID)
                }
                await MainActor.run {
                    service.showPanel(with: selectedText)
                }
            }
            return noErr
        }
        InstallEventHandler(target, callback, 1, [eventSpec], Unmanaged.passUnretained(self).toOpaque(), &eventHandlerRef)
        RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(optionKey), hotKeyID, target, 0, &hotKeyRef)
    }

    public func stop() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
        self.hotKeyRef = nil
        self.eventHandlerRef = nil
        panel?.close()
        panel = nil
    }

    public func translate(_ text: String, target: String) async -> Result<TranslationResult, TranslationError> {
        let settings = await MainActor.run { TranslationSettings() }
        guard !settings.apiKey.isEmpty else { return .failure(.missingAPIKey) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.emptySelection) }
        let cacheKey = "aliyun|\(target)|\(text)"
        if let cached = translationCache[cacheKey]?.primary {
            return .success(TranslationResult(text: cached, sourceLanguage: "自动识别"))
        }

        let resolvedTarget = Self.resolvedTargetLanguage(for: text, requested: target)
        let body: [String: Any] = [
            "model": settings.model,
            "temperature": 0.3,
            "messages": [
                ["role": "system", "content": "你是专业翻译助手，只返回翻译结果，不要解释。"],
                ["role": "user", "content": "将以下文本翻译成\(resolvedTarget)，保持格式和语气：\n\(text)"]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let url = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions") else {
            return .failure(.request("请求配置失败"))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { return .failure(.request("翻译服务返回错误")) }
            let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
            let choices = json?["choices"] as? [[String: Any]]
            let message = choices?.first?["message"] as? [String: Any]
            let content = message?["content"] as? String
            guard let content, !content.isEmpty else { return .failure(.request("翻译结果为空")) }
            let translated = content.trimmingCharacters(in: .whitespacesAndNewlines)
            translationCache[cacheKey] = TranslationCacheEntry(primary: translated, youdao: translationCache[cacheKey]?.youdao)
            return .success(TranslationResult(text: translated, sourceLanguage: "自动识别"))
        } catch { return .failure(.request("网络错误：\(error.localizedDescription)")) }
    }

    public func translateWithYoudao(_ text: String, target: String) async -> Result<SupplementalTranslationResult, TranslationError> {
        let settings = await MainActor.run { TranslationSettings() }
        guard !settings.youdaoAppKey.isEmpty, !settings.youdaoAppSecret.isEmpty else {
            return .failure(.request("未配置有道 App Key / App Secret"))
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptySelection) }
        let cacheKey = "youdao|\(target)|\(trimmed)"
        if let cached = translationCache[cacheKey]?.youdao {
            return .success(SupplementalTranslationResult(provider: "有道", text: cached, sourceLanguage: "自动识别"))
        }
        let resolvedTarget = Self.resolvedTargetLanguage(for: trimmed, requested: target)
        let salt = UUID().uuidString
        let currentTime = String(Int(Date().timeIntervalSince1970))
        let input = trimmed.count <= 20 ? trimmed : "\(trimmed.prefix(10))\(trimmed.count)\(trimmed.suffix(10))"
        let signSource = settings.youdaoAppKey + input + salt + currentTime + settings.youdaoAppSecret
        let sign = SHA256.hash(data: Data(signSource.utf8)).map { String(format: "%02x", $0) }.joined()
        guard let url = URL(string: "https://openapi.youdao.com/api") else { return .failure(.request("有道请求配置失败")) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let parameters = [
            ("q", trimmed), ("from", "auto"), ("to", resolvedTarget == "中文" ? "zh-CHS" : "en"),
            ("appKey", settings.youdaoAppKey), ("salt", salt), ("sign", sign),
            ("signType", "v3"), ("curtime", currentTime)
        ]
        request.httpBody = parameters.map { "\($0.0.urlEncoded)=\($0.1.urlEncoded)" }.joined(separator: "&").data(using: .utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { return .failure(.request("有道服务返回错误")) }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let translation = (json?["translation"] as? [String])?.joined(separator: "\n"), !translation.isEmpty else {
                let code = json?["errorCode"] as? String ?? "未知错误"
                let message = json?["errorCode"] as? String ?? "未知错误"
                return .failure(.request("有道翻译失败：\(code)（\(message)）"))
            }
            let detectedLanguage = (json?["l"] as? String)?.components(separatedBy: "2").first ?? "自动识别"
            translationCache[cacheKey] = TranslationCacheEntry(primary: translationCache[cacheKey]?.primary, youdao: translation)
            return .success(SupplementalTranslationResult(provider: "有道", text: translation, sourceLanguage: detectedLanguage))
        } catch { return .failure(.request("有道网络错误：\(error.localizedDescription)")) }
    }

    private static func resolvedTargetLanguage(for text: String, requested: String) -> String {
        guard requested == "自动选择" else { return requested }
        let chineseCount = text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        return chineseCount > 0 ? "English" : "中文"
    }

    private func showPanel(with selectedText: String?) {
        panel?.close()
        let source = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let state = TranslationPanelState(source: source?.isEmpty == false ? source! : "未检测到选中文本")
        panelState = state
        let popup = TranslationPanelView(service: self, state: state)
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 390), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        window.isFloatingPanel = true
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.contentView = NSHostingView(rootView: popup)
        let mouse = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: mouse.x - 190, y: mouse.y + 12))
        window.makeKeyAndOrderFront(nil)
        panel = window
        installDismissMonitors(for: window)
    }

    private func installDismissMonitors(for window: NSPanel) {
        dismissMonitors.forEach { NSEvent.removeMonitor($0) }
        dismissMonitors.removeAll()
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self, weak window] event in
            if event.type == .keyDown, event.keyCode == 53 {
                self?.closePanel()
                return nil
            }
            if let window, !window.frame.contains(NSEvent.mouseLocation) {
                self?.closePanel()
            }
            return event
        } {
            dismissMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak window] _ in
            guard let window, !window.frame.contains(NSEvent.mouseLocation) else { return }
            self?.closePanel()
        } {
            dismissMonitors.append(global)
        }
    }

    private func closePanel() {
        dismissMonitors.forEach { NSEvent.removeMonitor($0) }
        dismissMonitors.removeAll()
        panel?.close()
        panel = nil
    }

    nonisolated private static func captureAccessibilityText() -> String? {
        if AXIsProcessTrusted() {
            let system = AXUIElementCreateSystemWide()
            var focused: AnyObject?
            if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
               let element = focused {
                let focusedElement = element as! AXUIElement
                var value: AnyObject?
                if AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, &value) == .success,
                   let text = value as? String, !text.isEmpty {
                    return text
                }
                var selectedRangeValue: AnyObject?
                if AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextRangeAttribute as CFString, &selectedRangeValue) == .success,
                   let selectedRangeValue,
                   AXValueGetType(selectedRangeValue as! AXValue) == .cfRange {
                    var range = CFRange()
                    if AXValueGetValue(selectedRangeValue as! AXValue, .cfRange, &range), range.length == 0 {
                        return ""
                    }
                }
                if let text = selectedTextFromValueAndRange(of: focusedElement) {
                    return text
                }
            }
        }
        return nil
    }

    nonisolated private static func selectedTextFromValueAndRange(of element: AXUIElement) -> String? {
        var value: AnyObject?
        var rangeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let fullText = value as? String,
              let rangeObject = rangeValue else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeObject as! AXValue, .cfRange, &range), range.length > 0,
              range.location >= 0, range.location + range.length <= (fullText as NSString).length else { return nil }
        return (fullText as NSString).substring(with: NSRange(location: range.location, length: range.length))
    }

    nonisolated private static func captureSelectedTextViaClipboard(for bundleID: String?) -> String? {
        let pasteboard = NSPasteboard.general
        let oldItems = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        let originalChangeCount = pasteboard.changeCount
        defer {
            pasteboard.clearContents()
            let restored = oldItems.map { item in
                let pasteboardItem = NSPasteboardItem()
                item.forEach { pasteboardItem.setData($0.1, forType: $0.0) }
                return pasteboardItem
            }
            if !restored.isEmpty { pasteboard.writeObjects(restored) }
        }

        let source = CGEventSource(stateID: .hidSystemState)
        let commandDown = CGEvent(keyboardEventSource: source, virtualKey: 0x38, keyDown: true)
        let cDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
        let cUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        let commandUp = CGEvent(keyboardEventSource: source, virtualKey: 0x38, keyDown: false)
        commandDown?.flags = .maskCommand
        cDown?.flags = .maskCommand
        cUp?.flags = .maskCommand
        commandDown?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.02)
        cDown?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.02)
        cUp?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.02)
        commandUp?.post(tap: .cghidEventTap)

        for _ in 0..<12 where pasteboard.changeCount == originalChangeCount {
            Thread.sleep(forTimeInterval: 0.05)
        }
        let text = pasteboard.string(forType: .string)
        guard pasteboard.changeCount != originalChangeCount else { return nil }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

private struct TranslationPanelView: View {
    let service: TranslationService
    @ObservedObject var state: TranslationPanelState
    @State private var result = ""
    @State private var youdaoResult = "正在请求..."
    @State private var loading = true
    @State private var targetLanguage = "自动选择"
    @State private var copiedSection: String?
    @State private var speechSynthesizer = NSSpeechSynthesizer()

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("划词翻译", systemImage: "character.bubble")
                    .font(.headline)
                Spacer()
                Text("Option + R")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Label("自动检测", systemImage: "arrow.down")
                Spacer()
                Image(systemName: "arrow.left.arrow.right")
                Spacer()
                Picker("目标语言", selection: $targetLanguage) {
                    Text("自动选择").tag("自动选择")
                    Text("中文").tag("中文")
                    Text("English").tag("English")
                }
                .labelsHidden()
            }
            .font(.caption)
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
            resultSection(title: "原文", text: state.source, section: "source", showActions: state.source != "正在读取选中文本...")
            resultSection(title: "阿里云 · 大模型翻译", subtitle: TranslationSettings().model, text: loading ? "正在翻译..." : result, section: "aliyun", showActions: !loading && !result.isEmpty)
            resultSection(title: "有道 · 文本翻译 · 自动识别", text: youdaoResult, section: "youdao", showActions: !youdaoResult.isEmpty && youdaoResult != "正在请求...")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 380, height: 390, alignment: .top)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.18)))
        .task {
            await translateCurrentSource()
        }
        .onChange(of: state.source) { _, _ in
            Task { await translateCurrentSource() }
        }
        .onChange(of: targetLanguage) { _, _ in
            Task { await translateCurrentSource() }
        }
    }

    private func translateCurrentSource() async {
        guard state.source != "正在读取选中文本...", state.source != "未检测到选中文本" else {
            loading = false
            result = ""
            youdaoResult = ""
            return
        }
        result = "正在翻译..."
        youdaoResult = "正在请求..."
        loading = true
        async let primary = service.translate(state.source, target: targetLanguage)
        async let youdao = service.translateWithYoudao(state.source, target: targetLanguage)
        let translation = await primary
        switch translation { case .success(let value): result = value.text; case .failure(let error): result = error.localizedDescription }
        switch await youdao {
        case .success(let value): youdaoResult = value.text
        case .failure(let error): youdaoResult = error.localizedDescription
        }
        loading = false
    }

    @ViewBuilder
    private func resultSection(title: String, subtitle: String? = nil, text: String, section: String, showActions: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(title).font(.subheadline.weight(.semibold))
                if let subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if showActions {
                    Button { speak(text) } label: {
                        Image(systemName: "speaker.wave.2")
                    }
                    .buttonStyle(.borderless)
                    .help("朗读")
                    Button { copy(text, section: section) } label: {
                        Image(systemName: copiedSection == section ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("复制")
                }
            }
            ZStack(alignment: .topLeading) {
                if text == "正在翻译..." || text == "正在请求..." {
                    ProgressView().controlSize(.small)
                }
                ScrollView {
                    Text(text)
                        .font(.system(size: 14))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .opacity(text == "正在翻译..." || text == "正在请求..." ? 0 : 1)
            }
            .frame(height: 60, alignment: .topLeading)
        }
        .frame(height: 91, alignment: .top)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func copy(_ text: String, section: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedSection = section
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedSection == section { copiedSection = nil }
        }
    }

    private func speak(_ text: String) {
        speechSynthesizer.stopSpeaking()
        speechSynthesizer.startSpeaking(text)
    }
}

private extension String {
    var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}

@MainActor
private final class TranslationPanelState: ObservableObject {
    @Published var source: String

    init(source: String) {
        self.source = source
    }
}
