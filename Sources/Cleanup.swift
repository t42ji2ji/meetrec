import Foundation

/// AI 整理逐字稿：一批批送給側欄選的 Claude Code／Codex 修錯字、標點、贅字，
/// 改過的句子列在側欄讓使用者勾選，按套用才寫進逐字稿；套用後可以復原
@MainActor
final class TranscriptCleanup: ObservableObject {
    struct Change: Identifiable {
        let id: UUID
        let start: Double
        let original: String
        let revised: String
        var accepted = true
    }

    enum Phase: Equatable {
        case running(done: Int, total: Int)
        case review
        case applied(Int)
        case failed(String)
    }

    let editor: TranscriptEditor
    /// 這次照什麼指示改（預設的整理，或 AI 對話裡講好的）
    let instruction: String
    @Published private(set) var phase: Phase
    @Published var changes: [Change] = []
    private let started = Date()
    private var task: Task<Void, Never>?

    /// 一批幾句：太多容易漏行，太少呼叫次數多（每次 CLI 啟動要幾秒）
    static let batchSize = 40
    /// 同時跑幾批
    static let parallel = 3

    static let instruction = L("修正錯字和同音錯字、補上標點，去掉嗯、呃、那個這類贅字。保持原本的語言和說話的口氣，不要改成書面語，不要翻譯。",
                               "Fix typos and misheard words, add punctuation, and remove filler words like um and uh. Keep the original language and speaking tone; don't make it formal and don't translate.")

    init(editor: TranscriptEditor, kind: AssistantKind, tool: URL, path: String, model: String?, instruction: String? = nil) {
        self.editor = editor
        let instruction = instruction ?? Self.instruction
        self.instruction = instruction
        let lines = editor.transcript.segments.map { (id: $0.id, start: $0.start, text: $0.text) }.filter { !$0.text.isEmpty }
        let batches = stride(from: 0, to: lines.count, by: Self.batchSize).map { Array(lines[$0..<min($0 + Self.batchSize, lines.count)]) }
        phase = batches.isEmpty ? .review : .running(done: 0, total: batches.count)
        guard !batches.isEmpty else { return }

        var system = """
        你會收到一段會議逐字稿，每行開頭是 [編號]。照下面的指示逐行修正，每一行都照原本的編號輸出：「[編號] 修正後的文字」。\
        不要合併、拆開或刪掉任何一行，不用改的行照原樣輸出，不要加任何說明。

        指示：\(instruction)
        """
        let words = Settings.vocabulary.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !words.isEmpty { system += "\n\n常用詞（逐字稿裡聽起來像這些的，照這個寫法）：" + words.joined(separator: "、") }

        task = Task { [weak self] in
            var next = 0
            await withTaskGroup(of: (Int, Result<String, Error>).self) { group in
                func add() {
                    guard next < batches.count else { return }
                    let i = next, batch = batches[i]
                    next += 1
                    let user = batch.enumerated().map { "[\($0 + 1)] " + $1.text.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n")
                    group.addTask {
                        (i, await Result { try await AssistantCLI.once(kind, tool: tool, path: path, model: model, system: system, user: user, timeout: 300) })
                    }
                }
                for _ in 0..<Self.parallel { add() }
                var done = 0
                for await (i, result) in group {
                    guard let self, !Task.isCancelled else { group.cancelAll(); return }
                    switch result {
                    case .success(let reply): self.collect(reply, batch: batches[i])
                    case .failure(let error):
                        group.cancelAll()
                        self.phase = .failed("\(error)")
                        return
                    }
                    done += 1
                    self.phase = done == batches.count ? .review : .running(done: done, total: batches.count)
                    add()
                }
            }
        }
    }

    /// 回來的「[n] 文字」對回原本的句子；漏掉的行當作沒改
    private func collect(_ reply: String, batch: [(id: UUID, start: Double, text: String)]) {
        for line in reply.split(whereSeparator: \.isNewline) {
            guard let m = line.firstMatch(of: #/^\s*\[(\d+)\]\s*(.*)$/#), let n = Int(m.1), (1...batch.count).contains(n) else { continue }
            let s = batch[n - 1]
            let revised = Settings.script.convert(String(m.2).trimmingCharacters(in: .whitespaces))
            guard !revised.isEmpty, revised != s.text else { continue }
            changes.append(Change(id: s.id, start: s.start, original: s.text, revised: revised))
        }
        changes.sort { $0.start < $1.start }
    }

    /// 還沒跑完時預估剩下幾秒；第一批回來前不知道
    var remaining: Int? {
        guard case .running(let done, let total) = phase, done > 0 else { return nil }
        // 已經是平行跑下來的平均，直接乘剩下的批數
        return Int(Date().timeIntervalSince(started) / Double(done) * Double(total - done))
    }

    /// 只套用勾選的；整理途中使用者自己改過的句子不蓋掉
    func apply() {
        var n = 0
        for c in changes where c.accepted && editor.text(c.id) == c.original {
            editor.setText(c.id, c.revised)
            n += 1
        }
        editor.flush()
        phase = .applied(n)
    }

    func undo() {
        for c in changes where c.accepted && editor.text(c.id) == c.revised { editor.setText(c.id, c.original) }
        editor.flush()
        phase = .review
    }

    func cancel() { task?.cancel() }

    isolated deinit { task?.cancel() }
}
