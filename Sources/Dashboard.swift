import AppKit
import SwiftUI

/// 主視窗：左邊錄音清單，右邊播放、看逐字稿、修正。視窗開著時 app 出現在 Dock 和 Cmd-Tab，關掉就退回只有選單列
@MainActor
final class Dashboard: NSObject, NSWindowDelegate {
    static let shared = Dashboard()
    let model = DashboardModel()
    private var window: NSWindow?
    private var keyMonitor: Any?

    /// 打開主視窗；有給 recording 就選到那一筆
    func show(select recording: URL? = nil) {
        if let recording {
            model.selection = .recording(recording)
        } else if model.selection == nil, let first = Library.shared.recordings.first {
            model.selection = .recording(first.url)
        }
        let w = window ?? makeWindow()
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            // accessory app 沒有主選單，不補的話文字欄位裡 Cmd-C/V/Z 都沒反應
            NSApp.mainMenu = mainMenu()
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // 剛從 accessory 切成 regular 的那一輪有時候搶不到前景，下一輪再叫一次
        DispatchQueue.main.async {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate()
            // SwiftUI 會把焦點給第一個文字欄位（標題），一打開就按空白鍵會變成改標題
            if w.firstResponder is NSText { w.makeFirstResponder(nil) }
        }
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: DashboardView(model: model))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        hosting.sizingOptions = [.minSize]
        let w = NSWindow(contentViewController: hosting)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.toolbarStyle = .unified
        w.title = "MeetRec"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setContentSize(NSSize(width: 1040, height: 700))
        w.center()
        w.setFrameAutosaveName("MeetRecDashboard")
        window = w
        // 結束 app 不會關視窗，還在等存檔的修改要先寫下去
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.windowClosed() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            MainActor.assumeIsolated { self?.handleSpace(e) ?? false } ? nil : e
        }
        return w
    }

    /// 空白鍵播放／暫停；正在打字（first responder 是文字欄位的 field editor）或有對話框時不攔
    private func handleSpace(_ e: NSEvent) -> Bool {
        guard let window, e.window === window, window.attachedSheet == nil, e.keyCode == 49,
              e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock).isEmpty,
              !(window.firstResponder is NSText), model.player.url != nil else { return false }
        model.player.toggle()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        model.windowClosed()
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func importFiles() { model.importWithPanel() }

    private func mainMenu() -> NSMenu {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: String, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        let importItem = item("匯入…", "importFiles", "o")
        importItem.target = self
        add("MeetRec", [item("隱藏 MeetRec", "hide:", "h"), .separator(), item("結束 MeetRec", "terminate:", "q")])
        add("檔案", [importItem, .separator(), item("關閉視窗", "performClose:", "w")])
        add("編輯", [item("還原", "undo:", "z"), item("重做", "redo:", "z", [.command, .shift]), .separator(),
                     item("剪下", "cut:", "x"), item("拷貝", "copy:", "c"), item("貼上", "paste:", "v"), item("全選", "selectAll:", "a")])
        add("視窗", [item("最小化", "performMiniaturize:", "m"), item("縮放", "performZoom:", "")])
        return main
    }
}
