import AppKit
import AVFoundation

/// 語音輸入的按鍵：單一個修飾鍵（右 ⌥、fn…）或一般組合鍵（⌃Space、F5…）
struct Shortcut: Equatable {
    var keyCode: UInt16
    /// 組合鍵要同時按住的修飾鍵；單一修飾鍵是空的
    var modifiers: NSEvent.ModifierFlags = []

    static let standard = Shortcut(keyCode: 61)

    /// 修飾鍵的 keyCode 對到按著時會亮的旗標
    static let modifierKeys: [UInt16: (name: String, flag: NSEvent.ModifierFlags)] = [
        54: ("右 ⌘", .command), 55: ("左 ⌘", .command), 56: ("左 ⇧", .shift), 60: ("右 ⇧", .shift),
        58: ("左 ⌥", .option), 61: ("右 ⌥", .option), 59: ("左 ⌃", .control), 62: ("右 ⌃", .control), 63: ("fn", .function),
    ]
    static let mask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    var isModifier: Bool { Self.modifierKeys[keyCode] != nil }

    var name: String {
        if let m = Self.modifierKeys[keyCode] { return Settings.english ? m.name.replacingOccurrences(of: "右", with: "Right").replacingOccurrences(of: "左", with: "Left") : m.name }
        let symbols = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")].filter { modifiers.contains($0.0) }.map(\.1).joined()
        let fkeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        let special: [UInt16: String] = [49: "Space", 36: "↩", 48: "⇥", 51: "⌫"]
        let key = special[keyCode] ?? fkeys.firstIndex(of: keyCode).map { "F\($0 + 1)" } ?? Self.character(keyCode)
        return symbols + key
    }

