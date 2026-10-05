import Foundation

/// 使用者設定（存在 UserDefaults）
enum Settings {
    enum Script: String, CaseIterable, Identifiable {
        case traditional, simplified, original
        var id: String { rawValue }
        var label: String {
            switch self {
            case .traditional: return "繁體中文"
            case .simplified: return "簡體中文"
            case .original: return "不轉換"
            }
        }
    }

    private static let defaults = UserDefaults.standard

    /// 逐字稿的中文字體；whisper 有時繁簡混著出
    static var script: Script {
        get { defaults.string(forKey: "script").flatMap(Script.init) ?? .traditional }
        set { defaults.set(newValue.rawValue, forKey: "script") }
    }

    /// 瀏覽器開始用麥克風時跳出「要錄下這場會議嗎？」
    static var askToRecord: Bool {
        get { defaults.object(forKey: "askToRecord") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "askToRecord") }
    }

    /// 錄完自動轉逐字稿
    static var autoTranscribe: Bool {
        get { defaults.object(forKey: "autoTranscribe") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoTranscribe") }
    }
}

extension Settings.Script {
    private static let toTraditional = StringTransform("Hans-Hant"), toSimplified = StringTransform("Hant-Hans")

    /// 只換另一種字體「專用」的字，用的是整句轉換的結果（整句轉才分得出 头发→頭髮）；
    /// 兩邊通用或已經是目標字體的字保留原字，不然 ICU 會把「了解」改成「瞭解」
    func convert(_ text: String) -> String {
        let (to, back): (StringTransform, StringTransform)
        switch self {
        case .original: return text
        case .traditional: (to, back) = (Self.toTraditional, Self.toSimplified)
        case .simplified: (to, back) = (Self.toSimplified, Self.toTraditional)
        }
        let foreign = { (c: Character) -> Bool in
            let one = String(c)
            return (one.applyingTransform(to, reverse: false) ?? one) != one && (one.applyingTransform(back, reverse: false) ?? one) == one
        }
        guard text.contains(where: foreign), let whole = text.applyingTransform(to, reverse: false) else { return text }
        let original = Array(text), converted = Array(whole)
        guard original.count == converted.count else { return whole }
        return String(zip(original, converted).map { foreign($0) ? $1 : $0 })
    }
}
