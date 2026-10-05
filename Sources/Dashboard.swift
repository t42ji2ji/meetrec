import AppKit

/// 主視窗（暫時的空殼，之後換成完整的 dashboard）
@MainActor
final class Dashboard {
    static let shared = Dashboard()
    /// 打開主視窗；有給 recording 就選到那一筆
    func show(select recording: URL? = nil) {}
}