    /// 照目前鍵盤配置，這個鍵打出來的字
    private static func character(_ keyCode: UInt16) -> String {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        e?.flags = []
        e?.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// 語音輸入：按住設定的按鍵說話，放開轉成文字貼到目前的視窗。
/// 攔按鍵（組合鍵不能讓它打進目前的 app）和送出 ⌘V 都要輔助使用權限
@MainActor
final class Dictation {
    static let shared = Dictation()

    private let hud = DictationHUD()
    private var tap: CFMachPort?
    private var retry: Timer?
    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var started = Date()
    /// 按著修飾鍵的時候又按了別的鍵＝在用快捷鍵，不是要說話
    private var cancelled = false
    private let meter = LevelMeter()
    /// 設定裡正在錄新的按鍵，先別觸發
    var paused = false

    /// 依設定開關按鍵監聽；開的時候還沒有權限就跳系統的授權詢問，給了權限才接得上
    func update() {
        retry?.invalidate()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); self.tap = nil }
        guard Settings.dictation else { return }
        guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else {
            retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard AXIsProcessTrusted() else { return }
                    self?.update()
                }
            }
            return
        }
        let events = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | 1 << $1.rawValue }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: events, callback: { _, type, event, _ in
            MainActor.assumeIsolated { Dictation.shared.handle(type, event) } ? nil : Unmanaged.passUnretained(event)
        }, userInfo: nil)
        guard let tap else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    }

    /// 回傳 true 表示這個按鍵是語音輸入的，不要傳給目前的 app
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard !paused, let e = NSEvent(cgEvent: event) else { return false }
        let key = Settings.dictationKey
        if key.isModifier {
            if e.type == .flagsChanged, e.keyCode == key.keyCode {
                e.modifierFlags.contains(Shortcut.modifierKeys[key.keyCode]!.flag) ? start() : finish()
            } else if e.type != .keyUp, engine != nil {
                cancelled = true
            }
            return false
        }
        guard e.type != .flagsChanged, e.keyCode == key.keyCode else { return false }
        if e.type == .keyUp {
            guard engine != nil else { return false }
            finish()
            return true
        }
        guard e.modifierFlags.intersection(Shortcut.mask) == key.modifiers else { return false }
        if !e.isARepeat { start() }
        return true
    }

    private func start() {
        guard engine == nil else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-\(UUID().uuidString).caf")
        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let meter = meter
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
                try? file.write(from: buffer)
                guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
                let n = Int(buffer.frameLength)
                let rms = sqrt((0..<n).reduce(Float(0)) { $0 + samples[$1] * samples[$1] } / Float(n))
                // -55 dB 以下當沒聲音，-15 dB 以上滿格
                let level = min(1, max(0, (20 * log10(rms + 1e-9) + 55) / 40))
                DispatchQueue.main.async { MainActor.assumeIsolated { meter.level = CGFloat(level) } }
            }
            try engine.start()
            self.engine = engine
            self.file = file
        } catch {
            hud.show(.message("exclamationmark.triangle.fill", L("無法使用麥克風", "Couldn't use the microphone")))
            return
        }
        started = Date()
        cancelled = false
        meter.level = 0
        hud.show(.listening(meter))
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
            return hud.dismiss()
        }
        hud.show(.working)
        DispatchQueue.global().async {
            let result = Result { try Transcriber.dictate(url) }
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async {
                switch result {
                case .success(let text) where !text.isEmpty:
                    self.hud.dismiss()
                    Self.paste(text)
                case .success:
                    self.hud.show(.message("mic.slash.fill", L("沒聽到聲音", "Didn't hear anything")))
                case .failure(let error):
                    self.hud.show(.message("exclamationmark.triangle.fill", "\(error)"))
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

/// 收音時的小音量條：五根直條跟著麥克風音量高低
final class LevelMeter: NSView {
    var level: CGFloat = 0 {
        // 變大馬上跟、變小慢慢落，才不會一直閃
        didSet { shown = level > shown ? level : shown * 0.7 + level * 0.3; needsDisplay = true }
    }
    private var shown: CGFloat = 0
    private let weights: [CGFloat] = [0.5, 0.8, 1, 0.8, 0.5]

    override var intrinsicContentSize: NSSize { NSSize(width: 23, height: 16) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setFill()
        for (i, w) in weights.enumerated() {
            let h = max(3, bounds.height * w * shown)
            let rect = NSRect(x: CGFloat(i) * 5, y: (bounds.height - h) / 2, width: 3, height: h)
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

/// 語音輸入的小膠囊，在畫面靠下：收音時是麥克風＋音量條，轉文字時轉圈圈，出錯時一行字
final class DictationHUD: NSPanel {
    enum State {
        case listening(LevelMeter)
        case working
        case message(String, String)
    }

    private let effect = NSVisualEffectView()
    private let shadowView = NSView()
    private var autoHide: DispatchWorkItem?
    /// 視窗四周留給陰影的透明邊
    private let pad: CGFloat = 16

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        // 系統陰影在無邊框視窗外會多一圈明顯的細框，陰影自己畫
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ignoresMouseEvents = true
        appearance = NSAppearance(named: .vibrantDark)
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.masksToBounds = true
        shadowView.wantsLayer = true
        shadowView.layer?.shadowColor = NSColor.black.cgColor
        shadowView.layer?.shadowOpacity = 0.3
        shadowView.layer?.shadowRadius = 8
        shadowView.layer?.shadowOffset = CGSize(width: 0, height: -3)
        let container = NSView()
        container.addSubview(shadowView)
        container.addSubview(effect)
        contentView = container
    }

    func show(_ state: State) {
        effect.subviews.forEach { $0.removeFromSuperview() }
        let views: [NSView]
        switch state {
        case .listening(let meter):
            views = [icon("mic.fill", .systemRed), meter]
        case .working:
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            views = [spinner]
        case .message(let symbol, let text):
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .white
            label.lineBreakMode = .byTruncatingTail
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 280).isActive = true
            views = [icon(symbol, .white), label]
        }
        let stack = NSStackView(views: views)
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 18, bottom: 12, right: 18)
        stack.frame.size = stack.fittingSize
        effect.addSubview(stack)
        let size = NSSize(width: max(stack.frame.width, stack.frame.height), height: stack.frame.height)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        let f = screen.visibleFrame
        setFrame(NSRect(x: (f.midX - size.width / 2).rounded() - pad, y: (f.minY + f.height * 0.08).rounded() - pad,
                        width: size.width + pad * 2, height: size.height + pad * 2), display: false)
        let capsule = NSRect(x: pad, y: pad, width: size.width, height: size.height)
        effect.frame = capsule
        shadowView.frame = capsule
        stack.setFrameOrigin(NSPoint(x: (size.width - stack.frame.width) / 2, y: 0))
        effect.layer?.cornerRadius = size.height / 2
        shadowView.layer?.shadowPath = CGPath(roundedRect: shadowView.bounds, cornerWidth: size.height / 2, cornerHeight: size.height / 2, transform: nil)
        autoHide?.cancel()
        alphaValue = 1
        orderFrontRegardless()
        if case .message = state {
            let w = DispatchWorkItem { [weak self] in self?.dismiss() }
            autoHide = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
        }
    }

    func dismiss() {
        autoHide?.cancel()
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; animator().alphaValue = 0 }) { [weak self] in
            // 淡出中又開始下一次就別收起來
            if self?.alphaValue == 0 { self?.orderOut(nil) }
        }
    }

    private func icon(_ symbol: String, _ color: NSColor) -> NSImageView {
        let v = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        v.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        v.contentTintColor = color
        return v
    }
}
