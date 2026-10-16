import AppKit

/// 一份逐字稿。存在音檔旁邊的隱藏檔「.<音檔檔名>.transcript.json」；每次 save 同時匯出 .srt 和 .txt，
/// 所以手動修正也會反映在 srt/txt。
struct Transcript: Codable, Equatable {
    struct Segment: Codable, Equatable, Identifiable {
        var id = UUID()
        var start: Double // 秒
        var end: Double
        var speaker: String // speakers 的 key
        var text: String
        /// 翻譯（翻了才有）；改了原文就清掉
        var translation: String? = nil
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

    /// 同一個人連續講的併成一段；超過 30 秒就另起一段
    private var paragraphs: [(start: Double, speaker: String, text: String)] {
        var out: [(start: Double, speaker: String, text: String)] = []
        for s in segments {
            if let p = out.last, s.speaker == p.speaker, s.start - p.start < 30 {
                // 英文句子用空白接，中文用逗號
                out[out.count - 1].text += (s.text.first?.isASCII == true ? " " : "，") + s.text
            } else {
                out.append((s.start, s.speaker, s.text))
            }
        }
        return out
    }

    /// 一段一行，時間標在開頭
    func txt() -> String {
        paragraphs.map { "[\(Self.clock($0.start))] \(label($0.speaker))\($0.text)" }.joined(separator: "\n") + "\n"
    }

    func vtt() -> String {
        "WEBVTT\n\n" + segments.map { s in
            "\(Self.srtTime(s.start).replacingOccurrences(of: ",", with: ".")) --> \(Self.srtTime(s.end).replacingOccurrences(of: ",", with: "."))\n\(label(s.speaker))\(s.text)\n"
        }.joined(separator: "\n")
    }

    func markdown(title: String, subtitle: String) -> String {
        "# \(title)\n\n\(subtitle)\n\n" + paragraphs.map { p in
            let n = name(p.speaker)
            return "`\(Self.clock(p.start))`" + (n.isEmpty ? "" : " **\(n)**") + "\n\n\(p.text)\n"
        }.joined(separator: "\n")
    }

    func html(title: String, subtitle: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let body = paragraphs.map { p in
            let n = name(p.speaker)
            return "<p class=\"head\"><time>\(Self.clock(p.start))</time>" + (n.isEmpty ? "" : " <b>\(esc(n))</b>") + "</p>\n<p>\(esc(p.text))</p>"
        }.joined(separator: "\n")
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>\(esc(title))</title>
        <style>
        body { font: 15px/1.6 -apple-system, system-ui, sans-serif; max-width: 720px; margin: 40px auto; padding: 0 16px; color: #111; }
        h1 { font-size: 24px; margin-bottom: 4px; } .sub { color: #666; margin-bottom: 28px; }
        .head { margin: 18px 0 2px; font-size: 13px; color: #444; } time { color: #888; font-variant-numeric: tabular-nums; }
        @media (prefers-color-scheme: dark) { body { background: #111; color: #eee; } .sub, .head { color: #aaa; } }
        </style></head><body>
        <h1>\(esc(title))</h1><p class="sub">\(esc(subtitle))</p>
        \(body)
        </body></html>

        """
    }

    /// Word 檔：跟 PDF 同一份排版
    func docx(title: String, subtitle: String) throws -> Data {
        let body = attributed(title: title, subtitle: subtitle)
        return try body.data(from: NSRange(location: 0, length: body.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
    }

    /// PDF、Word 共用的排版：標題、日期，接著每段「時間 說話者」一行、內文一行
    private func attributed(title: String, subtitle: String) -> NSMutableAttributedString {
        let body = NSMutableAttributedString()
        func add(_ text: String, _ font: NSFont, _ color: NSColor = .black, after: CGFloat) {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = after
            style.lineSpacing = 2
            body.append(NSAttributedString(string: text + "\n", attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]))
        }
        add(title, .systemFont(ofSize: 20, weight: .semibold), after: 4)
        add(subtitle, .systemFont(ofSize: 11), .darkGray, after: 20)
        for p in paragraphs {
            let head = NSMutableAttributedString(string: Self.clock(p.start), attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular), .foregroundColor: NSColor.gray])
            let n = name(p.speaker)
            if !n.isEmpty { head.append(NSAttributedString(string: "  " + n, attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.darkGray])) }
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 2
            head.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: head.length))
            body.append(head)
            body.append(NSAttributedString(string: "\n"))
            add(p.text, .systemFont(ofSize: 11), after: 12)
        }
        return body
    }

    /// A4 分頁的 PDF
    func pdf(title: String, subtitle: String) -> Data {
        let body = attributed(title: title, subtitle: subtitle)
        var page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let frame = page.insetBy(dx: 56, dy: 56)
        let data = NSMutableData()
        let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &page, nil)!
        let setter = CTFramesetterCreateWithAttributedString(body)
        var at = 0
        repeat {
            ctx.beginPDFPage(nil)
            let f = CTFramesetterCreateFrame(setter, CFRange(location: at, length: 0), CGPath(rect: frame, transform: nil), nil)
            CTFrameDraw(f, ctx)
            let shown = CTFrameGetVisibleStringRange(f).length
            ctx.endPDFPage()
            if shown == 0 { break }
            at += shown
        } while at < body.length
        ctx.closePDF()
        return data as Data
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
