import AppKit

/// 本機裝的 AI 命令列工具（Claude Code、Codex），拿來跟逐字稿對話。用使用者自己的登入，MeetRec 不碰金鑰
enum AssistantKind: String, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    var name: String { self == .claude ? "Claude Code" : "Codex" }

    /// 可以選的模型（id 給命令列用）。不在清單裡的話就用工具自己設定的預設
    var models: [(id: String, name: String)] {
        switch self {
        case .claude:
            return [("fable", "Fable"), ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")]
        case .codex:
            // Codex 把帳號能用的模型存在這裡，跟它自己的選單一樣只列 visibility = list 的
            let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/models_cache.json")
            guard let data = try? Data(contentsOf: file),
                  let list = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["models"] as? [[String: Any]] else { return [] }
            return list.filter { $0["visibility"] as? String == "list" }
                .sorted { ($0["priority"] as? Int ?? 0) < ($1["priority"] as? Int ?? 0) }
                .compactMap { m in (m["slug"] as? String).map { ($0, m["display_name"] as? String ?? $0) } }
        }
    }
}

enum AssistantCLI {
    /// 從 Finder 打開的 app 拿到的 PATH 只有系統目錄；claude、codex（還有 codex 要的 node）通常裝在使用者 shell 才加進來的地方
    struct Found {
        var tools: [AssistantKind: URL]
        var path: String
    }

    static func detect() async -> Found {
        await Task.detached(priority: .utility) {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            var dirs = loginShellPath()?.split(separator: ":").map(String.init) ?? []
            for d in ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin", "/usr/bin", "/bin"] where !dirs.contains(d) {
                dirs.append(d)
            }
            var tools: [AssistantKind: URL] = [:]
            for kind in AssistantKind.allCases {
                for d in dirs {
                    let p = "\(d)/\(kind.rawValue)"
                    if FileManager.default.isExecutableFile(atPath: p) {
                        tools[kind] = URL(fileURLWithPath: p)
                        break
                    }
                }
            }
            return Found(tools: tools, path: dirs.joined(separator: ":"))
        }.value
    }

    /// 一次性的問答（語音輸入改寫、整理逐字稿）：不用工具、不留 session，回最後的文字
    static func once(_ kind: AssistantKind, tool: URL, path: String, model: String?, system: String, user: String, timeout: Double = 60) async throws -> String {
        let last = FileManager.default.temporaryDirectory.appendingPathComponent("MeetRec-once-\(UUID().uuidString).txt")
        var args: [String], input = user
        switch kind {
        case .claude:
            // 不用工具、不載 MCP、不留 session，只要一次回答
            args = ["-p", "--tools", "", "--strict-mcp-config", "--no-session-persistence", "--output-format", "text", "--system-prompt", system]
            if let model { args += ["--model", model] }
        case .codex:
            // codex 沒有 system prompt 參數，指示放在前面；最後的回答寫到檔案，不用從輸出裡挑
            args = ["exec", "-c", "sandbox_mode=\"read-only\"", "--skip-git-repo-check", "--output-last-message", last.path]
            if let model { args += ["-m", model] }
            args.append("-")
            input = system + "\n\n" + user
        }
        let dir = await AssistantChat.workingDirectory
        return try await Task.detached {
            let p = Process()
            p.executableURL = tool
            p.arguments = args
            p.currentDirectoryURL = dir
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = path
            p.environment = env
            let stdin = Pipe(), out = Pipe(), err = Pipe()
            p.standardInput = stdin
            p.standardOutput = out
            p.standardError = err
            try p.run()
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
            let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            let stdout = out.fileHandleForReading.readDataToEndOfFile()
            let stderr = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            timer.cancel()
            defer { try? FileManager.default.removeItem(at: last) }
            guard p.terminationStatus == 0 else {
                let message = String(decoding: stderr.isEmpty ? stdout : stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw Translator.Failure(message: "\(kind.name)：" + (message.isEmpty ? L("沒有回應", "no response") : String(message.suffix(200))))
            }
            return kind == .codex ? ((try? String(contentsOf: last, encoding: .utf8)) ?? "") : String(decoding: stdout, as: UTF8.self)
        }.value
    }

    /// 開一個互動登入 shell 印出 PATH；.zshrc 可能會印別的東西，用記號把 PATH 挑出來
    private static func loginShellPath() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        p.arguments = ["-ilc", "echo __MEETREC_PATH__$PATH"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        // .zshrc 卡住（例如在等輸入）就放棄，改用固定的候選目錄
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        timer.cancel()
        let text = String(decoding: data, as: UTF8.self)
        guard let r = text.range(of: "__MEETREC_PATH__", options: .backwards) else { return nil }
        return text[r.upperBound...].split(separator: "\n").first.map(String.init)
    }
}

