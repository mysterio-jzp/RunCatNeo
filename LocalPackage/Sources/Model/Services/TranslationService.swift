import AppKit
import Foundation
import SwiftUI

public struct TranslationResult: Sendable {
    public let text: String
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

public final class TranslationService {
    public static let shared = TranslationService()
    private var monitors: [Any] = []
    private var panel: NSPanel?

    private init() {}

    public func start() {
        guard monitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard event.type == .keyDown, event.keyCode == 15,
                  event.modifierFlags.contains(.option) else { return }
            self?.showPanel()
        }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) as Any)
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            handler(event)
            return event
        }) { monitors.append(local) }
    }

    public func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        panel?.close()
        panel = nil
    }

    public func translate(_ text: String, target: String) async -> Result<TranslationResult, TranslationError> {
        let settings = await MainActor.run { TranslationSettings() }
        guard !settings.apiKey.isEmpty else { return .failure(.missingAPIKey) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.emptySelection) }

        let body: [String: Any] = [
            "model": settings.model,
            "temperature": 0.3,
            "messages": [
                ["role": "system", "content": "你是专业翻译助手，只返回翻译结果，不要解释。"],
                ["role": "user", "content": "将以下文本翻译成\(target)，保持格式和语气：\n\(text)"]
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
            return .success(TranslationResult(text: content.trimmingCharacters(in: .whitespacesAndNewlines)))
        } catch { return .failure(.request("网络错误：\(error.localizedDescription)")) }
    }

    private func showPanel() {
        panel?.close()
        let popup = TranslationPanelView(service: self)
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 280), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        window.isFloatingPanel = true
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.contentView = NSHostingView(rootView: popup)
        let mouse = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: mouse.x - 180, y: mouse.y + 12))
        window.makeKeyAndOrderFront(nil)
        panel = window
    }

    fileprivate func selectedText() -> String? {
        if AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) {
            let system = AXUIElementCreateSystemWide()
            var focused: AnyObject?
            if AXUIElementCopyAttributeValue(system, kAXFocusedAttribute as CFString, &focused) == .success,
               let element = focused {
                var value: AnyObject?
                if AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success,
                   let text = value as? String, !text.isEmpty {
                    return text
                }
            }
        }
        return selectedTextViaClipboard()
    }

    private func selectedTextViaClipboard() -> String? {
        let pasteboard = NSPasteboard.general
        let oldItems = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        pasteboard.clearContents()
        let source = CGEventSource(stateID: .combinedSessionState)
        let commandDown = CGEvent(keyboardEventSource: source, virtualKey: 0x38, keyDown: true)
        let cDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
        let cUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        let commandUp = CGEvent(keyboardEventSource: source, virtualKey: 0x38, keyDown: false)
        [commandDown, cDown, cUp, commandUp].forEach { event in
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.1)
        let text = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        let restored = oldItems.map { item in
            let pasteboardItem = NSPasteboardItem()
            item.forEach { pasteboardItem.setData($0.1, forType: $0.0) }
            return pasteboardItem
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
        return text
    }
}

private struct TranslationPanelView: View {
    let service: TranslationService
    @State private var source = "读取选中文本..."
    @State private var result = ""
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("划词翻译").font(.headline)
            Text(source).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            if loading { ProgressView() } else { Text(result).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .padding(18)
        .frame(width: 360, height: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .task {
            source = service.selectedText() ?? "没有检测到选中文本"
            guard source != "没有检测到选中文本" else { loading = false; return }
            let translation = await service.translate(source, target: TranslationSettings().targetLanguage)
            switch translation { case .success(let value): result = value.text; case .failure(let error): result = error.localizedDescription }
            loading = false
        }
    }
}
