import AVFoundation
import Foundation

/// 錄音資料夾的內容與操作：列出錄音、排隊轉逐字稿（含進度）、匯入、改名、刪除。畫面只透過這裡動檔案。
@MainActor
final class Library: ObservableObject {
    static let shared = Library()
    let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/會議錄音")

    struct Recording: Identifiable, Hashable {
        let url: URL
        let date: Date
        let duration: Double // 秒
        var id: URL { url }
        var title: String { url.deletingPathExtension().lastPathComponent }
    }

    enum Status: Equatable {
        case queued
        case transcribing(Double) // 0...1
        case failed(String)
    }

    /// 正在錄的那一場（AppDelegate 每秒更新）
    struct Live: Equatable {
        let title: String
        let elapsed: TimeInterval
        let paused: Bool
        let problem: String?
    }

    /// 新的在前；不含正在錄的 .aac
    @Published private(set) var recordings: [Recording] = []
    /// 沒有 entry＝閒置
    @Published private(set) var status: [URL: Status] = [:]
    @Published var live: Live?
    /// 錄音中的暫停／繼續、停止並存檔（AppDelegate 設定）
    var toggleLivePause: () -> Void = {}
    var stopLive: () -> Void = {}
    /// 有逐字稿存檔就 +1（轉錄完成、手動修正），畫面靠它重新讀逐字稿
    @Published private(set) var revision = 0
    /// 每次逐字稿轉完（主執行緒）
    var onTranscribed: ((URL, Result<Transcript, Error>) -> Void)?
    /// 正在錄的檔案，清單要排除
    var recordingFile: URL? { didSet { reload() } }

    nonisolated private static let audioTypes: Set = ["m4a", "aac", "mp3", "wav", "aiff", "aif", "caf", "flac"]
    private var watcher: DispatchSourceFileSystemObject?

    private init() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        reload()
        // 資料夾有變動（Finder 裡改名、刪檔、新錄音）就重新整理
        let fd = open(folder.path, O_EVTONLY)
        let w = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        w.setEventHandler { [weak self] in self?.reload() }
        w.setCancelHandler { close(fd) }
        w.resume()
        watcher = w
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)) ?? []
        let live = recordingFile?.standardizedFileURL
        let known = Dictionary(uniqueKeysWithValues: recordings.map { ($0.url, $0) })
        recordings = files
            .filter { Self.audioTypes.contains($0.pathExtension.lowercased()) && $0.standardizedFileURL != live }
            .map { url in
                if let r = known[url] { return r }
                let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return Recording(url: url, date: date, duration: Self.duration(url))
            }
            .sorted { $0.date > $1.date }
    }

    private static func duration(_ url: URL) -> Double {
        guard let f = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(f.length) / f.fileFormat.sampleRate
    }

    func transcript(for r: Recording) -> Transcript? { Transcript.load(for: r.url) }

    /// 手動修正後存檔（同時更新 srt/txt）
    func save(_ t: Transcript, for r: Recording) throws {
        try t.save(for: r.url)
        revision += 1
    }

    /// 排進轉錄佇列；已在排或在轉就忽略
    func transcribe(_ url: URL) {
        if let s = status[url], !isFailed(s) { return }
        status[url] = .queued
        Transcriber.queue.async {
            let result = Result {
                try Transcriber.transcribe(url) { p in
                    DispatchQueue.main.async { self.status[url] = .transcribing(p) }
                }
            }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.status[url] = nil
                    self.revision += 1
                case .failure(let e): self.status[url] = .failed("\(e)")
                }
                self.onTranscribed?(url, result)
            }
        }
    }

    private func isFailed(_ s: Status) -> Bool {
        if case .failed = s { return true }
        return false
    }

    /// 複製進錄音資料夾後轉逐字稿；AVFoundation 不能播的格式（影片、ogg、webm…）抽出聲音轉成 m4a
    func importFiles(_ urls: [URL]) {
        for src in urls {
            DispatchQueue.global().async {
                let name = src.deletingPathExtension().lastPathComponent
                let ext = src.pathExtension.lowercased()
                let playable = Self.audioTypes.contains(ext)
                let dest = self.freeURL(name, ext: playable ? ext : "m4a")
                do {
                    if playable {
                        try FileManager.default.copyItem(at: src, to: dest)
                    } else {
                        try run(Transcriber.ffmpeg, ["-v", "error", "-i", src.path, "-vn", "-c:a", "aac", "-b:a", "128k", dest.path])
                    }
                    DispatchQueue.main.async {
                        self.reload()
                        self.transcribe(dest)
                    }
                } catch {
                    DispatchQueue.main.async { self.onTranscribed?(src, .failure(error)) }
                }
            }
        }
    }

    /// 改名：音檔、逐字稿、srt、txt 一起改。回傳新的音檔位置
    @discardableResult
    func rename(_ r: Recording, to title: String) throws -> URL {
        let title = title.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        let dest = folder.appendingPathComponent(title).appendingPathExtension(r.url.pathExtension)
        guard !title.isEmpty, dest != r.url else { return r.url }
        guard !FileManager.default.fileExists(atPath: dest.path) else { throw LibraryError.nameTaken(title) }
        let fm = FileManager.default
        for (from, to) in zip(Self.related(r.url), Self.related(dest)) where fm.fileExists(atPath: from.path) {
            try fm.moveItem(at: from, to: to)
        }
        reload()
        return dest
    }

    /// 音檔和逐字稿一起丟到垃圾桶
    func delete(_ r: Recording) throws {
        for u in Self.related(r.url) where FileManager.default.fileExists(atPath: u.path) {
            try FileManager.default.trashItem(at: u, resultingItemURL: nil)
        }
        status[r.url] = nil
        reload()
    }

    /// 音檔、逐字稿 json、srt、txt
    static func related(_ audio: URL) -> [URL] {
        let base = audio.deletingPathExtension()
        return [audio, Transcript.sidecar(for: audio), base.appendingPathExtension("srt"), base.appendingPathExtension("txt")]
    }

    nonisolated private func freeURL(_ name: String, ext: String) -> URL {
        var candidate = name
        var n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).appendingPathExtension(ext).path) {
            candidate = "\(name) \(n)"
            n += 1
        }
        return folder.appendingPathComponent(candidate).appendingPathExtension(ext)
    }
}

enum LibraryError: Error, CustomStringConvertible {
    case nameTaken(String)
    var description: String {
        switch self {
        case .nameTaken(let n): return "已經有叫「\(n)」的錄音"
        }
    }
}
