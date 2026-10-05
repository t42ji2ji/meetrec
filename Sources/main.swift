import AppKit
import AVFoundation
import ServiceManagement

/// 畫面中央的半透明提示面板（深色膠囊），不搶焦點
final class PromptPanel: NSPanel {
    private let effect = NSVisualEffectView()
    private var autoHide: DispatchWorkItem?
    private let radius: CGFloat = 22

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        appearance = NSAppearance(named: .vibrantDark)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        // 用 maskImage 裁圓角，視窗陰影才會跟著圓角走
        let r = radius
        let mask = NSImage(size: NSSize(width: r * 2 + 1, height: r * 2 + 1), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        mask.resizingMode = .stretch
        effect.maskImage = mask
        contentView = effect
    }

    func show(symbol: String, title: String, subtitle: String, buttons: [(String, Bool, () -> Void)], hideAfter: Double? = nil) {
        effect.subviews.forEach { $0.removeFromSuperview() }

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 28, weight: .regular)
        icon.contentTintColor = .systemRed
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .white
        let subLabel = NSTextField(labelWithString: subtitle)
        subLabel.font = .systemFont(ofSize: 12)
        subLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        subLabel.lineBreakMode = .byTruncatingMiddle
        let text = NSStackView(views: [titleLabel, subLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let pills = buttons.map { (label, primary, action) in
            PillButton(title: label, primary: primary) { [weak self] in self?.dismiss(); action() }
        }
        let row = NSStackView(views: pills)
        row.spacing = 8

        let stack = NSStackView(views: [icon, text, row])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.setCustomSpacing(28, after: text)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        let size = stack.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        let f = screen.visibleFrame
        setFrame(NSRect(x: (f.midX - size.width / 2).rounded(), y: (f.maxY - f.height * 0.16 - size.height).rounded(),
                        width: size.width, height: size.height), display: true)
        invalidateShadow()

        autoHide?.cancel()
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; animator().alphaValue = 1 }
        if let hideAfter {
            let w = DispatchWorkItem { [weak self] in self?.dismiss() }
            autoHide = w
            DispatchQueue.main.asyncAfter(deadline: .now() + hideAfter, execute: w)
        }
    }

    func dismiss() {
        autoHide?.cancel()
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; animator().alphaValue = 0 }) { [weak self] in self?.orderOut(nil) }
    }
}

/// 膠囊按鈕：主要＝紅底，次要＝半透明白底；hover 變亮、按下變暗
final class PillButton: NSView {
    private let label = NSTextField(labelWithString: "")
    private let primary: Bool
    private let handler: () -> Void
    private var hovering = false { didSet { updateColor() } }
    private var pressing = false { didSet { updateColor() } }

