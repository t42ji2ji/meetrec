import Foundation

/// 轉逐字稿需要的模型：不放進 app（太大），第一次使用時下載到 Application Support/MeetRec
@MainActor
final class Models: NSObject, ObservableObject {
    static let shared = Models()

    struct Model: Identifiable {
        let file: String
        let name: String
        let purpose: String
        let url: URL
        let size: Int64
        var id: String { file }
        var path: String { Transcriber.dir + "/" + file }
    }

    nonisolated static let all = [
        Model(file: "ggml-large-v3-turbo-q5_0.bin", name: "Whisper large-v3-turbo", purpose: "語音轉文字",
              url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!, size: 574_041_195),
        Model(file: "ggml-silero-v5.1.2.bin", name: "Silero VAD", purpose: "找出有人說話的段落",
              url: URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!, size: 885_098),
        Model(file: "pyannote-segmentation-3-0.onnx", name: "pyannote segmentation 3.0", purpose: "切出每個人說話的片段",
              url: URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/main/model.onnx")!, size: 5_992_913),
        Model(file: "3dspeaker-campplus-zh-en.onnx", name: "3D-Speaker CAM++", purpose: "分辨不同的人（中英文）",
              url: URL(string: "https://huggingface.co/csukuangfj/speaker-embedding-models/resolve/main/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx")!, size: 28_281_164),
    ]

    nonisolated static var totalSize: Int64 { all.reduce(0) { $0 + $1.size } }

    /// 檔案在、大小對才算有（下載到一半的不算）
    nonisolated static func installed(_ m: Model) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: m.path)[.size] as? Int64) == m.size
    }

    nonisolated static var ready: Bool { all.allSatisfy(installed) }

    /// 0...1；nil＝沒在下載
    @Published private(set) var progress: Double?
    @Published private(set) var error: String?
    /// 檔案狀態變了就 +1，畫面靠它重讀
    @Published private(set) var revision = 0

    private var task: Task<Void, Never>?

    func downloadAll() {
        guard task == nil else { return }
        error = nil
        progress = 0
        task = Task {
            do {
                try FileManager.default.createDirectory(atPath: Transcriber.dir, withIntermediateDirectories: true)
                let missing = Self.all.filter { !Self.installed($0) }
                let total = Double(missing.reduce(0) { $0 + $1.size })
                var done: Int64 = 0
                for m in missing {
                    try await download(m) { bytes in self.progress = Double(done + bytes) / max(total, 1) }
                    done += m.size
                    revision += 1
                }
            } catch is CancellationError {
            } catch {
                self.error = "下載失敗：\(error.localizedDescription)"
            }
            progress = nil
            task = nil
            revision += 1
        }
    }

    func cancel() { task?.cancel() }

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
