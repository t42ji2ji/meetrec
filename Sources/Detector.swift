import AppKit
import CoreAudio

/// Chromium 系瀏覽器；實際收音的是 bundle ID 帶 ".helper" 的輔助程式。appID 是主程式，用來以 AppleScript 讀分頁
struct Browser {
    let bundlePrefix: String
    let appID: String
    let name: String
}

let browsers = [
    Browser(bundlePrefix: "com.citrolabs.ego", appID: "com.citrolabs.ego.lite", name: "ego lite"),
    Browser(bundlePrefix: "com.google.Chrome", appID: "com.google.Chrome", name: "Chrome"),
    Browser(bundlePrefix: "company.thebrowser", appID: "company.thebrowser.Browser", name: "Arc"),
    Browser(bundlePrefix: "com.microsoft.edgemac", appID: "com.microsoft.edgemac", name: "Edge"),
    Browser(bundlePrefix: "com.brave.Browser", appID: "com.brave.Browser", name: "Brave"),
]

extension Browser {
    /// 開著的會議分頁標題（Google Meet、Teams）；只有會議代碼或讀不到（沒給自動化權限）就回 nil。主執行緒
    func meetingTitle() -> String? {
        let script = """
        tell application id "\(appID)"
            set out to ""
            repeat with w in windows
                repeat with t in tabs of w
                    set out to out & (URL of t) & "\t" & (title of t) & "\n"
                end repeat
            end repeat
            return out
        end tell
        """
        guard let out = NSAppleScript(source: script)?.executeAndReturnError(nil).stringValue else { return nil }
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, let title = Self.meetingName(url: parts[0], title: parts[1]) else { continue }
            return title
        }
        return nil
    }

    static func meetingName(url: String, title: String) -> String? {
        // 先去掉「(2)」之類的未讀數
        let title = title.replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)
        var name: String
        if url.contains("meet.google.com/") {
            // 「Meet - 週會」「Meet – abc-defg-hij」
            name = title.replacingOccurrences(of: #"^Meet\s*[-–—]\s*"#, with: "", options: .regularExpression)
            if name.range(of: #"^[a-z]{3,4}-[a-z]{4}-[a-z]{3}$"#, options: .regularExpression) != nil || name == "Meet" || name == "Google Meet" { return nil }
        } else if url.contains("teams.microsoft.com") || url.contains("teams.live.com") {
            name = title.replacingOccurrences(of: #"\s*\|\s*Microsoft Teams.*$"#, with: "", options: .regularExpression)
            if name.isEmpty || name.hasPrefix("Microsoft Teams") { return nil }
        } else {
            return nil
        }
        // 不能當檔名的字
        name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : String(name.prefix(60))
    }
}

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
