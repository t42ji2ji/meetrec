import Foundation

/// 轉逐字稿需要的模型：不放進 app（太大），第一次使用時下載到 Application Support/MeetRec
@MainActor
final class Models: NSObject, ObservableObject {
    static let shared = Models()

    struct Model: Identifiable {
        let file: String
        let name: String
        let purposeZh: String, purposeEn: String
        let url: URL
        let size: Int64
        var id: String { file }
        var purpose: String { L(purposeZh, purposeEn) }
        var path: String { Transcriber.dir + "/" + file }
    }

    /// 語音轉文字可以換（Settings.speechModel）：越大越準也越慢，讓使用者照自己的電腦選。
    /// 沒放 base：中文會整段漏掉，而且一直重試反而比 small 慢
    nonisolated static let speech = [
        whisper("ggml-small-q5_1.bin", "Whisper small", "比 turbo 快一倍，錯字較多", "About twice as fast as turbo, more mistakes", 190_085_487),
        whisper("ggml-large-v3-turbo-q5_0.bin", "Whisper large-v3-turbo", "速度和準確度兼顧", "Balanced speed and accuracy", 574_041_195),
        whisper("ggml-large-v3-q5_0.bin", "Whisper large-v3", "最準，速度約 turbo 的一半", "Most accurate, about half the speed of turbo", 1_081_140_203),
    ]

    private nonisolated static func whisper(_ file: String, _ name: String, _ zh: String, _ en: String, _ size: Int64) -> Model {
        Model(file: file, name: name, purposeZh: zh, purposeEn: en,
              url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(file)")!, size: size)
    }

    /// 不管選哪個語音模型都要的
    nonisolated static let support = [
        Model(file: "ggml-silero-v5.1.2.bin", name: "Silero VAD", purposeZh: "找出有人說話的段落", purposeEn: "Finds where people are talking",
              url: URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!, size: 885_098),
        Model(file: "pyannote-segmentation-3-0.onnx", name: "pyannote segmentation 3.0", purposeZh: "切出每個人說話的片段", purposeEn: "Splits speech into speaker turns",
              url: URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/main/model.onnx")!, size: 5_992_913),
        Model(file: "3dspeaker-campplus-zh-en.onnx", name: "3D-Speaker CAM++", purposeZh: "分辨不同的人（中英文）", purposeEn: "Tells speakers apart (Chinese & English)",
              url: URL(string: "https://huggingface.co/csukuangfj/speaker-embedding-models/resolve/main/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx")!, size: 28_281_164),
    ]

    nonisolated static var all: [Model] { speech + support }

    /// 目前選的語音模型；設定裡的檔名不在清單上（舊版、手動改）就用預設的 turbo
    nonisolated static var current: Model { speech.first { $0.file == Settings.speechModel } ?? speech[1] }

    /// 設定裡標「建議」的：記憶體 8 GB 以下的 Mac 跑大模型會跟其他 app 搶記憶體，建議 small
    nonisolated static var recommended: Model { ProcessInfo.processInfo.physicalMemory <= 8 << 30 ? speech[0] : speech[1] }

    /// 轉逐字稿現在需要的；雲端轉錄只要分說話者那些（在本機跑）
    nonisolated static var required: [Model] { (Settings.cloudTranscription ? [] : [current]) + support }

    nonisolated static var installedSize: Int64 { all.filter(installed).reduce(0) { $0 + $1.size } }

    /// 檔案在、大小對才算有（下載到一半的不算）
    nonisolated static func installed(_ m: Model) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: m.path)[.size] as? Int64) == m.size
    }

    nonisolated static var ready: Bool { required.allSatisfy(installed) }

    /// 0...1；nil＝沒在下載
    @Published private(set) var progress: Double?
    @Published private(set) var error: String?
    /// 檔案狀態變了就 +1，畫面靠它重讀
    @Published private(set) var revision = 0

    private var task: Task<Void, Never>?

    /// 換語音模型：選了才下載
    func select(_ m: Model) {
        Settings.speechModel = m.file
        revision += 1
        if !Self.ready { downloadMissing() }
    }

    /// 下載目前需要、還沒有的
    func downloadMissing() {
        guard task == nil else { return }
        error = nil
        progress = 0
        task = Task {
            do {
                try FileManager.default.createDirectory(atPath: Transcriber.dir, withIntermediateDirectories: true)
                let missing = Self.required.filter { !Self.installed($0) }
                let total = Double(missing.reduce(0) { $0 + $1.size })
                var done: Int64 = 0
                for m in missing {
                    try await download(m) { bytes in self.progress = Double(done + bytes) / max(total, 1) }
                    done += m.size
                    revision += 1
                }
            } catch is CancellationError {
            } catch {
                self.error = L("下載失敗：\(error.localizedDescription)", "Download failed: \(error.localizedDescription)")
            }
            progress = nil
            task = nil
            revision += 1
        }
    }

    func cancel() { task?.cancel() }

    func delete(_ m: Model) {
        try? FileManager.default.removeItem(atPath: m.path)
        revision += 1
    }

    func deleteAll() {
        cancel()
        for m in Self.all { try? FileManager.default.removeItem(atPath: m.path) }
        revision += 1
    }

    /// 系統下載到暫存檔，大小對了才搬到定位，下載到一半中斷不會留下壞檔
    private func download(_ m: Model, progress: @escaping @MainActor (Int64) -> Void) async throws {
        var observation: NSKeyValueObservation?
        var task: URLSessionDownloadTask?
        defer { observation?.invalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let t = URLSession.shared.downloadTask(with: m.url) { tmp, response, error in
                    do {
                        if let error { throw error }
                        guard let tmp, (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                        let size = try FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int64
                        guard size == m.size else { throw URLError(.cannotDecodeContentData) }
                        try? FileManager.default.removeItem(atPath: m.path)
                        try FileManager.default.moveItem(atPath: tmp.path, toPath: m.path)
                        cont.resume()
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
                observation = t.progress.observe(\.completedUnitCount) { p, _ in
                    let bytes = p.completedUnitCount
                    Task { @MainActor in progress(bytes) }
                }
                task = t
                t.resume()
            }
        } onCancel: {
            task?.cancel()
        }
    }
}