    init(title: String, primary: Bool, action: @escaping () -> Void) {
        self.primary = primary
        handler = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 15
        label.stringValue = title
        label.font = .systemFont(ofSize: 13, weight: primary ? .semibold : .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        updateColor()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateColor() {
        let base: NSColor = primary ? .systemRed : NSColor.white.withAlphaComponent(0.14)
        let c = pressing ? base.shadow(withLevel: 0.2)! : hovering ? base.highlight(withLevel: primary ? 0.15 : 0.12)! : base
        layer?.backgroundColor = c.cgColor
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false; pressing = false }
    override func mouseDown(with event: NSEvent) { pressing = true }
    override func mouseUp(with event: NSEvent) {
        pressing = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { handler() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let detector = Detector()
    private let panel = PromptPanel()
    private var statusItem: NSStatusItem!
    private var recorder: Recorder?
    private var recordingStart = Date()
    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0
    private var clock: Timer?
    private var transcribing = 0
    private let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/會議錄音")

    func applicationDidFinishLaunching(_ note: Notification) {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        if !UserDefaults.standard.bool(forKey: "didSetupLogin") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "didSetupLogin")
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatus()
        detector.onChange = { [weak self] b in self?.browserChanged(b) }
        detector.start()
    }

    private func browserChanged(_ b: Browser?) {
        if recorder == nil {
            if let b {
                panel.show(symbol: "waveform.circle.fill", title: "要錄下這場會議嗎？", subtitle: "\(b.name) 正在使用麥克風",
                           buttons: [("不用", false, {}), ("錄音", true, { [weak self] in self?.start(b) })])
            } else {
                panel.dismiss()
            }
        } else if b == nil {
            panel.show(symbol: "stop.circle.fill", title: "會議好像結束了", subtitle: "瀏覽器已停止使用麥克風",
                       buttons: [("繼續錄", false, {}), ("停止並存檔", true, { [weak self] in self?.stop() })])
        } else {
            panel.dismiss()
        }
        updateStatus()
    }

    private func start(_ b: Browser) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH-mm"
        let url = folder.appendingPathComponent("\(df.string(from: Date())) \(b.name).m4a")
        do {
            let r = try Recorder(browser: b, url: url)
            try r.start()
            recorder = r
            recordingStart = Date()
            pausedAt = nil
            pausedTotal = 0
            clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateStatus() }
        } catch {
            panel.show(symbol: "exclamationmark.triangle.fill", title: "無法開始錄音", subtitle: "\(error)", buttons: [("好", true, {})])
        }
        updateStatus()
    }

    private func stop() {
        guard let r = recorder else { return }
        r.stop()
        recorder = nil
        clock?.invalidate()
        updateStatus()
        panel.show(symbol: "checkmark.circle.fill", title: "已存檔", subtitle: r.url.lastPathComponent,
                   buttons: [("在 Finder 顯示", false, { NSWorkspace.shared.activateFileViewerSelecting([r.url]) })], hideAfter: 4)
        transcribe(r.url)
    }

    private func transcribe(_ audio: URL) {
        transcribing += 1
        updateStatus()
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try Transcriber.transcribe(audio) }
            DispatchQueue.main.async {
                self.transcribing -= 1
                self.updateStatus()
                switch result {
                case .success(let txt):
                    self.panel.show(symbol: "text.bubble.fill", title: "逐字稿好了", subtitle: txt.lastPathComponent,
                                    buttons: [("打開", true, { NSWorkspace.shared.open(txt) })], hideAfter: 8)
                case .failure(let error):
                    self.panel.show(symbol: "exclamationmark.triangle.fill", title: "逐字稿失敗", subtitle: "\(error)", buttons: [("好", true, {})])
                }
            }
        }
    }

    private func togglePause() {
        if let p = pausedAt {
            pausedTotal += Date().timeIntervalSince(p)
            pausedAt = nil
        } else {
            pausedAt = Date()
        }
        recorder?.setPaused(pausedAt != nil)
        updateStatus()
    }

    private func updateStatus() {
        guard let button = statusItem.button else { return }
        if recorder != nil {
            let now = Date()
            let s = Int(now.timeIntervalSince(recordingStart) - pausedTotal - (pausedAt.map { now.timeIntervalSince($0) } ?? 0))
            button.image = nil
            button.attributedTitle = NSAttributedString(string: String(format: "%@ %02d:%02d", pausedAt == nil ? "●" : "❚❚", s / 60, s % 60), attributes: [
                .foregroundColor: pausedAt == nil ? NSColor.systemRed : NSColor.secondaryLabelColor,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            ])
        } else {
            button.title = ""
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "MeetRec")
        }

        let menu = NSMenu()
        if recorder != nil {
            menu.addItem(MenuItem(pausedAt == nil ? "暫停" : "繼續錄音") { [weak self] in self?.togglePause() })
            menu.addItem(MenuItem("停止並存檔") { [weak self] in self?.stop() })
        } else if let b = detector.current {
            menu.addItem(MenuItem("錄音（\(b.name)）") { [weak self] in self?.start(b) })
        } else {
            let item = NSMenuItem(title: "沒有偵測到會議", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if transcribing > 0 {
            let item = NSMenuItem(title: "正在轉逐字稿…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let login = MenuItem("登入時自動啟動") { [weak self] in
            let svc = SMAppService.mainApp
            if svc.status == .enabled { try? svc.unregister() } else { try? svc.register() }
            self?.updateStatus()
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(MenuItem("打開錄音資料夾") { [weak self] in
            guard let self else { return }
            try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(self.folder)
        })
        menu.addItem(MenuItem("結束 MeetRec") { [weak self] in self?.stop(); NSApp.terminate(nil) })
        statusItem.menu = menu
    }
}

final class MenuItem: NSMenuItem {
    private var handler: () -> Void = {}
    convenience init(_ title: String, _ action: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        handler = action
    }
    @objc private func fire() { handler() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
