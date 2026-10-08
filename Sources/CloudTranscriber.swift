import Foundation
import Security

/// API key 存在鑰匙圈，一家一把；轉錄和翻譯用同一家時共用
enum APIKeys {
    /// 畫面每次重畫都會問有沒有 key；每次都讀鑰匙圈的話，使用者沒按「永遠允許」就會一直跳授權視窗，所以一次啟動每把只讀一次
    nonisolated(unsafe) private static var cache: [String: String?] = [:]
    private static let lock = NSLock()

    static subscript(account: String) -> String? {
        get {
            lock.lock(); defer { lock.unlock() }
            if let cached = cache[account] { return cached }
            var out: AnyObject?
            let q = query(account).merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 }
            let key = SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? (out as? Data).flatMap { String(data: $0, encoding: .utf8) } : nil
            cache[account] = key
            return key
        }
        set {
            lock.lock(); defer { lock.unlock() }
            SecItemDelete(query(account) as CFDictionary)
            let v = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            cache[account] = v?.isEmpty == false ? v : nil
            guard let v, !v.isEmpty else { return }
            SecItemAdd(query(account).merging([kSecValueData as String: Data(v.utf8)]) { $1 } as CFDictionary, nil)
        }
    }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "MeetRec API key", kSecAttrAccount as String: account]
    }
}

/// 雲端轉錄服務：都是 OpenAI 相容的 /audio/transcriptions（回 verbose_json 才有每句的時間）
enum TranscriptionService: String, CaseIterable, Identifiable {
    case groq, openai
    var id: String { rawValue }

    var name: String { self == .groq ? "Groq" : "OpenAI" }

    private var base: String { self == .groq ? "https://api.groq.com/openai/v1" : "https://api.openai.com/v1" }

    var keyPage: URL { URL(string: self == .groq ? "https://console.groq.com/keys" : "https://platform.openai.com/api-keys")! }

    /// 第一個是預設。OpenAI 的 gpt-4o 系列不給每句的時間，播放對不上，只能用 whisper-1
    var models: [(id: String, name: String)] {
        switch self {
        case .groq: return [("whisper-large-v3", L("Whisper large-v3（較準）", "Whisper large-v3 (more accurate)")),
                            ("whisper-large-v3-turbo", L("Whisper large-v3-turbo（較便宜）", "Whisper large-v3-turbo (cheaper)"))]
        case .openai: return [("whisper-1", "Whisper")]
        }
    }

    var apiKey: String? {
        get { APIKeys[rawValue] }
        nonmutating set { APIKeys[rawValue] = newValue }
    }

    /// 設定裡的「檢查」：列模型清單不花錢，金鑰錯會直接被拒
    func check(key: String) async throws {
        var request = URLRequest(url: URL(string: base + "/models")!, timeoutInterval: 30)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, r) = try await URLSession.shared.data(for: request)
        let status = (r as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw CloudTranscriber.Failure(service: self, message: CloudTranscriber.errorMessage(data, status)) }
    }

    var endpoint: URL { URL(string: base + "/audio/transcriptions")! }
}

enum CloudTranscriber {
    struct Failure: Error, CustomStringConvertible {
        let service: TranscriptionService
        let message: String
        var description: String { L("\(service.name) 轉錄失敗：\(message)", "\(service.name) transcription failed: \(message)") }
    }

    /// 上傳上限 25 MB；16 kHz 16-bit 單聲道一秒 32 KB，一段 10 分鐘約 19 MB
    static let pieceSeconds = 600

    /// 切成幾段依序上傳，時間接回整段的位置。在 Transcriber.queue 上跑，直接同步等回應
    static func recognize(_ pcm: [Float], wav: URL, service: TranscriptionService, model: String, progress: (Double) -> Void) throws -> [(start: Double, end: Double, text: String)] {
        guard let key = service.apiKey else {
            throw Failure(service: service, message: L("還沒設定 API key，到設定 › 轉錄填入", "No API key yet. Add one in Settings › Transcription."))
        }
        let (speech, regions) = try voiced(pcm, wav: wav)
        // 片段接起來之後的時間 → 原本錄音裡的時間
        let original = { (t: Double) -> Double in
            let sample = Int(t * 16000)
            let r = regions.last { $0.joined <= sample } ?? (from: 0, joined: 0, count: 0)
            return Double(r.from + min(sample - r.joined, r.count)) / 16000
        }
        var lines: [(start: Double, end: Double, text: String)] = []
        var start = 0
        while start < speech.count {
            let end = cut(speech, after: start)
            let offset = Double(start) / 16000
            for s in try transcribe(Array(speech[start..<end]), service: service, model: model, key: key) {
                lines.append((original(offset + s.start), original(offset + s.end), s.text))
            }
            start = end
            progress(Double(start) / Double(speech.count))
        }
        return lines
    }