/// 一場錄音的 AI 對話。第一句話連同逐字稿一起送出，之後接著同一個 session 問。
/// 每次回完存進錄音資料夾，關掉 app 再開還在，按「新對話」才清掉
@MainActor
final class AssistantChat: ObservableObject {
    struct Message: Identifiable, Codable {
        enum Role: String, Codable { case user, assistant, error }
        var id = UUID()
        let role: Role
        var text: String
        /// 附的圖，已轉成 JPEG
        var images: [Data] = []
        /// 用 @ 附上的其他場錄音名稱（只用來顯示；逐字稿在送出時就放進 prompt 了）
        var refs: [String]? = nil
        /// 這則回覆畫的圖：錄音資料夾裡的 HTML 檔名（資料夾會改名，所以不存完整路徑）
        var diagram: String? = nil
        private enum CodingKeys: CodingKey { case role, text, images, refs, diagram }
    }

    private struct Saved: Codable {
        var session: String?
        var messages: [Message]
    }

    let kind: AssistantKind
    private let file: URL
    @Published private(set) var messages: [Message] = []
    @Published private(set) var running = false
    /// 正在用的工具（MCP、讀檔、skill…），回覆中顯示在點點旁邊
    @Published private(set) var activity: String?

    /// Claude 要用需要確認的工具（MCP 等）時來問，等使用者按允許或拒絕
    struct Approval: Identifiable {
        let id: String
        let tool: String
        let detail: String
        let input: Data
    }
    @Published private(set) var approvals: [Approval] = []
    /// Claude 的權限詢問要從這裡回答，回完最後結果才關
    private var stdin: FileHandle?
    private var session: String?
    private var process: Process?
    /// 給 codex 的暫存圖檔，回完就刪
    private var imageFiles: [URL] = []

