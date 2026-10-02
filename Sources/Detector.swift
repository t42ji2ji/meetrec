import CoreAudio
import Foundation

/// Chromium 系瀏覽器；實際收音的是 bundle ID 帶 ".helper" 的輔助程式
struct Browser {
    let bundlePrefix: String
    let name: String
}

let browsers = [
    Browser(bundlePrefix: "com.citrolabs.ego", name: "ego lite"),
    Browser(bundlePrefix: "com.google.Chrome", name: "Chrome"),
    Browser(bundlePrefix: "company.thebrowser", name: "Arc"),
    Browser(bundlePrefix: "com.microsoft.edgemac", name: "Edge"),
    Browser(bundlePrefix: "com.brave.Browser", name: "Brave"),
]

/// 每秒檢查哪個瀏覽器在用麥克風，狀態改變時回呼（主執行緒）
final class Detector {
    var onChange: ((Browser?) -> Void)?
    private(set) var current: Browser?
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        var found: Browser?
        for p in processObjects() where getUInt32(p, kAudioProcessPropertyIsRunningInput) == 1 {
            guard let bundle = getString(p, kAudioProcessPropertyBundleID) else { continue }
            if let b = browsers.first(where: { bundle.hasPrefix($0.bundlePrefix) }) { found = b; break }
        }
        if found?.bundlePrefix != current?.bundlePrefix {
            current = found
            onChange?(found)
        }
    }
}
