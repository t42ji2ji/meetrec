import Foundation
import NaturalLanguage
import Translation

/// 翻譯服務。Claude 用自己的 Messages API，其他都是 OpenAI 相容的 chat/completions；加一家＝多一個 case
enum TranslationProvider: String, CaseIterable, Identifiable {
    case openai, claude, gemini, groq, grok, deepseek, zhipu
    var id: String { rawValue }

    struct Info {
        let name: String
        let endpoint: String
        /// 申請 API key 的頁面
        let keyPage: String
        /// 第一個是預設
        let models: [(id: String, name: String)]
    }

    var info: Info {
        switch self {
        case .openai:
            return Info(name: "OpenAI", endpoint: "https://api.openai.com/v1/chat/completions", keyPage: "https://platform.openai.com/api-keys",
                        models: [("gpt-5-mini", "GPT-5 mini"), ("gpt-5-nano", "GPT-5 nano"), ("gpt-5.4-mini", "GPT-5.4 mini")])
        case .claude:
            return Info(name: "Claude", endpoint: "https://api.anthropic.com/v1/messages", keyPage: "https://platform.claude.com/settings/keys",
                        models: [("claude-haiku-4-5", "Claude Haiku 4.5"), ("claude-sonnet-5-5", "Claude Sonnet 5.5")])
        case .gemini:
            return Info(name: "Gemini", endpoint: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", keyPage: "https://aistudio.google.com/apikey",
                        models: [("gemini-3.7-flash", "Gemini 3.7 Flash"), ("gemini-3.1-flash-lite", "Gemini 3.1 Flash-Lite"), ("gemini-3.8-flash", "Gemini 3.8 Flash")])
        case .groq:
            return Info(name: "Groq", endpoint: "https://api.groq.com/openai/v1/chat/completions", keyPage: "https://console.groq.com/keys",
                        models: [("openai/gpt-oss-120b", "GPT-OSS 120B"), ("qwen/qwen3.8-27b", "Qwen3.8 27B"), ("openai/gpt-oss-20b", "GPT-OSS 20B")])
        case .grok:
            return Info(name: "xAI Grok", endpoint: "https://api.x.ai/v1/chat/completions", keyPage: "https://console.x.ai",
                        models: [("grok-4.20-0309-non-reasoning", "Grok 4.20"), ("grok-4.3", "Grok 4.3"), ("grok-4.7", "Grok 4.7")])
        case .deepseek:
            return Info(name: "DeepSeek", endpoint: "https://api.deepseek.com/chat/completions", keyPage: "https://platform.deepseek.com/api_keys",
                        models: [("deepseek-flash", "DeepSeek Flash"), ("deepseek-v4-pro", "DeepSeek V4 Pro")])
        case .zhipu:
            return Info(name: L("智譜 Z.ai", "Z.ai (Zhipu)"), endpoint: "https://api.z.ai/api/paas/v4/chat/completions", keyPage: "https://z.ai/manage-apikey/apikey-list",
                        models: [("glm-4.7-flash", L("GLM-4.7-Flash（免費）", "GLM-4.7-Flash (free)")), ("glm-4.5-flash", L("GLM-4.5-Flash（免費）", "GLM-4.5-Flash (free)"))])
        }
    }

    var name: String { info.name }
    var endpoint: URL { URL(string: info.endpoint)! }
    var keyPage: URL { URL(string: info.keyPage)! }
    var models: [(id: String, name: String)] { info.models }

    /// 各家要的額外參數；翻譯不需要推理，能關就關、不能關就調到最低，快很多也省錢
    func extraBody(model: String) -> [String: Any] {
        switch self {
        case .openai, .gemini: return ["reasoning_effort": "low"]
        case .groq: return ["reasoning_effort": model.hasPrefix("qwen/") ? "none" : "low"]
        case .zhipu, .deepseek: return ["thinking": ["type": "disabled"]]
        // Sonnet 5.5 的思考關不掉，只能降 effort；Haiku 4.5 預設就不思考，也不收 effort
        case .claude: return model.hasPrefix("claude-sonnet") ? ["output_config": ["effort": "low"]] : [:]
        case .grok: return [:]
        }
    }

