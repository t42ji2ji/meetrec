import Foundation

/// 用 whisper.cpp 轉逐字稿，產出跟音檔同名的 .srt 和 .txt。
/// MeetRec 的錄音（speakers）左聲道（麥克風）＝我、右聲道（瀏覽器）＝對方，分開轉再依時間合併；其他音檔混成單聲道、不標說話者。
enum Transcriber {
    /// 一次只轉一個，自動轉和拖進來的檔案一起排隊
    static let queue = DispatchQueue(label: "transcriber")

    static let ffmpeg = "/opt/homebrew/bin/ffmpeg"
    static let whisper = "/opt/homebrew/bin/whisper-cli"
    static let model = home(".whisper-cpp-models/ggml-large-v3-turbo-q5_0.bin")
    static let vadModel = home(".whisper-cpp-models/ggml-silero-v5.1.2.bin")

    /// 回傳 .txt 的位置
    static func transcribe(_ audio: URL, speakers: Bool) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var segments: [(ms: Int, end: Int, speaker: String, text: String)] = []
        let tracks = speakers ? [(["-af", "pan=mono|c0=c0"], "我"), (["-af", "pan=mono|c0=c1"], "對方")] : [(["-ac", "1"], "")]
        for (ch, (mix, speaker)) in tracks.enumerated() {
            let wav = tmp.appendingPathComponent("\(ch).wav")
            let out = tmp.appendingPathComponent("\(ch)")
            try run(ffmpeg, ["-v", "error", "-y", "-i", audio.path, "-vn"] + mix + ["-ar", "16000", wav.path])
            // VAD 先剪掉沒人講話的段落，不然 whisper 會在靜音裡編出「(電話響起)」之類的字
            try run(whisper, ["-m", model, "-l", "zh", "--vad", "-vm", vadModel, "-np", "-oj", "-of", out.path, wav.path])
            let json = try JSONDecoder().decode(WhisperJSON.self, from: Data(contentsOf: out.appendingPathExtension("json")))
            for s in json.transcription {
                let text = s.text.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { segments.append((s.offsets.from, s.offsets.to, speaker, text)) }
            }
        }
        segments.sort { $0.ms < $1.ms }
        let label = { (speaker: String) in speaker.isEmpty ? "" : speaker + "：" }

        let srt = segments.enumerated().map { i, s in
            "\(i + 1)\n\(srtTime(s.ms)) --> \(srtTime(s.end))\n\(label(s.speaker))\(s.text)\n"
        }
        try srt.joined(separator: "\n").write(to: audio.deletingPathExtension().appendingPathExtension("srt"), atomically: true, encoding: .utf8)

        // 同一個人連續講的段落併成一行，時間標在開頭；超過 30 秒就另起一行
        var lines: [String] = []
        var last = "", lineStart = 0
        for s in segments {
            if !lines.isEmpty, s.speaker == last, s.ms - lineStart < 30_000 {
                lines[lines.count - 1] += "，" + s.text
            } else {
                let sec = s.ms / 1000
                lines.append(String(format: "[%02d:%02d] %@%@", sec / 60, sec % 60, label(s.speaker), s.text))
                last = s.speaker
                lineStart = s.ms
            }
        }
        let txt = audio.deletingPathExtension().appendingPathExtension("txt")
        try (lines.joined(separator: "\n") + "\n").write(to: txt, atomically: true, encoding: .utf8)
        return txt
    }

    private static func srtTime(_ ms: Int) -> String {
        String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw TranscribeError(tool: (tool as NSString).lastPathComponent, status: p.terminationStatus) }
    }

    private static func home(_ path: String) -> String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path).path
    }
}

struct TranscribeError: Error, CustomStringConvertible {
    let tool: String, status: Int32
    var description: String { "\(tool) 失敗（\(status)）" }
}

private struct WhisperJSON: Decodable {
    struct Segment: Decodable {
        struct Offsets: Decodable { let from, to: Int }
        let offsets: Offsets
        let text: String
    }
    let transcription: [Segment]
}
