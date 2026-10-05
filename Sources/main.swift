import AppKit
import AVFoundation
import ServiceManagement

/// 畫面中央的半透明提示面板（深色膠囊），不搶焦點
/// 陰影自己畫：系統的視窗陰影在無邊框視窗外會多一圈細線。視窗四周留 pad 的透明邊給陰影
final class PromptPanel: NSPanel {
    private let effect = NSVisualEffectView()
    private let shadowView = NSView()
    private let borderView = PassThroughView()
    private var autoHide: DispatchWorkItem?
    private let radius: CGFloat = 22
    private let pad: CGFloat = 32

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
        let r = radius
        let mask = NSImage(size: NSSize(width: r * 2 + 1, height: r * 2 + 1), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        mask.resizingMode = .stretch
        effect.maskImage = mask

        shadowView.wantsLayer = true
        shadowView.layer?.shadowColor = NSColor.black.cgColor
        shadowView.layer?.shadowOpacity = 0.45
        shadowView.layer?.shadowRadius = 16
        shadowView.layer?.shadowOffset = CGSize(width: 0, height: -6)
        // 淺色背景上靠陰影、深色背景上靠這圈亮邊分出輪廓
        borderView.wantsLayer = true
        borderView.layer?.cornerRadius = r
        borderView.layer?.borderWidth = 2
        borderView.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor

        let container = NSView()
        container.addSubview(shadowView)
        container.addSubview(effect)
        container.addSubview(borderView)
        contentView = container
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
        setFrame(NSRect(x: (f.midX - size.width / 2).rounded() - pad, y: (f.maxY - f.height * 0.16 - size.height).rounded() - pad,
                        width: size.width + pad * 2, height: size.height + pad * 2), display: false)
        let capsule = NSRect(x: pad, y: pad, width: size.width, height: size.height)
        for v in [shadowView, effect, borderView] { v.frame = capsule }
        shadowView.layer?.shadowPath = CGPath(roundedRect: shadowView.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        display()

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

/// 不接滑鼠事件的疊加層
final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let detector = Detector()
    private let panel = PromptPanel()
    private var statusItem: NSStatusItem!
    private var recorder: Recorder?
    private var recordingStart = Date()
    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0
    private var clock: Timer?
    private var problem: String?
    /// 這場錄音的瀏覽器、開始時間（檔名用）、抓到的會議標題
    private var meeting: (browser: Browser, date: String, title: String?)?
    private var titleTimer: Timer?
    private let library = Library.shared
    private var folder: URL { library.folder }

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
        library.onTranscribed = { [weak self] url, result in self?.transcribed(url, result) }
        library.toggleLivePause = { [weak self] in self?.togglePause() }
        library.stopLive = { [weak self] in self?.stop() }
        recoverInterrupted()
    }

    /// 結束或關機時把緩衝區寫進 .aac；轉成 m4a 留給下次啟動的 recoverInterrupted
    func applicationWillTerminate(_ note: Notification) {
        recorder?.stop()
    }

    /// 上次沒正常停止（閃退、強制結束、斷電、錄音中結束 app）留下的 .aac：轉成 m4a、轉逐字稿
    private func recoverInterrupted() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        let files = dirs + dirs.flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] }
        // 錄音中的 .aac 一定跟資料夾同名；匯入的 .aac 不算
        let leftovers = files.filter { $0.pathExtension == "aac" && $0.deletingPathExtension().lastPathComponent == $0.deletingLastPathComponent().lastPathComponent }
        guard !leftovers.isEmpty else { return }
        DispatchQueue.global().async {
            let saved = leftovers.map(Recorder.finalize)
            DispatchQueue.main.async {
                self.panel.show(symbol: "checkmark.circle.fill", title: "已補存上次中斷的錄音",
                                subtitle: saved.map { $0.deletingLastPathComponent().lastPathComponent }.joined(separator: "、"),
                                buttons: [("打開", false, { Dashboard.shared.show(select: saved.first) })])
                saved.forEach(self.library.transcribe)
            }
        }
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
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH-mm"
        let date = df.string(from: Date())
        var url: URL?
        do {
            url = try Recorder.newURL(in: folder, name: "\(date) \(b.name)")
            let r = try Recorder(browser: b, url: url!)
            r.onProblem = { [weak self] message in self?.recordingProblem(message) }
            try r.start()
            recorder = r
            library.recordingFile = r.url
            recordingStart = Date()
            pausedAt = nil
            pausedTotal = 0
            clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.updateStatus() } }
            meeting = (b, date, nil)
            // 錄音先開始再讀會議標題：第一次會跳自動化權限詢問，也可能還沒進會議室；讀不到就每 30 秒再試
            lookupTitle()
            titleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.lookupTitle() } }
        } catch {
            // 沒錄成就別留下空資料夾（裡面只有剛建的空 .aac）
            if let url { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            panel.show(symbol: "exclamationmark.triangle.fill", title: "無法開始錄音", subtitle: "\(error)", buttons: [("好", true, {})])
        }
        updateStatus()
    }

    private func lookupTitle() {
        guard let m = meeting, m.title == nil, let title = m.browser.meetingTitle() else { return }
        meeting?.title = title
        titleTimer?.invalidate()
    }

    private func stop() {
        guard let r = recorder else { return }
        lookupTitle()
        let name = meeting.flatMap { m in m.title.map { "\(m.date) \($0)" } }
        meeting = nil
        titleTimer?.invalidate()
        r.stop()
        recorder = nil
        problem = nil
        clock?.invalidate()
        updateStatus()
        let aac = r.url
        DispatchQueue.global().async {
            let finalized = Recorder.finalize(aac)
            DispatchQueue.main.async {
                // 有抓到會議標題就用它命名資料夾（撞名就維持原名）
                let url = name.flatMap { try? self.library.rename(audio: finalized, to: $0) } ?? finalized
                self.library.recordingFile = nil
                self.panel.show(symbol: "checkmark.circle.fill", title: "已存檔", subtitle: url.lastPathComponent,
                                buttons: [("打開", false, { Dashboard.shared.show(select: url) })], hideAfter: 4)
                self.library.transcribe(url)
            }
        }
    }

    private func recordingProblem(_ message: String?) {
        guard recorder != nil else { return }
        if let message {
            panel.show(symbol: "exclamationmark.triangle.fill", title: "錄音出狀況", subtitle: message, buttons: [("好", true, {})])
        } else if problem != nil {
            panel.show(symbol: "checkmark.circle.fill", title: "錄音已恢復", subtitle: "從剛才中斷的地方接著錄", buttons: [], hideAfter: 3)
        }
        problem = message
        updateStatus()
    }

    private func transcribed(_ url: URL, _ result: Result<Transcript, Error>) {
        updateStatus()
        switch result {
        case .success:
            panel.show(symbol: "text.bubble.fill", title: "逐字稿好了", subtitle: url.deletingPathExtension().lastPathComponent,
                       buttons: [("打開", true, { Dashboard.shared.show(select: url) })], hideAfter: 8)
        case .failure(let error):
            panel.show(symbol: "exclamationmark.triangle.fill", title: "逐字稿失敗", subtitle: "\(error)", buttons: [("好", true, {})])
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
        if let r = recorder {
            let now = Date()
            let elapsed = now.timeIntervalSince(recordingStart) - pausedTotal - (pausedAt.map { now.timeIntervalSince($0) } ?? 0)
            let s = Int(elapsed)
            library.live = .init(title: r.url.deletingPathExtension().lastPathComponent, elapsed: elapsed, paused: pausedAt != nil, problem: problem)
            button.image = nil
            let mark = problem != nil ? "⚠︎" : pausedAt == nil ? "●" : "❚❚"
            button.attributedTitle = NSAttributedString(string: String(format: "%@ %02d:%02d", mark, s / 60, s % 60), attributes: [
                .foregroundColor: problem != nil ? NSColor.systemOrange : pausedAt == nil ? NSColor.systemRed : NSColor.secondaryLabelColor,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            ])
        } else {
            library.live = nil
            button.title = ""
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "MeetRec")
        }

        let menu = NSMenu()
        menu.addItem(MenuItem("打開 MeetRec") { Dashboard.shared.show() })
        menu.addItem(.separator())
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
        if !library.status.isEmpty {
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
        menu.addItem(MenuItem("結束 MeetRec") { NSApp.terminate(nil) })
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

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