    /// 跟雲端轉錄同一家（Groq、OpenAI）時共用同一把
    var apiKey: String? {
        get { APIKeys[rawValue] }
        nonmutating set { APIKeys[rawValue] = newValue }
    }
}

enum Translator {
    /// 翻譯先藏起來（設定的翻譯區、逐字稿上的翻譯按鈕），之後要用改成 true
    static let enabled = false

    enum Target: String {
        case zh, en
        var label: String { self == .zh ? L("中文", "Chinese") : L("英文", "English") }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 一次送幾句：太多容易漏行，太少請求次數多
    static let chunkSize = 30

    /// 依序一批批翻，每批翻完就回報（句子 id → 譯文），畫面可以邊翻邊出現
    static func translate(_ lines: [(id: UUID, text: String)], to target: Target,
                          provider: TranslationProvider, model: String,
                          progress: @MainActor ([UUID: String], Double) -> Void) async throws {
        guard let key = provider.apiKey else {
            throw Failure(message: L("還沒設定 \(provider.name) 的 API key，到設定 › 翻譯填入。", "No API key for \(provider.name) yet. Add one in Settings › Translation."))
        }
        var start = 0
        while start < lines.count {
            try Task.checkCancellation()
            let chunk = Array(lines[start..<min(start + chunkSize, lines.count)])
            let result = try await translate(chunk, to: target, provider: provider, model: model, key: key)
            start += chunk.count
            await progress(result, Double(start) / Double(lines.count))
        }
    }

