import Foundation

/// 一份逐字稿。存在音檔旁邊的隱藏檔「.<音檔檔名>.transcript.json」；每次 save 同時匯出 .srt 和 .txt，
/// 所以手動修正也會反映在 srt/txt。
struct Transcript: Codable, Equatable {
    struct Segment: Codable, Equatable, Identifiable {
        var id = UUID()
        var start: Double // 秒
        var end: Double
        var speaker: String // speakers 的 key
        var text: String
    }

    var segments: [Segment]
    /// 說話者 key → 顯示名稱。key 不變（"me"、"them"、"them1"…、"s1"…），使用者改的是名稱；名稱空字串＝不標說話者
    var speakers: [String: String]
    /// 說話者 key → 使用者挑的顏色（speakerPalette 的索引）；沒挑的照 key 自動配
    var colors: [String: Int]? = nil

    /// 依第一次出現的順序
    var speakerOrder: [String] {
        var seen: [String] = []
        for s in segments where !seen.contains(s.speaker) { seen.append(s.speaker) }
        return seen
    }

    func name(_ speaker: String) -> String { speakers[speaker] ?? speaker }

    static func sidecar(for audio: URL) -> URL {
        audio.deletingLastPathComponent().appendingPathComponent(".\(audio.lastPathComponent).transcript.json")
    }

    static func load(for audio: URL) -> Transcript? {
        guard let data = try? Data(contentsOf: sidecar(for: audio)) else { return nil }
        return try? JSONDecoder().decode(Transcript.self, from: data)
    }

    /// 寫 json，並匯出同名 .srt、.txt
    func save(for audio: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Self.sidecar(for: audio), options: .atomic)
        let base = audio.deletingPathExtension()
        try srt().write(to: base.appendingPathExtension("srt"), atomically: true, encoding: .utf8)
        try txt().write(to: base.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
    }

    private func label(_ speaker: String) -> String {
        let n = name(speaker)
        return n.isEmpty ? "" : n + (n.allSatisfy(\.isASCII) ? ": " : "：")
    }

    func srt() -> String {
        segments.enumerated().map { i, s in
            "\(i + 1)\n\(Self.srtTime(s.start)) --> \(Self.srtTime(s.end))\n\(label(s.speaker))\(s.text)\n"
        }.joined(separator: "\n")
    }

    /// 同一個人連續講的併成一行，時間標在開頭；超過 30 秒就另起一行
    func txt() -> String {
        var lines: [String] = []
        var last = "", lineStart = 0.0
        for s in segments {
            if !lines.isEmpty, s.speaker == last, s.start - lineStart < 30 {
                // 英文句子用空白接，中文用逗號
                lines[lines.count - 1] += (s.text.first?.isASCII == true ? " " : "，") + s.text
            } else {
                lines.append("[\(Self.clock(s.start))] \(label(s.speaker))\(s.text)")
                last = s.speaker
                lineStart = s.start
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// mm:ss，超過一小時 h:mm:ss
    static func clock(_ t: Double) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    private static func srtTime(_ t: Double) -> String {
        let ms = Int((t * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
}