    /// 只留有人講話的片段接起來上傳，跟本機版一樣用 Silero VAD 判斷：
    /// 自動偵測語言只聽每段開頭 30 秒，開頭是雜音會判錯語言、整段翻成英文；沒人講話的地方 whisper 也會編字，還白白用掉額度。
    /// 前後各留 0.2 秒；停不到 1 秒的接回原音（不然一句話會被切成好幾行），停更久的換成 1 秒靜音，whisper 才會在那裡斷句
    private static func voiced(_ pcm: [Float], wav: URL) throws -> (speech: [Float], regions: [(from: Int, joined: Int, count: Int)]) {
        // 每行「Speech segment 0: start = 87111.00, end = 87142.00」，單位 10 毫秒
        let out = try run(Transcriber.vad, ["-vm", Transcriber.vadModel, "-np", "-f", wav.path])
        let spans = out.split(separator: "\n").compactMap { line -> (Int, Int)? in
            guard let m = line.firstMatch(of: #/start = ([\d.]+), end = ([\d.]+)/#), let a = Double(m.1), let b = Double(m.2) else { return nil }
            return (max(0, Int((a / 100 - 0.2) * 16000)), min(pcm.count, Int((b / 100 + 0.2) * 16000)))
        }
        var speech: [Float] = [], regions: [(from: Int, joined: Int, count: Int)] = []
        var last = 0
        for (a, b) in spans {
            let from = max(a, last)
            guard from < b else { continue }
            if !regions.isEmpty, from - last < 16000 {
                speech += pcm[last..<b]
                regions[regions.count - 1].count += b - last
            } else {
                if !speech.isEmpty { speech += [Float](repeating: 0, count: 16000) }
                regions.append((from, speech.count, b - from))
                speech += pcm[from..<b]
            }
            last = b
        }
        return (speech, regions)
    }

    /// 下一段的結尾：切在 10 分鐘前最後 30 秒裡最安靜的 0.1 秒，不要把一句話切成兩半
    private static func cut(_ pcm: [Float], after start: Int) -> Int {
        let limit = start + pieceSeconds * 16000
        guard limit < pcm.count else { return pcm.count }
        let window = 1600
        var best = limit, quietest = Float.infinity
        for i in stride(from: limit - 30 * 16000, to: limit - window, by: window) {
            let energy = pcm[i..<i + window].reduce(0) { $0 + $1 * $1 }
            if energy < quietest { quietest = energy; best = i + window / 2 }
        }
        return best
    }

    private struct Response: Decodable {
        struct Segment: Decodable {
            let start: Double, end: Double, text: String
            let no_speech_prob: Double?, avg_logprob: Double?
        }
        let segments: [Segment]?
    }

    private static func transcribe(_ pcm: [Float], service: TranscriptionService, model: String, key: String) throws -> [(start: Double, end: Double, text: String)] {
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Media.writeWav(pcm, to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }

        var fields = ["model": model, "response_format": "verbose_json", "timestamp_granularities[]": "segment"]
        if Settings.transcriptLanguage != .auto { fields["language"] = Settings.transcriptLanguage.rawValue }
        if let prompt = Settings.vocabularyPrompt { fields["prompt"] = prompt }
        let boundary = UUID().uuidString
        var body = Data()
        for (k, v) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(try Data(contentsOf: wav))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: service.endpoint, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        var lastError = ""
        for attempt in 0..<8 {
            let (data, response, error) = send(request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200, let r = try? JSONDecoder().decode(Response.self, from: data) {
                return (r.segments ?? []).compactMap { s -> (start: Double, end: Double, text: String)? in
                    // 沒人講話的地方 whisper 會編字（「謝謝觀看」之類），照 whisper 自己的判準丟掉
                    if (s.no_speech_prob ?? 0) > 0.6, (s.avg_logprob ?? 0) < -1 { return nil }
                    let text = Settings.script.convert(s.text).trimmingCharacters(in: .whitespaces)
                    return text.isEmpty ? nil : (s.start, s.end, text)
                }
            }
            lastError = error?.localizedDescription ?? errorMessage(data, status)
            // 金鑰錯、檔案有問題重試也沒用
            if [400, 401, 403, 404, 413].contains(status) { break }
            // 免費額度用完會回 429 並告訴你等多久；其他錯誤（伺服器忙、斷線）就漸漸拉長再試
            let wait = status == 429 ? Double((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after") ?? "") ?? 20 : Double(2 << attempt)
            Thread.sleep(forTimeInterval: min(wait, 120))
        }
        throw Failure(service: service, message: lastError)
    }

    private static func send(_ request: URLRequest) -> (Data, URLResponse?, Error?) {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: (Data, URLResponse?, Error?) = (Data(), nil, nil)
        URLSession.shared.dataTask(with: request) { d, r, e in
            result = (d ?? Data(), r, e)
            done.signal()
        }.resume()
        done.wait()
        return result
    }

    static func errorMessage(_ data: Data, _ status: Int) -> String {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((json?["error"] as? [String: Any])?["message"] as? String) ?? String(data: data, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 } ?? "HTTP \(status)"
    }
}
