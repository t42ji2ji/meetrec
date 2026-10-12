import AppKit
import CoreServices

/// onboarding 先把錄會議要的權限要好：瀏覽器的聲音、讀瀏覽器分頁（麥克風用 AVCaptureDevice）
enum Permissions {
    enum State { case unknown, granted, denied }

    // 錄瀏覽器聲音（螢幕與系統錄音裡的「只錄音訊」）沒有公開的查詢方式，用系統的 TCC：0 允許、1 拒絕、其他沒問過
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private static let audioCapture = "kTCCServiceAudioCapture" as CFString

    static var browserAudio: State {
        guard let f = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(f, to: Preflight.self)(audioCapture, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    static func requestBrowserAudio(_ done: @escaping @Sendable () -> Void) {
        guard let f = dlsym(tcc, "TCCAccessRequest") else { return done() }
        unsafeBitCast(f, to: Request.self)(audioCapture, nil) { _ in done() }
    }

    /// 裝了、而且讀得到分頁標題的瀏覽器
    static var tabBrowsers: [Browser] {
        browsers.filter { $0.tabTitle != nil && NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.appID) != nil }
    }

    /// 讀分頁要的自動化權限；瀏覽器沒開就查不到，ask 時先在背景打開它。會卡住，不要在主執行緒呼叫
    static func automation(_ b: Browser, ask: Bool) -> State {
        if ask, NSRunningApplication.runningApplications(withBundleIdentifier: b.appID).isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b.appID) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.hides = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
            for _ in 0..<50 where NSRunningApplication.runningApplications(withBundleIdentifier: b.appID).isEmpty { Thread.sleep(forTimeInterval: 0.2) }
            Thread.sleep(forTimeInterval: 1)
        }
        var target = AEAddressDesc()
        let id = Array(b.appID.utf8)
        AECreateDesc(typeApplicationBundleID, id, id.count, &target)
        defer { AEDisposeDesc(&target) }
        switch AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask) {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .unknown
        }
    }
}