    /// 回來的行數對不上（漏行、併行）就把沒翻到的拆成兩半再送，拆到單句還不行就放棄那句
    private static func translate(_ chunk: [(id: UUID, text: String)], to target: Target,
                                  provider: TranslationProvider, model: String, key: String) async throws -> [UUID: String] {
        let numbered = chunk.enumerated().map { "[\($0 + 1)] " + $1.text.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n")
        let reply = try await complete(system: prompt(target), user: numbered, provider: provider, model: model, key: key)
        var result: [UUID: String] = [:]
        for line in reply.split(whereSeparator: \.isNewline) {
            guard let m = line.firstMatch(of: #/^\s*\[(\d+)\]\s*(.*)$/#), let n = Int(m.1), (1...chunk.count).contains(n) else { continue }
            let text = String(m.2).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            result[chunk[n - 1].id] = target == .zh ? Settings.script.convert(text) : text
        }
        let missing = chunk.filter { result[$0.id] == nil }
        if !missing.isEmpty, chunk.count > 1 {
            let half = (missing.count + 1) / 2
            for part in [Array(missing[..<half]), Array(missing[half...])] where !part.isEmpty {
                try await result.merge(translate(part, to: target, provider: provider, model: model, key: key)) { $1 }
            }
        }
        return result
    }

    // MARK: 本機（Apple 翻譯）

    /// 本機翻譯一次只能一個方向：翻成中文就是英文→中文，反過來也是
    static func localConfiguration(_ target: Target) -> TranslationSession.Configuration {
        let chinese = Locale.Language(identifier: Settings.script == .simplified ? "zh" : "zh-TW"), english = Locale.Language(identifier: "en")
        return target == .zh ? .init(source: english, target: chinese) : .init(source: chinese, target: english)
    }

    /// 只送另一種語言的句子；已經是目標語言的不翻、不顯示
    static func translateLocally(_ lines: [(id: UUID, text: String)], to target: Target, session: TranslationSession,
                                 progress: @MainActor ([UUID: String], Double) -> Void) async throws {
        let other = lines.filter { language(of: $0.text) != target }
        guard !other.isEmpty else { return await progress([:], 1) }
        var start = 0
        while start < other.count {
            try Task.checkCancellation()
            let chunk = other[start..<min(start + chunkSize, other.count)]
            let responses = try await session.translations(from: chunk.map { .init(sourceText: $0.text, clientIdentifier: $0.id.uuidString) })
            var result: [UUID: String] = [:]
            for r in responses {
                guard let id = r.clientIdentifier.flatMap(UUID.init(uuidString:)) else { continue }
                result[id] = target == .zh ? Settings.script.convert(r.targetText) : r.targetText
            }
            start += chunk.count
            await progress(result, Double(start) / Double(other.count))
        }
    }

    private static func language(of text: String) -> Target? {
        switch NLLanguageRecognizer.dominantLanguage(for: text) {
        case .english: return .en
        case .simplifiedChinese, .traditionalChinese: return .zh
        default: return nil
        }
    }

    // MARK: 雲端

    /// 設定裡的「檢查」：送一句最短的請求，金鑰錯會直接被拒
    static func check(_ provider: TranslationProvider, key: String, model: String) async throws {
        _ = try await complete(system: "Reply with OK.", user: "ping", provider: provider, model: model, key: key, attempts: 2)
    }

    private static func prompt(_ target: Target) -> String {
        let language: String
        switch (target, Settings.script) {
        case (.en, _): language = "English"
        case (.zh, .simplified): language = "简体中文"
        case (.zh, _): language = "繁體中文，用台灣用語（例如：影片、軟體、伺服器、資料庫、示範、流程）"
        }
        return """
        你是會議逐字稿的翻譯。使用者給的每一行是一句話，格式是「[編號] 原文」，原文是語音辨識的結果，可能有錯字、中英夾雜。
        把每一句翻成\(language)，意思通順自然，人名、產品名、程式名詞可以保留原文。
        輸出格式和輸入一樣：每行「[編號] 譯文」，編號和行數都不能變，不能合併或拆開句子；已經是目標語言的句子照抄。
        只輸出譯文，不要加任何說明。
        """
    }

    /// 免費模型常回「忙線」，等一下再試
    private static func complete(system: String, user: String, provider: TranslationProvider, model: String, key: String, attempts: Int = 6) async throws -> String {
        var body = provider.extraBody(model: model)
        body["model"] = model
        var request = URLRequest(url: provider.endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if provider == .claude {
            body["system"] = system
            body["messages"] = [["role": "user", "content": user]]
            body["max_tokens"] = 16000
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            body["messages"] = [["role": "system", "content": system], ["role": "user", "content": user]]
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var lastError = ""
        for attempt in 0..<attempts {
            if attempt > 0 { try await Task.sleep(for: .seconds(min(2 << attempt, 30))) }
            let data: Data, status: Int
            do {
                let (d, r) = try await URLSession.shared.data(for: request)
                data = d
                status = (r as? HTTPURLResponse)?.statusCode ?? 0
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error.localizedDescription
                continue
            }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if status == 200, let content = provider == .claude ? claudeText(json) : ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String {
                return content
            }
            // 錯誤格式各家不同：{"error":{"message"}}、Gemini 包在陣列裡、xAI 的 error 直接是字串
            let errObj = json ?? ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]])?.first
            let err = errObj?["error"] as? [String: Any]
            lastError = (err?["message"] as? String) ?? (errObj?["error"] as? String) ?? String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            // 金鑰錯、參數錯重試也沒用；1305 是智譜的忙線，不管狀態碼都再試
            if [400, 401, 403, 404].contains(status), "\(err?["code"] ?? "")" != "1305" {
                throw Failure(message: L("\(provider.name) 拒絕了請求：\(lastError)", "\(provider.name) rejected the request: \(lastError)"))
            }
        }
        throw Failure(message: L("\(provider.name) 一直沒回應：\(lastError)", "\(provider.name) isn’t responding: \(lastError)"))
    }

    /// Claude 回的是內容區塊：思考區塊略過，文字區塊接起來
    private static func claudeText(_ json: [String: Any]?) -> String? {
        guard let blocks = json?["content"] as? [[String: Any]] else { return nil }
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        return text.isEmpty ? nil : text
    }
}
