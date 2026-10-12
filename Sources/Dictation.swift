import AppKit
import AVFoundation

/// 語音輸入：按住右 Option 說話，放開轉成文字貼到目前的視窗。
/// 偵測按鍵和送出 ⌘V 都要輔助使用權限
@MainActor
final class Dictation {
    static let shared = Dictation()

    private let panel = PromptPanel()
    private var monitors: [Any] = []
    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var started = Date()
    /// 按著右 Option 的時候又按了別的鍵＝在用快捷鍵，不是要說話
    private var cancelled = false
    private static let rightOption: UInt16 = 61

    /// 依設定開關按鍵監聽；開的時候還沒有權限就跳系統的授權詢問
    func update() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        guard Settings.dictation else { return }
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        let handle = { [weak self] (e: NSEvent) -> Void in MainActor.assumeIsolated { self?.handle(e) } }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: handle) as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { handle($0); return $0 } as Any)
    }

    private func handle(_ e: NSEvent) {
        if e.type == .keyDown || (e.type == .flagsChanged && e.keyCode != Self.rightOption) {
            if engine != nil { cancelled = true }
            return
        }
        if e.modifierFlags.contains(.option) { start() } else { finish() }
    }

    private func start() {
        guard engine == nil else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-\(UUID().uuidString).caf")
        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in try? file.write(from: buffer) }
            try engine.start()
            self.engine = engine
            self.file = file
        } catch {
            panel.show(symbol: "exclamationmark.triangle.fill", title: L("無法使用麥克風", "Couldn't use the microphone"), subtitle: "\(error)", buttons: [], hideAfter: 3)
            return
        }
        started = Date()
        cancelled = false
        panel.show(symbol: "mic.fill", title: L("錄音中", "Listening"), subtitle: L("放開右 Option 就貼上", "Release Right Option to paste"), buttons: [])
    }

    private func finish() {
        guard let engine, let url = file?.url else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        file = nil
        // 太短的多半是誤按
        guard !cancelled, Date().timeIntervalSince(started) > 0.4 else {
            try? FileManager.default.removeItem(at: url)
            return panel.dismiss()
        }
        panel.show(symbol: "waveform", title: L("轉文字中…", "Transcribing…"), subtitle: "", buttons: [])
        DispatchQueue.global().async {
            let result = Result { try Transcriber.dictate(url) }
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async {
                switch result {
                case .success(let text) where !text.isEmpty:
                    self.panel.dismiss()
                    Self.paste(text)
                case .success:
                    self.panel.show(symbol: "mic.slash.fill", title: L("沒聽到聲音", "Didn't hear anything"), subtitle: "", buttons: [], hideAfter: 2)
                case .failure(let error):
                    self.panel.show(symbol: "exclamationmark.triangle.fill", title: L("語音輸入失敗", "Dictation failed"), subtitle: "\(error)", buttons: [], hideAfter: 4)
                }
            }
        }
    }

    /// 放進剪貼簿、送 ⌘V，過一下再把原本剪貼簿的內容放回去
    private static func paste(_ text: String) {
        let pb = NSPasteboard.general
        let saved = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            pb.clearContents()
            pb.writeObjects(saved)
        }
    }
}
