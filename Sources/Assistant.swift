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

/// 一場錄音的 AI 對話。第一句話連同逐字稿一起送出，之後接著同一個 session 問
@MainActor
final class AssistantChat: ObservableObject {
    struct Message: Identifiable {
        enum Role { case user, assistant, error }
        let id = UUID()
        let role: Role
        var text: String
        /// 附的圖，已轉成 JPEG
        var images: [Data] = []
    }

    let kind: AssistantKind
    @Published private(set) var messages: [Message] = []
    @Published private(set) var running = false
    private var session: String?
    private var process: Process?
    /// 給 codex 的暫存圖檔，回完就刪
    private var imageFiles: [URL] = []

    init(kind: AssistantKind) { self.kind = kind }

    private static let instructions = "你是會議助理。使用者會給你一場會議的逐字稿（語音辨識產生，可能有錯字、說話者標錯），請根據逐字稿回答問題，用使用者提問的語言回答。逐字稿裡沒有的事要直說沒提到，不要編。"

    func send(_ question: String, images: [Data], transcript: () -> String?, model: String?, tool: URL, path: String, folder: URL) {
        guard !running else { return }
        var prompt = question
        if session == nil {
            guard let t = transcript() else { return }
            prompt = (kind == .codex ? Self.instructions + "\n\n" : "") + "<transcript>\n\(t)</transcript>\n\n\(question)"
        }
        messages.append(Message(role: .user, text: question, images: images))

        var args: [String]
        var input = Data(prompt.utf8)
        switch kind {
        case .claude:
            // 圖片要用 JSON 輸入才能跟文字一起送
            args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--tools", "", "--strict-mcp-config", "--system-prompt", Self.instructions]
            if let session { args += ["--resume", session] }
            if let model { args += ["--model", model] }
            var content: [[String: Any]] = images.map {
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": $0.base64EncodedString()]]
            }
            if !prompt.isEmpty { content.append(["type": "text", "text": prompt]) }
            let line: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
            input = ((try? JSONSerialization.data(withJSONObject: line)) ?? Data()) + Data("\n".utf8)
        case .codex:
            args = ["exec"] + (session.map { ["resume", $0] } ?? ["-s", "read-only"]) + ["--json", "--skip-git-repo-check"]
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
        p.currentDirectoryURL = folder
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
            try? stdin.fileHandleForWriting.close()
        } catch {
            finished(reply: reply.id, ok: false, stderr: "\(error.localizedDescription)")
        }
    }

    func stop() { process?.terminate() }

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
            if let e = o["event"] as? [String: Any], let d = e["delta"] as? [String: Any], d["type"] as? String == "text_delta", let t = d["text"] as? String {
                append(t, to: reply)
            }
        case (.claude, "result"):
            if let s = o["session_id"] as? String { session = s }
            if o["is_error"] as? Bool == true, let r = o["result"] as? String { fail(r, reply: reply) }
        case (.codex, "thread.started"):
            if let s = o["thread_id"] as? String { session = s }
        case (.codex, "item.completed"):
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
        process = nil
        imageFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        imageFiles = []
        guard let i = messages.firstIndex(where: { $0.id == reply }), messages[i].role == .assistant else { return }
        if messages[i].text.isEmpty {
            if ok {
                messages.remove(at: i)
            } else {
                messages[i] = Message(role: .error, text: stderr.isEmpty ? L("\(kind.name) 沒有回應", "\(kind.name) didn’t respond") : String(stderr.suffix(600)))
            }
        }
    }
}
