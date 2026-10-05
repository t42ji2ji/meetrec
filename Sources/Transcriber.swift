import Foundation

/// 錄完後用 whisper.cpp 轉逐字稿：左聲道（麥克風）＝我、右聲道（瀏覽器）＝對方，分開轉再依時間合併。
/// 產出跟錄音同名的 .txt。
enum Transcriber {
    static let ffmpeg = "/opt/homebrew/bin/ffmpeg"
    static let whisper = "/opt/homebrew/bin/whisper-cli"
    static let model = home(".whisper-cpp-models/ggml-large-v3-turbo-q5_0.bin")
    static let vadModel = home(".whisper-cpp-models/ggml-silero-v5.1.2.bin")

    static func transcribe(_ audio: URL) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var segments: [(ms: Int, speaker: String, text: String)] = []
        for (ch, speaker) in [(0, "我"), (1, "對方")] {
            let wav = tmp.appendingPathComponent("\(ch).wav")
            let out = tmp.appendingPathComponent("\(ch)")
            try run(ffmpeg, ["-v", "error", "-y", "-i", audio.path, "-af", "pan=mono|c0=c\(ch)", "-ar", "16000", wav.path])
            // VAD 先剪掉沒人講話的段落，不然 whisper 會在靜音裡編出「(電話響起)」之類的字
            try run(whisper, ["-m", model, "-l", "zh", "--vad", "-vm", vadModel, "-np", "-oj", "-of", out.path, wav.path])
            let json = try JSONDecoder().decode(WhisperJSON.self, from: Data(contentsOf: out.appendingPathExtension("json")))
            for s in json.transcription {
                let text = s.text.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { segments.append((s.offsets.from, speaker, text)) }
            }
        }
        segments.sort { $0.ms < $1.ms }

        // 同一個人連續講的段落併成一行，時間標在開頭；超過 30 秒就另起一行
        var lines: [String] = []
        var last = "", lineStart = 0
        for s in segments {
            if s.speaker == last, s.ms - lineStart < 30_000 {
                lines[lines.count - 1] += "，" + s.text
            } else {
                let sec = s.ms / 1000
                lines.append(String(format: "[%02d:%02d] %@：%@", sec / 60, sec % 60, s.speaker, s.text))
                last = s.speaker
                lineStart = s.ms
            }
        }
        let txt = audio.deletingPathExtension().appendingPathExtension("txt")
        try (lines.joined(separator: "\n") + "\n").write(to: txt, atomically: true, encoding: .utf8)
        return txt
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
        struct Offsets: Decodable { let from: Int }
        let offsets: Offsets
        let text: String
    }
    let transcription: [Segment]
}
