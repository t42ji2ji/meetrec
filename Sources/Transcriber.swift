import Foundation

/// 用 whisper.cpp 轉文字、sherpa-onnx 分說話者，結果存成 Transcript（同時匯出 .srt、.txt）。
/// MeetRec 錄的檔案（metadata 有 tag）：左聲道（麥克風）＝我，右聲道（瀏覽器）＝對方，對方再分成幾個人。
/// 其他音檔：混成單聲道，分成說話者 A、B…；只有一個人就不標。
enum Transcriber {
    /// 一次只轉一個，自動轉和手動加的一起排隊
    static let queue = DispatchQueue(label: "transcriber")

    static let ffmpeg = "/opt/homebrew/bin/ffmpeg"
    static let ffprobe = "/opt/homebrew/bin/ffprobe"
    static let whisper = "/opt/homebrew/bin/whisper-cli"
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MeetRec").path
    static let model = dir + "/ggml-large-v3-turbo-q5_0.bin"
    static let vadModel = dir + "/ggml-silero-v5.1.2.bin"
    static let diarizer = dir + "/sherpa-onnx/bin/sherpa-onnx-offline-speaker-diarization"
    static let segmentationModel = dir + "/pyannote-segmentation-3-0.onnx"
    static let embeddingModel = dir + "/3dspeaker-campplus-zh-en.onnx"
    /// MeetRec 錄的檔案在 metadata 的 comment 留這個標記（Recorder.finalize 寫入）
    static let tag = "MeetRec L=mic R=browser"
    /// 分群門檻：越大越容易把不同片段當成同一個人
    static let clusterThreshold = "0.9"

    private typealias Line = (start: Double, end: Double, text: String)

    static func transcribe(_ audio: URL, progress: @escaping (Double) -> Void) throws -> Transcript {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var t: Transcript
        if try run(ffprobe, ["-v", "error", "-show_entries", "format_tags=comment", "-of", "csv=p=0", audio.path]).contains(tag) {
            let mic = try extract(audio, ["-af", "pan=mono|c0=c0"], tmp.appendingPathComponent("mic"))
            let tab = try extract(audio, ["-af", "pan=mono|c0=c1"], tmp.appendingPathComponent("tab"))
            let turns = diarizeInBackground(tab.wav)
            let micDB = levels(mic.pcm), tabDB = levels(tab.pcm)
            // 麥克風比瀏覽器小聲的句子是旁人或喇叭漏進麥克風的聲音，不是我
            let me = try recognize(mic.wav) { progress($0 * 0.3) }
                .filter { loudness(micDB, $0) > loudness(tabDB, $0) }
            // 跟我說的話重複的：我的聲音被對方那邊的麥克風（例如同一間的同事）收進去又傳回來
            let others = try recognize(tab.wav) { progress(0.3 + $0 * 0.6) }
                .filter { o in !me.contains { echoes(o, of: $0) } }
            let who = label(others, turns: try turns.wait(), prefix: "them", single: "對方", multi: "對方")
            t = Transcript(segments: me.map { .init(start: $0.start, end: $0.end, speaker: "me", text: $0.text) } + who.segments,
                           speakers: who.names.merging(["me": "我"]) { a, _ in a })
        } else {
            let mono = try extract(audio, ["-ac", "1"], tmp.appendingPathComponent("mono"))
            let turns = diarizeInBackground(mono.wav)
            let lines = try recognize(mono.wav) { progress($0 * 0.9) }
            let who = label(lines, turns: try turns.wait(), prefix: "s", single: "", multi: "說話者")
            t = Transcript(segments: who.segments, speakers: who.names)
        }
        t.segments.sort { $0.start < $1.start }
        try t.save(for: audio)
        progress(1)
        return t
    }

