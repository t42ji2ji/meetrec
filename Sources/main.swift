import AppKit
import AVFoundation

/// 畫面中央的半透明提示面板，不搶焦點
final class PromptPanel: NSPanel {
    private let effect = NSVisualEffectView()
    private var autoHide: DispatchWorkItem?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.masksToBounds = true
        contentView = effect
    }

    func show(symbol: String, title: String, subtitle: String, buttons: [(String, Bool, () -> Void)], hideAfter: Double? = nil) {
        effect.subviews.forEach { $0.removeFromSuperview() }

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 30, weight: .regular)
        icon.contentTintColor = .systemRed
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        let subLabel = NSTextField(labelWithString: subtitle)
        subLabel.font = .systemFont(ofSize: 12)
        subLabel.textColor = .secondaryLabelColor
        let text = NSStackView(views: [titleLabel, subLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        let header = NSStackView(views: [icon, text])
        header.spacing = 12

        let buttonViews = buttons.map { (label, primary, action) -> NSButton in
            let b = ClosureButton(title: label, action: { [weak self] in self?.dismiss(); action() })
            b.controlSize = .large
            if primary { b.bezelColor = .systemRed; b.keyEquivalent = "\r" }
            return b
        }
        let row = NSStackView(views: buttonViews.reversed())
        row.spacing = 8
        let stack = NSStackView(views: [header, row])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
        ])

        let size = stack.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        let f = screen.visibleFrame
        setFrame(NSRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2 + f.height * 0.12, width: size.width, height: size.height), display: true)

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

final class ClosureButton: NSButton {
    private var handler: () -> Void = {}
    convenience init(title: String, action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        handler = action
        target = self
        self.action = #selector(fire)
    }
    @objc private func fire() { handler() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let detector = Detector()
    private let panel = PromptPanel()
    private var statusItem: NSStatusItem!
    private var recorder: Recorder?
    private var recordingStart = Date()
    private var clock: Timer?
    private let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/會議錄音")

    func applicationDidFinishLaunching(_ note: Notification) {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatus()
        detector.onChange = { [weak self] b in self?.browserChanged(b) }
        detector.start()
    }

    private func browserChanged(_ b: Browser?) {
        if recorder == nil {
            if let b {
                panel.show(symbol: "waveform.circle.fill", title: "要錄下這場會議嗎？", subtitle: "\(b.name) 正在使用麥克風",
                           buttons: [("錄音", true, { [weak self] in self?.start(b) }), ("不用", false, {})])
            } else {
                panel.dismiss()
            }
        } else if b == nil {
            panel.show(symbol: "stop.circle.fill", title: "會議好像結束了", subtitle: "瀏覽器已停止使用麥克風",
                       buttons: [("停止並存檔", true, { [weak self] in self?.stop() }), ("繼續錄", false, {})])
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
    }

    private func updateStatus() {
        guard let button = statusItem.button else { return }
        if recorder != nil {
            let s = Int(Date().timeIntervalSince(recordingStart))
            button.image = nil
            button.attributedTitle = NSAttributedString(string: String(format: "● %02d:%02d", s / 60, s % 60), attributes: [
                .foregroundColor: NSColor.systemRed,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            ])
        } else {
            button.title = ""
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "MeetRec")
        }

        let menu = NSMenu()
        if recorder != nil {
            menu.addItem(MenuItem("停止並存檔") { [weak self] in self?.stop() })
        } else if let b = detector.current {
            menu.addItem(MenuItem("錄音（\(b.name)）") { [weak self] in self?.start(b) })
        } else {
            let item = NSMenuItem(title: "沒有偵測到會議", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
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