    init(kind: AssistantKind, file: URL) {
        self.kind = kind
        self.file = file
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            session = saved.session
            messages = saved.messages
        }
    }

    /// 錄音資料夾裡每種工具一個隱藏檔，改名、刪除時跟著資料夾走
    static func file(in folder: URL, kind: AssistantKind) -> URL {
        folder.appendingPathComponent(".chat-\(kind.rawValue).json")
    }

    /// claude 只能在開始對話的那個目錄接回 session，錄音資料夾改名就接不回來，所以固定用同一個目錄
    static let workingDirectory = URL(fileURLWithPath: Transcriber.dir)

    /// 開新對話：停掉、刪掉存檔
    func discard() {
        stop()
        try? FileManager.default.removeItem(at: file)
    }

    private static let instructions = "你是會議助理。使用者會給你一場會議的逐字稿（語音辨識產生，可能有錯字、說話者標錯），請根據逐字稿回答問題，用使用者提問的語言回答。逐字稿裡沒有的事要直說沒提到，不要編；需要逐字稿以外的資料時可以用工具去查。使用者也可能附上其他場會議的逐字稿當參考，每份開頭有標題和日期，提到時要講清楚是哪一場。\n\n使用者要圖表或報告時用 diagram-design skill。你不能寫檔也不能跑指令：跳過所有寫檔、跑腳本、驗證、匯出的步驟，不要問樣式或要不要存 profile。只要一張圖就做一張圖。要報告時做成一份完整文件：標題、日期、照要求分章節，每章是簡短的文字，只在圖比文字清楚的地方放圖，整份二到四張，每張圖照 diagram-design 的規則畫成獨立的 inline SVG；清單、對照用表格或條列，不要硬畫成圖；內文用系統字型，整頁內容最寬約 960px，圖的 viewBox 寬度不超過它。HTML 的顏色要用 CSS 變數，淺色定義在 :root，深色定義在 @media (prefers-color-scheme: dark) 裡，同一個檔案跟著系統外觀切換；<title> 寫這份圖表或報告的名稱。先用一兩句話說明做了什麼，接著把完整、獨立的 HTML 放在回覆最後一個 ```\(diagramFence) 程式碼區塊裡，區塊後面不要再寫任何東西，也不要叫使用者開檔案。"

    /// 回覆裡圖表 HTML 的程式碼區塊標記，回完由 app 取出存檔
    static let diagramFence = "html meetrec-diagram"

    /// 打包在 app 裡的 diagram-design（claude --plugin-dir 用）
    private static let diagramPlugin = Bundle.main.resourceURL?.appendingPathComponent("diagram-design")

    /// context：這一句另外附上的其他場逐字稿
    func send(_ question: String, images: [Data], refs: [String], context: String, transcript: () -> String?, model: String?, tool: URL, path: String) {
        guard !running else { return }
        var prompt = context.isEmpty ? question : "\(context)\n\n\(question)"
        if session == nil {
            guard let t = transcript() else { return }
            prompt = (kind == .codex ? Self.instructions + "\n\n" : "") + "<transcript>\n\(t)</transcript>\n\n\(prompt)"
        }
        messages.append(Message(role: .user, text: question, images: images, refs: refs.isEmpty ? nil : refs))

        var args: [String]
        var input = Data(prompt.utf8)
        switch kind {
        case .claude:
            // 圖片要用 JSON 輸入才能跟文字一起送
            // 內建工具只留唯讀的；要確認的（使用者自己的 MCP）經 stdio 問回來，見 handle 的 control_request。
            // 權限模式寫死 default，不然會用使用者自己設的（例如 auto 會自己放行）
            args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--tools", "Read,Grep,Glob,WebFetch,WebSearch,Skill,ToolSearch",
                    "--permission-mode", "default", "--permission-prompt-tool", "stdio",
                    "--append-system-prompt", Self.instructions]
            if let dir = Self.diagramPlugin, FileManager.default.fileExists(atPath: dir.path) { args += ["--plugin-dir", dir.path] }
            if let session { args += ["--resume", session] }
            if let model { args += ["--model", model] }
            var content: [[String: Any]] = images.map {
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": $0.base64EncodedString()]]
            }
            if !prompt.isEmpty { content.append(["type": "text", "text": prompt]) }
            let line: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
            input = ((try? JSONSerialization.data(withJSONObject: line)) ?? Data()) + Data("\n".utf8)
        case .codex:
            // resume 不吃 -s，用設定覆寫讓接續的對話也是唯讀
            args = ["exec", "-c", "sandbox_mode=\"read-only\""] + (session.map { ["resume", $0] } ?? []) + ["--json", "--skip-git-repo-check"]
            if let model { args += ["-m", model] }
            // codex 只吃圖檔路徑，先寫到暫存資料夾
            for data in images {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("MeetRec-\(UUID().uuidString).jpg")
                if (try? data.write(to: file)) != nil {
                    imageFiles.append(file)
                    args.append("--image=\(file.path)")
                }
            }
            args.append("-")
        }
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        p.currentDirectoryURL = Self.workingDirectory
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        p.environment = env
        let stdin = Pipe(), out = Pipe(), err = Pipe()
        p.standardInput = stdin
        p.standardOutput = out
        p.standardError = err

        let reply = Message(role: .assistant, text: "")
        messages.append(reply)
        running = true
        process = p
        var pending = Data(), stderr = Data()
        err.fileHandleForReading.readabilityHandler = { h in stderr.append(h.availableData) }
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            // 讀到底才收尾：結束通知可能比最後幾行輸出先到
            guard !chunk.isEmpty else {
                h.readabilityHandler = nil
                p.waitUntilExit()
                err.fileHandleForReading.readabilityHandler = nil
                let ok = p.terminationStatus == 0 || p.terminationReason == .uncaughtSignal
                let errText = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.finished(reply: reply.id, ok: ok, stderr: errText) } }
                return
            }
            pending.append(chunk)
            var lines: [Data] = []
            while let nl = pending.firstIndex(of: 10) {
                lines.append(pending[pending.startIndex..<nl])
                pending = Data(pending[(nl + 1)...])
            }
            guard !lines.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { lines.forEach { self?.handle($0, reply: reply.id) } } }
        }
        do {
            try p.run()
            stdin.fileHandleForWriting.write(input)
            if kind == .claude {
                self.stdin = stdin.fileHandleForWriting
            } else {
                try? stdin.fileHandleForWriting.close()
            }
        } catch {
            finished(reply: reply.id, ok: false, stderr: "\(error.localizedDescription)")
        }
    }

    func stop() { process?.terminate() }

    func answer(_ approval: Approval, allow: Bool) {
        approvals.removeAll { $0.id == approval.id }
        let input = (try? JSONSerialization.jsonObject(with: approval.input)) ?? [String: Any]()
        let decision: [String: Any] = allow ? ["behavior": "allow", "updatedInput": input]
                                            : ["behavior": "deny", "message": "使用者拒絕了這個工具"]
        let line: [String: Any] = ["type": "control_response", "response": ["subtype": "success", "request_id": approval.id, "response": decision]]
        guard let data = try? JSONSerialization.data(withJSONObject: line) else { return }
        stdin?.write(data + Data("\n".utf8))
    }

    /// 拖進來或選的圖：縮到長邊 1568（Claude 建議的上限，再大只是多花 token），轉成 JPEG
    nonisolated static func jpeg(_ image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, 1568 / CGFloat(max(cg.width, cg.height)))
        let w = Int(CGFloat(cg.width) * scale), h = Int(CGFloat(cg.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        // 透明的地方填白，不然 JPEG 會變黑
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    private func handle(_ line: Data, reply: UUID) {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = o["type"] as? String else { return }
        switch (kind, type) {
        case (.claude, "stream_event"):
            guard let e = o["event"] as? [String: Any] else { break }
            if let d = e["delta"] as? [String: Any], d["type"] as? String == "text_delta", let t = d["text"] as? String {
                activity = nil
                append(t, to: reply)
            } else if e["type"] as? String == "content_block_start", let b = e["content_block"] as? [String: Any] {
                if b["type"] as? String == "tool_use", let name = b["name"] as? String {
                    activity = name.split(separator: "__").last.map(String.init)
                } else if b["type"] as? String == "text", !text(of: reply).isEmpty {
                    // 用完工具再開口的那段跟前面隔開
                    append("\n\n", to: reply)
                }
            }
        case (.claude, "control_request"):
            guard let id = o["request_id"] as? String, let r = o["request"] as? [String: Any], r["subtype"] as? String == "can_use_tool" else { break }
            let name = r["display_name"] as? String ?? r["tool_name"] as? String ?? ""
            let input = r["input"] ?? [String: Any]()
            let data = (try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8)
            let short = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) } ?? ""
            let server = (r["mcp_server"] as? String).map { "\($0) · " } ?? ""
            approvals.append(Approval(id: id, tool: server + name, detail: short == "{}" ? "" : String(short.prefix(300)), input: data))
        case (.claude, "result"):
            // 這一輪問完了，關掉 stdin 讓它結束
            try? stdin?.close()
            stdin = nil
            if let s = o["session_id"] as? String { session = s }
            if o["is_error"] as? Bool == true, let r = o["result"] as? String { fail(r, reply: reply) }
        case (.codex, "thread.started"):
            if let s = o["thread_id"] as? String { session = s }
        case (.codex, "item.started"):
            if let item = o["item"] as? [String: Any] {
                activity = item["tool"] as? String ?? item["command"] as? String
            }
        case (.codex, "item.completed"):
            activity = nil
            if let item = o["item"] as? [String: Any], item["type"] as? String == "agent_message", let t = item["text"] as? String {
                append((text(of: reply).isEmpty ? "" : "\n\n") + t, to: reply)
            }
        case (.codex, "turn.failed"):
            if let e = o["error"] as? [String: Any], let m = e["message"] as? String { fail(m, reply: reply) }
        default:
            break
        }
    }

    private func text(of id: UUID) -> String { messages.first { $0.id == id }?.text ?? "" }

    private func append(_ t: String, to id: UUID) {
        if let i = messages.firstIndex(where: { $0.id == id }) { messages[i].text += t }
    }

    private func fail(_ message: String, reply: UUID) {
        if let i = messages.firstIndex(where: { $0.id == reply }) {
            messages[i] = Message(role: .error, text: message)
        }
    }

    private func finished(reply: UUID, ok: Bool, stderr: String) {
        running = false
        activity = nil
        approvals = []
        try? stdin?.close()
        stdin = nil
        process = nil
        imageFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        imageFiles = []
        defer { save() }
        guard let i = messages.firstIndex(where: { $0.id == reply }), messages[i].role == .assistant else { return }
        extractDiagram(i)
        if messages[i].text.isEmpty, messages[i].diagram == nil {
            if ok {
                messages.remove(at: i)
            } else {
                messages[i] = Message(role: .error, text: stderr.isEmpty ? L("\(kind.name) 沒有回應", "\(kind.name) didn’t respond") : String(stderr.suffix(600)))
            }
        }
    }

    /// 回覆最後的圖表／報告區塊存成錄音資料夾裡的 HTML，對話裡只留說明文字
    private func extractDiagram(_ i: Int) {
        let text = messages[i].text
        guard let open = text.range(of: "```" + Self.diagramFence, options: .backwards),
              let close = text.range(of: "```", range: open.upperBound..<text.endIndex) else { return }
        let html = text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !html.isEmpty else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        // 檔名用 HTML 的 <title>（報告的名稱），沒有才叫「圖表」
        let title = html.range(of: "(?<=<title>)[^<]+(?=</title>)", options: .regularExpression)
            .map { html[$0].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") }
        let name = (title?.isEmpty == false ? title! : L("圖表", "Diagram")) + " \(f.string(from: Date())).html"
        guard (try? html.write(to: file.deletingLastPathComponent().appendingPathComponent(name), atomically: true, encoding: .utf8)) != nil else { return }
        messages[i].text = text[..<open.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        messages[i].diagram = name
    }

    /// 圖表檔在錄音資料夾裡的位置
    func diagramURL(_ name: String) -> URL { file.deletingLastPathComponent().appendingPathComponent(name) }

    /// 這場產生過的報告和圖表，新的在前；開新對話不會刪掉
    var reports: [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)) ?? []
        let date = { (u: URL) in (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return files.filter { $0.pathExtension == "html" }.sorted { date($0) > date($1) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Saved(session: session, messages: messages)) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