    /// 轉成 16 kHz 單聲道 wav 給 whisper／sherpa，另存一份 raw float 算音量
    private static func extract(_ audio: URL, _ mix: [String], _ base: URL) throws -> (wav: URL, pcm: [Float]) {
        let wav = base.appendingPathExtension("wav"), raw = base.appendingPathExtension("f32")
        try run(ffmpeg, ["-v", "error", "-y", "-i", audio.path, "-vn"] + mix + ["-ar", "16000", wav.path, "-vn"] + mix + ["-ar", "16000", "-f", "f32le", raw.path])
        let data = try Data(contentsOf: raw)
        return (wav, data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) })
    }

    private static func recognize(_ wav: URL, progress: @escaping (Double) -> Void) throws -> [Line] {
        let out = wav.deletingPathExtension()
        // VAD 先剪掉沒人講話的段落，不然 whisper 會在靜音裡編出「(電話響起)」之類的字
        try run(whisper, ["-m", model, "-l", "zh", "--vad", "-vm", vadModel, "-np", "-pp", "-oj", "-of", out.path, wav.path]) { line in
            if let r = line.range(of: "progress ="), let p = Double(line[r.upperBound...].trimmingCharacters(in: .whitespaces).dropLast()) {
                progress(p / 100)
            }
        }
        let json = try JSONDecoder().decode(WhisperJSON.self, from: Data(contentsOf: out.appendingPathExtension("json")))
        return json.transcription.compactMap { s in
            let text = s.text.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : (Double(s.offsets.from) / 1000, Double(s.offsets.to) / 1000, text)
        }
    }

    // MARK: 說話者

    private typealias Turn = (start: Double, end: Double, cluster: Int)

    private final class Pending {
        private let group = DispatchGroup()
        private var result: Result<[Turn], Error> = .success([])
        init(_ work: @escaping () throws -> [Turn]) {
            group.enter()
            DispatchQueue.global().async { self.result = Result(catching: work); self.group.leave() }
        }
        func wait() throws -> [Turn] {
            group.wait()
            return try result.get()
        }
    }

    /// sherpa-onnx 跑 CPU、whisper 跑 GPU，兩個同時跑
    private static func diarizeInBackground(_ wav: URL) -> Pending {
        Pending {
            let out = try run(diarizer, ["--segmentation.pyannote-model=\(segmentationModel)", "--embedding.model=\(embeddingModel)",
                                         "--segmentation.num-threads=4", "--embedding.num-threads=4",
                                         "--clustering.cluster-threshold=\(clusterThreshold)", wav.path])
            // 每行「0.318 -- 6.865 speaker_00」
            return out.split(separator: "\n").compactMap { line in
                let f = line.split(separator: " ")
                guard f.count == 4, let s = Double(f[0]), let e = Double(f[2]), f[3].hasPrefix("speaker_"), let c = Int(f[3].dropFirst(8)) else { return nil }
                return (s, e, c)
            }
        }
    }

    /// 每句話分給重疊最多的說話者；講話總長太短的群（多半是分錯的碎片）併進前後的人。
    /// 只剩一個人就叫 single，否則叫「multi A」「multi B」…（依出場順序）
    private static func label(_ lines: [Line], turns: [Turn], prefix: String, single: String, multi: String)
        -> (segments: [Transcript.Segment], names: [String: String]) {
        guard !lines.isEmpty else { return ([], [:]) }
        var cluster = lines.map { l -> Int in
            let overlap = Dictionary(turns.map { ($0.cluster, max(0, min($0.end, l.end) - max($0.start, l.start))) }, uniquingKeysWith: +)
            if let best = overlap.max(by: { $0.value < $1.value }), best.value > 0 { return best.key }
            return turns.min(by: { distance($0, l) < distance($1, l) })?.cluster ?? 0
        }
        let total = lines.reduce(0) { $0 + $1.end - $1.start }
        var talk: [Int: Double] = [:]
        for (l, c) in zip(lines, cluster) { talk[c, default: 0] += l.end - l.start }
        let minor = Set(talk.filter { $0.value < max(10, total * 0.03) }.keys)
        if minor.count < talk.count {
            for i in cluster.indices where minor.contains(cluster[i]) {
                let before = cluster[..<i].last { !minor.contains($0) }
                let after = cluster[(i + 1)...].first { !minor.contains($0) }
                cluster[i] = before ?? after!
            }
        }
        var order: [Int] = []
        for c in cluster where !order.contains(c) { order.append(c) }
        let key = { (c: Int) in "\(prefix)\(order.firstIndex(of: c)! + 1)" }
        var names: [String: String] = [:]
        for (i, c) in order.enumerated() {
            names[key(c)] = order.count == 1 ? single : "\(multi)\(Character(UnicodeScalar(65 + i % 26)!))"
        }
        let segments = zip(lines, cluster).map { l, c in Transcript.Segment(start: l.start, end: l.end, speaker: key(c), text: l.text) }
        return (segments, names)
    }

    private static func distance(_ t: Turn, _ l: Line) -> Double {
        max(t.start - l.end, l.start - t.end, 0)
    }

    // MARK: 音量與回音

    /// 每 0.1 秒的 dB
    private static func levels(_ pcm: [Float]) -> [Double] {
        stride(from: 0, to: pcm.count, by: 1600).map { i in
            let frame = pcm[i..<min(i + 1600, pcm.count)]
            let e = frame.reduce(0) { $0 + Double($1 * $1) } / Double(frame.count)
            return 10 * log10(e + 1e-12)
        }
    }

    private static func loudness(_ db: [Double], _ l: Line) -> Double {
        let a = min(Int(l.start * 10), db.count - 1), b = min(max(a + 1, Int(l.end * 10)), db.count)
        guard a >= 0, a < b else { return -120 }
        return db[a..<b].reduce(0, +) / Double(b - a)
    }

    /// 3 秒內、內容有六成以上一樣（最長共同子序列）就算回音；太短的（「對」「嗯」）不判斷
    private static func echoes(_ a: Line, of b: Line) -> Bool {
        guard abs(a.start - b.start) <= 3 else { return false }
        let x = Array(a.text.filter { $0.isLetter || $0.isNumber }), y = Array(b.text.filter { $0.isLetter || $0.isNumber })
        guard min(x.count, y.count) >= 4 else { return false }
        var dp = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            var prev = 0
            for j in 1...y.count {
                let tmp = dp[j]
                dp[j] = x[i - 1] == y[j - 1] ? prev + 1 : max(dp[j], dp[j - 1])
                prev = tmp
            }
        }
        return Double(dp[y.count]) >= 0.6 * Double(min(x.count, y.count))
    }
}

/// 跑外部指令，回傳 stdout；stderr 一行一行交給 onStderr
@discardableResult
func run(_ tool: String, _ args: [String], onStderr: ((String) -> Void)? = nil) throws -> String {
    let p = Process()
    let out = Pipe(), err = Pipe()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = out
    p.standardError = err
    var pending = ""
    err.fileHandleForReading.readabilityHandler = { h in
        pending += String(decoding: h.availableData, as: UTF8.self)
        while let r = pending.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            onStderr?(String(pending[..<r]))
            pending = String(pending[pending.index(after: r)...])
        }
    }
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    err.fileHandleForReading.readabilityHandler = nil
    if p.terminationStatus != 0 { throw TranscribeError(tool: (tool as NSString).lastPathComponent, status: p.terminationStatus) }
    return String(decoding: data, as: UTF8.self)
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
