import Foundation

/// 使用者設定（存在 UserDefaults）
enum Settings {
    enum Script: String, CaseIterable, Identifiable {
        case traditional, simplified, original
        var id: String { rawValue }
        var label: String {
            switch self {
            case .traditional: return L("繁體中文", "Traditional")
            case .simplified: return L("簡體中文", "Simplified")
            case .original: return L("不轉換", "Don't convert")
            }
        }
    }

    /// 介面語言
    enum Language: String, CaseIterable, Identifiable {
        case system, zh, en
        var id: String { rawValue }
        var label: String {
            switch self {
            case .system: return L("跟隨系統", "System")
            case .zh: return "中文"
            case .en: return "English"
            }
        }
    }

    /// 轉逐字稿的語言；auto＝whisper 聽開頭一段自己判斷
    enum TranscriptLanguage: String, CaseIterable, Identifiable {
        case auto, zh, en
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: return L("自動偵測", "Detect automatically")
            case .zh: return "中文"
            case .en: return "English"
            }
        }
    }

    private static let defaults = UserDefaults.standard

    static let languageChanged = Notification.Name("MeetRecLanguageChanged")

    /// 設定視窗、主視窗用 @AppStorage("language") 讀，改了會自己重畫；選單列和選單靠 languageChanged
    static var language: Language {
        get { defaults.string(forKey: "language").flatMap(Language.init) ?? .system }
        set {
            defaults.set(newValue.rawValue, forKey: "language")
            NotificationCenter.default.post(name: languageChanged, object: nil)
        }
    }

    /// 跟隨系統時看 macOS 替這個 app 選的語言（系統設定 › 語言與地區 › App 可以單獨指定）
    static var english: Bool {
        switch language {
        case .system: return Bundle.main.preferredLocalizations.first?.hasPrefix("en") ?? false
        case .zh: return false
        case .en: return true
        }
    }

    /// 語音轉文字模型的檔名（Models.speech 其中一個）
    static var speechModel: String {
        get { defaults.string(forKey: "speechModel") ?? "ggml-large-v3-turbo-q5_0.bin" }
        set { defaults.set(newValue, forKey: "speechModel") }
    }

    static var transcriptLanguage: TranscriptLanguage {
        get { defaults.string(forKey: "transcriptLanguage").flatMap(TranscriptLanguage.init) ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: "transcriptLanguage") }
    }

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

    /// 逐字稿內文的字級（pt）；主視窗用 @AppStorage("transcriptFontSize") 讀
    static let defaultFontSize = 18.0
    static var transcriptFontSize: Double {
        get { defaults.object(forKey: "transcriptFontSize") as? Double ?? defaultFontSize }
        set { defaults.set(min(max(newValue, 11), 36), forKey: "transcriptFontSize") }
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

/// 介面文字：照目前的介面語言挑中文或英文
func L(_ zh: String, _ en: String) -> String {
    Settings.english ? en : zh
}
